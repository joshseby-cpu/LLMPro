import Foundation
import SwiftUI

@MainActor
@Observable
final class PythonRuntime {
    static let shared = PythonRuntime()

    enum Phase: Equatable {
        case uninitialized
        case checkingUV
        case creatingVenv
        case installingMLXLM(String)
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .uninitialized {
        didSet {
            if case .failed(let msg) = phase { Log.error("Python runtime failed: \(msg)", .python) }
        }
    }
    private(set) var logTail: [String] = []

    var pythonURL: URL? { phase == .ready ? PathResolver.venvPython : nil }
    var isReady: Bool { phase == .ready }

    var statusLine: String {
        switch phase {
        case .uninitialized:           "Runtime: not started"
        case .checkingUV:              "Runtime: preparing uv"
        case .creatingVenv:            "Runtime: creating venv"
        case .installingMLXLM(let s):  "Runtime: \(s)"
        case .ready:                   "Runtime: ready"
        case .failed(let s):           "Runtime error: \(s)"
        }
    }

    var statusColor: Color {
        switch phase {
        case .ready:           .green
        case .failed:          .red
        case .uninitialized:   .gray
        default:               .orange
        }
    }

    private init() {}

    func bootstrapIfNeeded() async {
        if isReady { return }
        if FileManager.default.fileExists(atPath: PathResolver.venvPython.path) {
            if await verifyMLXLM() {
                // Always refresh helper scripts — edits in the app bundle should propagate
                // without forcing a fresh venv reinstall.
                try? installHelpers()
                phase = .ready
                return
            }
        }
        await bootstrap()
    }

