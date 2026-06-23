import Foundation
import Observation

/// Pins (favorites) for models and datasets, so the things a user reaches for most
/// float to the top of their lists. Persisted as JSON under app-support (no
/// SwiftData / schema change) — same pattern as `SystemPromptPresetStore`. Models
/// are keyed by `DetectedModel.id`, datasets by `DatasetRecord.id.uuidString`.
@MainActor
@Observable
final class FavoritesStore {
    static let shared = FavoritesStore()

    private let url = PathResolver.appSupport.appendingPathComponent("favorites.json")
    private struct Persisted: Codable { var models: [String] = []; var datasets: [String] = [] }

    private(set) var pinnedModelIDs: Set<String> = []
    private(set) var pinnedDatasetIDs: Set<String> = []

    init() { load() }

    func isModelPinned(_ id: String) -> Bool { pinnedModelIDs.contains(id) }
    func toggleModel(_ id: String) {
        if pinnedModelIDs.contains(id) { pinnedModelIDs.remove(id) } else { pinnedModelIDs.insert(id) }
        save()
    }

    func isDatasetPinned(_ id: String) -> Bool { pinnedDatasetIDs.contains(id) }
    func toggleDataset(_ id: String) {
        if pinnedDatasetIDs.contains(id) { pinnedDatasetIDs.remove(id) } else { pinnedDatasetIDs.insert(id) }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let p = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        pinnedModelIDs = Set(p.models)
        pinnedDatasetIDs = Set(p.datasets)
    }

    private func save() {
        let p = Persisted(models: Array(pinnedModelIDs), datasets: Array(pinnedDatasetIDs))
        if let data = try? JSONEncoder().encode(p) { try? data.write(to: url, options: .atomic) }
    }
}
