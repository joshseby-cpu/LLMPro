import Foundation
import Observation

struct SavedPrompt: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var text: String
}

/// A reusable library of test prompts for Try-it-out, so the user can fire common
/// coding asks at a model without retyping. Built-ins cover the usual coding-assistant
/// tasks; custom prompts persist as JSON under app-support (no schema change) — same
/// pattern as `SystemPromptPresetStore`.
@MainActor
@Observable
final class PromptLibraryStore {
    static let shared = PromptLibraryStore()

    private let url = PathResolver.appSupport.appendingPathComponent("prompt_library.json")
    private(set) var custom: [SavedPrompt] = []

    static let builtins: [SavedPrompt] = [
        .init(name: "FizzBuzz", text: "Write FizzBuzz in Python."),
        .init(name: "Reverse a linked list", text: "Write a function to reverse a singly linked list, with a short explanation."),
        .init(name: "Write unit tests", text: "Write thorough unit tests for the following function. Cover happy paths, edge cases, and error conditions.\n\n```\n# paste code here\n```"),
        .init(name: "Explain this code", text: "Explain what the following code does, step by step.\n\n```\n# paste code here\n```"),
        .init(name: "Find the bug", text: "There's a bug in this code. Find it, explain why it's wrong, and give a corrected version.\n\n```\n# paste code here\n```"),
        .init(name: "Refactor for readability", text: "Refactor this code for readability and idiomatic style without changing behavior.\n\n```\n# paste code here\n```"),
        .init(name: "Add docstrings", text: "Add clear docstrings/comments to this code where the intent is non-obvious.\n\n```\n# paste code here\n```"),
        .init(name: "Regex for emails", text: "Write a regular expression that matches valid email addresses, and explain each part."),
    ]

    var all: [SavedPrompt] { Self.builtins + custom }

    init() { load() }

    func add(name: String, text: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        custom.append(SavedPrompt(name: n, text: text))
        save()
    }

    func remove(_ p: SavedPrompt) {
        custom.removeAll { $0.id == p.id }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([SavedPrompt].self, from: data) else { return }
        custom = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(custom) { try? data.write(to: url, options: .atomic) }
    }
}
