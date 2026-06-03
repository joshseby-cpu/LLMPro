import Foundation
import SwiftUI

/// Turn a `LiveJob` into something a nine-year-old can understand.
enum TrainingNarrator {

    enum Phase: Equatable {
        case waiting
        case gettingReady       // before any log lines
        case openingBook        // saw "Loading pretrained model"
        case settingUp          // saw "Loading datasets"
        case learning(stepsDone: Int, stepsTotal: Int)
        case popQuiz(stepsDone: Int, stepsTotal: Int)
        case finished
        case failed(reason: String)

        var emoji: String {
            switch self {
            case .waiting:        "💤"
            case .gettingReady:   "🧰"
            case .openingBook:    "📖"
            case .settingUp:      "🧩"
            case .learning:       "📚"
            case .popQuiz:        "📝"
            case .finished:       "🎉"
            case .failed:         "⚠️"
            }
        }

        var headline: String {
            switch self {
            case .waiting:                 "Not started yet"
            case .gettingReady:            "Getting ready…"
            case .openingBook:             "Opening the textbook…"
            case .settingUp:               "Setting up the exercises…"
            case .learning(let n, let m):  "Learning \(n) of \(m) lessons"
            case .popQuiz(let n, let m):   "Pop quiz at lesson \(n) of \(m)"
            case .finished:                "All done!"
            case .failed(let r):           "Something went wrong: \(r)"
            }
        }

        var subtitle: String {
            switch self {
            case .waiting:        "Press Start Teaching when you're ready."
            case .gettingReady:   "Just a moment…"
            case .openingBook:    "Loading the model into memory (this can take a minute or two)."
            case .settingUp:      "Reading your dataset."
            case .learning:       "The model is studying. Watch the score below to see it improve."
            case .popQuiz:        "Checking how well it learned so far."
            case .finished:       "Your fine-tuned model is ready to chat with."
            case .failed:         "See the technical details below for help."
            }
        }
    }

    /// Decide the friendly phase from the latest job state.
    static func phase(for job: JobRegistry.LiveJob?) -> Phase {
        guard let job else { return .waiting }
        switch job.status {
        case .queued:     return .gettingReady
        case .completed:  return .finished
        case .failed:     return .failed(reason: job.logTail.last(where: { $0.contains("error") || $0.contains("Error") }) ?? "Unknown error")
        case .cancelled:  return .failed(reason: "Stopped before finishing")
        case .orphaned:   return .gettingReady
        case .running:    break
        }

        // Running: pick phase based on most recent log lines + steps.
        if let step = job.lastStep {
            let total = expectedTotal(from: job) ?? max(step.iter, 1)
            if step.isEval {
                return .popQuiz(stepsDone: step.iter, stepsTotal: total)
            }
            return .learning(stepsDone: step.iter, stepsTotal: total)
        }
        let recent = job.logTail.suffix(20).joined(separator: "\n").lowercased()
        if recent.contains("loading datasets") || recent.contains("starting training") {
            return .settingUp
        }
        if recent.contains("loading pretrained model") || recent.contains("loading model") {
            return .openingBook
        }
        return .gettingReady
    }

    /// Parse the `iters: NN` line in the captured log file (or look it up via the job's
    /// stored configYAML, if we had access). We rely on JobRegistry's logTail for now.
    private static func expectedTotal(from job: JobRegistry.LiveJob) -> Int? {
        for line in job.logTail.suffix(80) {
            if line.contains("Starting training") {
                // "Starting training..., iters: 50"
                if let range = line.range(of: #"iters:\s*(\d+)"#, options: .regularExpression),
                   let last = line[range].split(separator: ":").last,
                   let n = Int(last.trimmingCharacters(in: .whitespaces)) {
                    return n
                }
            }
        }
        return nil
    }

    /// Map loss improvement to a 1–5 star rating.
    /// `current` = most recent loss; `initial` = best estimate of starting loss
    /// (e.g. the first reported train or val loss).
    static func stars(initial: Double?, current: Double?) -> Int {
        guard let initial, let current, initial > 0, current > 0 else { return 0 }
        let drop = (initial - current) / initial
        switch drop {
        case ..<0.05:  return 1
        case 0.05..<0.15: return 2
        case 0.15..<0.30: return 3
        case 0.30..<0.50: return 4
        default:        return 5
        }
    }

    /// One-word verdict.
    static func verdict(for stars: Int) -> String {
        switch stars {
        case 5: "Excellent!"
        case 4: "Getting good!"
        case 3: "Improving"
        case 2: "A little better"
        case 1: "Just starting"
        default: "Warming up"
        }
    }

    /// Find the very-first non-zero loss we saw (initial baseline for the star rating).
    static func initialLoss(from job: JobRegistry.LiveJob) -> Double? {
        for step in job.steps {
            if let v = step.valLoss { return v }
            if let t = step.trainLoss { return t }
        }
        return nil
    }

    /// Current loss = most recent loss we've seen.
    static func currentLoss(from job: JobRegistry.LiveJob) -> Double? {
        if let last = job.steps.last(where: { $0.valLoss != nil }) {
            return last.valLoss
        }
        if let last = job.steps.last(where: { $0.trainLoss != nil }) {
            return last.trainLoss
        }
        return nil
    }

    /// Rough time-remaining estimate from the rolling iter/sec.
    static func eta(for job: JobRegistry.LiveJob) -> String? {
        guard let total = expectedTotal(from: job) ?? job.lastStep.map({ max($0.iter, 1) }),
              let last = job.lastStep,
              let itPerSec = last.itersPerSec, itPerSec > 0
        else { return nil }
        let remaining = max(0, total - last.iter)
        let seconds = Double(remaining) / itPerSec
        return formatDuration(seconds: seconds)
    }

    static func formatDuration(seconds: Double) -> String {
        if seconds < 60 { return "less than a minute left" }
        if seconds < 3600 {
            let m = Int((seconds / 60).rounded())
            return "about \(m) minute\(m == 1 ? "" : "s") left"
        }
        let h = Int(seconds / 3600)
        let m = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
        return m == 0 ? "about \(h) hour\(h == 1 ? "" : "s") left" : "about \(h)h \(m)m left"
    }
}
