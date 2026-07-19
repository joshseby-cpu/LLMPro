import Foundation
import Observation

struct ModelMeta: Codable, Hashable {
    var notes: String = ""
    var tags: [String] = []
    /// A user-chosen display name that overrides the auto-derived one. Empty = use the
    /// default. This is an alias only — the model's on-disk folder / repoID is never
    /// touched, so loading, training configs, and the HF cache layout keep working.
    var displayName: String = ""
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
        if meta.notes.isEmpty && meta.tags.isEmpty && meta.displayName.isEmpty {
            byID.removeValue(forKey: id)
        } else {
            byID[id] = meta
        }
        save()
    }

    /// The effective display name for a model id: the user's alias if set, else the
    /// caller's default (the auto-derived name).
    func displayName(for id: String, default fallback: String) -> String {
        let alias = meta(for: id).displayName
        return alias.isEmpty ? fallback : alias
    }

    /// Set (or, when `name` is empty or equals the default, clear) the display-name
    /// alias for a model id, preserving its notes + tags.
    func rename(_ name: String, for id: String, default fallback: String) {
        var m = meta(for: id)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        m.displayName = (trimmed.isEmpty || trimmed == fallback) ? "" : trimmed
        set(m, for: id)
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
