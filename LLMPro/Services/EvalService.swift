import Foundation
import SwiftData
import SwiftUI

// Scored-evaluation orchestrator.
//
// One eval goes:
//   ensure the suite's eval.jsonl exists (lazily pull a built-in via humaneval_pull.py)
//   measure pass@k of a model (+ optional adapter) against it             (eval_pass_rate.py)
//   persist the score + per-task breakdown into an EvalRun
//
// This is the read-only sibling of SelfImproveService: where Practice generates,
// trains, and re-grades in a loop, an EvalRun just grades once and records the
// result so the UI can show a before/after delta when the same base model is
// re-evaluated with a new adapter.
//
// Live progress is published into `status` so the UI can react. Heavy work happens
// inside one `Task { @MainActor in … }` body that streams JSON events from the
// subprocess; the EvalRun @Model is always re-fetched by UUID via a FetchDescriptor
// before it's mutated (never captured into the body) — Swift 6 strict concurrency.

@MainActor
@Observable
final class EvalService {
    static let shared = EvalService()
    private init() {}

    enum EvalError: LocalizedError {
        case runtimeNotReady
        case suiteMissing(String)
        case helperEmittedError(String)
        case process(String)
        case runVanished

        var errorDescription: String? {
            switch self {
            case .runtimeNotReady:           "Python runtime is not ready."
            case .suiteMissing(let s):       "Evaluation suite not found: \(s)"
            case .helperEmittedError(let s): "Helper error: \(s)"
            case .process(let s):            "Process error: \(s)"
            case .runVanished:               "Evaluation record vanished mid-run."
            }
        }
    }

    enum Phase: String, Equatable {
        case idle
        case pullingSuite
        case loadingModel
        case grading
        case completed
        case failed
        case cancelled
    }

    struct LiveStatus: Equatable {
        var runID: UUID?
        var phase: Phase = .idle
        var headline: String = ""
        var detail: String = ""
        var graded: Int = 0
        var total: Int = 0
        var passedSoFar: Int = 0
    }

    private(set) var status = LiveStatus()
    private(set) var logTail: [String] = []
    private var activeProcess: RunningProcess?

    var isRunning: Bool {
        switch status.phase {
        case .idle, .completed, .failed, .cancelled: false
        default: true
        }
    }

    // MARK: – Suite provisioning

    /// Returns the path to the suite's `eval.jsonl`, lazily pulling a built-in
    /// suite via humaneval_pull.py if it isn't already on disk. For `.custom`,
    /// returns `evals/custom-<id>/eval.jsonl` and assumes it exists (no authoring
    /// UI this version) — throws `.suiteMissing` if it doesn't.
    @discardableResult
    func ensureSuite(_ suite: EvalSuite, customID: String = "") async throws -> URL {
        switch suite {
        case .custom:
            let dir = PathResolver.evalSuiteDir(for: "custom-\(customID)")
            let evalFile = dir.appendingPathComponent("eval.jsonl")
            guard FileManager.default.fileExists(atPath: evalFile.path) else {
                throw EvalError.suiteMissing(evalFile.path)
            }
            return evalFile

        case .humaneval, .mbppSanitized:
            let dir = PathResolver.evalSuiteDir(for: suite.rawValue)
            let evalFile = dir.appendingPathComponent("eval.jsonl")
            if FileManager.default.fileExists(atPath: evalFile.path) {
                appendLog("eval.jsonl already present for \(suite.rawValue) — reusing")
                return evalFile
            }
            guard let preset = suite.pullPreset else {
                throw EvalError.suiteMissing(suite.rawValue)
            }
            guard PythonRuntime.shared.isReady, let python = PythonRuntime.shared.pythonURL else {
                throw EvalError.runtimeNotReady
            }
            status.phase = .pullingSuite
            status.headline = "Getting evaluation problems…"
            status.detail = suite.displayName
            try await pullSuite(python: python, preset: preset, outDir: dir)
            guard FileManager.default.fileExists(atPath: evalFile.path) else {
                throw EvalError.suiteMissing(evalFile.path)
            }
            return evalFile
        }
    }

