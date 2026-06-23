import AppKit
import UniformTypeIdentifiers

/// Render a finished training run to a shareable Markdown report — what was
/// trained, the hyperparameters AutoTuner chose, the loss trajectory, and how
/// well it learned (stars). Useful for keeping a record, filing an issue, or
/// comparing experiments outside the app. `@MainActor` because `TrainingJob` is
/// main-actor-isolated.
@MainActor
enum TrainingRunReport {

    static func markdown(for job: TrainingJob) -> String {
        let steps = job.decodedMetrics()
        let trainPts = steps.filter { $0.trainLoss != nil }
        let initial = trainPts.first?.trainLoss
        let current = trainPts.last?.trainLoss ?? job.lastLoss
        let stars = TrainingNarrator.stars(initial: initial, current: current)

        var out = "# Training run — \(job.name)\n\n"
        out += "| | |\n|---|---|\n"
        out += "| Base model | `\(job.baseModelRepoID)` |\n"
        out += "| Mode | \(job.trainMode.displayName) |\n"
        out += "| Status | \(job.status.rawValue) |\n"
        out += "| Created | \(format(job.createdAt)) |\n"
        if let s = job.startedAt, let e = job.endedAt {
            out += "| Duration | \(duration(from: s, to: e)) |\n"
        }
        out += "| Iterations | \(job.lastIter) |\n"
        if let initial { out += "| Initial loss | \(fmt(initial)) |\n" }
        if let current { out += "| Final loss | \(fmt(current)) |\n" }
        if let v = job.lastEvalLoss { out += "| Final val loss | \(fmt(v)) |\n" }
        if let initial, let current, initial > 0 {
            let pct = (1 - current / initial) * 100
            out += "| Improvement | \(String(format: "%.0f%%", pct)) |\n"
        }
        out += "| Learned | \(String(repeating: "★", count: stars))\(String(repeating: "☆", count: 5 - stars)) |\n\n"

        out += "## Hyperparameters\n\n```yaml\n\(job.configYAML.trimmingCharacters(in: .whitespacesAndNewlines))\n```\n\n"

        if !trainPts.isEmpty {
            out += "## Loss curve\n\n| iter | train | val |\n|---:|---:|---:|\n"
            for s in downsample(steps.filter { !$0.isEval }, max: 24) {
                let t = s.trainLoss.map(fmt) ?? ""
                let v = s.valLoss.map(fmt) ?? ""
                out += "| \(s.iter) | \(t) | \(v) |\n"
            }
        }
        return out
    }

    @MainActor
    static func exportWithPanel(for job: TrainingJob) {
        let md = markdown(for: job)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = sanitized(job.name) + "-report.md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? md.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Helpers

    private static func fmt(_ d: Double) -> String { String(format: "%.4f", d) }
    private static func format(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
    private static func duration(from: Date, to: Date) -> String {
        let secs = Int(to.timeIntervalSince(from))
        let m = secs / 60, s = secs % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }
    private static func downsample(_ steps: [TrainingStep], max: Int) -> [TrainingStep] {
        guard steps.count > max else { return steps }
        let stride = steps.count / max
        return steps.enumerated().compactMap { $0.offset % stride == 0 ? $0.element : nil }
    }
    private static func sanitized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }
}
