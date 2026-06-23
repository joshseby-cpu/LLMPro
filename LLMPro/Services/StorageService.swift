import Foundation
import Observation

/// Scans where LLMPro's disk goes and offers safe cleanup. The app accumulates a
/// lot on disk — the HuggingFace model/dataset cache, per-job adapters, datasets,
/// GGUF exports, Practice runs, the Python venv + compiled llama.cpp. This gives
/// the user one place to SEE the breakdown and reclaim space from the
/// regenerable bits (exports, logs, the llama.cpp build) without risking their
/// real data (models / adapters / datasets are reveal-only here — they have
/// dedicated delete UIs elsewhere).
@MainActor
@Observable
final class StorageService {
    static let shared = StorageService()
    private init() {}

    struct Category: Identifiable {
        let id: String
        let name: String
        let icon: String
        let url: URL
        var bytes: Int64
        var itemCount: Int
        /// Safe to wipe (regenerable) — only set for caches/build output/logs.
        let clearable: Bool
        let hint: String
    }

    private(set) var categories: [Category] = []
    private(set) var totalBytes: Int64 = 0
    private(set) var freeBytes: Int64 = 0
    private(set) var scanning = false

    /// Per-category definitions. `clearable` is deliberately conservative — user
    /// data (models/adapters/datasets/practice) is reveal-only; only true caches
    /// and rebuildable artifacts can be wiped from here.
    private func definitions() -> [(String, String, String, URL, Bool, String)] {
        [
            ("hf", "Downloaded models & datasets", "arrow.down.circle", PathResolver.hfHome, false,
             "HuggingFace cache. Delete individual models from the Models tab."),
            ("models", "Custom models", "cube.box", PathResolver.modelsCustomDir, false,
             "Imported / stripped / abliterated / trained-and-saved models."),
            ("adapters", "Training runs", "graduationcap", PathResolver.adaptersDir, false,
             "LoRA adapters from Teach. Delete from Progress → Past lessons."),
            ("datasets", "Lessons (datasets)", "books.vertical", PathResolver.datasetsDir, false,
             "Your training data. Delete individual ones from the Lessons tab."),
            ("selfimprove", "Practice runs", "arrow.triangle.2.circlepath", PathResolver.selfImproveDir, false,
             "Practice run artifacts. Delete from Save & Use."),
            ("exports", "GGUF / fused exports", "square.and.arrow.up", PathResolver.exportsDir, true,
             "Exported files — safe to clear, you can re-export any time."),
            ("evals", "Eval data", "checkmark.seal", PathResolver.evalsDir, false,
             "Scored-test suites and run sidecars."),
            ("llamacpp-build", "llama.cpp build", "hammer", PathResolver.llamaCppDir.appendingPathComponent("build"), true,
             "Compiled GGUF tools — safe to clear, rebuilt on demand."),
            ("logs", "Logs", "doc.text", PathResolver.logsDir, true,
             "Diagnostic logs — safe to clear."),
            ("runtime", "Python runtime", "gearshape.2", PathResolver.venvDir, false,
             "The mlx-lm virtual environment. Needed to run anything."),
        ]
    }

    func scan() async {
        scanning = true
        defer { scanning = false }
        let defs = definitions().map { ($0.0, $0.3) }
        let appSupport = PathResolver.appSupport
        let measured = await Task.detached(priority: .utility) { () -> ([String: (Int64, Int)], Int64) in
            var out: [String: (Int64, Int)] = [:]
            for (id, url) in defs { out[id] = Self.measure(url) }
            let free = Self.freeSpace(near: appSupport)
            return (out, free)
        }.value
        categories = definitions().map { def in
            let (bytes, count) = measured.0[def.0] ?? (0, 0)
            return Category(id: def.0, name: def.1, icon: def.2, url: def.3,
                            bytes: bytes, itemCount: count, clearable: def.4, hint: def.5)
        }
        totalBytes = categories.reduce(0) { $0 + $1.bytes }
        freeBytes = measured.1
    }

    /// Delete the CONTENTS of a clearable category (keep the folder itself).
    func clear(_ category: Category) async {
        guard category.clearable else { return }
        let url = category.url
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { return }
            for entry in entries { try? fm.removeItem(at: entry) }
        }.value
        await scan()
    }

    // MARK: - Off-main measurement (DirectoryEnumerator is illegal from async contexts)

    private nonisolated static func measure(_ url: URL) -> (Int64, Int) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return (0, 0) }
        // Top-level item count (models/runs/etc.), full recursive byte total.
        let topLevel = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil))?.count ?? 0
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return (0, topLevel) }
        var total: Int64 = 0
        for case let f as URL in e {
            if let s = try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize { total += Int64(s) }
        }
        return (total, topLevel)
    }

    private nonisolated static func freeSpace(near url: URL) -> Int64 {
        let vals = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int64(vals?.volumeAvailableCapacityForImportantUsage ?? 0)
    }
}
