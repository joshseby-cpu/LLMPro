import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct DatasetsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PythonRuntime.self) private var runtime
    @Query(sort: \DatasetRecord.createdAt, order: .reverse) private var datasets: [DatasetRecord]
    @State private var importer: Bool = false
    @State private var error: String?
    @State private var prep = DatasetPrepService.shared
    @State private var showingHFSearch: Bool = false
    @State private var editingDataset: DatasetRecord?
    @State private var renameTarget: DatasetRecord?
    @State private var renameDraft: String = ""
    @State private var deletionTarget: DatasetRecord?

    // Shrink dataset state — pre-filled from the target when promptShrink is called.
    @State private var shrinkTarget: DatasetRecord?
    @State private var shrinkMaxRows: Double = 1000
    @State private var shrinkMaxChars: Double = 8000
    @State private var shrinkName: String = ""
    @State private var shrinking: Bool = false
    @State private var shrinkError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    StarterDatasetsSection()
                    Divider()
                    huggingFaceBrowseCard
                    Divider()
                    dropZone
                    activePrepSection
                    Divider()
                    yoursSection
                }
                .padding(16)
            }
            .navigationTitle("Datasets")
            .toolbar { datasetsToolbar }
            .modifier(DatasetsPresentationModifier(
                showingHFSearch: $showingHFSearch,
                editingDataset: $editingDataset,
                shrinkTarget: $shrinkTarget,
                shrinkSheet: { ds in AnyView(shrinkSheet(for: ds).frame(minWidth: 480, minHeight: 380)) },
                renamePresented: renameBinding,
                renameTarget: renameTarget,
                renameDraft: $renameDraft,
                onRename: { ds, newName in ds.name = newName; try? modelContext.save() },
                onClearRename: { renameTarget = nil },
                deletionPresented: deletionBinding,
                deletionTarget: deletionTarget,
                onDelete: { ds in
                    try? FileManager.default.removeItem(at: ds.directoryURL)
                    modelContext.delete(ds)
                    try? modelContext.save()
                },
                onClearDeletion: { deletionTarget = nil },
                importer: $importer,
                onImport: handleImport,
                prepHistoryCount: prep.history.count,
                onPrepHistoryChange: registerCompletedPreps
            ))
        }
    }

    @ToolbarContentBuilder
    private var datasetsToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                createBlankDataset()
            } label: {
                Label("New blank…", systemImage: "plus.square")
            }
            .help("Create an empty dataset and add rows yourself")
            Button {
                showingHFSearch = true
            } label: {
                Label("Search HuggingFace…", systemImage: "magnifyingglass")
            }
            .help("Find any dataset on HuggingFace and download it")
            Button { importer = true } label: { Label("Import file…", systemImage: "tray.and.arrow.down") }
        }
    }

    private var huggingFaceBrowseCard: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "magnifyingglass.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(.tint)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 6) {
                Text("Browse HuggingFace for any dataset").font(.headline)
                Text("Search HuggingFace's library directly. LLMPro previews the first few rows, figures out the column shape automatically, and normalizes everything into the lesson format your model can learn from.")
                    .font(.caption).foregroundStyle(.secondary)
                Button {
                    showingHFSearch = true
                } label: {
                    Label("Search HuggingFace…", systemImage: "magnifyingglass")
                }
                .controlSize(.large)
                .padding(.top, 4)
            }
            Spacer()
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var dropZone: some View {
        VStack(spacing: 6) {
            Text("…or bring your own").font(.headline)
            Image(systemName: "tray.and.arrow.down").font(.title)
            Text("Drop a .jsonl file or a folder of train.jsonl / valid.jsonl / test.jsonl")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
        }
        .frame(maxWidth: .infinity, minHeight: 110)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { ingest(url: url) }
                }
            }
            return true
        }
    }

    @ViewBuilder
    private var activePrepSection: some View {
        if !prep.active.isEmpty {
            VStack(alignment: .leading) {
                Text("Preparing").font(.headline)
                ForEach(prep.active) { entry in
                    HStack {
                        ProgressView().controlSize(.small)
                        VStack(alignment: .leading) {
                            Text(entry.preset.displayName).font(.headline)
                            Text("\(entry.stage) — \(entry.message)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if let err = entry.error {
                            Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.caption)
                        }
                    }
                    .padding(8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var yoursSection: some View {
        VStack(alignment: .leading) {
            Text("Your datasets (\(datasets.count))").font(.headline)
            if datasets.isEmpty {
                Text("No datasets yet — grab one from the catalog above or drop a JSONL file.")
                    .foregroundStyle(.secondary)
            }
            ForEach(datasets) { ds in
                datasetRow(ds: ds)
            }
        }
    }

    private func datasetRow(ds: DatasetRecord) -> some View {
        Button {
            editingDataset = ds
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(ds.name).font(.headline)
                        Spacer()
                        Text(ds.schema.displayName).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("train \(ds.trainRows) · valid \(ds.validRows) · test \(ds.testRows)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary).font(.caption)
            }
            .contentShape(Rectangle())
            .padding(8)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit rows…") { editingDataset = ds }
            Button("Shrink…") { promptShrink(ds) }
            Button("Rename…") {
                renameDraft = ds.name
                renameTarget = ds
            }
            Button("Duplicate") { duplicateDataset(ds) }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([ds.directoryURL])
            }
            Divider()
            Button(role: .destructive) {
                deletionTarget = ds
            } label: { Text("Delete…") }
        }
    }

    private func shrinkSheet(for ds: DatasetRecord) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Shrink \"\(ds.name)\"").font(.title3.bold())
                Text("Make a smaller copy that fits in less memory while training. The original lesson stays as-is.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Keep at most this many training rows")
                    Spacer()
                    Text("\(Int(shrinkMaxRows)) of \(ds.trainRows)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $shrinkMaxRows, in: 50...Double(max(50, ds.trainRows)), step: 50)
                Text("Smaller = faster training + less memory. 500-2000 rows is usually enough for a noticeable fine-tune.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Drop rows longer than this many characters")
                    Spacer()
                    Text("\(Int(shrinkMaxChars).formatted()) chars")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $shrinkMaxChars, in: 1000...32000, step: 1000)
                Text("Training truncates long rows to ~2K tokens anyway (≈8K chars). Dropping them entirely avoids feeding the model malformed truncated samples that can NaN the loss.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Save as").font(.headline)
                TextField("New dataset name", text: $shrinkName)
                    .textFieldStyle(.roundedBorder)
            }

            if let err = shrinkError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.caption)
            }

            Spacer()

            HStack {
                Button("Cancel") { shrinkTarget = nil }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    // Snapshot all the state we need synchronously, then run.
                    // SwiftUI sometimes invalidates the view's `self` capture
                    // before the inner async closure runs — passing values
                    // explicitly keeps the action ironclad.
                    let snapName = shrinkName
                    let snapRows = Int(shrinkMaxRows)
                    let snapChars = Int(shrinkMaxChars)
                    let snapSourceID = ds.id
                    let snapTrainURL = ds.trainFile
                    let snapValidURL = ds.validFile
                    let snapTestURL = ds.testFile
                    let snapSchema = ds.schema
                    let snapSourceName = ds.name
                    Task {
                        await runShrink(name: snapName,
                                        rows: snapRows,
                                        chars: snapChars,
                                        sourceID: snapSourceID,
                                        train: snapTrainURL,
                                        valid: snapValidURL,
                                        test: snapTestURL,
                                        schema: snapSchema,
                                        sourceName: snapSourceName)
                    }
                } label: {
                    HStack {
                        if shrinking {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.down.right.and.arrow.up.left")
                        }
                        Text(shrinking ? "Shrinking…" : "Make smaller dataset")
                    }
                    .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(shrinking || shrinkName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
    }

    private func runShrink(name: String,
                           rows: Int,
                           chars: Int,
                           sourceID: UUID,
                           train: URL,
                           valid: URL,
                           test: URL,
                           schema: DatasetSchema,
                           sourceName: String) async {
        shrinkError = nil
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { shrinkError = "Name can't be empty."; return }
        shrinking = true
        defer { shrinking = false }

        let newID = UUID()
        let outDir = PathResolver.datasetDir(for: newID)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let result = await Task.detached { () -> (train: Int, valid: Int, test: Int)? in
            func filter(srcFile: URL, dstFile: URL, capRows: Int, capChars: Int) -> Int {
                guard let data = try? Data(contentsOf: srcFile),
                      let text = String(data: data, encoding: .utf8) else { return 0 }
                var kept: [String] = []
                kept.reserveCapacity(capRows)
                for line in text.split(whereSeparator: \.isNewline) {
                    if kept.count >= capRows { break }
                    if line.isEmpty { continue }
                    if line.count > capChars { continue }
                    kept.append(String(line))
                }
                let joined = kept.joined(separator: "\n") + (kept.isEmpty ? "" : "\n")
                try? joined.write(to: dstFile, atomically: true, encoding: .utf8)
                return kept.count
            }
            let trainKept = filter(srcFile: train,
                                   dstFile: outDir.appendingPathComponent("train.jsonl"),
                                   capRows: rows, capChars: chars)
            let smallCap = max(1, rows / 10)
            let validKept = filter(srcFile: valid,
                                   dstFile: outDir.appendingPathComponent("valid.jsonl"),
                                   capRows: smallCap, capChars: chars)
            let testKept  = filter(srcFile: test,
                                   dstFile: outDir.appendingPathComponent("test.jsonl"),
                                   capRows: smallCap, capChars: chars)
            if trainKept == 0 { return nil }
            return (trainKept, validKept, testKept)
        }.value

        guard let r = result else {
            shrinkError = "No rows survived the filter. Try larger caps."
            return
        }

        let rec = DatasetRecord(id: newID, name: trimmed, schema: schema,
                                trainRows: r.train, validRows: r.valid, testRows: r.test,
                                notes: "Shrunk from \"\(sourceName)\" (capped at \(rows) rows, \(chars) chars/row)")
        modelContext.insert(rec)
        try? modelContext.save()
        shrinkTarget = nil
    }

    private func promptShrink(_ ds: DatasetRecord) {
        shrinkMaxRows = Double(min(1000, ds.trainRows))
        shrinkMaxChars = 8000   // ~2K tokens, fits in default training max_seq_length
        shrinkName = "\(ds.name)-small"
        shrinkError = nil
        shrinkTarget = ds
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renameTarget != nil },
                set: { v in if !v { renameTarget = nil } })
    }

    private var deletionBinding: Binding<Bool> {
        Binding(get: { deletionTarget != nil },
                set: { v in if !v { deletionTarget = nil } })
    }

    private func createBlankDataset() {
        let id = UUID()
        let dir = PathResolver.datasetDir(for: id)
        do {
            try DatasetEditorService.createEmpty(at: dir)
        } catch {
            self.error = error.localizedDescription
            return
        }
        let record = DatasetRecord(id: id, name: "New dataset", schema: .chat,
                                   trainRows: 0, validRows: 0, testRows: 0,
                                   notes: "Created in LLMPro on \(Date().formatted(date: .abbreviated, time: .shortened))")
        modelContext.insert(record)
        try? modelContext.save()
        editingDataset = record
    }

    private func duplicateDataset(_ ds: DatasetRecord) {
        let newID = UUID()
        let dst = PathResolver.datasetDir(for: newID)
        do {
            try DatasetEditorService.duplicate(source: ds.directoryURL, destination: dst)
        } catch {
            self.error = error.localizedDescription
            return
        }
        let copy = DatasetRecord(id: newID, name: ds.name + " (copy)", schema: ds.schema,
                                 trainRows: ds.trainRows, validRows: ds.validRows, testRows: ds.testRows,
                                 notes: ds.notes)
        modelContext.insert(copy)
        try? modelContext.save()
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls): if let url = urls.first { ingest(url: url) }
        case .failure(let error): self.error = error.localizedDescription
        }
    }

    private func ingest(url: URL) {
        do {
            let id = UUID()
            let dst = PathResolver.datasetDir(for: id)
            let record = try DatasetService.ingest(source: url, into: dst,
                                                   name: url.deletingPathExtension().lastPathComponent)
            record.id = id
            modelContext.insert(record)
            try modelContext.save()
            self.error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Any prep entries in history that produced datasets we don't yet have a record for,
    /// register them now.
    private func registerCompletedPreps() {
        for entry in prep.history {
            guard entry.error == nil, let id = entry.resultDatasetID else { continue }
            if datasets.contains(where: { $0.id == id }) { continue }
            let record = DatasetRecord(id: id,
                                       name: entry.preset.displayName,
                                       schema: .chat,
                                       trainRows: entry.trainRows,
                                       validRows: entry.validRows,
                                       testRows: entry.testRows,
                                       notes: "Imported from \(entry.preset.hfRepo) on \(Date().formatted(date: .abbreviated, time: .shortened))")
            modelContext.insert(record)
            try? modelContext.save()
        }
    }
}

// MARK: - Presentation-modifier group
//
// `DatasetsView.body` previously hung three `.sheet`s, two `presenting:` alerts
// (each with inline action closures touching `modelContext`), a `.fileImporter`,
// and an `.onChange` off one `NavigationStack` expression — ~277ms to type-check
// before the SwiftUI preview compiler even adds its `__designTimeString`
// instrumentation, which is what tips the canvas over the work limit. Moving the
// whole presentation chain into this `ViewModifier` (with the state passed in as
// bindings + closures, so behavior is identical) makes `body` a small skeleton
// and gives this modifier its own fast `body(content:)` type-check unit.
private struct DatasetsPresentationModifier: ViewModifier {
    let showingHFSearch: Binding<Bool>
    let editingDataset: Binding<DatasetRecord?>
    let shrinkTarget: Binding<DatasetRecord?>
    let shrinkSheet: (DatasetRecord) -> AnyView
    let renamePresented: Binding<Bool>
    let renameTarget: DatasetRecord?
    let renameDraft: Binding<String>
    let onRename: (DatasetRecord, String) -> Void
    let onClearRename: () -> Void
    let deletionPresented: Binding<Bool>
    let deletionTarget: DatasetRecord?
    let onDelete: (DatasetRecord) -> Void
    let onClearDeletion: () -> Void
    let importer: Binding<Bool>
    let onImport: (Result<[URL], Error>) -> Void
    let prepHistoryCount: Int
    let onPrepHistoryChange: () -> Void

    private var importContentTypes: [UTType] {
        [UTType.fileURL, UTType.directory, UTType.json,
         UTType(filenameExtension: "jsonl") ?? .data]
    }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: showingHFSearch) {
                HuggingFaceDatasetSearchView()
            }
            .sheet(item: editingDataset) { ds in
                DatasetDetailView(dataset: ds)
            }
            .sheet(item: shrinkTarget) { ds in
                shrinkSheet(ds)
            }
            .alert("Rename dataset", isPresented: renamePresented, presenting: renameTarget) { ds in
                TextField("Name", text: renameDraft)
                Button("Save") {
                    let trimmed = renameDraft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { onRename(ds, trimmed) }
                    onClearRename()
                }
                Button("Cancel", role: .cancel) { onClearRename() }
            }
            .alert("Delete dataset?", isPresented: deletionPresented, presenting: deletionTarget) { ds in
                Button("Delete", role: .destructive) {
                    onDelete(ds)
                    onClearDeletion()
                }
                Button("Cancel", role: .cancel) { onClearDeletion() }
            } message: { ds in
                Text("Removes \"\(ds.name)\" and all its lesson files from this Mac. You can't undo this.")
            }
            .fileImporter(isPresented: importer,
                          allowedContentTypes: importContentTypes,
                          allowsMultipleSelection: false) { result in
                onImport(result)
            }
            .onChange(of: prepHistoryCount) { _, _ in
                onPrepHistoryChange()
            }
    }
}

