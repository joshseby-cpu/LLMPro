import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Install logging + crash handlers as early as possible — before the window,
    // before bootstrap — so anything that fails during startup is captured.
    func applicationWillFinishLaunching(_ notification: Notification) {
        Log.install()
        // Banner-while-frontmost + click-to-navigate for job notifications.
        NotificationService.shared.installDelegate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.notice("App terminating — stopping model server", .app)
        // The coding-agent's `mlx_lm server` is a long-lived daemon holding the
        // model in unified memory (tens of GB). It survives app exit otherwise —
        // an orphaned subprocess that keeps that memory wired. Stop it on quit.
        MLXServerService.shared.stop()
        // Release the caffeinate power assertion immediately (its `-w` tie to our
        // pid would end it anyway; this makes it deterministic).
        KeepAwakeService.shared.stopForQuit()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = JobRegistry.shared.runningJobs
        let practiceRunning = SelfImproveService.shared.isRunning
        guard !running.isEmpty || practiceRunning else { return .terminateNow }

        // Describe what's in flight — Teach jobs, a Practice run, or both. Practice
        // subprocesses were previously invisible to this guard and got silently
        // orphaned on quit (they have no pid-sidecar re-adoption like Teach).
        var parts: [String] = []
        if !running.isEmpty { parts.append("\(running.count) training job(s)") }
        if practiceRunning { parts.append("a Practice run") }
        let what = parts.joined(separator: " and ")
        Log.notice("Quit requested with \(what) running", .training)

        let alert = NSAlert()
        alert.messageText = "Work in progress"
        alert.informativeText = "You still have \(what) going. What would you like to do?"
        alert.addButton(withTitle: "Stop and Quit")
        alert.addButton(withTitle: practiceRunning && running.isEmpty ? "Quit Anyway" : "Detach and Quit")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()

        switch response {
        case .alertFirstButtonReturn:
            // .terminateLater means AppKit waits for an explicit reply. JobRegistry
            // is @MainActor, so the reply follows the await on the main actor — if
            // we never call reply(), AppKit hangs forever (no other code does).
            Task {
                if practiceRunning { SelfImproveService.shared.cancel() }
                await JobRegistry.shared.stopAll()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        case .alertSecondButtonReturn:
            // Practice children can't be re-adopted after relaunch — stop them
            // rather than leave orphans; Teach jobs detach (recoverOrphans
            // re-adopts them by pid on next launch).
            if practiceRunning { SelfImproveService.shared.cancel() }
            JobRegistry.shared.detachAll()
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}
