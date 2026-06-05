import SwiftUI

/// The ATTENTION pane: type a short prompt, run one forward pass through the model
/// (via the `inspect_attention.py` sidecar), and see a heatmap of what each
/// position attends to. Friendly mean-over-heads heatmap leads; the per-layer grid
/// sits behind a disclosure. Scoped hard (short prompt, mean-over-heads) to respect
/// the Metal memory ceiling.
struct AttentionInspectorView: View {
    let model: ModelRegistry.DetectedModel
    @State private var service = AttentionInspectService()
    @State private var prompt = "def add(a, b):"
    @State private var showLayers = false
    @State private var selectedLayer = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                promptRow
                if service.isRunning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(service.statusLine.isEmpty ? "Running one forward pass…" : service.statusLine)
                            .foregroundStyle(.secondary)
                    }
                } else if service.unsupported {
                    unsupportedCard
                } else if let error = service.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).font(.callout)
                } else if !service.layers.isEmpty {
                    resultView
                } else {
                    hint
                }
            }
            .padding(.top, 4)
        }
    }

    private var promptRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Give it a short prompt and watch where it looks.")
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("A short prompt…", text: $prompt)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 420)
                Button {
                    service.run(model: model, prompt: prompt)
                } label: {
                    Label("Peek inside", systemImage: "eye")
                }
                .buttonStyle(.borderedProminent)
                .disabled(service.isRunning || prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                if service.isRunning {
                    Button("Stop") { service.cancel() }
                }
            }
            if service.truncated {
                Text("Prompt was shortened to keep memory in check (attention grows with the square of length).")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var hint: some View {
        Text("Tip: keep the prompt short (a line or two). Brighter cells = stronger attention from that row's token to that column's token.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private var unsupportedCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "questionmark.circle").font(.title2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("Attention view isn't available for this architecture yet").font(.headline)
                Text("This model computes attention in a way the inspector can't tap into (e.g. a linear-attention or fused variant). The Weights and Thinking views still work.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var resultView: some View {
        let layerToShow = min(selectedLayer, service.layers.count - 1)
        VStack(alignment: .leading, spacing: 10) {
            Text("What it pays attention to")
                .font(.headline)
            Text(showLayers ? "Layer \(layerToShow) of \(service.layers.count - 1) · averaged over heads"
                            : "Last layer · averaged over heads")
                .font(.caption).foregroundStyle(.secondary)

            AttentionHeatmap(
                matrix: showLayers ? service.layers[layerToShow] : (service.layers.last ?? []),
                tokens: service.tokens
            )
            .frame(maxWidth: 520)

            // Disclosure: pick a specific layer.
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showLayers.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showLayers ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold)).frame(width: 12)
                    Label("Browse layers", systemImage: "square.stack.3d.up")
                        .font(.callout)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if showLayers, service.layers.count > 1 {
                HStack(spacing: 10) {
                    Text("Layer \(layerToShow)").font(.caption.monospaced()).frame(width: 70, alignment: .leading)
                    Slider(value: Binding(
                        get: { Double(layerToShow) },
                        set: { selectedLayer = Int($0.rounded()) }
                    ), in: 0...Double(service.layers.count - 1), step: 1)
                }
            }
        }
    }
}

/// Renders one seq×seq attention matrix as a Canvas heatmap with token labels.
private struct AttentionHeatmap: View {
    let matrix: [[Float]]
    let tokens: [String]

    var body: some View {
        if matrix.isEmpty {
            Text("No attention captured.").font(.caption).foregroundStyle(.secondary)
        } else {
            let n = matrix.count
            VStack(alignment: .leading, spacing: 4) {
                Canvas { ctx, size in
                    let cell = min(size.width, size.height) / CGFloat(n)
                    for r in 0..<n {
                        let row = matrix[r]
                        for c in 0..<min(n, row.count) {
                            let v = CGFloat(max(0, min(1, row[c])))
                            let rect = CGRect(x: CGFloat(c) * cell, y: CGFloat(r) * cell, width: cell, height: cell)
                            // Dark→bright accent ramp.
                            ctx.fill(Path(rect), with: .color(Color.accentColor.opacity(0.08 + 0.92 * v)))
                        }
                    }
                }
                .frame(width: 340, height: 340)
                .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

                if !tokens.isEmpty {
                    Text("Tokens: " + tokens.prefix(n).joined(separator: " · "))
                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

#if DEBUG
#Preview("Attention") {
    AttentionInspectorView(model: PreviewSupport.sampleDetectedModel)
        .previewEnvironment()
}
#endif
