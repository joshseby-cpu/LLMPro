import Foundation

/// Imports a GGUF model file by converting it to an MLX model directory under
/// `models/<name>/`, via the `gguf_to_mlx.py` helper (MLX's native GGUF loader —
/// no PyTorch). Two phases:
///   1. `precheck(path:)` — fast metadata read; returns whether this GGUF's
///      architecture + quantization are convertible by the lightweight path, so
///      the UI can warn BEFORE a long conversion (K-quant GGUFs aren't supported).
///   2. `convert(path:outputName:)` — runs the full conversion and rescans the
///      registry so the new MLX model shows up in the Models list.
@MainActor
@Observable
final class GGUFImportService {
    static let shared = GGUFImportService()
    private init() {}

    struct PrecheckResult: Sendable {
        var convertible: Bool
        var arch: String
        var name: String
        var quant: [String]
        var nTensors: Int
        var reason: String          // why-not, when convertible == false
    }

    enum Phase: Equatable {
        case idle
        case prechecking
        case converting(stage: String, message: String)
        case done(modelName: String, modelPath: String)
        case failed(reason: String)
    }
    private(set) var phase: Phase = .idle {
        didSet {
            switch phase {
            case .failed(let r): Log.error("GGUF import failed: \(r)", .model)
            case .done(let n, _): Log.info("GGUF import done → \(n)", .model)
            default: break
            }
        }
    }

