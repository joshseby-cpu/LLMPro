import SwiftUI

/// The "Memory" tab — see what's using RAM/GPU, understand where a model's
/// memory goes (experts dominate MoE footprints), profile which experts
/// actually fire, prune the cold ones, and cap MLX's memory budget.
struct MemoryView: View {
    @State private var metrics = SystemMetrics.shared
    @State private var mem = MemoryService.shared
    @State private var registry = ModelRegistry.shared
    @State private var expertSvc = ExpertManagementService.shared

    @State private var breakdownModelID: String = ""
    @State private var profileModelID: String = ""
    @State private var pruneName: String = ""

    private var moeModels: [ModelRegistry.DetectedModel] { registry.localModels.filter { $0.isMoE } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                liveSection
                Divider()
                breakdownSection
                Divider()
                profilerSection
                Divider()
                budgetSection
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .navigationTitle("Memory")
        .onAppear {
            metrics.start()
            Task { await mem.loadDeviceInfo() }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Memory").font(.largeTitle.bold())
            Text("See what's using memory, understand where a model's weight goes, and trim the experts you don't use.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Live memory

    private var liveSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Label("Live memory", systemImage: "gauge.with.dots.needle.67percent").font(.title3.bold())
                HelpHint("Unified & GPU memory",
                         "Apple Silicon shares one pool of RAM between the CPU and GPU. The bar shows how much of that pool is in use right now. The orange marker is Metal's recommended working-set ceiling — a single process that pushes past it hits a GPU out-of-memory error even though the OS still reports free RAM. That gap is why a training run can crash 'below the limit'.",
                         learnMore: URL(string: "https://developer.apple.com/documentation/metal/mtldevice/recommendedmaxworkingsetsize"))
                Spacer()
                if let d = mem.device {
                    Text(d.deviceName).font(.caption).foregroundStyle(.secondary)
                }
            }

            let usedGB = metrics.current.usedGB
            let totalGB = max(metrics.current.totalGB, 0.001)
            let ceilingGB = mem.device.map { Double($0.maxWorkingSet) / 1_073_741_824.0 } ?? 0

            memoryBar(usedGB: usedGB, totalGB: totalGB, ceilingGB: ceilingGB)

            HStack(spacing: 16) {
                legendSwatch(.blue, "In use \(String(format: "%.1f", usedGB)) GB")
                if ceilingGB > 0 {
                    legendSwatch(.orange, "Metal ceiling \(String(format: "%.0f", ceilingGB)) GB")
                }
                legendSwatch(.secondary, "Total \(String(format: "%.0f", totalGB)) GB")
                Spacer()
            }
            .font(.caption)
        }
    }

