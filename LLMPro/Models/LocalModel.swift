import Foundation
import SwiftData

@Model
final class LocalModel {
    @Attribute(.unique) var repoID: String
    var displayName: String
    var architecture: String
    var quantization: String
    var sizeBytes: Int64
    var path: String
    var isMLXReady: Bool
    var downloadedAt: Date
    var notes: String

    init(
        repoID: String,
        displayName: String,
        architecture: String,
        quantization: String,
        sizeBytes: Int64,
        path: String,
        isMLXReady: Bool,
        notes: String = ""
    ) {
        self.repoID = repoID
        self.displayName = displayName
        self.architecture = architecture
        self.quantization = quantization
        self.sizeBytes = sizeBytes
        self.path = path
        self.isMLXReady = isMLXReady
        self.downloadedAt = Date()
        self.notes = notes
    }

    var localURL: URL { URL(fileURLWithPath: path) }
    var humanSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
    var supportsNativeGGUF: Bool {
        ["llama", "mistral", "mixtral"].contains(architecture.lowercased())
    }
}
