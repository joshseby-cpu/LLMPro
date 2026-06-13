import Foundation
import SwiftData
import SwiftUI

// Self-improvement loop orchestrator.
//
// One run goes:
//   pull seed (HumanEval / MBPP) once
//   measure baseline pass@1 (base model, no adapter)
//   for each of N rounds:
//     generate K candidates per prompt, run unit tests, keep passers      (self_improve_round.py)
//     train a new LoRA adapter on the passers                              (python -m mlx_lm lora)
//     measure pass@1 with the new adapter against the held-out eval set    (eval_pass_rate.py)
//
// Live progress is published into `phase`, `currentRound`, `lastEvent`,
// `passAtOneTrend` so the UI can react. Heavy work happens inside one big
// `Task { @MainActor in … }` block; subprocesses stream JSON events that the
// service decodes and applies.

@MainActor
@Observable
final class SelfImproveService {
    static let shared = SelfImproveService()

    enum LoopError: LocalizedError {
        case runtimeNotReady
        case modelNotResolved(String)
        case helperEmittedError(String)
        case process(String)

        var errorDescription: String? {
            switch self {
            case .runtimeNotReady:           "Python runtime is not ready."
            case .modelNotResolved(let s):   "Could not resolve model: \(s)"
            case .helperEmittedError(let s): "Helper error: \(s)"
            case .process(let s):            "Process error: \(s)"
            }
        }
    }

    struct LiveStatus: Equatable {
        var runID: UUID?
        var phase: Phase = .idle
        var headline: String = ""
        var detail: String = ""
        var roundNumber: Int = 0
        var rowsDone: Int = 0
        var rowsTotal: Int = 0
        var passesSoFar: Int = 0
        var attemptsSoFar: Int = 0
        var passAtOneTrend: [Double] = []   // baseline + per-round eval scores

        var keepRate: Double {
            rowsTotal > 0 ? Double(rowsDone) / Double(rowsTotal) : 0
        }
    }

    enum Phase: String, Equatable {
        case idle
        case pullingSeed
        case baselineEval
        case generating
        case training
        case evaluating
        case completed
        case failed
        case cancelled
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

    private init() {}

    // MARK: – Entry point

    func start(run: SelfImproveRun, context: ModelContext) async {
        guard PythonRuntime.shared.isReady, let python = PythonRuntime.shared.pythonURL else {
            fail(run: run, context: context, error: LoopError.runtimeNotReady)
            return
        }
        let runID = run.id
        status = LiveStatus(runID: runID, phase: .pullingSeed,
                            headline: "Getting practice problems…",
                            detail: run.seed.displayName)
        logTail.removeAll()

        run.startedAt = Date()
        run.status = .generating
        run.lastError = nil
        try? context.save()
        run.writeSidecar()

        let modelArg = resolveModelArg(run.baseModelRepoID)

        do {
            // 1. Pull seed + eval if not already there.
            if !FileManager.default.fileExists(atPath: run.seedFile.path) {
                try await pullSeed(python: python, run: run)
            } else {
                appendLog("seed.jsonl already present — reusing")
            }

            // 2. Baseline eval (no adapter).
            if run.baselinePassAtOne == nil {
                status.phase = .baselineEval
                status.headline = "Seeing how well it does without practice…"
                let baseline = try await runEval(python: python, model: modelArg,
                                                  adapter: nil, evalFile: run.evalFile)
                run.baselinePassAtOne = baseline
                status.passAtOneTrend = [baseline]
                try? context.save()
                run.writeSidecar()
                appendLog(String(format: "baseline pass@1 = %.1f%%", baseline * 100))
            }

            // 3. Rounds.
            var lastAdapter: URL? = nil
            for n in 1 ... max(1, run.targetRounds) {
                if status.phase == .cancelled { break }

                let round = try await runOneRound(
                    runID: runID,
                    context: context,
                    python: python,
                    model: modelArg,
                    priorAdapter: lastAdapter,
                    roundNumber: n
                )
                lastAdapter = PathResolver.adaptersDir.appendingPathComponent(round.adapterRelativePath, isDirectory: true)
            }

            // 4. Done.
            if let live = Self.fetchRun(id: runID, context: context) {
                live.status = .completed
                live.endedAt = Date()
                try? context.save()
                live.writeSidecar()
            }
            status.phase = .completed
            status.headline = "Done — see Try it out to chat with the improved model."
            activeProcess = nil
        } catch {
            // A user cancel terminates the subprocess (SIGTERM → non-zero exit), which
            // throws here. Route to the cancelled terminal state instead of overwriting
            // it with .failed and a misleading error message.
            if status.phase == .cancelled || Task.isCancelled {
                cancelled(run: run, context: context)
            } else {
                fail(run: run, context: context, error: error)
            }
        }
    }

