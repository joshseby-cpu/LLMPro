import SwiftUI

/// Modal sheet for "Add N experts to this MoE model". Clearly labelled
/// EXPERIMENTAL because sparse-upcycled experts only become useful after
/// follow-up fine-tuning.
struct AddExpertView: View {
    let model: ModelRegistry.DetectedModel
    @Environment(\.dismiss) private var dismiss
    @State private var service = ExpertExpansionService.shared

    @State private var numNew: Int = 2
    @State private var noiseStd: Double = 0.01
    @State private var outputName: String

    init(model: ModelRegistry.DetectedModel) {
        self.model = model
        _outputName = State(initialValue: "\(model.displayName)-expanded")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            warningBanner
            Divider()
            options
            Divider()
            outputField
            Divider()
            progressOrError
            Spacer()
            buttons
        }
        .padding(20)
        .frame(minWidth: 540, minHeight: 600)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Add experts to this MoE model").font(.title3.bold())
                Text("EXPERIMENTAL")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.2), in: Capsule())
                    .foregroundStyle(.orange)
            }
            Text(model.repoID).font(.caption).foregroundStyle(.secondary)
            Text("Currently has \(model.numExperts) experts. Adding \(numNew) → \(model.numExperts + numNew) total.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.top, 2)
        }
    }

    private var warningBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Sparse upcycling is a research technique.")
                    .font(.subheadline.weight(.medium))
                HelpHint("Sparse upcycling",
                         "We clone your model's last expert N times with small random noise, and widen each layer's router so it can route to the new experts. Without follow-up fine-tuning the new experts behave nearly identically to the old one — there's no \"intelligence\" added until you train.\n\nTypical workflow: add experts here, then go to the Teach tab and fine-tune on your target domain. The added experts will specialize during training.",
                         learnMore: URL(string: "https://arxiv.org/abs/2212.05055"))
                Spacer()
            }
            Text("Without follow-up fine-tuning, the expanded model behaves almost the same as the original. Plan a Teach run after this completes.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("How many experts to add").font(.headline)
                    HelpHint("Number of new experts",
                             "Each new expert is a clone of the existing last expert plus tiny random noise. Adding more experts grows the model's disk size and parameter count, but the model is sparse so inference cost grows only modestly.",
                             learnMore: URL(string: "https://arxiv.org/abs/2212.05055"))
                    Spacer()
                }
                Stepper(value: $numNew, in: 1...32) {
                    Text("\(numNew) new experts (→ \(model.numExperts + numNew) total)")
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Noise (\(noiseStd, specifier: "%.3f"))").font(.headline)
                    HelpHint("Cloning noise",
                             "Small Gaussian noise added to the cloned weights so the new experts don't start identical (which would let them collapse into a single behavior during training). Larger values diverge faster but can hurt the base model's capability. 0.01 is a safe default.",
                             link: "https://arxiv.org/abs/2212.05055")
                    Spacer()
                }
                Slider(value: $noiseStd, in: 0.001...0.05, step: 0.001)
            }
        }
    }

    private var outputField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Save as").font(.headline)
            TextField("expanded-model-name", text: $outputName)
                .textFieldStyle(.roundedBorder)
            Text("Will be saved to ~/Library/Application Support/LLMPro/models/\(outputName)")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var progressOrError: some View {
        if let active = service.active {
            VStack(alignment: .leading, spacing: 6) {
                switch active.stage {
                case .idle:
                    HStack { ProgressView().controlSize(.small); Text("Starting…") }
                case .running(let stage, let message):
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(prettyStage(stage)).font(.subheadline.weight(.medium))
                            Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                case .finished(let path, let old, let new):
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Done! \(old) → \(new) experts.", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Text(path).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                        Text("Next step: go to Teach and fine-tune this new model so the added experts actually specialize.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                case .failed(let reason):
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        } else {
            EmptyView()
        }
    }

    private func prettyStage(_ raw: String) -> String {
        switch raw {
        case "starting": return "📚 Preparing"
        case "loading":  return "📖 Loading weights"
        case "cloning":  return "🧬 Cloning experts"
        case "writing":  return "💾 Writing new model"
        default:         return raw.capitalized
        }
    }

    private var buttons: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button {
                ExpertExpansionService.shared.run(
                    input: model,
                    outputName: outputName,
                    numNewExperts: numNew,
                    noiseStd: noiseStd)
            } label: {
                HStack {
                    Image(systemName: "plus.rectangle.on.rectangle")
                    Text("Add \(numNew) experts")
                }
                .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canRun)
        }
    }

    private var canRun: Bool {
        !outputName.isEmpty && service.active == nil
    }
}

#if DEBUG
#Preview("Add experts") {
    AddExpertView(model: PreviewSupport.sampleMoEModel)
        .previewEnvironment()
}
#endif
