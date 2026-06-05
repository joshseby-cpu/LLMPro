import SwiftUI
import AppKit

// The Code tab's editor pane: opens the file selected in the explorer, shows it
// in a syntax-highlighted, editable NSTextView, and lets the user Save (⌘S) or
// Revert. Re-loads when the agent or the user picks a different file.

struct CodeEditorView: View {
    let url: URL

    @State private var text: String = ""
    @State private var loadedText: String = ""
    @State private var language: CodeLanguage = .plain
    @State private var loadError: String?

    private var isDirty: Bool { text != loadedText && loadError == nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text").foregroundStyle(.secondary)
                Text(url.lastPathComponent).font(.callout.weight(.medium)).lineLimit(1)
                Text(language.rawValue).font(.caption2.monospaced()).foregroundStyle(.secondary)
                if isDirty { Circle().fill(.orange).frame(width: 7, height: 7) }
                Spacer()
                Button("Revert") { load() }.disabled(!isDirty).controlSize(.small)
                Button("Save") { save() }
                    .disabled(!isDirty)
                    .keyboardShortcut("s", modifiers: .command)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()

            if let loadError {
                VStack(spacing: 8) {
                    Image(systemName: "doc.questionmark").font(.largeTitle).foregroundStyle(.secondary)
                    Text(loadError).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                HighlightedTextView(text: $text, language: language)
            }
        }
        .task(id: url) { load() }
    }

    private func load() {
        language = CodeLanguage.from(path: url.path)
        if let data = try? Data(contentsOf: url), let string = String(data: data, encoding: .utf8) {
            text = string
            loadedText = string
            loadError = nil
        } else {
            text = ""
            loadedText = ""
            loadError = "“\(url.lastPathComponent)” isn’t UTF-8 text (it may be a binary or image file)."
        }
    }

    private func save() {
        guard let data = text.data(using: .utf8) else { return }
        try? data.write(to: url)
        loadedText = text
    }
}

// MARK: - Highlighted NSTextView

struct HighlightedTextView: NSViewRepresentable {
    @Binding var text: String
    let language: CodeLanguage

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        tv.backgroundColor = NSColor.textBackgroundColor
        tv.textColor = NSColor.labelColor
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.usesFindBar = true
        context.coordinator.textView = tv
        context.coordinator.apply(text: text, language: language)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.language = language
        // External change (a different file loaded, or Revert) → reset contents.
        if context.coordinator.lastText != text {
            context.coordinator.apply(text: text, language: language)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: HighlightedTextView
        weak var textView: NSTextView?
        var language: CodeLanguage
        var lastText: String = "\u{1}"               // sentinel ≠ any real text
        private var pending: Task<Void, Never>?

        init(_ parent: HighlightedTextView) {
            self.parent = parent
            self.language = parent.language
        }

        func apply(text: String, language: CodeLanguage) {
            guard let tv = textView else { return }
            lastText = text
            let selected = tv.selectedRanges
            tv.textStorage?.setAttributedString(SyntaxHighlighter.nsAttributed(text, language: language))
            tv.selectedRanges = selected
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            let updated = tv.string
            lastText = updated
            parent.text = updated
            // Debounced re-highlight so typing stays smooth on large files.
            pending?.cancel()
            let lang = language
            pending = Task { @MainActor [weak tv] in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled, let tv else { return }
                let ranges = tv.selectedRanges
                tv.textStorage?.setAttributedString(SyntaxHighlighter.nsAttributed(tv.string, language: lang))
                tv.selectedRanges = ranges
            }
        }
    }
}

#if DEBUG
#Preview("Code editor") {
    CodeEditorView(url: PreviewSupport.sampleFile)
        .previewEnvironment()
}
#endif
