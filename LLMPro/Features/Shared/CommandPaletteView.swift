import SwiftUI

/// ⌘K command palette — type a few letters, hit return, land anywhere in the
/// app. Ranks tab jumps and quick actions by a simple prefix-then-contains
/// match. Opened from the app menu (or ⌘K) via the `.openCommandPalette`
/// notification RootView listens for.
struct CommandPaletteView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private struct PaletteItem: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let icon: String
        let target: SidebarSection
    }

    private static let items: [PaletteItem] = [
        .init(id: "home", title: "Home", subtitle: "Checklist, activity, quick actions", icon: "house", target: .dashboard),
        .init(id: "models", title: "Models", subtitle: "Download, compare, export", icon: "cube.box", target: .models),
        .init(id: "lessons", title: "Lessons", subtitle: "Datasets — create, edit, check", icon: "books.vertical", target: .datasets),
        .init(id: "teach", title: "Teach", subtitle: "Start a fine-tune", icon: "graduationcap", target: .training),
        .init(id: "progress", title: "Progress", subtitle: "Watch training, past lessons", icon: "chart.line.uptrend.xyaxis", target: .monitor),
        .init(id: "chatDirect", title: "Chat", subtitle: "Talk to any local model", icon: "message", target: .chatDirect),
        .init(id: "story", title: "Story", subtitle: "Write long-form stories, chapter by chapter", icon: "book.closed", target: .story),
        .init(id: "chat", title: "Try it out", subtitle: "Arena compare, score it", icon: "bubble.left.and.bubble.right", target: .chat),
        .init(id: "code", title: "Code", subtitle: "Agentic coding with your model", icon: "chevron.left.forwardslash.chevron.right", target: .code),
        .init(id: "practice", title: "Practice", subtitle: "Automated self-improvement", icon: "arrow.triangle.2.circlepath", target: .selfImprove),
        .init(id: "fusion", title: "Fusion", subtitle: "Merge models", icon: "arrow.triangle.merge", target: .fusion),
        .init(id: "memory", title: "Memory", subtitle: "Agent memory", icon: "memorychip", target: .memory),
        .init(id: "inspect", title: "Inspect", subtitle: "Weights, attention, reasoning", icon: "scope", target: .inspect),
        .init(id: "export", title: "Save & Use", subtitle: "GGUF, cloud, Ollama, model cards", icon: "square.and.arrow.up", target: .export),
        .init(id: "settings", title: "Settings", subtitle: "Runtime, storage, logs", icon: "gearshape", target: .settings),
    ]

    private var matches: [PaletteItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return Self.items }
        let scored = Self.items.compactMap { item -> (PaletteItem, Int)? in
            let title = item.title.lowercased()
            if title.hasPrefix(q) { return (item, 0) }
            if title.contains(q) { return (item, 1) }
            if item.subtitle.lowercased().contains(q) { return (item, 2) }
            return nil
        }
        return scored.sorted { $0.1 < $1.1 }.map(\.0)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Jump to…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
                    .onSubmit { if let first = matches.first { go(first) } }
            }
            .padding(12)
            Divider()
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, item in
                        Button { go(item) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: item.icon)
                                    .frame(width: 22)
                                    .foregroundStyle(index == 0 && !query.isEmpty ? Color.brand : .secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title).font(.body)
                                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if index == 0 && !query.isEmpty {
                                    Text("↩").font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(index == 0 && !query.isEmpty ? Color.brand.opacity(0.08) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 440)
        .onAppear { searchFocused = true }
    }

    private func go(_ item: PaletteItem) {
        dismiss()
        NotificationCenter.default.post(name: .switchSidebar, object: item.target)
    }
}

extension Notification.Name {
    static let openCommandPalette = Notification.Name("LLMPro.openCommandPalette")
}
