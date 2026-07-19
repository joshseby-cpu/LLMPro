import SwiftUI
import UniformTypeIdentifiers

/// **Imagine** tab — free-form local text-to-image. Type a prompt, pick a size and
/// how many, and generate images with the same FLUX engine (`ImageGenService`) that
/// draws Story illustrations. Results are kept in a persistent gallery
/// (`ImagineStore`). Image generation uses a dedicated FLUX model, not the chat LLM,
/// so it works regardless of which language model is downloaded.
struct ImagineView: View {
    @State private var store = ImagineStore.shared
    @State private var imageGen = ImageGenService.shared

    @State private var prompt = ""
    @State private var size: ImageSize = .square
    @State private var count = 1
    @State private var isGenerating = false
    @State private var task: Task<Void, Never>?
    @State private var error: String?

    // Image-model (mflux) install gate. nil = unknown.
    @State private var installed: Bool?
    @State private var installing = false
    @State private var installStatus = ""

    @State private var preview: GeneratedImage?
    @FocusState private var promptFocused: Bool

    enum ImageSize: String, CaseIterable, Identifiable {
        case square = "Square", portrait = "Portrait", landscape = "Landscape"
        var id: String { rawValue }
        var dims: (w: Int, h: Int) {
            switch self {
            case .square:    (1024, 1024)
            case .portrait:  (768, 1024)
            case .landscape: (1024, 768)
            }
        }
        var icon: String {
            switch self {
            case .square: "square"; case .portrait: "rectangle.portrait"; case .landscape: "rectangle"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                gallery
                Divider()
                promptBar
            }
            .navigationTitle("Imagine")
        }
        .task { if installed == nil { installed = await imageGen.installed() } }
        .sheet(item: $preview) { img in ImagePreviewSheet(image: img, store: store) }
    }

    // MARK: - Gallery

