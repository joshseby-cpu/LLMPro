import SwiftUI
import SwiftData
import Charts

struct TrainingMonitorView: View {
    @Environment(JobRegistry.self) private var jobRegistry
    @Environment(\.modelContext) private var modelContext
    @State private var metrics = SystemMetrics.shared
    @State private var showTechnical = false
    @State private var resuming = false
    @State private var resumeError: String?

    var body: some View {
        NavigationStack {
            Group {
                if let job = mostRecentJob() {
                    content(for: job)
                } else {
                    ContentUnavailableView(
                        "Nothing learning yet",
                        systemImage: "books.vertical",
                        description: Text("Open the Teach tab to start a lesson.")
                    )
                }
            }
            .navigationTitle("Progress")
            // start() is idempotent/self-healing. We deliberately do NOT stop()
            // on disappear: SystemMetrics.shared is an app-lifecycle-owned
            // singleton (started in RootView) that Dashboard and others read —
            // stopping it here would zero the gauges app-wide.
            .task { metrics.start() }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(for job: JobRegistry.LiveJob) -> some View {
        let phase = TrainingNarrator.phase(for: job)
        let initial = TrainingNarrator.initialLoss(from: job)
        let current = TrainingNarrator.currentLoss(from: job)
        let starCount = TrainingNarrator.stars(initial: initial, current: current)

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                titleCard(job: job, phase: phase)
                progressCard(job: job, phase: phase)
                howWellCard(stars: starCount)
                memoryCard
                if job.status == .running {
                    stopButton(jobID: job.id)
                } else if job.status == .completed {
                    completionCard(job: job)
                } else if job.status == .orphaned {
                    resumeCard(job: job)
                }
                technicalDisclosure(job: job)
            }
            .padding(20)
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("Couldn't resume the lesson", isPresented: resumeErrorBinding) {
            Button("OK", role: .cancel) { resumeError = nil }
        } message: {
            Text(resumeError ?? "")
        }
    }

    private var resumeErrorBinding: Binding<Bool> {
        Binding(get: { resumeError != nil }, set: { if !$0 { resumeError = nil } })
    }

    // MARK: - Cards

    private func titleCard(job: JobRegistry.LiveJob, phase: TrainingNarrator.Phase) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(job.name).font(.title2.bold())
            Text(job.baseModelRepoID).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(phase.emoji).font(.title)
                VStack(alignment: .leading) {
                    Text(phase.headline).font(.headline)
                    Text(phase.subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 6)
        }
    }

