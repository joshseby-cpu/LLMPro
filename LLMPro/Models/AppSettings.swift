import Foundation
import SwiftData

@Model
final class AppSettings {
    @Attribute(.unique) var id: String
    var huggingFaceTokenRefKey: String
    var ollamaPath: String
    var lmStudioModelsPath: String
    var defaultBaseModelRepoID: String?
    var telemetryEnabled: Bool

    init() {
        self.id = "singleton"
        self.huggingFaceTokenRefKey = "llmpro.hfToken"
        self.ollamaPath = "/opt/homebrew/bin/ollama"
        self.lmStudioModelsPath = "\(NSHomeDirectory())/.lmstudio/models"
        self.telemetryEnabled = false
    }
}
