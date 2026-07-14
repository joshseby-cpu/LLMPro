import AppKit
import UniformTypeIdentifiers

/// Export a Story project to a single Markdown file (title, premise, and every
/// chapter). Saved via NSSavePanel.
@MainActor
enum StoryMarkdownExporter {
    static func markdown(project: StoryProject) -> String {
        var out = "# \(project.isUntitled ? "Untitled story" : project.title)\n\n"
        if !project.genre.isEmpty { out += "*\(project.genre)*\n\n" }
        if !project.premise.isEmpty { out += "> \(project.premise)\n\n" }
        for ch in project.chapters {
            out += "## \(ch.title)\n\n\(ch.text)\n\n"
        }
        return out
    }

    static func exportWithPanel(project: StoryProject) {
        let md = markdown(project: project)
        let panel = NSSavePanel()
        let stem = (project.isUntitled ? "story" : project.title)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(stem).md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? md.write(to: url, atomically: true, encoding: .utf8)
    }
}
