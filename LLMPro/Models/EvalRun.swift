import Foundation
import SwiftData

// A "scored evaluation" run = measure how often a model (+ optional adapter)
// passes a held-out coding-eval suite, expressed as pass@k (pass@1 by default).
// The interesting state is per-task: which problems passed, and why the failures
// failed. We store that per-task history as a JSON blob inside the @Model (the
// same pattern as TrainingJob.metricsBlob / SelfImproveRun.roundsBlob) so the
// SwiftData schema stays flat.
//
// An EvalRun is produced by EvalService driving eval_pass_rate.py against a
// suite's eval.jsonl. The suite is one of two built-ins (HumanEval, MBPP
// sanitized) lazily pulled via humaneval_pull.py, or a `.custom` folder under
// evals/. The score is carried back to the UI to drive a before/after delta when
// the same base model is re-evaluated with a new adapter.

enum EvalStatus: String, Codable, CaseIterable {
    case queued
    case running
    case completed
    case failed
    case cancelled
}

/// A coding-eval suite that ships unit tests with each problem. The two built-ins
/// map to `humaneval_pull.py` preset ids; `.custom` is a folder the user dropped
/// under `evals/custom-<id>/` (no authoring UI this version).
enum EvalSuite: String, Codable, CaseIterable, Identifiable {
    case humaneval = "humaneval"
    case mbppSanitized = "mbpp-sanitized"
    case custom = "custom"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .humaneval:     "HumanEval (164 problems)"
        case .mbppSanitized: "MBPP sanitized (~974 problems)"
        case .custom:        "Custom suite"
        }
    }

    var oneLine: String {
        switch self {
        case .humaneval:     "Short, classic coding problems with built-in tests."
        case .mbppSanitized: "Beginner-to-intermediate Python tasks. More variety, slower to grade."
        case .custom:        "Your own problems, dropped into the evals folder."
        }
    }

    /// The `humaneval_pull.py` preset id used to lazily download this suite, or nil
    /// for `.custom` (which is never pulled — it's assumed already on disk). The two
    /// built-in raw values ARE the preset ids the helper accepts.
    var pullPreset: String? {
        switch self {
        case .humaneval:     "humaneval"
        case .mbppSanitized: "mbpp-sanitized"
        case .custom:        nil
        }
    }
}

/// One graded problem within an eval run.
struct EvalTaskResult: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var taskID: String          // e.g. "HumanEval/0" or "mbpp/3"
    var passed: Bool
    var reason: String          // failure reason, "" when passed
}

@Model
final class EvalRun {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var baseModelRepoID: String
    /// "" = base model (no adapter); else matches `TrainingJob.adapterRelativePath`.
    var adapterRelativePath: String = ""
    var suiteRaw: String                    // EvalSuite.rawValue
    /// Folder id under evals/ when suite == .custom (the part after "custom-").
    var customSuiteID: String = ""
    var k: Int = 1                          // pass@k
    var problemCount: Int                   // problems actually graded
    var passAtK: Double
    var passedCount: Int
    var totalCount: Int
    var elapsedMs: Int = 0
    var statusRaw: String                   // EvalStatus.rawValue
    /// Friendly origin, e.g. "Test" / "Teach job: …" / "Practice R2".
    var sourceLabel: String = ""
    var sourceJobID: UUID?
    var perTaskBlob: Data = Data()          // [EvalTaskResult] JSON
    var lastError: String?

    init(id: UUID = UUID(),
         baseModelRepoID: String,
         adapterRelativePath: String = "",
         suite: EvalSuite,
         customSuiteID: String = "",
         k: Int = 1,
         problemCount: Int = 0,
         passAtK: Double = 0,
         passedCount: Int = 0,
         totalCount: Int = 0,
         status: EvalStatus = .queued,
         sourceLabel: String = "",
         sourceJobID: UUID? = nil) {
        self.id = id
        self.createdAt = Date()
        self.baseModelRepoID = baseModelRepoID
        self.adapterRelativePath = adapterRelativePath
        self.suiteRaw = suite.rawValue
        self.customSuiteID = customSuiteID
        self.k = k
        self.problemCount = problemCount
        self.passAtK = passAtK
        self.passedCount = passedCount
        self.totalCount = totalCount
        self.statusRaw = status.rawValue
        self.sourceLabel = sourceLabel
        self.sourceJobID = sourceJobID
        self.perTaskBlob = Data()
    }

    // MARK: – Enum bridges over raw values

    var suite: EvalSuite {
        get { EvalSuite(rawValue: suiteRaw) ?? .humaneval }
        set { suiteRaw = newValue.rawValue }
    }

    var status: EvalStatus {
        get { EvalStatus(rawValue: statusRaw) ?? .queued }
        set { statusRaw = newValue.rawValue }
    }

    // MARK: – Derived paths / values

    /// nil when this run measured the base model with no adapter; otherwise the
    /// adapter directory resolved the same way TrainingJob / SelfImproveRun do
    /// (relative path joined under the shared adapters dir).
    var adapterURL: URL? {
        guard !adapterRelativePath.isEmpty else { return nil }
        return PathResolver.adaptersDir.appendingPathComponent(adapterRelativePath, isDirectory: true)
    }

    /// pass@k rounded to a whole percent, for friendly display.
    var passPercent: Int { Int((passAtK * 100).rounded()) }

    /// The suite's folder id under evals/ (`<suiteID>`), matching EvalService's
    /// layout: a built-in uses its preset id; a custom suite uses "custom-<id>".
    var suiteFolderID: String {
        switch suite {
        case .custom: "custom-\(customSuiteID)"
        default:      suite.rawValue
        }
    }

    var directory: URL { PathResolver.evalSuiteDir(for: id.uuidString) }
    var sidecarURL: URL { directory.appendingPathComponent("eval_run.json") }

    // MARK: – Per-task blob

    func decodedTasks() -> [EvalTaskResult] {
        (try? JSONDecoder().decode([EvalTaskResult].self, from: perTaskBlob)) ?? []
    }

    func setTasks(_ tasks: [EvalTaskResult]) {
        if let data = try? JSONEncoder().encode(tasks) {
            perTaskBlob = data
        }
    }

    func appendTask(_ task: EvalTaskResult) {
        var tasks = decodedTasks()
        tasks.append(task)
        setTasks(tasks)
    }

    // MARK: – Sidecar (crash recovery / inspection)

    func writeSidecar() {
        let payload: [String: Any] = [
            "id":            id.uuidString,
            "createdAt":     createdAt.timeIntervalSince1970,
            "baseModel":     baseModelRepoID,
            "adapterPath":   adapterRelativePath,
            "suite":         suiteRaw,
            "customSuiteID": customSuiteID,
            "k":             k,
            "problemCount":  problemCount,
            "passAtK":       passAtK,
            "passedCount":   passedCount,
            "totalCount":    totalCount,
            "elapsedMs":     elapsedMs,
            "status":        statusRaw,
            "sourceLabel":   sourceLabel,
            "sourceJobID":   sourceJobID?.uuidString as Any,
            "lastError":     lastError as Any
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: sidecarURL)
        }
    }
}
