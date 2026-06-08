import Foundation

struct InferenceParams: Hashable, Sendable {
    var maxTokens: Int = 512
    var temperature: Double = 0.7
    var topP: Double = 0.95
    var seed: Int? = nil
    var systemPrompt: String = ""
}

actor InferenceService {
    static let shared = InferenceService()

    /// Stream tokens from `mlx_lm.generate`. Spawns one subprocess per turn.
    func stream(
        model: String,
        adapterPath: String?,
        prompt: String,
        params: InferenceParams
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                guard await PythonRuntime.shared.isReady, let python = await PythonRuntime.shared.pythonURL else {
                    continuation.finish(throwing: NSError(domain: "InferenceService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Python runtime not ready"]))
                    return
                }
                var fullPrompt = prompt
                if !params.systemPrompt.isEmpty {
                    fullPrompt = params.systemPrompt + "\n\n" + prompt
                }

                // Resolve a bare local-model name to its absolute directory before
                // handing it to mlx_lm. mlx-lm treats a slash-free string as an HF
                // repo id and tries to download it (load-bearing rule #4), so any
                // custom model under models/<name>/ — GGUF imports, strip-vision /
                // abliterate output, trained-and-saved models — would fail to load
                // in the Arena. HF repo ids (mlx-community/…) pass through unchanged.
                let resolvedModel = await Self.resolveModelArg(model)

                var args: [String] = [
                    "-m", "mlx_lm", "generate",
                    "--model", resolvedModel,
                    "--prompt", fullPrompt,
                    "--max-tokens", "\(params.maxTokens)",
                    "--temp", String(format: "%.3f", params.temperature),
                    "--top-p", String(format: "%.3f", params.topP)
                ]
                if let adapterPath, !adapterPath.isEmpty {
                    args.append(contentsOf: ["--adapter-path", adapterPath])
                }
                if let seed = params.seed {
                    args.append(contentsOf: ["--seed", "\(seed)"])
                }

                // Apply the optional MLX memory budget from the Memory tab (no-op when off).
                let wrapped = await MemoryService.wrap(args)
                var env = ["HF_HOME": PathResolver.hfHome.path, "PYTHONUNBUFFERED": "1"]
                for (k, v) in wrapped.env { env[k] = v }

                do {
                    let proc = try await ProcessRunner.spawn(
                        executable: python,
                        arguments: wrapped.arguments,
                        environment: env
                    )
                    var inOutputBlock = false
                    for await line in proc.stdout {
                        // mlx_lm.generate prints model output between ===== markers.
                        if line.contains("==========") {
                            inOutputBlock.toggle()
                            continue
                        }
                        if inOutputBlock {
                            continuation.yield(line)
                        }
                    }
                    let exit = try await proc.exit.value
                    if exit.code != 0 {
                        continuation.finish(throwing: NSError(domain: "InferenceService", code: Int(exit.code), userInfo: [NSLocalizedDescriptionKey: "mlx_lm.generate exited with code \(exit.code)"]))
                    } else {
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Mirrors `MLXServerService.resolveModelArg` / `EvalService` / `TrainingConfigView`:
    /// a registry hit becomes an absolute directory path so mlx-lm loads from our
    /// on-disk cache (or the custom-models dir) instead of treating a slash-free
    /// name as an HF repo id and re-downloading. Reads the `@MainActor` registry
    /// from this actor by hopping to the main actor. HF repo ids that aren't in the
    /// registry pass through unchanged. `ModelRegistry.scan()` already walks both HF
    /// cache layouts and models/<name>/, so a registry hit is sufficient evidence
    /// we can load from disk.
    private static func resolveModelArg(_ repoOrName: String) async -> String {
        if let dir = await MainActor.run(body: {
            ModelRegistry.shared.localModels.first(where: { $0.repoID == repoOrName })?.directory.path
        }) {
            return dir
        }
        // A slash-free name that the registry doesn't know is the failure case the
        // task targets: mlx-lm will read it as an HF repo id, fail to download it,
        // and exit 1. Log it (but still pass through gracefully). A name WITH a
        // slash is a genuine HF repo id (e.g. mlx-community/…) that simply hasn't
        // been downloaded yet — that's the normal path, so don't log it as an error.
        if !repoOrName.contains("/") {
            Log.error("InferenceService: local model '\(repoOrName)' not found in registry; mlx-lm will treat it as an HF repo id", .model)
        }
        return repoOrName
    }
}
