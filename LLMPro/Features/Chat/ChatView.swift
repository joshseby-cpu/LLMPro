import SwiftUI

struct ChatPaneView: View {
    @Bindable var session: ChatSession

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messagesScroller
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(session.label).font(.headline)
                Text(session.adapterPath == nil ? session.model + " (base)" : session.model + " + adapter")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button {
                session.clear()
            } label: { Image(systemName: "trash") }
            .help("Clear messages")
        }
        .padding(8)
    }

    @ViewBuilder
    private var messagesScroller: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(session.messages) { msg in
                        MessageBubble(message: msg, session: session,
                                      isLast: msg.id == session.messages.last?.id).id(msg.id)
                    }
                    if let err = session.error {
                        Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(.red).padding(.horizontal, 8)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay {
                if session.messages.isEmpty && session.error == nil {
                    emptyState
                }
            }
            .onChange(of: session.messages.last?.text) { _, _ in
                if let last = session.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    /// Friendly placeholder for an as-yet-unused chat pane, so a fresh pane reads
    /// as inviting rather than a black void. Subtle + secondary; worded to fit the
    /// base-vs-fine-tune compare panes.
    private var emptyState: some View {
        ContentUnavailableView(
            "Nothing here yet",
            systemImage: "bubble.left.and.bubble.right",
            description: Text("Ask something to compare the answers.")
        )
        .allowsHitTesting(false)
    }
}

/// One chat turn — role glyph, markdown/code-rendered content, and (for the last
/// finished assistant turn) copy + "Try again". Shared by `ChatPaneView` (the
/// arena panes) and the dedicated Chat tab's `ChatConversationView`.
struct MessageBubble: View {
    let message: ChatMessage
    var session: ChatSession
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: message.role == .user ? "person.circle.fill" : "sparkle")
                .foregroundStyle(message.role == .user ? .blue : .purple)
            VStack(alignment: .leading, spacing: 4) {
                Text(message.role.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                if message.text.isEmpty && message.isStreaming {
                    Text("▍").font(.system(.body, design: .monospaced))
                } else {
                    MessageContentView(text: message.text)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if message.role == .assistant && !message.isStreaming && !message.text.isEmpty {
                    actionRow
                }
            }
        }
        .padding(8)
        .background(message.role == .user ? Color.accentColor.opacity(0.08) : Color.gray.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 8))
    }

    private var actionRow: some View {
        HStack(spacing: 14) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.text, forType: .string)
            } label: { Label("Copy", systemImage: "doc.on.doc").font(.caption2) }
            .buttonStyle(.borderless)
            if isLast {
                Button { session.regenerateLast() } label: {
                    Label("Try again", systemImage: "arrow.clockwise").font(.caption2)
                }
                .buttonStyle(.borderless)
                .disabled(session.isGenerating)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }
}

#if DEBUG
#Preview("Chat pane") {
    ChatPaneView(session: PreviewSupport.sampleChatSession)
        .previewEnvironment()
}
#endif
