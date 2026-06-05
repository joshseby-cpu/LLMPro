import SwiftUI

/// The THINKING pane: ask the model a question and watch its **reasoning** trace
/// split from its **answer**, live. Reuses the existing streaming plumbing verbatim
/// — `OpenAIChatClient.stream` already decodes the server's separate `reasoning`
/// SSE field into `ChatStreamEvent.reasoningDelta`.
///
/// Thinking needs a live `mlx_lm server` (the shared `MLXServerService` daemon).
/// The pane is wired to the Inspect tab's model picker: if no server is running it
/// offers to load THIS selected model explicitly (a deliberate button, never an
/// accidental multi-GB auto-load); if a server is already running (e.g. from the
/// Code tab) it uses it and clearly labels which model is actually answering.
struct CoTInspectorView: View {
    let model: ModelRegistry.DetectedModel

    @State private var server = MLXServerService.shared
    @State private var prompt = "How many r's are in 'strawberry'? Think step by step."
    @State private var thinking = ""
    @State private var answer = ""
    @State private var isRunning = false
    @State private var error: String?
    @State private var showThinking = true
    @State private var runTask: Task<Void, Never>?

    /// True when the running server is serving a different model than the one
    /// selected in the Inspect picker (so answers won't reflect the picked model).
    private var servingMismatch: Bool {
        guard server.isReady else { return false }
        let loaded = server.loadedModelArg.isEmpty ? server.model : server.loadedModelArg
        // loadedModelArg is an absolute path for local models; match on either the
        // repoID or the on-disk directory.
        return !(loaded == model.repoID || loaded == model.directory.path
                 || loaded.hasSuffix(model.directory.lastPathComponent))
    }

    private var isStarting: Bool {
        if case .starting = server.state { return true } else { return false }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if isStarting {
                    startingCard
                } else if !server.isReady {
                    loadCard
                } else {
                    if servingMismatch { mismatchBanner }
                    promptRow
                    if !thinking.isEmpty { thinkingBlock }
                    if !answer.isEmpty || isRunning { answerBlock }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange).font(.callout)
                    }
                }
            }
            .padding(.top, 4)
        }
        .onDisappear { runTask?.cancel() }
    }

    // MARK: No server yet — offer to load THIS model

    private var loadCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "brain").font(.title2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text("Load \(model.displayName) to watch it think").font(.headline)
                Text("The Thinking view runs the model live. Loading \(model.displayName) (\(model.humanSize)) takes about a minute for a big model — it then stays warm for follow-up questions.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    Task { await server.start(model: model.directory.path, adapterPath: nil) }
                } label: {
                    Label("Load this model for Thinking", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                if case .failed(let msg) = server.state {
                    Label(msg, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
                }
                Text("Already chatting with a model in the Code tab? It'll be used here automatically.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var startingCard: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(server.statusText.isEmpty ? "Loading the model…" : server.statusText)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var mismatchBanner: some View {
        Label("Answers come from \(shortName(server.loadedModelArg.isEmpty ? server.model : server.loadedModelArg)) — the model loaded in Code, not \(model.displayName). To inspect \(model.displayName)'s thinking, load it in the Code tab.",
              systemImage: "info.circle")
            .font(.caption).foregroundStyle(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func shortName(_ s: String) -> String {
        (s as NSString).lastPathComponent
    }

    // MARK: Prompt + streamed result

    private var promptRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ask it something and watch it think.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Loaded: \(server.statusText)")
                .font(.caption2).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 8) {
                TextField("Ask a question…", text: $prompt, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .frame(maxWidth: 460)
                if isRunning {
                    Button("Stop") { runTask?.cancel(); isRunning = false }
                } else {
                    Button {
                        run()
                    } label: { Label("Think", systemImage: "brain") }
                    .buttonStyle(.borderedProminent)
                    .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    // The "💭 Thinking" disclosure — full-width Button + contentShape, the macOS
    // pattern that actually toggles on the whole row (not a bare DisclosureGroup).
    private var thinkingBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showThinking.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showThinking ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold)).frame(width: 12)
                    Label("💭 Thinking\(isRunning && answer.isEmpty ? "…" : "")", systemImage: "brain.head.profile")
                        .font(.callout)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if showThinking {
                Text(thinking)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var answerBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Answer", systemImage: "text.bubble").font(.callout.weight(.semibold))
            Text(answer.isEmpty ? "…" : answer)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: Run

    private func run() {
        guard let baseURL = server.baseURL else {
            error = "The model server isn't ready."
            return
        }
        thinking = ""; answer = ""; error = nil; isRunning = true
        let req = ChatCompletionRequest(
            model: server.loadedModelArg.isEmpty ? server.model : server.loadedModelArg,
            messages: [ChatWireMessage(role: "user", content: prompt)],
            tools: nil,
            temperature: 0.6,
            maxTokens: 1024,
            stream: true,
            chatTemplateKwargs: ["enable_thinking": true]   // ask thinking models to reason out loud
        )
        let client = OpenAIChatClient(baseURL: baseURL)
        runTask = Task { @MainActor in
            do {
                for try await event in client.stream(req) {
                    switch event {
                    case .reasoningDelta(let r): thinking += r
                    case .textDelta(let t):      answer += t
                    case .completed:             break
                    }
                }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
            self.isRunning = false
        }
    }
}

#if DEBUG
#Preview("Thinking") {
    CoTInspectorView(model: PreviewSupport.sampleDetectedModel)
        .previewEnvironment()
}
#endif
