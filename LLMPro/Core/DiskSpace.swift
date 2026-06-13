import Foundation

/// On-demand free-disk-space query for the volume that holds our app-support data
/// (`PathResolver.appSupport` — every multi-GB artifact lives under it: `hf/`,
/// `adapters/`, `models/`, `exports/`). Unlike memory, free disk isn't worth
/// polling — it's a snapshot you take right before a big download or training
/// run, so this is a pure Foundation helper, not a `SystemMetrics`-style poller.
enum DiskSpace {

    /// Free space (decimal GB, to match how Finder reports it) on the volume that
    /// backs `PathResolver.appSupport`, or `nil` if the OS query fails.
    ///
    /// Uses `volumeAvailableCapacityForImportantUsage` — the modern key that
    /// accounts for purgeable space, i.e. the realistic "how much can I actually
    /// write for something important like a model download" number rather than the
    /// raw free-blocks figure.
    static func freeGBForImportantUsage() -> Double? {
        do {
            let values = try PathResolver.appSupport.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            )
            // The key is reported in bytes as an Int64.
            guard let bytes = values.volumeAvailableCapacityForImportantUsage else {
                Log.error("disk free-space query returned no value", .data)
                return nil
            }
            // Decimal GB (÷1e9) to line up with what Finder shows the user.
            return Double(bytes) / 1_000_000_000.0
        } catch {
            Log.error("disk free-space query failed", .data, error: error)
            return nil
        }
    }

    /// How alarmed to be about a given free-space figure. Factored out as a pure
    /// function so the threshold logic is trivially unit-testable without any view
    /// or filesystem involvement.
    enum Tier {
        case ok        // plenty of room — no banner
        case warning   // getting tight — amber heads-up
        case critical  // about to run out — red warning
    }

    /// Map a free-GB figure to a `Tier`. `nil` (query failed) → `.ok` so a failed
    /// probe never nags the user with a banner they can't act on.
    static func tier(freeGB: Double?) -> Tier {
        guard let freeGB else { return .ok }
        if freeGB < 5 { return .critical }
        if freeGB < 20 { return .warning }
        return .ok
    }
}
