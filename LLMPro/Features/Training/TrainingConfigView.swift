import SwiftUI
import SwiftData

struct TrainingConfigView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PythonRuntime.self) private var runtime
    @Environment(JobRegistry.self) private var jobRegistry
    @Query(sort: \DatasetRecord.createdAt, order: .reverse) private var datasets: [DatasetRecord]
    @Query(sort: \TrainingJob.createdAt, order: .reverse) private var jobs: [TrainingJob]
    @State private var registry = ModelRegistry.shared

    // A pending Teach pre-fill owned by `RootView` (which is always alive, so it
    // doesn't miss the cross-tab hand-off notification the way this lazily-mounted
    // view would). We apply it on appear (first-ever visit, after RootView stashed
    // it) or on change (this view was already mounted when it arrived), then nil it
    // out so it can't re-apply on the next redraw. Defaults to a constant-nil binding
    // so callers / previews that don't route hand-offs keep working unchanged.
    @Binding var pendingHandoff: PendingTrainingHandoff?

    init(pendingHandoff: Binding<PendingTrainingHandoff?> = .constant(nil)) {
        self._pendingHandoff = pendingHandoff
    }

    /// Token of the last hand-off we applied — so the `.onReceive` belt-and-suspenders
    /// path can't re-apply the same request the `pendingHandoff` binding already
    /// delivered (and vice-versa). The `.onReceive` posts get a fresh token each time
    /// via `PendingTrainingHandoff`, so a genuinely new notification still applies.
    @State private var lastAppliedHandoffToken: UUID?

    // Step state
    @State private var jobName: String = ""           // empty = use derivedDefaultName
    @State private var selectedModelRepoID: String?
    @State private var selectedDatasetID: UUID?
    @State private var duration: TrainingDuration = .standard
    // Optional: keep improving an existing fine-tune instead of starting fresh.
    // When set, training continues from that job's adapter weights, reusing its
    // exact LoRA config so the resume is architecture-compatible.
    @State private var continueFromJobID: UUID? = nil
    // Preference (DPO) mode. Set by an `.openTrainingWithPreferences` hand-off from
    // "Try it out". It also follows automatically from the dataset type (see
    // `usePreferenceMode`) — there's no manual toggle in the primary UI per the
    // AutoTuner-picks-everything rule; DPO mode is implied by a `.preference` lesson.
    @State private var dpoMode = false

    /// Auto-default name derived from current selection. Used as the textfield
    /// placeholder, AND substituted into the saved job when the user hasn't typed
    /// their own name. Updates live as selection changes.
    private var derivedDefaultName: String {
        let model: String? = selectedModelRepoID.map { id in
            // Strip "owner/" prefix and trailing "-Instruct-Nbit" cruft for legibility.
            let short = id.split(separator: "/").last.map(String.init) ?? id
            return short
        }
        let dataset = datasets.first(where: { $0.id == selectedDatasetID })?.name
        switch (model, dataset) {
        case (let m?, let d?): return "\(m) + \(d)"
        case (let m?, nil):    return "\(m) lesson"
        case (nil,    let d?): return "Lesson on \(d)"
        default:               return "Coding lesson"
        }
    }

    // Advanced overrides
    @State private var showAdvanced: Bool = false
    @State private var advanced: TrainingConfig = .default

    // MoE expert targeting (only consulted when the selected base is MoE).
    // `pickSpecific = false` (default) means tune every expert via shared
    // pattern keys; `pickSpecific = true` lets the user toggle which expert
    // indices to LoRA-target.
    @State private var moeSpecificExperts: Bool = false
    @State private var selectedExpertIndices: Set<Int> = []

    // Flow state
    @State private var launching = false
    @State private var error: String?

    // "Training should modify the model": when on, the finished training is fused
    // into the chosen model and saved as a new ready-to-use model (the original is
    // kept). Non-destructive — no confirmation needed.
    @State private var applyToModelInPlace = false

    /// Convenience: the DetectedModel for the currently selected repoID, or nil
    /// if the user hasn't picked yet / the model isn't registered.
    private var selectedModel: ModelRegistry.DetectedModel? {
        guard let id = selectedModelRepoID else { return nil }
        return registry.localModels.first(where: { $0.repoID == id })
    }

    /// Models the user can actually fine-tune. DiffusionGemma checkpoints are
    /// inference-only (mlx-lm LoRA / the AutoTuner don't apply to masked /
    /// block-diffusion LMs), so they never appear in the "pick a model to teach"
    /// picker — they stay usable in Try it out, just not here.
    private var teachableModels: [ModelRegistry.DetectedModel] {
        registry.localModels.filter { !$0.isDiffusion }
    }

    /// The currently-selected dataset record, if any.
    private var selectedDataset: DatasetRecord? {
        guard let id = selectedDatasetID else { return nil }
        return datasets.first(where: { $0.id == id })
    }

    /// True when the chosen lesson is a preferences set. DPO mode follows from this
    /// (a chat lesson trains the normal supervised way).
    private var selectedDatasetIsPreference: Bool {
        selectedDataset?.schema == .preference
    }

    /// The effective "teach by preference" decision: the hand-off flag OR a
    /// `.preference` lesson. Drives the banner and the `launch()` branch so the UI
    /// and the run always agree, even if the user picks a preferences lesson by hand.
    private var usePreferenceMode: Bool {
        dpoMode || selectedDatasetIsPreference
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    LowDiskWarningBanner()
                    headline
                    if usePreferenceMode {
                        preferenceModeBanner
                    }
                    step1ModelPicker
                    step2DatasetPicker
                    step3DurationPicker
                    summaryAndStart
                    advancedDisclosure
                }
                .padding(20)
                .frame(maxWidth: 880, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Teach your model")
            .task { await registry.scan() }
            // Consume a hand-off RootView stashed before this view existed (the
            // first-ever-visit case the `.onReceive` paths below physically can't
            // catch). Runs every time the view appears; the token guard makes a
            // repeat appearance a no-op.
            .onAppear { consumePendingHandoffIfNeeded() }
            // Consume a hand-off that arrived while this view was already mounted:
            // RootView updates the binding, this fires. (The `.onReceive` paths cover
            // the same case directly — this is the belt to their suspenders.)
            .onChange(of: pendingHandoff) { _, _ in consumePendingHandoffIfNeeded() }
            .onReceive(NotificationCenter.default.publisher(for: .openTrainingWithModel)) { note in
                if let repo = note.object as? String {
                    apply(PendingTrainingHandoff(payload: .model(repo)))
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openTrainingWithPreferences)) { note in
                if let handoff = note.object as? PreferenceHandoff {
                    apply(PendingTrainingHandoff(payload: .preference(handoff)))
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openTrainingForCoding)) { note in
                if let repo = note.object as? String {
                    selectedModelRepoID = repo
                    // Auto-pick the first coding-looking dataset we have.
                    let codingNames = ["codealpaca", "magicoder", "dotnet", "coder", "code-"]
                    let coding = datasets.first { ds in
                        let lower = ds.name.lowercased()
                        return codingNames.contains(where: { lower.contains($0) })
                    } ?? datasets.first
                    if let ds = coding { selectedDatasetID = ds.id }
                    duration = .standard
                    let short = repo.split(separator: "/").last.map(String.init) ?? repo
                    jobName = "\(short)-coder"
                }
            }
        }
    }

    // MARK: - Hand-off pre-fill

    /// Apply the hand-off RootView stashed for us, if there is one we haven't already
    /// applied, then clear the binding so it can't re-apply on a later redraw.
    private func consumePendingHandoffIfNeeded() {
        guard let handoff = pendingHandoff else { return }
        apply(handoff)
        pendingHandoff = nil
    }

    /// Pre-fill the picker state from a hand-off. Idempotent per request: a hand-off
    /// whose token we already applied is ignored, so the `pendingHandoff` binding and
    /// the `.onReceive` notification paths can't double-apply the same request. Sets
    /// `selectedModelRepoID` to the exact `ModelRegistry.repoID` the model cards match
    /// on, and (for preferences) `selectedDatasetID` to the lesson's id + DPO mode, so
    /// both cards show selected on arrival.
    private func apply(_ handoff: PendingTrainingHandoff) {
        guard lastAppliedHandoffToken != handoff.token else { return }
        lastAppliedHandoffToken = handoff.token
        switch handoff.payload {
        case .model(let repo):
            selectedModelRepoID = repo
        case .preference(let pref):
            selectedModelRepoID = pref.model
            selectedDatasetID = pref.datasetID
            dpoMode = true
        }
    }

    // MARK: - Sections

    private var headline: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Teach a model to code, in three steps.")
                .font(.title2.bold())
            Text("LLMPro will pick the best settings for your Mac. You don't need to know how training works.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// Read-only heads-up shown when the selected lesson is a preferences set: the
    /// run will teach by preference (DPO). No toggle — the mode follows the lesson.
    private var preferenceModeBanner: some View {
        Label("🧭 This is a preferences lesson — LLMPro will teach by preference (DPO).",
              systemImage: "hand.thumbsup")
            .font(.callout)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var step1ModelPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("1. Pick a model to teach", systemImage: "1.circle.fill").font(.headline)

            if teachableModels.isEmpty {
                emptyStateCard(
                    title: "No models to teach yet",
                    body: "Open the Models tab on the left and download one (Llama 3.2 3B is a great first pick). Diffusion models can't be taught — they're chat-only.",
                    icon: "cube.box"
                )
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
                    ForEach(teachableModels) { model in
                        ModelChoiceCard(
                            model: model,
                            isSelected: selectedModelRepoID == model.repoID,
                            duration: duration
                        )
                        .onTapGesture { selectedModelRepoID = model.repoID }
                    }
                }
            }
            refineFromPreviousPicker
        }
    }

    /// Optional "keep improving a previous fine-tune" selector — the manual side
    /// of the iterate loop. When chosen, training continues from that completed
    /// adapter's weights (reusing its LoRA config) instead of the raw base model.
    @ViewBuilder
    private var refineFromPreviousPicker: some View {
        if !completedAdapterJobs.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Picker(selection: $continueFromJobID) {
                    Text("Start fresh from the base model").tag(UUID?.none)
                    ForEach(completedAdapterJobs) { j in
                        Text("Keep improving “\(j.name)”").tag(Optional(j.id))
                    }
                } label: {
                    Label("Continue a previous fine-tune?", systemImage: "arrow.triangle.2.circlepath")
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 460, alignment: .leading)
                if continueFromJobID != nil {
                    Text("Training picks up from that fine-tune's weights on the same base model and lessons, saved as a new model.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
            .onChange(of: continueFromJobID) { _, id in
                if let id, let src = jobs.first(where: { $0.id == id }) {
                    selectedModelRepoID = src.baseModelRepoID
                    selectedDatasetID = src.datasetID
                }
            }
        }
    }

    /// Completed jobs whose adapter weights are on disk — refinable fine-tunes.
    private var completedAdapterJobs: [TrainingJob] {
        jobs.filter {
            $0.status == .completed &&
            FileManager.default.fileExists(atPath: $0.adapterURL.appendingPathComponent("adapters.safetensors").path)
        }
    }

    @ViewBuilder
    private var step2DatasetPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("2. Pick what to teach it", systemImage: "2.circle.fill").font(.headline)
            if datasets.isEmpty {
                emptyStateCard(
                    title: "No lessons yet",
                    body: "Open the Datasets tab and tap Prepare on \"CodeAlpaca 20K\" — that's the recommended starter lesson.",
                    icon: "tray.full"
                )
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
                    ForEach(datasets) { ds in
                        DatasetChoiceCard(
                            dataset: ds,
                            isSelected: selectedDatasetID == ds.id
                        )
                        .onTapGesture { selectedDatasetID = ds.id }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var step3DurationPicker: some View {
        let preview = tunedPreview
        VStack(alignment: .leading, spacing: 10) {
            Label("3. How long should it study?", systemImage: "3.circle.fill").font(.headline)
            HStack(spacing: 12) {
                ForEach(TrainingDuration.allCases) { option in
                    DurationCard(
                        option: option,
                        estimatedMinutes: durationMinutes(option),
                        isSelected: duration == option
                    )
                    .onTapGesture { duration = option }
                }
            }
            if let preview {
                Text("LLMPro will train for **\(preview.iters) steps**, in batches of **\(preview.batchSize)**. It should take **about \(preview.estimatedMinutes) minute\(preview.estimatedMinutes == 1 ? "" : "s")**.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label("Smart recipe: warm-up + cosine learning-rate schedule\(preview.useDoRA ? " · DoRA for a higher-quality adapter" : "")",
                      systemImage: "wand.and.stars")
                    .font(.caption)
                    .foregroundStyle(.purple)
                memoryEstimate(preview)
            }
        }
    }

    /// Warn loudly when the training config might OOM the machine. Better to
    /// surface this BEFORE the user waits 10 min for the model to load and
    /// then crashes.
    ///
    /// **Critical**: the headroom check has to be much wider than the system-
    /// RAM headroom would suggest, because Apple Silicon's Metal layer has its
    /// own GPU working-set ceiling (~85% of total RAM in practice). A run
    /// with 5 GB of "free" RAM will still crash with
    /// `kIOGPUCommandBufferCallbackErrorOutOfMemory` because Metal can't push
    /// past its ceiling even when the kernel says memory is free. Hence the
    /// orange warning fires at <15 GB headroom, not <8.
    @ViewBuilder
    private func memoryEstimate(_ tuned: AutoTunedConfig) -> some View {
        let total = Int(Double(SystemMetrics.shared.totalMemoryBytes) / 1_073_741_824.0)
        // AutoTuner's estimate assumes LoRA (rank-r adapter on top of frozen
        // weights). If the user opened Advanced and picked Full FT, peak
        // memory roughly triples because every weight needs a gradient, plus
        // AdamW's m + v buffers are full-rank (~2x model size each). Bump the
        // estimate so the warning fires correctly.
        let peak: Int = {
            let base = tuned.estimatedPeakMemoryGB
            guard showAdvanced && advanced.fineTuneType == .full else { return base }
            // Find the model size on disk to scale the extra-memory budget.
            // bf16 weights: ~2 GB per B params. Full FT needs grads + m + v
            // → +3x weights minus the LoRA optimizer overhead we already had.
            let weightsGB: Int = {
                if let m = selectedModel {
                    return max(1, Int(m.sizeBytes / 1_073_741_824))
                }
                // Fall back to size-bucket estimate from AutoTuner internals.
                return base / 2
            }()
            return base + (weightsGB * 3)
        }()
        let headroom = total - peak
        HStack(spacing: 6) {
            if peak == 0 || total == 0 {
                EmptyView()
            } else if headroom < 15 {
                Label("Will likely run out of GPU memory: needs ~\(peak) GB of your \(total) GB. Apple Silicon's Metal layer can only use ~85% of unified memory, so anything that needs more than ~\(Int(Double(total) * 0.85)) GB will fail mid-run. Try: switch fine-tune type to LoRA (cuts memory ~4×), shrink the model in Modify (quantize 8-bit halves it), or pick a smaller base.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if headroom < 25 {
                Label("Tight: needs ~\(peak) GB of your \(total) GB. Should fit but leaves little headroom for the OS — close other apps before starting.",
                      systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.yellow)
            } else {
                Label("Will use about **\(peak) GB** of your **\(total) GB** unified memory while training.",
                      systemImage: "memorychip")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 2)
    }

    private var summaryAndStart: some View {
        VStack(alignment: .leading, spacing: 10) {
            applyInPlaceToggle
            TextField(derivedDefaultName, text: $jobName)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 360)
                .help("Defaults to \(derivedDefaultName) — type to override.")
            HStack {
                Button {
                    Task { await launch() }
                } label: {
                    HStack {
                        if launching {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: "play.fill")
                        }
                        Text(launching ? "Starting…" : "Start Teaching")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: 240)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canStart)

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
            if !runtime.isReady {
                Label("Setting up Python… you can start once the dot in the sidebar turns green.",
                      systemImage: "hourglass")
                    .font(.caption).foregroundStyle(.orange)
            }
            if jobRegistry.activeJob != nil {
                Label("A lesson is already running. Watch the Monitor tab or stop it first.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    /// The "training should modify the model" switch + an honest caption.
    private var applyInPlaceToggle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Save the trained model when done", isOn: $applyToModelInPlace)
            Text(applyToModelInPlace
                 ? "On: when training finishes, it's merged into the model and saved as a new ready-to-use model “\(selectedModelDisplayName)-trained” — no separate adapter step. Your original model is kept. \(applyCaveat)"
                 : "Off (normal): training produces a separate adapter; pick it up later in Save & Use to make a model from it.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(applyToModelInPlace ? Color.accentColor.opacity(0.08) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
    }

    /// Caveat tailored to the selected model: quantized models come back larger
    /// because fusing dequantizes them.
    private var applyCaveat: String {
        guard let repo = selectedModelRepoID,
              let m = registry.localModels.first(where: { $0.repoID == repo }),
              !m.quantization.isEmpty, m.quantization.lowercased() != "none"
        else { return "" }
        return "(It's \(m.quantization) — merging makes the saved copy full-precision, so it'll be larger on disk.)"
    }

    private var selectedModelDisplayName: String {
        guard let repo = selectedModelRepoID else { return "the selected model" }
        return registry.localModels.first(where: { $0.repoID == repo })?.displayName ?? repo
    }

    @ViewBuilder
    private var advancedDisclosure: some View {
        VStack(alignment: .leading, spacing: 10) {
            // A plain DisclosureGroup only toggles when you hit its tiny chevron —
            // nearly impossible to click. Drive the expansion with an explicit
            // full-width Button (whole row tappable) instead.
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showAdvanced.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .frame(width: 12)
                    Label("Advanced settings (don't change unless you know what these do)",
                          systemImage: "gearshape")
                        .font(.callout)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if showAdvanced {
                advancedForm
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var advancedForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("These fields override the auto-picked values when set. Leave them as auto-detected to keep things simple.")
                .font(.caption).foregroundStyle(.secondary)

            Form {
                Section {
                    Picker("Type", selection: $advanced.fineTuneType) {
                        ForEach(FineTuneType.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    HStack(spacing: 6) {
                        Text("LoRA method")
                        HelpHint("Fine-tune type: LoRA vs DoRA vs Full",
                                 "LoRA (Low-Rank Adaptation) trains tiny side-matrices added to specific layers — fast, memory-cheap, produces a small adapter file. DoRA is a variant that decomposes the update into magnitude + direction, often better quality at similar memory cost. Full fine-tune updates every weight in the base — most expressive but needs massive memory (you can't full-FT a 27B model on 128 GB). Full FT is blocked entirely for quantized models because mlx can't backprop through packed weights.",
                                 learnMore: URL(string: "https://huggingface.co/docs/peft/main/en/conceptual_guides/lora"))
                    }
                }
                Section {
                    HStack {
                        Text("Iterations: \(advanced.iters)")
                        Spacer()
                        Stepper("", value: $advanced.iters, in: 50...20_000, step: 50).labelsHidden()
                        HelpHint("Iterations",
                                 "How many training steps the model takes. Each step processes one batch and updates the LoRA weights once. More iterations = more learning but eventually the model overfits to your data and gets worse on everything else. Quick = ~200, Standard = ~600, Thorough = ~1500 for medium models.",
                                 learnMore: URL(string: "https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/LORA.md"))
                    }
                    HStack {
                        Text("Batch size: \(advanced.batchSize)")
                        Spacer()
                        Stepper("", value: $advanced.batchSize, in: 1...32).labelsHidden()
                        HelpHint("Batch size",
                                 "How many training examples are processed at once before the model updates. Bigger batches = smoother gradient estimates + faster wall-clock per epoch, but more memory. For huge models on 128 GB Macs, batch=1 is often forced. Pair with grad accumulation if you want an 'effective' batch larger than what fits in memory.",
                                 learnMore: URL(string: "https://huggingface.co/docs/transformers/perf_train_gpu_one#batch-size"))
                    }
                    HStack {
                        Text("Layers: \(advanced.numLayers)")
                        Spacer()
                        Stepper("", value: $advanced.numLayers, in: 1...80).labelsHidden()
                        HelpHint("Trainable layers",
                                 "How many of the model's transformer layers get LoRA adapters (starting from the top, closest to the output). Fewer layers = less memory + faster training but less capacity to learn complex patterns. 8-16 is typical; the rest are frozen.",
                                 link: "https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/LORA.md")
                    }
                    HStack {
                        Text("Max seq length: \(advanced.maxSeqLength)")
                        Spacer()
                        Stepper("", value: $advanced.maxSeqLength, in: 256...32_768, step: 256).labelsHidden()
                        HelpHint("Max sequence length",
                                 "How many tokens the model can attend to per training row. Longer = better at long-context tasks but quadratically more memory per step. Most coding rows are ~150-300 tokens, so 1024-2048 is plenty unless your dataset has multi-file or long-document examples.",
                                 link: "https://huggingface.co/docs/transformers/main_classes/tokenizer")
                    }
                    HStack {
                        Text("Learning rate")
                        Spacer()
                        TextField("", value: $advanced.learningRate, format: .number.precision(.fractionLength(0...8)))
                            .frame(width: 120)
                            .textFieldStyle(.roundedBorder)
                        HelpHint("Learning rate",
                                 "How big a step the model takes each iteration. Too high = NaN losses + the model 'explodes'; too low = it learns too slowly. Sane ranges: 1e-5 to 5e-5 for medium models, 5e-6 to 1e-5 for huge ones. The Auto-tuner picks a safe value based on model size.",
                                 learnMore: URL(string: "https://huggingface.co/docs/transformers/training#training-hyperparameters"))
                    }
                    HStack {
                        Toggle("Gradient checkpointing", isOn: $advanced.gradCheckpoint)
                        Spacer()
                        HelpHint("Gradient checkpointing",
                                 "A memory-saving trick: instead of keeping every layer's activations in memory during the backward pass, recompute them on the fly. Trades ~25% extra compute for huge memory savings. Required for big models on 128 GB Macs; harmless for small ones.",
                                 learnMore: URL(string: "https://huggingface.co/docs/transformers/perf_train_gpu_one#gradient-checkpointing"))
                    }
                    HStack {
                        Toggle("Mask prompt", isOn: $advanced.maskPrompt)
                        Spacer()
                        HelpHint("Mask prompt",
                                 "When on, the loss is computed only on the assistant's response — the user's prompt doesn't 'count'. This is what you want when training on chat data: you don't want the model to learn to produce user prompts, just better responses. Turning it off can sometimes improve numerical stability on tricky bases (the safe-mode auto-tuning does this for Qwen-27B-8bit).",
                                 link: "https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/LORA.md")
                    }
                    HStack {
                        Toggle("Warm-up + cosine LR schedule", isOn: Binding(
                            get: { advanced.lrScheduleWarmupSteps > 0 },
                            set: { advanced.lrScheduleWarmupSteps = $0 ? max(5, advanced.iters / 20) : 0 }
                        ))
                        Spacer()
                        HelpHint("Learning-rate schedule",
                                 "Instead of a flat learning rate, ramp up over the first few percent of steps (warm-up) then smoothly cosine-decay toward zero. Steadier early training and a better final result — standard practice in modern fine-tuning, and the portable equivalent of the recipes tools like Unsloth use on NVIDIA. The Auto-tuner turns this on for you.",
                                 link: "https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/LORA.md")
                    }
                    HStack {
                        Text("Optimizer")
                        Spacer()
                        Picker("", selection: $advanced.optimizer) {
                            Text("adamw").tag("adamw")
                            Text("adam").tag("adam")
                            Text("sgd").tag("sgd")
                        }
                        .labelsHidden()
                        .frame(width: 120)
                        HelpHint("Optimizer",
                                 "The algorithm that turns gradients into weight updates. AdamW is the strong default — adaptive per-parameter learning rates plus weight decay. Plain Adam is similar but no weight decay (slightly worse generalization). SGD is the simplest — no momentum buffers, so it can't get poisoned by a single bad gradient. The auto-tuner uses SGD for known-unstable bases like Qwen-27B-8bit.",
                                 learnMore: URL(string: "https://docs.pytorch.org/docs/stable/optim.html"))
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text("Schedule")
                        HelpHint("Training schedule",
                                 "How long, how big each step, and how aggressively the model learns. The Auto-tuner picks these from the model's size and your chosen duration (Quick / Standard / Thorough). Override here only if you know what you're doing.",
                                 learnMore: URL(string: "https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/LORA.md"))
                    }
                }
                if advanced.fineTuneType != .full {
                    Section {
                        Stepper("Rank: \(advanced.loraRank)", value: $advanced.loraRank, in: 1...128)
                        HStack {
                            Text("Scale")
                            Slider(value: $advanced.loraScale, in: 1...256)
                            Text("\(Int(advanced.loraScale))").monospacedDigit().frame(width: 40)
                        }
                        HStack {
                            Text("Dropout")
                            Slider(value: $advanced.loraDropout, in: 0...0.3)
                            Text(String(format: "%.2f", advanced.loraDropout)).monospacedDigit().frame(width: 40)
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Text("LoRA params")
                            HelpHint("LoRA rank · scale · dropout",
                                     "Rank controls how 'wide' each LoRA adapter matrix is — higher rank = more capacity to learn, but more memory + a bigger adapter on disk. Typical: 8 for huge models, 16 for medium. Scale is a multiplier applied at runtime — common convention is rank × 2. Dropout randomly zeroes adapter outputs during training to fight overfitting (usually leave at 0 for small datasets).",
                                     learnMore: URL(string: "https://huggingface.co/docs/peft/main/en/conceptual_guides/lora"))
                        }
                    }
                }
                if let model = selectedModel, model.isMoE, advanced.fineTuneType != .full {
                    let canPickIndividual = AutoTuner.supportsPerExpertTargeting(
                        architecture: model.architecture, repoID: model.repoID)
                    Section {
                        Text("All \(model.numExperts) experts will be LoRA-adapted together (routes \(model.expertsPerToken) per token). The adapter touches every expert's FFN weights across every layer.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if canPickIndividual {
                            Toggle("Pick specific experts", isOn: $moeSpecificExperts)
                                .onChange(of: moeSpecificExperts) { _, on in
                                    if !on {
                                        advanced.loraTargetKeys = AutoTuner.moeLoraTargetKeys(
                                            architecture: model.architecture, repoID: model.repoID)
                                        selectedExpertIndices.removeAll()
                                    } else if selectedExpertIndices.isEmpty {
                                        selectedExpertIndices = Set(0..<model.numExperts)
                                        advanced.loraTargetKeys = expertLoraKeys(
                                            for: model, selected: selectedExpertIndices)
                                    }
                                }
                            if moeSpecificExperts {
                                Text("Selected experts will have LoRA adapters; others stay frozen at their base weights. Useful if you've identified which experts handle a domain you want to specialize.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                ExpertPickerGrid(
                                    numExperts: model.numExperts,
                                    selected: $selectedExpertIndices,
                                    onChange: { idx in
                                        advanced.loraTargetKeys = expertLoraKeys(
                                            for: model, selected: idx)
                                    }
                                )
                            }
                        } else {
                            Label("This MoE flavor (Gemma-4 / switch-GLU) batches every expert into a single tensor per layer. There's no way to LoRA-target individual experts — the math operates on all of them at once. The 'tune all experts together' default above is the only option.",
                                  systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Text("Experts (MoE — \(model.numExperts) experts)")
                            HelpHint("Mixture-of-Experts",
                                     "This model has \(model.numExperts) experts and routes \(model.expertsPerToken) per token. By default we LoRA-target the FFN weights of every expert across every layer — that's the broadly-applicable 'tune the whole MoE' approach.\n\nFor architectures that store each expert as its own tensor (Mixtral, Qwen-MoE, OlmoE, Granite-MoE), you can also pick specific expert indices to specialize. Gemma-4 batches all experts into one tensor per layer, so per-expert picking is unavailable there.",
                                     learnMore: URL(string: "https://huggingface.co/blog/moe"))
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: 520)
        }
    }

    /// Build a LoRA target-keys list for a specific subset of expert indices.
    /// Each selected index expands to its FFN sub-weights, plus we always
    /// include the standard attention q/v projections.
    private func expertLoraKeys(for model: ModelRegistry.DetectedModel,
                                selected: Set<Int>) -> [String] {
        var keys = ["self_attn.q_proj", "self_attn.v_proj"]
        let arch = model.architecture.lowercased()
        let repo = model.repoID.lowercased()
        let isMixtral = arch.contains("mixtral") || repo.contains("mixtral")
        for idx in selected.sorted() {
            if isMixtral {
                keys.append("block_sparse_moe.experts.\(idx).w1")
                keys.append("block_sparse_moe.experts.\(idx).w3")
            } else {
                keys.append("mlp.experts.\(idx).gate_proj")
                keys.append("mlp.experts.\(idx).up_proj")
            }
        }
        return keys
    }

    // MARK: - Helpers

    private var canStart: Bool {
        runtime.isReady &&
        jobRegistry.activeJob == nil &&
        selectedModelRepoID != nil &&
        selectedDatasetID != nil &&
        !launching
    }

    private var tunedPreview: AutoTunedConfig? {
        guard let repo = selectedModelRepoID else { return nil }
        // Prefer the architecture-aware overload when the model is in our
        // registry — that's how MoE bases pick up MoE-appropriate LoRA keys.
        if let m = registry.localModels.first(where: { $0.repoID == repo }) {
            return AutoTuner.tune(model: m, dataPath: "", adapterPath: "", duration: duration)
        }
        return AutoTuner.tune(repoID: repo, dataPath: "", adapterPath: "", duration: duration)
    }

    /// Turn a user-facing model identifier into something mlx-lm can load.
    ///
    /// **Always** prefer the absolute snapshot path when we already have the
    /// model on disk — including for HF repo IDs like `mlx-community/Qwen…`.
    /// Otherwise mlx-lm's loader calls `huggingface_hub`, which respects
    /// `HF_HOME` but looks under `<HF_HOME>/hub/models--*/` — and our cache
    /// lives at `<HF_HOME>/models--*/` (the `snapshot_download(cache_dir=…)`
    /// layout). That mismatch triggers a 28 GB re-download every time you
    /// hit Start, presenting in the UI as "stuck on Opening the textbook".
    /// `ModelRegistry.scan()` already walks BOTH layouts, so a registry hit
    /// is sufficient evidence we can load from disk.
    private func resolveModelArg(_ repoOrName: String) -> String {
        if let local = registry.localModels.first(where: { $0.repoID == repoOrName }) {
            return local.directory.path
        }
        return repoOrName
    }

    private func durationMinutes(_ d: TrainingDuration) -> Int? {
        guard let repo = selectedModelRepoID else { return nil }
        return AutoTuner.tune(repoID: repo, dataPath: "", adapterPath: "", duration: d).estimatedMinutes
    }

    private func emptyStateCard(title: String, body: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(body).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func launch() async {
        // Refine path: continue an existing fine-tune from its weights, reusing
        // its exact LoRA config so the adapter is resume-compatible.
        if let srcID = continueFromJobID, let src = jobs.first(where: { $0.id == srcID }) {
            await launchRefine(from: src)
            return
        }

        guard let repo = selectedModelRepoID,
              let dsID = selectedDatasetID,
              let ds = datasets.first(where: { $0.id == dsID })
        else {
            error = "Pick a model and a lesson before starting."
            return
        }

        // The DatasetRecord row can outlive its on-disk directory if the user
        // (or an external cleanup) deleted the files. Catch that here rather
        // than letting mlx-lm fail 2 seconds later with a cryptic "Loading
        // Hugging Face dataset <path>" stderr that vanishes when the app
        // restarts.
        if !FileManager.default.fileExists(atPath: ds.trainFile.path) {
            error = "The lesson \"\(ds.name)\" is missing its files on disk. Re-prepare it from the Lessons tab, then try again."
            return
        }

        launching = true
        defer { launching = false }
        error = nil

        // Teach-by-preference when the lesson is a preferences set (or a DPO hand-off
        // flipped the flag). DPO needs a non-empty validation set, so carve one off the
        // train rows first (a no-op once a holdout exists), then tune + render via the
        // DPO path. A normal chat lesson stays on the supervised path below, unchanged.
        let isDPO = usePreferenceMode
        if isDPO {
            PreferenceService.splitForTraining(dataset: ds)
        }

        let jobID = UUID()
        let adapterURL = PathResolver.adapterDir(for: jobID)
        let tuned: AutoTunedConfig = {
            if let m = registry.localModels.first(where: { $0.repoID == repo }) {
                return isDPO
                    ? AutoTuner.tuneDPO(model: m, dataPath: ds.directoryURL.path,
                                        adapterPath: adapterURL.path, duration: duration)
                    : AutoTuner.tune(model: m, dataPath: ds.directoryURL.path,
                                     adapterPath: adapterURL.path, duration: duration)
            }
            return isDPO
                ? AutoTuner.tuneDPO(repoID: repo, dataPath: ds.directoryURL.path,
                                    adapterPath: adapterURL.path, duration: duration)
                : AutoTuner.tune(repoID: repo, dataPath: ds.directoryURL.path,
                                 adapterPath: adapterURL.path, duration: duration)
        }()

        // mlx_lm interprets `model:` as either a HuggingFace repo ID (has `/`) or a local
        // path. For custom locally-modified models (vision-stripped, abliterated, custom
        // imports) the repoID is just the folder name — pass the absolute directory path
        // instead so mlx-lm loads from disk rather than trying to fetch a nonexistent repo.
        let modelArg = resolveModelArg(repo)

        // Build YAML. For DPO, always render from the auto-tuned config — the Advanced
        // form is the SFT schema (no preference fields) and DPO follows the
        // AutoTuner-picks-everything rule. For SFT, honor the advanced overrides as before.
        let yaml: String
        if showAdvanced && !isDPO {
            var cfg = advanced
            cfg.model = modelArg
            cfg.data = ds.directoryURL.path
            cfg.adapterPath = adapterURL.path
            yaml = cfg.renderYAML()
        } else {
            yaml = AutoTuner.renderYAML(repoID: modelArg, dataPath: ds.directoryURL.path,
                                        adapterPath: adapterURL.path, tuned: tuned)
        }

        let trimmed = jobName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? derivedDefaultName : trimmed
        let job = TrainingJob(
            id: jobID,
            name: finalName,
            configYAML: yaml,
            baseModelRepoID: repo,
            datasetID: ds.id,
            adapterRelativePath: jobID.uuidString,
            applyToModelInPlace: applyToModelInPlace
        )
        // Record the algorithm so TrainingService picks the DPO launch argv.
        if isDPO { job.trainMode = .dpo }
        modelContext.insert(job)
        do { try modelContext.save() } catch {
            self.error = error.localizedDescription
            return
        }

        do {
            try await TrainingService.shared.start(job: job, context: modelContext)
            NotificationCenter.default.post(name: .switchToMonitor, object: nil)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Continue training from a completed fine-tune's weights. Reuses the source
    /// job's config verbatim (same base model + LoRA rank/keys → resume-safe),
    /// only redirecting the adapter output to a fresh job dir, then resumes via
    /// mlx-lm's `--resume-adapter-file`. Saved as a new model so the original is
    /// preserved.
    private func launchRefine(from src: TrainingJob) async {
        launching = true
        defer { launching = false }
        error = nil

        let srcAdapterFile = src.adapterURL.appendingPathComponent("adapters.safetensors")
        guard FileManager.default.fileExists(atPath: srcAdapterFile.path) else {
            error = "That fine-tune's weights are missing on disk — can't continue from it."
            return
        }

        let jobID = UUID()
        let newAdapterURL = PathResolver.adapterDir(for: jobID)
        try? FileManager.default.createDirectory(at: newAdapterURL, withIntermediateDirectories: true)
        let yaml = Self.replacingAdapterPath(in: src.configYAML, with: newAdapterURL.path)

        let trimmed = jobName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "\(src.name)-v2" : trimmed
        let job = TrainingJob(
            id: jobID,
            name: finalName,
            configYAML: yaml,
            baseModelRepoID: src.baseModelRepoID,
            datasetID: src.datasetID,
            adapterRelativePath: jobID.uuidString
        )
        modelContext.insert(job)
        do { try modelContext.save() } catch {
            self.error = error.localizedDescription
            return
        }

        do {
            try await TrainingService.shared.start(job: job, context: modelContext, resumeAdapterFile: srcAdapterFile)
            NotificationCenter.default.post(name: .switchToMonitor, object: nil)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Swap the `adapter_path:` line in a rendered config YAML, leaving the model
    /// and LoRA parameters untouched (so a resume stays architecture-compatible).
    static func replacingAdapterPath(in yaml: String, with newPath: String) -> String {
        yaml
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line.trimmingCharacters(in: .whitespaces).hasPrefix("adapter_path:")
                    ? "adapter_path: \"\(newPath)\""
                    : String(line)
            }
            .joined(separator: "\n")
    }
}

// MARK: - Cards

private struct ModelChoiceCard: View {
    let model: ModelRegistry.DetectedModel
    let isSelected: Bool
    let duration: TrainingDuration

    private var size: ModelSize { AutoTuner.categorize(repoID: model.repoID) }

    var body: some View {
        let tuned = AutoTuner.tune(repoID: model.repoID, dataPath: "", adapterPath: "", duration: duration)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(size.emoji).font(.largeTitle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName).font(.headline).lineLimit(1)
                    Text("\(size.displayName) · \(model.quantization)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint).font(.title3)
                }
            }
            Text(size.oneLine).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 8) {
                Label("\(tuned.estimatedMinutes) min", systemImage: "clock")
                    .font(.caption2)
                Label(model.humanSize, systemImage: "externaldrive")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.gray.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
    }
}

private struct DatasetChoiceCard: View {
    let dataset: DatasetRecord
    let isSelected: Bool

    private var filesMissing: Bool {
        !FileManager.default.fileExists(atPath: dataset.trainFile.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(filesMissing ? "⚠️" : "📚").font(.largeTitle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(dataset.name).font(.headline).lineLimit(1)
                    Text(filesMissing ? "Files missing on disk" : dataset.schema.displayName)
                        .font(.caption)
                        .foregroundStyle(filesMissing ? .orange : .secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint).font(.title3)
                }
            }
            Text(filesMissing
                 ? "Re-prepare this lesson from the Lessons tab to use it."
                 : "\(dataset.trainRows.formatted()) examples to learn from")
                .font(.caption2)
                .foregroundStyle(filesMissing ? .orange : .secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(filesMissing ? 0.55 : 1.0)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.gray.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
    }
}

private struct DurationCard: View {
    let option: TrainingDuration
    let estimatedMinutes: Int?
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            Text(option.emoji).font(.system(size: 28))
            Text(option.displayName).font(.headline)
            Text(estimatedMinutes.map { "~\($0) min" } ?? option.oneLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 90)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.gray.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
    }
}

extension Notification.Name {
    static let switchToMonitor = Notification.Name("LLMPro.switchToMonitor")
    /// Posted by Models tab's "Train for coding" button. `object` is the
    /// model repoID. Teach pre-fills model + first available coding dataset +
    /// "-coder" name suffix when this fires.
    static let openTrainingForCoding = Notification.Name("LLMPro.openTrainingForCoding")
}

/// A horizontal-wrapping grid of small expert-index buttons. Tapping toggles
/// whether that expert is in the LoRA target set. Used by the MoE expert
/// picker in TrainingConfigView's Advanced disclosure.
private struct ExpertPickerGrid: View {
    let numExperts: Int
    @Binding var selected: Set<Int>
    let onChange: (Set<Int>) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button("All") {
                    selected = Set(0..<numExperts)
                    onChange(selected)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                Button("None") {
                    selected.removeAll()
                    onChange(selected)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                Spacer()
                Text("\(selected.count) of \(numExperts) selected")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44, maximum: 56), spacing: 4)], spacing: 4) {
                ForEach(0..<numExperts, id: \.self) { idx in
                    Button {
                        if selected.contains(idx) { selected.remove(idx) }
                        else { selected.insert(idx) }
                        onChange(selected)
                    } label: {
                        Text("\(idx)")
                            .font(.caption.monospacedDigit())
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .background(
                                selected.contains(idx)
                                    ? AnyShapeStyle(Color.accentColor.opacity(0.7))
                                    : AnyShapeStyle(.quaternary.opacity(0.5)),
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                            .foregroundStyle(selected.contains(idx) ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

#if DEBUG
#Preview("Teach") {
    TrainingConfigView().previewEnvironment()
}
#endif
