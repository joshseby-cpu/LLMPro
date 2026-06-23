import Foundation

/// Validity checks over a chat dataset split, plus a non-destructive "clean" that
/// drops the rows that would hurt a fine-tune. mlx-lm trains on the assistant
/// turns, so the things that matter: every row needs a user prompt AND an
/// assistant reply, no empty content, and duplicates waste steps / encourage
/// memorization. Pure Swift — `lint` reports, `cleaned` returns a filtered copy
/// the caller can preview and save (the original file is untouched until they do).
enum DatasetLinter {

    enum Severity: String { case error, warning }

    struct Issue: Identifiable {
        let id = UUID()
        let rowIndex: Int          // -1 = dataset-level
        let severity: Severity
        let message: String
    }

    /// Token ceiling above which a row is flagged (it'll likely be truncated).
    static let longRowTokenWarn = 4096

    static func lint(_ rows: [ChatRow]) -> [Issue] {
        var issues: [Issue] = []
        var seen = Set<String>()

        for (i, row) in rows.enumerated() {
            let roles = row.messages.map { $0.role }
            if !roles.contains(.user) {
                issues.append(Issue(rowIndex: i, severity: .error, message: "Row \(i + 1): no user prompt."))
            }
            if !roles.contains(.assistant) {
                issues.append(Issue(rowIndex: i, severity: .error, message: "Row \(i + 1): no assistant reply — nothing to learn from."))
            }
            if row.messages.contains(where: { $0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                issues.append(Issue(rowIndex: i, severity: .error, message: "Row \(i + 1): has an empty message."))
            }
            if row.messages.last?.role == .user {
                issues.append(Issue(rowIndex: i, severity: .warning, message: "Row \(i + 1): ends on a user turn (no final assistant reply)."))
            }
            // System message must be first if present.
            if let firstSystem = roles.firstIndex(of: .system), firstSystem != 0 {
                issues.append(Issue(rowIndex: i, severity: .warning, message: "Row \(i + 1): system message isn't first."))
            }
            let tokens = row.messages.reduce(0) { $0 + DatasetInsightsService.estTokens($1.content) }
            if tokens > longRowTokenWarn {
                issues.append(Issue(rowIndex: i, severity: .warning, message: "Row \(i + 1): very long (~\(tokens) tokens) — may be truncated."))
            }
            let key = dedupKey(row)
            if seen.contains(key) {
                issues.append(Issue(rowIndex: i, severity: .warning, message: "Row \(i + 1): duplicate of an earlier row."))
            } else {
                seen.insert(key)
            }
        }
        return issues
    }

    /// A filtered copy: drop rows missing a user or assistant turn, rows with an
    /// empty message, and later duplicates. Order preserved. Non-destructive.
    static func cleaned(_ rows: [ChatRow]) -> [ChatRow] {
        var seen = Set<String>()
        var out: [ChatRow] = []
        for row in rows {
            let roles = row.messages.map { $0.role }
            guard roles.contains(.user), roles.contains(.assistant) else { continue }
            guard !row.messages.contains(where: { $0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { continue }
            let key = dedupKey(row)
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(row)
        }
        return out
    }

    private static func dedupKey(_ row: ChatRow) -> String {
        row.messages.map { "\($0.role.rawValue)\u{1}\($0.content)" }.joined(separator: "\u{2}")
    }
}
