import Foundation
import Observation

/// Which local image engine a model runs on. FLUX runs via **mflux**
/// (`generate_image.py`); SDXL and SD 1.5/2.x run via the vendored MLX Stable
/// Diffusion engine (`sdxl_generate.py`). The two take different args (FLUX is
/// guidance-distilled → no CFG/negative; SDXL uses both), so `ImageGenService.generate`
/// routes on this.
enum ImageModelFamily: String, Sendable, Hashable {
    case flux, sdxl, sd

    var engineHelper: String { self == .flux ? "generate_image.py" : "sdxl_generate.py" }
    var usesCFG: Bool { self != .flux }         // FLUX is guidance-distilled (CFG≈1)
}

/// A selectable local text-to-image model. FLUX presets are ungated mflux mirrors
/// (no HF token). SDXL/SD entries are the user's own downloaded diffusers models,
/// discovered in the HF cache. `baseModel` is a family-specific hint: for FLUX the
/// mflux architecture ("schnell"/"dev"); for SDXL the detected **variant** tag
/// ("sdxl"/"illustrious"/"pony"/"turbo"/… — drives step/CFG defaults). `cfg` and
/// `negative` are only used by SDXL/SD (FLUX ignores them).
struct ImageModel: Identifiable, Hashable, Sendable {
    let repo: String
    let name: String
    let family: ImageModelFamily
    let baseModel: String          // FLUX: "schnell"|"dev"; SDXL: variant tag
    let steps: Int
    let cfg: Double
    let negative: String
    let note: String
    /// For a **single-file** SDXL/SD checkpoint: the `.safetensors` filename within
    /// the repo (a repo may hold several, e.g. WAI ships v9/v12/v14). nil for a
    /// diffusers-layout model or a FLUX preset. Makes each checkpoint independently
    /// selectable and gives the conversion cache a stable key.
    let checkpointFile: String?
    var id: String { checkpointFile.map { "\(repo)#\($0)" } ?? repo }

    // Convenience initializer for the FLUX presets (family/cfg/negative fixed).
    init(repo: String, name: String, baseModel: String, steps: Int, note: String,
         family: ImageModelFamily = .flux, cfg: Double = 1.0, negative: String = "",
         checkpointFile: String? = nil) {
        self.repo = repo; self.name = name; self.family = family
        self.baseModel = baseModel; self.steps = steps; self.cfg = cfg
        self.negative = negative; self.note = note; self.checkpointFile = checkpointFile
    }

    static let presets: [ImageModel] = [
        .init(repo: "dhairyashil/FLUX.1-schnell-mflux-4bit", name: "FLUX.1 schnell — fast",
              baseModel: "schnell", steps: 4, note: "Fastest · 4-bit · ~10 GB"),
        .init(repo: "dhairyashil/FLUX.1-schnell-mflux-8bit", name: "FLUX.1 schnell — sharper",
              baseModel: "schnell", steps: 4, note: "Sharper · 8-bit · ~18 GB"),
        .init(repo: "dhairyashil/FLUX.1-dev-mflux-4bit", name: "FLUX.1 dev — higher quality",
              baseModel: "dev", steps: 20, note: "Higher quality, slower (~20 steps) · 4-bit · ~10 GB"),
        .init(repo: "dhairyashil/FLUX.1-dev-mflux-8bit", name: "FLUX.1 dev — best",
              baseModel: "dev", steps: 20, note: "Best quality, slowest · 8-bit · ~18 GB"),
    ]

    static var `default`: ImageModel { presets[0] }
    static func preset(repo: String) -> ImageModel { presets.first { $0.repo == repo } ?? .default }

