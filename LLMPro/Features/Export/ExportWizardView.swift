import SwiftUI
import SwiftData

enum ExportTarget: String, CaseIterable, Identifiable {
    case adapter, fusedSafetensors, gguf, cloud
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .adapter:          "LoRA adapter (zip)"
        case .fusedSafetensors: "Fused safetensors"
        case .gguf:             "GGUF for Ollama / LM Studio"
        case .cloud:            "Host to the cloud"
        }
    }
}

/// A thing the Save & Use tab can export: a completed Teach fine-tune
/// (`TrainingJob`) or a completed Practice run (`SelfImproveRun`). Both reduce to
/// {base model, adapter directory, name} — all the fuse / convert / zip paths
/// need — so export treats them uniformly and the automated loop's results are
/// first-class alongside manual fine-tunes.
struct ExportSource: Identifiable, Hashable {
    let id: UUID
    let name: String
    let baseModelRepoID: String
    let adapterPath: String
    let subtitle: String

    init(job: TrainingJob) {
        id = job.id
        name = job.name
        baseModelRepoID = job.baseModelRepoID
        adapterPath = job.adapterURL.path
        subtitle = "\(job.status.rawValue) · iter \(job.lastIter)"
    }

    init?(run: SelfImproveRun) {
        guard let dir = run.latestAdapterDirectory else { return nil }
        id = run.id
        name = run.name.isEmpty ? "Practice run" : run.name
        baseModelRepoID = run.baseModelRepoID
        adapterPath = dir.path
        subtitle = "Practice · \(run.decodedRounds().count) round(s)"
    }

    var adapterURL: URL { URL(fileURLWithPath: adapterPath) }
}

