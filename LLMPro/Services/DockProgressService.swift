import AppKit

/// Shows the current training step on the Dock icon (e.g. "38/50") so progress is
/// visible without opening the app or the menu-bar panel. Badge-only — no custom
/// Dock-tile drawing — to stay simple and robust. Driven by `JobRegistry`: updated
/// as steps stream in, cleared when no job is learning.
@MainActor
enum DockProgressService {
    static func refresh(_ jobs: [JobRegistry.LiveJob]) {
        let label: String? = {
            for job in jobs {
                switch TrainingNarrator.phase(for: job) {
                case .learning(let n, let m) where m > 0: return "\(n)/\(m)"
                case .popQuiz(let n, let m) where m > 0:   return "\(n)/\(m)"
                default: continue
                }
            }
            return nil
        }()
        NSApp.dockTile.badgeLabel = label
    }
}