    private func memoryBar(usedGB: Double, totalGB: Double, ceilingGB: Double) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let usedFrac = min(max(usedGB / totalGB, 0), 1)
            let ceilFrac = ceilingGB > 0 ? min(max(ceilingGB / totalGB, 0), 1) : 0
            let danger = ceilingGB > 0 && usedGB > 0.9 * ceilingGB
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5))
                RoundedRectangle(cornerRadius: 6)
                    .fill(danger ? Color.red : Color.blue)
                    .frame(width: w * usedFrac)
                if ceilFrac > 0 {
                    Rectangle().fill(Color.orange)
                        .frame(width: 2.5)
                        .offset(x: w * ceilFrac - 1.25)
                }
            }
        }
        .frame(height: 22)
    }

    // MARK: - Per-model breakdown

    private var breakdownSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Label("Where a model's memory goes", systemImage: "chart.pie").font(.title3.bold())
                HelpHint("Resident vs active memory",
                         "Every weight must sit in memory to be loadable, but a Mixture-of-Experts model only runs top-k of its experts per token. So the resident footprint (all experts) is much larger than what's active for any single token. Pruning experts you never use shrinks the resident footprint directly.",
                         learnMore: URL(string: "https://huggingface.co/blog/moe"))
                Spacer()
            }

            Picker("Model", selection: $breakdownModelID) {
                Text("Choose a model…").tag("")
                ForEach(registry.localModels, id: \.repoID) { m in
                    Text(m.displayName).tag(m.repoID)
                }
            }
            .labelsHidden()
            .onChange(of: breakdownModelID) { _, id in
                if let m = registry.localModels.first(where: { $0.repoID == id }) {
                    mem.computeBreakdown(for: m)
                }
            }

            if mem.breakdownLoading {
                HStack { ProgressView().controlSize(.small); Text("Reading weight headers…") }
            } else if let b = mem.breakdown, breakdownModelID == mem.breakdownModelID {
                breakdownDetail(b)
            } else if breakdownModelID.isEmpty {
                Text("Pick a model to see its expert / non-expert split.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func breakdownDetail(_ b: MemoryService.ModelBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Stacked resident bar: experts vs rest
            if b.isMoE {
                GeometryReader { geo in
                    let w = geo.size.width
                    let ef = b.expertFraction
                    HStack(spacing: 0) {
                        Rectangle().fill(Color.purple).frame(width: w * ef)
                        Rectangle().fill(Color.teal).frame(width: w * (1 - ef))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .frame(height: 22)
                HStack(spacing: 16) {
                    legendSwatch(.purple, "Experts \(MemoryService.gb(b.expert)) (\(Int(b.expertFraction * 100))%)")
                    legendSwatch(.teal, "Everything else \(MemoryService.gb(b.nonexpert))")
                    Spacer()
                }
                .font(.caption)

                statGrid([
                    ("Resident (all weights)", MemoryService.gb(b.total)),
                    ("Active per token (top-\(b.topK) of \(b.numExperts))", MemoryService.gb(b.activeEstimate)),
                    ("Per expert", MemoryService.gb(b.perExpert)),
                    ("Experts", "\(b.numExperts)"),
                ])
                Text("This MoE keeps \(MemoryService.gb(b.total)) resident but only ~\(MemoryService.gb(b.activeEstimate)) is active for any single token. Profile + prune below to reclaim the cold experts.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                statGrid([
                    ("Total weights", MemoryService.gb(b.total)),
                    ("Tensors", "\(b.tensors)"),
                    ("Shards", "\(b.shards)"),
                    ("Type", "Dense (no experts)"),
                ])
                Text("This is a dense model — there are no experts to profile or prune. To shrink it, use Shrink (quantize) in the Modify dialog.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Expert profiler

    private var profilerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Label("Expert usage profiler", systemImage: "scope").font(.title3.bold())
                Text("EXPERIMENTAL")
                    .font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.2), in: Capsule()).foregroundStyle(.orange)
                HelpHint("Expert profiling",
                         "Runs a batch of representative prompts through the model and records which experts the router picks for every token at every layer. Experts that almost never fire ('cold') are good prune candidates — removing them shrinks the resident footprint with little quality loss for your kind of workload. Prune, then fine-tune in Teach so the router re-balances.",
                         learnMore: URL(string: "https://huggingface.co/blog/moe"))
                Spacer()
            }

            if moeModels.isEmpty {
                Text("No Mixture-of-Experts models found locally. Profiling only applies to MoE models (Mixtral, Qwen-MoE, Gemma-4, …).")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("MoE model", selection: $profileModelID) {
                    Text("Choose an MoE model…").tag("")
                    ForEach(moeModels, id: \.repoID) { m in
                        Text("\(m.displayName) · \(m.numExperts) experts").tag(m.repoID)
                    }
                }
                .labelsHidden()

                HStack {
                    Button {
                        if let m = moeModels.first(where: { $0.repoID == profileModelID }) {
                            mem.profileExperts(for: m)
                        }
                    } label: {
                        Label("Profile experts", systemImage: "play.fill")
                    }
                    .disabled(profileModelID.isEmpty || mem.isProfiling)
                    if case .running(let msg) = mem.profileStage {
                        ProgressView().controlSize(.small)
                        Text(msg).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                }

                if case .failed(let reason) = mem.profileStage {
                    Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                }

                if mem.profileStage == .done, let r = mem.profileResult {
                    profileResultView(r)
                }
            }
        }
    }

    @ViewBuilder
    private func profileResultView(_ r: MemoryService.ProfileResult) -> some View {
        let maxFrac = max(r.fractions.max() ?? 0, 0.0001)
        VStack(alignment: .leading, spacing: 10) {
            Text("\(r.decisions) routing decisions over \(r.prompts) prompts. \(r.cold.count) of \(r.numExperts) experts are cold (selected far below average).")
                .font(.caption).foregroundStyle(.secondary)

            // Heat grid of experts: green = hot, fading to red = cold.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 30, maximum: 40), spacing: 3)], spacing: 3) {
                ForEach(0..<r.numExperts, id: \.self) { i in
                    let frac = i < r.fractions.count ? r.fractions[i] : 0
                    let isCold = r.cold.contains(i)
                    Text("\(i)")
                        .font(.system(size: 9).monospacedDigit())
                        .frame(maxWidth: .infinity, minHeight: 22)
                        .background(heatColor(frac, maxFrac), in: RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(isCold ? Color.red : .clear, lineWidth: 1.5))
                        .foregroundStyle(.white)
                        .help("Expert \(i): \(String(format: "%.2f", frac)) avg selections/decision\(isCold ? " · COLD" : "")")
                }
            }
            HStack(spacing: 16) {
                legendSwatch(.green, "Hot (frequently used)")
                legendSwatch(.gray, "Warm")
                legendSwatch(.red.opacity(0.7), "Cold (prune candidate)")
                Spacer()
            }.font(.caption2)

            if !r.cold.isEmpty {
                pruneControl(coldCount: r.cold.count, cold: Set(r.cold))
            }
        }
    }

    @ViewBuilder
    private func pruneControl(coldCount: Int, cold: Set<Int>) -> some View {
        let model = moeModels.first(where: { $0.repoID == profileModelID })
        let canPrune = model != nil && coldCount > 0 && coldCount < (model?.numExperts ?? 0) - 1
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("pruned-model-name", text: $pruneName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                Button {
                    if let m = model {
                        let name = pruneName.isEmpty ? "\(m.displayName)-pruned\(coldCount)" : pruneName
                        mem.pruneExperts(from: m, indices: cold, outputName: name)
                    }
                } label: {
                    Label("Prune \(coldCount) cold experts", systemImage: "scissors")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canPrune)
                Spacer()
            }
            if !canPrune && coldCount > 0 {
                Text("Too many cold experts to prune safely (would leave fewer than 2). Consider profiling with more prompts.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            expertJobProgress
        }
    }

    @ViewBuilder
    private var expertJobProgress: some View {
        if let active = expertSvc.active {
            switch active.stage {
            case .running(_, let message):
                HStack { ProgressView().controlSize(.small); Text(message).font(.caption).foregroundStyle(.secondary) }
            case .finished(let path, _, let old, let new):
                Label("Pruned \(old) → \(new) experts · \(path)", systemImage: "checkmark.seal.fill")
                    .font(.caption).foregroundStyle(.green).lineLimit(2)
            case .failed(let reason):
                Label(reason, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            case .idle:
                EmptyView()
            }
        }
    }

    // MARK: - Budget

    private var budgetSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Label("Memory budget", systemImage: "dial.medium").font(.title3.bold())
                HelpHint("MLX memory limit",
                         "Caps how much memory MLX will hold before it aggressively frees its cache, using mx.set_memory_limit. Setting it a little under the Metal ceiling makes long training runs free memory proactively instead of crashing at the ceiling. It trades a little speed (more cache churn) for stability. Applied to training and inference subprocesses.",
                         learnMore: URL(string: "https://ml-explore.github.io/mlx/build/html/python/_autosummary/mlx.core.set_memory_limit.html"))
                Spacer()
            }
            Toggle("Cap MLX memory during training & inference", isOn: $mem.budgetEnabled)
            if mem.budgetEnabled {
                HStack(spacing: 12) {
                    Text("Cap at \(Int(mem.budgetFraction * 100))% of ceiling")
                        .font(.subheadline)
                        .frame(width: 200, alignment: .leading)
                    Slider(value: $mem.budgetFraction, in: 0.5...1.0, step: 0.05)
                }
                if let bytes = mem.budgetBytes {
                    Text("≈ \(MemoryService.gb(bytes)) cap (ceiling \(mem.device.map { MemoryService.gb($0.maxWorkingSet) } ?? "?")).")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Detecting the GPU ceiling… open this tab again in a moment if no number appears.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Small helpers

    private func legendSwatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 11, height: 11)
            Text(label).foregroundStyle(.secondary)
        }
    }

    private func statGrid(_ items: [(String, String)]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                            GridItem(.flexible(), alignment: .leading)], spacing: 8) {
            ForEach(items, id: \.0) { item in
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.0).font(.caption2).foregroundStyle(.secondary)
                    Text(item.1).font(.callout.weight(.medium))
                }
            }
        }
    }

    private func heatColor(_ frac: Double, _ maxFrac: Double) -> Color {
        // 0 → red (cold), mid → gray, max → green (hot)
        let t = min(max(frac / maxFrac, 0), 1)
        if t < 0.25 { return Color.red.opacity(0.55 + 0.25 * (1 - t * 4)) }
        if t < 0.6  { return Color.gray.opacity(0.55) }
        return Color.green.opacity(0.45 + 0.45 * t)
    }
}

#if DEBUG
#Preview("Memory") {
    MemoryView().previewEnvironment()
}
#endif
