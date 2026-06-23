import AppKit
import UniformTypeIdentifiers

/// Export a Try-it-out conversation (one or both arena columns) to a Markdown
/// file — handy for sharing a model's answers, filing a bug, or seeding a dataset
/// by hand. Pure read of `ChatSession.messages`; the file is written via an
/// NSSavePanel so the user picks where it lands. `@MainActor` because
/// `ChatSession` is main-actor-isolated.
@MainActor
enum ConversationMarkdownExporter {

    static func markdown(title: String, sessions: [ChatSession]) -> String {
        var out = "# \(title)\n\n"
        for session in sessions where session.messages.contains(where: { !$0.text.isEmpty }) {
            out += "## \(session.label)\n\n"
            var meta = "Model: `\(session.model)`"
            if let a = session.adapterPath, !a.isEmpty { meta += " · Adapter: `\(a)`" }
            meta += " · temp \(String(format: "%.2f", session.params.temperature))"
            meta += ", top-p \(String(format: "%.2f", session.params.topP))"
            out += "_\(meta)_\n\n"
            for m in session.messages where !m.text.isEmpty {
                let who: String = {
                    switch m.role {
                    case .user:      return "🧑 User"
                    case .assistant: return "🤖 Assistant"
                    case .system:    return "⚙️ System"
                    }
                }()
                out += "**\(who)**\n\n\(m.text)\n\n---\n\n"
            }
        }
        return out
    }

    /// True if any of the given sessions has content worth exporting.
    static func hasContent(_ sessions: [ChatSession]) -> Bool {
        sessions.contains { $0.messages.contains(where: { !$0.text.isEmpty }) }
    }

    @MainActor
    static func exportWithPanel(title: String, suggestedName: String, sessions: [ChatSession]) {
        let md = markdown(title: title, sessions: sessions)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? md.write(to: url, atomically: true, encoding: .utf8)
    }
}
