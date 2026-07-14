import SwiftUI
import SwiftData

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PythonRuntime.self) private var runtime
    @Environment(JobRegistry.self) private var jobRegistry
    @Query(sort: \TrainingJob.createdAt, order: .reverse) private var jobs: [TrainingJob]
    @Query(sort: \DatasetRecord.createdAt, order: .reverse) private var datasets: [DatasetRecord]
    @Query(sort: \EvalRun.createdAt, order: .reverse) private var evals: [EvalRun]
    @Query(sort: \SelfImproveRun.createdAt, order: .reverse) private var practiceRuns: [SelfImproveRun]
    @State private var registry = ModelRegistry.shared
    @State private var metrics = SystemMetrics.shared

    // Rename sheet state. Held at the view's top level so the alert always finds it.
    @State private var renameTarget: TrainingJob?
    @State private var renameText: String = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    hero
                    GettingStartedChecklist(
                        hasModel: !registry.localModels.isEmpty,
                        hasDataset: !datasets.isEmpty,
                        hasFinishedJob: jobs.contains { $0.status == .completed })
                    DashboardQuickActions(
                        hasModel: !registry.localModels.isEmpty,
                        hasDataset: !datasets.isEmpty)
                    quickStats
                    RecentActivityFeed(
                        jobs: Array(jobs), datasets: Array(datasets),
                        evals: Array(evals), practiceRuns: Array(practiceRuns),
                        onRenameJob: { job in
                            renameText = job.name
                            renameTarget = job
                        })
                    Spacer(minLength: 12)
                }
                .padding(24)
                .frame(maxWidth: 880, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("LLMPro")
            .task { metrics.start(); await registry.scan() }
            .alert("Rename lesson", isPresented: renameAlertBinding) {
                TextField("New name", text: $renameText)
                Button("Save") { commitRename() }
                Button("Cancel", role: .cancel) { renameTarget = nil }
            } message: {
                if let t = renameTarget {
                    Text("Currently: \(t.name)")
                }
            }
        }
    }

    /// Present the rename alert while a job is targeted; clear on dismiss.
    /// Lifted out of the inline `.alert(isPresented:)` so the preview-dylib
    /// compiler (which instruments every string literal) doesn't have to infer a
    /// fresh `Binding(get:set:)` closure inside `body`.
    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )
    }

    private func commitRename() {
        guard let target = renameTarget else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            target.name = trimmed
            try? modelContext.save()
            target.writeSidecar()
        }
        renameTarget = nil
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Make your own coding helper")
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
            Text("Pick a model, give it some lessons, then chat with it. LLMPro handles the tricky parts.")
                .foregroundStyle(.secondary)
        }
    }

    // The single next-step card + NextStep struct were superseded by
    // GettingStartedChecklist (whole-journey view with live done states).

    private var quickStats: some View {
        Grid(horizontalSpacing: 16, verticalSpacing: 16) {
            GridRow {
                statCard(title: "Models on this Mac",
                         value: "\(registry.localModels.count)",
                         hint: registry.localModels.count == 0 ? "Download one to get started" : "Ready to teach",
                         icon: "cube.box")
                statCard(title: "Lessons ready",
                         value: "\(datasets.count)",
                         hint: datasets.count == 0 ? "Open Lessons to add one" : "Pick one in Teach",
                         icon: "books.vertical")
                statCard(title: "Lessons completed",
                         value: "\(jobs.filter { $0.status == .completed }.count)",
                         hint: "Total fine-tunes that finished",
                         icon: "checkmark.seal")
                statCard(title: "Memory free",
                         value: String(format: "%.0f GB", max(0, metrics.current.totalGB - metrics.current.usedGB)),
                         hint: "of \(Int(metrics.current.totalGB)) GB total",
                         icon: "memorychip")
            }
        }
    }

    private func statCard(title: String, value: String, hint: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.brand)
            Text(value)
                .font(.system(.title, design: .rounded).weight(.bold))
                .monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(hint).font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14, cornerRadius: 12)
    }

    // recentJobs / statusEmoji / statusPill were superseded by RecentActivityFeed
    // (a unified stream across jobs, lessons, report cards, and Practice runs).
}

extension Notification.Name {
    static let switchSidebar = Notification.Name("LLMPro.switchSidebar")
}

#if DEBUG
#Preview("Home") {
    DashboardView().previewEnvironment()
}
#endif
