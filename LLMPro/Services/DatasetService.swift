import Foundation

struct DatasetPreview {
    let schema: DatasetSchema
    let trainRows: Int
    let validRows: Int
    let testRows: Int
    let firstRows: [String]
}

enum DatasetService {

    /// Inspect a source URL (a .jsonl file OR a directory) and split into a normalized dataset.
    /// Writes train.jsonl / valid.jsonl / test.jsonl into the destination directory.
    static func ingest(source: URL, into destination: URL, name: String) throws -> DatasetRecord {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        if source.hasDirectoryPath {
            // Copy any of train/valid/test.jsonl that exist.
            for name in ["train.jsonl", "valid.jsonl", "test.jsonl"] {
                let src = source.appendingPathComponent(name)
                if fm.fileExists(atPath: src.path) {
                    let dst = destination.appendingPathComponent(name)
                    try? fm.removeItem(at: dst)
                    try fm.copyItem(at: src, to: dst)
                }
            }
        } else if source.pathExtension.lowercased() == "jsonl" {
            // Single file → 90/5/5 split.
            let lines = try String(contentsOf: source, encoding: .utf8)
                .split(whereSeparator: \.isNewline)
                .map(String.init)
            let total = lines.count
            // 90/5/5 split that keeps each of train/valid/test non-empty when total >= 3.
            // The naive cuts steal the test split's only row on small files (e.g. total=10
            // → test empty), so reserve at least one row for valid and one for test.
            let trainCut: Int
            let validCut: Int
            if total >= 3 {
                trainCut = min(max(1, Int(Double(total) * 0.9)), total - 2)
                validCut = min(max(trainCut + 1, Int(Double(total) * 0.95)), total - 1)
            } else {
                // Too few rows to give all three splits a row: put everything in train.
                trainCut = total
                validCut = total
            }
            try lines[..<trainCut].joined(separator: "\n").write(to: destination.appendingPathComponent("train.jsonl"), atomically: true, encoding: .utf8)
            try lines[trainCut..<validCut].joined(separator: "\n").write(to: destination.appendingPathComponent("valid.jsonl"), atomically: true, encoding: .utf8)
            try lines[validCut..<total].joined(separator: "\n").write(to: destination.appendingPathComponent("test.jsonl"), atomically: true, encoding: .utf8)
        } else {
            throw NSError(domain: "DatasetService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported source: \(source.lastPathComponent)"])
        }

        let preview = try inspect(directory: destination)
        let ds = DatasetRecord(name: name, schema: preview.schema,
                               trainRows: preview.trainRows, validRows: preview.validRows, testRows: preview.testRows)
        return ds
    }

    static func inspect(directory: URL) throws -> DatasetPreview {
        let train = directory.appendingPathComponent("train.jsonl")
        let valid = directory.appendingPathComponent("valid.jsonl")
        let test  = directory.appendingPathComponent("test.jsonl")
        let trainCount = countLines(train)
        let validCount = countLines(valid)
        let testCount  = countLines(test)
        let firstLines = (try? String(contentsOf: train, encoding: .utf8))?.split(whereSeparator: \.isNewline).prefix(100).map(String.init) ?? []
        let schema = classify(lines: firstLines)
        return DatasetPreview(schema: schema, trainRows: trainCount, validRows: validCount, testRows: testCount, firstRows: Array(firstLines.prefix(20)))
    }

    private static func countLines(_ url: URL) -> Int {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return s.split(whereSeparator: \.isNewline).count
    }

    static func classify(lines: [String]) -> DatasetSchema {
        var votes: [DatasetSchema: Int] = [:]
        for raw in lines.prefix(100) {
            guard let data = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if obj["messages"] != nil { votes[.chat, default: 0] += 1 }
            else if obj["tools"] != nil { votes[.tools, default: 0] += 1 }
            // Preference rows ({prompt, chosen, rejected}) also carry a `prompt`, so
            // they must be tested BEFORE the completions check to avoid being
            // misclassified as prompt/completion.
            else if obj["prompt"] != nil && obj["chosen"] != nil && obj["rejected"] != nil { votes[.preference, default: 0] += 1 }
            else if obj["prompt"] != nil && obj["completion"] != nil { votes[.completions, default: 0] += 1 }
            else if obj["text"] != nil { votes[.text, default: 0] += 1 }
        }
        return votes.max(by: { $0.value < $1.value })?.key ?? .unknown
    }
}
