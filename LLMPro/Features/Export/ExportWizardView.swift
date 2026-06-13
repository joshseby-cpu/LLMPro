import SwiftUI
import SwiftData

enum ExportTarget: String, CaseIterable, Identifiable {
    case adapter, fusedSafetensors, gguf
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .adapter:          "LoRA adapter (zip)"
        case .fusedSafetensors: "Fused safetensors"
        case .gguf:             "GGUF for Ollama / LM Studio"
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
            .onAppear {
                ollamaInstalled = FuseService.shared.locateOllama() != nil
                Task { llamaCppInstalled = await FuseService.shared.llamaCppInstalled() }
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

                    HStack {
                        Button { Task { await run(for: source) } } label: {
                            if running { ProgressView().controlSize(.small) }
                            else { Label("Run export", systemImage: "square.and.arrow.up") }
                        }
                        .disabled(running)
                        Spacer()
                    }
                    if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                    logPanel
                }
                .padding(16)
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
            if !ollamaInstalled {
                Label("Ollama CLI not found — install from https://ollama.com or copy the .gguf manually.",
                      systemImage: "info.circle").foregroundStyle(.orange)
            }
            if !isNativelyGGUFExportable(source) {
                converterSection
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

    /// Shown under the GGUF options when the selected model's architecture isn't
    /// directly GGUF-exportable (Qwen/Gemma/Phi). Export then needs llama.cpp's
    /// converter — surface a one-click installer instead of letting the run fail
    /// with a confusing spawn error.
    @ViewBuilder
    private var converterSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if llamaCppInstalled {
                Label("This architecture needs a two-step fuse + llama.cpp conversion. The converter is installed — you're ready to export.",
                      systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            } else {
                Label("This architecture isn't directly GGUF-exportable. It needs the llama.cpp converter — install it once and you're set.",
                      systemImage: "info.circle")
                    .foregroundStyle(.orange)
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
                .disabled(installingLlamaCpp || running)
            }
        }
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

    private func isNativelyGGUFExportable(_ source: ExportSource) -> Bool {
        let arch = source.baseModelRepoID.lowercased()
        return arch.contains("llama") || arch.contains("mistral") || arch.contains("mixtral")
    }

    private func run(for source: ExportSource) async {
        running = true; error = nil; log.removeAll()
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
                let savePath = exportsDir.appendingPathComponent("fused").path
                let ggufPath = exportsDir.appendingPathComponent("\(ollamaTag).gguf").path
                if isNativelyGGUFExportable(source) {
                    try await FuseService.shared.fuseToGGUF(baseModel: source.baseModelRepoID,
                                                            adapterPath: source.adapterPath,
                                                            savePath: savePath,
                                                            ggufPath: ggufPath,
                                                            onProgress: progress)
                } else {
                    try await FuseService.shared.fuseAndConvertExternalGGUF(
                        baseModel: source.baseModelRepoID,
                        adapterPath: source.adapterPath,
                        fp16Path: savePath,
                        ggufPath: ggufPath,
                        llamaCppDir: PathResolver.llamaCppDir,
                        onProgress: progress
                    )
                }
                progress("GGUF written to \(ggufPath)")
                if ollamaInstalled {
                    try await FuseService.shared.installInOllama(ggufPath: ggufPath,
                                                                 tag: ollamaTag,
                                                                 chatTemplate: template,
                                                                 onProgress: progress)
                    progress("✅ Installed as Ollama model: \(ollamaTag)")
                    progress("Try: ollama run \(ollamaTag) 'write fizzbuzz in rust'")
                }
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
