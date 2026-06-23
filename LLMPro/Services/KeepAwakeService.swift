import Foundation
import Observation

/// Keeps the Mac awake while a training/practice job is running, so an idle or
/// lid-close sleep doesn't pause or throttle a long run. Holds Apple's own
/// `caffeinate` (a power assertion) for the duration of active jobs — preferred
/// over an in-process IOKit assertion because it auto-releases if the app crashes
/// (no leaked assertion) and matches the project's sidecar-subprocess philosophy.
/// Driven by `JobRegistry`: `refresh(runningCount:)` is called on every job
/// transition; the assertion is held while the count is > 0 and released at 0.
/// Opt-out via the `keepAwakeWhileTraining` preference (default on).
@MainActor
@Observable
final class KeepAwakeService {
    static let shared = KeepAwakeService()
    private init() {}

    private var caffeinate: RunningProcess?
    private(set) var active = false

    static let prefKey = "keepAwakeWhileTraining"
    private var enabled: Bool {
        UserDefaults.standard.object(forKey: Self.prefKey) as? Bool ?? true
    }

    /// Hold caffeinate while ≥1 job runs and the pref is on; release otherwise.
    func refresh(runningCount: Int) {
        let want = enabled && runningCount > 0
        if want && caffeinate == nil {
            start()
        } else if !want && caffeinate != nil {
            stop()
        }
    }

    private func start() {
        Task {
            // -i no idle sleep, -m no disk sleep, -s no system sleep (on AC), -u user-active
            caffeinate = try? await ProcessRunner.spawn(
                executable: URL(fileURLWithPath: "/usr/bin/caffeinate"),
                arguments: ["-imsu"]
            )
            active = caffeinate != nil
            if active { Log.notice("Keep-awake on — a job is running", .app) }
        }
    }

    private func stop() {
        caffeinate?.terminate()
        caffeinate = nil
        active = false
        Log.notice("Keep-awake off", .app)
    }
}
