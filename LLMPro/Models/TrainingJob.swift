import Foundation
import SwiftData

enum JobStatus: String, Codable, CaseIterable {
    case queued, running, completed, failed, cancelled, orphaned
}

enum FineTuneType: String, Codable, CaseIterable, Identifiable {
    case lora, dora, full
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .lora: "LoRA"
        case .dora: "DoRA"
        case .full: "Full fine-tune"
        }
    }
}

@Model
final class TrainingJob {
    @Attribute(.unique) var id: UUID
    var name: String
    var statusRaw: String
    var configYAML: String
    var baseModelRepoID: String
    var datasetID: UUID
    var adapterRelativePath: String
    var pid: Int32?
    var startedAt: Date?
    var endedAt: Date?
    var lastIter: Int
    var lastLoss: Double?
    var lastEvalLoss: Double?
    var metricsBlob: Data
    var createdAt: Date
    /// When true, on successful completion the trained adapter is automatically
    /// fused into the base model and saved as a NEW ready-to-use model under
    /// `models/<name>-trained` (the user's "training should modify the model"
    /// choice). The original model is always kept — this is a copy, never an
    /// overwrite. Default false = the normal flow (adapter stays separate; use
    /// Save & Use to fuse on demand). Applied by `ModelApplyService` from the
    /// training-completion hook. A non-optional with a default is a lightweight
    /// SwiftData migration — old jobs read as false.
    /// (Stored name kept for migration stability; semantics are "auto-fuse to a
    /// new model," not in-place.)
    var applyToModelInPlace: Bool = false
    /// Set by `ModelApplyService` after the auto-fuse finishes (or fails), so the
    /// UI can show the outcome. nil = not attempted.
    var applyOutcome: String?

    init(
        id: UUID = UUID(),
        name: String,
        configYAML: String,
        baseModelRepoID: String,
        datasetID: UUID,
        adapterRelativePath: String,
        applyToModelInPlace: Bool = false
    ) {
        self.id = id
        self.name = name
        self.statusRaw = JobStatus.queued.rawValue
        self.configYAML = configYAML
        self.baseModelRepoID = baseModelRepoID
        self.datasetID = datasetID
        self.adapterRelativePath = adapterRelativePath
        self.applyToModelInPlace = applyToModelInPlace
        self.lastIter = 0
        self.metricsBlob = Data()
        self.createdAt = Date()
    }

    var status: JobStatus {
        get { JobStatus(rawValue: statusRaw) ?? .queued }
        set { statusRaw = newValue.rawValue }
    }

    var adapterURL: URL { PathResolver.adaptersDir.appendingPathComponent(adapterRelativePath, isDirectory: true) }
    var configURL: URL { adapterURL.appendingPathComponent("config.yaml") }
    var logURL: URL { adapterURL.appendingPathComponent("training.log") }
    var sidecarURL: URL { adapterURL.appendingPathComponent("job.json") }

    func appendStep(_ step: TrainingStep) {
        var arr = decodedMetrics()
        arr.append(step)
        if let data = try? JSONEncoder().encode(arr) { metricsBlob = data }
        lastIter = step.iter
        if step.isEval { lastEvalLoss = step.valLoss } else { lastLoss = step.trainLoss }
    }

    func decodedMetrics() -> [TrainingStep] {
        (try? JSONDecoder().decode([TrainingStep].self, from: metricsBlob)) ?? []
    }

    func writeSidecar() {
        let payload: [String: Any] = [
            "id": id.uuidString,
            "name": name,
            "status": statusRaw,
            "baseModel": baseModelRepoID,
            "datasetID": datasetID.uuidString,
            "adapterPath": adapterURL.path,
            "pid": pid as Any,
            "startedAt": startedAt?.timeIntervalSince1970 as Any,
            "endedAt": endedAt?.timeIntervalSince1970 as Any,
            "lastIter": lastIter
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: sidecarURL)
        }
    }
}
