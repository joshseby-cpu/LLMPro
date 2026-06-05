import SwiftUI
import AppKit

// Multi-line chat input where plain Return SENDS and Shift+Return inserts a
// newline — the behavior the user expects from a chat box. SwiftUI's TextEditor
// can't intercept Return cleanly, so we wrap an NSTextView and catch
// `insertNewline:` in the delegate.

struct ChatInputView: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.font = .systemFont(ofSize: 13)
        tv.drawsBackground = false
        tv.textColor = .labelColor
        tv.insertionPointColor = .labelColor
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.string = text
        context.coordinator.textView = tv
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = nsView.documentView as? NSTextView else { return }
        // External change (e.g. cleared after send) → sync down.
        if tv.string != text { tv.string = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatInputView
        weak var textView: NSTextView?

        init(_ parent: ChatInputView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let shiftHeld = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                if shiftHeld {
                    textView.insertNewlineIgnoringFieldEditor(nil)   // Shift+Return → newline
                    return true
                }
                parent.onSubmit()                                    // Return → send
                return true
            }
            return false
        }
    }
}

#if DEBUG
#Preview("Chat input") {
    ChatInputView(text: .constant("Ask the team to build a feature…"), onSubmit: {})
        .previewEnvironment()
}
#endif
