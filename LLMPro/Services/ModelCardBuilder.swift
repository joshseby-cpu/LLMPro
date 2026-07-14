import Foundation

/// Markdown generators for shareable export artifacts:
/// - `modelCard` — a HuggingFace-style model card for a fine-tune (what it is,
///   what it was trained on, how it scored) the user can publish alongside it.
/// - `cloudREADME` — the README dropped into a "Host to the cloud" safetensors
///   export with the exact vLLM / TGI commands to serve it.
/// Pure string builders — no IO. `@MainActor` because they read @Model types.
@MainActor
enum ModelCardBuilder {

    static func modelCard(
        name: String,
        baseModel: String,
        datasetName: String?,
        job: TrainingJob?,
        latestEval: EvalRun?
    ) -> String {
        var out = "# \(name)\n\n"
        out += "A coding fine-tune of `\(baseModel)`, trained locally with [LLMPro](https://github.com/joshseby-cpu/LLMPro) on Apple Silicon (mlx-lm LoRA).\n\n"
        out += "## Details\n\n| | |\n|---|---|\n"
        out += "| Base model | `\(baseModel)` |\n"
        if let datasetName { out += "| Training data | \(datasetName) |\n" }
        if let job {
            out += "| Method | \(job.trainMode.displayName) (LoRA via mlx-lm) |\n"
            out += "| Iterations | \(job.lastIter) |\n"
            if let loss = job.lastLoss { out += "| Final train loss | \(String(format: "%.4f", loss)) |\n" }
            if let v = job.lastEvalLoss { out += "| Final val loss | \(String(format: "%.4f", v)) |\n" }
            out += "| Trained | \(job.createdAt.formatted(date: .abbreviated, time: .omitted)) |\n"
        }
        if let e = latestEval {
            out += "\n## Evaluation\n\n"
            out += "| Suite | Score | pass@k |\n|---|---|---|\n"
            out += "| \(e.suite.displayName) | **\(e.passPercent)%** (\(e.passedCount)/\(e.totalCount)) | k=\(e.k) |\n"
        }
        out += "\n## Usage\n\nMLX (Apple Silicon):\n\n"
        out += "```bash\npython -m mlx_lm generate --model <this-folder> --prompt \"...\"\n```\n\n"
        out += "GGUF builds (if included) run in Ollama / LM Studio / llama.cpp.\n\n"
        out += "---\n_Made with LLMPro — fine-tuning without the fiddly parts._\n"
        return out
    }

    static func cloudREADME(modelName: String, baseModel: String) -> String {
        """
        # \(modelName) — cloud serving package

        Full-precision (dequantized) HuggingFace-format safetensors, exported by
        LLMPro from an mlx-lm LoRA fine-tune of `\(baseModel)`. This layout is what
        cloud inference runtimes consume directly — no GGUF needed.

        ## Serve with vLLM

        ```bash
        pip install vllm
        vllm serve /path/to/this/folder --served-model-name \(modelName)
        # OpenAI-compatible endpoint on :8000
        curl http://localhost:8000/v1/chat/completions \\
          -H 'Content-Type: application/json' \\
          -d '{"model": "\(modelName)", "messages": [{"role": "user", "content": "Hello"}]}'
        ```

        ## Serve with TGI (Text Generation Inference)

        ```bash
        docker run --gpus all -p 8080:80 -v $(pwd):/model \\
          ghcr.io/huggingface/text-generation-inference:latest \\
          --model-id /model
        ```

        ## Notes

        - Weights are fp16/bf16 — pick GPU hardware with enough VRAM (rule of thumb: ~2 bytes/parameter, plus KV cache).
        - The runtime must support this model's architecture; recent vLLM/TGI releases cover the mainstream families.
        - Chat template ships in `tokenizer_config.json` / `chat_template.jinja` and is applied automatically.
        """
    }
}
