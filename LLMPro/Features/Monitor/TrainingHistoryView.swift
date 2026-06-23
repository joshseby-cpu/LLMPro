import SwiftUI
import SwiftData

/// "Past lessons" — lists every training run (the persistent `TrainingJob`
/// records) and lets the user delete ones they no longer need. Deleting a run
/// removes its SwiftData record, drops it from the live `JobRegistry`, and
/// deletes its adapter folder on disk (config + adapters.safetensors + log +
/// checkpoints). It does NOT touch the dataset, the base model, or any
/// already-fused "…-trained" model produced from the run — only the run itself.
/// A run that's still training can't be deleted (delete is disabled for it).
struct TrainingHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \TrainingJob.createdAt, order: .reverse) private var jobs: [TrainingJob]

    @State private var deletionTarget: TrainingJob?
    @State private var confirmDeleteAllFinished = false
    @State private var sizes: [UUID: Int64] = [:]
    @State private var error: String?
    @State private var showCompare = false
    @State private var reportTarget: TrainingJob?

    /// Finished runs the bulk action would remove (anything not currently running).
    private var finishedJobs: [TrainingJob] { jobs.filter { $0.status != .running } }

    var body: some View {
        NavigationStack {
            Group {
                if jobs.isEmpty {
                    ContentUnavailableView(
                        "No lessons yet",
                        systemImage: "books.vertical",
                        description: Text("Training runs you complete will show up here.")
                    )
                } else {
                    List {
                        if let error {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                        }
                        ForEach(jobs) { job in
                            row(job)
                        }
                    }
                }
            }
            .navigationTitle("Past lessons")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showCompare = true } label: {
                        Label("Compare", systemImage: "chart.line.uptrend.xyaxis")
                    }
                    .disabled(jobs.count < 2)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) {
                        confirmDeleteAllFinished = true
                    } label: {
                        Label("Delete all finished", systemImage: "trash")
                    }
                    .disabled(finishedJobs.isEmpty)
                }
            }
            .sheet(isPresented: $showCompare) {
                TrainingComparisonView(jobs: jobs)
            }
            .sheet(item: $reportTarget) { job in
                TrainingRunReportView(job: job)
            }
            .alert("Delete this lesson?", isPresented: deletionPresented, presenting: deletionTarget) { job in
                Button("Delete", role: .destructive) { delete(job) }
                Button("Cancel", role: .cancel) {}
            } message: { job in
                Text("Removes \"\(job.name)\" and its trained adapter files from this Mac. The dataset and the base model are kept. You can't undo this.")
            }
            .alert("Delete all finished lessons?", isPresented: $confirmDeleteAllFinished) {
                Button("Delete \(finishedJobs.count)", role: .destructive) { deleteAllFinished() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes \(finishedJobs.count) finished training run\(finishedJobs.count == 1 ? "" : "s") and their adapter files. Runs still in progress are kept. You can't undo this.")
            }
            .frame(minWidth: 480, minHeight: 420)
            .task { await loadSizes() }
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func row(_ job: TrainingJob) -> some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon(job.status))
                .foregroundStyle(statusColor(job.status))
                .font(.title3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name).font(.body).lineLimit(1)
                HStack(spacing: 8) {
                    Text(statusText(job.status)).foregroundStyle(statusColor(job.status))
                    Text("·").foregroundStyle(.secondary)
                    Text(job.createdAt, format: .dateTime.month().day().hour().minute())
                        .foregroundStyle(.secondary)
                    if let bytes = sizes[job.id], bytes > 0 {
                        Text("·").foregroundStyle(.secondary)
                        Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
            Spacer()
            Button(role: .destructive) {
                deletionTarget = job
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(job.status == .running ? "Can't delete a lesson that's still running" : "Delete this lesson")
            .disabled(job.status == .running)
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { deletionTarget = job } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(job.status == .running)
        }
        .contextMenu {
            Button { reportTarget = job } label: {
                Label("View report…", systemImage: "doc.text")
            }
            Button { TrainingRunReport.exportWithPanel(for: job) } label: {
                Label("Export report…", systemImage: "square.and.arrow.up")
            }
            Button(role: .destructive) { deletionTarget = job } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(job.status == .running)
        }
    }

    private var deletionPresented: Binding<Bool> {
        Binding(get: { deletionTarget != nil }, set: { if !$0 { deletionTarget = nil } })
    }

    // MARK: - Actions

    private func delete(_ job: TrainingJob) {
        let id = job.id
        if let message = TrainingArtifactDeletion.deleteJob(job, context: modelContext) {
            error = message
        } else {
            sizes.removeValue(forKey: id)
            error = nil
        }
    }

    private func deleteAllFinished() {
        for job in finishedJobs { delete(job) }
    }

    /// Measure each run's adapter folder off the main actor, then publish back.
    private func loadSizes() async {
        let urls: [(UUID, URL)] = jobs.map { ($0.id, $0.adapterURL) }
        sizes = await Task.detached(priority: .utility) {
            Self.measure(urls)
        }.value
    }

    /// Synchronous folder-size sweep. Kept non-async so the `DirectoryEnumerator`
    /// fast-enumeration (unavailable from async contexts) is legal.
    private nonisolated static func measure(_ urls: [(UUID, URL)]) -> [UUID: Int64] {
        var out: [UUID: Int64] = [:]
        for (id, url) in urls {
            guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            var total: Int64 = 0
            for case let f as URL in e {
                if let s = try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize { total += Int64(s) }
            }
            out[id] = total
        }
        return out
    }

    // MARK: - Status presentation

    private func statusText(_ s: JobStatus) -> String {
        switch s {
        case .queued:    "Queued"
        case .running:   "Learning…"
        case .completed: "Finished"
        case .failed:    "Failed"
        case .cancelled: "Stopped"
        case .orphaned:  "Interrupted"
        }
    }

    private func statusColor(_ s: JobStatus) -> Color {
        switch s {
        case .completed:            .green
        case .running, .queued:     .brand
        case .failed:               .red
        case .cancelled, .orphaned: .orange
        }
    }

    private func statusIcon(_ s: JobStatus) -> String {
        switch s {
        case .completed: "checkmark.circle.fill"
        case .running:   "graduationcap.fill"
        case .queued:    "clock"
        case .failed:    "xmark.circle.fill"
        case .cancelled: "stop.circle"
        case .orphaned:  "exclamationmark.triangle.fill"
        }
    }
}
