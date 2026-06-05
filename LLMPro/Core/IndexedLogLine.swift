import Foundation

/// One line of a streamed log tail, paired with a stable positional id.
///
/// Several views render "the last N lines of a log" with
/// `ForEach(Array(lines.suffix(N).enumerated()), id: \.offset) { _, line in … }`.
/// That inline `Array(EnumeratedSequence<ArraySlice<String>>)` expression is a
/// real type-check hot spot — deep enough that the SwiftUI preview-dylib
/// compiler (which instruments every string literal) can blow past the
/// type-checker's work limit on it. Mapping the tail to a concrete
/// `[IndexedLogLine]` once, with an explicit type, removes that inference burden
/// from the view body while keeping rendering identical: the `id` is still the
/// positional offset within the tail, so SwiftUI's diffing behaves exactly as it
/// did with `id: \.offset`.
struct IndexedLogLine: Identifiable {
    let id: Int
    let text: String

    /// The last `count` lines of `source`, each tagged with its offset within
    /// the returned slice (0-based), matching the previous `enumerated()` ids.
    static func tail(of source: [String], count: Int) -> [IndexedLogLine] {
        source.suffix(count).enumerated().map { IndexedLogLine(id: $0.offset, text: $0.element) }
    }
}
