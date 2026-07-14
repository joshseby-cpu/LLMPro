import SwiftUI

struct SettingsView: View {
    @Environment(PythonRuntime.self) private var runtime
    @State private var hfTokenDraft: String = ""
    @State private var savedTokenStatus: String = ""
    @State private var logText: String = ""
    @State private var llamaCppInstalled: Bool = false
    @State private var installingLlamaCpp: Bool = false
    @State private var llamaCppStatus: String = ""
    @State private var toolsBuilt: Bool = false
    @State private var buildingTools: Bool = false
    @AppStorage(KeepAwakeService.prefKey) private var keepAwake: Bool = true
    @State private var confirmRecreateVenv = false

    var body: some View {
        TabView {
            runtime_tab.tabItem { Label("Runtime", systemImage: "terminal") }
            StorageSettingsView().tabItem { Label("Storage", systemImage: "internaldrive") }
            paths_tab.tabItem { Label("Paths", systemImage: "folder") }
            logs_tab.tabItem { Label("Logs", systemImage: "doc.text.magnifyingglass") }
            hf_tab.tabItem { Label("HuggingFace", systemImage: "person.crop.circle") }
        }
        .padding()
        .frame(minWidth: 600, minHeight: 440)
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
                    confirmRecreateVenv = true
                }
                .disabled(!JobRegistry.shared.runningJobs.isEmpty || SelfImproveService.shared.isRunning)
                .help(JobRegistry.shared.runningJobs.isEmpty && !SelfImproveService.shared.isRunning
                      ? "Delete and rebuild the Python runtime"
                      : "Can't rebuild the runtime while a job is running")
                Button("Open logs folder") {
                    NSWorkspace.shared.open(PathResolver.logsDir)
                }
            }
            .confirmationDialog("Rebuild the Python runtime?",
                                isPresented: $confirmRecreateVenv, titleVisibility: .visible) {
                Button("Delete & rebuild", role: .destructive) {
                    try? FileManager.default.removeItem(at: PathResolver.venvDir)
                    Task { await runtime.bootstrap() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Deletes the mlx-lm virtual environment and downloads a fresh one (a few minutes). Your models, lessons, and training runs are untouched.")
            }
            Section("Power") {
                Toggle("Keep my Mac awake during training", isOn: $keepAwake)
                    .onChange(of: keepAwake) { _, _ in
                        KeepAwakeService.shared.refresh(runningCount: JobRegistry.shared.runningJobs.count)
                    }
                Text("Holds a power assertion (caffeinate) while a Teach or Practice run is going, so sleep doesn't pause it.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Section("GGUF export tools") {
                LabeledContent("llama.cpp converter",
                               value: llamaCppInstalled ? "Installed" : "Not installed")
                Button {
                    Task { await installLlamaCpp() }
                } label: {
                    if installingLlamaCpp {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Installing…")
                        }
                    } else {
                        Text(llamaCppInstalled ? "Reinstall llama.cpp converter" : "Install llama.cpp converter")
                    }
                }
                .disabled(installingLlamaCpp)
                LabeledContent("k-quant + self-test tools",
                               value: toolsBuilt ? "Built" : "Not built")
                Button {
                    Task { await buildTools() }
                } label: {
                    if buildingTools {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Building…") }
                    } else {
                        Text(toolsBuilt ? "Rebuild llama.cpp tools" : "Build llama.cpp tools (k-quants + self-test)")
                    }
                }
                .disabled(buildingTools)
                if !llamaCppStatus.isEmpty {
                    Text(llamaCppStatus).font(.caption).foregroundStyle(.secondary)
                }
                Text("Converter exports Qwen / Gemma / Phi fine-tunes to GGUF. Building the tools (a few minutes) adds Q4_K_M/Q5_K_M/Q6_K and a coherence self-test.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            llamaCppInstalled = runtime.llamaCppInstalled()
            toolsBuilt = runtime.llamaToolsBuilt()
        }
    }

    private func installLlamaCpp() async {
        installingLlamaCpp = true
        defer { installingLlamaCpp = false }
        let ok = await runtime.installLlamaCpp { msg in llamaCppStatus = msg }
        llamaCppInstalled = runtime.llamaCppInstalled()
        if !ok && llamaCppStatus.isEmpty {
            llamaCppStatus = "Install failed — see Logs."
        }
    }

    private func buildTools() async {
        buildingTools = true
        defer { buildingTools = false }
        let ok = await runtime.buildLlamaCppTools { msg in llamaCppStatus = msg }
        llamaCppInstalled = runtime.llamaCppInstalled()
        toolsBuilt = runtime.llamaToolsBuilt()
        if !ok && llamaCppStatus.isEmpty {
            llamaCppStatus = "Build failed — see Logs."
        }
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
