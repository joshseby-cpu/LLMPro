import SwiftUI

struct ModelModifyView: View {
    let model: ModelRegistry.DetectedModel
    @Environment(\.dismiss) private var dismiss
    @State private var service = ModelModifyService.shared

    @State private var doStripVision: Bool
    @State private var doAbliterate: Bool
    @State private var doQuantize: Bool
    @State private var quantBits: Int
    @State private var outputName: String

    // MoE expert editing (only used when model.isMoE)
    private enum ExpertMode: String, CaseIterable, Identifiable {
        case none, add, remove, modify
        var id: String { rawValue }
    }
    @State private var expertMode: ExpertMode = .none
    @State private var addCount: Int = 2
    @State private var addNoise: Double = 0.01
    @State private var addSource: Int = -1            // -1 = last expert (default)
    @State private var removeSelection: Set<Int> = []
    @State private var modIndex: Int = 0
    @State private var modMode: ExpertManagementService.ModifyMode = .noise
    @State private var modNoise: Double = 0.01
    @State private var modCloneSrc: Int = 0

    init(model: ModelRegistry.DetectedModel) {
        self.model = model
        // Default: strip vision IF the model looks like a VLM, never abliterate by default.
        let looksLikeVLM = model.architecture.lowercased().contains("vl") ||
                           model.architecture.contains("_5") ||  // qwen3_5, etc.
                           model.repoID.lowercased().contains("vl") ||
                           model.repoID.lowercased().contains("vision")
        _doStripVision = State(initialValue: looksLikeVLM)
        _doAbliterate = State(initialValue: false)
        _doQuantize = State(initialValue: false)
        _quantBits = State(initialValue: 8)
        _outputName = State(initialValue: Self.defaultOutputName(
            for: model, stripVision: looksLikeVLM, abliterate: false,
            quantize: false, bits: 8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    options
                    if model.isMoE {
                        Divider()
                        expertSection
                    }
                }
                .padding(.trailing, 4)
            }
            .frame(minHeight: 200)
            Divider()
            outputField
            Divider()
            progressOrError
            Spacer(minLength: 0)
            buttons
        }
        .padding(20)
        .frame(minWidth: 540, minHeight: 620)
        .onChange(of: doStripVision) { _, _ in regenerateName() }
        .onChange(of: doAbliterate) { _, _ in regenerateName() }
        .onChange(of: doQuantize) { _, _ in regenerateName() }
        .onChange(of: quantBits) { _, _ in regenerateName() }
        .onChange(of: expertMode) { _, _ in regenerateName() }
        .onChange(of: addCount) { _, _ in regenerateName() }
        .onChange(of: modIndex) { _, _ in regenerateName() }
        .onChange(of: removeSelection) { _, _ in regenerateName() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Modify a copy of this model").font(.title3.bold())
            Text(model.repoID).font(.caption).foregroundStyle(.secondary)
            Text("This creates a NEW model on your Mac. The original stays untouched.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $doStripVision) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Remove vision capabilities").font(.headline)
                        HelpHint("Vision stripping",
                                 "Vision-Language Models (VLMs) combine a text LLM with a small vision encoder (ViT or CLIP). If you only want to fine-tune the text part for coding / instructions, the vision tower is dead weight — drop it. Typical savings: 1-5 GB depending on encoder size (it's surprisingly small compared to the text part). For real disk reduction, follow up with Shrink (quantize) below.",
                                 learnMore: URL(string: "https://huggingface.co/blog/vision-language-pretraining"))
                    }
                    Text("Drops the image-understanding part of a VLM. Saves roughly 1–5 GB depending on the vision tower (small relative to the text part) and trains noticeably faster. For big disk savings, pair this with Shrink below — that's where the real reduction comes from.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $doAbliterate) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Make uncensored").font(.headline)
                        Text("EXPERIMENTAL")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2), in: Capsule())
                            .foregroundStyle(.orange)
                        HelpHint("Abliteration",
                                 "Identifies the single direction in the model's residual stream that correlates with refusing requests, then projects that direction out of every weight matrix that writes to the residual stream. The technique was popularized by Maxime Labonne and FailSpy. It usually keeps the model's general capabilities intact while removing reflexive 'I can't help with that' responses. Always sanity-check the result — sometimes the projection damages adjacent capabilities.",
                                 learnMore: URL(string: "https://huggingface.co/blog/mlabonne/abliteration"))
                    }
                    Text("Identifies the direction in the model's internal state that triggers refusals, then projects it out of the weights. The model keeps its skills but stops reflexively saying \"I can't help with that\". This is the cleanest known technique, but always sanity-check the result.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $doQuantize) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Shrink (quantize)").font(.headline)
                        HelpHint("Quantization",
                                 "Replaces 16-bit weights with 8-bit or 4-bit integers using affine quantization (each group of 64 weights gets its own scale + zero-point). 8-bit halves disk + memory with nearly zero quality loss for most models. 4-bit quarters them but can introduce noticeable degradation on small or already-difficult models. Quantized models also can't be FULL-fine-tuned (only LoRA / DoRA) — mlx can't backprop through packed weights.",
                                 learnMore: URL(string: "https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/EXAMPLES.md#quantization"))
                    }
                    Text("Compress the weights to lower precision. 8-bit halves the size (54 GB → ~28 GB), 4-bit quarters it (→ ~14 GB). Lower precision trains faster + uses less memory, but very aggressive quantization (4-bit) can cause numerical instability — start with 8-bit if you're unsure.")
                        .font(.caption).foregroundStyle(.secondary)
                    if doQuantize {
                        Picker("Precision", selection: $quantBits) {
                            Text("8-bit (recommended)").tag(8)
                            Text("4-bit (smallest)").tag(4)
                        }
                        .pickerStyle(.segmented)
                        .padding(.top, 4)
                    }
                }
            }
        }
    }

    // MARK: - Expert editing section (MoE only)

    @ViewBuilder
    private var expertSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("Edit experts").font(.headline)
                Text("EXPERIMENTAL")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.2), in: Capsule())
                    .foregroundStyle(.orange)
                HelpHint("Mixture-of-Experts editing",
                         "This model has \(model.numExperts) experts with top-\(model.expertsPerToken) routing. Add new experts (sparse upcycling), remove some, or modify one in place — in the same pass as vision removal and shrinking. Structural expert edits usually need follow-up fine-tuning (Teach tab) so the router re-balances around the new expert set.",
                         learnMore: URL(string: "https://arxiv.org/abs/2212.05055"))
                Spacer()
            }
            Text("\(model.numExperts) experts · top-\(model.expertsPerToken) routing")
                .font(.caption).foregroundStyle(.secondary)

            Picker("Expert operation", selection: $expertMode) {
                Text("Don't change").tag(ExpertMode.none)
                Text("Add").tag(ExpertMode.add)
                Text("Remove").tag(ExpertMode.remove)
                Text("Modify").tag(ExpertMode.modify)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch expertMode {
            case .none:   EmptyView()
            case .add:    addExpertControls
            case .remove: removeExpertControls
            case .modify: modifyExpertControls
            }
        }
    }

    private var addExpertControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Stepper(value: $addCount, in: 1...64) {
                Text("Add \(addCount) experts (→ \(model.numExperts + addCount) total)")
            }
            HStack(spacing: 6) {
                Text("Noise (\(addNoise, specifier: "%.3f"))").font(.subheadline)
                HelpHint("Cloning noise",
                         "Gaussian noise added to the cloned weights so the new experts don't start identical to the source (which would let them collapse during training). 0.01 is a safe default.",
                         learnMore: URL(string: "https://arxiv.org/abs/2212.05055"))
                Spacer()
            }
            Slider(value: $addNoise, in: 0.001...0.05, step: 0.001)
            Picker("Clone from", selection: $addSource) {
                Text("Last expert (default)").tag(-1)
                ForEach(0..<model.numExperts, id: \.self) { i in
                    Text("Expert \(i)").tag(i)
                }
            }
        }
    }

    private var removeExpertControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(removeSelection.count) of \(model.numExperts) selected")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("All") { removeSelection = Set(0..<model.numExperts) }
                    .buttonStyle(.borderless).font(.caption)
                Button("None") { removeSelection.removeAll() }
                    .buttonStyle(.borderless).font(.caption)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 40, maximum: 56), spacing: 4)], spacing: 4) {
                ForEach(0..<model.numExperts, id: \.self) { idx in
                    Button {
                        if removeSelection.contains(idx) { removeSelection.remove(idx) }
                        else { removeSelection.insert(idx) }
                    } label: {
                        Text("\(idx)")
                            .font(.caption.monospacedDigit())
                            .frame(maxWidth: .infinity, minHeight: 26)
                            .background(
                                removeSelection.contains(idx)
                                    ? AnyShapeStyle(Color.red.opacity(0.7))
                                    : AnyShapeStyle(.quaternary.opacity(0.5)),
                                in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(removeSelection.contains(idx) ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Survivors are renumbered to stay contiguous and the router is trimmed to match. Plan to fine-tune afterward — the router was trained against the original expert set.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modifyExpertControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Which expert", selection: $modIndex) {
                ForEach(0..<model.numExperts, id: \.self) { i in
                    Text("Expert \(i)").tag(i)
                }
            }
            Picker("Operation", selection: $modMode) {
                ForEach(ExpertManagementService.ModifyMode.allCases) { m in
                    Text(m.displayName).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(modMode.explanation)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if modMode == .noise || modMode == .clone {
                HStack(spacing: 6) {
                    Text("Noise (\(modNoise, specifier: "%.3f"))").font(.subheadline)
                    HelpHint("Noise scale",
                             "Std-dev of Gaussian noise added to the weights. 0.01 for noise mode; 0.001–0.005 for clone mode (clones already resemble the source).",
                             learnMore: URL(string: "https://arxiv.org/abs/2212.05055"))
                    Spacer()
                }
                Slider(value: $modNoise, in: 0.001...0.1, step: 0.001)
            }
            if modMode == .clone {
                Picker("Clone from", selection: $modCloneSrc) {
                    ForEach(0..<model.numExperts, id: \.self) { i in
                        Text("Expert \(i)\(i == modIndex ? " (target — pick another)" : "")").tag(i)
                    }
                }
            }
        }
    }

    private var outputField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Save as").font(.headline)
            TextField("new-model-name", text: $outputName)
                .textFieldStyle(.roundedBorder)
            Text("Will be saved to ~/Library/Application Support/MLXStudio/models/\(outputName)")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var progressOrError: some View {
        if let active = service.active {
            VStack(alignment: .leading, spacing: 6) {
                switch active.stage {
                case .idle:
                    HStack { ProgressView().controlSize(.small); Text("Starting…") }
                case .managingExperts(let op, let message):
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Editing experts (\(op)) — \(message)").lineLimit(2)
                    }
                case .stripVision(let stage, let n, let m):
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Removing vision (\(stage))\(n != nil && m != nil ? " — shard \(n!) of \(m!)" : "")")
                    }
                case .abliterating(_, let message):
                    HStack { ProgressView().controlSize(.small); Text(message) }
                case .quantizing(let bits, let message):
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Shrinking to \(bits)-bit — \(message)")
                            .lineLimit(2)
                    }
                case .finished(let path, let droppedBytes):
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Done! Saved to \(path)", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        if droppedBytes > 0 {
                            Text("Removed \(ByteCountFormatter.string(fromByteCount: droppedBytes, countStyle: .file)) of vision weights.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                case .failed(let reason):
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            .padding(10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        } else {
            EmptyView()
        }
    }

    private var buttons: some View {
        HStack {
            Spacer()
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button {
                ModelModifyService.shared.run(
                    input: model,
                    outputName: outputName,
                    stripVision: doStripVision,
                    abliterate: doAbliterate,
                    quantizeBits: doQuantize ? quantBits : nil,
                    expertOp: buildExpertOp()
                )
            } label: {
                HStack {
                    Image(systemName: "wand.and.stars")
                    Text("Make new model")
                }
                .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canRun)
        }
    }

    private var canRun: Bool {
        !outputName.isEmpty &&
        (doStripVision || doAbliterate || doQuantize || expertOpIsValid) &&
        isReadyForNewRun
    }

    /// Whether the currently-selected expert operation is valid and runnable.
    /// `.none` (or a non-MoE model) means "no expert edit" — that's fine on its
    /// own as long as another op is selected, but it doesn't satisfy canRun by
    /// itself.
    private var expertOpIsValid: Bool {
        guard model.isMoE else { return false }
        switch expertMode {
        case .none:   return false
        case .add:    return addCount > 0
        case .remove: return !removeSelection.isEmpty && removeSelection.count < model.numExperts - 1
        case .modify: return modIndex >= 0 && modIndex < model.numExperts
                          && (modMode != .clone || modCloneSrc != modIndex)
        }
    }

    /// Build the ExpertOperation to hand to the service, or nil if no expert
    /// edit is selected / valid.
    private func buildExpertOp() -> ModelModifyService.ExpertOperation? {
        guard expertOpIsValid else { return nil }
        switch expertMode {
        case .none:
            return nil
        case .add:
            var args: [String: Any] = ["count": addCount, "noise_std": addNoise]
            if addSource >= 0 { args["src_expert"] = addSource }
            return makeExpertOp(op: "add", args: args,
                                summary: "Add \(addCount) experts")
        case .remove:
            return makeExpertOp(op: "remove", args: ["indices": removeSelection.sorted()],
                                summary: "Remove \(removeSelection.count) experts")
        case .modify:
            var args: [String: Any] = ["index": modIndex, "op": modMode.rawValue,
                                       "noise_std": modNoise]
            if modMode == .clone { args["clone_src"] = modCloneSrc }
            return makeExpertOp(op: "modify", args: args,
                                summary: "Modify expert \(modIndex)")
        }
    }

    private func makeExpertOp(op: String, args: [String: Any], summary: String)
        -> ModelModifyService.ExpertOperation? {
        guard let data = try? JSONSerialization.data(withJSONObject: args, options: []),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return .init(op: op, argsJSON: json, summary: summary)
    }

    /// Short filename suffix describing the expert edit, for the default output name.
    private func expertSuffix() -> String {
        guard model.isMoE else { return "" }
        switch expertMode {
        case .none:   return ""
        case .add:    return "plus\(addCount)e"
        case .remove: return "minus\(removeSelection.count)e"
        case .modify: return "mod\(modIndex)"
        }
    }

    /// True if no run is in flight. A previous run that ended in a terminal
    /// state (.finished or .failed) still counts as "ready" — the service's
    /// `run()` clears stale terminal state on entry, so a re-click is safe
    /// without waiting for the 6-second auto-clear timer.
    private var isReadyForNewRun: Bool {
        guard let stage = service.active?.stage else { return true }
        switch stage {
        case .finished, .failed: return true
        default: return false
        }
    }

    private func regenerateName() {
        outputName = Self.defaultOutputName(
            for: model, stripVision: doStripVision, abliterate: doAbliterate,
            quantize: doQuantize, bits: quantBits, expertSfx: expertSuffix())
    }

    private static func defaultOutputName(for model: ModelRegistry.DetectedModel,
                                          stripVision: Bool,
                                          abliterate: Bool,
                                          quantize: Bool,
                                          bits: Int,
                                          expertSfx: String = "") -> String {
        var name = model.displayName
        var suffixes: [String] = []
        if !expertSfx.isEmpty { suffixes.append(expertSfx) }
        if stripVision { suffixes.append("text-only") }
        if abliterate { suffixes.append("uncensored") }
        if quantize { suffixes.append("\(bits)bit") }
        if !suffixes.isEmpty { name += "-" + suffixes.joined(separator: "-") }
        return name
    }
}
