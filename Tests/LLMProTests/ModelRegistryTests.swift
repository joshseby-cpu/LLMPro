import XCTest
@testable import LLMPro

/// Tests for `ModelRegistry`'s duplicate-merge decision. The HF cache can hold
/// the same model in two on-disk layouts (`<HF_HOME>/models--*` and
/// `<HF_HOME>/hub/models--*`); `scan()` inspects both and dedups by repoID. The
/// `hub/` layout's `blobs/` symlink size readout is sometimes wrong (it has
/// reported 26.9 MB for a 28 GB model), so the dedup must keep the *larger*
/// reading rather than letting whichever entry was scanned last win. A wrong
/// pick here propagates to the Models list, the disk-usage total, and the
/// delete-confirmation "bytes to free" message.
@MainActor
final class ModelRegistryTests: XCTestCase {

    private func makeModel(repoID: String, sizeBytes: Int64) -> ModelRegistry.DetectedModel {
        ModelRegistry.DetectedModel(
            id: "\(repoID)#\(sizeBytes)",
            repoID: repoID,
            directory: URL(fileURLWithPath: "/tmp/\(repoID)"),
            architecture: "llama",
            quantization: "4bit",
            sizeBytes: sizeBytes,
            isMLXReady: true
        )
    }

    /// The 28 GB reading must win over the bogus 27 MB one no matter which order
    /// the two duplicates are passed — the bug was an order-dependent clobber.
    func testPrefersLargerSizeRegardlessOfArgumentOrder() {
        let big = makeModel(repoID: "mlx-community/Big-Model-8bit", sizeBytes: 28 * 1_000_000_000)
        let bogus = makeModel(repoID: "mlx-community/Big-Model-8bit", sizeBytes: 27 * 1_000_000)

        // Larger second (correct entry scanned first, bogus would have clobbered).
        XCTAssertEqual(ModelRegistry.preferredDuplicate(bogus, big).sizeBytes, big.sizeBytes)
        // Larger first (bogus scanned second would have clobbered).
        XCTAssertEqual(ModelRegistry.preferredDuplicate(big, bogus).sizeBytes, big.sizeBytes)
    }

    /// On an exact size tie the first argument wins, keeping the merge stable
    /// (the first-scanned layout survives).
    func testTieKeepsFirstArgument() {
        let first = makeModel(repoID: "mlx-community/Tied", sizeBytes: 1_000)
        let second = makeModel(repoID: "mlx-community/Tied", sizeBytes: 1_000)
        XCTAssertEqual(ModelRegistry.preferredDuplicate(first, second).id, first.id)
    }
}