struct ExportWizardView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TrainingJob.createdAt, order: .reverse) private var jobs: [TrainingJob]
    @Query(sort: \SelfImproveRun.createdAt, order: .reverse) private var runs: [SelfImproveRun]

    @State private var selectedSource: ExportSource?
    @State private var deletionTarget: ExportSource?
    /// Non-nil when the selected source's architecture can't be run as a GGUF
    /// (hybrid linear-attention/SSM, e.g. Qwen3.5/3.6). Blocks the GGUF target.
    @State private var ggufBlockReason: String?
    @State private var target: ExportTarget = .gguf
    @State private var ollamaTag: String = ""
    @State private var template: OllamaChatTemplate = .qwen
    @State private var log: [String] = []
    @State private var running: Bool = false
    @State private var error: String?
    @State private var ollamaInstalled: Bool = false
    @State private var alsoInstallInLMStudio: Bool = false
    @State private var lmstudioFusedName: String = ""
    @State private var llamaCppInstalled: Bool = false
    @State private var installingLlamaCpp: Bool = false
    @State private var quant: GGUFQuant = .q4_k_m
    /// Compiled llama.cpp tools (llama-quantize + llama-cli) — needed for k-quants
    /// and the post-export coherence self-test.
    @State private var toolsBuilt: Bool = false
    @State private var buildingTools: Bool = false
    @State private var modelCardTarget: ExportSource?
    @State private var showLeaderboard: Bool = false

    /// Completed fine-tunes — Teach jobs and Practice runs — whose adapter
    /// weights are on disk. The single list the user exports from.
    private var sources: [ExportSource] {
        let jobSources = jobs.compactMap { job -> ExportSource? in
            let weights = job.adapterURL.appendingPathComponent("adapters.safetensors").path
            guard FileManager.default.fileExists(atPath: weights) else { return nil }
            return ExportSource(job: job)
        }
        let runSources = runs.filter { $0.status == .completed }.compactMap { ExportSource(run: $0) }
        return jobSources + runSources
    }

    var body: some View {
        NavigationStack {
            HSplitView {
                jobList.frame(minWidth: 280, idealWidth: 320)
                detail.frame(minWidth: 480)
            }
            .navigationTitle("Export")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showLeaderboard = true
                    } label: {
                        Label("Report cards", systemImage: "trophy")
                    }
                    .help("Score history across all your models — see what's improving")
                }
            }
            .sheet(isPresented: $showLeaderboard) { EvalLeaderboardView() }
            .sheet(item: $modelCardTarget) { source in ModelCardPreviewView(source: source) }
            .onAppear {
                ollamaInstalled = FuseService.shared.locateOllama() != nil
                Task {
                    llamaCppInstalled = await FuseService.shared.llamaCppInstalled()
                    toolsBuilt = await FuseService.shared.llamaToolsInstalled()
                }
            }
        }
    }

    private var jobList: some View {
        List(sources, selection: $selectedSource) { source in
            VStack(alignment: .leading) {
                Text(source.name).font(.headline)
                Text(source.baseModelRepoID).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(source.subtitle).font(.caption2).foregroundStyle(.tertiary)
            }
            .tag(source)
            .contextMenu {
                Button(role: .destructive) { deletionTarget = source } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { deletionTarget = source } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .alert("Delete this run?", isPresented: deletionPresented, presenting: deletionTarget) { source in
            Button("Delete", role: .destructive) { delete(source) }
            Button("Cancel", role: .cancel) {}
        } message: { source in
            Text("Removes \"\(source.name)\" and its trained files from this Mac. The dataset and base model are kept. You can't undo this.")
        }
    }

    private var deletionPresented: Binding<Bool> {
        Binding(get: { deletionTarget != nil }, set: { if !$0 { deletionTarget = nil } })
    }

    /// Delete the underlying Teach job or Practice run behind an export row.
    private func delete(_ source: ExportSource) {
        let message: String?
        if let job = jobs.first(where: { $0.id == source.id }) {
            message = TrainingArtifactDeletion.deleteJob(job, context: modelContext)
        } else if let run = runs.first(where: { $0.id == source.id }) {
            message = TrainingArtifactDeletion.deleteRun(run, context: modelContext)
        } else {
            message = "Couldn't find that item to delete."
        }
        if let message {
            error = message
        } else {
            if selectedSource == source { selectedSource = nil }
            error = nil
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let source = selectedSource {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(source.name).font(.title3).bold()
                    Picker("Target", selection: $target) {
                        ForEach(ExportTarget.allCases) { Text($0.displayName).tag($0) }
                    }.pickerStyle(.segmented)

                    if target == .gguf {
                        ggufOptions(for: source)
                    }
                    if target == .fusedSafetensors {
                        Text("Will produce safetensors in `~/Library/Application Support/LLMPro/exports/<id>-fused/`.").font(.callout)
                        Toggle("Also install in LM Studio (~/.lmstudio/models/LLMPro/<name>/)",
                               isOn: $alsoInstallInLMStudio)
                        if alsoInstallInLMStudio {
                            TextField("LM Studio model name", text: $lmstudioFusedName)
                                .textFieldStyle(.roundedBorder)
                                .help("Lands under ~/.lmstudio/models/LLMPro/<this name>/")
                        }
                    }
                    if target == .adapter {
                        Text("Zips the raw LoRA adapter directory — load with `--adapter-path` in mlx-lm.").font(.callout)
                    }
                    if target == .cloud {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Makes a full-precision safetensors folder that cloud runtimes (vLLM, TGI, SGLang) serve directly — works for every architecture, including ones GGUF can't handle.")
                                .font(.callout)
                            Text("Includes a README with the exact serve commands. Output: `exports/<id>/cloud/`.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    HStack {
                        Button { Task { await run(for: source) } } label: {
                            if running { ProgressView().controlSize(.small) }
                            else { Label("Run export", systemImage: "square.and.arrow.up") }
                        }
                        .disabled(running || installingLlamaCpp || buildingTools
                                  || (target == .gguf && !ggufExportReady))
                        Button {
                            modelCardTarget = source
                        } label: {
                            Label("Model card…", systemImage: "doc.richtext")
                        }
                        .help("Preview and save a shareable Markdown summary of this fine-tune")
                        Spacer()
                    }
                    if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                    logPanel
                }
                .padding(16)
            }
            .task(id: selectedSource) {
                ggufBlockReason = selectedSource.flatMap(ggufBlock)
            }
        } else {
            ContentUnavailableView("Pick a fine-tune", systemImage: "tray",
                                   description: Text("Export the result of a completed Teach or Practice run."))
        }
    }

    @ViewBuilder
    private func ggufOptions(for source: ExportSource) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Ollama tag (e.g. qwen-coder-mytune)", text: $ollamaTag)
            Picker("Chat template", selection: $template) {
                ForEach(OllamaChatTemplate.allCases) { Text($0.displayName).tag($0) }
            }
            if let ggufBlockReason {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Can't export this architecture to GGUF", systemImage: "xmark.octagon")
                        .font(.headline).foregroundStyle(.red)
                    Text(ggufBlockReason)
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Picker("Format", selection: $quant) {
                    ForEach(GGUFQuant.allCases) { q in
                        Text(q.displayName + (q.isKQuant && !toolsBuilt ? " — needs tools" : "")).tag(q)
                    }
                }
                if !ollamaInstalled {
                    Label("Ollama CLI not found — install from https://ollama.com or copy the .gguf manually.",
                          systemImage: "info.circle").foregroundStyle(.orange)
                }
                toolsSection
            }
        }
        .onAppear {
            if ollamaTag.isEmpty {
                ollamaTag = (source.baseModelRepoID.split(separator: "/").last.map(String.init) ?? "model")
                    .lowercased()
                    .replacingOccurrences(of: "-instruct", with: "")
                    .replacingOccurrences(of: "-4bit", with: "")
                    + "-tuned"
            }
        }
    }

    /// Converter + compiled-tools readiness for the GGUF target. The Python
    /// converter handles f16/bf16/q8_0; k-quants (Q4_K_M etc.) and the post-export
    /// coherence self-test need the compiled llama.cpp tools (built from source).
    @ViewBuilder
    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !llamaCppInstalled {
                Label("GGUF export needs llama.cpp's converter. Install it once and you're set.",
                      systemImage: "info.circle").foregroundStyle(.orange)
                Button { Task { await installConverter() } } label: {
                    if installingLlamaCpp {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Installing converter…") }
                    } else {
                        Label("Install llama.cpp converter", systemImage: "arrow.down.circle")
                    }
                }
                .disabled(installingLlamaCpp || running).tint(.brand)
            } else if quant.isKQuant && !toolsBuilt {
                Label("Q4_K_M/Q5_K_M/Q6_K and the coherence self-test need llama.cpp's compiled tools. Build them once (a few minutes), or pick Q8_0/F16/BF16.",
                      systemImage: "info.circle").foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button { Task { await buildTools() } } label: {
                    if buildingTools {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Building llama.cpp tools…") }
                    } else {
                        Label("Build llama.cpp tools", systemImage: "hammer")
                    }
                }
                .disabled(buildingTools || running).tint(.brand)
            } else {
                Label(toolsBuilt
                        ? "Ready — exports are self-tested (the app runs the GGUF and checks the output) before being declared done."
                        : "Converter installed — ready to export. Build the tools for k-quants + a self-test.",
                      systemImage: "checkmark.circle").foregroundStyle(.green)
            }
        }
    }

    /// True when a GGUF export can actually run right now (not blocked, converter
    /// present, and the compiled tools present if a k-quant is selected).
    private var ggufExportReady: Bool {
        ggufBlockReason == nil && llamaCppInstalled && !(quant.isKQuant && !toolsBuilt)
    }

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
            .frame(minHeight: 140, maxHeight: 240)
            .background(Color.black.opacity(0.85))
            .foregroundStyle(.green)
        }
    }

    /// Reason this source can't be exported to a *working* GGUF, or nil if it can.
    /// Hybrid linear-attention/SSM architectures (Qwen3.5/3.6) convert + load but
    /// llama.cpp runs them as garbage — so the GGUF target is blocked. Prefers the
    /// base model's `config.json` (most accurate); falls back to repo-id markers
    /// for HF-cache bases we can't resolve to a local directory.
    private func ggufBlock(for source: ExportSource) -> String? {
        if let dir = ModelRegistry.shared.localModels.first(where: { $0.repoID == source.baseModelRepoID })?.directory.path,
           let reason = FuseService.ggufRoundTripWarning(forModelDir: dir) {
            return reason
        }
        let id = source.baseModelRepoID.lowercased()
        let markers = ["qwen3_5", "qwen35", "qwen3.5", "qwen3.6", "mamba", "hybrid", "-ssm"]
        if markers.contains(where: id.contains) {
            return "This model uses a hybrid / experimental architecture (linear-attention/SSM). llama.cpp can't run the converted GGUF correctly — it loads but produces garbled output. Run it in LLMPro's Try it out / Code tabs instead, or fine-tune a GGUF-friendly base (Qwen2.5, Llama 3.x, Gemma 2, Mistral)."
        }
        return nil
    }

    private func run(for source: ExportSource) async {
        running = true; error = nil; log.removeAll()
        NotificationService.shared.primeAuthorization()
        defer { Task { @MainActor in running = false } }

        let exportsDir = PathResolver.exportsDir.appendingPathComponent(source.id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)

        let progress: @Sendable (String) -> Void = { line in
            Task { @MainActor in
                self.log.append(line)
                if self.log.count > 500 { self.log.removeFirst(self.log.count - 500) }
            }
        }

        do {
            switch target {
            case .adapter:
                let zipURL = exportsDir.appendingPathComponent("\(source.name)-adapter.zip")
                try zipDirectory(source.adapterURL, to: zipURL)
                progress("Wrote \(zipURL.path)")
            case .fusedSafetensors:
                let savePath = exportsDir.appendingPathComponent("fused").path
                try await FuseService.shared.fuse(baseModel: source.baseModelRepoID,
                                                  adapterPath: source.adapterPath,
                                                  savePath: savePath,
                                                  onProgress: progress)
                progress("Fused safetensors at \(savePath)")

                if alsoInstallInLMStudio {
                    let name = lmstudioFusedName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else {
                        progress("[warning] Skipped LM Studio install: name is empty.")
                        return
                    }
                    let destDir = PathResolver.lmStudioDefault
                        .appendingPathComponent("LLMPro", isDirectory: true)
                        .appendingPathComponent(name, isDirectory: true)
                    try? FileManager.default.createDirectory(
                        at: destDir.deletingLastPathComponent(), withIntermediateDirectories: true
                    )
                    // cp -cRL gives us CoW + dereferences any stray symlinks
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/bin/cp")
                    p.arguments = ["-cRL", savePath + "/", destDir.path]
                    try p.run(); p.waitUntilExit()
                    if p.terminationStatus == 0 {
                        progress("✅ Installed in LM Studio: ~/.lmstudio/models/LLMPro/\(name)/")
                    } else {
                        progress("[error] LM Studio install failed (exit \(p.terminationStatus))")
                    }
                }
            case .gguf:
                // Belt-and-suspenders: the Run button is disabled for blocked
                // archs, but never spawn a doomed multi-GB export even if it isn't.
                if let reason = ggufBlock(for: source) {
                    progress("[blocked] " + reason)
                    error = "GGUF export isn't available for this architecture."
                    return
                }
                // The tag doubles as the output file stem — sanitize BEFORE the
                // long fuse so a '/' or an emptied field can't fail an hour in.
                let stem = ollamaTag
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "/", with: "-")
                    .replacingOccurrences(of: ":", with: "-")
                let safeStem = stem.isEmpty ? "model-tuned" : stem
                if safeStem != ollamaTag { ollamaTag = safeStem }
                let savePath = exportsDir.appendingPathComponent("fused").path
                let ggufPath = exportsDir.appendingPathComponent("\(safeStem).gguf").path
                // Unified path: fuse (--dequantize) → convert → (k-quant) → self-test.
                let test = try await FuseService.shared.fuseAndConvertExternalGGUF(
                    baseModel: source.baseModelRepoID,
                    adapterPath: source.adapterPath,
                    fp16Path: savePath,
                    ggufPath: ggufPath,
                    quant: quant,
                    onProgress: progress
                )
                progress("GGUF written to \(ggufPath)")
                switch test.outcome {
                case .passed:  progress("✅ Self-test passed — it runs and generates: \(test.sample.prefix(120))")
                case .failed:  progress("⚠️ Self-test FAILED — the GGUF did not generate usable output (\(test.detail)). \(test.sample.prefix(120))")
                case .skipped: progress("ℹ️ Self-test skipped (build the llama.cpp tools to enable it).")
                }
                if ollamaInstalled {
                    try await FuseService.shared.installInOllama(ggufPath: ggufPath,
                                                                 tag: ollamaTag,
                                                                 chatTemplate: template,
                                                                 onProgress: progress)
                    progress("✅ Installed as Ollama model: \(ollamaTag)")
                    progress("Try: ollama run \(ollamaTag) 'write fizzbuzz in rust'")
                }
            case .cloud:
                // Full-precision HF safetensors — the arch-agnostic cloud format
                // (vLLM/TGI/SGLang read this directly; no GGUF conversion involved).
                let cloudDir = exportsDir.appendingPathComponent("cloud", isDirectory: true)
                try await FuseService.shared.fuse(
                    baseModel: source.baseModelRepoID,
                    adapterPath: source.adapterPath,
                    savePath: cloudDir.path,
                    dequantize: true,
                    onProgress: progress
                )
                let readme = ModelCardBuilder.cloudREADME(
                    modelName: source.name, baseModel: source.baseModelRepoID)
                try? readme.write(to: cloudDir.appendingPathComponent("README.md"),
                                  atomically: true, encoding: .utf8)
                progress("✅ Cloud package ready: \(cloudDir.path)")
                progress("README.md inside has the vLLM / TGI serve commands.")
                NSWorkspace.shared.activateFileViewerSelecting([cloudDir])
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func zipDirectory(_ src: URL, to dst: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        var writeError: Error?
        coordinator.coordinate(readingItemAt: src, options: .forUploading, error: &coordError) { tmpURL in
            do {
                if FileManager.default.fileExists(atPath: dst.path) {
                    try FileManager.default.removeItem(at: dst)
                }
                try FileManager.default.moveItem(at: tmpURL, to: dst)
            } catch {
                writeError = error
            }
        }
        if let coordError { throw coordError }
        if let writeError { throw writeError }
    }
}

#if DEBUG
#Preview("Save & Use") {
    ExportWizardView().previewEnvironment()
}
#endif
