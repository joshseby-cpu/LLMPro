import SwiftUI

struct ArenaView: View {
    @State private var baseSession: ChatSession
    @State private var adapterSession: ChatSession
    @State private var prompt: String = ""
    @State private var systemPrompt: String = "You are a careful, expert programming assistant. Prefer correct, idiomatic code with minimal commentary."
    @State private var temperature: Double = 0.4
    @State private var maxTokens: Int = 512
    @State private var arenaMode: Bool = true
    @State private var modelText: String = "mlx-community/Llama-3.2-3B-Instruct-4bit"
    @State private var adapterText: String = ""

    init() {
        // Default to a general base — the whole point of LLMPro is to take a non-coder
        // and turn it into one. The adapter side is what makes it a coder.
        let initialModel = "mlx-community/Llama-3.2-3B-Instruct-4bit"
        _baseSession = State(initialValue: ChatSession(model: initialModel, adapterPath: nil, label: "Base (general)"))
        _adapterSession = State(initialValue: ChatSession(model: initialModel, adapterPath: nil, label: "Coding fine-tune"))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controls
                Divider()
                if arenaMode {
                    HSplitView {
                        ChatPaneView(session: baseSession)
                        ChatPaneView(session: adapterSession)
                    }
                } else {
                    ChatPaneView(session: adapterSession)
                }
                Divider()
                if !adapterText.isEmpty {
                    decisionBar
                    Divider()
                }
                inputBar
            }
            .navigationTitle(arenaMode ? "Model Arena" : "Chat")
            .onReceive(NotificationCenter.default.publisher(for: .openChatWithModel)) { note in
                if let h = note.object as? ModelHandoff {
                    modelText = h.model
                    adapterText = h.adapterPath ?? ""
                    if let p = h.adapterPath, !p.isEmpty { arenaMode = true }
                    applyModelChange()
                } else if let repo = note.object as? String {
                    modelText = repo
                    applyModelChange()
                }
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack {
                Toggle("Arena (compare base vs fine-tuned)", isOn: $arenaMode).toggleStyle(.switch)
                Spacer()
                Stepper("Max tokens: \(maxTokens)", value: $maxTokens, in: 64...8192, step: 64).frame(width: 220)
                HStack { Text("Temp"); Slider(value: $temperature, in: 0...1.5); Text(String(format: "%.2f", temperature)).monospacedDigit() }
                    .frame(width: 240)
            }
            HStack {
                TextField("Base model (HF repo or local path)", text: $modelText, onCommit: applyModelChange)
                TextField("Adapter path (LoRA dir)", text: $adapterText, onCommit: applyModelChange)
                Button("Apply") { applyModelChange() }
            }
            TextField("System prompt", text: $systemPrompt, axis: .vertical).lineLimit(2...4)
        }
        .padding(10)
    }

    private var inputBar: some View {
        HStack(alignment: .bottom) {
            TextEditor(text: $prompt)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 60, maxHeight: 160)
                .padding(6)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            VStack {
                Button {
                    send()
                } label: { Label("Send", systemImage: "paperplane.fill") }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button {
                    sendCodingEval()
                } label: { Label("Mini-eval", systemImage: "checkmark.seal") }
                .help("Send a built-in coding probe to both panels")
            }
        }
        .padding(10)
    }

    // The test → decision edge: once a fine-tuned adapter is loaded, let the user
    // act on the verdict without hunting through the sidebar — retrain it, use it
    // in the Code tab, or export it.
    private var decisionBar: some View {
        HStack(spacing: 10) {
            Text("How did the fine-tune do?").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button {
                NotificationCenter.default.post(name: .openTrainingWithModel, object: modelText)
            } label: { Label("Train again", systemImage: "arrow.triangle.2.circlepath") }
                .help("Not good enough? Go back to Teach with this model to fine-tune again.")
            Button {
                NotificationCenter.default.post(
                    name: .openCodeWithModel,
                    object: ModelHandoff(model: modelText, adapterPath: adapterText.isEmpty ? nil : adapterText))
            } label: { Label("Use in Code", systemImage: "chevron.left.forwardslash.chevron.right") }
                .help("Good enough? Load it into the Code tab's agent team.")
            Button {
                NotificationCenter.default.post(name: .switchSidebar, object: SidebarSection.export)
            } label: { Label("Save & Use", systemImage: "square.and.arrow.up") }
                .help("Export this fine-tune to Ollama / LM Studio.")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.quaternary.opacity(0.3))
    }

    private func applyModelChange() {
        var params = baseSession.params
        params.systemPrompt = systemPrompt
        params.temperature = temperature
        params.maxTokens = maxTokens
        baseSession.model = modelText
        baseSession.adapterPath = nil
        baseSession.params = params
        adapterSession.model = modelText
        adapterSession.adapterPath = adapterText.isEmpty ? nil : adapterText
        adapterSession.params = params
    }

    private func send() {
        let p = prompt
        prompt = ""
        applyModelChange()
        if arenaMode { baseSession.send(p) }
        adapterSession.send(p)
    }

    private func sendCodingEval() {
        let probes = [
            "Write a Python function that returns the nth Fibonacci number using memoization.",
            "In Rust, implement a function `fn is_prime(n: u64) -> bool` that's efficient for n up to 10^12.",
            "Refactor this code for clarity:\n\n```python\ndef f(x):\n  return [y for y in range(x) if y%2==0]\n```",
            "Explain the difference between `Option<T>` and `Result<T, E>` in Rust, then give a small example for each."
        ]
        let chosen = probes.randomElement() ?? probes[0]
        applyModelChange()
        if arenaMode { baseSession.send(chosen) }
        adapterSession.send(chosen)
    }
}
