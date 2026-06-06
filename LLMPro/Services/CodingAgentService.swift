import Foundation
import SwiftUI

// The Code tab's brain: a multi-agent ORCHESTRATION engine. The user talks only
// to the Orchestrator (a TeamRole loop). Its tools include delegation calls
// (call_planner / call_researcher / call_coder / call_ui) and ask_user; calling
// a delegate runs THAT role's loop to completion and returns its result. The
// Orchestrator can call multiple builders in one turn to run them concurrently
// (one shared model server, so generation is interleaved on the GPU). See
// AgentRoles.swift for the roles, prompts, and per-role toolsets.
//
// Tool-call handling is shared with the single-agent days: native `tool_calls`
// when the model template supports them, else a `<tool_call>` / fenced-JSON text
// fallback (AgentTools.parseFallbackCalls).

// MARK: - Display model

enum AgentRole: Sendable { case user, assistant, info }   // the KIND of a transcript bubble

struct AgentToolCallView: Identifiable, Sendable {
    let id: String
    let name: String
    let argumentsJSON: String
    var status: Status = .running
    var output: String?
    var isError: Bool = false
    var detail: String? = nil          // UI-only diff / extra detail (not sent to the model)

    enum Status: Sendable { case pendingApproval, running, done, denied }

    var isReadOnly: Bool { AgentToolName(rawValue: name)?.isReadOnly ?? false }

    var title: String {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        func s(_ k: String) -> String { args[k] as? String ?? "" }
        if let role = TeamRole.role(forCallTool: name) {
            let t = s("task")
            return "→ \(role.displayName)" + (t.isEmpty ? "" : ": \(t.prefix(70))")
        }
        switch AgentToolName(rawValue: name) {
        case .readFile:   return "Read \(s("path"))"
        case .listDir:    return "List \(s("path").isEmpty ? "." : s("path"))"
        case .glob:       return "Find \(s("pattern"))"
        case .grep:       return "Search “\(s("pattern"))”"
        case .writeFile:  return "Write \(s("path"))"
        case .editFile:   return "Edit \(s("path"))"
        case .runCommand: return "Run: \(s("command"))"
        case .useSkill:   return "Use skill: \(s("name"))"
        case .todoWrite:  return "Update plan"
        case .askUser:    return "Ask you: \(s("question").prefix(70))"
        case .remember:   return "Remember: \(s("lesson").prefix(70))"
        case .webSearch:  return "Search web: \(s("query").prefix(60))"
        case .fetchUrl:   return "Fetch \(s("url").prefix(70))"
        case nil:         return name
        }
    }
}

struct AgentBubble: Identifiable, Sendable {
    let id = UUID()
    var role: AgentRole
    var text: String
    var reasoning: String = ""             // chain-of-thought from a "thinking" model
    var toolCalls: [AgentToolCallView] = []
    var isStreaming: Bool = false
    var attachments: [String] = []
    var teamRole: TeamRole? = nil          // which agent produced this (assistant bubbles)
    var depth: Int = 0                     // delegation depth, for indenting
}

struct TodoItem: Identifiable, Sendable, Hashable {
    let id = UUID()
    var content: String
    var status: Status
    enum Status: String, Sendable { case pending, inProgress = "in_progress", completed }
}

struct PendingApproval: Identifiable, Sendable {
    let id: String
    let name: String
    let argumentsJSON: String
    var title: String { AgentToolCallView(id: id, name: name, argumentsJSON: argumentsJSON).title }
}

struct UserQuestion: Identifiable, Sendable {
    let id = UUID()
    let question: String
    /// Fixed choices the agent offered (rendered as buttons). Empty → free text.
    var options: [String] = []
}

