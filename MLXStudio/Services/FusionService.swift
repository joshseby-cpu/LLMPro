import Foundation
import SwiftUI

/// Combine two or more local models into a brand-new one ("Model fusion").
///
/// This wraps the bundled `merge_models.py` helper, which in turn invokes
/// `mergekit` — the standard tool for tensor-level model merging. Mergekit
/// runs on CPU on Apple Silicon (it uses HuggingFace `transformers`, which
/// doesn't have first-class MPS support yet) so even merging two 3B models
/// is a multi-minute operation. The progress UI reflects that.
///
/// The output lands under `<APP_SUPPORT>/MLXStudio/models/<outputName>/`
/// and is auto-rescanned into `ModelRegistry` when finished.
@MainActor
@Observable
final class FusionService {
    static let shared = FusionService()

    /// Each method maps to a recipe in `merge_models.py`'s `build_yaml`.
    enum MergeMethod: String, CaseIterable, Identifiable, Hashable {
        case slerp, linear, ties, dare

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .slerp:  "SLERP (best for 2 models)"
            case .linear: "Linear (weighted average)"
            case .ties:   "TIES"
            case .dare:   "DARE-TIES"
            }
        }

        /// Plain-language description shown beside the picker.
        var explanation: String {
            switch self {
            case .slerp:
                return "Spherical linear interpolation between exactly two models. Smoothly blends their weights along the unit sphere — usually the best 'just merge these two' choice. Set `t` to control how much of each model ends up in the mix (0.0 = all of model A, 1.0 = all of model B)."
            case .linear:
                return "Plain weighted average of N models, tensor by tensor. Predictable but blunt — averaging two strong specialists usually produces a model that's mediocre at both. Useful mainly when the models you're merging were trained from the same base."
            case .ties:
                return "TIES-Merging (Yadav et al, 2023): resolves sign conflicts between models by majority-vote per parameter, then keeps only the top-density fraction of magnitudes. Designed for merging task-specialised fine-tunes back together without them stepping on each other."
            case .dare:
                return "DARE + TIES (Yu et al, 2023): randomly drops a fraction of each model's weight delta before applying TIES. Often beats plain TIES in practice — the random dropout reduces the parameter conflicts TIES has to resolve."
            }
        }

        /// Public reference link surfaced as 'Learn more' in the UI.
        var learnMoreURL: URL? {
            switch self {
            case .slerp:  URL(string: "https://huggingface.co/blog/mlabonne/merge-models#slerp")
            case .linear: URL(string: "https://huggingface.co/blog/mlabonne/merge-models#linear")
            case .ties:   URL(string: "https://arxiv.org/abs/2306.01708")
            case .dare:   URL(string: "https://arxiv.org/abs/2311.03099")
            }
        }

        /// SLERP is hard-capped at 2 models by the mergekit grammar.
        var maxModels: Int? { self == .slerp ? 2 : nil }
        var minModels: Int { 2 }
    }

    /// Progress states the UI binds to. Each `running` carries the most
    /// recent stage label + raw message we received from the helper.
    enum FusionStage: Equatable {
        case idle
        case running(stage: String, message: String)
        case finished(outputPath: String, bytes: Int64)
        case failed(reason: String)
    }

    struct ActiveJob: Identifiable {
        let id = UUID()
        let outputName: String
        let method: MergeMethod
        let modelRepoIDs: [String]
        var stage: FusionStage = .idle
        var startedAt: Date = Date()
    }

    private(set) var active: ActiveJob?

    private init() {}

    /// Kick off a fusion job. If a previous job is still in-flight, refuses.
    /// If a previous job ended (`.finished` / `.failed`) we clear it so the
    /// user can immediately start a follow-up.
    func run(outputName: String,
             method: MergeMethod,
             models: [ModelRegistry.DetectedModel],
             t: Double = 0.5,
             weights: [Double] = [],
             density: Double = 0.5) {
        guard !outputName.isEmpty, models.count >= method.minModels else { return }
        if let maxN = method.maxModels, models.count > maxN { return }

        // Refuse new jobs only when one is actively running. Stale terminal
        // states get cleared so the user can re-run without restarting.
        if let stage = active?.stage {
            switch stage {
            case .finished, .failed: active = nil
            default: return
            }
        }

        guard PythonRuntime.shared.isReady, let python = PythonRuntime.shared.pythonURL else {
            var aborted = ActiveJob(outputName: outputName, method: method,
                                    modelRepoIDs: models.map(\.repoID))
            aborted.stage = .failed(reason: "Python runtime is not ready yet.")
            active = aborted
            return
        }

        // Mergekit loads via HuggingFace transformers, which doesn't understand
        // MLX's quantization block in config.json. Refuse quantized inputs
        // before launching the subprocess so the user gets an actionable error.
        for m in models {
            let q = m.quantization.lowercased()
            if q.contains("bit") {
                var aborted = ActiveJob(outputName: outputName, method: method,
                                        modelRepoIDs: models.map(\.repoID))
                aborted.stage = .failed(reason:
                    "‘\(m.repoID)’ is quantized (\(m.quantization)). Mergekit can only merge full-precision weights (bf16 / fp16). Use a non-quantized version of the model, or download the bf16 release.")
                active = aborted
                return
            }
        }

        let job = ActiveJob(outputName: outputName, method: method,
                            modelRepoIDs: models.map(\.repoID))
        active = job

        // Snapshot Sendable values up front so the Task block doesn't capture
        // the @MainActor service or @Model-adjacent types across actor hops.
        let methodID = method.rawValue
        let modelPaths = models.map(\.directory.path)
        let outDir = PathResolver.modelsCustomDir
            .appendingPathComponent(outputName, isDirectory: true)

        Task { @MainActor in
            try? FileManager.default.removeItem(at: outDir)

            // Build per-model weight array. SLERP uses t directly; the others
            // use per-model weights. If the caller didn't pass weights, split
            // evenly across models excluding the base (TIES/DARE) or across
            // all (linear).
            var weightArr = weights
            if weightArr.isEmpty {
                weightArr = Array(repeating: 1.0 / Double(modelPaths.count),
                                  count: modelPaths.count)
            }

            let modelsConfig: [[String: Any]] = zip(modelPaths, weightArr).map { (path, w) in
                ["path": path, "weight": w]
            }

            let configJSON: [String: Any] = [
                "method": methodID,
                "models": modelsConfig,
                "t": t,
                "density": density,
                "dtype": "bfloat16",
            ]

            let configURL = PathResolver.runtimeDir
                .appendingPathComponent(".mergekit-\(outputName).json", isDirectory: false)
            do {
                let data = try JSONSerialization.data(withJSONObject: configJSON, options: [.prettyPrinted])
                try data.write(to: configURL)
            } catch {
                active?.stage = .failed(reason: "Couldn't write mergekit config: \(error.localizedDescription)")
                return
            }

            let helper = PathResolver.helpersDir.appendingPathComponent("merge_models.py")
            guard FileManager.default.fileExists(atPath: helper.path) else {
                active?.stage = .failed(reason: "merge_models.py missing — restart the app to refresh helpers.")
                return
            }

            // First-time setup: if mergekit isn't in the venv yet (the
            // bootstrap may pre-date the Fusion feature), install it now.
            // This is a multi-GB pip resolve so we surface it as its own
            // stage rather than letting the helper fail with an obscure
            // ImportError.
            active?.stage = .running(stage: "installing", message: "Checking mergekit…")
            let alreadyInstalled = await PythonRuntime.shared.mergekitInstalled()
            if !alreadyInstalled {
                let ok = await PythonRuntime.shared.installMergekit { [weak self] msg in
                    self?.active?.stage = .running(stage: "installing", message: msg)
                }
                if !ok {
                    active?.stage = .failed(reason: "Couldn't install mergekit. Check the Settings tab → Runtime log for details, or reinstall the Python runtime.")
                    return
                }
            }

            active?.stage = .running(stage: "starting", message: "Preparing")
            do {
                _ = try await ProcessRunner.runCapturing(
                    executable: python,
                    arguments: [helper.path, configURL.path, outDir.path],
                    environment: [
                        "PYTHONUNBUFFERED": "1",
                        "HF_HOME": PathResolver.hfHome.path,
                    ],
                    onStdout: { [weak self] line in
                        Task { @MainActor in self?.handleLine(line) }
                    },
                    onStderr: { [weak self] line in
                        // mergekit logs a lot to stderr ("Warning:", "Saving:"
                        // etc) — surface as the running message but don't
                        // mistake it for a fatal error.
                        Task { @MainActor in
                            let trimmed = line.trimmingCharacters(in: .whitespaces)
                            guard !trimmed.isEmpty else { return }
                            if case .running = self?.active?.stage {
                                self?.active?.stage = .running(stage: "merging",
                                                               message: String(trimmed.prefix(160)))
                            }
                        }
                    }
                )
            } catch {
                if case .failed = active?.stage {
                    // The helper already set a specific error — keep it.
                } else {
                    active?.stage = .failed(reason: error.localizedDescription)
                }
            }

            try? FileManager.default.removeItem(at: configURL)
            await ModelRegistry.shared.scan()

            // Auto-clear terminal states after a short window so the user
            // can launch another fusion without restart.
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
            let bytes: Int64 = {
                if let n = json["bytes"] as? Int64 { return n }
                if let n = json["bytes"] as? Int { return Int64(n) }
                return 0
            }()
            active?.stage = .finished(outputPath: dst, bytes: bytes)
        case "error":
            active?.stage = .failed(reason: (json["message"] as? String) ?? "Fusion failed.")
        default:
            break
        }
    }
}