    /// Drive humaneval_pull.py to write `<outDir>/eval.jsonl` (and seed.jsonl,
    /// which we ignore here). Mirrors SelfImproveService.pullSeed's spawn/parse.
    private func pullSuite(python: URL, preset: String, outDir: URL) async throws {
        let args: [String] = [
            PathResolver.helpersDir.appendingPathComponent("humaneval_pull.py").path,
            preset,
            outDir.path
        ]
        let process = try await ProcessRunner.spawn(
            executable: python, arguments: args,
            environment: ["HF_HOME": PathResolver.hfHome.path, "PYTHONUNBUFFERED": "1"])
        activeProcess = process

        var err: String?
        for await line in process.stdout {
            appendLog(line)
            guard let event = decodeEvent(line), let kind = event["event"] as? String else { continue }
            switch kind {
            case "progress":
                if let msg = event["message"] as? String { status.detail = msg }
            case "done":
                let eval = event["eval"] as? Int ?? 0
                status.detail = "\(eval) evaluation problems ready"
            case "error":
                err = event["message"] as? String
            default:
                break
            }
        }
        for await line in process.stderr { appendLog("[stderr] " + line) }
        let exit = (try? await process.exit.value) ?? ProcessExit(code: -1, signal: nil)
        activeProcess = nil
        if exit.code != 0 {
            throw EvalError.helperEmittedError(err ?? "humaneval_pull exited \(exit.code)")
        }
    }

    // MARK: – Entry point

    /// Insert a running EvalRun, grade the model (+ optional adapter) against the
    /// suite, and persist the result. Returns the re-fetched EvalRun (or, if it
    /// somehow vanished from the store, the original inserted instance).
    @discardableResult
    func runEval(model: String,
                 adapterPath: String?,
                 suite: EvalSuite,
                 customID: String = "",
                 k: Int = 1,
                 limit: Int,
                 sourceLabel: String,
                 sourceJobID: UUID?,
                 context: ModelContext) async -> EvalRun {

        // Insert the record up front (status .running) and SAVE so the UI can show
        // it immediately and a crash leaves a sidecar behind.
        let run = EvalRun(
            baseModelRepoID: model,
            adapterRelativePath: Self.adapterRelativePath(for: adapterPath),
            suite: suite,
            customSuiteID: suite == .custom ? customID : "",
            k: max(1, k),
            status: .running,
            sourceLabel: sourceLabel,
            sourceJobID: sourceJobID)
        context.insert(run)
        try? context.save()
        run.writeSidecar()

        let runID = run.id
        let effectiveK = max(1, k)
        status = LiveStatus(runID: runID, phase: .pullingSuite,
                            headline: "Getting evaluation problems…",
                            detail: suite.displayName)
        logTail.removeAll()

        guard PythonRuntime.shared.isReady, let python = PythonRuntime.shared.pythonURL else {
            failRun(id: runID, context: context, error: EvalError.runtimeNotReady)
            return Self.fetchRun(id: runID, context: context) ?? run
        }

        let modelArg = resolveModelArg(model)

        do {
            let evalFile = try await ensureSuite(suite, customID: customID)

            status.phase = .loadingModel
            status.headline = "Warming up the model…"
            status.detail = adapterPath == nil ? "base model" : "with the fine-tuned adapter"

            try await grade(python: python,
                            model: modelArg,
                            adapterPath: adapterPath,
                            evalFile: evalFile,
                            k: effectiveK,
                            limit: limit,
                            runID: runID,
                            context: context)

            status.phase = .completed
            status.headline = "Done"
            activeProcess = nil
        } catch {
            failRun(id: runID, context: context, error: error)
        }

        return Self.fetchRun(id: runID, context: context) ?? run
    }

