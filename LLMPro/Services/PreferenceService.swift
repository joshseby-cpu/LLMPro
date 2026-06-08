import Foundation
import SwiftData

/// Storage layer for the DPO "preference loop" — a dataset of
/// `{prompt, chosen, rejected}` pairs (plus an optional `system`) that a
/// preference-optimization trainer (DPO/ORPO via mlx-lm) consumes via
/// `--data <dir>` over `train.jsonl` / `valid.jsonl`.
///
/// Engine-agnostic on purpose: this enum only reads/writes the on-disk JSONL and
/// the backing `DatasetRecord`. It does not know how the pairs get trained.
///
/// Stateless static helpers, mirroring `DatasetService`. Every method touching
/// SwiftData is `@MainActor`; the `DatasetRecord` is always passed in (already
/// fetched on the main actor) rather than captured across an actor hop.
@MainActor
enum PreferenceService {

    // MARK: - Create / locate the active set

    /// Create a fresh preference dataset: a `datasets/<uuid>/` dir with empty
    /// `train.jsonl` + `valid.jsonl`, an inserted-and-saved `DatasetRecord`.
    static func createPreferenceSet(name: String, context: ModelContext) -> DatasetRecord {
        let id = UUID()
        let dir = PathResolver.datasetDir(for: id)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for file in ["train.jsonl", "valid.jsonl"] {
                let url = dir.appendingPathComponent(file)
                if !fm.fileExists(atPath: url.path) {
                    fm.createFile(atPath: url.path, contents: Data())
                }
            }
        } catch {
            Log.error("createPreferenceSet: could not create \(dir.lastPathComponent)", .dataset, error: error)
        }

        let record = DatasetRecord(id: id, name: name, schema: .preference,
                                   trainRows: 0, validRows: 0, testRows: 0,
                                   notes: "Preference pairs (chosen/rejected) for DPO.")
        context.insert(record)
        try? context.save()
        return record
    }

    /// The most-recent `.preference` dataset, creating a default one if none exist.
    static func findOrCreateActivePreferenceSet(context: ModelContext) -> DatasetRecord {
        let preference = DatasetSchema.preference.rawValue
        var descriptor = FetchDescriptor<DatasetRecord>(
            predicate: #Predicate { $0.schemaRaw == preference },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 1
        if let existing = (try? context.fetch(descriptor))?.first {
            return existing
        }
        return createPreferenceSet(name: "My preferences", context: context)
    }

    // MARK: - Append a pair

    /// Append one `{prompt, chosen, rejected[, system]}` line to the dataset's
    /// `train.jsonl`, atomically. `system` is included only when non-nil and
    /// non-empty. De-dups: if an identical encoded line already exists, this is a
    /// no-op (no row-count bump, no save).
    static func appendPair(prompt: String, chosen: String, rejected: String,
                           system: String?, to dataset: DatasetRecord, context: ModelContext) {
        let trainFile = dataset.trainFile
        let dir = dataset.directoryURL
        let fm = FileManager.default

        let normalizedSystem = system.flatMap { $0.isEmpty ? nil : $0 }
        let payload = PreferenceWireRow(prompt: prompt, chosen: chosen,
                                        rejected: rejected, system: normalizedSystem)

        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        guard let lineData = try? encoder.encode(payload),
              let line = String(data: lineData, encoding: .utf8) else {
            Log.error("appendPair: could not encode preference pair", .dataset)
            return
        }

        // Read existing rows (skip blanks) for de-dup.
        let existingText = (try? String(contentsOf: trainFile, encoding: .utf8)) ?? ""
        let existingLines = existingText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if existingLines.contains(line) { return }

        var newLines = existingLines
        newLines.append(line)
        let output = newLines.joined(separator: "\n") + "\n"

        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let tmp = trainFile.appendingPathExtension("tmp")
            try? fm.removeItem(at: tmp)
            try output.write(to: tmp, atomically: false, encoding: .utf8)
            if fm.fileExists(atPath: trainFile.path) {
                _ = try fm.replaceItemAt(trainFile, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: trainFile)
            }
        } catch {
            Log.error("appendPair: could not write \(trainFile.lastPathComponent)", .dataset, error: error)
            return
        }

        dataset.trainRows = newLines.count
        try? context.save()
    }

    // MARK: - Split for training

    /// DPO needs a non-empty validation set. If `valid.jsonl` is empty/absent but
    /// `train.jsonl` has at least a few rows, carve ~10% (≥1, capped below the train
    /// count) of the train rows out into `valid.jsonl` so `--data <dir>` sees both.
    /// Safe to call before every training run: a no-op once a validation set exists.
    static func splitForTraining(dataset: DatasetRecord) {
        let trainFile = dataset.trainFile
        let validFile = dataset.validFile
        let fm = FileManager.default

        let validLines = nonEmptyLines(of: validFile)
        guard validLines.isEmpty else { return }   // already split

        let trainLines = nonEmptyLines(of: trainFile)
        guard trainLines.count >= 3 else { return } // too few to spare a holdout

        // ~10%, at least 1, but always leave at least 1 row in train.
        let validCount = min(max(1, trainLines.count / 10), trainLines.count - 1)
        let splitAt = trainLines.count - validCount
        let keptTrain = Array(trainLines[..<splitAt])
        let movedValid = Array(trainLines[splitAt...])

        do {
            try fm.createDirectory(at: dataset.directoryURL, withIntermediateDirectories: true)
            try writeLines(keptTrain, to: trainFile)
            try writeLines(movedValid, to: validFile)
        } catch {
            Log.error("splitForTraining: could not write split for \(dataset.name)", .dataset, error: error)
            return
        }
    }

    // MARK: - Helpers

    /// One preference example. `system` is `String?` so `JSONEncoder` omits the key
    /// entirely when it is nil (the codebase relies on this default behavior).
    private struct PreferenceWireRow: Encodable {
        var prompt: String
        var chosen: String
        var rejected: String
        var system: String?
    }

    private static func nonEmptyLines(of url: URL) -> [String] {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Atomic write of newline-joined lines (temp file + replace), mirroring the
    /// `DatasetEditorService` save pattern.
    private static func writeLines(_ lines: [String], to file: URL) throws {
        let fm = FileManager.default
        let output = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        let tmp = file.appendingPathExtension("tmp")
        try? fm.removeItem(at: tmp)
        try output.write(to: tmp, atomically: false, encoding: .utf8)
        if fm.fileExists(atPath: file.path) {
            _ = try fm.replaceItemAt(file, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: file)
        }
    }
}
