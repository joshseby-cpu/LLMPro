import SwiftUI

/// "Model Fusion" — pick N local models, pick a merge method, get a brand new
/// model on disk. Backed by `FusionService` → `merge_models.py` → mergekit.
///
/// Layout follows the project's "friendly first" convention: warm copy at the
/// top, a method picker with full plain-language explanations, the model
/// pickers, then any method-specific knobs (t / density / weights) inside a
/// disclosure. Progress and final-state UI lives at the bottom.
struct FusionView: View {
    @State private var registry = ModelRegistry.shared
    @State private var service = FusionService.shared

    // Selections.
    @State private var selectedRepoIDs: [String] = ["", ""]
    @State private var method: FusionService.MergeMethod = .slerp
    @State private var outputName: String = ""

    // Method-specific params.
    @State private var t: Double = 0.5
    @State private var density: Double = 0.5
    @State private var weights: [Double] = [0.5, 0.5]

    @State private var didAutoFillName = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                Divider()
                methodPicker
                Divider()
                modelPickers
                if method != .slerp || true {
                    Divider()
                    methodParams
                }
                Divider()
                outputField
                runButton
                if let active = service.active {
                    activeJobCard(active)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .padding(.top, 4)
                }
                Spacer(minLength: 20)
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .navigationTitle("Model fusion")
        .task { await registry.scan() }
        .onChange(of: method) { _, _ in
            // SLERP / TIES / DARE need exactly the right slot count. Normalize.
            normalizeSlotCount()
            regenerateAutoFillName()
        }
        .onChange(of: selectedRepoIDs) { _, _ in regenerateAutoFillName() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.merge")
                    .font(.title2)
                    .foregroundStyle(.purple)
                Text("Fuse two models into one")
                    .font(.title2.bold())
            }
            Text("Pick a few small models you already have, and combine them into a new one. The output appears as a brand-new model in your Models tab — the originals stay untouched.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Heads-up: fusion only works on full-precision models (bf16 / fp16). Quantized (4-bit / 8-bit) inputs are skipped automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
    }

    // MARK: - Method picker

