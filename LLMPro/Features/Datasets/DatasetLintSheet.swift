import SwiftUI

/// "Check this lesson" — runs DatasetLinter over the current split's rows and lists
/// what would hurt a fine-tune (missing prompts/replies, empty messages,
/// duplicates, over-long rows). Offers a non-destructive one-click "Make a clean
/// copy" that hands the filtered rows back to the detail view, which the user then
/// Saves. Original file is untouched until they save.
struct DatasetLintSheet: View {
    let rows: [ChatRow]
    /// Called with the cleaned rows when the user accepts the fix.
    let onClean: ([ChatRow]) -> Void
    @Environment(\.dismiss) private var dismiss

    private var issues: [DatasetLinter.Issue] { DatasetLinter.lint(rows) }

    var body: some View {
        let found = issues
        let errors = found.filter { $0.severity == .error }.count
        let warnings = found.filter { $0.severity == .warning }.count
        let cleanedCount = DatasetLinter.cleaned(rows).count
        let dropped = rows.count - cleanedCount

        return VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Check “this lesson”", systemImage: "checkmark.seal")

            if found.isEmpty {
                Label("No problems found — this lesson looks good to train on.", systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(.green)
            } else {
                HStack(spacing: 16) {
                    Label("\(errors) error\(errors == 1 ? "" : "s")", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(errors > 0 ? .red : .secondary)
                    Label("\(warnings) warning\(warnings == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(warnings > 0 ? .orange : .secondary)
                }
                .font(.callout)

                List(found) { issue in
                    Label {
                        Text(issue.message).font(.callout)
                    } icon: {
                        Image(systemName: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(issue.severity == .error ? .red : .orange)
                    }
                }
                .frame(minHeight: 180)
            }

            if dropped > 0 {
                Text("“Make a clean copy” removes \(dropped) problem row\(dropped == 1 ? "" : "s") (missing prompt/reply, empty, or duplicate), keeping \(cleanedCount).")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if dropped > 0 {
                    Button {
                        onClean(DatasetLinter.cleaned(rows))
                        dismiss()
                    } label: {
                        Label("Make a clean copy (\(cleanedCount) rows)", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent).tint(.brand)
                }
                Spacer()
                Button("Done") { dismiss() }
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 420)
    }
}