private struct StarterDatasetsSection: View {
    @State private var maxRowsByPreset: [String: Int] = [:]
    private var prepService = DatasetPrepService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Coding-instruction datasets").font(.title3).bold()
                Spacer()
                Label("One-click download → normalized to chat schema → ready to train",
                      systemImage: "sparkles")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Take any general LLM (Llama 3.2, Qwen Instruct, Mistral, Gemma) and teach it coding by training on one of these.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(CodingDatasetCatalog.all) { preset in
                presetCard(preset)
            }
        }
    }

    private func presetCard(_ preset: CodingDatasetPreset) -> some View {
        let maxRows = maxRowsByPreset[preset.id] ?? min(preset.approxRows, 20_000)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(preset.displayName).font(.headline)
                    Text(preset.hfRepo).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Button {
                    prepService.prepare(preset: preset, maxRows: maxRows)
                } label: { Label("Prepare", systemImage: "tray.and.arrow.down.fill") }
            }
            Text(preset.description).font(.callout)
            HStack(spacing: 12) {
                Label(preset.recommendedFor, systemImage: "lightbulb").font(.caption).foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 6) {
                    Text("Sample size:").font(.caption)
                    Stepper(value: Binding(get: { maxRows },
                                           set: { maxRowsByPreset[preset.id] = $0 }),
                            in: 1_000...preset.approxRows,
                            step: 1_000) {
                        Text("\(maxRows.formatted()) rows").font(.caption.monospacedDigit())
                    }
                    .frame(width: 220)
                }
            }
            Text("License: \(preset.licenseHint)")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}


#if DEBUG
#Preview("Lessons") {
    DatasetsView().previewEnvironment()
}
#endif
