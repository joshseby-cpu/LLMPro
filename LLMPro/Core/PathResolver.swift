import Foundation

enum PathResolver {
    static let appSupport: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("LLMPro", isDirectory: true)
        migrateLegacyAppSupportIfNeeded(base: base, target: dir)
        ensureDir(dir); return dir
    }()

    /// One-time rename of the pre-rebrand data directory. The app used to store
    /// everything under `Application Support/MLXStudio`; the product is now
    /// `LLMPro`. If the old directory exists and the new one doesn't yet, move it
    /// in place (a same-volume rename — instantaneous, no copy, no re-download of
    /// the multi-hundred-GB model cache). Safe to leave in indefinitely: it only
    /// fires when the legacy dir is present and the new one is absent, so it's a
    /// no-op on fresh installs and on every launch after the first migrated one.
    private static func migrateLegacyAppSupportIfNeeded(base: URL, target: URL) {
        let fm = FileManager.default
        let legacy = base.appendingPathComponent("MLXStudio", isDirectory: true)
        guard fm.fileExists(atPath: legacy.path),
              !fm.fileExists(atPath: target.path) else { return }
        do {
            try fm.moveItem(at: legacy, to: target)
        } catch {
            // If the move fails (e.g. permissions, or a partial new dir appeared
            // in a race), fall back to a fresh LLMPro dir rather than crashing —
            // the user keeps the old MLXStudio folder and can move it by hand.
            NSLog("LLMPro: legacy app-support migration failed: \(error.localizedDescription)")
        }
    }

    static var runtimeDir: URL    { appSupport.appendingPathComponent("runtime", isDirectory: true).ensured() }
    static var venvDir: URL       { runtimeDir.appendingPathComponent(".venv", isDirectory: true) }
    static var venvPython: URL    { venvDir.appendingPathComponent("bin/python3", isDirectory: false) }
    static var venvBin: URL       { venvDir.appendingPathComponent("bin", isDirectory: true) }
    static var uvBinary: URL      { runtimeDir.appendingPathComponent("uv", isDirectory: false) }

    static var hfHome: URL        { appSupport.appendingPathComponent("hf", isDirectory: true).ensured() }
    static var adaptersDir: URL   { appSupport.appendingPathComponent("adapters", isDirectory: true).ensured() }
    static var datasetsDir: URL   { appSupport.appendingPathComponent("datasets", isDirectory: true).ensured() }
    static var modelsCustomDir: URL { appSupport.appendingPathComponent("models", isDirectory: true).ensured() }
    static var logsDir: URL       { appSupport.appendingPathComponent("logs", isDirectory: true).ensured() }
    static var exportsDir: URL    { appSupport.appendingPathComponent("exports", isDirectory: true).ensured() }
    static var helpersDir: URL    { runtimeDir.appendingPathComponent("helpers", isDirectory: true).ensured() }
    /// Cached diffusers conversions of single-file `.safetensors` SDXL/SD checkpoints
    /// (one subdir per checkpoint), so the one-time `from_single_file` conversion is
    /// reused across generations. Populated by `sdxl_generate.py --convert-cache`.
    static var sdxlConvertedDir: URL { appSupport.appendingPathComponent("imagegen/converted", isDirectory: true).ensured() }
    static var llamaCppDir: URL   { runtimeDir.appendingPathComponent("llama.cpp", isDirectory: true) }
    static var ollamaDefault: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ollama/models") }
    /// LM Studio reads models from this directory by default, laid out as
    /// `<publisher>/<name>/` containing `config.json` + safetensors (MLX) or
    /// a `.gguf` file (llama.cpp). LM Studio also reads `~/.lmstudio/hub/models/`
    /// in newer versions; both paths are scanned and either works.
    static var lmStudioDefault: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".lmstudio/models") }
    static var selfImproveDir: URL { appSupport.appendingPathComponent("selfimprove", isDirectory: true).ensured() }
    /// Scored-evaluation data. Layout:
    ///   evals/humaneval/eval.jsonl        built-in suites, lazily pulled by
    ///   evals/mbpp-sanitized/eval.jsonl   humaneval_pull.py (folder id == preset id)
    ///   evals/custom-<uuid>/eval.jsonl    user-supplied custom suites
    ///   evals/<run-uuid>/eval_run.json    one folder per EvalRun: its sidecar
    /// `evalSuiteDir(for:)` builds a folder under here by id (suite id OR run id).
    static var evalsDir: URL      { appSupport.appendingPathComponent("evals", isDirectory: true).ensured() }
    /// SKILL.md packages for the coding agent — one folder per skill, each with a
    /// `SKILL.md` (frontmatter name/description + instructions) and optional files.
    static var skillsDir: URL     { appSupport.appendingPathComponent("skills", isDirectory: true).ensured() }
    /// Markdown definitions for the Code-tab team agents — one `<role>.md` per
    /// agent (frontmatter: name/emoji/tint/tools/delegates/maxIterations +
    /// system-prompt body). Seeded from the app bundle on first launch, then
    /// user-editable (edits are preserved across launches).
    static var agentsDir: URL     { appSupport.appendingPathComponent("agents", isDirectory: true).ensured() }
    /// Experiential memory for the evolving Code-tab agent — one Markdown file per
    /// project (a list of `- ` bullet lessons/facts). The agent reads these into
    /// its prompt before each task and appends new lessons after each task, so it
    /// improves across sessions without any fine-tuning. User-editable Markdown.
    static var agentMemoryDir: URL { appSupport.appendingPathComponent("agentmemory", isDirectory: true).ensured() }
    /// Saved chat conversations for the Chat tab — one `<uuid>.json` per
    /// conversation (`ConversationStore`), so a big transcript rewrites only its
    /// own file. Independent of SwiftData / the training loop.
    static var conversationsDir: URL { appSupport.appendingPathComponent("conversations", isDirectory: true).ensured() }
    /// Saved Story-mode projects — one `<uuid>.json` per story (`StoryStore`), each
    /// holding the premise/settings + all chapters. Independent of SwiftData.
    static var storiesDir: URL { appSupport.appendingPathComponent("stories", isDirectory: true).ensured() }
    /// Generated illustrations for a story, one folder per story id (kept out of
    /// the flat `stories/<uuid>.json` files). Removed when the story is deleted.
    static func storyImagesDir(for storyID: UUID) -> URL {
        appSupport.appendingPathComponent("storyimages", isDirectory: true)
            .appendingPathComponent(storyID.uuidString, isDirectory: true).ensured()
    }

    /// Free-form generated images for the Imagine tab: `imagegen/<uuid>.png` +
    /// `imagegen/gallery.json` (the `ImagineStore` metadata). Independent of Story.
    static var imagesDir: URL { appSupport.appendingPathComponent("imagegen", isDirectory: true).ensured() }

    static func adapterDir(for jobID: UUID) -> URL {
        adaptersDir.appendingPathComponent(jobID.uuidString, isDirectory: true).ensured()
    }

    static func datasetDir(for id: UUID) -> URL {
        datasetsDir.appendingPathComponent(id.uuidString, isDirectory: true).ensured()
    }

    static func selfImproveRunDir(for id: UUID) -> URL {
        selfImproveDir.appendingPathComponent(id.uuidString, isDirectory: true).ensured()
    }

    /// A folder under `evals/` addressed by a string id — used for both suite
    /// folders (e.g. "humaneval", "custom-<uuid>") and per-run sidecar folders
    /// (the EvalRun's uuid). Created on access like the other dir helpers.
    static func evalSuiteDir(for id: String) -> URL {
        evalsDir.appendingPathComponent(id, isDirectory: true).ensured()
    }

    private static func ensureDir(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

private extension URL {
    func ensured() -> URL {
        try? FileManager.default.createDirectory(at: self, withIntermediateDirectories: true)
        return self
    }
}