    func bootstrap() async {
        do {
            phase = .checkingUV
            let uv = try await resolveUV()

            phase = .creatingVenv
            // `--clear` makes this idempotent: if a venv dir already exists but we
            // reached bootstrap anyway (verifyMLXLM was slow/transient on a cold
            // first launch, or a previous install was interrupted), recreate over
            // it instead of hard-failing with "a virtual environment already
            // exists". Without it, a transient verify failure wedges the runtime
            // until the user manually wipes the venv.
            try await runUV(uv, ["venv", PathResolver.venvDir.path, "--python", "3.11", "--clear"])

            phase = .installingMLXLM("Installing mlx-lm + datasets (this can take a few minutes)")
            try await runUV(uv, [
                "pip", "install",
                "--python", PathResolver.venvPython.path,
                "mlx-lm", "huggingface_hub", "datasets", "safetensors", "sentencepiece", "protobuf",
                // `gguf` is the tiny pure-python reader used by gguf_to_mlx.py to
                // read GGUF metadata/vocab for the GGUF→MLX importer (no PyTorch).
                "gguf",
                // `pillow` (PIL) is pulled in by the vendored DiffusionGemma
                // image-processing import path (optiq.vlm.gemma4.image_processing)
                // that diffusion_generate.py loads. No torch — PIL + numpy only.
                "pillow",
                // `mlx-lm-lora` is the separate preference-tuning trainer (DPO etc.)
                // launched as `python -m mlx_lm_lora.train -c config.yaml`. It's a
                // small add-on on top of mlx-lm, so it ships in the base install for
                // fresh venvs; an older venv installs it on-demand via
                // installDPOTrainer() (it's NOT part of the Ready gate).
                "mlx-lm-lora"
            ])

            // mergekit powers the Fusion tab. It pulls in torch + transformers
            // + accelerate, so the install is large (~3 GB) — but only on first
            // bootstrap. Subsequent launches skip pip entirely if `import
            // mlx_lm` works (see bootstrapIfNeeded). Failure here is non-fatal
            // for the rest of the app — mlx-lm is what actually unblocks Ready;
            // fusion will surface "mergekit not installed" if someone tries it
            // before this finishes.
            phase = .installingMLXLM("Installing mergekit (powers Fusion — ~3 GB, one-time)")
            do {
                try await runUV(uv, [
                    "pip", "install",
                    "--python", PathResolver.venvPython.path,
                    "mergekit"
                ])
            } catch {
                appendLog("mergekit install failed: \(error.localizedDescription) — Fusion tab will be disabled until next launch.")
            }

            // Install hf_download helper script.
            try installHelpers()

            if await verifyMLXLM() {
                phase = .ready
            } else {
                phase = .failed("mlx-lm installed but `import mlx_lm` failed.")
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Find a usable `uv` binary: prefer the bundled one, fall back to `$PATH`, fall back to `~/.local/bin/uv`.
    private func resolveUV() async throws -> URL {
        if let bundled = Bundle.main.url(forResource: "uv-aarch64-apple-darwin", withExtension: nil) {
            let dest = PathResolver.uvBinary
            if !FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: bundled, to: dest)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            }
            return dest
        }
        if FileManager.default.fileExists(atPath: PathResolver.uvBinary.path) {
            return PathResolver.uvBinary
        }
        for candidate in ["/opt/homebrew/bin/uv", "/usr/local/bin/uv", "\(NSHomeDirectory())/.local/bin/uv"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        throw RuntimeError.uvNotFound
    }

    /// Find a usable `git` binary: the macOS system one (`/usr/bin/git`, the
    /// developer-tools shim) first, then common Homebrew locations. Used to clone
    /// llama.cpp for the GGUF converter.
    private func resolveGit() throws -> URL {
        for candidate in ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        throw RuntimeError.gitNotFound
    }

    private func runGit(_ args: [String]) async throws {
        let git = try resolveGit()
        appendLog("$ git \(args.joined(separator: " "))")
        try await ProcessRunner.runCapturing(
            executable: git,
            arguments: args,
            environment: ["GIT_TERMINAL_PROMPT": "0"],
            onStdout: { [weak self] line in Task { @MainActor in self?.appendLog(line) } },
            onStderr: { [weak self] line in Task { @MainActor in self?.appendLog(line) } }
        )
    }

    private func runUV(_ uv: URL, _ args: [String]) async throws {
        appendLog("$ \(uv.lastPathComponent) \(args.joined(separator: " "))")
        try await ProcessRunner.runCapturing(
            executable: uv,
            arguments: args,
            environment: ["VIRTUAL_ENV": PathResolver.venvDir.path],
            onStdout: { [weak self] line in Task { @MainActor in self?.appendLog(line) } },
            onStderr: { [weak self] line in Task { @MainActor in self?.appendLog(line) } }
        )
    }

    private func verifyMLXLM() async -> Bool {
        guard FileManager.default.isExecutableFile(atPath: PathResolver.venvPython.path) else { return false }
        do {
            try await ProcessRunner.runCapturing(
                executable: PathResolver.venvPython,
                arguments: ["-c", "import mlx_lm; print(mlx_lm.__version__)"]
            )
            return true
        } catch {
            return false
        }
    }

    /// Returns true if `mergekit` is importable in the venv. Cheap (~50 ms).
    func mergekitInstalled() async -> Bool {
        guard let python = pythonURL else { return false }
        do {
            try await ProcessRunner.runCapturing(
                executable: python,
                arguments: ["-c", "import mergekit"]
            )
            return true
        } catch {
            return false
        }
    }

    /// Install mergekit on-demand. The first-launch bootstrap already does
    /// this, but users whose venv was created before the fusion feature
    /// shipped need a way to install it without nuking the whole runtime.
    /// Called by FusionService before the first merge attempt.
    func installMergekit(progress: @escaping @MainActor (String) -> Void) async -> Bool {
        do {
            let uv = try await resolveUV()
            await MainActor.run { progress("Installing mergekit (~3 GB, one-time)…") }
            try await runUV(uv, [
                "pip", "install",
                "--python", PathResolver.venvPython.path,
                "mergekit"
            ])
            return true
        } catch {
            await MainActor.run { progress("Install failed: \(error.localizedDescription)") }
            return false
        }
    }

    /// True when llama.cpp's `convert_hf_to_gguf.py` is checked out under
    /// `PathResolver.llamaCppDir`. The GGUF export fall-back for
    /// non-natively-exportable architectures (Qwen/Gemma/Phi) needs it. Cheap
    /// (a file-existence check). Mirrors `mergekitInstalled()` semantically.
    func llamaCppInstalled() -> Bool {
        let converter = PathResolver.llamaCppDir.appendingPathComponent("convert_hf_to_gguf.py")
        return FileManager.default.fileExists(atPath: converter.path)
    }

    /// Install llama.cpp's GGUF converter on demand: shallow-clone the repo into
    /// `PathResolver.llamaCppDir` (skipped if already present) and `uv pip install`
    /// its runtime deps — `gguf` (the writer lib) AND `torch`, which
    /// `convert_hf_to_gguf.py` imports at module load (without it the convert step
    /// fails with "No module named 'torch'"). The project's base venv is
    /// deliberately torch-free (it uses MLX), so torch is added here, on demand,
    /// only for users who actually export non-natively-exportable architectures
    /// (Qwen / Gemma / Phi) to GGUF. Mirrors `installMergekit` — same
    /// `resolveUV`/`runUV` plumbing and progress streaming. Called from the Export
    /// screen / Settings before a two-step fuse → GGUF export. Returns true on
    /// success.
    func installLlamaCpp(progress: @escaping @MainActor (String) -> Void) async -> Bool {
        do {
            let dir = PathResolver.llamaCppDir
            if llamaCppInstalled() {
                await MainActor.run { progress("llama.cpp converter already installed.") }
            } else {
                // A stale partial checkout (clone interrupted) would make `git
                // clone` fail with "destination path already exists"; clear it so
                // the retry is clean.
                if FileManager.default.fileExists(atPath: dir.path) {
                    try? FileManager.default.removeItem(at: dir)
                }
                await MainActor.run { progress("Cloning llama.cpp (the GGUF converter)…") }
                try await runGit([
                    "clone", "--depth", "1",
                    "https://github.com/ggerganov/llama.cpp", dir.path
                ])
            }
            // convert_hf_to_gguf.py needs `gguf` (its writer lib) AND `torch`
            // (imported at module load). torch is a large download (~hundreds of
            // MB) — flag it in the progress so the wait isn't a surprise.
            await MainActor.run { progress("Installing converter deps (gguf + torch — torch is a large download)…") }
            let uv = try await resolveUV()
            try await runUV(uv, [
                "pip", "install",
                "--python", PathResolver.venvPython.path,
                "gguf", "torch"
            ])
            Log.notice("llama.cpp GGUF converter installed at \(dir.path)", .model)
            await MainActor.run { progress("llama.cpp converter ready.") }
            return true
        } catch {
            Log.error("llama.cpp converter install failed", .model, error: error)
            await MainActor.run { progress("Install failed: \(error.localizedDescription)") }
            return false
        }
    }

    /// True once the compiled llama.cpp binaries exist (built by
    /// `buildLlamaCppTools`). `llama-quantize` makes real k-quants (Q4_K_M etc.)
    /// the Python converter can't, and `llama-cli` runs the post-export coherence
    /// self-test. Cheap file-existence check.
    func llamaToolsBuilt() -> Bool {
        let bin = PathResolver.llamaCppDir.appendingPathComponent("build/bin")
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: bin.appendingPathComponent("llama-quantize").path)
            && fm.isExecutableFile(atPath: bin.appendingPathComponent("llama-completion").path)
    }

    /// Find a usable `cmake` (Homebrew first, then a couple of fallbacks).
    private func resolveCMake() throws -> URL {
        for candidate in ["/opt/homebrew/bin/cmake", "/usr/local/bin/cmake", "/opt/local/bin/cmake"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        throw RuntimeError.cmakeNotFound
    }

    /// Build llama.cpp's `llama-quantize` + `llama-completion` from the cloned
    /// source (cmake, Metal on, libcurl off). This is the heavy step that unlocks
    /// real k-quants (Q4_K_M/Q5_K_M/Q6_K) and the in-app GGUF coherence self-test —
    /// the Python `convert_hf_to_gguf.py` can only emit f16/bf16/q8_0 and can't run
    /// a model. Clones the converter first if needed. ~a few minutes on first build;
    /// subsequent calls are no-ops once the binaries exist. Returns true on success.
    func buildLlamaCppTools(progress: @escaping @MainActor (String) -> Void) async -> Bool {
        do {
            if llamaToolsBuilt() {
                await MainActor.run { progress("llama.cpp tools already built.") }
                return true
            }
            // Need the source clone present (installLlamaCpp does the clone + deps).
            if !llamaCppInstalled() {
                await MainActor.run { progress("Cloning llama.cpp source first…") }
                guard await installLlamaCpp(progress: progress) else { return false }
            }
            let cmake = try resolveCMake()
            let dir = PathResolver.llamaCppDir
            let buildDir = dir.appendingPathComponent("build")
            let cores = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)

            await MainActor.run { progress("Configuring llama.cpp build (cmake)…") }
            try await runCMake(cmake, [
                "-S", dir.path, "-B", buildDir.path,
                "-DCMAKE_BUILD_TYPE=Release", "-DLLAMA_CURL=OFF", "-DGGML_METAL=ON"
            ])
            await MainActor.run { progress("Building llama-quantize + llama-completion (this takes a few minutes)…") }
            try await runCMake(cmake, [
                "--build", buildDir.path, "--config", "Release",
                "-j", "\(cores)", "--target", "llama-quantize", "llama-completion"
            ])
            guard llamaToolsBuilt() else {
                await MainActor.run { progress("Build finished but binaries are missing — see the log.") }
                return false
            }
            Log.notice("llama.cpp tools built at \(buildDir.path)/bin", .model)
            await MainActor.run { progress("llama.cpp tools ready (k-quants + self-test enabled).") }
            return true
        } catch {
            Log.error("llama.cpp tools build failed", .model, error: error)
            await MainActor.run { progress("Build failed: \(error.localizedDescription)") }
            return false
        }
    }

    private func runCMake(_ cmake: URL, _ args: [String]) async throws {
        appendLog("$ cmake \(args.joined(separator: " "))")
        try await ProcessRunner.runCapturing(
            executable: cmake,
            arguments: args,
            onStdout: { [weak self] line in Task { @MainActor in self?.appendLog(line) } },
            onStderr: { [weak self] line in Task { @MainActor in self?.appendLog(line) } }
        )
    }

    /// Returns true if `mlx_lm_lora` (the DPO / preference-tuning trainer) is
    /// importable in the venv. Cheap (~50 ms). It's an optional add-on (like
    /// mergekit), so it's intentionally NOT part of verifyMLXLM / the Ready gate.
    func dpoTrainerInstalled() async -> Bool {
        guard let python = pythonURL else { return false }
        do {
            try await ProcessRunner.runCapturing(
                executable: python,
                arguments: ["-c", "import mlx_lm_lora"]
            )
            return true
        } catch {
            return false
        }
    }

    /// Install the DPO trainer on-demand. Fresh first-launch bootstraps already
    /// include `mlx-lm-lora`, but a venv created before the preference-loop
    /// feature shipped needs a way to add it without recreating the whole
    /// runtime. Called by TrainingService before launching a DPO job.
    func installDPOTrainer(progress: @escaping @MainActor (String) -> Void) async -> Bool {
        do {
            let uv = try await resolveUV()
            await MainActor.run { progress("Installing the DPO trainer (mlx-lm-lora)…") }
            try await runUV(uv, [
                "pip", "install",
                "--python", PathResolver.venvPython.path,
                "mlx-lm-lora"
            ])
            return true
        } catch {
            await MainActor.run { progress("Install failed: \(error.localizedDescription)") }
            return false
        }
    }

    /// Returns true if `mflux` (the MLX FLUX text-to-image backend for Story
    /// illustrations) is importable in the venv. Cheap (~50 ms). Optional add-on,
    /// so it's intentionally NOT part of verifyMLXLM / the Ready gate — Story only
    /// needs it when the user turns illustrations on.
    func imageGenInstalled() async -> Bool {
        guard let python = pythonURL else { return false }
        do {
            try await ProcessRunner.runCapturing(
                executable: python,
                arguments: ["-c", "import mflux"]
            )
            return true
        } catch {
            return false
        }
    }

    /// Install the image generator on-demand. `mflux==0.18.0` caps `mlx<0.32`, which
    /// the current venv (mlx 0.31.x) already satisfies, and its other deps (torch,
    /// transformers, safetensors, sentencepiece) are already present from mlx-lm —
    /// so this is a small metadata-only install, NOT a multi-GB torch pull. The
    /// FLUX weights themselves download lazily on first image generation. Pinned so
    /// a future mflux that bumps its mlx floor can't silently break the venv.
    func installImageGen(progress: @escaping @MainActor (String) -> Void) async -> Bool {
        do {
            let uv = try await resolveUV()
            await MainActor.run { progress("Installing the image generator (mflux)…") }
            try await runUV(uv, [
                "pip", "install",
                "--python", PathResolver.venvPython.path,
                "mflux==0.18.0"
            ])
            return true
        } catch {
            await MainActor.run { progress("Install failed: \(error.localizedDescription)") }
            return false
        }
    }

    private func installHelpers() throws {
        let destDir = PathResolver.helpersDir
        for name in ["hf_download", "prepare_coding_dataset", "download_hf_dataset", "strip_vision", "abliterate",
                     "humaneval_pull", "self_improve_round", "eval_pass_rate",
                     "merge_models", "add_expert", "manage_experts",
                     "mem_probe", "model_memory", "profile_experts", "mlx_run",
                     "inspect_attention", "gguf_to_mlx", "diffusion_generate", "diffusion_server",
                     "generate_image"] {
            guard let resourceURL = Bundle.main.url(forResource: name, withExtension: "py", subdirectory: "helpers")
                                  ?? Bundle.main.url(forResource: name, withExtension: "py")
            else { continue }
            let dest = destDir.appendingPathComponent("\(name).py")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: resourceURL, to: dest)
        }
        try installDiffusionVendor(into: destDir)
    }