    func cancel() {
        guard isRunning else { return }
        status.phase = .cancelled
        status.headline = "Cancelling…"
        activeProcess?.terminate()
    }

    // MARK: – One round

    @discardableResult
    private func runOneRound(runID: UUID,
                             context: ModelContext,
                             python: URL,
                             model: String,
                             priorAdapter: URL?,
                             roundNumber n: Int) async throws -> SelfImproveRoundRecord {

        guard let run = Self.fetchRun(id: runID, context: context) else {
            throw LoopError.process("Run vanished mid-loop")
        }

        // — 3a. Generate + test ----------------------------------------------------
        status.phase = .generating
        status.headline = "Round \(n): trying problems…"
        status.detail = priorAdapter == nil ? "starting from base model" : "using last round's adapter"
        status.roundNumber = n
        status.rowsDone = 0
        status.rowsTotal = 0
        status.passesSoFar = 0
        status.attemptsSoFar = 0

        let roundJobID = UUID()
        let roundDir = run.roundDir(n)
        try? FileManager.default.createDirectory(at: roundDir, withIntermediateDirectories: true)

        var roundRecord = SelfImproveRoundRecord(
            roundNumber: n,
            startedAt: Date(),
            endedAt: nil,
            candidatesPerPrompt: run.candidatesPerPrompt,
            rowsAttempted: 0,
            rowsKept: 0,
            totalCandidates: 0,
            totalPasses: 0,
            datasetRelativePath: "\(run.id.uuidString)/round_\(n)/dataset",
            adapterRelativePath: roundJobID.uuidString,
            roundJobID: roundJobID,
            evalPassAtOne: nil
        )
        run.appendRound(roundRecord)
        try? context.save()

        let limitArg = run.rowsPerRound > 0 ? ["--limit", "\(run.rowsPerRound)"] : []
        var args: [String] = [
            (PathResolver.helpersDir.appendingPathComponent("self_improve_round.py")).path,
            "--seed", run.seedFile.path,
            "--out",  roundDir.path,
            "--model", model,
            "--candidates", "\(run.candidatesPerPrompt)",
            // Keep up to 2 distinct passing solutions per problem (not just the
            // first) — roughly doubles dataset diversity and is the main lever
            // against the tiny-keeper-set overfit documented in STATE.md Practice.
            "--keep-per-problem", "2",
            "--max-tokens", "512",
            "--temperature", "0.7",
            "--top-p", "0.95",
            "--row-timeout", "15",
        ] + limitArg
        if let pa = priorAdapter {
            args.append(contentsOf: ["--adapter", pa.path])
        }

        let env: [String: String] = [
            "HF_HOME": PathResolver.hfHome.path,
            "PYTHONUNBUFFERED": "1",
            "MLX_DISABLE_CUDA": "1",
        ]
        let process = try await ProcessRunner.spawn(executable: python, arguments: args, environment: env)
        activeProcess = process

        // Stream events; mutate roundRecord on key events.
        for await line in process.stdout {
            appendLog(line)
            handleRoundEvent(line, roundRecord: &roundRecord, run: run, context: context)
            // Apply running totals to status
            status.rowsTotal = roundRecord.rowsAttempted
            status.rowsDone  = roundRecord.rowsKept + (status.rowsDone > roundRecord.rowsKept ? status.rowsDone : 0)
        }
        // Drain stderr into log
        for await line in process.stderr {
            appendLog("[stderr] " + line)
        }
        let exit: ProcessExit
        do { exit = try await process.exit.value }
        catch { exit = ProcessExit(code: -1, signal: nil) }
        activeProcess = nil

        guard exit.code == 0 else {
            throw LoopError.process("self_improve_round exited \(exit.code)")
        }

        roundRecord.endedAt = Date()
        run.updateRound(roundRecord)
        try? context.save()
        run.writeSidecar()

        // — 3b. Train on the CUMULATIVE keeper buffer -----------------------------
        // Rejection fine-tuning / ReST: train each round on the growing, deduped
        // union of every round's keepers so far — not just this round's handful —
        // which was the documented cause of the tiny-dataset overfit curve.
        status.phase = .training
        status.headline = "Round \(n): studying what it got right…"

        let datasetDir = roundDir.appendingPathComponent("cumulative", isDirectory: true)
        let cumCounts = Self.buildCumulativeDataset(run: run, throughRound: n, into: datasetDir)
        let cumulativeTotal = cumCounts.train + cumCounts.valid
        status.detail = "\(cumulativeTotal) lessons so far (all rounds)"

        let adapterDir = PathResolver.adaptersDir.appendingPathComponent(roundJobID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: adapterDir, withIntermediateDirectories: true)

        let size = AutoTuner.categorize(repoID: run.baseModelRepoID)
        var tuned = AutoTuner.tune(size: size, dataPath: datasetDir.path,
                                   adapterPath: adapterDir.path, duration: .quick)
        // We want shorter rounds: cap iters at the user's per-round budget.
        tuned.iters = min(tuned.iters, max(20, run.trainIters))

        // mlx-lm refuses to train when `valid.jsonl` has fewer than `batch_size`
        // rows. For tiny rounds (which is the common shape early in a Practice
        // run — only a handful of candidates pass), shrink batch_size to fit.
        let validFile = datasetDir.appendingPathComponent("valid.jsonl")
        let validCount = countJSONLines(validFile)
        if validCount > 0, validCount < tuned.batchSize {
            tuned.batchSize = max(1, validCount)
        }
        // val_batches default (25) doesn't fit either — cap it.
        let valBatchesCap = max(1, validCount / max(1, tuned.batchSize))

        // Build the TrainingConfig directly so we can cap val_batches alongside
        // batch_size — AutoTuner.renderYAML uses the default val_batches (25)
        // which mlx-lm rejects when our tiny valid.jsonl can't fill it.
        var cfg = TrainingConfig.default
        cfg.model = model
        cfg.data = datasetDir.path
        cfg.adapterPath = adapterDir.path
        cfg.batchSize = tuned.batchSize
        cfg.iters = tuned.iters
        cfg.numLayers = tuned.numLayers
        cfg.maxSeqLength = tuned.maxSeqLength
        cfg.learningRate = tuned.learningRate
        cfg.gradAccumulationSteps = tuned.gradAccumulationSteps
        cfg.gradCheckpoint = tuned.gradCheckpoint
        cfg.loraRank = tuned.loraRank
        cfg.loraScale = tuned.loraScale
        cfg.loraTargetKeys = tuned.loraTargetKeys
        cfg.fineTuneType = .lora
        cfg.optimizer = tuned.optimizer
        cfg.maskPrompt = tuned.maskPrompt
        cfg.valBatches = valBatchesCap
        cfg.stepsPerEval = max(cfg.stepsPerEval, tuned.iters)   // skip mid-run eval on tiny rounds
        cfg.saveEvery = max(cfg.saveEvery, tuned.iters)

        let configURL = adapterDir.appendingPathComponent("config.yaml")
        try cfg.renderYAML().write(to: configURL, atomically: true, encoding: .utf8)

        try await runTraining(python: python, configURL: configURL, adapterDir: adapterDir)

        // — 3c. Eval new adapter --------------------------------------------------
        status.phase = .evaluating
        status.headline = "Round \(n): grading the practice…"
        let pass = try await runEval(python: python, model: model,
                                     adapter: adapterDir, evalFile: run.evalFile)
        roundRecord.evalPassAtOne = pass
        run.updateRound(roundRecord)
        status.passAtOneTrend = run.passAtOneTrend
        try? context.save()
        run.writeSidecar()
        appendLog(String(format: "round \(n) pass@1 = %.1f%%", pass * 100))

        return roundRecord
    }