struct AgentSettings: Sendable {
    var autoApproveEdits = true            // ON by default for the team (builders run unattended)
    var autoRunCommands = true
    var useNativeTools = true
    var parallelAgents = true              // when off, the orchestrator runs delegates one at a time
                                           // (kinder to a smaller model — only one request in flight)
    var letModelThink = false              // OFF by default → send enable_thinking:false so a
                                           // "thinking" model (Gemma-4, Qwen3) acts directly instead of
                                           // reasoning past the token budget and never tool-calling
    var temperature = 0.2
    var maxTokens = 4096                    // enough headroom for a verbose model's plan /
                                           // file-write in one step (2048 truncated Gemma's plans);
                                           // with thinking off this stays reasonably fast
    var evolve = true                      // the "evolving agent": inject this project's learned
                                           // lessons before each task, and reflect+save new ones
                                           // after — improving across sessions WITHOUT fine-tuning
                                           // (the in-context complement to the Practice loop)
    var useSkills = true                   // Agent Skills: each agent sees the name+description of
                                           // every installed skill (SKILL.md package) and loads the
                                           // full instructions on demand via the use_skill tool
                                           // (3-stage progressive disclosure, à la Codex/Anthropic)
}

// MARK: - Service

@MainActor
@Observable
final class CodingAgentService {
    static let shared = CodingAgentService()

    /// Max nesting depth for agent-to-agent delegation (entry agent = depth 0).
    /// Agents can reference each other, so this bounds cycles and fan-out chains.
    static let maxDelegationDepth = 6

    var workspaceURL: URL?
    var settings = AgentSettings()
    private(set) var transcript: [AgentBubble] = []
    private(set) var todos: [TodoItem] = []
    private(set) var isRunning = false
    private(set) var pendingApproval: PendingApproval?
    private(set) var pendingQuestion: UserQuestion?
    private(set) var lastError: String?

    /// A mutable conversation for one agent. The orchestrator's persists across
    /// user turns; each delegate gets a fresh one.
    private final class Convo { var wire: [ChatWireMessage]; init(_ wire: [ChatWireMessage]) { self.wire = wire } }
    private let orchestrator = Convo([])

    private var runTask: Task<Void, Never>?
    private var approvalContinuation: CheckedContinuation<Bool, Never>?
    private var answerContinuation: CheckedContinuation<String, Never>?

    private init() {}

    private var client: OpenAIChatClient {
        OpenAIChatClient(baseURL: MLXServerService.shared.baseURL ?? URL(string: "http://127.0.0.1:8080/v1")!, timeout: 600)
    }
    private var executor: ToolExecutor {
        var ex = ToolExecutor(workspace: workspaceURL ?? FileManager.default.temporaryDirectory)
        // Agent Skills: hand the executor every installed skill's full context so
        // the `use_skill` tool can return the complete instructions on demand —
        // including a skill loaded transitively via another skill's `skills:` link.
        // The per-agent SCOPE (which skills an agent is told about) is applied to
        // the discovery list + tool availability below, not here.
        if settings.useSkills { ex.skills = SkillStore.shared.skills.map(\.context) }
        return ex
    }

    /// The skills a given agent may use, honoring its `skills:` frontmatter
    /// (skill→agent link). `nil` (key absent) → ALL installed skills (the default,
    /// so unconfigured agents keep seeing everything). An explicit empty list opts
    /// the agent out. Linked skills referenced by an in-scope skill are also pulled
    /// in, so skill→skill links work even when the agent didn't list them directly.
    private func availableSkills(for role: TeamRole) -> [Skill] {
        guard settings.useSkills else { return [] }
        let all = SkillStore.shared.skills
        guard let scoped = role.skillIDs else { return all }   // nil → all
        var keep = Set(scoped)
        // transitively include skills linked from in-scope ones
        var frontier = scoped
        while let id = frontier.popLast() {
            if let s = all.first(where: { $0.id == id }) {
                for link in s.links where !keep.contains(link) { keep.insert(link); frontier.append(link) }
            }
        }
        return all.filter { keep.contains($0.id) }
    }

    // MARK: Session control

    func startSession(model: String, adapterPath: String?) async {
        await MLXServerService.shared.start(model: model, adapterPath: adapterPath)
        if MLXServerService.shared.isReady { resetConversation() }
    }

