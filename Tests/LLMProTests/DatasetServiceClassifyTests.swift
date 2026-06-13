import XCTest
@testable import LLMPro

/// Tests for dataset schema auto-detection. The whole training pipeline assumes
/// the schema was classified correctly; the highest-stakes case is preference
/// vs. completions — a preference row carries a `prompt`, so a naive ordering
/// would misfile a DPO dataset as SFT completions and break "Teach by preference".
final class DatasetServiceClassifyTests: XCTestCase {

    func testChatRowClassifiesAsChat() {
        let line = #"{"messages":[{"role":"user","content":"hi"},{"role":"assistant","content":"hello"}]}"#
        XCTAssertEqual(DatasetService.classify(lines: [line]), .chat)
    }

    func testToolsRowClassifiesAsTools() {
        let line = #"{"tools":[{"type":"function","function":{"name":"get_weather"}}],"prompt":"weather?"}"#
        XCTAssertEqual(DatasetService.classify(lines: [line]), .tools)
    }

    func testCompletionsRowClassifiesAsCompletions() {
        let line = #"{"prompt":"2+2=","completion":"4"}"#
        XCTAssertEqual(DatasetService.classify(lines: [line]), .completions)
    }

    func testTextRowClassifiesAsText() {
        let line = #"{"text":"the quick brown fox"}"#
        XCTAssertEqual(DatasetService.classify(lines: [line]), .text)
    }

    func testEmptyObjectClassifiesAsUnknown() {
        XCTAssertEqual(DatasetService.classify(lines: [#"{}"#]), .unknown)
    }

    func testGarbageClassifiesAsUnknown() {
        XCTAssertEqual(DatasetService.classify(lines: ["not json at all", "{broken"]), .unknown)
    }

    func testEmptyInputClassifiesAsUnknown() {
        XCTAssertEqual(DatasetService.classify(lines: []), .unknown)
    }

    // MARK: - The critical ordering case

    /// A {prompt, chosen, rejected} row MUST classify as .preference, never
    /// .completions — even though it also has a `prompt`. The classifier tests
    /// preference before completions for exactly this reason.
    func testPreferenceRowClassifiesAsPreferenceNotCompletions() {
        let line = #"{"prompt":"Write a haiku","chosen":"good answer","rejected":"bad answer"}"#
        let schema = DatasetService.classify(lines: [line])
        XCTAssertEqual(schema, .preference)
        XCTAssertNotEqual(schema, .completions, "preference rows must not be misfiled as completions")
    }

    /// Preference rows may also carry a `system` field; still preference.
    func testPreferenceRowWithSystemFieldClassifiesAsPreference() {
        let line = #"{"system":"You are helpful","prompt":"hi","chosen":"hello","rejected":"go away"}"#
        XCTAssertEqual(DatasetService.classify(lines: [line]), .preference)
    }

    // MARK: - Majority vote across rows

    func testMajorityVoteAcrossMixedRows() {
        let lines = [
            #"{"messages":[{"role":"user","content":"a"}]}"#,
            #"{"messages":[{"role":"user","content":"b"}]}"#,
            #"{"prompt":"x","completion":"y"}"#,
        ]
        // Two chat rows beat one completions row.
        XCTAssertEqual(DatasetService.classify(lines: lines), .chat)
    }
}
