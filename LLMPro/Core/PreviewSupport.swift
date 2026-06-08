import SwiftUI
import SwiftData

#if DEBUG

/// Scaffolding that makes every SwiftUI `#Preview` in the app render in Xcode's
/// canvas without booting any real service. It provides:
///
///   * `PreviewSupport.container` — a single in-memory `ModelContainer` registered
///     for all six `@Model` types the app uses, seeded once with realistic sample
///     data (a couple of `TrainingJob`s, some `DatasetRecord`s, a `LocalModel`, an
///     `AppSettings`, a `SelfImproveRun`, an `AgentProfile`).
///   * Convenience sample instances (`sampleJob`, `sampleDataset`, `sampleRun`, …)
///     drawn from that seeded container, for views whose initializer *requires* a
///     model object or value type.
///   * `View.previewEnvironment()` — applies the in-memory container plus the two
///     injected `@Observable` singletons (`PythonRuntime`, `JobRegistry`) and a
///     macOS-window-sized default frame, so a preview is one call away:
///
///         #Preview("Home") { DashboardView().previewEnvironment() }
///
/// Both singletons have a no-op `private init` (bootstrapping is a separate async
/// method a preview never calls), so injecting the real `.shared` instances is
/// safe and requires no mock subclasses.
///
/// This whole file is wrapped in `#if DEBUG`; it never ships in a Release build.
@MainActor
enum PreviewSupport {

    // MARK: - In-memory model container

