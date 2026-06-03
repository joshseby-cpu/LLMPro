import Foundation

/// Drives the `inspect_attention.py` sidecar: runs one forward pass through a model
/// and accumulates per-layer (mean-over-heads) attention matrices for the heatmap.
/// Mirrors the spawn + line-stream + JSON-event pattern used by `SelfImproveService`.
@MainActor
@Observable
final class AttentionInspectService {
    private(set) var isRunning = false
    private(set) var statusLine = ""
    private(set) var unsupported = false
    private(set) var truncated = false
    private(set) var error: String?
    /// One seq×seq matrix per layer, ordered by layer index.
    private(set) var layers: [[[Float]]] = []
    private(set) var tokens: [String] = []

    private var process: RunningProcess?
    private var byLayer: [Int: [[Float]]] = [:]

    /// Hard cap on prompt length — attention is O(L²·heads·layers), so we keep it
    /// short to stay well under the Metal working-set ceiling.
    static let maxSeq = 64

    func cancel() {
        process?.terminate()
        process = nil
        isRunning = false
        statusLine = "Stopped."
    }

    func run(model: ModelRegistry.DetectedModel, prompt: String) {
        guard !isRunning else { return }
        guard PythonRuntime.shared.isReady, let python = PythonRuntime.shared.pythonURL else {
            error = "The Python runtime isn't ready yet. Wait for the dot in the sidebar to turn green."
            return
        }
        // Reset state.
        isRunning = true
        unsupported = false
        truncated = false
        error = nil
        layers = []
        tokens = []
        byLayer = [:]
        statusLine = "Loading the model…"

        // mlx-lm treats a bare string (no "/") as an HF repo id, so always hand it
        // the absolute on-disk snapshot path (same rule as TrainingConfigView).
        let modelArg = model.directory.path
        let helper = PathResolver.helpersDir.appendingPathComponent("inspect_attention.py").path
        let args = [
            helper,
            "--model", modelArg,
            "--prompt", prompt,
            "--max-seq", "\(Self.maxSeq)",
            "--head", "mean",
        ]
        let env: [String: String] = [
            "HF_HOME": PathResolver.hfHome.path,
            "PYTHONUNBUFFERED": "1",
            "MLX_DISABLE_CUDA": "1",
            // Self-pin memory: this helper does NOT go through mlx_run.py.
            "MLXSTUDIO_MEM_LIMIT_GB": "108",
        ]

        Task { @MainActor in
            do {
                let proc = try await ProcessRunner.spawn(executable: python, arguments: args, environment: env)
                self.process = proc
                for await line in proc.stdout {
                    self.handleEvent(line)
                }
                var collectedErr = ""
                for await line in proc.stderr { collectedErr += line + "\n" }
                let exit = (try? await proc.exit.value) ?? ProcessExit(code: -1, signal: nil)
                if exit.code != 0, self.error == nil, !self.unsupported {
                    let tail = collectedErr.split(separator: "\n").suffix(3).joined(separator: " ")
                    self.error = "The inspector couldn't read attention (exit \(exit.code)). \(tail)"
                }
            } catch {
                self.error = error.localizedDescription
            }
            self.process = nil
            self.isRunning = false
            if self.error == nil, !self.unsupported, self.layers.isEmpty {
                self.error = "No attention was captured."
            }
            if let e = self.error { Log.error("Attention inspect failed: \(e)", .inspect) }
        }
    }

    // MARK: Event handling (one JSON object per line)

    private func handleEvent(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = obj["event"] as? String
        else { return }

        switch event {
        case "start":
            if let toks = obj["tokens"] as? [String] { tokens = toks }
            if let t = obj["truncated"] as? Bool { truncated = t }
            let nl = (obj["n_layers"] as? NSNumber)?.intValue ?? 0
            statusLine = "Running one forward pass through \(nl) layers…"
        case "unsupported":
            unsupported = true
            statusLine = ""
        case "progress":
            if let stage = obj["stage"] as? String { statusLine = stage == "forward" ? "Computing attention…" : stage }
        case "layer":
            guard let idx = (obj["layer"] as? NSNumber)?.intValue,
                  let rows = obj["weights"] as? [[Any]] else { return }
            let matrix: [[Float]] = rows.map { row in
                row.map { ($0 as? NSNumber)?.floatValue ?? 0 }
            }
            byLayer[idx] = matrix
            layers = byLayer.keys.sorted().map { byLayer[$0]! }
            statusLine = "Captured layer \(idx)…"
        case "done":
            statusLine = ""
        case "error":
            error = (obj["message"] as? String) ?? "Unknown error."
        default:
            break
        }
    }
}
