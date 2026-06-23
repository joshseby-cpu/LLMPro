import Foundation

actor FuseService {
    static let shared = FuseService()

    enum FuseError: LocalizedError {
        case runtimeNotReady
        case ollamaNotFound
        case llamaCppMissing
        case llamaToolsMissing
        var errorDescription: String? {
            switch self {
            case .runtimeNotReady: "Python runtime not ready."
            case .ollamaNotFound:  "Ollama CLI not found. Install Ollama from https://ollama.com."
            case .llamaCppMissing:
                "The llama.cpp GGUF converter isn't installed — install it from the Export screen (or Settings) to export this architecture to GGUF."
            case .llamaToolsMissing:
                "The llama.cpp tools (llama-quantize / llama-cli) aren't built yet — build them from the Export screen to make k-quants (Q4_K_M etc.) and run the coherence self-test."
            }
        }
    }

    /// True when llama.cpp's `convert_hf_to_gguf.py` is present on disk (under
    /// `PathResolver.llamaCppDir`). The two-step fuse → GGUF fall-back for
    /// non-natively-exportable architectures (Qwen/Gemma/Phi) needs it; install
    /// it on demand via `PythonRuntime.installLlamaCpp`.
    func llamaCppInstalled() -> Bool {
        let converter = PathResolver.llamaCppDir.appendingPathComponent("convert_hf_to_gguf.py")
        return FileManager.default.fileExists(atPath: converter.path)
    }

    /// The compiled llama.cpp binaries (built from source via
    /// `PythonRuntime.buildLlamaCppTools`). `llama-quantize` produces real k-quants
    /// (Q4_K_M/Q5_K_M/Q6_K) the converter can't; `llama-completion` runs the
    /// post-export coherence self-test (raw completion — this llama.cpp split it out
    /// of `llama-cli`, which now rejects `-no-cnv`). They live under `build/bin/`.
    static var llamaQuantizeBin: URL { PathResolver.llamaCppDir.appendingPathComponent("build/bin/llama-quantize") }
    static var llamaCompletionBin: URL { PathResolver.llamaCppDir.appendingPathComponent("build/bin/llama-completion") }

    /// True once both compiled binaries exist — k-quant output and the self-test
    /// require them. The plain converter (`llamaCppInstalled`) only does f16/bf16/q8_0.
    func llamaToolsInstalled() -> Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: Self.llamaQuantizeBin.path)
            && fm.isExecutableFile(atPath: Self.llamaCompletionBin.path)
    }

    /// Resolve a bare local-model name to its absolute directory before handing it
    /// to mlx-lm. mlx-lm reads a slash-free string as an HF repo id and tries to
    /// download it (load-bearing rule #4) — so a fine-tune whose base is a custom
    /// local model (GGUF import, strip-vision/abliterate output, etc.) would fail
    /// the fuse with a 401 from HuggingFace. Mirrors `InferenceService` /
    /// `MLXServerService` / `EvalService`. HF repo ids (with a slash) pass through.
    private static func resolveModelArg(_ repoOrName: String) async -> String {
        if let dir = await MainActor.run(body: {
            ModelRegistry.shared.localModels.first(where: { $0.repoID == repoOrName })?.directory.path
        }) {
            return dir
        }
        return repoOrName
    }

    /// llama.cpp's `qwen35` / Step3.5 loader expects a multi-token-prediction
    /// (MTP / "NextN") block when the model's config declares MTP layers — it shows
    /// up as an extra block N (e.g. `blk.64.*` on a 64-layer model). But the **MLX**
    /// builds of these models drop the MTP weights while the config still advertises
    /// them, so a straight conversion writes the MTP metadata without the tensors →
    /// the GGUF fails to load with `missing tensor 'blk.N.attn_norm.weight'`.
    /// `convert_hf_to_gguf.py --no-mtp` excludes the MTP head, producing a clean
    /// trunk-only GGUF that loads (MTP is only a speculative-decoding speedup). The
    /// flag is valid only for Qwen3.5/3.6/Step3.5, so gate on the config actually
    /// declaring MTP layers (the key only exists on those archs → self-gating).
    private static func mtpExclusionArgs(forModelDir dir: String) -> [String] {
        let cfg = URL(fileURLWithPath: dir).appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: cfg),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        func mtpLayers(_ d: [String: Any]) -> Int {
            (d["mtp_num_hidden_layers"] as? Int) ?? (d["num_nextn_predict_layers"] as? Int) ?? 0
        }
        var n = mtpLayers(json)
        if n == 0, let tc = json["text_config"] as? [String: Any] { n = mtpLayers(tc) }
        if n > 0 { Log.notice("GGUF export: model declares \(n) MTP layer(s) but MLX builds drop them — adding --no-mtp", .model) }
        return n > 0 ? ["--no-mtp"] : []
    }

    /// Whether converting *this MLX model* to GGUF would silently corrupt it.
    /// Hybrid Qwen3.5/3.6 ("qwen3_5", Gated-DeltaNet linear-attention + an MTP head)
    /// CAN run as a GGUF in current llama.cpp — but converting the **MLX build**
    /// specifically is broken: MLX bakes Qwen3-Next's zero-centered RMSNorm `+1`
    /// shift (and a conv1d axis move) into the saved weights, and llama.cpp's
    /// `convert_hf_to_gguf.py` (conversion/qwen.py) applies `+1` *again* → ~2×-wrong
    /// norm scale → token-soup / invalid-UTF-8 output. (Confirmed on a Qwen3.6-27B
    /// fine-tune in LM Studio.) This is a conversion-INPUT mismatch intrinsic to the
    /// MLX format for hybrid archs — not a runtime limit and not fixable by us short
    /// of converting from the original HF checkpoint (which loses the fine-tune).
    /// Returns a user-facing reason string when the dir is an affected arch, else
    /// nil. Callers (`GGUFExportSheet`, `ExportWizardView`) treat non-nil as a hard
    /// **block** so the user never burns a multi-GB export that can't run.
    ///
    /// `nonisolated`/`static` so the SwiftUI export sheet can call it synchronously
    /// (a one-shot config.json read; no actor hop).
    nonisolated static func ggufRoundTripWarning(forModelDir dir: String) -> String? {
        let cfg = URL(fileURLWithPath: dir).appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: cfg),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        // Merge nested text_config (VLMs nest the LM config there).
        var j = json
        if let tc = json["text_config"] as? [String: Any] { j.merge(tc) { _, new in new } }

        let mtp = (j["mtp_num_hidden_layers"] as? Int) ?? (j["num_nextn_predict_layers"] as? Int) ?? 0
        let modelType = (j["model_type"] as? String ?? "").lowercased()
        let archNames = ((json["architectures"] as? [String]) ?? []).map { $0.lowercased() }
        // Hybrid linear-attention / SSM markers: the qwen3_5 family, anything that
        // advertises mamba/ssm/linear-attention in its type, arch name, or a
        // per-layer layer_types list.
        let hybridMarkers = ["qwen3_5", "qwen35", "mamba", "hybrid", "ssm", "linear_attn"]
        let typeIsHybrid = hybridMarkers.contains { modelType.contains($0) }
        let archIsHybrid = archNames.contains { name in hybridMarkers.contains { name.contains($0) } }
        let layerTypesHybrid = (j["layer_types"] as? [String])?.contains {
            let t = $0.lowercased(); return t.contains("linear") || t.contains("mamba") || t.contains("ssm")
        } ?? false

        guard mtp > 0 || typeIsHybrid || archIsHybrid || layerTypesHybrid else { return nil }
        return "This is a hybrid architecture (Qwen3.5/3.6-style linear-attention/SSM, or a multi-token-prediction head). Converting the MLX build to GGUF corrupts it — MLX bakes in a norm shift that llama.cpp's converter re-applies, producing garbled output. GGUF export is disabled for these. The model runs correctly inside LLMPro (Try it out / Code); for Ollama / LM Studio, fine-tune a GGUF-friendly base instead (Qwen2.5, Llama 3.x, Gemma 2, Mistral)."
    }

    /// Fuse a LoRA adapter back into the base model, producing safetensors.
    /// `dequantize: true` emits a full-precision (bf16) HF-layout checkpoint — REQUIRED
    /// before GGUF conversion when the base is MLX-quantized: mlx-lm's affine
    /// group-quant (`.scales`/`.biases`) is not an HF/llama.cpp quant format, so
    /// `convert_hf_to_gguf.py` can't read a fused-but-still-quantized model. Plain
    /// "Fused safetensors" exports keep the default (preserve the base's precision).
    func fuse(
        baseModel: String,
        adapterPath: String,
        savePath: String,
        dequantize: Bool = false,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws {
        guard await PythonRuntime.shared.isReady, let python = await PythonRuntime.shared.pythonURL
        else { throw FuseError.runtimeNotReady }
        let model = await Self.resolveModelArg(baseModel)
        try await ProcessRunner.runCapturing(
            executable: python,
            arguments: [
                "-m", "mlx_lm", "fuse",
                "--model", model,
                "--adapter-path", adapterPath,
                "--save-path", savePath
            ] + (dequantize ? ["--dequantize"] : []),
            environment: ["HF_HOME": PathResolver.hfHome.path, "PYTHONUNBUFFERED": "1"],
            onStdout: { line in onProgress?(line) },
            onStderr: { line in onProgress?(line) }
        )
    }

    /// Convert an HF-format model directory to a GGUF at the requested quant. This
    /// is the single converter both export entry-points share. Base types
    /// (f16/bf16/q8_0) go straight through `convert_hf_to_gguf.py`; k-quants
    /// (Q4_K_M/Q5_K_M/Q6_K) are a two-step — convert to a temp f16 GGUF, then run
    /// `llama-quantize` (the converter can't emit k-quants) and delete the temp.
    /// Fails fast if the prerequisite tool is missing so we never spawn nothing.
    func convertDirToGGUF(
        modelDir: String,
        ggufPath: String,
        quant: GGUFQuant,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws {
        guard await PythonRuntime.shared.isReady, let python = await PythonRuntime.shared.pythonURL
        else { throw FuseError.runtimeNotReady }
        let converter = PathResolver.llamaCppDir.appendingPathComponent("convert_hf_to_gguf.py")
        guard FileManager.default.fileExists(atPath: converter.path) else {
            Log.error("GGUF export blocked: \(converter.path) not found — converter not installed", .model)
            throw FuseError.llamaCppMissing
        }

        func runConverter(outfile: String, outType: String) async throws {
            try await ProcessRunner.runCapturing(
                executable: python,
                arguments: [converter.path, modelDir, "--outfile", outfile, "--outtype", outType]
                    + Self.mtpExclusionArgs(forModelDir: modelDir),
                environment: ["PYTHONUNBUFFERED": "1"],
                onStdout: { line in onProgress?(line) },
                onStderr: { line in onProgress?(line) }
            )
        }

        if let kquant = quant.quantizeType {
            guard llamaToolsInstalled() else { throw FuseError.llamaToolsMissing }
            let tmpF16 = ggufPath + ".f16.tmp.gguf"
            onProgress?("Converting to f16 (step 1/2)…")
            try await runConverter(outfile: tmpF16, outType: "f16")
            onProgress?("Quantizing to \(kquant) (step 2/2)…")
            try await ProcessRunner.runCapturing(
                executable: Self.llamaQuantizeBin,
                arguments: [tmpF16, ggufPath, kquant],
                environment: ["PYTHONUNBUFFERED": "1"],
                onStdout: { line in onProgress?(line) },
                onStderr: { line in onProgress?(line) }
            )
            try? FileManager.default.removeItem(atPath: tmpF16)
        } else {
            try await runConverter(outfile: ggufPath, outType: quant.convertOutType)
        }
    }

    /// Post-export coherence self-test: load the freshly built GGUF with the
    /// compiled `llama-cli` and generate a few tokens. A "green UI is not a pass" —
    /// this catches the silent garbage / invalid-UTF-8 failures (e.g. the Qwen3.6
    /// double-norm-shift) that "convert succeeded" can't. Returns a skipped result
    /// (not a failure) when the binaries aren't built, so f16/q8 exports still work
    /// without the source build.
    func verifyGGUF(ggufPath: String, onProgress: (@Sendable (String) -> Void)? = nil) async -> GGUFSelfTest {
        guard llamaToolsInstalled() else {
            return GGUFSelfTest(outcome: .skipped, sample: "", detail: "self-test skipped (build the tools to enable it)")
        }
        onProgress?("Running self-test (loading the GGUF and generating)…")
        let collected = LineSink()
        do {
            try await ProcessRunner.runCapturing(
                executable: Self.llamaCompletionBin,
                arguments: ["-m", ggufPath, "-p", "The capital of France is",
                            "-n", "24", "-st", "-ngl", "999", "--no-warmup", "--temp", "0"],
                environment: ["PYTHONUNBUFFERED": "1"],
                onStdout: { line in collected.append(line); onProgress?(line) },
                onStderr: { line in onProgress?(line) }
            )
        } catch {
            return GGUFSelfTest(outcome: .failed, sample: "", detail: "couldn't run self-test: \(error.localizedDescription)")
        }
        let text = collected.joined()
        let hasReplacement = text.contains("\u{FFFD}")
        let letters = text.filter { $0.isLetter }.count
        let sample = String(text.prefix(300)).trimmingCharacters(in: .whitespacesAndNewlines)
        if hasReplacement {
            return GGUFSelfTest(outcome: .failed, sample: sample, detail: "garbled output (invalid UTF-8) — the GGUF does not run correctly")
        }
        if letters < 6 {
            return GGUFSelfTest(outcome: .failed, sample: sample, detail: "no usable output — the GGUF may not run correctly")
        }
        return GGUFSelfTest(outcome: .passed, sample: sample, detail: "coherent output")
    }

    /// Fuse a LoRA adapter to a dequantized HF checkpoint, convert to GGUF at the
    /// requested quant, then self-test. The Save & Use export path.
    @discardableResult
    func fuseAndConvertExternalGGUF(
        baseModel: String,
        adapterPath: String,
        fp16Path: String,
        ggufPath: String,
        quant: GGUFQuant = .q8_0,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> GGUFSelfTest {
        // Fail fast BEFORE the (expensive) fuse if the converter isn't installed.
        let converter = PathResolver.llamaCppDir.appendingPathComponent("convert_hf_to_gguf.py")
        guard FileManager.default.fileExists(atPath: converter.path) else {
            Log.error("GGUF export blocked: \(converter.path) not found — converter not installed", .model)
            throw FuseError.llamaCppMissing
        }
        if quant.quantizeType != nil, !llamaToolsInstalled() { throw FuseError.llamaToolsMissing }
        // --dequantize so a quantized MLX base becomes an HF checkpoint the converter can read.
        try await fuse(baseModel: baseModel, adapterPath: adapterPath, savePath: fp16Path, dequantize: true, onProgress: onProgress)
        try await convertDirToGGUF(modelDir: fp16Path, ggufPath: ggufPath, quant: quant, onProgress: onProgress)
        return await verifyGGUF(ggufPath: ggufPath, onProgress: onProgress)
    }

    /// Convert a plain HF-format model directory straight to GGUF — no adapter,
    /// no fuse step (the direct per-model export from the Models tab). The caller
    /// gates out MLX-quantized and diffusion checkpoints. Returns the self-test.
    @discardableResult
    func convertModelToGGUF(
        modelPath: String,
        ggufPath: String,
        quant: GGUFQuant = .q8_0,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> GGUFSelfTest {
        let model = await Self.resolveModelArg(modelPath)
        try await convertDirToGGUF(modelDir: model, ggufPath: ggufPath, quant: quant, onProgress: onProgress)
        return await verifyGGUF(ggufPath: ggufPath, onProgress: onProgress)
    }

    /// Install a fine-tuned GGUF into Ollama under the given model tag.
    func installInOllama(
        ggufPath: String,
        tag: String,
        chatTemplate: OllamaChatTemplate,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws {
        let ollama = locateOllama()
        guard let ollama else { throw FuseError.ollamaNotFound }
        let modelfile = """
        FROM \(ggufPath)
        \(chatTemplate.modelfileBody)
        """
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("Modelfile-\(UUID().uuidString)")
        try modelfile.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await ProcessRunner.runCapturing(
            executable: URL(fileURLWithPath: ollama),
            arguments: ["create", tag, "-f", tmp.path],
            onStdout: { line in onProgress?(line) },
            onStderr: { line in onProgress?(line) }
        )
    }

    func locateOllama() -> String? {
        for candidate in ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

/// A GGUF output precision the user can pick. Base types (f16/bf16/q8_0) are
/// produced directly by `convert_hf_to_gguf.py`; the k-quants (Q4_K_M/Q5_K_M/Q6_K)
/// — the small, fast formats Ollama / LM Studio users actually want — require the
/// compiled `llama-quantize` binary, so they're a two-step convert-then-quantize.
enum GGUFQuant: String, CaseIterable, Identifiable {
    case q4_k_m, q5_k_m, q6_k, q8_0, f16, bf16
    var id: String { rawValue }

    /// k-quants need the compiled `llama-quantize`; base types only need the converter.
    var isKQuant: Bool { self == .q4_k_m || self == .q5_k_m || self == .q6_k }

    /// `--outtype` passed to the converter. For a k-quant we convert at f16 first.
    var convertOutType: String { isKQuant ? "f16" : rawValue }

    /// The `llama-quantize` type argument (e.g. "Q4_K_M"), or nil for base types.
    var quantizeType: String? { isKQuant ? rawValue.uppercased() : nil }

    var displayName: String {
        switch self {
        case .q4_k_m: "Q4_K_M — 4-bit, smallest & fastest (recommended for Ollama / LM Studio)"
        case .q5_k_m: "Q5_K_M — 5-bit, a bit larger, higher quality"
        case .q6_k:   "Q6_K — 6-bit, near-lossless"
        case .q8_0:   "Q8_0 — 8-bit, very close to full quality"
        case .f16:    "F16 — full precision (largest)"
        case .bf16:   "BF16 — full precision (bfloat16)"
        }
    }
}

/// Outcome of the post-export GGUF coherence self-test (`verifyGGUF`).
struct GGUFSelfTest: Sendable {
    enum Outcome: Sendable { case passed, failed, skipped }
    let outcome: Outcome
    let sample: String
    let detail: String
}

/// Thread-safe line accumulator for capturing a subprocess's stdout from the
/// `@Sendable` stream closures (Swift 6 won't let those capture a mutable var).
final class LineSink: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
    func joined() -> String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
}

enum OllamaChatTemplate: String, CaseIterable, Identifiable {
    case qwen, deepseek, llama3, phi, mistral, raw
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .qwen:     "Qwen (ChatML)"
        case .deepseek: "DeepSeek Coder"
        case .llama3:   "Llama 3"
        case .phi:      "Phi"
        case .mistral:  "Mistral / Instruct"
        case .raw:      "Raw (no template)"
        }
    }

    var modelfileBody: String {
        switch self {
        case .qwen:
            return """
            TEMPLATE \"\"\"<|im_start|>system
            {{ .System }}<|im_end|>
            <|im_start|>user
            {{ .Prompt }}<|im_end|>
            <|im_start|>assistant
            \"\"\"
            PARAMETER stop "<|im_end|>"
            """
        case .deepseek:
            return """
            TEMPLATE \"\"\"### Instruction:
            {{ .Prompt }}
            ### Response:
            \"\"\"
            PARAMETER stop "### Instruction:"
            """
        case .llama3:
            return """
            TEMPLATE \"\"\"<|begin_of_text|><|start_header_id|>system<|end_header_id|>

            {{ .System }}<|eot_id|><|start_header_id|>user<|end_header_id|>

            {{ .Prompt }}<|eot_id|><|start_header_id|>assistant<|end_header_id|>

            \"\"\"
            PARAMETER stop "<|eot_id|>"
            """
        case .phi:
            return """
            TEMPLATE \"\"\"<|user|>
            {{ .Prompt }}<|end|>
            <|assistant|>
            \"\"\"
            PARAMETER stop "<|end|>"
            """
        case .mistral:
            return """
            TEMPLATE \"\"\"[INST] {{ .Prompt }} [/INST]\"\"\"
            """
        case .raw:
            return ""
        }
    }

    static func suggestion(forArchitecture arch: String) -> OllamaChatTemplate {
        switch arch.lowercased() {
        case "qwen2", "qwen":       return .qwen
        case "llama":               return .llama3
        case "mistral", "mixtral":  return .mistral
        case "phi", "phi3":         return .phi
        case "deepseek":            return .deepseek
        default:                    return .raw
        }
    }
}
