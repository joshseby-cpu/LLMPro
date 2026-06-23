import Foundation
import Observation

struct SystemPromptPreset: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var prompt: String
}

/// Curated + user-saved system prompts for the Try-it-out tab, so the user can
/// switch the model's persona in one click instead of retyping. Built-ins are
/// always present; custom ones persist as JSON under app-support (no SwiftData /
/// no schema change — keeps LLMProApp's modelContainer untouched).
@MainActor
@Observable
final class SystemPromptPresetStore {
    static let shared = SystemPromptPresetStore()

    private let url = PathResolver.appSupport.appendingPathComponent("system_prompt_presets.json")
    private(set) var custom: [SystemPromptPreset] = []

    static let builtins: [SystemPromptPreset] = [
        .init(name: "Expert coder (default)", prompt: "You are a careful, expert programming assistant. Prefer correct, idiomatic code with minimal commentary."),
        .init(name: "Terse — code only", prompt: "You are a coding assistant. Reply with code only — no prose, no explanation, no markdown fences unless asked."),
        .init(name: "Explain like a teacher", prompt: "You are a patient programming teacher. Explain your reasoning step by step, then give the code, then summarize the key idea in one sentence."),
        .init(name: "Senior reviewer", prompt: "You are a senior engineer reviewing code. Point out bugs, edge cases, security issues, and simpler alternatives. Be direct and specific."),
        .init(name: "Test writer", prompt: "You are a test-writing assistant. Given code or a spec, produce thorough unit tests covering happy paths, edge cases, and error conditions."),
        .init(name: "Shell / DevOps", prompt: "You are a DevOps assistant. Prefer safe, POSIX-portable shell with `set -euo pipefail`, explain destructive commands, and never assume sudo."),
    ]

    var all: [SystemPromptPreset] { Self.builtins + custom }

    init() { load() }

    func add(name: String, prompt: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        custom.append(SystemPromptPreset(name: trimmed, prompt: prompt))
        save()
    }

    func remove(_ preset: SystemPromptPreset) {
        custom.removeAll { $0.id == preset.id }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([SystemPromptPreset].self, from: data) else { return }
        custom = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(custom) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
