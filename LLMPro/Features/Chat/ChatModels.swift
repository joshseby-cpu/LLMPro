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

    /// The in-flight generation Task. Cancelling it tears down the InferenceService
    /// stream, whose `onTermination` terminates the mlx_lm / diffusion subprocess —
    /// so clearing or closing the session aborts generation instead of leaking the
    /// child to max-tokens.
    private var generationTask: Task<Void, Never>?
    /// Bumped on every send() and every stop(), so a superseded/cancelled task's
    /// tail can detect it's no longer current and skip resetting the shared
    /// isGenerating / generationTask fields — otherwise a fast Stop→Send lets the
    /// old task null out the NEW generation, orphaning its subprocess.
    private var generation = 0

    init(model: String, adapterPath: String?, label: String) {
        self.model = model
        self.adapterPath = adapterPath
        self.label = label
    }

    // isolated deinit (SE-0371): runs on the main actor so it may touch the
    // main-actor-isolated generationTask. Cancelling tears down the stream, whose
    // onTermination kills the subprocess — no leaked child when a session is freed.
    isolated deinit { generationTask?.cancel() }

    /// Abort any in-flight generation (also kills the backing subprocess).
    func stop() {
        generation &+= 1   // invalidate the in-flight task's tail
        generationTask?.cancel()
        generationTask = nil
        isGenerating = false
    }

    func clear() {
        stop()
        messages.removeAll()
        error = nil
    }

    /// Re-run the last turn: drop the trailing assistant reply (and its empty
    /// streaming placeholder) and re-send the last user message. Useful when the
    /// model's answer was off — a different sample (esp. with temp > 0) often helps.
    func regenerateLast() {
        guard !isGenerating else { return }
        while let last = messages.last, last.role == .assistant { messages.removeLast() }
        guard let lastUser = messages.last, lastUser.role == .user else { return }
        let prompt = lastUser.text
        messages.removeLast()   // send() re-appends it
        send(prompt)
    }

    func send(_ prompt: String) {
        guard !isGenerating else { return }
        generation &+= 1
        let myGen = generation
        messages.append(ChatMessage(role: .user, text: prompt, isStreaming: false))
        let assistant = ChatMessage(role: .assistant, text: "", isStreaming: true)
        let assistantID = assistant.id
        messages.append(assistant)
        isGenerating = true
        error = nil

        let fullContext = renderHistoryForModel()
        generationTask = Task {
            do {
                let stream = await InferenceService.shared.stream(
                    model: model,
                    adapterPath: adapterPath,
                    prompt: fullContext,
                    params: params
                )
                for try await chunk in stream {
                    if let i = messages.firstIndex(where: { $0.id == assistantID }) {
                        // Append raw: InferenceService yields chunks ready to
                        // concatenate (the mlx_lm path re-adds its line newline; the
                        // diffusion path streams raw token segments that join inline).
                        messages[i].text.append(chunk)
                    }
                }
                if let i = messages.firstIndex(where: { $0.id == assistantID }) {
                    messages[i].isStreaming = false
                }
            } catch is CancellationError {
                // Deliberate stop()/clear(): the subprocess was already torn down
                // via the stream's onTermination — nothing to surface to the user.
                if let i = messages.firstIndex(where: { $0.id == assistantID }) {
                    messages[i].isStreaming = false
                }
            } catch {
                self.error = error.localizedDescription
                if let i = messages.firstIndex(where: { $0.id == assistantID }) {
                    messages[i].isStreaming = false
                    // Persist the answer without the model's <think> reasoning, so
                    // history, exports, and the context fed back to the model stay clean.
                    messages[i].text = ReasoningStripper.visible(messages[i].text)
                }
            }
            // Only reset the shared fields if THIS task is still the current one —
            // a Stop→Send (or clear→Send) may have started a newer generation whose
            // handle we must not clobber (that would orphan its subprocess).
            if self.generation == myGen {
                self.isGenerating = false
                self.generationTask = nil
            }
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
