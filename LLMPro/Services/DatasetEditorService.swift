import Foundation

/// In-memory representation of one example in a chat dataset.
/// All dataset edits in LLMPro happen against the chat schema, regardless of
/// what shape the source file used — the editor auto-promotes legacy rows when it
/// loads them and writes back chat-shape JSONL on save.
struct ChatRow: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var messages: [ChatMessageRow]

    /// Short one-line summary for the list view.
    var summary: String {
        let userText = messages.first(where: { $0.role == .user })?.content ?? ""
        return String(userText.prefix(110)).replacingOccurrences(of: "\n", with: " ")
    }
}

struct ChatMessageRow: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var role: Role
    var content: String

    enum Role: String, Codable, CaseIterable, Identifiable {
        case system, user, assistant
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .system: "System"
            case .user: "User"
            case .assistant: "Assistant"
            }
        }
    }
}

enum DatasetSplit: String, CaseIterable, Identifiable {
    case train, valid, test
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .train: "Training"
        case .valid: "Validation"
        case .test:  "Test"
        }
    }
    func filename() -> String { "\(rawValue).jsonl" }
}

/// Pure file IO over a dataset directory. No SwiftUI state — call from view models.
enum DatasetEditorService {

    /// Load every row from one split, auto-promoting non-chat shapes to chat
    /// on the fly. Returns ChatRow values in file order.
    static func load(directory: URL, split: DatasetSplit) throws -> [ChatRow] {
        let file = directory.appendingPathComponent(split.filename())
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let text = try String(contentsOf: file, encoding: .utf8)
        var rows: [ChatRow] = []
        rows.reserveCapacity(64)
        for raw in text.split(whereSeparator: \.isNewline) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let data = trimmed.data(using: .utf8) else { continue }
            if let row = parseRow(jsonData: data) {
                rows.append(row)
            }
        }
        return rows
    }

    /// Save rows back to disk atomically.
    static func save(rows: [ChatRow], to directory: URL, split: DatasetSplit) throws {
        let file = directory.appendingPathComponent(split.filename())
        let tmp = file.appendingPathExtension("tmp")
        try? FileManager.default.removeItem(at: tmp)

        guard FileManager.default.createFile(atPath: tmp.path, contents: nil) else {
            throw NSError(domain: "DatasetEditorService", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create \(tmp.lastPathComponent)"])
        }
        let handle = try FileHandle(forWritingTo: tmp)
        defer { try? handle.close() }

        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        for row in rows {
            let payload = WireRow(messages: row.messages.map { WireMessage(role: $0.role.rawValue, content: $0.content) })
            let data = try encoder.encode(payload)
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data("\n".utf8))
        }
        try handle.close()

        // Replace original atomically (FileManager handles same-volume moves).
        _ = try FileManager.default.replaceItemAt(file, withItemAt: tmp)
    }

    /// Create empty {train,valid,test}.jsonl files in `directory`.
    static func createEmpty(at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for split in DatasetSplit.allCases {
            let f = directory.appendingPathComponent(split.filename())
            if !FileManager.default.fileExists(atPath: f.path) {
                FileManager.default.createFile(atPath: f.path, contents: Data())
            }
        }
    }

    /// Copy every file from `source` to `destination`. Used by Duplicate.
    static func duplicate(source: URL, destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let entries = (try? FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? []
        for entry in entries {
            let dst = destination.appendingPathComponent(entry.lastPathComponent)
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.copyItem(at: entry, to: dst)
        }
    }

    // MARK: - Row parsing (handles chat + legacy shapes)

    private struct WireRow: Codable {
        var messages: [WireMessage]
    }
    private struct WireMessage: Codable {
        var role: String
        var content: String
    }

    static func parseRow(jsonData: Data) -> ChatRow? {
        guard let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return nil
        }
        // Chat: {messages: [...]}
        if let arr = json["messages"] as? [[String: Any]] {
            let messages: [ChatMessageRow] = arr.compactMap { obj in
                guard let r = obj["role"] as? String else { return nil }
                let content = (obj["content"] as? String) ?? stringifyContent(obj["content"])
                let role = ChatMessageRow.Role(rawValue: r) ?? .user
                return ChatMessageRow(role: role, content: content)
            }
            if messages.isEmpty { return nil }
            return ChatRow(messages: messages)
        }
        // ShareGPT: {conversations: [{from/role, value/content}]}
        if let arr = json["conversations"] as? [[String: Any]] {
            let roleMap: [String: ChatMessageRow.Role] = [
                "human": .user, "user": .user, "gpt": .assistant, "assistant": .assistant,
                "system": .system,
            ]
            let messages: [ChatMessageRow] = arr.compactMap { obj in
                let rawRole = (obj["from"] as? String) ?? (obj["role"] as? String) ?? "user"
                let role = roleMap[rawRole.lowercased()] ?? .user
                let content = (obj["value"] as? String) ?? (obj["content"] as? String) ?? stringifyContent(obj["content"])
                return ChatMessageRow(role: role, content: content)
            }
            if messages.isEmpty { return nil }
            return ChatRow(messages: messages)
        }
        // instruction / output (Alpaca)
        if let instr = nonEmptyString(json["instruction"]),
           let out = nonEmptyString(json["output"] ?? json["response"] ?? json["completion"] ?? json["answer"] ?? json["solution"]) {
            let extra = nonEmptyString(json["input"])
            let user = extra.map { "\(instr)\n\n\($0)" } ?? instr
            return ChatRow(messages: [
                ChatMessageRow(role: .user, content: user),
                ChatMessageRow(role: .assistant, content: out),
            ])
        }
        // prompt / completion
        if let p = nonEmptyString(json["prompt"]), let c = nonEmptyString(json["completion"]) {
            return ChatRow(messages: [
                ChatMessageRow(role: .user, content: p),
                ChatMessageRow(role: .assistant, content: c),
            ])
        }
        // question / answer
        if let q = nonEmptyString(json["question"]), let a = nonEmptyString(json["answer"]) {
            return ChatRow(messages: [
                ChatMessageRow(role: .user, content: q),
                ChatMessageRow(role: .assistant, content: a),
            ])
        }
        // raw text
        if let t = nonEmptyString(json["text"]) {
            return ChatRow(messages: [
                ChatMessageRow(role: .user, content: t),
            ])
        }
        return nil
    }

    private static func nonEmptyString(_ any: Any?) -> String? {
        guard let s = any as? String, !s.isEmpty else { return nil }
        return s
    }

    private static func stringifyContent(_ any: Any?) -> String {
        if let s = any as? String { return s }
        if let arr = any as? [[String: Any]] {
            // Some chat formats have content as a list of segments. Concatenate the .text parts.
            let parts: [String] = arr.compactMap { $0["text"] as? String ?? "" }
            return parts.joined()
        }
        return ""
    }
}
