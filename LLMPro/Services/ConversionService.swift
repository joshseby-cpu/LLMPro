import Foundation

enum ConversionQuant: String, CaseIterable, Identifiable {
    case none, q4, q8
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .none: "Keep fp16"
        case .q4:   "4-bit (smallest, fastest)"
        case .q8:   "8-bit (balance)"
        }
    }
}

actor ConversionService {
    static let shared = ConversionService()

    func convert(hfRepoID: String, quant: ConversionQuant, mlxPath: String) async throws {
        guard await PythonRuntime.shared.isReady, let python = await PythonRuntime.shared.pythonURL else {
            throw NSError(domain: "ConversionService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Python runtime not ready"])
        }
        var args: [String] = ["-m", "mlx_lm", "convert", "--hf-path", hfRepoID, "--mlx-path", mlxPath]
        switch quant {
        case .none: break
        case .q4: args.append(contentsOf: ["-q", "--q-bits", "4"])
        case .q8: args.append(contentsOf: ["-q", "--q-bits", "8"])
        }
        try await ProcessRunner.runCapturing(
            executable: python,
            arguments: args,
            environment: ["HF_HOME": PathResolver.hfHome.path]
        )
    }
}
