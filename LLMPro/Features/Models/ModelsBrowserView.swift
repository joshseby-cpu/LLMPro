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
    @State private var selected: HFModel?

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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                content
            }
            .padding(10)
            .navigationTitle("Models")
            .task(id: "init") {
                await registry.scan()
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
        }
        .padding(5)
        .background(.bar)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(.secondary, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var content: some View {
        list.frame(maxWidth: .infinity, maxHeight: .infinity)
        HSplitView {
            if let selected {
                ModelDetailView(model: selected)
            }
        }
    }

    @ViewBuilder
    private var list: some View {
        List(selection: $selected) {
            if !downloads.active.isEmpty {
                Section("Downloading") {
                    ForEach(downloads.active) { dl in
                        DownloadRow(download: dl)
                    }
                }
            }

            Section() {
                if let searchError {
                    Label(searchError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                } else if searching {
                    Text("Searching…")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(results) { model in
                        ModelResultRow(model: model).tag(model)
                    }
                }
            }

            Section(header: localModelsHeader) {
                if registry.localModels.isEmpty {
                    Text(registry.isScanning ? "Scanning…" : "No local models yet — download one above.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(registry.localModels) { local in
                        LocalModelRow(
                            model: local,
                            isInUse: isModelInUse(local),
                            onModifyTapped: { modifyTarget = local },
                            onDeleteTapped: { deletionTarget = local },
                            onDuplicateTapped: { promptDuplicate(of: local) },
                            onLMStudioTapped: { promptLMStudio(of: local) },
                            onTrainCodingTapped: { trainForCoding(local) }
                        )
                        .contextMenu {
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([local.directory])
                            }
                            Button("Train for coding agent") { trainForCoding(local) }
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
            }
        }
        .listStyle(.inset)
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
            Spacer()
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
            } catch {
                self.searchError = error.localizedDescription
            }
            self.searching = false
        }
    }
}

private struct ModelResultRow: View {
    let model: HFModel
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(model.shortName).font(.headline)
                if model.isMLXCommunity {
                    Text("MLX").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.2), in: Capsule())
                }
                Spacer()
                if let d = model.downloads { Text("\(d.formatted(.number.notation(.compactName))) ↓").font(.caption2).foregroundStyle(.secondary) }
            }
            Text(model.repoID).font(.caption).foregroundStyle(.secondary)
            if let tags = model.tags, !tags.isEmpty {
                Text(tags.prefix(4).joined(separator: " · ")).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
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

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName).font(.headline)
                Text("\(model.architecture) · \(model.quantization) · \(model.humanSize)")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
            .foregroundStyle(.blue)
            .help("Duplicate as a new independent local model (APFS clonefile — usually instant)")
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
}

private struct DownloadRow: View {
    let download: DownloadService.ActiveDownload
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(download.repoID).font(.headline).lineLimit(1)
                Spacer()
                Text(percentText).font(.caption.monospacedDigit())
            }
            ProgressView(value: download.percent)
            if let err = download.error {
                Text(err).font(.caption).foregroundStyle(.red)
            } else if !download.fileLabel.isEmpty {
                Text(download.fileLabel).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
    private var percentText: String {
        if download.bytesTotal == 0 { return "—" }
        return String(format: "%.1f%%", download.percent * 100)
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