    private func progressCard(job: JobRegistry.LiveJob, phase: TrainingNarrator.Phase) -> some View {
        let (done, total) = stepCounts(job: job, phase: phase)
        let percent = total > 0 ? Double(done) / Double(total) : 0
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Lessons learned", systemImage: "books.vertical")
                    .font(.headline)
                Spacer()
                Text(total > 0 ? "\(done) of \(total)" : "—")
                    .font(.headline.monospacedDigit())
            }
            ProgressView(value: percent)
                .progressViewStyle(.linear)
                .tint(.accentColor)
                .scaleEffect(x: 1, y: 1.8, anchor: .center)
                .padding(.vertical, 4)
            HStack {
                Text("\(Int(percent * 100))% done")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if let eta = TrainingNarrator.eta(for: job), job.status == .running {
                    Text(eta).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func howWellCard(stars: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("How well is it learning?", systemImage: "sparkles").font(.headline)
            HStack(spacing: 6) {
                ForEach(1...5, id: \.self) { n in
                    Image(systemName: n <= stars ? "star.fill" : "star")
                        .foregroundStyle(n <= stars ? Color.yellow : Color.gray.opacity(0.4))
                        .font(.title2)
                }
                Spacer()
                Text(TrainingNarrator.verdict(for: stars))
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            Text("Each star = the model getting noticeably better at the lessons.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var memoryCard: some View {
        let snap = metrics.current
        let pct = snap.totalGB > 0 ? min(snap.usedGB / snap.totalGB, 1.0) : 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Memory in use", systemImage: "memorychip").font(.headline)
                Spacer()
                Text(String(format: "%.0f of %.0f GB", snap.usedGB, snap.totalGB))
                    .font(.headline.monospacedDigit())
            }
            ProgressView(value: pct)
                .tint(pct > 0.85 ? .red : (pct > 0.7 ? .orange : .green))
                .scaleEffect(x: 1, y: 1.5, anchor: .center)
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func stopButton(jobID: UUID) -> some View {
        HStack {
            Spacer()
            Button(role: .destructive) {
                JobRegistry.shared.stop(jobID: jobID)
            } label: {
                Label("Stop early", systemImage: "stop.fill").padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // The Progress → Test/Use/Export edge: when a lesson finishes, hand the
    // freshly trained model+adapter straight to the next stage instead of leaving
    // the user to copy a UUID path between tabs.
    private func completionCard(job: JobRegistry.LiveJob) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("All done — your model finished its lessons!", systemImage: "checkmark.seal.fill")
                .font(.headline).foregroundStyle(.green)
            Text("Take it for a spin, put it to work in the Code tab, or save it for everyday use.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button {
                    NotificationCenter.default.post(name: .openChatWithModel, object: handoff(job))
                } label: { Label("Try it out", systemImage: "bubble.left.and.bubble.right") }
                    .buttonStyle(.borderedProminent)
                Button {
                    NotificationCenter.default.post(name: .openChatWithModel, object: scoringHandoff(job))
                } label: { Label("Grade it", systemImage: "checklist") }
                    .help("Open Test and immediately score it on a coding suite.")
                Button {
                    NotificationCenter.default.post(name: .openCodeWithModel, object: handoff(job))
                } label: { Label("Use in Code", systemImage: "chevron.left.forwardslash.chevron.right") }
                Button {
                    NotificationCenter.default.post(name: .switchSidebar, object: SidebarSection.export)
                } label: { Label("Save & Use", systemImage: "square.and.arrow.up") }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }

    private func handoff(_ job: JobRegistry.LiveJob) -> ModelHandoff {
        ModelHandoff(model: job.baseModelRepoID, adapterPath: job.adapterURL.path)
    }

    /// Same artifact as `handoff` but flagged to auto-score on arrival, so the
    /// "Grade it" CTA lands the user in the pre-filled Test node with the scored
    /// eval already running.
    private func scoringHandoff(_ job: JobRegistry.LiveJob) -> ModelHandoff {
        ModelHandoff(model: job.baseModelRepoID, adapterPath: job.adapterURL.path, autoScore: true)
    }

    // The retrain-after-interruption edge: a job whose process died while the app
    // was closed comes back as `.orphaned`. Offer to pick the lesson back up from
    // its most-recent checkpoint instead of starting over from scratch.
    private func resumeCard(job: JobRegistry.LiveJob) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("This lesson was interrupted", systemImage: "pause.circle.fill")
                .font(.headline).foregroundStyle(.orange)
            Text("It looks like the app closed while your model was still learning. The good news: it saved its progress along the way, so we can pick up right where it left off.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button {
                    attemptResume(job: job)
                } label: {
                    HStack(spacing: 6) {
                        if resuming { ProgressView().controlSize(.small) }
                        Label("Resume lesson", systemImage: "play.fill").padding(.horizontal, 4)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(resuming)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }

    // The view's only logic: re-fetch the SwiftData record and hand it to the
    // service (which finds the checkpoint and respawns mlx-lm). On success the
    // registry flips the LiveJob to `.running` and the `.running` UI takes over,
    // so there's nothing to refresh here.
    private func attemptResume(job: JobRegistry.LiveJob) {
        let jobID = job.id
        let descriptor = FetchDescriptor<TrainingJob>(predicate: #Predicate { $0.id == jobID })
        guard let record = (try? modelContext.fetch(descriptor))?.first else {
            resumeError = "We couldn't find the saved details for this lesson, so it can't be resumed. You can start a fresh lesson from the Teach tab."
            return
        }
        guard let checkpoint = TrainingService.latestAdapterCheckpoint(in: job.adapterURL) else {
            resumeError = "This lesson didn't save far enough to resume. You can start a fresh lesson from the Teach tab."
            return
        }
        resuming = true
        Task { @MainActor in
            defer { resuming = false }
            do {
                try await TrainingService.shared.resume(job: record, latestAdapterFile: checkpoint, context: modelContext)
            } catch {
                Log.error("Resume failed for job \(jobID)", .training, error: error)
                resumeError = error.localizedDescription
            }
        }
    }

    // MARK: - Technical disclosure

    private func technicalDisclosure(job: JobRegistry.LiveJob) -> some View {
        // Full-width tappable header (a plain DisclosureGroup only toggles on its
        // tiny chevron, which is nearly impossible to hit).
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showTechnical.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showTechnical ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold)).frame(width: 12)
                    Label("Technical details", systemImage: "chart.xyaxis.line").font(.callout)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if showTechnical {
                VStack(alignment: .leading, spacing: 12) {
                    statStrip(job: job)
                    chartsGrid(for: job)
                    logTail(job: job)
                }
                .padding(.top, 8)
            }
        }
    }

    private func statStrip(job: JobRegistry.LiveJob) -> some View {
        HStack(spacing: 12) {
            if let s = job.lastStep {
                StatChip(label: "iter", value: "\(s.iter)")
                if let l = s.trainLoss { StatChip(label: "loss", value: String(format: "%.3f", l)) }
                if let t = s.tokensPerSec { StatChip(label: "tok/s", value: String(format: "%.0f", t)) }
                if let p = s.peakMemGB { StatChip(label: "peak", value: String(format: "%.1f GB", p)) }
            } else {
                Text("Metrics will appear once the model starts training.").foregroundStyle(.secondary).font(.caption)
            }
        }
    }

    private func chartsGrid(for job: JobRegistry.LiveJob) -> some View {
        let trainPoints = job.steps.filter { !$0.isEval && $0.trainLoss != nil }
        let evalPoints  = job.steps.filter { $0.isEval && $0.valLoss != nil }
        return Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                chartCard(title: "Train loss") {
                    Chart(downsample(trainPoints), id: \.iter) { step in
                        LineMark(x: .value("iter", step.iter), y: .value("loss", step.trainLoss ?? 0))
                            .interpolationMethod(.monotone)
                    }
                }
                chartCard(title: "Eval loss") {
                    Chart(evalPoints, id: \.iter) { step in
                        LineMark(x: .value("iter", step.iter), y: .value("loss", step.valLoss ?? 0))
                            .symbol(.circle)
                    }
                }
            }
            GridRow {
                chartCard(title: "Learning rate") {
                    Chart(downsample(trainPoints), id: \.iter) { step in
                        LineMark(x: .value("iter", step.iter), y: .value("lr", step.learningRate))
                    }
                    .chartYScale(type: .log)
                }
                chartCard(title: "Tokens/sec") {
                    Chart(downsample(trainPoints), id: \.iter) { step in
                        LineMark(x: .value("iter", step.iter), y: .value("tok/s", step.tokensPerSec ?? 0))
                            .interpolationMethod(.monotone)
                    }
                }
            }
        }
    }

    private func chartCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content().frame(minHeight: 140)
        }
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func logTail(job: JobRegistry.LiveJob) -> some View {
        // `Array(job.logTail.suffix(30).enumerated())` inline forces the solver
        // through a deep EnumeratedSequence<ArraySlice<…>> → Array → ForEach
        // generic chain; annotating the result type up front keeps the body fast
        // (and well under the preview compiler's stricter limit).
        let lines: [IndexedLogLine] = IndexedLogLine.tail(of: job.logTail, count: 30)
        return VStack(alignment: .leading) {
            Text("Log (last 30 lines)").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(lines) { line in
                        Text(line.text).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(minHeight: 140, maxHeight: 220)
            .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(.green)
        }
    }

    // MARK: - Helpers

    private func mostRecentJob() -> JobRegistry.LiveJob? {
        jobRegistry.activeJob
            ?? jobRegistry.jobs.values.sorted(by: {
                ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast)
            }).first
    }

    private func stepCounts(job: JobRegistry.LiveJob, phase: TrainingNarrator.Phase) -> (Int, Int) {
        switch phase {
        case .learning(let n, let m), .popQuiz(let n, let m):
            return (n, m)
        case .finished:
            // After completion lastStep is the final iter; total = same.
            let last = job.lastStep?.iter ?? 0
            return (last, last)
        default:
            return (0, 0)
        }
    }

    private func downsample(_ steps: [TrainingStep], maxPoints: Int = 500) -> [TrainingStep] {
        guard steps.count > maxPoints else { return steps }
        let stride = steps.count / maxPoints
        return steps.enumerated().compactMap { idx, step in idx % stride == 0 ? step : nil }
    }
}

private struct StatChip: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit().bold())
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }
}

#if DEBUG
#Preview("Progress") {
    TrainingMonitorView().previewEnvironment()
}
#endif
