import SwiftUI

/// Renders an assistant/user message, breaking out fenced code blocks into
/// monospaced panels each with a Copy button (and a Copy-all for the whole
/// message). Replaces a plain `Text(message.text)` in the chat bubble.
struct MessageContentView: View {
    let text: String
    var body: some View {
        let segments = CodeBlockParser.parse(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                switch seg {
                case .text(let t):
                    Text(t).textSelection(.enabled)
                case .code(let lang, let code):
                    codeBlock(language: lang, code: code)
                }
            }
        }
    }

    private func codeBlock(language: String?, code: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc").font(.caption2)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.black.opacity(0.06))
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
    }
}
