import SwiftUI
import AppKit

// Lightweight, dependency-free syntax highlighter. Regex-based, multi-language,
// produces an `AttributedString` (and an `NSAttributedString` for the editor's
// NSTextView). Used by the Code tab's editor pane AND the chat transcript so the
// model's code / diffs render as readable colored code instead of raw text/JSON.
//
// It's intentionally approximate (a real grammar is overkill here): one combined
// pass claims comments + strings position-ordered, then numbers, keywords, and
// capitalized type names fill the gaps. Good enough to read by.

enum CodeLanguage: String, Sendable {
    case swift, cSharp, python, javascript, typescript, json, html, css, xml, shell, ruby, go, rust, java, kotlin, sql, markdown, plain

    static func from(path: String) -> CodeLanguage {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return .swift
        case "cs": return .cSharp
        case "py": return .python
        case "js", "jsx", "mjs", "cjs": return .javascript
        case "ts", "tsx": return .typescript
        case "json": return .json
        case "html", "htm", "razor", "cshtml", "vue", "svelte": return .html
        case "css", "scss", "sass", "less": return .css
        case "xml", "csproj", "xaml", "plist", "storyboard": return .xml
        case "sh", "bash", "zsh": return .shell
        case "rb": return .ruby
        case "go": return .go
        case "rs": return .rust
        case "java": return .java
        case "kt", "kts": return .kotlin
        case "sql": return .sql
        case "md", "markdown": return .markdown
        default: return .plain
        }
    }

    static func from(fence: String) -> CodeLanguage {
        switch fence.lowercased() {
        case "swift": return .swift
        case "csharp", "cs", "c#": return .cSharp
        case "python", "py": return .python
        case "javascript", "js": return .javascript
        case "typescript", "ts": return .typescript
        case "json": return .json
        case "html", "razor": return .html
        case "css", "scss": return .css
        case "xml": return .xml
        case "bash", "sh", "shell", "zsh": return .shell
        case "go": return .go
        case "rust", "rs": return .rust
        case "java": return .java
        case "kotlin", "kt": return .kotlin
        case "sql": return .sql
        default: return .plain
        }
    }

    var commentRegex: String {
        switch self {
        case .python, .shell, .ruby:
            return "#[^\\n]*"
        case .sql:
            return "--[^\\n]*|/\\*[\\s\\S]*?\\*/"
        case .html, .xml:
            return "<!--[\\s\\S]*?-->"
        case .css, .json, .markdown, .plain:
            return "/\\*[\\s\\S]*?\\*/"
        default: // c-like
            return "//[^\\n]*|/\\*[\\s\\S]*?\\*/"
        }
    }

    var highlightsTypes: Bool {
        switch self { case .json, .shell, .plain, .markdown, .css: return false; default: return true }
    }

    var keywords: [String] {
        switch self {
        case .swift:
            return ["func","let","var","if","else","guard","return","for","in","while","switch","case","default","struct","class","enum","protocol","extension","import","self","init","deinit","static","private","public","internal","fileprivate","open","final","lazy","weak","unowned","throws","throw","try","catch","do","async","await","actor","nil","true","false","some","any","where","as","is","defer","repeat","break","continue","associatedtype","typealias","subscript","mutating","override","convenience","required"]
        case .cSharp:
            return ["using","namespace","class","struct","interface","enum","public","private","protected","internal","static","void","var","new","return","if","else","for","foreach","while","switch","case","default","break","continue","this","base","null","true","false","async","await","try","catch","finally","throw","get","set","override","virtual","abstract","sealed","readonly","const","string","int","bool","double","decimal","long","float","object","record","partial","in","out","ref","is","as","typeof","nameof"]
        case .python:
            return ["def","class","return","if","elif","else","for","while","in","import","from","as","with","try","except","finally","raise","pass","break","continue","lambda","yield","global","nonlocal","async","await","None","True","False","and","or","not","is","self","print","del","assert"]
        case .javascript, .typescript:
            return ["function","const","let","var","return","if","else","for","while","switch","case","default","break","continue","class","extends","new","this","super","null","undefined","true","false","async","await","try","catch","finally","throw","import","export","from","default","typeof","instanceof","in","of","yield","interface","type","enum","public","private","readonly","implements","namespace"]
        case .go:
            return ["package","import","func","var","const","type","struct","interface","map","chan","go","defer","return","if","else","for","range","switch","case","default","break","continue","nil","true","false","make","new","string","int","bool","error"]
        case .rust:
            return ["fn","let","mut","const","struct","enum","trait","impl","pub","use","mod","return","if","else","for","while","loop","match","in","self","Self","async","await","move","ref","where","as","dyn","true","false","Some","None","Ok","Err","match"]
        case .java, .kotlin:
            return ["class","interface","enum","public","private","protected","static","final","void","new","return","if","else","for","while","switch","case","default","break","continue","this","super","null","true","false","try","catch","finally","throw","throws","import","package","extends","implements","abstract","val","var","fun","when","object","data","override","suspend"]
        case .ruby:
            return ["def","class","module","end","return","if","elsif","else","unless","while","until","for","in","do","begin","rescue","ensure","raise","yield","nil","true","false","self","require","attr_accessor","puts"]
        case .sql:
            return ["SELECT","FROM","WHERE","INSERT","INTO","VALUES","UPDATE","SET","DELETE","CREATE","TABLE","ALTER","DROP","JOIN","LEFT","RIGHT","INNER","OUTER","ON","GROUP","BY","ORDER","HAVING","LIMIT","AND","OR","NOT","NULL","AS","DISTINCT","COUNT","SUM","AVG","INDEX","PRIMARY","KEY","FOREIGN","REFERENCES"]
        default:
            return []
        }
    }
}

