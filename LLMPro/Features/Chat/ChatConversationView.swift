import SwiftUI

/// The dedicated **Chat** tab — a clean, focused conversation with any local
/// model, with saved chat history. Distinct from "Try it out" (which is the
/// arena/compare/score workbench): this is just talking to a model. Reuses
/// `ChatSession` for streaming, `MessageBubble` for rendering, the persona
/// presets, and the Markdown exporter.
struct ChatConversationView: View {
    @State private var store = ConversationStore.shared
    @State private var registry = ModelRegistry.shared
    @State private var presetStore = SystemPromptPresetStore.shared

    @State private var selectedID: UUID?
    @State private var session: ChatSession?
    /// Which conversation the live `session` maps to. Distinct from `selectedID`,
    /// which changes the instant a new row is picked — persisting must target the
    /// conversation the session was BUILT from, or a switch clobbers the new
    /// conversation with the old transcript.
    @State private var sessionConvID: UUID?
    @State private var input: String = ""

    // Mirrors of the active session's tunables, bound to the top-bar controls.
    @State private var model: String = ""
    @State private var systemPrompt: String = "You are a helpful, concise assistant."
    @State private var temperature: Double = 0.7

    @State private var renameTarget: StoredConversation?
    @State private var renameText: String = ""
    @State private var deletionTarget: StoredConversation?
    /// True when the loaded conversation's saved model was gone, so the session
    /// runs on a fallback — persist() must not overwrite the stored model with it.
    @State private var sessionModelIsFallback = false

    private var localModels: [ModelRegistry.DetectedModel] { registry.localModels }

