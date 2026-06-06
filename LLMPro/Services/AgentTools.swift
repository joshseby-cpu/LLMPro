import Foundation

// The tools the coding agent can call, their JSON-Schema definitions (sent to
// the model as the request `tools` array), a text fallback parser for models
// whose chat template can't emit native tool_calls, and the sandboxed executor
// that actually runs them against the user's project folder.
//
// Everything here is workspace-relative and path-escape-checked: a tool can
// only touch files at or under the chosen project root. Shell commands run with
// the project root as their working directory. Mutating tools (write/edit/run)
// are gated by an approval step in CodingAgentService — this file just executes
// whatever it's told and reports the result.

// MARK: - Tool catalogue

enum AgentToolName: String, CaseIterable, Sendable {
    case readFile    = "read_file"
    case listDir     = "list_dir"
    case glob        = "glob"
    case grep        = "grep"
    case writeFile   = "write_file"
    case editFile    = "edit_file"
    case runCommand  = "run_command"
    case useSkill    = "use_skill"
    case todoWrite   = "todo_write"
    case askUser     = "ask_user"
    case remember    = "remember"
    case webSearch   = "web_search"
    case fetchUrl    = "fetch_url"

    /// Read-only tools can't change anything, so they auto-run without an
    /// approval prompt. The rest mutate the workspace or run arbitrary code and
    /// are gated unless the user opted into auto-approve. `todo_write`, the web
    /// tools, `ask_user`, and `remember` never touch the workspace, so they're
    /// read-only too. The web tools only READ from the network (no posting),
    /// so they auto-run as well.
    var isReadOnly: Bool {
        switch self {
        case .readFile, .listDir, .glob, .grep, .useSkill, .todoWrite,
             .askUser, .remember, .webSearch, .fetchUrl: return true
        case .writeFile, .editFile, .runCommand: return false
        }
    }
}

enum AgentTools {
    static let maxOutputChars = 16_000
    static let commandTimeout: TimeInterval = 120

    /// Build the `tools` array for a specific set of tools (per-role).
    static func specs(for tools: [AgentToolName]) -> [ChatToolSpec] {
        tools.map(toolSpec(for:))
    }

    /// Convenience for the classic file/command toolset.
    static func specs(includeUseSkill: Bool = false) -> [ChatToolSpec] {
        var tools: [AgentToolName] = [.readFile, .listDir, .glob, .grep, .writeFile, .editFile, .runCommand, .todoWrite]
        if includeUseSkill { tools.append(.useSkill) }
        return specs(for: tools)
    }

