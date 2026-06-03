import Foundation
import SwiftUI

@MainActor
@Observable
final class DownloadService {
    static let shared = DownloadService()

    struct ActiveDownload: Identifiable {
        let id: UUID = UUID()
        let repoID: String
        var fileLabel: String = ""
        var bytesDownloaded: Int64 = 0
        var bytesTotal: Int64 = 0
        var startedAt: Date = Date()
        var done: Bool = false
        var error: String?

        var percent: Double {
            bytesTotal > 0 ? Double(bytesDownloaded) / Double(bytesTotal) : 0
        }
    }

    private(set) var active: [ActiveDownload] = []
    private(set) var history: [ActiveDownload] = []

    private init() {}

    func download(repoID: String) async {
        guard PythonRuntime.shared.isReady, let python = PythonRuntime.shared.pythonURL else { return }
        var entry = ActiveDownload(repoID: repoID)
        active.append(entry)
        let idx = active.count - 1

        let helper = PathResolver.helpersDir.appendingPathComponent("hf_download.py")
        guard FileManager.default.fileExists(atPath: helper.path) else {
            entry.error = "hf_download.py missing — runtime not fully bootstrapped."
            active[idx] = entry
            return
        }

        let token = KeychainHelper.readHFToken() ?? ""
        do {
            let _ = try await ProcessRunner.runCapturing(
                executable: python,
                arguments: [helper.path, repoID, PathResolver.hfHome.path, token],
                environment: ["HF_HOME": PathResolver.hfHome.path],
                onStdout: { [weak self] line in
                    Task { @MainActor in self?.handle(line: line, repoID: repoID) }
                },
                onStderr: { _ in }
            )
        } catch {
            await MainActor.run {
                if let i = self.active.firstIndex(where: { $0.repoID == repoID && !$0.done }) {
                    self.active[i].error = error.localizedDescription
                }
            }
        }

        await MainActor.run {
            if let i = self.active.firstIndex(where: { $0.repoID == repoID && !$0.done }) {
                var done = self.active.remove(at: i)
                done.done = true
                self.history.append(done)
            }
            Task { await ModelRegistry.shared.scan() }
        }
    }

    private func handle(line: String, repoID: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        guard let i = active.firstIndex(where: { $0.repoID == repoID && !$0.done }) else { return }
        var entry = active[i]

        switch json["event"] as? String {
        case "start":
            if let total = json["total_bytes"] as? NSNumber {
                entry.bytesTotal = Int64(total.int64Value)
            }
        case "progress":
            entry.fileLabel = (json["file"] as? String) ?? entry.fileLabel
            if let downloaded = json["downloaded"] as? NSNumber {
                entry.bytesDownloaded = Int64(downloaded.int64Value)
            }
            if let total = json["total"] as? NSNumber, total.int64Value > 0 {
                entry.bytesTotal = Int64(total.int64Value)
            }
        case "done":
            // Cap the bar at 100% but DO NOT mark done — the cleanup block in download()
            // owns the active → history transition once the subprocess exits.
            if entry.bytesTotal > 0 { entry.bytesDownloaded = entry.bytesTotal }
        case "error":
            entry.error = (json["message"] as? String) ?? "Unknown error"
        default:
            break
        }
        active[i] = entry
    }
}

enum KeychainHelper {
    static let hfTokenAccount = "llmpro.hfToken"

    static func readHFToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "LLMPro",
            kSecAttrAccount as String: hfTokenAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8)
        else { return nil }
        return s
    }

    @discardableResult
    static func writeHFToken(_ token: String) -> Bool {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "LLMPro",
            kSecAttrAccount as String: hfTokenAccount
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }
}
