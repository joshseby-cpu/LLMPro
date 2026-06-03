import Foundation
import SwiftData

// A saved coding-agent definition for the Code tab's agent library. An agent
// bundles a model + optional LoRA adapter, a role/instructions block, tool
// permissions, sampling settings, and a set of enabled skills (by SKILL.md
// folder id). The Code tab lets the user pick one of these and run it; only one
// runs at a time (the "switchable agent library" model — see docs/STATE.md).
@Model
final class AgentProfile {
    @Attribute(.unique) var id: UUID
    var name: String
    var emoji: String                 // friendly icon shown in the picker
    var detail: String                // one-line description
    var modelRepoID: String           // base model (ModelRegistry repoID)
    var adapterJobID: UUID?           // optional fine-tune (a completed TrainingJob)
    var instructions: String          // appended to the base coding-agent system prompt
    var autoApproveEdits: Bool
    var autoRunCommands: Bool
    var useNativeTools: Bool
    var temperature: Double
    var maxTokens: Int
    var maxIterations: Int
    var enabledSkillIDs: [String]     // SKILL.md folder ids this agent may use
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        emoji: String = "🤖",
        detail: String = "",
        modelRepoID: String,
        adapterJobID: UUID? = nil,
        instructions: String = "",
        autoApproveEdits: Bool = false,
        autoRunCommands: Bool = false,
        useNativeTools: Bool = true,
        temperature: Double = 0.2,
        maxTokens: Int = 2048,
        maxIterations: Int = 25,
        enabledSkillIDs: [String] = []
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.detail = detail
        self.modelRepoID = modelRepoID
        self.adapterJobID = adapterJobID
        self.instructions = instructions
        self.autoApproveEdits = autoApproveEdits
        self.autoRunCommands = autoRunCommands
        self.useNativeTools = useNativeTools
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.maxIterations = maxIterations
        self.enabledSkillIDs = enabledSkillIDs
        self.createdAt = Date()
    }

    /// The runtime settings the agent loop consumes.
    var agentSettings: AgentSettings {
        AgentSettings(
            autoApproveEdits: autoApproveEdits,
            autoRunCommands: autoRunCommands,
            useNativeTools: useNativeTools,
            temperature: temperature,
            maxTokens: maxTokens)
    }
}