    /// Spawn eval_pass_rate.py and stream its JSON events, persisting the result
    /// onto the (re-fetched) EvalRun. `--k` is passed only when k > 1; the helper
    /// keeps `pass_at_1` as an alias of `pass_at_k` when k == 1, so we read both.
    private func grade(python: URL,
                       model: String,
                       adapterPath: String?,
                       evalFile: URL,
                       k: Int,
                       limit: Int,
                       runID: UUID,
                       context: ModelContext) async throws {
        var args: [String] = [
            PathResolver.helpersDir.appendingPathComponent("eval_pass_rate.py").path,
            "--eval", evalFile.path,
            "--model", model,
            "--max-tokens", "512",
            "--temperature", "0.0",
            "--row-timeout", "15",
        ]
        if let adapterPath, !adapterPath.isEmpty {
            args.append(contentsOf: ["--adapter", adapterPath])
        }
        if limit > 0 {
            args.append(contentsOf: ["--limit", "\(limit)"])
        }
        // Only pass --k when k > 1 — the concurrently-added flag defaults to 1, and
        // older helper builds without the flag would reject an unknown argument.
        if k > 1 {
            args.append(contentsOf: ["--k", "\(k)"])
        }

        let env: [String: String] = [
            "HF_HOME": PathResolver.hfHome.path,
            "PYTHONUNBUFFERED": "1",
            "MLX_DISABLE_CUDA": "1",
        ]
        let process = try await ProcessRunner.spawn(executable: python, arguments: args, environment: env)
        activeProcess = process

        var tasks: [EvalTaskResult] = []
        var graded = 0
        var total = 0
        var passedSoFar = 0
        var helperError: String?

        // Outcome fields filled on `done`.
        var donePassAtK: Double?
        var donePassed: Int?
        var doneTotal: Int?
        var doneMs: Int?
        var doneK: Int?

        for await line in process.stdout {
            appendLog(line)
            guard let event = decodeEvent(line), let kind = event["event"] as? String else { continue }
            switch kind {
            case "start":
                total = event["rows"] as? Int ?? 0
                status.phase = .grading
                status.total = total
                status.graded = 0
                status.passedSoFar = 0
                status.headline = "Grading \(total) problems…"
                status.detail = ""

            case "model_loaded":
                status.detail = "Model ready — grading…"

            case "row":
                graded += 1
                let taskID = event["task_id"] as? String ?? "row-\(graded)"
                let passed = event["passed"] as? Bool ?? false
                let reason = event["reason"] as? String ?? ""
                if passed { passedSoFar += 1 }
                tasks.append(EvalTaskResult(taskID: taskID, passed: passed, reason: passed ? "" : reason))
                status.graded = graded
                status.passedSoFar = passedSoFar
                status.detail = "Graded \(graded) of \(max(total, graded)) — \(passedSoFar) passed"

            case "done":
                // pass_at_k is the new key; pass_at_1 is the alias when k == 1.
                donePassAtK = (event["pass_at_k"] as? Double) ?? (event["pass_at_1"] as? Double)
                donePassed  = event["passed"] as? Int
                doneTotal   = event["total"] as? Int
                doneMs      = event["ms"] as? Int
                doneK       = event["k"] as? Int

            case "error":
                helperError = event["message"] as? String ?? "eval failed"

            default:
                break
            }
        }
        for await line in process.stderr { appendLog("[stderr] " + line) }
        let exit = (try? await process.exit.value) ?? ProcessExit(code: -1, signal: nil)
        activeProcess = nil

        if let helperError {
            throw EvalError.helperEmittedError(helperError)
        }
        guard exit.code == 0 else {
            throw EvalError.process("eval exited \(exit.code)")
        }

        // Re-fetch the @Model by id before mutating it (never captured into the body).
        guard let live = Self.fetchRun(id: runID, context: context) else {
            throw EvalError.runVanished
        }

        let passedCount = donePassed ?? passedSoFar
        let totalCount  = doneTotal ?? (total > 0 ? total : tasks.count)
        let passAtK     = donePassAtK ?? (totalCount > 0 ? Double(passedCount) / Double(totalCount) : 0)

        live.passAtK = passAtK
        live.passedCount = passedCount
        live.totalCount = totalCount
        live.problemCount = tasks.isEmpty ? totalCount : tasks.count
        live.elapsedMs = doneMs ?? 0
        if let doneK { live.k = max(1, doneK) }
        live.setTasks(tasks)
        live.status = .completed
        live.lastError = nil
        try? context.save()
        live.writeSidecar()

        status.detail = String(format: "%d of %d passed (%.0f%%)",
                               passedCount, totalCount, passAtK * 100)
    }

