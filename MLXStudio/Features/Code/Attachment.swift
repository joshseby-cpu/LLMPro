import Foundation
import AppKit
import Vision

// A file/image the user attaches to a message. Because the agent talks to a
// TEXT model server (mlx_lm), we turn every attachment into text the model can
// actually use: text/code/doc files are inlined verbatim; images are run through
// on-device OCR (macOS Vision) so screenshots of code/errors become readable;
// other binaries are noted by name only. (True image understanding would need a
// vision backend; that's out of scope for the text server.)

struct Attachment: Identifiable, Hashable, Sendable {
    let id = UUID()
    let url: URL
    let name: String
    let kind: Kind

    enum Kind: String, Sendable { case text, image, other }

    init(url: URL) {
        self.url = url
        self.name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "heic", "heif", "webp"]
        if imageExts.contains(ext) {
            self.kind = .image
        } else if Attachment.looksTextual(url) {
            self.kind = .text
        } else {
            self.kind = .other
        }
    }

    private static let textExts: Set<String> = [
        "txt","md","markdown","rst","json","jsonl","xml","yml","yaml","toml","ini","cfg","conf",
        "csv","tsv","log","html","htm","css","scss","sass","less","js","jsx","mjs","cjs","ts","tsx",
        "py","cs","java","kt","kts","go","rs","rb","php","swift","c","h","cc","cpp","hpp","m","mm",
        "sh","bash","zsh","sql","gradle","properties","env","gitignore","dockerfile","makefile",
        "razor","cshtml","vue","svelte","csproj","sln","plist","gradle","lock","cmake","r","lua","pl","tex"]

    static func looksTextual(_ url: URL) -> Bool {
        if textExts.contains(url.pathExtension.lowercased()) { return true }
        // No/unknown extension: sniff small files for valid UTF-8.
        guard let size = fileSize(url), size > 0, size < 512_000,
              let data = try? Data(contentsOf: url) else { return false }
        return String(data: data, encoding: .utf8) != nil
    }

    static func fileSize(_ url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    }

    // MARK: - Turn attachments into text for the model

    static func combinedText(for attachments: [Attachment]) async -> String {
        var out = ""
        for attachment in attachments {
            switch attachment.kind {
            case .text:
                if let data = try? Data(contentsOf: attachment.url),
                   let text = String(data: data, encoding: .utf8) {
                    let capped = text.count > 64_000 ? String(text.prefix(64_000)) + "\n… (truncated)" : text
                    out += "\n\n--- Attached file: \(attachment.name) ---\n```\n\(capped)\n```"
                }
            case .image:
                let recognized = await ocrText(attachment.url)
                if recognized.isEmpty {
                    out += "\n\n[Attached image: \(attachment.name) — no readable text was found in it.]"
                } else {
                    out += "\n\n--- Attached image: \(attachment.name) (text read via OCR) ---\n\(recognized)"
                }
            case .other:
                let kb = (fileSize(attachment.url) ?? 0) / 1024
                out += "\n\n[Attached file: \(attachment.name) — \(kb) KB binary; its contents can't be read as text.]"
            }
        }
        return out
    }

    /// On-device text recognition (macOS Vision). Runs off the main actor.
    private static func ocrText(_ url: URL) async -> String {
        await Task.detached(priority: .userInitiated) {
            guard let image = NSImage(contentsOf: url),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { return "" }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
            let observations = request.results ?? []
            return observations
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
        }.value
    }
}
