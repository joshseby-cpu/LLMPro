import Foundation

struct TrainingStep: Codable, Hashable, Sendable {
    let iter: Int
    let trainLoss: Double?
    let valLoss: Double?
    let learningRate: Double
    let tokensPerSec: Double?
    let itersPerSec: Double?
    let trainedTokens: Int?
    let peakMemGB: Double?
    let gradNorm: Double?
    let isEval: Bool
}

enum LogStreamParser {
    // Example mlx-lm train line:
    // Iter 10: Train loss 1.234, Learning Rate 1.000e-05, It/sec 0.45, Tokens/sec 250.3, Trained Tokens 5120, Peak mem 7.2 GB
    nonisolated(unsafe) private static let trainRegex = /Iter\s+(\d+):\s+Train\s+loss\s+([\d.]+)(?:,\s+Learning\s+Rate\s+([\d.eE+\-]+))?(?:,\s+It\/sec\s+([\d.]+))?(?:,\s+Tokens\/sec\s+([\d.]+))?(?:,\s+Trained\s+Tokens\s+(\d+))?(?:,\s+Peak\s+mem\s+([\d.]+)\s*GB)?/

    // Example mlx-lm-lora (DPO) train line:
    // Iter 1: loss 0.693, chosen_r 0.000, rejected_r 0.000, acc 0.000, margin 0.000, lr 1.000e-05, it/s 0.390, tok/s 45.292, peak_mem 4.771GB
    // The label is a bare "loss" immediately after "Iter N:", so this anchors on
    // ": loss " — which the SFT "Iter N: Train loss" / "Iter N: Val loss" lines
    // can never satisfy (they have a word between the colon and "loss"). We only
    // capture the fields TrainingStep models (iter, loss, lr, it/s, tok/s,
    // peak_mem); chosen_r/rejected_r/acc/margin are skipped non-capturing to keep
    // the output tuple small. peak_mem has no space before "GB".
    nonisolated(unsafe) private static let dpoTrainRegex = /Iter\s+(\d+):\s+loss\s+([\d.]+)(?:,\s+chosen_r\s+[\d.\-]+)?(?:,\s+rejected_r\s+[\d.\-]+)?(?:,\s+acc\s+[\d.]+)?(?:,\s+margin\s+[\d.\-]+)?(?:,\s+lr\s+([\d.eE+\-]+))?(?:,\s+it\/s\s+([\d.]+))?(?:,\s+tok\/s\s+([\d.]+))?(?:,\s+peak_mem\s+([\d.]+)\s*GB)?/

    // Example eval line (mlx-lm SFT and mlx-lm-lora DPO both print "Iter N: Val loss …"):
    // Iter 200: Val loss 1.103, Val took 12.34s
    nonisolated(unsafe) private static let evalRegex = /Iter\s+(\d+):\s+Val\s+loss\s+([\d.]+)/

    // NaN loss appears as "Train loss nan" / "Val loss nan" (SFT) or a bare
    // "loss nan" (DPO). Specific check because the loss regexes won't capture nan
    // (it's not [\d.]+). Used by TrainingService to mark the job failed before
    // the user wastes hours. The bare-"loss" form anchors on ": loss nan" so it
    // also matches the DPO train line without touching the SFT cases.
    nonisolated(unsafe) private static let nanLossRegex = /Iter\s+\d+:\s+(?:(?:Train|Val)\s+)?loss\s+nan/

    // Optional grad norm line (newer mlx-lm versions):
    nonisolated(unsafe) private static let gradRegex = /Iter\s+(\d+):.*Grad\s+norm\s+([\d.eE+\-]+)/

    static func parse(_ line: String) -> TrainingStep? {
        if let m = try? evalRegex.firstMatch(in: line) {
            return TrainingStep(
                iter: Int(m.output.1) ?? 0,
                trainLoss: nil,
                valLoss: Double(m.output.2),
                learningRate: 0,
                tokensPerSec: nil,
                itersPerSec: nil,
                trainedTokens: nil,
                peakMemGB: nil,
                gradNorm: nil,
                isEval: true
            )
        }

        if let m = try? trainRegex.firstMatch(in: line) {
            return TrainingStep(
                iter: Int(m.output.1) ?? 0,
                trainLoss: Double(m.output.2),
                valLoss: nil,
                learningRate: m.output.3.flatMap { Double($0) } ?? 0,
                tokensPerSec: m.output.5.flatMap { Double($0) },
                itersPerSec: m.output.4.flatMap { Double($0) },
                trainedTokens: m.output.6.flatMap { Int($0) },
                peakMemGB: m.output.7.flatMap { Double($0) },
                gradNorm: extractGradNorm(line),
                isEval: false
            )
        }

        // DPO train line — tried AFTER the SFT train regex so an SFT line never
        // reaches here. loss drives the Progress chart + TrainingNarrator.stars;
        // the reward/margin extras aren't modeled in TrainingStep, so we just
        // surface loss + lr + throughput + peak mem.
        if let m = try? dpoTrainRegex.firstMatch(in: line) {
            return TrainingStep(
                iter: Int(m.output.1) ?? 0,
                trainLoss: Double(m.output.2),
                valLoss: nil,
                learningRate: m.output.3.flatMap { Double($0) } ?? 0,
                tokensPerSec: m.output.5.flatMap { Double($0) },
                itersPerSec: m.output.4.flatMap { Double($0) },
                trainedTokens: nil,
                peakMemGB: m.output.6.flatMap { Double($0) },
                gradNorm: nil,
                isEval: false
            )
        }

        return nil
    }

    private static func extractGradNorm(_ line: String) -> Double? {
        guard let m = try? gradRegex.firstMatch(in: line) else { return nil }
        return Double(m.output.2)
    }

    /// True if this line indicates mlx-lm produced NaN loss. Caller (the
    /// training service) should treat this as a terminal failure — continuing
    /// to train will just burn time producing a useless adapter.
    static func hasNaNLoss(_ line: String) -> Bool {
        (try? nanLossRegex.firstMatch(in: line)) != nil
    }
}
