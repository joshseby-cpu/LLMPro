import SwiftUI

struct ModelDetailView: View {
    let model: HFModel
    @Environment(PythonRuntime.self) private var runtime
    @State private var detail: HFModelDetail?
    @State private var totalSize: Int64 = 0
    @State private var loading = true
    @State private var error: String?
    @State private var quantChoice: ConversionQuant = .q4
    @State private var converting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                if loading { ProgressView("Loading…") }
                if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                if let detail { detailSection(detail) }
                actionBar
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: model.id) {
            await load()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.repoID).font(.title2).bold().textSelection(.enabled)
            HStack(spacing: 12) {
                if let d = model.downloads { Label("\(d.formatted())", systemImage: "arrow.down.circle") }
                if let l = model.likes { Label("\(l)", systemImage: "heart") }
                if let lm = model.lastModified { Label(lm, systemImage: "clock") }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func detailSection(_ detail: HFModelDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if totalSize > 0 {
                Label("≈ \(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)) total",
                      systemImage: "externaldrive")
                    .font(.callout)
            }
            if let lib = detail.library_name { Text("Library: \(lib)").font(.caption).foregroundStyle(.secondary) }
            if let tags = detail.tags, !tags.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(tags.prefix(20), id: \.self) { tag in
                        Text(tag).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    Task { await DownloadService.shared.download(repoID: model.repoID) }
                } label: { Label("Download", systemImage: "arrow.down.circle.fill") }
                    .keyboardShortcut("d", modifiers: [.command])
                    .disabled(!runtime.isReady)

                Button {
                    NotificationCenter.default.post(name: .openTrainingWithModel, object: model.repoID)
                } label: { Label("Use for training", systemImage: "play.rectangle") }

                Button {
                    NotificationCenter.default.post(name: .openChatWithModel, object: model.repoID)
                } label: { Label("Open in Chat", systemImage: "bubble.left") }
            }
            if !model.isMLXCommunity {
                HStack {
                    Text("Not MLX-converted. Convert after download:").font(.caption)
                    Picker("", selection: $quantChoice) {
                        ForEach(ConversionQuant.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().frame(width: 220)
                    Button("Convert") {
                        converting = true
                        Task {
                            defer { Task { @MainActor in converting = false } }
                            let dest = PathResolver.modelsCustomDir
                                .appendingPathComponent(model.shortName + "-mlx", isDirectory: true).path
                            try? await ConversionService.shared.convert(hfRepoID: model.repoID, quant: quantChoice, mlxPath: dest)
                            await ModelRegistry.shared.scan()
                        }
                    }
                    .disabled(converting)
                }
                .padding(.top, 8)
            }
        }
    }

    private func load() async {
        loading = true; error = nil
        do {
            let d = try await HuggingFaceClient.shared.detail(repoID: model.repoID)
            let size = (try? await HuggingFaceClient.shared.resolveTotalSize(repoID: model.repoID)) ?? 0
            await MainActor.run {
                self.detail = d
                self.totalSize = size
                self.loading = false
            }
        } catch {
            await MainActor.run {
                self.error = error.localizedDescription
                self.loading = false
            }
        }
    }
}

extension Notification.Name {
    static let openTrainingWithModel = Notification.Name("LLMPro.openTrainingWithModel")
    static let openChatWithModel = Notification.Name("LLMPro.openChatWithModel")
}

// Minimal FlowLayout for tag chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
