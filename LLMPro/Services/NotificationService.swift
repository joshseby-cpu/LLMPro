import Foundation
import UserNotifications

/// Local "your job finished" notifications. Training, Practice, and GGUF export
/// can run for many minutes — long enough that the user switches apps. This posts
/// a macOS notification when one finishes (success or failure) so they don't have
/// to babysit the Progress tab. Best-effort: if the user denied notifications it
/// silently no-ops. Authorization is requested once, lazily, the first time we'd
/// post (so we never prompt on a cold first launch before the user has done
/// anything). Mirrors the project's "friendly-first" tone in the copy.
@MainActor
final class NotificationService {
    static let shared = NotificationService()
    private init() {}

    private var authorized = false
    private var askedThisSession = false

    /// Ask for permission once per session, lazily. Returns whether we're allowed
    /// to post. Never throws — a denied/unavailable center just means no banners.
    private func ensureAuthorized() async -> Bool {
        if authorized { return true }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            authorized = true
            return true
        case .notDetermined:
            guard !askedThisSession else { return false }
            askedThisSession = true
            authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            return authorized
        default:
            return false
        }
    }

    /// Pre-warm the permission prompt at a natural moment (e.g. when the user
    /// starts their first long job) rather than on cold launch.
    func primeAuthorization() {
        Task { _ = await ensureAuthorized() }
    }

    private func post(title: String, body: String, id: String) {
        Task {
            guard await ensureAuthorized() else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    // MARK: - Job-specific helpers (friendly copy)

    func trainingFinished(name: String, success: Bool) {
        post(title: success ? "Lesson complete 🎓" : "Lesson stopped",
             body: success ? "“\(name)” finished training — open Progress to try it out."
                           : "“\(name)” didn’t finish. Open Progress to see what happened.",
             id: "training-\(name)-\(success)")
    }

    func practiceFinished(name: String, success: Bool) {
        post(title: success ? "Practice complete 🧠" : "Practice stopped",
             body: success ? "“\(name)” finished its practice rounds."
                           : "“\(name)” practice run ended early.",
             id: "practice-\(name)")
    }

    func exportFinished(name: String, success: Bool) {
        post(title: success ? "Export ready 📦" : "Export failed",
             body: success ? "“\(name)” is exported and ready to use."
                           : "“\(name)” export didn’t finish — check the output.",
             id: "export-\(name)")
    }
}
