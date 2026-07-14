import SwiftUI

/// Read-only "Insights" panel for a dataset split — shown as a DisclosureGroup in
/// DatasetDetailView. Surfaces the numbers that decide whether a lesson is good
/// to train on: size, role balance, length distribution, duplicates. Recomputes
/// from the in-memory rows, so it tracks edits without re-reading the file.
struct DatasetInsightsView: View {
    let rows: [ChatRow]

    // Cached analysis — analyze() is O(total text) (it builds full-text dedup
    // keys), so computing it in `body` froze the UI on big datasets. Recomputed
    // off the main actor whenever the rows change.
    @State private var cached: DatasetInsightsService.Insights?

    var body: some View {
        Group {
            if let ins = cached {
                content(ins)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Analyzing…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: rows) {
            let snapshot = rows
            cached = await Task.detached(priority: .userInitiated) {
                DatasetInsightsService.analyze(snapshot)
            }.value
        }
    }

    private func content(_ ins: DatasetInsightsService.Insights) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 20) {
                stat("Rows", "\(ins.rowCount)")
                stat("Messages", "\(ins.messageCount)")
                stat("Est. tokens", compact(ins.estTokens))
                stat("Avg msgs/row", String(format: "%.1f", ins.avgMessagesPerRow))
            }
            HStack(spacing: 20) {
                stat("Avg user", "\(ins.avgUserChars) ch")
                stat("Avg reply", "\(ins.avgAssistantChars) ch")
                stat("Longest", "\(ins.longestRowTokens) tok")
                stat("Duplicates", "\(ins.duplicateRows)", warn: ins.duplicateRows > 0)
            }
            roleBalance(ins)
            lengthHistogram(ins)
            if ins.emptyMessages > 0 {
                Label("\(ins.emptyMessages) empty message(s) — run Check to clean.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stat(_ label: String, _ value: String, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.monospacedDigit()).foregroundStyle(warn ? Color.orange : .primary)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func roleBalance(_ ins: DatasetInsightsService.Insights) -> some View {
        let order: [ChatMessageRow.Role] = [.system, .user, .assistant]
        let total = max(1, ins.messageCount)
        return VStack(alignment: .leading, spacing: 4) {
            Text("Role balance").font(.caption).foregroundStyle(.secondary)
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(order, id: \.self) { role in
                        let c = ins.roleCounts[role] ?? 0
                        if c > 0 {
                            Rectangle().fill(roleColor(role))
                                .frame(width: max(2, geo.size.width * CGFloat(Double(c) / Double(total))))
                                .help("\(role.displayName): \(c)")
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .frame(height: 10)
            HStack(spacing: 12) {
                ForEach(order, id: \.self) { role in
                    Label("\(role.displayName) \(ins.roleCounts[role] ?? 0)", systemImage: "circle.fill")
                        .labelStyle(.titleAndIcon).font(.caption2)
                        .foregroundStyle(roleColor(role))
                }
            }
        }
    }

    private func lengthHistogram(_ ins: DatasetInsightsService.Insights) -> some View {
        let maxC = max(1, ins.lengthBuckets.map(\.count).max() ?? 1)
        return VStack(alignment: .leading, spacing: 4) {
            Text("Row length (est. tokens)").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(ins.lengthBuckets, id: \.label) { bucket in
                    VStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.brand.opacity(0.8))
                            .frame(width: 22, height: max(2, 44 * CGFloat(Double(bucket.count) / Double(maxC))))
                        Text(bucket.label).font(.system(size: 8)).foregroundStyle(.secondary)
                    }
                    .help("\(bucket.count) rows")
                }
            }
        }
    }

    private func roleColor(_ role: ChatMessageRow.Role) -> Color {
        switch role {
        case .system:    return .gray
        case .user:      return .blue
        case .assistant: return .brand
        }
    }

    private func compact(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }
}