    func resetConversation() {
        stop()
        transcript.removeAll()
        todos.removeAll()
        orchestrator.wire = [systemMessage(.entry)]
        lastError = nil
    }

    func send(_ text: String, attachments: [Attachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!trimmed.isEmpty || !attachments.isEmpty), !isRunning, MLXServerService.shared.isReady else { return }
        if orchestrator.wire.isEmpty { orchestrator.wire = [systemMessage(.entry)] }
        else { orchestrator.wire[0] = systemMessage(.entry) }   // pick up workspace changes

        transcript.append(AgentBubble(role: .user,
                                      text: trimmed.isEmpty ? "(see attachments)" : trimmed,
                                      attachments: attachments.map(\.name)))
        lastError = nil
        isRunning = true
        runTask = Task {
            let extra = attachments.isEmpty ? "" : await Attachment.combinedText(for: attachments)
            self.orchestrator.wire.append(ChatWireMessage(role: "user", content: trimmed + extra))
            let outcome = await self.runRole(.entry, convo: self.orchestrator, depth: 0)
            self.isRunning = false
            self.runTask = nil
            // The "evolving" step: after the task finishes (not cancelled), reflect
            // on what happened and save durable lessons for next time.
            if !Task.isCancelled { await self.reflectAfterTask(task: trimmed, outcome: outcome) }
        }
    }

    /// Post-task reflection (the after_run hook). Cheap, bounded, best-effort: one
    /// LLM call extracts durable project lessons and appends them to memory. Shows
    /// a quiet transcript note when something was learned.
    private func reflectAfterTask(task: String, outcome: String) async {
        guard settings.evolve, let ws = workspaceURL,
              !outcome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let added = await AgentMemoryService.shared.reflect(
            task: task, outcome: outcome, workspace: ws,
            modelArg: MLXServerService.shared.loadedModelArg)
        if added > 0 {
            appendInfo("🧠 Learned \(added) new \(added == 1 ? "lesson" : "lessons") about this project (saved to memory).")
        }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        approvalContinuation?.resume(returning: false); approvalContinuation = nil
        answerContinuation?.resume(returning: "(cancelled)"); answerContinuation = nil
        pendingApproval = nil
        pendingQuestion = nil
        isRunning = false
    }

    func resolveApproval(_ approved: Bool) {
        approvalContinuation?.resume(returning: approved); approvalContinuation = nil
    }

    func answerUser(_ text: String) {
        answerContinuation?.resume(returning: text.isEmpty ? "(no answer)" : text); answerContinuation = nil
        pendingQuestion = nil
    }

    // MARK: - The agent loop (one role)

