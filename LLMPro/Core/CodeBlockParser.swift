import Foundation

/// Splits assistant text into prose and fenced code blocks so the UI can render
/// each code block in a monospaced panel with its own Copy button. A small,
/// unit-testable fence scanner — handles ``` and ```lang fences, tolerates an
/// unterminated final fence (still streaming).
enum CodeBlockParser {
    enum Segment: Equatable {
        case text(String)
        case code(language: String?, code: String)
    }

    static func parse(_ input: String) -> [Segment] {
        var segments: [Segment] = []
        let lines = input.components(separatedBy: "\n")
        var i = 0
        var textBuffer: [String] = []

        func flushText() {
            if !textBuffer.isEmpty {
                let joined = textBuffer.joined(separator: "\n")
                if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    segments.append(.text(joined))
                }
                textBuffer.removeAll()
            }
        }

        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("```") {
                flushText()
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count, !lines[i].hasPrefix("```") {
                    codeLines.append(lines[i]); i += 1
                }
                // Skip the closing fence if present (absent while still streaming).
                if i < lines.count { i += 1 }
                segments.append(.code(language: lang.isEmpty ? nil : lang, code: codeLines.joined(separator: "\n")))
            } else {
                textBuffer.append(line)
                i += 1
            }
        }
        flushText()
        return segments
    }
}