    // MARK: – Cumulative keeper buffer (rejection fine-tuning / ReST)

    /// Merge every round's keeper rows into one growing, deduped training set,
    /// then re-split it deterministically into train/valid/test.
    ///
    /// This is the fix for the documented Practice overfit curve: training each
    /// round on only that round's handful of passers overfits a tiny dataset.
    /// Instead we train on the union of all rounds' keepers so far (textbook
    /// rejection fine-tuning / ReST).
    ///
    /// - Parameter roundsRows: one `[String]` of raw JSONL lines per round, in
    ///   round order (round 1 first … round n last). Each element is the union
    ///   of that round's train + valid + test lines.
    /// - Returns: deterministic train/valid/test line arrays.
    ///
    /// Dedup: keyed on `messages[0].content` (the user prompt). When the same
    /// prompt appears in multiple rounds the LAST occurrence wins (latest round
    /// = the most-improved model's solution). Lines that don't parse or carry no
    /// `messages[0].content` are skipped. Pure + `nonisolated static` so tests
    /// can call it with no main-actor hop and no filesystem.
    nonisolated static func mergeAndSplitKeepers(roundsRows: [[String]])
        -> (train: [String], valid: [String], test: [String]) {

        // Dedup by prompt key, last-occurrence-wins, but preserve a stable
        // first-seen order so the re-split is deterministic across runs.
        var lineByKey: [String: String] = [:]
        var orderByKey: [String: Int] = [:]
        var nextOrder = 0

        for round in roundsRows {
            for line in round {
                guard let key = Self.promptKey(from: line) else { continue }
                if orderByKey[key] == nil {
                    orderByKey[key] = nextOrder
                    nextOrder += 1
                }
                lineByKey[key] = line   // last write wins → latest round kept
            }
        }

        guard !lineByKey.isEmpty else { return ([], [], []) }

        // Stable order: first-seen index, tie-broken by key for full determinism.
        let orderedKeys = lineByKey.keys.sorted { a, b in
            let oa = orderByKey[a] ?? Int.max
            let ob = orderByKey[b] ?? Int.max
            return oa != ob ? oa < ob : a < b
        }
        let rows = orderedKeys.map { lineByKey[$0]! }
        let total = rows.count

        // Degenerate 1-row case: mlx-lm needs a non-empty valid set, so reuse
        // the single row across all three splits.
        if total == 1 {
            return ([rows[0]], [rows[0]], [rows[0]])
        }

        // Hold out ~10% as valid (at least 1 when total >= 2). test mirrors valid.
        let validCount = max(1, total / 10)
        let valid = Array(rows.suffix(validCount))
        let train = Array(rows.prefix(total - validCount))
        return (train, valid, valid)
    }