    enum ImportError: LocalizedError {
        case runtimeNotReady
        case helperMissing
        case notConvertible(String)
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .runtimeNotReady:     "The Python runtime isn't ready yet. Finish first-run setup, then try again."
            case .helperMissing:       "gguf_to_mlx.py is missing — restart the app to refresh helpers."
            case .notConvertible(let m): m
            case .failed(let m):       m
            }
        }
    }

    private var helperURL: URL { PathResolver.helpersDir.appendingPathComponent("gguf_to_mlx.py") }

    /// Download a single .gguf file from a HuggingFace repo via huggingface_hub
    /// (into the HF cache) and return its local path. Used by the "HuggingFace"
    /// source in the import sheet before precheck/convert.
    func downloadFromHuggingFace(repo: String, filename: String) async throws -> String {
        guard PythonRuntime.shared.isReady, let python = PythonRuntime.shared.pythonURL
        else { throw ImportError.runtimeNotReady }
        phase = .converting(stage: "download", message: "Downloading \(filename)…")
        let token = KeychainHelper.readHFToken() ?? ""
        let code = """
        import sys
        from huggingface_hub import hf_hub_download
        p = hf_hub_download(sys.argv[1], sys.argv[2], token=(sys.argv[3] or None))
        print("PATH:" + p)
        """
        let out = LineCollector()
        let errLines = LineCollector()
        do {
            _ = try await ProcessRunner.runCapturing(
                executable: python,
                arguments: ["-c", code, repo, filename, token],
                environment: ["HF_HOME": PathResolver.hfHome.path, "PYTHONUNBUFFERED": "1"],
                onStdout: { line in out.add(line) },
                onStderr: { line in errLines.add(line) })
        } catch {
            phase = .idle
            throw ImportError.failed(Self.lastError(errLines.all) ?? error.localizedDescription)
        }
        phase = .idle
        let path = out.all.compactMap { line -> String? in
            guard let r = line.range(of: "PATH:") else { return nil }
            return String(line[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }.last
        guard let path, FileManager.default.fileExists(atPath: path) else {
            throw ImportError.failed(Self.lastError(errLines.all) ?? "Couldn't download \(filename) from \(repo).")
        }
        return path
    }

    nonisolated private static func lastError(_ lines: [String]) -> String? {
        lines.map { $0.trimmingCharacters(in: .whitespaces) }
             .last { $0.lowercased().contains("error") }
    }

    /// Read GGUF metadata and report whether it's convertible. Fast (no tensors).
    func precheck(path: String) async throws -> PrecheckResult {
        guard PythonRuntime.shared.isReady, let python = PythonRuntime.shared.pythonURL
        else { throw ImportError.runtimeNotReady }
        guard FileManager.default.fileExists(atPath: helperURL.path) else { throw ImportError.helperMissing }
        phase = .prechecking
        let lines = LineCollector()
        do {
            _ = try await ProcessRunner.runCapturing(
                executable: python,
                arguments: [helperURL.path, "precheck", path],
                environment: ["HF_HOME": PathResolver.hfHome.path, "PYTHONUNBUFFERED": "1"],
                onStdout: { line in lines.add(line) },
                onStderr: { _ in }
            )
        } catch {
            phase = .idle
            let e = lines.all.compactMap(Self.parseError).first
            throw ImportError.failed(e ?? error.localizedDescription)
        }
        phase = .idle
        if let r = lines.all.compactMap(Self.parsePrecheck).first { return r }
        let e = lines.all.compactMap(Self.parseError).first
        throw ImportError.failed(e ?? "Couldn't read the GGUF file.")
    }

    /// Convert the GGUF to an MLX model under `models/<outputName>/`. Re-runs the
    /// precheck first and refuses an unsupported file with its reason.
    ///
    /// `optimize`: when true AND the GGUF was full-precision (F16/F32), the new
    /// model is quantized to `optimizeBits`-bit MLX — a real size/speed win
    /// (e.g. fp16 1.2 GB → 4-bit ~350 MB). If the GGUF was ALREADY quantized
    /// (Q4_0/Q8_0), optimization is SKIPPED: re-quantizing an already-quantized
    /// model only adds overhead (measured ~9 bpw from an 8-bit source) and loses
    /// quality, so the imported MLX model is left as-is — it's already optimal.
    @discardableResult
    func convert(path: String, outputName: String,
                 optimize: Bool = true, optimizeBits: Int = 4) async throws -> URL {
        guard PythonRuntime.shared.isReady, let python = PythonRuntime.shared.pythonURL
        else { throw ImportError.runtimeNotReady }
        guard FileManager.default.fileExists(atPath: helperURL.path) else { throw ImportError.helperMissing }

        // Gate on the precheck so we never start a long convert on a K-quant.
        let pre = try await precheck(path: path)
        guard pre.convertible else { throw ImportError.notConvertible(pre.reason) }

        let fm = FileManager.default
        var name = outputName.isEmpty ? sanitized(pre.name) : sanitized(outputName)
        if name.isEmpty { name = "gguf-model" }
        var dest = PathResolver.modelsCustomDir.appendingPathComponent(name, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = PathResolver.modelsCustomDir.appendingPathComponent("\(name)-\(n)", isDirectory: true)
            n += 1
        }

        phase = .converting(stage: "starting", message: "Preparing…")
        let lines = LineCollector()
        do {
            _ = try await ProcessRunner.runCapturing(
                executable: python,
                arguments: [helperURL.path, "convert", path, dest.path, dest.lastPathComponent],
                environment: ["HF_HOME": PathResolver.hfHome.path, "PYTHONUNBUFFERED": "1"],
                onStdout: { [weak self] line in
                    lines.add(line)
                    // Live progress only — parse + publish on the main actor.
                    if let p = Self.parseProgress(line) {
                        Task { @MainActor in self?.phase = .converting(stage: p.0, message: p.1) }
                    }
                },
                onStderr: { _ in }
            )
        } catch {
            try? fm.removeItem(at: dest)
            let msg = lines.all.compactMap(Self.parseError).first ?? error.localizedDescription
            phase = .failed(reason: msg)
            throw ImportError.failed(msg)
        }

        if let convErr = lines.all.compactMap(Self.parseError).first {
            try? fm.removeItem(at: dest)
            phase = .failed(reason: convErr)
            throw ImportError.failed(convErr)
        }
        guard fm.fileExists(atPath: dest.appendingPathComponent("config.json").path) else {
            try? fm.removeItem(at: dest)
            let msg = "Conversion produced no model."
            phase = .failed(reason: msg)
            throw ImportError.failed(msg)
        }

        // Optimize for MLX: quantize, but ONLY if the GGUF was full-precision.
        // The helper's `done` event reports whether the output is already
        // quantized (an already-quantized GGUF → quantization in config). We
        // detect it from config.json to decide.
        if optimize, !modelIsQuantized(dest) {
            do {
                try await quantizeInPlace(dir: dest, bits: optimizeBits, python: python)
            } catch {
                // Quantization is a bonus — the unquantized model is still valid.
                // Keep it and tell the user the optimize step didn't run.
                Log.error("GGUF import: optimize step failed: \(error.localizedDescription)", .model)
            }
        }

        await ModelRegistry.shared.scan()
        phase = .done(modelName: dest.lastPathComponent, modelPath: dest.path)
        return dest
    }

    /// True if the MLX model at `dir` already carries a `quantization` block.
    private func modelIsQuantized(_ dir: URL) -> Bool {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("config.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return json["quantization"] != nil
    }

    /// Quantize an MLX model dir to `bits`-bit, in place: `mlx_lm convert -q`
    /// writes to a temp dir (it refuses to overwrite), then we swap it in.
    private func quantizeInPlace(dir: URL, bits: Int, python: URL) async throws {
        phase = .converting(stage: "optimize", message: "Optimizing for MLX (\(bits)-bit quantize)…")
        let fm = FileManager.default
        let tmp = dir.appendingPathExtension("opt-\(UUID().uuidString)")
        try? fm.removeItem(at: tmp)
        let lines = LineCollector()
        do {
            _ = try await ProcessRunner.runCapturing(
                executable: python,
                arguments: ["-m", "mlx_lm", "convert", "--hf-path", dir.path,
                            "--mlx-path", tmp.path, "-q", "--q-bits", "\(bits)"],
                environment: ["HF_HOME": PathResolver.hfHome.path, "PYTHONUNBUFFERED": "1"],
                onStdout: { line in lines.add(line) },
                onStderr: { line in lines.add(line) })
        } catch {
            try? fm.removeItem(at: tmp)
            throw ImportError.failed("quantize: " + (Self.lastError(lines.all) ?? error.localizedDescription))
        }
        guard fm.fileExists(atPath: tmp.appendingPathComponent("config.json").path) else {
            try? fm.removeItem(at: tmp)
            throw ImportError.failed("Optimization produced no model.")
        }
        // Swap: replace the unquantized dir with the quantized one.
        try? fm.removeItem(at: dir)
        try fm.moveItem(at: tmp, to: dir)
    }

    // MARK: line parsing (nonisolated — safe to call from @Sendable callbacks)

    nonisolated private static func parseProgress(_ line: String) -> (String, String)? {
        guard let data = line.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              j["event"] as? String == "progress"
        else { return nil }
        return ((j["stage"] as? String) ?? "", (j["message"] as? String) ?? "")
    }

    nonisolated private static func parsePrecheck(_ line: String) -> PrecheckResult? {
        guard let data = line.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              j["event"] as? String == "precheck"
        else { return nil }
        return PrecheckResult(
            convertible: (j["convertible"] as? Bool) ?? false,
            arch: (j["arch"] as? String) ?? "unknown",
            name: (j["name"] as? String) ?? "",
            quant: (j["quant"] as? [String]) ?? [],
            nTensors: (j["n_tensors"] as? Int) ?? 0,
            reason: (j["reason"] as? String) ?? "")
    }

    nonisolated private static func parseError(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              j["event"] as? String == "error"
        else { return nil }
        return j["message"] as? String
    }

    /// Folder-safe model name from a GGUF's `general.name` (often has spaces/dots).
    private func sanitized(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.")
        let cleaned = String(s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
    }
}

/// Thread-safe collector for subprocess output lines. The `onStdout`/`onStderr`
/// callbacks are `@Sendable` and fire off the main actor, so we can't mutate
/// captured vars from them under Swift 6 strict concurrency — collect here and
/// read `.all` after the process exits.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}
