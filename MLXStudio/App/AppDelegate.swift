import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Install logging + crash handlers as early as possible — before the window,
    // before bootstrap — so anything that fails during startup is captured.
    func applicationWillFinishLaunching(_ notification: Notification) {
        Log.install()
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
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = JobRegistry.shared.runningJobs
        guard !running.isEmpty else { return .terminateNow }
        Log.notice("Quit requested with \(running.count) training job(s) running", .training)

        let alert = NSAlert()
        alert.messageText = "Training in progress"
        alert.informativeText = "\(running.count) training job(s) are still running. What would you like to do?"
        alert.addButton(withTitle: "Stop and Quit")
        alert.addButton(withTitle: "Detach and Quit")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()

        switch response {
        case .alertFirstButtonReturn:
            Task { await JobRegistry.shared.stopAll() }
            return .terminateLater
        case .alertSecondButtonReturn:
            JobRegistry.shared.detachAll()
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}