    /// The JSON-schema spec for one tool. Tool-template models (Qwen, Llama-3.1+,
    /// …) use these for native function calling.
    static func toolSpec(for name: AgentToolName) -> ChatToolSpec {
        switch name {
        case .readFile:
            return spec(.readFile, "Read a UTF-8 text file from the project. Use this before editing a file you haven't seen.",
                 props: ["path": "File path relative to the project root."], required: ["path"])
        case .listDir:
            return spec(.listDir, "List the files and folders at a path in the project. Folders end with a slash.",
                 props: ["path": "Folder path relative to the project root. Defaults to the root."], required: [])
        case .glob:
            return spec(.glob, "Find files in the project by glob pattern. Supports * (within a path segment) and ** (across folders), e.g. \"**/*.swift\".",
                 props: ["pattern": "The glob pattern to match against project-relative file paths."], required: ["pattern"])
        case .grep:
            return spec(.grep, "Search the project's text files for a pattern (extended regex). Returns matching file:line: text.",
                 props: ["pattern": "The regular expression or literal text to search for.",
                         "path": "Optional sub-path to limit the search. Defaults to the whole project."], required: ["pattern"])
        case .writeFile:
            return spec(.writeFile, "Create a new file or completely overwrite an existing one with the given content.",
                 props: ["path": "File path relative to the project root.",
                         "content": "The full new contents of the file."], required: ["path", "content"])
        case .editFile:
            return spec(.editFile, "Replace the first exact occurrence of old_string with new_string in an existing file. old_string must match exactly. Set replace_all to \"true\" to replace every occurrence.",
                 props: ["path": "File path relative to the project root.",
                         "old_string": "The exact text to find. Include enough surrounding context to be unique.",
                         "new_string": "The text to replace it with.",
                         "replace_all": "Optional. \"true\" to replace all occurrences instead of just the first."],
                 required: ["path", "old_string", "new_string"])
        case .runCommand:
            return spec(.runCommand, "Run a shell command. Each call is a FRESH shell with cwd = project root; `cd` doesn't persist — chain with && or use flags like --project.",
                 props: ["command": "The shell command to run, e.g. `swift build` or `npm test`."], required: ["command"])
        case .todoWrite:
            return spec(.todoWrite, "Record or update your task plan as a checklist so the user can follow along.",
                 props: ["todos": "A JSON array like [{\"content\": \"...\", \"status\": \"pending|in_progress|completed\"}], in order."],
                 required: ["todos"])
        case .useSkill:
            return spec(.useSkill, "Load the full instructions for one of your available skills (listed in your system prompt) by its exact name.",
                 props: ["name": "The exact skill name to load."], required: ["name"])
        case .askUser:
            return spec(.askUser, "Ask the user a question and wait for their answer. Use ONLY when you genuinely need their input to proceed (a real fork, a missing preference). To steer the model with fixed choices, pass `options` — the user picks one with a button; omit it for a free-text answer.",
                 props: ["question": "The question to ask the user.",
                         "options": "Optional. A JSON array of 2–5 short answer choices to offer as buttons, e.g. [\"Postgres\", \"SQLite\", \"MySQL\"]. Omit for a free-text question."],
                 required: ["question"])
        case .remember:
            return spec(.remember, "Save a DURABLE lesson or fact about THIS project to your long-term memory, so future sessions reuse it. Use for things that stay true: the build/test/run commands, framework & versions, directory layout, conventions, key decisions, and mistakes to avoid. NOT for one-off task details.",
                 props: ["lesson": "One concise, reusable fact or lesson (≤ 20 words)."],
                 required: ["lesson"])
        case .webSearch:
            return spec(.webSearch, "Search the web and get a list of result titles, URLs, and snippets. Use this to find current information, docs, library versions, or APIs that may be newer than your training data. Follow up with fetch_url to read a promising result in full.",
                 props: ["query": "The search query, like you'd type into a search engine."],
                 required: ["query"])
        case .fetchUrl:
            return spec(.fetchUrl, "Download a web page and return its readable text (HTML stripped). Use after web_search to read a result, or to fetch a known docs/API URL directly.",
                 props: ["url": "The full http(s) URL to fetch."],
                 required: ["url"])
        }
    }

    private static func spec(_ name: AgentToolName, _ description: String,
                             props: [String: String], required: [String]) -> ChatToolSpec {
        ChatToolSpec(function: ChatFunctionSpec(
            name: name.rawValue,
            description: description,
            parameters: ChatToolParameters(
                properties: props.mapValues { ChatToolProperty(type: "string", description: $0) },
                required: required)))
    }

    // MARK: - Text fallback parsing