    @ViewBuilder
    private var gallery: some View {
        if store.images.isEmpty {
            ContentUnavailableView {
                Label("Imagine anything", systemImage: "photo.artframe")
            } description: {
                Text("Describe a picture below and generate it locally on your Mac.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 14)], spacing: 14) {
                    ForEach(store.images) { img in
                        GalleryThumb(url: store.url(for: img))
                            .onTapGesture { preview = img }
                            .contextMenu {
                                Button("Save image…", systemImage: "square.and.arrow.down") { save(img) }
                                Button("Copy prompt", systemImage: "doc.on.doc") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(img.prompt, forType: .string)
                                }
                                Button("Use this prompt", systemImage: "arrow.uturn.left") {
                                    prompt = img.prompt; promptFocused = true
                                }
                                Button("Make another like this", systemImage: "wand.and.stars") {
                                    prompt = img.prompt; size = matchSize(img); generate()
                                }
                                Divider()
                                Button("Delete", systemImage: "trash", role: .destructive) { store.delete(img.id) }
                            }
                    }
                }
                .padding(16)
            }
        }
    }

    // MARK: - Prompt bar

    @ViewBuilder
    private var promptBar: some View {
        VStack(spacing: 8) {
            if installed == false {
                installGate
            }
            if let p = imageGen.progress, isGenerating {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(p.loadingModel
                         ? "Loading the image model… (first run downloads ~10 GB)"
                         : "Rendering image \(min(p.done + 1, p.total)) of \(p.total)…")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Describe an image — e.g. “a cozy cabin in a snowy pine forest at dusk, warm light in the windows”",
                          text: $prompt, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .focused($promptFocused)
                    .onSubmit(generate)

                Menu {
                    Picker("Size", selection: $size) {
                        ForEach(ImageSize.allCases) { Label($0.rawValue, systemImage: $0.icon).tag($0) }
                    }
                    Picker("How many", selection: $count) {
                        ForEach(1...4, id: \.self) { Text("\($0) image\($0 == 1 ? "" : "s")").tag($0) }
                    }
                } label: {
                    Label("\(size.rawValue) · \(count)×", systemImage: "slider.horizontal.3")
                }
                .menuStyle(.borderlessButton).fixedSize()

                if isGenerating {
                    Button(role: .destructive) { stop() } label: { Label("Stop", systemImage: "stop.fill") }
                        .keyboardShortcut(".", modifiers: [.command])
                } else {
                    Button(action: generate) { Label("Generate", systemImage: "sparkles") }
                        .buttonStyle(.borderedProminent).tint(.brand)
                        .keyboardShortcut(.return, modifiers: [.command])
                        .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || installed == false)
                }
            }
        }
        .padding(10)
    }

    private var installGate: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo.badge.plus").font(.title2).foregroundStyle(Color.brand)
            VStack(alignment: .leading, spacing: 2) {
                Text("Set up the image generator").font(.subheadline.weight(.semibold))
                Text("One-time: installs the local FLUX model (mflux). First image downloads ~10 GB.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if installing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(installStatus.isEmpty ? "Installing…" : installStatus)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Button("Install") { installImageGen() }.buttonStyle(.borderedProminent).tint(.brand)
            }
        }
        .padding(12)
        .background(Color.brand.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Actions

    private func generate() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isGenerating, installed != false else { return }
        error = nil
        isGenerating = true
        let (w, h) = size.dims
        var requests: [ImageGenService.Request] = []
        var pending: [(file: String, seed: Int)] = []
        for _ in 0..<count {
            let seed = Int.random(in: 0..<Int(Int32.max))
            let file = "\(UUID().uuidString).png"
            requests.append(.init(prompt: text,
                                  output: PathResolver.imagesDir.appendingPathComponent(file),
                                  seed: seed))
            pending.append((file, seed))
        }
        task = Task {
            let saved = await ImageGenService.shared.generate(requests, steps: 4, width: w, height: h)
            if Task.isCancelled {
                for p in saved { try? FileManager.default.removeItem(at: URL(fileURLWithPath: p)) }
            } else {
                let names = Set(saved.map { URL(fileURLWithPath: $0).lastPathComponent })
                // Insert oldest-first so the batch reads left-to-right, newest overall on top.
                for p in pending.reversed() where names.contains(p.file) {
                    store.add(GeneratedImage(prompt: text, file: p.file, seed: p.seed, width: w, height: h))
                }
                if saved.isEmpty { error = "Couldn't generate an image — check Settings ▸ Logs." }
            }
            isGenerating = false
        }
    }

    private func stop() {
        task?.cancel()
        task = nil
        isGenerating = false
    }

    private func matchSize(_ img: GeneratedImage) -> ImageSize {
        if img.width == img.height { return .square }
        return img.width > img.height ? .landscape : .portrait
    }

    private func save(_ img: GeneratedImage) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "image.png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: store.url(for: img), to: dest)
    }

    private func installImageGen() {
        installing = true; installStatus = ""
        Task {
            let ok = await imageGen.install { line in installStatus = line }
            installed = ok ? true : await imageGen.installed()
            installing = false
        }
    }
}

// MARK: - Gallery thumbnail

/// Async-loads a generated PNG off the main thread and caches it, so a large gallery
/// doesn't re-decode on every redraw.
private struct GalleryThumb: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable().scaledToFill()
                    .frame(height: 200).frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
            } else {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4))
                    .frame(height: 200)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .clipped()
        .task(id: url) { image = await Self.load(url) }
    }

    private static func load(_ url: URL) async -> NSImage? {
        await Task.detached(priority: .utility) { NSImage(contentsOf: url) }.value
    }
}

// MARK: - Full-size preview

private struct ImagePreviewSheet: View {
    let image: GeneratedImage
    let store: ImagineStore
    @Environment(\.dismiss) private var dismiss
    @State private var loaded: NSImage?

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("\(image.width)×\(image.height) · seed \(image.seed)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let loaded {
                Image(nsImage: loaded)
                    .resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text(image.prompt).font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            HStack {
                Button("Save image…", systemImage: "square.and.arrow.down") { saveOut() }
                Button("Copy prompt", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(image.prompt, forType: .string)
                }
                Spacer()
                Button("Delete", systemImage: "trash", role: .destructive) {
                    store.delete(image.id); dismiss()
                }
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 560)
        .task { loaded = await Task.detached(priority: .utility) { NSImage(contentsOf: store.url(for: image)) }.value }
    }

    private func saveOut() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "image.png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: store.url(for: image), to: dest)
    }
}
