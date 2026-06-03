import Foundation

// Minimal OpenAI-compatible chat client. Talks to the local `mlx_lm server`
// (started by MLXServerService) at http://127.0.0.1:<port>/v1/chat/completions.
//
// We deliberately keep this tiny and non-streaming for v1 — the agent loop
// (CodingAgentService) needs whole assistant turns (with tool_calls) before it
// can act, so token streaming buys little here and adds SSE parsing. The wire
// shapes match the subset of the OpenAI chat API that mlx-lm's server supports.
//
// IMPORTANT (see docs/CONTRACTS.md): mlx-lm parses tool calls out of the model's
// generated text via the tokenizer's chat template + tool_parser. Models whose
// template is NOT tool-aware return their tool intent in `message.content` with
// an empty `tool_calls`. CodingAgentService handles that case with a text
// fallback parser — this client just faithfully decodes whatever the server sent.

// MARK: - Wire types

/// One message in the conversation as the server expects it. Doubles as the
/// source-of-truth history the agent re-sends every turn.
struct ChatWireMessage: Codable, Sendable {
    var role: String                       // "system" | "user" | "assistant" | "tool"
    var content: String?                   // nil on an assistant turn that is only tool_calls
    var toolCalls: [ChatWireToolCall]?     // assistant turn requesting tools
    var toolCallID: String?                // set on a "tool" result message
    var name: String?                      // tool name on a "tool" result (some templates want it)

    enum CodingKeys: String, CodingKey {
        case role, content, name
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }

    init(role: String, content: String? = nil, toolCalls: [ChatWireToolCall]? = nil,
         toolCallID: String? = nil, name: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.name = name
    }
}

struct ChatWireToolCall: Codable, Sendable {
    var id: String
    var type: String                       // always "function"
    var function: ChatWireFunctionCall

    init(id: String, function: ChatWireFunctionCall) {
        self.id = id
        self.type = "function"
        self.function = function
    }
}

struct ChatWireFunctionCall: Codable, Sendable {
    var name: String
    var arguments: String                  // a JSON *string* per the OpenAI spec
}

// MARK: - Tool definitions (request `tools` array)

struct ChatToolSpec: Encodable, Sendable {
    var type: String = "function"
    var function: ChatFunctionSpec
}

struct ChatFunctionSpec: Encodable, Sendable {
    var name: String
    var description: String
    var parameters: ChatToolParameters
}

/// A JSON-Schema "object" — all our tool parameters are flat strings, so this
/// narrow shape is enough and keeps us free of an `Any`-typed schema.
struct ChatToolParameters: Encodable, Sendable {
    var type: String = "object"
    var properties: [String: ChatToolProperty]
    var required: [String]
}

struct ChatToolProperty: Encodable, Sendable {
    var type: String                       // "string"
    var description: String
}

// MARK: - Request / response

struct ChatCompletionRequest: Encodable, Sendable {
    var model: String
    var messages: [ChatWireMessage]
    var tools: [ChatToolSpec]?
    var temperature: Double
    var maxTokens: Int
    var stream: Bool = false
    /// Extra kwargs for the tokenizer's `apply_chat_template` (mlx-lm server
    /// forwards these). We use it to send `{"enable_thinking": false}` so a
    /// "thinking" model acts directly instead of reasoning forever and never
    /// emitting a tool call.
    var chatTemplateKwargs: [String: Bool]? = nil

    enum CodingKeys: String, CodingKey {
        case model, messages, tools, temperature, stream
        case maxTokens = "max_tokens"
        case chatTemplateKwargs = "chat_template_kwargs"
    }
}

struct ChatCompletionResponse: Decodable, Sendable {
    var choices: [Choice]
    var usage: Usage?

    struct Choice: Decodable, Sendable {
        var message: ChatWireMessage
        var finishReason: String?
        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    struct Usage: Decodable, Sendable {
        var promptTokens: Int?
        var completionTokens: Int?
        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
        }
    }

    /// The first choice's assistant text (convenience for non-tool, single-shot
    /// calls like the memory reflection pass). Empty string if absent.
    var firstText: String { choices.first?.message.content ?? "" }
}

// MARK: - Client

