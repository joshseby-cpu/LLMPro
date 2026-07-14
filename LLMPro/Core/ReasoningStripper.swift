import Foundation

/// Hides a reasoning model's chain-of-thought from user-facing output. Reasoning
/// models (Qwen3, DeepSeek-R1, etc.) emit a `<think>…</think>` block before the
/// real answer; some chat templates consume the opening tag and emit only the
/// closing `</think>`. We strip it everywhere the user reads generated prose
/// (chat replies, story chapters) so the thinking never pollutes the text,
/// summaries, rolling context, or exports. The Inspect → "Watch it think" tab is
/// the deliberate place to SEE reasoning; it uses a separate reasoning channel.
enum ReasoningStripper {
    private static let openTags = ["<think>", "<thinking>", "<reason>", "<reasoning>", "<reflection>"]
    private static let closeTags = ["</think>", "</thinking>", "</reason>", "</reasoning>", "</reflection>"]

    private static let pairRegex: NSRegularExpression = {
        // <think>…</think> (and variants), non-greedy, across newlines, any case.
        try! NSRegularExpression(
            pattern: "<(think|thinking|reason|reasoning|reflection)>.*?</\\1>",
            options: [.caseInsensitive, .dotMatchesLineSeparators])
    }()

    /// Returns `text` with reasoning removed. `streaming: true` also hides an
    /// unclosed opening tag (reasoning still in progress) so it doesn't flash
    /// before the answer arrives.
    static func visible(_ text: String, streaming: Bool = false) -> String {
        var s = text

        // 1. Remove complete <think>…</think> pairs anywhere.
        let full = NSRange(s.startIndex..., in: s)
        s = pairRegex.stringByReplacingMatches(in: s, range: full, withTemplate: "")

        // 2. A lone closing tag (the template ate the opening one) means everything
        //    before it is reasoning — keep only what follows the LAST close.
        var cut: String.Index?
        for tag in closeTags {
            if let r = s.range(of: tag, options: [.caseInsensitive, .backwards]) {
                if cut == nil || r.upperBound > cut! { cut = r.upperBound }
            }
        }
        if let cut { s = String(s[cut...]) }

        // 3. While streaming, an unclosed opening tag is reasoning-in-progress —
        //    hide from it to the end.
        if streaming {
            var start: String.Index?
            for tag in openTags {
                if let r = s.range(of: tag, options: .caseInsensitive) {
                    if start == nil || r.lowerBound < start! { start = r.lowerBound }
                }
            }
            if let start { s = String(s[..<start]) }
        }

        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
