import Foundation
import SwiftUI

// Runs `python -m mlx_lm server` as a long-lived daemon and exposes it as a
// local OpenAI-compatible endpoint for the coding agent. Starting one is what
// finally answers STATE.md's "pin the model in memory" question: the model is
// loaded ONCE here and reused for every agent turn, instead of paying the
// 60–90 s cold-load on every message like the per-turn `mlx_lm generate` path
// in InferenceService does.
//
// Lifecycle: start() → pick a free localhost port → spawn the server → wait for
// it to listen (/health) → fire a 1-token warm-up request to force the model
// load and surface load/adapter errors early → .ready. stop() tears it down.
@MainActor
@Observable
final class MLXServerService {
    static let shared = MLXServerService()

    enum State: Equatable {
        case stopped
        case starting(String)
        case ready(port: Int)
        case failed(String)
    }

    private(set) var state: State = .stopped {
        didSet {
            switch state {
            case .failed(let msg): Log.error("Model server failed: \(msg)", .server)
            case .ready(let port): Log.info("Model server ready on port \(port)", .server)
            default: break
            }
        }
    }
    private(set) var model: String = ""
    private(set) var adapterPath: String?
    private(set) var logTail: [String] = []

    /// The exact `--model` string the server was launched with (an absolute
    /// path for local models). Sent as the request `model` field so the server
    /// never tries to hot-swap to a differently-named model mid-session.
    private(set) var loadedModelArg: String = ""

    private var process: RunningProcess?
    private var exitWatcher: Task<Void, Never>?
    /// Bumped on every start()/stop() so a stale process's exit handler can tell
    /// it's been superseded and stay quiet.
    private var generation = 0

    private init() {}

    var isReady: Bool { if case .ready = state { return true } else { return false } }

    var baseURL: URL? {
        if case .ready(let port) = state { return URL(string: "http://127.0.0.1:\(port)/v1") }
        return nil
    }

    var statusText: String {
        switch state {
        case .stopped:            "No model loaded"
        case .starting(let s):    s
        case .ready:              "\(shortName(model)) is loaded and ready"
        case .failed(let s):      s
        }
    }

    // MARK: - Lifecycle

