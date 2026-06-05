import SwiftUI

/// Full CRUD on the experts in a MoE model: add new, remove existing,
/// or modify one in place (noise / reinit / clone-from-another). Tabbed UI.
struct ExpertManagerView: View {
    let model: ModelRegistry.DetectedModel
    @Environment(\.dismiss) private var dismiss
    @State private var service = ExpertManagementService.shared

    private enum Tab: String, CaseIterable, Identifiable {
        case add, remove, modify
        var id: String { rawValue }
        var label: String {
            switch self {
            case .add:    "Add"
            case .remove: "Remove"
            case .modify: "Modify"
            }
        }
        var icon: String {
            switch self {
            case .add:    "plus.rectangle.on.rectangle"
            case .remove: "minus.rectangle"
            case .modify: "slider.horizontal.3"
            }
        }
    }
    @State private var tab: Tab = .add

    // Shared output naming
    @State private var outputName: String

    // Add op
    @State private var addCount: Int = 2
    @State private var addNoise: Double = 0.01
    @State private var addSourcePicker: Int = -1  // -1 = "last expert (default)"

    // Remove op
    @State private var removeSelection: Set<Int> = []

    // Modify op
    @State private var modifyIndex: Int = 0
    @State private var modifyMode: ExpertManagementService.ModifyMode = .noise
    @State private var modifyNoise: Double = 0.01
    @State private var modifyCloneSrc: Int = 0

    init(model: ModelRegistry.DetectedModel) {
        self.model = model
        _outputName = State(initialValue: "\(model.displayName)-experts-edited")
    }

