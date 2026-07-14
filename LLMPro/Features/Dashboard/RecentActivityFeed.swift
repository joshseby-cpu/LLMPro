import SwiftUI

/// The Home "what happened recently" feed — a single time-sorted stream across
/// every loop artifact: fine-tunes (TrainingJob), lessons added (DatasetRecord),
/// report cards (EvalRun), and Practice runs (SelfImproveRun). Each row is a
/// friendly one-liner with a relative timestamp; tapping jumps to the tab where
/// that thing lives. Pure value-type merge over data the Dashboard already
/// queries — no new storage.
struct RecentActivityFeed: View {
    let jobs: [TrainingJob]
    let datasets: [DatasetRecord]
    let evals: [EvalRun]
    let practiceRuns: [SelfImproveRun]
    /// Rename hook so training rows keep the Dashboard's existing rename flow.
    var onRenameJob: ((TrainingJob) -> Void)? = nil

    private struct ActivityItem: Identifiable {
        let id: String
        let date: Date
        let emoji: String
        let line: String
        let detail: String
        let target: SidebarSection
        let job: TrainingJob?
    }

    private var items: [ActivityItem] {
        var out: [ActivityItem] = []
        for j in jobs.prefix(20) {
            let (emoji, verb): (String, String) = {
                switch j.status {
                case .completed: ("🎓", "Taught")
                case .running:   ("📚", "Teaching")
                case .failed:    ("⚠️", "Lesson failed —")
                case .cancelled: ("⏹", "Stopped teaching")
                case .orphaned:  ("🔄", "Interrupted —")
                case .queued:    ("⌛", "Queued")
                }
            }()
            out.append(ActivityItem(
                id: "job-\(j.id)", date: j.endedAt ?? j.startedAt ?? j.createdAt,
                emoji: emoji, line: "\(verb) \(j.name)",
                detail: j.baseModelRepoID, target: .monitor, job: j))
        }
        for d in datasets.prefix(10) {
            out.append(ActivityItem(
                id: "ds-\(d.id)", date: d.createdAt,
                emoji: "📖", line: "Added lesson \(d.name)",
                detail: "\(d.trainRows) rows", target: .datasets, job: nil))
        }
        for e in evals.prefix(10) where e.status == .completed {
            out.append(ActivityItem(
                id: "eval-\(e.id)", date: e.createdAt,
                emoji: "📊", line: "Scored \(e.passPercent)% on \(e.suite.displayName)",
                detail: e.baseModelRepoID, target: .chat, job: nil))
        }
        for r in practiceRuns.prefix(10) {
            out.append(ActivityItem(
                id: "pr-\(r.id)", date: r.createdAt,
                emoji: "🔄", line: "Practice — \(r.name.isEmpty ? r.baseModelRepoID : r.name)",
                detail: statusLine(r.status), target: .selfImprove, job: nil))
        }
        return out.sorted { $0.date > $1.date }.prefix(10).map { $0 }
    }

    var body: some View {
        let feed = items
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Recent activity", systemImage: "clock.arrow.circlepath")
            if feed.isEmpty {
                Text("Nothing yet — your journey shows up here as you go.")
                    .foregroundStyle(.secondary).font(.callout)
            } else {
                ForEach(feed) { item in
                    Button {
                        NotificationCenter.default.post(name: .switchSidebar, object: item.target)
                    } label: {
                        HStack(spacing: 12) {
                            Text(item.emoji).font(.title3)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.line).font(.callout).foregroundStyle(.primary).lineLimit(1)
                                Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(item.date, format: .relative(presentation: .named))
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if let job = item.job, let onRenameJob {
                            Button("Rename…") { onRenameJob(job) }
                        }
                    }
                    Divider()
                }
            }
        }
    }

    private func statusLine(_ s: SelfImproveStatus) -> String {
        switch s {
        case .completed: "finished"
        case .failed:    "didn't finish"
        case .cancelled: "stopped"
        case .queued:    "queued"
        default:         "in progress"
        }
    }
}
