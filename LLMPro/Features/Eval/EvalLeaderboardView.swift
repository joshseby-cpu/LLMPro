import SwiftUI
import SwiftData
import Charts

/// "Report cards" — the history of every scored eval, grouped so you can see
/// whether your fine-tunes are actually getting better: best score per artifact,
/// a trend chart over time, and the full run list. This is the retrain
/// back-edge's memory — pick what to train next based on numbers, not vibes.
struct EvalLeaderboardView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \EvalRun.createdAt, order: .reverse) private var runs: [EvalRun]

    private var completed: [EvalRun] { runs.filter { $0.status == .completed } }

    /// Best run per (base model + adapter) — the leaderboard rows.
    private var leaders: [EvalRun] {
        var best: [String: EvalRun] = [:]
        for run in completed {
            let key = run.baseModelRepoID + "|" + run.adapterRelativePath
            if let cur = best[key] {
                if run.passPercent > cur.passPercent { best[key] = run }
            } else {
                best[key] = run
            }
        }
        return best.values.sorted { $0.passPercent > $1.passPercent }
    }

    var body: some View {
        NavigationStack {
            Group {
                if completed.isEmpty {
                    ContentUnavailableView(
                        "No report cards yet",
                        systemImage: "checklist",
                        description: Text("Score a model in Try it out — results build up here so you can see what's improving."))
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if completed.count >= 2 { trendChart }
                            leaderboard
                            allRuns
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle("Report cards")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .frame(minWidth: 560, minHeight: 500)
        }
    }

    private var trendChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Scores over time", systemImage: "chart.line.uptrend.xyaxis")
            Chart(completed.suffix(30)) { run in
                PointMark(x: .value("Date", run.createdAt),
                          y: .value("Score", run.passPercent))
                    .foregroundStyle(by: .value("Suite", run.suite.displayName))
                LineMark(x: .value("Date", run.createdAt),
                         y: .value("Score", run.passPercent))
                    .foregroundStyle(by: .value("Suite", run.suite.displayName))
                    .opacity(0.4)
            }
            .chartYScale(domain: 0...100)
            .chartYAxisLabel("pass %")
            .frame(height: 180)
        }
        .card()
    }

    private var leaderboard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Best per model", systemImage: "trophy")
            ForEach(Array(leaders.prefix(10).enumerated()), id: \.element.id) { rank, run in
                HStack(spacing: 12) {
                    Text(medal(rank)).font(.title3).frame(width: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(artifactName(run)).font(.callout.weight(.medium)).lineLimit(1)
                        Text("\(run.suite.displayName) · k=\(run.k)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(run.passPercent)%")
                        .font(.title3.monospacedDigit().weight(.bold))
                        .foregroundStyle(rank == 0 ? Color.brand : .primary)
                }
                .padding(.vertical, 2)
                Divider()
            }
        }
        .card()
    }

    private var allRuns: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("All runs (\(completed.count))", systemImage: "clock.arrow.circlepath")
            ForEach(completed.prefix(30)) { run in
                HStack(spacing: 10) {
                    Text("\(run.passPercent)%").font(.caption.monospacedDigit().weight(.semibold))
                        .frame(width: 42, alignment: .trailing)
                    Text(artifactName(run)).font(.caption).lineLimit(1)
                    Spacer()
                    Text(run.suite.displayName).font(.caption2).foregroundStyle(.secondary)
                    Text(run.createdAt, format: .dateTime.month().day())
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 1)
            }
        }
        .card()
    }

    private func artifactName(_ run: EvalRun) -> String {
        let base = run.baseModelRepoID.split(separator: "/").last.map(String.init) ?? run.baseModelRepoID
        return run.adapterRelativePath.isEmpty ? base : base + " + fine-tune"
    }

    private func medal(_ rank: Int) -> String {
        switch rank {
        case 0: "🥇"
        case 1: "🥈"
        case 2: "🥉"
        default: "\(rank + 1)."
        }
    }
}
