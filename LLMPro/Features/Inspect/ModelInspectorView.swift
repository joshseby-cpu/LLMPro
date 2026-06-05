import SwiftUI

/// The "Inspect" tab — look inside any local model three ways: its **Weights**
/// (pure-Swift safetensors parse), what it **Pays attention to** (a one-forward
/// MLX capture), and its **Thinking** (live reasoning/answer split). This file is
/// the friendly-first shell: a model picker + a 3-way segmented control hosting
/// the three panes. All real work lives in the per-pane services/views.
struct ModelInspectorView: View {
    @State private var registry = ModelRegistry.shared
    @State private var selectedRepoID: String?
    @State private var mode: Mode = .weights

    enum Mode: String, CaseIterable, Identifiable {
        case weights, attention, thinking
        var id: String { rawValue }
        var title: String {
            switch self {
            case .weights:   "Weights"
            case .attention: "Attention"
            case .thinking:  "Thinking"
            }
        }
        var icon: String {
            switch self {
            case .weights:   "square.stack.3d.up"
            case .attention: "eye"
            case .thinking:  "brain"
            }
        }
    }

    private var selectedModel: ModelRegistry.DetectedModel? {
        guard let id = selectedRepoID else { return nil }
        return registry.localModels.first { $0.repoID == id }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                header
                if registry.localModels.isEmpty {
                    emptyState
                } else {
                    modelPicker
                    modePicker
                    Divider()
                    pane
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle("Look inside your model")
            .task {
                await registry.scan()
                if selectedRepoID == nil { selectedRepoID = registry.localModels.first?.repoID }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("See what's inside.")
                .font(.title2.bold())
            Text("Peek at a model's building blocks, what it focuses on, and how it thinks — no ML background needed.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "cube.box").font(.title2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("No models on this Mac yet").font(.headline)
                Text("Open the Models tab and download one, then come back to look inside it.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var modelPicker: some View {
        HStack(spacing: 8) {
            Image(systemName: "cube.box.fill").foregroundStyle(.secondary)
            Picker("Model", selection: $selectedRepoID) {
                ForEach(registry.localModels) { m in
                    Text("\(m.displayName)  ·  \(m.humanSize)").tag(Optional(m.repoID))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 440, alignment: .leading)
        }
    }

    private var modePicker: some View {
        Picker("View", selection: $mode) {
            ForEach(Mode.allCases) { m in
                Label(m.title, systemImage: m.icon).tag(m)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 460)
    }

    @ViewBuilder
    private var pane: some View {
        if let model = selectedModel {
            switch mode {
            case .weights:   WeightsInspectorView(model: model)
            case .attention: AttentionInspectorView(model: model)
            case .thinking:  CoTInspectorView(model: model)
            }
        }
    }
}

#if DEBUG
#Preview("Inspect") {
    ModelInspectorView().previewEnvironment()
}
#endif
