import SwiftUI

struct SettingsView: View {
    @Environment(PythonRuntime.self) private var runtime
    @State private var hfTokenDraft: String = ""
    @State private var savedTokenStatus: String = ""
    @State private var logText: String = ""

    var body: some View {
        TabView {
            runtime_tab.tabItem { Label("Runtime", systemImage: "terminal") }
            paths_tab.tabItem { Label("Paths", systemImage: "folder") }
            logs_tab.tabItem { Label("Logs", systemImage: "doc.text.magnifyingglass") }
            hf_tab.tabItem { Label("HuggingFace", systemImage: "person.crop.circle") }
        }
        .padding()
        .frame(minWidth: 600, minHeight: 400)
    }

    /// Live tail of the app log (`llmpro.log`) — the first place to look when
    /// something breaks. Errors, subprocess failures, server load problems, and a
    /// post-crash backtrace breadcrumb all land here without needing Console.app.
    private var logs_tab: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Application log").font(.headline)
                Spacer()
                Button { logText = Log.tail() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                Button { NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL]) } label: {
                    Label("Reveal", systemImage: "folder")
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(logText.isEmpty ? Log.tail() : logText, forType: .string)
                } label: { Label("Copy", systemImage: "doc.on.doc") }
            }
            ScrollView {
                Text(logText.isEmpty ? "(log is empty — nothing recorded yet this session)" : logText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            Text("Newest entries at the bottom · stored at \(Log.fileURL.path)")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .onAppear { logText = Log.tail() }
    }

    private var runtime_tab: some View {
        Form {
            LabeledContent("Status", value: runtime.statusLine)
            LabeledContent("Python", value: runtime.pythonURL?.path ?? "—")
            Section {
                Button("Recreate venv") {
                    try? FileManager.default.removeItem(at: PathResolver.venvDir)
                    Task { await runtime.bootstrap() }
                }
                Button("Open logs folder") {
                    NSWorkspace.shared.open(PathResolver.logsDir)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var paths_tab: some View {
        Form {
            LabeledContent("App Support", value: PathResolver.appSupport.path)
            LabeledContent("HF cache", value: PathResolver.hfHome.path)
            LabeledContent("Adapters", value: PathResolver.adaptersDir.path)
            LabeledContent("Datasets", value: PathResolver.datasetsDir.path)
            LabeledContent("Exports", value: PathResolver.exportsDir.path)
            Section {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([PathResolver.appSupport])
                }
            }
        }
        .formStyle(.grouped)
    }

    private var hf_tab: some View {
        Form {
            Section("HuggingFace token") {
                SecureField("hf_...", text: $hfTokenDraft)
                Button("Save to Keychain") {
                    savedTokenStatus = KeychainHelper.writeHFToken(hfTokenDraft) ? "✓ Saved" : "✗ Failed"
                }
                Text(savedTokenStatus).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

#if DEBUG
#Preview("Settings") {
    SettingsView().previewEnvironment()
}
#endif
