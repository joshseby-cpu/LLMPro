import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

// "Code" tab — point your fine-tuned model at a real project folder and let it
// read, edit, and run commands like a local Claude-Code. Backed by
// MLXServerService (the loaded model) + CodingAgentService (the agent loop).
//
// Friendly-first per the app convention: warm copy + plain status lead; the
// YAML-ish knobs (temperature, native tool-calling) and the raw server log live
// behind disclosures.
struct CodeView: View {
    @State private var server = MLXServerService.shared
    @State private var agent = CodingAgentService.shared
    @State private var registry = ModelRegistry.shared

    @State private var input = ""
    @State private var showOptions = false
    @State private var showAgents = false
    @State private var showMemory = false
    @State private var showSkills = false
    @State private var answerText = ""

    // IDE panes
    @State private var selectedFile: URL? = nil
    @State private var explorerRefresh = 0
    @AppStorage("codeShowWorkspacePanes") private var showWorkspacePanes = true

    @State private var attachments: [Attachment] = []

    @AppStorage("codeWorkspacePath") private var savedWorkspacePath = ""
    @AppStorage("codeOrchestratorModel") private var selectedModel = ""

    // The fine-tuned LoRA the team runs on (optional). This is the loop's
    // "use the coding model I trained" edge — a completed Teach/Practice adapter
    // layered on the base model.
    @AppStorage("codeAdapterJobID") private var savedAdapterID = ""
    @State private var selectedAdapterID: UUID? = nil
    @Query(sort: \TrainingJob.createdAt, order: .reverse) private var jobs: [TrainingJob]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider()
                workspaceArea
            }
            .navigationTitle("Code")
        }
        .task { await prepare() }
        .onChange(of: agent.transcript.count) { _, _ in
            explorerRefresh += 1   // re-scan the file tree as agents write files
        }
        .onChange(of: selectedAdapterID) { _, id in
            savedAdapterID = id?.uuidString ?? ""
            // A LoRA only works with the model it was trained on — keep them consistent.
            if let id, let job = jobs.first(where: { $0.id == id }),
               registry.localModels.contains(where: { $0.repoID == job.baseModelRepoID }) {
                selectedModel = job.baseModelRepoID
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openCodeWithModel)) { note in
            applyHandoff(note.object)
        }
        .sheet(isPresented: $showAgents) { AgentsManagerView() }
        .sheet(isPresented: $showSkills) { SkillsManagerView() }
        .sheet(isPresented: $showMemory) {
            if let ws = agent.workspaceURL { ProjectMemoryView(workspace: ws) }
        }
    }

    /// "Skills (N)…" — shows how many skill packs are installed.
    private var skillsButtonTitle: String {
        let n = SkillStore.shared.skills.count
        return n > 0 ? "Manage skills (\(n))…" : "Manage skills…"
    }

    /// "Project memory (N)" — shows how many lessons this project has accumulated.
    private var memoryButtonTitle: String {
        guard let ws = agent.workspaceURL else { return "Project memory" }
        _ = AgentMemoryService.shared.revision   // observe so the count refreshes
        let n = AgentMemoryService.shared.count(for: ws)
        return n > 0 ? "Project memory (\(n))…" : "Project memory…"
    }

    // MARK: IDE layout

    @ViewBuilder
    private var workspaceArea: some View {
        if showWorkspacePanes, let ws = agent.workspaceURL {
            HSplitView {
                FileExplorerView(root: ws, selection: $selectedFile, refreshToken: explorerRefresh)
                    .frame(minWidth: 170, idealWidth: 220, maxWidth: 340)
                if let file = selectedFile {
                    CodeEditorView(url: file)
                        .frame(minWidth: 320, idealWidth: 460)
                } else {
                    editorPlaceholder
                        .frame(minWidth: 240, idealWidth: 320)
                }
                chatColumn
                    .frame(minWidth: 360)
            }
        } else {
            chatColumn
        }
    }

    private var editorPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
            Text("Select a file in the explorer to view and edit it")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var chatColumn: some View {
        VStack(spacing: 0) {
            if !agent.todos.isEmpty {
                PlanView(todos: agent.todos)
                Divider()
            }
            transcript
            if let question = agent.pendingQuestion {
                questionBar(question)
            }
            if let pending = agent.pendingApproval {
                approvalBar(pending)
            }
            Divider()
            inputBar
        }
    }

    private func questionBar(_ question: UserQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble").foregroundStyle(.purple)
                Text("The team needs your input:").font(.caption.weight(.semibold))
            }
            Text(question.question).font(.callout)
            if question.options.isEmpty {
                // Free-text question.
                HStack {
                    TextField("Your answer…", text: $answerText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { submitAnswer() }
                    Button("Answer") { submitAnswer() }
                        .buttonStyle(.borderedProminent)
                        .disabled(answerText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                // Multiple-choice: one button per option steers the run; a free-text
                // field stays available for an answer that isn't on the list.
                VStack(spacing: 6) {
                    ForEach(question.options, id: \.self) { option in
                        Button { agent.answerUser(option) } label: {
                            HStack {
                                Text(option).multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                }
                HStack {
                    TextField("Or type your own answer…", text: $answerText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { submitAnswer() }
                    Button("Send") { submitAnswer() }
                        .buttonStyle(.bordered)
                        .disabled(answerText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(10)
        .background(.purple.opacity(0.12))
    }

    private func submitAnswer() {
        let a = answerText
        answerText = ""
        agent.answerUser(a)
    }

    // MARK: Header / session controls

    private var header: some View {
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { showWorkspacePanes.toggle() } label: {
                    Image(systemName: "sidebar.left")
                        .foregroundStyle(showWorkspacePanes ? Color.accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                .help("Show/hide the file explorer and editor")

                Button { chooseFolder() } label: {
                    Label(folderLabel, systemImage: "folder")
                        .lineLimit(1)
                }
                .help("Choose the project folder the team can read and edit")

                Picker("Model", selection: $selectedModel) {
                    Text("Pick a model").tag("")
                    ForEach(registry.localModels) { m in
                        Text(m.displayName).tag(m.repoID)
                    }
                }
                .frame(maxWidth: 240)
                .help("The shared LLM the whole agent team runs on. Press Start/Restart to load it.")

                if !completedAdapterJobs.isEmpty {
                    Picker("Adapter", selection: $selectedAdapterID) {
                        Text("Base only").tag(UUID?.none)
                        ForEach(completedAdapterJobs) { j in
                            Text(j.name).tag(Optional(j.id))
                        }
                    }
                    .frame(maxWidth: 200)
                    .help("Run the team on a LoRA you fine-tuned in the Teach or Practice tab, layered on the base model.")
                }

                Spacer()
                sessionButton
            }

            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(server.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("· team: \(TeamRole.all.map(\.emoji).joined())")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if server.isReady, !selectedModel.isEmpty, selectedModel != server.model {
                    Text("· press Restart to load \(selectedModel.split(separator: "/").last.map(String.init) ?? selectedModel)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }

            Button { showOptions.toggle() } label: {
                Label("Options", systemImage: "gearshape").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .popover(isPresented: $showOptions, arrowEdge: .bottom) {
                ScrollView { optionsForm.padding(14) }
                    .frame(width: 380)
                    .frame(maxHeight: 460)
            }
        }
        .padding(10)
    }

    @ViewBuilder
    private var sessionButton: some View {
        if case .starting = server.state {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Starting…").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 8) {
                Button(server.isReady ? "Restart" : "Start session") {
                    startSession()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedModel.isEmpty)
                if server.isReady {
                    Button { server.stop() } label: { Image(systemName: "stop.circle") }
                        .help("Unload the model and stop the server")
                }
            }
        }
    }

    // Flat layout on purpose: an expandable header that nests a ScrollView
    // (or further DisclosureGroups) competing with the transcript ScrollView
    // below it sends SwiftUI's macOS layout into a cycle (beachball) — even when
    // the log is empty. Keeping this as plain growing content avoids that.
    private var optionsForm: some View {
        @Bindable var agent = agent
        return VStack(alignment: .leading, spacing: 8) {
            Toggle("Auto-approve file edits (write / edit)", isOn: $agent.settings.autoApproveEdits)
            Toggle("Auto-run shell commands", isOn: $agent.settings.autoRunCommands)
            Text("With these off, the agent asks before it changes files or runs commands.")
                .font(.caption2).foregroundStyle(.secondary)

            Divider()
            Toggle("Run teammates in parallel \(TeamRole.all.map(\.emoji).joined())",
                   isOn: $agent.settings.parallelAgents)
            Text("On: the Orchestrator can run the Coder and UI agents at the same time (faster on a big model). Off: teammates run one at a time — easier on a smaller model, since only one request hits the GPU at once.")
                .font(.caption2).foregroundStyle(.secondary)

            Divider()
            Button {
                showOptions = false
                showAgents = true
            } label: {
                Label("Edit team agents…", systemImage: "person.2.badge.gearshape")
            }
            Text("Each teammate’s instructions live in an editable Markdown file — tweak how they think, or reset to default.")
                .font(.caption2).foregroundStyle(.secondary)

            Divider()
            Toggle("Skills: load instruction packs on demand", isOn: $agent.settings.useSkills)
            Text("On: every agent sees each skill’s name + description, and loads the full SKILL.md instructions only when a task matches — progressive disclosure, à la Codex/Anthropic.")
                .font(.caption2).foregroundStyle(.secondary)
            Button {
                showOptions = false
                showSkills = true
            } label: {
                Label(skillsButtonTitle, systemImage: "wand.and.stars")
            }

            Divider()
            Toggle("Evolve: learn from each task", isOn: $agent.settings.evolve)
            Text("On: the team remembers durable lessons about THIS project (build commands, conventions, gotchas) and reuses them next time — improving without re-training the model.")
                .font(.caption2).foregroundStyle(.secondary)
            Button {
                showOptions = false
                showMemory = true
            } label: {
                Label(memoryButtonTitle, systemImage: "brain")
            }
            .disabled(agent.workspaceURL == nil)

            Divider()
            Text("Advanced").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Toggle("Use native tool-calling", isOn: $agent.settings.useNativeTools)
            Text("Turn off if your model errors on the tools field — the agent then relies on text tool calls.")
                .font(.caption2).foregroundStyle(.secondary)
            Toggle("Let the model think first (slower)", isOn: $agent.settings.letModelThink)
            Text("Off (recommended) tells “thinking” models (Gemma-4, Qwen3) to act directly instead of reasoning at length — otherwise they can burn the whole turn thinking and never call a tool.")
                .font(.caption2).foregroundStyle(.secondary)
            Stepper("Max tokens per step: \(agent.settings.maxTokens)",
                    value: $agent.settings.maxTokens, in: 256...8192, step: 256)
            HStack {
                Text("Temperature")
                Slider(value: $agent.settings.temperature, in: 0...1)
                Text(String(format: "%.2f", agent.settings.temperature)).monospacedDigit()
            }
            Button("Clear conversation") { agent.resetConversation() }
                .disabled(agent.isRunning)

            if !server.logTail.isEmpty {
                Divider()
                Text("Server log").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(server.logTail.suffix(20).joined(separator: "\n"))
                    .font(.system(.caption2, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.top, 4)
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if agent.transcript.isEmpty {
                        emptyState
                    }
                    ForEach(agent.transcript) { bubble in
                        BubbleView(bubble: bubble)
                            .id(bubble.id)
                    }
                    Color.clear.frame(height: 1).id("BOTTOM")
                }
                .padding(12)
                // Hard-disable implicit animation for the whole transcript subtree.
                // Streaming flushes + indeterminate ProgressView spinners + parallel
                // builders all mutate this LazyVStack many times/sec; if any of those
                // updates carries an ambient animation, SwiftUI animates every lazy
                // subview's placement (Array.motionVectors → repeated StackLayout
                // sizing) and pegs the @MainActor main thread, starving the agent
                // loop. Nilling the transaction animation keeps placement instant.
                .transaction { $0.animation = nil }
            }
            // NOTE: do NOT wrap scrollTo in withAnimation. An animated scroll runs
            // inside an animation transaction, so SwiftUI animates the placement of
            // every lazy subview (Array.motionVectors) and re-runs the full nested-
            // stack layout per frame. With long agent messages that pegs the main
            // thread at 100% CPU — and since the agent loop is @MainActor, the run
            // stalls. A plain scrollTo jumps without re-laying-out the whole stack.
            .onChange(of: agent.transcript.count) { _, _ in
                proxy.scrollTo("BOTTOM", anchor: .bottom)
            }
            .onChange(of: agent.isRunning) { _, _ in
                proxy.scrollTo("BOTTOM", anchor: .bottom)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Talk to the Orchestrator")
                .font(.title3).bold()
            Text(server.isReady
                 ? "Describe what you want built. The Orchestrator (🧭) plans it with the Planner (🗺️) and Researcher (🔬), then dispatches the Coder (💻) and UI (🎨) builders — and asks you when it needs clarification."
                 : "Pick a project folder and the shared model, then press **Start session** to load it. The first load takes a minute for big models, then it stays warm.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if server.isReady {
                Text("Try: “Build a small to-do web app with add/complete/delete.”")
                    .font(.callout).italic().foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 24)
    }

    // MARK: Approval

    private func approvalBar(_ pending: PendingApproval) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Allow this action?").bold()
                Text(pending.title)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Deny") { agent.resolveApproval(false) }
            Button("Allow") { agent.resolveApproval(true) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
        }
        .padding(10)
        .background(.orange.opacity(0.12))
    }

    // MARK: Input

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attachments) { attachment in
                            attachmentChip(attachment) { attachments.removeAll { $0.id == attachment.id } }
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button { attachFiles() } label: {
                    Image(systemName: "paperclip").font(.body)
                }
                .buttonStyle(.borderless)
                .help("Attach files or images")

                ChatInputView(text: $input, onSubmit: { send() })
                    .frame(minHeight: 46, maxHeight: 140)
                    .padding(2)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .topLeading) {
                        if input.isEmpty {
                            Text("Describe a coding task…  ↩︎ to send · ⇧↩︎ for a new line")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 12).padding(.vertical, 14)
                                .allowsHitTesting(false)
                        }
                    }

                if agent.isRunning {
                    Button { agent.stop() } label: { Image(systemName: "stop.fill").font(.title3) }
                        .buttonStyle(.borderless)
                        .help("Stop")
                } else {
                    Button { send() } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                        .buttonStyle(.borderless)
                        .disabled(!canSend)
                        .help("Send (Return)")
                }
            }
        }
        .padding(10)
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
            return true
        }
    }

    private var canSend: Bool {
        server.isReady && (!input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    private func attachmentChip(_ attachment: Attachment, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Image(systemName: attachment.kind == .image ? "photo" : (attachment.kind == .text ? "doc.text" : "doc"))
                .font(.caption2)
            Text(attachment.name).font(.caption2).lineLimit(1)
            Button(action: onRemove) { Image(systemName: "xmark.circle.fill").font(.caption2) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
    }

    // MARK: Derived values

    /// Completed Teach/Practice jobs whose adapter weights are on disk — the
    /// fine-tuned coders the user can point the team at.
    private var completedAdapterJobs: [TrainingJob] {
        jobs.filter {
            $0.status == .completed &&
            FileManager.default.fileExists(atPath: $0.adapterURL.appendingPathComponent("adapters.safetensors").path)
        }
    }

    private var selectedAdapterPath: String? {
        guard let id = selectedAdapterID, let job = jobs.first(where: { $0.id == id }) else { return nil }
        return job.adapterURL.path
    }

    private var folderLabel: String {
        agent.workspaceURL?.lastPathComponent ?? "Choose folder…"
    }

    private var statusColor: Color {
        switch server.state {
        case .ready:   .green
        case .failed:  .red
        case .stopped: .gray
        default:       .orange
        }
    }

    // MARK: Actions

    private func prepare() async {
        if registry.localModels.isEmpty { await registry.scan() }
        if selectedModel.isEmpty || !registry.localModels.contains(where: { $0.repoID == selectedModel }) {
            selectedModel = registry.localModels.first?.repoID ?? ""
        }
        if agent.workspaceURL == nil, !savedWorkspacePath.isEmpty,
           FileManager.default.fileExists(atPath: savedWorkspacePath) {
            agent.workspaceURL = URL(fileURLWithPath: savedWorkspacePath)
        }
        if selectedAdapterID == nil, !savedAdapterID.isEmpty,
           let id = UUID(uuidString: savedAdapterID),
           jobs.contains(where: { $0.id == id }) {
            selectedAdapterID = id
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose the project folder the team can read and edit."
        if panel.runModal() == .OK, let url = panel.url {
            agent.workspaceURL = url
            savedWorkspacePath = url.path
        }
    }

    private func startSession() {
        guard !selectedModel.isEmpty else { return }
        let adapter = selectedAdapterPath
        Task { await agent.startSession(model: selectedModel, adapterPath: adapter) }
    }

    /// Pre-fill the model + adapter pickers from a Progress/Practice hand-off so
    /// the fine-tune the user just produced is the one the team loads.
    private func applyHandoff(_ object: Any?) {
        if let h = object as? ModelHandoff {
            if registry.localModels.contains(where: { $0.repoID == h.model }) { selectedModel = h.model }
            if let p = h.adapterPath, let job = jobs.first(where: { $0.adapterURL.path == p }) {
                selectedAdapterID = job.id
            }
        } else if let repo = object as? String,
                  registry.localModels.contains(where: { $0.repoID == repo }) {
            selectedModel = repo
        }
    }

    private func send() {
        guard canSend else { return }
        let text = input
        let toSend = attachments
        input = ""
        attachments = []
        agent.send(text, attachments: toSend)
    }

    private func attachFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Attach files or images to send to the model."
        if panel.runModal() == .OK {
            for url in panel.urls { addAttachment(url) }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                Task { @MainActor in addAttachment(url) }
            }
        }
    }

    private func addAttachment(_ url: URL) {
        guard !attachments.contains(where: { $0.url == url }) else { return }
        attachments.append(Attachment(url: url))
    }
}

// MARK: - Bubble

private struct BubbleView: View {
    let bubble: AgentBubble

    var body: some View {
        switch bubble.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(bubble.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !bubble.attachments.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(bubble.attachments, id: \.self) { name in
                                HStack(spacing: 3) {
                                    Image(systemName: "paperclip").font(.caption2)
                                    Text(name).font(.caption2).lineLimit(1)
                                }
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                            }
                        }
                    }
                }
                .padding(10)
                .background(.tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
            }
        case .info:
            Text(bubble.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        case .assistant:
            HStack(alignment: .top, spacing: 0) {
                if bubble.depth > 0 {
                    Rectangle().fill(.quaternary).frame(width: 2)
                        .padding(.leading, CGFloat(bubble.depth - 1) * 14)
                        .padding(.trailing, 8)
                }
                VStack(alignment: .leading, spacing: 8) {
                    if let role = bubble.teamRole {
                        HStack(spacing: 5) {
                            Text(role.emoji)
                            Text(role.displayName).font(.caption.weight(.semibold)).foregroundStyle(role.tint)
                            if bubble.isStreaming { ProgressView().controlSize(.mini) }
                        }
                    }
                    if !bubble.reasoning.isEmpty {
                        ReasoningView(text: bubble.reasoning)
                    }
                    if !bubble.text.isEmpty {
                        // fixedSize(vertical) makes the Text compute its height once
                        // from the offered width instead of participating in the
                        // stack's width/height re-proposal loop — without it a long
                        // message sends SwiftUI's StackLayout into an O(2^depth)
                        // re-measurement spin. textSelection is also costly to lay
                        // out, so only enable it once streaming has finished.
                        Group {
                            if bubble.isStreaming {
                                Text(bubble.text)
                            } else {
                                Text(bubble.text).textSelection(.enabled)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else if bubble.isStreaming && bubble.toolCalls.isEmpty {
                        Text("Working…").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(bubble.toolCalls) { call in
                        ToolCardView(call: call)
                    }
                }
            }
        }
    }
}

// MARK: - Reasoning ("thinking" models)

/// Shows a thinking model's chain-of-thought as a dimmed, collapsible block so a
/// reasoning model (Gemma-4, Qwen3-thinking, DeepSeek-R1…) doesn't look like it
/// produced nothing while it's busy thinking.
private struct ReasoningView: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2).frame(width: 10)
                    Text("💭 Thinking").font(.caption2.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            if expanded {
                ScrollView {
                    Text(text).font(.caption2).italic().foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .frame(maxHeight: 180)
            } else {
                Text(text).font(.caption2).italic().foregroundStyle(.tertiary)
                    .lineLimit(2).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Tool card

private struct ToolCardView: View {
    let call: AgentToolCallView
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(call.title)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                    Spacer()
                    statusBadge
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(8)

            if expanded {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    if let detail = call.detail, !detail.isEmpty {
                        ScrollView { DiffText(text: detail, language: cardLanguage) }
                            .frame(maxHeight: 240)
                    } else if !prettyArgs.isEmpty {
                        Text(prettyArgs)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if let output = call.output, !output.isEmpty {
                        ScrollView {
                            if AgentToolName(rawValue: call.name) == .readFile && !call.isError {
                                Text(SyntaxHighlighter.attributed(output, language: cardLanguage))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            } else {
                                Text(output)
                                    .font(.system(.caption2, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .foregroundStyle(call.isError ? .red : .primary)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxHeight: 220)
                    }
                }
                .padding(8)
            }
        }
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary, lineWidth: 1))
        .onChange(of: call.status) { _, new in
            if new == .pendingApproval { expanded = true }   // surface the diff while deciding
        }
    }

    private var icon: String {
        if TeamRole.role(forCallTool: call.name) != nil { return "person.2.fill" }
        switch AgentToolName(rawValue: call.name) {
        case .readFile:   return "doc.text"
        case .listDir:    return "folder"
        case .glob:       return "doc.text.magnifyingglass"
        case .grep:       return "magnifyingglass"
        case .writeFile:  return "square.and.pencil"
        case .editFile:   return "pencil"
        case .runCommand: return "terminal"
        case .useSkill:   return "wand.and.stars"
        case .todoWrite:  return "checklist"
        case .askUser:    return "questionmark.bubble"
        case .remember:   return "brain"
        case .webSearch:  return "globe"
        case .fetchUrl:   return "link"
        case nil:         return "wrench.and.screwdriver"
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch call.status {
        case .pendingApproval:
            Image(systemName: "lock.shield").foregroundStyle(.orange)
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: call.isError ? "exclamationmark.triangle.fill" : "checkmark")
                .foregroundStyle(call.isError ? .red : .green)
        case .denied:
            Image(systemName: "hand.raised.fill").foregroundStyle(.red)
        }
    }

    private var prettyArgs: String {
        guard let data = call.argumentsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: pretty, encoding: .utf8) else { return call.argumentsJSON }
        return s
    }

    /// Language for highlighting this card's diff / file output, from its path arg.
    private var cardLanguage: CodeLanguage {
        let args = (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8))) as? [String: Any] ?? [:]
        if let path = args["path"] as? String { return CodeLanguage.from(path: path) }
        return .plain
    }
}

// MARK: - Diff + Plan

/// Renders a `- ` / `+ ` diff with red/green gutters AND syntax-highlighted code,
/// so changes read like code instead of plain text.
private struct DiffText: View {
    let text: String
    var language: CodeLanguage = .plain

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, raw in
                line(String(raw))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func line(_ text: String) -> some View {
        if text.hasPrefix("+ ") || text.hasPrefix("- ") {
            let added = text.hasPrefix("+ ")
            HStack(alignment: .top, spacing: 0) {
                Text(added ? "+ " : "- ")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(added ? .green : .red)
                Text(SyntaxHighlighter.attributed(String(text.dropFirst(2)), language: language))
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((added ? Color.green : Color.red).opacity(0.10))
        } else {
            Text(text.isEmpty ? " " : text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The agent's live task plan (written via the `todo_write` tool).
private struct PlanView: View {
    let todos: [TodoItem]
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(todos) { todo in
                    HStack(spacing: 8) {
                        Image(systemName: icon(todo.status)).foregroundStyle(tint(todo.status))
                        Text(todo.content)
                            .strikethrough(todo.status == .completed)
                            .foregroundStyle(todo.status == .completed ? .secondary : .primary)
                        Spacer()
                    }
                    .font(.callout)
                }
            }
            .padding(.top, 4)
        } label: {
            let done = todos.filter { $0.status == .completed }.count
            Label("Plan — \(done)/\(todos.count) done", systemImage: "checklist")
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func icon(_ s: TodoItem.Status) -> String {
        switch s {
        case .pending:    "circle"
        case .inProgress: "circle.lefthalf.filled"
        case .completed:  "checkmark.circle.fill"
        }
    }
    private func tint(_ s: TodoItem.Status) -> Color {
        switch s {
        case .pending:    .secondary
        case .inProgress: .blue
        case .completed:  .green
        }
    }
}

#if DEBUG
#Preview("Code") {
    CodeView().previewEnvironment()
}
#endif
