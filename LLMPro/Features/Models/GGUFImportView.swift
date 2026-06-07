import SwiftUI
import UniformTypeIdentifiers

/// Sheet for importing a GGUF model → MLX (Models tab "Import GGUF"). Pick a local
/// .gguf or pull one from HuggingFace, run the lightweight pre-check (arch + quant),
/// then convert. Honest about the K-quant limitation: an unsupported file is flagged
/// before any long conversion, with guidance.
struct GGUFImportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var importer = GGUFImportService.shared
    @State private var registry = ModelRegistry.shared

    private enum SourceKind: String, CaseIterable, Identifiable {
        case local = "Local file", huggingface = "HuggingFace"
        var id: String { rawValue }
    }
    @State private var sourceKind: SourceKind = .local

    @State private var localPath: String = ""
    @State private var hfRepo: String = ""
    @State private var hfFilename: String = ""

    @State private var precheck: GGUFImportService.PrecheckResult?
    @State private var outputName: String = ""
    @State private var optimize = true
    @State private var optimizeBits = 4
    @State private var busy = false
    @State private var error: String?
    @State private var showFilePicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            sourcePicker
            if sourceKind == .local { localSourceRow } else { hfSourceRow }
            if let precheck { verdict(precheck) }
            Divider()
            progressOrError
            Spacer(minLength: 0)
            buttons
        }
        .padding(20)
        .frame(minWidth: 540, minHeight: 460)
        .fileImporter(isPresented: $showFilePicker,
                      allowedContentTypes: [Self.ggufType, .data],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                localPath = url.path
                precheck = nil; error = nil
                Task { await runPrecheck(path: url.path) }
            }
        }
    }

    private static let ggufType = UTType(filenameExtension: "gguf") ?? .data

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Import a GGUF model").font(.title3.bold())
            Text("Converts a GGUF file into an MLX model on your Mac. The lightweight converter handles F16 / Q4_0 / Q4_1 / Q8_0 GGUFs of common architectures (Llama, Qwen, Gemma, Mistral, Phi). K-quants (Q4_K_M etc.) aren't supported — grab the MLX build from HuggingFace instead.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sourcePicker: some View {
        Picker("Source", selection: $sourceKind) {
            ForEach(SourceKind.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .onChange(of: sourceKind) { _, _ in precheck = nil; error = nil }
    }

    private var localSourceRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Path to a .gguf file", text: $localPath)
                    .textFieldStyle(.roundedBorder)
                Button("Choose…") { showFilePicker = true }
            }
            if !localPath.isEmpty {
                Button("Check this file") { Task { await runPrecheck(path: localPath) } }
                    .disabled(busy)
            }
        }
    }

    private var hfSourceRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("HuggingFace repo (e.g. TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF)", text: $hfRepo)
                .textFieldStyle(.roundedBorder)
            TextField("GGUF filename (e.g. tinyllama-1.1b-chat-v1.0.Q8_0.gguf)", text: $hfFilename)
                .textFieldStyle(.roundedBorder)
            Text("Tip: pick a **Q8_0** or **Q4_0** file from the repo's Files tab — K-quant (…Q4_K_M…) files won't convert.")
                .font(.caption2).foregroundStyle(.secondary)
            Button("Download & check") { Task { await downloadAndPrecheck() } }
                .disabled(busy || hfRepo.isEmpty || hfFilename.isEmpty)
        }
    }

    @ViewBuilder
    private func verdict(_ p: GGUFImportService.PrecheckResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: p.convertible ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(p.convertible ? .green : .orange)
                Text(p.convertible ? "Convertible" : "Not supported by the lightweight converter")
                    .font(.headline)
            }
            Text("Architecture: \(p.arch) · Quant: \(p.quant.joined(separator: ", ")) · \(p.nTensors) tensors")
                .font(.caption).foregroundStyle(.secondary)
            if !p.convertible, !p.reason.isEmpty {
                Text(p.reason).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if p.convertible {
                TextField("Save as (model name)", text: $outputName)
                    .textFieldStyle(.roundedBorder)
                    .onAppear { if outputName.isEmpty { outputName = defaultName(p) } }
                optimizeControls(p)
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    /// "Optimize for MLX" — quantize the result. Only meaningful for a
    /// full-precision (F16/F32) GGUF; an already-quantized GGUF is left as-is
    /// (re-quantizing degrades it), so we show that instead of a live toggle.
    @ViewBuilder
    private func optimizeControls(_ p: GGUFImportService.PrecheckResult) -> some View {
        if sourceIsFullPrecision(p) {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Optimize for MLX (quantize)", isOn: $optimize)
                if optimize {
                    Picker("Precision", selection: $optimizeBits) {
                        Text("4-bit (smallest)").tag(4)
                        Text("8-bit (higher quality)").tag(8)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 280)
                }
                Text(optimize
                     ? "This GGUF is full-precision; quantizing makes the MLX model much smaller and faster (e.g. ~4× smaller at 4-bit)."
                     : "Off: keep full precision (largest, highest quality).")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("Already quantized (\(p.quant.joined(separator: ", "))) — it's imported as-is, already optimal for MLX. Re-quantizing would only lose quality.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A GGUF is "full precision" when its tensors are only F16/F32 (no Q* types).
    private func sourceIsFullPrecision(_ p: GGUFImportService.PrecheckResult) -> Bool {
        !p.quant.contains { $0.uppercased().hasPrefix("Q") }
    }

    @ViewBuilder
    private var progressOrError: some View {
        switch importer.phase {
        case .prechecking:
            HStack { ProgressView().controlSize(.small); Text("Reading the GGUF…") }
        case .converting(_, let message):
            HStack { ProgressView().controlSize(.small); Text(message).lineLimit(2) }
        case .done(let name, _):
            Label("Imported as “\(name)” — it's now in your Models list.", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .idle:
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var buttons: some View {
        HStack {
            Spacer()
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            Button {
                Task { await convert() }
            } label: {
                HStack { Image(systemName: "wand.and.stars"); Text("Convert to MLX") }.padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canConvert)
        }
    }

    private var canConvert: Bool {
        !busy && (precheck?.convertible ?? false) && !outputName.isEmpty && !sourcePath.isEmpty
    }

    /// The on-disk path we'll convert — the local file, or the downloaded HF file.
    private var sourcePath: String { localPath }

    private func defaultName(_ p: GGUFImportService.PrecheckResult) -> String {
        let base = p.name.isEmpty ? "gguf-model" : p.name
        return base + "-mlx"
    }

    // MARK: actions

    private func runPrecheck(path: String) async {
        busy = true; defer { busy = false }
        error = nil
        do {
            let r = try await importer.precheck(path: path)
            precheck = r
            if r.convertible, outputName.isEmpty { outputName = defaultName(r) }
        } catch {
            self.error = error.localizedDescription
            precheck = nil
        }
    }

    private func downloadAndPrecheck() async {
        busy = true; defer { busy = false }
        error = nil; precheck = nil
        do {
            let path = try await importer.downloadFromHuggingFace(repo: hfRepo, filename: hfFilename)
            localPath = path
            await runPrecheck(path: path)
        } catch {
            self.error = "Download failed: \(error.localizedDescription)"
        }
    }

    private func convert() async {
        busy = true; defer { busy = false }
        error = nil
        do {
            _ = try await importer.convert(path: sourcePath, outputName: outputName,
                                           optimize: optimize, optimizeBits: optimizeBits)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
