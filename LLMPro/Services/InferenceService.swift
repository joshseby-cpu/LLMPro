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

                // DiffusionGemma is a masked/block-diffusion LM with no mlx-lm
                // class, so it can't go through `mlx_lm generate`. If the model
                // is diffusion, hand off to the vendored diffusion_generate.py
                // helper, which streams the standard JSON-event protocol. The
                // Arena consumes the same AsyncStream<String> either way.
                if await Self.isDiffusionModel(repoOrName: model, resolvedPath: resolvedModel) {
                    await Self.streamDiffusion(
                        python: python,
                        resolvedModel: resolvedModel,
                        prompt: fullPrompt,
                        params: params,
                        continuation: continuation
                    )
                    return
                }

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
                            // ChatSession appends stream chunks raw, so re-add the
                            // newline ProcessRunner stripped when splitting mlx_lm's
                            // line-granular output. (The diffusion branch yields raw
                            // token segments that must concatenate inline.)
                            continuation.yield(line + "\n")
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

    /// Decide whether a model should be served by the DiffusionGemma helper
    /// rather than `mlx_lm generate`. Prefers the registry's `isDiffusion` flag
    /// (which `ModelRegistry.scan()` derives from config.json for both HF-cache
    /// and custom-dir models). Falls back to reading the resolved directory's
    /// own `config.json` `model_type` — covers a freshly-downloaded model the
    /// registry hasn't rescanned yet, as long as we resolved to a local path.
    private static func isDiffusionModel(repoOrName: String, resolvedPath: String) async -> Bool {
        if let flagged = await MainActor.run(body: {
            ModelRegistry.shared.localModels.first(where: { $0.repoID == repoOrName })?.isDiffusion
        }) {
            return flagged
        }
        // No registry hit: read config.json straight off the resolved path if it
        // resolved to a real directory. A slash-free name that didn't resolve is
        // an HF repo id mlx-lm would fetch — not something we treat as diffusion.
        let configURL = URL(fileURLWithPath: resolvedPath).appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        let modelType = (json["model_type"] as? String)?.lowercased() ?? ""
        let archNames = (json["architectures"] as? [String]) ?? []
        return modelType == "diffusion_gemma"
            || archNames.contains { $0.hasPrefix("DiffusionGemma") }
    }

    /// Spawn the vendored `diffusion_generate.py` and translate its JSON-event
    /// protocol into the Arena's `AsyncStream<String>`: each `token`/`progress`
    /// text segment is yielded as it denoises, `done` finishes, `error` throws.
    /// The helper self-pins MLX memory (it bypasses mlx_run.py), so it is NOT
    /// wrapped with `MemoryService.wrap` — it is spawned directly with the same
    /// env the other direct helpers (e.g. inspect_attention) use.
    private static func streamDiffusion(
        python: URL,
        resolvedModel: String,
        prompt: String,
        params: InferenceParams,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async {
        let helper = PathResolver.helpersDir.appendingPathComponent("diffusion_generate.py").path
        let args = [
            helper,
            "--model", resolvedModel,
            "--prompt", prompt,
            "--max-tokens", "\(params.maxTokens)",
            "--temperature", String(format: "%.3f", params.temperature),
        ]
        let env: [String: String] = [
            "HF_HOME": PathResolver.hfHome.path,
            "PYTHONUNBUFFERED": "1",
            // Self-pin memory: this helper does NOT go through mlx_run.py.
            "LLMPRO_MEM_LIMIT_GB": "108",
        ]

        do {
            let proc = try await ProcessRunner.spawn(executable: python, arguments: args, environment: env)
            var helperError: String?
            for await line in proc.stdout {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("{"),
                      let data = trimmed.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let event = obj["event"] as? String
                else { continue }
                switch event {
                case "token":
                    if let text = obj["text"] as? String, !text.isEmpty {
                        continuation.yield(text)
                    }
                case "error":
                    helperError = (obj["message"] as? String) ?? "diffusion generation failed"
                default:
                    // start / progress / done carry no streamable text segment.
                    break
                }
            }
            let exit = try await proc.exit.value
            if let helperError {
                Log.error("diffusion_generate: \(helperError)", .model)
                continuation.finish(throwing: NSError(domain: "InferenceService", code: 2, userInfo: [NSLocalizedDescriptionKey: helperError]))
            } else if exit.code != 0 {
                Log.error("diffusion_generate exited with code \(exit.code)", .model)
                continuation.finish(throwing: NSError(domain: "InferenceService", code: Int(exit.code), userInfo: [NSLocalizedDescriptionKey: "diffusion_generate exited with code \(exit.code)"]))
            } else {
                continuation.finish()
            }
        } catch {
            Log.error("diffusion_generate spawn failed: \(error.localizedDescription)", .model)
            continuation.finish(throwing: error)
        }
    }
}
