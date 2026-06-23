import Foundation
import SwiftData

/// Shared delete logic for the two places that list training artifacts — the
/// Progress "Past lessons" sheet and the Save & Use export list. Centralized so
/// both remove the SwiftData record, the live `JobRegistry` entry, and the
/// on-disk folder identically. Never touches datasets, base models, or any fused
/// "…-trained" model produced from a run — only the run's own record + folder.
/// Returns `nil` on success, or a user-facing error message.
@MainActor
enum TrainingArtifactDeletion {
    /// In-flight Practice statuses — a run in any of these is still working and
    /// must not be deleted out from under its subprocess.
    private static let activePracticeStatuses: Set<SelfImproveStatus> =
        [.generating, .testing, .training, .evaluating]

    /// Delete a Teach fine-tune (`TrainingJob`) — record + `adapters/<uuid>/`.
    static func deleteJob(_ job: TrainingJob, context: ModelContext) -> String? {
        guard job.status != .running else { return "That lesson is still running — stop it first." }
        let id = job.id
        let adapterURL = job.adapterURL
        // Drop the live entry first (refuses if a process is somehow still alive).
        guard JobRegistry.shared.remove(jobID: id) else {
            return "That lesson still has a running process — stop it first."
        }
        try? FileManager.default.removeItem(at: adapterURL)
        context.delete(job)
        do {
            try context.save()
        } catch {
            Log.error("Deleting training job \(id) failed: \(error.localizedDescription)", .training)
            return "Couldn't delete: \(error.localizedDescription)"
        }
        return nil
    }

    /// Delete a Practice run (`SelfImproveRun`) — record + `selfimprove/<uuid>/`.
    static func deleteRun(_ run: SelfImproveRun, context: ModelContext) -> String? {
        guard !activePracticeStatuses.contains(run.status) else {
            return "That practice run is still going — stop it first."
        }
        let id = run.id
        let dir = run.directory
        try? FileManager.default.removeItem(at: dir)
        context.delete(run)
        do {
            try context.save()
        } catch {
            Log.error("Deleting practice run \(id) failed: \(error.localizedDescription)", .training)
            return "Couldn't delete: \(error.localizedDescription)"
        }
        return nil
    }
}
