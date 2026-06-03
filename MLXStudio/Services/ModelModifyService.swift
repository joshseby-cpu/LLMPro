import Foundation
import SwiftUI

/// Apply transformations to a local model: strip vision capabilities and/or
/// abliterate (remove refusal direction). Both produce NEW local models so the
/// original on-disk weights are never touched.
@MainActor
@Observable
final class ModelModifyService {
    static let shared = ModelModifyService()

    enum ModificationStage: Equatable {
        case idle
        case managingExperts(op: String, message: String)
        case stripVision(stage: String, shardNum: Int?, totalShards: Int?)
        case abliterating(stage: String, message: String)
        case quantizing(bits: Int, message: String)
        case finished(outputPath: String, droppedBytes: Int64)
        case failed(reason: String)
    }

    /// Describes an expert-management edit to run as part of the pipeline.
    /// `argsJSON` is the already-serialized op-args blob that `manage_experts.py`
    /// expects as its 4th argument (see that helper's docstring). `summary` is a
    /// short human label used in progress/finished UI (e.g. "Add 2 experts").
    struct ExpertOperation: Equatable {
        let op: String          // "add" | "remove" | "modify"
        let argsJSON: String
        let summary: String
    }

    struct ActiveJob: Identifiable {
        let id = UUID()
        let inputRepoID: String
        let outputName: String
        let stripVision: Bool
        let abliterate: Bool
        let quantizeBits: Int?    // nil = don't quantize; otherwise 4 or 8
        let expertOp: ExpertOperation?   // nil = no expert edit
        var stage: ModificationStage = .idle
        var startedAt: Date = Date()
    }

    private(set) var active: ActiveJob?

    /// Latest strip-vision tally captured from the helper's `done` event.
    /// Plumbed into `.finished` so the UI can show "Removed N GB of vision weights".
    /// Reset at the start of every job; carries 0 if strip wasn't run.
    private var lastStripDroppedBytes: Int64 = 0
    private var lastStripDroppedTensors: Int = 0

    private init() {}

    /// Run the requested modifications. `outputName` becomes the directory under the
    /// custom models dir (`<APP_SUPPORT>/MLXStudio/models/<outputName>/`).
    /// Stages run in order: strip-vision → abliterate → quantize. Each stage
    /// writes to a temp dir if a later stage will consume it, else to the
    /// final dir. Temp dirs are cleaned up at the end.
    func run(input: ModelRegistry.DetectedModel,
             outputName: String,
             stripVision: Bool,
             abliterate: Bool,
             quantizeBits: Int? = nil,
             expertOp: ExpertOperation? = nil) {
        guard !outputName.isEmpty else { return }
        // Only block when an active job is genuinely in flight. A prior run
        // that completed (.finished) or failed (.failed) leaves `active`
        // non-nil until the auto-clear timer fires — that shouldn't refuse
        // a fresh attempt. The user just clicking Make new model again is
        // intentional.
        if let stage = active?.stage {
            switch stage {
            case .finished, .failed: active = nil   // reset stale state
            default: return                          // genuinely in flight
            }
        }
        guard PythonRuntime.shared.isReady, let python = PythonRuntime.shared.pythonURL else { return }

        let job = ActiveJob(
            inputRepoID: input.repoID,
            outputName: outputName,
            stripVision: stripVision,
            abliterate: abliterate,
            quantizeBits: quantizeBits,
            expertOp: expertOp
        )
        active = job
        lastStripDroppedBytes = 0
        lastStripDroppedTensors = 0

        Task { @MainActor in
            let finalDir = PathResolver.modelsCustomDir
                .appendingPathComponent(outputName, isDirectory: true)
            try? FileManager.default.createDirectory(at: finalDir.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: finalDir)

            var inputDir = input.directory
            var tmpDirs: [URL] = []

            // Stage ordering (each optional): 1 strip → 2 experts → 3
            // abliterate → 4 quantize. A stage writes to a temp dir if ANY
            // later stage is enabled, otherwise straight to finalDir.
            let stageEnabled: [Int: Bool] = [
                1: stripVision,
                2: expertOp != nil,
                3: abliterate,
                4: quantizeBits != nil,
            ]
            func destFor(currentStage: Int) -> URL {
                let hasLater = stageEnabled.contains { $0.key > currentStage && $0.value }
                if hasLater {
                    let tmp = finalDir.appendingPathExtension("stage\(currentStage)-tmp")
                    try? FileManager.default.removeItem(at: tmp)
                    tmpDirs.append(tmp)
                    return tmp
                }
                return finalDir
            }

            // Helper: schedule the auto-clear timer + run a closure inside
            // the same Task. We always want stale terminal state cleared,
            // even when an early-return path fires (e.g. strip refuses on
            // Gemma-4 → previously left the user staring at a disabled
            // button until they restarted the app).
            func scheduleAutoClear() {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(6))
                    if case .finished = active?.stage { active = nil }
                    if case .failed   = active?.stage { active = nil }
                }
            }

