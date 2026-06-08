import Foundation

/// Friendly-language size category for a base model.
enum ModelSize: String {
    case tiny    // < 2 B params  (e.g. Llama-3.2-1B, Gemma-2-2B)
    case small   // 2 – 5 B       (e.g. Llama-3.2-3B, Phi-3.5-mini)
    case medium  // 5 – 10 B      (e.g. Qwen2.5-7B, Mistral-7B)
    case large   // 10 – 20 B     (e.g. Llama-3.1-13B)
    case huge    // 20 B+         (e.g. Qwen3-32B, Qwen3.6-27B)

    var displayName: String {
        switch self {
        case .tiny:   "Tiny"
        case .small:  "Small"
        case .medium: "Medium"
        case .large:  "Big"
        case .huge:   "Huge"
        }
    }

    var emoji: String {
        switch self {
        case .tiny:   "🐭"
        case .small:  "🐰"
        case .medium: "🐶"
        case .large:  "🦁"
        case .huge:   "🐘"
        }
    }

    var oneLine: String {
        switch self {
        case .tiny:   "Trains super fast. Good for trying things out."
        case .small:  "Fast and capable. Great everyday choice."
        case .medium: "Smart and balanced. The recommended size."
        case .large:  "Smarter, but slower to train."
        case .huge:   "Smartest. Needs lots of memory and patience."
        }
    }
}

/// User's choice of how long to spend training.
enum TrainingDuration: String, CaseIterable, Identifiable {
    case quick      // ~5–15 min depending on model
    case standard   // ~30–90 min
    case thorough   // ~2–8 hr

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .quick:    "Quick"
        case .standard: "Standard"
        case .thorough: "Thorough"
        }
    }

    var emoji: String {
        switch self {
        case .quick:    "⚡"
        case .standard: "📚"
        case .thorough: "🎓"
        }
    }

    var oneLine: String {
        switch self {
        case .quick:    "Just see if it works"
        case .standard: "A real fine-tune"
        case .thorough: "Best results, lots of patience"
        }
    }
}

struct AutoTunedConfig {
    var batchSize: Int
    var iters: Int
    var numLayers: Int
    var maxSeqLength: Int
    var learningRate: Double
    var gradAccumulationSteps: Int
    var gradCheckpoint: Bool
    var loraRank: Int
    var loraScale: Double
    var loraTargetKeys: [String]
    /// Best-guess training time in minutes, used purely for UI ("~25 min").
    var estimatedMinutes: Int
    /// Rough peak unified-memory estimate during training, in GB. Includes
    /// the model weights + activation buffers + a small LoRA optimizer state.
    /// Surfaced in the Teach UI so the user can see "this will use ~80 GB"
    /// before launching and avoid OOMing the run.
    var estimatedPeakMemoryGB: Int = 0
    /// `adamw` (default) or `sgd`. SGD is used for known-unstable bases (Qwen
    /// 27B 8bit etc) — its lack of momentum/variance buffers means a single
    /// noisy gradient can't poison every subsequent step into NaN.
    var optimizer: String = "adamw"
    /// When true, loss is computed on every token (not just the assistant
    /// reply). Strictly less efficient learning, but more numerically stable
    /// on bases that NaN with default settings.
    var maskPrompt: Bool = true
    /// Use DoRA (weight-decomposed LoRA) instead of plain LoRA — a better-quality
    /// adapter at the same rank, for a small speed/memory cost. Auto-selected for
    /// the "Thorough" (best-results) tier.
    var useDoRA: Bool = false
    /// Warmup steps for a warmup→cosine-decay LR schedule (0 = constant LR).
    /// AutoTuner sets ~5% of iters — steadier early training, better final minimum.
    var warmupSteps: Int = 0
    /// Which trainer this config targets. `.sft` (default) renders the mlx-lm SFT
    /// YAML; `.dpo` renders the mlx-lm-lora preference-tuning YAML.
    var trainMode: TrainMode = .sft
    /// DPO temperature (β). Only meaningful when `trainMode == .dpo`.
    var dpoBeta: Double = 0.1
}

