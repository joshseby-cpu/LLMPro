import SwiftUI

struct FirstRunView: View {
    @Environment(PythonRuntime.self) private var runtime
    var onComplete: () -> Void

    @State private var step: Int = 0
    @State private var hfToken: String = ""
    @State private var selectedStarters: Set<String> = []

    // Starter models are general-purpose Instruct bases.
    // The whole point of LLMPro is to take these and *teach them coding* via fine-tuning.
    private let starterModels: [(repo: String, blurb: String)] = [
        ("mlx-community/Llama-3.2-3B-Instruct-4bit",
         "Tiny + fast general assistant. Great target to specialize into a coder. Fits in 8 GB."),
        ("mlx-community/Qwen2.5-7B-Instruct-4bit",
         "Strong general 7B Instruct. Becomes a competent coder with ~500 LoRA steps. Fits in 16 GB."),
        ("mlx-community/Mistral-7B-Instruct-v0.3-4bit",
         "Classic Mistral instruct base. Responds well to coding SFT. Fits in 16 GB."),
        ("mlx-community/gemma-2-2b-it-4bit",
         "Tiny Gemma 2 instruct — fastest training of the four. Fits in 8 GB.")
    ]

    var body: some View {
        VStack {
            TabView(selection: $step) {
                systemCheck.tag(0)
                runtimePane.tag(1)
                tokenPane.tag(2)
                startersPane.tag(3)
                finishPane.tag(4)
            }
            .tabViewStyle(.automatic)
            .frame(minWidth: 720, minHeight: 480)
            HStack {
                if step > 0 { Button("Back") { step -= 1 } }
                Spacer()
                if step < 4 {
                    Button(step == 1 ? "Continue when ready" : "Continue") { step += 1 }
                        .disabled(step == 1 && !runtime.isReady)
                } else {
                    Button("Finish") { onComplete() }
                }
            }
            .padding()
        }
        .padding()
    }

    private var systemCheck: some View {
        VStack(spacing: 16) {
            Text("Welcome to LLMPro").font(.largeTitle.bold())
            Text("A native macOS app for fine-tuning local LLMs with Apple's MLX framework.").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                checkRow(ok: isAppleSilicon, label: "Apple Silicon Mac")
                checkRow(ok: macOS14Plus, label: "macOS 14+")
                checkRow(ok: hasEnoughRAM, label: "≥ 16 GB unified memory recommended (for 7B models)")
            }
            .card()
        }
    }

    private var runtimePane: some View {
        // See IndexedLogLine: the inline Array(...suffix.enumerated()) chain is a
        // type-check hot spot that the preview compiler makes worse.
        let lines: [IndexedLogLine] = IndexedLogLine.tail(of: runtime.logTail, count: 40)
        return VStack(spacing: 12) {
            Text("Python runtime").font(.title2.bold())
            Text(runtime.statusLine).foregroundStyle(runtime.statusColor)
            ProgressView().opacity(runtime.isReady ? 0 : 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(lines) { line in
                        Text(line.text).font(.system(.caption2, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 200)
            .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(.green)
            HStack {
                Button("Retry bootstrap") { Task { await runtime.bootstrap() } }
            }
        }
        .padding()
    }

    private var tokenPane: some View {
        VStack(spacing: 12) {
            Text("HuggingFace token (optional)").font(.title2.bold())
            Text("Needed for gated models. Stored in Keychain — never sent anywhere else.").foregroundStyle(.secondary)
            SecureField("hf_...", text: $hfToken).textFieldStyle(.roundedBorder).frame(maxWidth: 480)
            Button("Save to Keychain") {
                _ = KeychainHelper.writeHFToken(hfToken)
            }
            .disabled(hfToken.isEmpty)
        }
        .padding()
    }

    private var startersPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Starter coding models").font(.title2.bold())
            Text("We can download these in the background while you set up your first dataset.").foregroundStyle(.secondary)
            ForEach(starterModels, id: \.repo) { item in
                Toggle(isOn: Binding(
                    get: { selectedStarters.contains(item.repo) },
                    set: { on in
                        if on { selectedStarters.insert(item.repo) } else { selectedStarters.remove(item.repo) }
                    }
                )) {
                    VStack(alignment: .leading) {
                        Text(item.repo).font(.headline)
                        Text(item.blurb).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
    }

    private var finishPane: some View {
        VStack(spacing: 16) {
            Text("Ready to go!").font(.largeTitle.bold())
            Text("Selected starters will download in the background.").foregroundStyle(.secondary)
            Button("Open Dashboard") {
                for repo in selectedStarters {
                    Task { await DownloadService.shared.download(repoID: repo) }
                }
                onComplete()
            }
            .keyboardShortcut(.return)
            .controlSize(.large)
        }
        .padding()
    }

    private func checkRow(ok: Bool, label: String) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
            Text(label)
            Spacer()
        }
    }

    private var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }
    private var macOS14Plus: Bool {
        if #available(macOS 14, *) { return true } else { return false }
    }
    private var hasEnoughRAM: Bool {
        ProcessInfo.processInfo.physicalMemory >= 16 * 1024 * 1024 * 1024
    }
}

#if DEBUG
#Preview("First run") {
    FirstRunView(onComplete: {})
        .previewEnvironment()
}
#endif
