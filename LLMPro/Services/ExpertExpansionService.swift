import Foundation
import SwiftUI

/// Wrap `add_expert.py` — the "add N experts to an existing MoE" helper.
///
/// EXPERIMENTAL by design (sparse upcycling without follow-up training is
/// known to give nearly the original model — the new experts only earn their
/// keep after fine-tuning). The UI labels it accordingly. We keep this as a
/// separate service rather than overloading ModelModifyService because it
/// changes the architecture, not just the weights — chain composition with
/// strip / abliterate / quantize doesn't make sense.
@MainActor
@Observable
final class ExpertExpansionService {
    static let shared = ExpertExpansionService()

    enum Stage: Equatable {
        case idle
        case running(stage: String, message: String)
        case finished(outputPath: String, oldCount: Int, newCount: Int)
        case failed(reason: String)
    }

    struct ActiveJob: Identifiable {
        let id = UUID()
        let inputRepoID: String
        let outputName: String
        let numNewExperts: Int
        var stage: Stage = .idle
        var startedAt: Date = Date()
    }

    private(set) var active: ActiveJob?

    private init() {}

    /// Kick off an expansion. Quietly refuses if a previous run is still
    /// in-flight; clears stale terminal states.
    func run(input: ModelRegistry.DetectedModel,
             outputName: String,
             numNewExperts: Int,
             noiseStd: Double = 0.01) {
        guard !outputName.isEmpty, numNewExperts >= 1, input.isMoE else { return }
        if let stage = active?.stage {
            switch stage {
            case .finished, .failed: active = nil
            default: return
            }
        }
        guard PythonRuntime.shared.isReady, let python = PythonRuntime.shared.pythonURL else {
            var aborted = ActiveJob(inputRepoID: input.repoID, outputName: outputName,
                                    numNewExperts: numNewExperts)
            aborted.stage = .failed(reason: "Python runtime is not ready yet.")
            active = aborted
            return
        }

        let job = ActiveJob(inputRepoID: input.repoID, outputName: outputName,
                            numNewExperts: numNewExperts)
        active = job

        let srcPath = input.directory.path
        let outDir = PathResolver.modelsCustomDir
            .appendingPathComponent(outputName, isDirectory: true)

        Task { @MainActor in
            try? FileManager.default.removeItem(at: outDir)

            let helper = PathResolver.helpersDir.appendingPathComponent("add_expert.py")
            guard FileManager.default.fileExists(atPath: helper.path) else {
                active?.stage = .failed(reason: "add_expert.py missing — restart the app to refresh helpers.")
                return
            }

            active?.stage = .running(stage: "starting", message: "Preparing")
            do {
                _ = try await ProcessRunner.runCapturing(
                    executable: python,
                    arguments: [helper.path, srcPath, outDir.path,
                                "\(numNewExperts)", "\(noiseStd)"],
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
            active?.stage = .finished(outputPath: dst, oldCount: oldN, newCount: newN)
        case "error":
            active?.stage = .failed(reason: (json["message"] as? String) ?? "Expert expansion failed.")
        default:
            break
        }
    }
}
