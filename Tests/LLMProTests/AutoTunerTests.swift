import XCTest
@testable import LLMPro

/// Tests for the auto-tuner that picks every training hyperparameter. The Teach
/// UI exposes only model/dataset/duration, so these buckets are the entire
/// hyperparameter surface — a bucket regressing to zero iters or zero batch
/// would silently produce a no-op or crashing training run.
final class AutoTunerTests: XCTestCase {

    /// ModelSize is not CaseIterable in the source, so enumerate it here. If a
    /// case is added, this list (and the tune() coverage below) should grow.
    private let allSizes: [ModelSize] = [.tiny, .small, .medium, .large, .huge]

    // MARK: - categorize: repo id / param-count → ModelSize

    func testCategorizeTiny() {
        XCTAssertEqual(AutoTuner.categorize(repoID: "mlx-community/Llama-3.2-1B-Instruct-4bit"), .tiny)
        XCTAssertEqual(AutoTuner.categorize(repoID: "google/gemma-2-2b"), .small)
    }

    func testCategorizeSmall() {
        XCTAssertEqual(AutoTuner.categorize(repoID: "mlx-community/Llama-3.2-3B-Instruct"), .small)
    }

    func testCategorizeMedium() {
        XCTAssertEqual(AutoTuner.categorize(repoID: "mlx-community/Qwen2.5-7B-Instruct-4bit"), .medium)
    }

    func testCategorizeHuge() {
        XCTAssertEqual(AutoTuner.categorize(repoID: "mlx-community/Qwen3.6-27B-8bit"), .huge)
        XCTAssertEqual(AutoTuner.categorize(repoID: "mlx-community/Qwen3-32B-4bit"), .huge)
    }

    /// 2B is the boundary into .small per the patterns (>= 2.0 → small).
    func testCategorizeBoundaryTwoBillion() {
        XCTAssertEqual(AutoTuner.categorize(repoID: "some-2b-model"), .small)
    }

    /// No "<num>B" marker → falls back to .medium (the documented, safer default).
    ///
    /// This was previously a bug: the patterns table ended with `(0.0, .tiny)` and
    /// `maxBillion` is 0 when no marker matches, so `maxBillion >= 0.0` always
    /// returned .tiny first, making the documented `return .medium` dead code. A
    /// custom-renamed model with no size in its name therefore got the most
    /// aggressive .tiny hyperparameters. Fixed (2026-06-13 audit): the `(0.0, .tiny)`
    /// tuple was removed and an explicit `0 < maxBillion < 2 → .tiny` branch added,
    /// so a real sub-2B marker still maps to tiny while an UNMARKED id now correctly
    /// falls through to .medium.
    func testCategorizeNoMarkerFallsBackToMedium() {
        XCTAssertEqual(AutoTuner.categorize(repoID: "mlx-community/some-coding-model"), .medium)
        XCTAssertEqual(AutoTuner.categorize(repoID: "phi-mini-instruct"), .medium)
    }

    /// A genuine sub-2B marker still maps to .tiny (the explicit guarded branch).
    func testCategorizeSmallMarkerStillTiny() {
        XCTAssertEqual(AutoTuner.categorize(repoID: "llama-3.2-1b-instruct"), .tiny)
        XCTAssertEqual(AutoTuner.categorize(repoID: "qwen2.5-1.5b"), .tiny)
    }

    /// When multiple markers appear, the largest wins (e.g. a "1.5B" embedder
    /// shipped alongside a "32B" base should categorize as the 32B).
    func testCategorizePicksLargestMarker() {
        XCTAssertEqual(AutoTuner.categorize(repoID: "mix-1.5b-and-32b"), .huge)
    }

    // MARK: - tune: every (size, duration) bucket must be sane

    /// Guard against any bucket regressing to zero/negative iters, batch, or time.
    func testEveryBucketProducesPositiveConfig() {
        for size in allSizes {
            for duration in TrainingDuration.allCases {
                let cfg = AutoTuner.tune(size: size,
                                         dataPath: "/tmp/data",
                                         adapterPath: "/tmp/adapter",
                                         duration: duration)
                let ctx = "size=\(size.rawValue) duration=\(duration.rawValue)"
                XCTAssertGreaterThan(cfg.iters, 0, "iters must be positive (\(ctx))")
                XCTAssertGreaterThan(cfg.batchSize, 0, "batchSize must be positive (\(ctx))")
                XCTAssertGreaterThan(cfg.estimatedMinutes, 0, "estimatedMinutes must be positive (\(ctx))")
                XCTAssertGreaterThan(cfg.numLayers, 0, "numLayers must be positive (\(ctx))")
                XCTAssertGreaterThan(cfg.maxSeqLength, 0, "maxSeqLength must be positive (\(ctx))")
                XCTAssertGreaterThan(cfg.learningRate, 0, "learningRate must be positive (\(ctx))")
                XCTAssertGreaterThan(cfg.loraRank, 0, "loraRank must be positive (\(ctx))")
                XCTAssertGreaterThan(cfg.gradAccumulationSteps, 0, "gradAccumulationSteps must be positive (\(ctx))")
                XCTAssertFalse(cfg.loraTargetKeys.isEmpty, "loraTargetKeys must be non-empty (\(ctx))")
                XCTAssertGreaterThan(cfg.estimatedPeakMemoryGB, 0, "estimatedPeakMemoryGB must be positive (\(ctx))")
            }
        }
    }

    /// More duration ⇒ at least as many iters within a fixed size.
    func testItersMonotonicWithDuration() {
        for size in allSizes {
            let quick = AutoTuner.tune(size: size, dataPath: "/tmp/d", adapterPath: "/tmp/a", duration: .quick).iters
            let standard = AutoTuner.tune(size: size, dataPath: "/tmp/d", adapterPath: "/tmp/a", duration: .standard).iters
            let thorough = AutoTuner.tune(size: size, dataPath: "/tmp/d", adapterPath: "/tmp/a", duration: .thorough).iters
            XCTAssertLessThanOrEqual(quick, standard, "quick <= standard iters for \(size.rawValue)")
            XCTAssertLessThanOrEqual(standard, thorough, "standard <= thorough iters for \(size.rawValue)")
        }
    }

    /// The repoID-based tune() entry point used by the UI must also be sane and
    /// route through categorize correctly.
    func testTuneByRepoIDProducesPositiveConfig() {
        let cfg = AutoTuner.tune(repoID: "mlx-community/Llama-3.2-1B-Instruct-4bit",
                                 dataPath: "/tmp/data",
                                 adapterPath: "/tmp/adapter",
                                 duration: .quick)
        XCTAssertGreaterThan(cfg.iters, 0)
        XCTAssertGreaterThan(cfg.batchSize, 0)
        XCTAssertGreaterThan(cfg.estimatedMinutes, 0)
    }
}
