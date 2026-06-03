import Foundation

enum PathResolver {
    static let appSupport: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("MLXStudio", isDirectory: true)
        ensureDir(dir); return dir
    }()

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
    static var llamaCppDir: URL   { runtimeDir.appendingPathComponent("llama.cpp", isDirectory: true) }
    static var ollamaDefault: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ollama/models") }
    /// LM Studio reads models from this directory by default, laid out as
    /// `<publisher>/<name>/` containing `config.json` + safetensors (MLX) or
    /// a `.gguf` file (llama.cpp). LM Studio also reads `~/.lmstudio/hub/models/`
    /// in newer versions; both paths are scanned and either works.
    static var lmStudioDefault: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".lmstudio/models") }
    static var selfImproveDir: URL { appSupport.appendingPathComponent("selfimprove", isDirectory: true).ensured() }
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

    static func adapterDir(for jobID: UUID) -> URL {
        adaptersDir.appendingPathComponent(jobID.uuidString, isDirectory: true).ensured()
    }

    static func datasetDir(for id: UUID) -> URL {
        datasetsDir.appendingPathComponent(id.uuidString, isDirectory: true).ensured()
    }

    static func selfImproveRunDir(for id: UUID) -> URL {
        selfImproveDir.appendingPathComponent(id.uuidString, isDirectory: true).ensured()
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
