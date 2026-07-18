import Foundation

/// Pre-flight RAM checks for local models. Apple-Silicon MLX uses unified memory,
/// so a model's resident footprint ≈ its on-disk weight size; a model whose weights
/// exceed physical RAM can't load and the OS OOM-kills the process (the notorious
/// `exited with code 9` — SIGKILL). These helpers catch that BEFORE spawning, and
/// translate a SIGKILL exit into a plain-language "out of memory" message.
///
/// Quantized models report their already-compressed size here, so the same threshold
/// works for fp16 and 4-/8-bit alike (a 4-bit 70B ≈ 40 GB passes; a 224 GB fp16 120B
/// on a 128 GB Mac does not).
enum ModelFit {
    /// Fraction of physical RAM the weights may occupy before we call it unloadable.
    /// Leaves headroom for the KV cache, the OS, and the app itself.
    private static let safeFraction = 0.85

    /// Returns a user-facing error if `localModelPath` is a local model directory
    /// whose weights won't fit in RAM; nil if it fits, isn't a local dir, or the size
    /// can't be determined (e.g. a bare HF repo id that downloads on demand).
    static func tooLargeError(localModelPath: String) -> String? {
        let url = URL(fileURLWithPath: localModelPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue,
              let bytes = weightBytes(in: url), bytes > 0 else { return nil }
        let ram = Int64(ProcessInfo.processInfo.physicalMemory)
        guard ram > 0, Double(bytes) > Double(ram) * safeFraction else { return nil }
        let w = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        let r = ByteCountFormatter.string(fromByteCount: ram, countStyle: .memory)
        return "This model’s weights are \(w) — too large for this Mac’s \(r) of memory. "
             + "Pick a smaller model or a 4-bit version. (A large unquantized model has to be "
             + "quantized on a machine with more RAM first — it can’t be shrunk here, because "
             + "shrinking also has to load it fully into memory.)"
    }

    /// This Mac's total physical RAM in bytes.
    static var physicalRAM: Int64 { Int64(ProcessInfo.processInfo.physicalMemory) }

    /// Whether a model of `weightBytes` would fit in RAM (same 85%-of-physical rule
    /// as `tooLargeError`). Used to pre-warn on a search result before downloading.
    static func fits(weightBytes: Int64) -> Bool {
        let ram = physicalRAM
        return ram <= 0 || Double(weightBytes) <= Double(ram) * safeFraction
    }

    /// Map a non-zero subprocess exit code to a user-facing message, translating the
    /// OOM-killer's SIGKILL (9, or 128+9 = 137) into plain language.
    static func exitMessage(code: Int32, tool: String) -> String {
        if code == 9 || code == 137 {
            return "\(tool) ran out of memory and was stopped by the system — the model is "
                 + "likely too large for this Mac’s RAM. Try a smaller or more-quantized model."
        }
        return "\(tool) exited with code \(code)"
    }

    /// Total size of a model dir's weight files (`*.safetensors`), resolving HF-cache
    /// symlinks to their real blob sizes. Non-recursive — mlx-lm model dirs are flat.
    static func weightBytes(in dir: URL) -> Int64? {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return nil }
        var total: Int64 = 0
        for item in items where item.pathExtension == "safetensors" {
            let resolved = item.resolvingSymlinksInPath()
            if let sz = (try? resolved.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                total += Int64(sz)
            }
        }
        return total > 0 ? total : nil
    }
}
