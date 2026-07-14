import Foundation
import Observation

/// One saved chat message — the persisted mirror of a `ChatMessage` (which isn't
/// Codable and carries live streaming state). Only finalized turns are stored.
struct StoredMessage: Codable, Hashable {
    var role: String     // "user" | "assistant" | "system"
    var text: String
}

/// A saved conversation for the Chat tab. Holds everything needed to rebuild a
/// live `ChatSession`: which model, the system prompt + temperature, and the
/// transcript. Persisted as one JSON file per conversation.
struct StoredConversation: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    var model: String
    var systemPrompt: String
    var temperature: Double
    var messages: [StoredMessage]
    var updatedAt: Date

    var isUntitled: Bool { title == StoredConversation.untitled }
    static let untitled = "New chat"
}

/// Persists Chat-tab conversations as one `<uuid>.json` per conversation under
/// `conversations/` (so a long transcript rewrites only its own file). Same
/// side-store philosophy as the other JSON stores — no SwiftData, no schema.
@MainActor
@Observable
final class ConversationStore {
    static let shared = ConversationStore()

    private let dir = PathResolver.conversationsDir
    /// Most-recently-updated first.
    private(set) var conversations: [StoredConversation] = []

    init() { load() }

    // MARK: - CRUD

    @discardableResult
    func create(model: String, systemPrompt: String, temperature: Double) -> StoredConversation {
        let conv = StoredConversation(
            title: StoredConversation.untitled,
            model: model,
            systemPrompt: systemPrompt,
            temperature: temperature,
            messages: [],
            updatedAt: Date())
        conversations.insert(conv, at: 0)
        write(conv)
        return conv
    }

    /// Upsert a conversation and re-sort by recency.
    func update(_ conv: StoredConversation) {
        var updated = conv
        updated.updatedAt = Date()
        if let i = conversations.firstIndex(where: { $0.id == conv.id }) {
            conversations[i] = updated
        } else {
            conversations.append(updated)
        }
        conversations.sort { $0.updatedAt > $1.updatedAt }
        write(updated)
    }

    func rename(_ id: UUID, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var conv = conversations.first(where: { $0.id == id }) else { return }
        conv.title = trimmed
        update(conv)
    }

    func delete(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: fileURL(id))
    }

    /// Drop a conversation from disk if it's still the empty "New chat" (so a
    /// glanced-at-but-unused chat doesn't accumulate).
    func discardIfEmpty(_ id: UUID) {
        guard let conv = conversations.first(where: { $0.id == id }),
              conv.messages.isEmpty, conv.isUntitled else { return }
        delete(id)
    }

    // MARK: - Disk

    private func fileURL(_ id: UUID) -> URL {
        dir.appendingPathComponent("\(id.uuidString).json")
    }

    private func write(_ conv: StoredConversation) {
        guard let data = try? JSONEncoder().encode(conv) else { return }
        try? data.write(to: fileURL(conv.id), options: .atomic)
    }

    private func load() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return }
        var loaded: [StoredConversation] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file) else { continue }
            do {
                loaded.append(try JSONDecoder().decode(StoredConversation.self, from: data))
            } catch {
                // Don't silently drop a saved chat — surface it (e.g. a future
                // non-optional field added to StoredConversation would fail every
                // old file). Keep the file on disk; skip only this session.
                Log.error("Skipping unreadable conversation \(file.lastPathComponent): \(error.localizedDescription)", .app)
            }
        }
        conversations = loaded.sorted { $0.updatedAt > $1.updatedAt }
    }
}
