import SwiftUI

// Markdown-defined team agents. Each Code-tab role (orchestrator / planner /
// researcher / coder / ui) is described by a `<role>.md` file with YAML-ish
// frontmatter and a system-prompt body:
//
//   ---
//   id: coder
//   name: Coder
//   emoji: 💻
//   tint: green
//   tools: [read_file, list_dir, glob, grep, write_file, edit_file, run_command, todo_write]
//   delegates: []
//   maxIterations: 28
//   ---
//   You are the CODER, a builder on the team. …
//
// The files are seeded from the app bundle on first launch into
// `PathResolver.agentsDir`, then editable by the user (or by an agent writing
// the file) — edits are preserved across launches. `TeamRole` reads the parsed
// override from `AgentStore.overrides`; its compiled-in values are the fallback
// when a file is missing, unparseable, or a field is absent.

/// One parsed agent definition. Optional fields distinguish "key absent → use
/// the role's compiled-in default" (nil) from "key present but empty" (e.g. an
/// explicit `delegates: []`).
struct AgentDefinition: Sendable, Identifiable {
    let id: String              // role raw value, e.g. "coder"
    var name: String?
    var emoji: String?
    var tint: String?
    var tools: [String]?
    var delegates: [String]?
    var skills: [String]?       // ids of Agent Skills this agent may use (skill→agent).
                               // nil = not specified → agent sees ALL skills (default).
    var maxIterations: Int?
    var prompt: String?         // system-prompt body (nil/empty → default header)
}

@MainActor
@Observable
final class AgentStore {
    static let shared = AgentStore()

    /// The built-in agents, in canonical display order. These ship as bundled
    /// markdown (seeded on first launch) and can be reset to default but NOT
    /// deleted. Custom agents the user creates are listed after these.
    nonisolated static let builtinOrder = ["orchestrator", "planner", "researcher", "coder", "ui"]

    /// The entry agent — the one the user talks to, which coordinates the rest.
    /// Always built-in and non-deletable so the team always has a front door.
    /// `nonisolated` so the (nonisolated) `TeamRole` value type can read it.
    nonisolated static let entryID = "orchestrator"

    func isBuiltin(_ id: String) -> Bool { Self.builtinOrder.contains(id) }

    /// Non-isolated snapshot read by `TeamRole`'s (non-isolated) computed
    /// properties. Written only on the main actor during `load()`, read as value
    /// copies elsewhere — safe by construction.
    nonisolated(unsafe) static var overrides: [String: AgentDefinition] = [:]
    /// Non-isolated ordered id list (built-ins first, then custom). Mirrors
    /// `definitions` order; `TeamRole.all` reads this without touching the actor.
    nonisolated(unsafe) static var orderedIDsSnapshot: [String] = []

    /// Parsed definitions in display order, for the editor UI to list.
    private(set) var definitions: [AgentDefinition] = []

    private let fm = FileManager.default

    /// Seed missing files from the bundle, then parse everything. Call once at launch.
    func installAndLoad() {
        installDefaultsIfNeeded()
        load()
    }

    /// Copy each bundled `<role>.md` to disk only if it isn't already there, so
    /// user edits survive launches (unlike the Python helpers, which we refresh
    /// every launch).
    func installDefaultsIfNeeded() {
        for id in Self.builtinOrder {
            let dest = fileURL(for: id)
            guard !fm.fileExists(atPath: dest.path), let src = bundleURL(for: id) else { continue }
            try? fm.copyItem(at: src, to: dest)
        }
    }

    /// Re-parse every agent markdown file into `definitions` and the snapshots.
    /// Order: built-ins first (canonical), then custom agents (the user's, by id).
    func load() {
        var ids = Self.builtinOrder
        if let files = try? fm.contentsOfDirectory(at: PathResolver.agentsDir,
                                                   includingPropertiesForKeys: nil) {
            let custom = files
                .filter { $0.pathExtension == "md" }
                .map { $0.deletingPathExtension().lastPathComponent }
                .filter { !Self.builtinOrder.contains($0) }
                .sorted()
            ids.append(contentsOf: custom)
        }
        let defs = ids.map { Self.parse(markdown(for: $0), id: $0) }
        definitions = defs
        AgentStore.overrides = Dictionary(uniqueKeysWithValues: defs.map { ($0.id, $0) })
        AgentStore.orderedIDsSnapshot = ids
    }

    // MARK: File access

