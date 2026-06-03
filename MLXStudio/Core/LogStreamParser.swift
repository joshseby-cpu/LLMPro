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

    // Example eval line:
    // Iter 200: Val loss 1.103, Val took 12.34s
    nonisolated(unsafe) private static let evalRegex = /Iter\s+(\d+):\s+Val\s+loss\s+([\d.]+)/

    // NaN loss appears as "Val loss nan" or "Train loss nan". Specific check
    // because the regex above won't capture nan (it's not [\d.]+). Used by
    // TrainingService to mark the job failed before the user wastes hours.
    nonisolated(unsafe) private static let nanLossRegex = /Iter\s+\d+:\s+(Train|Val)\s+loss\s+nan/

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