enum AutoTuner {
    /// Map a HuggingFace repo ID or model name to a size bucket using a heuristic
    /// (digit + "B" pattern). Falls back to .medium if no marker is found.
    static func categorize(repoID: String) -> ModelSize {
        let lowered = repoID.lowercased()
        // Match patterns like "27b", "1.5b", "32b", "3b", "70b". Order matters: check large first.
        let patterns: [(Double, ModelSize)] = [
            (20.0, .huge),
            (10.0, .large),
            (5.0,  .medium),
            (2.0,  .small),
            (0.0,  .tiny),
        ]
        // Extract every "<num>B" or "<num>b" marker; pick the largest.
        let regex = try! NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)\s*b\b"#)
        let nsRange = NSRange(lowered.startIndex..., in: lowered)
        var maxBillion: Double = 0
        regex.enumerateMatches(in: lowered, options: [], range: nsRange) { match, _, _ in
            guard let m = match, let r = Range(m.range(at: 1), in: lowered),
                  let v = Double(lowered[r]) else { return }
            maxBillion = max(maxBillion, v)
        }
        for (threshold, size) in patterns where maxBillion >= threshold {
            return size
        }
        return .medium
    }

    static func tune(repoID: String,
                     dataPath: String,
                     adapterPath: String,
                     duration: TrainingDuration) -> AutoTunedConfig {
        let size = categorize(repoID: repoID)
        var cfg = tune(size: size, dataPath: dataPath, adapterPath: adapterPath, duration: duration)
        if isNumericallyUnstableBase(repoID: repoID) {
            cfg = applySafeMode(to: cfg)
        }
        return cfg
    }

    /// Architecture-aware overload. When the user picked an MoE base, we
    /// can't use the dense default LoRA target keys — the experts won't be
    /// touched. Look up `numExperts` and `architecture` from a registered
    /// `DetectedModel` and swap in MoE-appropriate target keys.
    static func tune(model: ModelRegistry.DetectedModel,
                     dataPath: String,
                     adapterPath: String,
                     duration: TrainingDuration) -> AutoTunedConfig {
        var cfg = tune(repoID: model.repoID, dataPath: dataPath,
                       adapterPath: adapterPath, duration: duration)
        if model.isMoE {
            cfg.loraTargetKeys = moeLoraTargetKeys(architecture: model.architecture, repoID: model.repoID)
        }
        return cfg
    }

    /// DPO-tuned hyperparameters, derived from the SFT recipe for the same
    /// model + duration then adjusted for preference tuning:
    ///   • fewer iters — preference sets are tiny (~1/3 of SFT, clamped 60–300),
    ///   • a smaller LR — DPO is sensitive and easily over-optimizes (~half SFT),
    ///   • β = 0.1 (the trainer's default),
    ///   • ~2× the peak-memory estimate — DPO loads a second full frozen copy of
    ///     the base as the reference model.
    /// LoRA rank/scale/target-keys and the warmup schedule carry over from SFT.
    static func tuneDPO(repoID: String,
                        dataPath: String,
                        adapterPath: String,
                        duration: TrainingDuration) -> AutoTunedConfig {
        let sft = tune(repoID: repoID, dataPath: dataPath,
                       adapterPath: adapterPath, duration: duration)
        return applyDPOAdjustments(to: sft)
    }

    /// Architecture-aware DPO overload — uses MoE target keys when the base is MoE.
    static func tuneDPO(model: ModelRegistry.DetectedModel,
                        dataPath: String,
                        adapterPath: String,
                        duration: TrainingDuration) -> AutoTunedConfig {
        let sft = tune(model: model, dataPath: dataPath,
                       adapterPath: adapterPath, duration: duration)
        return applyDPOAdjustments(to: sft)
    }

    /// Shared SFT→DPO adjustment so both `tuneDPO` overloads stay consistent.
    private static func applyDPOAdjustments(to sft: AutoTunedConfig) -> AutoTunedConfig {
        var cfg = sft
        cfg.trainMode = .dpo
        cfg.dpoBeta = 0.1
        // Fewer iters: preference datasets are small. ~1/3 of SFT, clamped to a
        // sane floor/ceiling so a Quick run still does enough and a Thorough run
        // doesn't overfit the tiny set.
        cfg.iters = min(300, max(60, sft.iters / 3))
        // Smaller LR — DPO is sensitive; roughly half the SFT rate.
        cfg.learningRate = sft.learningRate * 0.5
        // Warmup tracks the (now shorter) iters — ~5%, clamped like the SFT path.
        cfg.warmupSteps = max(5, min(cfg.iters / 20, 50))
        // The reference model is a second full copy of the base (~2× weights),
        // so roughly double the peak-memory estimate the UI warns with.
        cfg.estimatedPeakMemoryGB = sft.estimatedPeakMemoryGB * 2
        // Re-estimate wall-clock for the new iter count (load overhead is the
        // bulk of a short DPO run; keep it proportional to the SFT estimate).
        let iterRatio = sft.iters > 0 ? Double(cfg.iters) / Double(sft.iters) : 1.0
        cfg.estimatedMinutes = max(1, Int((Double(sft.estimatedMinutes) * iterRatio).rounded()))
        // DPO isn't supported by the SGD safe-mode path in mlx-lm-lora (its
        // optimizer choices are adam/adamw/muon); keep AdamW for preference runs.
        if cfg.optimizer == "sgd" { cfg.optimizer = "adamw" }
        return cfg
    }

    /// Pick LoRA target patterns appropriate for the model's MoE flavor.
    ///
    /// mlx-lm's LoRA matcher uses a substring search against module names,
    /// so a single short pattern like `mlp.experts.gate_proj` matches *every*
    /// expert across every layer. We always include attention q/v as well
    /// since those are universal.
    static func moeLoraTargetKeys(architecture: String, repoID: String) -> [String] {
        let a = architecture.lowercased()
        let r = repoID.lowercased()
        // Mixtral / DeepSeek-MoE family: experts under block_sparse_moe with w1/w2/w3.
        if a.contains("mixtral") || r.contains("mixtral") || a.contains("deepseek_v2") {
            return [
                "self_attn.q_proj", "self_attn.v_proj",
                "block_sparse_moe.experts.w1",
                "block_sparse_moe.experts.w3"
            ]
        }
        // DBRX nests experts differently; targets are mlp.experts.up/down/gate proj-equivalent.
        if a.contains("dbrx") || r.contains("dbrx") {
            return [
                "self_attn.q_proj", "self_attn.v_proj",
                "ffn.experts.mlp.v1",
                "ffn.experts.mlp.w1"
            ]
        }
        // Gemma-4 MoE batches every expert into a single `switch_glu` tensor
        // per layer (shape ~[num_experts, hidden, intermediate]). Verified by
        // sampling the actual safetensors keys of `gemma-4-26b-a4b`:
        //   language_model.model.layers.<i>.experts.switch_glu.gate_proj.weight
        //   language_model.model.layers.<i>.experts.switch_glu.up_proj.weight
        //   language_model.model.layers.<i>.experts.switch_glu.down_proj.weight
        // The MLX `language_model.` prefix is irrelevant to substring matching.
        if a.contains("gemma4") || r.contains("gemma-4") || r.contains("gemma4") {
            return [
                "self_attn.q_proj", "self_attn.v_proj",
                "experts.switch_glu.gate_proj",
                "experts.switch_glu.up_proj"
            ]
        }
        // Qwen2-MoE / Qwen3-MoE / OlmoE / Granite-MoE — all use the
        // `mlp.experts.<N>.{gate,up,down}_proj` convention.
        return [
            "self_attn.q_proj", "self_attn.v_proj",
            "mlp.experts.gate_proj",
            "mlp.experts.up_proj"
        ]
    }

    /// Per-expert LoRA targeting only makes sense when each expert is its
    /// own tensor (Mixtral / Qwen-MoE / OlmoE / etc.). Gemma-4 batches all
    /// experts into a single `switch_glu` tensor, so there's no way to
    /// adapt just expert 3; the UI must hide the picker for those models.
    static func supportsPerExpertTargeting(architecture: String, repoID: String) -> Bool {
        let a = architecture.lowercased()
        let r = repoID.lowercased()
        if a.contains("gemma4") || r.contains("gemma-4") || r.contains("gemma4") {
            return false
        }
        return true
    }

    /// Returns true for bases that NaN with default AdamW + grad-accumulation
    /// settings on most coding datasets. We verified this experimentally for
    /// Qwen3.5/3.6 27B at 8bit; happy to expand the list as more are found.
    /// See docs/STATE.md "Known numerical issues".
    static func isNumericallyUnstableBase(repoID: String) -> Bool {
        let l = repoID.lowercased()
        let isQwenHuge = l.contains("qwen3.5") || l.contains("qwen3.6")
        let isEightBit = l.contains("8bit") || l.contains("-8bit") || l.contains("_8bit")
        return isQwenHuge && isEightBit
    }

    /// Conservative overrides that empirically survive training on
    /// Qwen-27B-8bit-class bases. Slower than AdamW (SGD has no momentum)
    /// but doesn't NaN. Used automatically when `isNumericallyUnstableBase`
    /// returns true.
    private static func applySafeMode(to cfg: AutoTunedConfig) -> AutoTunedConfig {
        var safe = cfg
        safe.optimizer = "sgd"
        safe.gradAccumulationSteps = 1     // no cascade-NaN through accumulation
        safe.maskPrompt = false            // loss on all tokens is more stable
        safe.loraRank = 4                  // smallest sensible adapter
        safe.loraScale = 8.0
        safe.loraTargetKeys = ["self_attn.q_proj", "self_attn.v_proj"]
        safe.numLayers = 8                 // fewer trainable layers, less to go wrong
        safe.maxSeqLength = 1024           // smaller activations, fewer chances to overflow
        safe.learningRate = 5.0e-6
        // SGD is ~1.5x slower than AdamW per iter at the same batch size
        // because the lack of accumulation means more iters of compute per
        // "effective update". Match the user's wall-clock expectation.
        safe.estimatedMinutes = max(1, Int(Double(cfg.estimatedMinutes) * 1.5))
        safe.useDoRA = false               // keep the simplest stable path on NaN-prone bases
        return safe
    }

    static func tune(size: ModelSize,
                     dataPath: String,
                     adapterPath: String,
                     duration: TrainingDuration) -> AutoTunedConfig {

        // Batch size: keep batch×seq×grad-acc small enough for memory.
        let batch: Int
        let gradAccum: Int
        let layers: Int
        let maxSeq: Int
        let gradCkpt: Bool

        switch size {
        case .tiny:
            batch = 4; gradAccum = 1; layers = 16; maxSeq = 2048; gradCkpt = false
        case .small:
            batch = 4; gradAccum = 1; layers = 16; maxSeq = 2048; gradCkpt = false
        case .medium:
            batch = 2; gradAccum = 2; layers = 16; maxSeq = 2048; gradCkpt = true
        case .large:
            batch = 1; gradAccum = 2; layers = 12; maxSeq = 1536; gradCkpt = true
        case .huge:
            // Huge bf16 models (Qwen 27B ≈ 56 GB resident). History: the original
            // 16 layers × 2048 × grad_accum 4 hard-crashed at the Metal ceiling, so
            // it was cut hard to 8 × 1024 × 1. Now that `mlx_run.py` pins MLX's
            // memory limit to the real working-set ceiling (an over-budget run frees
            // cache instead of crashing), we sit in the middle: more adapted layers
            // and a larger effective batch for a materially better fine-tune, with
            // seq + grad-accum kept below the config that OOM'd. grad_accum is
            // ~memory-neutral (micro-batches run sequentially) but steadies the
            // gradient. Validated end-to-end on Qwen3.6-27B-bf16 (peak under ceiling).
            batch = 1; gradAccum = 2; layers = 12; maxSeq = 1536; gradCkpt = true
        }

        // Iters by duration × size — picked so most runs land in a reasonable wall-clock.
        let iters: Int
        switch (duration, size) {
        case (.quick,    .tiny):    iters = 200
        case (.quick,    .small):   iters = 150
        case (.quick,    .medium):  iters = 100
        case (.quick,    .large):   iters = 60
        case (.quick,    .huge):    iters = 50
        case (.standard, .tiny):    iters = 800
        case (.standard, .small):   iters = 600
        case (.standard, .medium):  iters = 500
        case (.standard, .large):   iters = 300
        case (.standard, .huge):    iters = 200
        case (.thorough, .tiny):    iters = 2000
        case (.thorough, .small):   iters = 1500
        case (.thorough, .medium):  iters = 1200
        case (.thorough, .large):   iters = 800
        case (.thorough, .huge):    iters = 500
        }

        // Learning rate: smaller models tolerate larger LRs, huge models need stability.
        let lr: Double = {
            switch size {
            case .tiny, .small: return 2.0e-5
            case .medium:       return 1.5e-5
            case .large:        return 1.0e-5
            case .huge:         return 8.0e-6
            }
        }()

        // LoRA shape: small models benefit from a bigger adapter; huge ones don't need much.
        let rank: Int
        switch size {
        case .tiny, .small: rank = 16
        case .medium:       rank = 12
        case .large:        rank = 10
        case .huge:         rank = 8
        }
        let scale = Double(rank) * 2.0

        // Target keys. The FFN (mlp.*) is where most code-pattern / API-recall
        // capacity lives, so for medium+ dense models we adapt gate/up/down too —
        // attention-only materially underfits coding transfer. This matches the
        // app's own curated recipes (qwen2.5-7b-teach-coding.yaml targets mlp.*)
        // and mlx-lm's LORA guidance; the MoE path already adapts mlp.experts.*.
        // Tiny/small stay attention-only to keep memory + per-iter cost down.
        let keys: [String]
        switch size {
        case .tiny:
            keys = ["self_attn.q_proj", "self_attn.v_proj"]
        case .small:
            keys = ["self_attn.q_proj", "self_attn.v_proj",
                    "mlp.gate_proj", "mlp.up_proj"]
        default: // medium / large / huge
            keys = ["self_attn.q_proj", "self_attn.k_proj",
                    "self_attn.v_proj", "self_attn.o_proj",
                    "mlp.gate_proj", "mlp.up_proj", "mlp.down_proj"]
        }

        // Wall-clock estimate from empirical measurements on M-series 128 GB:
        //   32B 4-bit, batch 1, grad-ckpt: ~2.5 sec/iter (50 iters → ~2 min training)
        //   27B 8-bit, batch 1, grad-ckpt: ~3.5 sec/iter
        // Per-iter time is dominated by parameter count, not sequence length (real CodeAlpaca
        // rows average ~150 tokens, so seq budget is mostly idle). Hardcode by size bucket.
        let secondsPerIter: Double = {
            switch size {
            case .tiny:   return 0.8   // 1-2B
            case .small:  return 1.8   // 3-5B
            case .medium: return 3.0   // 7-10B
            case .large:  return 5.0   // 10-20B
            case .huge:   return 8.0   // 20B+ (more adapted layers ⇒ a touch slower per iter)
            }
        }()
        let loadOverheadSeconds: Double = {
            switch size {
            case .tiny:   return 20
            case .small:  return 40
            case .medium: return 90
            case .large:  return 180
            case .huge:   return 240
            }
        }()
        let totalSeconds = loadOverheadSeconds + secondsPerIter * Double(iters)
        let minutes = max(1, Int((totalSeconds / 60).rounded()))

        // Peak-memory estimate during training. Three contributions, in GB:
        //   1. Model weights (the big one). bf16 ≈ 2 × param-count; 8bit ≈ 1×;
        //      4bit ≈ 0.5×. We can't easily know the precision here, so assume
        //      bf16 (the worst case for memory) — UI shows the upper bound.
        //   2. Activations + KV cache: roughly batch × max_seq × hidden_dim ×
        //      n_layers × 2 bytes × ~3 (forward + backward + ckpt). At seq=2048,
        //      bs=1, on a 27B (hidden 5120, 64 layers) this is ~10 GB.
        //   3. LoRA optimizer state (rank × layers × hidden × 8 bytes): negligible.
        // The estimate is intentionally pessimistic — better to over-warn than
        // OOM the run.
        let weightsGB: Int = {
            switch size {
            case .tiny:   return 4    // 1-2B at bf16
            case .small:  return 10   // 3-5B
            case .medium: return 20   // 7-10B
            case .large:  return 30   // 10-20B
            case .huge:   return 56   // 27B at bf16
            }
        }()
        let activationGB: Int = {
            // Scales with max_seq × num_layers × batch × grad_accum
            let bytes = Double(maxSeq) * Double(layers) * Double(batch) * Double(gradAccum)
                      * 5120.0 * 2.0 * 3.0   // hidden×bf16×fwd+bwd+ckpt
            return max(1, Int(bytes / 1e9))
        }()
        let peakMemGB = weightsGB + activationGB + 4   // +4 GB OS/Python overhead

        // Smarter recipe (MLX-native, the portable equivalent of what tools like
        // Unsloth do on CUDA): a warmup→cosine LR schedule on every run, and DoRA
        // for the "Thorough" best-results tier. ~5% warmup, clamped to a sane band.
        let warmup = max(5, min(iters / 20, 50))
        let useDoRA = (duration == .thorough)

        return AutoTunedConfig(
            batchSize: batch,
            iters: iters,
            numLayers: layers,
            maxSeqLength: maxSeq,
            learningRate: lr,
            gradAccumulationSteps: gradAccum,
            gradCheckpoint: gradCkpt,
            loraRank: rank,
            loraScale: scale,
            loraTargetKeys: keys,
            estimatedMinutes: minutes,
            estimatedPeakMemoryGB: peakMemGB,
            useDoRA: useDoRA,
            warmupSteps: warmup
        )
    }

    /// Render an AutoTunedConfig + paths into the mlx-lm YAML our TrainingService consumes.
    static func renderYAML(repoID: String, dataPath: String, adapterPath: String,
                           tuned: AutoTunedConfig) -> String {
        // Reuse TrainingConfig so we keep one source of truth for the YAML format.
        var cfg = TrainingConfig.default
        cfg.model = repoID
        cfg.data = dataPath
        cfg.adapterPath = adapterPath
        cfg.batchSize = tuned.batchSize
        cfg.iters = tuned.iters
        cfg.numLayers = tuned.numLayers
        cfg.maxSeqLength = tuned.maxSeqLength
        cfg.learningRate = tuned.learningRate
        cfg.gradAccumulationSteps = tuned.gradAccumulationSteps
        cfg.gradCheckpoint = tuned.gradCheckpoint
        cfg.loraRank = tuned.loraRank
        cfg.loraScale = tuned.loraScale
        cfg.loraTargetKeys = tuned.loraTargetKeys
        cfg.fineTuneType = tuned.useDoRA ? .dora : .lora
        cfg.optimizer = tuned.optimizer
        cfg.maskPrompt = tuned.maskPrompt
        cfg.lrScheduleWarmupSteps = tuned.warmupSteps
        // Preference-tuning fields. When .sft (the default) these are ignored by
        // TrainingConfig.renderYAML(), so the SFT output stays byte-identical.
        cfg.trainMode = tuned.trainMode
        cfg.dpoBeta = tuned.dpoBeta
        // Scale validation cadence to the run length: a Quick run (~50 iters) at the
        // TrainingConfig default of 100 would emit ZERO "Val loss" lines, leaving the
        // friendly Progress chart + 5-star rating empty on exactly the runs new users
        // try first. Evaluate ~5×/run, snapshot ~4×/run.
        cfg.stepsPerEval = max(10, tuned.iters / 5)
        cfg.saveEvery = max(cfg.stepsPerEval, tuned.iters / 4)
        cfg.valBatches = 10
        // Mild LoRA dropout — free regularization on the small coding datasets this
        // app trains on; matches the curated recipes (0.05). Off for NaN-prone bases.
        cfg.loraDropout = tuned.optimizer == "sgd" ? 0.0 : 0.05
        return cfg.renderYAML()
    }
}
