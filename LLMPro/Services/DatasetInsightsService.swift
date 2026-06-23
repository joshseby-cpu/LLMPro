import Foundation

/// Read-only statistics over a loaded chat dataset split. Pure Swift — no IO, no
/// state — so it's cheap to recompute as the user edits rows. Powers the
/// "Insights" disclosure in DatasetDetailView: how big is this lesson, is it
/// balanced, are there obvious problems. Token counts are a rough estimate
/// (≈ chars / 4) — good enough to judge whether a row will blow past max-seq-len.
enum DatasetInsightsService {

    struct Insights {
        var rowCount: Int
        var messageCount: Int
        var estTokens: Int
        var roleCounts: [ChatMessageRow.Role: Int]
        var avgMessagesPerRow: Double
        var avgUserChars: Int
        var avgAssistantChars: Int
        var duplicateRows: Int
        var emptyMessages: Int
        /// (label, count) buckets of estimated tokens per row, for a histogram.
        var lengthBuckets: [(label: String, count: Int)]
        var longestRowTokens: Int
    }

    /// Rough token estimate for a string (English ≈ 4 chars/token).
    static func estTokens(_ s: String) -> Int { max(0, s.count / 4) }

    static func analyze(_ rows: [ChatRow]) -> Insights {
        var roleCounts: [ChatMessageRow.Role: Int] = [:]
        var messageCount = 0
        var totalTokens = 0
        var userChars = 0, userMsgs = 0
        var asstChars = 0, asstMsgs = 0
        var emptyMessages = 0
        var perRowTokens: [Int] = []

        for row in rows {
            var rowTokens = 0
            for m in row.messages {
                messageCount += 1
                roleCounts[m.role, default: 0] += 1
                let t = estTokens(m.content)
                rowTokens += t
                if m.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { emptyMessages += 1 }
                switch m.role {
                case .user:      userChars += m.content.count; userMsgs += 1
                case .assistant: asstChars += m.content.count; asstMsgs += 1
                case .system:    break
                }
            }
            totalTokens += rowTokens
            perRowTokens.append(rowTokens)
        }

        // Duplicate rows = identical (role, content) message sequences.
        var seen = Set<String>()
        var duplicates = 0
        for row in rows {
            let key = row.messages.map { "\($0.role.rawValue)\u{1}\($0.content)" }.joined(separator: "\u{2}")
            if seen.contains(key) { duplicates += 1 } else { seen.insert(key) }
        }

        let buckets = histogram(perRowTokens)

        return Insights(
            rowCount: rows.count,
            messageCount: messageCount,
            estTokens: totalTokens,
            roleCounts: roleCounts,
            avgMessagesPerRow: rows.isEmpty ? 0 : Double(messageCount) / Double(rows.count),
            avgUserChars: userMsgs == 0 ? 0 : userChars / userMsgs,
            avgAssistantChars: asstMsgs == 0 ? 0 : asstChars / asstMsgs,
            duplicateRows: duplicates,
            emptyMessages: emptyMessages,
            lengthBuckets: buckets,
            longestRowTokens: perRowTokens.max() ?? 0)
    }

    /// Fixed token buckets that cover the useful fine-tuning range.
    private static func histogram(_ perRowTokens: [Int]) -> [(label: String, count: Int)] {
        let edges = [128, 256, 512, 1024, 2048, 4096]
        var counts = Array(repeating: 0, count: edges.count + 1)
        for t in perRowTokens {
            var placed = false
            for (i, e) in edges.enumerated() where t <= e { counts[i] += 1; placed = true; break }
            if !placed { counts[edges.count] += 1 }
        }
        let labels = ["≤128", "≤256", "≤512", "≤1k", "≤2k", "≤4k", ">4k"]
        return Array(zip(labels, counts))
    }
}
