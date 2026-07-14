import SwiftUI
import AppKit

/// Content of the menu-bar status panel shown while a training/practice run is
/// active. Reuses `TrainingNarrator` verbatim for the friendly phase/ETA/stars so
/// it never drifts from the Progress tab. Lets the user glance at progress, jump
/// to Progress, or stop the run without un-minimizing the app. Injected with the
/// shared `JobRegistry` (already an @Observable), so it updates live as steps
/// stream in.
struct JobStatusMenuBarContent: View {
    var jobRegistry: JobRegistry

    var body: some View {
        let running = jobRegistry.runningJobs.sorted {
            ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast)
        }
        VStack(alignment: .leading, spacing: 10) {
            if let job = running.first {
                activeJob(job, extra: running.count - 1)
            } else {
                Text("No active runs").font(.headline)
                Text("Start a lesson in Teach to watch live progress here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Button("Open LLMPro") { activate() }
        }
        .padding(14)
        .frame(width: 300)
    }

    @ViewBuilder
    private func activeJob(_ job: JobRegistry.LiveJob, extra: Int) -> some View {
        let phase = TrainingNarrator.phase(for: job)
        let stars = TrainingNarrator.stars(
            initial: TrainingNarrator.initialLoss(from: job),
            current: TrainingNarrator.currentLoss(from: job))
        VStack(alignment: .leading, spacing: 8) {
            Text("\(phase.emoji)  \(phase.headline)").font(.headline)
            Text(job.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if case .learning(let n, let m) = phase, m > 0 {
                ProgressView(value: Double(min(n, m)), total: Double(m)).tint(.brand)
            } else if case .popQuiz(let n, let m) = phase, m > 0 {
                ProgressView(value: Double(min(n, m)), total: Double(m)).tint(.brand)
            }
            HStack {
                Text(String(repeating: "★", count: stars) + String(repeating: "☆", count: 5 - stars))
                    .foregroundStyle(.yellow)
                Spacer()
                if let eta = TrainingNarrator.eta(for: job) {
                    Text("~\(eta) left").font(.caption).foregroundStyle(.secondary)
                }
            }
            if extra > 0 {
                Text("+\(extra) more running").font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Button("Open Progress") {
                    activate()
                    NotificationCenter.default.post(name: .switchToMonitor, object: nil)
                }
                Button("Stop", role: .destructive) {
                    JobRegistry.shared.stop(jobID: job.id)
                }
            }
        }
    }

    /// Bring the app forward AND re-open the main window if it was closed —
    /// `activate` alone does nothing visible when no window exists (the app stays
    /// alive after last-window-close so training survives), which made these
    /// buttons appear dead exactly when they're most useful.
    private func activate() {
        NSApp.activate(ignoringOtherApps: true)
        let visible = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
        if !visible {
            // Re-open the closed WindowGroup window (same path the Dock icon uses).
            if let main = NSApp.windows.first(where: { $0.canBecomeMain }) {
                main.makeKeyAndOrderFront(nil)
            }
        }
    }
}