    /// Extracts the dedup key (`messages[0].content`) from one JSONL line, or
    /// nil if the line doesn't parse or has no first user message content.
    nonisolated private static func promptKey(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = obj["messages"] as? [[String: Any]],
              let first = messages.first,
              let content = first["content"] as? String
        else { return nil }
        return content
    }

    /// Reads each round's `dataset/{train,valid,test}.jsonl` (rounds 1…n,
    /// tolerating missing files), merges + re-splits via `mergeAndSplitKeepers`,
    /// and writes the cumulative `train/valid/test.jsonl` into `destDir`.
    /// Non-pure (touches disk) but `static` — no instance state.
    @discardableResult
    static func buildCumulativeDataset(run: SelfImproveRun,
                                       throughRound n: Int,
                                       into destDir: URL) -> (train: Int, valid: Int, test: Int) {
        var roundsRows: [[String]] = []
        for k in 1 ... max(1, n) {
            let dir = run.roundDir(k).appendingPathComponent("dataset", isDirectory: true)
            var rows: [String] = []
            for name in ["train.jsonl", "valid.jsonl", "test.jsonl"] {
                rows.append(contentsOf: readJSONLines(dir.appendingPathComponent(name)))
            }
            roundsRows.append(rows)
        }

        let split = mergeAndSplitKeepers(roundsRows: roundsRows)

        do {
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            try writeJSONLines(split.train, to: destDir.appendingPathComponent("train.jsonl"))
            try writeJSONLines(split.valid, to: destDir.appendingPathComponent("valid.jsonl"))
            try writeJSONLines(split.test,  to: destDir.appendingPathComponent("test.jsonl"))
        } catch {
            Log.error("Practice: failed to write cumulative dataset at \(destDir.path): \(error.localizedDescription)", .training, error: error)
        }

        return (split.train.count, split.valid.count, split.test.count)
    }

