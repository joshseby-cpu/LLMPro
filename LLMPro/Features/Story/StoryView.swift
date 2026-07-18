import SwiftUI
import UniformTypeIdentifiers

/// **Story** tab — long-form creative writing with a local model. Write a premise,
/// pick a model, and generate a story chapter by chapter (with rolling summaries
/// so it stays coherent across 15+ chapters), then revise any chapter. Saved as
/// projects. Content latitude is entirely the chosen model's — an uncensored model
/// (made via Models → Make uncensored) writes without refusals; this UI adds no
/// filter of its own.
struct StoryView: View {
    @State private var store = StoryStore.shared
    @State private var registry = ModelRegistry.shared

    @State private var selectedID: UUID?
    @State private var generator: StoryGenerator?
    /// The project the live generator maps to (persistence keys on this, not
    /// selectedID — same reason as the Chat tab).
    @State private var generatorProjID: UUID?

    @State private var renameTarget: StoryProject?
    @State private var renameText = ""
    @State private var deletionTarget: StoryProject?

    private var localModels: [ModelRegistry.DetectedModel] { registry.localModels }

    var body: some View {
        NavigationStack {
            Group {
                if localModels.isEmpty {
                    noModels
                } else {
                    HSplitView {
                        projectList.frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
                        editorArea.frame(minWidth: 480)
                    }
                }
            }
            .navigationTitle("Story")
        }
        .task {
            await registry.scan()
            if selectedID == nil { selectedID = store.projects.first?.id }
        }
        .onChange(of: selectedID) { _, new in
            persist()
            if let old = generatorProjID { store.discardIfEmpty(old) }
            if let new, let proj = store.projects.first(where: { $0.id == new }) {
                loadGenerator(proj)
            } else {
                generator?.stop(); generator = nil; generatorProjID = nil
            }
        }
        .onDisappear {
            persist()
            generator?.stop()
            if let id = generatorProjID { store.discardIfEmpty(id) }
        }
        .alert("Rename story", isPresented: renamePresented, presenting: renameTarget) { proj in
            TextField("Title", text: $renameText)
            Button("Save") {
                let t = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                store.rename(proj.id, to: t)
                // Keep the live generator's copy in sync, or its next save() would
                // write the old title straight back over the rename.
                if !t.isEmpty, generatorProjID == proj.id { generator?.project.title = t }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this story?", isPresented: deletionPresented, presenting: deletionTarget) { proj in
            Button("Delete", role: .destructive) { deleteProject(proj.id) }
            Button("Cancel", role: .cancel) {}
        } message: { proj in
            Text("“\(proj.isUntitled ? "Untitled story" : proj.title)” and all its chapters will be permanently removed.")
        }
    }

    // MARK: - Empty state

    private var noModels: some View {
        ContentUnavailableView {
            Label("No models yet", systemImage: "book.closed")
        } description: {
            Text("Download a model in the Models tab, then come back to write stories with it.")
        } actions: {
            Button("Open Models") {
                NotificationCenter.default.post(name: .switchSidebar, object: SidebarSection.models)
            }
            .buttonStyle(.borderedProminent).tint(.brand)
        }
    }

    // MARK: - Project list

    private var projectList: some View {
        VStack(spacing: 0) {
            Button { startNewStory() } label: {
                Label("New story", systemImage: "square.and.pencil").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(.brand)
            .padding(8)

            List(selection: $selectedID) {
                ForEach(store.projects) { proj in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(proj.isUntitled ? "Untitled story" : proj.title).font(.callout).lineLimit(1)
                        Text("\(proj.chapters.count) chapter\(proj.chapters.count == 1 ? "" : "s") · \(proj.updatedAt, format: .relative(presentation: .named))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .tag(proj.id)
                    .contextMenu {
                        Button("Rename…") { renameText = proj.title; renameTarget = proj }
                        Button("Delete…", role: .destructive) { deletionTarget = proj }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { deletionTarget = proj }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    // MARK: - Editor

    @ViewBuilder
    private var editorArea: some View {
        if let generator {
            StoryEditorPane(
                generator: generator,
                models: localModels,
                persist: persist,
                changeModel: changeModel)
        } else {
            ContentUnavailableView {
                Label("Write a story", systemImage: "book.closed")
            } description: {
                Text("Pick a story on the left, or start a new one.")
            } actions: {
                Button("New story") { startNewStory() }.buttonStyle(.borderedProminent).tint(.brand)
            }
        }
    }

    // MARK: - Lifecycle

    private func startNewStory() {
        let defaultModel = generator?.project.model
            ?? (localModels.first?.repoID ?? "")
        let proj = store.create(model: defaultModel.isEmpty ? (localModels.first?.repoID ?? "") : defaultModel)
        selectedID = proj.id
    }

    private func loadGenerator(_ proj: StoryProject) {
        generator?.stop()
        var p = proj
        if !localModels.contains(where: { $0.repoID == p.model }) {
            p.model = localModels.first?.repoID ?? p.model
        }
        let g = StoryGenerator(project: p)
        generator = g
        generatorProjID = proj.id
    }

    private func persist() {
        guard let generator, let id = generatorProjID,
              store.projects.contains(where: { $0.id == id }) else { return }
        store.update(generator.project)   // project.id already == id
    }

    private func changeModel(to repoID: String) {
        generator?.project.model = repoID
        persist()
    }

    private func deleteProject(_ id: UUID) {
        if generatorProjID == id {
            generator?.stop(); generator = nil; generatorProjID = nil; selectedID = nil
        }
        store.delete(id)
    }

    private var renamePresented: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }
    private var deletionPresented: Binding<Bool> {
        Binding(get: { deletionTarget != nil }, set: { if !$0 { deletionTarget = nil } })
    }
}

// MARK: - Editor pane

private struct StoryEditorPane: View {
    @Bindable var generator: StoryGenerator
    let models: [ModelRegistry.DetectedModel]
    let persist: () -> Void
    let changeModel: (String) -> Void

    @State private var instruction = ""
    @State private var showSettings = false
    @State private var reviseTarget: StoryChapter?
    @State private var editTarget: StoryChapter?
    @State private var chapterDeletionTarget: StoryChapter?
    @FocusState private var premiseFocused: Bool
    @FocusState private var styleFocused: Bool

    // Image-generation add-on (mflux). `imageGenInstalled` is nil until checked.
    @State private var imageGen = ImageGenService.shared
    @State private var imageGenInstalled: Bool?
    @State private var installingImageGen = false
    @State private var installStatus = ""

    private var project: StoryProject { generator.project }

    /// The live text of the chapter currently streaming — drives follow-scroll.
    private var streamingChapterText: String {
        generator.project.chapters.first(where: { $0.id == generator.streamingChapterID })?.text ?? ""
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if showSettings { settings }
                        premiseCard
                        ForEach(project.chapters) { ch in
                            chapterCard(ch)
                                .id(ch.id)
                        }
                        if let err = generator.error {
                            Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: generator.streamingChapterID) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                }
                .onChange(of: streamingChapterText) { _, _ in
                    if let id = generator.streamingChapterID { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            Divider()
            generationBar
        }
        .sheet(item: $reviseTarget) { ch in
            ReviseSheet(chapterTitle: ch.title) { instr in
                generator.reviseChapter(id: ch.id, instruction: instr)
            }
        }
        .sheet(item: $editTarget) { ch in
            ChapterEditSheet(chapter: ch) { updated in
                if let i = generator.project.chapters.firstIndex(where: { $0.id == ch.id }) {
                    generator.project.chapters[i] = updated
                    persist()
                    // A manual edit blanks the summary — regenerate it so later
                    // chapters' rolling context reflects the change.
                    if updated.summary.isEmpty && !updated.text.isEmpty && !generator.isGenerating {
                        generator.resummarizeChapter(id: ch.id)
                    }
                }
            }
        }
        .confirmationDialog("Delete this chapter?", isPresented: chapterDeletePresented, presenting: chapterDeletionTarget) { ch in
            Button("Delete", role: .destructive) { deleteChapter(ch.id) }
            Button("Cancel", role: .cancel) {}
        } message: { ch in
            Text("“\(ch.title)” will be permanently removed from the story.")
        }
    }

    private var chapterDeletePresented: Binding<Bool> {
        Binding(get: { chapterDeletionTarget != nil }, set: { if !$0 { chapterDeletionTarget = nil } })
    }

    /// Remove a chapter and renumber the remaining default-titled ("Chapter N")
    /// ones so titles stay sequential and the count+1 scheme can't collide.
    private func deleteChapter(_ id: UUID) {
        guard let i = generator.project.chapters.firstIndex(where: { $0.id == id }) else { return }
        generator.project.chapters.remove(at: i)
        for idx in generator.project.chapters.indices {
            if generator.project.chapters[idx].title.range(of: "^Chapter \\d+$", options: .regularExpression) != nil {
                generator.project.chapters[idx].title = "Chapter \(idx + 1)"
            }
        }
        persist()
    }

    private var header: some View {
        HStack(spacing: 12) {
            TextField("Story title", text: $generator.project.title)
                .textFieldStyle(.plain).font(.title3.bold())
                .onSubmit(persist)
            Spacer()
            Menu {
                ForEach(models) { m in Button(m.displayName) { changeModel(m.repoID) } }
            } label: {
                Label(displayName(project.model), systemImage: "cube.box").lineLimit(1)
            }
            .frame(maxWidth: 220)
            Button { showSettings.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                .help("Story settings")
            Button {
                StoryMarkdownExporter.exportWithPanel(project: project)
            } label: { Image(systemName: "square.and.arrow.up") }
                .help("Export the story to Markdown")
                .disabled(project.chapters.isEmpty)
        }
        .padding(10)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Genre", selection: $generator.project.genre) {
                    Text("Any").tag("")
                    ForEach(StoryProject.genres, id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 220)
                .onChange(of: generator.project.genre) { _, _ in persist() }
                Spacer()
                Stepper("~\(project.chapterWordTarget) words/chapter", value: $generator.project.chapterWordTarget, in: 200...3000, step: 100)
                    .onChange(of: generator.project.chapterWordTarget) { _, _ in persist() }
            }
            HStack {
                HStack(spacing: 4) {
                    Text("Creativity").font(.caption)
                    Slider(value: $generator.project.temperature, in: 0...1.5) { editing in if !editing { persist() } }
                        .frame(width: 120)
                    Text(String(format: "%.2f", project.temperature)).font(.caption.monospacedDigit())
                }
                Spacer()
                Stepper("Target: \(project.targetChapters) chapters", value: $generator.project.targetChapters, in: 1...40)
                    .onChange(of: generator.project.targetChapters) { _, _ in persist() }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Style & tone (freeform — POV, voice, content latitude)").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $generator.project.styleInstructions)
                    .frame(height: 60).font(.callout)
                    .focused($styleFocused)
                    .onChange(of: styleFocused) { _, focused in if !focused { persist() } }
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            }
            HStack {
                Button {
                    persist(); generator.planOutline()
                } label: { Label("Plan outline", systemImage: "list.bullet.rectangle") }
                    .disabled(generator.isGenerating || project.premise.isEmpty)
                Spacer()
            }
            if !project.outline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DisclosureGroup("Outline") {
                    Text(project.outline).font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
            }
            Divider()
            illustrationSettings
        }
        .card()
        .task { if project.illustrationsPerChapter > 0 { await refreshImageGenInstalled() } }
    }

    @ViewBuilder
    private var illustrationSettings: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Stepper("Illustrations per chapter: \(project.illustrationsPerChapter)",
                        value: $generator.project.illustrationsPerChapter, in: 0...4)
                    .onChange(of: generator.project.illustrationsPerChapter) { _, n in
                        persist()
                        if n > 0 { Task { await refreshImageGenInstalled() } }
                    }
                Spacer()
                if project.illustrationsPerChapter > 0 { imageGenStatusView }
            }
            if project.illustrationsPerChapter > 0 {
                Text("Art style — kept identical on every illustration so the whole story matches")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("e.g. soft watercolor children's-book illustration, warm palette",
                          text: $generator.project.artStyle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(persist)
                Text("Generated locally with FLUX after each chapter is written. First use downloads the image model (~10 GB, no account needed); each image takes a few seconds.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var imageGenStatusView: some View {
        switch imageGenInstalled {
        case .some(true):
            Label("Image model ready", systemImage: "checkmark.seal.fill")
                .font(.caption).foregroundStyle(.green)
        case .some(false):
            if installingImageGen {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(installStatus.isEmpty ? "Installing…" : installStatus)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Button { installImageGen() } label: {
                    Label("Install image generator", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
        case .none:
            ProgressView().controlSize(.small)
        }
    }

    private func refreshImageGenInstalled() async {
        imageGenInstalled = await ImageGenService.shared.installed()
    }

    private func installImageGen() {
        installingImageGen = true
        installStatus = ""
        Task {
            let ok = await ImageGenService.shared.install { line in installStatus = line }
            imageGenInstalled = ok ? true : await ImageGenService.shared.installed()
            installingImageGen = false
        }
    }

    private var premiseCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What's the story?").font(.headline)
            TextEditor(text: $generator.project.premise)
                .frame(minHeight: 60, maxHeight: 120).font(.callout)
                .focused($premiseFocused)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .onChange(of: premiseFocused) { _, focused in if !focused { persist() } }
            if project.premise.isEmpty {
                Text("e.g. “A rogue AI aboard a generation ship befriends the last awake human as the ship drifts toward an unknown signal.”")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .card()
    }

    private func chapterCard(_ ch: StoryChapter) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(ch.title).font(.headline)
                if generator.streamingChapterID == ch.id {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Menu {
                    Button("Revise…", systemImage: "wand.and.stars") { reviseTarget = ch }
                    Button("Edit text…", systemImage: "pencil") { editTarget = ch }
                    Button("Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ch.text, forType: .string)
                    }
                    if project.illustrationsPerChapter > 0 && !ch.text.isEmpty {
                        Divider()
                        Button(ch.illustrations.isEmpty ? "Illustrate" : "Redraw illustrations",
                               systemImage: "photo.on.rectangle") {
                            persist(); generator.illustrateChapter(id: ch.id)
                        }
                    }
                    Divider()
                    Button("Delete…", systemImage: "trash", role: .destructive) {
                        chapterDeletionTarget = ch
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .disabled(generator.isGenerating)
            }
            if ch.text.isEmpty && generator.streamingChapterID == ch.id {
                Text("▍").font(.system(.body, design: .serif))
            } else {
                MessageContentView(text: ch.text)
                    .font(.system(.body, design: .serif))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            if !ch.illustrations.isEmpty { illustrationsGallery(ch) }
        }
        .card()
    }

    @ViewBuilder
    private func illustrationsGallery(_ ch: StoryChapter) -> some View {
        let dir = PathResolver.storyImagesDir(for: project.id)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 10)], spacing: 10) {
            ForEach(ch.illustrations) { illo in
                let url = dir.appendingPathComponent(illo.file)
                IllustrationView(url: url)
                    .contextMenu {
                        Button("Save image…", systemImage: "square.and.arrow.down") { saveImage(url) }
                        Button("Show in Finder", systemImage: "folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                        Divider()
                        Button("Remove", systemImage: "trash", role: .destructive) {
                            generator.removeIllustration(chapterID: ch.id, illustrationID: illo.id)
                        }
                    }
                    .help(illo.prompt)
            }
        }
        .padding(.top, 4)
    }

    private func saveImage(_ src: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "illustration.png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: src, to: dest)
    }

    private var generationBar: some View {
        VStack(spacing: 8) {
            if generator.isGenerating, let p = imageGen.progress {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(p.loadingModel
                         ? "Loading the image model… (first run downloads ~10 GB — this can take a while)"
                         : "Rendering illustration \(min(p.done + 1, p.total)) of \(p.total)…")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            } else if !generator.statusLine.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(generator.statusLine).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(project.chapters.isEmpty ? "Any extra guidance for the opening chapter (optional)…"
                                                   : "Guidance for the next chapter (optional)…",
                          text: $instruction, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...4)
                if generator.isGenerating {
                    Button(role: .destructive) { generator.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                        .keyboardShortcut(".", modifiers: [.command])
                } else {
                    Button {
                        persist()
                        generator.writeNextChapter(instruction: instruction)
                        instruction = ""
                    } label: {
                        Label(project.chapters.isEmpty ? "Write opening chapter" : "Write next chapter",
                              systemImage: "pencil.line")
                    }
                    .buttonStyle(.borderedProminent).tint(.brand)
                    .disabled(project.premise.isEmpty)
                    if project.chapters.count < project.targetChapters {
                        Button {
                            persist(); generator.autoWriteToTarget()
                        } label: { Label("Write to \(project.targetChapters)", systemImage: "text.append") }
                            .disabled(project.premise.isEmpty)
                            .help("Keep writing chapters until the story reaches \(project.targetChapters) (you can Stop anytime)")
                    }
                }
            }
        }
        .padding(10)
    }

    private func displayName(_ repoID: String) -> String {
        repoID.split(separator: "/").last.map(String.init) ?? repoID
    }
}

// MARK: - Revise / edit sheets

private struct ReviseSheet: View {
    let chapterTitle: String
    let onRevise: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var instruction = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Revise \(chapterTitle)", systemImage: "wand.and.stars")
            Text("Describe the change. The chapter is rewritten to match, keeping the rest of the story consistent.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $instruction)
                .frame(minHeight: 100).font(.callout)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Revise") {
                    let i = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !i.isEmpty { onRevise(i) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent).tint(.brand)
                .disabled(instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(minWidth: 460, minHeight: 260)
    }
}

// MARK: - Illustration thumbnail

/// Loads a generated illustration off the main thread and caches it in state, so a
/// chapter card with images doesn't re-decode PNGs on every redraw (e.g. while a
/// later chapter is streaming). Reloads if the file at `url` changes (Redraw).
private struct IllustrationView: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable().scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            } else {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4))
                    .frame(height: 160)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .task(id: url) { image = await Self.load(url) }
    }

    private static func load(_ url: URL) async -> NSImage? {
        await Task.detached(priority: .utility) { NSImage(contentsOf: url) }.value
    }
}

private struct ChapterEditSheet: View {
    let chapter: StoryChapter
    let onSave: (StoryChapter) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var text: String

    init(chapter: StoryChapter, onSave: @escaping (StoryChapter) -> Void) {
        self.chapter = chapter
        self.onSave = onSave
        _title = State(initialValue: chapter.title)
        _text = State(initialValue: chapter.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Edit chapter", systemImage: "pencil")
            TextField("Chapter title", text: $title).textFieldStyle(.roundedBorder)
            TextEditor(text: $text)
                .font(.system(.body, design: .serif))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    var updated = chapter
                    updated.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? chapter.title : title
                    updated.text = text
                    // Edited text invalidates the old auto-summary.
                    if updated.text != chapter.text { updated.summary = "" }
                    onSave(updated)
                    dismiss()
                }
                .buttonStyle(.borderedProminent).tint(.brand)
            }
        }
        .padding(20).frame(minWidth: 560, minHeight: 480)
    }
}
