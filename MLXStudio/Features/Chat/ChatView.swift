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
                        MessageBubble(message: msg).id(msg.id)
                    }
                    if let err = session.error {
                        Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(.red).padding(.horizontal, 8)
                    }
                }
                .padding(12)
            }
            .onChange(of: session.messages.last?.text) { _, _ in
                if let last = session.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: message.role == .user ? "person.circle.fill" : "sparkle")
                .foregroundStyle(message.role == .user ? .blue : .purple)
            VStack(alignment: .leading, spacing: 4) {
                Text(message.role.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                Text(message.text.isEmpty && message.isStreaming ? "▍" : message.text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .background(message.role == .user ? Color.accentColor.opacity(0.08) : Color.gray.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 8))
    }
}
