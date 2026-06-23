import SwiftUI

/// In-app preview of a training run's Markdown report (the same content
/// `TrainingRunReport` writes to disk), with Copy + Export actions. Presented from
/// the Past lessons list.
struct TrainingRunReportView: View {
    let job: TrainingJob
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let md = TrainingRunReport.markdown(for: job)
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Report — \(job.name)", systemImage: "doc.text")
            ScrollView {
                Text(md)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(md, forType: .string)
                } label: { Label("Copy", systemImage: "doc.on.doc") }
                Button {
                    TrainingRunReport.exportWithPanel(for: job)
                } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                .tint(.brand)
                Spacer()
                Button("Done") { dismiss() }
            }
        }
        .padding(20)
        .frame(minWidth: 580, minHeight: 540)
    }
}