    /// Build an `ImageModel` for a downloaded SD/SDXL model, choosing step/CFG/negative
    /// defaults from the checkpoint's variant (detected by name). See `SDXLVariant` for
    /// the lookup table. Pass `checkpointFile` for a single-file `.safetensors`
    /// checkpoint (converted to diffusers on first use); omit it for a diffusers dir.
    static func sdxl(repo: String, family: ImageModelFamily, checkpointFile: String? = nil) -> ImageModel {
        // Variant detection sees the checkpoint filename too (e.g. "…Lightning_4S").
        let v = SDXLVariant.detect(checkpointFile.map { "\(repo)/\($0)" } ?? repo)
        let short: String = {
            if let f = checkpointFile { return (f as NSString).deletingPathExtension }
            return repo.split(separator: "/").last.map(String.init) ?? repo
        }()
        let note = checkpointFile != nil ? v.note.replacingOccurrences(of: "your download", with: "single-file") : v.note
        return .init(repo: repo, name: short, baseModel: v.tag, steps: v.steps,
                     note: note, family: family, cfg: v.cfg, negative: v.negative,
                     checkpointFile: checkpointFile)
    }
}

/// SDXL checkpoint variants have very different optimal settings. Detected by
/// case-insensitive name substring (distillation flags win, then anime families,
/// then base). Values grounded in community/official guidance; distilled variants
/// (Turbo/Lightning/Hyper) use few steps + CFG≈0 and no negative prompt.
enum SDXLVariant {
    case base, illustrious, noobai, pony, turbo, lightning, hyper

    static func detect(_ repo: String) -> SDXLVariant {
        let n = repo.lowercased()
        if n.contains("turbo") { return .turbo }
        if n.contains("lightning") { return .lightning }
        if n.contains("hyper") { return .hyper }
        if n.contains("pony") { return .pony }
        if n.contains("noob") { return .noobai }
        if n.contains("illustri") || n.contains("wai") { return .illustrious }
        return .base
    }

