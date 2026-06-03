import Foundation
import SwiftUI

struct ChatMessage: Identifiable, Hashable {
    let id = UUID()
    let role: Role
    var text: String
    var isStreaming: Bool

    enum Role: String { case user, assistant, system }
}

@MainActor
@Observable
final class ChatSession {
    var model: String
    var adapterPath: String?
    var messages: [ChatMessage] = []
    var params: InferenceParams = .init()
    var isGenerating: Bool = false
    var error: String?
    let label: String

    init(model: String, adapterPath: String?, label: String) {
        self.model = model
        self.adapterPath = adapterPath
        self.label = label
    }

    func clear() { messages.removeAll(); error = nil }

    func send(_ prompt: String) {
        guard !isGenerating else { return }
        messages.append(ChatMessage(role: .user, text: prompt, isStreaming: false))
        let assistant = ChatMessage(role: .assistant, text: "", isStreaming: true)
        let assistantID = assistant.id
        messages.append(assistant)
        isGenerating = true
        error = nil

        let fullContext = renderHistoryForModel()
        Task {
            do {
                let stream = await InferenceService.shared.stream(
                    model: model,
                    adapterPath: adapterPath,
                    prompt: fullContext,
                    params: params
                )
                for try await line in stream {
                    if let i = messages.firstIndex(where: { $0.id == assistantID }) {
                        messages[i].text.append(line + "\n")
                    }
                }
                if let i = messages.firstIndex(where: { $0.id == assistantID }) {
                    messages[i].isStreaming = false
                }
            } catch {
                self.error = error.localizedDescription
                if let i = messages.firstIndex(where: { $0.id == assistantID }) {
                    messages[i].isStreaming = false
                }
            }
            self.isGenerating = false
        }
    }

    private func renderHistoryForModel() -> String {
        var parts: [String] = []
        for m in messages where m.role != .assistant || !m.isStreaming {
            let prefix: String = {
                switch m.role {
                case .user:      "User: "
                case .assistant: "Assistant: "
                case .system:    "System: "
                }
            }()
            parts.append(prefix + m.text)
        }
        parts.append("Assistant:")
        return parts.joined(separator: "\n")
    }
}