            // Stage 1: strip vision
            if stripVision {
                let dst = destFor(currentStage: 1)
                let ok = await runStripVision(python: python, src: inputDir, dst: dst)
                if !ok { cleanup(tmpDirs); scheduleAutoClear(); return }
                inputDir = dst
            }

            // Stage 2: manage experts (add / remove / modify)
            if let op = expertOp {
                let dst = destFor(currentStage: 2)
                let ok = await runManageExperts(python: python, src: inputDir, dst: dst, op: op)
                if !ok { cleanup(tmpDirs); scheduleAutoClear(); return }
                inputDir = dst
            }

            // Stage 3: abliterate
            if abliterate {
                let dst = destFor(currentStage: 3)
                let ok = await runAbliterate(python: python, src: inputDir, dst: dst)
                if !ok { cleanup(tmpDirs); scheduleAutoClear(); return }
                inputDir = dst
            }

            // Stage 4: quantize. `mlx_lm convert` does its own dir creation —
            // it actually REFUSES to write to an existing dir. So remove
            // finalDir first.
            if let bits = quantizeBits {
                try? FileManager.default.removeItem(at: finalDir)
                let ok = await runQuantize(python: python, src: inputDir, dst: finalDir, bits: bits)
                if !ok { cleanup(tmpDirs); scheduleAutoClear(); return }
            }

            // Pure-copy case: nothing set. UI shouldn't allow this, but be safe.
            if !stripVision && expertOp == nil && !abliterate && quantizeBits == nil {
                try? FileManager.default.copyItem(at: inputDir, to: finalDir)
            }

            cleanup(tmpDirs)
            await ModelRegistry.shared.scan()

