import SwiftUI
import SwiftData

/// Side-by-side comparison of two local models — pick any two and see their
/// facts in aligned columns, with rows that differ highlighted. Reuses
/// `ModelFacts` from the model card. Answers "which of these should I train /
/// keep / delete?" without opening two Finder windows and a calculator.
struct ModelCompareView: View {
    let models: [ModelRegistry.DetectedModel]
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \EvalRun.createdAt, order: .reverse) private var evals: [EvalRun]

    @State private var leftID: String = ""
    @State private var rightID: String = ""
    @State private var leftFacts = ModelFacts()
    @State private var rightFacts = ModelFacts()

    private var left: ModelRegistry.DetectedModel? { models.first { $0.id == leftID } }
    private var right: ModelRegistry.DetectedModel? { models.first { $0.id == rightID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Compare models", systemImage: "square.split.2x1")
            HStack(spacing: 12) {
                picker("First model", selection: $leftID)
                picker("Second model", selection: $rightID)
            }
            if let l = left, let r = right {
                comparison(l, r)
            } else {
                ContentUnavailableView("Pick two models", systemImage: "square.split.2x1",
                                       description: Text("Choose a model on each side to compare them."))
            }
            Spacer(minLength: 0)
            HStack { Spacer(); Button("Done") { dismiss() } }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 480)
        .onAppear {
            if leftID.isEmpty, models.count > 0 { leftID = models[0].id }
            if rightID.isEmpty, models.count > 1 { rightID = models[1].id }
        }
        .onChange(of: leftID, initial: true) { _, _ in
            if let l = left { leftFacts = ModelFacts.configFacts(directory: l.directory) }
        }
        .onChange(of: rightID, initial: true) { _, _ in
            if let r = right { rightFacts = ModelFacts.configFacts(directory: r.directory) }
        }
    }

    private func picker(_ label: String, selection: Binding<String>) -> some View {
        Picker(label, selection: selection) {
            ForEach(models) { m in Text(m.displayName).tag(m.id) }
        }
        .labelsHidden()
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func comparison(_ l: ModelRegistry.DetectedModel, _ r: ModelRegistry.DetectedModel) -> some View {
        let rows: [(String, String, String)] = [
            ("Architecture", l.architecture, r.architecture),
            ("Quantization", l.quantization, r.quantization),
            ("Size on disk", l.humanSize, r.humanSize),
            ("Layers", leftFacts.layers.map(String.init) ?? "—", rightFacts.layers.map(String.init) ?? "—"),
            ("Hidden size", leftFacts.hiddenSize.map(String.init) ?? "—", rightFacts.hiddenSize.map(String.init) ?? "—"),
            ("Attention heads", leftFacts.attentionHeads.map(String.init) ?? "—", rightFacts.attentionHeads.map(String.init) ?? "—"),
            ("Context window", leftFacts.contextLength.map { "\($0)" } ?? "—", rightFacts.contextLength.map { "\($0)" } ?? "—"),
            ("Vocabulary", leftFacts.vocabSize.map { "\($0 / 1000)k" } ?? "—", rightFacts.vocabSize.map { "\($0 / 1000)k" } ?? "—"),
            ("Experts (MoE)", l.isMoE ? "\(l.numExperts)" : "dense", r.isMoE ? "\(r.numExperts)" : "dense"),
            ("GGUF export", ggufText(l), ggufText(r)),
            ("Latest score", scoreText(l), scoreText(r)),
        ]
        ScrollView {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    Text(l.displayName).font(.headline).lineLimit(1)
                    Text(r.displayName).font(.headline).lineLimit(1)
                }
                Divider()
                ForEach(rows, id: \.0) { row in
                    GridRow {
                        Text(row.0).font(.caption).foregroundStyle(.secondary)
                        cell(row.1, differs: row.1 != row.2)
                        cell(row.2, differs: row.1 != row.2)
                    }
                }
            }
            .padding(4)
        }
        .card()
    }

    private func cell(_ text: String, differs: Bool) -> some View {
        Text(text)
            .font(.callout.monospacedDigit())
            .foregroundStyle(differs ? Color.brand : Color.primary)
            .fontWeight(differs ? .semibold : .regular)
    }

    private func ggufText(_ m: ModelRegistry.DetectedModel) -> String {
        FuseService.ggufRoundTripWarning(forModelDir: m.directory.path) == nil ? "✓ works" : "blocked"
    }

    private func scoreText(_ m: ModelRegistry.DetectedModel) -> String {
        if let e = evals.first(where: { $0.baseModelRepoID == m.repoID && $0.status == .completed }) {
            return "\(e.passPercent)% \(e.suite.displayName)"
        }
        return "not scored"
    }
}
