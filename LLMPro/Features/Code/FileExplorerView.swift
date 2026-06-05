import SwiftUI

// Project file tree for the Code tab's left pane. Builds a bounded tree of the
// workspace (skipping VCS/build/dependency dirs), lets the user click a file to
// open it in the editor, and exposes `refresh()` so it re-scans after the agent
// writes files. Pure SwiftUI — OutlineGroup gives native expand/collapse.

struct FileNode: Identifiable, Hashable {
    let id: String          // absolute path
    let url: URL
    let name: String
    let isDirectory: Bool
    var children: [FileNode]?

    static let ignored: Set<String> = [
        ".git", "node_modules", "bin", "obj", ".build", "DerivedData",
        ".venv", "venv", "Pods", ".next", "dist", "build", "target", ".idea", ".vs"
    ]

    static func tree(at url: URL, depth: Int = 0) -> [FileNode] {
        guard depth < 9,
              let items = try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }
        let sorted = items
            .filter { !ignored.contains($0.lastPathComponent) }
            .sorted { a, b in
                let ad = (try? a.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let bd = (try? b.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if ad != bd { return ad }                 // directories first
                return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
            }
        return sorted.map { item in
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return FileNode(
                id: item.path, url: item, name: item.lastPathComponent, isDirectory: isDir,
                children: isDir ? tree(at: item, depth: depth + 1) : nil)
        }
    }
}

struct FileExplorerView: View {
    let root: URL
    @Binding var selection: URL?
    /// Bumping this from the parent (after agent edits) triggers a re-scan.
    var refreshToken: Int = 0

    @State private var nodes: [FileNode] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill").foregroundStyle(.tint)
                Text(root.lastPathComponent).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer()
                Button { nodes = FileNode.tree(at: root) } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh")
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            Divider()

            List {
                if nodes.isEmpty {
                    Text("Empty folder").font(.caption).foregroundStyle(.secondary)
                } else {
                    OutlineGroup(nodes, children: \.children) { node in
                        row(node)
                    }
                }
            }
            .listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, 24)
        }
        .onChange(of: refreshToken) { _, _ in nodes = FileNode.tree(at: root) }
        .onChange(of: root) { _, _ in selection = nil; nodes = FileNode.tree(at: root) }
        .task { nodes = FileNode.tree(at: root) }
    }

    @ViewBuilder
    private func row(_ node: FileNode) -> some View {
        if node.isDirectory {
            Label(node.name, systemImage: "folder")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Button { selection = node.url } label: {
                Label(node.name, systemImage: icon(for: node.name))
                    .font(.callout)
                    .foregroundStyle(selection == node.url ? Color.accentColor : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func icon(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "swift": return "swift"
        case "json": return "curlybraces"
        case "md", "markdown": return "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "svg", "ico", "webp": return "photo"
        case "cs", "py", "js", "jsx", "ts", "tsx", "go", "rs", "java", "kt", "rb", "cpp", "c", "h":
            return "chevron.left.forwardslash.chevron.right"
        case "html", "htm", "razor", "cshtml", "xml", "csproj", "vue", "svelte": return "chevron.left.slash.chevron.right"
        case "css", "scss", "sass", "less": return "paintbrush"
        case "sh", "bash", "zsh": return "terminal"
        case "yml", "yaml", "toml", "lock", "config", "ini": return "gearshape"
        default: return "doc.text"
        }
    }
}

#if DEBUG
#Preview("File explorer") {
    FileExplorerView(root: PreviewSupport.sampleWorkspace, selection: .constant(nil))
        .previewEnvironment()
}
#endif
