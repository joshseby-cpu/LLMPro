import Foundation
import SwiftUI

@MainActor
@Observable
final class DatasetPrepService {
    static let shared = DatasetPrepService()

    struct ActivePrep: Identifiable {
        let id = UUID()
        let preset: CodingDatasetPreset
        var stage: String = "queued"
        var message: String = ""
        var done: Bool = false
        var error: String?
        var resultDatasetID: UUID?
        var trainRows: Int = 0
        var validRows: Int = 0
        var testRows: Int = 0
    }

    private(set) var active: [ActivePrep] = []
    private(set) var history: [ActivePrep] = []

    private init() {}

    // MARK: - Arbitrary HuggingFace dataset

    struct ArbitraryHFRequest: Hashable {
        var repoID: String
        var displayName: String
        var maxRows: Int = 20_000
        var schema: String = "auto"   // auto | messages | instruction_output | prompt_completion | question_answer | text | sharegpt
        var fields: [String: String] = [:]
        var config: String? = nil     // dataset config name (None → default)
        var split: String = "train"
    }

    /// Prepare ANY HuggingFace dataset (not just a curated preset). The Python helper
    /// auto-detects the schema unless the caller supplies a schema + fields override.
    func prepareArbitrary(request: ArbitraryHFRequest,
                          onComplete: ((UUID) -> Void)? = nil) {
        guard PythonRuntime.shared.isReady, let python = PythonRuntime.shared.pythonURL else { return }
        let pseudoPreset = CodingDatasetPreset(
            id: "hf-arbitrary",
            displayName: request.displayName,
            hfRepo: request.repoID,
            approxRows: max(request.maxRows, 1_000),
            description: "Custom HuggingFace dataset",
            recommendedFor: "",
            licenseHint: ""
        )
        var entry = ActivePrep(preset: pseudoPreset)
        active.append(entry)
        let entryID = entry.id

        let helper = PathResolver.helpersDir.appendingPathComponent("download_hf_dataset.py")
        guard FileManager.default.fileExists(atPath: helper.path) else {
            update(entryID) { $0.error = "download_hf_dataset.py missing — restart the app to refresh helpers." }
            return
        }

        let datasetID = UUID()
        let outDir = PathResolver.datasetDir(for: datasetID)
        let token = KeychainHelper.readHFToken() ?? ""

        var optionsDict: [String: Any] = [
            "max_rows": request.maxRows,
            "schema": request.schema,
            "split": request.split,
            "fields": request.fields,
        ]
        if let config = request.config { optionsDict["config"] = config }
        let optionsJSON = (try? JSONSerialization.data(withJSONObject: optionsDict)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        Task {
            do {
                _ = try await ProcessRunner.runCapturing(
                    executable: python,
                    arguments: [helper.path, request.repoID, outDir.path, optionsJSON],
                    environment: [
                        "HF_HOME": PathResolver.hfHome.path,
                        "PYTHONUNBUFFERED": "1",
                        "HF_TOKEN": token,
                    ],
                    onStdout: { [weak self] line in
                        Task { @MainActor in self?.handle(line: line, id: entryID) }
                    },
                    onStderr: { _ in }
                )
            } catch {
                await MainActor.run {
                    self.update(entryID) { $0.error = error.localizedDescription }
                }
            }

            await MainActor.run {
                guard let idx = self.active.firstIndex(where: { $0.id == entryID }) else { return }
                var done = self.active.remove(at: idx)
                done.done = true
                if done.error == nil {
                    done.resultDatasetID = datasetID
                }
                self.history.append(done)
                if let cb = onComplete, done.error == nil {
                    cb(datasetID)
                }
            }
        }
    }

    func prepare(preset: CodingDatasetPreset,
                 maxRows: Int = 20_000,
                 onComplete: ((UUID) -> Void)? = nil) {
        guard PythonRuntime.shared.isReady, let python = PythonRuntime.shared.pythonURL else { return }
        var entry = ActivePrep(preset: preset)
        active.append(entry)
        let entryID = entry.id

        let helper = PathResolver.helpersDir.appendingPathComponent("prepare_coding_dataset.py")
        guard FileManager.default.fileExists(atPath: helper.path) else {
            update(entryID) { $0.error = "prepare_coding_dataset.py missing — runtime not fully bootstrapped." }
            return
        }

        let datasetID = UUID()
        let outDir = PathResolver.datasetDir(for: datasetID)
        let token = KeychainHelper.readHFToken() ?? ""

        Task {
            do {
                _ = try await ProcessRunner.runCapturing(
                    executable: python,
                    arguments: [helper.path, preset.id, outDir.path, token, "\(maxRows)"],
                    environment: ["HF_HOME": PathResolver.hfHome.path, "PYTHONUNBUFFERED": "1"],
                    onStdout: { [weak self] line in
                        Task { @MainActor in self?.handle(line: line, id: entryID) }
                    },
                    onStderr: { _ in }
                )
            } catch {
                await MainActor.run {
                    self.update(entryID) { $0.error = error.localizedDescription }
                }
            }

            await MainActor.run {
                guard let idx = self.active.firstIndex(where: { $0.id == entryID }) else { return }
                var done = self.active.remove(at: idx)
                done.done = true
                if done.error == nil {
                    done.resultDatasetID = datasetID
                }
                self.history.append(done)
                if let cb = onComplete, done.error == nil {
                    cb(datasetID)
                }
            }
        }
    }

    private func handle(line: String, id: UUID) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        update(id) { entry in
            switch json["event"] as? String {
            case "start":
                entry.stage = "downloading"
                entry.message = "Loading \(json["hf_repo"] ?? "...")"
            case "progress":
                entry.stage = (json["stage"] as? String) ?? entry.stage
                entry.message = (json["message"] as? String) ?? entry.message
            case "done":
                entry.stage = "done"
                entry.trainRows = (json["train"] as? Int) ?? 0
                entry.validRows = (json["valid"] as? Int) ?? 0
                entry.testRows  = (json["test"]  as? Int) ?? 0
            case "error":
                entry.error = (json["message"] as? String) ?? "Unknown error"
            default:
                break
            }
        }
    }

    private func update(_ id: UUID, _ mutate: (inout ActivePrep) -> Void) {
        guard let i = active.firstIndex(where: { $0.id == id }) else { return }
        var entry = active[i]
        mutate(&entry)
        active[i] = entry
    }
}
