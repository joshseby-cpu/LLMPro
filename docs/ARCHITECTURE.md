# Architecture

> 📝 **Maintainers**: when you add, rename, or delete a file under `LLMPro/`,
> update the module table below in the same session. See the
> [doc-maintenance contract](../CLAUDE.md#%EF%B8%8F-documentation-is-part-of-the-work--read-this-section-twice).

This doc maps every file in the project to its responsibility, so that an agent
working in one area knows what exists elsewhere. Filenames are clickable.

> If [`CLAUDE.md`](../CLAUDE.md) is the 5-minute orientation, this is the 30-minute
> deep dive. Read after CLAUDE.md.

---

## Layer cake

```
┌───────────────────────────────────────────────────────────────────────┐
│ Features/                                                              │
│   SwiftUI views per sidebar tab.                                       │
│   Should be ~all View code; minimal business logic.                    │
├───────────────────────────────────────────────────────────────────────┤
│ Services/                                                              │
│   The heart of the app. One service per business capability.           │
│   Most are @MainActor @Observable singletons. The actor-pattern        │
│   ones (HuggingFaceClient, FuseService) are stateless or thread-safe.  │
├───────────────────────────────────────────────────────────────────────┤
│ Models/                                                                │
│   SwiftData @Model types (persistent state) — TrainingJob, LocalModel, │
│   DatasetRecord, AppSettings.                                          │
├───────────────────────────────────────────────────────────────────────┤
│ Core/                                                                  │
│   Low-level utilities: ProcessRunner, PathResolver, LogStreamParser,   │
│   SyntaxHighlighter, PreviewSupport (DEBUG-only preview scaffold),      │
│   IndexedLogLine + BindingBridges (preview type-check-speed helpers).   │
│   Mostly pure Foundation + mlx, no SwiftData; the two preview helpers   │
│   are tiny SwiftUI shims.                                              │
├───────────────────────────────────────────────────────────────────────┤
│ Resources/helpers/                                                     │
│   Python helper scripts. Invoked as subprocesses; emit JSON events.    │
│   Live in the app bundle; copied into the venv on every launch by      │
│   PythonRuntime.installHelpers().                                      │
├───────────────────────────────────────────────────────────────────────┤
│ Resources/recipes/                                                     │
│   YAML training-config presets. Currently 4 coding-focused recipes.    │
└───────────────────────────────────────────────────────────────────────┘
```

---

## App / lifecycle

| File | Responsibility |
|---|---|
| [`LLMPro/App/LLMProApp.swift`](../LLMPro/App/LLMProApp.swift) | `@main` entry; sets up `WindowGroup`, `Settings` scene, SwiftData container, injects `PythonRuntime.shared` and `JobRegistry.shared` into the environment, kicks off `bootstrapIfNeeded` and `recoverOrphans` on launch. |
| [`LLMPro/App/AppDelegate.swift`](../LLMPro/App/AppDelegate.swift) | Overrides `applicationShouldTerminateAfterLastWindowClosed → false`. Quit prompt with Stop / Detach / Cancel for running training jobs. |
| [`LLMPro/App/RootView.swift`](../LLMPro/App/RootView.swift) | `NavigationSplitView` shell. Routes to Features by `SidebarSection`. Listens to cross-tab `Notification.Name` events (`.switchSidebar`, `.switchToMonitor`, `.openTrainingWithModel`, `.openChatWithModel`) to jump between tabs in response to user actions deep in other views. Runtime-status footer at the bottom of the sidebar. |
| [`LLMPro/Info.plist`](../LLMPro/Info.plist), [`LLMPro/LLMPro.entitlements`](../LLMPro/LLMPro.entitlements) | Hardened-runtime entitlements (JIT, unsigned-exec, library validation off, dyld env vars on). CFBundleIconName + CFBundleIconFile both set to `AppIcon`. |

---

## Core utilities

| File | Responsibility |
|---|---|
| [`LLMPro/Core/PathResolver.swift`](../LLMPro/Core/PathResolver.swift) | Single source of truth for every directory the app uses. Lazily creates dirs on first access. All other code calls `PathResolver.adaptersDir`, `PathResolver.datasetDir(for: uuid)`, etc. — never builds paths from raw strings. Includes `agentsDir` (`~/Library/Application Support/LLMPro/agents/`) — the editable `<role>.md` team-agent definitions seeded by `AgentStore` — `skillsDir` (`~/Library/Application Support/LLMPro/skills/`) — the Agent Skills library, one folder per `SKILL.md` package — and `evalsDir` (`~/Library/Application Support/LLMPro/evals/`) + `evalSuiteDir(for:)` — the scored-eval harness's cached suites + per-run sidecars (see [`CONTRACTS.md`](CONTRACTS.md#6-filesystem-layout-the-canonical-paths)). |
| [`LLMPro/Core/LoopHandoff.swift`](../LLMPro/Core/LoopHandoff.swift) | The feedback loop's cross-tab glue. `struct ModelHandoff: Sendable { model: String; adapterPath: String?; autoScore: Bool = false }` — a base model + optional LoRA adapter — is posted as a notification `object` to pre-fill the next stage's tab (Progress→Try-it-out/Code, Practice→Try-it-out/Code), so the user never copies a disk path by hand. **`autoScore`** (additive, default false) tells the Test node to auto-run the eval on arrival — Progress's "Grade it" CTA sets it. Receivers accept **either** a `ModelHandoff` **or** a bare `String` (model only) for backward compatibility (the dual-decode is unchanged). Also declares `Notification.Name.openCodeWithModel` (open the Code tab + load this model/adapter). **Also declares `struct PreferenceHandoff: Sendable { model; adapterPath?; datasetID: UUID }` + `Notification.Name.openTrainingWithPreferences`** — the **DPO preference back-edge**: the Arena's "Teach by preference →" CTA posts it (carrying the `.preference` dataset) and `TrainingConfigView` pre-fills + switches to DPO mode. See [`CONCEPT.md`](CONCEPT.md). |
| [`LLMPro/Core/ProcessRunner.swift`](../LLMPro/Core/ProcessRunner.swift) | `Foundation.Process` wrapper that returns `AsyncStream<String>` for stdout/stderr (line-buffered via a thread-safe `LineBuffer` class with NSLock). Two entry points: `runCapturing()` (await full completion) and `spawn()` (return a `RunningProcess` handle for streaming long-running jobs). |
| [`LLMPro/Core/LogStreamParser.swift`](../LLMPro/Core/LogStreamParser.swift) | Regex-based parser for the `Iter N: Train loss…` lines that `mlx_lm.lora` writes to stdout. Emits `TrainingStep` structs that the rest of the app consumes. The regexes are marked `nonisolated(unsafe)` because Swift Regex types aren't yet Sendable. |
| [`LLMPro/Core/SafetensorsHeader.swift`](../LLMPro/Core/SafetensorsHeader.swift) | Pure-Swift `.safetensors` header reader for the **Inspect** tab's Weights view — **no model load, no Python, no tensor data read**. Parses each shard's `8-byte little-endian u64 header length + JSON` (and `model.safetensors.index.json` for multi-shard) via `FileHandle` + `JSONSerialization`, reading only the first ~tens-of-KB of a multi-GB file → `[TensorEntry]` (name, dtype, shape, byteSize, paramCount over **all** dims). The canonical example of the Swift-first rule (structure = Swift; only deep value-stats would need the MLX sidecar). Verified exact against the cached Qwen/Gemma (byte-sum == `index.json` total_size). |
| [`LLMPro/Core/HelpHint.swift`](../LLMPro/Core/HelpHint.swift) | Reusable `HelpHint(title:, message:, learnMore:)` ⓘ-icon component. Tapping opens a popover with a plain-language explanation + an optional "Learn more →" hyperlink to authoritative reading. Used everywhere Advanced settings live (Teach, Modify, Practice, Fusion, Add experts). Convenience `LabeledHint` wraps a label + hint + content together. |
| [`LLMPro/Core/SyntaxHighlighter.swift`](../LLMPro/Core/SyntaxHighlighter.swift) | Dependency-free, regex-based multi-language syntax highlighter (no WebView / Monaco / JS runtime). `CodeLanguage` enum (swift, cSharp, python, javascript, typescript, json, html, css, xml, shell, ruby, go, rust, java, kotlin, sql, markdown, plain) with `from(path:)` (by file extension) and `from(fence:)` (by ` ```lang `), plus per-language `keywords` / `commentRegex` / `highlightsTypes`. `nsAttributed(_:language:fontSize:)` → `NSAttributedString` (for the editor's `NSTextView`); `attributed(...)` → `AttributedString` (for SwiftUI `Text` in the transcript). One combined pass claims comments + strings position-ordered (so `//` inside a string and `"` inside a comment resolve right), then numbers / keywords / capitalized type names fill the unclaimed gaps (tracked via an `IndexSet`). Palette: keyword=purple, string=green, comment=gray, number=orange, type=teal. Used by the Code tab's editor and transcript-diff rendering. |
| [`LLMPro/Core/PreviewSupport.swift`](../LLMPro/Core/PreviewSupport.swift) | **DEBUG-only** (`#if DEBUG`) SwiftUI-preview scaffold — `@MainActor enum PreviewSupport`. Holds one in-memory `ModelContainer` (`ModelConfiguration(isStoredInMemoryOnly: true)`) registered for **all 7** `@Model` types (`TrainingJob, LocalModel, DatasetRecord, AppSettings, SelfImproveRun, EvalRun, AgentProfile`) and seeded once with realistic samples — live SwiftData instances (`sampleJob`, `sampleCompletedJob`, `sampleDataset`/`…Small`/`…Evol`, `sampleModel`/`…Small`, `sampleSettings`, `sampleRun`, `sampleEvalRun`, `sampleAgent`) plus non-persisted sample value types (`sampleHFModel`, `sampleDetectedModel`, `sampleMoEModel`, `sampleChatSession`, `sampleChatRow`, `sampleWorkspace`, `sampleFile`). Provides `View.previewEnvironment()` — applies `.modelContainer(PreviewSupport.container)`, `.environment(PythonRuntime.shared)`, `.environment(JobRegistry.shared)` (the real singletons; their `private init`s are no-ops, so no mocks), and a default `.frame(minWidth: 900, minHeight: 600)`. Every view-bearing file under `Features/` (32) plus `App/RootView.swift` now carries a `#Preview` (33 total) that ends in `.previewEnvironment()`. **Adding a new `@Model` type means registering it here too** (and in `LLMProApp`), or `@Query` previews of it fail in the canvas. |
| [`LLMPro/Core/IndexedLogLine.swift`](../LLMPro/Core/IndexedLogLine.swift) | An `Identifiable` log-line-tail helper. `IndexedLogLine.tail(of:count:)` maps the last N lines of a `[String]` log to a concrete `[IndexedLogLine]` (positional-offset `id` so list diffing is unchanged), replacing the inline `ForEach(Array(log.suffix(N).enumerated()), id: \.offset)` — a deep `EnumeratedSequence<ArraySlice<…>>` chain that's **slow to type-check** and tripped the preview-dylib compiler ("unable to type-check this expression in reasonable time"). Used by [`TrainingMonitorView`](../LLMPro/Features/Monitor/TrainingMonitorView.swift) and [`FirstRunView`](../LLMPro/Features/Settings/FirstRunView.swift). See [`CONVENTIONS.md`](CONVENTIONS.md#preview-type-checker-anti-patterns-a-plain-build-is-not-enough). |
| [`LLMPro/Core/BindingBridges.swift`](../LLMPro/Core/BindingBridges.swift) | SwiftUI `Binding` adapters that keep `body` cheap to type-check. `Binding<Double>.rounding(_:)` bridges an `Int`-backed `@State` to a `Double` `Slider`/`Stepper` binding (replaces the inline `Binding(get: { Double(x) }, set: { x = Int($0.rounded()) })`). Used by [`SelfImproveView`](../LLMPro/Features/SelfImprove/SelfImproveView.swift). Same motivation as `IndexedLogLine` — lifting these out of the view `body` keeps the preview type-checker under budget. See [`CONVENTIONS.md`](CONVENTIONS.md#preview-type-checker-anti-patterns-a-plain-build-is-not-enough). |
| [`LLMPro/Core/DiskSpace.swift`](../LLMPro/Core/DiskSpace.swift) | Pure-Foundation free-disk-space probe (no Python, no view code). `DiskSpace.freeGBForImportantUsage() -> Double?` reads `PathResolver.appSupport`'s `.volumeAvailableCapacityForImportantUsageKey` (the modern purgeable-aware key — the right number for "can I download a multi-GB model") and returns **decimal** GB (÷ 1e9, to match Finder); `Log.error` + `nil` on failure. `DiskSpace.tier(freeGB:) -> Tier` (`.ok`/`.warning`/`.critical`) is the pure threshold decision (≥20 GB ok · <20 warning · <5 critical; `nil` → `.ok`, a failed probe never nags) so it's unit-testable without a filesystem. Backs `LowDiskWarningBanner`. |
| [`LLMPro/Features/Shared/LowDiskWarningBanner.swift`](../LLMPro/Features/Shared/LowDiskWarningBanner.swift) | Reusable warning banner (the first `Features/Shared/` component). Queries `DiskSpace` in `.task` then re-polls every ~30s (cancels on disappear); renders an amber "Low disk space" card (<20 GB) or a red "Very low disk space" card (<5 GB) showing the free-GB figure, and `EmptyView()` (hidden) when space is fine or unknown. Informational, no action button. Placed atop `ModelsBrowserView` (downloads) and `TrainingConfigView` (training) — the two big disk consumers. |

---

## SwiftData models

| File | Responsibility |
|---|---|
| [`LLMPro/Models/TrainingJob.swift`](../LLMPro/Models/TrainingJob.swift) | One per training run. Stores: id, name, status enum, configYAML snapshot, base model id, dataset id, adapter dir, pid, start/end times, last iter, lastLoss/lastEvalLoss, metricsBlob (encoded `[TrainingStep]`), and **`trainModeRaw`** (`TrainMode {sft, dpo}`, additive — defaults `"sft"`, **no migration**; a `.dpo` job was trained via `mlx_lm_lora.train`). Helpers for `adapterURL`, `configURL`, `logURL`, `sidecarURL`, and a `trainMode` bridge. `writeSidecar()` drops a `job.json` for crash recovery. |
| [`LLMPro/Models/LocalModel.swift`](../LLMPro/Models/LocalModel.swift) | (Currently unused for runtime state — `ModelRegistry.DetectedModel` is the runtime equivalent; we may consolidate later.) |
| [`LLMPro/Models/DatasetRecord.swift`](../LLMPro/Models/DatasetRecord.swift) | One per prepared dataset. Stores: id, name, schemaRaw, train/valid/test row counts, relativePath (UUID string under datasets dir), createdAt, notes. **`DatasetSchema` gained a `preference` case** — the DPO preference loop stores its `{"prompt","chosen","rejected"[,"system"]}` pairs as a first-class `DatasetRecord` (not a new `@Model`), written by [`PreferenceService`](../LLMPro/Services/PreferenceService.swift); `DatasetService.classify()` votes `preference` (before `completions`). |
| [`LLMPro/Models/AppSettings.swift`](../LLMPro/Models/AppSettings.swift) | Singleton settings record (HF token Keychain ref, Ollama path, LM Studio path, default base model, telemetry off). |
| [`LLMPro/Models/SelfImproveRun.swift`](../LLMPro/Models/SelfImproveRun.swift) | One per recursive-self-improvement (Practice) run. Stores: base model, seed preset (HumanEval / MBPP), target rounds, candidates-per-prompt, rows-per-round, train-iters, status, baseline pass@1, and the round history as a JSON blob (`[SelfImproveRoundRecord]`). Same `writeSidecar()` pattern as `TrainingJob` for crash recovery; sidecar lives at `selfimprove/<uuid>/run.json`. |
| [`LLMPro/Models/EvalRun.swift`](../LLMPro/Models/EvalRun.swift) | One per scored Test-stage eval of a `(model + adapter)`. Mirrors `SelfImproveRun`'s blob-in-model + sidecar pattern. Stores: base model, `adapterRelativePath` (`""` = base model, else == `TrainingJob.adapterRelativePath` so scores compare across retrains), suite (`humaneval`/`mbpp-sanitized`/`custom`) + `customSuiteID`, `k`, problem count, `passAtK` / `passedCount` / `totalCount`, `elapsedMs`, status, source label + `sourceJobID`, and the per-task pass/fail list as a JSON blob (`[EvalTaskResult]`). Enums `EvalSuite` (with `displayName`/`oneLine`/`pullPreset`) + `EvalStatus`. Helpers `adapterURL`, `passPercent`, `decodedTasks()`/`setTasks()`, `writeSidecar()` → `evals/<run-uuid>/eval_run.json`. Owned by `EvalService`. **Registered in BOTH the `LLMProApp` schema list AND `PreviewSupport`** (with a `sampleEvalRun`). |
| [`LLMPro/Models/AgentProfile.swift`](../LLMPro/Models/AgentProfile.swift) | **UNUSED** by the Code tab now (the fixed Orchestrator team replaced the switchable single-agent library), but **kept in the SwiftData schema** (additive-only). One per saved Code-tab agent: id, name, emoji, detail, model repo ID, optional adapter job UUID, role instructions, auto-approve / native-tools toggles, temperature / max-tokens, and `enabledSkillIDs` (legacy per-agent skill ids — **superseded**: Agent Skills are now team-global via `SkillStore`, not per-agent). A computed `agentSettings` bridges to `CodingAgentService.AgentSettings` (no longer passes the removed `maxIterations`). |

---

## Services

The core of the app. Most are `@MainActor @Observable final class` singletons.

### Python plumbing

| File | Responsibility |
|---|---|
| [`LLMPro/Services/PythonRuntime.swift`](../LLMPro/Services/PythonRuntime.swift) | Bootstraps and tracks the venv: state machine `.uninitialized → .checkingUV → .creatingVenv → .installingMLXLM → .ready` (or `.failed`). Finds `uv` via bundle → app-support → PATH. Creates venv at `~/Library/Application Support/LLMPro/runtime/.venv/`. Installs `mlx-lm huggingface_hub datasets safetensors sentencepiece protobuf pillow` (**`pillow` is for the vendored DiffusionGemma decoder** — `optiq.vlm.gemma4` imports PIL; no torch). **Critically: `bootstrapIfNeeded()` always re-runs `installHelpers()` even when the venv is already ready**, so helper-script edits in the bundle propagate without a full rebootstrap. `installHelpers()` copies the flat `.py` helpers (incl. `diffusion_generate` **and** `diffusion_server` — the long-lived DiffusionGemma HTTP daemon the Code tab serves) **and recursively copies the `diffusion_vendor/` subtree** (`optiq/vlm/...`, layout preserved) into `runtime/helpers/` — a flattened copy would break `import optiq.vlm.diffusion_gemma`. |
| [`LLMPro/Core/ProcessRunner.swift`](../LLMPro/Core/ProcessRunner.swift) | (Already covered above.) |

### HuggingFace integration

| File | Responsibility |
|---|---|
| [`LLMPro/Services/HuggingFaceClient.swift`](../LLMPro/Services/HuggingFaceClient.swift) | Calls the HF Hub API directly via `URLSession`. **Models**: `search(query:, mlxOnly:)`, `detail(repoID:)`, `resolveTotalSize(repoID:)`. **Datasets**: `searchDatasets(query:)`, `datasetDetail(repoID:)`, `datasetFirstRows(repoID:, config:, split:)` (uses the public `datasets-server.huggingface.co/rows` API the HF web viewer uses). Decoded result types: `HFModel`, `HFModelDetail`, `HFFile`, `HFDataset`, `HFDatasetDetail`, `HFDatasetRows`. Includes a tagged-enum `AnyCodable` for JSON polymorphism (required for Sendable conformance). |
| [`LLMPro/Services/DownloadService.swift`](../LLMPro/Services/DownloadService.swift) | Wraps `hf_download.py`. Manages an `[ActiveDownload]` list with per-row byte progress; moves entries to `history` on completion. Also exports `KeychainHelper.{readHFToken, writeHFToken}` (Security framework, generic password, service="LLMPro", account="llmpro.hfToken"). |
| [`LLMPro/Services/ModelRegistry.swift`](../LLMPro/Services/ModelRegistry.swift) | Scans both HF cache layouts (`hf/models--*` AND `hf/hub/models--*`) plus the custom-model dir (`models/<name>/`). Inspects each repo's `config.json` to extract architecture and quantization. Computes accurate sizes by walking `blobs/` with `lstat` (avoids double-counting via symlinks). `delete(repoID:)` wipes all four cache locations (`hf/`, `hf/hub/`, `hf/.locks/`, `hf/hub/.locks/`). **`DetectedModel.isDiffusion: Bool`** — `true` when `config.json` has top-level `model_type == "diffusion_gemma"` (Google's DiffusionGemma; the wrapper type stays this even though the inner tower is `diffusion_gemma_text`) **or** an `architectures` entry starting with `DiffusionGemma`. This one flag drives the `InferenceService` diffusion routing (chat), the **`MLXServerService` diffusion routing** (the Code tab's agentic loop, via `diffusion_server.py`), the Teach/Practice picker exclusions (DiffusionGemma is not fine-tunable, so it's excluded only from those + DPO), and the Models-tab badge ("Diffusion · chat + Code"; the Code tab shows an "agentic tool-use is experimental" caption). |
| [`LLMPro/Services/ConversionService.swift`](../LLMPro/Services/ConversionService.swift) | Wraps `python -m mlx_lm convert --hf-path <repo> -q --q-bits {4,8}` for converting non-MLX models. |

### Datasets

| File | Responsibility |
|---|---|
| [`LLMPro/Services/DatasetService.swift`](../LLMPro/Services/DatasetService.swift) | Pure helpers: `ingest(source: URL, into: URL, name: String)` takes a JSONL/dir drop and produces a normalized `DatasetRecord`. `inspect(directory:)` returns row counts + auto-detected schema. `classify(lines:)` votes between `chat / completions / tools / text / unknown`. |
| [`LLMPro/Services/DatasetEditorService.swift`](../LLMPro/Services/DatasetEditorService.swift) | The chat-row editor backend. `ChatRow` and `ChatMessageRow` are the in-memory types the editor manipulates. `load(directory:, split:)` reads any source schema and **auto-promotes to chat** on the fly. `save(rows:, to:, split:)` writes atomically (temp file + `FileManager.replaceItemAt`). `createEmpty(at:)` makes a blank dataset; `duplicate(source:, destination:)` deep-copies. |
| [`LLMPro/Services/DatasetPrepService.swift`](../LLMPro/Services/DatasetPrepService.swift) | Wraps `prepare_coding_dataset.py` (catalog preset) and `download_hf_dataset.py` (arbitrary HF). State: `[ActivePrep]` + `[history]`. `prepare(preset:, maxRows:, onComplete:)` for catalog entries. `prepareArbitrary(request:, onComplete:)` for HF browse → download. |
| [`LLMPro/Services/CodingDatasetCatalog.swift`](../LLMPro/Services/CodingDatasetCatalog.swift) | Static list of 5 curated coding-instruction datasets with metadata (HF repo, approx rows, description, license, recommended-for blurb). The IDs match the PRESETS dict in `prepare_coding_dataset.py`. |

### Training + inference

| File | Responsibility |
|---|---|
| [`LLMPro/Services/AutoTuner.swift`](../LLMPro/Services/AutoTuner.swift) | Picks every hyperparameter from `(ModelSize, TrainingDuration)`. Buckets models by digit-B pattern in the repo ID (`tiny < small < medium < large < huge`). Maps duration × size to iters, batch, num_layers, max_seq, lr, grad_ckpt, rank, scale, target keys, plus an empirically-tuned wall-clock estimate (used to render the "~26 min" labels on duration cards). `renderYAML()` produces the YAML mlx-lm consumes. Two `tune` overloads: `tune(repoID:...)` (legacy, dense-only) and `tune(model:...)` (architecture-aware — picks MoE-appropriate target keys when `model.isMoE`). `moeLoraTargetKeys(architecture:, repoID:)` returns Mixtral- or Qwen-MoE-style key patterns depending on layout. **`tuneDPO(...)`** is the DPO variant (the "Teach by preference" loop): fewer iters, ~half the SFT learning rate, β=0.1, a ~2× memory estimate (DPO holds a second frozen reference model), and the `adamw` optimizer. |
| [`LLMPro/Services/TrainingNarrator.swift`](../LLMPro/Services/TrainingNarrator.swift) | Translates `JobRegistry.LiveJob` state into friendly UI strings. `Phase` enum (`.waiting / .gettingReady / .openingBook / .settingUp / .learning / .popQuiz / .finished / .failed`) with `emoji + headline + subtitle`. `stars(initial:, current:)` maps loss-improvement ratio to 1-5 stars. `eta(for:)` computes time-remaining from rolling `It/sec`. |
| [`LLMPro/Services/TrainingService.swift`](../LLMPro/Services/TrainingService.swift) | Spawns the trainer. `start(job:, context:)` is `@MainActor` (SwiftData lives there), writes `config.yaml` + `job.json`, registers the job in `JobRegistry`, then spawns 3 tail tasks: stdout → LogStreamParser → metrics, stderr → logTail, exit → status update. **Critical detail**: all 3 tail tasks re-fetch the `TrainingJob` by UUID via `FetchDescriptor` rather than capturing the `@Model` reference into `Task`, which Swift 6 strict concurrency rejects. **`start()` branches SFT vs DPO** on `TrainingJob.trainMode`: SFT → `python -m mlx_lm lora -c config.yaml`; **DPO → `python -m mlx_lm_lora.train`** (the separate `mlx-lm-lora` package) with the DPO-controlling hyperparameters passed as **CLI flags** (`--train-mode dpo`, `--beta`, `--dpo-cpo-loss-type`, `--gradient-accumulation-steps`) AND `-c config.yaml` for None-default/nested keys (incl. `fuse: false`) — because `mlx_lm_lora.train` only merges YAML into still-`None` args. It reads the on-disk row counts and **clamps `--batch-size` to `min(trainRows, validRows)`** (DPO's `iterate_dpo_batches` hangs otherwise). The exit handler was hardened so abnormal termination always lands the job in `.failed`. `TrainMode {sft, dpo}` + `dpoBeta`/`dpoLossType` live on `TrainingConfig`, with a `renderDPOYAML()`. Full DPO contract in [`CONTRACTS.md`](CONTRACTS.md#mlx_lm_loratrain--dpo-preference-training-separate-package). |
| [`LLMPro/Services/PreferenceService.swift`](../LLMPro/Services/PreferenceService.swift) | **NEW.** `@MainActor enum` backing the **DPO preference loop** ("Teach by preference"). Stores preferences as a first-class [`DatasetRecord`](../LLMPro/Models/DatasetRecord.swift) with the new `DatasetSchema.preference` case (**not** a new `@Model` → no SwiftData migration), as `{"prompt","chosen","rejected"[,"system"]}` JSONL in `datasets/<uuid>/train.jsonl` (+ `valid.jsonl`). `createPreferenceSet` / `findOrCreateActivePreferenceSet`; `appendPair(prompt:chosen:rejected:system:to:context:)` (atomic append + de-dup, bumps `trainRows`); `splitForTraining(dataset:)` carves ~10% of `train.jsonl` into `valid.jsonl` before a DPO launch. Fed by the Arena's `preferenceBar`, consumed by `TrainingService`'s DPO branch. |
| [`LLMPro/Services/InferenceService.swift`](../LLMPro/Services/InferenceService.swift) | Per-turn spawn of `python -m mlx_lm generate --prompt ...`. Returns an `AsyncThrowingStream<String, Error>` that yields tokens as they appear between the `==========` markers in mlx-lm's stdout. New process per turn — sidesteps stdin-pipe deadlocks. **`stream` now resolves a bare local-model name to its absolute path** before invoking `mlx_lm generate` (registry hit → `directory.path`), mirroring the training/eval/server resolvers — previously the Arena passed the bare name and mlx-lm treated any local custom model as an HF repo id, failing with "exited with code 1". HF repo ids (with `/`) pass through unchanged. **Diffusion branch:** `stream` checks `isDiffusionModel(...)` (registry `isDiffusion` flag, else a `config.json` `model_type == "diffusion_gemma"` read) and routes those models to a **direct spawn of `diffusion_generate.py`** (self-pinned memory, NOT `mlx_lm generate`), parsing its JSON-event protocol (`token`/`progress`/`done`/`error`). **Streaming contract:** the mlx_lm path yields each stdout line **with its newline re-added** (`yield(line + "\n")`); the diffusion path yields **raw `token` text segments** — both are now *ready-to-append*, so `ChatSession.send` appends `chunk` **raw** (was `chunk + "\n"`), fixing a per-token-newline bug that rendered diffusion output one token per line. See [`CONTRACTS.md`](CONTRACTS.md#inferenceservice--chatsession-streaming-contract-yield-ready-to-append). |
| [`LLMPro/Services/JobRegistry.swift`](../LLMPro/Services/JobRegistry.swift) | `@MainActor` runtime registry of active + recovered jobs. `LiveJob` is the in-memory view (status, pid, steps, logTail, baseModelRepoID, adapterURL). `register / attach / recordStep / recordLog / markCompleted / markFailed / stop / detach`. `recoverOrphans()` scans `adapters/*/job.json` on launch; if pid is alive → reattach, if pid dead + checkpoint exists → mark `.orphaned` with a Resume option. |

### Modification + export

| File | Responsibility |
|---|---|
| [`LLMPro/Services/ModelModifyService.swift`](../LLMPro/Services/ModelModifyService.swift) | Orchestrates the model-modify pipeline, each stage producing a NEW local model. 4 optional stages chained via temp dirs: **strip-vision → manage-experts → abliterate → quantize**. Expert stage takes an `ExpertOperation` (op + serialized args) and shells out to `manage_experts.py`. State: optional `ActiveJob` with stage (`.managingExperts / .stripVision / .abliterating / .quantizing / .finished / .failed`). |
| [`LLMPro/Services/ModelApplyService.swift`](../LLMPro/Services/ModelApplyService.swift) | `@MainActor @Observable`. Powers Teach's "Save the trained model when done" toggle (`TrainingJob.applyToModelInPlace`): on a clean training completion, auto-fuses the adapter into the base via `FuseService.fuse` and saves the result as a NEW `models/<name>-trained` model — the original is always kept (a copy, never an overwrite). Fuse → temp dir → validate (config.json + a `.safetensors`) → move into a unique models/ name → `ModelRegistry.scan()`. Nothing registers unless validation passes. `Phase` enum drives status. Called from `TrainingService`'s completion hook; outcome recorded on `TrainingJob.applyOutcome`. |
| [`LLMPro/Services/GGUFImportService.swift`](../LLMPro/Services/GGUFImportService.swift) | `@MainActor @Observable`. Powers the Models-tab "Import GGUF" sheet. `precheck(path:)` reads a GGUF's arch+quant (via `gguf_to_mlx.py precheck`) to report whether the lightweight converter can handle it (F16/Q4_0/Q4_1/Q8_0 yes; K-quants no). `convert(path:outputName:)` runs `gguf_to_mlx.py convert` → new `models/<name>/` MLX model, gated on the precheck. `downloadFromHuggingFace(repo:filename:)` pulls a single .gguf. **Optimize for MLX**: for a full-precision (F16/F32) GGUF, `convert(...optimize:optimizeBits:)` runs an `mlx_lm convert -q` pass (quantizeInPlace → temp dir → swap) for a ~4× smaller canonical-MLX model; already-quantized GGUFs are left as-is (re-quantizing degrades them). No PyTorch — uses mlx.core's native GGUF loader. **Chat-template fallback:** when the source GGUF carries no `tokenizer.ggml.chat_template` metadata, `gguf_to_mlx.py` now writes a **per-architecture default** chat template (ChatML for qwen2/qwen2moe/qwen3, Gemma turn format, Llama-3 headers, Phi-3, Mistral) so converted INSTRUCT models chat out of the box; the `done` event reports `chat_template_source` (`metadata` \| `fallback-<arch>` \| `none`). See [`CONTRACTS.md`](CONTRACTS.md#gguf_to_mlxpy--gguf--mlx-import-chat-template-fallback). |
| [`LLMPro/Services/FuseService.swift`](../LLMPro/Services/FuseService.swift) | Wraps `python -m mlx_lm fuse` for adapter merging + GGUF export. `fuse()` produces safetensors; `fuseToGGUF()` adds `--export-gguf` (only works for `llama / mistral / mixtral` architectures). `fuseAndConvertExternalGGUF()` falls back to llama.cpp's `convert_hf_to_gguf.py` for Qwen/Gemma/Phi. `installInOllama()` runs `ollama create <tag> -f Modelfile` with a chat-template-aware Modelfile. `OllamaChatTemplate` enum has built-in templates for Qwen / DeepSeek / Llama 3 / Phi / Mistral / raw. |
| [`LLMPro/Services/FusionService.swift`](../LLMPro/Services/FusionService.swift) | Wraps `merge_models.py` → `mergekit`. Supports four merge methods (SLERP / Linear / TIES / DARE-TIES) with per-method params (t for SLERP, density for TIES/DARE, weights for Linear). Refuses MLX-quantized inputs (mergekit loads via HF transformers which doesn't understand MLX's quantization block). On first use, lazily installs mergekit via `PythonRuntime.installMergekit` if the venv pre-dates the fusion feature. Output lands at `models/<outputName>/` and is auto-rescanned into `ModelRegistry`. |
| [`LLMPro/Services/ExpertExpansionService.swift`](../LLMPro/Services/ExpertExpansionService.swift) | Wraps `add_expert.py` — sparse upcycling that adds N new experts to an existing MoE model. Clones the last expert with small Gaussian noise + widens each layer's router. EXPERIMENTAL — outputs only become useful after follow-up fine-tuning. State: optional `ActiveJob` with stage `.running(stage:message:) / .finished(outputPath:oldCount:newCount:) / .failed`. |

### Self-improvement

| File | Responsibility |
|---|---|
| [`LLMPro/Services/SelfImproveService.swift`](../LLMPro/Services/SelfImproveService.swift) | `@MainActor @Observable` orchestrator for the Practice loop. `start(run:, context:)` drives the pipeline end-to-end: pull seed → baseline eval → for each round { `self_improve_round.py` (generate + sandbox-test + write that round's keepers) → build a **cumulative deduped keeper buffer** of rounds 1..N (`mergeAndSplitKeepers` / `buildCumulativeDataset` → `round_N/cumulative/`, dedup by user-prompt keeping the latest round's solution) → `python -m mlx_lm lora` (LoRA train on the cumulative buffer, continual from the prior adapter, hyperparams from AutoTuner) → `eval_pass_rate.py` (pass@1 on held-out set) } → mark completed. The cumulative buffer is the anti-overfit fix for the per-round tiny-keeper-set problem (early rounds keep only a handful of passers). Tracks `LiveStatus` (phase / headline / detail / pass-at-one trend) for the UI. Reuses `TrainingConfigView.resolveModelArg`'s pattern so bare folder names get expanded to absolute paths before mlx-lm sees them. Cancel via `cancel()` (sends SIGTERM to the active subprocess and sets phase to `.cancelled`). |
| [`LLMPro/Services/EvalService.swift`](../LLMPro/Services/EvalService.swift) | `@MainActor @Observable` singleton (`.shared`) — the scored Test-stage harness. Turns the loop's ③ Test node into a tracked **pass@k** score per `(model + adapter)` written to an [`EvalRun`](../LLMPro/Models/EvalRun.swift). Reuses the **same** eval engine as Practice — the one-shot [`eval_pass_rate.py`](../LLMPro/Resources/helpers/eval_pass_rate.py) + suite puller [`humaneval_pull.py`](../LLMPro/Resources/helpers/humaneval_pull.py) + the Practice RLIMIT_AS+SIGALRM sandbox — NOT the persistent `MLXServerService`. `ensureSuite(_:customID:)` lazily caches a suite's `eval.jsonl` (built-ins via `humaneval_pull.py`). `runEval(model:adapterPath:suite:customID:k:limit:sourceLabel:sourceJobID:context:) async -> EvalRun` inserts a `.running` EvalRun, resolves the model arg to an absolute path, spawns `eval_pass_rate.py`, decodes the `row`/`done` events, then **re-fetches the @Model by UUID via `FetchDescriptor`** (the standard pattern) before persisting score + per-task blob + elapsed + writing the sidecar. `latestEval(forBase:adapter:context:)` and `previousAdapterEval(forBase:excludingAdapter:context:)` drive the **score delta** vs the previous fine-tune of the same base. `cancel()` SIGTERMs the active subprocess. Publishes an `@Observable LiveStatus` (phase + graded N of M + passedSoFar, `isRunning`). |

### Coding agent / Orchestrator team

The Code tab runs a **fixed five-role agent team** (orchestrator · planner ·
researcher · coder · ui), all sharing one `mlx_lm server`. The user talks only to
the Orchestrator, which delegates to the others. The single-agent *profile* library
was replaced (see the UNUSED note under the Code feature section below), but **Agent
Skills** (`SkillStore` + `use_skill`, 3-stage progressive disclosure) are live,
raw-markdown CRUD-editable, and team-global **by default** (an agent can opt into a
subset via its `skills:` frontmatter; skills can link to other skills).

| File | Responsibility |
|---|---|
| [`LLMPro/Services/MLXServerService.swift`](../LLMPro/Services/MLXServerService.swift) | `@MainActor @Observable` singleton that runs a **long-lived inference daemon** (the team's shared inference backbone — every role's turns hit this one server). State enum `.stopped / .starting / .ready(port:) / .failed`. `start(model:adapterPath:)` resolves the model arg to an absolute path (registry hit → `directory.path`, mirroring `SelfImproveService.resolveModelArg`), binds a free localhost port (POSIX socket to port 0), spawns the server, polls `GET /health`, then fires a 1-token warm-up chat to force the model load and surface bad-adapter / OOM errors before flipping to `.ready(port:)`. **`start` branches on `ModelRegistry`'s `isDiffusion`:** a normal model spawns `python -m mlx_lm server`; a **diffusion model** (`model_type: diffusion_gemma`) spawns the vendored [`diffusion_server.py`](../LLMPro/Resources/helpers/diffusion_server.py) instead (mlx-lm can't serve a diffusion LM) — **the adapterPath is ignored** (diffusion has no LoRA). Both go through the **same** free-port / `waitForServerUp` (`/health`) / warm-up / state machine, so `OpenAIChatClient` + `CodingAgentService` work unchanged. `baseURL` → `http://127.0.0.1:<port>/v1`. Routes argv through `MemoryService.wrap` (so both are memory-wrapped by `mlx_run.py`) + sets `HF_HOME`/`PYTHONUNBUFFERED` (same as `InferenceService`); a `generation` counter invalidates stale exit-handlers. Unlike `InferenceService`'s per-turn cold-load, the model loads **once** and is reused for every agent turn. |
| [`LLMPro/Services/OpenAIChatClient.swift`](../LLMPro/Services/OpenAIChatClient.swift) | Minimal `URLSession` client for `POST {baseURL}/v1/chat/completions`. `complete(_:)` is the one-shot path (used for the server warm-up); `stream(_:)` parses SSE `chat.completion.chunk` frames into `ChatStreamEvent.textDelta` / `.completed(ChatWireMessage)` (accumulating content + `tool_calls` deltas) — the agent loop uses this for live output. Codable wire types: `ChatWireMessage` (role/content/toolCalls/toolCallID/name), `ChatWireToolCall`, `ChatWireFunctionCall`, the tool-definition types `ChatToolSpec`/`ChatFunctionSpec`/`ChatToolParameters`/`ChatToolProperty`, `ChatCompletionRequest`, `ChatCompletionResponse`, `ChatStreamChunk`. 600 s timeout because the first request to a fresh server triggers the model load. |
| [`LLMPro/Services/AgentTools.swift`](../LLMPro/Services/AgentTools.swift) | The agents' toolset. `AgentToolName` enum (read_file, list_dir, glob, grep, write_file, edit_file, run_command, **web_search, fetch_url, ask_user**, use_skill, todo_write — each with `isReadOnly`; the new three are read-only). The `AgentTools` namespace provides a per-tool `toolSpec(for:)` + `specs(for: [AgentToolName])` so **each role advertises only the tools it has** (was a single `specs(...)`), `parseFallbackCalls(from:)` (parses `<tool_call>{…}</tool_call>` blocks + bare/code-fenced JSON — for models whose chat template can't emit native tool_calls), and `stripToolCallBlocks(from:)`. `ToolExecutor` is workspace-sandboxed: `sandboxed()` rejects path escapes (lexically resolves `..`, requires the path stay at/under the project root); `run_command` runs `/bin/zsh -lc <cmd>` with the workspace as cwd and a 120 s watchdog; all output truncated to 16000 chars (`maxOutputChars`). `glob` matches `*`/`**`/`?` via `globToRegex`; `edit_file` supports `replace_all`; `write_file`/`edit_file` produce a UI-only `- / +` diff (`ToolResult.displayDetail` + `previewDiff(...)` for pre-approval display, never sent to the model). `execute` now handles `web_search`/`fetch_url` (→ `WebSearch`); `todo_write`, `ask_user`, and the `call_<role>` delegation calls are **intercepted by the orchestration engine, not the executor**. `ToolExecutor.useSkill(name)` returns the matching Agent Skill's full instructions body + its folder path (`SkillContext.dirPath`) so the agent can read bundled files. Result types `ParsedToolCall`, `ToolResult`. |
| [`LLMPro/Services/WebSearch.swift`](../LLMPro/Services/WebSearch.swift) | Web tools for the Researcher role — **no API key**. `search(query:limit:)` scrapes the DuckDuckGo HTML endpoint, parses `result__a` / `result__snippet`, decodes the `uddg=` redirect param to the real URL → `[Result(title, url, snippet)]`. `fetch(url:maxChars:)` downloads a page via `URLSession` and strips it to readable text (drops script/style/comments/tags, decodes HTML entities, truncates). Best-effort: degrades gracefully on failure. Verified against live DuckDuckGo (9 results parsed). |
| [`LLMPro/Services/AgentRoles.swift`](../LLMPro/Services/AgentRoles.swift) | The fixed team definition, now **markdown-backed**. `TeamRole` enum (orchestrator, planner, researcher, coder, ui) resolves `displayName` / `emoji` (🧭🗺️🔬💻🎨) / `tint` / `baseTools` / `delegates` / `maxIterations` / the system-prompt header from `AgentStore.overrides[rawValue]` (parsed from `agents/<role>.md`), each falling back to a compiled-in `defaultX` when the file or field is absent — so the markdown is authoritative and the Swift values are the fallback. Defaults: `delegates` (orchestrator → `[planner, researcher, coder, ui]`; planner → `[researcher]`; builders → none), `baseTools` (orchestrator: read_file/list_dir/glob/ask_user; planner: + grep + todo_write; researcher: web_search/fetch_url + read-only file tools + ask_user; coder & ui: full file/command tools + todo_write). `toolSpecs()` (base-tool specs + a `call_<role>` delegation spec per delegate via `delegationSpec(to:)`), `skillIDs` (exposes `AgentDefinition.skills` — the per-agent skill→agent link list; nil = all skills), a role-specific `systemPrompt(workspace:overview:nativeTools:)` (the markdown body is the role's "character"; the project folder, overview, and tool-calling footer are still appended in code), `callToolName` (`"call_<role>"`), and `role(forCallTool:)`. |
| [`LLMPro/Services/AgentStore.swift`](../LLMPro/Services/AgentStore.swift) | `@MainActor @Observable` singleton that owns the team agents' markdown. `installAndLoad()` (called at launch from `LLMProApp`'s `.task`, before `bootstrapIfNeeded`) seeds each bundled `Resources/agents/<role>.md` into `PathResolver.agentsDir` **only if missing** (so user edits survive launches — unlike the Python helpers, which overwrite every launch), then parses the YAML-ish frontmatter (`id`/`name`/`emoji`/`tint`/`tools`/`delegates`/`maxIterations`/**`skills`**) + the system-prompt body into an `AgentDefinition` per role and publishes the `nonisolated(unsafe) static var overrides: [String: AgentDefinition]` snapshot that `TeamRole` reads. `AgentDefinition.skills: [String]?` carries skill→agent links (nil = all skills, [] = none). `parse` runs input through `SkillStore.normalizeFences(_:)` first so smart-substituted (`—`/`–`) frontmatter fences still load. `save(id:markdown:)` / `resetToDefault(id:)` write the file and reload; `markdown(for:)` / `defaultMarkdown(for:)` back the editor. Separate from the dead `AgentProfile` (the removed agent library). |
| [`LLMPro/Services/CodingAgentService.swift`](../LLMPro/Services/CodingAgentService.swift) | `@MainActor @Observable` singleton — **the multi-agent orchestration engine** (the old single-agent loop is gone). The user talks to the Orchestrator, a `TeamRole` loop run on a persistent `Convo`. Display types: `AgentRole`, `AgentToolCallView`, `AgentBubble` (now carries `teamRole` + `depth` for role chips + indentation), `TodoItem`, `PendingApproval`, `UserQuestion`, `AgentSettings` (**autoApproveEdits now defaults ON** — builders run unattended; the single approval slot serializes, so auto-approve avoids parallel-approval conflicts; `maxIterations` was dropped, it's per-role on `TeamRole` now; **`useSkills`** (Bool, default true) gates the Agent Skills catalogue + the `use_skill` tool). `startSession(model:adapterPath:)` (simplified — **no AgentProfile**) boots the server and seeds the Orchestrator convo. **Agent Skills:** `availableSkills(for: role)` scopes the catalogue to a role's linked skills (the role's `skills:` frontmatter via `TeamRole.skillIDs`; **`nil`/key-absent = ALL skills (default), `[]` = none**; transitive skill→skill links are followed). It scopes BOTH the system-prompt discovery list AND `use_skill` availability. `systemMessage` appends each in-scope skill's `name: description` under a "## Skills available to you" heading (stage-1 discovery); when ≥1 in-scope skill exists and `settings.useSkills` is on, `runRole` adds the `use_skill` tool (stage-2 activation), whose executor returns the skill's full instructions body + folder path + (for a linked skill) the names+descriptions of its linked skills ("Related skills you can also load with use_skill: …"). `runRole(role, convo, depth)` runs one role's loop: stream the turn → parse native or `<tool_call>`/fenced-JSON tool calls → `executeRoleCalls` → feed results back → until the role gives a final answer (capped at `role.maxIterations`). `executeRoleCalls` dispatches each call: delegation calls (`call_*`) are collected and run by `runDelegations` (a recursive sub-agent run — when >1 in one turn they run **CONCURRENTLY** via unstructured Tasks, interleaving at their await points on the one shared model server; depth-capped at 5); `ask_user` pauses on `pendingQuestion` + an answer continuation (resolved by `answerUser`); `todo_write` updates the shared plan; file/web tools go to `ToolExecutor` (approval-gated). |
| [`LLMPro/Services/SkillStore.swift`](../LLMPro/Services/SkillStore.swift) | **Live (revived).** Backing store for **Agent Skills** — reusable `SKILL.md` instruction packages under `PathResolver.skillsDir` (one folder per skill; folder-name slug is the stable id). `@MainActor @Observable` singleton (`SkillStore.shared`). `installDefaultsAndScan()` runs at launch (from `LLMProApp`'s `.task`): scans `skillsDir` and, on the very first launch only (guarded by a `didSeedExampleSkills` `UserDefaults` flag so deletions don't reappear), seeds four instruction-only example skills (`conventional-commits`, `code-reviewer`, `swiftui-app-builder`, `project-build-verify`). Types `Skill` / `SkillContext` (`name` / `description` / **`links: [String]`** / `dirPath`); the frontmatter `skills:` (alias `links:`) field carries skill→skill links. **Raw-markdown CRUD** (parity with `AgentStore`): `markdown(for:)`, `save(id:markdown:)`, `create(name:description:instructions:links:)`, `duplicate(id:)`, exposed `uniqueFolderID(from:)`, plus `scan()`, `save(_:)` (folder id never changes on rename), `importSkill(from:)`, `skills.map(\.context)`. `delete(id:)` **scrubs** the deleted id from every other skill's links (no danglers). A `revision` counter bumps on every mutation so SwiftUI refreshes. Static `normalizeFences(_:)` rewrites any dash-only line (`-`, en-dash `–` U+2013, em-dash `—` U+2014) to a canonical `---`; `SkillStore.parse` (and `AgentStore.parse`) run input through it first so smart-substituted fences still load. Team-global by default; per-agent scoping lives in `CodingAgentService.availableSkills(for:)`. |

### System

| File | Responsibility |
|---|---|
| [`LLMPro/Services/SystemMetrics.swift`](../LLMPro/Services/SystemMetrics.swift) | `@MainActor @Observable` runtime memory tracker. Uses `host_statistics64(HOST_VM_INFO64)` for active+wire pages, `host_page_size` for page size, `ProcessInfo.physicalMemory` for total. Polls every 1 s. **`start()` is idempotent and the poller is started ONCE at app launch (`RootView .task`)** — do not start/stop it per-view (a prior per-view `.task`/`onDisappear` pairing raced and left the gauges reading 0). Charts use the `history` ring buffer. |
| [`LLMPro/Services/MemoryService.swift`](../LLMPro/Services/MemoryService.swift) | `@MainActor @Observable` hub for the Memory tab. Loads the Metal working-set ceiling once (`mem_probe.py`), computes per-model expert/non-expert breakdowns (`model_memory.py`, header-only), runs the expert profiler (`profile_experts.py`) and routes cold-expert pruning to `ExpertManagementService.remove`. Owns the persisted memory budget (`budgetEnabled`/`budgetFraction` → `budgetBytes`) and `wrap(_:)`, which prepends `mlx_run.py` + sets `LLMPRO_MEMORY_LIMIT_BYTES` for training/inference when the budget is on. |

---

## Features

Each feature folder corresponds to one sidebar section. They are pure SwiftUI Views
that talk to `Services/`. None of them owns business logic.

### Home (`Features/Dashboard/`)

[`DashboardView.swift`](../LLMPro/Features/Dashboard/DashboardView.swift) — hero
copy + a contextual "next step" card driven by counts of models / datasets / jobs
+ 4 stat cards + recent training runs list. Posts `.switchSidebar` notifications
to jump to specific tabs.

### Models (`Features/Models/`)

| File | Responsibility |
|---|---|
| [`ModelsBrowserView.swift`](../LLMPro/Features/Models/ModelsBrowserView.swift) | Three-section list: Downloading / HuggingFace results / Local models. Search bar with `mlx-community only` toggle. Per-local-row: trash + ✨ modify icon (greyed when the model is in active training). **A `model.isDiffusion` row shows a "Diffusion · chat + Code" badge** (a small inline `Label`, sparkles icon) flagging that the model works in Try-it-out and the **Code** tab (tool-use experimental) but can't be fine-tuned — it's excluded only from Teach/Practice/DPO, since mlx-lm can't LoRA-train a diffusion LM. A `LowDiskWarningBanner` sits atop the list. Total-disk header. Confirmation alerts for delete (with bytes-freed message). Sheet for modify. |
| [`ModelDetailView.swift`](../LLMPro/Features/Models/ModelDetailView.swift) | Right-pane detail when a HF result is selected. Pulls `detail` + `resolveTotalSize` from HuggingFaceClient. Action buttons: Download, Use for training (posts `.openTrainingWithModel`), Open in Chat. For non-mlx-community repos, offers a `mlx_lm.convert` step with quant picker. |
| [`ModelModifyView.swift`](../LLMPro/Features/Models/ModelModifyView.swift) | Sheet with toggles: "Remove vision capabilities" (auto-checked if VLM), "Make uncensored" (EXPERIMENTAL), "Shrink (quantize)". For MoE bases it also shows an **Edit experts** section (Add / Remove / Modify) so expert edits run in the same pipeline pass as strip + shrink. Auto-derives output name (suffixes per op). Live per-stage progress. The standalone `ExpertManagerView` still exists for expert-only quick edits via the Models context menu. |

### Lessons (`Features/Datasets/`)

| File | Responsibility |
|---|---|
| [`DatasetsView.swift`](../LLMPro/Features/Datasets/DatasetsView.swift) | Toolbar: New blank · Search HuggingFace · Import file. Sections: Coding-instruction datasets (curated catalog cards with size-stepper and Prepare button), Browse HuggingFace card, Drop zone, Your datasets (clickable rows + context menu: Edit, Rename, Duplicate, Show in Finder, Delete). |
| [`DatasetDetailView.swift`](../LLMPro/Features/Datasets/DatasetDetailView.swift) | Full CRUD editor. Editable name field at top (auto-saves to SwiftData). Split picker (Training / Validation / Test). Row list with index + summary + role chips. Inline top bar (Close + Save) and bottom bar (Delete dataset + Add row). Auto-saves to disk after every row mutation. |
| [`DatasetRowEditorView.swift`](../LLMPro/Features/Datasets/DatasetRowEditorView.swift) | Sheet for editing a single ChatRow. Per-message role picker (System / User / Assistant) + multi-line TextEditor with role-specific placeholder. Add/remove messages. Save / Cancel. |
| [`HuggingFaceDatasetSearchView.swift`](../LLMPro/Features/Datasets/HuggingFaceDatasetSearchView.swift) | Modal sheet for searching arbitrary HF datasets. Three-column layout: results list / preview pane / options form. Schema picker (auto + 6 source types). Column-mapping TextFields appear when non-auto. Sample-rows preview shows columns + truncated row content. |

### Teach (`Features/Training/`)

[`TrainingConfigView.swift`](../LLMPro/Features/Training/TrainingConfigView.swift)
— the simple 3-card flow:

1. Model card grid (LazyVGrid over `ModelRegistry.localModels`, **filtered to
   `!isDiffusion`** — DiffusionGemma can't be LoRA-fine-tuned by mlx-lm, so it never
   appears in "pick a model to teach")
2. Dataset card grid (LazyVGrid over `@Query<DatasetRecord>`)
3. Duration cards (Quick / Standard / Thorough)

Plus a job-name field, primary "Start Teaching" button, and the **"Advanced settings"**
disclosure containing the full mlx-lm YAML form (iters, batch, layers, lr, max_seq,
grad_ckpt, LoRA rank/scale/dropout/keys).

`launch()` builds the YAML via `AutoTuner.renderYAML()` (or the user's advanced
overrides), creates the `TrainingJob` SwiftData record, and calls
`TrainingService.shared.start(...)`. **Critically calls `resolveModelArg()`** to
turn local-folder-name model IDs into absolute paths. It also listens for
`.openTrainingWithModel` to pre-fill the model (the loop's retrain back-edge,
posted by Models / Arena). An optional **"Continue a previous fine-tune?" picker**
over completed jobs routes to `launchRefine(from:)`, which reuses the source job's
config (swapping only `adapter_path`) and continues from its weights via
`TrainingService.start(…, resumeAdapterFile:)` (→ mlx-lm `--resume-adapter-file`).

**DPO mode (the "Teach by preference" loop).** TrainingConfigView also listens for
`.openTrainingWithPreferences` (a `PreferenceHandoff`) and **auto-detects when the
selected lesson is a `.preference` dataset** → shows a "teach by preference (DPO)"
banner and switches into DPO mode. In DPO mode `launch()` branches to
`PreferenceService.splitForTraining` (carve `valid.jsonl`) + `AutoTuner.tuneDPO` and
sets `job.trainMode = .dpo`, so `TrainingService` runs `mlx_lm_lora.train` instead of
`mlx_lm lora`. The produced adapter lands under `adapters/<uuid>/` like any job.

### Progress (`Features/Monitor/`)

[`TrainingMonitorView.swift`](../LLMPro/Features/Monitor/TrainingMonitorView.swift)
— shows the most recent job from `JobRegistry`. Four cards:

1. **Title card** with `TrainingNarrator.Phase` emoji + headline + subtitle
2. **Lessons learned** progress bar with N of M + percent + ETA
3. **How well is it learning?** 5-star rating + verdict from `TrainingNarrator.stars`
4. **Memory in use** gauge

Below: optional "Stop early" button + **"Technical details" disclosure** with
stat strip + 2×2 Swift Charts grid + raw log tail. When `job.status == .completed`
it shows the loop's **completion CTA card**: "Try it out" (posts `.openChatWithModel`
with a `ModelHandoff` built from the job's model + `adapterURL.path`), **"Grade it"**
(posts the same `.openChatWithModel` handoff but with `autoScore: true`, so it lands
in the Test node and **scores immediately** via `EvalService`), "Use in Code"
(`.openCodeWithModel`), and "Save & Use" (`.switchSidebar` → `.export`). These are
the user-driven hand-offs to the next loop stage — completion never auto-navigates.

### Try it out (`Features/Chat/`)

| File | Responsibility |
|---|---|
| [`ChatModels.swift`](../LLMPro/Features/Chat/ChatModels.swift) | `ChatMessage`, `ChatSession` (the per-pane VM). `send(prompt)` adds user+assistant messages, streams tokens via `InferenceService`, mutates the assistant message in place — appending each `chunk` **raw** (`text.append(chunk)`, was `chunk + "\n"`) per the yield-ready-to-append streaming contract, so the diffusion path (raw token segments) no longer renders one token per line while the mlx_lm path (line + `\n`) is unchanged. |
| [`ChatView.swift`](../LLMPro/Features/Chat/ChatView.swift) | One chat pane with message bubbles + clear button + auto-scroll. |
| [`ArenaView.swift`](../LLMPro/Features/Chat/ArenaView.swift) | Side-by-side two-pane: Base (no adapter) vs Coding fine-tune (with adapter). Shared input bar that broadcasts to both. Toggle to disable arena mode for single-pane chat. **Loop stage ③ (test) — now a *scored* node.** The old unscored "Mini-eval" button is replaced by a **"Score it"** action (suite picker HumanEval/MBPP; depth picker Quick=20 / Standard=40 / Thorough=all; an Advanced `DisclosureGroup` with a k stepper 1–8) that calls [`EvalService.shared.runEval(...)`](../LLMPro/Services/EvalService.swift). Results render in a friendly-first **`evalReportCard`** (big pass%, 1–5 star rating, suite + problem count, a **delta vs the previous fine-tune of the same base**, and a technical "Details" `DisclosureGroup` with the per-task pass/fail table + raw counts + elapsed + k). Its `.openChatWithModel` receiver accepts a `ModelHandoff` and pre-fills **both** model and adapter (and enables compare); a bare `String` still pre-fills the model only; **`ModelHandoff.autoScore == true` auto-runs "Score it" on arrival** (Progress's "Grade it"). Once an adapter is loaded it shows a **decision bar** — "Train again" (`.openTrainingWithModel` → the retrain back-edge), "Use in Code" (`.openCodeWithModel`), "Save & Use" (`.switchSidebar` → `.export`) — with the **score delta wired in** ("did pass@k go up?"). **DPO preference capture (the preference back-edge).** ArenaView also has a **`preferenceBar`** — a "Which answer is better?" 👍 capture row (SEPARATE from the `evalReportCard` above), with a running count + de-dup, that calls [`PreferenceService.appendPair(...)`](../LLMPro/Services/PreferenceService.swift) to accumulate `{prompt,chosen,rejected[,system]}` pairs into a `.preference` `DatasetRecord`. At **≥4 preferences** a **"Teach by preference →"** CTA enables, posting a `PreferenceHandoff` via `.openTrainingWithPreferences` (→ Teach in DPO mode). |

### Code (`Features/Code/`)

The Code tab now runs the **Orchestrator team** (`TeamRole`, five fixed roles): the
user talks only to the Orchestrator, which delegates to Planner / Researcher /
Coder / UI. There is **no agent picker and no manager menu** — instead a single
shared-**Model** picker drives all roles. It is still a **3-pane mini-IDE** — file
explorer | editable syntax-highlighted editor | agent chat — toggleable from the
header.

| File | Responsibility |
|---|---|
| [`CodeView.swift`](../LLMPro/Features/Code/CodeView.swift) | The Orchestrator-team tab, structured as a **3-pane IDE**. `workspaceArea` is an `HSplitView { FileExplorerView \| (CodeEditorView(selectedFile) OR an editorPlaceholder) \| chatColumn }`, shown when `showWorkspacePanes` (`@AppStorage("codeShowWorkspacePanes")`, default true) AND a workspace folder is set; otherwise just the full-width `chatColumn`. The header has a **sidebar-toggle button** ("sidebar.left"), a folder picker (NSOpenPanel, directories), a **standalone shared-`Model` picker** (`@AppStorage("codeOrchestratorModel")` — the one model that serves every role), a **Start/Restart + Stop** session button with a server-status dot, and a **"team: 🧭🗺️🔬💻🎨" indicator**. The old agent picker + manager menu (New/Edit agent) are **removed**. `@State selectedFile: URL?` is the open editor file; `@State explorerRefresh` is bumped on every `agent.transcript.count` change so the file tree re-scans as the agents write files. **Loop stage ④ (use).** An **adapter Picker** lists completed `TrainingJob`s whose `adapters.safetensors` exists and is persisted via `@AppStorage("codeAdapterJobID")`; `startSession()` threads the selected adapter path into `CodingAgentService.startSession(model:adapterPath:)` → `MLXServerService --adapter-path` (previously hardcoded `nil`, so the fine-tuned coder couldn't run here). It also listens for `.openCodeWithModel` (`applyHandoff` accepts a `ModelHandoff` or a bare `String`) to pre-fill model + adapter from the loop. **Diffusion models work here too** (served via `diffusion_server.py`, see `MLXServerService`): when the picked model `isDiffusion`, CodeView shows a friendly caption — "Diffusion model — chat works; agentic tool-use is experimental." — and leaves native tool-calling ON (default) so the server's translated `tool_calls` are used. **"Options"** (a popover off a gear button) holds the auto-approve toggles, native-tools toggle, max-tokens stepper, temperature slider, an **"Edit team agents…"** button (opens [`AgentsManagerView`](../LLMPro/Features/Code/AgentsManagerView.swift)), a **"Skills: load instruction packs on demand"** toggle (`AgentSettings.useSkills`) + a **"Manage skills (N)…"** button (N = installed count; opens [`SkillsManagerView`](../LLMPro/Features/Code/SkillsManagerView.swift)), Clear conversation, and the server log. `chatColumn` holds the `PlanView` (live `todo_write` checklist) + a **role-labeled, depth-indented** transcript + a `questionBar` (renders the Orchestrator's `ask_user` question; one **button per offered option** that calls `agent.answerUser(option)` to steer the run, plus an "Or type your own answer…" free-text fallback) + approval bar + input bar (⌘-Return). The transcript renders via a private `BubbleView` (assistant bubbles show the producing role's emoji + name in the role's `tint`, indented by `depth`) and a collapsible `ToolCardView`; an inline Allow/Deny bar appears when `agent.pendingApproval != nil`. `DiffText` shows **syntax-highlighted** diffs; `read_file` output is highlighted too. Assistant text streams in live with a "Working…" indicator. |
| [`FileExplorerView.swift`](../LLMPro/Features/Code/FileExplorerView.swift) | The Code tab's **left pane**: a project file tree. `FileNode` (id / url / name / isDirectory / children); `FileNode.tree(at:)` builds a bounded tree (depth < 9) skipping VCS / build / dependency dirs (`.git`, `node_modules`, `bin`, `obj`, `.build`, `DerivedData`, `.venv`, `Pods`, `dist`, `build`, `target`, …) and hidden files. `FileExplorerView(root:selection:refreshToken:)` renders a `List` + `OutlineGroup` (native expand/collapse); file rows are Buttons that set `selection: Binding<URL?>`; a `refreshToken: Int` re-scans when bumped (plus a manual refresh button). File-type SF Symbol icons. |
| [`CodeEditorView.swift`](../LLMPro/Features/Code/CodeEditorView.swift) | The Code tab's **center pane**: `CodeEditorView(url:)` loads the selected file into a syntax-highlighted, **editable** `NSTextView` with Save (⌘S) / Revert, a dirty-dot, a language label, and a binary / non-UTF-8 error state. `HighlightedTextView` is an `NSViewRepresentable` wrapping `NSTextView` (via `scrollableTextView()`); it applies `SyntaxHighlighter.nsAttributed` on load and re-highlights on edit (debounced via a `@MainActor` Task, preserving the selection). The Coordinator is `@MainActor`. |
| [`ChatInputView.swift`](../LLMPro/Features/Code/ChatInputView.swift) | The chat input box: an `NSViewRepresentable` over `NSTextView` where **plain Return sends** (`onSubmit`) and **Shift+Return inserts a newline** — intercepts `insertNewline:` in `doCommandBy`, checking `NSApp.currentEvent` for the shift flag. Replaces the old `TextEditor` so the user doesn't have to click Send. |
| [`Attachment.swift`](../LLMPro/Features/Code/Attachment.swift) | A file/image attached to a message. `Attachment(url:)` classifies it (text / image / other by extension + UTF-8 sniff). `Attachment.combinedText(for:)` turns attachments into text the local text-model can use: text/doc files inlined as fenced blocks (≤64 KB), **images OCR'd via macOS Vision** (`VNRecognizeTextRequest`, off-main) with the recognized text inlined, other binaries noted by name. Consumed by `CodingAgentService.send(_:attachments:)`; chips render in the input bar and the user bubble. (The `mlx_lm` server is text-only, so OCR is the bridge — no true vision.) |
| [`MarkdownEditor.swift`](../LLMPro/Features/Code/MarkdownEditor.swift) | An `NSViewRepresentable` wrapping `NSTextView` for **raw-markdown editing** — used by BOTH `SkillsManagerView` and `AgentsManagerView` (replaced their SwiftUI `TextEditor`). Monospaced, `isRichText = false`, undo enabled, with automatic dash/quote/text substitution, smart-insert-delete, spelling correction, and data/link detection all **DISABLED**. Why: SwiftUI `TextEditor` inherited macOS smart-substitution, so typing `---` frontmatter fences turned into `—` (em-dash, U+2014), silently breaking YAML parsing; this editor saves exactly what's typed. |
| [`SkillsManagerView.swift`](../LLMPro/Features/Code/SkillsManagerView.swift) | **Live (revived).** The **Agent Skills editor** sheet — a raw-`SKILL.md` CRUD editor mirroring `AgentsManagerView`: a skill list (left) + a monospace `MarkdownEditor` over the actual `SKILL.md` text (right) + toolbar **＋ New / − Delete / Duplicate**, plus Reveal-in-Finder and Save. ＋ creates a skill **immediately** with a placeholder name and selects it (rename by editing the `name:` line; folder id stays stable). Persists through `SkillStore`. Opened from the Code tab's Options popover via "Manage skills (N)…" (N = installed count). The old `.alert`-with-TextField New flow and `SkillEditorView` form are gone. |
| [`AgentsManagerView.swift`](../LLMPro/Features/Code/AgentsManagerView.swift) | The **team-agent editor** sheet (opened from the Code tab → Options popover → "Edit team agents…"). Lists the 5 markdown agents from `AgentStore`; each one's raw markdown is editable in a `MarkdownEditor` with **Save** (writes the `<role>.md` file + reloads `AgentStore` so the next run uses it), **Reset to default** (re-copies the bundled version), and **Show in Finder**. Shares the create-immediately + raw-markdown pattern with `SkillsManagerView`. This is the ACTIVE editor for the Orchestrator team — distinct from the now-deleted `AgentEditorView`. |

All logic lives in `CodingAgentService` (the orchestration engine) / `MLXServerService`
(the shared model server) / `AgentRoles` (the team definition, now markdown-backed
via `AgentStore`). The team agents are edited through the **active**
`AgentsManagerView`. **Agent Skills are LIVE again**: `SkillStore` + `SkillsManagerView`
+ the `use_skill` tool were revived from the old dead library and wired into the
dynamic `TeamRole` team. Skills are now edited as **raw `SKILL.md` markdown with
full CRUD** (parity with the team agents) and support **linking in both
directions**: skill→skill (`skills:`/`links:` frontmatter) and skill→agent (an
agent's `skills:` frontmatter, via `CodingAgentService.availableSkills(for:)`).
They are **team-global by default** (an agent with no `skills:` key sees every
installed skill); an agent can opt into a subset. `AgentProfile`
remains **unused** — the single-agent library / templates were replaced by the fixed
team (AgentProfile remains in the SwiftData schema; the dead `AgentTemplate.swift`
was **deleted**). `AgentEditorView` was
**deleted**. Note: the markdown-agent system
(`AgentStore` + `AgentsManagerView` + `Resources/agents/*.md`) is **separate** from
the dead `AgentProfile`; the markdown agents are the editable form of the live
5-role team.

### Practice (`Features/SelfImprove/`)

[`SelfImproveView.swift`](../LLMPro/Features/SelfImprove/SelfImproveView.swift)
— the recursive-self-improvement front-end. Three sections:

1. **Setup card** (only when no run is active): model picker (over
   `ModelRegistry.localModels` **filtered to `!isDiffusion`** — a diffusion LM can't be
   fine-tuned, so it's excluded from Practice just like Teach), seed picker (HumanEval / MBPP), three sliders (rounds 1–6, candidates-per-prompt 2–8, problems-per-round 10–60). "Advanced" disclosure with study-iterations-per-round. "Start Practice" button.
2. **Active run card** (during a run): emoji + headline + detail (driven by `SelfImproveService.LiveStatus`), progress bar (kept lessons of attempted problems), pass-at-1 trend chart (baseline → R1 → R2 → …), "Stop" button. "Technical details" disclosure with per-round table + log tail.
3. **History list**: each past run with start→last pass-at-1 delta, a **"Use this fine-tune" menu** (Try it out / Use in Code — both post a `ModelHandoff` of the run's model + final adapter — / Reveal in Finder / Copy adapter path), and trash to delete. This is what un-silos Practice: its adapters re-enter the outer loop exactly like a Teach job.

The view reads the in-flight run from `SelfImproveService.shared.status.runID` and pulls all other runs from `@Query<SelfImproveRun>`.

### Fusion (`Features/Fusion/`)

[`FusionView.swift`](../LLMPro/Features/Fusion/FusionView.swift) — the model-merge
front-end for `FusionService` (mergekit). Pick a method (SLERP / Linear / TIES /
DARE-TIES), choose 2+ base models, set per-method params, name the output. Live
per-stage progress while merging.

### Memory (`Features/Memory/`)

[`MemoryView.swift`](../LLMPro/Features/Memory/MemoryView.swift) — the expert &
memory-management tab, backed by `MemoryService`. Four sections:

1. **Live memory** — a bar of unified-RAM in use (from `SystemMetrics`) with the
   Metal working-set ceiling drawn as an orange marker (the real GPU-OOM
   threshold) and total RAM. Turns red as usage nears the ceiling.
2. **Where a model's memory goes** — model picker → expert vs non-expert stacked
   bar + resident / active-per-token / per-expert stats (header-only read, instant).
   Dense models show a "no experts" variant.
3. **Expert usage profiler** (EXPERIMENTAL) — MoE picker → Profile button → a heat
   grid of per-expert activation (green hot → red cold) + a one-click **Prune cold
   experts** that routes to `ExpertManagementService.remove` and shows its progress.
4. **Memory budget** — toggle + % slider that caps MLX memory during training /
   inference via `mlx_run.py`.

Every non-obvious control has a `HelpHint` with a learn-more link, per the
friendly-first convention.

### Save & Use (`Features/Export/`)

[`ExportWizardView.swift`](../LLMPro/Features/Export/ExportWizardView.swift)
— source picker on the left, options panel on the right. The list is built from an
`ExportSource` value (`Identifiable, Hashable`) that wraps **either** a completed
[`TrainingJob`](../LLMPro/Models/TrainingJob.swift) **or** a completed
[`SelfImproveRun`](../LLMPro/Models/SelfImproveRun.swift), so **Teach fine-tunes
and Practice adapters are both exportable** through the same panel. This is the
loop's off-ramp (the terminal sink — no `.exportCompleted` notification, by design).
Three target choices: adapter zip / fused safetensors / GGUF for Ollama. For GGUF:
chat-template picker (Qwen / DeepSeek / Llama 3 / Phi / Mistral / raw), Ollama tag
field, "Install in Ollama" runs the actual `ollama create` command. Falls back to
llama.cpp's converter for non-Llama/Mistral architectures.

### Settings (`Features/Settings/`)

| File | Responsibility |
|---|---|
| [`FirstRunView.swift`](../LLMPro/Features/Settings/FirstRunView.swift) | 5-step `TabView`: system check / Python runtime bootstrap / HF token (Keychain) / starter coding models picker / done. Shown until `@AppStorage("firstRunComplete")` is set. |
| [`SettingsView.swift`](../LLMPro/Features/Settings/SettingsView.swift) | `TabView` with Runtime / Paths / HuggingFace sections. Shown in the standard macOS Settings scene. |

---

## Resources

### Helpers (`Resources/helpers/`)

All are JSON-event-emitting Python scripts. Detailed protocol in [`CONTRACTS.md`](CONTRACTS.md#helper-script-protocol).

| File | Responsibility |
|---|---|
| [`hf_download.py`](../LLMPro/Resources/helpers/hf_download.py) | Downloads any HF repo. Polls cache `blobs/` size every 250 ms to emit accurate progress (works for both classic HTTP and xet transports — see [`CONVENTIONS.md`](CONVENTIONS.md#why-the-disk-size-poller-not-tqdm)). |
| [`prepare_coding_dataset.py`](../LLMPro/Resources/helpers/prepare_coding_dataset.py) | Curated dataset prep. Has a `PRESETS` dict (5 entries today). Downloads via `datasets.load_dataset`, normalises with per-preset row-splitter functions, writes 90/5/5 chat-schema JSONL. |
| [`download_hf_dataset.py`](../LLMPro/Resources/helpers/download_hf_dataset.py) | Arbitrary HF dataset prep. Auto-detects source schema (`messages / sharegpt / instruction_output / prompt_completion / question_answer / text`). Accepts a JSON options blob for manual column mapping. |
| [`strip_vision.py`](../LLMPro/Resources/helpers/strip_vision.py) | Drops vision weights from a VLM. Reads shards with `mx.load` (handles bf16, which numpy doesn't), filters tensors by name prefix, writes with `mx.save_safetensors`. Strips vision keys from config.json. Copies tokenizer + chat_template. |
| [`abliterate.py`](../LLMPro/Resources/helpers/abliterate.py) | Refusal-direction projection (Labonne/FailSpy abliteration). Loads model via `mlx_lm.utils.load`, runs 20 contrastive harmful/harmless prompts through it, computes mean residual at ~60%-depth layer, projects that direction out of every attention `o_proj` and MLP `down_proj` at or after the probe layer. Saves with `mlx_lm.utils.save`. |
| [`humaneval_pull.py`](../LLMPro/Resources/helpers/humaneval_pull.py) | Downloads a coding-eval dataset (HumanEval or MBPP sanitized) and emits two files in the run dir: `seed.jsonl` (rows the model practices on each round) and `eval.jsonl` (held-out rows used to measure pass@1). Each row carries `prompt / tests / entry_point / canonical_solution / messages` — the messages field gives a chat-schema view of the canonical solve so round 0 can train if desired. Deterministic shuffle (`random.Random(0)`). |
| [`self_improve_round.py`](../LLMPro/Resources/helpers/self_improve_round.py) | One Practice round in one Python process — model is loaded **once** (lazy `mlx_lm.utils.load`, plus optional adapter). For each prompt: generate K candidates via `mlx_lm.generate.generate` (chat-templated, temperature 0.7), extract a fenced ` ```python` block from each response, run the candidate together with the row's `tests` in a **subprocess sandbox** (15 s wall-clock + 1 GB `RLIMIT_AS`), keep the first passing candidate. Writes `dataset/{train,valid,test}.jsonl` in chat schema (90/5/5 with floors so valid+test are non-empty) and `results.jsonl` (one line per prompt). |
| [`eval_pass_rate.py`](../LLMPro/Resources/helpers/eval_pass_rate.py) | Measures **pass@k** of a model + optional adapter against a held-out `eval.jsonl`. Reuses `self_improve_round.py`'s primitives (`extract_code`, `run_one_test`, `load_model`, `generate_one`) via `sys.path` import so the two helpers stay in lockstep. Emits `{"event":"row", …}` per problem and `{"event":"done", …}` at the end. **`--k` (default 1) + `--temperature` (default 0.2, k>1 only)**: at `k==1` it's **byte-for-byte unchanged** — greedy (`temperature=0.0`), and `done` still carries `pass_at_1` (so the existing `SelfImproveService` caller is unaffected); at `k>1` each row passes if ANY of its k candidates passes, `row` gains `passes`+`k`, and `done` carries `pass_at_k`+`k` (no `pass_at_1`). Driven by both `SelfImproveService` (k=1) and `EvalService` (the Test node's "Score it"). See [`CONTRACTS.md`](CONTRACTS.md#eval_pass_ratepy----k----temperature-passk). |
| [`merge_models.py`](../LLMPro/Resources/helpers/merge_models.py) | Wraps `mergekit` for the Fusion tab. Translates an internal JSON config (method + models + per-method params) into mergekit YAML, then shells out to `python -m mergekit.scripts.run_yaml`. Tails mergekit's stdout into stage-classified progress events (`loading / merging / tokenizer / saving`). Refuses MLX-quantized inputs (those have a `"quantization"` block in config.json that mergekit's HF-transformers loader can't parse). Supports SLERP / Linear / TIES / DARE-TIES. |
| [`add_expert.py`](../LLMPro/Resources/helpers/add_expert.py) | Sparse upcycling — adds N new experts to an existing MoE model. Auto-detects Mixtral- vs Qwen-MoE-style tensor naming, then per layer: clones the last expert's component weights N times with Gaussian noise (default σ=0.01) and appends N new rows to each router/gate weight (init = mean of existing rows + noise). Updates `num_local_experts` / `num_experts` / `ffn_config.moe_num_experts` in config.json. Outputs a single-shard `model.safetensors` to keep things simple. EXPERIMENTAL — clones need follow-up fine-tuning to specialize. |
| [`manage_experts.py`](../LLMPro/Resources/helpers/manage_experts.py) | Full expert CRUD (add / remove / modify) for MoE models. Auto-detects per-expert (Mixtral / Qwen-MoE) and batched (Gemma-4 `switch_glu`) layouts. Uses `mlx.core` for all I/O + math (bf16-safe; the numpy backend can't read bf16), `mx.eval` per layer to bound memory. Writes a single `model.safetensors` with `metadata={"format":"mlx"}`. Driven by `ExpertManagementService` and by the unified `ModelModifyService` expert stage. |
| [`mem_probe.py`](../LLMPro/Resources/helpers/mem_probe.py) | One-shot JSON snapshot of MLX/Metal device facts: `max_recommended_working_set` (the GPU OOM ceiling), `device_memory`, `device_name`. Probes both `mx.*` and `mx.metal.*` (the accessors moved between versions). active/peak/cache are per-process so always 0 from this standalone probe — the live "used" number comes from `SystemMetrics` instead. |
| [`model_memory.py`](../LLMPro/Resources/helpers/model_memory.py) | Per-model memory breakdown read from safetensors **headers only** (no weight load): total vs expert vs non-expert bytes, num_experts, top_k, per-expert size, and active-per-token estimate (nonexpert + per_expert×top_k). Classifies expert tensors by name (`experts.switch_glu` / `experts.<N>.` / `block_sparse_moe.experts`). |
| [`profile_experts.py`](../LLMPro/Resources/helpers/profile_experts.py) | Loads a MoE, runs representative prompts, records router top-k selections per layer → per-expert activation histogram + cold-expert list. Architecture-agnostic router detection: any module with a 2-D weight whose first dim == num_experts, tapped by patching `nn.Linear`/`nn.QuantizedLinear.__call__`. EXPERIMENTAL. Feeds the Memory tab's profiler + prune. |
| [`mlx_run.py`](../LLMPro/Resources/helpers/mlx_run.py) | Thin launcher that applies an MLX memory budget then runs the real command via `runpy`. Reads `LLMPRO_MEMORY_LIMIT_BYTES` → `mx.set_memory_limit`. LLMPro prepends it to mlx_lm invocations (training / inference) only when the Memory-tab budget is on; transparent passthrough otherwise. |
| [`diffusion_generate.py`](../LLMPro/Resources/helpers/diffusion_generate.py) | **DiffusionGemma inference (non-mlx-lm), one-shot.** Runs Google's DiffusionGemma — a masked/block-diffusion LM with no autoregressive mlx-lm class — by adding the vendored `diffusion_vendor/` to `sys.path` and importing `optiq.vlm.diffusion_gemma`. Streams via the standard JSON-event protocol (`start`/`progress`/`token`/`done`/`error`). **Applies the Gemma chat template** + pre-tokenizes with `add_special_tokens=False` (the model is `-it`; the vendored `stream_generate` doesn't template a raw string → an un-templated prompt produced garbage). **Self-pins MLX memory** (bypasses `mlx_run.py`, like `inspect_attention.py`). CLI `--model --prompt [--max-tokens] [--temperature] [--sampler …]`. Driven by `InferenceService` for diffusion-model **chat** (Try-it-out). Full contract in [`CONTRACTS.md`](CONTRACTS.md#diffusion_generatepy--diffusiongemma-inference-non-mlx-lm). |
| [`diffusion_server.py`](../LLMPro/Resources/helpers/diffusion_server.py) | **DiffusionGemma daemon (non-mlx-lm), Code tab.** The long-lived counterpart to `diffusion_generate.py`: an **OpenAI-compatible HTTP server** (Python **stdlib `http.server.ThreadingHTTPServer`, no Flask**) around the same vendored decoder, so the Orchestrator team can drive a diffusion model through the *same* `OpenAIChatClient` + `CodingAgentService` loop as an `mlx_lm server` model (`mlx_lm server` can't serve a diffusion LM). The model loads **once on a single dedicated MLX worker thread** (the vendored decode binds a thread-local `mx` stream at import → load + all generation must run on one thread; HTTP request threads submit jobs via a queue). Endpoints: `GET /health`, `GET /v1/models`, `POST /v1/chat/completions` (non-stream + SSE, the exact shape `OpenAIChatClient` decodes). Prints `LLMPRO_DIFFUSION_SERVER_READY port=<port>` when ready. **Translates** DiffusionGemma's native tool grammar `<|tool_call>call:NAME{…}<tool_call|>` into OpenAI `tool_calls` (tolerant, fail-open to plain `content`); tool RESULTS need no translation. Launched (via `mlx_run.py`) by `MLXServerService` when `isDiffusion`; **no `--adapter-path`** (diffusion has no LoRA). Full contract in [`CONTRACTS.md`](CONTRACTS.md#diffusion_serverpy--long-lived-openai-compatible-diffusion-server-code-tab). |

#### Vendored DiffusionGemma decoder (`Resources/helpers/diffusion_vendor/`)

[`diffusion_vendor/`](../LLMPro/Resources/helpers/diffusion_vendor/) is a **vendored
copy (NOT a pip dependency)** of the `optiq/vlm` DiffusionGemma inference subset from
the MIT-licensed [`mlx-optiq`](https://pypi.org/project/mlx-optiq/) v0.2.3 — ~34 `.py`
files (the `optiq.vlm.diffusion_gemma` `load`/`stream_generate` closure, the Gemma-4
backbone, and the `_mlxvlm` masked-diffusion decode loop) plus
[`VENDORED.md`](../LLMPro/Resources/helpers/diffusion_vendor/VENDORED.md) (provenance,
the full MIT license text, and the deliberately-excluded `optiq/{lab,runtime,serve,cli,…}`
+ `sandbox.py` + `mlx_lm_patches/` subtrees). It's copied — not installed — so it's
reviewable, pinned, and free of the upstream package's network/subprocess/agent
machinery. It depends only on libraries already in the venv (`mlx`, `mlx-lm`,
`transformers`, `numpy`, `Pillow`, `huggingface_hub` — **no torch**). The `optiq/`
package layout is preserved so its relative imports resolve once the dir is on
`sys.path`; `PythonRuntime.installHelpers()` recursively copies the whole subtree into
`runtime/helpers/diffusion_vendor/` next to `diffusion_generate.py`. Rationale:
[`CONVENTIONS.md`](CONVENTIONS.md#vendoring-the-diffusiongemma-decoder-copy-not-pip).

### Recipes (`Resources/recipes/`)

| File | Use |
|---|---|
| [`llama-3.2-3b-teach-coding.yaml`](../LLMPro/Resources/recipes/llama-3.2-3b-teach-coding.yaml) | Llama 3.2 3B Instruct → coder, ~40 min |
| [`qwen2.5-7b-teach-coding.yaml`](../LLMPro/Resources/recipes/qwen2.5-7b-teach-coding.yaml) | Qwen 2.5 7B Instruct → coder, ~90 min |
| [`mistral-7b-teach-coding.yaml`](../LLMPro/Resources/recipes/mistral-7b-teach-coding.yaml) | Mistral 7B Instruct → coder, ~80 min |
| [`gemma-2-2b-teach-coding.yaml`](../LLMPro/Resources/recipes/gemma-2-2b-teach-coding.yaml) | Gemma 2 2B IT → coder, ~25 min |

These are **not currently loaded by the app** — they're reference / starter
material in the bundle, intended to be promoted into the AutoTuner's per-size
defaults if those need adjustment.

### Team agents (`Resources/agents/`)

The five Code-tab roles' definitions, one Markdown file per role. Bundled, then
seeded into `PathResolver.agentsDir` on first launch by `AgentStore` (only if
missing, so user edits persist). Each file is YAML-ish frontmatter
(`id`/`name`/`emoji`/`tint`/`tools`/`delegates`/`maxIterations`) + a system-prompt
body. See [`CONTRACTS.md`](CONTRACTS.md#agent-markdown-file-format-team-agents) for
the format.

| File | Role |
|---|---|
| [`orchestrator.md`](../LLMPro/Resources/agents/orchestrator.md) | 🧭 Orchestrator — talks to the user, delegates to the others |
| [`planner.md`](../LLMPro/Resources/agents/planner.md) | 🗺️ Planner — turns a request into an ordered plan |
| [`researcher.md`](../LLMPro/Resources/agents/researcher.md) | 🔬 Researcher — web research via the scientific method |
| [`coder.md`](../LLMPro/Resources/agents/coder.md) | 💻 Coder — builder: backend / logic / general code |
| [`ui.md`](../LLMPro/Resources/agents/ui.md) | 🎨 UI — builder: user-interface code |

---

## Build-time config

| File | Purpose |
|---|---|
| [`project.yml`](../project.yml) | XcodeGen spec. SWIFT_VERSION 6.0, macOS 14, arm64-only. Bundles `LLMPro/` as the only source. Info.plist properties + entitlements declared inline. `ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon`. |
| [`LLMPro/Resources/Assets.xcassets/AppIcon.appiconset/`](../LLMPro/Resources/Assets.xcassets/AppIcon.appiconset/) | 10 PNG sizes (16 / 32 / 128 / 256 / 512 at @1x and @2x) generated by [`tools/make_icon.py`](../tools/make_icon.py). |
| [`tools/make_icon.py`](../tools/make_icon.py) | The icon generator — Python + Pillow. Renders a 1024×1024 master (gradient squircle + graduation cap + tassel + sparkles) and downsamples. Edit + re-run to change the icon. |
| [`tools/agent_smoke.py`](../tools/agent_smoke.py) | End-to-end regression harness for the Code tab's coding agent. A faithful Python mirror of `MLXServerService` + `CodingAgentService` + `ToolExecutor`: starts `mlx_lm server`, drives the tool-use loop (native + `<tool_call>` fallback) in a temp workspace, and asserts read→write→finish. Run: `HF_HOME=<app hf> python3 tools/agent_smoke.py <model_snapshot_path>`. Verified PASS on Qwen3.6-27B-bf16 (native) + Llama-3.2-1B (fallback). |

---

## Cross-tab communication

Sometimes a view in tab A needs to trigger a state change in tab B. We use
`NotificationCenter` with named `Notification.Name` extensions, declared
alongside the views that send them. These are also the **feedback loop's edges** —
carrying a fine-tuned model (+adapter) forward to pre-fill the next stage's tab
(see [`CONCEPT.md`](CONCEPT.md)). The model/adapter ones carry a
[`ModelHandoff`](../LLMPro/Core/LoopHandoff.swift) (or a bare `String` for
backward compatibility) as the notification `object`:

| Notification | Posted by | Object | Received by |
|---|---|---|---|
| `.switchSidebar` | `DashboardView` buttons; Progress/Arena "Save & Use" CTAs | `SidebarSection` | `RootView.sidebar.onReceive` (sets selection) |
| `.switchToMonitor` | `TrainingConfigView.launch()` after a successful start | (none) | `RootView` (switches to `.monitor`) |
| `.openTrainingWithModel` | `ModelDetailView` "Use for training"; Arena "Train again" (retrain back-edge) | `String` (repoID) | `TrainingConfigView` (pre-fills `selectedModelRepoID`) |
| `.openChatWithModel` | Progress completion card ("Try it out" + "Grade it") / Arena decision bar / Practice "Use this fine-tune" / `ModelDetailView` | `ModelHandoff` (or `String`); "Grade it" sets `autoScore: true` | `RootView` → `.chat`; `ArenaView` pre-fills model + adapter, auto-scores when `autoScore` |
| `.openCodeWithModel` | Progress completion card / Arena decision bar / Practice "Use this fine-tune" | `ModelHandoff` (or `String`) | `RootView` → `.code`; `CodeView` pre-fills model + adapter |

Don't expand this pattern past a handful of cross-tab events. For more complex
state sharing, lift the state into a Service.

---

## Tests (`Tests/LLMProTests/`)

The `LLMProTests` XcodeGen target holds the project's first unit-test suite —
**37 passing XCTest tests** (`xcodebuild … test` → TEST SUCCEEDED). Pure-logic
coverage, no model loads or subprocesses:

| File | Covers |
|---|---|
| [`LogStreamParserTests.swift`](../Tests/LLMProTests/LogStreamParserTests.swift) | `LogStreamParser` regexes against real mlx-lm train / eval / DPO lines |
| [`DatasetServiceClassifyTests.swift`](../Tests/LLMProTests/DatasetServiceClassifyTests.swift) | `DatasetService.classify` for each source schema (incl. the `preference`-before-`completions` vote) |
| [`AutoTunerTests.swift`](../Tests/LLMProTests/AutoTunerTests.swift) | `AutoTuner.categorize` size buckets + every `(size, duration)` bucket produces a sane (positive, monotonic) config |
| [`FuseServiceTemplateTests.swift`](../Tests/LLMProTests/FuseServiceTemplateTests.swift) | `FuseService.OllamaChatTemplate` per-architecture suggestions |

The stale empty `Tests/MLXStudioTests/` was removed. (One pinned discrepancy:
`AutoTuner.categorize`'s doc comment says it falls back to `.medium` for a
marker-less id, but the trailing `return .medium` is dead code — the patterns table
ends with `(0.0, .tiny)`, so a marker-less id actually returns `.tiny`;
`testCategorizeNoMarkerFallsBackToTiny` pins the **actual** behavior and flags the
gap. See [`STATE.md`](STATE.md#tests).)

## Where files DON'T live

To save you from looking:

- **No CI yet.** Local builds via `xcodebuild` only; run the test suite with
  `xcodebuild … test` (see [`BUILDING.md`](BUILDING.md)).
- **No icon generator tests.** [`tools/make_icon.py`](../tools/make_icon.py) is
  one-shot — re-run by hand if you change the design.

See [`STATE.md`](STATE.md) for the full status board.
