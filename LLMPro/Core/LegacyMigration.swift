import Foundation

/// One-time data carried across the MLXStudio → LLMPro rebrand.
///
/// The Application Support *folder* is migrated in `PathResolver` (a same-volume
/// rename of the multi-hundred-GB data dir). This handles the other half:
/// **UserDefaults**, which are keyed by bundle identifier. The bundle id changed
/// from `com.josh.mlxstudio.MLXStudio` to `com.josh.llmpro.LLMPro`, so without
/// this a renamed install would read empty defaults — re-showing the First Run
/// wizard, re-seeding example skills, and forgetting the chosen Code model /
/// workspace. Both migrations are idempotent and safe to leave in indefinitely.
enum LegacyMigration {
    private static let legacyBundleID = "com.josh.mlxstudio.MLXStudio"
    private static let doneFlag = "didMigrateFromMLXStudioDefaults"

    /// Copy preferences from the old bundle-id domain into the current one, once.
    /// Only fills keys that aren't already set in the new domain, so a value the
    /// user changed *after* migrating is never overwritten on a later launch.
    static func migrateUserDefaultsIfNeeded() {
        let new = UserDefaults.standard
        guard !new.bool(forKey: doneFlag) else { return }
        // Mark done up front so a mid-migration crash can't loop on every launch.
        new.set(true, forKey: doneFlag)

        guard let legacy = UserDefaults(suiteName: legacyBundleID) else { return }
        let old = legacy.persistentDomain(forName: legacyBundleID) ?? [:]
        guard !old.isEmpty else { return }

        for (key, value) in old {
            // Skip AppKit/SwiftUI window-geometry bookkeeping (NS… keys) — those
            // are window-class-name specific and meaningless under the new app.
            if key.hasPrefix("NS") { continue }
            if new.object(forKey: key) == nil {
                new.set(value, forKey: key)
            }
        }
        new.synchronize()
        NSLog("LLMPro: migrated \(old.count) legacy preference key(s) from MLXStudio.")
    }
}
