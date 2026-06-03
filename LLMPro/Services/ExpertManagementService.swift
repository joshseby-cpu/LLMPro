import Foundation
import SwiftUI

/// Unified service for add / remove / modify operations on the experts in
/// a Mixture-of-Experts model. Wraps `manage_experts.py`, which auto-detects
/// per-expert (Mixtral / Qwen-MoE / OlmoE / DBRX) and batched (Gemma-4
/// switch_glu) tensor layouts.
///
/// Each run produces a NEW local model under `<APP_SUPPORT>/LLMPro/models/`;
/// the source is never touched. The new model is auto-rescanned into
/// `ModelRegistry` when finished.
@MainActor
@Observable
final class ExpertManagementService {
    static let shared = ExpertManagementService()

    enum Op: String, Codable {
        case add, remove, modify
    }

    enum ModifyMode: String, Codable, CaseIterable, Identifiable {
        case noise       // add Gaussian noise to the expert's weights
        case reinit      // fresh random init using fan-in std
        case clone       // overwrite with a copy of another expert + noise
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .noise:  "Add noise"
            case .reinit: "Re-initialize (random)"
            case .clone:  "Clone from another expert"
            }
        }
        var explanation: String {
            switch self {
            case .noise:
                return "Add small Gaussian noise to this expert's weights. Useful when you want to 'jiggle' an expert that has collapsed into the same behavior as another, without throwing away its learned content. Sub-percent noise is usually enough."
            case .reinit:
                return "Completely replace this expert's weights with a fresh random initialization (mean 0, std = 1/√fan-in). Use when you want one expert to start from scratch and learn something new during follow-up fine-tuning."
            case .clone:
                return "Overwrite this expert with a copy of another expert plus small noise. Same mechanic as sparse upcycling, but in-place on an existing expert slot — useful for replacing a bad/dead expert with a copy of a known-good one."
            }
        }
    }

    enum Stage: Equatable {
        case idle
        case running(stage: String, message: String)
        case finished(outputPath: String, op: Op, oldCount: Int, newCount: Int)
        case failed(reason: String)
    }

    struct ActiveJob: Identifiable {
        let id = UUID()
        let inputRepoID: String
        let outputName: String
        let op: Op
        var stage: Stage = .idle
        var startedAt: Date = Date()
    }

    private(set) var active: ActiveJob?

    private init() {}

    /// Add `count` new experts. `srcExpert` is the index to clone from (use
    /// nil → defaults to "last expert" inside the helper).
    func add(input: ModelRegistry.DetectedModel,
             outputName: String,
             count: Int,
             srcExpert: Int? = nil,
             noiseStd: Double = 0.01) {
        var args: [String: Any] = ["count": count, "noise_std": noiseStd]
        if let src = srcExpert { args["src_expert"] = src }
        launch(input: input, outputName: outputName, op: .add, args: args)
    }

    /// Remove the given expert indices. Refuses to leave fewer than 2 experts.
    func remove(input: ModelRegistry.DetectedModel,
                outputName: String,
                indices: Set<Int>) {
        launch(input: input, outputName: outputName, op: .remove,
               args: ["indices": indices.sorted()])
    }

    /// Modify one expert in-place. `mode` controls the operation; `cloneSrc`
    /// is only used when `mode == .clone`.
    func modify(input: ModelRegistry.DetectedModel,
                outputName: String,
                index: Int,
                mode: ModifyMode,
                noiseStd: Double = 0.01,
                cloneSrc: Int? = nil) {
        var args: [String: Any] = [
            "index": index,
            "op": mode.rawValue,
            "noise_std": noiseStd,
        ]
        if let src = cloneSrc { args["clone_src"] = src }
        launch(input: input, outputName: outputName, op: .modify, args: args)
    }

    // -------- internal launcher --------

    private func launch(input: ModelRegistry.DetectedModel,
                        outputName: String,
                        op: Op,
                        args: [String: Any]) {
        guard !outputName.isEmpty, input.isMoE else { return }
        if let stage = active?.stage {
            switch stage {
            case .finished, .failed: active = nil
            default: return
            }
        }
        guard PythonRuntime.shared.isReady, let python = PythonRuntime.shared.pythonURL else {
            var aborted = ActiveJob(inputRepoID: input.repoID, outputName: outputName, op: op)
            aborted.stage = .failed(reason: "Python runtime is not ready yet.")
            active = aborted
            return
        }

        let job = ActiveJob(inputRepoID: input.repoID, outputName: outputName, op: op)
        active = job

        let srcPath = input.directory.path
        let outDir = PathResolver.modelsCustomDir
            .appendingPathComponent(outputName, isDirectory: true)
        let opName = op.rawValue
        let argsJSON: String = {
            guard let data = try? JSONSerialization.data(withJSONObject: args, options: []),
                  let str = String(data: data, encoding: .utf8) else { return "{}" }
            return str
        }()

        Task { @MainActor in
            try? FileManager.default.removeItem(at: outDir)

            let helper = PathResolver.helpersDir.appendingPathComponent("manage_experts.py")
            guard FileManager.default.fileExists(atPath: helper.path) else {
                active?.stage = .failed(reason: "manage_experts.py missing — restart the app to refresh helpers.")
                return
            }

            active?.stage = .running(stage: "starting", message: "Preparing")
            do {
                _ = try await ProcessRunner.runCapturing(
                    executable: python,
                    arguments: [helper.path, opName, srcPath, outDir.path, argsJSON],
                    environment: ["PYTHONUNBUFFERED": "1"],
                    onStdout: { [weak self] line in
                        Task { @MainActor in self?.handleLine(line) }
                    },
                    onStderr: { _ in }
                )
            } catch {
                if case .failed = active?.stage {
                    // Helper already emitted a specific error — keep it.
                } else {
                    active?.stage = .failed(reason: error.localizedDescription)
                }
            }

            await ModelRegistry.shared.scan()

            try? await Task.sleep(for: .seconds(8))
            if case .finished = active?.stage { active = nil }
            if case .failed   = active?.stage { active = nil }
        }
    }

    private func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        switch json["event"] as? String {
        case "progress":
            let stage = (json["stage"] as? String) ?? ""
            let message = (json["message"] as? String) ?? ""
            active?.stage = .running(stage: stage, message: message)
        case "done":
            let dst = (json["dst"] as? String) ?? ""
            let oldN = (json["old_experts"] as? Int) ?? 0
            let newN = (json["new_experts"] as? Int) ?? 0
            let opStr = (json["op"] as? String) ?? "add"
            let op = Op(rawValue: opStr) ?? .add
            active?.stage = .finished(outputPath: dst, op: op, oldCount: oldN, newCount: newN)
        case "error":
            active?.stage = .failed(reason: (json["message"] as? String) ?? "Expert management failed.")
        default:
            break
        }
    }
}
