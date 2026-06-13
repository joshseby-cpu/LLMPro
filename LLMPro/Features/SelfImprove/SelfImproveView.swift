import SwiftUI
import SwiftData
import Charts

// "Practice" tab. The friendly metaphor: pick a model and a problem set, the
// model practices, we grade it, the lessons it got right become its next
// study material, repeat. The technical name is self-distillation / rejection
// sampling — but the UI never says any of that out loud.

struct SelfImproveView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PythonRuntime.self) private var runtime
    @Query(sort: \SelfImproveRun.createdAt, order: .reverse) private var runs: [SelfImproveRun]
    @State private var service = SelfImproveService.shared
    @State private var registry = ModelRegistry.shared

    // Setup form state — only meaningful when no run is in flight.
    @State private var pickedModelRepoID: String = ""
    @State private var pickedSeed: SelfImproveSeed = .humaneval
    @State private var targetRounds: Int = 3
    @State private var candidatesPerPrompt: Int = 4
    @State private var rowsPerRound: Int = 20
    @State private var trainIters: Int = 80
    @State private var name: String = ""
    @State private var showPracticeAdvanced = false
    @State private var showRunTechnical = false

    var activeRun: SelfImproveRun? {
        guard let id = service.status.runID else { return nil }
        return runs.first(where: { $0.id == id })
    }

    /// Models that can practice. Practice fine-tunes each round (LoRA on the
    /// candidates that pass), so DiffusionGemma checkpoints — which mlx-lm can't
    /// LoRA-train — are excluded here just like in Teach. They stay usable for
    /// chat in Try it out.
    private var practiceableModels: [ModelRegistry.DetectedModel] {
        registry.localModels.filter { !$0.isDiffusion }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                heroBanner

                if let run = activeRun, service.isRunning {
                    activeRunCard(run: run)
                        .transition(.opacity)
                } else {
                    setupCard
                        .transition(.opacity)
                }

                historySection
            }
            .padding(20)
            .frame(maxWidth: 980, alignment: .topLeading)
        }
        .navigationTitle("Practice")
        .task {
            await registry.scan()
            if pickedModelRepoID.isEmpty {
                pickedModelRepoID = practiceableModels.first?.repoID ?? ""
            }
        }
    }

    // MARK: – Sections ---------------------------------------------------------

    private var heroBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("🎯")
                Text("Practice & Improve")
                    .font(.system(size: 26, weight: .bold))
            }
            Text("Have your model practice coding problems and learn from what it gets right. Each round, the model tries problems, we grade them, and the ones it solved become the next round's homework.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var setupCard: some View {
        if !runtime.isReady {
            cardBox {
                Text("Waiting for the Python runtime to finish setting up…")
                    .foregroundStyle(.secondary)
            }
        } else if practiceableModels.isEmpty {
            cardBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No models that can practice yet.")
                        .font(.headline)
                    Text("Open the Models tab, search HuggingFace, and download something coding-capable (Qwen2.5-Coder-1.5B is a fast first try). Diffusion models can't practice — they're chat-only.")
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            cardBox {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Set up practice")
                        .font(.title3.bold())

                    pickerRow("Which model should practice?", systemImage: "cpu") {
                        Picker("", selection: $pickedModelRepoID) {
                            ForEach(practiceableModels) { m in
                                Text(m.displayName).tag(m.repoID)
                            }
                        }
                        .labelsHidden()
                    }

                    pickerRow("Which problem set?", systemImage: "books.vertical") {
                        Picker("", selection: $pickedSeed) {
                            ForEach(SelfImproveSeed.allCases) { s in
                                Text(s.displayName).tag(s)
                            }
                        }
                        .labelsHidden()
                    }
                    Text(pickedSeed.oneLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 26)

                    Divider()

                    sliderRow("How many rounds of practice?",
                              value: .rounding($targetRounds),
                              range: 1...6, step: 1, formatted: "\(targetRounds)",
                              hint: HelpHint("Rounds",
                                "One round = generate K candidate solutions per problem, run the unit tests, keep the passing ones as training data, train a LoRA on those, evaluate. Each round builds on the previous round's LoRA. More rounds = more cumulative learning but also more wall-clock time.",
                                learnMore: URL(string: "https://github.com/karpathy/autoresearch")))

                    sliderRow("How many tries per problem?",
                              value: .rounding($candidatesPerPrompt),
                              range: 2...8, step: 1, formatted: "\(candidatesPerPrompt)",
                              hint: HelpHint("Candidates per problem",
                                "How many solutions the model generates for each problem. Each one is unit-tested; the ones that pass become next-round training data. More candidates = more diversity (better at finding a working solution) but linearly more inference time per round.",
                                link: "https://arxiv.org/abs/2107.03374"))

                    sliderRow("How many problems per round?",
                              value: .rounding($rowsPerRound),
                              range: 10...60, step: 5, formatted: "\(rowsPerRound) problems",
                              hint: HelpHint("Problems per round",
                                "How many distinct programming problems to attempt each round. More problems = broader practice surface; fewer = faster rounds. The default 20 balances signal-to-noise on the pass-rate curve with reasonable wall-clock time.",
                                link: "https://github.com/openai/human-eval"))

                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { showPracticeAdvanced.toggle() }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: showPracticeAdvanced ? "chevron.down" : "chevron.right")
                                    .font(.caption.weight(.semibold)).frame(width: 12)
                                Text("Advanced")
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        if showPracticeAdvanced {
                            sliderRow("Study iterations per round",
                                      value: .rounding($trainIters),
                                      range: 30...250, step: 10, formatted: "\(trainIters)",
                                      hint: HelpHint("Training iterations per round",
                                        "Each round trains a small LoRA on the candidates that passed unit tests. More iterations means the model fits those passing examples more thoroughly — useful early but risks overfitting once you've got a small keeper set. 80-120 is the sweet spot.",
                                        link: "https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/LORA.md"))
                                .padding(.top, 4)
                            Text("Each round trains a small LoRA on what the model got right. More iterations = more refinement per round.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)

                    HStack {
                        TextField("Name this run (optional)", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 320)
                        Spacer()
                        Button(action: startRun) {
                            Label("Start Practice", systemImage: "play.fill")
                                .padding(.horizontal, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(pickedModelRepoID.isEmpty)
                    }
                }
            }
        }
    }

    private func activeRunCard(run: SelfImproveRun) -> some View {
        cardBox {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(run.name.isEmpty ? "Practice run" : run.name)
                            .font(.title3.bold())
                        Text(run.baseModelRepoID).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) { service.cancel() } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                }

                phaseHeader

                if !service.status.detail.isEmpty {
                    Text(service.status.detail)
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if service.status.rowsTotal > 0 {
                    let frac = max(0, min(1, Double(service.status.rowsDone) / Double(service.status.rowsTotal)))
                    ProgressView(value: frac)
                        .progressViewStyle(.linear)
                    HStack {
                        Text("\(service.status.rowsDone) of \(service.status.rowsTotal) kept lessons").font(.caption)
                        Spacer()
                        if service.status.attemptsSoFar > 0 {
                            Text("\(service.status.passesSoFar) passes / \(service.status.attemptsSoFar) tries")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                if !service.status.passAtOneTrend.isEmpty {
                    trendChart(values: service.status.passAtOneTrend)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { showRunTechnical.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: showRunTechnical ? "chevron.down" : "chevron.right")
                                .font(.caption.weight(.semibold)).frame(width: 12)
                            Text("Technical details")
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    if showRunTechnical {
                        technicalDetails(run: run)
                    }
                }
                .font(.caption)
            }
        }
    }

    private var phaseHeader: some View {
        HStack(spacing: 12) {
            Text(phaseEmoji(service.status.phase)).font(.system(size: 36))
            VStack(alignment: .leading, spacing: 2) {
                Text(service.status.headline.isEmpty ? phaseHeadline(service.status.phase) : service.status.headline)
                    .font(.title3.bold())
                if service.status.roundNumber > 0 {
                    Text("Round \(service.status.roundNumber)")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
            }
            Spacer()
        }
    }

    private func trendChart(values: [Double]) -> some View {
        // baseline + per-round eval — a single line going (hopefully) up.
        let points = Array(values.enumerated())
        return VStack(alignment: .leading, spacing: 6) {
            Text("How well it's solving problems")
                .font(.subheadline.bold())
            Chart {
                ForEach(points, id: \.offset) { idx, value in
                    LineMark(
                        x: .value("Round", idx == 0 ? "Start" : "R\(idx)"),
                        y: .value("Pass rate", value)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.purple)
                    PointMark(
                        x: .value("Round", idx == 0 ? "Start" : "R\(idx)"),
                        y: .value("Pass rate", value)
                    )
                    .foregroundStyle(.purple)
                    .annotation(position: .top) {
                        Text("\(Int(value * 100))%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .chartYScale(domain: 0...1)
            .chartYAxis {
                AxisMarks(values: [0, 0.25, 0.5, 0.75, 1.0]) { v in
                    AxisGridLine()
                    AxisValueLabel {
                        if let d = v.as(Double.self) { Text("\(Int(d * 100))%").font(.caption2) }
                    }
                }
            }
            .frame(height: 160)
        }
    }

    private func technicalDetails(run: SelfImproveRun) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let b = run.baselinePassAtOne {
                Text(String(format: "Baseline (no practice): %.1f%%", b * 100))
            }
            ForEach(run.decodedRounds()) { rec in
                HStack(alignment: .firstTextBaseline) {
                    Text("R\(rec.roundNumber):")
                        .frame(width: 36, alignment: .leading)
                    Text("\(rec.rowsKept)/\(rec.rowsAttempted) kept")
                        .frame(width: 110, alignment: .leading)
                    Text(String(format: "%.0f%% try-pass", rec.passRate * 100))
                        .frame(width: 110, alignment: .leading)
                    if let e = rec.evalPassAtOne {
                        Text(String(format: "→ %.1f%% eval", e * 100))
                    }
                }
                .font(.system(.caption, design: .monospaced))
            }
            if !service.logTail.isEmpty {
                Text("Log").font(.caption.bold()).padding(.top, 6)
                ScrollView {
                    Text(service.logTail.suffix(80).joined(separator: "\n"))
                        .font(.system(.caption2, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    @ViewBuilder
    private var historySection: some View {
        if !runs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("History").font(.title3.bold())
                ForEach(runs) { r in
                    historyRow(r)
                }
            }
        }
    }

    private func historyRow(_ run: SelfImproveRun) -> some View {
        let trend = run.passAtOneTrend
        let start = trend.first
        let last = trend.last
        let improvement = (last ?? 0) - (start ?? 0)
        return HStack(alignment: .top, spacing: 12) {
            statusBadge(run.status)
            VStack(alignment: .leading, spacing: 4) {
                Text(run.name.isEmpty ? "Practice run" : run.name)
                    .font(.headline)
                Text(run.baseModelRepoID).font(.caption).foregroundStyle(.secondary)
                if let start, let last {
                    Text(String(format: "%.0f%% → %.0f%% (%+0.1f pts) across %d rounds",
                                start * 100, last * 100, improvement * 100, run.decodedRounds().count))
                        .font(.caption)
                } else {
                    Text("\(run.decodedRounds().count) round(s) — no eval yet")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let err = run.lastError, run.status == .failed {
                    Text(err).font(.caption2).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer()
            if let url = run.latestAdapterDirectory {
                Menu {
                    Button {
                        NotificationCenter.default.post(name: .openChatWithModel, object: handoff(run, url))
                    } label: { Label("Try it out", systemImage: "bubble.left.and.bubble.right") }
                    Button {
                        NotificationCenter.default.post(name: .openCodeWithModel, object: handoff(run, url))
                    } label: { Label("Use in Code", systemImage: "chevron.left.forwardslash.chevron.right") }
                    Divider()
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: { Label("Reveal in Finder", systemImage: "folder") }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.path, forType: .string)
                    } label: { Label("Copy adapter path", systemImage: "doc.on.doc") }
                } label: {
                    Label("Use this fine-tune", systemImage: "sparkles")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .controlSize(.small)
            }
            Button(role: .destructive) {
                modelContext.delete(run)
                try? modelContext.save()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .background(.background.tertiary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Hand the automated loop's result to the manual loop's Test / Use stages.
    private func handoff(_ run: SelfImproveRun, _ adapter: URL) -> ModelHandoff {
        ModelHandoff(model: run.baseModelRepoID, adapterPath: adapter.path)
    }

    // MARK: – Actions ----------------------------------------------------------

    private func startRun() {
        guard !pickedModelRepoID.isEmpty else { return }
        let displayName = name.trimmingCharacters(in: .whitespaces).isEmpty
            ? "\(pickedSeed.rawValue) practice" : name
        let run = SelfImproveRun(
            name: displayName,
            baseModelRepoID: pickedModelRepoID,
            seed: pickedSeed,
            targetRounds: targetRounds,
            candidatesPerPrompt: candidatesPerPrompt,
            rowsPerRound: rowsPerRound,
            trainIters: trainIters
        )
        modelContext.insert(run)
        try? modelContext.save()
        Task { await service.start(run: run, context: modelContext) }
    }

    // MARK: – Building blocks --------------------------------------------------

    private func cardBox<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading) { content() }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func pickerRow<Content: View>(_ title: String, systemImage: String,
                                          @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(.purple).frame(width: 16)
            Text(title)
            Spacer()
            content().frame(maxWidth: 320)
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                           step: Double, formatted: String,
                           hint: HelpHint? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                if let hint { hint }
                Spacer()
                Text(formatted).font(.subheadline).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }

    private func statusBadge(_ s: SelfImproveStatus) -> some View {
        let (label, color): (String, Color) = {
            switch s {
            case .queued:     ("•", .gray)
            case .completed:  ("✓", .green)
            case .failed:     ("!", .red)
            case .cancelled:  ("–", .secondary)
            default:          ("…", .orange)
            }
        }()
        return Text(label)
            .font(.headline.bold())
            .frame(width: 28, height: 28)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(Circle())
    }

    private func phaseEmoji(_ p: SelfImproveService.Phase) -> String {
        switch p {
        case .idle, .completed:  "🎓"
        case .pullingSeed:       "📚"
        case .baselineEval:      "🧪"
        case .generating:        "✏️"
        case .training:          "🧠"
        case .evaluating:        "✅"
        case .failed:            "⚠️"
        case .cancelled:         "🛑"
        }
    }

    private func phaseHeadline(_ p: SelfImproveService.Phase) -> String {
        switch p {
        case .idle:          "Ready"
        case .pullingSeed:   "Getting the practice problems"
        case .baselineEval:  "Checking how it does without practice"
        case .generating:    "Trying problems"
        case .training:      "Studying what it got right"
        case .evaluating:    "Grading the practice"
        case .completed:     "All done"
        case .failed:        "Stopped"
        case .cancelled:     "Cancelled"
        }
    }
}

#if DEBUG
#Preview("Practice") {
    SelfImproveView().previewEnvironment()
}
#endif
