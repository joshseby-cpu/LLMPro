import Foundation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class ModelRegistry {
    static let shared = ModelRegistry()

    private(set) var localModels: [DetectedModel] = []
    private(set) var lastScan: Date?
    private(set) var isScanning = false

    struct DetectedModel: Identifiable, Hashable {
        let id: String
        let repoID: String
        let directory: URL
        let architecture: String
        let quantization: String
        let sizeBytes: Int64
        let isMLXReady: Bool
        /// Total number of experts in the model, if it's a Mixture-of-Experts
        /// architecture. 0 means a dense (non-MoE) model. Populated by reading
        /// `num_local_experts` or `num_experts` from config.json.
        var numExperts: Int = 0
        /// How many experts the router activates per token. For dense models
        /// this is 0; for MoE typically 2 (Mixtral, Qwen-MoE) or 1.
        var expertsPerToken: Int = 0
        /// True when this is a Google DiffusionGemma checkpoint — a masked /
        /// block-diffusion LM with no autoregressive mlx-lm class. The Arena
        /// routes these to the vendored `diffusion_generate.py` helper instead
        /// of `mlx_lm generate`. Detected from config.json's top-level
        /// `model_type == "diffusion_gemma"` (or a `DiffusionGemma*` architecture).
        var isDiffusion: Bool = false

        var displayName: String { repoID.split(separator: "/").last.map(String.init) ?? repoID }
        var humanSize: String { ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file) }
        var supportsNativeGGUF: Bool { ["llama", "mistral", "mixtral"].contains(architecture.lowercased()) }
        /// True when this is a Mixture-of-Experts model and the rest of the
        /// app should treat it as one (different LoRA target patterns,
        /// expert-picker UI, sparse-upcycling availability).
        var isMoE: Bool { numExperts > 1 }
    }

    private init() {}

    /// Pick which of two `DetectedModel`s for the *same* repoID to keep when the
    /// HF cache holds the model in both on-disk layouts (`<HF_HOME>/models--*`
    /// and `<HF_HOME>/hub/models--*`). The two layouts can report different
    /// sizes — the `hub/` layout's `blobs/` symlink readout is sometimes wrong
    /// (it has reported 26.9 MB for a 28 GB model), so naively letting the
    /// later-scanned entry overwrite the earlier one clobbers a correct size
    /// with a bogus one. Keep the entry with the larger `sizeBytes`; `a` wins
    /// ties so the merge is stable (first-scanned survives an exact tie).
    /// Pure and filesystem-free so it can be unit-tested directly.
    static func preferredDuplicate(_ a: DetectedModel, _ b: DetectedModel) -> DetectedModel {
        a.sizeBytes >= b.sizeBytes ? a : b
    }

    /// Delete every on-disk artefact for a model from disk. Handles:
    ///   - HF snapshot-cache layout                 (<HF_HOME>/models--*)
    ///   - HF standard hub layout                   (<HF_HOME>/hub/models--*)
    ///   - Both layouts' sibling `.locks` dirs
    ///   - Custom-models drop folder                (<modelsCustomDir>/<name>/)
    /// Custom models (strip-vision / abliterate output, manual imports) use the
    /// bare folder name as their repoID — no `owner/repo` slash — so we treat
    /// any slash-free repoID as a candidate for the custom dir.
    /// Returns the number of bytes freed.
    enum LMStudioInstallError: LocalizedError {
        case sourceMissing
        case destinationExists(URL)
        case lmStudioNotFound
        case cpFailed(Int32, String)
        var errorDescription: String? {
            switch self {
            case .sourceMissing: "Model files are missing on disk."
            case .destinationExists(let url): "LM Studio already has a model at \(url.path). Pick a different name."
            case .lmStudioNotFound: "Couldn't find LM Studio's models folder at ~/.lmstudio/models/. Install LM Studio first (https://lmstudio.ai)."
            case .cpFailed(let code, let msg): "Copy failed (exit \(code)): \(msg)"
            }
        }
    }

    /// Copy a local MLX model into LM Studio's models directory using the
    /// `<publisher>/<name>/` layout LM Studio expects. Uses `cp -cRL` so the
    /// transfer is CoW on APFS (zero extra disk) and dereferences any HF
    /// snapshot symlinks (LM Studio reads the files directly, not symlinks).
    /// Creates the LM Studio dir if it doesn't exist; if LM Studio has never
    /// been launched and `.lmstudio/` is entirely missing, returns an error
    /// telling the user to install it.
    func installInLMStudio(source: ModelRegistry.DetectedModel,
                           publisher: String,
                           name: String) async -> Result<URL, LMStudioInstallError> {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.directory.path) else { return .failure(.sourceMissing) }

        let lmstudioRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".lmstudio")
        guard fm.fileExists(atPath: lmstudioRoot.path) else { return .failure(.lmStudioNotFound) }

        let modelsRoot = PathResolver.lmStudioDefault
        try? fm.createDirectory(at: modelsRoot, withIntermediateDirectories: true)

        let dest = modelsRoot
            .appendingPathComponent(publisher, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        if fm.fileExists(atPath: dest.path) { return .failure(.destinationExists(dest)) }
        try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

        let result: Result<URL, LMStudioInstallError> = await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/cp")
            process.arguments = ["-cRL", source.directory.path + "/", dest.path]
            let err = Pipe()
            process.standardError = err
            process.standardOutput = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return .failure(.cpFailed(-1, error.localizedDescription))
            }
            if process.terminationStatus != 0 {
                let errData = (try? err.fileHandleForReading.readToEnd()) ?? Data()
                let errStr = String(data: errData, encoding: .utf8) ?? ""
                return .failure(.cpFailed(process.terminationStatus, errStr))
            }
            return .success(dest)
        }.value

        // Post-copy: replace the Gemma chat template with the minja-compatible
        // version. Gemma-4 ships a 17 KB Jinja that uses `is sequence`,
        // unconditional `| upper` on possibly-undefined fields, macros, and
        // namespaces — LM Studio's minja runtime chokes on every one. The
        // patched template strips out the unsupported constructs while keeping
        // turn-delimiter format (`<|turn>role\n...<turn|>\n`) and tool-use
        // markers intact. Skip for non-Gemma architectures since their
        // templates work fine as-is.
        if case .success(let installedDir) = result {
            patchChatTemplateIfNeeded(at: installedDir, source: source)
        }

        return result
    }

    /// Replace the chat template if the model's runtime tools (LM Studio's
    /// minja) can't handle the original. Original is preserved as
    /// `chat_template.jinja.original-backup` so users can restore it.
    private func patchChatTemplateIfNeeded(at installedDir: URL,
                                           source: ModelRegistry.DetectedModel) {
        let arch = source.architecture.lowercased()
        let repo = source.repoID.lowercased()

        // Gemma-4: ships a sophisticated tool-use template that minja can't
        // parse (`is sequence` test missing, plus `| upper` on undefined
        // `type` fields). Replace with the bundled patched template.
        let isGemma4 = arch.contains("gemma4") || repo.contains("gemma-4") || repo.contains("gemma4")
        guard isGemma4 else { return }

        guard let bundledURL = Bundle.main.url(forResource: "gemma-4-minja",
                                               withExtension: "jinja",
                                               subdirectory: "templates")
                              ?? Bundle.main.url(forResource: "gemma-4-minja",
                                                 withExtension: "jinja")
        else { return }

        let dst = installedDir.appendingPathComponent("chat_template.jinja", isDirectory: false)
        let backup = installedDir.appendingPathComponent("chat_template.jinja.original-backup",
                                                         isDirectory: false)
        let fm = FileManager.default
        if fm.fileExists(atPath: dst.path) {
            try? fm.removeItem(at: backup)
            try? fm.moveItem(at: dst, to: backup)
        }
        try? fm.copyItem(at: bundledURL, to: dst)
    }

    enum DuplicateError: LocalizedError {
        case sourceMissing
        case destinationExists(URL)
        case cpFailed(Int32, String)
        var errorDescription: String? {
            switch self {
            case .sourceMissing: "Source model directory not found."
            case .destinationExists(let url): "A folder already exists at \(url.lastPathComponent)."
            case .cpFailed(let code, let msg): "Copy failed (exit \(code)): \(msg)"
            }
        }
    }

    /// Make a full standalone copy of an on-disk model as a new entry under
    /// `modelsCustomDir/<newName>/`. Uses `cp -cRL`:
    ///   -c  clonefile() on APFS → Copy-on-Write, near-zero extra disk
    ///   -R  recursive
    ///   -L  dereference symlinks (HF cache uses `snapshots/<rev>/*.safetensors
    ///        → ../../blobs/<sha>`; the copy needs real files, not dangling
    ///        symlinks into the original blobs/)
    /// On non-APFS volumes the -c flag is silently ignored and we fall back to
    /// a real byte copy. Either way the destination is functionally independent.
    func duplicate(source: ModelRegistry.DetectedModel, newName: String) async -> Result<URL, DuplicateError> {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.directory.path) else { return .failure(.sourceMissing) }

        let dest = PathResolver.modelsCustomDir.appendingPathComponent(newName, isDirectory: true)
        if fm.fileExists(atPath: dest.path) { return .failure(.destinationExists(dest)) }

        // Run cp off the main actor; copy can take seconds on non-APFS.
        let result: Result<URL, DuplicateError> = await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/cp")
            process.arguments = ["-cRL", source.directory.path + "/", dest.path]
            let err = Pipe()
            process.standardError = err
            process.standardOutput = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return .failure(.cpFailed(-1, error.localizedDescription))
            }
            if process.terminationStatus != 0 {
                let errData = (try? err.fileHandleForReading.readToEnd()) ?? Data()
                let errStr = String(data: errData, encoding: .utf8) ?? ""
                return .failure(.cpFailed(process.terminationStatus, errStr))
            }
            return .success(dest)
        }.value

        if case .success = result { await scan() }
        return result
    }

    @discardableResult
    func delete(repoID: String) async -> Int64 {
        let safe = "models--" + repoID.replacingOccurrences(of: "/", with: "--")
        var candidates: [URL] = [
            PathResolver.hfHome.appendingPathComponent(safe, isDirectory: true),
            PathResolver.hfHome.appendingPathComponent("hub", isDirectory: true).appendingPathComponent(safe, isDirectory: true),
            PathResolver.hfHome.appendingPathComponent(".locks", isDirectory: true).appendingPathComponent(safe, isDirectory: true),
            PathResolver.hfHome.appendingPathComponent("hub", isDirectory: true).appendingPathComponent(".locks", isDirectory: true).appendingPathComponent(safe, isDirectory: true),
        ]
        // Custom-models dir uses the bare repoID as a folder name. Only add it as
        // a delete candidate when repoID is a single safe path component:
        // a value containing "/" would nest (or, with "..", traverse) out of the
        // custom-models dir, so removeItem could delete outside it. Require the
        // resolved URL to be a DIRECT child of modelsCustomDir.
        if !repoID.contains("/"), !repoID.contains("..") {
            let customDir = PathResolver.modelsCustomDir.appendingPathComponent(repoID, isDirectory: true)
            if customDir.deletingLastPathComponent().standardizedFileURL.path == PathResolver.modelsCustomDir.standardizedFileURL.path {
                candidates.append(customDir)
            } else {
                Log.error("ModelRegistry.delete: rejected unsafe custom-model path for repoID '\(repoID)'", .model)
            }
        }

        var freed: Int64 = 0
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            // Measure before removing. HF caches keep their weights in blobs/;
            // custom dirs keep them right next to config.json.
            if url.lastPathComponent.hasPrefix("models--") {
                let blobs = url.appendingPathComponent("blobs", isDirectory: true)
                freed += blobsDirectorySize(at: blobs)
            } else if url.path.hasPrefix(PathResolver.modelsCustomDir.path) {
                freed += directorySize(at: url)
            }
            try? FileManager.default.removeItem(at: url)
        }
        await scan()
        return freed
    }

    func scan() async {
        isScanning = true
        defer { isScanning = false; lastScan = Date() }
        var found: [String: DetectedModel] = [:]
        let fm = FileManager.default

        // The HF cache can land at TWO layouts depending on how it was populated:
        //   1. snapshot_download(cache_dir=$HF_HOME) writes to <HF_HOME>/models--<owner>--<repo>/
        //   2. mlx-lm's loader uses HF_HOME (env) which writes the standard <HF_HOME>/hub/models--<owner>--<repo>/
        // Scan both, deduping by repoID.
        let hfRoots = [
            PathResolver.hfHome,
            PathResolver.hfHome.appendingPathComponent("hub", isDirectory: true),
        ]
        for root in hfRoots {
            guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for entry in entries where entry.lastPathComponent.hasPrefix("models--") {
                if let detected = inspectHFCacheRepo(at: entry) {
                    let id = detected.repoID
                    if let existing = found[id] {
                        // Same model in both HF layouts: keep the larger reading,
                        // not whichever the directory enumeration hit last.
                        found[id] = Self.preferredDuplicate(existing, detected)
                    } else {
                        found[id] = detected
                    }
                }
            }
        }

        // Custom models drop-folder.
        if let entries = try? fm.contentsOfDirectory(at: PathResolver.modelsCustomDir, includingPropertiesForKeys: nil) {
            for entry in entries where entry.hasDirectoryPath {
                if let detected = inspectGenericModelDir(at: entry, fallbackRepoID: entry.lastPathComponent, blobsDir: nil) {
                    found[detected.repoID] = detected
                }
            }
        }

        self.localModels = found.values.sorted { $0.repoID < $1.repoID }
    }

    private func inspectHFCacheRepo(at url: URL) -> DetectedModel? {
        let trimmed = url.lastPathComponent.replacingOccurrences(of: "models--", with: "")
        let parts = trimmed.split(separator: "-", omittingEmptySubsequences: false)
        let parts2 = trimmed.components(separatedBy: "--")
        let repoID: String = parts2.count >= 2
            ? "\(parts2[0])/\(parts2[1...].joined(separator: "--"))"
            : (parts.first.map(String.init) ?? trimmed)

        let snapshots = url.appendingPathComponent("snapshots", isDirectory: true)
        guard let revisions = try? FileManager.default.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil),
              let snapshot = revisions.first(where: { $0.hasDirectoryPath })
        else { return nil }

        // Real bytes live in the `blobs/` sibling; snapshot/* are symlinks.
        let blobsDir = url.appendingPathComponent("blobs", isDirectory: true)
        return inspectGenericModelDir(at: snapshot, fallbackRepoID: repoID, blobsDir: blobsDir)
    }

    private func inspectGenericModelDir(at dir: URL, fallbackRepoID: String, blobsDir: URL?) -> DetectedModel? {
        let fm = FileManager.default
        let configURL = dir.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // Some multi-modal models (Gemma-4, Llama-4 vision, MiniCPM-V) wrap
        // a real LLM under `text_config` and only carry the wrapper's type
        // at top level. Prefer the inner model_type when present — that's
        // what the AutoTuner / MoE-key picker actually needs.
        let textConfig = (json["text_config"] as? [String: Any]) ?? [:]
        let architecture = (textConfig["model_type"] as? String)
            ?? (json["model_type"] as? String)
            ?? ((json["architectures"] as? [String])?.first?.lowercased() ?? "unknown")

        let quant: String = {
            if let q = json["quantization"] as? [String: Any], let bits = q["bits"] as? Int { return "\(bits)bit" }
            if dir.path.lowercased().contains("4bit") { return "4bit" }
            if dir.path.lowercased().contains("8bit") { return "8bit" }
            return "fp16"
        }()

        let size = blobsDir.map { blobsDirectorySize(at: $0) } ?? directorySize(at: dir)
        let isMLXReady = mlxFormatLooksValid(in: dir, fm: fm)

        // DiffusionGemma detection: a masked/block-diffusion LM that has no
        // mlx-lm class, so the Arena must route it to diffusion_generate.py.
        // Match the wrapper's top-level model_type (it stays "diffusion_gemma"
        // even though the inner text tower is "diffusion_gemma_text"), or any
        // architecture whose name starts with "DiffusionGemma".
        let rawModelType = (json["model_type"] as? String)?.lowercased() ?? ""
        let archNames = (json["architectures"] as? [String]) ?? []
        let isDiffusion = rawModelType == "diffusion_gemma"
            || archNames.contains { $0.hasPrefix("DiffusionGemma") }

        // MoE detection: read num_local_experts / num_experts from config.json.
        // Three layouts in the wild today:
        //   1. Flat top-level fields            — Mixtral / Qwen-MoE / OlmoE / Granite-MoE
        //   2. Nested under `ffn_config`        — DBRX
        //   3. Nested under `text_config`       — Gemma-4 (multi-modal wrapper), Llama-4 vision
        // The third layout is critical for the new Gemma-4-MoE models: top
        // level only carries the wrapper type, so we have to descend into
        // text_config to find the real expert count and routing config.
        // Gemma-4 also uses `top_k_experts` rather than `num_experts_per_tok`.
        let numExperts: Int = {
            for src in [json, textConfig] {
                if let n = src["num_local_experts"] as? Int, n > 1 { return n }
                if let n = src["num_experts"]       as? Int, n > 1 { return n }
            }
            if let ffn = json["ffn_config"] as? [String: Any] {
                if let n = ffn["moe_num_experts"] as? Int, n > 1 { return n }
            }
            return 0
        }()
        let expertsPerTok: Int = {
            for src in [json, textConfig] {
                if let n = src["num_experts_per_tok"] as? Int, n > 0 { return n }
                if let n = src["top_k_experts"]      as? Int, n > 0 { return n }
            }
            if let ffn = json["ffn_config"] as? [String: Any], let n = ffn["moe_top_k"] as? Int, n > 0 { return n }
            return numExperts > 1 ? 2 : 0   // sensible default for unknown MoE
        }()

        return DetectedModel(
            id: dir.path,
            repoID: fallbackRepoID,
            directory: dir,
            architecture: architecture,
            quantization: quant,
            sizeBytes: size,
            isMLXReady: isMLXReady,
            numExperts: numExperts,
            expertsPerToken: expertsPerTok,
            isDiffusion: isDiffusion
        )
    }

    private func mlxFormatLooksValid(in dir: URL, fm: FileManager) -> Bool {
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return false }
        let hasIndex = files.contains { $0.lastPathComponent == "model.safetensors.index.json" }
        let hasSingle = files.contains { $0.lastPathComponent == "model.safetensors" }
        let hasMLXTag = files.contains { $0.lastPathComponent.contains("mlx") }
        return hasIndex || hasSingle || hasMLXTag
    }

    private func directorySize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// Sum the real blob files in <repo>/blobs/ — these hold the actual weights.
    /// Use `lstat` so we measure file sizes, not symlink target resolution.
    private func blobsDirectorySize(at blobsDir: URL) -> Int64 {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: blobsDir.path) else { return 0 }
        var total: Int64 = 0
        for name in entries {
            let path = blobsDir.appendingPathComponent(name).path
            var st = stat()
            if lstat(path, &st) == 0 {
                total += Int64(st.st_size)
            }
        }
        return total
    }
}