    var tag: String {
        switch self {
        case .base: "sdxl"; case .illustrious: "illustrious"; case .noobai: "noobai"
        case .pony: "pony"; case .turbo: "turbo"; case .lightning: "lightning"; case .hyper: "hyper"
        }
    }
    var steps: Int {
        switch self {
        case .base: 28; case .illustrious: 26; case .noobai: 30; case .pony: 25
        case .turbo: 4; case .lightning: 6; case .hyper: 6
        }
    }
    var cfg: Double {
        switch self {
        case .base: 6.0; case .illustrious: 5.0; case .noobai: 4.5; case .pony: 7.0
        case .turbo: 0.0; case .lightning: 0.0; case .hyper: 1.0
        }
    }
    /// A light default negative for the CFG-using variants; empty for distilled
    /// (CFG≈0 makes the negative encoder a no-op, so sending one is pointless).
    var negative: String {
        switch self {
        case .turbo, .lightning, .hyper: ""
        default: "lowres, bad anatomy, bad hands, worst quality, low quality, jpeg artifacts, watermark, signature"
        }
    }
    var note: String {
        switch self {
        case .base: "SDXL · your download"
        case .illustrious: "SDXL (Illustrious) · anime · your download"
        case .noobai: "SDXL (NoobAI) · anime · your download"
        case .pony: "SDXL (Pony) · needs score tags · your download"
        case .turbo: "SDXL Turbo · fast (4 steps) · your download"
        case .lightning: "SDXL Lightning · fast · your download"
        case .hyper: "Hyper-SDXL · fast · your download"
        }
    }
}

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

    /// Whether a model repo's weights are already in the HF cache (so the picker can
    /// show "Ready" vs a download-size hint). Presence-based — a partial/interrupted
    /// download reads as present, which is fine: the next generate resumes it.
    nonisolated static func isRepoCached(_ repo: String) -> Bool {
        let safe = "models--" + repo.replacingOccurrences(of: "/", with: "--")
        let fm = FileManager.default
        for base in [PathResolver.hfHome, PathResolver.hfHome.appendingPathComponent("hub")] {
            let snaps = base.appendingPathComponent(safe).appendingPathComponent("snapshots")
            if let entries = try? fm.contentsOfDirectory(atPath: snaps.path), !entries.isEmpty {
                return true
            }
        }
        return false
    }
    nonisolated func isModelDownloaded(_ repo: String) -> Bool { Self.isRepoCached(repo) }

    /// Every image model the user has on disk: downloaded FLUX presets plus their own
    /// FLUX/SDXL/SD downloads (diffusers + single-file). For the Models tab's "what do
    /// my installed models support" view. `static` so it can run off the main thread.
    nonisolated static func downloadedImageModels() -> [ImageModel] {
        ImageModel.presets.filter { isRepoCached($0.repo) } + downloadedNonPresetImageModels()
    }

    /// Image models (FLUX, SDXL, or SD 1.5/2.x) found in the HF cache that AREN'T a
    /// built-in preset — so a user's own downloaded image model is selectable and
    /// routed to the right engine. Detects both a **diffusers layout** (`unet/` or
    /// `transformer/`, classified via `model_index.json` + folder markers) and
    /// **single-file** `.safetensors` SDXL/SD checkpoints (each an entry, converted to
    /// diffusers on first use). Chat LLMs (config.json, no diffusion markers) and video
    /// models (WAN/SVD/LTX) never appear.
    ///
    /// Reads safetensors headers for single-file candidates, so it's not free — callers
    /// should cache the result (the Imagine view scans once on appear, off the main
    /// thread) rather than calling it per render. `static` so it can run in a detached
    /// task without touching the `@MainActor` singleton.
    nonisolated static func downloadedNonPresetImageModels() -> [ImageModel] {
        let presetRepos = Set(ImageModel.presets.map(\.repo))
        let fm = FileManager.default
        var seen = Set<String>()
        var out: [ImageModel] = []
        for base in [PathResolver.hfHome, PathResolver.hfHome.appendingPathComponent("hub")] {
            guard let dirs = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { continue }
            for d in dirs where d.lastPathComponent.hasPrefix("models--") {
                let repo = d.lastPathComponent
                    .replacingOccurrences(of: "models--", with: "")
                    .replacingOccurrences(of: "--", with: "/")
                if presetRepos.contains(repo) || seen.contains(repo) { continue }
                guard let snap = Self.snapshot(in: d) else { continue }
                if let family = Self.classifyDiffusers(atSnapshot: snap, repo: repo) {
                    seen.insert(repo)
                    switch family {
                    case .flux:
                        let nl = repo.lowercased()
                        let dev = nl.contains("dev") || nl.contains("kontext") || nl.contains("krea")
                        let short = repo.split(separator: "/").last.map(String.init) ?? repo
                        out.append(.init(repo: repo, name: short, baseModel: dev ? "dev" : "schnell",
                                         steps: dev ? 20 : 4, note: "FLUX · your download"))
                    case .sdxl, .sd:
                        out.append(.sdxl(repo: repo, family: family))
                    }
                } else {
                    // No diffusers layout — look for single-file SDXL/SD checkpoints.
                    let sfs = Self.singleFileCheckpoints(atSnapshot: snap)
                    if !sfs.isEmpty { seen.insert(repo) }
                    for sf in sfs {
                        out.append(.sdxl(repo: repo, family: sf.family, checkpointFile: sf.file))
                    }
                }
            }
        }
        return out
    }

    /// Single-file `.safetensors` SDXL/SD checkpoints in a snapshot root (each a
    /// selectable model). Skips repos that carry a `config.json` (those are LLMs) and
    /// inspects each `.safetensors` header for the diffusion signatures — SDXL has a
    /// second text encoder (`conditioner.embedders.1`), SD has `model.diffusion_model`
    /// without it; an LLM has neither (`model.layers`/`embed_tokens` instead).
    nonisolated static func singleFileCheckpoints(atSnapshot snap: URL) -> [(file: String, family: ImageModelFamily)] {
        let fm = FileManager.default
        // config.json in the root ⇒ an LLM / non-single-file model; skip entirely.
        if fm.fileExists(atPath: snap.appendingPathComponent("config.json").path) { return [] }
        guard let entries = try? fm.contentsOfDirectory(at: snap, includingPropertiesForKeys: nil) else { return [] }
        var out: [(file: String, family: ImageModelFamily)] = []
        for url in entries where url.pathExtension == "safetensors" {
            guard let keys = try? SafetensorsHeader.parse(shard: url).entries else { continue }
            let hasUNet = keys.contains { $0.name.hasPrefix("model.diffusion_model.") }
            guard hasUNet else { continue }  // not a diffusion checkpoint (e.g. an LLM)
            let hasBigG = keys.contains { $0.name.hasPrefix("conditioner.embedders.1") }
            out.append((url.lastPathComponent, hasBigG ? .sdxl : .sd))
        }
        return out.sorted { $0.file < $1.file }
    }

    /// Whether a diffusers component folder (unet/, transformer/) actually holds
    /// weights — a `.safetensors` file or a sharded `.safetensors.index.json`. A
    /// config-only folder (just `config.json`) returns false.
    nonisolated static func dirHasWeights(_ dir: URL) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return false }
        return entries.contains { $0.hasSuffix(".safetensors") || $0.hasSuffix(".safetensors.index.json") }
    }

    /// The (first) snapshot directory inside a cached `models--…` dir, or nil.
    nonisolated static func snapshot(in modelDir: URL) -> URL? {
        (try? FileManager.default.contentsOfDirectory(
            at: modelDir.appendingPathComponent("snapshots"), includingPropertiesForKeys: nil))?
            .first { $0.hasDirectoryPath }
    }

    /// Classify a cached model by image-engine family (FLUX / SDXL / SD), or nil if
    /// it's not a runnable image model (a chat LLM, a video model, an SD3/other
    /// transformer we can't run, or a single-file checkpoint). Reads the
    /// `model_index.json` pipeline class first, then falls back to folder markers
    /// (`unet/` + `text_encoder_2/` = SDXL; `unet/` alone = SD; `transformer/` = FLUX).
    nonisolated static func classifyDiffusers(atSnapshot snap: URL, repo: String) -> ImageModelFamily? {
        let fm = FileManager.default
        // Require actual WEIGHTS in the folder, not just its config.json — a
        // `from_single_file` conversion fetches config-only copies of the SDXL base
        // pipeline into the cache, which would otherwise read as a selectable-but-broken
        // model (no unet weights to generate with).
        let hasTransformer = Self.dirHasWeights(snap.appendingPathComponent("transformer"))
        let hasUNet = Self.dirHasWeights(snap.appendingPathComponent("unet"))
        let hasTE2 = fm.fileExists(atPath: snap.appendingPathComponent("text_encoder_2").path)
        guard hasTransformer || hasUNet else { return nil }   // not a runnable diffusers model
        let cls = (try? String(contentsOf: snap.appendingPathComponent("model_index.json"),
                               encoding: .utf8))?.lowercased() ?? ""
        let nl = repo.lowercased()
        // Video diffusers models exist but we can't run them.
        if ["wan", "svd", "stable-video", "ltx", "cogvideo", "hunyuanvideo", "mochi"]
            .contains(where: { nl.contains($0) }) { return nil }
        if cls.contains("fluxpipeline") || (hasTransformer && nl.contains("flux")) { return .flux }
        if cls.contains("stablediffusionxlpipeline") || (hasUNet && hasTE2) { return .sdxl }
        if cls.contains("stablediffusionpipeline") || (hasUNet && !hasTE2) { return .sd }
        return nil   // e.g. SD3 (transformer, non-FLUX) — no engine yet
    }

    /// Resolve the local diffusers snapshot directory for a downloaded repo — the
    /// SDXL/SD engine loads from a path, not a repo id. nil if not on disk.
    nonisolated func snapshotDir(for repo: String) -> URL? {
        let safe = "models--" + repo.replacingOccurrences(of: "/", with: "--")
        for base in [PathResolver.hfHome, PathResolver.hfHome.appendingPathComponent("hub")] {
            if let snap = Self.snapshot(in: base.appendingPathComponent(safe)) { return snap }
        }
        return nil
    }

    // MARK: - Install gate

    func installed() async -> Bool { await PythonRuntime.shared.imageGenInstalled() }

    @discardableResult
    func install(onLine: @escaping @MainActor (String) -> Void = { _ in }) async -> Bool {
        await PythonRuntime.shared.installImageGen(progress: onLine)
    }

    // MARK: - Generate

    /// Render a batch, returning the absolute paths actually written (a failed image
    /// is skipped, not fatal — the rest of the chapter still gets illustrated).
    /// Serialized: a second call while one is running returns `[]` rather than loading
    /// a second model in parallel.
    ///
    /// Routes on `family`: **FLUX** → `generate_image.py` (mflux, guidance-distilled,
    /// so CFG/negative are ignored); **SDXL/SD** → `sdxl_generate.py` (vendored MLX
    /// Stable Diffusion, which honors CFG + negative). For SDXL/SD, `model` is a repo id
    /// we resolve to its cache snapshot dir — unlike FLUX there's no lazy auto-download,
    /// so if it isn't on disk this fails cleanly. If `checkpointFile` is set the model is
    /// a **single-file** `.safetensors`: we pass that file + a `--convert-cache` dir, and
    /// the helper converts it to diffusers once (cached) before loading.
    ///
    /// **Cancellation-aware:** if the awaiting Task is cancelled (Story `stop()`,
    /// switching stories, deinit), the subprocess is terminated instead of running to
    /// completion in the background. Returns whatever was saved before the cancel.
    func generate(_ requests: [Request],
                  family: ImageModelFamily = .flux,
                  model: String = ImageGenService.defaultModel,
                  baseModel: String = ImageGenService.defaultBaseModel,
                  steps: Int = 4,
                  cfg: Double = 1.0,
                  negative: String = "",
                  checkpointFile: String? = nil,
                  width: Int = 1024, height: Int = 768) async -> [String] {
        guard !requests.isEmpty else { return [] }
        guard progress == nil else {
            Log.error("Image generation already in progress — dropping overlapping batch", .app)
            return []
        }
        guard let python = PythonRuntime.shared.pythonURL else { return [] }
        let helper = PathResolver.helpersDir.appendingPathComponent(family.engineHelper)
        guard FileManager.default.fileExists(atPath: helper.path) else {
            Log.error("\(family.engineHelper) missing — runtime not fully bootstrapped", .app)
            return []
        }

        // FLUX loads from a repo id (mflux fetches it lazily); SDXL/SD load from a
        // local diffusers dir (or a single-file .safetensors) that must be on disk.
        let modelArg: String
        var convertCache: String? = nil
        if family == .flux {
            modelArg = model
        } else if let dir = snapshotDir(for: model) {
            if let ckpt = checkpointFile {
                // Single-file: pass the .safetensors path + a per-checkpoint cache dir
                // for its one-time diffusers conversion.
                modelArg = dir.appendingPathComponent(ckpt).path
                let key = "\(model)#\(ckpt)".replacingOccurrences(of: "/", with: "_")
                convertCache = PathResolver.sdxlConvertedDir.appendingPathComponent(key, isDirectory: true).path
            } else {
                modelArg = dir.path
            }
        } else {
            Log.error("SDXL/SD model not downloaded — can't resolve local dir for \(model)", .app)
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

        var args = [helper.path, "--prompts-json", listURL.path,
                    "--model", modelArg,
                    "--steps", String(steps), "--width", String(width),
                    "--height", String(height), "--metadata"]
        if family == .flux {
            args += ["--base-model", baseModel]
        } else {
            args += ["--cfg", String(cfg), "--negative", negative]
            if let convertCache { args += ["--convert-cache", convertCache] }
        }

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