    /// Copy the vendored DiffusionGemma inference subtree out of the app bundle
    /// into `runtime/helpers/diffusion_vendor/`, preserving its directory
    /// structure. `diffusion_generate.py` computes the vendor path relative to
    /// its own `__file__`, so the subtree must sit next to it as a sibling
    /// `diffusion_vendor/` with `optiq/vlm/...` intact (a flattened group would
    /// break `import optiq.vlm.diffusion_gemma`). The folder reference in
    /// project.yml ships it under `LLMPro.app/Contents/Resources/diffusion_vendor/`.
    /// We blow away any stale copy first so bundle edits propagate on relaunch,
    /// matching how the flat `.py` helpers above are refreshed.
    private func installDiffusionVendor(into destDir: URL) throws {
        guard let src = Bundle.main.url(forResource: "diffusion_vendor", withExtension: nil) else { return }
        let dest = destDir.appendingPathComponent("diffusion_vendor", isDirectory: true)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: src, to: dest)
    }

    private func appendLog(_ line: String) {
        logTail.append(line)
        if logTail.count > 500 { logTail.removeFirst(logTail.count - 500) }
    }

    enum RuntimeError: LocalizedError {
        case uvNotFound
        case gitNotFound
        case cmakeNotFound
        var errorDescription: String? {
            switch self {
            case .uvNotFound:
                return "Could not find `uv`. Install it from https://docs.astral.sh/uv/ or bundle a uv binary in Resources."
            case .gitNotFound:
                return "Could not find `git`. Install Xcode Command Line Tools (`xcode-select --install`) and try again."
            case .cmakeNotFound:
                return "Could not find `cmake`, needed to build the llama.cpp tools. Install it with `brew install cmake` and try again."
            }
        }
    }
}
