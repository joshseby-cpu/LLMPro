import Foundation
import Observation

/// Local text-to-image for Story illustrations. Runs `generate_image.py` (mflux /
/// MLX FLUX) as a subprocess and parses its JSON-event stdout. A whole chapter's
/// illustrations go through one `generate(_:)` call — the ~12B FLUX model loads
/// once per call and is reused for every image in the batch.
///
/// Optional add-on: `mflux` isn't part of the Ready gate. The UI checks
/// `installed()` and offers `install()` before the first illustration.
@MainActor
@Observable
final class ImageGenService {
    static let shared = ImageGenService()
    private init() {}

    /// The default image model: an **ungated**, pre-quantized mflux mirror of
    /// FLUX.1-schnell (Apache-2.0). The canonical `black-forest-labs/FLUX.1-schnell`
    /// is a **gated** repo (needs an HF token + accepted terms), which breaks the
    /// app's zero-setup promise; this mirror needs neither and is smaller (~10 GB,
    /// pre-quantized 4-bit). `defaultBaseModel` is the architecture hint mflux needs
    /// when the model is a custom repo.
    static let defaultModel = "dhairyashil/FLUX.1-schnell-mflux-4bit"
    static let defaultBaseModel = "schnell"

    /// One image to render. `output` is the absolute destination PNG.
    struct Request: Sendable {
        let prompt: String
        let output: URL
        let seed: Int
    }

    /// Live batch progress (non-nil only while a batch runs). `loadingModel` is true
    /// during the initial load, which on first run also downloads FLUX (~24–34 GB) —
    /// so the UI can show a "first-time download" note instead of looking hung.
    struct Progress: Equatable {
        var done: Int
        var total: Int
        var loadingModel: Bool
    }
    private(set) var progress: Progress?

    var isBusy: Bool { progress != nil }

    // MARK: - Install gate

    func installed() async -> Bool { await PythonRuntime.shared.imageGenInstalled() }

    @discardableResult
    func install(onLine: @escaping @MainActor (String) -> Void = { _ in }) async -> Bool {
        await PythonRuntime.shared.installImageGen(progress: onLine)
    }

    // MARK: - Generate

    /// Render a batch, returning the absolute paths actually written (a failed image
    /// is skipped, not fatal — the rest of the chapter still gets illustrated). Steps
    /// stay at 4 (FLUX.1-schnell is timestep-distilled). Serialized: a second call
    /// while one is running returns `[]` rather than loading a second FLUX in parallel.
    ///
    /// **Cancellation-aware:** if the awaiting Task is cancelled (Story `stop()`,
    /// switching stories, deinit), the FLUX subprocess is terminated instead of
    /// running to completion in the background. Returns whatever was saved before the
    /// cancel; the caller discards/cleans those on the supersede path.
    func generate(_ requests: [Request],
                  steps: Int = 4,
                  width: Int = 1024, height: Int = 768) async -> [String] {
        guard !requests.isEmpty else { return [] }
        guard progress == nil else {
            Log.error("Image generation already in progress — dropping overlapping batch", .app)
            return []
        }
        guard let python = PythonRuntime.shared.pythonURL else { return [] }
        let helper = PathResolver.helpersDir.appendingPathComponent("generate_image.py")
        guard FileManager.default.fileExists(atPath: helper.path) else {
            Log.error("generate_image.py missing — runtime not fully bootstrapped", .app)
            return []
        }

        // Batch JSONL: one {prompt, output, seed} per line so the model loads once.
        let listURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("imgreq-\(UUID().uuidString).jsonl")
        var lines: [String] = []
        for r in requests {
            let obj: [String: Any] = ["prompt": r.prompt, "output": r.output.path, "seed": r.seed]
            if let d = try? JSONSerialization.data(withJSONObject: obj),
               let s = String(data: d, encoding: .utf8) { lines.append(s) }
        }
        guard (try? lines.joined(separator: "\n").write(to: listURL, atomically: true, encoding: .utf8)) != nil
        else {
            Log.error("Couldn't write image-request list", .app)
            return []
        }
        defer { try? FileManager.default.removeItem(at: listURL) }

        progress = Progress(done: 0, total: requests.count, loadingModel: true)
        defer { progress = nil }

        let args = [helper.path, "--prompts-json", listURL.path,
                    "--model", Self.defaultModel, "--base-model", Self.defaultBaseModel,
                    "--steps", String(steps), "--width", String(width),
                    "--height", String(height), "--metadata"]

        // HF_HOME shares the model cache with the rest of the app. Pass the user's
        // HF token when they have one (mirrors DownloadService) — the default mirror
        // is ungated, but this lets a token-holder use a gated model too, and speeds
        // authenticated downloads. Token travels via env, never argv.
        var env = ["HF_HOME": PathResolver.hfHome.path]
        if let token = KeychainHelper.readHFToken(), !token.isEmpty { env["HF_TOKEN"] = token }

        let running: RunningProcess
        do {
            running = try await ProcessRunner.spawn(
                executable: python, arguments: args, environment: env)
        } catch {
            Log.error("Image generation couldn't start", .app, error: error)
            return []
        }

        // Consume stdout on the main actor (this function is @MainActor, so the
        // for-await body resumes here) — no lock needed. `onCancel` terminates the
        // child so a Stop kills FLUX instead of leaking it. stderr is drained in
        // parallel so its 64 KB pipe can't fill and stall the child.
        var savedPaths: [String] = []
        await withTaskCancellationHandler {
            let stderrDrain = Task.detached { for await _ in running.stderr {} }
            for await line in running.stdout {
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                let event = json["event"] as? String
                if event == "progress", (json["stage"] as? String) == "saved",
                   let p = json["path"] as? String { savedPaths.append(p) }
                if var prog = progress {
                    prog.done = savedPaths.count
                    if event == "progress" || event == "done" { prog.loadingModel = false }
                    else if event == "start" || event == "loading" || event == "heartbeat" {
                        prog.loadingModel = true
                    }
                    progress = prog
                }
            }
            _ = try? await running.exit.value
            await stderrDrain.value
        } onCancel: {
            running.terminate()
        }
        return savedPaths
    }
}