    /// Small fine-tuned models frequently lack a tool-aware chat template, so
    /// mlx-lm returns their tool intent as plain text with empty `tool_calls`.
    /// We instruct those models (in the system prompt) to emit
    /// `<tool_call>{"name": "...", "arguments": {...}}</tool_call>` and parse it
    /// here. We also accept a bare top-level JSON object as a last resort.
    static func parseFallbackCalls(from content: String) -> [ParsedToolCall] {
        var calls: [ParsedToolCall] = []
        var index = 0

        func appendCall(name: String, argsObject: Any) {
            let argsJSON: String
            if let s = argsObject as? String {
                argsJSON = s
            } else if let data = try? JSONSerialization.data(withJSONObject: argsObject),
                      let s = String(data: data, encoding: .utf8) {
                argsJSON = s
            } else {
                argsJSON = "{}"
            }
            calls.append(ParsedToolCall(id: "call_fallback_\(index)", name: name, argumentsJSON: argsJSON))
            index += 1
        }

        // Primary: <tool_call> ... </tool_call> blocks. Capture everything
        // BETWEEN the tags (not a brace-matched group) — a non-greedy `\{.*?\}`
        // truncates nested-object arguments like {"arguments":{"path":"x"}} at
        // the first inner brace. This is exactly the format Qwen-family models
        // emit natively, so the fallback doubles as a safety net for them.
        let scanner = content as NSString
        let pattern = try? NSRegularExpression(pattern: "<tool_call>(.*?)</tool_call>",
                                               options: [.dotMatchesLineSeparators])
        if let pattern {
            let matches = pattern.matches(in: content, range: NSRange(location: 0, length: scanner.length))
            for m in matches where m.numberOfRanges >= 2 {
                let json = AgentTools.sanitizeToolBlock(scanner.substring(with: m.range(at: 1)))
                if let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                   let name = obj["name"] as? String {
                    appendCall(name: name, argsObject: obj["arguments"] ?? obj["parameters"] ?? [String: Any]())
                }
            }
        }
        if !calls.isEmpty { return calls }

        // Secondary: ```json fenced blocks. Qwen-Coder narrates a plan with the
        // tool calls embedded as fenced JSON (often several per message). Each
        // fence holding a JSON object with a known tool name is a call, in order.
        if let fence = try? NSRegularExpression(pattern: "```(?:json)?[ \\t]*\\n?([\\s\\S]*?)```") {
            for m in fence.matches(in: content, range: NSRange(location: 0, length: scanner.length)) where m.numberOfRanges >= 2 {
                let inner = AgentTools.sanitizeToolBlock(scanner.substring(with: m.range(at: 1)))
                if inner.hasPrefix("{"),
                   let obj = try? JSONSerialization.jsonObject(with: Data(inner.utf8)) as? [String: Any],
                   let name = obj["name"] as? String,
                   AgentToolName(rawValue: name) != nil {
                    appendCall(name: name, argsObject: obj["arguments"] ?? obj["parameters"] ?? [String: Any]())
                }
            }
        }
        if !calls.isEmpty { return calls }

        // Last resort: the whole message is one JSON object naming a tool,
        // possibly wrapped in a ```json code fence.
        var trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            trimmed = trimmed.replacingOccurrences(of: "```json", with: "```")
            if let firstNL = trimmed.firstIndex(of: "\n") { trimmed = String(trimmed[trimmed.index(after: firstNL)...]) }
            if let fence = trimmed.range(of: "```", options: .backwards) { trimmed = String(trimmed[..<fence.lowerBound]) }
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let cleaned = AgentTools.sanitizeToolBlock(trimmed)
        if cleaned.hasPrefix("{"),
           let obj = try? JSONSerialization.jsonObject(with: Data(cleaned.utf8)) as? [String: Any],
           let name = obj["name"] as? String,
           AgentToolName(rawValue: name) != nil {
            appendCall(name: name, argsObject: obj["arguments"] ?? obj["parameters"] ?? [String: Any]())
        }
        return calls
    }

    /// Remove leaked model special tokens (e.g. gemma's `<|…|>`, `<tool_call|>`,
    /// `<end_of_turn>`) that corrupt tool-call JSON, so a slightly-malformed call
    /// from a weaker model still parses.
    static func sanitizeToolBlock(_ s: String) -> String {
        var out = s
        // Gemma-4 emits its special quote token `<|"|>` in place of a real `"`
        // inside text-format tool calls, which breaks the JSON. Restore it FIRST,
        // before the generic `<|…|>` strip below would delete it and leave the
        // string unterminated.
        out = out.replacingOccurrences(of: "<|\"|>", with: "\"")
        for pattern in ["<\\|.*?\\|>", "</?tool_call\\|>", "<end_of_turn>", "<start_of_turn>", "<eos>", "<bos>"] {
            if let rx = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) {
                out = rx.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "")
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Produce clean display text from an assistant turn: remove tool-call
    /// representations — both `<tool_call>` tags and ```json fences that hold a
    /// tool call (Qwen-Coder emits the latter) — plus any leaked model special
    /// tokens (e.g. `<|im_end|>`), leaving just the model's prose.
    static func stripToolCallBlocks(from content: String) -> String {
        var s = content
        for pattern in [
            "<tool_call>.*?</tool_call>",            // <tool_call> … </tool_call>
            "```(?:json)?[^`]*\"name\"[^`]*```"       // fenced JSON tool call
        ] {
            if let rx = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) {
                s = rx.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
            }
        }
        return sanitizeToolBlock(s)   // also strips <|…|>, <end_of_turn>, etc. + trims
    }
}

