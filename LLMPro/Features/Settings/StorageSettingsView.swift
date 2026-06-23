import SwiftUI

/// "Storage" — where LLMPro's disk goes, with safe cleanup. Surfaced as a tab in
/// Settings. Shows a per-category breakdown (downloaded models, training runs,
/// datasets, exports, the Python runtime, …) with sizes, a free-space readout, and
/// a one-click clear for the regenerable categories (exports / logs / llama.cpp
/// build). User data (models / adapters / datasets) is reveal-only here — those
/// have dedicated delete UIs in their own tabs.
struct StorageSettingsView: View {
    @State private var storage = StorageService.shared
    @State private var clearTarget: StorageService.Category?

    private static let fmt: ByteCountFormatter = {
        let f = ByteCountFormatter(); f.countStyle = .file; return f
    }()
    private func human(_ bytes: Int64) -> String { Self.fmt.string(fromByteCount: bytes) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !storage.categories.isEmpty { proportionBar }
            List {
                ForEach(storage.categories) { cat in row(cat) }
            }
            .listStyle(.inset)
        }
        .padding(.vertical, 4)
        .task { if storage.categories.isEmpty { await storage.scan() } }
        .alert("Clear these files?", isPresented: clearPresented, presenting: clearTarget) { cat in
            Button("Clear", role: .destructive) { Task { await storage.clear(cat) } }
            Button("Cancel", role: .cancel) {}
        } message: { cat in
            Text("Deletes the contents of “\(cat.name)” (\(human(cat.bytes))). \(cat.hint)")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Used by LLMPro: \(human(storage.totalBytes))").font(.headline)
                if storage.freeBytes > 0 {
                    Text("\(human(storage.freeBytes)) free on disk").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                Task { await storage.scan() }
            } label: {
                if storage.scanning {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Scanning…") }
                } else {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
            }
            .disabled(storage.scanning)
        }
    }

    /// A thin proportional bar showing each category's share of the total.
    private var proportionBar: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(storage.categories.filter { $0.bytes > 0 }) { cat in
                    Rectangle()
                        .fill(color(for: cat.id))
                        .frame(width: max(2, geo.size.width * widthFraction(cat)))
                        .help("\(cat.name): \(human(cat.bytes))")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .frame(height: 14)
    }

    private func widthFraction(_ cat: StorageService.Category) -> CGFloat {
        guard storage.totalBytes > 0 else { return 0 }
        return CGFloat(Double(cat.bytes) / Double(storage.totalBytes))
    }

    private func row(_ cat: StorageService.Category) -> some View {
        HStack(spacing: 12) {
            Image(systemName: cat.icon).foregroundStyle(color(for: cat.id)).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(cat.name).font(.body)
                    if cat.itemCount > 0 {
                        Text("\(cat.itemCount) item\(cat.itemCount == 1 ? "" : "s")")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(cat.hint).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(human(cat.bytes)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([cat.url])
            } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless).help("Reveal in Finder")
            if cat.clearable {
                Button(role: .destructive) { clearTarget = cat } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .disabled(cat.bytes == 0)
                    .help("Clear (safe — regenerable)")
            }
        }
        .padding(.vertical, 2)
    }

    private var clearPresented: Binding<Bool> {
        Binding(get: { clearTarget != nil }, set: { if !$0 { clearTarget = nil } })
    }

    /// Stable per-category colors for the bar + row icons.
    private func color(for id: String) -> Color {
        switch id {
        case "hf":             return .blue
        case "models":         return .brand
        case "adapters":       return .green
        case "datasets":       return .orange
        case "selfimprove":    return .teal
        case "exports":        return .purple
        case "evals":          return .pink
        case "llamacpp-build": return .gray
        case "logs":           return .secondary
        case "runtime":        return .indigo
        default:               return .secondary
        }
    }
}

#if DEBUG
#Preview("Storage") { StorageSettingsView().frame(width: 600, height: 460) }
#endif