enum SyntaxHighlighter {
    enum Palette {
        static let keyword = NSColor(srgbRed: 0.78, green: 0.47, blue: 0.87, alpha: 1)  // purple
        static let string  = NSColor(srgbRed: 0.55, green: 0.78, blue: 0.40, alpha: 1)  // green
        static let comment = NSColor(srgbRed: 0.48, green: 0.53, blue: 0.58, alpha: 1)  // gray
        static let number  = NSColor(srgbRed: 0.85, green: 0.62, blue: 0.40, alpha: 1)  // orange
        static let type    = NSColor(srgbRed: 0.34, green: 0.71, blue: 0.76, alpha: 1)  // teal
        static let plain   = NSColor.labelColor
    }

    private static let stringAlt =
        "\"(?:\\\\.|[^\"\\\\])*\"|'(?:\\\\.|[^'\\\\])*'|`(?:\\\\.|[^`\\\\])*`"
    private static let numberPattern = "\\b\\d[\\d_]*(?:\\.\\d+)?\\b"
    private static let typePattern   = "\\b[A-Z][A-Za-z0-9_]+\\b"

    /// NSAttributedString for the editor's NSTextView.
    static func nsAttributed(_ code: String, language: CodeLanguage, fontSize: CGFloat = 12.5) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let result = NSMutableAttributedString(
            string: code, attributes: [.font: font, .foregroundColor: Palette.plain])
        guard language != .plain || !code.isEmpty else { return result }
        let ns = code as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var claimed = IndexSet()

        func isClaimed(_ r: NSRange) -> Bool {
            r.location != NSNotFound && !claimed.intersection(IndexSet(integersIn: r.location..<(r.location + r.length))).isEmpty
        }
        func paint(_ pattern: String, _ color: NSColor) {
            guard let rx = try? NSRegularExpression(pattern: pattern) else { return }
            rx.enumerateMatches(in: code, range: whole) { m, _, _ in
                guard let r = m?.range, r.location != NSNotFound, !isClaimed(r) else { return }
                result.addAttribute(.foregroundColor, value: color, range: r)
                claimed.insert(integersIn: r.location..<(r.location + r.length))
            }
        }

        // Pass 1: comments + strings, position-ordered so // inside a string and
        // " inside a comment resolve correctly.
        if let rx = try? NSRegularExpression(pattern: "(\(language.commentRegex))|(\(stringAlt))") {
            rx.enumerateMatches(in: code, range: whole) { m, _, _ in
                guard let m else { return }
                if m.range(at: 1).location != NSNotFound {
                    result.addAttribute(.foregroundColor, value: Palette.comment, range: m.range(at: 1))
                    claimed.insert(integersIn: m.range(at: 1).location..<(m.range(at: 1).location + m.range(at: 1).length))
                } else if m.range(at: 2).location != NSNotFound {
                    result.addAttribute(.foregroundColor, value: Palette.string, range: m.range(at: 2))
                    claimed.insert(integersIn: m.range(at: 2).location..<(m.range(at: 2).location + m.range(at: 2).length))
                }
            }
        }
        paint(numberPattern, Palette.number)
        if !language.keywords.isEmpty {
            let kw = language.keywords.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
            paint("\\b(?:\(kw))\\b", Palette.keyword)
        }
        if language.highlightsTypes { paint(typePattern, Palette.type) }
        return result
    }

    /// AttributedString for SwiftUI `Text` (transcript code / diffs).
    static func attributed(_ code: String, language: CodeLanguage, fontSize: CGFloat = 11.5) -> AttributedString {
        AttributedString(nsAttributed(code, language: language, fontSize: fontSize))
    }
}