/// A normalized tool call, whether it arrived as a native `tool_calls` entry or
/// was parsed out of free-form text.
struct ParsedToolCall: Identifiable, Sendable {
    let id: String
    let name: String
    let argumentsJSON: String          // a JSON object string: {"path": "...", ...}
}

struct ToolResult: Sendable {
    var output: String                 // fed back to the model (kept concise)
    var isError: Bool
    var displayDetail: String? = nil   // UI-only, e.g. a diff — never sent to the model
}

// MARK: - Executor

struct ToolExecutor: Sendable {
    let workspace: URL
    var skills: [SkillContext] = []          // enabled skills for use_skill

    enum ToolError: LocalizedError {
        case outsideWorkspace(String)
        case missingArgument(String)
        case unknownTool(String)
        case stringNotFound
        var errorDescription: String? {
            switch self {
            case .outsideWorkspace(let p): "Path `\(p)` is outside the project folder. Stay within the project."
            case .missingArgument(let a):  "Missing required argument `\(a)`."
            case .unknownTool(let n):      "Unknown tool `\(n)`."
            case .stringNotFound:          "old_string was not found in the file. Read the file again and match its exact text."
            }
        }
    }

    func execute(name: String, argumentsJSON: String) async -> ToolResult {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        do {
            guard let tool = AgentToolName(rawValue: name) else { throw ToolError.unknownTool(name) }
            switch tool {
            case .readFile:   return try readFile(args)
            case .listDir:    return try listDir(args)
            case .glob:       return try globFiles(args)
            case .grep:       return try await grep(args)
            case .writeFile:  return try writeFile(args)
            case .editFile:   return try editFile(args)
            case .runCommand: return try await runCommand(args)
            case .useSkill:   return try useSkill(args)
            case .webSearch:  return try await webSearch(args)
            case .fetchUrl:   return try await fetchUrl(args)
            // todo_write, ask_user, and remember are intercepted in the
            // orchestration engine (they update app state / pause for the user /
            // write project memory); these are defensive fallbacks.
            case .todoWrite:  return ToolResult(output: "Plan updated.", isError: false)
            case .askUser:    return ToolResult(output: "(handled by the orchestrator)", isError: false)
            case .remember:   return ToolResult(output: "(handled by the orchestrator)", isError: false)
            }
        } catch {
            return ToolResult(output: error.localizedDescription, isError: true)
        }
    }

    // MARK: tool implementations

