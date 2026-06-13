import XCTest
@testable import LLMPro

/// Tests for the mlx-lm / mlx-lm-lora training-log line parser. These guard the
/// loop's critical path: a regression here silently empties the Progress chart,
/// the 5-star rating, and the NaN-abort that saves the user hours of dead training.
final class LogStreamParserTests: XCTestCase {

    // MARK: - SFT train lines

    func testParsesSFTTrainLine() {
        let line = "Iter 10: Train loss 1.234, Learning Rate 1.000e-05, It/sec 0.45, Tokens/sec 250.3, Trained Tokens 5120, Peak mem 7.2 GB"
        let step = LogStreamParser.parse(line)
        XCTAssertNotNil(step)
        XCTAssertEqual(step?.iter, 10)
        XCTAssertEqual(step?.trainLoss ?? .nan, 1.234, accuracy: 1e-6)
        XCTAssertNil(step?.valLoss)
        XCTAssertFalse(step?.isEval ?? true)
        XCTAssertEqual(step?.learningRate ?? .nan, 1.000e-05, accuracy: 1e-12)
        XCTAssertEqual(step?.itersPerSec ?? .nan, 0.45, accuracy: 1e-6)
        XCTAssertEqual(step?.tokensPerSec ?? .nan, 250.3, accuracy: 1e-6)
        XCTAssertEqual(step?.trainedTokens, 5120)
        XCTAssertEqual(step?.peakMemGB ?? .nan, 7.2, accuracy: 1e-6)
    }

    // MARK: - Val / eval lines

    func testParsesValLine() {
        let line = "Iter 200: Val loss 1.103, Val took 12.34s"
        let step = LogStreamParser.parse(line)
        XCTAssertNotNil(step)
        XCTAssertEqual(step?.iter, 200)
        XCTAssertEqual(step?.valLoss ?? .nan, 1.103, accuracy: 1e-6)
        XCTAssertNil(step?.trainLoss)
        XCTAssertTrue(step?.isEval ?? false)
    }

    // MARK: - DPO train lines (bare "loss", no "Train" prefix)

    func testParsesDPOTrainLine() {
        let line = "Iter 1: loss 0.693, chosen_r 0.000, rejected_r 0.000, acc 0.000, margin 0.000, lr 1.000e-05, it/s 0.390, tok/s 45.292, peak_mem 4.771GB"
        let step = LogStreamParser.parse(line)
        XCTAssertNotNil(step)
        XCTAssertEqual(step?.iter, 1)
        // DPO uses a bare "loss" → mapped onto trainLoss so it drives the chart.
        XCTAssertEqual(step?.trainLoss ?? .nan, 0.693, accuracy: 1e-6)
        XCTAssertNil(step?.valLoss)
        XCTAssertFalse(step?.isEval ?? true)
        XCTAssertEqual(step?.learningRate ?? .nan, 1.000e-05, accuracy: 1e-12)
        XCTAssertEqual(step?.itersPerSec ?? .nan, 0.390, accuracy: 1e-6)
        XCTAssertEqual(step?.tokensPerSec ?? .nan, 45.292, accuracy: 1e-6)
        // peak_mem has no space before "GB" in the DPO format.
        XCTAssertEqual(step?.peakMemGB ?? .nan, 4.771, accuracy: 1e-6)
    }

    /// The two train formats must not cross-match: an SFT "Train loss" line must
    /// be parsed by the SFT path (trainLoss set, throughput/tokens present), and a
    /// DPO bare-"loss" line by the DPO path. Both produce trainLoss, so we
    /// distinguish via fields only the SFT branch fills (trainedTokens) vs.
    /// DPO-only labels. The real guard is that neither line is misread as the
    /// other's *shape* — verified by checking SFT keeps Trained Tokens.
    func testSFTAndDPOLinesDoNotCrossMatch() {
        let sftLine = "Iter 10: Train loss 1.234, Learning Rate 1.000e-05, It/sec 0.45, Tokens/sec 250.3, Trained Tokens 5120, Peak mem 7.2 GB"
        let dpoLine = "Iter 1: loss 0.693, chosen_r 0.000, rejected_r 0.000, acc 0.000, margin 0.000, lr 1.000e-05, it/s 0.390, tok/s 45.292, peak_mem 4.771GB"

        let sft = LogStreamParser.parse(sftLine)
        let dpo = LogStreamParser.parse(dpoLine)

        // SFT branch fills trainedTokens; DPO branch never does.
        XCTAssertEqual(sft?.trainedTokens, 5120, "SFT line must be parsed by the SFT branch")
        XCTAssertNil(dpo?.trainedTokens, "DPO line must be parsed by the DPO branch (no Trained Tokens)")

        // Sanity: the loss values are distinct and correct, proving each line was
        // read by its own regex and not coerced into the other.
        XCTAssertEqual(sft?.trainLoss ?? .nan, 1.234, accuracy: 1e-6)
        XCTAssertEqual(dpo?.trainLoss ?? .nan, 0.693, accuracy: 1e-6)
    }

    // MARK: - NaN detection

    func testDetectsSFTTrainNaN() {
        XCTAssertTrue(LogStreamParser.hasNaNLoss("Iter 5: Train loss nan, Learning Rate 1.000e-05"))
    }

    func testDetectsSFTValNaN() {
        XCTAssertTrue(LogStreamParser.hasNaNLoss("Iter 200: Val loss nan, Val took 12.34s"))
    }

    func testDetectsDPONaN() {
        XCTAssertTrue(LogStreamParser.hasNaNLoss("Iter 1: loss nan, chosen_r 0.000, acc 0.000"))
    }

    func testNoNaNFalsePositiveOnNormalLine() {
        XCTAssertFalse(LogStreamParser.hasNaNLoss("Iter 10: Train loss 1.234, Learning Rate 1.000e-05"))
        XCTAssertFalse(LogStreamParser.hasNaNLoss("Iter 1: loss 0.693, acc 0.000, margin 0.000"))
    }

    // MARK: - Negative cases (no false positives)

    func testGarbageLineReturnsNil() {
        XCTAssertNil(LogStreamParser.parse("loading dataset shard 3/12..."))
        XCTAssertNil(LogStreamParser.parse(""))
        XCTAssertNil(LogStreamParser.parse("Iter: missing number"))
        XCTAssertNil(LogStreamParser.parse("Total training time: 3.2 min"))
    }
}