    func start(model: String, adapterPath: String?) async {
        // Wait for the old server to fully exit before spawning the new one — a
        // multi-GB mlx_lm server briefly coexisting with its replacement is the
        // memory spike this guards against.
        await stopAndWait()
        generation += 1
        let gen = generation

        guard PythonRuntime.shared.isReady, let python = PythonRuntime.shared.pythonURL else {
            state = .failed("The Python runtime isn't ready yet. Finish first-run setup, then try again.")
            return
        }

        let resolved = resolveModelArg(model)
        self.model = model
        self.adapterPath = adapterPath
        self.loadedModelArg = resolved
        logTail.removeAll()

        let port = findFreePort()
        state = .starting("Starting model server…")

        // DiffusionGemma is a masked/block-diffusion LM with no autoregressive
        // mlx-lm class, so it can't be served by `mlx_lm server`. When the model
        // is diffusion, swap ONLY the argv for the vendored diffusion_server.py
        // (which serves the same OpenAI-compatible /v1/chat/completions + /health
        // the rest of this lifecycle expects). Diffusion models have no LoRA, so
        // `adapterPath` is intentionally ignored on this branch. Everything else —
        // findFreePort, the spawn, waitForServerUp, the warm-up complete(), the
        // exit-watcher and state machine — is reused unchanged.
        let isDiffusion = isDiffusionModel(repoOrName: model, resolvedPath: resolved)
        var args: [String]
        if isDiffusion {
            args = [PathResolver.helpersDir.appendingPathComponent("diffusion_server.py").path,
                    "--model", resolved,
                    "--host", "127.0.0.1",
                    "--port", "\(port)"]
        } else {
            args = ["-m", "mlx_lm", "server",
                    "--model", resolved,
                    "--host", "127.0.0.1",
                    "--port", "\(port)",
                    "--log-level", "INFO"]
            if let adapterPath, !adapterPath.isEmpty {
                args += ["--adapter-path", adapterPath]
            }
        }

        // Apply the optional MLX memory budget from the Memory tab (no-op when
        // off). wrap() prepends mlx_run.py, which runs `-m mlx_lm …` via runpy AND
        // a bare script path via runpy.run_path — so the diffusion_server.py script
        // argv is launched correctly with the same Apple-Silicon memory tuning.
        let wrapped = MemoryService.wrap(args)
        var env = ["HF_HOME": PathResolver.hfHome.path, "PYTHONUNBUFFERED": "1"]
        for (k, v) in wrapped.env { env[k] = v }

        Log.info("spawn: \(wrapped.arguments.joined(separator: " "))", .server)

        let proc: RunningProcess
        do {
            proc = try await ProcessRunner.spawn(executable: python, arguments: wrapped.arguments, environment: env)
        } catch {
            state = .failed("Couldn't launch the model server: \(error.localizedDescription)")
            return
        }
        // A second start()/stop() during the spawn await bumps `generation`; if we
        // assigned self.process anyway we'd overwrite the successor's handle and
        // orphan OUR child — a multi-GB server with no owner. We lost the race:
        // kill the process we just made and defer to the newer call.
        guard gen == generation else {
            proc.terminate()
            return
        }
        self.process = proc
        tail(proc.stdout)
        tail(proc.stderr)

        exitWatcher = Task { [weak self] in
            let exit = try? await proc.exit.value
            self?.handleServerExit(generation: gen, code: exit?.code)
        }

        // 1. Wait for the HTTP server to bind.
        let up = await waitForServerUp(port: port, timeout: 30)
        guard gen == generation else { return }            // superseded by another start/stop
        if case .failed = state { return }                 // exit handler already spoke
        guard up else {
            state = .failed("The model server didn't start listening. \(lastLogLines())")
            proc.terminate()
            return
        }

        // 2. Warm up — forces the model to load now (so the first real message
        //    isn't a surprise 90 s wait) and surfaces bad-adapter / OOM errors.
        state = .starting("Loading \(shortName(model)) into memory…")
        do {
            let client = OpenAIChatClient(baseURL: URL(string: "http://127.0.0.1:\(port)/v1")!)
            _ = try await client.complete(ChatCompletionRequest(
                model: resolved,
                messages: [ChatWireMessage(role: "user", content: "ready")],
                tools: nil, temperature: 0, maxTokens: 1))
            guard gen == generation else { return }
            if case .failed = state { return }
            state = .ready(port: port)
        } catch {
            guard gen == generation else { return }
            state = .failed("The model failed to load: \(error.localizedDescription) \(lastLogLines())")
            proc.terminate()
        }
    }

    func stop() {
        generation += 1                                    // invalidate any in-flight start/exit
        exitWatcher?.cancel()
        exitWatcher = nil
        process?.terminate()
        process = nil
        state = .stopped
    }

    /// Like `stop()`, but waits for the old server process to actually exit (and
    /// release its multi-GB model from unified memory) before returning, so a
    /// caller about to load a new model never double-occupies memory. Bounded by a
    /// short timeout: if the process won't die in time, escalate from SIGTERM to
    /// SIGKILL, then proceed regardless.
    private func stopAndWait() async {
        generation += 1                                    // invalidate any in-flight start/exit
        exitWatcher?.cancel()
        exitWatcher = nil
        guard let oldProc = process else {
            state = .stopped
            return
        }
        process = nil
        state = .stopped

        oldProc.terminate()
        let exited = await awaitExit(of: oldProc, timeout: 8)
        if !exited {
            // SIGTERM didn't take in time — escalate to a hard kill, then give it
            // a brief moment to actually release memory before we return.
            Log.error("Model server didn't exit on terminate; sending SIGKILL", .server)
            oldProc.kill()
            _ = await awaitExit(of: oldProc, timeout: 3)
        }
    }