    func cancel() {
        guard isRunning else { return }
        status.phase = .cancelled
        status.headline = "Cancelling…"
        activeProcess?.terminate()
    }

    // MARK: – Lookups (for score deltas)

    /// The most recent completed eval of this exact base + adapter combination,
    /// or nil. Pass "" for `adapter` to look up base-model (no-adapter) evals.
    func latestEval(forBase base: String, adapter: String, context: ModelContext) -> EvalRun? {
        let completed = EvalStatus.completed.rawValue
        var descriptor = FetchDescriptor<EvalRun>(
            predicate: #Predicate {
                $0.baseModelRepoID == base
                && $0.adapterRelativePath == adapter
                && $0.statusRaw == completed
            },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// The most recent completed eval of the SAME base model whose adapter differs
    /// from `excludingAdapter` — used to compute a before/after score delta against
    /// the previous adapter (or the base model). Returns nil if there's no prior.
    func previousAdapterEval(forBase base: String, excludingAdapter: String, context: ModelContext) -> EvalRun? {
        let completed = EvalStatus.completed.rawValue
        let descriptor = FetchDescriptor<EvalRun>(
            predicate: #Predicate {
                $0.baseModelRepoID == base
                && $0.adapterRelativePath != excludingAdapter
                && $0.statusRaw == completed
            },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return (try? context.fetch(descriptor))?.first
    }

    // MARK: – Helpers

    /// The relative path stored on the EvalRun for a given absolute adapter path.
    /// nil/empty → "" (base model). An absolute path under the shared adapters dir
    /// is reduced to its trailing component(s), matching how TrainingJob /
    /// SelfImproveRun store `adapterRelativePath`. A path outside the adapters dir
    /// is stored verbatim (resolved as an absolute path again by `adapterURL`'s
    /// caller — but in practice all adapters live under adaptersDir).
    private static func adapterRelativePath(for absolutePath: String?) -> String {
        guard let absolutePath, !absolutePath.isEmpty else { return "" }
        let adaptersRoot = PathResolver.adaptersDir.path
        let normalizedRoot = adaptersRoot.hasSuffix("/") ? adaptersRoot : adaptersRoot + "/"
        if absolutePath.hasPrefix(normalizedRoot) {
            return String(absolutePath.dropFirst(normalizedRoot.count))
        }
        // Already a bare relative path (no leading slash) — store as-is.
        if !absolutePath.hasPrefix("/") {
            return absolutePath
        }
        // An absolute path elsewhere: keep just the last component so adapterURL
        // still resolves to *something* under adaptersDir. (Not expected in normal
        // flows; adapters live under adaptersDir.)
        return URL(fileURLWithPath: absolutePath).lastPathComponent
    }

    private func decodeEvent(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    private func appendLog(_ line: String) {
        logTail.append(line)
        if logTail.count > 1200 { logTail.removeFirst(logTail.count - 1200) }
    }

    private func failRun(id: UUID, context: ModelContext, error: any Error) {
        let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if let live = Self.fetchRun(id: id, context: context) {
            live.status = .failed
            live.lastError = msg
            try? context.save()
            live.writeSidecar()
        }
        Log.error("Eval run failed: \(msg)", .training)
        status.phase = .failed
        status.headline = "Stopped"
        status.detail = msg
        activeProcess = nil
    }

    /// Mirrors `SelfImproveService.resolveModelArg` / `TrainingConfigView`'s: prefer
    /// a registry hit even for HF-shaped `owner/repo` ids, otherwise mlx-lm's
    /// hf_hub resolver looks under the wrong cache layout and re-downloads.
    private func resolveModelArg(_ repoOrName: String) -> String {
        if let local = ModelRegistry.shared.localModels.first(where: { $0.repoID == repoOrName }) {
            return local.directory.path
        }
        return repoOrName
    }

    private static func fetchRun(id: UUID, context: ModelContext) -> EvalRun? {
        let descriptor = FetchDescriptor<EvalRun>(predicate: #Predicate { $0.id == id })
        return (try? context.fetch(descriptor))?.first
    }
}
