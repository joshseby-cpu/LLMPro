import SwiftUI
import AppKit

/// A plain-text editor for raw Markdown (agent + skill SKILL.md / .md files).
///
/// SwiftUI's `TextEditor` inherits NSTextView's automatic text substitutions, so
/// typing `---` becomes `—` (em-dash) and `"x"` becomes `"x"` (smart quotes) —
/// which silently corrupts YAML frontmatter fences and any code in the body. This
/// wrapper is an NSTextView with ALL automatic substitution turned off, so what
/// the user types is exactly what gets saved. Monospaced to match the editors.
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let tv = scroll.documentView as? NSTextView else { return scroll }

        // The whole point: no smart dashes / quotes / text replacement.
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isRichText = false

        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.isEditable = true
        tv.isSelectable = true
        tv.allowsUndo = true
        tv.delegate = context.coordinator
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        // Only push external changes (e.g. loading a different file) into the view;
        // never stomp the user's in-progress edit (which already matches `text`).
        if tv.string != text { tv.string = text }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: MarkdownEditor
        init(_ parent: MarkdownEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }
}
