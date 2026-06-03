import SwiftUI
import SwiftData

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PythonRuntime.self) private var runtime
    @Environment(JobRegistry.self) private var jobRegistry
    @Query(sort: \TrainingJob.createdAt, order: .reverse) private var jobs: [TrainingJob]
    @Query(sort: \DatasetRecord.createdAt, order: .reverse) private var datasets: [DatasetRecord]
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
                    nextStepCard
                    quickStats
                    recentJobs
                    Spacer(minLength: 12)
                }
                .padding(24)
                .frame(maxWidth: 880, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("LLMPro")
            .task { metrics.start(); await registry.scan() }
            .alert("Rename lesson",
                   isPresented: Binding(
                    get: { renameTarget != nil },
                    set: { if !$0 { renameTarget = nil } }
                   )) {
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
            Text("Make your own coding helper").font(.largeTitle.bold())
            Text("Pick a model, give it some lessons, then chat with it. LLMPro handles the tricky parts.")
                .foregroundStyle(.secondary)
        }
    }

    private struct NextStep {
        let title: String
        let body: String
        let icon: String
        let actionLabel: String?
        let actionSection: SidebarSection?
    }

    private var nextStep: NextStep {
        if registry.localModels.isEmpty {
            return NextStep(
                title: "Step 1 — Get a model",
                body: "Models are like blank textbooks. Open the Models tab and download one. Llama 3.2 3B is a great first try.",
                icon: "1.circle.fill",
                actionLabel: "Open Models", actionSection: .models)
        }
        if datasets.isEmpty {
            return NextStep(
                title: "Step 2 — Get a lesson",
                body: "Open the Lessons tab and tap Prepare on \"CodeAlpaca 20K\". It's a starter pack of coding examples.",
                icon: "2.circle.fill",
                actionLabel: "Open Lessons", actionSection: .datasets)
        }
        if jobs.isEmpty {
            return NextStep(
                title: "Step 3 — Teach it",
                body: "You have everything you need. Open Teach to start a lesson — LLMPro will pick the best settings for you.",
                icon: "3.circle.fill",
                actionLabel: "Open Teach", actionSection: .training)
        }
        return NextStep(
            title: "You're all set.",
            body: "Tap Teach to run another lesson, or Try it out to chat with what you trained.",
            icon: "checkmark.seal.fill",
            actionLabel: nil, actionSection: nil)
    }

    private var nextStepCard: some View {
        let step = nextStep
        return HStack(alignment: .top, spacing: 16) {
            Image(systemName: step.icon).font(.largeTitle).foregroundStyle(.tint).frame(width: 44)
            VStack(alignment: .leading, spacing: 6) {
                Text(step.title).font(.title3.bold())
                Text(step.body).font(.callout).foregroundStyle(.secondary)
                if let label = step.actionLabel, let section = step.actionSection {
                    Button(label) {
                        NotificationCenter.default.post(name: .switchSidebar, object: section)
                    }
                    .controlSize(.large)
                    .padding(.top, 4)
                }
            }
            Spacer()
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

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
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.monospacedDigit().bold())
            Text(hint).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var recentJobs: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent lessons").font(.headline)
            if jobs.isEmpty {
                Text("No lessons yet. Open Teach to start one.").foregroundStyle(.secondary).font(.callout)
            } else {
                ForEach(jobs.prefix(8)) { job in
                    HStack(spacing: 12) {
                        Text(statusEmoji(for: job.status)).font(.title3)
                        VStack(alignment: .leading) {
                            Text(job.name).font(.headline)
                            Text(job.baseModelRepoID).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        statusPill(for: job.status)
                        if let loss = job.lastLoss {
                            Text(String(format: "loss %.2f", loss)).font(.caption.monospacedDigit())
                        }
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button("Rename…") {
                            renameText = job.name
                            renameTarget = job
                        }
                    }
                    Divider()
                }
            }
        }
    }

    private func statusEmoji(for status: JobStatus) -> String {
        switch status {
        case .running:   "📚"
        case .completed: "🎉"
        case .failed:    "⚠️"
        case .cancelled: "⏹"
        case .orphaned:  "🔄"
        case .queued:    "⌛"
        }
    }

    private func statusPill(for status: JobStatus) -> some View {
        let (label, color): (String, Color) = {
            switch status {
            case .running:   ("Learning",  .green)
            case .completed: ("Done",      .blue)
            case .failed:    ("Problem",   .red)
            case .cancelled: ("Stopped",   .secondary)
            case .orphaned:  ("Recovered", .orange)
            case .queued:    ("Waiting",   .gray)
            }
        }()
        return Text(label)
            .font(.caption.bold())
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

extension Notification.Name {
    static let switchSidebar = Notification.Name("LLMPro.switchSidebar")
}
