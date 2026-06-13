import Foundation

struct HFModel: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let author: String?
    let downloads: Int?
    let likes: Int?
    let lastModified: String?
    let library_name: String?
    let pipeline_tag: String?
    let tags: [String]?

    var repoID: String { id }
    var shortName: String { id.split(separator: "/").last.map(String.init) ?? id }
    var isMLXCommunity: Bool { author == "mlx-community" || id.hasPrefix("mlx-community/") }
}

struct HFFile: Sendable, Codable, Hashable {
    let rfilename: String
    let size: Int64?
}

// MARK: - Dataset types

struct HFDataset: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let author: String?
    let downloads: Int?
    let likes: Int?
    let lastModified: String?
    let tags: [String]?
    let cardData: HFDatasetCardData?

    var repoID: String { id }
    var shortName: String { id.split(separator: "/").last.map(String.init) ?? id }
}

struct HFDatasetCardData: Sendable, Codable, Hashable {
    let license: String?
    let task_categories: [String]?
    let language: [String]?
    let size_categories: [String]?
}

struct HFDatasetDetail: Sendable, Codable {
    let id: String
    let siblings: [HFFile]?
    let tags: [String]?
    let downloads: Int?
    let cardData: HFDatasetCardData?
}

/// Raw response from datasets-server.huggingface.co/rows.
/// Rows are returned with the structure {row_idx, row, truncated_cells} — we keep
/// only the `row` dict (column-name → JSON value).
struct HFDatasetRows: Sendable, Codable {
    struct Feature: Sendable, Codable, Hashable {
        let name: String
        let type: HFDatasetFeatureType?
    }
    struct RowWrapper: Sendable, Codable {
        let row_idx: Int
        let row: HFRowValue
    }
    let features: [Feature]?
    let rows: [RowWrapper]?
    let num_rows_total: Int?
}

struct HFDatasetFeatureType: Sendable, Codable, Hashable {
    let dtype: String?
}

/// `row` values from the HF datasets-server are arbitrary JSON; box them
/// behind a wrapper so we can keep Codable conformance.
struct HFRowValue: Sendable, Codable {
    let dict: [String: AnyCodable]
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        dict = try container.decode([String: AnyCodable].self)
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(dict)
    }
    func stringValue(_ key: String) -> String? {
        guard let any = dict[key] else { return nil }
        return any.stringDescription
    }
}

/// Minimal Any/JSON-tolerant wrapper.
/// Stores values in their decoded form via a tagged enum so the whole thing is Sendable.
struct AnyCodable: Sendable, Codable {
    enum Kind: Sendable {
        case null
        case string(String)
        case bool(Bool)
        case int(Int)
        case double(Double)
        case array([AnyCodable])
        case object([String: AnyCodable])
    }
    let kind: Kind

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { kind = .null; return }
        if let s = try? c.decode(String.self) { kind = .string(s); return }
        if let b = try? c.decode(Bool.self) { kind = .bool(b); return }
        if let i = try? c.decode(Int.self) { kind = .int(i); return }
        if let d = try? c.decode(Double.self) { kind = .double(d); return }
        if let a = try? c.decode([AnyCodable].self) { kind = .array(a); return }
        if let m = try? c.decode([String: AnyCodable].self) { kind = .object(m); return }
        kind = .null
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch kind {
        case .null:           try c.encodeNil()
        case .string(let s):  try c.encode(s)
        case .bool(let b):    try c.encode(b)
        case .int(let i):     try c.encode(i)
        case .double(let d):  try c.encode(d)
        case .array(let a):   try c.encode(a)
        case .object(let m):  try c.encode(m)
        }
    }

    var stringDescription: String {
        switch kind {
        case .null:           return ""
        case .string(let s):  return s
        case .bool(let b):    return String(b)
        case .int(let i):     return String(i)
        case .double(let d):  return String(d)
        case .array(let arr): return "[\(arr.count) items]"
        case .object(let m):  return "{\(m.count) keys}"
        }
    }
}

