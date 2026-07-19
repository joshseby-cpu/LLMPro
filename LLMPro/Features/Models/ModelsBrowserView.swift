import SwiftUI
import SwiftData

struct ModelsBrowserView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PythonRuntime.self) private var runtime
    @Environment(JobRegistry.self) private var jobRegistry
    @State private var registry = ModelRegistry.shared
    @State private var downloads = DownloadService.shared

    @State private var query: String = "Qwen Coder"
    @State private var mlxOnly: Bool = true
    @State private var searching = false
    @State private var searchError: String?
    @State private var results: [HFModel] = []
    /// Tapping a result opens its details sheet (replaces the old inline panel).
    @State private var detailTarget: HFModel?
    /// repoID → total download size in bytes, fetched lazily after a search so each
    /// result can show "≈ 1.8 GB" and a RAM-fit chip before the user commits.
    @State private var sizeCache: [String: Int64] = [:]

    // GGUF LLM "download & convert" combo.
    @State private var ggufImport = GGUFImportService.shared
    @State private var convertingRepo: String?
    @State private var convertError: String?
    /// Per GGUF-LLM repoID: whether it has an MLX-convertible quant (+ that file's
    /// size), fetched after a search so the card offers "Download & convert" only
    /// when it'll actually work. Absent = still checking.
    @State private var ggufConvert: [String: GGUFConvertState] = [:]

    @State private var deletionTarget: ModelRegistry.DetectedModel?
    @State private var lastDeletionFreed: Int64 = 0
    @State private var showDeletionResult: Bool = false
    @State private var modifyTarget: ModelRegistry.DetectedModel?
    @State private var addExpertTarget: ModelRegistry.DetectedModel?
    @State private var manageExpertsTarget: ModelRegistry.DetectedModel?

    @State private var duplicateTarget: ModelRegistry.DetectedModel?
    @State private var duplicateText: String = ""
    @State private var duplicating: Bool = false
    @State private var duplicationError: String?

    @State private var lmstudioTarget: ModelRegistry.DetectedModel?
    @State private var lmstudioPublisher: String = ""
    @State private var lmstudioName: String = ""
    @State private var lmstudioInstalling: Bool = false
    @State private var lmstudioError: String?
    @State private var lmstudioInstalledAt: URL?

    @State private var showGGUFImport = false
    @State private var ggufExportTarget: ModelRegistry.DetectedModel?
    @State private var notesTarget: ModelRegistry.DetectedModel?
    @State private var cardTarget: ModelRegistry.DetectedModel?
    /// Rename works for both LLMs and image models, so it's keyed by a stable id +
    /// current default name rather than a specific model type.
    @State private var renameTarget: RenameTarget?
    @State private var showCompare: Bool = false
    @State private var favorites = FavoritesStore.shared
    /// Downloaded image models (FLUX/SDXL/SD) surfaced so the user sees every model they
    /// have + what it supports. These aren't LLMs (no config.json), so they're absent
    /// from `registry.localModels`; scanned separately (off-thread — it reads headers).
    @State private var imageModels: [ImageModel] = []
    /// Non-nil filters the local list to models carrying this tag (from the
    /// notes & tags sheet) — the read side that makes tags worth writing.
    @State private var tagFilter: String? = nil

    /// Local models with pinned favorites floated to the top (stable otherwise),
    /// optionally narrowed to a tag.
    private var sortedLocalModels: [ModelRegistry.DetectedModel] {
        var models = registry.localModels
        if let tagFilter {
            models = models.filter { ModelMetaStore.shared.meta(for: $0.id).tags.contains(tagFilter) }
        }
        return models.enumerated().sorted { a, b in
            let pa = favorites.isModelPinned(a.element.id), pb = favorites.isModelPinned(b.element.id)
            if pa != pb { return pa }
            return a.offset < b.offset
        }.map(\.element)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                LowDiskWarningBanner()
                searchBar
                content
            }
            .padding(14)
            .navigationTitle("Models")
            .task(id: "init") {
                await registry.scan()
                imageModels = await Task.detached(priority: .utility) {
                    ImageGenService.downloadedImageModels()
                }.value
            }
            .sheet(item: $detailTarget) { model in
                ModelDetailSheet(model: model, sizeBytes: sizeCache[model.repoID],
                                 onConvert: { startDownloadConvert(model) })
            }
            .sheet(isPresented: $showGGUFImport) {
                GGUFImportView()
            }
            .sheet(item: $renameTarget) { target in
                RenameModelSheet(modelID: target.id, defaultName: target.defaultName)
            }
            .sheet(item: $ggufExportTarget) { target in
                GGUFExportSheet(model: target)
            }
            .sheet(item: $notesTarget) { target in
                ModelNotesSheet(modelID: target.id, modelName: target.displayName)
            }
            .sheet(item: $cardTarget) { target in
                ModelCardView(model: target)
            }
            .sheet(isPresented: $showCompare) {
                ModelCompareView(models: registry.localModels)
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search HuggingFace…", text: $query, onCommit: search)
                    .textFieldStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .onSubmit { search() }
            Toggle("mlx-community only", isOn: $mlxOnly)
                .toggleStyle(.switch)
                .controlSize(.small)
            Button(action: search) {
                if searching { ProgressView().controlSize(.small) }
                else { Text("Search") }
            }
            .keyboardShortcut(.return, modifiers: [.command])
            Divider().frame(height: 16)
            Button { showGGUFImport = true } label: {
                Label("Import GGUF", systemImage: "square.and.arrow.down")
            }
            .help("Convert a GGUF model file (from LM Studio / Ollama / HuggingFace) into an MLX model")
        }
        .padding(5)
        .background(.bar)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(.secondary, lineWidth: 1)
        )
    }

    private var content: some View {
        list.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sectionTitle(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Live progress / error for the GGUF download-&-convert combo (nil when idle).
    private var convertBanner: AnyView? {
        if convertingRepo != nil {
            return AnyView(VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(convertingRepo ?? "", systemImage: "wand.and.stars")
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer()
                    ProgressView().controlSize(.small)
                }
                Text(convertPhaseText).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                ProgressView().progressViewStyle(.linear).tint(.brand)
            })
        } else if let err = convertError {
            return AnyView(HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Couldn’t convert").font(.subheadline.weight(.semibold))
                    Text(err).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("OK") { convertError = nil }.controlSize(.small)
            })
        }
        return nil
    }

    private var convertPhaseText: String {
        switch ggufImport.phase {
        case .idle: "Downloading the Q8_0 quant (~8 GB) — this can take a while…"
        case .prechecking: "Checking the file…"
        case .converting(_, let msg): msg
        case .done: "Done — added to your models."
        case .failed(let r): r
        }
    }

    // A ScrollView + LazyVStack rather than a `List`: List has a well-known
    // initial-layout bug where a section of a few dynamically-loaded rows renders
    // at zero height until the user scrolls (search results kept vanishing). The
    // LazyVStack lays out its visible rows immediately and gives full styling control.
    @ViewBuilder
    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if let banner = convertBanner { banner.cardRow() }

                if !downloads.active.isEmpty {
                    sectionTitle("Downloading", systemImage: "arrow.down.circle")
                    ForEach(downloads.active) { dl in
                        DownloadProgressCard(download: dl).cardRow()
                    }
                }

                if let searchError {
                    Label(searchError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).cardRow()
                } else if searching {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Searching HuggingFace…").foregroundStyle(.secondary)
                    }.cardRow()
                } else if !results.isEmpty {
                    Text("\(results.count) result\(results.count == 1 ? "" : "s")")
                        .font(.headline).padding(.top, 4)
                    ForEach(results) { model in
                        ModelResultCard(
                            model: model,
                            sizeBytes: sizeCache[model.repoID],
                            state: downloadState(for: model),
                            converting: convertingRepo == model.repoID,
                            convert: ggufConvert[model.repoID],
                            onDownload: { startDownload(model) },
                            onDetails: { detailTarget = model },
                            onConvert: { startDownloadConvert(model) }
                        )
                        .cardRow()
                    }
                }

                localModelsHeader
                    .frame(maxWidth: .infinity)
                    .padding(.top, downloads.active.isEmpty && results.isEmpty ? 2 : 10)
                if registry.localModels.isEmpty {
                    Text(registry.isScanning ? "Scanning…" : "No models yet — search above to download one.")
                        .foregroundStyle(.secondary).padding(.vertical, 8)
                } else {
                    ForEach(sortedLocalModels) { local in
                        LocalModelRow(
                            model: local,
                            isInUse: isModelInUse(local),
                            onModifyTapped: { modifyTarget = local },
                            onDeleteTapped: { deletionTarget = local },
                            onDuplicateTapped: { promptDuplicate(of: local) },
                            onLMStudioTapped: { promptLMStudio(of: local) },
                            onTrainCodingTapped: { trainForCoding(local) },
                            onExportGGUFTapped: { ggufExportTarget = local }
                        )
                        .card(padding: 10, cornerRadius: 10)
                        .contextMenu {
                            Button(favorites.isModelPinned(local.id) ? "Unpin" : "Pin to top",
                                   systemImage: favorites.isModelPinned(local.id) ? "star.slash" : "star") {
                                favorites.toggleModel(local.id)
                            }
                            Button("Rename…", systemImage: "pencil") {
                                renameTarget = RenameTarget(id: local.id, defaultName: local.displayName)
                            }
                            Button("Notes & tags…", systemImage: "tag") { notesTarget = local }
                            Divider()
                            Button("About this model…", systemImage: "info.circle") { cardTarget = local }
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([local.directory])
                            }
                            Button("Train for coding agent") { trainForCoding(local) }
                            Button("Export to GGUF…") { ggufExportTarget = local }
                            Button("Duplicate…") { promptDuplicate(of: local) }
                            Button("Send to LM Studio…") { promptLMStudio(of: local) }
                            Button("Modify…") { modifyTarget = local }
                            if local.isMoE {
                                Button("Manage experts (MoE)…") { manageExpertsTarget = local }
                            }
                            Divider()
                            Button(role: .destructive) {
                                deletionTarget = local
                            } label: {
                                Text("Delete from disk…")
                            }
                            .disabled(isModelInUse(local))
                        }
                    }
                }

                imageModelsSection
            }
            .padding(.bottom, 12)
        }
        .modifier(DeletionAndSheetsModifier(
            deletionTitle: deletionAlertTitle,
            deletionPresented: deletionAlertBinding,
            deletionTarget: deletionTarget,
            onConfirmDelete: confirmDelete,
            onClearDeletion: { deletionTarget = nil },
            showDeletionResult: $showDeletionResult,
            lastDeletionFreed: lastDeletionFreed,
            modifyTarget: $modifyTarget,
            addExpertTarget: $addExpertTarget,
            manageExpertsTarget: $manageExpertsTarget
        ))
        .modifier(DuplicateAlertsModifier(
            title: duplicateAlertTitle,
            presented: duplicateAlertBinding,
            duplicateText: $duplicateText,
            target: duplicateTarget,
            duplicating: $duplicating,
            errorPresented: duplicationErrorBinding,
            errorText: duplicationError,
            onClearError: { duplicationError = nil },
            onClearTarget: { duplicateTarget = nil },
            onCommit: { source, name in Task { await commitDuplicate(source: source, newName: name) } }
        ))
        .modifier(LMStudioAlertsModifier(
            targetPresented: lmstudioTargetBinding,
            target: lmstudioTarget,
            publisher: $lmstudioPublisher,
            name: $lmstudioName,
            installing: $lmstudioInstalling,
            installedPresented: lmstudioInstalledBinding,
            installedAt: lmstudioInstalledAt,
            errorPresented: lmstudioErrorBinding,
            errorText: lmstudioError,
            onClearError: { lmstudioError = nil },
            onClearTarget: { lmstudioTarget = nil },
            onClearInstalled: { lmstudioInstalledAt = nil },
            onCommit: { source, pub, nm in Task { await commitLMStudio(source: source, publisher: pub, name: nm) } }
        ))
    }

    // MARK: - Alert titles (lifted out of the modifier chain)

    private var duplicateAlertTitle: String {
        "Duplicate \(duplicateTarget?.displayName ?? "model")"
    }

    private func promptDuplicate(of model: ModelRegistry.DetectedModel) {
        duplicationError = nil
        // Sensible default: "<orig>-copy" with a -2 etc. suffix if taken.
        let base = "\(model.displayName)-copy"
        var candidate = base
        var n = 2
        while registry.localModels.contains(where: { $0.repoID == candidate }) {
            candidate = "\(base)-\(n)"
            n += 1
        }
        duplicateText = candidate
        duplicateTarget = model
    }

    private func trainForCoding(_ model: ModelRegistry.DetectedModel) {
        // Hand off to Teach tab via notification. Teach handles dataset
        // selection + auto-naming. We just have to switch tab + post.
        NotificationCenter.default.post(name: .switchSidebar, object: SidebarSection.training)
        // Fire after sidebar swaps so the Teach view is mounted and listening.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NotificationCenter.default.post(name: .openTrainingForCoding, object: model.repoID)
        }
    }

    private func promptLMStudio(of model: ModelRegistry.DetectedModel) {
        lmstudioError = nil
        // Best-guess split: HF-style "owner/repo" gives us a publisher;
        // bare folder names use "LLMPro" as the publisher so they sort
        // separately from any HF-published models the user might also have.
        if model.repoID.contains("/") {
            let parts = model.repoID.split(separator: "/", maxSplits: 1).map(String.init)
            lmstudioPublisher = parts[0]
            lmstudioName = parts.count > 1 ? parts[1] : model.displayName
        } else {
            lmstudioPublisher = "LLMPro"
            lmstudioName = model.displayName
        }
        lmstudioTarget = model
    }

    private func commitLMStudio(source: ModelRegistry.DetectedModel,
                                publisher: String,
                                name: String) async {
        if publisher.contains("/") || name.contains("/") || publisher.isEmpty || name.isEmpty {
            lmstudioError = "Publisher and name can't be empty or contain slashes."
            return
        }
        lmstudioInstalling = true
        let result = await registry.installInLMStudio(source: source, publisher: publisher, name: name)
        lmstudioInstalling = false
        switch result {
        case .success(let url):
            lmstudioInstalledAt = url
        case .failure(let err):
            lmstudioError = err.localizedDescription
        }
    }

    private func commitDuplicate(source: ModelRegistry.DetectedModel, newName name: String) async {
        if name.contains("/") || name.contains("\\") || name.isEmpty {
            duplicationError = "Name can't be empty or contain slashes."
            return
        }
        if registry.localModels.contains(where: { $0.repoID == name }) {
            duplicationError = "A local model named “\(name)” already exists."
            return
        }
        duplicating = true
        let result = await registry.duplicate(source: source, newName: name)
        duplicating = false
        if case .failure(let err) = result {
            duplicationError = err.localizedDescription
        }
    }

    private var localModelsHeader: some View {
        HStack {
            Text("Local models (\(registry.localModels.count))")
            let tags = ModelMetaStore.shared.allTags()
            if !tags.isEmpty {
                Menu {
                    Button("All models") { tagFilter = nil }
                    Divider()
                    ForEach(tags, id: \.self) { tag in
                        Button(tagFilter == tag ? "✓ \(tag)" : tag) {
                            tagFilter = (tagFilter == tag) ? nil : tag
                        }
                    }
                } label: {
                    Label(tagFilter ?? "Tag", systemImage: "tag")
                        .font(.caption)
                        .foregroundStyle(tagFilter == nil ? Color.secondary : Color.brand)
                }
                .buttonStyle(.borderless)
                .help("Filter local models by tag")
            }
            Spacer()
            if registry.localModels.count >= 2 {
                Button {
                    showCompare = true
                } label: {
                    Label("Compare…", systemImage: "square.split.2x1")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Compare two models side by side")
            }
            if !registry.localModels.isEmpty {
                Text("Total: \(totalLocalDiskString)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var totalLocalDiskString: String {
        let total = registry.localModels.reduce(Int64(0)) { $0 + $1.sizeBytes }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    /// Downloaded image models — a separate section because they're not LLMs (they make
    /// pictures, not text) and so never appear in "Local models" above. This is where a
    /// user sees which of their models do image generation.
    @ViewBuilder
    private var imageModelsSection: some View {
        if !imageModels.isEmpty {
            HStack {
                Text("Image models (\(imageModels.count))")
                Spacer()
                Label("Generate in Imagine", systemImage: "photo.artframe")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
            ForEach(imageModels) { m in
                ImageModelRow(model: m)
                    .card(padding: 10, cornerRadius: 10)
                    .contextMenu {
                        Button("Rename…", systemImage: "pencil") {
                            renameTarget = RenameTarget(id: m.id, defaultName: m.name)
                        }
                        Button("Show in Finder") {
                            if let dir = ImageGenService.shared.snapshotDir(for: m.repo) {
                                NSWorkspace.shared.activateFileViewerSelecting([dir])
                            }
                        }
                    }
            }
        }
    }

    private var deletionAlertTitle: String {
        if let m = deletionTarget { return "Delete \(m.displayName)?" }
        return "Delete?"
    }

    /// Show the alert when deletionTarget is non-nil; clear target when dismissed.
    private var deletionAlertBinding: Binding<Bool> {
        Binding(
            get: { deletionTarget != nil },
            set: { newValue in if !newValue { deletionTarget = nil } }
        )
    }

    // The following item-driven alerts use `isPresented:` + a synthesized Bool
    // binding rather than `.alert(item:)` because they need to read the optional
    // state inside their `message`/`actions` closures. Lifting each
    // `Binding(get:set:)` out of `body` keeps the view-body type-checker (and the
    // preview-dylib compiler, which is far stricter) from choking on the long
    // `.alert` modifier chain.

    /// Present the duplicate-name alert while a model is targeted for duplication.
    private var duplicateAlertBinding: Binding<Bool> {
        Binding(
            get: { duplicateTarget != nil },
            set: { if !$0 { duplicateTarget = nil } }
        )
    }

    /// Present the duplication-error alert while an error message is set.
    private var duplicationErrorBinding: Binding<Bool> {
        Binding(
            get: { duplicationError != nil },
            set: { if !$0 { duplicationError = nil } }
        )
    }

    /// Present the LM Studio publisher/name alert while a model is targeted.
    private var lmstudioTargetBinding: Binding<Bool> {
        Binding(
            get: { lmstudioTarget != nil },
            set: { if !$0 { lmstudioTarget = nil } }
        )
    }

    /// Present the "installed in LM Studio" alert once an install path exists.
    private var lmstudioInstalledBinding: Binding<Bool> {
        Binding(
            get: { lmstudioInstalledAt != nil },
            set: { if !$0 { lmstudioInstalledAt = nil } }
        )
    }

    /// Present the LM Studio error alert while an error message is set.
    private var lmstudioErrorBinding: Binding<Bool> {
        Binding(
            get: { lmstudioError != nil },
            set: { if !$0 { lmstudioError = nil } }
        )
    }

    private func isModelInUse(_ model: ModelRegistry.DetectedModel) -> Bool {
        jobRegistry.runningJobs.contains { $0.baseModelRepoID == model.repoID }
    }

    private func confirmDelete(model: ModelRegistry.DetectedModel) {
        Task {
            let freed = await registry.delete(repoID: model.repoID)
            await MainActor.run {
                self.lastDeletionFreed = freed
                self.showDeletionResult = true
                self.deletionTarget = nil
            }
        }
    }

    private func search() {
        guard !searching else { return }
        searching = true
        searchError = nil
        Task {
            do {
                let hits = try await HuggingFaceClient.shared.search(query: query, mlxOnly: mlxOnly)
                self.results = hits
                fetchSizes(for: hits)
                fetchGGUFConvert(for: hits)
            } catch {
                self.searchError = error.localizedDescription
            }
            self.searching = false
        }
    }

    /// Fetch each result's total download size in the background (bounded
    /// concurrency) so cards can show "≈ 1.8 GB" + a RAM-fit chip. Best-effort:
    /// a failed size fetch just leaves that card without a size.
    private func fetchSizes(for models: [HFModel]) {
        // Skip GGUF repos — their total is the sum of every quant, which we never show.
        let missing = models.filter { !$0.isGGUF }.map(\.repoID).filter { sizeCache[$0] == nil }
        guard !missing.isEmpty else { return }
        Task {
            await withTaskGroup(of: (String, Int64?).self) { group in
                var running = 0
                var iterator = missing.makeIterator()
                func addNext() {
                    guard let repo = iterator.next() else { return }
                    running += 1
                    group.addTask {
                        (repo, try? await HuggingFaceClient.shared.resolveTotalSize(repoID: repo))
                    }
                }
                for _ in 0..<min(6, missing.count) { addNext() }
                for await (repo, size) in group {
                    if let size, size > 0 { sizeCache[repo] = size }
                    running -= 1
                    addNext()
                }
            }
        }
    }

    /// For each GGUF language model, check (bounded concurrency) whether it has an
    /// MLX-convertible quant so the card can offer the right action.
    private func fetchGGUFConvert(for models: [HFModel]) {
        let repos = models.filter { $0.isConvertibleGGUF && ggufConvert[$0.repoID] == nil }.map(\.repoID)
        guard !repos.isEmpty else { return }
        for r in repos { ggufConvert[r] = .checking }
        Task {
            await withTaskGroup(of: (String, GGUFConvertState).self) { group in
                var iterator = repos.makeIterator()
                func addNext() {
                    guard let repo = iterator.next() else { return }
                    group.addTask {
                        if let info = await GGUFImportService.shared.convertibleFile(repo: repo) {
                            return (repo, .convertible(file: info.file, size: info.size))
                        }
                        return (repo, .notConvertible)
                    }
                }
                for _ in 0..<min(4, repos.count) { addNext() }
                for await (repo, state) in group {
                    ggufConvert[repo] = state
                    addNext()
                }
            }
        }
    }

    private func downloadState(for model: HFModel) -> ModelResultCard.State {
        if let dl = downloads.active.first(where: { $0.repoID == model.repoID }) {
            return .downloading(dl.percent)
        }
        if registry.localModels.contains(where: { $0.repoID == model.repoID }) {
            return .installed
        }
        return .available
    }

    private func startDownload(_ model: HFModel) {
        guard runtime.isReady else { return }
        Task { await DownloadService.shared.download(repoID: model.repoID) }
    }

    /// Download the best convertible quant (Q8_0) of a GGUF language model and
    /// convert it to a usable MLX model — one tap. Progress shows in the banner.
    private func startDownloadConvert(_ model: HFModel) {
        guard runtime.isReady, convertingRepo == nil else { return }
        convertingRepo = model.repoID
        convertError = nil
        Task {
            do {
                _ = try await ggufImport.downloadAndConvert(repo: model.repoID)
            } catch {
                convertError = error.localizedDescription
            }
            convertingRepo = nil
        }
    }
}

/// Convertibility of a GGUF language-model repo — does it have a pure Q8_0/Q4_0/F16
/// the MLX converter can read? Resolved asynchronously after a search.
enum GGUFConvertState: Equatable {
    case checking
    case convertible(file: String, size: Int64)
    case notConvertible
}

/// A search result rendered as a scannable card: name + provenance, a metadata
/// line (size · downloads · updated + a RAM-fit warning), and a stateful action
/// button on the right (Download / Downloading % / Installed). Tapping the card
/// body (not the button) opens the details sheet.
private struct ModelResultCard: View {
    enum State: Equatable { case available, downloading(Double), installed }

    let model: HFModel
    let sizeBytes: Int64?
    let state: State
    /// True while THIS repo is mid download-&-convert (GGUF LLM combo).
    var converting: Bool = false
    /// Convertibility for a GGUF LLM (nil for non-GGUF or not-yet-checked).
    var convert: GGUFConvertState? = nil
    let onDownload: () -> Void
    let onDetails: () -> Void
    var onConvert: () -> Void = {}

    @Environment(PythonRuntime.self) private var runtime

    private var tooBig: Bool { sizeBytes.map { !ModelFit.fits(weightBytes: $0) } ?? false }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(model.shortName).font(.headline).lineLimit(1)
                    if model.isMLXCommunity { mlxBadge }
                }
                Text(model.repoID).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                metadataRow
            }
            Spacer(minLength: 8)
            actionButton
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: onDetails)
    }

    private var mlxBadge: some View {
        Text("MLX")
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Color.brand.opacity(0.18), in: Capsule())
            .foregroundStyle(Color.brand)
    }

    @ViewBuilder
    private var metadataRow: some View {
        HStack(spacing: 8) {
            if model.isConvertibleGGUF {
                switch convert {
                case .convertible(_, let size)?:
                    metaChip("Q8_0 → MLX · \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))",
                             systemImage: "wand.and.stars")
                case .notConvertible?:
                    Label("GGUF · no MLX-convertible quant", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.orange)
                default:
                    HStack(spacing: 3) { ProgressView().controlSize(.mini); Text("checking…") }
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            } else if model.isGGUF {
                Label("image/video · can’t run here", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
            } else if let sizeBytes {
                metaChip(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file),
                         systemImage: "internaldrive")
            } else {
                HStack(spacing: 3) { ProgressView().controlSize(.mini); Text("sizing…") }
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if let d = model.downloads {
                metaChip(d.formatted(.number.notation(.compactName)), systemImage: "arrow.down.circle")
            }
            if !model.isGGUF { imageChip }
            if !model.isGGUF && tooBig {
                Label("Too big for your RAM", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
    }

    /// Tells the user, before downloading, whether this is an image-generation model
    /// and whether LLMPro can run it: FLUX/SDXL/SD → "use in Imagine" (brand); a video
    /// or unrecognized image model → a muted "can't run" / "image model" note.
    @ViewBuilder
    private var imageChip: some View {
        switch model.imageKind {
        case .flux: imageBadge("FLUX image · Imagine", color: .brand)
        case .sdxl: imageBadge("SDXL image · Imagine", color: .brand)
        case .sd:   imageBadge("SD image · Imagine", color: .brand)
        case .imageOther:
            Label("image model", systemImage: "photo").font(.caption2).foregroundStyle(.secondary)
        case .video:
            Label("video · can’t run here", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2).foregroundStyle(.orange)
        case .none:
            EmptyView()
        }
    }

    private func imageBadge(_ text: String, color: Color) -> some View {
        Label(text, systemImage: "photo.artframe").font(.caption2.weight(.medium)).foregroundStyle(color)
    }

    private func metaChip(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption2).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var actionButton: some View {
        switch state {
        case .installed:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        case .downloading(let pct):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("\(Int(pct * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        case .available:
            if converting {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Converting…").font(.caption).foregroundStyle(.secondary)
                }
            } else if model.isConvertibleGGUF {
                // A GGUF language model: offer convert only once we've confirmed it
                // has an MLX-loadable quant (Q8_0/Q4_0/F16).
                switch convert {
                case .convertible?:
                    Button(action: onConvert) {
                        Label("Download & convert", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.borderedProminent).tint(.brand).controlSize(.small)
                    .disabled(!runtime.isReady)
                    .help("Download the Q8_0 quant and convert it to a usable MLX model")
                case .notConvertible?:
                    Button(action: onDetails) { Label("GGUF", systemImage: "info.circle") }
                        .buttonStyle(.bordered).tint(.orange).controlSize(.small)
                        .help("No MLX-convertible quant (only k-quants/i-quants). Tap for details.")
                default:
                    ProgressView().controlSize(.small)
                }
            } else if model.isGGUF {
                // GGUF image/video (FLUX, WAN, …) — can't be converted to an LLM.
                Button(action: onDetails) {
                    Label("GGUF", systemImage: "info.circle")
                }
                .buttonStyle(.bordered).tint(.orange).controlSize(.small)
                .help("GGUF image/video model — LLMPro can't run this. Tap for details.")
            } else {
                Button(action: onDownload) {
                    Label("Download", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent).tint(.brand).controlSize(.small)
                .disabled(!runtime.isReady)
                .help(runtime.isReady ? "Download \(model.shortName)" : "The Python runtime is still starting…")
            }
        }
    }
}

/// Identifies a model to rename (any type — LLM or image), by its stable metadata id
/// and current default name. `Identifiable` so it can drive a `.sheet(item:)`.
struct RenameTarget: Identifiable {
    let id: String
    let defaultName: String
}

/// A downloaded image model in the Models tab. Compact: what it is + what it supports
/// (image generation, in the Imagine tab). Not an LLM, so no Teach/Chat/convert actions.
private struct ImageModelRow: View {
    let model: ImageModel
    @State private var meta = ModelMetaStore.shared

    private var familyLabel: String {
        switch model.family {
        case .flux: "FLUX"
        case .sdxl: "SDXL" + (model.checkpointFile != nil ? " · single-file" : "")
        case .sd:   "Stable Diffusion"
        }
    }
    private var badgeText: String {
        switch model.family { case .flux: "FLUX"; case .sdxl: "SDXL"; case .sd: "SD" }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo.artframe").font(.title3).foregroundStyle(Color.brand).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(meta.displayName(for: model.id, default: model.name)).font(.headline).lineLimit(1)
                Text("\(familyLabel) · image generation").font(.caption).foregroundStyle(.secondary)
                Label("Imagine · Story illustrations", systemImage: "sparkles")
                    .font(.caption2).foregroundStyle(.tertiary).labelStyle(.titleAndIcon)
            }
            Spacer()
            Text(badgeText).font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Color.brand.opacity(0.18), in: Capsule())
                .foregroundStyle(Color.brand)
        }
    }
}

private struct LocalModelRow: View {
    let model: ModelRegistry.DetectedModel
    let isInUse: Bool
    let onModifyTapped: () -> Void
    let onDeleteTapped: () -> Void
    let onDuplicateTapped: () -> Void
    let onLMStudioTapped: () -> Void
    let onTrainCodingTapped: () -> Void
    let onExportGGUFTapped: () -> Void

    @State private var favorites = FavoritesStore.shared
    @State private var meta = ModelMetaStore.shared

    var body: some View {
        HStack(spacing: 10) {
            Button {
                favorites.toggleModel(model.id)
            } label: {
                Image(systemName: favorites.isModelPinned(model.id) ? "star.fill" : "star")
                    .foregroundStyle(favorites.isModelPinned(model.id) ? Color.yellow : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.borderless)
            .help(favorites.isModelPinned(model.id) ? "Unpin" : "Pin to top")
            VStack(alignment: .leading, spacing: 2) {
                Text(meta.displayName(for: model.id, default: model.displayName)).font(.headline)
                Text("\(model.architecture) · \(model.quantization) · \(model.humanSize)")
                    .font(.caption).foregroundStyle(.secondary)
                // What the user can actually do with this model. A regular MLX LLM does
                // the full text loop; a DiffusionGemma guest chats + codes but can't be
                // fine-tuned. (Image models aren't LLMs — they live in the Image models
                // section below and generate in Imagine, not here.)
                Label(model.isDiffusion
                      ? "Chat · Code — not fine-tunable"
                      : "Chat · Fine-tune · Try it out · Code · Story · Practice",
                      systemImage: "sparkles")
                    .font(.caption2).foregroundStyle(.tertiary).labelStyle(.titleAndIcon)
                let tags = meta.meta(for: model.id).tags
                if !tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(tags, id: \.self) { tag in
                            Text(tag).font(.system(size: 9))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.tint.opacity(0.15), in: Capsule())
                        }
                    }
                }
            }
            diffusionBadge
            Spacer()
            if isInUse {
                Label("In use", systemImage: "lock.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.orange)
                    .help("This model is being used by a training run. Stop it before changing anything.")
            }
            if model.isMLXReady {
                Label("MLX-ready", systemImage: "checkmark.seal.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.green)
            } else {
                Label("Needs convert", systemImage: "arrow.triangle.2.circlepath")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.orange)
            }
            Button {
                onTrainCodingTapped()
            } label: {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(isInUse ? Color.secondary : Color.green)
            .disabled(isInUse)
            .help(isInUse ? "Stop the running lesson first" : "Train this model for coding (jumps to Teach with model + coding dataset + good defaults pre-filled)")
            Button {
                onDuplicateTapped()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.brand)
            .help("Duplicate as a new independent local model (APFS clonefile — usually instant)")
            Button {
                onExportGGUFTapped()
            } label: {
                Image(systemName: "arrow.down.doc")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.indigo)
            .help("Export to GGUF for Ollama / LM Studio")
            Button {
                onLMStudioTapped()
            } label: {
                Image(systemName: "paperplane")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.teal)
            .help("Send to LM Studio (copies into ~/.lmstudio/models/, instant on APFS)")
            Button {
                onModifyTapped()
            } label: {
                Image(systemName: "wand.and.stars")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(isInUse ? Color.secondary : Color.purple)
            .disabled(isInUse)
            .help(isInUse ? "Stop the running lesson first" : "Modify: strip vision, abliterate, etc. (creates a copy)")
            Button(role: .destructive) {
                onDeleteTapped()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(isInUse ? Color.secondary : Color.red)
            .disabled(isInUse)
            .help(isInUse ? "Stop the running lesson first" : "Delete from disk to free space")
        }
        .padding(.vertical, 2)
    }

    /// Small inline tag flagging DiffusionGemma checkpoints, which are
    /// inference-only — usable in Try it out but not in Teach / Practice
    /// (mlx-lm can't LoRA-train a diffusion LM). Mirrors the capsule-badge
    /// style used elsewhere in the app.
    @ViewBuilder
    private var diffusionBadge: some View {
        if model.isDiffusion {
            Label("Diffusion · chat + Code", systemImage: "sparkles")
                .font(.caption2)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.purple.opacity(0.15), in: Capsule())
                .foregroundStyle(.purple)
                .help("This is a diffusion model — great for chatting in Try it out and using in Code, but it can't be fine-tuned in Teach or Practice.")
        }
    }
}

/// An in-flight download: name, running "1.2 GB of 5.4 GB" size, a progress bar
/// (determinate when the total is known, animating when it isn't so it never looks
/// stuck at 0%), and the current file / any error.
private struct DownloadProgressCard: View {
    let download: DownloadService.ActiveDownload
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(download.repoID, systemImage: "arrow.down.circle")
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                Text(percentText).font(.caption.monospacedDigit()).foregroundStyle(Color.brand)
            }
            if download.bytesTotal > 0 {
                ProgressView(value: download.percent).tint(.brand)
            } else {
                ProgressView().progressViewStyle(.linear).tint(.brand)
            }
            HStack(spacing: 4) {
                Text(sizeText).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                if let err = download.error {
                    Text("· \(err)").font(.caption2).foregroundStyle(.red).lineLimit(1)
                } else if !download.fileLabel.isEmpty {
                    Text("· \(download.fileLabel)").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer()
            }
        }
    }

    private var percentText: String {
        download.bytesTotal > 0 ? String(format: "%.0f%%", download.percent * 100) : "downloading…"
    }

    /// "1.2 GB of 5.4 GB" when the total is known, else the running amount.
    private var sizeText: String {
        let dl = ByteCountFormatter.string(fromByteCount: download.bytesDownloaded, countStyle: .file)
        if download.bytesTotal > 0 {
            let tot = ByteCountFormatter.string(fromByteCount: download.bytesTotal, countStyle: .file)
            return "\(dl) of \(tot)"
        }
        return download.bytesDownloaded > 0 ? "\(dl) downloaded" : "starting…"
    }
}

private extension View {
    /// Wrap a row's content in the shared elevated card surface, full width.
    func cardRow() -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(padding: 12, cornerRadius: 12)
    }
}

// MARK: - Presentation-modifier groups
//
// `ModelsBrowserView.list` used to hang a single chain of ~9 `.alert`/`.sheet`
// modifiers — several with inline `Binding(get:set:)` — off one expression.
// That whole `ModifiedContent<…>` tower has to be type-checked at once, which is
// a known constraint-solver hot spot. The SwiftUI *preview-dylib* compiler makes
// it worse: it instruments every string literal with
// `__designTimeString(_:fallback:)`, pushing the borderline expression past the
// type-checker's work limit so the canvas fails to build even though the normal
// `xcodebuild` passes. Splitting the chain into these three small `ViewModifier`
// structs gives the solver three independent, fast `body(content:)` units while
// keeping every alert, binding, and action byte-for-byte identical in behavior.

private struct DeletionAndSheetsModifier: ViewModifier {
    let deletionTitle: String
    let deletionPresented: Binding<Bool>
    let deletionTarget: ModelRegistry.DetectedModel?
    let onConfirmDelete: (ModelRegistry.DetectedModel) -> Void
    let onClearDeletion: () -> Void
    let showDeletionResult: Binding<Bool>
    let lastDeletionFreed: Int64
    let modifyTarget: Binding<ModelRegistry.DetectedModel?>
    let addExpertTarget: Binding<ModelRegistry.DetectedModel?>
    let manageExpertsTarget: Binding<ModelRegistry.DetectedModel?>

    func body(content: Content) -> some View {
        content
            .alert(
                deletionTitle,
                isPresented: deletionPresented,
                presenting: deletionTarget
            ) { model in
                Button("Delete", role: .destructive) { onConfirmDelete(model) }
                Button("Cancel", role: .cancel) { onClearDeletion() }
            } message: { model in
                Text("This will permanently remove \(model.humanSize) of model files from this Mac. You can re-download anytime.")
            }
            .alert("Freed up disk space", isPresented: showDeletionResult) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Freed \(ByteCountFormatter.string(fromByteCount: lastDeletionFreed, countStyle: .file)) of disk space.")
            }
            .sheet(item: modifyTarget) { target in
                ModelModifyView(model: target)
            }
            .sheet(item: addExpertTarget) { target in
                AddExpertView(model: target)
            }
            .sheet(item: manageExpertsTarget) { target in
                ExpertManagerView(model: target)
            }
    }
}

private struct DuplicateAlertsModifier: ViewModifier {
    let title: String
    let presented: Binding<Bool>
    let duplicateText: Binding<String>
    let target: ModelRegistry.DetectedModel?
    let duplicating: Binding<Bool>
    let errorPresented: Binding<Bool>
    let errorText: String?
    let onClearError: () -> Void
    let onClearTarget: () -> Void
    let onCommit: (ModelRegistry.DetectedModel, String) -> Void

    func body(content: Content) -> some View {
        content
            .alert(title, isPresented: presented) {
                duplicateActions
            } message: {
                duplicateMessage
            }
            .alert("Duplicating…", isPresented: duplicating) {
                // Auto-dismisses when commitDuplicate sets `duplicating = false`.
                // No buttons — the user is supposed to wait.
            } message: {
                Text("Cloning the model into your local-models folder. APFS CoW means this is usually near-instant; on non-APFS volumes it can take a minute per ~30 GB.")
            }
            .alert("Couldn't duplicate model", isPresented: errorPresented) {
                Button("OK", role: .cancel) { onClearError() }
            } message: {
                Text(errorText ?? "")
            }
    }

    @ViewBuilder
    private var duplicateActions: some View {
        TextField("New name", text: duplicateText)
        // Capture source + name SYNCHRONOUSLY before SwiftUI's alert
        // dismissal nukes duplicateTarget. Reading them inside the async
        // closure would race-fail.
        Button("Duplicate") {
            guard let source = target else { return }
            let name = duplicateText.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
            onCommit(source, name)
        }
        .disabled(duplicateText.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
        Button("Cancel", role: .cancel) { onClearTarget() }
    }

    @ViewBuilder
    private var duplicateMessage: some View {
        if let t = target {
            Text("Creates an independent copy in your local-models folder (\(t.humanSize) on non-APFS volumes, near-zero on APFS thanks to clonefile).")
        }
    }
}

private struct LMStudioAlertsModifier: ViewModifier {
    let targetPresented: Binding<Bool>
    let target: ModelRegistry.DetectedModel?
    let publisher: Binding<String>
    let name: Binding<String>
    let installing: Binding<Bool>
    let installedPresented: Binding<Bool>
    let installedAt: URL?
    let errorPresented: Binding<Bool>
    let errorText: String?
    let onClearError: () -> Void
    let onClearTarget: () -> Void
    let onClearInstalled: () -> Void
    let onCommit: (ModelRegistry.DetectedModel, String, String) -> Void

    func body(content: Content) -> some View {
        content
            .alert("Send to LM Studio", isPresented: targetPresented) {
                sendActions
            } message: {
                sendMessage
            }
            .alert("Sending to LM Studio…", isPresented: installing) {
                // No buttons; auto-dismisses on completion.
            } message: {
                Text("Cloning model files into LM Studio's folder.")
            }
            .alert("Installed in LM Studio", isPresented: installedPresented) {
                installedActions
            } message: {
                Text("Open LM Studio and look for the model under its new publisher.")
            }
            .alert("Couldn't send to LM Studio", isPresented: errorPresented) {
                Button("OK", role: .cancel) { onClearError() }
            } message: {
                Text(errorText ?? "")
            }
    }

    @ViewBuilder
    private var sendActions: some View {
        TextField("Publisher (folder)", text: publisher)
        TextField("Model name", text: name)
        Button("Send") {
            guard let source = target else { return }
            let pub = publisher.wrappedValue.trimmingCharacters(in: .whitespaces)
            let nm = name.wrappedValue.trimmingCharacters(in: .whitespaces)
            onCommit(source, pub, nm)
        }
        .disabled(publisher.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty ||
                  name.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
        Button("Cancel", role: .cancel) { onClearTarget() }
    }

    @ViewBuilder
    private var sendMessage: some View {
        if let t = target {
            Text("Will copy \(t.humanSize) into ~/.lmstudio/models/<publisher>/<name>/. APFS Copy-on-Write means this is usually near-instant with zero extra disk.")
        }
    }

    @ViewBuilder
    private var installedActions: some View {
        Button("Show in Finder") {
            if let url = installedAt {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            onClearInstalled()
        }
        Button("OK", role: .cancel) { onClearInstalled() }
    }
}

#if DEBUG
#Preview("Models") {
    ModelsBrowserView().previewEnvironment()
}
#endif
