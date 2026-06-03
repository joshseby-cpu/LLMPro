import Foundation

// MARK: - Pure value report (Sendable, built off-main, no model load, no Python)

/// A friendly + technical summary of a model's weights, assembled entirely from
/// safetensors headers (`SafetensorsHeader`) + `config.json`. Pure value type, so
/// it crosses actor boundaries freely and is built on a background task.
struct ModelWeightsReport: Sendable {

    /// Tensors grouped by their transformer block index (parsed from the name).
    struct LayerGroup: Identifiable, Sendable {
        let index: Int
        let tensors: [SafetensorsHeader.TensorEntry]
        var paramCount: Int { tensors.reduce(0) { $0 + $1.paramCount } }
        var byteSize: Int { tensors.reduce(0) { $0 + $1.byteSize } }
        var id: Int { index }
    }

    var repoID: String
    var architecture: String            // config model_type, e.g. "qwen3_5"
    var totalParams: Int
    var totalBytes: Int
    var tensorCount: Int
    var dtypeHistogram: [String: Int]   // dtype string -> number of tensors
    var numLayers: Int
    var numHeads: Int
    var numKVHeads: Int
    var headDim: Int
    var hiddenSize: Int
    var vocabSize: Int
    var numExperts: Int
    var tiedEmbeddings: Bool
    var quantized: Bool
    var quantBits: Int?
    var layers: [LayerGroup]
    var tensors: [SafetensorsHeader.TensorEntry]   // every tensor, for the table

    var isGQA: Bool { numKVHeads > 0 && numKVHeads < numHeads }
    var isMoE: Bool { numExperts > 1 }

    /// "27.4B" / "1.2M" — friendly param count.
    var paramsHuman: String {
        let p = Double(totalParams)
        if p >= 1e9 { return String(format: "%.1fB", p / 1e9) }
        if p >= 1e6 { return String(format: "%.1fM", p / 1e6) }
        if p >= 1e3 { return String(format: "%.1fK", p / 1e3) }
        return "\(totalParams)"
    }

    /// Plain-language one-liner about the numeric format (the dominant dtype).
    var dtypeSummary: String {
        guard let top = dtypeHistogram.max(by: { $0.value < $1.value })?.key else { return "unknown" }
        switch top {
        case "BF16": return "bfloat16 — full precision, training-ready"
        case "F16":  return "float16 — full precision"
        case "F32":  return "float32 — highest precision, large"
        case "U32", "U8", "I8":
            return quantBits.map { "quantized to \($0)-bit — smaller + faster" } ?? "quantized — smaller + faster"
        default:     return top
        }
    }

    // MARK: Build (pure, off-main)