    private var methodPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("How should they be merged?")
                    .font(.headline)
                HelpHint("Merge methods",
                         "Each method blends the two models' weights differently. SLERP is the safe default for blending two related models. TIES and DARE-TIES are better when you're merging task-specialised fine-tunes that might disagree about specific weights. Linear is the simplest but the bluntest.",
                         learnMore: URL(string: "https://huggingface.co/blog/mlabonne/merge-models"))
                Spacer()
            }
            Picker("", selection: $method) {
                ForEach(FusionService.MergeMethod.allCases) { m in
                    Text(m.displayName).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 6) {
                Text(method.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let url = method.learnMoreURL {
                    Link(destination: url) {
                        HStack(spacing: 4) {
                            Text("Learn more about \(method.displayName)")
                            Image(systemName: "arrow.up.right")
                        }
                        .font(.callout)
                    }
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Model pickers

    private var modelPickers: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("Which models?")
                    .font(.headline)
                HelpHint("Picking models",
                         "Only full-precision (bf16 / fp16) models show up here — mergekit can't merge quantized weights. The two models should share the same architecture; merging a Llama with a Qwen will fail.",
                         link: "https://huggingface.co/blog/mlabonne/merge-models")
                Spacer()
            }

            ForEach(Array(selectedRepoIDs.enumerated()), id: \.offset) { idx, _ in
                modelSlot(index: idx)
            }

            if method != .slerp {
                Button {
                    selectedRepoIDs.append("")
                    weights.append(1.0 / Double(selectedRepoIDs.count + 1))
                    // Re-normalize weights so they sum to 1.
                    let s = weights.reduce(0, +)
                    if s > 0 { weights = weights.map { $0 / s } }
                } label: {
                    Label("Add another model", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func modelSlot(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(roleLabel(for: index)).font(.subheadline.weight(.medium))
                Spacer()
                if selectedRepoIDs.count > method.minModels && index >= method.minModels {
                    Button {
                        selectedRepoIDs.remove(at: index)
                        if weights.count > index { weights.remove(at: index) }
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Picker("", selection: $selectedRepoIDs[index]) {
                Text("— pick a model —").tag("")
                ForEach(eligibleModels, id: \.repoID) { m in
                    HStack {
                        Text(m.displayName)
                        Text("· \(m.humanSize)")
                            .foregroundStyle(.secondary)
                    }
                    .tag(m.repoID)
                }
            }
            .labelsHidden()

            if method == .linear, weights.indices.contains(index) {
                HStack {
                    Text("Weight: \(weights[index], specifier: "%.2f")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { weights[safe: index] ?? 1.0 / Double(selectedRepoIDs.count) },
                        set: { weights[index] = $0 }
                    ), in: 0.0...1.0)
                }
            }
        }
    }

    private func roleLabel(for index: Int) -> String {
        switch method {
        case .slerp:
            return index == 0 ? "Model A (base)" : "Model B"
        case .linear:
            return "Model \(index + 1)"
        case .ties, .dare:
            return index == 0 ? "Base model" : "Donor model \(index)"
        }
    }

    private var eligibleModels: [ModelRegistry.DetectedModel] {
        registry.localModels
            .filter { $0.isMLXReady && !$0.quantization.lowercased().contains("bit") }
    }

    // MARK: - Method params

    @ViewBuilder
    private var methodParams: some View {
        switch method {
        case .slerp:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("Blend factor (t = \(t, specifier: "%.2f"))").font(.subheadline.weight(.medium))
                    HelpHint("Blend factor (t)",
                             "How much of each model ends up in the mix. t = 0.0 means the output is 100% Model A; t = 1.0 means it's 100% Model B; t = 0.5 is an even blend along the spherical geodesic between them.",
                             learnMore: URL(string: "https://huggingface.co/blog/mlabonne/merge-models#slerp"))
                    Spacer()
                }
                Slider(value: $t, in: 0.0...1.0, step: 0.05) {
                    EmptyView()
                } minimumValueLabel: {
                    Text("A").font(.caption2)
                } maximumValueLabel: {
                    Text("B").font(.caption2)
                }
            }
        case .ties, .dare:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("Density (= \(density, specifier: "%.2f"))").font(.subheadline.weight(.medium))
                    HelpHint("Density (TIES/DARE)",
                             "How much of each donor model's weight delta to keep, by magnitude. 1.0 keeps everything; 0.5 keeps the top half by absolute value; 0.2 keeps only the largest 20% (good when the donors disagree a lot). Lower density → less interference between donors, but less of each donor's specialisation survives.",
                             learnMore: URL(string: "https://arxiv.org/abs/2306.01708"))
                    Spacer()
                }
                Slider(value: $density, in: 0.1...1.0, step: 0.05)
            }
        case .linear:
            EmptyView()
        }
    }

    // MARK: - Output

    private var outputField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Save the fused model as").font(.headline)
                HelpHint("Output name",
                         "This becomes the model's name on your Mac. We auto-suggest a name from the inputs and method, but feel free to change it.",
                         link: "https://huggingface.co/blog/mlabonne/merge-models")
                Spacer()
            }
            TextField("fused-model-name", text: $outputName)
                .textFieldStyle(.roundedBorder)
            Text("Will be saved to ~/Library/Application Support/LLMPro/models/\(outputName)")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var runButton: some View {
        HStack {
            Spacer()
            Button {
                launch()
            } label: {
                HStack {
                    Image(systemName: "wand.and.stars")
                    Text("Fuse models")
                }
                .padding(.horizontal, 10)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canRun)
        }
    }

    private var canRun: Bool {
        guard !outputName.isEmpty else { return false }
        guard service.active == nil else { return false }
        let chosen = selectedRepoIDs.filter { !$0.isEmpty }
        if chosen.count < method.minModels { return false }
        if let maxN = method.maxModels, chosen.count > maxN { return false }
        return true
    }

    // MARK: - Active job card

    @ViewBuilder
    private func activeJobCard(_ active: FusionService.ActiveJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch active.stage {
            case .idle:
                HStack { ProgressView().controlSize(.small); Text("Starting…") }
            case .running(let stage, let message):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stagePrettyName(stage)).font(.subheadline.weight(.medium))
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            case .finished(let path, let bytes):
                VStack(alignment: .leading, spacing: 4) {
                    Label("Done! Fused model saved.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text(path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if bytes > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            case .failed(let reason):
                Label(reason, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func stagePrettyName(_ raw: String) -> String {
        switch raw {
        case "starting": return "📚 Getting set up"
        case "loading":  return "📖 Loading models into memory"
        case "merging":  return "⚗️ Blending weights"
        case "saving":   return "💾 Writing the fused model"
        case "tokenizer":return "✏️ Copying tokenizer"
        default:         return raw.capitalized
        }
    }

    // MARK: - Actions

    private func launch() {
        errorMessage = nil
        let chosen = selectedRepoIDs
            .compactMap { repoID -> ModelRegistry.DetectedModel? in
                registry.localModels.first(where: { $0.repoID == repoID })
            }
        guard chosen.count == selectedRepoIDs.filter({ !$0.isEmpty }).count else {
            errorMessage = "One or more selected models couldn't be located on disk."
            return
        }
        service.run(outputName: outputName,
                    method: method,
                    models: chosen,
                    t: t,
                    weights: method == .linear ? weights : [],
                    density: density)
    }

    private func normalizeSlotCount() {
        let need: Int
        if let maxN = method.maxModels {
            need = min(max(selectedRepoIDs.count, method.minModels), maxN)
        } else {
            need = max(selectedRepoIDs.count, method.minModels)
        }
        while selectedRepoIDs.count < need { selectedRepoIDs.append("") }
        while selectedRepoIDs.count > need { selectedRepoIDs.removeLast() }
        // Keep weights in sync (linear only).
        while weights.count < selectedRepoIDs.count {
            weights.append(1.0 / Double(selectedRepoIDs.count))
        }
        while weights.count > selectedRepoIDs.count { weights.removeLast() }
    }

    private func regenerateAutoFillName() {
        // Only auto-fill if the user hasn't typed anything custom.
        if !outputName.isEmpty && didAutoFillName == false { return }
        let parts = selectedRepoIDs.compactMap { id -> String? in
            guard !id.isEmpty else { return nil }
            return id.split(separator: "/").last.map(String.init) ?? id
        }
        guard parts.count >= 2 else { return }
        let suffix = method == .slerp ? "slerp" : method.rawValue
        outputName = parts.joined(separator: "+") + "-" + suffix
        didAutoFillName = true
    }
}

/// Safe-index extension used by FusionView's weight bindings.
private extension Array {
    subscript(safe i: Int) -> Element? { (i >= 0 && i < count) ? self[i] : nil }
}
