import SwiftUI

// A team agent. Agents are DATA, not code: each one is defined by a markdown file
// (loaded and parsed by `AgentStore`) and identified by a string `id`. The user
// talks only to the ENTRY agent (id "orchestrator"), which coordinates the rest.
//
// Any agent can delegate to any other agent it lists in its `delegates:`
// frontmatter — each delegate `x` becomes a `call_x` tool on that agent. So agents
// reference other agents purely by id, and the team is fully dynamic: create,
// edit, and delete agents by adding/editing/removing markdown files (see
// `AgentStore` for the CRUD and `AgentsManagerView` for the editor).
//
// `TeamRole` is a thin value-type view over an agent's `AgentDefinition` in
// `AgentStore`, with safe fallbacks for any field a markdown file leaves out. (The
// name is historical — it used to be a fixed enum of five roles.)

struct TeamRole: Sendable, Identifiable, Hashable {
    let id: String
    init(_ id: String) { self.id = id }

    /// The parsed markdown definition for this agent — the source of truth.
    var resolved: AgentDefinition? { AgentStore.overrides[id] }

    // MARK: Registry

    /// Every agent, in display order (built-ins first, then custom).
    static var all: [TeamRole] { AgentStore.orderedIDsSnapshot.map { TeamRole($0) } }

    /// The entry agent the user talks to (it coordinates the others).
    static var entry: TeamRole { TeamRole(AgentStore.entryID) }
    var isEntry: Bool { id == AgentStore.entryID }

    /// An agent by id, or nil if no such agent is registered.
    static func byID(_ id: String) -> TeamRole? {
        AgentStore.overrides[id] != nil ? TeamRole(id) : nil
    }

    // MARK: Display

    var displayName: String { resolved?.name ?? id.capitalized }
    var emoji: String { resolved?.emoji ?? "🤖" }
    var tint: Color { resolved?.tint.flatMap(Self.color(named:)) ?? Self.fallbackTint(for: id) }
    var maxIterations: Int { max(1, resolved?.maxIterations ?? 20) }

    /// A "builder" writes files — used for the parallel-dispatch treatment and UI
    /// cues. Derived from the toolset, so a custom agent with write tools is
    /// automatically treated as a builder.
    var isBuilder: Bool { baseTools.contains(.writeFile) || baseTools.contains(.editFile) }

    /// Map a frontmatter `tint:` name to a SwiftUI color. Unknown → nil (fallback).
    static func color(named name: String) -> Color? {
        switch name.lowercased() {
        case "purple": .purple; case "blue": .blue; case "teal": .teal
        case "green": .green; case "orange": .orange; case "red": .red
        case "pink": .pink; case "yellow": .yellow; case "mint": .mint
        case "indigo": .indigo; case "cyan": .cyan; case "gray", "grey": .gray
        case "brown": .brown; case "primary": .primary
        default: nil
        }
    }

    /// Deterministic per-id fallback tint for an agent with no `tint:` set, so each
    /// custom agent still gets a stable, distinct color in the UI.
    private static func fallbackTint(for id: String) -> Color {
        let palette: [Color] = [.purple, .blue, .teal, .green, .orange, .pink, .indigo, .mint, .red, .brown, .cyan]
        var hash = 5381
        for byte in id.utf8 { hash = ((hash << 5) &+ hash) &+ Int(byte) }
        return palette[abs(hash) % palette.count]
    }

    // MARK: Tools & delegation

    /// Other agents this one can delegate to (→ `call_<id>` tools). Unknown ids in
    /// the markdown are dropped, so a dangling reference is ignored, not fatal.
    var delegates: [TeamRole] {
        (resolved?.delegates ?? []).compactMap { TeamRole.byID($0) }
    }

    /// Non-delegation tools this agent gets. Falls back to a safe read-only set.
    var baseTools: [AgentToolName] {
        if let raw = resolved?.tools { return raw.compactMap { AgentToolName(rawValue: $0) } }
        return Self.defaultTools
    }
    private static let defaultTools: [AgentToolName] = [.readFile, .listDir, .glob, .grep, .todoWrite]

    /// Which Agent Skills this agent may use (skill→agent link). The markdown's
    /// `skills:` frontmatter; `nil` (key absent) means "all installed skills" — the
    /// default, so existing agents keep seeing every skill. An explicit empty list
    /// opts out entirely.
    var skillIDs: [String]? { resolved?.skills }

    func toolSpecs() -> [ChatToolSpec] {
        var specs = AgentTools.specs(for: baseTools)
        for target in delegates { specs.append(TeamRole.delegationSpec(to: target)) }
        return specs
    }

    var callToolName: String { "call_\(id)" }

    static func role(forCallTool name: String) -> TeamRole? {
        guard name.hasPrefix("call_") else { return nil }
        return TeamRole.byID(String(name.dropFirst(5)))
    }

    static func delegationSpec(to role: TeamRole) -> ChatToolSpec {
        ChatToolSpec(function: ChatFunctionSpec(
            name: role.callToolName,
            description: "Delegate a task to the \(role.displayName) agent and get its result back.",
            parameters: ChatToolParameters(
                properties: ["task": ChatToolProperty(
                    type: "string",
                    description: "A clear, self-contained description of what the \(role.displayName) should do (it doesn't see this conversation).")],
                required: ["task"])))
    }

    // MARK: System prompt

    func systemPrompt(workspace: String, overview: String?, nativeTools: Bool = true) -> String {
        // The agent's "character" prompt is its markdown body; a generic line is
        // the fallback. The project folder, overview, the list of teammates it can
        // call, and the (native-vs-text) tool-calling instructions are always
        // appended here so they stay consistent across every agent.
        let header = (resolved?.prompt).flatMap { $0.isEmpty ? nil : $0 } ?? Self.genericHeader(self)

        var prompt = header

        let team = delegates
        if !team.isEmpty {
            let lines = team.map { "- \($0.callToolName)(task) — delegate to the \($0.displayName) agent." }
                .joined(separator: "\n")
            prompt += "\n\nYou can delegate to these teammates (each doesn't see this conversation, so give a self-contained task):\n\(lines)"
        }

        prompt += "\n\nProject folder (all file paths are relative to it):\n\(workspace)"
        if let overview, !overview.isEmpty {
            prompt += "\n\nTop level of the project:\n\(overview)"
        }
        if nativeTools {
            // Native function calling is on. Do NOT mention the <tool_call> text
            // format — some models (e.g. Gemma-4) will follow it and emit broken
            // JSON with their special tokens instead of using the clean native path.
            prompt += """


            Use your function-calling interface to make tool calls — one or more per turn. Take one step at a time. When you are finished, reply with a short plain-text summary and call no more tools.
            """
        } else {
            prompt += """


            Calling tools: emit each tool call on its own line in EXACTLY this format, with normal double quotes:
            <tool_call>{"name": "tool_name", "arguments": {"key": "value"}}</tool_call>
            Take one step at a time. When you are finished, reply with a short plain-text summary and DO NOT call any more tools.
            """
        }
        return prompt
    }

    /// Fallback prompt for an agent whose markdown body is empty.
    private static func genericHeader(_ role: TeamRole) -> String {
        "You are the \(role.displayName) agent on a coding team. Carry out the task you are given using your tools, then return a short, clear summary of what you did."
    }
}
