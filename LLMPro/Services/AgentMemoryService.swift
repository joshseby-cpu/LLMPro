import Foundation
import CryptoKit

// The "evolving agent": a lightweight, per-project EXPERIENTIAL MEMORY for the
// Code-tab team. It is the in-context complement to the (heavyweight) fine-tuning
// Practice loop — the agent gets better at a project across sessions WITHOUT
// touching model weights, by remembering durable lessons and reusing them.
//
// Shape (faithful to the MS Agent Framework memory pattern — before_run inject /
// after_run extract — and to self-evolving-agent work): each project has ONE
// Markdown file (a list of `- ` bullet lessons) under PathResolver.agentMemoryDir.
//   • BEFORE a task: `promptBlock(for:)` is injected into the agent's system prompt.
//   • DURING a task: the agent may call the `remember` tool to save a lesson.
//   • AFTER a task: `reflect(...)` makes one cheap LLM call to extract new durable
//     lessons and appends them (deduped).
//   • When the file grows past `cap`, `consolidate(...)` merges/prunes it.
//
// Everything is plain Markdown so the user (or the agent) can read and edit it.

@MainActor
@Observable
final class AgentMemoryService {
    static let shared = AgentMemoryService()
    private init() {}

    /// Soft ceiling on stored lessons per project before we consolidate.
    let cap = 40
    /// Most lessons to inject into a single prompt (newest-last bias).
    let promptCap = 25
    /// Most new lessons to accept from one reflection pass.
    let reflectMax = 5

    /// Bumped on every mutation so SwiftUI views (the memory editor, the Options
    /// count badge) refresh.
    private(set) var revision = 0

    private let fm = FileManager.default

    // MARK: File mapping

    /// One Markdown file per project: `<sanitized-name>-<short-hash>.md`. The hash
    /// is a STABLE digest of the absolute path (Swift's `hashValue` is randomized
    /// per process, so we use MD5) — keeps the file stable across launches while
    /// staying human-identifiable in Finder.
    func fileURL(for workspace: URL) -> URL {
        let path = workspace.standardizedFileURL.path
        let digest = Insecure.MD5.hash(data: Data(path.utf8))
        let short = digest.prefix(3).map { String(format: "%02x", $0) }.joined()
        let name = workspace.lastPathComponent
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { acc, ch in if !(ch == "-" && acc.hasSuffix("-")) { acc.append(ch) } }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let slug = name.isEmpty ? "project" : name
        return PathResolver.agentMemoryDir.appendingPathComponent("\(slug)-\(short).md")
    }

    // MARK: Read

    /// The durable lessons for a project, in file order (oldest → newest).
    func memories(for workspace: URL) -> [String] {
        Self.parse(rawMarkdown(for: workspace))
    }

    func count(for workspace: URL) -> Int { memories(for: workspace).count }

    /// Raw Markdown for the editor (empty string if none yet).
    func rawMarkdown(for workspace: URL) -> String {
        (try? String(contentsOf: fileURL(for: workspace), encoding: .utf8)) ?? ""
    }

    /// The block injected into the agent's system prompt before a task. Empty when
    /// there's nothing learned yet.
    func promptBlock(for workspace: URL) -> String {
        let all = memories(for: workspace)
        guard !all.isEmpty else { return "" }
        let shown = all.suffix(promptCap)
        let bullets = shown.map { "- \($0)" }.joined(separator: "\n")
        return """
        ## What you've learned about THIS project (durable memory)
        These are lessons saved from past sessions in this exact project folder. Trust them, build on them, and don't relearn what's already here.
        \(bullets)
        """
    }

    // MARK: Write

