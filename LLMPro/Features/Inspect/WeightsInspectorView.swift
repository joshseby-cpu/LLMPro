import SwiftUI

/// The WEIGHTS pane: a friendly summary card up top (params, format, layers,
/// GQA/MoE flags), and the full per-tensor table + a param-by-layer bar chart
/// tucked behind a disclosure. Pure-Swift data via `WeightsInspectService`.
struct WeightsInspectorView: View {
    let model: ModelRegistry.DetectedModel
    @State private var service = WeightsInspectService()
    @State private var showDetails = false
    @State private var search = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if service.isLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading the model's blueprint…").foregroundStyle(.secondary)
                    }
                } else if let error = service.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).font(.callout)
                } else if let report = service.report {
                    summaryCard(report)
                    detailsDisclosure(report)
                }
            }
            .padding(.top, 4)
        }
        .task(id: model.repoID) { service.load(model: model) }
    }

    // MARK: Friendly summary

    private func summaryCard(_ r: ModelWeightsReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("🧠").font(.system(size: 34))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(r.paramsHuman) parameters").font(.title3.bold())
                    Text(r.dtypeSummary).font(.caption).foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], alignment: .leading, spacing: 10) {
                factTile("Layers", "\(r.numLayers)", "square.stack.3d.up")
                factTile("Attention heads", r.numHeads > 0 ? "\(r.numHeads)" : "—", "eye")
                if r.isGQA {
                    factTile("Grouped-query", "\(r.numHeads)q · \(r.numKVHeads)kv", "rectangle.3.group")
                }
                if r.isMoE {
                    factTile("Experts (MoE)", "\(r.numExperts)", "person.3")
                }
                factTile("Hidden size", r.hiddenSize > 0 ? "\(r.hiddenSize)" : "—", "ruler")
                factTile("Vocabulary", r.vocabSize > 0 ? r.vocabSize.formatted() : "—", "textformat")
                factTile("On disk", ByteCountFormatter.string(fromByteCount: Int64(r.totalBytes), countStyle: .file), "internaldrive")
                factTile("Tensors", "\(r.tensorCount)", "number")
            }
            HStack(spacing: 10) {
                if r.quantized {
                    badge("Quantized" + (r.quantBits.map { " · \($0)-bit" } ?? ""), .orange)
                } else {
                    badge("Full precision", .green)
                }
                if r.tiedEmbeddings { badge("Tied embeddings", .blue) }
                badge(r.architecture, .gray)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func factTile(_ label: String, _ value: String, _ icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    // MARK: Technical disclosure (full-width Button, not a bare DisclosureGroup)

    private func detailsDisclosure(_ r: ModelWeightsReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showDetails.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showDetails ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold)).frame(width: 12)
                    Label("Technical details — every tensor, layer by layer", systemImage: "tablecells")
                        .font(.callout)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if showDetails {
                paramByLayerChart(r)
                Divider()
                tensorTable(r)
            }
        }
        .padding(.top, 4)
    }

    /// A simple Canvas bar chart of trainable-parameter mass per layer — the
    /// "where the weight lives" picture.
    private func paramByLayerChart(_ r: ModelWeightsReport) -> some View {
        let maxP = max(1, r.layers.map(\.paramCount).max() ?? 1)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Parameters per layer").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Canvas { ctx, size in
                guard !r.layers.isEmpty else { return }
                let gap: CGFloat = 1
                let barW = max(1, (size.width - gap * CGFloat(r.layers.count - 1)) / CGFloat(r.layers.count))
                for (i, layer) in r.layers.enumerated() {
                    let h = size.height * CGFloat(layer.paramCount) / CGFloat(maxP)
                    let x = CGFloat(i) * (barW + gap)
                    let rect = CGRect(x: x, y: size.height - h, width: barW, height: h)
                    ctx.fill(Path(rect), with: .color(.accentColor.opacity(0.7)))
                }
            }
            .frame(height: 80)
            .background(Color.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            Text("\(r.layers.count) layers · tallest = most parameters")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func tensorTable(_ r: ModelWeightsReport) -> some View {
        let filtered = search.isEmpty
            ? r.tensors
            : r.tensors.filter { $0.name.localizedCaseInsensitiveContains(search) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter tensors (e.g. self_attn, layers.0, embed)", text: $search)
                    .textFieldStyle(.plain)
                Text("\(filtered.count) / \(r.tensors.count)").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(8)
            .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))

            // Header row
            HStack(spacing: 8) {
                Text("Tensor").frame(maxWidth: .infinity, alignment: .leading)
                Text("Shape").frame(width: 150, alignment: .leading)
                Text("Type").frame(width: 50, alignment: .leading)
                Text("Params").frame(width: 80, alignment: .trailing)
            }
            .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)

            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(filtered.prefix(500)) { t in
                    HStack(spacing: 8) {
                        Text(t.name).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(t.shapeText).font(.caption.monospaced()).foregroundStyle(.secondary)
                            .frame(width: 150, alignment: .leading).lineLimit(1)
                        Text(t.dtype).font(.caption.monospaced()).foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .leading)
                        Text(t.paramCount.formatted()).font(.caption.monospaced()).foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .trailing)
                    }
                    .padding(.vertical, 3)
                    Divider().opacity(0.3)
                }
                if filtered.count > 500 {
                    Text("… and \(filtered.count - 500) more (filter to narrow)")
                        .font(.caption2).foregroundStyle(.secondary).padding(.top, 4)
                }
            }
        }
    }
}
