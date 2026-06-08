import SwiftUI
import SwiftData

/// How many problems a "Score it" run grades. Friendly speed/thoroughness trade-off;
/// `thorough` is effectively "all" (the helper treats a huge limit as no cap).
private enum EvalDepth: String, CaseIterable, Identifiable {
    case quick, standard, thorough
    var id: String { rawValue }

    var limit: Int {
        switch self {
        case .quick:    20
        case .standard: 40
        case .thorough: 100_000
        }
    }

    var label: String {
        switch self {
        case .quick:    "Quick (20)"
        case .standard: "Standard (40)"
        case .thorough: "Thorough (all)"
        }
    }
}

struct ArenaView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var baseSession: ChatSession
    @State private var adapterSession: ChatSession
    @State private var prompt: String = ""
    @State private var systemPrompt: String = "You are a careful, expert programming assistant. Prefer correct, idiomatic code with minimal commentary."
    @State private var temperature: Double = 0.4
    @State private var maxTokens: Int = 512
    @State private var arenaMode: Bool = true
    @State private var modelText: String = "mlx-community/Llama-3.2-3B-Instruct-4bit"
    @State private var adapterText: String = ""

    // Scored-evaluation state. The view only SHOWS scores; EvalService DOES the work.
    @State private var evalService = EvalService.shared
    @State private var evalSuite: EvalSuite = .humaneval
    @State private var evalDepth: EvalDepth = .quick
    @State private var evalK: Int = 1
    @State private var showEvalTechnical = false
    @State private var currentEval: EvalRun?
    /// Guards against an autoScore handoff firing a second run (e.g. a redelivered
    /// notification) while one is already in flight for the same artifact.
    @State private var autoScoredArtifact: String?

    // Preference-capture state (the DPO loop's input edge). Kept entirely SEPARATE
    // from the eval pieces above: the view only records the user's "which is better?"
    // verdict; PreferenceService persists it as a {prompt, chosen, rejected} pair.
    // The dataset is created lazily on the first capture so an unused Arena never
    // leaves an empty preference lesson behind.
    @State private var prefDataset: DatasetRecord?
    @State private var prefCount: Int = 0

    init() {
        // Default to a general base — the whole point of LLMPro is to take a non-coder
        // and turn it into one. The adapter side is what makes it a coder.
        let initialModel = "mlx-community/Llama-3.2-3B-Instruct-4bit"
        _baseSession = State(initialValue: ChatSession(model: initialModel, adapterPath: nil, label: "Base (general)"))
        _adapterSession = State(initialValue: ChatSession(model: initialModel, adapterPath: nil, label: "Coding fine-tune"))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controls
                Divider()
                if arenaMode {
                    HSplitView {
                        ChatPaneView(session: baseSession)
                        ChatPaneView(session: adapterSession)
                    }
                } else {
                    ChatPaneView(session: adapterSession)
                }
                Divider()
                if showReportCard {
                    evalReportCard
                    Divider()
                }
                if showPreferenceBar {
                    preferenceBar
                    Divider()
                }
                if !adapterText.isEmpty {
                    decisionBar
                    Divider()
                }
                inputBar
            }
            .navigationTitle(arenaMode ? "Model Arena" : "Chat")
            .onAppear { loadPreferenceCount() }
            .onReceive(NotificationCenter.default.publisher(for: .openChatWithModel)) { note in
                handleHandoff(note.object)
            }
        }
    }

    /// Apply an incoming `.openChatWithModel` payload (a `ModelHandoff` with model +
    /// optional adapter + autoScore, or a bare `String` model id — dual-decode kept
    /// so older posters still work). A `ModelHandoff` carrying `autoScore == true`
    /// kicks off a scored eval immediately on arrival.
    private func handleHandoff(_ object: Any?) {
        if let h = object as? ModelHandoff {
            modelText = h.model
            adapterText = h.adapterPath ?? ""
            if let p = h.adapterPath, !p.isEmpty { arenaMode = true }
            applyModelChange()
            if h.autoScore { autoScore() }
        } else if let repo = object as? String {
            modelText = repo
            applyModelChange()
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack {
                Toggle("Arena (compare base vs fine-tuned)", isOn: $arenaMode).toggleStyle(.switch)
                Spacer()
                Stepper("Max tokens: \(maxTokens)", value: $maxTokens, in: 64...8192, step: 64).frame(width: 220)
                HStack { Text("Temp"); Slider(value: $temperature, in: 0...1.5); Text(String(format: "%.2f", temperature)).monospacedDigit() }
                    .frame(width: 240)
            }
            HStack {
                TextField("Base model (HF repo or local path)", text: $modelText, onCommit: applyModelChange)
                TextField("Adapter path (LoRA dir)", text: $adapterText, onCommit: applyModelChange)
                Button("Apply") { applyModelChange() }
            }
            TextField("System prompt", text: $systemPrompt, axis: .vertical).lineLimit(2...4)
        }
        .padding(10)
    }

    private var inputBar: some View {
        VStack(spacing: 8) {
            scoreControls
            HStack(alignment: .bottom) {
                TextEditor(text: $prompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 60, maxHeight: 160)
                    .padding(6)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                Button {
                    send()
                } label: { Label("Send", systemImage: "paperplane.fill") }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(10)
    }

    // The scored-eval action: pick a suite + how thorough, then grade the loaded
    // model (+ adapter) on a held-out coding suite. Friendly pickers up front; the
    // pass@k knob is tucked into "Advanced" so the primary flow stays one tap.
    @ViewBuilder
    private var scoreControls: some View {
        HStack(spacing: 10) {
            Button {
                runScore()
            } label: {
                Label("Score it", systemImage: "checklist")
            }
            .buttonStyle(.borderedProminent)
            .disabled(evalService.isRunning)
            .help("Grade this model on a coding suite and get a pass rate.")

            if evalService.isRunning {
                Button(role: .destructive) {
                    evalService.cancel()
                } label: { Label("Cancel", systemImage: "xmark.circle") }
            }

            Picker("Suite", selection: $evalSuite) {
                Text("HumanEval").tag(EvalSuite.humaneval)
                Text("MBPP").tag(EvalSuite.mbppSanitized)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(evalService.isRunning)

            Picker("How thorough", selection: $evalDepth) {
                ForEach(EvalDepth.allCases) { depth in
                    Text(depth.label).tag(depth)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .disabled(evalService.isRunning)

            Spacer()

            advancedEvalControls
        }
    }

    private var advancedEvalControls: some View {
        DisclosureGroup("Advanced") {
            VStack(alignment: .leading, spacing: 4) {
                Stepper("Samples per problem (k): \(evalK)", value: $evalK, in: 1...8)
                    .disabled(evalService.isRunning)
                Text("k > 1 samples each problem several times at a higher temperature and counts it as passed if any sample passes (pass@k).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 4)
            .frame(maxWidth: 360, alignment: .leading)
        }
        .fixedSize()
    }

    // The test → decision edge: once a fine-tuned adapter is loaded, let the user
    // act on the verdict without hunting through the sidebar — retrain it, use it
    // in the Code tab, or export it.
    private var decisionBar: some View {
        HStack(spacing: 10) {
            Text("How did the fine-tune do?").font(.caption).foregroundStyle(.secondary)
            if let delta = scoreDelta {
                deltaLabel(delta, neutralWhenDown: true).font(.caption)
            }
            Spacer()
            Button {
                NotificationCenter.default.post(name: .openTrainingWithModel, object: modelText)
            } label: { Label("Train again", systemImage: "arrow.triangle.2.circlepath") }
                .help("Not good enough? Go back to Teach with this model to fine-tune again.")
            Button {
                NotificationCenter.default.post(
                    name: .openCodeWithModel,
                    object: ModelHandoff(model: modelText, adapterPath: adapterText.isEmpty ? nil : adapterText))
            } label: { Label("Use in Code", systemImage: "chevron.left.forwardslash.chevron.right") }
                .help("Good enough? Load it into the Code tab's agent team.")
            Button {
                NotificationCenter.default.post(name: .switchSidebar, object: SidebarSection.export)
            } label: { Label("Save & Use", systemImage: "square.and.arrow.up") }
                .help("Export this fine-tune to Ollama / LM Studio.")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.quaternary.opacity(0.3))
    }

    private func applyModelChange() {
        var params = baseSession.params
        params.systemPrompt = systemPrompt
        params.temperature = temperature
        params.maxTokens = maxTokens
        baseSession.model = modelText
        baseSession.adapterPath = nil
        baseSession.params = params
        adapterSession.model = modelText
        adapterSession.adapterPath = adapterText.isEmpty ? nil : adapterText
        adapterSession.params = params
    }

    private func send() {
        let p = prompt
        prompt = ""
        applyModelChange()
        if arenaMode { baseSession.send(p) }
        adapterSession.send(p)
    }

    // MARK: - Scored evaluation

    /// Kick off a scored eval of the currently-loaded model (+ adapter) using the
    /// selected suite / depth / k. The view only records the resulting `EvalRun`;
    /// EvalService persists it and publishes live progress via `status`.
    private func runScore() {
        guard !evalService.isRunning else { return }
        let model = modelText
        let adapter = adapterText.isEmpty ? nil : adapterText
        let suite = evalSuite
        let k = evalK
        let limit = evalDepth.limit
        Task {
            currentEval = await evalService.runEval(
                model: model,
                adapterPath: adapter,
                suite: suite,
                k: k,
                limit: limit,
                sourceLabel: "Test",
                sourceJobID: nil,
                context: modelContext)
        }
    }

    /// Auto-score on an `autoScore` handoff. Guarded so a redelivered notification
    /// (or one arriving mid-run) doesn't fire a second run for the same artifact.
    private func autoScore() {
        guard !evalService.isRunning else { return }
        let key = modelText + "::" + adapterText
        guard autoScoredArtifact != key else { return }
        autoScoredArtifact = key
        runScore()
    }

    // MARK: - Eval report card

    /// Show the report card while a run is in progress, or whenever a completed run
    /// exists for the loaded artifact.
    private var showReportCard: Bool {
        evalService.isRunning || resolvedEval != nil
    }

    /// The run to display: the one we just launched, else the latest stored result
    /// for this exact base + adapter.
    private var resolvedEval: EvalRun? {
        if let currentEval { return currentEval }
        return evalService.latestEval(forBase: modelText,
                                      adapter: storedAdapterPath(adapterText),
                                      context: modelContext)
    }

    @ViewBuilder
    private var evalReportCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if evalService.isRunning {
                runningReport
            } else if let run = resolvedEval {
                completedReport(run)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    @ViewBuilder
    private var runningReport: some View {
        let s = evalService.status
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(runningHeadline(s)).font(.headline)
                if !s.detail.isEmpty {
                    Text(s.detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(role: .destructive) {
                evalService.cancel()
            } label: { Label("Cancel", systemImage: "xmark.circle") }
        }
    }

    private func runningHeadline(_ s: EvalService.LiveStatus) -> String {
        if s.total > 0 {
            return "Grading \(s.graded) of \(s.total)…"
        }
        return s.headline.isEmpty ? "Scoring…" : s.headline
    }

    @ViewBuilder
    private func completedReport(_ run: EvalRun) -> some View {
        evalHeadlineRow(run)
        evalDeltaRow
        evalTechnicalDisclosure(run)
    }

    private func evalHeadlineRow(_ run: EvalRun) -> some View {
        let stars = scoreStars(for: run.passPercent)
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(run.passPercent)%")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    ForEach(1...5, id: \.self) { n in
                        Image(systemName: n <= stars ? "star.fill" : "star")
                            .foregroundStyle(n <= stars ? Color.yellow : Color.gray.opacity(0.4))
                    }
                }
                Text(scoreSummary(run))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func scoreSummary(_ run: EvalRun) -> String {
        var parts = [run.suite.displayName, "\(run.totalCount) problems"]
        if run.k > 1 { parts.append("pass@\(run.k)") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var evalDeltaRow: some View {
        if let delta = scoreDelta {
            deltaLabel(delta, neutralWhenDown: false)
                .font(.subheadline.weight(.medium))
        } else {
            Text("First score for this model.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func evalTechnicalDisclosure(_ run: EvalRun) -> some View {
        DisclosureGroup("Details", isExpanded: $showEvalTechnical) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    Text("\(run.passedCount) / \(run.totalCount) passed").monospacedDigit()
                    Text("k = \(run.k)").monospacedDigit()
                    if run.elapsedMs > 0 {
                        Text(String(format: "%.1fs", Double(run.elapsedMs) / 1000))
                            .monospacedDigit()
                    }
                }
                .font(.caption).foregroundStyle(.secondary)

                Divider()

                ForEach(run.decodedTasks()) { task in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: task.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(task.passed ? Color.green : Color.orange)
                        Text(task.taskID).font(.caption.monospaced())
                        if !task.passed && !task.reason.isEmpty {
                            Text(task.reason)
                                .font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.tail)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }

    // MARK: - Score delta / stars

    /// Percentage-point delta of the resolved run vs the most recent eval of the
    /// same base model with a *different* adapter (the previous try, or the base).
    /// nil when there's no current run or no prior to compare against.
    private var scoreDelta: Int? {
        guard let run = resolvedEval else { return nil }
        guard let previous = evalService.previousAdapterEval(
            forBase: modelText,
            excludingAdapter: storedAdapterPath(adapterText),
            context: modelContext) else { return nil }
        return run.passPercent - previous.passPercent
    }

    /// A coloured "▲ +X pts vs your last try" / "▼ −X pts …" caption.
    /// `neutralWhenDown` swaps the down-copy to "worth another round" for the
    /// decision bar (vs the plain "vs your last try" on the report card).
    private func deltaLabel(_ delta: Int, neutralWhenDown: Bool) -> some View {
        let up = delta >= 0
        let symbol: String = up ? "▲" : "▼"
        let sign: String = up ? "+" : "−"
        let magnitude: Int = abs(delta)
        let tail: String = (!up && neutralWhenDown) ? "worth another round" : "vs your last try"
        let text: String = "\(symbol) \(sign)\(magnitude) pts — \(tail)"
        let color: Color = up ? .green : .orange
        return Text(text).foregroundStyle(color)
    }

    /// 1–5 stars from a pass percentage: <20→1, <40→2, <60→3, <80→4, ≥80→5.
    private func scoreStars(for percent: Int) -> Int {
        switch percent {
        case ..<20: 1
        case ..<40: 2
        case ..<60: 3
        case ..<80: 4
        default:    5
        }
    }

    /// Reduce an absolute adapter path to the relative form stored on `EvalRun`
    /// (matching `EvalService`'s private normaliser) so `latestEval` /
    /// `previousAdapterEval` lookups actually match persisted runs. "" stays "".
    private func storedAdapterPath(_ absolutePath: String) -> String {
        guard !absolutePath.isEmpty else { return "" }
        let root = PathResolver.adaptersDir.path
        let normalizedRoot = root.hasSuffix("/") ? root : root + "/"
        if absolutePath.hasPrefix(normalizedRoot) {
            return String(absolutePath.dropFirst(normalizedRoot.count))
        }
        if !absolutePath.hasPrefix("/") { return absolutePath }
        return URL(fileURLWithPath: absolutePath).lastPathComponent
    }

    // MARK: - Preference capture (DPO loop input edge)
    //
    // Separate from the eval pieces above. When both panes hold a finished answer to
    // the same prompt, the user picks the better one; we save it as a preference pair
    // and (once there are enough) offer to teach by preference. The view SHOWS; the
    // PreferenceService / AutoTuner / TrainingService DO.

    /// Minimum pairs before "Teach by preference" is worth offering — DPO needs at
    /// least a handful of examples (and we split one off for validation).
    private static let minPairsToTrain = 4

    /// The shared input both panes answered: the most recent user turn. Read from the
    /// adapter session (both panes are sent the same prompt by `send()`); falls back to
    /// the base session.
    private var lastUserPrompt: String? {
        let text = adapterSession.messages.last(where: { $0.role == .user })?.text
            ?? baseSession.messages.last(where: { $0.role == .user })?.text
        return (text?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The last *finished* assistant reply in a session, trimmed. nil while a reply is
    /// still streaming or none exists yet. (`send()` appends a trailing newline per
    /// chunk, so trimming matters before we persist the text.)
    private func lastAssistantReply(in session: ChatSession) -> String? {
        let text = session.messages.last(where: { $0.role == .assistant && !$0.isStreaming })?.text
        return (text?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Show the preference bar only when there are genuinely two answers to compare:
    /// compare mode is on, neither pane is mid-stream, and both have a finished reply.
    private var showPreferenceBar: Bool {
        guard arenaMode else { return false }
        guard !baseSession.isGenerating, !adapterSession.isGenerating else { return false }
        guard lastUserPrompt != nil else { return false }
        return lastAssistantReply(in: baseSession) != nil
            && lastAssistantReply(in: adapterSession) != nil
    }

    private var canTeachByPreference: Bool { prefCount >= Self.minPairsToTrain }

    @ViewBuilder
    private var preferenceBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            preferenceChoiceRow
            preferenceFooterRow
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.quaternary.opacity(0.3))
    }

    private var preferenceChoiceRow: some View {
        HStack(spacing: 10) {
            Text("Which answer is better?").font(.callout.weight(.medium))
            Button {
                capturePreference(chosenIsBase: true)
            } label: { Label("👍 Base (left)", systemImage: "hand.thumbsup") }
                .help("Mark the left (base) answer as the better one and save it as a preference.")
            Button {
                capturePreference(chosenIsBase: false)
            } label: { Label("👍 Fine-tune (right)", systemImage: "hand.thumbsup") }
                .help("Mark the right (fine-tune) answer as the better one and save it as a preference.")
            Spacer()
        }
    }

    private var preferenceFooterRow: some View {
        HStack(spacing: 12) {
            Text(preferenceCaption)
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if !canTeachByPreference {
                Text("Rate at least \(Self.minPairsToTrain) to teach by preference")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Button {
                teachByPreference()
            } label: { Label("Teach by preference →", systemImage: "graduationcap") }
                .disabled(!canTeachByPreference)
                .help("Fine-tune this model on the answers you picked (DPO).")
        }
    }

    private var preferenceCaption: String {
        prefCount == 0
            ? "Pick the better answer to start a preferences lesson — more is better."
            : "💾 \(prefCount) preference\(prefCount == 1 ? "" : "s") saved — more is better."
    }

    /// Record one preference pair: chosen = the picked pane's reply, rejected = the
    /// other's. Lazily creates the active preference set on first capture, then
    /// refreshes the running count (de-dup is handled inside the service).
    private func capturePreference(chosenIsBase: Bool) {
        guard let prompt = lastUserPrompt,
              let baseReply = lastAssistantReply(in: baseSession),
              let adapterReply = lastAssistantReply(in: adapterSession)
        else { return }
        let chosen = chosenIsBase ? baseReply : adapterReply
        let rejected = chosenIsBase ? adapterReply : baseReply
        let system = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)

        if prefDataset == nil {
            prefDataset = PreferenceService.findOrCreateActivePreferenceSet(context: modelContext)
        }
        guard let dataset = prefDataset else { return }
        PreferenceService.appendPair(
            prompt: prompt,
            chosen: chosen,
            rejected: rejected,
            system: system.isEmpty ? nil : system,
            to: dataset,
            context: modelContext)
        prefCount = dataset.trainRows
    }

    /// Hand the preference set to Teach. RootView switches the tab; we only post the
    /// payload so the user never re-types the model or the lesson.
    private func teachByPreference() {
        guard canTeachByPreference, let dataset = prefDataset else { return }
        let handoff = PreferenceHandoff(
            model: modelText,
            adapterPath: adapterText.isEmpty ? nil : adapterText,
            datasetID: dataset.id)
        NotificationCenter.default.post(name: .openTrainingWithPreferences, object: handoff)
    }

    /// Load the count from an already-existing active preference set so the caption is
    /// accurate on open — without eagerly creating an empty one if the user never rates.
    private func loadPreferenceCount() {
        guard prefDataset == nil else { return }
        let preference = DatasetSchema.preference.rawValue
        var descriptor = FetchDescriptor<DatasetRecord>(
            predicate: #Predicate { $0.schemaRaw == preference },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 1
        if let existing = (try? modelContext.fetch(descriptor))?.first {
            prefDataset = existing
            prefCount = existing.trainRows
        }
    }
}

#if DEBUG
#Preview("Try it out") {
    ArenaView().previewEnvironment()
}
#endif