    /// Awaits a process's exit, capped at `timeout` seconds. Returns true if it
    /// exited within the budget, false on timeout.
    private func awaitExit(of proc: RunningProcess, timeout: TimeInterval) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                _ = try? await proc.exit.value
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    private func handleServerExit(generation gen: Int, code: Int32?) {
        guard gen == generation else { return }            // an old process we already replaced
        process = nil
        // An exit while we thought it was up/loading means it crashed.
        switch state {
        case .stopped, .failed:
            break
        default:
            state = .failed("The model server stopped unexpectedly (exit \(code ?? -1)). \(lastLogLines())")
        }
    }

    // MARK: - Helpers

    /// Mirrors `SelfImproveService.resolveModelArg` / `TrainingConfigView` — a
    /// registry hit becomes an absolute path so mlx-lm loads from our cache
    /// layout instead of re-downloading under `<HF_HOME>/hub/`.
    private func resolveModelArg(_ repoOrName: String) -> String {
        if let local = ModelRegistry.shared.localModels.first(where: { $0.repoID == repoOrName }) {
            return local.directory.path
        }
        return repoOrName
    }

    /// Decide whether a model must be served by `diffusion_server.py` instead of
    /// `mlx_lm server`. Mirrors `InferenceService.isDiffusionModel`: prefer the
    /// registry's `isDiffusion` flag (`ModelRegistry.scan()` derives it from
    /// config.json for both HF-cache and custom-dir models); fall back to reading
    /// the resolved directory's own `config.json` `model_type == "diffusion_gemma"`
    /// (covers a freshly-downloaded model the registry hasn't rescanned yet, as
    /// long as we resolved to a local path). Both run on the @MainActor, so no hop.
    private func isDiffusionModel(repoOrName: String, resolvedPath: String) -> Bool {
        if let flagged = ModelRegistry.shared.localModels.first(where: { $0.repoID == repoOrName })?.isDiffusion {
            return flagged
        }
        let configURL = URL(fileURLWithPath: resolvedPath).appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        let modelType = (json["model_type"] as? String)?.lowercased() ?? ""
        let archNames = (json["architectures"] as? [String]) ?? []
        return modelType == "diffusion_gemma"
            || archNames.contains { $0.hasPrefix("DiffusionGemma") }
    }

    private func tail(_ stream: AsyncStream<String>) {
        Task { [weak self] in
            for await line in stream {
                self?.appendLog(line)
            }
        }
    }

    private func appendLog(_ line: String) {
        logTail.append(line)
        if logTail.count > 400 { logTail.removeFirst(logTail.count - 400) }
    }

    private func lastLogLines(_ n: Int = 4) -> String {
        let tail = logTail.suffix(n).joined(separator: " ")
        return tail.isEmpty ? "" : "(\(tail))"
    }

    private func shortName(_ repo: String) -> String {
        repo.split(separator: "/").last.map(String.init) ?? repo
    }

    private func waitForServerUp(port: Int, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        while Date() < deadline {
            if Task.isCancelled { return false }
            var req = URLRequest(url: url)
            req.timeoutInterval = 2
            // Any HTTP reply (even 404) proves the server is listening.
            if let (_, resp) = try? await URLSession.shared.data(for: req), resp is HTTPURLResponse {
                return true
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return false
    }

    /// Ask the kernel for an unused TCP port by binding to port 0. Falls back to
    /// 8080 if anything goes sideways. A tiny race window exists between close
    /// and the server's bind, acceptable for a localhost dev tool.
    private func findFreePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return 8080 }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = in_addr_t(0)               // INADDR_ANY
        addr.sin_port = 0
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { return 8080 }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        var local = sockaddr_in()
        let nameResult = withUnsafeMutablePointer(to: &local) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard nameResult == 0 else { return 8080 }
        return Int(UInt16(bigEndian: local.sin_port))
    }
}
