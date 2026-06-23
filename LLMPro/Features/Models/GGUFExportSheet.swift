import SwiftUI

/// Direct "Export to GGUF" for a single local model — no adapter, no fuse step.
/// Converts a full-precision (fp16/bf16) text model straight to a `.gguf` file
/// you can drop into Ollama or LM Studio. Quantized and diffusion models can't
/// be converted this way, so the sheet gates them out with a friendly note.
struct GGUFExportSheet: View {
    let model: ModelRegistry.DetectedModel
    @Environment(\.dismiss) private var dismiss

    @State private var quant: GGUFQuant = .q4_k_m
    @State private var outputName: String = ""
    @State private var log: [String] = []
    @State private var exporting = false
    @State private var error: String?
    @State private var exportedPath: URL?
    @State private var selfTest: GGUFSelfTest?

    @State private var llamaCppInstalled = false
    @State private var installingLlamaCpp = false
    /// The compiled llama.cpp binaries (llama-quantize + llama-cli). Needed for
    /// k-quants (Q4_K_M etc.) and the post-export coherence self-test.
    @State private var toolsBuilt = false
    @State private var buildingTools = false

    /// Set when the model's architecture isn't reliably round-tripped by llama.cpp
    /// (hybrid linear-attention/SSM or MTP-head models — e.g. Qwen3.5/3.6). These
    /// produce a GGUF that loads but emits garbage, so export is **blocked** (not
    /// just warned) — `canExport` requires this to be nil.
    @State private var roundTripWarning: String?

    /// True when the model can't be converted directly (quantized or diffusion).
    private var isConvertible: Bool { !model.isDiffusion && !isQuantized }

