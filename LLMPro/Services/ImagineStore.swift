import Foundation
import Observation

/// One image made in the Imagine tab. `file` is a filename under
/// `PathResolver.imagesDir`; the rest is the recipe that produced it, so an image
/// can be re-generated or varied.
struct GeneratedImage: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var prompt: String
    var file: String
    var seed: Int
    var width: Int
    var height: Int
    var createdAt: Date = Date()
}

/// Persists the Imagine-tab gallery as `imagegen/gallery.json` (metadata) alongside
/// the PNGs in `imagegen/`. Same side-store pattern as `ConversationStore` /
/// `StoryStore` — `@MainActor @Observable`, no SwiftData.
@MainActor
@Observable
final class ImagineStore {
    static let shared = ImagineStore()

    private let dir = PathResolver.imagesDir
    private var galleryURL: URL { dir.appendingPathComponent("gallery.json") }

    private(set) var images: [GeneratedImage] = []   // most-recent first

    init() { load() }

    /// Absolute URL of an image's PNG on disk. `nonisolated` so a background image
    /// loader can compute it (reads only the immutable `dir`).
    nonisolated func url(for image: GeneratedImage) -> URL { dir.appendingPathComponent(image.file) }

    func add(_ image: GeneratedImage) {
        images.insert(image, at: 0)
        write()
    }

    func delete(_ id: UUID) {
        guard let i = images.firstIndex(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: url(for: images[i]))
        images.remove(at: i)
        write()
    }

    func clearAll() {
        for img in images { try? FileManager.default.removeItem(at: url(for: img)) }
        images.removeAll()
        write()
    }

    // MARK: - Disk

    private func write() {
        guard let data = try? JSONEncoder().encode(images) else { return }
        try? data.write(to: galleryURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: galleryURL),
              let loaded = try? JSONDecoder().decode([GeneratedImage].self, from: data) else { return }
        // Drop any entries whose PNG went missing (e.g. deleted outside the app).
        images = loaded.filter { FileManager.default.fileExists(atPath: url(for: $0).path) }
    }
}
