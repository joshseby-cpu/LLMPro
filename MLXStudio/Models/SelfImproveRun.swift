import Foundation
import SwiftData

// A "self-improvement" run = N rounds, each of which does
//   generate K candidates per prompt → run unit tests → retrain on passers.
// The interesting state is per-round: pass-rate trend, adapter path, dataset path.
// We store the round history as a JSON blob inside the @Model (same pattern as
// TrainingJob.metricsBlob) — keeps the SwiftData schema flat.

enum SelfImproveStatus: String, Codable, CaseIterable {
    case queued
    case generating     // round in flight: producing candidate completions
    case testing        // round in flight: running unit tests
    case training       // round in flight: mlx-lm lora on the new dataset
    case evaluating     // round in flight: pass@1 on held-out set
    case completed
    case failed
    case cancelled
}

/// A coding-eval preset that ships unit tests with each prompt.
enum SelfImproveSeed: String, Codable, CaseIterable, Identifiable {
    case humaneval
    case mbppSanitized = "mbpp-sanitized"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .humaneval:      "HumanEval (164 problems)"
        case .mbppSanitized:  "MBPP sanitized (~974 problems)"
        }
    }

    var oneLine: String {
        switch self {
        case .humaneval:      "Short, classic coding problems with built-in tests."
        case .mbppSanitized:  "Beginner-to-intermediate Python tasks. More variety, slower per round."
        }
    }
}

struct SelfImproveRoundRecord: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var roundNumber: Int                    // 1-based
    var startedAt: Date
    var endedAt: Date?
    var candidatesPerPrompt: Int
    var rowsAttempted: Int                  // # prompts in this round
    var rowsKept: Int                       // # prompts where ≥1 candidate passed
    var totalCandidates: Int                // rowsAttempted * candidatesPerPrompt
    var totalPasses: Int
    var datasetRelativePath: String         // selfimprove/<run>/round_N/dataset
    var adapterRelativePath: String         // adapters/<round-job-id>
    var roundJobID: UUID                    // matching TrainingJob.id for this round
    var evalPassAtOne: Double?              // measured against held-out eval set
    var notes: String = ""

    var keepRate: Double {
        rowsAttempted > 0 ? Double(rowsKept) / Double(rowsAttempted) : 0
    }
    var passRate: Double {
        totalCandidates > 0 ? Double(totalPasses) / Double(totalCandidates) : 0
    }
}

@Model
final class SelfImproveRun {
    @Attribute(.unique) var id: UUID
    var name: String
    var baseModelRepoID: String
    var seedRaw: String                       // SelfImproveSeed.rawValue
    var statusRaw: String
    var targetRounds: Int
    var candidatesPerPrompt: Int
    var rowsPerRound: Int                     // 0 = all
    var trainIters: Int                       // per round
    var startedAt: Date?
    var endedAt: Date?
    var roundsBlob: Data                      // [SelfImproveRoundRecord] JSON
    var baselinePassAtOne: Double?            // pass@1 with base model, no adapter
    var lastError: String?
    var createdAt: Date

    init(id: UUID = UUID(),
         name: String,
         baseModelRepoID: String,
         seed: SelfImproveSeed,
         targetRounds: Int = 3,
         candidatesPerPrompt: Int = 4,
         rowsPerRound: Int = 30,
         trainIters: Int = 80) {
        self.id = id
        self.name = name
        self.baseModelRepoID = baseModelRepoID
        self.seedRaw = seed.rawValue
        self.statusRaw = SelfImproveStatus.queued.rawValue
        self.targetRounds = targetRounds
        self.candidatesPerPrompt = candidatesPerPrompt
        self.rowsPerRound = rowsPerRound
        self.trainIters = trainIters
        self.roundsBlob = Data()
        self.createdAt = Date()
    }

    var status: SelfImproveStatus {
        get { SelfImproveStatus(rawValue: statusRaw) ?? .queued }
        set { statusRaw = newValue.rawValue }
    }

    var seed: SelfImproveSeed {
        get { SelfImproveSeed(rawValue: seedRaw) ?? .humaneval }
        set { seedRaw = newValue.rawValue }
    }

    var directory: URL { PathResolver.selfImproveRunDir(for: id) }
    var seedFile: URL  { directory.appendingPathComponent("seed.jsonl") }
    var evalFile: URL  { directory.appendingPathComponent("eval.jsonl") }
    var sidecarURL: URL { directory.appendingPathComponent("run.json") }

    func roundDir(_ n: Int) -> URL {
        directory.appendingPathComponent("round_\(n)", isDirectory: true)
    }

    func decodedRounds() -> [SelfImproveRoundRecord] {
        (try? JSONDecoder().decode([SelfImproveRoundRecord].self, from: roundsBlob)) ?? []
    }

    func setRounds(_ rounds: [SelfImproveRoundRecord]) {
        if let data = try? JSONEncoder().encode(rounds) {
            roundsBlob = data
        }
    }

    func appendRound(_ round: SelfImproveRoundRecord) {
        var rounds = decodedRounds()
        rounds.append(round)
        setRounds(rounds)
    }

    func updateRound(_ updated: SelfImproveRoundRecord) {
        var rounds = decodedRounds()
        if let idx = rounds.firstIndex(where: { $0.id == updated.id }) {
            rounds[idx] = updated
            setRounds(rounds)
        }
    }

    /// Latest adapter path (used for "Try it out" / continuing training).
    /// Returns nil if no round has finished training yet.
    var latestAdapterDirectory: URL? {
        guard let last = decodedRounds().last else { return nil }
        return PathResolver.adaptersDir.appendingPathComponent(last.adapterRelativePath, isDirectory: true)
    }

    /// Pass-rate trend (baseline → round 1 → round 2 …) for the chart.
    var passAtOneTrend: [Double] {
        var trend: [Double] = []
        if let b = baselinePassAtOne { trend.append(b) }
        for r in decodedRounds() {
            if let p = r.evalPassAtOne { trend.append(p) }
        }
        return trend
    }

    func writeSidecar() {
        let payload: [String: Any] = [
            "id":                  id.uuidString,
            "name":                name,
            "baseModel":           baseModelRepoID,
            "seed":                seedRaw,
            "status":              statusRaw,
            "targetRounds":        targetRounds,
            "candidatesPerPrompt": candidatesPerPrompt,
            "rowsPerRound":        rowsPerRound,
            "trainIters":          trainIters,
            "startedAt":           startedAt?.timeIntervalSince1970 as Any,
            "endedAt":             endedAt?.timeIntervalSince1970 as Any,
            "baseline":            baselinePassAtOne as Any,
            "rounds":              decodedRounds().count
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: sidecarURL)
        }
    }
}
