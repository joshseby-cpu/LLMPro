import Foundation
import Observation

/// Keeps the Mac awake while a training/practice job is running, so an idle or
/// lid-close sleep doesn't pause or throttle a long run. Holds Apple's own
/// `caffeinate` (a power assertion) for the duration of active work.
///
/// Lifetime safety: spawned as `caffeinate -imsu -w <our pid>`, so the assertion
/// dies with the app — a crash, force-quit, or "Detach and Quit" can never leak
/// a system-wide no-sleep process. `applicationWillTerminate` also stops it
/// explicitly (belt and suspenders).
///
/// Race safety: `refresh`/`setPracticeActive` only record the *desired* state and
/// funnel into `reconcile()`; the async spawn re-checks desire after the await
/// and kills the child it just made if the world changed mid-spawn (a job that
/// ends during the spawn window can't strand an active assertion).
///
/// Sources: Teach jobs (`JobRegistry` transitions call `refresh(runningCount:)`)
/// and Practice runs (`SelfImproveService` calls `setPracticeActive(_:)`).
/// Opt-out via the `keepAwakeWhileTraining` preference (default on).
@MainActor
@Observable
final class KeepAwakeService {
    static let shared = KeepAwakeService()
    private init() {}

    private var caffeinate: RunningProcess?
    private var spawning = false
    private var jobCount = 0
    private var practiceActive = false
    private(set) var active = false

    static let prefKey = "keepAwakeWhileTraining"
    private var enabled: Bool {
        UserDefaults.standard.object(forKey: Self.prefKey) as? Bool ?? true
    }

    private var wantActive: Bool { enabled && (jobCount > 0 || practiceActive) }

    /// Teach-side signal — called from every JobRegistry transition.
    func refresh(runningCount: Int) {
        jobCount = runningCount
        reconcile()
    }

    /// Practice-side signal — called by SelfImproveService at run start/end.
    func setPracticeActive(_ active: Bool) {
        practiceActive = active
        reconcile()
    }

    /// Called from applicationWillTerminate. `-w <pid>` already guarantees the
    /// child exits with us; this just makes it immediate and intentional.
    func stopForQuit() {
        caffeinate?.terminate()
        caffeinate = nil
        active = false
    }

    private func reconcile() {
        if wantActive && caffeinate == nil && !spawning {
            spawning = true
            Task { [weak self] in
                guard let self else { return }
                // -i no idle sleep, -m no disk sleep, -s no system sleep (on AC),
                // -u user-active; -w ties the assertion to OUR process lifetime.
                let proc = try? await ProcessRunner.spawn(
                    executable: URL(fileURLWithPath: "/usr/bin/caffeinate"),
                    arguments: ["-imsu", "-w", "\(ProcessInfo.processInfo.processIdentifier)"]
                )
                self.spawning = false
                if self.wantActive, self.caffeinate == nil, let proc {
                    self.caffeinate = proc
                    self.active = true
                    Log.notice("Keep-awake on — a job is running", .app)
                } else {
                    // The world changed during the spawn (job ended, pref flipped,
                    // or another spawn won) — don't strand the child we just made.
                    proc?.terminate()
                    self.reconcile()
                }
            }
        } else if !wantActive && caffeinate != nil {
            caffeinate?.terminate()
            caffeinate = nil
            active = false
            Log.notice("Keep-awake off", .app)
        }
    }
}
