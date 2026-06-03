import Foundation

/// Pure-Swift reader for the `.safetensors` on-disk format — **no model load, no
/// Python, no tensor data read**. This is the engine behind the Inspect tab's
/// weights view, and the canonical example of the Swift-first rule (see
/// `docs/CONVENTIONS.md`): enumerating a model's structure is just file IO + JSON,
/// so it stays in Swift; only deep per-value statistics (which need to dequantize
/// mlx-quantized tensors) reach for the Python/MLX sidecar.
///
/// Format (verified on this machine's cached mlx-community bf16 models):
/// ```
/// [ 8 bytes: u64 little-endian header length N ]
/// [ N bytes: UTF-8 JSON  {name: {dtype, shape, data_offsets:[start,end]}, "__metadata__": {...}} ]
/// [ raw tensor bytes … (NEVER read here) ]
/// ```
/// We read only the first `8 + N` bytes of each shard, so inspecting a 55 GB model
/// touches well under 1 MB total.
enum SafetensorsHeader {

    /// One tensor's metadata, straight from the header (no values).
    struct TensorEntry: Identifiable, Hashable, Sendable {
        let name: String
        let dtype: String          // "BF16", "F16", "F32", "U32" (mlx-quantized packing), …
        let shape: [Int]
        let byteSize: Int          // data_offsets[1] - data_offsets[0]

        var id: String { name }
        /// Number of elements = product of every dimension (handles 1-D norms,
        /// 3-D conv/expert-stacked weights, etc — not just 2-D matrices).
        var paramCount: Int { shape.reduce(1, *) }
        var shapeText: String { "[" + shape.map(String.init).joined(separator: ", ") + "]" }
    }

    enum HeaderError: LocalizedError {
        case tooSmall, badLength, badJSON
        var errorDescription: String? {
            switch self {
            case .tooSmall: "File is too small to be a safetensors shard."
            case .badLength: "Safetensors header length is invalid."
            case .badJSON:  "Safetensors header JSON could not be parsed."
            }
        }
    }

    /// Parse a single shard's header. Reads only `8 + headerLength` bytes via a
    /// file handle, so the multi-gigabyte tensor blob is never paged in.
    static func parse(shard url: URL) throws -> (entries: [TensorEntry], metadata: [String: String]) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        guard let lenData = try handle.read(upToCount: 8), lenData.count == 8 else {
            throw HeaderError.tooSmall
        }
        let headerLen = lenData.withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
        // Guard against a garbage length (e.g. a non-safetensors file): cap at 256 MB.
        guard headerLen > 0, headerLen < 256 * 1024 * 1024 else { throw HeaderError.badLength }

        guard let jsonData = try handle.read(upToCount: Int(headerLen)),
              jsonData.count == Int(headerLen) else {
            throw HeaderError.badLength
        }
        guard let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw HeaderError.badJSON
        }

        var entries: [TensorEntry] = []
        var metadata: [String: String] = [:]
        for (key, value) in root {
            if key == "__metadata__" {
                if let m = value as? [String: Any] {
                    for (mk, mv) in m { metadata[mk] = String(describing: mv) }
                }
                continue
            }
            guard let obj = value as? [String: Any],
                  let dtype = obj["dtype"] as? String,
                  let shapeRaw = obj["shape"] as? [Any]
            else { continue }
            let shape = shapeRaw.compactMap { ($0 as? NSNumber)?.intValue }
            var byteSize = 0
            if let off = obj["data_offsets"] as? [Any], off.count == 2,
               let s = (off[0] as? NSNumber)?.intValue, let e = (off[1] as? NSNumber)?.intValue {
                byteSize = max(0, e - s)
            }
            entries.append(TensorEntry(name: key, dtype: dtype, shape: shape, byteSize: byteSize))
        }
        entries.sort { $0.name < $1.name }
        return (entries, metadata)
    }

    /// Enumerate ALL tensors of a model directory (snapshot folder), transparently
    /// handling the three on-disk shapes we've seen:
    ///   • multi-shard with `model.safetensors.index.json` (weight_map → shard)
    ///   • a single `model.safetensors`
    ///   • any other `*.safetensors` files present (fallback union)
    /// Deduplicates by tensor name (a tensor lives in exactly one shard).
    static func enumerateModel(directory: URL) throws -> [TensorEntry] {
        let fm = FileManager.default
        let indexURL = directory.appendingPathComponent("model.safetensors.index.json")

        // Preferred: the index tells us exactly which shards to read.
        if let indexData = try? Data(contentsOf: indexURL),
           let index = try? JSONSerialization.jsonObject(with: indexData) as? [String: Any],
           let weightMap = index["weight_map"] as? [String: String] {
            let shardNames = Set(weightMap.values)
            var byName: [String: TensorEntry] = [:]
            for shardName in shardNames.sorted() {
                let shardURL = directory.appendingPathComponent(shardName)
                guard fm.fileExists(atPath: shardURL.path) else { continue }
                let (entries, _) = try parse(shard: shardURL)
                for e in entries { byName[e.name] = e }
            }
            if !byName.isEmpty { return byName.values.sorted { $0.name < $1.name } }
        }

        // Fallback: read every *.safetensors in the directory and union them.
        let contents = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let shards = contents.filter { $0.pathExtension == "safetensors" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !shards.isEmpty else { throw HeaderError.tooSmall }
        var byName: [String: TensorEntry] = [:]
        for shardURL in shards {
            if let (entries, _) = try? parse(shard: shardURL) {
                for e in entries { byName[e.name] = e }
            }
        }
        return byName.values.sorted { $0.name < $1.name }
    }
}
