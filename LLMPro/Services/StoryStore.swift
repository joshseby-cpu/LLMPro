import Foundation
import Observation

/// One generated illustration attached to a chapter. `file` is a filename under
/// the story's image directory (`PathResolver.storyImagesDir(for:)`); `prompt` is
/// the scene description used to generate it (already includes the story's art
/// style). Interleaved into the chapter prose in order.
struct StoryIllustration: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var prompt: String
    var file: String
}

/// One chapter of a story. `summary` is a short auto-generated synopsis used to
/// keep the model consistent across a long story without feeding every chapter's
/// full text back in (a 15-chapter story far exceeds any context window).
struct StoryChapter: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    var text: String
    var summary: String = ""
    var illustrations: [StoryIllustration] = []
}

extension StoryChapter {
    /// Tolerant decode so a chapter written before `illustrations` existed still
    /// loads (synthesized Codable would otherwise throw on the missing key and the
    /// whole story would be dropped).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Chapter"
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        illustrations = try c.decodeIfPresent([StoryIllustration].self, forKey: .illustrations) ?? []
    }
}

/// A Story-mode project: the premise + writing settings + all chapters. Persisted
/// as one JSON file. NOTE (forward-compat): any field added later must be
/// `Optional` or have a default, or old files fail to decode.
struct StoryProject: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    var premise: String = ""
    /// Freeform "how to write it" — tone, POV, style, and any content latitude the
    /// user wants. Fed to the model verbatim; behavior depends on the chosen model.
    var styleInstructions: String = ""
    var genre: String = ""
    /// Optional chapter-by-chapter plan the model follows for long-story coherence.
    var outline: String = ""
    var model: String = ""
    var temperature: Double = 0.85
    var chapterWordTarget: Int = 800
    var targetChapters: Int = 10
    /// How many AI illustrations to generate per chapter (0 = none). Needs an
    /// image model installed (Settings → Runtime → image generation).
    var illustrationsPerChapter: Int = 0
    /// The shared visual style every illustration uses, so a story's images look
    /// consistent — e.g. "soft watercolor children's-book illustration, warm palette".
    var artStyle: String = ""
    var chapters: [StoryChapter] = []
    var updatedAt: Date = Date()

    static let untitled = "Untitled story"
    var isUntitled: Bool { title == StoryProject.untitled || title.isEmpty }

    static let genres = ["Fantasy", "Science fiction", "Mystery", "Thriller", "Romance",
                         "Horror", "Literary", "Adventure", "Historical", "Comedy"]
}

extension StoryProject {
    /// Tolerant decode: every field uses `decodeIfPresent … ?? default`, so a story
    /// written by an older/newer version (missing a field) still loads instead of
    /// being silently dropped. (In an extension to keep the memberwise init.)
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? StoryProject.untitled
        premise = try c.decodeIfPresent(String.self, forKey: .premise) ?? ""
        styleInstructions = try c.decodeIfPresent(String.self, forKey: .styleInstructions) ?? ""
        genre = try c.decodeIfPresent(String.self, forKey: .genre) ?? ""
        outline = try c.decodeIfPresent(String.self, forKey: .outline) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 0.85
        chapterWordTarget = try c.decodeIfPresent(Int.self, forKey: .chapterWordTarget) ?? 800
        targetChapters = try c.decodeIfPresent(Int.self, forKey: .targetChapters) ?? 10
        illustrationsPerChapter = try c.decodeIfPresent(Int.self, forKey: .illustrationsPerChapter) ?? 0
        artStyle = try c.decodeIfPresent(String.self, forKey: .artStyle) ?? ""
        chapters = try c.decodeIfPresent([StoryChapter].self, forKey: .chapters) ?? []
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

/// Persists Story projects as one `stories/<uuid>.json` per project. Same
/// side-store pattern as `ConversationStore` — no SwiftData, atomic per-file writes.
@MainActor
@Observable
final class StoryStore {
    static let shared = StoryStore()

    private let dir = PathResolver.storiesDir
    private(set) var projects: [StoryProject] = []   // most-recently-updated first

    init() { load() }

    @discardableResult
    func create(model: String) -> StoryProject {
        let p = StoryProject(title: StoryProject.untitled, model: model, updatedAt: Date())
        projects.insert(p, at: 0)
        write(p)
        return p
    }

    func update(_ project: StoryProject) {
        // Non-resurrecting: only ever update a KNOWN project. If the id was just
        // deleted (e.g. a superseded generator task's late tail-save fires after
        // deleteProject), silently no-op instead of re-adding it to the list + disk.
        guard let i = projects.firstIndex(where: { $0.id == project.id }) else { return }
        var updated = project
        updated.updatedAt = Date()
        projects[i] = updated
        projects.sort { $0.updatedAt > $1.updatedAt }
        write(updated)
    }

    func rename(_ id: UUID, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var p = projects.first(where: { $0.id == id }) else { return }
        p.title = trimmed
        update(p)
    }

    func delete(_ id: UUID) {
        projects.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: fileURL(id))
        // Also remove any generated illustrations for this story.
        try? FileManager.default.removeItem(at: PathResolver.storyImagesDir(for: id))
    }

    /// Drop a project only if it's a truly-untouched stub — no chapters, default
    /// title, and no premise/style/genre/outline work worth keeping.
    func discardIfEmpty(_ id: UUID) {
        guard let p = projects.first(where: { $0.id == id }),
              p.chapters.isEmpty, p.isUntitled, p.premise.isEmpty,
              p.styleInstructions.isEmpty, p.genre.isEmpty,
              p.outline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        delete(id)
    }

    // MARK: - Disk

    private func fileURL(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).json") }

    private func write(_ project: StoryProject) {
        guard let data = try? JSONEncoder().encode(project) else { return }
        try? data.write(to: fileURL(project.id), options: .atomic)
    }

    private func load() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        var loaded: [StoryProject] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file) else { continue }
            do {
                loaded.append(try JSONDecoder().decode(StoryProject.self, from: data))
            } catch {
                Log.error("Skipping unreadable story \(file.lastPathComponent): \(error.localizedDescription)", .app)
            }
        }
        projects = loaded.sorted { $0.updatedAt > $1.updatedAt }
    }
}