    /// Read config.json + every safetensors header in `directory` and assemble the
    /// report. Throws if no safetensors files are found. No model is loaded.
    static func build(directory: URL, repoID: String) throws -> ModelWeightsReport {
        let tensors = try SafetensorsHeader.enumerateModel(directory: directory)
        let cfg = loadConfig(directory: directory)

        // Hyperparameters live under `text_config` for multimodal wrappers
        // (qwen3_5 / gemma4); fall back to the top level for plain LMs.
        func intField(_ key: String) -> Int {
            if let tc = cfg["text_config"] as? [String: Any], let v = (tc[key] as? NSNumber)?.intValue { return v }
            if let v = (cfg[key] as? NSNumber)?.intValue { return v }
            return 0
        }
        func boolField(_ key: String) -> Bool {
            if let tc = cfg["text_config"] as? [String: Any], let v = tc[key] as? Bool { return v }
            return cfg[key] as? Bool ?? false
        }

        let modelType = (cfg["model_type"] as? String)
            ?? ((cfg["text_config"] as? [String: Any])?["model_type"] as? String)
            ?? "unknown"

        let hidden = intField("hidden_size")
        let heads = intField("num_attention_heads")
        var headDim = intField("head_dim")
        if headDim == 0, heads > 0, hidden > 0 { headDim = hidden / heads }

        // num_experts has a few spellings across architectures.
        let experts = max(intField("num_experts"),
                          max(intField("num_local_experts"), intField("n_routed_experts")))

        // Quantization: an mlx-quantized model carries a `quantization` block in
        // config.json AND packs weights as U32 (+ sibling .scales/.biases). Detect
        // either signal.
        var quantBits: Int? = nil
        if let q = cfg["quantization"] as? [String: Any] ?? (cfg["text_config"] as? [String: Any])?["quantization"] as? [String: Any] {
            quantBits = (q["bits"] as? NSNumber)?.intValue
        }
        let hasPackedDtype = tensors.contains { ["U32", "U8", "I8"].contains($0.dtype) }
        let quantized = quantBits != nil || hasPackedDtype

        // Totals + dtype histogram.
        var totalParams = 0, totalBytes = 0
        var hist: [String: Int] = [:]
        for t in tensors {
            totalParams += t.paramCount
            totalBytes += t.byteSize
            hist[t.dtype, default: 0] += 1
        }

        // Group by transformer block index parsed from the tensor name
        // ("…layers.<i>.…"). Tensors with no layer index (embeddings, final norm,
        // lm_head) are left out of the per-layer view.
        var byLayer: [Int: [SafetensorsHeader.TensorEntry]] = [:]
        for t in tensors {
            if let idx = layerIndex(of: t.name) { byLayer[idx, default: []].append(t) }
        }
        let layers = byLayer.keys.sorted().map { LayerGroup(index: $0, tensors: byLayer[$0]!) }
        let numLayers = max(intField("num_hidden_layers"), layers.count)

        return ModelWeightsReport(
            repoID: repoID,
            architecture: modelType,
            totalParams: totalParams,
            totalBytes: totalBytes,
            tensorCount: tensors.count,
            dtypeHistogram: hist,
            numLayers: numLayers,
            numHeads: heads,
            numKVHeads: intField("num_key_value_heads"),
            headDim: headDim,
            hiddenSize: hidden,
            vocabSize: intField("vocab_size"),
            numExperts: experts,
            tiedEmbeddings: boolField("tie_word_embeddings"),
            quantized: quantized,
            quantBits: quantBits,
            layers: layers,
            tensors: tensors
        )
    }

    private static func loadConfig(directory: URL) -> [String: Any] {
        let url = directory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    /// Extract the integer in "…layers.<N>.…" if present.
    nonisolated(unsafe) private static let layerRegex = try! NSRegularExpression(pattern: #"layers\.(\d+)\."#)
    private static func layerIndex(of name: String) -> Int? {
        let range = NSRange(name.startIndex..., in: name)
        guard let m = layerRegex.firstMatch(in: name, range: range),
              let r = Range(m.range(at: 1), in: name) else { return nil }
        return Int(name[r])
    }
}

// MARK: - @MainActor service the View binds to

/// Drives the pure `ModelWeightsReport.build` off the main actor and publishes
/// loading / report / error state. No Python, nothing long-lived.
@MainActor
@Observable
final class WeightsInspectService {
    private(set) var report: ModelWeightsReport?
    private(set) var isLoading = false
    private(set) var error: String?
    private var loadedRepoID: String?

    /// Parse a model's weights. No-op if the same model is already loaded.
    func load(model: ModelRegistry.DetectedModel) {
        if loadedRepoID == model.repoID, report != nil { return }
        isLoading = true
        error = nil
        let dir = model.directory
        let repo = model.repoID
        Task {
            do {
                let r = try await Task.detached(priority: .userInitiated) {
                    try ModelWeightsReport.build(directory: dir, repoID: repo)
                }.value
                self.report = r
                self.loadedRepoID = repo
            } catch {
                self.error = error.localizedDescription
                self.report = nil
            }
            self.isLoading = false
        }
    }
}
