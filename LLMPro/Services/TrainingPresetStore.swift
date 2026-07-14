import Foundation
import Observation

struct TrainingPreset: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var config: TrainingConfig
}

/// Saved training recipes — a power-user affordance that lives entirely inside
/// the Advanced disclosure (AutoTuner still picks everything in the primary
/// flow). A preset snapshots the tunable knobs of a `TrainingConfig`; applying
/// one keeps the current model/dataset/adapter paths (those are per-run, not
/// part of a recipe). JSON under app-support — same pattern as the other stores.
@MainActor
@Observable
final class TrainingPresetStore {
    static let shared = TrainingPresetStore()

    private let url = PathResolver.appSupport.appendingPathComponent("training_presets.json")
    private(set) var presets: [TrainingPreset] = []

    init() { load() }

    func add(name: String, config: TrainingConfig) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        presets.append(TrainingPreset(name: trimmed, config: config))
        save()
    }

    func remove(_ preset: TrainingPreset) {
        presets.removeAll { $0.id == preset.id }
        save()
    }

    /// Merge a preset into the current config: recipe knobs from the preset,
    /// per-run identity (model / data / adapter output path) kept from `current`.
    static func applying(_ preset: TrainingPreset, to current: TrainingConfig) -> TrainingConfig {
        var merged = preset.config
        merged.model = current.model
        merged.data = current.data
        merged.adapterPath = current.adapterPath
        return merged
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([TrainingPreset].self, from: data) else { return }
        presets = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(presets) { try? data.write(to: url, options: .atomic) }
    }
}