    /// MLX-quantized models report a "Nbit" quantization; full-precision ones
    /// report "fp16". Anything that isn't plain fp16/bf16 can't go to GGUF.
    private var isQuantized: Bool {
        let q = model.quantization.lowercased()
        return q != "fp16" && q != "bf16"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if !isConvertible {
                notConvertibleNote
            } else if roundTripWarning != nil {
                blockedArchNote
            } else if !llamaCppInstalled {
                converterMissingSection
            } else {
                optionsSection
            }
            if let exportedPath { successSection(exportedPath) }
            if let selfTest { selfTestCard(selfTest) }
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            if exporting || !log.isEmpty { logPanel }
            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        .frame(minWidth: 540, minHeight: 560)
        .onAppear {
            if outputName.isEmpty { outputName = sanitized(model.displayName) }
            roundTripWarning = FuseService.ggufRoundTripWarning(forModelDir: model.directory.path)
            Task {
                llamaCppInstalled = await FuseService.shared.llamaCppInstalled()
                toolsBuilt = await FuseService.shared.llamaToolsInstalled()
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("Export \(model.displayName) to GGUF", systemImage: "arrow.down.doc")
            Text("Make a single .gguf file you can run in Ollama or LM Studio.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var notConvertibleNote: some View {
        let reason = model.isDiffusion ? "a diffusion model" : "a quantized (\(model.quantization)) model"
        return VStack(alignment: .leading, spacing: 8) {
            Label("Can't export this one to GGUF", systemImage: "info.circle")
                .font(.headline).foregroundStyle(.orange)
            Text("GGUF export needs a full-precision (fp16/bf16) text model. This is \(reason), so it can't be converted directly — re-import or download a full-precision version first.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var converterMissingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Needs the llama.cpp converter", systemImage: "info.circle")
                .font(.headline).foregroundStyle(.orange)
            Text("GGUF export uses llama.cpp's converter. Install it once and you're set.")
                .font(.callout).foregroundStyle(.secondary)
            Button {
                Task { await installConverter() }
            } label: {
                if installingLlamaCpp {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Installing llama.cpp converter…")
                    }
                } else {
                    Label("Install llama.cpp converter", systemImage: "arrow.down.circle")
                }
            }
            .disabled(installingLlamaCpp)
            .tint(.brand)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var blockedArchNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Can't export this architecture to GGUF", systemImage: "xmark.octagon")
                .font(.headline).foregroundStyle(.red)
            Text(roundTripWarning ?? "")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("File name").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    TextField("model-name", text: $outputName)
                        .textFieldStyle(.roundedBorder)
                    Text(".gguf").foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Format").font(.caption).foregroundStyle(.secondary)
                Picker("Format", selection: $quant) {
                    ForEach(GGUFQuant.allCases) { q in
                        Text(q.displayName + (q.isKQuant && !toolsBuilt ? " — needs tools" : "")).tag(q)
                    }
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
            }
            if quant.isKQuant && !toolsBuilt { toolsNeededNote }
            else if toolsBuilt {
                Label("Exports are self-tested — the app runs the GGUF and checks the output before declaring success.",
                      systemImage: "checkmark.seal")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    /// Shown when a k-quant is picked but the compiled tools aren't built yet.
    private var toolsNeededNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Q4_K_M/Q5_K_M/Q6_K and the coherence self-test need llama.cpp's compiled tools. Build them once (a few minutes), or pick Q8_0/F16/BF16 which don't need them.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await buildTools() }
            } label: {
                if buildingTools {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Building llama.cpp tools…") }
                } else {
                    Label("Build llama.cpp tools", systemImage: "hammer")
                }
            }
            .disabled(buildingTools)
            .tint(.brand)
        }
    }

    private func selfTestCard(_ test: GGUFSelfTest) -> some View {
        let (icon, color, title): (String, Color, String) = {
            switch test.outcome {
            case .passed:  return ("checkmark.seal.fill", .green, "Self-test passed — the GGUF runs and generates coherent text")
            case .failed:  return ("xmark.octagon.fill", .red, "Self-test failed — the GGUF did not generate usable output")
            case .skipped: return ("info.circle", .secondary, "Self-test skipped")
            }
        }()
        return VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.headline).foregroundStyle(color)
            if !test.sample.isEmpty {
                Text(test.sample).font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary).textSelection(.enabled)
                    .lineLimit(4).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(test.detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func successSection(_ path: URL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Exported ✓", systemImage: "checkmark.circle.fill")
                .font(.headline).foregroundStyle(.green)
            Text(path.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([path])
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var logPanel: some View {
        VStack(alignment: .leading) {
            Text("Output").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            .frame(minHeight: 120, maxHeight: 200)
            .background(Color.black.opacity(0.85))
            .foregroundStyle(.green)
        }
    }

    private var footer: some View {
        HStack {
            Button("Export") { Task { await runExport() } }
                .buttonStyle(.borderedProminent)
                .tint(.brand)
                .disabled(!canExport)
            if exporting { ProgressView().controlSize(.small) }
            Spacer()
            Button("Done") { dismiss() }
        }
    }

    private var canExport: Bool {
        isConvertible
            && roundTripWarning == nil   // hybrid/experimental archs are blocked
            && llamaCppInstalled
            && !(quant.isKQuant && !toolsBuilt)  // k-quants need the compiled tools
            && !exporting
            && !installingLlamaCpp
            && !buildingTools
            && !sanitized(outputName).isEmpty
    }

    // MARK: - Actions

    private func installConverter() async {
        installingLlamaCpp = true
        error = nil
        defer { installingLlamaCpp = false }
        let ok = await PythonRuntime.shared.installLlamaCpp { msg in
            log.append(msg)
            if log.count > 500 { log.removeFirst(log.count - 500) }
        }
        llamaCppInstalled = await FuseService.shared.llamaCppInstalled()
        if !ok {
            error = "Couldn't install the llama.cpp converter. See the output below or Settings → Logs."
        }
    }

    private func buildTools() async {
        buildingTools = true
        error = nil
        defer { buildingTools = false }
        let ok = await PythonRuntime.shared.buildLlamaCppTools { msg in
            log.append(msg)
            if log.count > 500 { log.removeFirst(log.count - 500) }
        }
        llamaCppInstalled = await FuseService.shared.llamaCppInstalled()
        toolsBuilt = await FuseService.shared.llamaToolsInstalled()
        if !ok {
            error = "Couldn't build the llama.cpp tools. See the output below or Settings → Logs."
        }
    }

    private func runExport() async {
        exporting = true
        error = nil
        exportedPath = nil
        selfTest = nil
        log.removeAll()
        defer { Task { @MainActor in exporting = false } }

        let name = sanitized(outputName)
        let exportDir = PathResolver.exportsDir.appendingPathComponent(sanitized(model.displayName), isDirectory: true)
        try? FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let ggufURL = exportDir.appendingPathComponent("\(name).gguf")

        let progress: @Sendable (String) -> Void = { line in
            Task { @MainActor in
                self.log.append(line)
                if self.log.count > 500 { self.log.removeFirst(self.log.count - 500) }
            }
        }

        NotificationService.shared.primeAuthorization()
        do {
            let test = try await FuseService.shared.convertModelToGGUF(
                modelPath: model.directory.path,
                ggufPath: ggufURL.path,
                quant: quant,
                onProgress: progress
            )
            exportedPath = ggufURL
            selfTest = test
            NotificationService.shared.exportFinished(name: name, success: test.outcome != .failed)
        } catch {
            self.error = error.localizedDescription
            NotificationService.shared.exportFinished(name: name, success: false)
        }
    }

    /// Reduce a display name to a safe single-path-component file stem.
    private func sanitized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }
}

#if DEBUG
#Preview("Export to GGUF") {
    GGUFExportSheet(model: ModelRegistry.DetectedModel(
        id: "preview",
        repoID: "mlx-community/Qwen2.5-Coder-7B",
        directory: URL(fileURLWithPath: "/tmp/model"),
        architecture: "qwen2",
        quantization: "fp16",
        sizeBytes: 7_000_000_000,
        isMLXReady: true
    ))
}
#endif
