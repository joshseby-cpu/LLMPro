import Foundation
import Observation

struct ModelMeta: Codable, Hashable {
    var notes: String = ""
    var tags: [String] = []
}

/// User notes + tags for local models, stored as a side JSON keyed by model id
/// (`DetectedModel.id`). The registry scans disk and has no place to hang
/// user-authored metadata, so this keeps it separate (no SwiftData / schema
/// change) — same pattern as `SystemPromptPresetStore` / `FavoritesStore`.
@MainActor
@Observable
final class ModelMetaStore {
    static let shared = ModelMetaStore()

    private let url = PathResolver.appSupport.appendingPathComponent("model_meta.json")
    private(set) var byID: [String: ModelMeta] = [:]

    init() { load() }

    func meta(for id: String) -> ModelMeta { byID[id] ?? ModelMeta() }

    func set(_ meta: ModelMeta, for id: String) {
        if meta.notes.isEmpty && meta.tags.isEmpty {
            byID.removeValue(forKey: id)
        } else {
            byID[id] = meta
        }
        save()
    }

    /// Every tag in use, sorted — for a filter menu.
    func allTags() -> [String] {
        Set(byID.values.flatMap { $0.tags }).sorted()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: ModelMeta].self, from: data) else { return }
        byID = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(byID) { try? data.write(to: url, options: .atomic) }
    }
}
