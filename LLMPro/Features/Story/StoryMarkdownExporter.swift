import AppKit
import UniformTypeIdentifiers

/// Export a Story project to a single Markdown file (title, premise, and every
/// chapter). Any generated illustrations are copied next to the `.md` into a
/// `<stem>_images/` folder and referenced with relative `![](…)` links, so the
/// export is self-contained. Saved via NSSavePanel.
@MainActor
enum StoryMarkdownExporter {
    /// `imageDirName` is the relative folder the images are copied into; pass nil to
    /// omit image links (e.g. a story with no illustrations).
    static func markdown(project: StoryProject, imageDirName: String? = nil) -> String {
        var out = "# \(project.isUntitled ? "Untitled story" : project.title)\n\n"
        if !project.genre.isEmpty { out += "*\(project.genre)*\n\n" }
        if !project.premise.isEmpty { out += "> \(project.premise)\n\n" }
        for ch in project.chapters {
            out += "## \(ch.title)\n\n\(ch.text)\n\n"
            if let imageDirName {
                for illo in ch.illustrations {
                    out += "![\(altText(illo.prompt))](\(imageDirName)/\(illo.file))\n\n"
                }
            }
        }
        return out
    }

    static func exportWithPanel(project: StoryProject) {
        let hasImages = project.chapters.contains { !$0.illustrations.isEmpty }
        let panel = NSSavePanel()
        let stem = (project.isUntitled ? "story" : project.title)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(stem).md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let imageDirName = hasImages ? "\(url.deletingPathExtension().lastPathComponent)_images" : nil
        let md = markdown(project: project, imageDirName: imageDirName)
        try? md.write(to: url, atomically: true, encoding: .utf8)

        if let imageDirName {
            let srcDir = PathResolver.storyImagesDir(for: project.id)
            let destDir = url.deletingLastPathComponent().appendingPathComponent(imageDirName)
            try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            for ch in project.chapters {
                for illo in ch.illustrations {
                    let src = srcDir.appendingPathComponent(illo.file)
                    guard FileManager.default.fileExists(atPath: src.path) else { continue }
                    let dest = destDir.appendingPathComponent(illo.file)
                    try? FileManager.default.removeItem(at: dest)
                    try? FileManager.default.copyItem(at: src, to: dest)
                }
            }
        }
    }

    /// Single-line, bracket-safe alt text for a Markdown image link.
    private static func altText(_ prompt: String) -> String {
        prompt
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")")
            .trimmingCharacters(in: .whitespaces)
    }
}