    /// Shared in-memory container registered for every `@Model` type the app uses
    /// (mirrors `LLMProApp`'s `.modelContainer(for:)` list). Seeded once on first
    /// access. Built with `try!` deliberately: a failure here is a programmer error
    /// in the preview scaffold, and previews are debug-only.
    static let container: ModelContainer = {
        let schema = Schema([
            TrainingJob.self,
            LocalModel.self,
            DatasetRecord.self,
            AppSettings.self,
            SelfImproveRun.self,
            AgentProfile.self,
            EvalRun.self,
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: config)
        seed(container.mainContext)
        return container
    }()

    /// Insert a realistic spread of sample records so list/detail previews have
    /// something to render. Called exactly once, when `container` is first built.
    private static func seed(_ context: ModelContext) {
        for object in makeJobs() { context.insert(object) }
        for object in makeDatasets() { context.insert(object) }
        for object in makeModels() { context.insert(object) }
        context.insert(makeSettings())
        context.insert(makeRun())
        context.insert(makeAgent())
        context.insert(makeEvalRun())
        try? context.save()
    }

    // MARK: - Sample model instances (live in `container`)

    /// A running, mid-training job with a few metric points — good for Monitor /
    /// Dashboard "in progress" previews.
    static let sampleJob: TrainingJob = {
        let job = TrainingJob(
            name: "Qwen2.5-7B + CodeAlpaca",
            configYAML: sampleConfigYAML,
            baseModelRepoID: "mlx-community/Qwen2.5-7B-Instruct-4bit",
            datasetID: sampleDataset.id,
            adapterRelativePath: UUID().uuidString)
        job.status = .running
        job.startedAt = Date().addingTimeInterval(-180)
        job.pid = 4242
        for i in stride(from: 10, through: 120, by: 10) {
            let train = 1.9 - Double(i) * 0.009
            job.appendStep(TrainingStep(
                iter: i,
                trainLoss: train,
                valLoss: i % 50 == 0 ? train + 0.05 : nil,
                learningRate: 1e-5,
                tokensPerSec: 250 + Double(i),
                itersPerSec: 0.45,
                trainedTokens: i * 512,
                peakMemGB: 7.2,
                gradNorm: 0.8,
                isEval: i % 50 == 0))
        }
        return job
    }()

    /// A completed job — good for Export / Dashboard "done" previews.
    static let sampleCompletedJob: TrainingJob = {
        let job = TrainingJob(
            name: "Llama-3.2-3B coding lesson",
            configYAML: sampleConfigYAML,
            baseModelRepoID: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            datasetID: sampleDataset.id,
            adapterRelativePath: UUID().uuidString)
        job.status = .completed
        job.startedAt = Date().addingTimeInterval(-600)
        job.endedAt = Date().addingTimeInterval(-300)
        job.lastIter = 200
        job.lastLoss = 0.74
        job.lastEvalLoss = 0.81
        return job
    }()

    /// The dataset the sample jobs train on.
    static let sampleDataset = DatasetRecord(
        name: "CodeAlpaca (20k)",
        schema: .chat,
        trainRows: 18_000,
        validRows: 1_000,
        testRows: 1_000,
        notes: "Curated coding-instruction dataset normalized to chat schema.")

    static let sampleDatasetSmall = DatasetRecord(
        name: "My hand-written lessons",
        schema: .chat,
        trainRows: 42,
        validRows: 6,
        testRows: 6,
        notes: "")

    static let sampleDatasetEvol = DatasetRecord(
        name: "Magicoder Evol Instruct",
        schema: .chat,
        trainRows: 110_000,
        validRows: 2_000,
        testRows: 2_000)

    static let sampleModel = LocalModel(
        repoID: "mlx-community/Qwen2.5-7B-Instruct-4bit",
        displayName: "Qwen2.5-7B-Instruct-4bit",
        architecture: "qwen2",
        quantization: "4bit",
        sizeBytes: 4_300_000_000,
        path: "/tmp/preview/Qwen2.5-7B-Instruct-4bit",
        isMLXReady: true)

    static let sampleModelSmall = LocalModel(
        repoID: "mlx-community/Llama-3.2-3B-Instruct-4bit",
        displayName: "Llama-3.2-3B-Instruct-4bit",
        architecture: "llama",
        quantization: "4bit",
        sizeBytes: 1_900_000_000,
        path: "/tmp/preview/Llama-3.2-3B-Instruct-4bit",
        isMLXReady: true)

    static let sampleSettings = AppSettings()

    /// A practice run with a baseline + one completed round, so the trend chart and
    /// round list have data.
    static let sampleRun: SelfImproveRun = {
        let run = SelfImproveRun(
            name: "Llama-3.2-1B HumanEval",
            baseModelRepoID: "mlx-community/Llama-3.2-1B-Instruct-4bit",
            seed: .humaneval,
            targetRounds: 3,
            candidatesPerPrompt: 4,
            rowsPerRound: 20,
            trainIters: 80)
        run.status = .completed
        run.baselinePassAtOne = 0.18
        run.startedAt = Date().addingTimeInterval(-900)
        run.endedAt = Date().addingTimeInterval(-120)
        run.appendRound(SelfImproveRoundRecord(
            roundNumber: 1,
            startedAt: Date().addingTimeInterval(-800),
            endedAt: Date().addingTimeInterval(-500),
            candidatesPerPrompt: 4,
            rowsAttempted: 20,
            rowsKept: 11,
            totalCandidates: 80,
            totalPasses: 17,
            datasetRelativePath: "selfimprove/preview/round_1/dataset",
            adapterRelativePath: UUID().uuidString,
            roundJobID: UUID(),
            evalPassAtOne: 0.27))
        return run
    }()

    /// A completed scored-evaluation run — HumanEval, 40 problems, ~0.78 pass@1,
    /// with a few per-task results so the score view and task list have data.
    static let sampleEvalRun: EvalRun = {
        let run = EvalRun(
            baseModelRepoID: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            adapterRelativePath: UUID().uuidString,
            suite: .humaneval,
            k: 1,
            problemCount: 40,
            passAtK: 0.78,
            passedCount: 31,
            totalCount: 40,
            status: .completed,
            sourceLabel: "Test")
        run.elapsedMs = 92_000
        run.setTasks([
            EvalTaskResult(taskID: "HumanEval/0", passed: true,  reason: ""),
            EvalTaskResult(taskID: "HumanEval/1", passed: true,  reason: ""),
            EvalTaskResult(taskID: "HumanEval/2", passed: false, reason: "AssertionError"),
            EvalTaskResult(taskID: "HumanEval/3", passed: true,  reason: ""),
            EvalTaskResult(taskID: "HumanEval/4", passed: false, reason: "timeout"),
        ])
        return run
    }()

    static let sampleAgent = AgentProfile(
        name: "Careful Coder",
        emoji: "🧑‍💻",
        detail: "A conservative coding assistant that asks before editing.",
        modelRepoID: "mlx-community/Qwen2.5-7B-Instruct-4bit",
        instructions: "Prefer correct, idiomatic code with minimal commentary.",
        temperature: 0.2,
        maxTokens: 2048)

    // MARK: - Sample value types (not persisted)

    /// A `HFModel` as returned by a HuggingFace search — for `ModelDetailView`.
    static let sampleHFModel = HFModel(
        id: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
        author: "mlx-community",
        downloads: 12_345,
        likes: 210,
        lastModified: "2025-01-15T10:00:00.000Z",
        library_name: "mlx",
        pipeline_tag: "text-generation",
        tags: ["mlx", "code", "qwen2"])

    /// A `ModelRegistry.DetectedModel` (a model already on disk) — for the Models
    /// modify/expert sheets and the Inspect sub-views.
    static let sampleDetectedModel = ModelRegistry.DetectedModel(
        id: "mlx-community/Qwen2.5-7B-Instruct-4bit",
        repoID: "mlx-community/Qwen2.5-7B-Instruct-4bit",
        directory: URL(fileURLWithPath: "/tmp/preview/Qwen2.5-7B-Instruct-4bit"),
        architecture: "qwen2",
        quantization: "4bit",
        sizeBytes: 4_300_000_000,
        isMLXReady: true)

    /// A Mixture-of-Experts detected model, for expert-manager previews.
    static let sampleMoEModel = ModelRegistry.DetectedModel(
        id: "mlx-community/Mixtral-8x7B-Instruct-4bit",
        repoID: "mlx-community/Mixtral-8x7B-Instruct-4bit",
        directory: URL(fileURLWithPath: "/tmp/preview/Mixtral-8x7B-Instruct-4bit"),
        architecture: "mixtral",
        quantization: "4bit",
        sizeBytes: 24_000_000_000,
        isMLXReady: true,
        numExperts: 8,
        expertsPerToken: 2)

    /// A chat session for the `ChatPaneView` preview, pre-populated with a turn.
    static var sampleChatSession: ChatSession {
        let session = ChatSession(
            model: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
            adapterPath: nil,
            label: "Coding fine-tune")
        session.messages = [
            ChatMessage(role: .user, text: "Write a function that reverses a string.", isStreaming: false),
            ChatMessage(role: .assistant, text: "def reverse(s: str) -> str:\n    return s[::-1]", isStreaming: false),
        ]
        return session
    }

    /// A single chat-dataset row for the row-editor preview.
    static let sampleChatRow = ChatRow(messages: [
        ChatMessageRow(role: .system, content: "You are a helpful coding assistant."),
        ChatMessageRow(role: .user, content: "How do I read a file in Swift?"),
        ChatMessageRow(role: .assistant, content: "Use `String(contentsOf:encoding:)` for text files."),
    ])

    /// A throwaway temp directory used as a "workspace" for the Code-tab previews
    /// (FileExplorer / CodeEditor / ProjectMemory). Created lazily; the previews
    /// only render initial state, so an empty dir is fine.
    static let sampleWorkspace: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LLMProPreviewWorkspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// A throwaway sample source file for the `CodeEditorView` preview.
    static let sampleFile: URL = {
        let url = sampleWorkspace.appendingPathComponent("example.swift")
        if !FileManager.default.fileExists(atPath: url.path) {
            let body = "import Foundation\n\nfunc greet(_ name: String) -> String {\n    \"Hello, \\(name)!\"\n}\n"
            try? body.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }()

    // MARK: - Seed builders

    private static func makeJobs() -> [TrainingJob] { [sampleJob, sampleCompletedJob] }
    private static func makeDatasets() -> [DatasetRecord] { [sampleDataset, sampleDatasetSmall, sampleDatasetEvol] }
    private static func makeModels() -> [LocalModel] { [sampleModel, sampleModelSmall] }
    private static func makeSettings() -> AppSettings { sampleSettings }
    private static func makeRun() -> SelfImproveRun { sampleRun }
    private static func makeAgent() -> AgentProfile { sampleAgent }
    private static func makeEvalRun() -> EvalRun { sampleEvalRun }

    private static let sampleConfigYAML = """
    model: mlx-community/Qwen2.5-7B-Instruct-4bit
    train: true
    fine_tune_type: lora
    num_layers: 16
    batch_size: 4
    iters: 200
    learning_rate: 1.0e-5
    max_seq_length: 2048
    """
}

// MARK: - View convenience

extension View {
    /// One-call preview environment for this app: in-memory SwiftData container
    /// (all six `@Model` types, seeded), the two injected `@Observable` singletons,
    /// and a macOS-window-sized default frame. Use it as the last modifier in a
    /// `#Preview` body:
    ///
    ///     #Preview("Home") { DashboardView().previewEnvironment() }
    @MainActor
    func previewEnvironment() -> some View {
        self
            .modelContainer(PreviewSupport.container)
            .environment(PythonRuntime.shared)
            .environment(JobRegistry.shared)
            .frame(minWidth: 900, minHeight: 600)
    }
}

#endif
