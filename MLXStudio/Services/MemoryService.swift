import Foundation
import SwiftUI

/// Memory & expert management hub.
///
/// Three jobs:
///  1. **Device facts** — the Metal GPU working-set ceiling + total unified
///     memory (via `mem_probe.py`). On Apple Silicon unified memory, the live
///     "used" number comes from `SystemMetrics` (it already includes GPU
///     buffers); the value the user really needs is the *ceiling* that triggers
///     the `kIOGPUCommandBufferCallbackErrorOutOfMemory` crash, which the OS
///     RAM gauge doesn't show.
///  2. **Per-model breakdown** — how much of a model is experts vs everything
///     else, and how much is actually active per token (via `model_memory.py`,
///     header-only, no weight load).
///  3. **Expert profiling + prune** — which experts actually fire on a prompt
///     set (via `profile_experts.py`), and a one-click prune of the cold ones
///     through `ExpertManagementService`.
///
/// Also owns the **memory budget** (an optional cap applied to training /
/// inference subprocesses via `mx.set_memory_limit`).
@MainActor
@Observable
final class MemoryService {
    static let shared = MemoryService()
    private init() {
        let d = UserDefaults.standard
        budgetEnabled = d.bool(forKey: Self.kBudgetEnabled)
        let frac = d.double(forKey: Self.kBudgetFraction)
        budgetFraction = frac > 0 ? frac : 0.9
    }

    // MARK: - Device facts

    struct DeviceInfo: Equatable {
        var maxWorkingSet: Int64    // Metal recommended working-set ceiling (the OOM threshold)
        var deviceMemory: Int64     // total unified memory the GPU sees
        var deviceName: String
    }
    private(set) var device: DeviceInfo?

    func loadDeviceInfo() async {
        guard device == nil else { return }
        guard PythonRuntime.shared.isReady, let python = PythonRuntime.shared.pythonURL else { return }
        let helper = PathResolver.helpersDir.appendingPathComponent("mem_probe.py")
        guard FileManager.default.fileExists(atPath: helper.path) else { return }
        let out = try? await ProcessRunner.runCapturing(
            executable: python, arguments: [helper.path],
            environment: ["PYTHONUNBUFFERED": "1"])
        guard let json = Self.lastJSON(out ?? "") else { return }
        device = DeviceInfo(
            maxWorkingSet: (json["max_recommended_working_set"] as? NSNumber)?.int64Value ?? 0,
            deviceMemory: (json["device_memory"] as? NSNumber)?.int64Value ?? 0,
            deviceName: (json["device_name"] as? String) ?? "Apple Silicon GPU")
    }

    // MARK: - Per-model breakdown

    struct ModelBreakdown: Equatable {
        var total: Int64
        var expert: Int64
        var nonexpert: Int64
        var numExperts: Int
        var topK: Int
        var perExpert: Int64
        var activeEstimate: Int64
        var shards: Int
        var tensors: Int

        var expertFraction: Double { total > 0 ? Double(expert) / Double(total) : 0 }
        var isMoE: Bool { numExperts > 1 }
    }
    private(set) var breakdown: ModelBreakdown?
    private(set) var breakdownModelID: String?
    private(set) var breakdownLoading = false

    func computeBreakdown(for model: ModelRegistry.DetectedModel) {
        breakdownLoading = true
        breakdownModelID = model.repoID
        breakdown = nil
        let dir = model.directory
        Task { @MainActor in
            defer { breakdownLoading = false }
            guard PythonRuntime.shared.isReady, let python = PythonRuntime.shared.pythonURL else { return }
            let helper = PathResolver.helpersDir.appendingPathComponent("model_memory.py")
            guard FileManager.default.fileExists(atPath: helper.path) else { return }
            let out = try? await ProcessRunner.runCapturing(
                executable: python, arguments: [helper.path, dir.path],
                environment: ["PYTHONUNBUFFERED": "1"])
            guard let j = Self.lastJSON(out ?? ""), (j["event"] as? String) == "done" else { return }
            // Ignore if the user switched models while we were computing.
            guard breakdownModelID == model.repoID else { return }
            func i64(_ k: String) -> Int64 { (j[k] as? NSNumber)?.int64Value ?? 0 }
            func i(_ k: String) -> Int { (j[k] as? NSNumber)?.intValue ?? 0 }
            breakdown = ModelBreakdown(
                total: i64("total"), expert: i64("expert"), nonexpert: i64("nonexpert"),
                numExperts: i("num_experts"), topK: i("top_k"), perExpert: i64("per_expert"),
                activeEstimate: i64("active_estimate"), shards: i("shards"), tensors: i("tensors"))
        }
    }

    // MARK: - Expert profiling

    enum ProfileStage: Equatable {
        case idle
        case running(String)
        case done
        case failed(String)
    }
    struct ProfileResult: Equatable {
        var numExperts: Int
        var topK: Int
        var decisions: Int
        var counts: [Int]
        var fractions: [Double]
        var cold: [Int]
        var avgCount: Double
        var prompts: Int
    }
    private(set) var profileStage: ProfileStage = .idle
    private(set) var profileResult: ProfileResult?
    private(set) var profilingModelID: String?

    var isProfiling: Bool {
        if case .running = profileStage { return true }
        return false
    }