struct OpenAIChatClient: Sendable {
    let baseURL: URL                       // e.g. http://127.0.0.1:8080/v1
    /// Generous default — the FIRST request to a freshly-started server has to
    /// wait for the model to load into memory (60–90 s for a 27B). Callers that
    /// know the model is warm can pass a shorter timeout.
    var timeout: TimeInterval = 600

    enum ClientError: LocalizedError {
        case badStatus(Int, String)
        case emptyResponse
        var errorDescription: String? {
            switch self {
            case .badStatus(let code, let body):
                return "Model server returned HTTP \(code): \(body.prefix(400))"
            case .emptyResponse:
                return "Model server returned no choices."
            }
        }
    }

    func complete(_ request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        var req = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = timeout
        req.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            Log.error("chat HTTP \(http.statusCode): \(body.prefix(300))", .agent)
            throw ClientError.badStatus(http.statusCode, body)
        }
        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard !decoded.choices.isEmpty else { throw ClientError.emptyResponse }
        return decoded
    }

    /// Streaming variant (SSE, `stream: true`). Yields `.textDelta` as assistant
    /// prose arrives so the UI shows live progress, then a final `.completed`
    /// with the assembled message (content + any tool_calls accumulated from the
    /// streamed deltas). The agent loop acts on `.completed`.
    func stream(_ request: ChatCompletionRequest) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                var req = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.timeoutInterval = timeout
                var body = request
                body.stream = true
                do {
                    req.httpBody = try JSONEncoder().encode(body)
                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                        var errData = Data()
                        for try await b in bytes { errData.append(b) }
                        throw ClientError.badStatus(http.statusCode, String(data: errData, encoding: .utf8) ?? "")
                    }

                    var content = ""
                    var tools: [Int: (id: String, name: String, args: String)] = [:]
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(ChatStreamChunk.self, from: data),
                              let choice = chunk.choices.first else { continue }
                        if let delta = choice.delta.content, !delta.isEmpty {
                            content += delta
                            continuation.yield(.textDelta(delta))
                        }
                        // "Thinking" models (Gemma-4, Qwen3-thinking, DeepSeek-R1…)
                        // stream their chain-of-thought in a separate `reasoning`
                        // field, not `content`. Surface it so the turn isn't blank.
                        if let r = choice.delta.reasoning, !r.isEmpty {
                            continuation.yield(.reasoningDelta(r))
                        }
                        for tc in choice.delta.toolCalls ?? [] {
                            let i = tc.index ?? 0
                            var acc = tools[i] ?? (id: "", name: "", args: "")
                            if let id = tc.id { acc.id = id }
                            if let name = tc.function?.name { acc.name += name }
                            if let args = tc.function?.arguments { acc.args += args }
                            tools[i] = acc
                        }
                    }

                    let toolCalls: [ChatWireToolCall]? = tools.isEmpty ? nil :
                        tools.sorted { $0.key < $1.key }.map { _, v in
                            ChatWireToolCall(
                                id: v.id.isEmpty ? "call_\(UUID().uuidString.prefix(8))" : v.id,
                                function: ChatWireFunctionCall(name: v.name, arguments: v.args))
                        }
                    continuation.yield(.completed(ChatWireMessage(
                        role: "assistant",
                        content: content.isEmpty ? nil : content,
                        toolCalls: toolCalls)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

enum ChatStreamEvent: Sendable {
    case textDelta(String)
    case reasoningDelta(String)            // chain-of-thought from a "thinking" model
    case completed(ChatWireMessage)
}

/// A single `chat.completion.chunk` SSE frame (subset we consume).
private struct ChatStreamChunk: Decodable {
    let choices: [Choice]
    struct Choice: Decodable { let delta: Delta }
    struct Delta: Decodable {
        let content: String?
        let reasoning: String?             // mlx-lm streams thinking models' CoT here
        let toolCalls: [ToolCallDelta]?
        enum CodingKeys: String, CodingKey { case content, reasoning; case toolCalls = "tool_calls" }
    }
    struct ToolCallDelta: Decodable {
        let index: Int?
        let id: String?
        let function: FunctionDelta?
    }
    struct FunctionDelta: Decodable {
        let name: String?
        let arguments: String?
    }
}