struct HFModelDetail: Sendable, Codable {
    let id: String
    let siblings: [HFFile]?
    let tags: [String]?
    let pipeline_tag: String?
    let library_name: String?
    let cardData: HFCardData?

    struct HFCardData: Sendable, Codable {
        let license: String?
        let language: [String]?
    }
}

enum HuggingFaceError: LocalizedError {
    case badURL
    case http(Int)
    case decode
    case timeout

    var errorDescription: String? {
        switch self {
        case .badURL: "Bad HuggingFace URL"
        case .http(let s): "HTTP error \(s)"
        case .decode: "Could not decode HuggingFace response"
        case .timeout: "HuggingFace request timed out — check your connection and try again"
        }
    }
}

actor HuggingFaceClient {
    static let shared = HuggingFaceClient()
    private let base = URL(string: "https://huggingface.co")!
    private var token: String?

    func setToken(_ token: String?) { self.token = token }

    /// Search the Hub. When `mlxOnly` is true, restrict to `author=mlx-community`.
    func search(query: String, mlxOnly: Bool = true, limit: Int = 30) async throws -> [HFModel] {
        var components = URLComponents(url: base.appendingPathComponent("/api/models"), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "full", value: "false"),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1")
        ]
        if mlxOnly { items.append(URLQueryItem(name: "author", value: "mlx-community")) }
        components.queryItems = items
        guard let url = components.url else { throw HuggingFaceError.badURL }
        return try await get([HFModel].self, url: url)
    }

    func detail(repoID: String) async throws -> HFModelDetail {
        let url = base.appendingPathComponent("/api/models/\(repoID)")
        return try await get(HFModelDetail.self, url: url)
    }

    func resolveTotalSize(repoID: String) async throws -> Int64 {
        let detail = try await detail(repoID: repoID)
        let files = (detail.siblings ?? []).filter {
            $0.rfilename.hasSuffix(".safetensors") ||
            $0.rfilename.hasSuffix(".bin") ||
            $0.rfilename.hasSuffix(".gguf") ||
            $0.rfilename == "tokenizer.json"
        }
        return files.compactMap { $0.size }.reduce(0, +)
    }

    // MARK: - Datasets

    /// Search HuggingFace datasets. Returns repo IDs ordered by download count.
    func searchDatasets(query: String, limit: Int = 30) async throws -> [HFDataset] {
        var components = URLComponents(url: base.appendingPathComponent("/api/datasets"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "full", value: "false"),
        ]
        guard let url = components.url else { throw HuggingFaceError.badURL }
        return try await get([HFDataset].self, url: url)
    }

    /// Fetch metadata for a specific dataset (siblings, card data, etc.).
    func datasetDetail(repoID: String) async throws -> HFDatasetDetail {
        let url = base.appendingPathComponent("/api/datasets/\(repoID)")
        return try await get(HFDatasetDetail.self, url: url)
    }

    /// Pull the first few rows of a dataset via HF's datasets-server (the same API
    /// the HF web viewer uses). Returns raw row dicts so the UI can show a preview
    /// and the user can pick column names if auto-detection fails.
    func datasetFirstRows(repoID: String, config: String = "default", split: String = "train", length: Int = 5) async throws -> HFDatasetRows {
        var components = URLComponents(string: "https://datasets-server.huggingface.co/rows")!
        components.queryItems = [
            URLQueryItem(name: "dataset", value: repoID),
            URLQueryItem(name: "config", value: config),
            URLQueryItem(name: "split", value: split),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "length", value: "\(length)"),
        ]
        guard let url = components.url else { throw HuggingFaceError.badURL }
        return try await get(HFDatasetRows.self, url: url)
    }

    private func get<T: Decodable>(_ type: T.Type, url: URL) async throws -> T {
        var req = URLRequest(url: url)
        // Bound every metadata/search/preview request so a slow or stalled HF
        // endpoint can't freeze the UI with no recourse; surface a friendly timeout.
        req.timeoutInterval = 20
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw HuggingFaceError.timeout
        }
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HuggingFaceError.http(http.statusCode)
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw HuggingFaceError.decode }
    }
}