    func fileURL(for id: String) -> URL {
        PathResolver.agentsDir.appendingPathComponent("\(id).md")
    }

    func bundleURL(for id: String) -> URL? {
        Bundle.main.url(forResource: id, withExtension: "md", subdirectory: "agents")
            ?? Bundle.main.url(forResource: id, withExtension: "md")
    }

    /// The raw markdown for a role: the on-disk file if present, else the bundled
    /// default, else "".
    func markdown(for id: String) -> String {
        if let text = try? String(contentsOf: fileURL(for: id), encoding: .utf8) { return text }
        if let src = bundleURL(for: id), let text = try? String(contentsOf: src, encoding: .utf8) { return text }
        return ""
    }

    /// The bundled default markdown for a role (ignores user edits).
    func defaultMarkdown(for id: String) -> String {
        guard let src = bundleURL(for: id), let text = try? String(contentsOf: src, encoding: .utf8) else { return "" }
        return text
    }

    /// Write edited markdown for a role and reload.
    func save(id: String, markdown: String) {
        try? markdown.write(to: fileURL(for: id), atomically: true, encoding: .utf8)
        load()
    }

    /// Restore a built-in agent's file to its bundled default and reload. Custom
    /// agents have no bundled default, so this is a no-op for them.
    func resetToDefault(id: String) {
        guard isBuiltin(id) else { return }
        let text = defaultMarkdown(for: id)
        if !text.isEmpty { try? text.write(to: fileURL(for: id), atomically: true, encoding: .utf8) }
        load()
    }

    // MARK: - CRUD (create / delete / duplicate custom agents)

    /// Create a new custom agent from fields, write its markdown, optionally wire
    /// it into the entry agent's delegates (so the Orchestrator can call it right
    /// away), and reload. Returns the new agent's id.
    @discardableResult
    func create(name: String, emoji: String = "🤖", tint: String = "",
                prompt: String = "", tools: [String] = ["read_file", "list_dir", "glob", "grep", "todo_write"],
                delegates: [String] = [], maxIterations: Int = 20,
                wireIntoEntry: Bool = true) -> String {
        let id = uniqueID(from: name)
        let md = Self.compose(id: id, name: name.isEmpty ? id.capitalized : name,
                              emoji: emoji, tint: tint, tools: tools,
                              delegates: delegates, maxIterations: maxIterations, prompt: prompt)
        try? md.write(to: fileURL(for: id), atomically: true, encoding: .utf8)
        if wireIntoEntry, id != Self.entryID { addDelegate(id, to: Self.entryID) }
        load()
        return id
    }

    /// Delete a custom agent (built-ins can't be deleted — reset them instead) and
    /// scrub it from every other agent's delegates. Returns true if deleted.
    @discardableResult
    func delete(id: String) -> Bool {
        guard !isBuiltin(id) else { return false }
        try? fm.removeItem(at: fileURL(for: id))
        for oid in allFileIDs() where oid != id {
            let dels = Self.parse(markdown(for: oid), id: oid).delegates ?? []
            if dels.contains(id) { setDelegates(dels.filter { $0 != id }, for: oid) }
        }
        load()
        return true
    }

    /// Duplicate any agent into a new custom agent (not auto-wired). Returns new id.
    @discardableResult
    func duplicate(id: String) -> String {
        let def = Self.parse(markdown(for: id), id: id)
        return create(name: (def.name ?? id.capitalized) + " copy",
                      emoji: def.emoji ?? "🤖", tint: def.tint ?? "",
                      prompt: def.prompt ?? "", tools: def.tools ?? [],
                      delegates: def.delegates ?? [], maxIterations: def.maxIterations ?? 20,
                      wireIntoEntry: false)
    }

    /// Add `delegateID` to `agentID`'s delegates (no-op if already present).
    func addDelegate(_ delegateID: String, to agentID: String) {
        var dels = Self.parse(markdown(for: agentID), id: agentID).delegates ?? []
        guard !dels.contains(delegateID) else { return }
        dels.append(delegateID)
        setDelegates(dels, for: agentID)
        load()
    }

    /// Rewrite an agent's `delegates:` frontmatter line (insert one if missing).
    func setDelegates(_ ids: [String], for agentID: String) {
        let line = "delegates: [\(ids.joined(separator: ", "))]"
        let updated = Self.replaceFrontmatterLine(markdown(for: agentID), key: "delegates", value: line)
        try? updated.write(to: fileURL(for: agentID), atomically: true, encoding: .utf8)
    }