    /// Reads a JSONL file into non-empty lines. Returns [] when the file is
    /// missing or unreadable (tolerated — early rounds may lack some splits).
    nonisolated private static func readJSONLines(_ url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return [] }
        return text.split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    nonisolated private static func writeJSONLines(_ lines: [String], to url: URL) throws {
        let body = lines.joined(separator: "\n")
        let content = lines.isEmpty ? "" : body + "\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: – Subprocess wrappers

    private func pullSeed(python: URL, run: SelfImproveRun) async throws {
        let args: [String] = [
            PathResolver.helpersDir.appendingPathComponent("humaneval_pull.py").path,
            run.seed.rawValue,
            run.directory.path
        ]
        let process = try await ProcessRunner.spawn(executable: python, arguments: args,
                                                    environment: ["HF_HOME": PathResolver.hfHome.path,
                                                                  "PYTHONUNBUFFERED": "1"])
        activeProcess = process
        var err: String?
        for await line in process.stdout {
            appendLog(line)
            if let data = line.data(using: .utf8),
               let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let kind = event["event"] as? String {
                    switch kind {
                    case "progress":
                        if let msg = event["message"] as? String { status.detail = msg }
                    case "done":
                        let seed = event["seed"] as? Int ?? 0
                        let eval = event["eval"] as? Int ?? 0
                        status.detail = "\(seed) practice + \(eval) test problems"
                    case "error":
                        err = event["message"] as? String
                    default: break
                    }
                }
            }
        }
        for await line in process.stderr { appendLog("[stderr] " + line) }
        let exit = (try? await process.exit.value) ?? ProcessExit(code: -1, signal: nil)
        activeProcess = nil
        if exit.code != 0 {
            throw LoopError.helperEmittedError(err ?? "humaneval_pull exited \(exit.code)")
        }
    }

    private func runEval(python: URL, model: String, adapter: URL?, evalFile: URL) async throws -> Double {
        var args: [String] = [
            PathResolver.helpersDir.appendingPathComponent("eval_pass_rate.py").path,
            "--eval", evalFile.path,
            "--model", model,
            "--max-tokens", "512",
            "--temperature", "0.0",
            "--row-timeout", "15",
        ]
        if let a = adapter { args.append(contentsOf: ["--adapter", a.path]) }

        let env: [String: String] = [
            "HF_HOME": PathResolver.hfHome.path,
            "PYTHONUNBUFFERED": "1",
            "MLX_DISABLE_CUDA": "1"
        ]
        let process = try await ProcessRunner.spawn(executable: python, arguments: args, environment: env)
        activeProcess = process
        var passAtOne: Double?
        var rowsDone = 0
        var totalRows = 0
        for await line in process.stdout {
            appendLog(line)
            if let data = line.data(using: .utf8),
               let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let kind = event["event"] as? String {
                switch kind {
                case "start":
                    totalRows = event["rows"] as? Int ?? 0
                    status.detail = "Grading \(totalRows) test problems…"
                case "row":
                    rowsDone += 1
                    status.detail = "Graded \(rowsDone) of \(totalRows)"
                case "done":
                    // pass_at_1 is the k==1 alias; for k>1 the helper emits only
                    // pass_at_k. Read both so a k>1 run never silently reports 0%.
                    passAtOne = (event["pass_at_1"] as? Double) ?? (event["pass_at_k"] as? Double)
                case "error":
                    throw LoopError.helperEmittedError((event["message"] as? String) ?? "eval failed")
                default: break
                }
            }
        }
        for await line in process.stderr { appendLog("[stderr] " + line) }
        let exit = (try? await process.exit.value) ?? ProcessExit(code: -1, signal: nil)
        activeProcess = nil
        if exit.code != 0 { throw LoopError.process("eval exited \(exit.code)") }
        return passAtOne ?? 0
    }

