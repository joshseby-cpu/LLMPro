# CLAUDE.md — orientation for agents

This file is the first thing any agent (you) should read before touching this repo.
It exists to prevent context loss between sessions and to keep new work consistent with
existing decisions. **Read it fully once, then dip into [`docs/`](docs/) as needed.**

---

## 🤖 Work through the agent team — start with `Main`

This repo ships its own subagent team in [`.claude/agents/`](.claude/agents/). **Use
it.** Don't do multi-step or multi-domain work as a single monolithic agent — route
it through the team so each change is made by the right specialist under consistent
rules.

**[`Main`](.claude/agents/Main.md) is the orchestration entry point.** For anything
beyond a trivial one-file edit, begin with Main. Main decomposes the work, dispatches
specialists (in parallel where the work is independent), is the **only** agent that
talks to the user directly, and relays specialists' questions back to you. Main does
**not** edit files itself — every concrete change goes through a builder.

The roster (full descriptions in each file's frontmatter):

| Agent | Use for | Relevance here |
|---|---|---|
| [`Main`](.claude/agents/Main.md) | Orchestration / entry point for any multi-step task | **Start here** |
| [`Planner`](.claude/agents/Planner.md) | Sequencing a task that spans subsystems before any edits | Use for cross-tab / multi-service features |
| [`Researcher`](.claude/agents/Researcher.md) | Empirical questions (mlx-lm API, HF behaviour) via web + sandbox tests | Builders may call it directly |
| [`Builder-Swift`](.claude/agents/Builder-Swift.md) | `.swift`, `project.yml`, entitlements, model/service/concurrency code | **Primary builder** — most of `MLXStudio/` |
| [`Builder-SwiftUI`](.claude/agents/Builder-SwiftUI.md) | SwiftUI view-layer: `View`/`Scene`/previews/navigation/`@Observable` view models | **Primary builder** — everything in `Features/` |
| [`Builder-Python`](.claude/agents/Builder-Python.md) | `.py` — the `Resources/helpers/` scripts and `tools/` | The mlx-lm/HF/weight-surgery helpers |
| [`Builder-Text`](.claude/agents/Builder-Text.md) | `.md`/`.txt` docs — `docs/`, this file, README, INSTALL | **The doc-maintenance contract below runs through here** |
| [`Builder-TypeScript`](.claude/agents/Builder-TypeScript.md) | `.ts/.tsx/.js` | Not used — this repo has no TypeScript |

**The team does not exempt anyone from the rules in this file.** Whichever builder
makes a change still owes the **load-bearing decisions** (§"The minimum you must know")
and the **doc-maintenance contract** (next section). When Main dispatches a builder,
the relevant rules from this file should travel in the dispatch prompt, since
subagents don't inherit the conversation. A Swift change that adds a file still
requires the matching `ARCHITECTURE.md` update — typically a follow-up `Builder-Text`
task in the same session.

---

## ⚠️ Documentation is part of the work — read this section twice

This codebase is maintained by agents in successive sessions. **The
documentation set is how knowledge survives between sessions.** If you change
code without updating the relevant docs, the next agent will lose the context
you just built — and "out-of-date docs are worse than no docs because they
actively lie."

**Doc maintenance contract**: before you end any session in which you changed
code, walk this table and update what applies:

| If you did this… | You must update this doc |
|---|---|
| Added / renamed / deleted a file in `MLXStudio/` | [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — the module tables |
| Added a new user-facing flow (button, sheet, sidebar tab) | [`docs/WORKFLOWS.md`](docs/WORKFLOWS.md) — add or amend the trace |
| Changed an mlx-lm CLI flag, HF API call, helper JSON event, file-path convention, SwiftData field, or Notification.Name | [`docs/CONTRACTS.md`](docs/CONTRACTS.md) |
| Made a design decision worth remembering — or reversed one | [`docs/CONVENTIONS.md`](docs/CONVENTIONS.md) |
| Added a capability a future agent might want to extend | [`docs/EXTENDING.md`](docs/EXTENDING.md) — add a recipe |
| Discovered a build issue, workaround, Swift 6 gotcha, or signing detail | [`docs/BUILDING.md`](docs/BUILDING.md) — troubleshooting section |
| Fixed a bug, finished a half-done feature, hit a numerical issue, or completed a verified end-to-end run | [`docs/STATE.md`](docs/STATE.md) — Working / Half-done / Known issues + the **Recent session log** |
| Changed any of the load-bearing decisions in this file | Update this file (CLAUDE.md) AND `CONVENTIONS.md` together |

**Heuristic**: before you finish a task, `grep` the docs for terms related to
what you changed. If a doc now says something untrue, fix it. If a code path
no longer matches the workflow described in `WORKFLOWS.md`, fix it. If a file
you wrote is not in `ARCHITECTURE.md`, add it.

**Always append to the Recent session log in [`docs/STATE.md`](docs/STATE.md)**
when finishing a session. Even a one-liner ("Fixed off-by-one in
`LogStreamParser` regex around eval lines") is enough to save the next agent
significant time.

**Skipping doc maintenance is a regression.** Treat it with the same weight as
breaking a test would have if we had tests.

---

## What this project is

**MLX Studio** is a native macOS SwiftUI app that puts a polished, no-code UI on top of
Apple's [`mlx-lm`](https://github.com/ml-explore/mlx-lm) — the goal is to let a user
who knows nothing about LLM training:

1. Pick any LLM from HuggingFace
2. Pick (or build) a coding dataset
3. Fine-tune the model on their Mac with sensible auto-tuned hyperparameters
4. Test the fine-tuned model locally
5. Export to Ollama / LM Studio for everyday use

It is *not* a CLI wrapper. It is *not* a research notebook. It is a polished consumer
app for a power user on a 128 GB M-series MacBook who wants their own coding assistant
without learning what a learning rate is.

> If you find yourself adding a CLI flag, a YAML config the user has to edit by hand,
> or a feature that requires "knowing what gradient checkpointing means", you are
> drifting from the product. Push that complexity behind the **Advanced settings**
> disclosure and pick a sensible default for the primary flow.

---

## The core loop — read this first

The sidebar tabs are not a menu of unrelated tools. They are the stages of **one
closed feedback loop** that a single artifact — a base **model**, and after
fine-tuning its **LoRA adapter** — travels through:

```
① DOWNLOAD a model  →  ② FINE-TUNE it  →  ③ TEST it  →  ④ USE it (coding)
   (Models)             (Teach/Lessons)    (Try it out)   (Code)
                          ▲                                     │
                          └──── ⑤ if it's not good enough ──────┘  (retrain back-edge)
```

The artifact is carried two ways: a [`TrainingJob`](MLXStudio/Models/TrainingJob.swift)
SwiftData record (`adapterURL = PathResolver.adapterDir(for: jobID)`), and a
[`ModelHandoff`](MLXStudio/Core/LoopHandoff.swift) `{model, adapterPath?}` posted as a
cross-tab `Notification.Name` `object` to pre-fill the next tab. **Practice** is the
same loop automated; **Save & Use** is the off-loop exit. Hand-offs are user-driven
CTAs — completion never auto-switches tabs.

**Read [`docs/CONCEPT.md`](docs/CONCEPT.md) before adding any tab or cross-tab flow** —
it's the doc that explains *why* the app is shaped this way.

---

## Five-minute orientation

| You want to… | Read this |
|---|---|
| Understand the app as one feedback loop (read first) | [`docs/CONCEPT.md`](docs/CONCEPT.md) |
| Understand what code lives where | [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) |
| Trace a user action end-to-end through code | [`docs/WORKFLOWS.md`](docs/WORKFLOWS.md) |
| Know what we depend on (mlx-lm flags, HF endpoints, helper JSON) | [`docs/CONTRACTS.md`](docs/CONTRACTS.md) |
| Understand *why* something is built the way it is | [`docs/CONVENTIONS.md`](docs/CONVENTIONS.md) |
| Add a new feature without breaking existing ones | [`docs/EXTENDING.md`](docs/EXTENDING.md) |
| Build and run the app from scratch | [`docs/BUILDING.md`](docs/BUILDING.md) |
| See what's done, half-done, and known-buggy | [`docs/STATE.md`](docs/STATE.md) |
| See the external projects / prior art that informed each feature | [`docs/REFERENCES.md`](docs/REFERENCES.md) |

---

## The product in one diagram

```
┌──────────────── SwiftUI app (macOS 14+, Apple Silicon) ─────────────────┐
│                                                                          │
│  Sidebar:   Home · Models · Lessons · Teach · Progress · Try it out      │
│             · Code · Practice · Fusion · Memory · Inspect · Save & Use    │
│             · Settings                                                    │
│                                                                          │
│  @Observable view models  ←→  SwiftData (@Model)                        │
│                  ↑                                                       │
│  Services layer (actor-isolated or @MainActor):                          │
│    PythonRuntime · HuggingFaceClient · DownloadService ·                 │
│    TrainingService · InferenceService · FuseService ·                    │
│    ModelRegistry · DatasetService · DatasetEditorService ·               │
│    DatasetPrepService · ModelModifyService · JobRegistry ·               │
│    SystemMetrics · AutoTuner · TrainingNarrator ·                        │
│    SelfImproveService · MLXServerService · CodingAgentService ·          │
│    AgentRoles · WebSearch · SkillStore                                   │
│                  ↑                                                       │
│  Core/ProcessRunner (Foundation.Process → AsyncStream<String>)          │
│                  ↑                                                       │
└──────────── Python subprocesses (uv-managed venv on disk) ──────────────┘
        python -m mlx_lm lora -c config.yaml          (training)
        python -m mlx_lm generate --adapter-path ...  (inference)
        python -m mlx_lm server --port <free> ...     (Code tab: long-lived agent server)
        python -m mlx_lm fuse  --export-gguf ...      (export)
        python hf_download.py            (model download, JSON-event progress)
        python prepare_coding_dataset.py (curated dataset preset → chat JSONL)
        python download_hf_dataset.py    (arbitrary HF dataset → chat JSONL)
        python strip_vision.py           (drop vision weights from VLM)
        python abliterate.py             (uncensor via refusal-direction projection)
        python humaneval_pull.py         (Practice seed: HumanEval/MBPP → seed + eval JSONL)
        python self_improve_round.py     (Practice round: gen K candidates, sandbox-test, write dataset)
        python eval_pass_rate.py         (Practice eval: pass@1 with optional adapter)
```

Disk layout under `~/Library/Application Support/MLXStudio/`:
```
runtime/.venv/          uv-managed Python 3.11 venv with mlx-lm installed
runtime/helpers/        copy of helper scripts from app bundle
hf/                     HuggingFace cache (HF_HOME) — models AND datasets
adapters/<job-uuid>/    one folder per training job: config.yaml + adapters.safetensors + job.json + training.log
datasets/<ds-uuid>/     train.jsonl + valid.jsonl + test.jsonl (chat schema)
models/<custom-name>/   modified models: text-only strips, abliterated copies, manual imports
exports/<job-uuid>/     GGUF / fused safetensors output from the Save & Use flow
selfimprove/<run-uuid>/ Practice run: seed.jsonl, eval.jsonl, run.json, round_N/dataset/, results.jsonl
skills/<skill-id>/      Code-tab Agent Skills (live): one SKILL.md package per folder (use_skill, 3-stage progressive disclosure)
```

---

## The minimum you must know to not break things

These are the load-bearing decisions. Violating any of them risks regressing
previously verified behaviour.

1. **Python is a sidecar, not embedded.** We never link `libpython`. Every
   Python call is a subprocess via `Core/ProcessRunner.swift`. Helpers communicate
   with Swift by emitting one JSON object per line on stdout — see
   [`docs/CONTRACTS.md`](docs/CONTRACTS.md). Don't change to a new IPC mechanism
   without good reason. **And use as little Python as possible** — default to Swift;
   reach for Python only for work that truly needs the ML stack (mlx-lm, HF hub,
   weight surgery). Every helper is permanent bundle weight. See the **Swift-first
   rule** in [`docs/CONVENTIONS.md`](docs/CONVENTIONS.md#use-as-little-python-as-possible-swift-first-rule).

2. **Helpers are copied out of the bundle on every launch** by
   `PythonRuntime.installHelpers()`. The copy lives in
   `~/Library/Application Support/MLXStudio/runtime/helpers/`. The subprocess
   always invokes `<helpers-dir>/<name>.py`, never the in-bundle path. If you add
   a new helper, add its name to the `installHelpers()` list AND to the
   `pip install …` line in `PythonRuntime.bootstrap()` if it needs a new dep.

3. **All training paths produce mlx-lm chat JSONL.** Every dataset preset and HF
   downloader normalises its source schema to `{"messages": [{"role", "content"}, …]}`.
   The dataset editor only edits in chat shape. Don't introduce a parallel schema.

4. **Local-model paths must be resolved to absolute paths before being written
   into `config.yaml`.** mlx-lm interprets a bare string with no `/` as an HF repo
   ID, not a local folder. See `TrainingConfigView.resolveModelArg()`. If you build
   a new training entry-point, route it through the same resolver.

5. **The HF cache has *two* layouts on disk.** `snapshot_download(cache_dir=X)`
   writes to `X/models--owner--repo/`. `huggingface_hub` with `HF_HOME=X` writes
   to `X/hub/models--owner--repo/`. `ModelRegistry.scan()` looks at both. If you
   add new file-watching code, check both.

6. **AutoTuner picks every hyperparameter.** The Teach UI exposes only three
   decisions: model, dataset, duration. Everything else (batch, iters, lr, lora
   rank, target keys, grad checkpointing, max seq length) flows from
   `AutoTuner.tune()`. There is an "Advanced settings" disclosure for power users
   but it should remain hidden by default. Don't add knobs to the primary UI.

7. **The friendly UI is the default; technical is the disclosure.** Progress, Teach,
   and Lessons all follow this rule: warm copy + emoji + plain-language status leads;
   technical (charts, logs, YAML) lives behind a `DisclosureGroup`. Do not invert.

8. **Hardened-runtime entitlements are non-negotiable.** The bundled Python uses
   JIT. The entitlements (`com.apple.security.cs.allow-jit`,
   `allow-unsigned-executable-memory`, `disable-library-validation`,
   `allow-dyld-environment-variables`) are required for the app to launch when
   spawning subprocesses. They're in [`MLXStudio.entitlements`](MLXStudio/MLXStudio.entitlements).

9. **SwiftData models are @MainActor by default.** Services that read/write them
   are `@MainActor @Observable final class`. Long-running work happens via
   `Task { @MainActor in … }` blocks that re-fetch the SwiftData record by UUID
   using a `FetchDescriptor`. Don't capture `@Model` instances into `Task.detached`
   blocks — Swift 6's strict concurrency will reject it.

10. **Window close ≠ app quit.** `AppDelegate.applicationShouldTerminateAfterLastWindowClosed`
    returns `false` so training survives accidentally closing the window. The
    quit prompt offers Stop / Detach / Cancel.

---

## How to navigate the codebase

```
MLXStudio/
├── App/          MLXStudioApp.swift (entry point), AppDelegate, RootView (sidebar shell)
├── Core/         Low-level utilities: ProcessRunner, PathResolver, LogStreamParser, SyntaxHighlighter
├── Models/       SwiftData @Model types: TrainingJob, LocalModel, DatasetRecord, AppSettings, AgentProfile
├── Services/     The heart of the app — every business action lives in a service:
│                 PythonRuntime, HuggingFaceClient, DownloadService, TrainingService,
│                 InferenceService, FuseService, ModelRegistry, DatasetService,
│                 DatasetEditorService, DatasetPrepService, ModelModifyService,
│                 JobRegistry, SystemMetrics, AutoTuner, TrainingNarrator,
│                 ConversionService, CodingDatasetCatalog, SelfImproveService,
│                 MLXServerService, OpenAIChatClient, AgentTools, AgentRoles,
│                 WebSearch, CodingAgentService, SkillStore (Agent Skills)
├── Features/     One folder per sidebar tab:
│   ├── Dashboard/  (Home) — DashboardView
│   ├── Models/     ModelsBrowserView, ModelDetailView, ModelModifyView
│   ├── Datasets/   (Lessons) DatasetsView, DatasetDetailView, DatasetRowEditorView, HuggingFaceDatasetSearchView
│   ├── Training/   (Teach) TrainingConfigView
│   ├── Monitor/    (Progress) TrainingMonitorView
│   ├── Chat/       (Try it out) ArenaView, ChatView, ChatModels
│   ├── Code/       (Code) CodeView — agentic coding assistant + 3-pane IDE; FileExplorerView, CodeEditorView, MarkdownEditor, SkillsManagerView (Agent Skills, raw-markdown CRUD; links skill↔skill and skill↔agent), AgentsManagerView; AgentTemplate (dead; AgentEditorView deleted)
│   ├── SelfImprove/ (Practice) SelfImproveView
│   ├── Inspect/    (Inspect) ModelInspectorView — WeightsInspectorView (pure-Swift safetensors header parse via Core/SafetensorsHeader), AttentionInspectorView (one-forward MLX capture via inspect_attention.py), CoTInspectorView (live reasoning split, reuses OpenAIChatClient)
│   ├── Export/     (Save & Use) ExportWizardView
│   └── Settings/   SettingsView, FirstRunView
└── Resources/
    ├── helpers/    Python helper scripts (download, prepare-dataset, strip-vision, abliterate, etc.)
    ├── recipes/    YAML training recipe presets (coding fine-tunes for various base models)
    └── Assets.xcassets/  AppIcon
```

**Rule of thumb**: a View file should be ~all SwiftUI, ~no business logic. Business
logic lives in a Service. If a View is getting fat with logic, that's a refactor
signal — extract to or add to a Service.

---

## Vocabulary

The app uses friendly names that don't always match the code. Keep both in mind:

| User-facing (sidebar / copy) | Code-side (filenames / models) |
|---|---|
| Home | Dashboard |
| Lessons | Datasets · DatasetRecord |
| Teach | TrainingConfigView |
| Progress | TrainingMonitorView · JobRegistry |
| Try it out | ArenaView · InferenceService |
| Code (the "Orchestrator team") | CodeView · CodingAgentService · AgentRoles · MLXServerService |
| The five team roles (🧭🗺️🔬💻🎨) | TeamRole.orchestrator / planner / researcher / coder / ui |
| Editing a team agent ("Edit team agents…") | Resources/agents/<role>.md + AgentStore + AgentsManagerView (raw-markdown editor via MarkdownEditor; the editable form of the 5 roles; NOT the dead AgentProfile) |
| Delegating to a teammate ("call the Planner") | call_<role> tool → CodingAgentService.runDelegate |
| ~~An "Agent" (switchable, removed)~~ | AgentProfile — **dead code** (agent picker removed; AgentEditorView deleted) |
| A "Skill" / "Manage skills" (Agent Skills) | SkillStore · SkillsManagerView · skills/<id>/SKILL.md · `use_skill` tool — **live**: raw-markdown CRUD via MarkdownEditor; 3-stage progressive disclosure; team-global by default; links skill↔skill (`skills:`/`links:`) and skill↔agent (agent `skills:`) |
| Practice | SelfImproveView · SelfImproveService · SelfImproveRun |
| Save & Use | ExportWizardView · FuseService |
| A "lesson" | one row in a JSONL = one ChatRow |
| "How well it's learning" / star rating | loss-improvement ratio (TrainingNarrator.stars) |
| "Opening the textbook…" / "Setting up the exercises…" | TrainingNarrator.Phase |
| "Tiny / Small / Medium / Big / Huge" | ModelSize enum in AutoTuner |
| "Quick / Standard / Thorough" | TrainingDuration enum in AutoTuner |
| A "practice problem" | one row in seed.jsonl with `prompt + tests + entry_point` |
| "Trying problems / Studying / Grading" | SelfImproveService.Phase |
| "Kept lessons" / "passes" | candidates that pass the sandboxed unit tests |

When writing code comments and identifiers, use the technical names. When writing
user-facing strings, use the friendly names.

---

## Conventions you should follow

These are short here; the full set is in [`docs/CONVENTIONS.md`](docs/CONVENTIONS.md).

- **No emoji in code unless asked.** Emoji belong in user-facing strings (Narrator,
  AutoTuner display names) where they're part of the UX.
- **Friendly progress narrator** is `TrainingNarrator`. When you add a new long-running
  operation, add a phase to that enum rather than coining new ad-hoc status strings.
- **JSON-event protocol for helpers.** All helper scripts emit
  `{"event": "start"|"progress"|"done"|"error", …}` on stdout. The Swift side parses
  line-by-line. Follow this exact pattern — see [`docs/CONTRACTS.md`](docs/CONTRACTS.md#helper-script-protocol).
- **AutoTuner picks hyperparameters.** Do not surface new training knobs in the
  primary UI. Add them to AutoTuner if they should be auto-set, or to the Advanced
  disclosure if power users need them.
- **Friendly first, technical disclosed.** Lead with plain-language + emoji + star
  ratings; tuck charts/logs/YAML under a `DisclosureGroup`.
- **Sidecar files for crash recovery.** Every long-running operation that produces
  a SwiftData record should also drop a sidecar JSON in its output dir
  (`adapter/job.json`) so we can recover after a crash.
- **Log at error chokepoints; read the logs after testing.** Errors go through
  `Log.error/.fault` ([`Core/Log.swift`](MLXStudio/Core/Log.swift) → `os.Logger` +
  `logs/mlxstudio.log` + a crash/signal backtrace breadcrumb). **A green UI is not a
  pass** — after any test (build-run, UI walkthrough, model run, stress sweep) read
  the log (`tail`/`grep ERROR\|FAULT` the file, or Settings → Logs) and check for a
  new `~/Library/Logs/DiagnosticReports/MLXStudio-*.ips`; zero error lines + no new
  `.ips` is the bar. See `CONVENTIONS.md` → "Always read the logs after testing"
  (this rule exists because a 13-tab "all PASS" sweep missed a real crash sitting in
  the `.ips`). Don't add a third-party logging dep.

---

## What's verified working (as of the last session)

End-to-end smoke-tested in the UI:

- ✅ First-run flow (Python runtime bootstrap, starter model download)
- ✅ HuggingFace model search + download (`mlx-community` filter + "All")
- ✅ HuggingFace dataset search + preview + auto-schema-detect + normalize to chat JSONL
- ✅ Curated dataset catalog (CodeAlpaca, Magicoder Evol, Magicoder OSS, evol-codealpaca, Glaive)
- ✅ Drag-drop JSONL import with auto schema detection
- ✅ Dataset CRUD: create blank, edit rows, add row, delete row, rename, duplicate, delete dataset, show in Finder
- ✅ Teach: 3-card picker (model / dataset / duration) with auto-tuned hyperparameters and live time estimates
- ✅ Progress: friendly phase narrator, 5-star learning rating, ETA, technical-details disclosure with 4 charts and log tail
- ✅ Training of: Llama 3.2 1B (200 iters Quick, ~3 min), Qwen3-32B-4bit (50 iters, ~3.5 min), Qwen3.6-27B-8bit (50 iters, ~6 min), Qwen3.6-27B-8bit-Text-Gen stripped (50 iters, ~2 min)
- ✅ Local-model delete with confirmation and disk-usage display
- ✅ Strip-vision (drop vision weights from a VLM, save as new local model)
- ✅ Abliteration / "Make uncensored" — **rewritten + verified end-to-end** on a quantized model (Llama-3.2-1B-4bit: stays coherent, refusals 3/5→1/5, refusal signal removed 100%). Dequantizes quantized inputs first (4-bit requant snaps the edit ~85% back → fp16 output, re-Shrink to recompress), uses the **last chat-token** direction (not a token-mean → avoids the ~137× BOS attention sink), **skips tied embeddings** (avoids logit collapse), ablates attention + MLP + **MoE** writes across all layers (walk unit-tested: Gemma `experts.switch_glu` / Qwen `switch_mlp` / dense / per-expert). Full recipe in [`docs/CONTRACTS.md`](docs/CONTRACTS.md) §2.
- ✅ Custom app icon (purple gradient + graduation cap)
- ✅ Practice tab — recursive self-improvement loop: pull HumanEval/MBPP, baseline pass@1, generate-test-train-eval per round, friendly progress + trend chart. **Verified end-to-end through the UI on Llama-3.2-1B (2 rounds × 4 candidates × 20 problems, 2.9 min wall-clock). Plumbing works; defaults need tuning to produce an *improving* curve rather than the overfit-on-tiny-keeper-set curve the smoke run produced.**

Known issues + half-done items are in [`docs/STATE.md`](docs/STATE.md).

---

## Where this came from

This codebase was bootstrapped via a plan at
[`~/.claude/plans/create-a-application-for-piped-abelson.md`](../../.claude/plans/create-a-application-for-piped-abelson.md)
(if it still exists on the working machine). The plan captured the user's
preferences: native SwiftUI (not Tauri), Apple Silicon only, bundle Python via uv,
full Studio scope, coding-focused, Ollama hand-off as the primary export.

Many subsequent sessions added features:
- HuggingFace dataset search (any dataset, not just curated)
- Model deletion with disk-usage display
- Friendly UX redesign (the 9-year-old simplification)
- Vision stripping + abliteration
- Custom app icon
- Dataset CRUD editor

When in doubt, prefer the existing pattern over inventing a new one. See
[`docs/EXTENDING.md`](docs/EXTENDING.md) for how to add features without disturbing what's there.
