import Foundation
import SwiftData

/// Applies a finished training run into the model it trained on — the user's
/// "training should modify the model" choice — by producing a NEW, ready-to-use
/// model in the custom models folder (the original is always kept).
///
/// The normal flow leaves the trained LoRA as a separate adapter (Save & Use fuses
/// it into a new model on demand). When a job has `applyToModelInPlace == true`,
/// this service does that fuse automatically the moment training finishes, so the
/// result shows up in the Models list immediately — no manual export step.
///
/// ## Design: a copy, never an overwrite (deliberate, safe)
/// We fuse base+adapter into `models/<name>-trained` and register it. The source
/// model is never modified or deleted. This sidesteps every corruption risk:
/// - The shared HF download cache is read-only-shared (re-download dedup + other
///   tools rely on it); we never touch it.
/// - A crash mid-fuse leaves only a discardable temp dir; the model you trained on
///   is exactly as it was.
/// Fusing a quantized base **dequantizes** it (mlx-lm limitation), so the trained
/// copy comes out full-precision (larger); we surface that in the outcome string.
@MainActor
@Observable
final class ModelApplyService {
    static let shared = ModelApplyService()
    private init() {}

    /// Live status for the most recent / in-flight apply, for the Progress UI.
    enum Phase: Equatable {
        case idle
        case fusing(model: String)
        case validating
        case done(modelName: String, modelPath: String, dequantized: Bool)
        case failed(reason: String)
    }
    private(set) var phase: Phase = .idle {
        didSet {
            switch phase {
            case .failed(let r): Log.error("Apply-to-model failed: \(r)", .model)
            case .done(let name, _, _): Log.info("Apply-to-model done → new model \(name)", .model)
            default: break
            }
        }
    }

    enum ApplyError: LocalizedError {
        case sourceMissing
        case adapterMissing
        case fuseFailed(String)
        case validateFailed(String)
        var errorDescription: String? {
            switch self {
            case .sourceMissing:         "The model to apply training to is no longer on disk."
            case .adapterMissing:        "The trained adapter weights are missing — nothing to apply."
            case .fuseFailed(let m):     "Couldn't merge the training into the model: \(m)"
            case .validateFailed(let m): "The merged model didn't validate, so nothing was saved: \(m)"
            }
        }
    }

    /// Fuse `adapterDir` into the model identified by `repoID` and save the result
    /// as a new model under `models/`. Returns the path of the new model on success.
    /// The original model is always left untouched.
    @discardableResult
    func apply(repoID: String, adapterDir: URL) async throws -> URL {
        let fm = FileManager.default

        guard let model = ModelRegistry.shared.localModels.first(where: { $0.repoID == repoID })
        else { phase = .failed(reason: ApplyError.sourceMissing.localizedDescription); throw ApplyError.sourceMissing }
        let sourceDir = model.directory
        guard fm.fileExists(atPath: sourceDir.path) else {
            phase = .failed(reason: ApplyError.sourceMissing.localizedDescription); throw ApplyError.sourceMissing
        }
        let adapterFile = adapterDir.appendingPathComponent("adapters.safetensors")
        guard fm.fileExists(atPath: adapterFile.path) else {
            phase = .failed(reason: ApplyError.adapterMissing.localizedDescription); throw ApplyError.adapterMissing
        }

        let dequantized = !model.quantization.isEmpty && model.quantization.lowercased() != "none"

        // Pick a unique destination name in models/: "<model>-trained" (+N).
        let baseName = model.displayName + "-trained"
        var name = baseName
        var finalDir = PathResolver.modelsCustomDir.appendingPathComponent(name, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: finalDir.path) {
            name = "\(baseName)-\(n)"; n += 1
            finalDir = PathResolver.modelsCustomDir.appendingPathComponent(name, isDirectory: true)
        }

        // 1. FUSE into a temp dir first — the new model only "appears" once it's
        //    complete and validated, so a partial/failed fuse never registers.
        phase = .fusing(model: model.displayName)
        let tmpFused = PathResolver.modelsCustomDir
            .appendingPathComponent(".apply-\(UUID().uuidString)", isDirectory: true)
        try? fm.removeItem(at: tmpFused)
        do {
            try await FuseService.shared.fuse(
                baseModel: sourceDir.path,
                adapterPath: adapterDir.path,
                savePath: tmpFused.path
            )
        } catch {
            try? fm.removeItem(at: tmpFused)
            phase = .failed(reason: ApplyError.fuseFailed(error.localizedDescription).localizedDescription)
            throw ApplyError.fuseFailed(error.localizedDescription)
        }

        // 2. VALIDATE — must have config + weights or we discard and keep nothing.
        phase = .validating
        let hasConfig = fm.fileExists(atPath: tmpFused.appendingPathComponent("config.json").path)
        let hasWeights = ((try? fm.contentsOfDirectory(atPath: tmpFused.path)) ?? [])
            .contains { $0.hasSuffix(".safetensors") }
        guard hasConfig && hasWeights else {
            try? fm.removeItem(at: tmpFused)
            let why = "merged output was incomplete (config=\(hasConfig), weights=\(hasWeights))"
            phase = .failed(reason: ApplyError.validateFailed(why).localizedDescription)
            throw ApplyError.validateFailed(why)
        }

        // 3. Move the validated temp dir into its final models/ name + register it.
        do {
            try fm.moveItem(at: tmpFused, to: finalDir)
        } catch {
            try? fm.removeItem(at: tmpFused)
            phase = .failed(reason: ApplyError.fuseFailed(error.localizedDescription).localizedDescription)
            throw ApplyError.fuseFailed(error.localizedDescription)
        }

        await ModelRegistry.shared.scan()
        phase = .done(modelName: name, modelPath: finalDir.path, dequantized: dequantized)
        return finalDir
    }
}
