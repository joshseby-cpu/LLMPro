import XCTest
@testable import LLMPro

/// Tests for the cumulative-keeper merge that fixes the Practice (recursive
/// self-improvement) overfit curve. Each round previously trained on only that
/// round's handful of passers, so the LoRA overfit a tiny dataset. The fix is to
/// train on the growing, deduped union of all rounds' keepers (textbook
/// rejection fine-tuning / ReST). `mergeAndSplitKeepers` is the pure core of that
/// fix, so it's exercised here with no filesystem and no main-actor hop.
///
/// Rows are mlx-lm chat schema:
///   {"messages":[{"role":"user","content":<prompt>},{"role":"assistant","content":<code>}]}
final class SelfImproveMergeTests: XCTestCase {

    // MARK: - Fixtures

    /// One chat-schema JSONL line for a (prompt, code) pair.
    private func row(prompt: String, code: String) -> String {
        let obj: [String: Any] = [
            "messages": [
                ["role": "user", "content": prompt],
                ["role": "assistant", "content": code],
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(data: data, encoding: .utf8)!
    }

    /// Pulls the assistant content out of a result line (for last-write-wins checks).
    private func assistantContent(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = obj["messages"] as? [[String: Any]],
              messages.count >= 2,
              let content = messages[1]["content"] as? String
        else { return nil }
        return content
    }

    /// Pulls the user prompt out of a result line.
    private func promptContent(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = obj["messages"] as? [[String: Any]],
              let first = messages.first,
              let content = first["content"] as? String
        else { return nil }
        return content
    }

    // MARK: - (a) Same prompt across rounds → 1 deduped row, round-2 content wins

    func testSamePromptAcrossRoundsDedupsToLatestRound() {
        let round1 = [row(prompt: "two_sum", code: "def f(): return 1  # round1")]
        let round2 = [row(prompt: "two_sum", code: "def f(): return 2  # round2")]

        let split = SelfImproveService.mergeAndSplitKeepers(roundsRows: [round1, round2])

        // Exactly one unique problem → degenerate 1-row case: all three reuse it.
        let unique = Set(split.train + split.valid)
        XCTAssertEqual(unique.count, 1, "the shared prompt should dedup to a single row")

        // The LAST round's assistant solution must be the one kept.
        for line in split.train + split.valid + split.test {
            XCTAssertEqual(assistantContent(line), "def f(): return 2  # round2",
                           "latest round's solution must win the dedup")
        }
        // 1-row degenerate contract: all three non-empty (mlx-lm needs valid set).
        XCTAssertFalse(split.train.isEmpty)
        XCTAssertFalse(split.valid.isEmpty)
        XCTAssertFalse(split.test.isEmpty)
    }

    // MARK: - (b) N distinct rows → counts add up, valid >= 1, train non-empty

    func testManyDistinctRowsSplitConsistently() {
        // 20 distinct problems spread over two rounds (10 each, no overlap).
        let round1 = (0..<10).map { row(prompt: "p\($0)", code: "c\($0)") }
        let round2 = (10..<20).map { row(prompt: "p\($0)", code: "c\($0)") }

        let split = SelfImproveService.mergeAndSplitKeepers(roundsRows: [round1, round2])

        let total = split.train.count + split.valid.count
        XCTAssertEqual(total, 20, "all 20 distinct problems should survive")

        XCTAssertGreaterThanOrEqual(split.valid.count, 1, "valid must hold out at least one row")
        XCTAssertFalse(split.train.isEmpty, "train must be non-empty")

        // ~10% held out → 2 of 20.
        XCTAssertEqual(split.valid.count, 2)
        XCTAssertEqual(split.train.count, 18)

        // test mirrors valid (same rows, same count).
        XCTAssertEqual(split.test, split.valid)

        // train and valid are disjoint by prompt (genuine hold-out within the buffer).
        let trainKeys = Set(split.train.compactMap(promptContent))
        let validKeys = Set(split.valid.compactMap(promptContent))
        XCTAssertTrue(trainKeys.isDisjoint(with: validKeys),
                      "held-out valid rows must not also appear in train")

        // Every original distinct prompt appears exactly once across train+valid.
        let allKeys = trainKeys.union(validKeys)
        XCTAssertEqual(allKeys.count, 20)
    }

    // MARK: - (c) Degenerate single-row case → all three splits non-empty

    func testSingleRowProducesNonEmptySplits() {
        let only = [row(prompt: "solo", code: "def solo(): pass")]

        let split = SelfImproveService.mergeAndSplitKeepers(roundsRows: [only])

        XCTAssertEqual(split.train.count, 1)
        XCTAssertEqual(split.valid.count, 1)
        XCTAssertEqual(split.test.count, 1)
        XCTAssertEqual(split.train, split.valid)
        XCTAssertEqual(split.test, split.valid)
    }

    // MARK: - Determinism + robustness

    /// No randomness / no Date(): repeated calls give identical splits.
    func testSplitIsDeterministic() {
        let round1 = (0..<15).map { row(prompt: "q\($0)", code: "s\($0)") }
        let a = SelfImproveService.mergeAndSplitKeepers(roundsRows: [round1])
        let b = SelfImproveService.mergeAndSplitKeepers(roundsRows: [round1])
        XCTAssertEqual(a.train, b.train)
        XCTAssertEqual(a.valid, b.valid)
        XCTAssertEqual(a.test, b.test)
    }

    /// Empty input → all empty.
    func testEmptyInputProducesEmptySplits() {
        let split = SelfImproveService.mergeAndSplitKeepers(roundsRows: [])
        XCTAssertTrue(split.train.isEmpty)
        XCTAssertTrue(split.valid.isEmpty)
        XCTAssertTrue(split.test.isEmpty)
    }

    /// Malformed / non-chat lines are skipped, not crashed on.
    func testMalformedLinesAreSkipped() {
        let good = row(prompt: "real", code: "def real(): pass")
        let junk = ["not json at all", "{\"messages\":[]}", "{\"foo\":1}", ""]
        let split = SelfImproveService.mergeAndSplitKeepers(roundsRows: [junk + [good]])

        // Exactly one valid chat row survives → degenerate 1-row case reuses it
        // across train/valid/test, so dedup to the unique set to count it.
        let unique = Set(split.train + split.valid + split.test)
        XCTAssertEqual(unique.count, 1, "only the one valid chat row should survive")
        for line in split.train + split.valid + split.test {
            XCTAssertEqual(promptContent(line), "real")
        }
    }
}