    /// Append one lesson if it isn't already present (case/space-insensitive).
    @discardableResult
    func add(_ text: String, for workspace: URL) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        var all = memories(for: workspace)
        let keys = Set(all.map(Self.normalize))
        guard !keys.contains(Self.normalize(clean)) else { return false }
        all.append(clean)
        writeBullets(all, for: workspace)
        return true
    }

    /// Append several lessons (deduped). Returns how many were actually new.
    @discardableResult
    func addMany(_ texts: [String], for workspace: URL) -> Int {
        var all = memories(for: workspace)
        var keys = Set(all.map(Self.normalize))
        var added = 0
        for t in texts {
            let clean = t.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = Self.normalize(clean)
            guard !clean.isEmpty, !keys.contains(key) else { continue }
            all.append(clean); keys.insert(key); added += 1
        }
        if added > 0 { writeBullets(all, for: workspace) }
        return added
    }

    /// Replace the whole list (used by the editor's Save and by consolidation).
    func replaceAll(_ texts: [String], for workspace: URL) {
        writeBullets(texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
                     for: workspace)
    }

    /// Save raw Markdown straight from the editor.
    func saveRaw(_ markdown: String, for workspace: URL) {
        try? markdown.write(to: fileURL(for: workspace), atomically: true, encoding: .utf8)
        revision += 1
    }

    func clear(for workspace: URL) {
        try? fm.removeItem(at: fileURL(for: workspace))
        revision += 1
    }

    private func writeBullets(_ bullets: [String], for workspace: URL) {
        let body = bullets.map { "- \($0)" }.joined(separator: "\n")
        let doc = """
        # Project memory — \(workspace.lastPathComponent)
        <!-- Durable lessons the coding agent learned here. One per line, starting with "- ".
             Edited by the agent (reflection + the remember tool) and by you. -->

        \(body)
        """
        try? doc.write(to: fileURL(for: workspace), atomically: true, encoding: .utf8)
        revision += 1
    }

    // MARK: Reflection (the "evolve" step) — after_run

    /// After a finished task, extract durable lessons from what happened and append
    /// them. One cheap, bounded LLM call on the already-loaded model. Returns the
    /// number of new lessons added. Safe to call fire-and-forget.
    @discardableResult
    func reflect(task: String, outcome: String, workspace: URL, modelArg: String) async -> Int {
        guard MLXServerService.shared.isReady else { return 0 }
        let existing = memories(for: workspace)
        let existingBlock = existing.isEmpty ? "(none yet)" : existing.map { "- \($0)" }.joined(separator: "\n")

        let system = """
        You are the MEMORY module of a coding agent that works in ONE project folder. After a task, extract DURABLE, REUSABLE facts and lessons about THIS project that will help on FUTURE tasks — e.g. the build / test / run commands, the framework and versions, the directory layout, naming/style conventions, key decisions, and mistakes to avoid next time. Ignore transient details (specific values, one-off requests, anything not reusable). Do NOT repeat anything already in the existing memory.
        Output ONLY a compact JSON array of short strings (each ≤ 16 words), at most \(reflectMax) items. If there is nothing durable worth saving, output [].
        """
        let user = """
        EXISTING MEMORY (do not repeat):
        \(existingBlock)

        TASK THE USER ASKED FOR:
        \(task.prefix(1500))

        WHAT HAPPENED / RESULT:
        \(outcome.prefix(3000))

        Return the JSON array of NEW durable lessons to add.
        """

        let request = ChatCompletionRequest(
            model: modelArg,
            messages: [ChatWireMessage(role: "system", content: system),
                       ChatWireMessage(role: "user", content: user)],
            tools: nil,
            temperature: 0.0,
            maxTokens: 400,
            chatTemplateKwargs: ["enable_thinking": false])

        guard let text = try? await client.complete(request).firstText else { return 0 }
        let lessons = Self.parseStringArray(text)
        guard !lessons.isEmpty else { return 0 }
        let added = addMany(Array(lessons.prefix(reflectMax)), for: workspace)
        if added > 0, memories(for: workspace).count > cap {
            await consolidate(workspace: workspace, modelArg: modelArg)
        }
        return added
    }

    /// Merge/dedup/prune an over-cap memory down to the most useful lessons. One
    /// LLM call; replaces the file only if it returns a sane non-empty list.
    func consolidate(workspace: URL, modelArg: String) async {
        guard MLXServerService.shared.isReady else { return }
        let all = memories(for: workspace)
        guard all.count > cap else { return }
        let system = """
        You tidy a coding agent's project memory. Merge duplicates and overlaps, drop anything transient or obsolete, and keep the most useful DURABLE facts and lessons. Preserve concrete commands and conventions. Output ONLY a compact JSON array of short strings, at most \(cap) items, ordered most-useful first.
        """
        let request = ChatCompletionRequest(
            model: modelArg,
            messages: [ChatWireMessage(role: "system", content: system),
                       ChatWireMessage(role: "user", content: all.map { "- \($0)" }.joined(separator: "\n"))],
            tools: nil,
            temperature: 0.0,
            maxTokens: 1200,
            chatTemplateKwargs: ["enable_thinking": false])
        guard let text = try? await client.complete(request).firstText else { return }
        let merged = Self.parseStringArray(text)
        if merged.count >= 3 { replaceAll(Array(merged.prefix(cap)), for: workspace) }
    }

    private var client: OpenAIChatClient {
        OpenAIChatClient(baseURL: MLXServerService.shared.baseURL ?? URL(string: "http://127.0.0.1:8080/v1")!, timeout: 600)
    }

    // MARK: Parsing helpers

    /// Pull `- ` bullets out of the Markdown file (ignores headers/comments).
    static func parse(_ markdown: String) -> [String] {
        var out: [String] = []
        for raw in markdown.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("- ") || line.hasPrefix("* ") else { continue }
            let text = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { out.append(text) }
        }
        return out
    }

    /// Parse an LLM reply into a list of strings: a JSON array if present, else the
    /// `- `/numbered bullet lines. Tolerant of markdown fences and surrounding prose.
    static func parseStringArray(_ reply: String) -> [String] {
        var s = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        if let lo = s.firstIndex(of: "["), let hi = s.lastIndex(of: "]"), lo < hi {
            let slice = String(s[lo...hi])
            if let data = slice.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] {
                let items = arr.compactMap { ($0 as? String) ?? ($0 as? CustomStringConvertible).map { "\($0)" } }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && $0.lowercased() != "none" }
                if !items.isEmpty { return items }
            }
        }
        // Fallback: bullet / numbered lines.
        var out: [String] = []
        for raw in s.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            for p in ["- ", "* ", "• "] { if line.hasPrefix(p) { line = String(line.dropFirst(p.count)) } }
            while let f = line.first, f.isNumber || f == "." || f == ")" || f == " " { line.removeFirst() }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.count >= 3, line.lowercased() != "none" { out.append(line) }
        }
        return out
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