            active?.stage = .finished(outputPath: finalDir.path,
                                      droppedBytes: lastStripDroppedBytes)
            scheduleAutoClear()
        }
    }

    private func cleanup(_ dirs: [URL]) {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
    }

    private func runStripVision(python: URL, src: URL, dst: URL) async -> Bool {
        let helper = PathResolver.helpersDir.appendingPathComponent("strip_vision.py")
        guard FileManager.default.fileExists(atPath: helper.path) else {
            active?.stage = .failed(reason: "strip_vision.py missing — restart the app to refresh helpers.")
            return false
        }
        active?.stage = .stripVision(stage: "starting", shardNum: nil, totalShards: nil)
        do {
            _ = try await ProcessRunner.runCapturing(
                executable: python,
                arguments: [helper.path, src.path, dst.path],
                environment: ["PYTHONUNBUFFERED": "1"],
                onStdout: { [weak self] line in
                    Task { @MainActor in self?.handleStripLine(line) }
                },
                onStderr: { _ in }
            )
            return true
        } catch {
            // Don't clobber a specific error the helper already wrote via its
            // JSON event stream — e.g. the Gemma-4 refusal at exit 11.
            // The catch fires synchronously when the process exits, but the
            // stdout watcher Task processes the JSON {"event":"error", ...}
            // line asynchronously and may not have run yet. Give it a brief
            // window to drain before deciding whether to set our own generic
            // message; if a specific reason has been recorded, leave it alone.
            try? await Task.sleep(for: .milliseconds(300))
            await MainActor.run {
                if case .failed = active?.stage {} else {
                    active?.stage = .failed(reason: error.localizedDescription)
                }
            }
            return false
        }
    }

    private func runManageExperts(python: URL, src: URL, dst: URL, op: ExpertOperation) async -> Bool {
        let helper = PathResolver.helpersDir.appendingPathComponent("manage_experts.py")
        guard FileManager.default.fileExists(atPath: helper.path) else {
            active?.stage = .failed(reason: "manage_experts.py missing — restart the app to refresh helpers.")
            return false
        }
        guard op.argsJSON.isEmpty == false else {
            active?.stage = .failed(reason: "Internal error: empty expert-operation arguments.")
            return false
        }
        active?.stage = .managingExperts(op: op.op, message: "Preparing")
        do {
            _ = try await ProcessRunner.runCapturing(
                executable: python,
                arguments: [helper.path, op.op, src.path, dst.path, op.argsJSON],
                environment: ["PYTHONUNBUFFERED": "1"],
                onStdout: { [weak self] line in
                    Task { @MainActor in self?.handleExpertLine(line, op: op.op) }
                },
                onStderr: { _ in }
            )
            return true
        } catch {
            // Mirror the strip-vision drain pattern: the helper may have written
            // a specific JSON error that the stdout watcher hasn't processed yet
            // when the process-exit throw fires. Give it a brief window, then
            // only set a generic message if no specific one was recorded.
            try? await Task.sleep(for: .milliseconds(300))
            await MainActor.run {
                if case .failed = active?.stage {} else {
                    active?.stage = .failed(reason: error.localizedDescription)
                }
            }
            return false
        }
    }

    private func runAbliterate(python: URL, src: URL, dst: URL) async -> Bool {
        let helper = PathResolver.helpersDir.appendingPathComponent("abliterate.py")
        guard FileManager.default.fileExists(atPath: helper.path) else {
            active?.stage = .failed(reason: "abliterate.py missing — restart the app to refresh helpers.")
            return false
        }
        active?.stage = .abliterating(stage: "starting", message: "Preparing")
        do {
            _ = try await ProcessRunner.runCapturing(
                executable: python,
                arguments: [helper.path, src.path, dst.path],
                environment: ["PYTHONUNBUFFERED": "1", "HF_HOME": PathResolver.hfHome.path],
                onStdout: { [weak self] line in
                    Task { @MainActor in self?.handleAbliterateLine(line) }
                },
                onStderr: { _ in }
            )
            return true
        } catch {
            await MainActor.run {
                if case .failed = active?.stage {} else {
                    active?.stage = .failed(reason: error.localizedDescription)
                }
            }
            return false
        }
    }

    /// Wrap `python -m mlx_lm convert --hf-path SRC --mlx-path DST -q --q-bits N`.
    /// mlx_lm.convert's stdout isn't a JSON-event stream — it just prints
    /// shard-loading and "Quantizing..." lines. We surface the latest line as
    /// the message so the UI has something live to show.
    private func runQuantize(python: URL, src: URL, dst: URL, bits: Int) async -> Bool {
        active?.stage = .quantizing(bits: bits, message: "Loading model…")
        do {
            _ = try await ProcessRunner.runCapturing(
                executable: python,
                arguments: [
                    "-m", "mlx_lm", "convert",
                    "--hf-path", src.path,
                    "--mlx-path", dst.path,
                    "-q", "--q-bits", "\(bits)"
                ],
                environment: [
                    "PYTHONUNBUFFERED": "1",
                    "HF_HOME": PathResolver.hfHome.path
                ],
                onStdout: { [weak self] line in
                    Task { @MainActor in
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return }
                        self?.active?.stage = .quantizing(bits: bits, message: String(trimmed.prefix(120)))
                    }
                },
                onStderr: { [weak self] line in
                    Task { @MainActor in
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return }
                        self?.active?.stage = .quantizing(bits: bits, message: String(trimmed.prefix(120)))
                    }
                }
            )
            return true
        } catch {
            await MainActor.run { active?.stage = .failed(reason: error.localizedDescription) }
            return false
        }
    }

    private func handleStripLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        switch json["event"] as? String {
        case "progress":
            let stage = (json["stage"] as? String) ?? ""
            let shard = json["shard_num"] as? Int
            let total = json["total_shards"] as? Int
            active?.stage = .stripVision(stage: stage, shardNum: shard, totalShards: total)
        case "done":
            // Capture how much we actually removed — surfaces in the finished UI.
            if let n = json["dropped_bytes"] as? Int64 {
                lastStripDroppedBytes = n
            } else if let n = json["dropped_bytes"] as? Int {
                lastStripDroppedBytes = Int64(n)
            }
            if let t = json["dropped_tensors"] as? Int {
                lastStripDroppedTensors = t
            }
        case "error":
            active?.stage = .failed(reason: (json["message"] as? String) ?? "Strip-vision failed")
        default:
            break
        }
    }

    private func handleAbliterateLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        switch json["event"] as? String {
        case "progress":
            let stage = (json["stage"] as? String) ?? ""
            let message = (json["message"] as? String) ?? ""
            active?.stage = .abliterating(stage: stage, message: message)
        case "error":
            active?.stage = .failed(reason: (json["message"] as? String) ?? "Abliteration failed")
        default:
            break
        }
    }

    private func handleExpertLine(_ line: String, op: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        switch json["event"] as? String {
        case "progress":
            let stage = (json["stage"] as? String) ?? ""
            let message = (json["message"] as? String) ?? ""
            active?.stage = .managingExperts(op: op, message: message.isEmpty ? stage : message)
        case "error":
            active?.stage = .failed(reason: (json["message"] as? String) ?? "Expert edit failed")
        case "done":
            // The pipeline owns the terminal `.finished` state; expert-stage
            // completion just lets the next stage proceed. Nothing to record.
            break
        default:
            break
        }
    }
}
