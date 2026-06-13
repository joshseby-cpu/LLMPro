import XCTest
@testable import LLMPro

/// Tests for the per-architecture Ollama chat-template suggestion used by the
/// Save & Use export flow. A wrong template produces a model that "works" but
/// emits the wrong special tokens, so the export silently degrades quality.
final class FuseServiceTemplateTests: XCTestCase {

    func testQwenArchitectures() {
        XCTAssertEqual(OllamaChatTemplate.suggestion(forArchitecture: "qwen2"), .qwen)
        XCTAssertEqual(OllamaChatTemplate.suggestion(forArchitecture: "qwen"), .qwen)
    }

    func testLlamaArchitecture() {
        XCTAssertEqual(OllamaChatTemplate.suggestion(forArchitecture: "llama"), .llama3)
    }

    func testMistralAndMixtralArchitectures() {
        XCTAssertEqual(OllamaChatTemplate.suggestion(forArchitecture: "mistral"), .mistral)
        XCTAssertEqual(OllamaChatTemplate.suggestion(forArchitecture: "mixtral"), .mistral)
    }

    func testPhiArchitectures() {
        XCTAssertEqual(OllamaChatTemplate.suggestion(forArchitecture: "phi"), .phi)
        XCTAssertEqual(OllamaChatTemplate.suggestion(forArchitecture: "phi3"), .phi)
    }

    func testDeepseekArchitecture() {
        XCTAssertEqual(OllamaChatTemplate.suggestion(forArchitecture: "deepseek"), .deepseek)
    }

    /// Matching is case-insensitive (suggestion lowercases the input).
    func testCaseInsensitiveMatching() {
        XCTAssertEqual(OllamaChatTemplate.suggestion(forArchitecture: "Qwen2"), .qwen)
        XCTAssertEqual(OllamaChatTemplate.suggestion(forArchitecture: "LLAMA"), .llama3)
    }

    /// Unknown / unhandled architectures fall back to .raw (no template).
    func testUnknownArchitectureFallsBackToRaw() {
        XCTAssertEqual(OllamaChatTemplate.suggestion(forArchitecture: "gemma"), .raw)
        XCTAssertEqual(OllamaChatTemplate.suggestion(forArchitecture: "some-future-arch"), .raw)
        XCTAssertEqual(OllamaChatTemplate.suggestion(forArchitecture: ""), .raw)
    }

    /// Every non-raw suggested template must carry a non-empty Modelfile body so
    /// the export actually writes a TEMPLATE block. (raw is intentionally empty.)
    func testNonRawTemplatesHaveNonEmptyBody() {
        for template in OllamaChatTemplate.allCases where template != .raw {
            XCTAssertFalse(template.modelfileBody.isEmpty,
                           "\(template.rawValue) should have a non-empty Modelfile body")
        }
        XCTAssertTrue(OllamaChatTemplate.raw.modelfileBody.isEmpty, "raw template body must be empty")
    }
}