    /// All agent ids that have a markdown file on disk (built-in or custom).
    private func allFileIDs() -> [String] {
        let onDisk = (try? fm.contentsOfDirectory(at: PathResolver.agentsDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "md" }
            .map { $0.deletingPathExtension().lastPathComponent } ?? []
        return Array(Set(onDisk).union(Self.builtinOrder))
    }

    /// Slugify a name into a unique, file-safe id (kebab-case), avoiding collisions
    /// with existing agents (built-in or on-disk).
    func uniqueID(from rawName: String) -> String {
        let slug = rawName.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { acc, ch in if !(ch == "-" && acc.hasSuffix("-")) { acc.append(ch) } }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let base = slug.isEmpty ? "agent" : slug
        let taken = Set(allFileIDs())
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    /// Build a complete agent markdown file from fields.
    static func compose(id: String, name: String, emoji: String, tint: String,
                        tools: [String], delegates: [String], maxIterations: Int,
                        prompt: String) -> String {
        var fm = ["---", "id: \(id)", "name: \(name)"]
        if !emoji.isEmpty { fm.append("emoji: \(emoji)") }
        if !tint.isEmpty { fm.append("tint: \(tint)") }
        fm.append("tools: [\(tools.joined(separator: ", "))]")
        fm.append("delegates: [\(delegates.joined(separator: ", "))]")
        fm.append("maxIterations: \(maxIterations)")
        fm.append("---")
        let body = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return fm.joined(separator: "\n") + "\n" + (body.isEmpty
            ? "You are the \(name) agent on a coding team. Carry out the task you are given using your tools, then return a short summary."
            : body) + "\n"
    }

    /// Replace (or insert) one `key:` line inside the leading `---` frontmatter
    /// block, preserving everything else. If the file has no frontmatter, wrap the
    /// whole thing in a minimal block with this line.
    static func replaceFrontmatterLine(_ text: String, key: String, value: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return "---\n\(value)\n---\n" + text   // no frontmatter: prepend a minimal one
        }
        // Find the closing --- of the frontmatter block.
        guard let closeIdx = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return text
        }
        var out = lines
        let keyPrefix = "\(key.lowercased()):"
        if let hit = (1..<closeIdx).first(where: {
            out[$0].trimmingCharacters(in: .whitespaces).lowercased().hasPrefix(keyPrefix)
        }) {
            out[hit] = value
        } else {
            out.insert(value, at: closeIdx)   // insert just before the closing ---
        }
        return out.joined(separator: "\n")
    }

    // MARK: Frontmatter parser

    /// Parse `---<frontmatter>---<body>`. Tolerant of a missing block (whole file
    /// becomes the prompt). Scalars: name/emoji/tint/maxIterations. Lists
    /// (`tools`, `delegates`) accept inline `[a, b, c]` or bare comma-separated.
    static func parse(_ rawText: String, id: String) -> AgentDefinition {
        // Normalize smart-dash-substituted fences (`—`/`–`) back to `---`.
        let text = SkillStore.normalizeFences(rawText)
        guard text.hasPrefix("---") else {
            let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return AgentDefinition(id: id, prompt: body.isEmpty ? nil : body)
        }
        let parts = text.components(separatedBy: "---")
        guard parts.count >= 3 else {
            let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return AgentDefinition(id: id, prompt: body.isEmpty ? nil : body)
        }

        var def = AgentDefinition(id: id)
        for rawLine in parts[1].split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "name":          def.name = value.isEmpty ? nil : value
            case "emoji":         def.emoji = value.isEmpty ? nil : value
            case "tint":          def.tint = value.isEmpty ? nil : value.lowercased()
            case "maxiterations": def.maxIterations = Int(value)
            case "tools":         def.tools = parseList(value)
            case "delegates":     def.delegates = parseList(value)
            case "skills":        def.skills = parseList(value)
            default: break
            }
        }
        let body = parts[2...].joined(separator: "---").trimmingCharacters(in: .whitespacesAndNewlines)
        def.prompt = body.isEmpty ? nil : body
        return def
    }

    /// `[a, b, c]` or `a, b, c` → ["a","b","c"]. Empty list → [] (explicit).
    private static func parseList(_ raw: String) -> [String] {
        var s = raw
        if s.hasPrefix("[") { s.removeFirst() }
        if s.hasSuffix("]") { s.removeLast() }
        return s.split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
            .filter { !$0.isEmpty }
    }
}
