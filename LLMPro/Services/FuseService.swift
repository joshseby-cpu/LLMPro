import Foundation

actor FuseService {
    static let shared = FuseService()

    enum FuseError: LocalizedError {
        case runtimeNotReady
        case ollamaNotFound
        case llamaCppMissing
        var errorDescription: String? {
            switch self {
            case .runtimeNotReady: "Python runtime not ready."
            case .ollamaNotFound:  "Ollama CLI not found. Install Ollama from https://ollama.com."
            case .llamaCppMissing:
                "The llama.cpp GGUF converter isn't installed — install it from the Export screen (or Settings) to export this architecture to GGUF."
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

    /// Fuse a LoRA adapter back into the base model, producing safetensors.
    func fuse(
        baseModel: String,
        adapterPath: String,
        savePath: String,
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
            ],
            environment: ["HF_HOME": PathResolver.hfHome.path, "PYTHONUNBUFFERED": "1"],
            onStdout: { line in onProgress?(line) },
            onStderr: { line in onProgress?(line) }
        )
    }

    /// Fuse and emit GGUF in one shot. Only valid for Llama/Mistral/Mixtral architectures.
    func fuseToGGUF(
        baseModel: String,
        adapterPath: String,
        savePath: String,
        ggufPath: String,
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
                "--save-path", savePath,
                "--export-gguf",
                "--gguf-path", ggufPath
            ],
            environment: ["HF_HOME": PathResolver.hfHome.path, "PYTHONUNBUFFERED": "1"],
            onStdout: { line in onProgress?(line) },
            onStderr: { line in onProgress?(line) }
        )
    }

    /// Fall-back: fuse to fp16 safetensors then run llama.cpp's convert_hf_to_gguf.py.
    func fuseAndConvertExternalGGUF(
        baseModel: String,
        adapterPath: String,
        fp16Path: String,
        ggufPath: String,
        llamaCppDir: URL,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws {
        // Fail fast BEFORE the (expensive) fuse if the converter isn't installed —
        // never spawn a non-existent script (that produced a confusing raw spawn
        // failure). The user installs it from the Export screen / Settings.
        let converter = llamaCppDir.appendingPathComponent("convert_hf_to_gguf.py")
        guard FileManager.default.fileExists(atPath: converter.path) else {
            Log.error("GGUF export blocked: \(converter.path) not found — llama.cpp converter not installed", .model)
            throw FuseError.llamaCppMissing
        }
        try await fuse(baseModel: baseModel, adapterPath: adapterPath, savePath: fp16Path, onProgress: onProgress)
        guard await PythonRuntime.shared.isReady, let python = await PythonRuntime.shared.pythonURL
        else { throw FuseError.runtimeNotReady }
        try await ProcessRunner.runCapturing(
            executable: python,
            arguments: [converter.path, fp16Path, "--outfile", ggufPath, "--outtype", "f16"],
            environment: ["PYTHONUNBUFFERED": "1"],
            onStdout: { line in onProgress?(line) },
            onStderr: { line in onProgress?(line) }
        )
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
