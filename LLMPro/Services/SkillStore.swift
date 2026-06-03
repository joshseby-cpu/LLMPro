import Foundation
import SwiftUI

// SKILL.md packages for the coding agent — Agent Skills, modeled on the
// OpenAI Codex / Anthropic standard. Each skill is a folder under
// PathResolver.skillsDir containing a `SKILL.md` with YAML-ish frontmatter and a
// markdown instructions body, plus any optional bundled files. The folder name is
// the skill's stable id.
//
// Frontmatter fields:
//   name:        display name
//   description: when to use this skill (the agent matches on this)
//   skills:      [ids] of OTHER skills this one links to (skill→skill). When the
//                agent loads this skill, the linked skills are surfaced too.
//
// Skills are edited as RAW MARKDOWN (parity with the team agents) — see
// SkillsManagerView. Agents link to skills via their own `skills:` frontmatter
// (skill→agent); see AgentStore / CodingAgentService.
//
// Progressive disclosure: the agent only sees each available skill's name +
// description in its system prompt, and pulls the full instructions on demand
// with the `use_skill` tool (see AgentTools / CodingAgentService).

/// What the agent loop actually carries for a skill (Sendable so it can cross
/// into the ToolExecutor).
struct SkillContext: Sendable, Hashable {
    let id: String
    let name: String
    let description: String
    let instructions: String
    var links: [String] = []        // ids of skills this one links to (skill→skill)
    var dirPath: String = ""        // absolute path to the skill folder, so the
                                    // agent can read bundled scripts/references/assets
}

struct Skill: Identifiable, Hashable, Sendable {
    let id: String                 // folder name
    var name: String
    var description: String
    var instructions: String
    var links: [String]            // linked skill ids (skill→skill)
    let dirURL: URL

    var markdownURL: URL { dirURL.appendingPathComponent("SKILL.md") }
    var context: SkillContext {
        SkillContext(id: id, name: name, description: description,
                     instructions: instructions, links: links, dirPath: dirURL.path)
    }
}

@MainActor
@Observable
final class SkillStore {
    static let shared = SkillStore()

    private(set) var skills: [Skill] = []

    private init() {}

    /// Bumped on every mutation so SwiftUI views (the manager, the Options count)
    /// refresh even though `skills` is the same array type.
    private(set) var revision = 0

    /// Call once at launch: scan the skills directory, then (the first time only)
    /// seed a couple of example skills so the feature isn't empty. Seeding is
    /// one-shot via a UserDefaults flag, so a user who deletes the examples won't
    /// have them reappear after adding their own.
    func installDefaultsAndScan() {
        scan()
        if skills.isEmpty, !UserDefaults.standard.bool(forKey: "didSeedExampleSkills") {
            for ex in Self.exampleSkills {
                _ = create(name: ex.name, description: ex.description, instructions: ex.instructions)
            }
            UserDefaults.standard.set(true, forKey: "didSeedExampleSkills")
            scan()
        }
    }

    /// Two instruction-only starter skills demonstrating the SKILL.md format.
    /// Users edit or delete them in the Skills manager; custom skills sit alongside.
    private static let exampleSkills: [(name: String, description: String, instructions: String)] = [
        ("conventional-commits",
         "Use when writing a git commit message. Produces a Conventional Commits–style message from the staged changes.",
         """
         ## When to use
         Whenever you are about to write or suggest a git commit message.

         ## How to write the message
         Use the Conventional Commits format:
         `<type>(<optional scope>): <short summary>`

         - **type** is one of: feat, fix, docs, style, refactor, perf, test, build, ci, chore.
         - Keep the summary in the imperative mood, ≤ 72 chars, no trailing period.
         - Add a blank line then a body explaining *why* (not what) when the change isn't trivial.
         - Note breaking changes with a `BREAKING CHANGE:` footer.

         Example:
         feat(auth): add refresh-token rotation
         """),
        ("code-reviewer",
         "Use when asked to review code or a diff. Checks for correctness, security, and clarity before approving.",
         """
         ## When to use
         When the user asks you to review code, a pull request, or a diff.

         ## Review checklist
         Go through these in order and report concrete findings (file:line where possible):
         1. Correctness — off-by-one, nil/undefined, wrong operator, missed edge cases, error paths.
         2. Security — injection, path traversal, unvalidated input, secrets in code.
         3. Resource safety — leaks, unbounded loops, N+1 queries, blocking the main thread.
         4. Clarity — dead code, misleading names, missing or false comments.

         For each finding give: severity (blocker / major / minor), the location, and a suggested fix.
         End with an overall verdict: approve, approve-with-nits, or request-changes.
         """),
    ]

    // MARK: Lookup

    func skill(id: String) -> Skill? { skills.first { $0.id == id } }

    func contexts(for ids: [String]) -> [SkillContext] {
        ids.compactMap { skill(id: $0)?.context }
    }

    func scan() {
        let fm = FileManager.default
        var found: [Skill] = []
        if let entries = try? fm.contentsOfDirectory(at: PathResolver.skillsDir,
                                                     includingPropertiesForKeys: [.isDirectoryKey]) {
            for entry in entries where entry.hasDirectoryPath {
                let md = entry.appendingPathComponent("SKILL.md")
                guard let text = try? String(contentsOf: md, encoding: .utf8) else { continue }
                let parsed = Self.parse(text)
                let id = entry.lastPathComponent
                found.append(Skill(
                    id: id,
                    name: parsed.name ?? id,
                    description: parsed.description ?? "",
                    instructions: parsed.body,
                    links: parsed.links,
                    dirURL: entry))
            }
        }
        skills = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        revision += 1
    }

