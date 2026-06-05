import SwiftUI

/// Sheet for editing a single ChatRow. Pure value type in, value type out via the
/// `onCommit` callback — DatasetDetailView owns the array and persistence.
struct DatasetRowEditorView: View {
    let initial: ChatRow
    let isNew: Bool
    let onCommit: (ChatRow?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var working: ChatRow

    init(initial: ChatRow, isNew: Bool, onCommit: @escaping (ChatRow?) -> Void) {
        self.initial = initial
        self.isNew = isNew
        self.onCommit = onCommit
        _working = State(initialValue: initial)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 12) {
                    ForEach($working.messages) { binding in
                        messageCard(message: binding)
                    }
                    Button {
                        addMessage()
                    } label: {
                        Label("Add message", systemImage: "plus.message")
                            .font(.callout)
                    }
                    .controlSize(.regular)
                    .padding(.top, 4)
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(isNew ? "Add a row" : "Edit row").font(.headline)
            Text("Each row is one full conversation the model learns from. The user message is what someone asks; the assistant message is what you want the model to say back.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private func messageCard(message: Binding<ChatMessageRow>) -> some View {
        let msg = message.wrappedValue
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Role", selection: message.role) {
                    ForEach(ChatMessageRow.Role.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
                Spacer()
                Button(role: .destructive) {
                    removeMessage(id: msg.id)
                } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Remove this message")
                .disabled(working.messages.count <= 1)
            }
            TextEditor(text: message.content)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 100, maxHeight: 220)
                .padding(8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    if msg.content.isEmpty {
                        Text(placeholder(for: msg.role))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 14).padding(.vertical, 14)
                            .allowsHitTesting(false)
                    }
                }
        }
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") {
                onCommit(nil)
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button {
                onCommit(working)
                dismiss()
            } label: {
                Label(isNew ? "Add" : "Save changes", systemImage: "checkmark")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!hasContent)
        }
        .padding(14)
    }

    private var hasContent: Bool {
        working.messages.contains { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func addMessage() {
        let nextRole: ChatMessageRow.Role = (working.messages.last?.role == .user) ? .assistant : .user
        working.messages.append(ChatMessageRow(role: nextRole, content: ""))
    }

    private func removeMessage(id: UUID) {
        working.messages.removeAll { $0.id == id }
        if working.messages.isEmpty {
            // Always keep at least one editable row.
            working.messages.append(ChatMessageRow(role: .user, content: ""))
        }
    }

    private func placeholder(for role: ChatMessageRow.Role) -> String {
        switch role {
        case .system:    "Optional. The persona or rules the assistant should follow."
        case .user:      "What the person asks the model. Example: \"Write a Python function that…\""
        case .assistant: "What the model should answer with. Example: a code block + brief explanation."
        }
    }
}

#if DEBUG
#Preview("Edit lesson") {
    DatasetRowEditorView(initial: PreviewSupport.sampleChatRow, isNew: false) { _ in }
        .previewEnvironment()
}
#endif
