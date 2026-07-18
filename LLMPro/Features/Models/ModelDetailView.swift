import SwiftUI

/// Details for a HuggingFace search result, shown in a sheet from the Models
/// browser. Leads with the size + a RAM-fit verdict, a clean metadata row, and a
/// clear Download CTA; raw HF bookkeeping tags (`region:…`, `base_model:…`,
/// `arxiv:…`) are filtered out so only meaningful tags show.
struct ModelDetailSheet: View {
    let model: HFModel
    /// Pre-fetched by the result card so the size shows instantly; re-resolved here
    /// if the caller didn't have it yet.
    var sizeBytes: Int64?
    /// Triggers the GGUF download-&-convert combo (owned by the browser so its
    /// progress banner can track it). Nil for non-GGUF.
    var onConvert: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(PythonRuntime.self) private var runtime
    @State private var detail: HFModelDetail?
    @State private var totalSize: Int64 = 0
    @State private var loading = true
    @State private var error: String?
    @State private var quantChoice: ConversionQuant = .q4
    @State private var converting = false

    private var effectiveSize: Int64 { totalSize > 0 ? totalSize : (sizeBytes ?? 0) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.shortName).font(.title3.bold()).lineLimit(1)
                if model.isMLXCommunity { mlxBadge }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(model.repoID).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    metaRow
                    if model.isGGUF { ggufBanner }
                    sizeCard
                    if loading { ProgressView("Loading details…").frame(maxWidth: .infinity) }
                    if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                    if let detail { tagsSection(detail) }
                    // `mlx_lm convert` reads HF safetensors, not GGUF — the GGUF
                    // banner already points to Import GGUF, so hide this for GGUF.
                    if !model.isMLXCommunity && !model.isGGUF { convertRow }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            actionBar.padding(16)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 460)
        .task(id: model.id) { await load() }
    }

    private var mlxBadge: some View {
        Text("MLX").font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.brand.opacity(0.18), in: Capsule())
            .foregroundStyle(Color.brand)
    }

    /// Why a GGUF download "doesn't show up" — the #1 model-download confusion.
    @ViewBuilder
    private var ggufBanner: some View {
        let convertible = model.isConvertibleGGUF
        VStack(alignment: .leading, spacing: 6) {
            Label(convertible ? "GGUF model — convert it to use it here"
                              : "GGUF image/video model — can’t run in LLMPro",
                  systemImage: convertible ? "wand.and.stars" : "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(convertible ? Color.brand : .orange)
            if convertible {
                Text("LLMPro runs **MLX** models, so a raw GGUF download stays invisible. **Download & convert** grabs just the **Q8_0** quant (~8 GB, not the whole repo) and turns it into a usable MLX model.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("This is a diffusion **image/video** model (FLUX, WAN, SDXL, …). LLMPro only runs **MLX language models** — there’s no way to convert this to run here.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background((convertible ? Color.brand : Color.orange).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder((convertible ? Color.brand : Color.orange).opacity(0.35)))
    }

    private var metaRow: some View {
        HStack(spacing: 14) {
            if let d = model.downloads {
                Label(d.formatted(.number.notation(.compactName)), systemImage: "arrow.down.circle")
            }
            if let l = model.likes, l > 0 { Label("\(l)", systemImage: "heart") }
            if let updated = friendlyDate { Label(updated, systemImage: "clock") }
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var sizeCard: some View {
        let bytes = effectiveSize
        HStack(spacing: 10) {
            Image(systemName: "internaldrive")
                .font(.title2).foregroundStyle(Color.brand)
            VStack(alignment: .leading, spacing: 2) {
                if bytes > 0 {
                    Text("≈ \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) to download")
                        .font(.headline)
                    fitVerdict(bytes)
                } else {
                    Text("Fetching download size…").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .card(padding: 12)
    }

    @ViewBuilder
    private func fitVerdict(_ bytes: Int64) -> some View {
        let ram = ByteCountFormatter.string(fromByteCount: ModelFit.physicalRAM, countStyle: .memory)
        if ModelFit.fits(weightBytes: bytes) {
            Label("Runs on your Mac (\(ram) of memory)", systemImage: "checkmark.seal.fill")
                .font(.caption).foregroundStyle(.green)
        } else {
            Label("Too large for your \(ram) of memory — pick a smaller or 4-bit model",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func tagsSection(_ detail: HFModelDetail) -> some View {
        let tags = curatedTags(detail.tags ?? [])
        if !tags.isEmpty || detail.library_name != nil {
            VStack(alignment: .leading, spacing: 8) {
                Text("About").font(.headline)
                if let lib = detail.library_name {
                    Label("Runs with \(lib)", systemImage: "shippingbox").font(.caption).foregroundStyle(.secondary)
                }
                if let lic = detail.cardData?.license {
                    Label("License: \(lic)", systemImage: "doc.text").font(.caption).foregroundStyle(.secondary)
                }
                if !tags.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(tags, id: \.self) { tag in
                            Text(tag).font(.caption2)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.primary.opacity(0.06), in: Capsule())
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var convertRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Not MLX-ready — convert it after downloading", systemImage: "wand.and.stars")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
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
        }
        .card(padding: 12)
    }

    @ViewBuilder
    private var actionBar: some View {
        if model.isConvertibleGGUF {
            VStack(spacing: 8) {
                Button {
                    onConvert?(); dismiss()
                } label: {
                    Label("Download & convert to MLX", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.brand)
                .disabled(!runtime.isReady || onConvert == nil)
                Button {
                    Task { await DownloadService.shared.download(repoID: model.repoID) }
                    dismiss()
                } label: {
                    Label("Download raw GGUF files only", systemImage: "arrow.down.circle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .help("Downloads the raw GGUF files (won't appear in your models unless converted).")
            }
        } else if model.isGGUF {
            // Image/video GGUF — a raw download can't run and can't be converted.
            Button {
                Task { await DownloadService.shared.download(repoID: model.repoID) }
                dismiss()
            } label: {
                Label("Download raw files anyway", systemImage: "arrow.down.circle").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!runtime.isReady)
            .help("Downloads the GGUF files to LLMPro's cache. They won't appear in your models.")
        } else {
            HStack(spacing: 10) {
                Button {
                    Task { await DownloadService.shared.download(repoID: model.repoID) }
                    dismiss()
                } label: {
                    Label("Download", systemImage: "arrow.down.circle.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.brand)
                .keyboardShortcut("d", modifiers: [.command])
                .disabled(!runtime.isReady)

                Button {
                    NotificationCenter.default.post(name: .openTrainingWithModel, object: model.repoID)
                    dismiss()
                } label: { Label("Teach", systemImage: "graduationcap") }

                Button {
                    NotificationCenter.default.post(name: .openChatWithModel, object: model.repoID)
                    dismiss()
                } label: { Label("Chat", systemImage: "bubble.left") }
            }
        }
    }

    // MARK: - Data + formatting

    private var friendlyDate: String? {
        guard let raw = model.lastModified else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = iso.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        guard let date else { return nil }
        let f = DateFormatter()
        f.dateFormat = "MMM yyyy"
        return "Updated \(f.string(from: date))"
    }

    /// Keep only human-meaningful tags — drop HF bookkeeping (`region:`,
    /// `base_model:`, `arxiv:`, `doi:`, `license:` [shown separately], `dataset:`).
    private func curatedTags(_ tags: [String]) -> [String] {
        let dropPrefixes = ["region:", "base_model:", "arxiv:", "doi:", "license:",
                            "dataset:", "co2_eq", "endpoints_compatible", "autotrain"]
        return tags
            .filter { tag in !dropPrefixes.contains { tag.hasPrefix($0) } }
            .prefix(10)
            .map { $0 }
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

#if DEBUG
#Preview("Model detail") {
    ModelDetailSheet(model: PreviewSupport.sampleHFModel, sizeBytes: 1_800_000_000)
        .previewEnvironment()
}
#endif
