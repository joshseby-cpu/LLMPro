import Foundation
import SwiftData

enum DatasetSchema: String, Codable, CaseIterable {
    case chat, completions, tools, text, unknown

    var displayName: String {
        switch self {
        case .chat:        "Chat (messages)"
        case .completions: "Completions (prompt/completion)"
        case .tools:       "Tools (function calls)"
        case .text:        "Text (raw)"
        case .unknown:     "Unknown"
        }
    }
}

@Model
final class DatasetRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var schemaRaw: String
    var trainRows: Int
    var validRows: Int
    var testRows: Int
    var relativePath: String
    var createdAt: Date
    var notes: String

    init(id: UUID = UUID(), name: String, schema: DatasetSchema, trainRows: Int, validRows: Int, testRows: Int, notes: String = "") {
        self.id = id
        self.name = name
        self.schemaRaw = schema.rawValue
        self.trainRows = trainRows
        self.validRows = validRows
        self.testRows = testRows
        self.relativePath = id.uuidString
        self.createdAt = Date()
        self.notes = notes
    }

    var schema: DatasetSchema {
        get { DatasetSchema(rawValue: schemaRaw) ?? .unknown }
        set { schemaRaw = newValue.rawValue }
    }

    var directoryURL: URL { PathResolver.datasetsDir.appendingPathComponent(relativePath, isDirectory: true) }
    var trainFile: URL { directoryURL.appendingPathComponent("train.jsonl") }
    var validFile: URL { directoryURL.appendingPathComponent("valid.jsonl") }
    var testFile: URL { directoryURL.appendingPathComponent("test.jsonl") }
}
