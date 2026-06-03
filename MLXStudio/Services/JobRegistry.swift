import Foundation
import SwiftUI
import Darwin

@MainActor
@Observable
final class JobRegistry {
    static let shared = JobRegistry()

    struct LiveJob: Identifiable {
        let id: UUID
        var name: String
        var status: JobStatus
        var pid: Int32?
        var lastStep: TrainingStep?
        var steps: [TrainingStep]
        var logTail: [String]
        var startedAt: Date?
        let adapterURL: URL
        let baseModelRepoID: String
    }

    private(set) var jobs: [UUID: LiveJob] = [:]
    private var processes: [UUID: RunningProcess] = [:]

    var runningJobs: [LiveJob] { jobs.values.filter { $0.status == .running } }
    var activeJob: LiveJob? { runningJobs.first }

    private init() {}

    func register(_ job: TrainingJob) {
        jobs[job.id] = LiveJob(
            id: job.id,
            name: job.name,
            status: job.status,
            pid: job.pid,
            lastStep: nil,
            steps: job.decodedMetrics(),
            logTail: [],
            startedAt: job.startedAt,
            adapterURL: job.adapterURL,
            baseModelRepoID: job.baseModelRepoID
        )
    }

    func attach(_ job: TrainingJob, process: RunningProcess) {
        processes[job.id] = process
        update(job.id) {
            $0.pid = process.pid
            $0.status = .running
            $0.startedAt = Date()
        }
    }

    func recordStep(jobID: UUID, _ step: TrainingStep) {
        update(jobID) {
            $0.lastStep = step
            $0.steps.append(step)
            if $0.steps.count > 5000 { $0.steps.removeFirst($0.steps.count - 5000) }
        }
    }

    func recordLog(jobID: UUID, _ line: String) {
        update(jobID) {
            $0.logTail.append(line)
            if $0.logTail.count > 500 { $0.logTail.removeFirst($0.logTail.count - 500) }
        }
    }

    func markCompleted(jobID: UUID) {
        update(jobID) { $0.status = .completed }
        processes.removeValue(forKey: jobID)
    }

    func markFailed(jobID: UUID, _ reason: String) {
        update(jobID) {
            $0.status = .failed
            $0.logTail.append("[error] " + reason)
        }
        Log.error("Training job \(jobID) failed: \(reason)", .training)
        processes.removeValue(forKey: jobID)
    }

    func stop(jobID: UUID) {
        processes[jobID]?.terminate()
        update(jobID) { $0.status = .cancelled }
        processes.removeValue(forKey: jobID)
    }

    func stopAll() async {
        for (id, _) in processes { stop(jobID: id) }
    }

    func detachAll() {
        for proc in processes.values { proc.detach() }
        processes.removeAll()
    }

    func recoverOrphans() async {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: PathResolver.adaptersDir, includingPropertiesForKeys: nil) else { return }
        for adapterDir in entries where adapterDir.hasDirectoryPath {
            let sidecar = adapterDir.appendingPathComponent("job.json")
            guard let data = try? Data(contentsOf: sidecar),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let idStr = json["id"] as? String,
                  let uuid = UUID(uuidString: idStr)
            else { continue }

            // Already known?
            if jobs[uuid] != nil { continue }

            let status: JobStatus = {
                if let pid = json["pid"] as? Int32, isProcessAlive(pid) { return .running }
                return .orphaned
            }()

            jobs[uuid] = LiveJob(
                id: uuid,
                name: (json["name"] as? String) ?? "Recovered job",
                status: status,
                pid: json["pid"] as? Int32,
                lastStep: nil,
                steps: [],
                logTail: ["[recovered from \(adapterDir.lastPathComponent)]"],
                startedAt: (json["startedAt"] as? TimeInterval).map(Date.init(timeIntervalSince1970:)),
                adapterURL: adapterDir,
                baseModelRepoID: (json["baseModel"] as? String) ?? ""
            )
        }
    }

    private func update(_ id: UUID, _ mutate: (inout LiveJob) -> Void) {
        guard var job = jobs[id] else { return }
        mutate(&job)
        jobs[id] = job
    }

    /// True only if `pid` is a *live* process that is actually our venv Python
    /// running training — not merely some process with that number.
    ///
    /// The bug this fixes: after a training run ends and the app restarts, the OS
    /// frequently **recycles the dead process's PID** to an unrelated live process.
    /// A bare `kill(pid, 0)` then succeeds, and `recoverOrphans()` resurrects the
    /// long-dead job as `.running` — which makes `activeJob` non-nil and blocks the
    /// user from starting any new training ("a lesson is already running" when none
    /// is). Verifying the executable path defends against that PID reuse: a recycled
    /// PID belonging to some other binary (or a non-MLX-Studio python) is rejected.
    private func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0, kill(pid, 0) == 0 else { return false }
        var buf = [CChar](repeating: 0, count: 4096)   // PROC_PIDPATHINFO_MAXSIZE
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return false }
        let path = String(cString: buf).lowercased()
        // Our training spawns the bundled venv python:
        //   ~/Library/Application Support/MLXStudio/runtime/.venv/bin/python3.x
        return path.contains("python") && path.contains("mlxstudio")
    }
}
