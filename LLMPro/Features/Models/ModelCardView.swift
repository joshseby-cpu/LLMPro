import SwiftUI
import SwiftData

/// Everything interesting about one local model, gathered from what's already on
/// disk: config.json facts (layers/heads/vocab/context), a parameter count from
/// the safetensors headers, lineage (fine-tunes trained from it), the latest
/// report-card score, and the user's notes/tags. Loaded once per sheet
/// presentation; the tensor sweep runs off the main actor.
struct ModelFacts {
    var layers: Int?
    var hiddenSize: Int?
    var attentionHeads: Int?
    var kvHeads: Int?
    var vocabSize: Int?
    var contextLength: Int?
    var paramCount: Int?

    /// Rough parameter count from safetensors headers. Quantized models pack
    /// weights (U32), so the count is approximate there — good enough for a card.
    static func tensorParamCount(directory: URL) -> Int? {
        guard let entries = try? SafetensorsHeader.enumerateModel(directory: directory), !entries.isEmpty
        else { return nil }
        return entries.reduce(0) { $0 + $1.paramCount }
    }

    static func configFacts(directory: URL) -> ModelFacts {
        var f = ModelFacts()
        let cfg = directory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: cfg),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return f }
        var j = json
        if let tc = json["text_config"] as? [String: Any] { j.merge(tc) { _, new in new } }
        f.layers = j["num_hidden_layers"] as? Int
        f.hiddenSize = j["hidden_size"] as? Int
        f.attentionHeads = j["num_attention_heads"] as? Int
        f.kvHeads = j["num_key_value_heads"] as? Int
        f.vocabSize = j["vocab_size"] as? Int
        f.contextLength = (j["max_position_embeddings"] as? Int) ?? (j["max_sequence_length"] as? Int)
        return f
    }

    static func compactParams(_ n: Int) -> String {
        if n >= 1_000_000_000 { return String(format: "%.1fB", Double(n) / 1_000_000_000) }
        if n >= 1_000_000 { return String(format: "%.0fM", Double(n) / 1_000_000) }
        return "\(n)"
    }
}

/// "About this model" — the rich model card, opened from a model's context menu.
struct ModelCardView: View {
    let model: ModelRegistry.DetectedModel
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \TrainingJob.createdAt, order: .reverse) private var jobs: [TrainingJob]
    @Query(sort: \EvalRun.createdAt, order: .reverse) private var evals: [EvalRun]

    @State private var facts = ModelFacts()
    @State private var meta = ModelMeta()

    private var lineage: [TrainingJob] { jobs.filter { $0.baseModelRepoID == model.repoID } }
    private var latestScore: EvalRun? {
        evals.first { $0.baseModelRepoID == model.repoID && $0.status == .completed }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    factsCard
                    if let score = latestScore { scoreCard(score) }
                    if !lineage.isEmpty { lineageCard }
                    if !meta.notes.isEmpty || !meta.tags.isEmpty { notesCard }
                }
            }
            HStack {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([model.directory])
                } label: { Label("Show in Finder", systemImage: "folder") }
                Spacer()
                Button("Done") { dismiss() }
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 480)
        .onAppear {
            facts = ModelFacts.configFacts(directory: model.directory)
            meta = ModelMetaStore.shared.meta(for: model.id)
            let dir = model.directory
            Task {
                let count = await Task.detached(priority: .utility) {
                    ModelFacts.tensorParamCount(directory: dir)
                }.value
                facts.paramCount = count
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader(model.displayName, systemImage: "cube.box")
            Text(model.repoID).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack(spacing: 6) {
                badge(model.architecture, color: .brand)
                badge(model.quantization, color: .blue)
                if model.isMoE { badge("MoE ×\(model.numExperts)", color: .orange) }
                if model.isDiffusion { badge("Diffusion", color: .purple) }
                if FuseService.ggufRoundTripWarning(forModelDir: model.directory.path) == nil {
                    badge("GGUF-ready", color: .green)
                }
            }
        }
    }

    private var factsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                GridRow { factCell("Size on disk", model.humanSize)
                          factCell("Parameters", facts.paramCount.map { "~" + ModelFacts.compactParams($0) } ?? "…") }
                GridRow { factCell("Layers", facts.layers.map(String.init) ?? "—")
                          factCell("Hidden size", facts.hiddenSize.map(String.init) ?? "—") }
                GridRow { factCell("Attention heads", headsText)
                          factCell("Vocabulary", facts.vocabSize.map { "\($0 / 1000)k tokens" } ?? "—") }
                GridRow { factCell("Context window", facts.contextLength.map { "\($0) tokens" } ?? "—")
                          factCell("Runs with", model.isDiffusion ? "diffusion decoder" : "mlx-lm") }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var headsText: String {
        guard let h = facts.attentionHeads else { return "—" }
        if let kv = facts.kvHeads, kv != h { return "\(h) (\(kv) KV)" }
        return "\(h)"
    }

    private func scoreCard(_ run: EvalRun) -> some View {
        HStack(spacing: 12) {
            Text("📊").font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Latest report card: \(run.passPercent)% on \(run.suite.displayName)")
                    .font(.callout.weight(.medium))
                Text(run.createdAt, format: .relative(presentation: .named))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var lineageCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Fine-tunes from this model").font(.caption).foregroundStyle(.secondary)
            ForEach(lineage.prefix(6)) { job in
                HStack(spacing: 8) {
                    Image(systemName: job.status == .completed ? "checkmark.circle.fill" : "circle.dotted")
                        .foregroundStyle(job.status == .completed ? Color.green : Color.secondary)
                    Text(job.name).font(.callout).lineLimit(1)
                    Spacer()
                    Text(job.createdAt, format: .dateTime.month().day()).font(.caption).foregroundStyle(.tertiary)
                }
            }
            if lineage.count > 6 {
                Text("+\(lineage.count - 6) more").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !meta.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(meta.tags, id: \.self) { tag in badge(tag, color: .secondary) }
                }
            }
            if !meta.notes.isEmpty {
                Text(meta.notes).font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func factCell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.callout.monospacedDigit().weight(.medium))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .gridColumnAlignment(.leading)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