    private var canPickIndividual: Bool {
        AutoTuner.supportsPerExpertTargeting(architecture: model.architecture, repoID: model.repoID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            tabPicker
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch tab {
                    case .add:    addPanel
                    case .remove: removePanel
                    case .modify: modifyPanel
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 240)
            Divider()
            outputField
            progressOrError
            Spacer(minLength: 0)
            buttons
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 720)
        .onChange(of: tab) { _, t in regenerateOutputName(for: t) }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Manage experts in this MoE model").font(.title3.bold())
                Text("EXPERIMENTAL")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.2), in: Capsule())
                    .foregroundStyle(.orange)
            }
            Text(model.repoID).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Label("\(model.numExperts) experts", systemImage: "person.3.fill")
                Label("top-\(model.expertsPerToken) routing", systemImage: "arrow.triangle.branch")
                Label(canPickIndividual ? "per-expert layout" : "batched layout (Gemma-4)",
                      systemImage: canPickIndividual ? "square.grid.3x3" : "square.stack.3d.up")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Tab picker

    private var tabPicker: some View {
        HStack(spacing: 8) {
            ForEach(Tab.allCases) { t in
                Button {
                    tab = t
                } label: {
                    Label(t.label, systemImage: t.icon)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(tab == t
                            ? AnyShapeStyle(Color.accentColor.opacity(0.15))
                            : AnyShapeStyle(.quaternary.opacity(0.4)),
                            in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(tab == t ? Color.accentColor : .clear, lineWidth: 2)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Add panel

    private var addPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            warningBanner(
                "Cloned experts are noise-perturbed copies of an existing expert. They need follow-up fine-tuning to specialize — without it, the model behaves nearly identically to the original.",
                link: URL(string: "https://arxiv.org/abs/2212.05055"))

            HStack(spacing: 6) {
                Text("How many to add").font(.headline)
                HelpHint("Number of new experts",
                         "Each new expert grows model size by ~one expert's worth of FFN weights (plus a row in the router). Routing cost grows only modestly because top-K stays the same.",
                         learnMore: URL(string: "https://arxiv.org/abs/2212.05055"))
                Spacer()
            }
            Stepper(value: $addCount, in: 1...64) {
                Text("\(addCount) new (→ \(model.numExperts + addCount) total)")
            }

            HStack(spacing: 6) {
                Text("Noise (\(addNoise, specifier: "%.3f"))").font(.headline)
                HelpHint("Cloning noise",
                         "Gaussian noise added to the cloned weights so the new experts don't start identical (which would let them collapse during training). 0.01 is a safe default.",
                         link: "https://arxiv.org/abs/2212.05055")
                Spacer()
            }
            Slider(value: $addNoise, in: 0.001...0.05, step: 0.001)

            HStack(spacing: 6) {
                Text("Clone from").font(.headline)
                HelpHint("Source expert",
                         "Which existing expert to clone. Defaults to the last one — useful if there's no reason to prefer one over another. Picking a specific expert that you know specializes in your target domain may give the new experts a faster start.",
                         link: "https://arxiv.org/abs/2212.05055")
                Spacer()
            }
            Picker("", selection: $addSourcePicker) {
                Text("Last expert (default)").tag(-1)
                ForEach(0..<model.numExperts, id: \.self) { i in
                    Text("Expert \(i)").tag(i)
                }
            }
            .labelsHidden()
        }
    }

    // MARK: - Remove panel

    private var removePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            warningBanner(
                "Removing experts means the router will produce indices that no longer exist — the model needs follow-up fine-tuning to re-balance routing. Without that, generation quality may drop sharply. Refusing to leave fewer than 2 experts.",
                link: nil)

            HStack(spacing: 6) {
                Text("Experts to remove").font(.headline)
                HelpHint("Removing experts",
                         "Selected experts and their corresponding router rows are dropped from the model. Remaining experts are renumbered so indices stay contiguous (0..N-1). The router's gate weight is trimmed to match. Plan to fine-tune after this — the router was trained against the original expert set.",
                         learnMore: URL(string: "https://huggingface.co/blog/moe"))
                Spacer()
                Text("\(removeSelection.count) of \(model.numExperts) selected")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if model.numExperts > 0 {
                HStack(spacing: 8) {
                    Button("All") { removeSelection = Set(0..<model.numExperts) }
                        .buttonStyle(.borderless).font(.caption)
                    Button("None") { removeSelection.removeAll() }
                        .buttonStyle(.borderless).font(.caption)
                    Spacer()
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 44, maximum: 60), spacing: 4)], spacing: 4) {
                    ForEach(0..<model.numExperts, id: \.self) { idx in
                        Button {
                            if removeSelection.contains(idx) { removeSelection.remove(idx) }
                            else { removeSelection.insert(idx) }
                        } label: {
                            Text("\(idx)")
                                .font(.caption.monospacedDigit())
                                .frame(maxWidth: .infinity, minHeight: 28)
                                .background(
                                    removeSelection.contains(idx)
                                        ? AnyShapeStyle(Color.red.opacity(0.7))
                                        : AnyShapeStyle(.quaternary.opacity(0.5)),
                                    in: RoundedRectangle(cornerRadius: 6)
                                )
                                .foregroundStyle(removeSelection.contains(idx) ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Modify panel

    private var modifyPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            warningBanner(
                "In-place edit of one expert. The model's other experts and router stay untouched. Behavior depends on the operation — see the help icons.",
                link: nil)

            HStack(spacing: 6) {
                Text("Which expert").font(.headline)
                HelpHint("Target expert",
                         "Which expert in 0..N-1 to modify. The change applies across every layer's copy of this expert. For diagnostic-style work (e.g. 'is expert 5 important?'), this is your entry point.",
                         link: "https://huggingface.co/blog/moe")
                Spacer()
            }
            Picker("", selection: $modifyIndex) {
                ForEach(0..<model.numExperts, id: \.self) { i in
                    Text("Expert \(i)").tag(i)
                }
            }
            .labelsHidden()

            HStack(spacing: 6) {
                Text("Operation").font(.headline)
                HelpHint(modifyMode.displayName, modifyMode.explanation,
                         link: "https://arxiv.org/abs/2212.05055")
                Spacer()
            }
            Picker("", selection: $modifyMode) {
                ForEach(ExpertManagementService.ModifyMode.allCases) { m in
                    Text(m.displayName).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(modifyMode.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))

            if modifyMode == .noise || modifyMode == .clone {
                HStack(spacing: 6) {
                    Text("Noise (\(modifyNoise, specifier: "%.3f"))").font(.headline)
                    HelpHint("Noise scale",
                             "Standard deviation of Gaussian noise added to weights. Smaller = more conservative change. 0.01 is a good default for noise mode; 0.001-0.005 for clone mode (clones are already similar to the source).",
                             link: "https://arxiv.org/abs/2212.05055")
                    Spacer()
                }
                Slider(value: $modifyNoise, in: 0.001...0.1, step: 0.001)
            }

            if modifyMode == .clone {
                HStack(spacing: 6) {
                    Text("Clone from").font(.headline)
                    HelpHint("Source expert (clone)",
                             "Pick which expert's weights to copy into the target. Useful for replacing a dead or collapsed expert with a copy of a known-good one.",
                             link: "https://arxiv.org/abs/2212.05055")
                    Spacer()
                }
                Picker("", selection: $modifyCloneSrc) {
                    ForEach(0..<model.numExperts, id: \.self) { i in
                        Text("Expert \(i)\(i == modifyIndex ? " (target — pick different)" : "")").tag(i)
                    }
                }
                .labelsHidden()
            }
        }
    }

    // MARK: - Shared output + buttons + progress

    private var outputField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Save as").font(.headline)
                HelpHint("Output model name",
                         "The new model directory under ~/Library/Application Support/LLMPro/models/. The original is never touched.",
                         link: "https://huggingface.co/blog/moe")
                Spacer()
            }
            TextField("output-name", text: $outputName)
                .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder
    private var progressOrError: some View {
        if let active = service.active {
            VStack(alignment: .leading, spacing: 6) {
                switch active.stage {
                case .idle:
                    HStack { ProgressView().controlSize(.small); Text("Starting…") }
                case .running(let stage, let message):
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(prettyStage(stage)).font(.subheadline.weight(.medium))
                            Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                case .finished(let path, let op, let old, let new):
                    VStack(alignment: .leading, spacing: 4) {
                        Label(doneSummary(op: op, old: old, new: new), systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Text(path).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                        Text("Next step: go to Teach and fine-tune so the changes propagate through the router.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                case .failed(let reason):
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        } else {
            EmptyView()
        }
    }

    private func prettyStage(_ raw: String) -> String {
        switch raw {
        case "starting":  return "📚 Preparing"
        case "loading":   return "📖 Loading weights"
        case "detected":  return "🔍 Inspecting MoE layout"
        case "cloning":   return "🧬 Cloning experts"
        case "removing":  return "✂️ Removing experts"
        case "modifying": return "🛠 Modifying expert"
        case "writing":   return "💾 Writing new model"
        default:          return raw.capitalized
        }
    }

    private func doneSummary(op: ExpertManagementService.Op, old: Int, new: Int) -> String {
        switch op {
        case .add:    return "Done! \(old) → \(new) experts."
        case .remove: return "Done! \(old) → \(new) experts."
        case .modify: return "Done! Modified expert \(modifyIndex) of \(new)."
        }
    }

    private var buttons: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button {
                run()
            } label: {
                HStack {
                    Image(systemName: tab == .add ? "plus" : (tab == .remove ? "minus" : "slider.horizontal.3"))
                    Text(actionLabel)
                }
                .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canRun)
        }
    }

    private var actionLabel: String {
        switch tab {
        case .add:    return "Add \(addCount) experts"
        case .remove: return "Remove \(removeSelection.count) experts"
        case .modify: return "Apply \(modifyMode.displayName)"
        }
    }

    private var canRun: Bool {
        guard !outputName.isEmpty, service.active == nil else { return false }
        switch tab {
        case .add:    return addCount > 0
        case .remove: return !removeSelection.isEmpty && removeSelection.count < model.numExperts - 1
        case .modify: return modifyIndex >= 0 && modifyIndex < model.numExperts
                          && (modifyMode != .clone || modifyCloneSrc != modifyIndex)
        }
    }

    // MARK: - Banner

    private func warningBanner(_ text: String, link: URL?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let link {
                Link("Learn more →", destination: link).font(.caption2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private func regenerateOutputName(for t: Tab) {
        let suffix: String
        switch t {
        case .add:    suffix = "plus\(addCount)"
        case .remove: suffix = "minus\(removeSelection.count)"
        case .modify: suffix = "mod\(modifyIndex)-\(modifyMode.rawValue)"
        }
        outputName = "\(model.displayName)-\(suffix)"
    }

    // MARK: - Run

    private func run() {
        switch tab {
        case .add:
            service.add(input: model, outputName: outputName,
                        count: addCount,
                        srcExpert: addSourcePicker >= 0 ? addSourcePicker : nil,
                        noiseStd: addNoise)
        case .remove:
            service.remove(input: model, outputName: outputName, indices: removeSelection)
        case .modify:
            service.modify(input: model, outputName: outputName,
                           index: modifyIndex, mode: modifyMode,
                           noiseStd: modifyNoise,
                           cloneSrc: modifyMode == .clone ? modifyCloneSrc : nil)
        }
    }
}

#if DEBUG
#Preview("Manage experts") {
    ExpertManagerView(model: PreviewSupport.sampleMoEModel)
        .previewEnvironment()
}
#endif
