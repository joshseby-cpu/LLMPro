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

                var args: [String] = [
                    "-m", "mlx_lm", "generate",
                    "--model", model,
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
}