    /// Run one role's loop on its conversation until it stops calling tools.
    /// Returns the role's final text (fed back to whoever delegated to it).
    private func runRole(_ role: TeamRole, convo: Convo, depth: Int) async -> String {
        var tools = role.toolSpecs()
        // Give every role the `remember` tool while the evolving agent is on, so it
        // can persist a durable lesson the moment it learns one (in addition to the
        // automatic post-task reflection).
        if settings.evolve, workspaceURL != nil { tools.append(AgentTools.toolSpec(for: .remember)) }
        // Agent Skills: when this agent has at least one skill in scope, give it the
        // use_skill tool so it can load a skill's full instructions on demand
        // (Stage 2 of progressive disclosure — the catalogue is in the system prompt).
        if !availableSkills(for: role).isEmpty {
            tools.append(AgentTools.toolSpec(for: .useSkill))
        }
        var iterations = 0
        var lastText = ""

        while iterations < role.maxIterations {
            if Task.isCancelled { return lastText }
            iterations += 1

            let request = ChatCompletionRequest(
                model: MLXServerService.shared.loadedModelArg,
                messages: prune(convo.wire),
                tools: settings.useNativeTools ? tools : nil,
                temperature: settings.temperature,
                maxTokens: settings.maxTokens,
                chatTemplateKwargs: ["enable_thinking": settings.letModelThink])

            let idx = appendStreamingBubble(role: role, depth: depth)
            var message: ChatWireMessage?
            // Coalesce streaming deltas. Applying every token to the @Observable
            // transcript re-lays-out the whole growing bubble; per-token that is
            // O(n²) over the message length and — because this loop is @MainActor —
            // can saturate the main thread and stall the run. Buffer deltas and flush
            // at most ~12×/sec (or when a chunk accumulates) to bound layout cost.
            var pendingText = ""
            var pendingReasoning = ""
            var lastFlush = Date()
            func flushDeltas(force: Bool) {
                let pending = pendingText.count + pendingReasoning.count
                guard pending > 0 else { return }
                guard force || pending >= 48 || Date().timeIntervalSince(lastFlush) >= 0.08 else { return }
                if !pendingText.isEmpty { appendToBubble(idx, pendingText); pendingText = "" }
                if !pendingReasoning.isEmpty { appendReasoning(idx, pendingReasoning); pendingReasoning = "" }
                lastFlush = Date()
            }
            do {
                for try await event in client.stream(request) {
                    if Task.isCancelled { break }
                    switch event {
                    case .textDelta(let delta):      pendingText += delta;      flushDeltas(force: false)
                    case .reasoningDelta(let delta): pendingReasoning += delta; flushDeltas(force: false)
                    case .completed(let msg):        message = msg
                    }
                }
            } catch {
                flushDeltas(force: true)
                finalizeBubble(idx)
                if Task.isCancelled { return lastText }
                recordError("\(role.displayName): \(error.localizedDescription)")
                return lastText
            }
            flushDeltas(force: true)
            finalizeBubble(idx)
            if Task.isCancelled { return lastText }
            guard let message else { recordError("\(role.displayName) returned no response."); return lastText }

            let rawText = message.content ?? ""
            let nativeCalls = message.toolCalls ?? []
            var calls: [ParsedToolCall]
            var native: Bool

            if !nativeCalls.isEmpty {
                native = true
                calls = nativeCalls.map { ParsedToolCall(id: $0.id, name: $0.function.name, argumentsJSON: $0.function.arguments) }
                convo.wire.append(ChatWireMessage(role: "assistant", content: rawText.isEmpty ? nil : rawText, toolCalls: nativeCalls))
            } else {
                let fallback = AgentTools.parseFallbackCalls(from: rawText)
                if fallback.isEmpty {
                    // No tool call → treat this turn as the role's final answer.
                    convo.wire.append(ChatWireMessage(role: "assistant", content: rawText))
                    let visible = AgentTools.stripToolCallBlocks(from: rawText)
                    setBubbleText(idx, visible)
                    // Don't appear to "stop for no reason": if the model produced
                    // neither a visible answer nor a tool call, say why. The usual
                    // cause is a reasoning model that ran out of room mid-think, or
                    // a model that can't tool-call.
                    if visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let thought = transcript.indices.contains(idx)
                            && !transcript[idx].reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        appendInfo(thought
                            ? "💭 The model spent the whole turn “thinking” and never produced an answer or tool call — it ran out of room. Raise **Max tokens** in Options, or pick a coding model like **Qwen2.5-Coder** in the Model picker (reasoning models such as Gemma over-think for agent work)."
                            : "⚠️ The model returned nothing usable. Pick a coding model like **Qwen2.5-Coder** in the Model picker, or turn off native tool-calling in Options.")
                    }
                    return rawText
                }
                native = false
                calls = fallback
                convo.wire.append(ChatWireMessage(role: "assistant", content: rawText))
            }

            setBubbleText(idx, AgentTools.stripToolCallBlocks(from: rawText))
            attachTools(idx, calls)
            lastText = rawText
            if await executeRoleCalls(calls, convo: convo, bubbleIndex: idx, native: native, depth: depth) { return lastText }
        }
        appendInfo("\(role.emoji) \(role.displayName) reached its step limit.")
        return lastText
    }

    /// Execute a role's tool calls: delegation (recursive, parallel if >1), ask_user,
    /// todo_write, and ordinary file/web tools (approval-gated). Returns true if cancelled.
    private func executeRoleCalls(_ calls: [ParsedToolCall], convo: Convo, bubbleIndex: Int, native: Bool, depth: Int) async -> Bool {
        var fallbackResults = ""
        var delegations: [ParsedToolCall] = []

        for call in calls {
            if Task.isCancelled { return true }

            // Delegation → collect (run together for parallelism after the loop).
            if TeamRole.role(forCallTool: call.name) != nil {
                delegations.append(call)
                continue
            }

            // ask_user → pause for the user's reply (free text or a picked option).
            if call.name == AgentToolName.askUser.rawValue {
                let question = stringArg(call.argumentsJSON, "question") ?? "Could you clarify?"
                let options = Self.parseOptions(call.argumentsJSON)
                setTool(bubbleIndex, call.id) { $0.status = .running }
                let answer = await askUser(question, options: options)
                if Task.isCancelled { return true }
                setTool(bubbleIndex, call.id) { $0.status = .done; $0.output = "You: \(answer)" }
                feedBack(native: native, convo: convo, callID: call.id, name: call.name, body: answer, into: &fallbackResults)
                continue
            }

            // todo_write → update the shared plan.
            if call.name == AgentToolName.todoWrite.rawValue {
                let ack = applyTodoWrite(call.argumentsJSON)
                setTool(bubbleIndex, call.id) { $0.status = .done; $0.output = ack }
                feedBack(native: native, convo: convo, callID: call.id, name: call.name, body: ack, into: &fallbackResults)
                continue
            }

            // remember → save a durable lesson to the project's evolving memory.
            if call.name == AgentToolName.remember.rawValue {
                let lesson = stringArg(call.argumentsJSON, "lesson")
                    ?? stringArg(call.argumentsJSON, "text") ?? ""
                var ack = "Memory off."
                if settings.evolve, let ws = workspaceURL {
                    ack = AgentMemoryService.shared.add(lesson, for: ws)
                        ? "Saved to project memory." : "Already known — not duplicated."
                }
                setTool(bubbleIndex, call.id) { $0.status = .done; $0.output = ack }
                feedBack(native: native, convo: convo, callID: call.id, name: call.name, body: ack, into: &fallbackResults)
                continue
            }

            // Ordinary file / web tool.
            if let diff = executor.previewDiff(name: call.name, argumentsJSON: call.argumentsJSON) {
                setTool(bubbleIndex, call.id) { $0.detail = diff }
            }
            let tool = AgentToolName(rawValue: call.name)
            let autoApproved = (tool?.isReadOnly ?? false)
                || ((tool == .writeFile || tool == .editFile) && settings.autoApproveEdits)
                || (tool == .runCommand && settings.autoRunCommands)
            if !autoApproved {
                setTool(bubbleIndex, call.id) { $0.status = .pendingApproval }
                let approved = await requestApproval(call)
                if Task.isCancelled { return true }
                if !approved {
                    setTool(bubbleIndex, call.id) { $0.status = .denied; $0.isError = true; $0.output = "Denied by user." }
                    feedBack(native: native, convo: convo, callID: call.id, name: call.name,
                             body: "The user denied permission to run \(call.name).", into: &fallbackResults)
                    continue
                }
            }
            setTool(bubbleIndex, call.id) { $0.status = .running }
            let result = await executor.execute(name: call.name, argumentsJSON: call.argumentsJSON)
            setTool(bubbleIndex, call.id) {
                $0.status = .done; $0.isError = result.isError; $0.output = result.output
                if let d = result.displayDetail { $0.detail = d }
            }
            feedBack(native: native, convo: convo, callID: call.id, name: call.name, body: result.output, into: &fallbackResults)
        }

        if !delegations.isEmpty {
            let results = await runDelegations(delegations, depth: depth)
            for (call, output) in results {
                setTool(bubbleIndex, call.id) { $0.status = .done; $0.output = output }
                feedBack(native: native, convo: convo, callID: call.id, name: call.name, body: output, into: &fallbackResults)
            }
        }

        if !native && !fallbackResults.isEmpty {
            convo.wire.append(ChatWireMessage(role: "user", content: fallbackResults))
        }
        return false
    }

    /// Run delegate sub-agents — concurrently when there's more than one (the
    /// orchestrator dispatching coder + ui in the same turn = parallel).
    private func runDelegations(_ calls: [ParsedToolCall], depth: Int) async -> [(ParsedToolCall, String)] {
        guard depth < Self.maxDelegationDepth else {
            return calls.map { ($0, "Delegation depth limit reached (\(Self.maxDelegationDepth)).") }
        }
        // Sequential when parallelism is off (or only one call): run each delegate
        // to completion before starting the next, so only one request is ever in
        // flight on the shared server — gentler on a smaller model.
        if !settings.parallelAgents || calls.count == 1 {
            var results: [(ParsedToolCall, String)] = []
            for call in calls {
                results.append((call, await runDelegate(call, depth: depth)))
            }
            return results
        }
        // Parallel: start each delegate concurrently; they interleave at their await
        // points (model requests) on the single shared server. Unstructured Tasks
        // inherit the @MainActor context.
        let started = calls.map { call in Task { await self.runDelegate(call, depth: depth) } }
        var results: [(ParsedToolCall, String)] = []
        for (call, task) in zip(calls, started) {
            results.append((call, await task.value))
        }
        return results
    }

    private func runDelegate(_ call: ParsedToolCall, depth: Int) async -> String {
        guard let role = TeamRole.role(forCallTool: call.name) else { return "Unknown delegate." }
        let task = stringArg(call.argumentsJSON, "task") ?? ""
        let convo = Convo([systemMessage(role), ChatWireMessage(role: "user", content: task)])
        return await runRole(role, convo: convo, depth: depth + 1)
    }

    // MARK: User interaction

    private func askUser(_ question: String, options: [String] = []) async -> String {
        pendingQuestion = UserQuestion(question: question, options: options)
        let answer = await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
            self.answerContinuation = c
        }
        pendingQuestion = nil
        return answer
    }

    /// Pull `options` out of an ask_user call's arguments. `ChatToolProperty` is
    /// string-only, so models pass a JSON array (native models) or a stringified
    /// one. Be lenient: accept a JSON array, or fall back to splitting on newlines
    /// / "|" / commas. Empty result → a free-text question.
    static func parseOptions(_ argumentsJSON: String) -> [String] {
        guard let data = argumentsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["options"] else { return [] }

        func clean(_ items: [String]) -> [String] {
            var seen = Set<String>(), out: [String] = []
            for item in items {
                let t = item.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty, seen.insert(t).inserted { out.append(t) }
            }
            return Array(out.prefix(6))
        }

        if let arr = raw as? [String] { return clean(arr) }
        if let arr = raw as? [Any] { return clean(arr.map { String(describing: $0) }) }
        if let s = raw as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if let d = trimmed.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: d) as? [Any] {
                return clean(arr.map { String(describing: $0) })
            }
            let seps = CharacterSet(charactersIn: "\n|")
            var parts = trimmed.components(separatedBy: seps)
            if parts.count < 2 { parts = trimmed.components(separatedBy: ",") }
            return clean(parts)
        }
        return []
    }

    private func requestApproval(_ call: ParsedToolCall) async -> Bool {
        pendingApproval = PendingApproval(id: call.id, name: call.name, argumentsJSON: call.argumentsJSON)
        let decision = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            self.approvalContinuation = c
        }
        pendingApproval = nil
        return decision
    }

    // MARK: Helpers

    private func feedBack(native: Bool, convo: Convo, callID: String, name: String, body: String, into fallback: inout String) {
        if native {
            convo.wire.append(ChatWireMessage(role: "tool", content: body, toolCallID: callID, name: name))
        } else {
            fallback += "<tool_result name=\"\(name)\">\n\(body)\n</tool_result>\n"
        }
    }

    private func applyTodoWrite(_ argumentsJSON: String) -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        var raw: [Any] = []
        if let arr = args["todos"] as? [Any] { raw = arr }
        else if let str = args["todos"] as? String,
                let parsed = try? JSONSerialization.jsonObject(with: Data(str.utf8)) as? [Any] { raw = parsed }
        var items: [TodoItem] = []
        for entry in raw {
            guard let obj = entry as? [String: Any], let content = obj["content"] as? String else { continue }
            let status = TodoItem.Status(rawValue: (obj["status"] as? String) ?? "pending") ?? .pending
            items.append(TodoItem(content: content, status: status))
        }
        guard !items.isEmpty else { return "No valid todos provided." }
        todos = items
        let done = items.filter { $0.status == .completed }.count
        return "Plan updated: \(done)/\(items.count) done."
    }

    private func stringArg(_ argumentsJSON: String, _ key: String) -> String? {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        return args[key] as? String
    }

    /// Bound the conversation we re-send so it stays within the context window.
    private func prune(_ wire: [ChatWireMessage], budget: Int = 48_000) -> [ChatWireMessage] {
        guard let system = wire.first, wire.count > 4 else { return wire }
        var kept: [ChatWireMessage] = []
        var total = 0
        for msg in wire.dropFirst().reversed() {
            total += (msg.content?.count ?? 0) + 256
            kept.insert(msg, at: 0)
            if total > budget { break }
        }
        while let first = kept.first,
              first.role == "tool" || (first.role == "assistant" && first.toolCalls?.isEmpty == false) {
            kept.removeFirst()
            if kept.isEmpty { break }
        }
        return [system] + kept
    }

    private func systemMessage(_ role: TeamRole) -> ChatWireMessage {
        var content = role.systemPrompt(workspace: workspaceURL?.path ?? "(no project folder selected)",
                                        overview: workspaceOverview(),
                                        nativeTools: settings.useNativeTools)
        // Project conventions: ingest an AGENTS.md / CLAUDE.md-style file from the
        // workspace root — the offline, Swift-native equivalent of what Codex /
        // opencode / pi auto-read — so a small local model picks up THIS project's
        // build/test commands, layout, and do-nots without being told each turn.
        // Before the memory block so a learned lesson can still override a stale one.
        if let conventions = workspaceConventions() {
            content += "\n\n" + conventions
        }
        // The "evolving agent": fold in what we've learned about THIS project on
        // past runs, and tell the role it can save new durable lessons.
        if settings.evolve, let ws = workspaceURL {
            let block = AgentMemoryService.shared.promptBlock(for: ws)
            if !block.isEmpty { content += "\n\n" + block }
            content += "\n\nIf you discover a durable, reusable fact about this project (a build/test/run command, a convention, a gotcha to avoid), call the `remember` tool to save it for next time."
        }
        // Agent Skills — Stage 1 (discovery): list only each skill's name +
        // description so the agent knows WHEN to use one, without spending context
        // on the full instructions. It loads those on demand with use_skill.
        let skills = availableSkills(for: role)
        if !skills.isEmpty {
            let lines = skills.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
            content += """


            ## Skills available to you
            These are reusable instruction packages. When a task matches a skill's description, call `use_skill` with its name to load the full instructions, then follow them.
            \(lines)
            """
        }
        // Parallelism directive — reflects the "Run teammates in parallel" toggle.
        // Only relevant to a role that can delegate to more than one teammate (the
        // orchestrator). Without this the model follows its base prompt's "call
        // them in the same turn" guidance even when the user turned parallel OFF,
        // so it keeps narrating/attempting parallel dispatch. The runtime already
        // serializes execution when off (runDelegations), but the model's PLAN
        // should match the setting too.
        if role.delegates.count > 1 {
            if settings.parallelAgents {
                content += "\n\n## Teammate dispatch: PARALLEL is ON\nWhen two teammates' tasks are independent, dispatch them together (emit both `call_*` tool calls in the SAME turn) so they run concurrently. Only serialize when one genuinely depends on another's output."
            } else {
                content += "\n\n## Teammate dispatch: ONE AT A TIME\nParallel teammates are turned OFF. Dispatch teammates SEQUENTIALLY: emit exactly ONE `call_*` tool call per turn, wait for its result, then dispatch the next. Do NOT emit multiple `call_*` calls in the same turn, and do not describe the work as running \"in parallel\"."
            }
        }
        return ChatWireMessage(role: "system", content: content)
    }

    /// Read a project-conventions file from the workspace root if present — the
    /// offline, Swift-native equivalent of the AGENTS.md / CLAUDE.md file every
    /// reference coding agent (OpenAI Codex, opencode, pi) auto-ingests. Returns a
    /// budget-clamped block ready to append to the system prompt, or nil. First
    /// match wins, in rough order of community convention.
    private func workspaceConventions(limit: Int = 8_000) -> String? {
        guard let dir = workspaceURL else { return nil }
        let candidates = ["AGENTS.md", "CLAUDE.md", ".cursorrules", ".github/copilot-instructions.md"]
        for name in candidates {
            let url = dir.appendingPathComponent(name)
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let body = trimmed.count > limit
                ? String(trimmed.prefix(limit)) + "\n(…truncated)"
                : trimmed
            return "## Project conventions (from \(name))\n"
                 + "Follow these unless the user says otherwise:\n\n\(body)"
        }
        return nil
    }

    private func workspaceOverview(limit: Int = 40) -> String? {
        guard let dir = workspaceURL,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return nil }
        let skip: Set<String> = ["node_modules", ".build", "build", "DerivedData", ".venv", "bin", "obj"]
        let names = entries
            .filter { !skip.contains($0.lastPathComponent) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(limit)
            .map { url -> String in
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return isDir ? url.lastPathComponent + "/" : url.lastPathComponent
            }
        guard !names.isEmpty else { return nil }
        return names.joined(separator: "\n") + (entries.count > limit ? "\n… and more" : "")
    }

    // MARK: Transcript mutation

    private func appendStreamingBubble(role: TeamRole, depth: Int) -> Int {
        transcript.append(AgentBubble(role: .assistant, text: "", isStreaming: true, teamRole: role, depth: depth))
        return transcript.count - 1
    }

    private func appendToBubble(_ idx: Int, _ delta: String) {
        guard transcript.indices.contains(idx) else { return }
        transcript[idx].text += delta
    }

    private func appendReasoning(_ idx: Int, _ delta: String) {
        guard transcript.indices.contains(idx) else { return }
        transcript[idx].reasoning += delta
    }

    private func setBubbleText(_ idx: Int, _ text: String) {
        guard transcript.indices.contains(idx) else { return }
        transcript[idx].text = text
    }

    private func attachTools(_ idx: Int, _ calls: [ParsedToolCall]) {
        guard transcript.indices.contains(idx) else { return }
        transcript[idx].toolCalls = calls.map {
            AgentToolCallView(id: $0.id, name: $0.name, argumentsJSON: $0.argumentsJSON, status: .running)
        }
    }

    private func finalizeBubble(_ idx: Int) {
        guard transcript.indices.contains(idx) else { return }
        transcript[idx].isStreaming = false
    }

    private func appendInfo(_ text: String) {
        transcript.append(AgentBubble(role: .info, text: text))
    }

    private func recordError(_ message: String) {
        lastError = message
        appendInfo("⚠️ \(message)")
    }

    private func setTool(_ bubbleIndex: Int, _ callID: String, _ mutate: (inout AgentToolCallView) -> Void) {
        guard transcript.indices.contains(bubbleIndex),
              let i = transcript[bubbleIndex].toolCalls.firstIndex(where: { $0.id == callID }) else { return }
        mutate(&transcript[bubbleIndex].toolCalls[i])
    }
}