    private func runTraining(python: URL, configURL: URL, adapterDir: URL) async throws {
        let env: [String: String] = [
            "HF_HOME": PathResolver.hfHome.path,
            "PYTHONUNBUFFERED": "1",
            "MLX_DISABLE_CUDA": "1"
        ]
        let process = try await ProcessRunner.spawn(
            executable: python,
            arguments: ["-m", "mlx_lm", "lora", "-c", configURL.path],
            environment: env
        )
        activeProcess = process

        let logURL = adapterDir.appendingPathComponent("training.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: logURL)
        _ = try? handle?.seekToEnd()

        var lastIter: Int = 0
        var lastLoss: Double?
        for await line in process.stdout {
            appendLog(line)
            if let data = (line + "\n").data(using: .utf8) { try? handle?.write(contentsOf: data) }
            if let step = LogStreamParser.parse(line) {
                lastIter = step.iter
                if !step.isEval, let l = step.trainLoss { lastLoss = l }
                if let l = lastLoss {
                    status.detail = "Iter \(lastIter) — loss \(String(format: "%.3f", l))"
                } else {
                    status.detail = "Iter \(lastIter)"
                }
            }
        }
        for await line in process.stderr {
            if let data = ("[stderr] " + line + "\n").data(using: .utf8) { try? handle?.write(contentsOf: data) }
            appendLog("[stderr] " + line)
        }
        try? handle?.close()

        let exit = (try? await process.exit.value) ?? ProcessExit(code: -1, signal: nil)
        activeProcess = nil
        if exit.code != 0 { throw LoopError.process("training exited \(exit.code)") }
    }

    // MARK: – Round-event JSON parsing

    private func handleRoundEvent(_ line: String,
                                  roundRecord: inout SelfImproveRoundRecord,
                                  run: SelfImproveRun,
                                  context: ModelContext) {
        guard let data = line.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = event["event"] as? String
        else { return }

        switch kind {
        case "start":
            let rows = event["rows"] as? Int ?? 0
            let cand = event["candidates"] as? Int ?? roundRecord.candidatesPerPrompt
            roundRecord.rowsAttempted = rows
            roundRecord.candidatesPerPrompt = cand
            roundRecord.totalCandidates = rows * cand
            status.rowsTotal = rows
            status.detail = "Trying \(rows) problems with \(cand) attempts each"

        case "row_start":
            if let i = event["i"] as? Int, let preview = event["prompt_preview"] as? String {
                status.detail = "Problem \(i + 1): \(preview)"
            }

        case "candidate":
            status.attemptsSoFar += 1
            if (event["status"] as? String) == "pass" { status.passesSoFar += 1 }
            roundRecord.totalPasses = status.passesSoFar

        case "row_done":
            if let passed = event["passed"] as? Bool, passed {
                roundRecord.rowsKept += 1
                status.rowsDone = roundRecord.rowsKept
            }

        case "done":
            if let r = event["pass_rate"] as? Double { roundRecord.totalPasses = Int(r * Double(roundRecord.totalCandidates)) }
            if let kept = event["kept"] as? Int { roundRecord.rowsKept = kept }
            status.detail = String(format: "Round complete — kept %d of %d problems", roundRecord.rowsKept, roundRecord.rowsAttempted)

        case "error":
            if let msg = event["message"] as? String { appendLog("[helper-error] " + msg) }

        default: break
        }
        run.updateRound(roundRecord)
        try? context.save()
    }

    // MARK: – Helpers

    private func appendLog(_ line: String) {
        logTail.append(line)
        if logTail.count > 1200 { logTail.removeFirst(logTail.count - 1200) }
    }

    private func fail(run: SelfImproveRun, context: ModelContext, error: any Error) {
        let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        run.status = .failed
        run.lastError = msg
        run.endedAt = Date()
        try? context.save()
        run.writeSidecar()
        Log.error("Practice run failed: \(msg)", .training)
        status.phase = .failed
        status.headline = "Stopped"
        status.detail = msg
        activeProcess = nil
    }

    /// Persist a user-initiated cancel as the cancelled terminal state (not .failed).
    private func cancelled(run: SelfImproveRun, context: ModelContext) {
        run.status = .cancelled
        run.lastError = nil
        run.endedAt = Date()
        try? context.save()
        run.writeSidecar()
        status.phase = .cancelled
        status.headline = "Stopped"
        status.detail = "Cancelled."
        activeProcess = nil
    }

    /// Mirrors `TrainingConfigView.resolveModelArg`. Always prefer a registry
    /// hit, even for HF-shaped `owner/repo` IDs — otherwise mlx-lm's hf_hub
    /// resolver looks under `<HF_HOME>/hub/` (the wrong layout) and triggers
    /// a 28 GB re-download. See the longer comment over in TrainingConfigView.
    private func resolveModelArg(_ repoOrName: String) -> String {
        let registry = ModelRegistry.shared
        if let local = registry.localModels.first(where: { $0.repoID == repoOrName }) {
            return local.directory.path
        }
        return repoOrName
    }

    private static func fetchRun(id: UUID, context: ModelContext) -> SelfImproveRun? {
        let descriptor = FetchDescriptor<SelfImproveRun>(predicate: #Predicate { $0.id == id })
        return (try? context.fetch(descriptor))?.first
    }

    private func countJSONLines(_ url: URL) -> Int {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return 0 }
        return text.split(whereSeparator: \.isNewline).filter { !$0.isEmpty }.count
    }
}