    // MARK: Raw-markdown access (parity with AgentStore — the manager edits this)

    func fileURL(for id: String) -> URL {
        PathResolver.skillsDir.appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("SKILL.md")
    }

    /// Raw SKILL.md text for a skill (empty string if missing).
    func markdown(for id: String) -> String {
        (try? String(contentsOf: fileURL(for: id), encoding: .utf8)) ?? ""
    }

    /// Write raw edited markdown for an existing skill and reload.
    func save(id: String, markdown: String) {
        let dir = PathResolver.skillsDir.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? markdown.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        scan()
    }

    // MARK: CRUD

    @discardableResult
    func create(name: String, description: String = "", instructions: String = "",
                links: [String] = []) -> Skill {
        let id = uniqueFolderID(from: name)
        let dir = PathResolver.skillsDir.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let skill = Skill(id: id, name: name, description: description,
                          instructions: instructions, links: links, dirURL: dir)
        write(skill)
        scan()
        return skill
    }

    /// Rewrite SKILL.md from a structured Skill value. The folder id is
    /// intentionally NOT changed so references to it survive an edit.
    func save(_ skill: Skill) {
        write(skill)
        scan()
    }

    func delete(id: String) {
        let dir = PathResolver.skillsDir.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        // Scrub this id from any other skill's links so we don't leave danglers.
        for other in skills where other.id != id && other.links.contains(id) {
            var s = other; s.links.removeAll { $0 == id }; write(s)
        }
        scan()
    }

    /// Duplicate a skill into a new one (id-unique). Links are copied as-is.
    @discardableResult
    func duplicate(id: String) -> Skill? {
        guard let s = skill(id: id) else { return nil }
        return create(name: s.name + " copy", description: s.description,
                      instructions: s.instructions, links: s.links)
    }

    /// Import an existing skill folder (must contain SKILL.md) by copying it in.
    @discardableResult
    func importSkill(from source: URL) -> Skill? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.appendingPathComponent("SKILL.md").path) else { return nil }
        let id = uniqueFolderID(from: source.lastPathComponent)
        let dest = PathResolver.skillsDir.appendingPathComponent(id, isDirectory: true)
        try? fm.copyItem(at: source, to: dest)
        scan()
        return skill(id: id)
    }

    // MARK: - SKILL.md I/O

    private func write(_ skill: Skill) {
        var fm = ["---", "name: \(skill.name)", "description: \(skill.description)"]
        if !skill.links.isEmpty { fm.append("skills: [\(skill.links.joined(separator: ", "))]") }
        fm.append("---")
        let md = fm.joined(separator: "\n") + "\n\n" + skill.instructions + "\n"
        try? md.data(using: .utf8)?.write(to: skill.markdownURL)
    }

    /// Parse `---\nname: …\ndescription: …\nskills: [a, b]\n---\n<body>`. Tolerant
    /// of a missing frontmatter block (treats the whole file as the body). The
    /// `skills:` key also accepts the alias `links:`.
    static func parse(_ rawText: String) -> (name: String?, description: String?, links: [String], body: String) {
        // Safety net: macOS smart-dash substitution can turn typed `---` fences
        // into `—`/`–`. Normalize any dash-only fence line back to `---` so such a
        // file still parses (the editor now disables substitution, but older files
        // and hand-edits may still have it).
        let text = Self.normalizeFences(rawText)
        guard text.hasPrefix("---") else {
            return (nil, nil, [], text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let parts = text.components(separatedBy: "---")
        guard parts.count >= 3 else {
            return (nil, nil, [], text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var name: String?
        var description: String?
        var links: [String] = []
        for rawLine in parts[1].split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "name":           name = value
            case "description":    description = value
            case "skills", "links": links = parseList(value)
            default: break
            }
        }
        let body = parts[2...].joined(separator: "---").trimmingCharacters(in: .whitespacesAndNewlines)
        return (name, description, links, body)
    }

    /// Convert any line that is only dash-like characters (`-`, en-dash `–`,
    /// em-dash `—`) into a canonical `---` frontmatter fence. Fixes files whose
    /// fences were smart-substituted. Lines with other content are untouched.
    static func normalizeFences(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, t.allSatisfy({ $0 == "-" || $0 == "\u{2013}" || $0 == "\u{2014}" }) {
                return "---"
            }
            return String(line)
        }.joined(separator: "\n")
    }

    /// `[a, b, c]` or `a, b, c` → ["a","b","c"].
    private static func parseList(_ raw: String) -> [String] {
        var s = raw
        if s.hasPrefix("[") { s.removeFirst() }
        if s.hasSuffix("]") { s.removeLast() }
        return s.split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
            .filter { !$0.isEmpty }
    }

    func uniqueFolderID(from rawName: String) -> String {
        let base = rawName
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { acc, ch in
                if ch == "-" && acc.hasSuffix("-") { return }
                acc.append(ch)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let slug = base.isEmpty ? "skill" : base
        let fm = FileManager.default
        var candidate = slug
        var n = 2
        while fm.fileExists(atPath: PathResolver.skillsDir.appendingPathComponent(candidate).path) {
            candidate = "\(slug)-\(n)"
            n += 1
        }
        return candidate
    }
}