    func profileExperts(for model: ModelRegistry.DetectedModel, maxPrompts: Int = 16) {
        guard model.isMoE, !isProfiling else { return }
        guard PythonRuntime.shared.isReady, let python = PythonRuntime.shared.pythonURL else {
            profileStage = .failed("Python runtime is not ready yet."); return
        }
        let helper = PathResolver.helpersDir.appendingPathComponent("profile_experts.py")
        guard FileManager.default.fileExists(atPath: helper.path) else {
            profileStage = .failed("profile_experts.py missing — restart the app to refresh helpers."); return
        }
        profileStage = .running("Starting…")
        profileResult = nil
        profilingModelID = model.repoID
        let dir = model.directory
        let argsJSON = "{\"max_prompts\": \(maxPrompts)}"
        Task { @MainActor in
            do {
                _ = try await ProcessRunner.runCapturing(
                    executable: python,
                    arguments: [helper.path, dir.path, argsJSON],
                    environment: ["PYTHONUNBUFFERED": "1", "HF_HOME": PathResolver.hfHome.path],
                    onStdout: { [weak self] line in
                        Task { @MainActor in self?.handleProfileLine(line) }
                    },
                    onStderr: { _ in })
            } catch {
                try? await Task.sleep(for: .milliseconds(300))
                await MainActor.run {
                    if case .failed = profileStage {} else {
                        profileStage = .failed(error.localizedDescription)
                    }
                }
            }
        }
    }

    private func handleProfileLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        switch j["event"] as? String {
        case "progress":
            profileStage = .running((j["message"] as? String) ?? "Working…")
        case "done":
            func ints(_ k: String) -> [Int] { (j[k] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? [] }
            func dbls(_ k: String) -> [Double] { (j[k] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? [] }
            profileResult = ProfileResult(
                numExperts: (j["num_experts"] as? NSNumber)?.intValue ?? 0,
                topK: (j["top_k"] as? NSNumber)?.intValue ?? 0,
                decisions: (j["decisions"] as? NSNumber)?.intValue ?? 0,
                counts: ints("counts"),
                fractions: dbls("fractions"),
                cold: ints("cold"),
                avgCount: (j["avg_count"] as? NSNumber)?.doubleValue ?? 0,
                prompts: (j["prompts"] as? NSNumber)?.intValue ?? 0)
            profileStage = .done
        case "error":
            profileStage = .failed((j["message"] as? String) ?? "Profiling failed")
        default:
            break
        }
    }

    /// Prune the given expert indices into a new model via the existing
    /// expert-management pipeline. Returns immediately; progress is on
    /// `ExpertManagementService.shared.active`.
    func pruneExperts(from model: ModelRegistry.DetectedModel, indices: Set<Int>, outputName: String) {
        ExpertManagementService.shared.remove(input: model, outputName: outputName, indices: indices)
    }

    // MARK: - Memory budget

    private static let kBudgetEnabled = "memBudgetEnabled"
    private static let kBudgetFraction = "memBudgetFraction"

    var budgetEnabled: Bool {
        didSet { UserDefaults.standard.set(budgetEnabled, forKey: Self.kBudgetEnabled) }
    }
    /// Fraction of the Metal working-set ceiling to cap mlx at (0.5–1.0).
    var budgetFraction: Double {
        didSet { UserDefaults.standard.set(budgetFraction, forKey: Self.kBudgetFraction) }
    }

    /// Bytes to pass to `mx.set_memory_limit` given the detected ceiling, or nil
    /// if budgeting is off / ceiling unknown.
    var budgetBytes: Int64? {
        guard budgetEnabled, let mws = device?.maxWorkingSet, mws > 0 else { return nil }
        return Int64(Double(mws) * budgetFraction)
    }

    /// Wrap an mlx_lm CLI argument vector with the `mlx_run.py` launcher. Pass the
    /// args you'd normally hand to python, starting with "-m".
    ///
    /// We **always** route through the launcher (not just when the Memory-tab
    /// budget is on) so `mlx_run.py` applies Apple-Silicon-aware MLX memory
    /// management on every run — re-pinning the memory/cache/wired limits to the
    /// real Metal working-set ceiling so a large run frees its cache before a hard
    /// OOM instead of crashing. When the user sets an explicit budget it's passed
    /// as `MLXSTUDIO_MEMORY_LIMIT_BYTES`, which overrides the auto memory limit.
    /// If the helper is somehow missing this degrades to a transparent passthrough.
    static func wrap(_ arguments: [String]) -> (arguments: [String], env: [String: String]) {
        let runner = PathResolver.helpersDir.appendingPathComponent("mlx_run.py").path
        guard FileManager.default.fileExists(atPath: runner) else { return (arguments, [:]) }
        var env: [String: String] = [:]
        if let bytes = shared.budgetBytes { env["MLXSTUDIO_MEMORY_LIMIT_BYTES"] = "\(bytes)" }
        return ([runner] + arguments, env)
    }

    // MARK: - Helpers

    private static func lastJSON(_ output: String) -> [String: Any]? {
        for line in output.split(separator: "\n").reversed() {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("{"), let data = t.data(using: .utf8),
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            return j
        }
        return nil
    }

    static func gb(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }
}
