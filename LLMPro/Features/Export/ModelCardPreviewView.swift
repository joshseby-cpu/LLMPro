import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Preview + save a shareable Markdown model card for an export source. Pulls
/// the training job, its dataset name, and the latest matching report card
/// automatically — the user just copies or saves the result (drop it in the
/// export folder or a HuggingFace repo).
struct ModelCardPreviewView: View {
    let source: ExportSource
    @Environment(\.dismiss) private var dismiss
    @Query private var jobs: [TrainingJob]
    @Query private var datasets: [DatasetRecord]
    @Query(sort: \EvalRun.createdAt, order: .reverse) private var evals: [EvalRun]

    @State private var copied = false

    private var markdown: String {
        let job = jobs.first { $0.id == source.id }
        let datasetName = job.flatMap { j in datasets.first { $0.id == j.datasetID }?.name }
        let eval = evals.first {
            $0.status == .completed && $0.baseModelRepoID == source.baseModelRepoID
                && (job == nil || $0.adapterRelativePath == job!.adapterRelativePath)
        }
        return ModelCardBuilder.modelCard(
            name: source.name,
            baseModel: source.baseModelRepoID,
            datasetName: datasetName,
            job: job,
            latestEval: eval)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Model card", systemImage: "doc.richtext")
            Text("A shareable summary of this fine-tune — save it next to the exported files or publish it with the model.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(markdown)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(markdown, forType: .string)
                    copied = true
                } label: {
                    Label(copied ? "Copied ✓" : "Copy", systemImage: "doc.on.doc")
                }
                Button {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = "README.md"
                    panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
                    if panel.runModal() == .OK, let url = panel.url {
                        try? markdown.write(to: url, atomically: true, encoding: .utf8)
                    }
                } label: {
                    Label("Save…", systemImage: "square.and.arrow.down")
                }
                Spacer()
                Button("Done") { dismiss() }
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 480)
    }
}