    private func readFile(_ args: [String: Any]) throws -> ToolResult {
        let url = try sandboxed(stringArg(args, "path"))
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            return ToolResult(output: "Could not read \(url.lastPathComponent) as UTF-8 text.", isError: true)
        }
        return ToolResult(output: truncate(text), isError: false)
    }

    private func listDir(_ args: [String: Any]) throws -> ToolResult {
        let rel = (args["path"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "."
        let url = try sandboxed(rel)
        let entries = (try? FileManager.default.contentsOfDirectory(at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey])) ?? []
        let lines = entries
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { entry -> String in
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return isDir ? entry.lastPathComponent + "/" : entry.lastPathComponent
            }
        let body = lines.isEmpty ? "(empty)" : lines.joined(separator: "\n")
        return ToolResult(output: truncate(body), isError: false)
    }

    private func globFiles(_ args: [String: Any]) throws -> ToolResult {
        let pattern = try stringArg(args, "pattern")
        // A pattern with no "/" matches against the file's basename so "*.swift"
        // finds every Swift file; otherwise it matches the project-relative path.
        let matchBasename = !pattern.contains("/")
        guard let regex = Self.globToRegex(pattern) else {
            return ToolResult(output: "Invalid glob pattern: \(pattern)", isError: true)
        }
        let skipDirs: Set<String> = [".git", "node_modules", ".build", "build", "DerivedData", ".venv"]
        var matches: [String] = []
        if let en = FileManager.default.enumerator(at: workspace.standardizedFileURL,
                                                   includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                                                   options: [.skipsHiddenFiles]) {
            for case let url as URL in en {
                if matches.count >= 1000 { break }
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir {
                    if skipDirs.contains(url.lastPathComponent) { en.skipDescendants() }
                    continue
                }
                let target = matchBasename ? url.lastPathComponent : relativePath(url)
                if regex.firstMatch(in: target, range: NSRange(target.startIndex..., in: target)) != nil {
                    matches.append(relativePath(url))
                }
            }
        }
        matches.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        let body = matches.isEmpty ? "No files match \(pattern)." : matches.joined(separator: "\n")
        return ToolResult(output: truncate(body), isError: false)
    }

    private func grep(_ args: [String: Any]) async throws -> ToolResult {
        let pattern = try stringArg(args, "pattern")
        let sub = (args["path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let searchRoot = try sub.map { try sandboxed($0) } ?? workspace
        let proc = try await ProcessRunner.spawn(
            executable: URL(fileURLWithPath: "/usr/bin/grep"),
            arguments: ["-rInE", "--exclude-dir=.git", "--exclude-dir=node_modules",
                        "--exclude-dir=.build", "-e", pattern, searchRoot.path],
            currentDirectory: workspace)
        var out = ""
        for await line in proc.stdout {
            out += line.replacingOccurrences(of: workspace.path + "/", with: "") + "\n"
            if out.count > AgentTools.maxOutputChars { break }
        }
        _ = try? await proc.exit.value
        let body = out.isEmpty ? "No matches." : out
        return ToolResult(output: truncate(body), isError: false)
    }

    private func writeFile(_ args: [String: Any]) throws -> ToolResult {
        let url = try sandboxed(stringArg(args, "path"))
        let content = try stringArg(args, "content")
        let existed = FileManager.default.fileExists(atPath: url.path)
        let oldContent: String? = existed ? (try? String(contentsOf: url, encoding: .utf8)) : nil
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try content.data(using: .utf8)?.write(to: url)
        let verb = existed ? "Overwrote" : "Created"
        return ToolResult(output: "\(verb) \(relativePath(url)) (\(content.utf8.count) bytes).",
                          isError: false,
                          displayDetail: Self.writeDiff(old: oldContent, new: content))
    }

    private func editFile(_ args: [String: Any]) throws -> ToolResult {
        let url = try sandboxed(stringArg(args, "path"))
        let oldString = try stringArg(args, "old_string")
        let newString = try stringArg(args, "new_string")
        let replaceAll = (args["replace_all"] as? String)?.lowercased() == "true" || (args["replace_all"] as? Bool) == true
        guard !oldString.isEmpty else { throw ToolError.missingArgument("old_string") }
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            return ToolResult(output: "Could not read \(url.lastPathComponent) as UTF-8 text.", isError: true)
        }
        guard text.contains(oldString) else { throw ToolError.stringNotFound }
        let updated: String
        let suffix: String
        if replaceAll {
            let count = text.components(separatedBy: oldString).count - 1
            updated = text.replacingOccurrences(of: oldString, with: newString)
            suffix = " (\(count) occurrence\(count == 1 ? "" : "s"))"
        } else {
            var u = text
            if let r = u.range(of: oldString) { u.replaceSubrange(r, with: newString) }
            updated = u
            suffix = ""
        }
        try updated.data(using: .utf8)?.write(to: url)
        return ToolResult(output: "Edited \(relativePath(url))\(suffix).",
                          isError: false,
                          displayDetail: Self.editDiff(old: oldString, new: newString))
    }

    private func runCommand(_ args: [String: Any]) async throws -> ToolResult {
        let command = try stringArg(args, "command")
        let proc = try await ProcessRunner.spawn(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-lc", command],
            currentDirectory: workspace)

        let outTask = Task { () -> String in
            var s = ""
            for await line in proc.stdout { s += line + "\n" }
            return s
        }
        let errTask = Task { () -> String in
            var s = ""
            for await line in proc.stderr { s += line + "\n" }
            return s
        }

        // Kill the command if it overruns the timeout (e.g. a server that never
        // exits). Terminating makes proc.exit resolve, so we never hang here.
        let timedOut = TimeoutFlag()
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(AgentTools.commandTimeout * 1_000_000_000))
            await timedOut.set()
            proc.terminate()
        }
        let exit = try? await proc.exit.value
        watchdog.cancel()

        let stdout = await outTask.value
        let stderr = await errTask.value
        var body = ""
        if !stdout.isEmpty { body += stdout }
        if !stderr.isEmpty { body += (body.isEmpty ? "" : "\n") + stderr }
        if await timedOut.value {
            body += "\n(Command timed out after \(Int(AgentTools.commandTimeout))s and was terminated.)"
        }
        let code = exit?.code ?? -1
        let header = "exit code: \(code)\n"
        let isError = code != 0
        // Keep the diagnostic TAIL — a failing build/test prints its error summary
        // last, so head-only truncation would drop exactly what the model needs.
        return ToolResult(output: truncateTail(header + (body.isEmpty ? "(no output)" : body)), isError: isError)
    }

    private func useSkill(_ args: [String: Any]) throws -> ToolResult {
        let name = try stringArg(args, "name")
        if let skill = skills.first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.id.caseInsensitiveCompare(name) == .orderedSame
        }) {
            // Stage 3: hand back the full instructions, plus the skill's folder path
            // so the agent can read any bundled references/scripts/assets it mentions.
            var out = "Skill: \(skill.name)\n\n\(skill.instructions)"
            if !skill.dirPath.isEmpty {
                out += "\n\n(Bundled files for this skill live in: \(skill.dirPath))"
            }
            // skill→skill links: tell the agent which related skills it can also load.
            let linked = skill.links.compactMap { id in
                skills.first { $0.id == id }
            }
            if !linked.isEmpty {
                let names = linked.map { "\($0.name) — \($0.description)" }.joined(separator: "\n- ")
                out += "\n\nRelated skills you can also load with use_skill:\n- \(names)"
            }
            return ToolResult(output: truncate(out), isError: false)
        }
        let available = skills.map(\.name).joined(separator: ", ")
        return ToolResult(output: "No skill named “\(name)”. Available skills: \(available.isEmpty ? "(none)" : available)",
                          isError: true)
    }

    // MARK: web tools (read-only network)

    /// Browser-y headers + a short timeout shared by both web tools. DuckDuckGo's
    /// HTML endpoint and most docs sites reject a default URLSession user-agent.
    private static func webRequest(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                     + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        return req
    }

    /// Web search via DuckDuckGo's keyless HTML endpoint — no API key, no account,
    /// consistent with the app's no-credentials posture. Parses the result anchors
    /// + snippets out of the returned HTML. Best-effort: returns a clear message if
    /// the network is down or the markup changes, rather than throwing.
    private func webSearch(_ args: [String: Any]) async throws -> ToolResult {
        let query = try stringArg(args, "query")
        guard let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://html.duckduckgo.com/html/?q=\(q)") else {
            return ToolResult(output: "Invalid search query.", isError: true)
        }
        do {
            let (data, _) = try await URLSession.shared.data(for: Self.webRequest(url))
            guard let html = String(data: data, encoding: .utf8) else {
                return ToolResult(output: "Search returned no readable response.", isError: true)
            }
            let results = Self.parseDuckDuckGo(html)
            if results.isEmpty {
                return ToolResult(output: "No results for “\(query)”.", isError: false)
            }
            let body = results.prefix(8).enumerated().map { i, r in
                "\(i + 1). \(r.title)\n   \(r.url)\n   \(r.snippet)"
            }.joined(separator: "\n\n")
            return ToolResult(output: truncate(body), isError: false)
        } catch {
            return ToolResult(output: "Web search failed (offline or blocked): \(error.localizedDescription)",
                              isError: true)
        }
    }

    /// Fetch a URL and return readable text (scripts/styles/tags stripped). Only
    /// http/https; refuses other schemes. Best-effort HTML→text — good enough for
    /// the model to read docs / API references.
    private func fetchUrl(_ args: [String: Any]) async throws -> ToolResult {
        let raw = try stringArg(args, "url")
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return ToolResult(output: "fetch_url needs a full http(s) URL. Got: \(raw)", isError: true)
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: Self.webRequest(url))
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                return ToolResult(output: "HTTP \(http.statusCode) fetching \(url.host ?? raw).", isError: true)
            }
            guard let body = String(data: data, encoding: .utf8) else {
                return ToolResult(output: "Fetched \(data.count) bytes but couldn't decode as text "
                                  + "(probably a binary file).", isError: true)
            }
            let text = Self.htmlToText(body)
            return ToolResult(output: truncate(text.isEmpty ? "(page had no readable text)" : text),
                              isError: false)
        } catch {
            return ToolResult(output: "Couldn't fetch \(url.host ?? raw): \(error.localizedDescription)",
                              isError: true)
        }
    }

    struct WebResult { let title: String; let url: String; let snippet: String }

    /// Pull (title, url, snippet) triples out of DuckDuckGo HTML results. The
    /// lite/html endpoint wraps each hit's title in `<a class="result__a" …>` and
    /// the blurb in `class="result__snippet"`. We also un-wrap DDG's redirect
    /// links (`/l/?…uddg=<real-url>`) back to the real destination.
    static func parseDuckDuckGo(_ html: String) -> [WebResult] {
        var out: [WebResult] = []
        let ns = html as NSString
        guard let linkRx = try? NSRegularExpression(
            pattern: "result__a[^>]*href=\"(.*?)\"[^>]*>(.*?)</a>",
            options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return out }
        let snipRx = try? NSRegularExpression(
            pattern: "result__snippet[^>]*>(.*?)</a>",
            options: [.dotMatchesLineSeparators, .caseInsensitive])
        let links = linkRx.matches(in: html, range: NSRange(location: 0, length: ns.length))
        let snips = snipRx?.matches(in: html, range: NSRange(location: 0, length: ns.length)) ?? []
        for (i, m) in links.enumerated() where m.numberOfRanges >= 3 {
            let href = unwrapDDG(ns.substring(with: m.range(at: 1)))
            let title = stripTags(ns.substring(with: m.range(at: 2)))
            var snippet = ""
            if i < snips.count, snips[i].numberOfRanges >= 2 {
                snippet = stripTags(ns.substring(with: snips[i].range(at: 1)))
            }
            if !title.isEmpty { out.append(WebResult(title: title, url: href, snippet: snippet)) }
        }
        return out
    }

    private static func unwrapDDG(_ href: String) -> String {
        // DDG wraps results as //duckduckgo.com/l/?uddg=<percent-encoded-real-url>
        guard href.contains("uddg=") else {
            return href.hasPrefix("//") ? "https:" + href : href
        }
        guard let comps = URLComponents(string: href.hasPrefix("//") ? "https:" + href : href),
              let real = comps.queryItems?.first(where: { $0.name == "uddg" })?.value else { return href }
        return real
    }

    /// Crude but effective HTML → readable text: drop script/style, turn tags into
    /// spaces, decode the few entities that matter, collapse whitespace.
    static func htmlToText(_ html: String) -> String {
        var s = html
        for pattern in ["<script[^>]*>.*?</script>", "<style[^>]*>.*?</style>",
                        "<!--.*?-->", "<head[^>]*>.*?</head>"] {
            if let rx = try? NSRegularExpression(pattern: pattern,
                    options: [.dotMatchesLineSeparators, .caseInsensitive]) {
                s = rx.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
            }
        }
        return stripTags(s)
    }

    /// Remove HTML tags, decode common entities, collapse runs of whitespace.
    static func stripTags(_ html: String) -> String {
        var s = html
        if let rx = try? NSRegularExpression(pattern: "<[^>]+>", options: [.dotMatchesLineSeparators]) {
            s = rx.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
        }
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                        "&#39;": "'", "&#x27;": "'", "&nbsp;": " ", "&hellip;": "…"]
        for (e, c) in entities { s = s.replacingOccurrences(of: e, with: c) }
        if let rx = try? NSRegularExpression(pattern: "[ \\t]*\\n[ \\t\\n]*") {
            s = rx.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "\n")
        }
        if let rx = try? NSRegularExpression(pattern: "[ \\t]{2,}") {
            s = rx.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Compute the diff a write/edit WOULD produce, without applying it — so the
    /// UI can show changes before the user approves. Returns nil for other tools.
    func previewDiff(name: String, argumentsJSON: String) -> String? {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        switch AgentToolName(rawValue: name) {
        case .editFile:
            guard let oldS = args["old_string"] as? String, let newS = args["new_string"] as? String else { return nil }
            return Self.editDiff(old: oldS, new: newS)
        case .writeFile:
            guard let path = args["path"] as? String, let content = args["content"] as? String,
                  let url = try? sandboxed(path) else { return nil }
            let oldContent: String? = FileManager.default.fileExists(atPath: url.path)
                ? (try? String(contentsOf: url, encoding: .utf8)) : nil
            return Self.writeDiff(old: oldContent, new: content)
        default:
            return nil
        }
    }

    // MARK: diff + glob helpers

    static func editDiff(old: String, new: String) -> String {
        var lines = old.split(separator: "\n", omittingEmptySubsequences: false).map { "- \($0)" }
        lines += new.split(separator: "\n", omittingEmptySubsequences: false).map { "+ \($0)" }
        return clampLines(lines)
    }

    static func writeDiff(old: String?, new: String) -> String {
        let newLines = new.split(separator: "\n", omittingEmptySubsequences: false)
        var lines: [String]
        if let old, !old.isEmpty {
            let oldCount = old.split(separator: "\n", omittingEmptySubsequences: false).count
            lines = ["overwrites existing file (\(oldCount) → \(newLines.count) lines)"]
        } else {
            lines = ["new file (\(newLines.count) lines)"]
        }
        lines += newLines.map { "+ \($0)" }
        return clampLines(lines)
    }

    private static func clampLines(_ lines: [String], max: Int = 80) -> String {
        guard lines.count > max else { return lines.joined(separator: "\n") }
        return (lines.prefix(max) + ["… (\(lines.count - max) more lines)"]).joined(separator: "\n")
    }

    /// Translate a glob (`*`, `**`, `?`) into an anchored regex. `**` matches
    /// across path separators; `*` matches within one segment.
    static func globToRegex(_ glob: String) -> NSRegularExpression? {
        let chars = Array(glob)
        var rx = "^"
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "*":
                if i + 1 < chars.count && chars[i + 1] == "*" {
                    rx += ".*"
                    i += 1
                    if i + 1 < chars.count && chars[i + 1] == "/" { i += 1 }  // "**/" also matches at root
                } else {
                    rx += "[^/]*"
                }
            case "?":
                rx += "[^/]"
            case ".", "(", ")", "+", "|", "^", "$", "{", "}", "[", "]", "\\":
                rx += "\\" + String(c)
            default:
                rx += String(c)
            }
            i += 1
        }
        rx += "$"
        return try? NSRegularExpression(pattern: rx)
    }

    // MARK: helpers

    private func stringArg(_ args: [String: Any], _ key: String) throws -> String {
        guard let v = args[key] as? String else { throw ToolError.missingArgument(key) }
        return v
    }

    /// Resolve a workspace-relative (or absolute) path and refuse anything that
    /// escapes the project root. `..` is resolved lexically before the check.
    private func sandboxed(_ relative: String) throws -> URL {
        let root = workspace.standardizedFileURL
        let rel = relative.trimmingCharacters(in: .whitespacesAndNewlines)
        let joined = rel.hasPrefix("/") ? URL(fileURLWithPath: rel) : root.appendingPathComponent(rel)
        let std = joined.standardizedFileURL
        guard std.path == root.path || std.path.hasPrefix(root.path + "/") else {
            throw ToolError.outsideWorkspace(rel)
        }
        return std
    }

    private func relativePath(_ url: URL) -> String {
        let root = workspace.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        return p.hasPrefix(root + "/") ? String(p.dropFirst(root.count + 1)) : url.lastPathComponent
    }

    private func truncate(_ s: String) -> String {
        guard s.count > AgentTools.maxOutputChars else { return s }
        let head = s.prefix(AgentTools.maxOutputChars)
        return head + "\n… (truncated, \(s.count - AgentTools.maxOutputChars) more characters)"
    }

    /// Like `truncate`, but preserves the diagnostic TAIL. A failing build/test
    /// prints its error summary at the END, so head-only truncation drops exactly
    /// what the model needs to fix it. Small head for context + elided middle +
    /// tail. Used for command output only; file reads / search hits stay head-truncated.
    private func truncateTail(_ s: String) -> String {
        guard s.count > AgentTools.maxOutputChars else { return s }
        let headBudget = AgentTools.maxOutputChars / 4
        let tailBudget = AgentTools.maxOutputChars - headBudget
        let head = String(s.prefix(headBudget))
        let tail = String(s.suffix(tailBudget))
        let elided = s.count - head.count - tail.count
        return head + "\n… (\(elided) chars elided) …\n" + tail
    }
}

/// Tiny actor so the watchdog and the awaiting task can share the timed-out
/// flag without data races under Swift 6 strict concurrency.
private actor TimeoutFlag {
    private(set) var value = false
    func set() { value = true }
}