    var body: some View {
        NavigationStack {
            Group {
                if localModels.isEmpty {
                    noModels
                } else {
                    HSplitView {
                        conversationList.frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
                        chatArea.frame(minWidth: 440)
                    }
                }
            }
            .navigationTitle("Chat")
        }
        .task {
            await registry.scan()
            if selectedID == nil { selectedID = store.conversations.first?.id }
        }
        .onChange(of: selectedID) { old, new in
            // Persist the currently-loaded session (keyed on sessionConvID, still
            // the OLD conversation here) before switching away.
            persist()
            if let old { store.discardIfEmpty(old) }
            if let new, let conv = store.conversations.first(where: { $0.id == new }) {
                loadSession(conv)
            } else {
                session?.stop()
                session = nil
                sessionConvID = nil
            }
        }
        .onDisappear {
            persist()
            session?.stop()
            if let id = sessionConvID { store.discardIfEmpty(id) }
        }
        .alert("Rename chat", isPresented: renamePresented, presenting: renameTarget) { conv in
            TextField("Title", text: $renameText)
            Button("Save") { store.rename(conv.id, to: renameText) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this chat?", isPresented: deletionPresented, presenting: deletionTarget) { conv in
            Button("Delete", role: .destructive) { deleteConversation(conv.id) }
            Button("Cancel", role: .cancel) {}
        } message: { conv in
            Text("“\(conv.isUntitled ? "New chat" : conv.title)” and its messages will be permanently removed.")
        }
    }

    // MARK: - Empty state

    private var noModels: some View {
        ContentUnavailableView {
            Label("No models yet", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("Download a model in the Models tab, then come back to chat with it.")
        } actions: {
            Button("Open Models") {
                NotificationCenter.default.post(name: .switchSidebar, object: SidebarSection.models)
            }
            .buttonStyle(.borderedProminent).tint(.brand)
        }
    }

    // MARK: - Conversation list (left rail)

    private var conversationList: some View {
        VStack(spacing: 0) {
            Button {
                startNewChat()
            } label: {
                Label("New chat", systemImage: "square.and.pencil").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(.brand)
            .padding(8)

            List(selection: $selectedID) {
                ForEach(store.conversations) { conv in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(conv.isUntitled && conv.messages.isEmpty ? "New chat" : conv.title)
                            .font(.callout).lineLimit(1)
                        Text(conv.updatedAt, format: .relative(presentation: .named))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .tag(conv.id)
                    .contextMenu {
                        Button("Rename…") { renameText = conv.title; renameTarget = conv }
                        Button("Delete…", role: .destructive) { deletionTarget = conv }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { deletionTarget = conv }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    // MARK: - Chat area (right)

    @ViewBuilder
    private var chatArea: some View {
        if let session {
            VStack(spacing: 0) {
                topBar(session)
                Divider()
                transcript(session)
                Divider()
                inputBar(session)
            }
        } else {
            ContentUnavailableView {
                Label("Start chatting", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Pick a conversation on the left, or start a new one.")
            } actions: {
                Button("New chat") { startNewChat() }.buttonStyle(.borderedProminent).tint(.brand)
            }
        }
    }

    private func topBar(_ session: ChatSession) -> some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(localModels) { m in
                    Button(m.displayName) { changeModel(to: m.repoID) }
                }
            } label: {
                Label(displayName(model), systemImage: "cube.box").lineLimit(1)
            }
            .frame(maxWidth: 260)

            Menu {
                ForEach(presetStore.all) { preset in
                    Button(preset.name) {
                        systemPrompt = preset.prompt
                        session.params.systemPrompt = preset.prompt
                        persist()
                    }
                }
            } label: { Label("Persona", systemImage: "person.bubble") }

            HStack(spacing: 4) {
                Text("Temp").font(.caption)
                // Update the live param on every tick, but only persist (which
                // rewrites the JSON + re-sorts the sidebar) when the drag ends.
                Slider(value: $temperature, in: 0...1.5) { editing in
                    if !editing { persist() }
                }
                .frame(width: 90)
                .onChange(of: temperature) { _, v in session.params.temperature = v }
                Text(String(format: "%.1f", temperature)).font(.caption.monospacedDigit())
            }

            Spacer()

            Button {
                ConversationMarkdownExporter.exportWithPanel(
                    title: currentTitle(), suggestedName: "\(currentTitle()).md", sessions: [session])
            } label: { Image(systemName: "square.and.arrow.up") }
                .help("Export this chat to Markdown")
                .disabled(session.messages.isEmpty)

            Button {
                session.clear()
                persist()
            } label: { Image(systemName: "trash") }
                .help("Clear this conversation")
                .disabled(session.messages.isEmpty)
        }
        .padding(10)
    }

    private func transcript(_ session: ChatSession) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(session.messages) { msg in
                        MessageBubble(message: msg, session: session,
                                      isLast: msg.id == session.messages.last?.id)
                            .id(msg.id)
                    }
                    if let err = session.error {
                        Label(err, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red).padding(.horizontal, 8)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .overlay {
                if session.messages.isEmpty && session.error == nil {
                    ContentUnavailableView("Say hello", systemImage: "text.bubble",
                                           description: Text("Type a message below to start chatting with \(displayName(model))."))
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: session.messages.last?.text) { _, _ in
                if let last = session.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            .onChange(of: session.isGenerating) { _, generating in
                if !generating { persist() }   // capture the completed assistant turn
            }
            .task(id: sessionConvID) {
                // Jump to the latest message when a saved conversation loads (a long
                // transcript otherwise opens pinned to the top).
                if let last = session.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private func inputBar(_ session: ChatSession) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextEditor(text: $input)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 44, maxHeight: 140)
                .padding(6)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            if session.isGenerating {
                Button(role: .destructive) { session.stop() } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .keyboardShortcut(".", modifiers: [.command])
            } else {
                Button { send(session) } label: { Label("Send", systemImage: "paperplane.fill") }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(10)
    }

    // MARK: - Actions

    private func startNewChat() {
        let defaultModel = model.isEmpty ? (localModels.first?.repoID ?? "") : model
        let conv = store.create(model: defaultModel, systemPrompt: systemPrompt, temperature: temperature)
        selectedID = conv.id   // triggers loadSession via onChange
    }

    private func loadSession(_ conv: StoredConversation) {
        session?.stop()   // stop any in-flight generation on the outgoing session
        input = ""        // don't bleed one conversation's unsent draft into the next
        // Fall back to a still-present model if the saved one was deleted.
        let installed = localModels.contains(where: { $0.repoID == conv.model })
        sessionModelIsFallback = !installed
        let m = installed ? conv.model : (localModels.first?.repoID ?? conv.model)
        let s = ChatSession(model: m, adapterPath: nil, label: conv.title)
        s.messages = conv.messages.map {
            ChatMessage(role: role(from: $0.role), text: $0.text, isStreaming: false)
        }
        s.params.systemPrompt = conv.systemPrompt
        s.params.temperature = conv.temperature
        s.params.maxTokens = 1024
        session = s
        sessionConvID = conv.id
        model = m
        systemPrompt = conv.systemPrompt
        temperature = conv.temperature
    }

    private func send(_ session: ChatSession) {
        guard !session.isGenerating else { return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""
        UserDefaults.standard.set(true, forKey: "onboarding.triedChat")
        session.send(text)
        persist()   // save the user turn immediately (before the reply streams in)
    }

    private func changeModel(to repoID: String) {
        model = repoID
        session?.model = repoID
        sessionModelIsFallback = false   // an explicit pick is authoritative
        persist()
    }

    /// Map the live session back into its stored conversation. Only finalized
    /// turns (no empty streaming placeholder) are persisted; auto-titles from the
    /// first user message.
    private func persist() {
        guard let session, let id = sessionConvID,
              var conv = store.conversations.first(where: { $0.id == id }) else { return }
        // Only a deliberate model pick is authoritative — never let a chat opened
        // on a deleted model (running on a fallback) rewrite its stored model.
        if !sessionModelIsFallback { conv.model = session.model }
        conv.systemPrompt = session.params.systemPrompt
        conv.temperature = session.params.temperature
        // Keep a non-empty partial reply (don't lose 95%-streamed text on switch);
        // drop only the truly-empty assistant placeholder.
        let newMessages = session.messages
            .filter { !($0.role == .assistant && $0.text.isEmpty) }
            .map { StoredMessage(role: $0.role.rawValue, text: $0.text) }
        // A failed/aborted "Try again" strips its empty reply, leaving a trailing
        // user turn with FEWER messages than stored — never clobber a good answer
        // with that worse state (persist only the tunables above).
        let droppingAnswer = newMessages.last?.role == "user" && newMessages.count < conv.messages.count
        if !droppingAnswer { conv.messages = newMessages }
        if conv.isUntitled, let firstUser = conv.messages.first(where: { $0.role == "user" }) {
            conv.title = String(firstUser.text.prefix(48)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        store.update(conv)
    }

    private func deleteConversation(_ id: UUID) {
        if sessionConvID == id {
            session?.stop()
            session = nil
            sessionConvID = nil
            selectedID = nil
        }
        store.delete(id)
    }

    // MARK: - Helpers

    private var renamePresented: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private var deletionPresented: Binding<Bool> {
        Binding(get: { deletionTarget != nil }, set: { if !$0 { deletionTarget = nil } })
    }

    private func currentTitle() -> String {
        store.conversations.first(where: { $0.id == selectedID })?.title ?? "chat"
    }

    private func displayName(_ repoID: String) -> String {
        repoID.split(separator: "/").last.map(String.init) ?? repoID
    }

    private func role(from raw: String) -> ChatMessage.Role {
        ChatMessage.Role(rawValue: raw) ?? .assistant
    }
}
