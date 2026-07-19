# Project state

> 📝 **Maintainers**: this file is the project's living memory.
> **You are expected to update it in every session you do real work.** Minimum:
> append one line to the "Recent session log" at the bottom with what you did.
> Also move features between sections ("half-done" ↔ "working") as their state
> changes, log new known bugs, and tick items off the "open design questions"
> list when resolved. See the
> [doc-maintenance contract](../CLAUDE.md#%EF%B8%8F-documentation-is-part-of-the-work--read-this-section-twice).

What works, what's half-done, what's known-buggy, what's deliberately out of
scope.

---

## Working end-to-end (verified)

- ✅ **First-run wizard** — 5 steps including Python runtime bootstrap and
  starter coding-model selection.
- ✅ **Python runtime** — uv venv at `~/Library/Application Support/LLMPro/runtime/.venv/`,
  mlx-lm 0.31.3 installed, helpers refreshed every launch.
- ✅ **HuggingFace model search** — filterable by `mlx-community` org or "All".
- ✅ **HuggingFace model download** — accurate progress bar via dir-size poller
  (works for both xet and classic HTTP transports).
- ✅ **HuggingFace dataset search** — separate sheet, first-rows preview via the
  public datasets-server endpoint, schema picker + column mapping.
- ✅ **Coding-dataset catalog** — 5 curated presets (CodeAlpaca, Magicoder-Evol,
  Magicoder-OSS, evol-codealpaca, Glaive). One-click prepare with adjustable
  sample size.
- ✅ **Drag-drop JSONL import** with auto schema detection.
- ✅ **Dataset CRUD** — create blank, edit rows, add row, delete row, rename,
  duplicate, delete dataset. Auto-saves after every mutation.
- ✅ **Local model registry** — scans both HF cache layouts, shows accurate
  per-model size from blobs/.
- ✅ **Local model delete** — confirmation alert with bytes-to-free message;
  wipes all 4 cache locations.
- ✅ **Local model modify (strip vision)** — verified on Qwen3.6-27B-8bit
  (dropped 333 vision tensors / 921 MB, kept 27 GB of language model weights;
  trained cleanly on CodeAlpaca after the fix).
- ✅ **Local model modify (abliterate)** — Python helper implemented and ships;
  ran on small models in CLI testing.
- ✅ **AutoTuner** — picks batch, iters, layers, lr, lora rank/scale/keys per
  `(ModelSize, TrainingDuration)`. Time estimates calibrated against real M-series
  runs.
- ✅ **Teach UI** — 3-card picker (model / dataset / duration) + Advanced
  disclosure with the full mlx-lm YAML form.
- ✅ **Training subprocess** — `python -m mlx_lm lora -c config.yaml`, stdout
  tailed via LogStreamParser, metrics flow through JobRegistry, SwiftData
  appendStep, sidecar `job.json` for crash recovery.
- ✅ **Progress UI** — friendly phase narrator (📖 / 🧩 / 📚 / 📝 / 🎉),
  5-star learning rating from loss-improvement ratio, ETA, memory gauge,
  Technical Details disclosure with charts and log.
- ✅ **Try-it-out (Arena)** — base vs fine-tuned A/B chat, shared input bar. (The
  old unscored "Mini-eval" button is now the scored **"Score it"** action — see the
  "Scored Test node" entry below.)
- ✅ **Scored Test node ("Score it" / EvalService / EvalRun) — verified live
  end-to-end.** Turns the loop's ③ Test node ([`ArenaView`](../LLMPro/Features/Chat/ArenaView.swift))
  into a tracked, quantitative **pass@k** score per `(model + adapter)`, written to a new
  [`EvalRun`](../LLMPro/Models/EvalRun.swift) `@Model` and feeding the ⑤ retrain
  back-edge. [`EvalService`](../LLMPro/Services/EvalService.swift) (singleton) reuses the
  **existing** eval engine — one-shot [`eval_pass_rate.py`](../LLMPro/Resources/helpers/eval_pass_rate.py)
  + [`humaneval_pull.py`](../LLMPro/Resources/helpers/humaneval_pull.py) + the Practice
  RLIMIT_AS+SIGALRM sandbox — not a new daemon. **Verified live** in the Test node on
  `qwen2.5-0.5b-instruct-mlx` (HumanEval, depth Quick=20, base/no-adapter) running as a
  standalone Debug `.app` (BUILD SUCCEEDED; NOT under Xcode's debugger): the UI streamed
  a live "Grading N of 20 — N passed" status, then rendered the report card — **40%,
  ★★★☆☆ (3 stars), "HumanEval (164 problems) · 20 problems", "First score for this
  model."** + a Details disclosure. **Persistence confirmed**: an `EvalRun` record +
  sidecar `evals/2FB34179-…/eval_run.json` were written with `passAtK 0.40`,
  `passedCount 8`, `totalCount 20`, `problemCount 20`, suite `humaneval`, baseModel
  `qwen2.5-0.5b-instruct-mlx`, status `completed`, sourceLabel `Test`, k 1,
  `elapsedMs ~36392`, `lastError null` — matching the UI exactly. **Logs clean**: zero
  ERROR/FAULT in `logs/llmpro.log` since launch, no new `DiagnosticReports/LLMPro-*.ips`.
  The engine was **also validated headless against a real model**: `eval_pass_rate.py`
  on the 0.5B at **k=1 → pass@1 0.375 (3/8)** with real generations + both pass/fail
  sandbox paths exercised, and at **k=2** it emitted the new `start.k` /
  `row.passes`+`row.k` / `done.pass_at_k`+`done.k` fields correctly (a passing-greedy
  row failing at temp>0 is expected small-model variance, not a bug). Progress's
  completion card also gained a **"Grade it"** CTA
  (`.openChatWithModel` + `ModelHandoff.autoScore: true` → Test node auto-scores).
  **One caveat, build-verified but NOT live-witnessed:** the score-**delta** path
  (▲/▼ "vs your last try", via `EvalService.previousAdapterEval`) needs two evals of the
  same base with different adapters, and no small model with an adapter was available —
  the "first score for this model" no-previous branch WAS verified live; the delta
  branch was not. Custom suites (`EvalSuite.custom`) are importable via the Test node
  ("Import suite…") as of the 2026-06-13 loop; hand-drop still works. Design rationale in
  [`CONVENTIONS.md`](CONVENTIONS.md#the-scored-test-node-evalservice--evalrun); trace in
  [`WORKFLOWS.md §6b`](WORKFLOWS.md).
- ✅ **DPO preference loop ("Teach by preference") — plumbing verified live
  end-to-end.** The Arena's ③ Test node gained a second back-edge: the user marks
  which answer is better (👍 capture row, separate from the Feature-1 "Score it"
  report card), preference pairs accumulate into a `DatasetSchema.preference`
  [`DatasetRecord`](../LLMPro/Models/DatasetRecord.swift) via
  [`PreferenceService`](../LLMPro/Services/PreferenceService.swift), and a **DPO
  fine-tune** turns them into a normal LoRA adapter that flows back through the loop.
  DPO runs via the **separate `mlx-lm-lora` (v2.1.0)** package
  (`python -m mlx_lm_lora.train`), installed on-demand like mergekit (the installed
  `mlx-lm` 0.31.3 has no DPO). New plumbing: `TrainMode {sft,dpo}` + `dpoBeta`/
  `dpoLossType` on `TrainingConfig` → `renderDPOYAML()`; `AutoTuner.tuneDPO`;
  `TrainingJob.trainModeRaw` (additive, default "sft", **no migration**);
  `LogStreamParser` DPO regex (`Iter N: loss …`, anchored on `: loss `);
  `PreferenceHandoff` + `.openTrainingWithPreferences` (Arena "Teach by preference →"
  CTA at ≥4 prefs → Teach in DPO mode). **Verified live** through the UI on
  `qwen2.5-0.5b-instruct-mlx`: captured 4 preferences (👍 buttons, running count,
  de-dup), the CTA enabled at 4 and switched to Teach with the `.preference` lesson
  auto-detecting DPO mode + banner; a Quick DPO run trained **66/66 iters** (real DPO
  loss lines, **batch clamped 4→1** for the 3-train/1-valid split), wrote
  `adapters.safetensors` (22 MB) + checkpoints, `job.json` `status: completed`,
  Progress showed 100% + a star rating, completion CTAs appeared. **Logs clean** (zero
  ERROR/FAULT in `llmpro.log`, no new `.ips`). **Two honest caveats:** (1) DPO on a
  4-preference set **overfits** (the star rating was low) — quality needs many more
  preferences; the **PLUMBING is what's verified**, not the quality. (2) The "Teach by
  preference" CTA switches tabs but the model/dataset **pre-fill has a
  notification-timing bug** being fixed separately (sibling agent) — "pre-fill fix in
  progress." Two contract gotchas worth knowing (full detail in
  [`CONTRACTS.md`](CONTRACTS.md#mlx_lm_loratrain--dpo-preference-training-separate-package)):
  `mlx_lm_lora.train` IGNORES YAML for its non-`None`-default args (incl.
  `--train-mode` default `"sft"`) so DPO knobs MUST be CLI flags; `fuse: false` is
  required (else it dumps a ~1.3 GB `model.safetensors` per adapter dir); and
  `--batch-size` MUST be clamped to `min(trainRows, validRows)` (its
  `iterate_dpo_batches` hangs otherwise). Design rationale in
  [`CONVENTIONS.md`](CONVENTIONS.md#dpo-preference-loop-via-on-demand-mlx-lm-lora);
  loop shape in [`CONCEPT.md`](CONCEPT.md#the-preference-back-edge-the-arena-also-produces-fuel).
- ✅ **Arena local-model inference fix.** `InferenceService.stream` now resolves a
  bare local-model name (custom `models/<name>` from GGUF import / strip-vision /
  abliterate / trained-and-saved) to its **absolute path** before `mlx_lm generate`,
  mirroring the training/eval/server resolvers. Previously the Arena passed the bare
  name, mlx-lm treated it as an HF repo id, and any local custom model failed with
  "exited with code 1". HF repo ids (with `/`) pass through unchanged. (Found while
  verifying the DPO loop, since DPO captures run against a local model in the Arena.)
- ✅ **DiffusionGemma (non-fine-tunable "guest" model) — chat AND Code, both verified
  live end-to-end.** Google's `google/diffusiongemma-26B-A4B-it` is a
  **masked/block-diffusion** LM (`model_type: diffusion_gemma`, decodes by iteratively
  unmasking a fixed canvas) — **not** autoregressive, so mlx-lm's `generate`/`server`
  can't run it and mlx-lm LoRA/AutoTuner **can't fine-tune** it. So in LLMPro it's a
  **non-fine-tunable guest**: download + chat (Try-it-out) **+ the Code tab's agentic
  loop** (experimental), **excluded only from Teach/Practice/DPO**. It runs the prebuilt
  `mlx-community/diffusiongemma-26B-A4B-it-OptiQ-4bit` (~15 GB). The decoder is
  **vendored, not pip-installed** — the MIT `optiq.vlm` subset of `mlx-optiq` v0.2.3,
  copied into [`Resources/helpers/diffusion_vendor/`](../LLMPro/Resources/helpers/diffusion_vendor/)
  (~34 `.py` + `VENDORED.md`; the package's network/subprocess/agent subtrees were
  deliberately left out; self-contained on `mlx`/`mlx-lm`/`transformers`/`numpy`/`Pillow`
  — **no torch**). **Chat path:** helper [`diffusion_generate.py`](../LLMPro/Resources/helpers/diffusion_generate.py)
  adds the vendor dir to `sys.path`, imports `optiq.vlm.diffusion_gemma`, **applies the
  Gemma chat template** (+ pre-tokenizes with `add_special_tokens=False`), self-pins
  MLX memory (bypasses `mlx_run.py`), and streams the standard JSON-event protocol
  (`start`/`progress`/`token`/`done`/`error`). **Code path:** helper
  [`diffusion_server.py`](../LLMPro/Resources/helpers/diffusion_server.py) is a
  long-lived **OpenAI-compatible HTTP server** (Python stdlib `http.server`
  `ThreadingHTTPServer`, **no Flask**) around the same vendored decoder — the model
  loads ONCE on a single dedicated **MLX worker thread** (the vendored decode binds a
  thread-local `mx` stream at import; HTTP threads submit jobs via a queue), exposes
  `GET /health` / `GET /v1/models` / `POST /v1/chat/completions` (non-stream + SSE in
  the exact shape `OpenAIChatClient` decodes), prints `LLMPRO_DIFFUSION_SERVER_READY
  port=<port>` when ready, and **translates** DiffusionGemma's native tool grammar
  `<|tool_call>call:NAME{…}<tool_call|>` into OpenAI `tool_calls` (tolerant, fail-open
  to plain `content`). Swift: `ModelRegistry.DetectedModel.isDiffusion`
  (config `model_type == "diffusion_gemma"` / `DiffusionGemma*` arch); `InferenceService.stream`
  routes diffusion models to `diffusion_generate.py` (chat, direct spawn, self-pinned
  mem); **`MLXServerService.start` branches on `isDiffusion` to launch
  `diffusion_server.py` (via `mlx_run.py`) instead of `mlx_lm server` — `adapterPath` is
  ignored (no LoRA) — reusing the same free-port / `/health` / warm-up / state
  machine, so `OpenAIChatClient` + `CodingAgentService` are unchanged**;
  `PythonRuntime.installHelpers()` recursively copies the `diffusion_vendor/` subtree +
  stages both `diffusion_generate.py` and `diffusion_server.py`, `bootstrap()` adds
  `pillow`; Teach + Practice pickers exclude `isDiffusion`; Models rows show a
  "Diffusion · chat only" badge (now slightly stale — Code works too); CodeView shows a
  "Diffusion model — chat works; agentic tool-use is experimental." caption and keeps
  native tool-calling on. **Verified live (chat)** through the UI on the 4-bit OptiQ
  model (~15 GB downloaded): coherent, correctly-formatted prose (a haiku about Apple
  Silicon; a 2-sentence "why the ocean is salty"; load ~16.8 GB peak, ~0.6–3 s gen
  after a cold load); absent from the Teach + Practice pickers; an mlx-lm regression
  check (a normal qwen model in the Arena) still streams correctly after the
  streaming-contract change; all 13 tabs swept, no crash; `llmpro.log` zero ERROR/FAULT,
  no new `.ips`. **Verified live (Code)** with DiffusionGemma-8bit served in the Code
  tab: the Orchestrator team drove the full agentic loop (Orchestrator → Coder →
  `write_file` → `list_dir`) and created a file on disk; logs clean, no crash;
  tool-calling works, with an occasional unusable diffusion turn that the Orchestrator
  recovers from (a canvas-256 reliability caveat). **Two chat bugs found and fixed
  during the first pass, both re-verified:** (1) the chat template wasn't applied
  (un-templated prompt → garbage) — the helper now templates + pre-tokenizes; (2) a
  per-token-newline rendering bug — `InferenceService` now yields ready-to-append chunks
  (mlx_lm re-adds its line `\n`, diffusion yields raw token segments) and
  `ChatSession.send` appends `chunk` **raw** (was `chunk + "\n"`). Contracts in
  [`CONTRACTS.md`](CONTRACTS.md#diffusion_generatepy--diffusiongemma-inference-non-mlx-lm)
  (chat) + [`CONTRACTS.md`](CONTRACTS.md#diffusion_serverpy--long-lived-openai-compatible-diffusion-server-code-tab)
  (Code); decisions in [`CONVENTIONS.md`](CONVENTIONS.md#vendoring-the-diffusiongemma-decoder-copy-not-pip);
  loop framing in [`CONCEPT.md`](CONCEPT.md#non-fine-tunable-guest-models-diffusiongemma--on--test---use-off-the-fine-tune-edges).
- ✅ **GGUF→MLX chat-template fallback.** [`gguf_to_mlx.py`](../LLMPro/Resources/helpers/gguf_to_mlx.py)
  now writes a **per-architecture default** chat template when the source GGUF carries
  none in its `tokenizer.ggml.chat_template` metadata (ChatML for qwen2/qwen2moe/qwen3,
  Gemma turn format, Llama-3 headers, Phi-3, Mistral), so a converted **INSTRUCT**
  model chats out of the box. Previously such a model had no template and failed in
  chat/Code/eval with "tokenizer.chat_template is not set" until one was hand-injected
  (this was the gap found while verifying the eval harness — the on-disk-converted
  Qwen2.5-0.5B test model needed a manual ChatML template). Metadata-present
  conversions are unchanged; the `done` event gained `chat_template_source`
  (`metadata` | `fallback-<arch>` | `none`). This **resolves** the former Half-done
  "GGUF→MLX importer does not reconstruct a chat template" item (the spun-off task is
  done). Contract:
  [`CONTRACTS.md`](CONTRACTS.md#gguf_to_mlxpy--gguf--mlx-import-chat-template-fallback).
- ✅ **Save & Use (Export)** — adapter zip / fused safetensors / GGUF, one-click
  Ollama install with chat-template detection.
- ✅ **Custom app icon** — purple gradient squircle with graduation cap; PNG
  generator at [`tools/make_icon.py`](../tools/make_icon.py).
- ✅ **Window-close-survives-training** — closing the window keeps training
  running; quit-while-training prompt with Stop / Detach / Cancel.
- ✅ **Cross-tab navigation** — Notification.Name events for "use this model for
  training", "open in chat", "open Models from Dashboard", etc.
- ✅ **SwiftUI live previews** — `ENABLE_PREVIEWS: YES` plus a `#Preview` on every
  view-bearing file (32 under `Features/` + `App/RootView.swift` = 33), each built
  via `View.previewEnvironment()` from the DEBUG-only scaffold
  [`Core/PreviewSupport.swift`](../LLMPro/Core/PreviewSupport.swift) (in-memory
  `ModelContainer` for all 7 `@Model` types + seeded samples + the real
  `PythonRuntime.shared`/`JobRegistry.shared` singletons). **Debug build clean,
  zero warnings, no new crash report.** Canvas rendering is an Xcode-GUI check (no
  headless macOS-preview render exists) — and the bodies now type-check fast enough
  that the canvas dylib compile no longer trips the stricter preview type-checker
  (diagnostic build shows 0 expressions over 80 ms; see the Recent-session-log
  hardening entry + [`CONVENTIONS.md`](CONVENTIONS.md#preview-type-checker-anti-patterns-a-plain-build-is-not-enough)).
- ✅ **Code tab (agentic coding assistant) — agent loop verified end-to-end.**
  New sidebar tab driving an agent loop with the user's local (optionally
  fine-tuned) MLX model over a long-lived `mlx_lm server`. **Compile-clean (BUILD
  SUCCEEDED, warning-clean.)** The full loop (server lifecycle → OpenAI tool
  protocol → native + fallback tool calls → sandboxed read/edit/run → result
  feedback → termination) was verified end-to-end against real local models via a
  faithful harness that mirrors the Swift loop exactly: **Qwen3.6-27B-bf16 PASS
  with native `tool_calls`** (warm-load 5.3 s → `read_file` → `write_file` → correct
  plain-text finish, accurate output), and **Llama-3.2-1B-4bit** exercised the
  `<tool_call>` text-fallback path. Live token streaming + a context-growth guard
  added. **Full toolset** (read / list / glob / grep / write / edit (+replace_all) /
  run + task-planning via `todo_write` + diff previews) verified in a Qwen-27B run
  that planned with `todo_write`, discovered files with `glob`, then read + wrote an
  accurate summary. Hand-driving the SwiftUI UI is the only remaining manual check —
  see Half-done.
  - ✅ **Team agents are editable Markdown files.** The 5 roles are defined by
    `Resources/agents/<role>.md` (frontmatter + system-prompt body), seeded by
    `AgentStore` into `agentsDir` once (edits persist), authoritative over the Swift
    `TeamRole` defaults; edited in-app via `AgentsManagerView` (Options → "Edit team
    agents…"). **Verified live**: first launch seeded all 5 files, the editor listed
    + showed their markdown, and editing the Orchestrator body + Save took effect on
    the next run.
  - ✅ **Multi-choice `ask_user`.** `ask_user` gained an optional `options` list so an
    agent can offer the user fixed-choice buttons; `CodeView.questionBar` renders one
    button per option (clicking steers the run) plus a free-text fallback. **Verified
    live**: the Orchestrator offered React/Vue/Svelte buttons; clicking "Vue" replanned
    a Vue app and dispatched the Coder + UI builders.
  - ✅ **Agent Skills (SKILL.md packages, 3-stage progressive disclosure) + raw-markdown
    CRUD + linking.** Revived the dead `SkillStore` / `SkillsManagerView` / `use_skill`
    code into the live `TeamRole` team: a skill is a `skills/<id>/SKILL.md` folder; the
    system prompt advertises only `name: description` (discovery), the agent calls
    `use_skill(name)` to load the full body + folder path (activation), then follows it
    (execution). `SkillsManagerView` is now a **raw-`SKILL.md` CRUD editor** (parity with
    `AgentsManagerView`, via the substitution-disabled `MarkdownEditor`). Skills are
    **team-global by default**; an agent can scope to a subset via its `skills:`
    frontmatter (skill→agent; nil=all/[]=none) and a skill can link to others via its own
    `skills:`/`links:` (skill→skill, transitive), scoped by
    `CodingAgentService.availableSkills(for:)`. Gated by `AgentSettings.useSkills` (default
    on). Seeds `conventional-commits` + `code-reviewer` on first launch
    (UserDefaults-guarded). **Verified live in the UI + headless tests against the real
    Swift code.**

End-to-end runs we've completed:

| Model | Quant | Dataset | Iters | Time | Final loss | Verdict |
|---|---|---|---|---|---|---|
| Llama-3.2-1B-Instruct | 4bit | Magicoder-Evol | 200 | ~6 min | 1.116 | ⭐⭐ Improved |
| Qwen3-32B | 4bit | CodeAlpaca | 50 | ~3.5 min | 0.619 | ⭐⭐⭐⭐⭐ |
| Qwen3.6-27B (original) | 8bit | CodeAlpaca | 50 | ~6 min | 0.571 | ⭐⭐⭐⭐⭐ |
| Qwen3.6-27B-Text-Gen (stripped) | 8bit | CodeAlpaca | 50 | ~2 min | 0.752 | ⭐⭐⭐⭐ |
| Qwen3.6-27B (original/stripped) | 8bit | Magicoder-Evol | ~7 | crash | NaN | numerical instability — see below |

---

## Half-done

Honest state of features that *kind of* work but need polish.

### Abliteration (uncensoring)

Marked Experimental in the UI. The Python helper is correct but slow on 27B+
(loading the full model + running 40 contrastive prompts). Tested end-to-end
only on smaller models in CLI. Defaults to projecting the refusal direction at
60% depth; this might need to be a slider in the Advanced view.

### llama.cpp helper for GGUF export of non-Llama architectures — RESOLVED

The Export wizard correctly detects when GGUF export needs llama.cpp's
`convert_hf_to_gguf.py` (for Qwen, Gemma, Phi). It looks for the converter at
`<runtime>/llama.cpp/convert_hf_to_gguf.py`. **Now installable in one click:**
`PythonRuntime.installLlamaCpp(progress:)` (mirrors `installMergekit` /
`installDPOTrainer`) `git clone --depth 1`s llama.cpp into
`PathResolver.llamaCppDir` and `uv pip install gguf`s into the venv; an "Install
llama.cpp converter" button is surfaced in both the Export wizard (the
`converterSection`) and Settings → Runtime ("GGUF export tools"). And
`FuseService.fuseAndConvertExternalGGUF` now **fails fast** with an actionable
`FuseError.llamaCppMissing` *before* the multi-minute fuse if the converter is
absent (it used to spawn the missing script and surface a raw error). Guard +
installer build-verified; the live clone is a runtime/network action not yet
smoke-tested through the UI.

### Resume button for orphaned jobs — RESOLVED

`JobRegistry.recoverOrphans()` marks dead-pid jobs as `.orphaned`. The Monitor
view now renders a friendly orange "This lesson was interrupted" **resumeCard**
with a "Resume lesson" button when `mostRecentJob()` is `.orphaned` (the action
chain in `TrainingMonitorView.content(for:)` gained an `.orphaned` branch
alongside `.running`/`.completed`). It fetches the SwiftData `TrainingJob` by id,
finds the newest checkpoint via the new `TrainingService.latestAdapterCheckpoint(in:)`
(highest-numbered `NNNNNNN_adapters.safetensors`, else `adapters.safetensors`),
and calls the pre-existing `TrainingService.resume(...)`; on success
`JobRegistry.attach` flips the job to `.running` and the normal running UI takes
over. Missing SwiftData record or no checkpoint → a friendly alert, no crash.
Build-verified; the live resume run is a runtime action not yet UI-smoke-tested.

### `LocalModel` SwiftData @Model

Defined in [`Models/LocalModel.swift`](../LLMPro/Models/LocalModel.swift) but
not used at runtime — `ModelRegistry.DetectedModel` (the runtime equivalent)
covers the current need. Either delete LocalModel or start using it for
per-model preferences (favorite, alias, notes).

### Practice tab (recursive self-improvement) — overfit root-cause fixed; empirical tuning still open

New in this session. Implements rejection-sampling self-distillation gated by
unit-test execution. **Verified end-to-end through the SwiftUI front-end on
Llama-3.2-1B-Instruct-4bit** (HumanEval seed, 2 rounds × 4 candidates × 20
problems, 2.9 min wall-clock). Every phase transitioned correctly (pulling
seed → baseline eval → generate → train → evaluate → next round → completed),
the trend chart animated as rounds landed, the run persisted to SwiftData +
sidecar + per-round dataset dirs + adapters dir, and the history row shows the
delta with a Reveal-adapter button.

**Open tuning question, not a bug:** the smoke-run measured pass@1 31% →
9% (catastrophic overfit on 5 train rows × ~50 iters). The loop's measurement
is honest — to actually get an *improving* curve on Llama-1B, the dataset per
round needs to be larger (more problems, higher candidates), the learning rate
should be cut for tiny datasets, or both. Reasonable starting point: 40
problems × 4 candidates on a stronger base. None of this is a fix to the loop
plumbing — it's a defaults question. Worth revisiting after a few more runs.

**Structural fix landed (2026-06-13 loop, iter 10):** the primary cause of that
9% collapse was that each round trained on **only that round's keepers** (5 rows
× ~50 iters → memorise-then-collapse). The round now trains on a **cumulative,
deduped buffer of all rounds' keepers so far** (`round_N/cumulative/`, built by
`SelfImproveService.mergeAndSplitKeepers` — dedup by user-prompt, latest round's
solution wins), so the training set grows monotonically instead of staying tiny.
This is the textbook rejection-fine-tuning buffer and is the highest-confidence
anti-overfit lever; it's covered by 6 new unit tests. **Still unvalidated by a
live run** — whether the curve now *improves* (vs merely not collapsing) needs an
end-to-end Practice run, and the numeric defaults (rounds/candidates/iters/LR)
are deliberately unchanged pending that measurement. Next session: run Practice
on Llama-1B and compare the trend to the old per-round-only behaviour.

Earlier risks worth checking on first UI run:

- **mlx_lm.generate API drift**: `generate_one()` in `self_improve_round.py`
  tries `(sampler=…)` first and falls back to legacy `(temp=, top_p=)` positional.
  If the user's installed mlx-lm has a third signature we haven't seen, both
  paths will TypeError → 0 candidates → "0 passing samples" error.
- **HumanEval dataset script**: `load_dataset("openai_humaneval")` is the
  canonical name and works without auth, but HF occasionally renames or
  deprecates eval sets. If `humaneval_pull.py` fails with HTTP 404, try
  `bigcode/humanevalpack` or pin to a known-good revision.
- **Sandbox sufficiency** (hardened 2026-06-13 audit): candidates still run with
  `RLIMIT_AS=1GB + SIGALRM`, but the model-generated-code sandbox in
  `self_improve_round.py` was hardened — each candidate now runs in its **own
  process group** (`start_new_session=True`, group-`killpg` on timeout so a
  fork-bomb can't survive the wall-clock alarm), in a **throwaway cwd**, with a
  **stripped environment** (an allowlist, so generated code no longer sees `HF_TOKEN`
  or other secrets), plus `RLIMIT_NPROC` (fork-bomb cap), `RLIMIT_FSIZE`
  (64 MiB single-file write cap), and `RLIMIT_CPU`. Still not a general-purpose
  sandbox — trust model remains "code from a model we just fine-tuned" — but the
  obvious fork-bomb / disk-abuse / secret-leak holes are closed.
- **Time budget**: a Quick round on a 7B with 4 candidates × 20 problems is
  ~80 generations + 80 sandboxed tests + a short LoRA + an eval pass. Order
  of 10–15 min on M-series. The UI does not currently estimate this — the user
  just sees the live counter.
- **Cancellation only kills the active subprocess**: if you Stop during the
  *training* phase of round N, the round will be abandoned mid-way. Already-
  written `round_N/dataset/` stays on disk for inspection; the SwiftData round
  record will show `endedAt == nil`. A future cleanup pass should garbage-collect
  these. **(2026-06-13 audit:** a user Stop now routes to a `.cancelled` terminal
  state instead of being reported as a failure, so a deliberate cancel no longer
  shows up as a red "failed" run.**)**

To smoke-test: pick a small model (Llama-3.2-1B or Qwen2.5-Coder-1.5B), seed
HumanEval, 2 rounds, 4 candidates, 12 problems per round. Should finish in
~5 minutes and produce a measurable baseline→R1→R2 pass-at-1 trend.

### Scored Test node ("Score it" / EvalService / EvalRun) — now verified live, moved to working

**Resolved — moved to working.** The earlier "implemented + build-verified; live UI
smoke in progress" status has been cleared: Main ran the "Score it" flow live in the
Test node end-to-end (standalone Debug `.app`, `qwen2.5-0.5b-instruct-mlx`, HumanEval,
Quick=20, base) — the report card rendered (**40%, 3 stars, "First score for this
model."**), an `EvalRun` + sidecar `evals/<uuid>/eval_run.json` persisted with matching
fields (`passAtK 0.40`, 8/20), logs were clean, and the engine was additionally
validated headless against the real 0.5B at k=1 (pass@1 0.375, 3/8) and k=2 (new
`passes`/`pass_at_k`/`k` fields emitted). See the "Scored Test node" bullet under the
working section and the newest Recent-session-log entry.

Remaining boundaries (not blocking the working status):

- **Score-delta path build-verified but NOT live-witnessed.** The ▲/▼ "vs your last
  try" comparison (`EvalService.previousAdapterEval`) needs two evals of the same base
  with different adapters; no small model with an adapter was available, so only the
  no-previous "first score for this model" branch was seen live.
- **Custom suites are importable via the Test node** ("Import suite…") as of the
  2026-06-13 loop; hand-dropping `evals/custom-<uuid>/eval.jsonl` still works. There's no
  in-app row editor — it's file import + discovery + delete. Built-ins (HumanEval / MBPP)
  remain the only auto-pulled suites.

### Code tab (agentic coding assistant) — agent loop verified end-to-end

The Code tab (`MLXServerService` + `OpenAIChatClient` + `AgentTools` +
`CodingAgentService` + `CodeView`) compiles clean and the **full loop is verified
end-to-end against real local models** via a faithful harness (`tools/agent_smoke.py`)
that mirrors the Swift loop exactly — server lifecycle, OpenAI tool protocol,
native + fallback parsing, sandboxed execution, result feedback, termination:

- **Qwen3.6-27B-bf16 (native `tool_calls`): PASS.** Warm-loaded in 5.3 s, then
  `read_file(greeting.py)` → `write_file(SUMMARY.md, …)` → correct plain-text
  finish; the written summary accurately described the file's behaviour. Confirms
  mlx-lm DOES populate native `tool_calls` for tool-template models.
- **Llama-3.2-1B-4bit (text fallback): plumbing PASS.** Exercised the `<tool_call>`
  fallback path end-to-end (the tiny model makes weak calls, but server + loop +
  sandbox all work). Surfaced + fixed a real gap: some models emit `"parameters"`
  instead of `"arguments"` — `parseFallbackCalls` now accepts both.
- **SSE streaming confirmed** against the live server (`data:` frames,
  `chat.completion.chunk`, `delta.content`, `[DONE]`) — matches the new
  `ChatStreamChunk` decoder.

Rounded out this pass: **live token streaming** (assistant text streams into the
transcript with a “Working…” indicator), a **context-growth guard** (`prunedWire()`
keeps system + recent history within a ~48 KB budget, snapped to a clean turn
boundary), and system-prompt hardening so weak models don't copy the tool-call
example path verbatim.

The harness is a Python mirror, not the Swift code itself, so the one remaining
manual check is hand-driving the SwiftUI UI (pick folder + agent → Start → type a
task). The Swift implementation shares the exact protocol the harness validated.

**2026-05-30 — full 5-role Orchestrator run verified IN-APP (gemma-4-26b-a4b-text +
fine-tuned adapter).** Drove "create a blazor project that list the top 10
cryptocurrencies" through the live Code tab. The whole team fired end-to-end:
Orchestrator → Planner (6-step plan via `todo_write`) → Researcher (`web_search`
+ `fetch_url` found the real CoinGecko `/coins/markets` endpoint) → Orchestrator
dispatched **Coder + UI in parallel** → builders wrote a complete ~20-file Blazor
project to disk (`Models/Coin.cs`, `Services/CryptoService.cs`,
`Components/CryptoTable.razor`, scaffolded `wwwroot/`, ran `dotnet` via
`run_command`) → Orchestrator returned a final summary, Plan 4/4 done. ~2.3 min
wall-clock. Two fixes were required to get here, both verified:

1. **Native tool-calling for reasoning models (gemma-4).** With native tools on,
   `TeamRole.systemPrompt(workspace:overview:nativeTools:)` now OMITS the
   `<tool_call>` text-format footer — gemma was *following* that example and
   emitting malformed text-format JSON with its special quote token `<|"|>`
   (`tool_calls: []`), so nothing dispatched after the Planner. Footer-less prompt
   → clean native `call_planner`/`call_coder`. Belt-and-suspenders:
   `AgentTools.sanitizeToolBlock` restores `<|"|>` → `"` before parsing.
2. **Transcript layout hang (the real "stops after the Planner" symptom).** A live
   `sample(1)` of the app caught the main thread pinned 100% in SwiftUI
   `StackLayout` re-measurement (`LazyVStack → placeChildren1 → sizeChildren… →
   resize → sizeThatFits`, plus `Array.motionVectors` from an animated scroll).
   Because `CodingAgentService` is `@MainActor`, that layout spin *starved the
   agent loop*, so the run couldn't continue — the server sat at 0% CPU while the
   app sat at 100%. Three fixes: (a) the transcript auto-scroll no longer wraps
   `proxy.scrollTo` in `withAnimation`; (b) the assistant/user bubble `Text` gets
   `.fixedSize(horizontal: false, vertical: true)` and only enables
   `.textSelection` once streaming ends; (c) `runRole` coalesces streaming deltas
   and flushes to the `@Observable` transcript at most ~12×/sec instead of
   per-token. After: app CPU stays 0–40% with brief spikes that resolve instantly;
   server does the work; both settle to 0% at completion.

Deferred-for-now (intentional, not bugs):

- **Permission model is minimal.** Two auto-approve toggles (`autoApproveEdits`,
  `autoRunCommands`) plus per-action Allow/Deny. No tiered allowlist (e.g. "always
  allow `git status`") yet.
- **Context handling is a budget trim, not summarization.** `prunedWire()` drops
  the oldest turns past the budget rather than summarizing them — fine for most
  sessions; a summarizing compactor is a future enhancement.

### Agent skills (`SkillStore` / `use_skill`) — now LIVE and verified

**Resolved — moved to working.** The `SkillStore` / `SkillsManagerView` /
`use_skill` code (originally built for the removed single-agent library and long
marked dead) has been **revived as Agent Skills** and wired into the live
`TeamRole` team — `SKILL.md` packages, 3-stage progressive disclosure, **raw-markdown
CRUD**, **team-global by default with optional per-agent scoping** and **skill↔skill /
skill↔agent linking**, two seeded example skills, gated by `AgentSettings.useSkills`.
**BUILD-GREEN + headless tests against the real `SkillStore` + live in-app UI.** See
the "Agent Skills" bullet under the Code-tab working section and the newest
Recent-session-log entry.

The single-agent *profile* library it was originally part of —
[`AgentProfile`](../LLMPro/Models/AgentProfile.swift) — remains **dead
code** (compiles, unreferenced; `AgentProfile` stays in the SwiftData schema only).
`AgentEditorView` and the dead `AgentTemplate.swift` were **deleted**. The old per-agent `AgentProfile.enabledSkillIDs`
model is **superseded** — per-agent scoping now lives in the agent's `skills:`
frontmatter, not a UI toggle list.

### Sample-size stepper on the catalog prepare row

Works for adjusting `max_rows` per preset before tapping Prepare. But it
doesn't surface for the `Browse HuggingFace` path — there's a single max-rows
in the search sheet's options form but no per-result preview of what's reasonable.

### GGUF→MLX importer does not reconstruct a chat template — RESOLVED

**Fixed — moved to working** (the spun-off task is done). `gguf_to_mlx.py` now writes
a **per-architecture default** chat template when the GGUF carries none in its
`tokenizer.ggml.chat_template` metadata (ChatML for qwen2/qwen2moe/qwen3, Gemma turn
format, Llama-3 headers, Phi-3, Mistral), so a converted INSTRUCT model whose GGUF
lacked that metadata now chats out of the box instead of failing with
"tokenizer.chat_template is not set". Metadata-present conversions are unchanged; the
`done` event gained `chat_template_source` (`metadata` | `fallback-<arch>` | `none`).
See the "GGUF→MLX chat-template fallback" bullet under the working section, the
`gguf_to_mlx.py` contract in
[`CONTRACTS.md`](CONTRACTS.md#gguf_to_mlxpy--gguf--mlx-import-chat-template-fallback),
and the Recent-session-log entry.

---

## Known numerical issues

### Magicoder-Evol-Instruct + Qwen3.6-27B → NaN loss

Documented in detail in this session: training Qwen3.6-27B (original or
stripped, doesn't matter) on Magicoder-Evol-Instruct-110K produces NaN losses
after ~7 iters. The same model trains cleanly on CodeAlpaca.

Probable cause: some Magicoder-Evol rows tokenize to extremely long sequences
which, after `max_seq_length` truncation, trigger an overflow in bf16
gradient computation when the prompt-mask + completion loss interact poorly.

**Workaround**: pair Qwen3.6-27B with CodeAlpaca or Magicoder-OSS rather than
Magicoder-Evol. If we want a permanent fix in the app, we could:
- Pre-truncate dataset rows at `max_seq_length / 2` before passing to mlx-lm
- Add a `prompt_truncation_warning` in the Teach UI when picking that
  model+dataset combo
- Report upstream as an mlx-lm bug

### Per-model size readout is sometimes wrong for HF-cached models

`ModelRegistry.inspectGenericModelDir` uses `lstat` on the `blobs/` directory.
This works for snapshot_download layout but the `hf/hub/...` (mlx-lm's loader)
layout has nested symlinks and the size readout has been seen wrong (showed
"26.9 MB" for a 28 GB model). For the same model in the snapshot_download
layout, size was correct.

Mitigation: prefer reading sizes from the top-level cache; if needed, dedupe
across both layouts in `scan()` (currently does dedupe by repoID but the size
comes from whichever layout was inspected last).

---

## Open design questions

Things we should think about before adding to:

### How should we handle multi-base-model training in the Arena view?

Currently the Arena shows the SAME model in both panes with `--adapter-path`
toggled on the right. Some users will want to compare against a different base
entirely. The state machine for two independent models + their own adapters
would need work.

### Should there be a "model pinning" / pre-load step?

Loading a 27B model takes 60-90 seconds. Doing this every time the user clicks
Send in the Arena is slow. A "pin this model in memory" step would help, but
requires a long-running inference daemon.

**Addressed (for the Code tab) by `MLXServerService`.** The coding agent now runs
`python -m mlx_lm server` as a persistent daemon — the model loads once and is
reused for every turn. The Arena still uses the per-turn `mlx_lm generate`
cold-load. If we want pinning in the Arena too, the same server service could back
it; the open question is now just whether to extend it there.

### How do we handle storage pressure?

We have no quota or auto-cleanup. A user can easily fill a 1 TB disk with 5-6
huge models. Should we:
- Add a "low disk warning" banner?
- Auto-delete least-recently-used adapters?
- Move large models to `~/.cache/huggingface` and symlink (so user can clean
  via standard HF tools)?

### Should we ship `uv` in the bundle?

Currently `PythonRuntime.resolveUV()` falls back through several paths. For
shareability we should ship a static `uv` in `Resources/`. This needs code
signing handling — the binary must be signed as part of the app bundle.

---

## Notarization todos

For shipping to anyone other than ourselves, the app needs:

1. **Code signing with a Developer ID**. Currently ad-hoc signed.
2. **Hardened-runtime entitlements** are already correctly declared:
   - `com.apple.security.cs.allow-jit` (MLX uses Metal JIT)
   - `com.apple.security.cs.allow-unsigned-executable-memory`
   - `com.apple.security.cs.disable-library-validation` (for the bundled Python)
   - `com.apple.security.cs.allow-dyld-environment-variables` (HF_HOME et al)
3. **Sign the bundled `uv` binary** if we ship one — it lives in `Resources/`
   and macOS won't trust it without a signature.
4. **Notarize the app** via `notarytool` — requires an Apple Developer account.
5. **Test in a fresh user account** before claiming notarization passed.

Apple's notary historically trips on Python-bundling apps. Budget time for
back-and-forth on the first submission. Document any caveats here once done.

---

## Tests

There is now a **53-test XCTest suite** (7 files) in `Tests/LLMProTests/` (the
`LLMProTests` XcodeGen target). `xcodebuild … test` → **TEST SUCCEEDED**. All
pure-logic, no model loads or subprocesses (the `ProcessRunner` tests spawn tiny deterministic
`/bin/sh -c` commands — `echo`/`seq`/`sleep`/`exit` — not model runs). Run with:

```bash
xcodebuild -project LLMPro.xcodeproj -scheme LLMPro \
           -destination 'platform=macOS' test
```

Current coverage:

| File | What it tests |
|---|---|
| [`LogStreamParserTests.swift`](../Tests/LLMProTests/LogStreamParserTests.swift) | `LogStreamParser` regexes against real mlx-lm train / eval / DPO stdout lines (and that noise lines don't match) |
| [`DatasetServiceClassifyTests.swift`](../Tests/LLMProTests/DatasetServiceClassifyTests.swift) | `DatasetService.classify` across the source schemas, including the `preference`-before-`completions` vote |
| [`AutoTunerTests.swift`](../Tests/LLMProTests/AutoTunerTests.swift) | `AutoTuner.categorize` size buckets (incl. the no-marker → `.medium` fallback + the explicit sub-2B → `.tiny` branch) + every `(size, duration)` bucket produces a positive, monotonic config (guards against a bucket regressing to zero iters/batch) |
| [`FuseServiceTemplateTests.swift`](../Tests/LLMProTests/FuseServiceTemplateTests.swift) | `FuseService.OllamaChatTemplate` per-architecture suggestions |
| [`ModelRegistryTests.swift`](../Tests/LLMProTests/ModelRegistryTests.swift) | `ModelRegistry` size-preference / argument-order tie-breaking |
| [`SelfImproveMergeTests.swift`](../Tests/LLMProTests/SelfImproveMergeTests.swift) | `SelfImproveService.mergeAndSplitKeepers` — cumulative-keeper dedup (latest round wins), deterministic + non-empty splits, empty/malformed-line handling |
| [`ProcessRunnerTests.swift`](../Tests/LLMProTests/ProcessRunnerTests.swift) | `ProcessRunner` streaming/capture: all lines including the **unterminated final line** (the EOF-tail fix), non-zero-exit code+stderr surfacing, both streams terminating on exit, and a **cancelled consumer reaping the child** (the orphan-subprocess fix) |

The stale empty `Tests/MLXStudioTests/` folder was removed.

**Former pinned discrepancy — now FIXED (2026-06-13 audit).** `AutoTuner.categorize`
previously contradicted its own doc comment: it claimed to "fall back to `.medium`
if no marker is found," but the patterns table ended with `(0.0, .tiny)` and
`maxBillion` was 0 for a markerless name, so `maxBillion >= 0.0` always returned
`.tiny` first — making the documented `return .medium` dead code. The audit removed
the `(0.0, .tiny)` tuple and added an explicit `0 < maxBillion < 2 → .tiny` branch,
so a markerless name (a custom-renamed model with no size in its name) now correctly
falls through to the safer `.medium` default while a genuine sub-2B marker still maps
to `.tiny`. The test was renamed `testCategorizeNoMarkerFallsBackToMedium` and a
`testCategorizeSmallMarkerStillTiny` was added to pin both branches.

Good next test targets: `DatasetEditorService.parseRow` (each source row shape
auto-promotes to chat) and `HuggingFaceClient` decode against recorded JSON responses.

---

## Audit — deferred items (known / not regressions)

The 2026-06-13 full code audit (see the Recent-session-log entry) landed the
correctness/safety fixes in three commits. These items were **surfaced by the same
audit but intentionally NOT fixed** — each needs a product/security decision or is
lower-priority. Listed so the next agent doesn't re-discover them as "new":

**RESOLVED in wave 3 (`acec4a8`) — the user approved these hardenings:**

- ✅ **Code-agent command/edit auto-run now defaults to OFF.** `AgentSettings`
  `autoApproveEdits`/`autoRunCommands` both default `false` (edits + shell commands go
  through the approval gate); the UI toggles still let the user opt in per session.
  **`run_command`'s `/bin/zsh -lc` child env is now secret-scrubbed** — inherited vars
  matching a secret denylist (TOKEN/SECRET/PASSWORD/API_KEY/_KEY/CREDENTIAL +
  HF_TOKEN/AWS_/OPENAI/ANTHROPIC/GH_TOKEN/…) are blanked; PATH/HOME/etc. kept.
- ✅ **`fetch_url` now has an SSRF guard** (`validatePublicURL`/`isBlockedSSRFTarget`):
  rejects non-http(s) + `localhost`, resolves the host via `getaddrinfo`, and blocks if
  ANY resolved address (DNS-rebinding defense) is loopback/link-local (incl.
  169.254.169.254)/private/ULA/unspecified/multicast. Fails closed; the DDG redirect
  target is filtered through the same check.
- ✅ **Delegation now has a breadth/total cap.** Per-task budget of 40 total spawns
  (reset each top-level turn) + a cycle guard (A→B→A short-circuits via the ancestor
  chain), both feeding a message back to the model instead of spawning. Depth cap (6) kept.

**Still deferred — needs a decision or lower priority:**

- **Restored Code workspace may need a security-scoped bookmark.** The Code tab
  re-opens its last workspace folder on launch; verify whether the app's sandbox
  status actually grants read/write to that path on restore (a security-scoped
  bookmark may be required), or whether the restore silently fails outside the
  app-support tree.
- **DatasetEditor silently drops non-text structured chat content.** The chat-row
  editor only round-trips plain-text message content; structured/multi-part content
  (e.g. tool blocks, image parts) is dropped on load→save rather than preserved or
  flagged.

**LOW priority (cosmetic / robustness, no current bug observed):**

- **FuseService Modelfile path quoting** — the generated Ollama `Modelfile` `FROM
  <gguf-path>` line isn't quoted; a path with spaces could break `ollama create`.
- **InferenceService system prompt not using the chat-template slot** — the Arena
  passes `--system-prompt` rather than routing the system message through the model's
  chat-template system slot, so some models may not honor it as intended.
- **ModelsBrowser handoff is timing-based (0.15s).** The "use this model" handoff
  relies on a 0.15s delay rather than an explicit ready signal — works in practice but
  is fragile.
- **`diffusion_server.py` non-stream `done.wait()` has no timeout** — a wedged
  diffusion worker thread could block a non-streaming request indefinitely (the
  streaming path is fine).

---

## Things deliberately out of scope (and why)

See [`CONVENTIONS.md#things-we-considered-and-rejected`](CONVENTIONS.md#things-we-considered-and-rejected)
for the full reasoning. Quick reference:

- **App Store distribution** — would require Sandboxing, which fundamentally
  conflicts with our subprocess + file model. Not doing this right now.
- **Backwards-compatible SwiftData migrations** — additive-only for now.
- **A logging framework** — ~~small app, plain `print` is fine~~ **REVERSED
  2026-05-31**: added first-party [`Core/Log.swift`](../LLMPro/Core/Log.swift)
  (os.Logger + rotating file `logs/llmpro.log` + crash/signal breadcrumb), no
  third-party dep. See the Recent-session-log entry and CONVENTIONS.md.
- **Telemetry / analytics** — privacy-first; user-runs-on-device app.

---

## Recent session log

Most-recently-resolved items at top. Maintain this section when you complete
work that another agent might be looking for context on.

- **Session 2026-07-19 (cont.) — Single-file SDXL/SD support + "what my installed models support" overview.**
  **Single-file checkpoints** (A1111/LDM `.safetensors`, e.g. the user's `WAI-NSFW-illustrious-SDXL`
  with v9/v12/v14) now work in Imagine. `sdxl_generate.py` gained `--convert-cache`: a single-file
  `--model` is converted **once** to a diffusers dir via `diffusers.StableDiffusionXLPipeline`/
  `StableDiffusionPipeline.from_single_file(...).save_pretrained(...)` (cached under
  `imagegen/converted/<repo#file>/`), then loaded by the existing MLX engine. Needed a vendor patch:
  `model_io.load_tokenizer` now falls back to the combined `tokenizer.json` (diffusers `save_pretrained`
  writes that, not the split `vocab.json`+`merges.txt` the fabled-illusion model happened to ship).
  Added `diffusers`+`omegaconf` to `installImageGen` (torch/transformers already present). Swift:
  `ImageModel.checkpointFile` (id = `repo#file`) makes each checkpoint independently selectable;
  `downloadedNonPresetImageModels()` now also detects single-file SDXL/SD by reading the safetensors
  **header** (`model.diffusion_model.` ⇒ diffusion; `conditioner.embedders.1` ⇒ SDXL vs SD), skipping
  any repo with a `config.json` (LLMs). The scan reads headers so it's cached in `@State` (scanned
  off-thread on appear) instead of per-render; `downloadedNonPresetImageModels()`/`isRepoCached` are
  now `nonisolated static`. `generate(checkpointFile:)` passes the `.safetensors` + `--convert-cache`.
  **Capability overview (Models tab):** each LLM row now shows a "Chat · Fine-tune · Try it out · Code ·
  Story · Practice" line (DiffusionGemma: "Chat · Code — not fine-tunable"); a new **"Image models (N)"**
  section (`ImageModelRow`, fed by `ImageGenService.downloadedImageModels()`) lists downloaded FLUX/SDXL/SD
  models with "Imagine · Story illustrations" — so every installed model is visible with what it supports,
  and image models no longer silently "disappear" from the Models tab. Also fixed: `classifyDiffusers`
  now requires actual weights (`dirHasWeights`), so the **config-only** `stabilityai/stable-diffusion-xl-base-1.0`
  copy that `from_single_file` fetches into the cache is no longer offered as a broken model.
  **Live-verified in the app:** all three WAI single-file checkpoints (v9/v12/v14) show as "SDXL
  (Illustrious) · anime · single-file" in the Imagine picker AND the Models-tab "Image models" section;
  selecting v14 converted it (once, → `imagegen/converted/…#…v14.safetensors`, 6.5 GB) and generated a
  coherent 1344×768 kimono/cherry-blossom anime image; Local models show the capability line; config-only
  sdxl-base is filtered out. mlx-lm/mflux/diffusers all import after the safetensors 0.7→0.8 bump. Zero
  ERROR/FAULT, no crash.

- **Session 2026-07-19 (cont.) — SDXL / Stable Diffusion support (second image engine) + image-gen capability in Models tab.**
  Added a **second local image engine** so the user's downloaded **SDXL** (and SD 1.5/2.x)
  models generate in Imagine, alongside FLUX (mflux). Engine = a **vendored copy of Apple's
  mlx-examples `stable_diffusion`** package at `Resources/helpers/sdxl_vendor/` (MIT), driven by a
  new `sdxl_generate.py` helper (same JSON-event protocol as `generate_image.py`). Two local
  patches (search `LLMPro:` in the vendor): `model_io.py` loads weights from a **local diffusers
  dir** (not just a hardcoded HF repo) with a filename-variant fallback + `is_sdxl()` auto-detect;
  `__init__.py` derives SDXL `add_time_ids` from the real latent size (upstream hardcodes 512 →
  bad 1024² framing). The vendored VAE already runs fp32 (sidesteps the SDXL fp16→black-image bug).
  **No new pip deps** — mlx/numpy/Pillow/regex/huggingface_hub are already in the venv;
  `installImageGen` now also lists pillow+regex and is described as "FLUX + Stable Diffusion".
  **Swift routing:** `ImageModelFamily` (flux/sdxl/sd) → `ImageGenService.generate(family:…)`
  routes FLUX→`generate_image.py`, SDXL/SD→`sdxl_generate.py` (with `--cfg`/`--negative`, and the
  model resolved to its local snapshot dir via `snapshotDir(for:)`). `SDXLVariant` picks
  step/CFG/negative defaults by name (base 28/6, Illustrious 26/5, Pony 25/7, Turbo/Lightning/Hyper
  4-6/≈0/no-neg). `downloadedNonPresetImageModels()` now classifies family via
  `classifyDiffusers()` (model_index `_class_name` + `unet/`+`text_encoder_2/` markers) and includes
  SDXL/SD, so the Imagine picker's "On your Mac" lists them. Imagine snaps SDXL to ~1 MP buckets
  (`sdxlBucket`). **Models tab (pre-download):** `HFModel.imageKind` (flux/sdxl/sd/imageOther/video)
  + `canGenerateImages` drive a capability **badge** on search cards ("SDXL image · Imagine") and a
  **banner** in the detail sheet ("download → use in Imagine" / "video · can't run"); the
  convert-to-LLM row is hidden for image models. **VALIDATED:** `sdxl_generate.py` ran standalone
  on the user's real `John6666/fabled-illusion-…-sdxl` (diffusers SDXL, 6.5 GB) → coherent, on-prompt
  1024² image (not black). Single-file SDXL (`WAI-…-SDXL` .safetensors) is **not yet supported**
  (needs a diffusers conversion step) — the scan skips it (no diffusers dir). **Live-verified in the
  app:** the fabled-illusion SDXL appears in the Imagine picker's "On your Mac" and generated a
  coherent Japanese-garden image at the 1344×768 SDXL bucket (family-aware sizing); Models-tab
  search shows "SDXL image · Imagine" on every Juggernaut-XL diffusers result and "image/video ·
  can't run here" on the GGUF one; the detail sheet shows the "SDXL image model — generate in
  Imagine" banner and (new) hides Teach/Chat for image models. Zero ERROR/FAULT, no crash.

- **Session 2026-07-19 (cont.) — Imagine: picker shows your downloaded image models.**
  Reworked the Imagine model menu into two sections — **"On your Mac"** (image models
  already in the HF cache) and **"Download & use"** (presets not yet fetched) — so the picker
  reflects what's actually downloaded and picks a local model over re-fetching. Added
  `ImageGenService.downloadedNonPresetImageModels()`, which scans the HF cache for a diffusers
  layout (`model_index.json` / a `transformer/` folder) **and** confirms the family is FLUX
  (repo name or the pipeline class in `model_index.json` mentions "flux"), so a user's *own*
  downloaded FLUX model is selectable too. It deliberately skips both chat LLMs (no diffusers
  layout) **and** non-FLUX image models like SDXL/SD — mflux only runs FLUX, so offering an SDXL
  model would just fail at generate time (verified live: the scan first surfaced a downloaded
  `…-sdxl` model, which the FLUX filter now correctly hides). Context: the user's 6 "Local
  models" are all **language** models (gemma2/qwen3_moe/mistral/stablelm/llama) and **cannot**
  generate images — image gen requires a diffusion model, which is why the Imagine picker is a
  separate, image-only list. `modelButton` renders each row with a checkmark on the current pick
  + the size/quality note.

- **Session 2026-07-19 (cont.) — Imagine: model picker + richer sizes.**
  Added an **image-model picker** (`ImageModel.presets`: FLUX.1 schnell 4-bit/8-bit + FLUX.1
  dev 4-bit/8-bit — all ungated mflux mirrors, no token) with a per-model "downloaded?" hint
  (`ImageGenService.isModelDownloaded`); `generate` gained `model:`/`baseModel:` params (dev
  uses ~20 steps vs schnell's 4). And **flexible sizes** — an aspect (Square/Landscape/Portrait/
  Wide/Tall) × resolution (Small 768 / Standard 1024 / Large 1280) picker, computed to a
  multiple of 16 (the long edge = resolution). Model + aspect + resolution persist via
  `@AppStorage`. **Verified live:** the model submenu shows all 4 with ✓/⤓ indicators and
  persists the choice; Wide (16:9) generated a **1024×576** panorama (confirmed in gallery.json),
  no errors.

- **Session 2026-07-19 — Imagine tab (free-form local text-to-image).**
  New `.imagine` sidebar tab (between Code and Practice) so the app now has Chat / Story /
  Code / **Imagine** creative surfaces. Prompt → pick size (Square/Portrait/Landscape) +
  count (1–4) → Generate, using the **same FLUX engine** (`ImageGenService`) that draws Story
  illustrations — a dedicated image model, independent of the chat LLM. Results persist in a
  gallery ([`ImagineStore`](../LLMPro/Services/ImagineStore.swift) → `imagegen/gallery.json` +
  `imagegen/<uuid>.png`); tap for a full-size preview (dims + seed + Save/Copy/Delete), context
  menu for "Use this prompt" / "Make another like this". Cancellation-aware; an install gate
  offers the one-time `mflux` install when absent. New: `Features/Imagine/ImagineView.swift`,
  `Services/ImagineStore.swift`, `PathResolver.imagesDir`, RootView `.imagine` case.
  **Verified live:** generated "a red panda astronaut floating in space…" (1024², seed shown) →
  rendered a coherent on-prompt image, appeared in the gallery, preview sheet works, persisted;
  no errors, no crash.

- **Session 2026-07-18 (cont.) — GGUF "Download & convert" combo (one-tap GGUF LLM → usable MLX).**
  Follow-up to the GGUF-labeling work: a **GGUF language-model** search result now shows a
  **"Download & convert"** button that, in one tap, downloads only the **Q8_0** quant (~8 GB,
  not the whole 82 GB repo), converts it to an MLX model, and adds it to Local models —
  reusing `GGUFImportService`'s existing `downloadFromHuggingFace` (single-file) + `precheck`
  + `convert` (auto-optimize/rescan). New: `GGUFImportService.downloadAndConvert(repo:)` +
  `bestConvertibleFile(repo:)` (prefers Q8_0 → Q4_0 → F16; throws if the repo only has
  k-quants/i-quants). `HFModel.isImageOrVideo`/`isConvertibleGGUF` gate the button — a GGUF
  **image/video** repo (FLUX/WAN) shows the info button instead (no LLM to convert). Progress
  shows in a banner atop the Models list (download → convert stage); the card shows
  "Converting…". **Convertibility pre-check:** `bestConvertibleFile` / `convertibleFile`
  EXCLUDE **i-matrix** files (`i1-*`) — an "i1-Q4_0" isn't pure Q4_0 (it keeps the output layer
  in a k-quant like **Q6_K**, which MLX can't read), so picking it by filename downloaded a file
  that then failed at precheck. Now after a search each GGUF LLM is checked via
  `HuggingFaceClient.detailWithSizes` (`GGUFConvertState`), and the card shows **"Download &
  convert" only when a pure Q8_0/Q4_0/F16 exists** (with that file's real size, e.g. "Q8_0 → MLX ·
  9.83 GB"); an i1/k-quant-only repo shows **"GGUF · no MLX-convertible quant"** + an info button.
  **Verified live:** (1) TinyLlama-1.1B static GGUF → download `…Q8_0.gguf` → convert → Local
  models `llama · 8bit · 1.24 GB`; (2) `Dirty-Muse-…-i1-GGUF` correctly shows "no MLX-convertible
  quant" while the sibling static `…-GGUF` (Q8_0) offers "Download & convert · 9.83 GB". No errors.

- **Session 2026-07-18 (cont.) — "downloaded models don't show up" = GGUF, + List-layout bug + disk cleanup.**
  A user reported downloads "most of the time don't show up in my models." Root cause:
  they were downloading **GGUF** repos (and image/video models like WAN/FLUX). `ModelRegistry.scan`
  only detects **MLX** models (`config.json` + `.safetensors`); a raw GGUF download lands in
  the HF cache **invisibly**, and downloading a whole multi-hundred-GB GGUF repo can never
  produce a usable model. Fix: `HFModel.isGGUF`/`isMLXReady` (from the `gguf`/`mlx` tags,
  library, or repo name); search-result cards show a **"⚠ GGUF · needs conversion"** chip and
  an amber **"GGUF"** button that opens the details sheet instead of a one-click download; the
  sheet shows a banner explaining GGUF must be converted via **Import GGUF** (Q4_0/Q8_0 LLMs
  only; image/video GGUF can't run) + a de-emphasized "Download raw files anyway". The
  `mlx_lm convert` row is hidden for GGUF (it can't read GGUF).
  **Also fixed a real `List` bug:** the revamped results section rendered **zero-height** until
  the user scrolled (SwiftUI `List` doesn't lay out a few dynamically-loaded rows initially).
  Converted `ModelsBrowserView`'s content from `List` to **`ScrollView` + `LazyVStack`** (all
  local-model wiring — context menu, alert/sheet modifiers — preserved); results now render
  immediately. **Disk:** the user's drive was **99% full (144 MiB free)** — 1.41 TB of mostly
  unusable GGUF/image/video models — which also broke the build (codesign). Freed **131 GB** by
  deleting 37 interrupted `.incomplete` partials (user-approved). Verified live: GGUF searches
  render instantly with the chip/button/banner; zero ERROR/FAULT, no crash.

- **Session 2026-07-18 (cont.) — Model-download UX revamp + size-display bug fix.**
  The Models tab's search/download UI was a flat list with a jarring solid-purple
  selection block, no model size anywhere, an ISO-timestamp, and a tag-soup detail
  panel (`region:us`, `base_model:finetune:…`, `license:other`). Rebuilt the download
  experience in [`ModelsBrowserView.swift`](../LLMPro/Features/Models/ModelsBrowserView.swift):
  search results are now **cards** (`ModelResultCard`) showing the model's **download
  size** (async-fetched) + download count + a **RAM-fit warning** when a model is too
  big, with a **stateful action button** (Download → Downloading % → ✓ Installed);
  in-flight downloads render as **`DownloadProgressCard`** ("1.2 GB of 5.4 GB" + bar);
  and the old inline panel became a clean **`ModelDetailSheet`** ([ModelDetailView.swift](../LLMPro/Features/Models/ModelDetailView.swift))
  — humanized "Updated Sep 2024", a prominent size + fit verdict ("✓ Runs on your Mac
  (128 GB)"), curated tags (HF bookkeeping like `region:`/`base_model:`/`arxiv:` filtered
  out), and Download/Teach/Chat CTAs. **Root-cause bug fixed:** `HuggingFaceClient.resolveTotalSize`
  hit `/api/models/{id}` which returns siblings **without** file sizes → every size summed
  to 0 (the old detail panel's size line silently never showed either). Now passes
  **`?blobs=true`**. `ModelFit` gained `fits(weightBytes:)` + `physicalRAM` for the card/sheet
  fit chips. **Verified live:** searched Qwen2 → cards show 285 MB / 1.74 GB / 8.32 GB etc.;
  downloaded the 0.5B (card flipped Download → ✓ Installed); details sheet renders clean.
  Release build clean, installed, zero ERROR/FAULT, no `.ips`.

- **Session 2026-07-18 (cont.) — RAM pre-flight guard (oversized models fail fast, not "code 9").**
  A user picked **Venus-120b-v1.2** (a 120B frankenmerge, **fp16, 240 GB on disk**) on a
  **128 GB** Mac; story generation died with the cryptic **`mlx_lm.generate exited with
  code 9`**. Root cause: the OS OOM-killer (SIGKILL) — a 240 GB model can't fit in 128 GB
  of unified memory, and it can't be shrunk locally either (the in-app quantizer / `mlx_lm
  convert` must load the full fp16 model into RAM first → same OOM). New
  [`Core/ModelFit.swift`](../LLMPro/Core/ModelFit.swift): `tooLargeError` sums a local
  model's `*.safetensors` bytes vs 85% of `physicalMemory` and returns a plain-language
  message; `exitMessage` maps a SIGKILL exit (9/137) to "ran out of memory". Wired into
  `InferenceService.stream` + `MLXServerService.start` (pre-flight before spawn + in the
  exit handlers). **Verified live in the app:** selecting Venus + "Write opening chapter"
  now shows *"This model's weights are 240.63 GB — too large for this Mac's 128 GB of
  memory. Pick a smaller model or a 4-bit version…"* **instantly** (no 30 s load, no crash,
  one clean ERROR log line). Note for future: there is **no MLX-runnable Venus-120b** —
  every HF GGUF is a k-quant/i-quant (Q2_K, IQ1–3, Q4_K…) and `gguf_to_mlx.py` (MLX's
  native loader) only reads Q4_0/Q4_1/Q8_0/F16, so the GGUF→MLX import path is a dead end
  for it; a fitting model (or a shard-by-shard streaming quantizer, not yet built) is the
  only way to run a 120B here.

- **Session 2026-07-18 — Story illustrations (local themed AI images per chapter).**
  Story tab can now insert **local** AI illustrations into chapters. New settings:
  **Illustrations per chapter (0–4)** + a freeform **Art style** kept identical on
  every image so a story's illustrations stay visually consistent. After each chapter
  is written (or via a per-chapter **Illustrate/Redraw** menu action), the LLM extracts
  N visual scenes, the frozen art-style is prepended, deterministic seeds are assigned
  (per-story base seed from the UUID + chapter offset + image index), and all N render
  in **one** `generate_image.py` (mflux / FLUX.1-schnell) batch so the ~12B model loads
  once per chapter. Images show inline in the chapter card (per-image Save / Show in
  Finder / Remove); Markdown export copies them into a sibling `<stem>_images/` folder
  with `![](…)` links. New: `ImageGenService`, `generate_image.py`, `StoryIllustration`
  + `illustrationsPerChapter`/`artStyle` on `StoryProject` (tolerant decoders),
  `PathResolver.storyImagesDir`, `PythonRuntime.installImageGen`/`imageGenInstalled`.
  **mflux is an optional on-demand add-on** (`uv pip install mflux==0.18.0`, gated in
  Story settings); the pin is safe — a `uv pip install --dry-run` confirmed it adds 27
  packages and changes **zero** core ML packages (transformers 5.9 / torch 2.12 /
  hf-hub 1.16 / numpy 2.4 / mlx 0.31 already satisfy its ranges). **Caught during
  build:** the 0.18.0 API differs from earlier mflux — `Flux1(model_config=…,
  quantize=)` (NO `model_name=`), `generate_image(seed, prompt, num_inference_steps=,
  width=, height=)` (NOT a `Config` object), `save(path=, export_json_metadata=,
  overwrite=)` (NOT `export_metadata=`) — verified against the 0.18.0 sdist and fixed
  before it shipped. **Adversarial review (24-agent workflow) → 9 confirmed findings
  fixed:** (HIGH) redraw/revise no longer deletes existing illustrations unless the new
  batch produced images (was a delete-before-confirm data-loss bug) + surfaces a
  non-fatal error on failure; (MED) `ImageGenService.generate` is now cancellation-aware
  — Stop terminates the FLUX subprocess instead of leaking it, and orphaned PNGs from a
  superseded batch are deleted; (MED) scene parser prefers enumerated lines so a model
  preamble isn't taken as scene #1; (LOW) manual Illustrate now reports a missing image
  model; (LOW) the image-progress bar is scoped to the active generator.
  **GATED-MODEL BLOCKER caught by a live run (only surfaces on a real download):**
  `black-forest-labs/FLUX.1-schnell` is `gated: auto` → an unauthenticated download
  **401s**, breaking zero-setup use. Fixed by defaulting to the **ungated** pre-quantized
  mirror **`dhairyashil/FLUX.1-schnell-mflux-4bit`** (`ImageGenService.defaultModel`,
  ~9.6 GB, loads with **no token**, `quantize=None` since it's pre-quantized); the helper
  now treats a `--model` with `/` as an HF repo + takes `--base-model`; `ImageGenService`
  also passes `HF_TOKEN` (Keychain) when present as a fallback for gated models.
  **VERIFIED LIVE end-to-end in the running app** (2026-07-18): downloaded Llama-3.2-1B,
  wrote a story chapter (streams + completes, no errors); the illustration gallery,
  per-image context menu, and settings/install-gate ("Image model ready") all render;
  a real **Redraw** downloaded the 9.6 GB mirror (no token) and generated **2 coherent,
  on-theme watercolor illustrations** that replaced the placeholders and displayed in
  the chapter card. Debug + Release build clean (Swift 6, zero warnings), installed to
  /Applications, zero ERROR/FAULT across the whole run, no `.ips`.

- **Session 2026-07-01 (cont.) — hide reasoning `<think>` blocks; Story Mode.**
  **Think-block hiding:** reasoning models (Qwen3/DeepSeek-R1) emit `<think>…</think>`
  before the answer (some templates emit only the closing `</think>`). New
  `Core/ReasoningStripper.visible(_:streaming:)` removes it: complete pairs anywhere,
  a lone trailing close (keep only what follows the last `</think>`), and — when
  `streaming` — an unclosed opening tag (hide reasoning-in-progress so it doesn't
  flash). Applied at the shared render layer (`MessageContentView`, `streaming:true`
  — covers Chat, Story, arena live streaming) AND stripped from stored text on
  completion in `ChatSession` (chat history/export/context) and `StoryGenerator`
  (chapter prose, summaries, outline) so reasoning never pollutes summaries, rolling
  context, or exports. Verified against 8 edge cases. The Inspect → "Watch it think"
  tab is unaffected (separate reasoning channel — deliberately shows CoT).
  **Story Mode** (the tab this session added — see the entry below) was live when
  its adversarial-review workflow was interrupted by a session exit; re-run pending.

- **Session 2026-07-01 (cont.) — Story Mode tab (long-form chaptered writing).**
  New `.story` sidebar tab: write a premise, pick a model, generate a story
  chapter-by-chapter (rolling per-chapter summaries keep 15+ chapters coherent
  without blowing the context window), revise any chapter, auto-write to a target
  count, plan an outline, export to Markdown. Saved projects. `StoryStore` +
  `StoryGenerator` (self-persists to the store — no View-capturing closure) +
  `StoryView`/`StoryMarkdownExporter`. No content filter — latitude is the chosen
  model + the user's freeform style text. Build clean; installed.
  **Adversarial review (28 agents, 19 confirmed / 4 rejected) → applied 18:**
  - **Delete-during-generation resurrected the story** (HIGH): a superseded generator
    task's late `save()` re-added the just-deleted project (list + JSON). Fixed at the
    store: `StoryStore.update` is now non-resurrecting (no-ops for an unknown id).
  - **Continuity was broken** (HIGH): the empty stub chapter was appended BEFORE building
    the prompt, so `storySoFar()` fed an empty "previous chapter" tail. Now the prompt is
    built first.
  - **Rename reverted** (HIGH): renaming the open story was overwritten by the generator's
    stale title on the next save — now synced.
  - Auto-write no longer counts a truncated/errored chapter as done (streamText reports
    success); outline restore-on-stop; style edits persist on focus-loss; forward-compat
    tolerant `StoryProject.init(from:)`; chapters renumber after a delete (no duplicate
    "Chapter N"); summaries cover the whole chapter (head+tail if long); **maxTokens now
    reserves budget for a reasoning model's hidden think tokens** (was truncating chapters
    to empty); chapter delete confirms; discardIfEmpty keeps style/genre/outline work;
    revise sees other chapters' summaries; LazyVStack chapter list; edit re-summarizes;
    streaming follow-scroll. Deferred (LOW): app-lifetime generator ownership so a long
    auto-write survives a tab switch (same view-scoped tradeoff as the Chat tab). Build clean.

- **Session 2026-07-01 (cont.) — new dedicated Chat tab (saved conversations).**
  Added a `.chatDirect` sidebar tab **"Chat"** (icon `message`, before "Try it out")
  for casual single-model conversation with persistent history — distinct from the
  arena/eval-heavy "Try it out". New: `ConversationStore` (one `conversations/<uuid>.json`
  per chat) + `ChatConversationView` (left rail of saved chats: new/rename/delete;
  right: model picker + Persona + temp + export + clear + transcript + Send/Stop).
  Reuses `ChatSession`/`InferenceService` streaming and the now-internal `MessageBubble`
  (markdown/code render, copy, regenerate). Works with any local model incl. `…-trained`
  fine-tunes and DiffusionGemma. **Design note / caught bug:** persistence keys on a
  separate `sessionConvID` (the conversation the live session was built from), NOT
  `selectedID` — otherwise `onChange(selectedID)` (which fires after the id already
  changed) would write the outgoing transcript into the incoming conversation. The
  outgoing session is `stop()`-ed before a new one loads. Ran a 4-dimension adversarial
  review workflow (17 agents, 11 confirmed / 2 rejected) and applied ALL of it:
  - **ChatSession Stop→Send race** (HIGH, also affected the arena): the finished task's
    tail unconditionally nulled `generationTask`/`isGenerating`, so a fast Stop→Send let
    the OLD task clobber the NEW generation's handle → orphaned subprocess. Added a
    `generation` counter bumped on send/stop; the tail only resets shared fields if still
    current.
  - **"Try again"/aborted-regen data-loss** (HIGH): a failed regeneration stripped the
    good stored answer to nothing. `persist()` now refuses to overwrite a stored answer
    with a worse "trailing user turn, fewer messages" state, and keeps non-empty partial
    replies (switch-away mid-stream no longer loses 95%-streamed text).
  - Unsent draft no longer bleeds between conversations (`input=""` in loadSession);
    delete confirms; a chat opened on a deleted model no longer silently rewrites its
    stored model (fallback tracked); temp slider persists on drag-end only (was rewriting
    JSON + re-sorting every tick); loading a conversation scrolls to the latest; unreadable
    conversation JSON is logged not silently dropped.
  Build clean; installed. _Pending: push._

- **Session 2026-07-01 (cont.) — review fixes: 24 of 42 confirmed findings applied.**
  The `llmpro-full-review` workflow (6 dimensions → 43 adversarial verifiers, 42
  confirmed / 1 rejected) surfaced real bugs; fixed this session (build clean between
  batches):
  - **Cross-tab hand-offs actually work now** (HIGH): `.openChatWithModel` /
    `.openCodeWithModel` payloads were ALWAYS dropped when the target tab wasn't
    mounted (plain switch in RootView.detail; NotificationCenter has no replay) — so
    "Grade it"/"Try it out"/"Use in Code" only switched tabs on first visit. Fixed by
    extending the `pendingTrainingHandoff` stash pattern: `PendingModelHandoff` +
    RootView stashes + ArenaView/CodeView consume on mount/change (direct `.onReceive`s
    removed — single delivery path, no double-apply).
  - **Stale `.running` records deletable** (HIGH): a crash/force-quit leaves the
    SwiftData record `.running` forever (exit-watcher dies with the app) — deletion was
    permanently blocked. `TrainingArtifactDeletion.isLive()` now trusts the registry
    (pid-verified), not the record; history-view gates mirror it.
  - **resume() gets watchers** (HIGH): the standalone resume spawn had no exit/stdout/
    stderr pipeline (resumed jobs stuck `.running`, empty log) — now delegates to
    `start(resumeAdapterFile:)`.
  - **caffeinate can't leak** (HIGH): now `-w <app pid>` (dies with the app), spawn-race
    reconciliation, `stopForQuit()` in applicationWillTerminate; Practice runs now hold
    the assertion too (was Teach-only).
  - **Quit no longer orphans Practice** (HIGH): applicationShouldTerminate now counts
    SelfImproveService and cancels it on Stop-and-Quit / Detach-and-Quit.
  - **Dataset perf** (3× HIGH): JSONL load + save moved off the main actor;
    DatasetInsightsView + DatasetLintSheet compute once off-main instead of per body
    eval (froze the UI on big lessons). Lint "clean copy" now auto-saves (was silently
    discarded on close/split-switch — the only non-persisting edit path).
  - **Arena**: Stop button (⌘.) while generating; a mid-generation Send no longer
    silently discards the typed prompt.
  - **User Stop ≠ failure**: a deliberate stop was recorded `.failed` with a scary
    "killed by signal 15 / out of memory" message + failure notification — exit handler
    + markFailed now honor `.cancelled`. Practice cancel between subprocesses no longer
    falls through to "Done 🎉" (round-loop + runOneRound guards).
  - **Recreate venv**: confirm dialog + disabled while any job runs (was instant wipe).
  - **Storage → Clear logs** keeps the live llmpro.log (unlinking it silently killed all
    logging for the session). **k-quant temp f16 + partial output** cleaned on failure.
    **verifyGGUF** got a 3-min watchdog (spawn + SIGTERM; a wedged load can't hang the
    export). **MLXServerService** start-race can't orphan a multi-GB server anymore.
    **GGUF sheet** can't be dismissed mid-export. **Ollama tag** sanitized up-front.
  - **Notifications**: UNUserNotificationCenter delegate installed — banners show while
    frontmost, click opens the right tab (re-opening the window if closed). Menu-bar
    Open buttons also re-open the closed window. TrainingComparisonView decodes metrics
    once. Model **tags now filter** the Models list (were write-only).
  - Docs: WORKFLOWS §7 rewritten (unified GGUF path), CLAUDE.md export line + exports/
    layout, CONTRACTS logs/ + exports/ layout, ARCHITECTURE Settings tabs row.
  **Deferred (honest list)**: ModelRegistry.scan still enumerates on-main (large
  refactor of a critical service); full ARCHITECTURE/CLAUDE.md module-table backfill
  (Inspect tab rows etc.); live token counter + regenerate-stream polish; GGUF export
  cancellation (needs process-handle plumbing through the export UIs).

- **Session 2026-07-01 — round-3 batch: 9 features + full-project review.**
  Ran a 6-dimension adversarially-verified review workflow (`llmpro-full-review`)
  over the whole tree + shipped the remaining vetted backlog (build clean between
  each):
  1. **Getting-started checklist** — `GettingStartedChecklist` replaces the Home
     single-step card: all 4 loop stages with live done states (models/lessons/
     finished-job + `onboarding.triedChat` set by ArenaView's first send);
     collapses to a dismissible 🎉 banner when complete.
  2. **Recent activity feed** — `RecentActivityFeed`: unified time-sorted stream
     over TrainingJob + DatasetRecord + EvalRun + SelfImproveRun with deep links;
     replaces `recentJobs` (rename preserved via closure).
  3. **Quick actions + tip of the day** — `DashboardQuickActions`: 4 prerequisite-
     aware launcher tiles + 15 curated rotating tips (day-of-year + offset).
  4. **Model card** — `ModelCardView` ("About this model…" context menu): config
     facts (layers/heads/vocab/context), ~param count from safetensors headers
     (off-main), lineage (fine-tunes from this base), latest report-card score,
     notes/tags, GGUF-ready badge.
  5. **Model compare** — `ModelCompareView` ("Compare…" in the Local models
     header): two-column facts grid, differing rows highlighted in brand.
  6. **Host to the cloud export** — new `ExportTarget.cloud`: fuse `--dequantize`
     → full-precision HF safetensors + a README (`ModelCardBuilder.cloudREADME`)
     with exact vLLM/TGI serve commands. Arch-agnostic — the honest cross-OS/cloud
     path for hybrid archs (Qwen3.6) that GGUF can't run.
  7. **Model card generator** — `ModelCardBuilder.modelCard` + `ModelCardPreviewView`
     ("Model card…" in Save & Use): HF-style markdown with training details +
     eval table; copy/save.
  8. **Report cards (eval leaderboard)** — `EvalLeaderboardView` (trophy toolbar
     button in Save & Use): score-over-time chart, best-per-artifact leaderboard
     (🥇🥈🥉), full run history.
  9. **Training recipes** — `TrainingPresetStore` + preset bar inside Teach's
     Advanced disclosure (AutoTuner primary flow untouched); apply keeps per-run
     model/data/adapter paths. `training_presets.json`.
  10. **⌘K command palette** — `CommandPaletteView` + `.openCommandPalette`
     notification; menu item added via `.commands` in LLMProApp; RootView hosts
     the sheet. Prefix-then-contains ranking over all 13 tabs.
  Review findings applied separately (see next entry once merged). _Pending: push._

- **Session 2026-06-23 (cont.) — feature batch round 2 (9 more, ideated via workflow).**
  Ran a 6-agent round-2 ideation workflow (`llmpro-feature-ideation-2`) merging fresh ideas
  with the deferred backlog → ranked batch; shipped the high-value, low-risk subset (build
  clean between each):
  1. **Overlaid loss-curve comparison** — `TrainingComparisonView` (Swift Charts overlay of
     `decodedMetrics()` train loss across selected runs); "Compare" toolbar button in
     `TrainingHistoryView`.
  2. **Markdown run report** — `TrainingRunReport` (markdown gen + NSSavePanel) +
     `TrainingRunReportView` (in-app preview); "View/Export report…" in the Past lessons
     context menu.
  3. **Dock progress badge** — `DockProgressService` sets `NSApp.dockTile.badgeLabel`
     ("38/50") from `JobRegistry` step transitions; cleared when idle.
  4. **Pin/favorite models + datasets** — `FavoritesStore` (JSON, no schema); star button +
     pinned-first sort in `ModelsBrowserView` + `DatasetsView`.
  5. **Model notes & tags** — `ModelMetaStore` (JSON keyed by `DetectedModel.id`) +
     `ModelNotesSheet`; tag chips in the model row, "Notes & tags…" context menu.
  6. **Regenerate response** — `ChatSession.regenerateLast()` + a "Try again" button on the
     last assistant message.
  7. **Copy code blocks** — `CodeBlockParser` (fence scanner) + `MessageContentView` (per-block
     Copy + per-message Copy), replacing the plain `Text` in `ChatView.MessageBubble`.
  8. **Prompt library** — `PromptLibraryStore` (8 built-in coding prompts + custom JSON) via a
     "Prompts" menu in ArenaView's sampling row.
  9. (run-report preview counted under 2.) Stores 4,5,7,9 all clone the `SystemPromptPresetStore`
     pattern (JSON under app-support, no SwiftData/modelContainer change → `LLMProApp` untouched).
  Deferred to future solo sessions (per workflow, higher blast radius): training-job-queue,
  live-token-counter (mlx_lm tok/s line is discarded — needs a Researcher pass), reusable
  training-presets (touches the Teach flow), model-card + compare, eval-leaderboard,
  regression-prompt-set, HF-safetensors "host to cloud" export (touches the export engine).
  _Pending: push the whole day's work._

- **Session 2026-06-23 (cont.) — feature batch (9 new features, ideated via workflow).**
  Ran a 7-agent ideation workflow (`llmpro-feature-ideation`) → ranked buildable batch,
  then shipped it (build clean between each, all Debug-verified):
  1. **Completion notifications** — `NotificationService` (UserNotifications, lazy auth).
     Posts a friendly banner when Teach/Practice/Export finishes (success or fail).
     Hooks: `JobRegistry.markCompleted/markFailed`, `SelfImproveService` completion,
     the two export views.
  2. **Keep-awake** — `KeepAwakeService` holds `caffeinate -imsu` while ≥1 job runs
     (refcount on `JobRegistry.runningJobs`); opt-out toggle in Settings → Runtime → Power.
  3. **Menu bar status** — `JobStatusMenuBar` + a `MenuBarExtra` scene in `LLMProApp`
     (inserted only while a job runs); reuses `TrainingNarrator` for phase/ETA/stars,
     with Open-Progress + Stop.
  4. **Storage** — `StorageService` scans every PathResolver dir → per-category sizes +
     free space; `StorageSettingsView` (new Settings tab) shows the breakdown + a
     proportional bar + reveal/clear. Clearable = regenerable only (exports/logs/llama.cpp
     build); user data is reveal-only.
  5. **Cache cleanup** — `StorageService.clear()` wipes a clearable category's contents.
  6. **Dataset insights** — `DatasetInsightsService` (row/msg/token counts, role balance,
     length histogram, dup count) + `DatasetInsightsView` (disclosure in DatasetDetailView).
  7. **Dataset linter** — `DatasetLinter` (missing prompt/reply, empty msgs, dups, over-long)
     + `DatasetLintSheet` with non-destructive "Make a clean copy" → sets rows + dirty.
  8. **Export chat to Markdown** — `ConversationMarkdownExporter` (@MainActor; NSSavePanel);
     "Export chat…" button in ArenaView (one or both arena columns).
  9. **Sampling controls + system-prompt presets** — activated the previously-dead
     `InferenceParams.topP`/`seed` with UI in ArenaView; `SystemPromptPresetStore`
     (6 built-ins + custom presets saved to `system_prompt_presets.json`) via a Persona menu.
  Bonus: Settings → Runtime now has a **"Build llama.cpp tools"** button (k-quants + self-test).
  Deferred (per workflow, mostly because they'd touch the uncommitted TrainingMonitorView/
  ExportWizardView or want their own session): dock badge, orphan-finder, dataset rebalancer,
  overlaid loss curves, prompt library, regression set, command palette, training queue,
  training-run report, pin/favorites, live token counter, regenerate/stop-sequences.
  _Pending: push the whole day's work._

- **Session 2026-06-23 (cont.) — hardened GGUF export: --dequantize, real k-quants, self-test.**
  Multi-agent research (workflow `mlx-to-gguf-feasibility`, 8 agents) corrected the
  earlier "llama.cpp can't run qwen35" call: it CAN (Simon Willison ran Unsloth's
  Qwen3.6-27B Q4_K_M coherently). The real cause of LLMPro's Qwen3.6 garbage is a
  **double-applied Qwen3-Next RMSNorm `+1` shift**: MLX bakes it into saved weights,
  `convert_hf_to_gguf.py` (conversion/qwen.py) re-applies it → ~2× wrong norms → token
  soup. Intrinsic to converting the MLX build of a hybrid arch; the hybrid block stays
  (rationale comment corrected). For STANDARD archs the path was just under-hardened —
  fixed:
  1. `FuseService.fuse(dequantize:)` → GGUF exports now pass `--dequantize` so a
     quantized MLX base (MLX affine `.scales`/`.biases`) becomes an HF checkpoint the
     converter can read (was a silent failure for quantized bases).
  2. Build llama.cpp from source: `PythonRuntime.buildLlamaCppTools` (cmake, Metal on,
     curl off) compiles `llama-quantize` + `llama-completion` into
     `runtime/llama.cpp/build/bin/`. Unlocks real **k-quants** (Q4_K_M/Q5_K_M/Q6_K) and
     the self-test. (NOTE: this llama.cpp split completion out of `llama-cli`, which now
     rejects `-no-cnv` — the self-test uses `llama-completion -st`.)
  3. `GGUFQuant` enum (shared by both export UIs): base types (f16/bf16/q8_0) go straight
     through the converter; k-quants are convert-to-f16-then-`llama-quantize`.
  4. `FuseService.verifyGGUF` — post-export coherence **self-test**: runs
     `llama-completion` and only reports success if the GGUF emits coherent UTF-8 (no
     U+FFFD). "A green UI is not a pass" applied to exports — catches the garbage case.
  5. Both export surfaces updated: `GGUFExportSheet` (per-model) + `ExportWizardView`
     (Save & Use) get a k-quant picker, a "Build llama.cpp tools" button gating
     k-quants/self-test, and a self-test result card. ExportWizard's GGUF path is now
     unified (always fuse `--dequantize` → convert → optional quantize → self-test);
     dropped the llama-only `mlx_lm --export-gguf` branch + `isNativelyGGUFExportable`.
  Validated end-to-end on this machine: fp16 GGUF → `llama-quantize` Q4_K_M (469M) →
  `llama-completion` self-test → coherent "Paris", exit 0. Build clean (Debug). Default
  quant is now **Q4_K_M**. _Pending: push._

- **Session 2026-06-23 (cont.) — hybrid-SSM GGUF export now BLOCKED (was warn).**
  User exported the Qwen3.6 fine-tune again and LM Studio failed at generation:
  `PredictWorker::Execute - caught exception: Failed to parse input at pos 0: t�`
  (invalid UTF-8 = garbage token IDs) and a chat-template with no role separators
  (`'You are a helpful assistantHelloHi there…'`). Confirms the prior hybrid-SSM
  diagnosis. Per user choice, upgraded the guardrail from warn-but-allow to a hard
  **block**: `FuseService.ggufRoundTripWarning` is now treated as blocking by both
  callers. `GGUFExportSheet` shows a red "Can't export this architecture to GGUF"
  card (own if/else branch) and `canExport` requires `roundTripWarning == nil`.
  `ExportWizardView` gained `ggufBlock(for:)` (config-based via resolved local-model
  dir, with repo-id-marker fallback for HF-cache bases), a red block card in the GGUF
  options, a disabled "Run export" when `target == .gguf && ggufBlockReason != nil`,
  and a defensive guard in `run()`'s `.gguf` branch so a doomed multi-GB export can
  never spawn. Build clean (Debug). _Pending: push._

- **Session 2026-06-23 (cont.) — delete previous training runs.** The Progress tab
  only ever showed the most-recent run with no way to clear out old ones. Added a
  "Past lessons" toolbar button → `TrainingHistoryView` sheet: a `@Query`'d list of
  every `TrainingJob` (most-recent first) with friendly status badge, date, and
  on-disk adapter size (measured off-main via a `nonisolated static` sweep — the
  `DirectoryEnumerator` fast-enumeration is illegal from async contexts). Per-row
  trash + swipe delete (disabled while running) + "Delete all finished". Delete =
  remove SwiftData record + `JobRegistry.remove(jobID:)` (new; refuses a live
  process) + `removeItem(adapters/<uuid>/)`. Does NOT touch the dataset, base model,
  or any fused `…-trained` model. New file added to `project.yml` via `xcodegen`.
  Build clean (Debug). **Follow-up:** the **Save & Use** export list shows the same
  runs (plus Practice runs), so added context-menu + swipe **Delete** there too, with
  a confirm alert. Centralized the delete logic into `TrainingArtifactDeletion`
  (`deleteJob` / `deleteRun`) shared by both `TrainingHistoryView` and
  `ExportWizardView`; `deleteRun` removes `selfimprove/<uuid>/` for Practice runs and
  guards the in-flight statuses (generating/testing/training/evaluating). _Pending: push._

- **Session 2026-06-23 (cont.) — hybrid-SSM GGUF guardrail (Qwen3.6 garbage output).**
  After the `--no-mtp` fix the SeeSharp (Qwen3.6-27B, `qwen3_5`) GGUF *loaded and ran*
  in LM Studio but emitted mixed-language token-soup (`_6Logy的画面ubberFrame…`).
  Diagnosis: `qwen3_5` is a **hybrid** arch (standard attention + linear-attention/SSM
  Mamba-style layers + MTP head). llama.cpp's `convert_hf_to_gguf.py` round-trips an
  **MLX-format** hybrid-SSM checkpoint poorly — even the SSM control tensors came out
  partially Q8_0. The decisive source-vs-GGUF A/B was **impossible** (the source model
  `models/Qwen3.6-27B-bf16-trained` had been deleted; models dir empty), but the garbage
  signature + llama.cpp's immature hybrid-SSM support point to an **upstream conversion/
  runtime limitation, not an LLMPro bug**. Fix (guardrail, not a converter change):
  `FuseService.ggufRoundTripWarning(forModelDir:)` (nonisolated static — reads config.json)
  flags hybrid/experimental archs (MTP head, `model_type`/arch containing
  qwen3_5/qwen35/mamba/ssm/linear_attn/hybrid, or `layer_types` with linear/mamba/ssm
  layers). `GGUFExportSheet` shows a non-blocking "Experimental architecture" card before
  export with MLX-instead guidance ("runs correctly in Try it out / Code"). Build clean.
  Known-good GGUF archs remain plain llama/mistral/mixtral/qwen2/gemma2/phi3-style; hybrid
  archs should be run in MLX rather than exported. _Pending: push these commits._

- **Session 2026-06-23 (cont.) — GGUF export of Qwen3.6/MTP archs fixed (`--no-mtp`).**
  Exported Qwen3.6 GGUFs failed to load in llama.cpp/Unsloth with
  `missing tensor 'blk.64.attn_norm.weight'`. Root cause: Qwen3.6 (`qwen35`)
  declares a multi-token-prediction layer (`mtp_num_hidden_layers=1` → block 64 on a
  64-layer model), but **mlx-lm drops the MTP weights** when building the MLX model —
  so conversion wrote the MTP/`nextn` metadata without the tensors, and the loader
  then demanded block 64. Fix (`665740f`): `FuseService.mtpExclusionArgs` detects
  MTP-in-config (self-gating — key only exists on Qwen3.5/3.6/Step3.5) and passes
  `convert_hf_to_gguf.py --no-mtp`, producing a clean trunk-only GGUF (MTP is only a
  spec-decoding speedup). Applied in `convertModelToGGUF` + `fuseAndConvertExternalGGUF`.
  Re-exported the user's SeeSharp.gguf and verified: 64 blocks, no `blk.64`, no nextn
  KV. NOTE: this only works because the loader already supports `qwen35` (the error
  was tensor-level, not "unknown architecture") — Qwen3.6 GGUF still needs a recent
  llama.cpp.

- **Session 2026-06-23 — GGUF export fixed + per-model export added.** GGUF export
  was effectively broken; now works end-to-end (validated live: qwen2.5-0.5b → valid
  Q8_0 GGUF). Three fixes + one feature:
  1. `installLlamaCpp` only pip-installed `gguf`, but `convert_hf_to_gguf.py` imports
     `torch` at module load → every non-Llama GGUF export died with "No module named
     torch". Now installs `gguf + torch` (base venv stays torch-free; torch added
     on-demand). (`819bcc2`)
  2. `FuseService.fuse`/`fuseToGGUF` passed the bare base-model name to `mlx_lm fuse
     --model` → mlx-lm treated it as an HF repo id → **401** (load-bearing rule #4).
     Added `FuseService.resolveModelArg` applied in both. (`52162fa`)
  3. **New: per-model "Export to GGUF"** in the Models tab (row action + context menu)
     → `GGUFExportSheet` → `FuseService.convertModelToGGUF` (runs convert_hf_to_gguf
     directly on a model dir, no adapter/fuse). Gates out quantized + diffusion models
     with a friendly note; installs the converter on demand. Completes the loop
     download → train → test → use/export. (`654b969`)
  - **Gotcha for future work:** `convert_hf_to_gguf.py --outtype` only accepts
     `f32/f16/bf16/q8_0/tq*` — **NOT** K-quants like `q4_k_m` (those need llama.cpp's
     separate `llama-quantize` binary, which a `--depth 1` source clone doesn't build).
     The sheet offers Q8_0/F16/BF16. Adding Q4_K_M later means building/bundling
     `llama-quantize` and a post-convert quantize step.

- **Session 2026-06-13 (cont.) — Full stress test (clean).** Three layers:
  (1) unit suite 53/53 pass; (2) UI sweep of the live app — rapid all-13-tab
  init/teardown (no hang), every tab verified rendering after the visual refresh
  (Home/Models/Lessons/Teach/Progress/Try-it-out/Code/Practice/Fusion/Memory/
  Inspect/Save&Use/Settings + its Runtime/Paths/Logs/HuggingFace sub-tabs), HF
  model search (`llama` → 6 mlx-community results), Inspect parsing a real 27B
  model (851 tensors / 26.9B params via the pure-Swift safetensors reader), and
  the Code Options **sheet** lifecycle incl. the sheet-from-sheet handoff; the
  shared metrics poller survived heavy tab-switching (wave-2 fix held).
  (3) Log/crash audit: zero app-runtime error/fault lines, no new `.ips`, process
  still alive. One investigated false alarm — a blank HF search on a garbled
  query; network/query/code/entitlements (app-sandbox=false) all verified and a
  clean re-search returned results, so not a bug. No code changes; verification only.

- **Session 2026-06-13 (cont.) — Visual/aesthetic UI refresh (`5267406`, `ec3dc77`).**
  Reviewed every tab live (screenshots) then restyled. (1) **Brand identity unified:**
  new `AccentColor` asset (violet ≈ #6B4AFF/#8C78FF) wired app-wide via
  `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME` — all controls were system blue
  despite the purple icon; now everything (sidebar selection, buttons, toggles,
  sliders, progress) is brand violet. (2) **New `Core/Theme.swift` design system:**
  `Color.brand`, `.card()` surface (defined border + elevation, replaces flat
  `.thinMaterial`), `sectionHeader()`, `Theme.brandGradient`. (3) **Rolled out:** Home
  + Teach/Progress/Practice/Lessons/Save&Use/First-run cards → `.card()`; Teach picker
  gains a brand-tinted selected state; semantic green/orange/red preserved. (4) **Fixes:**
  "Try it out" tab was titled "Model Arena" (fixed); its empty compare panes were bare
  black voids (now a friendly empty-state). Build + 53 tests green; verified live on
  Home/Teach/Try-it-out/Progress. Convention recorded in CONVENTIONS.md "Brand accent +
  the shared card surface".
- **Session 2026-06-13 (cont.) — Full code audit + fixes (3 commits).** A 6-agent
  read-only audit of the whole codebase, then correctness/safety fixes landed across
  three commits (build + 53 tests green; this was a code session — the docs were
  updated in a follow-up Builder-Text pass, source files unchanged by the docs pass).

  - **Wave 1 (`90b64c9`):** AppDelegate quit-hang fixed (the `.terminateLater` path
    now actually calls `reply(toApplicationShouldTerminate:)`). `ProcessRunner` got
    three fixes: the pipe `readabilityHandler` now **owns stream-finish on EOF** (was
    dropping the final stdout/stderr line — i.e. the error/traceback tail); a
    `continuation.onTermination` now **terminates the child when its consumer is
    cancelled** (was orphaning subprocesses); and a new `RunningProcess.kill()`
    (SIGKILL escalation) was added. `JobRegistry.stopAll` snapshots its keys (was
    mutate-during-iteration). `MLXServerService` now **awaits the old server's exit
    before respawning** (was double-loading a multi-GB model). `AutoTuner.categorize`
    now returns **`.medium`** (not `.tiny`) for size-markerless names — the documented
    fallback, with an explicit `<2B → .tiny` branch (the dead-code `(0.0, .tiny)` tuple
    is gone); `AutoTuner` also clamps DPO `val_batches` to the tiny valid-row count.
    `DatasetService`'s 90/5/5 split no longer produces an empty test/valid split for
    small files. `EvalService` fails an empty suite with `.noProblems` instead of
    saving a 0/0 EvalRun. `TrainingService` now escapes model/data/adapter_path in the
    generated YAML. `SelfImproveService` routes a **user-cancel to a `.cancelled`
    terminal state** (was reported as failure) and `runEval` dual-reads
    `pass_at_1 ?? pass_at_k`. `AgentTools.sandboxed()` now **resolves symlinks**
    (closing a workspace-jail escape where an in-jail symlink let file tools read/write
    outside the workspace). `self_improve_round.py` hardened its model-generated-code
    sandbox: own process group (`start_new_session` + `killpg` on timeout), throwaway
    cwd, **stripped environment so generated code no longer sees `HF_TOKEN`/secrets**,
    plus `RLIMIT_NPROC`/`FSIZE`/`CPU`. `manage_experts.py` / `add_expert.py` /
    `strip_vision.py` gained top-level error-event guards; `hf_download.py` clamps
    progress to ≤1.0.
  - **Wave 2 (`d125dfd`):** `TrainingMonitorView` **no longer stops the shared
    `SystemMetrics` poller on disappear** (it was freezing the memory gauges
    app-wide). `SelfImproveView` Practice-run delete is now confirmation-gated and
    cleans up the on-disk dir. `ModelRegistry.delete(repoID:)` rejects `/` and `..`
    (path-traversal guard). `HuggingFaceClient` got a 20 s request timeout. The Arena
    generation leak is fixed (`InferenceService` terminates the child on stream
    `onTermination` + checks `Task.isCancelled`; `ChatSession` stores/cancels its
    generation `Task` in `clear()` / `stop()` / `deinit`). **The HF token is no longer
    passed as argv** — it now travels via the **`HF_TOKEN` env var** for
    `hf_download.py` and `prepare_coding_dataset.py` (`DownloadService` /
    `DatasetPrepService` set the env; the Python reads `HF_TOKEN` with an argv
    fallback). A pre-existing Swift-6 region-isolation error in `DatasetPrepService`
    (sending non-`Sendable` `onComplete`) was fixed by making `onComplete` `@Sendable`.
  - **Tests (`0a318b1`):** added `Tests/LLMProTests/ProcessRunnerTests.swift` (7
    tests — streaming captures all lines incl. the unterminated EOF tail, non-zero exit
    surfaces code+stderr, both streams terminate on exit, a cancelled consumer reaps
    the child). The suite is now **7 test files / 53 tests** (see the Tests section).
  - **Wave 3 — security hardening (`acec4a8`, user-approved):** auto-run/auto-approve
    now default OFF; `run_command` env is secret-scrubbed; `fetch_url` SSRF guard
    (DNS-rebinding-aware, fails closed); delegation breadth/total cap (40/task) + cycle
    guard. Build + 53 tests green.
  - **Still deferred:** see the "Audit — deferred items" section above — restored-workspace
    security-scoped bookmark, DatasetEditor structured-content drop, and a handful of LOW
    cosmetic items (FuseService Modelfile quoting, InferenceService system-prompt slot,
    ModelsBrowser timing handoff, diffusion_server non-stream timeout).

- **Code tab now serves text-diffusion models (DiffusionGemma) for the agentic loop —
  VERIFIED LIVE.** DiffusionGemma is **no longer chat-only**: it now also drives the
  **Code** tab's Orchestrator team (agentic, experimental). New helper
  [`diffusion_server.py`](../LLMPro/Resources/helpers/diffusion_server.py) — a
  long-lived **OpenAI-compatible HTTP server** (Python stdlib `http.server`
  `ThreadingHTTPServer`, **no Flask**) around the vendored diffusion decoder. The model
  loads ONCE on a single dedicated **MLX worker thread** (the vendored decode binds a
  thread-local `mx` stream at import → load + all generation must run on one thread;
  HTTP request threads submit jobs via a queue). Endpoints: `GET /health`,
  `GET /v1/models`, `POST /v1/chat/completions` (non-stream + SSE in the exact shape
  `OpenAIChatClient` decodes). Prints `LLMPRO_DIFFUSION_SERVER_READY port=<port>` when
  ready. **Translates** DiffusionGemma's native tool grammar
  `<|tool_call>call:NAME{key:value,…}<tool_call|>` (string args quoted `<|"|>…<|"|>`)
  into OpenAI `tool_calls` (tolerant parser; **fail-open** to plain `content` if nothing
  parses — the agent's text fallback still runs); tool RESULTS (`role:"tool"`) need no
  translation (the model's chat template consumes them). Swift:
  `MLXServerService.start(model:adapterPath:)` now branches on `ModelRegistry`'s
  `isDiffusion` — for diffusion models it launches `diffusion_server.py` (via
  `mlx_run.py`, so it's memory-wrapped like `mlx_lm server`; **`adapterPath` is
  ignored** — diffusion has no LoRA) instead of `python -m mlx_lm server`, reusing the
  same free-port / `waitForServerUp` (`/health`) / warm-up / state machine, so
  `OpenAIChatClient` + `CodingAgentService` work unchanged.
  `PythonRuntime.installHelpers()` now also stages `diffusion_server.py` (the
  `diffusion_vendor/` subtree was already copied; no new pip deps — stdlib + existing
  mlx/transformers/pillow/numpy). `CodeView` shows a friendly caption — "Diffusion
  model — chat works; agentic tool-use is experimental." — and keeps native
  tool-calling ON (default) so the server's translated `tool_calls` are used.
  **Verified live:** DiffusionGemma-8bit served in the Code tab; the Orchestrator team
  drove the full loop (Orchestrator → Coder → `write_file` → `list_dir`) and created a
  file on disk; logs clean, no crash — with an occasional unusable diffusion turn the
  Orchestrator recovers from (canvas-256 reliability caveat). **Correctness fix across
  the docs:** DiffusionGemma is now "chat + Code (experimental); not fine-tunable" —
  excluded ONLY from Teach/Practice/DPO (the "chat only" framing was updated in
  CONCEPT / CONVENTIONS / CLAUDE / CONTRACTS / ARCHITECTURE / EXTENDING; the literal
  Models-tab badge still reads "Diffusion · chat only" in source and is noted as
  slightly stale). Docs updated (CONTRACTS / ARCHITECTURE / CONCEPT / CONVENTIONS /
  EXTENDING / STATE / CLAUDE). **Source files were NOT touched by this docs pass.**

- **GGUF→MLX chat-template fallback (already committed) — gap RESOLVED; moved to
  Working.** `gguf_to_mlx.py` now writes a **per-architecture default** chat template
  when the source GGUF carries none in its `tokenizer.ggml.chat_template` metadata
  (ChatML for qwen2/qwen2moe/qwen3, Gemma turn format, Llama-3 headers, Phi-3,
  Mistral), so converted **INSTRUCT** models chat out of the box (previously they had
  no template and failed with "tokenizer.chat_template is not set" until one was
  hand-injected — the gap found while verifying the eval harness). Metadata-present
  conversions are unchanged; the `done` event gained **`chat_template_source`**
  (`metadata` | `fallback-<arch>` | `none`). This closes the former Half-done
  "GGUF→MLX importer does not reconstruct a chat template" item (the spun-off task is
  resolved). Docs updated (CONTRACTS new `gguf_to_mlx.py` subsection + ARCHITECTURE
  `GGUFImportService` note + STATE Working/Half-done move).

- **First test suite (already committed) — 37 passing XCTest tests.** Added
  `Tests/LLMProTests/` (the `LLMProTests` XcodeGen target): `LogStreamParserTests`
  (mlx-lm train/eval/DPO line regexes), `DatasetServiceClassifyTests`
  (`classify` per schema incl. the `preference`-before-`completions` vote),
  `AutoTunerTests` (`categorize` buckets + every `(size, duration)` bucket sane),
  `FuseServiceTemplateTests` (`OllamaChatTemplate`). `xcodebuild … test` →
  **TEST SUCCEEDED**. Removed the stale empty `Tests/MLXStudioTests/`. **Minor
  discrepancy pinned:** `AutoTuner.categorize`'s doc says it falls back to `.medium`
  for a marker-less id, but the trailing `return .medium` is dead code (the patterns
  table ends with `(0.0, .tiny)`), so a marker-less id returns `.tiny` —
  `testCategorizeNoMarkerFallsBackToTiny` pins the actual behavior and flags it as a
  product decision. Docs updated (STATE Tests section + ARCHITECTURE Tests table +
  BUILDING `xcodebuild … test` line).

- **DiffusionGemma (inference-only "guest" model) — VERIFIED LIVE end-to-end; landed
  in Working.** Added the ability to run Google's `google/diffusiongemma-26B-A4B-it` —
  a **masked/block-diffusion** LM (`model_type: diffusion_gemma`, decodes by unmasking
  a fixed canvas) — as an **inference-only** model: it can be downloaded + chatted in
  Try-it-out but is **excluded from Teach/Practice/DPO** because mlx-lm can't run it
  through `generate`/`server` and can't LoRA-fine-tune it. Runs the prebuilt
  `mlx-community/diffusiongemma-26B-A4B-it-OptiQ-4bit` (~15 GB). **Decoder is VENDORED,
  not pip** — the MIT `optiq.vlm` DiffusionGemma subset of `mlx-optiq` v0.2.3 copied
  into `Resources/helpers/diffusion_vendor/` (~34 `.py` + `VENDORED.md`; the package's
  network/subprocess/serve/cli/agent subtrees deliberately excluded → smaller attack
  surface + pinned; self-contained on `mlx`/`mlx-lm`/`transformers`/`numpy`/`Pillow`,
  no torch). New helper `diffusion_generate.py` adds the vendor dir to `sys.path`,
  imports `optiq.vlm.diffusion_gemma`, **applies the Gemma chat template** + pre-tokenizes
  with `add_special_tokens=False`, self-pins MLX memory (bypasses `mlx_run.py`), streams
  `start`/`progress`/`token`/`done`/`error`. Swift: `ModelRegistry.DetectedModel.isDiffusion`
  (config `model_type`/arch detect); `InferenceService.stream` routes diffusion →
  `diffusion_generate.py` (direct spawn); `PythonRuntime.installHelpers()` now
  **recursively** copies the `diffusion_vendor/` subtree (was flat-`.py`-only) +
  `diffusion_generate.py`, `bootstrap()` adds `pillow`; `TrainingConfigView` (Teach) +
  `SelfImproveView` (Practice) filter `!isDiffusion`; `ModelsBrowserView` shows a
  "Diffusion · chat only" badge. **Streaming-contract change worth noting:**
  `InferenceService` now yields *ready-to-append* chunks (mlx_lm re-adds its line `\n`,
  diffusion yields raw token segments) and `ChatSession.send` appends `chunk` **raw**
  (was `chunk + "\n"`) — fixes a per-token-newline bug that rendered diffusion output
  one token per line; the mlx_lm path is unchanged in behavior. **Verified live** in
  the UI on the 4-bit OptiQ model: badge shown in Models; coherent correctly-formatted
  prose in Try-it-out (haiku about Apple Silicon; 2-sentence "why the ocean is salty";
  ~16.8 GB peak, ~0.6–3 s gen after cold load); absent from Teach/Practice pickers; a
  normal qwen model still streams in the Arena (mlx-lm regression check); all 13 tabs
  swept, no crash; `llmpro.log` zero ERROR/FAULT, no new `.ips`. **Two bugs found +
  fixed + re-verified:** chat-template-not-applied (garbage output), and the
  per-token-newline rendering. The (already-known) **GGUF→MLX chat-template gap remains
  open** (separate task; a converted test model still needs a manual template) — it is
  unrelated to this work. **Non-bug note:** a 6-day-old temp test model
  (`models/qwen2.5-0.5b-instruct-mlx`) had vanished from disk; this was **NOT an app
  bug** — there is no spontaneous model-deletion path in the code (only the explicit
  user `ModelRegistry.delete(repoID:)`) — and it was simply re-created from its on-disk
  GGUF for testing. Docs updated (CONTRACTS / ARCHITECTURE / CONCEPT / CONVENTIONS /
  EXTENDING / STATE / CLAUDE). **Source files were NOT touched by this docs pass.**

- **DPO preference loop ("Teach by preference", Feature 2 of 4) — VERIFIED LIVE
  end-to-end; landed in Working. + Arena local-model inference fix.** The Arena's ③
  Test node gained a **preference back-edge**: a 👍 "Which answer is better?" capture
  row (separate from Feature-1's "Score it" report card) → preference pairs accumulate
  → a **DPO** fine-tune → a normal LoRA adapter that flows back through the loop. New
  [`PreferenceService.swift`](../LLMPro/Services/PreferenceService.swift) (`@MainActor
  enum`: `createPreferenceSet` / `findOrCreateActivePreferenceSet` / `appendPair`
  (atomic, de-dup, bumps `trainRows`) / `splitForTraining` (~10% → `valid.jsonl`));
  preferences stored as a first-class `DatasetRecord` with a NEW
  `DatasetSchema.preference` case (**not** a new `@Model` → no SwiftData migration),
  `{"prompt","chosen","rejected"[,"system"]}` JSONL; `DatasetService.classify()` votes
  `preference` before `completions`. **DPO engine = the separate `mlx-lm-lora` v2.1.0**
  (`python -m mlx_lm_lora.train`), installed **on-demand** like mergekit
  (`PythonRuntime.dpoTrainerInstalled()`/`installDPOTrainer()`; in `bootstrap()` pip
  list; NOT gating `.ready`) — the installed `mlx-lm` 0.31.3 has no DPO. Swift
  plumbing: `TrainMode {sft,dpo}` + `dpoBeta`/`dpoLossType` on `TrainingConfig` →
  `renderDPOYAML()`; `AutoTuner.tuneDPO` (fewer iters, ~half lr, β=0.1, ~2× mem,
  adamw); `TrainingJob.trainModeRaw` (additive, default "sft"); `TrainingService.start()`
  branches SFT vs DPO; `LogStreamParser` DPO regex `Iter (\d+): loss ([\d.]+)`
  (anchored on `: loss ` so it can't match SFT `Train loss`/`Val loss`). Loop wiring:
  `ArenaView.preferenceBar` + "Teach by preference →" CTA (≥4 prefs);
  `PreferenceHandoff{model,adapterPath?,datasetID}` + `.openTrainingWithPreferences`
  (in `Core/LoopHandoff.swift`); `RootView` routes it to Teach; `TrainingConfigView`
  auto-detects a `.preference` lesson → DPO banner + mode, `launch()` →
  `splitForTraining` + `tuneDPO` + `job.trainMode = .dpo`. **THREE load-bearing
  contract gotchas** (now in CONTRACTS): (1) `mlx_lm_lora.train` merges `-c config.yaml`
  ONLY into still-`None` argparse args, so its non-`None`-default args (incl.
  `--train-mode` default `"sft"`, `--beta`, `--dpo-cpo-loss-type`,
  `--gradient-accumulation-steps`) IGNORE the YAML → MUST be **CLI flags**; `-c` is for
  None-default/nested keys (`lora_parameters`, `lr_schedule`, **`fuse: false`**). (2)
  `fuse: false` is REQUIRED (fuse defaults true → dumps a ~1.3 GB `model.safetensors`
  per adapter dir). (3) `--batch-size` MUST be clamped to `min(trainRows, validRows)`
  — `iterate_dpo_batches` HANGS (infinite 100%-CPU spin) when batch > rows. The exit
  handler was hardened so abnormal termination → `.failed` (not stuck `.running`).
  **Verified live** through the UI on `qwen2.5-0.5b-instruct-mlx`: 4 prefs captured
  (de-dup + running count), CTA enabled at 4 → Teach auto-detected DPO; a Quick DPO run
  trained **66/66 iters** (real DPO loss lines, batch clamped **4→1** for a 3-train/
  1-valid split), wrote `adapters.safetensors` (22 MB) + checkpoints, `job.json`
  `status: completed`, Progress 100% + star rating, completion CTAs shown. **Logs
  clean** (zero ERROR/FAULT, no new `.ips`). **Honest caveats:** (1) DPO on 4 prefs
  **overfits** (low star rating) — quality needs more prefs; the PLUMBING is verified.
  (2) The CTA switches tabs but the model/dataset **pre-fill has a notification-timing
  bug** being fixed separately (sibling agent). **Also fixed:** `InferenceService.stream`
  now resolves a bare local-model name to its absolute path before `mlx_lm generate`
  (HF repo ids unchanged) — local custom models previously failed with "exited with
  code 1" in the Arena (found while exercising DPO captures). Docs updated (CONTRACTS /
  ARCHITECTURE / CONCEPT / CONVENTIONS / EXTENDING / STATE / CLAUDE). **Source files
  were NOT touched by this docs pass.**

- **Scored Test node — VERIFIED LIVE end-to-end; moved from Half-done to working.**
  Follow-up to the entry below. Main built a fresh standalone Debug `.app`
  (`xcodebuild … BUILD SUCCEEDED`, run NOT under Xcode's debugger) and ran the
  "Score it" flow live in the Try-it-out (Arena) Test node:
  `qwen2.5-0.5b-instruct-mlx` (a small model converted on disk from a Qwen2.5-0.5B
  GGUF for fast testing), suite HumanEval, depth Quick=20, base/no-adapter. The UI
  streamed a live "Grading N of 20 — N passed" status, then rendered the report card
  — **40%, ★★★☆☆ (3 stars), "HumanEval (164 problems) · 20 problems", "First score
  for this model."** + a Details disclosure. **Persistence verified**: an `EvalRun`
  record + sidecar `evals/2FB34179-…/eval_run.json` were written with `passAtK 0.40`,
  `passedCount 8`, `totalCount 20`, `problemCount 20`, suite `humaneval`, baseModel
  `qwen2.5-0.5b-instruct-mlx`, status `completed`, sourceLabel `Test`, k 1,
  `elapsedMs ~36392`, `lastError null` — matching the UI exactly. **Logs clean**: zero
  ERROR/FAULT in `logs/llmpro.log` since launch, no new
  `~/Library/Logs/DiagnosticReports/LLMPro-*.ips`. The engine was **also validated
  headless against a real model** (impossible in the prior pass — no small model
  existed): `eval_pass_rate.py` on the 0.5B at **k=1 → pass@1 0.375 (3/8)** with real
  generations + both pass/fail sandbox paths exercised, and at **k=2** it emitted the
  new `start.k` / `row.passes`+`row.k` / `done.pass_at_k`+`done.k` fields correctly (a
  passing-greedy row failing at temp>0 is expected small-model variance, not a bug).
  **Honest caveat:** the score-**delta** path (▲/▼ "vs your last try", via
  `EvalService.previousAdapterEval`) was **build-verified but NOT live-witnessed** — it
  needs two evals of the same base with different adapters, and no small model with an
  adapter was available; the "first score for this model" no-previous branch WAS
  verified live. Moved the eval-harness item from Half-done to "Working end-to-end
  (verified)". **Surfaced a separate bug** (now a spun-off task, logged under Half-done):
  the GGUF→MLX importer doesn't reconstruct a chat template, so the on-disk-converted
  test model needed a hand-injected ChatML template before it would run.
- **Scored Test node — new `EvalService` + `EvalRun` @Model turn ③ "Test" into a
  tracked pass@k score; "Score it" (Arena) + "Grade it" (Progress) wired; BUILD-GREEN,
  live UI smoke handed to Main.** The loop's Test node now emits a quantitative,
  comparable **pass@k** per `(model + adapter)` that feeds the ⑤ retrain back-edge
  ("did the score go up vs the previous fine-tune?"). New
  [`EvalService`](../LLMPro/Services/EvalService.swift) (singleton) +
  [`EvalRun`](../LLMPro/Models/EvalRun.swift) `@Model` (blob-in-model + sidecar, like
  `SelfImproveRun`; `adapterRelativePath == ""` = base model, else ==
  `TrainingJob.adapterRelativePath`). It **reuses the existing eval engine** —
  `eval_pass_rate.py` + `humaneval_pull.py` + the Practice sandbox — NOT a new daemon
  (deliberately not `MLXServerService`: re-implementing sandboxed test exec + fighting
  the Code tab for the daemon). [`ArenaView`](../LLMPro/Features/Chat/ArenaView.swift)'s
  old unscored "Mini-eval" → a **"Score it"** action (suite HumanEval/MBPP; depth
  Quick=20/Standard=40/Thorough=all; Advanced k stepper 1–8) + a friendly-first report
  card (pass% + 1–5 stars + a **delta vs the previous fine-tune** + per-task Details);
  the same delta feeds the decision bar.
  [`TrainingMonitorView`](../LLMPro/Features/Monitor/TrainingMonitorView.swift) gained
  a **"Grade it"** CTA (`.openChatWithModel` + `ModelHandoff.autoScore: true` → Test
  node auto-scores). Additive plumbing: `ModelHandoff.autoScore` (default false, stays
  `Sendable`, dual-decode unchanged); `PathResolver.evalsDir`/`evalSuiteDir(for:)`
  (`evals/<suiteID>/eval.jsonl`, `evals/custom-<uuid>/eval.jsonl`,
  `evals/<run-uuid>/eval_run.json`); `EvalRun.self` registered in **both** the
  `LLMProApp` schema list and `PreviewSupport` (+ `sampleEvalRun`).
  `eval_pass_rate.py` gained `--k`/`--temperature` — **`k==1` byte-for-byte unchanged**
  (greedy, still emits `pass_at_1`, so `SelfImproveService` is unaffected); `k>1` →
  `row` gains `passes`+`k`, `done` gains `pass_at_k`+`k` (no `pass_at_1`). 5 design
  decisions: (1) score in a NEW `EvalRun`, not on `TrainingJob` (base models + Practice
  adapters need scoring + comparability); (2) grow the EXISTING Test node, NOT a new
  "Grades" tab; (3) eval engine = one-shot helper + sandbox, NOT the persistent server;
  (4) pass@1 default, pass@k an Advanced knob; (5) v1 = built-in suites only, custom
  suites on-disk-but-no-UI.
  **Verification (honest boundary):** ✅ BUILD green — `xcodegen` + Debug `xcodebuild`
  → BUILD SUCCEEDED, 0 warnings in touched files, 0 expr/bodies >80 ms on the
  diagnostic build. ✅ Python `--k` verified via `py_compile` + a monkeypatched
  `main()` over a real 2-row fixture using the REAL sandbox (k==1 unchanged incl.
  `pass_at_1`; k>1 emits `passes`/`pass_at_k`/`k`) — **not yet run against a real model
  through the engine**. ⏳ **A live end-to-end UI run (Score it → report card +
  persisted EvalRun + sidecar + score delta) is IN PROGRESS by Main and has NOT been
  witnessed here — do not claim a live pass until Main confirms.** Docs updated
  (ARCHITECTURE / CONTRACTS / CONCEPT / CONVENTIONS / EXTENDING / WORKFLOWS / STATE +
  CLAUDE).

- **Hardened SwiftUI preview type-checking — lifted inline `Binding(get:set:)` out of
  view bodies + split long `.alert`/`.sheet`/`.onReceive` chains into `ViewModifier`
  structs across 7 views; added `Core/IndexedLogLine.swift` + `Core/BindingBridges.swift`;
  clean Debug build, 0 expr >80 ms.** Follow-up to the previews pass: adding a
  `#Preview` to every view surfaced that the preview-dylib compiler (it instruments
  literals with `__designTimeString` + recompiles each view to a canvas dylib) is far
  stricter on type-check time than `xcodebuild` — `ModelsBrowserView` built clean but
  **failed the canvas** with "unable to type-check this expression in reasonable time"
  (a long `.alert`/`.sheet` chain with inline `Binding(get:set:)`). Behavior- and
  UI-preserving fix: two new `Core/` helpers —
  [`IndexedLogLine`](../LLMPro/Core/IndexedLogLine.swift) (`.tail(...)` → concrete
  `[IndexedLogLine]`, replaces `ForEach(Array(log.suffix(N).enumerated()),
  id: \.offset)`; used by `TrainingMonitorView` + `FirstRunView`) and
  [`BindingBridges`](../LLMPro/Core/BindingBridges.swift)
  (`Binding<Double>.rounding(_:)` bridges Int `@State` → `Double` slider; used by
  `SelfImproveView`) — plus lifting inline `Binding`s into computed properties and
  splitting long presentation/`.onReceive` chains into named `ViewModifier` structs
  (state passed as `Binding`s/closures, **NOT `self`**, to preserve `@State` identity):
  `ModelsBrowserView` (`DeletionAndSheetsModifier`/`DuplicateAlertsModifier`/
  `LMStudioAlertsModifier`), `DatasetsView` (`DatasetsPresentationModifier` +
  a `@ToolbarContentBuilder` property), `RootView` (`SidebarNotificationRouter` for the
  6-deep `.onReceive` chain), `DashboardView`, `SelfImproveView`, `TrainingMonitorView`,
  `FirstRunView`. **Verified:** clean Debug `xcodebuild` → BUILD SUCCEEDED, 0 swift
  warnings; a diagnostic build with `-warn-long-expression-type-checking=80
  -warn-long-function-bodies=80` shows **0** expressions over 80 ms (worst offenders
  `ModelsBrowserView.list` 263 ms and `DatasetsView.body` 277 ms → gone). Key lesson
  for the next agent adding previews: **a plain `xcodebuild` is NOT a sufficient
  preview gate** — re-run with those frontend flags on a `clean` build (incremental
  builds cache + hide the times). Anti-patterns + detection recipe now in
  [`CONVENTIONS.md`](CONVENTIONS.md#preview-type-checker-anti-patterns-a-plain-build-is-not-enough)
  + [`BUILDING.md`](BUILDING.md#swiftui-canvas-fails-with-unable-to-type-check-this-expression-in-reasonable-time).
  Docs updated (ARCHITECTURE / CONVENTIONS / BUILDING / STATE).

- **SwiftUI previews — added `Core/PreviewSupport.swift` + a `#Preview` to all 33
  views; in-memory SwiftData container + `.previewEnvironment()`; clean Debug
  build.** `ENABLE_PREVIEWS: YES` was already set but no view had a `#Preview`, so
  the canvas was empty. New DEBUG-only `@MainActor enum PreviewSupport`
  ([`Core/PreviewSupport.swift`](../LLMPro/Core/PreviewSupport.swift)) holds one
  in-memory `ModelContainer` registered for all 6 `@Model` types
  (`ModelConfiguration(isStoredInMemoryOnly: true)`) seeded with realistic samples
  (`sampleJob`/`sampleCompletedJob`/`sampleDataset`+variants/`sampleModel`+variants/
  `sampleSettings`/`sampleRun`/`sampleAgent` + non-persisted value types
  `sampleHFModel`/`sampleDetectedModel`/`sampleMoEModel`/`sampleChatSession`/
  `sampleChatRow`/`sampleWorkspace`/`sampleFile`), and a
  `View.previewEnvironment()` modifier (`.modelContainer` + the real
  `PythonRuntime.shared`/`JobRegistry.shared` — no-op `private init`s, so no mocks —
  + a 900×600 default frame). A `#Preview` (own `#if DEBUG`, ending in
  `.previewEnvironment()`, friendly sidebar names) was added to every view-bearing
  file under `Features/` (32) + `App/RootView.swift` = **33 blocks**; the 3 non-view
  files (`Chat/ChatModels.swift`, `Code/Attachment.swift`, `Code/AgentTemplate.swift`)
  were skipped. `DEBUG` comes from XcodeGen's default
  `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG` (no explicit `project.yml` flag).
  **`xcodegen generate` + Debug `xcodebuild` → BUILD SUCCEEDED, zero warnings, no new
  crash report** (canvas rendering is the user's Xcode check — no headless
  macOS-preview render CLI). Gotchas for the next agent: a new `@Model` type must be
  registered in **both** `LLMProApp`'s `.modelContainer(for:)` list **and**
  `PreviewSupport`'s schema; a view needing a new injected env value means extending
  `previewEnvironment()`; new view files still need `xcodegen generate`. Docs updated
  (ARCHITECTURE / CONVENTIONS / EXTENDING / BUILDING / STATE).

- **New rule: always read the logs after testing (docs-only).** Added
  `### Always read the logs after testing` to CONVENTIONS.md → Build hygiene: a
  green UI is NOT a pass — after any test, `tail`/`grep ERROR|FAULT`
  `logs/llmpro.log` (or Settings → Logs / `log stream`) AND check for a new
  `DiagnosticReports/LLMPro-*.ips`; zero error lines + no new `.ips` is the bar.
  Rationale baked in: the 13-tab "all PASS" stress sweep missed a real
  `EXC_BAD_ACCESS` sitting in the `.ips`. Pointer added to CLAUDE.md's conventions
  list. Also finally landed the CONVENTIONS.md "rejected list" reversal of the
  no-logging-framework stance (the earlier edit had silently no-op'd).

- **Full app logging + crash breadcrumbs — shipped, BUILD-GREEN, UI-verified
  live.** Reversed the old "plain `print` is fine" stance (the May-27 crash had to
  be reconstructed from the OS `.ips` because we logged nothing). New first-party
  [`Core/Log.swift`](../LLMPro/Core/Log.swift) (`Log` enum, no third-party dep):
  every message fans out to **(a)** Apple unified logging (`os.Logger`, subsystem =
  bundle id, per-category — live in Console.app / `log stream`) **and (b)** a
  persistent **rotating file** `logs/llmpro.log` (~5 MB → `.log.1`), with
  `Log.info/.notice/.error/.fault`, `#fileID:line` capture, and `.debug` gated to
  DEBUG builds. `Log.install()` (called from `AppDelegate.applicationWillFinishLaunching`,
  before the window) wires `NSSetUncaughtExceptionHandler` + fatal-signal handlers
  (SIGSEGV/SIGABRT/SIGBUS/…) that write a **`backtrace_symbols_fd` breadcrumb to our
  log file before re-raising** (signal handler is a context-free C function with
  pre-allocated buffers — async-signal-safe-ish), so the NEXT crash leaves a stack
  trace in `llmpro.log`, not only the OS `.ips`. Wired at the real error
  chokepoints: `ProcessRunner.spawn`/`runCapturing` (every subprocess spawn + nonzero
  exit), `PythonRuntime.phase` didSet (`.failed`), `MLXServerService.state` didSet
  (`.failed`/`.ready`), `OpenAIChatClient.complete` (HTTP errors),
  `JobRegistry.markFailed` (training), `SelfImproveService.fail` (Practice),
  `AttentionInspectService` (Inspect). UI: **Settings → Logs** tab (live tail +
  Refresh / Reveal-in-Finder / Copy); renamed the stale "View bootstrap log" button
  to "Open logs folder". **Verified live**: `llmpro.log` is created at launch and
  the in-app Logs tab shows real `[app]`/`[python]`/`[server]` entries (launch
  banner, subprocess spawns, server-ready). `xcodegen` + `xcodebuild` GREEN, 0
  errors, app healthy (0% CPU, no crash). Docs: CONVENTIONS.md "considered &
  rejected" + the out-of-scope list above both updated to record the reversal.
  **Next agent: use `Log.*` at new error sites; do NOT add swift-log/CocoaLumberjack.**
  (Tooling note: Bash stdout stayed flaky — several `Edit`s silently no-op'd on
  stale offsets; all final state confirmed by Python byte-reads + `xcodebuild`.)

- **Two fixes from a Sonnet-4.6 UI stress test — BUILD-GREEN + the UX one
  UI-verified.** A separate model drove the whole UI; after filtering its report
  (it hallucinated several specifics — a non-existent "View" sub-tab, a wrong
  62-layer count, fabricated OS details — all cross-checked against disk and
  discarded), two findings were real and are now fixed:
  1. **Inspect → Thinking ignored the model picker (UX dead-end).** Old behavior:
     selecting a model in the Inspect picker then opening Thinking just said "No
     model is loaded yet — go to the Code tab." Now
     [`CoTInspectorView`](../LLMPro/Features/Inspect/CoTInspectorView.swift) takes
     the selected `DetectedModel` and, when no server is running, shows **"Load
     <model> to watch it think"** with the size/time cost + an explicit **"Load this
     model for Thinking"** button (`MLXServerService.shared.start(model:adapterPath:)`
     — a deliberate button, never an accidental multi-GB auto-load). When a server
     IS running with a *different* model it shows a mismatch banner naming which model
     actually answers. `ModelInspectorView` now passes `CoTInspectorView(model:)`.
     **UI-verified live**: the pane shows the named load button.
  2. **`.alert`-dismiss use-after-free crash (1 historical occurrence, May 27).**
     Read the REAL `.ips` faulting frames (don't trust the stress-test report's
     paraphrase — it guessed "sheet"): frame [11] `-[NSAlert
     beginSheetModalForWindow:]_block_invoke`, [12] `NSWindowEndWindowModalSession`,
     [13] `AppKitDialogBridge.updateExistingPresentation`, [14]
     `AppKitDialogBridge.updateExistingAlert`, [15] `preferencesDidChange` ←
     SwiftUI `ViewGraph.updateOutputs` → nil PC. So it's a SwiftUI **`.alert`** being
     re-evaluated by an `@Observable` change WHILE it's mid-dismiss — a use-after-free
     in the AppKit alert bridge, NOT a `.sheet`. The exposed alerts are the
     delete-confirmation `.alert`s inside `SkillsManagerView` (line 48) and
     `AgentsManagerView` (line 43): their Delete button synchronously called
     `store.delete(…)`, which bumps the `@Observable` `SkillStore`/`AgentStore`
     revision and recomputes the manager's `body` during the alert's modal teardown.
     **Fix:** `deleteSkill()` / `deleteAgent()` now defer the store mutation with
     `DispatchQueue.main.async { … }` so the alert finishes dismissing before the
     revision bump triggers re-render. Targeted at the exact race in the stack;
     low-risk (one runloop tick later). **`xcodebuild` GREEN (0 errors); UI-verified:
     deleted a skill via the confirmation alert with no crash.** (My first attempt —
     re-hosting CodeView's manager `.sheet`s on a `Color.clear` background — was
     based on a wrong "sheet" reading AND failed to apply (stale offset); CodeView is
     unchanged. Ignore any earlier note claiming that.)
  Tooling caveat (again): this session's Bash stdout AND some tool-result tails were
  garbled (grep returned wrong line numbers + injected text; reads appended duplicate
  lines). Worked around it by trusting only read BODIES (not tails), using `Write`
  wholesale for the file I owned, short self-verifying `Edit`s, and `xcodebuild` exit
  as ground truth. Re-verify any grep-based claim from this session.

- **Live model inspector — new "Inspect" tab (Weights / Attention / Thinking).
  BUILD-GREEN + parser verified exact + UI-verified live.** A 13th sidebar tab to
  look inside any local model three ways, designed Swift-first off a 3-agent
  research workflow grounded in the installed mlx-lm + the two cached models.
  1. **Weights — pure Swift, no model load, no Python.**
     [`Core/SafetensorsHeader.swift`](../LLMPro/Core/SafetensorsHeader.swift)
     reads each shard's `8-byte LE u64 header-length + JSON` header (and
     `model.safetensors.index.json` for multi-shard) — touching <1 MB of a 55 GB
     model — to enumerate every tensor's name/dtype/shape/byteSize/paramCount.
     [`Services/WeightsInspectService.swift`](../LLMPro/Services/WeightsInspectService.swift)
     builds a `ModelWeightsReport` off-main (param total, dtype histogram, per-layer
     groups, GQA/MoE/quant flags; config read prefers `text_config` for the
     multimodal wrappers, all-dims paramCount, U32-triplet quant detection).
     **Verified EXACT** via a `swiftc` harness over the REAL `SafetensorsHeader.swift`:
     Qwen3.6-27B → 1184 tensors / 27,356,728,560 params / byte-sum 54,713,457,120 ==
     index total_size; gemma-4-26b → 1043 / 25,805,936,206 / 51,611,872,412; both
     all-BF16. **UI-verified** on the 8-bit gemma: card shows 7.1B params, 30 layers,
     16q·8kv GQA, 128 experts, 2816 hidden, 262,144 vocab, "Quantized · 8-bit" +
     "Tied embeddings" badges; disclosure shows the per-layer Canvas bar chart + the
     1339-tensor table with the real U32/BF16 quant triplets.
  2. **Attention — one-forward Python+MLX sidecar.**
     [`Resources/helpers/inspect_attention.py`](../LLMPro/Resources/helpers/inspect_attention.py)
     monkeypatches `mx.fast.scaled_dot_product_attention` (the single shared kernel
     all mainstream mlx-lm archs call), recomputes `softmax(QK^T)` with GQA head
     expansion, runs ONE forward over a ≤64-token prompt, emits mean-over-heads
     seq×seq matrices per layer as JSON, restores the kernel in a `finally`. Self-pins
     memory (`LLMPRO_MEM_LIMIT_GB`, default 108; bypasses `mlx_run.py`). Emits a
     clean `unsupported` event for shared-SDPA-bypassing archs (gemma3n/llama4/
     qwen3_next/mamba/rwkv). Driven by
     [`Services/AttentionInspectService.swift`](../LLMPro/Services/AttentionInspectService.swift)
     → Canvas heatmap in `AttentionInspectorView`. **Capture math verified against
     real `mlx`** (synthetic GQA: head-expansion correct, softmax row-sums == 1.00000,
     shape (B,Hq,L,L) → PASS); py_compile clean; UI pane renders (prompt + Peek
     inside). NOT yet exercised: a full forward through a real 55 GB model
     (memory-prohibitive while the app holds ~17 GB).
  3. **Thinking — live, pure Swift, reuses the reasoning pipeline.**
     [`Features/Inspect/CoTInspectorView.swift`](../LLMPro/Features/Inspect/CoTInspectorView.swift)
     streams the already-loaded `MLXServerService` model via `OpenAIChatClient.stream`
     with `chat_template_kwargs:{enable_thinking:true}`, routing `.reasoningDelta` →
     a 💭 Thinking disclosure and `.textDelta` → the Answer. **UI-verified**: shows
     the friendly "No model is loaded yet — open the Code tab…" hint when no server.
  UI shell [`Features/Inspect/ModelInspectorView.swift`](../LLMPro/Features/Inspect/ModelInspectorView.swift)
  (model picker + Weights/Attention/Thinking segments); wired into
  [`App/RootView.swift`](../LLMPro/App/RootView.swift) (`SidebarSection.inspect`,
  "Inspect", `scope` icon); `inspect_attention` registered in
  `PythonRuntime.installHelpers()`. **`xcodegen generate` + `xcodebuild` GREEN
  (Swift 6 strict-concurrency clean, 0 errors); all three panes verified live.**
  **Deferred:** deep per-value tensor stats (bf16 Swift-doable; mlx-quantized U32
  needs a `tensor_stats.py` helper, unexercised); per-token logprobs / top-k strip
  (server caps `top_logprobs` at 11, streaming carries none → needs a non-stream
  call); attention for the exotic bypassing archs. **Tooling caveat for next agent:**
  this session's Bash *stdout* was intermittently garbled (grep returned 0 for
  strings that are present); Read/Edit/Write + Python byte-reads stayed reliable —
  trust those, and re-verify any grep-based check.

- **Reference-repo review pass — 6 improvements drawn from the prior-art repos
  ([`REFERENCES.md`](REFERENCES.md)); BUILD-GREEN.** A multi-agent audit compared
  the app to its reference projects and these landed (each build-verified):
  1. **AGENTS.md / CLAUDE.md ingest in the Code agent** (Codex / opencode / pi
     pattern). New `CodingAgentService.workspaceConventions()` reads the first of
     `AGENTS.md` / `CLAUDE.md` / `.cursorrules` / `.github/copilot-instructions.md`
     from the workspace root (8 KB-clamped) and appends it to the system prompt
     after `workspaceOverview()`, before the memory block (so a learned lesson can
     still override). Offline, pure Foundation IO.
  2. **Dense-model LoRA now adapts the FFN, not just attention** (mlx-lm LORA
     guidance + the app's own curated `qwen2.5-7b` recipe). `AutoTuner` dense keys:
     small → q/v + `mlp.gate_proj`/`mlp.up_proj`; medium/large/huge → q/k/v/o +
     `mlp.{gate,up,down}_proj`; tiny stays attention-only. (MoE path already did
     `mlp.experts.*`.)
  3. **AutoTuner now scales eval cadence + sets LoRA dropout** so the friendly
     Progress val-loss chart + 5-star rating populate on short Quick runs:
     `steps_per_eval = max(10, iters/5)`, `save_every = max(that, iters/4)`,
     `val_batches = 10`, `dropout = 0.05` (0.0 on SGD/NaN-prone bases). These set
     existing `TrainingConfig` fields in `AutoTuner.renderYAML`.
  4. **Command-output truncation keeps the diagnostic TAIL** (Codex / opencode).
     New `ToolExecutor.truncateTail` (head/4 + elision marker + tail) used by
     `run_command`, so a failing build/test's error summary at the end is no longer
     dropped. File reads / search hits stay head-truncated.
  5. **Practice overfit lever: keep up to 2 distinct passing solutions per problem**
     (rejection-sampling best practice). `self_improve_round.py` gained
     `--keep-per-problem` (dedup'd by normalized whitespace; was: keep only the
     first); `SelfImproveService` passes `--keep-per-problem 2` — roughly doubles
     dataset diversity to counter the documented pass@1 31%→9% collapse. (Note: the
     audit's claim that Practice "hardcodes lr/iters" was WRONG — `runOneRound`
     already routes through `AutoTuner.tune` and clamps iters.)
  6. **Docs: [`REFERENCES.md`](REFERENCES.md)** gained AlphaLLM (MCTS+critic
     self-improvement), autoresearch-mlx (fixed-time MLX loops), query-llm (CoT),
     ai-llm-data-visualizer (a new §⑦ Visualization), and **[`WORKFLOWS.md`](WORKFLOWS.md)
     §14 was rewritten** from a stale "REMOVED / dead code" banner (it still linked
     the deleted `AgentEditorView` and called the live managers dead) to the current
     `AgentsManagerView` / `SkillsManagerView` flow; sections 13/14 verified intact.
  **Deferred (not done):** deleting dead `AgentTemplate.swift` / `AgentProfile.swift`
  would need a `project.yml` regen (`xcodegen generate`) + dropping `AgentProfile`
  from the SwiftData schema array in `LLMProApp.swift` — left as a focused
  follow-up so a docs/quality pass doesn't churn the schema. The bigger PROPOSE
  items (pass@k eval, tiered command allowlist, cumulative cross-round keepers,
  summarizing context compaction) await sign-off. **UI-verified live (computer-use,
  fresh build):** swept all 12 sidebar tabs with **zero crashes** (app held 0% CPU /
  `S` state throughout, no DiagnosticReports). Spot-checks tied to these changes:
  **Teach** "Smart recipe ✨" preview computed through the modified `AutoTuner.tune`
  (Qwen3.6-27B → 200 steps / ~31 min / ~61 GB / warm-up+cosine) and the Advanced form
  binds the new `TrainingConfig` fields cleanly (build is the real proof those exist);
  **Code → Options** shows the live Skills toggle + "Manage skills (2)…" + "Edit team
  agents…"; **Manage skills** opens the raw-`SKILL.md` editor (both seeded skills,
  intact `---` frontmatter, ＋/−/duplicate/Reveal/Save, both link directions
  documented inline); **Edit team agents** lists all 5 roles with `orchestrator.md`
  frontmatter+body, Reset/Reveal/Save; **Memory** confirms the 108 GB Metal ceiling
  pin (M5 Max / 128 GB). Not exercised live (would need a 10–30 min run): an actual
  Teach fine-tune end-to-end with the new MLP keys / dropout / steps_per_eval in the
  rendered `config.yaml`, and a Practice run exercising `--keep-per-problem 2` — both
  are covered by the build + `py_compile` + the byte-level edit checks.

- **Skills → raw-markdown CRUD + skill↔skill / skill↔agent linking; new
  `MarkdownEditor` (substitution off) — shipped + verified.** Skills are now edited
  as **raw `SKILL.md` markdown with full CRUD** (parity with the team agents):
  `SkillsManagerView` was rewritten to mirror `AgentsManagerView` (skill list +
  monospace raw editor + ＋ New / − Delete / Duplicate + Reveal + Save).
  `SkillStore` gained raw-markdown CRUD APIs (`markdown(for:)`, `save(id:markdown:)`,
  `duplicate(id:)`, exposed `uniqueFolderID(from:)`, a `revision` counter that bumps
  on every mutation); `create(name:description:instructions:links:)` takes links;
  `delete(id:)` **scrubs** the deleted id from every other skill's links.
  **Linking both directions:** skill→skill via a `SKILL.md` `skills:` (alias
  `links:`) frontmatter (`Skill`/`SkillContext.links`); `use_skill` appends linked
  skills' names+descriptions and follows links transitively. Skill→agent via an
  agent's `agents/<role>.md` `skills:` frontmatter (`AgentDefinition.skills` /
  `TeamRole.skillIDs`); `CodingAgentService.availableSkills(for:)` scopes both the
  discovery list and `use_skill` availability — **nil (key absent) = ALL skills
  (default, unchanged), `[]` = none**. **New `MarkdownEditor`**
  (`Features/Code/MarkdownEditor.swift`): an `NSTextView` wrapper with smart
  dash/quote/text substitution, smart-insert-delete, spelling correction, and
  data/link detection all disabled, `isRichText=false`, monospaced. Both managers use
  it instead of SwiftUI `TextEditor`, which had silently turned `---` fences into `—`
  (U+2014) and broken YAML parsing (a file saved through the old editor began with
  U+2014 and parsed to name=nil/links=[]); the new editor saves exactly what's typed
  (saved file now begins with bytes `2d 2d 2d`). **`normalizeFences` safety net:**
  `SkillStore.normalizeFences(_:)` (static) rewrites any dash-only line (`-` /
  en-dash `–` / em-dash `—`) to `---`; both `SkillStore.parse` and `AgentStore.parse`
  run input through it first, so older/smart-substituted files still load (real `---`
  + body rules preserved, verified 6/6). **Create-immediately for New** in both
  managers: ＋ creates the item immediately with a placeholder name and selects it
  (rename in the markdown); the old alert-in-sheet-in-popover New flow
  (`showNew`/`newName`) was unreliable on macOS and was removed. **Deleted**
  `Features/Code/AgentEditorView.swift` (the dead per-`AgentProfile` editor; it
  referenced the old `Skill` initializer + removed skill toggles). **BUILD-GREEN;
  verified live in the UI (create→edit+link→delete cycle; saved file starts with real
  `2d 2d 2d`) and with headless tests against the real Swift code.** Docs updated
  (ARCHITECTURE / CONVENTIONS / CONTRACTS / EXTENDING / STATE + CLAUDE).

- **Agent Skills (SKILL.md packages, 3-stage progressive disclosure) — shipped +
  verified.** The Code-tab agent team now supports **Agent Skills** — reusable
  `SKILL.md` instruction packages modeled on the OpenAI Codex / Anthropic Agent
  Skills standard. This **revived the previously-dead** `SkillStore` /
  `SkillsManagerView` / `use_skill` code (left from the removed single-agent
  library, marked dead in earlier docs) and wired it into the live dynamic
  `TeamRole` team. A skill is a folder under
  [`PathResolver.skillsDir`](../LLMPro/Core/PathResolver.swift) (`skills/<id>/`)
  holding a `SKILL.md` (YAML frontmatter `name`/`description` + Markdown body) plus
  optional bundled files. **3-stage progressive disclosure**: (1) **discovery** —
  `CodingAgentService.systemMessage` appends only each skill's `name: description`
  under a `## Skills available to you` heading; (2) **activation** — when ≥1 skill
  exists and `AgentSettings.useSkills` (new Bool, default true) is on, `runRole`
  adds the `use_skill` tool and `ToolExecutor.useSkill` returns the FULL
  instructions body + the skill's folder path (new `SkillContext.dirPath`); (3)
  **execution** — the agent follows them, optionally reading bundled files.
  **Seeding**: `SkillStore.installDefaultsAndScan()` runs at launch from
  `LLMProApp`'s `.task` and, on the very first launch only (guarded by a
  `didSeedExampleSkills` `UserDefaults` flag so deletions don't reappear), seeds two
  instruction-only example skills (`conventional-commits`, `code-reviewer`). Skills
  are **team-global** (every role sees the catalogue, matching Codex/Anthropic's
  implicit-by-description model) — the old per-agent `enabledSkillIDs` on the dead
  `AgentProfile` is **superseded**. UI: Code → Options popover gains a "Skills: load
  instruction packs on demand" toggle + a "Manage skills (N)…" button (N = installed
  count) opening `SkillsManagerView` (create / edit / delete). Offline-safe (local
  Markdown, no network). **BUILD-GREEN + verified end-to-end: 8/8 headless tests
  against the real `SkillStore.swift` + live in-app UI** (toggle present, button
  shows "(2)", manager lists both seeded skills, both folders + `SKILL.md` created
  on first launch). Docs updated (ARCHITECTURE/CONTRACTS/CONVENTIONS/EXTENDING/STATE
  + CLAUDE vocab).
- **Transcript hang under *parallel* builders — follow-up fix.** The earlier
  transcript-hang fix (no `withAnimation` scroll + `fixedSize` + ~12×/sec delta
  throttle) was enough for a single builder but NOT for parallel Coder+UI: a fresh
  `sample(1)` showed the main thread again pinned 100% in
  `LazyVStack → Array.motionVectors → StackLayout` with the server at 0%. Two
  builders streaming at once (plus indeterminate `ProgressView` spinners) keep an
  ambient animation alive, so subview placement still animated. Fix: a single
  `.transaction { $0.animation = nil }` on the transcript `LazyVStack`
  (`CodeView.transcript`) hard-disables implicit layout animation. **Verified
  live:** the blazor prompt (parallel Coder+UI) now runs to completion (Plan 4/4,
  files written, final summary) and settles to 0% CPU — vs. the previous permanent
  deadlock. One transient ~15 s app-spike can still occur at the single heaviest
  moment (a long Planner message finalizing as the parallel dispatch lands) but it
  self-resolves and the run continues. See CONVENTIONS.md "Streaming-transcript
  rendering must stay cheap", rule 4.
- **Team agents are now editable Markdown files + multi-choice `ask_user` — both
  verified live.** (1) **Markdown team agents.** The five Code-tab roles
  (orchestrator/planner/researcher/coder/ui) are now defined by
  `LLMPro/Resources/agents/<role>.md` (YAML-ish frontmatter — `id`/`name`/`emoji`/
  `tint`/`tools`/`delegates`/`maxIterations` — + a system-prompt body) instead of only
  hardcoded Swift. New [`AgentStore`](../LLMPro/Services/AgentStore.swift)
  (`@MainActor @Observable`) `installAndLoad()`s at launch (from `LLMProApp`'s
  `.task`, before bootstrap): it copies each bundled file to `PathResolver.agentsDir`
  **only if missing** (so user edits persist across launches, unlike the Python helpers
  which overwrite every launch), parses each into an `AgentDefinition`, and publishes a
  `nonisolated(unsafe) static var overrides` snapshot.
  [`TeamRole`](../LLMPro/Services/AgentRoles.swift) now reads `displayName`/`emoji`/
  `tint`/`baseTools`/`delegates`/`maxIterations`/header from `AgentStore.overrides`,
  falling back to compiled-in `defaultX` when a file/field is absent (markdown is
  authoritative; the project folder/overview/tool footer are still appended in code).
  Edited in-app via [`AgentsManagerView`](../LLMPro/Features/Code/AgentsManagerView.swift)
  (Code → Options → "Edit team agents…"): Save (writes file + reloads `AgentStore`),
  Reset to default, Show in Finder. **SEPARATE from the dead `AgentProfile`/`SkillStore`
  library — not the same thing.** (2) **Multi-choice `ask_user`.** The `ask_user` tool
  gained an optional `options` arg (documented to the model as a JSON array of 2–5
  labels since `ChatToolProperty` is string-only); `CodingAgentService.parseOptions`
  parses it leniently (JSON array, else split on newlines/`|`/commas; dedup; cap 6) →
  `UserQuestion.options`; `CodeView.questionBar` renders one button per option (clicking
  calls `answerUser(option)` to steer the run) + an "Or type your own answer…" fallback.
  **Both verified live**: first launch seeded all 5 agent files, the editor listed +
  showed their markdown, editing the Orchestrator body + Save took effect next run; and
  with the Orchestrator told to ask first, the run rendered React/Vue/Svelte buttons,
  clicking "Vue" replanned a Vue app and dispatched the Coder + UI builders.
  BUILD-GREEN + UI-VERIFIED. Docs updated (ARCHITECTURE/CONTRACTS/CONVENTIONS/EXTENDING/
  STATE + CLAUDE vocab).

- **Code agent now runs the FULL 5-role team end-to-end in-app with Gemma — two
  fixes.** Verified by driving "create a blazor project that list the top 10
  cryptocurrencies" through the live Code tab on `gemma-4-26b-a4b-text` + adapter:
  Orchestrator → Planner (6-step plan) → Researcher (web_search + fetch_url found
  the real CoinGecko endpoint) → Coder + UI **in parallel** → a complete ~20-file
  Blazor project written to disk → final summary, Plan 4/4. (1) **Native tool
  calls for reasoning models:** `TeamRole.systemPrompt(…, nativeTools:)` omits the
  `<tool_call>` text-format footer when native tools are on — Gemma was copying
  that example and emitting malformed text JSON with its `<|"|>` quote token, so
  nothing dispatched after the Planner; `AgentTools.sanitizeToolBlock` also now
  un-mangles `<|"|>`→`"`. (2) **Transcript layout hang (the actual "stops after
  the Planner" cause):** a live `sample(1)` caught the main thread at 100% in
  SwiftUI `StackLayout` re-measurement + `Array.motionVectors`; since
  `CodingAgentService` is `@MainActor`, the layout spin starved the agent loop
  (server idle at 0%, app pinned at 100%). Fixed by (a) dropping `withAnimation`
  from the transcript auto-scroll, (b) `.fixedSize(vertical)` + streaming-gated
  `.textSelection` on bubble `Text`, (c) coalescing streaming deltas to ~12×/sec
  instead of per-token. After: app CPU 0–40% with self-resolving spikes, run
  completes in ~2.3 min. Model-quality nuance (not a bug): the fine-tuned Coder
  stubbed `CryptoService` with mock data instead of the researched `HttpClient`
  call — exactly the kind of gap the Teach→Practice retrain loop exists to close.
- **Made Gemma (and other "thinking" models) actually work in the Code agent —
  by disabling thinking.** The user was right that `gemma-4-26b-a4b-text` *should*
  work. Root cause (continued from the entry below): the model reasons past the
  token budget and never emits a tool call. Its chat template exposes an
  **`enable_thinking`** switch (sets an empty thought channel → skip thinking), and
  **mlx-lm's server forwards `chat_template_kwargs`** from the request body (verified
  in `server.py`; its own `--help` shows `'{"enable_thinking":false}'`). Added
  [`ChatCompletionRequest.chatTemplateKwargs`](../LLMPro/Services/OpenAIChatClient.swift);
  the agent now sends `{"enable_thinking": settings.letModelThink}` on **every** role
  request, with `letModelThink` defaulting to **false** (act directly). New Options
  toggle "Let the model think first (slower)". **VERIFIED live** against a loaded
  gemma-4-26b-a4b server: with `enable_thinking:false` it returned
  `finish_reason: tool_calls`, `reasoning_len 0`, and a clean **`call_coder`**
  delegation with a detailed Blazor task — vs. the old think-forever-never-call.
  Build green. Takeaway: for agent/tool-calling work, **disable model thinking**;
  it's the difference between Gemma working and not.
  - **Follow-up:** the run then stalled "after the Planner" because Gemma is verbose
    and its plan truncated at the 2048 `maxTokens` cap. Raised the agent's default
    `AgentSettings.maxTokens` to **4096** (with thinking off it stays fast). Verified
    headlessly: fed the Orchestrator the exact prompt + a completed Planner plan, and
    Gemma returned `tool_calls: [call_coder, call_ui]` (parallel builders, real
    self-contained tasks, 265 tokens) — i.e. it now **dispatches the builders past the
    Planner** instead of stopping. Full chain on Gemma: Orchestrator→call_planner →
    Planner plan → Orchestrator→call_coder+call_ui → builders write files.

- **Fixed the Code agent "starts then stops immediately" on reasoning models.**
  Diagnosed live against the running server: `gemma-4-26b-a4b` is a **reasoning
  model** — the `mlx_lm server` streams its chain-of-thought in a **`reasoning`**
  delta field (verified: `delta: {"reasoning": "…"}`), and the final message's
  `content`/`tool_calls` stay null until it finishes thinking (it over-thinks past
  1024+ tokens). [`OpenAIChatClient`](../LLMPro/Services/OpenAIChatClient.swift)
  only read `content`/`tool_calls`, so the Orchestrator received an empty message →
  the runRole loop treated it as a "final answer" → stopped with a blank bubble.
  Fixes: (1) parse `reasoning` deltas → new `ChatStreamEvent.reasoningDelta`,
  accumulated into `AgentBubble.reasoning` and shown as a dimmed collapsible
  **"💭 Thinking"** block ([`CodeView.ReasoningView`](../LLMPro/Features/Code/CodeView.swift));
  (2) a **no-output safeguard** in `runRole` — when a turn yields no visible answer
  and no tool call, it now posts a clear hint (raise **Max tokens**, or pick a
  coding model like **Qwen2.5-Coder**) instead of silently ending. Build green.
  Takeaway: reasoning models (Gemma-4, Qwen3-thinking, DeepSeek-R1) over-think for
  agent work; **recommend Qwen2.5-Coder-7B for the Code tab**.

- **Fixed un-clickable "Advanced settings" / "Technical details" disclosures.**
  A SwiftUI `DisclosureGroup` on macOS only toggles when you hit its **tiny
  chevron** — clicking the label row does nothing — so users couldn't open the
  Teach **Advanced fine-tuning options** (the reported bug), nor the Progress /
  Practice technical/advanced sections. Replaced the `DisclosureGroup`s in
  [`TrainingConfigView`](../LLMPro/Features/Training/TrainingConfigView.swift)
  (Teach Advanced),
  [`TrainingMonitorView`](../LLMPro/Features/Monitor/TrainingMonitorView.swift)
  (Progress Technical details), and
  [`SelfImproveView`](../LLMPro/Features/SelfImprove/SelfImproveView.swift)
  (Practice Advanced + Technical details) with a **full-width tappable `Button`
  header** (`.contentShape(Rectangle())`) + conditional content, so the whole row
  toggles. Build green; verified in the UI — Teach Advanced and Progress Technical
  details both expand on a single click anywhere on the row. (If you add a
  collapsible section, use this Button pattern, not a bare DisclosureGroup.)

- **Fixed "a lesson is already running" when none is (orphan-recovery PID reuse).**
  `JobRegistry.recoverOrphans()` decided a recovered job was `.running` purely from
  `kill(pid, 0) == 0`. After a training process dies and the app restarts, the OS
  **recycles that PID** to an unrelated live process, so `kill` succeeds and the
  dead job is resurrected as running → `activeJob` non-nil → Teach's `canStart`
  gate and the "a lesson is already running. Watch the Monitor tab or stop it
  first." banner **block all new training**. Fixed
  [`JobRegistry.isProcessAlive`](../LLMPro/Services/JobRegistry.swift) to also
  verify via `proc_pidpath` that the live PID is actually our venv python (path
  contains `python` + `llmpro`); a recycled PID belonging to another binary is
  rejected, so the job recovers as `.orphaned` instead. Build green; verified in the
  UI — after relaunch the Teach banner is gone and **Start Teaching is enabled**
  (Qwen3.6-27B-bf16 + C#/.NET selected). Note: relaunching the app while a job is
  (even falsely) "running" trips the quit dialog, so a force-relaunch was needed
  once to clear the pre-existing stale jobs; new launches self-heal.

- **Smarter fine-tune recipe — DoRA + LR schedule (the MLX-native answer to the
  "Unsloth / densification" ask).** Researched + sourced: **Unsloth can't run on
  Apple Silicon** (its speedups are NVIDIA Triton/xformers/BitsandBytes kernels,
  CUDA ≥7.0; the README's "macOS/MLX" line is the separate *Unsloth Studio*
  product, not the importable lib), and **"densification" is not a real
  fine-tuning technique** (academic MoE→dense distillation term — a conflation).
  Added the portable, mlx-lm-native equivalents that genuinely improve quality:
  (1) **DoRA** (`fine_tune_type: dora`) — AutoTuner auto-selects it for the
  **Thorough** tier; (2) a **warmup→cosine-decay LR schedule** (`lr_schedule`)
  emitted on every run. Both flow through `AutoTunedConfig` (`useDoRA`,
  `warmupSteps`) → [`AutoTuner`](../LLMPro/Services/AutoTuner.swift) →
  `TrainingConfig.renderYAML`. Surfaced as a "Smart recipe ✨" line in Teach + an
  Advanced "Warm-up + cosine LR schedule" toggle (the DoRA/Full picker already
  existed). **Also fixed a latent YAML float bug**: PyYAML parses `2e-05` as a
  *string* (needs `2.0e-05`); `TrainingConfig.yamlNum(_:)` now dot-pads every float
  we emit (`learning_rate`, `scale`, `dropout`, `lr_schedule` args). VALIDATED on a
  real Qwen3.6-27B-bf16 run through mlx_run: DoRA trains (params 1.041M), the LR
  **ramps 1e-7→8e-6 over warmup** (schedule live), peak **87.8 GB** (under the
  107.5 GB ceiling), exit 0, adapter saved. Build green. **UI-verified** in the
  freshly-built app: the Teach "Smart recipe ✨" note shows "· DoRA" on Thorough and
  drops it on Standard; the Advanced **LoRA/DoRA/Full** picker + the new **Warm-up +
  cosine LR schedule** toggle work; per-iter ETA reflects the new 8 s/iter (~71 min
  Thorough). Spot-checked Progress / Try-it-out / Code — all render, no crash.
  Side note: cleared a stale dead-PID training job that `recoverOrphans` had left
  marked "running" (it falsely blocked Start Teaching) — a pre-existing recovery
  bug worth fixing (mark dead-PID jobs failed/orphaned, not running).

- **Apple-Silicon / MLX runtime tuning (always-on).** Probed the machine
  (M5 Max, 128 GB) and found MLX's stock memory + cache limits default to
  **~121.6 GB — above the ~107.5 GB Metal working-set ceiling** (wired limit was
  0), which is why big runs hard-crash with `kIOGPUCommandBufferCallbackError…`.
  Rewrote [`mlx_run.py`](../LLMPro/Resources/helpers/mlx_run.py) to read the
  ceiling from `mx.device_info()` and re-pin `set_memory_limit` / `set_wired_limit`
  / `set_cache_limit` (cache = ceiling/2) on **every** run, and changed
  [`MemoryService.wrap`](../LLMPro/Services/MemoryService.swift) to **always**
  route mlx_lm through the launcher (was: only when the Memory-tab budget was on).
  Limits are soft (a genuinely-bigger run still proceeds); `LLMPRO_NO_AUTOTUNE=1`
  opts out; the explicit budget still overrides. Verified: `_apply_limits` pins
  107.5/107.5/53.8 GB; the launcher still dispatches mlx_lm; and a **live 27B + LoRA
  generate through the launcher** ran clean (peak 54.0 GB, exit 0, coherent output).
  Build green. Build is already `arm64`-only (`project.yml` `ARCHS: arm64`).
  Follow-up idea (not done — needs a real training run to validate, can't OOM-test
  blind): now that over-budget runs degrade gracefully, `AutoTuner`'s very
  conservative "huge" case (8 layers / seq 1024) could likely afford more layers
  for better 27B fine-tunes.

- **Full smoke test (headless) — green.** After the loop fixes, ran an automated
  smoke pass: (a) whole-app `xcodebuild` **green**; (b) a multi-agent headless
  workflow checked all **15 Python helpers + the mlx-lm CLI surface + helper
  registration** → **16 PASS · 0 FAIL** after fixing the one WARN
  ([`prepare_coding_dataset.py`](../LLMPro/Resources/helpers/prepare_coding_dataset.py)
  leaked a raw traceback when the optional `max_rows` arg was non-integer — now
  emits a clean `{"event":"error"}` and returns 2); (c) a **live** `mlx_lm generate`
  loaded the cached Qwen3.6-27B-bf16 base **+ a fine-tuned LoRA adapter** from disk
  (no download) and produced coherent output (peak 54 GB, exit 0) — live-proves the
  "use the model I trained" path the Code-tab adapter Picker now exposes. Notes:
  `mergekit` was absent from the *current* venv (helper degrades to a JSON error;
  `bootstrap()` does list it — likely a stale venv). **The interactive UI walkthrough
  then ran (computer-use, fresh build, all 12 tabs):** no crash on any tab, and all
  five loop CTAs verified live against real on-disk data — Code adapter Picker (lists
  every completed fine-tune; selecting one auto-syncs the base model), Try-it-out
  decision bar ("Train again / Use in Code / Save & Use", and "Use in Code" navigates
  via `.openCodeWithModel`), Teach "Continue a previous fine-tune?" (lists every
  adapter), Practice "Use this fine-tune" menu (Try it out / Use in Code / Reveal /
  Copy path), and Save & Use listing Teach jobs **and** the Practice run ("UI smoke —
  Practice · 2 round(s)"). The Progress completion CTA card is gated on `.completed`
  and didn't surface only because the most-recent job on this machine is incomplete
  (code/build-verified).

- **Wired the feedback loop's broken UI edges.** Ran a multi-agent
  **feedback-loop audit**: the loop (*download → fine-tune → test → use → retrain*)
  was physically complete in the backend but **broken at the UI seams** — the user
  had to copy adapter paths between tabs by hand, and the **Code tab literally
  couldn't load a fine-tuned adapter** (`startSession` passed `adapterPath: nil`).
  Closed the gaps via a new [`ModelHandoff`](../LLMPro/Core/LoopHandoff.swift)
  `{model, adapterPath?}` payload (carried as a notification `object`; receivers
  accept it OR a bare `String`) + `.openCodeWithModel`, plus user-driven completion
  CTAs across Code / Progress / Try-it-out / Teach / Practice / Export:
  (1) [`CodeView`](../LLMPro/Features/Code/CodeView.swift) adapter Picker
  (`@AppStorage("codeAdapterJobID")`) → `startSession(model:adapterPath:)` →
  `mlx_lm server --adapter-path`; (2)
  [`TrainingMonitorView`](../LLMPro/Features/Monitor/TrainingMonitorView.swift)
  completion CTA card; (3)
  [`ArenaView`](../LLMPro/Features/Chat/ArenaView.swift) accepts a `ModelHandoff`
  (model + adapter) + a "Train again / Use in Code / Save & Use" **decision bar**
  (the retrain back-edge); (4)
  [`TrainingConfigView`](../LLMPro/Features/Training/TrainingConfigView.swift)
  "Continue a previous fine-tune?" picker → `launchRefine(from:)` reusing the source
  config + `TrainingService.start(…, resumeAdapterFile:)` (→ mlx-lm
  `--resume-adapter-file`); (5)
  [`SelfImproveView`](../LLMPro/Features/SelfImprove/SelfImproveView.swift) "Use
  this fine-tune" menu + [`ExportWizardView`](../LLMPro/Features/Export/ExportWizardView.swift)
  `ExportSource` (TrainingJob OR completed SelfImproveRun) so Practice adapters are
  exportable. `RootView` now handles `.openCodeWithModel` (selects `.code`). **Fixes
  #1–#5, build green.** Design note: hand-offs are **user-driven CTAs**, not
  auto-navigation (a completing fine-tune does NOT yank the user to another tab —
  that would fight the "window-close ≠ quit, training survives" ethos). **Descoped**
  (#6/#7): an `.exportCompleted` notification (would be unobserved/dead) and a
  post-download nudge (the local-model row's "Train for coding" already wires
  Download→Teach). New centerpiece doc
  [`CONCEPT.md`](CONCEPT.md) explains the app as one loop; CLAUDE/ARCHITECTURE/
  WORKFLOWS/CONTRACTS/CONVENTIONS updated. **Next: a full in-app smoke test of the
  whole loop is in progress.**

- **Parallel-agents toggle.** Added `AgentSettings.parallelAgents` (default ON) and
  an Options toggle "Run teammates in parallel". When off, `runDelegations` runs
  delegates sequentially (one request in flight) — for smaller models. Build green.

- **Code tab became a multi-agent Orchestrator team.** Replaced the switchable
  single-agent flow with a **fixed five-role team** ([`TeamRole`](../LLMPro/Services/AgentRoles.swift):
  orchestrator 🧭 · planner 🗺️ · researcher 🔬 · coder 💻 · ui 🎨). The user talks
  only to the Orchestrator, which delegates via `call_<role>(task)` tools; >1 in a
  turn run concurrently; depth-capped at 5. New
  [`WebSearch`](../LLMPro/Services/WebSearch.swift) gives the Researcher real web
  tools (`web_search` / `fetch_url` over the DuckDuckGo HTML endpoint, no API key).
  [`AgentTools`](../LLMPro/Services/AgentTools.swift) gained `web_search` /
  `fetch_url` / `ask_user` and a per-role `specs(for:)`.
  [`CodingAgentService`](../LLMPro/Services/CodingAgentService.swift) rewritten as
  the orchestration engine (`runRole` / `runDelegations` / `ask_user` pause /
  per-role loops; auto-approve now defaults ON; `maxIterations` is per-role).
  [`CodeView`](../LLMPro/Features/Code/CodeView.swift) drops the agent picker +
  manager menu for a single shared-**Model** picker + a role-labeled, depth-indented
  transcript + a question bar. One shared `mlx_lm` model serves all roles. **Build
  green + warning-clean; `WebSearch` verified against live DuckDuckGo (9 results
  parsed).** Honest caveat: a **full in-app multi-agent run hasn't been click-driven
  yet** (the GUI was flaky during testing) — the orchestration loop reuses the
  proven single-agent loop logic plus delegation. The single-agent library
  (`AgentProfile`, `AgentEditorView`, `AgentTemplate`, `SkillsManagerView`,
  `SkillStore`) is now **dead code** — compiles, unreferenced; `AgentProfile` stays
  in the SwiftData schema only.
- **Enter-to-send + message attachments in the Code tab.** (1) Replaced the chat
  `TextEditor` with [`ChatInputView`](../LLMPro/Features/Code/ChatInputView.swift),
  an NSTextView-backed input where **plain Return sends** and **Shift+Return inserts a
  newline** (intercepts `insertNewline:` in `doCommandBy`, checking the shift modifier);
  the big Send button is replaced by a small ↑ arrow. (2) **Attachments**:
  [`Attachment`](../LLMPro/Features/Code/Attachment.swift) + a paperclip button
  (NSOpenPanel) and drag-and-drop onto the input add files, shown as removable chips. On
  send, each is turned into text the local model can use — text/code/doc files inlined as
  fenced blocks; **images run through on-device OCR (macOS Vision)** with the recognized
  text inlined (great for error/code screenshots); other binaries noted by name.
  `CodingAgentService.send(_:attachments:)` builds the combined user message (OCR runs
  off-main in the run Task); the user bubble shows attachment chips. Honest limitation:
  the `mlx_lm` server is text-only, so true image *understanding* isn't supported — OCR is
  the bridge; a vision backend (mlx-vlm) is a separate effort. Build green + warning-clean;
  the new input bar (Return-to-send hint + paperclip) confirmed rendering in the app.
- **Code tab expanded into a mini-IDE.** Added a native regex-based
  [`SyntaxHighlighter`](../LLMPro/Core/SyntaxHighlighter.swift) (AttributedString /
  NSAttributedString, ~18 languages, no WebView/JS),
  [`FileExplorerView`](../LLMPro/Features/Code/FileExplorerView.swift) (project
  tree, `OutlineGroup`, bumped on transcript change),
  [`CodeEditorView`](../LLMPro/Features/Code/CodeEditorView.swift) (editable
  highlighted `NSTextView` + Save/Revert), restructured `CodeView` into a 3-pane
  `HSplitView` (explorer | editor | chat) toggleable from a header sidebar button,
  syntax-highlighted diffs + `read_file` output in the transcript (`DiffText` /
  `ToolCardView.cardLanguage`), and
  [`AgentTemplate`](../LLMPro/Features/Code/AgentTemplate.swift) — 8
  specialized-agent presets in the New-agent flow's "Start from a template" menu.
  **Build green + warning-clean.** VERIFIED live in the app: the 3-pane layout
  renders, the file tree expands folders + lists files, opening `Program.cs` shows
  correct C# highlighting (keywords purple, types teal, strings green) with
  Save/Revert, and the template menu lists all 8 roles. Honest caveat: editor
  live re-highlight is debounced and the highlighter is a regex approximation
  (not a full grammar), so pathological code can mis-tint.
- **Direct model picker in the Code-tab header.** Added a **Model** `Picker` next to
  the Agent picker (`CodeView`), bound via `modelBinding` to the selected agent's
  `modelRepoID` (writes back to the `AgentProfile` + saves). Lets the user pick the
  coding LLM in one click instead of opening Edit-agent. A status-row hint ("press
  Restart to load <model>") appears when the chosen model differs from the one
  currently loaded (`server.model`). Verified in-UI: the header picker drops down
  all 5 local models and switches the agent's model. Model selection still takes
  effect on Start/Restart (a model swap restarts the `mlx_lm server`).
- **Parser/prompt robustness for Qwen-Coder's narrative tool-call style.** Driving
  the Blazor prompt in-UI surfaced that Qwen2.5-Coder narrates a plan with the tool
  calls embedded as ```json fences (often several per message) — NOT `<tool_call>`
  tags and not a single top-level JSON object, so `parseFallbackCalls` extracted
  nothing, treated the whole thing as a final answer, and showed the raw JSON
  (the user's "why json?"). Fixes: (1) `parseFallbackCalls` now also scans for
  ```json fenced blocks anywhere in the message and treats each JSON object with a
  known tool name as a call, in order (verified extracting 3 embedded calls); (2)
  the final-answer branch now runs `stripToolCallBlocks` too, so leftover fences /
  `<|im_end|>` never render raw; (3) `stripToolCallBlocks` strips fenced JSON tool
  calls + special tokens. After the fix, the in-UI run executed tool cards cleanly,
  scaffolded a Blazor WASM project (67 files), and recovered from a bad template
  (`blazorserver`→`blazorwasm`). Also added a **system-prompt note that
  `run_command` is a FRESH shell each call** (cwd = project root; `cd` doesn't
  persist — chain with `&&` or use `--project`), since the 7B looped on `dotnet run`
  from the wrong dir. Completion quality is bounded by the 7B coder; a stronger
  coder model finishes more reliably.
- **First full in-app agentic run — SUCCESS (closes the long-pending UI gap).**
  Drove the Code tab end-to-end in the real app: edited the "General coder" agent
  to use **Qwen2.5-Coder-7B-Instruct-4bit** (a tool-capable coder) with both
  auto-approve toggles on, started the session (model warm-loaded), and sent
  "Create a Blazor project that lists the top 10 cryptocurrencies." The agent
  **planned with `todo_write`** (a 7-step plan rendered live), ran `dotnet new` via
  `run_command` to scaffold a real Blazor project (73 files), and wrote correct
  domain code: `Models/CryptoData.cs` (CoinGecko-mapped model with
  `[JsonPropertyName]`) and `Services/CryptoService.cs` (HttpClient →
  `api.coingecko.com`, `GetTopCryptosAsync` with `order=market_cap_desc&per_page=10`).
  Confirms native-vs-fallback + plan + sandboxed `run_command` all work in the GUI,
  not just the harness. Two notes: (a) the 7B made minor sequencing slips (tried to
  read/edit `.csproj` around `dotnet new`, surfaced as red tool cards — harmless);
  (b) **fixed a display leak** — Qwen-Coder emits tool calls as ```json fences with
  `<|im_end|>` tokens, which showed raw in the transcript; `stripToolCallBlocks` now
  also strips fenced JSON tool calls + special tokens so bubbles show only prose.
  (GUI driving required adding macOS "Dictation" to the computer-use allowlist —
  its overlay had been intercepting clicks.)
- **Code-tab "Options" → popover, and a tool-call sanitizer for messy models.**
  Two follow-ups from driving the app: (1) The flattened inline Options disclosure
  (see next entry) still misbehaved in the header, so Options is now a **popover**
  off a gear button (`showOptions` drives `.popover`) — it renders in its own window,
  fully decoupled from the header/transcript layout, so it can't cycle or clip.
  (2) **Tool-call sanitizer.** Testing the prompt "Create a Blazor project that lists
  the top 10 cryptocurrencies" against the default agent (`gemma-4-26b-a4b`) exposed
  that gemma doesn't return native `tool_calls` via mlx-lm and its text tool-calls
  leak special tokens (e.g. `{"command":"dotnet --version<|"|>"}}` + a trailing
  `<tool_call|>`), which broke JSON parsing and stalled the loop after one step.
  Added `AgentTools.sanitizeToolBlock` (strips `<|…|>`, `<tool_call|>`,
  `<end_of_turn>`, etc.) applied before parsing in `parseFallbackCalls`, mirrored in
  `tools/agent_smoke.py`. The default gemma agent (and other weak/odd models) now
  survives slightly-malformed tool calls. dotnet 10 is present, so the agent can
  scaffold a real Blazor project. Build green.
- **Fixed Code-tab freeze when expanding "Options".** The Options `DisclosureGroup`
  in the Code-tab header revealed a nested `ScrollView` (the Server-log view, capped
  with `maxHeight: 160`) plus nested `DisclosureGroup`s. That nested ScrollView sat
  in the flexible header `VStack` directly above the transcript `ScrollView` in the
  same `VStack(spacing: 0)` — two ScrollViews competing for vertical space with
  circular constraints sends SwiftUI's macOS layout into a cycle (beachball),
  triggered even with an empty log (matching the "no model loaded" repro).
  **Fix:** flattened `optionsForm` in `CodeView.swift` — removed the nested
  ScrollView and the nested Advanced/Server-log `DisclosureGroup`s; Advanced and
  Server log are now plain labeled sections, and the server log renders as plain
  `Text` (last 20 lines) only when non-empty. The header is now plain growing
  content with the transcript as the view's only `ScrollView`. Rebuilt + relaunched;
  could not click-verify in-session because a macOS Dictation overlay was
  intercepting clicks.
- **Full agent coding support: glob, task planning, diff previews, replace_all.**
  Brought the agent's toolset to parity with full coding agents (opencode/pi/
  claw-code) while staying single-agent (orchestration still deferred, per the
  earlier "switchable library" choice). Added: **`glob`** (find files by
  `*`/`**`/`?` pattern; `globToRegex` translation verified on 11 cases incl.
  cross-folder `**`, basename-vs-path, root-level `**`); **`todo_write`** — the
  agent records a checklist that renders in a live **Plan panel** (`PlanView`),
  intercepted in `CodingAgentService` (updates `todos`, not the workspace);
  **diff previews** — `write_file`/`edit_file` compute a `- / +` diff
  (`ToolResult.displayDetail` + `ToolExecutor.previewDiff`) shown on the tool card
  *before* approval (auto-expands on pending approval; rendered by `DiffText`),
  never sent to the model; **`edit_file` `replace_all`**; and a short **workspace
  overview** injected into the system prompt for grounding. Extended
  `tools/agent_smoke.py` with glob + todo_write and re-ran it. Build green,
  warning-clean in changed files.
- **Made the coding tool complete: end-to-end verified + streaming + context guard.**
  Drove the agent loop end-to-end against real local models with a faithful Python
  harness (`tools/agent_smoke.py`) mirroring `MLXServerService` + `CodingAgentService`
  + `ToolExecutor`. **Qwen3.6-27B-bf16 PASSED with native `tool_calls`**
  (warm-load 5.3 s → `read_file` → `write_file` → correct finish; SUMMARY.md content
  accurate) and **Llama-3.2-1B-4bit** exercised the `<tool_call>` text-fallback path.
  This proves both tool-calling paths, the server lifecycle, sandboxed execution,
  and loop termination work against real models. Improvements shipped:
  (1) **live SSE streaming** — `OpenAIChatClient.stream` parses `chat.completion.chunk`
  frames (content + tool_call deltas); `CodingAgentService` streams assistant text
  into the bubble with a “Working…” indicator (SSE shape confirmed against the live
  server). (2) **Context-growth guard** — `prunedWire()` keeps system + recent
  history within a ~48 KB budget, snapped to a clean turn boundary. (3) **Fallback
  parser hardened** — accepts `"parameters"` as an alias for `"arguments"` (a real
  gap the 1B run exposed). (4) **System-prompt hardening** — tells the model to use
  real paths, never copy the example. Build green + warning-clean in all new files.
  Remaining manual check: hand-driving the SwiftUI UI (the harness validates the
  identical protocol the Swift code uses).
- **Agent library + skills manager (built on the Code tab).** Made the Code tab
  agent-driven: a switchable library of named, saved agent profiles plus a
  SKILL.md skills system, both managed from inside the tab. **One agent runs at a
  time** — this is the foundation; orchestration / sub-agents are explicitly
  deferred. Two new files:
  [`AgentProfile.swift`](../LLMPro/Models/AgentProfile.swift) (a SwiftData
  `@Model`: name / emoji / detail / model / optional adapter job / instructions /
  the auto-approve + native-tools toggles / temperature / max-tokens /
  max-iterations / `enabledSkillIDs` / createdAt, with a computed `agentSettings`
  bridge; added to `LLMProApp`'s `modelContainer`) and
  [`SkillStore.swift`](../LLMPro/Services/SkillStore.swift) (`@MainActor
  @Observable` manager of SKILL.md packages under the new `PathResolver.skillsDir`
  — `scan` / `create` / `save` / `delete` / `importSkill` / `contexts(for:)`; the
  folder-name slug is a STABLE id so a rename rewrites only the frontmatter and
  agent references survive). Modified:
  [`PathResolver`](../LLMPro/Core/PathResolver.swift) gained `skillsDir`
  (`~/Library/Application Support/LLMPro/skills/`);
  [`AgentTools`](../LLMPro/Services/AgentTools.swift) gained a `use_skill` tool
  (read-only → auto-approved; `specs(includeUseSkill:)` advertises it only when the
  agent has skills; `ToolExecutor.skills` + a `useSkill` handler return the named
  skill's instructions) — **progressive disclosure** modeled on Anthropic Skills
  (the prompt lists only name+description until the model calls `use_skill`);
  [`CodingAgentService`](../LLMPro/Services/CodingAgentService.swift)'s
  `startSession(...)` now takes agentName / instructions / skills / settings and
  the system prompt appends the role + an enabled-skills list. The Code tab
  ([`CodeView`](../LLMPro/Features/Code/CodeView.swift)) replaced the model +
  adapter pickers with an **agent picker** + a manager menu (`slider.horizontal.3`:
  New / Edit agent, Manage skills); `prepare()` seeds a default "General coder" on
  first run and restores `@AppStorage("codeSelectedAgent")`. Two new sheets:
  [`AgentEditorView.swift`](../LLMPro/Features/Code/AgentEditorView.swift)
  (create/edit a profile) and
  [`SkillsManagerView.swift`](../LLMPro/Features/Code/SkillsManagerView.swift)
  (list/create/edit/delete skills + a `SkillEditorView`). **No other new
  app-support dirs and no new Notification.Names**; `AgentProfile` is an additive
  entity. **Honest verification: compile-verified (BUILD SUCCEEDED), new files
  warning-clean.** The SKILL.md round-trip logic is straightforward, but a FULL
  in-app run (create an agent + a skill, run a task through the UI, watch
  `use_skill` fire) is still **pending** — same hand-off level as the underlying
  Code-tab feature below. "Multi-agent" here = a switchable library, not
  orchestration.

- **New "Code" tab — agentic coding assistant over a local `mlx_lm server`.**
  Added a sidebar tab (right after "Try it out", icon
  `chevron.left.forwardslash.chevron.right`) that drives an agent loop with the
  user's local, optionally fine-tuned MLX model. The model reads/edits files and
  runs commands inside a user-chosen project folder. Five new files:
  [`MLXServerService.swift`](../LLMPro/Services/MLXServerService.swift) (runs
  `python -m mlx_lm server` as a long-lived daemon — resolve model path → free
  port → spawn → poll `/health` → 1-token warm-up → `.ready`; the model loads
  ONCE and is reused per turn, finally answering the long-open model-pinning
  question), [`OpenAIChatClient.swift`](../LLMPro/Services/OpenAIChatClient.swift)
  (minimal non-streaming `/v1/chat/completions` client),
  [`AgentTools.swift`](../LLMPro/Services/AgentTools.swift) (read_file/list_dir/
  grep/write_file/edit_file/run_command toolset + `ToolExecutor` with workspace
  sandbox + 16 KB truncation + native-tools `specs` + `<tool_call>` fallback
  parser), [`CodingAgentService.swift`](../LLMPro/Services/CodingAgentService.swift)
  (the loop: native `tool_calls` → `role:"tool"` results, else fallback
  `<tool_call>` text → `<tool_result>` results fed back as one user message;
  per-tool approval gate — read-only auto, write/edit/run gated), and
  [`CodeView.swift`](../LLMPro/Features/Code/CodeView.swift) (folder/model/
  adapter pickers, server-status dot, Options/Advanced/Server-log disclosures,
  tool cards, inline Allow/Deny bar). `RootView.SidebarSection` gained a `.code`
  case. **Dual tool-calling** (send native `tools` AND instruct/parse the
  `<tool_call>` text format — small fine-tunes often lack a tool-aware template;
  the fallback matches Qwen's native emission, doubling as a safety net).
  **No new app-support dirs or Notification.Names** — only `@AppStorage("codeWorkspacePath")`.
  Build green (BUILD SUCCEEDED); `mlx_lm 0.31.3 server` flags verified;
  Qwen3.6-27B-bf16 template confirmed to emit `<tool_call>`; fallback parser
  verified on nested/multi-call/code-fenced inputs. **A full in-app agent run is
  still pending** (left for the user to drive). Deferred: token streaming, context
  compaction, a tiered permission allowlist.

- **New "Memory" tab — expert & memory management (full UI, verified on-device).**
  Added a sidebar tab (between Fusion and Save & Use, icon `memorychip`) backed by
  `Services/MemoryService.swift` + `Features/Memory/MemoryView.swift`, with four
  sections:
  1. **Live memory** — system unified-RAM in use vs **Metal's recommended
     working-set ceiling** (the real OOM threshold, which the OS RAM gauge hides)
     vs total. Ceiling/device come from `mem_probe.py`; the live used number comes
     from `SystemMetrics` (unified memory already includes GPU buffers).
  2. **Where a model's memory goes** — expert vs non-expert split read from
     safetensors *headers only* (no weight load) via `model_memory.py`. For the
     Gemma-4 MoE it shows 48.07 GB resident, **88% experts**, only ~8.19 GB active
     per token (top-8 of 128). Works for dense models too (0 experts).
  3. **Expert usage profiler** (EXPERIMENTAL) — `profile_experts.py` loads the MoE,
     runs prompts, and records router top-k selections per layer. Verified on real
     Gemma-4: found 30 router projections, `counts.sum() == decisions×top_k`
     exactly. Cold experts get a one-click **Prune** (routes to
     `ExpertManagementService.remove`). Router detection is architecture-agnostic:
     any module with a 2-D weight whose first dim == num_experts, tapped by
     patching `nn.Linear`/`nn.QuantizedLinear.__call__`.
  4. **Memory budget** — optional cap (% of ceiling) applied to training +
     inference via the new `mlx_run.py` launcher, which calls `mx.set_memory_limit`
     before exec'ing the real mlx_lm module. `MemoryService.wrap()` prepends it +
     sets `LLMPRO_MEMORY_LIMIT_BYTES`; `TrainingService` and `InferenceService`
     route through it (no-op when the budget is off).
  - **Fixed a pre-existing `SystemMetrics` bug**: the RAM gauges read 0/0
    everywhere (Home, Progress) because the poller was started per-view in
    `.task`/`onAppear` while `DashboardView.onDisappear` called `stop()` — a
    navigation race left the single poller cancelled. Now started once at app
    launch (`RootView .task`), `start()` is idempotent (won't cancel a live task),
    the Dashboard no longer stops it on disappear, and `total` uses
    `ProcessInfo.physicalMemory`. Verified live: 15.9 GB in use / 108 GB ceiling /
    128 GB total.
  - New helpers registered in `PythonRuntime.installHelpers`: `mem_probe`,
    `model_memory`, `profile_experts`, `mlx_run`. (Reminder: re-run `xcodegen
    generate` AFTER creating a new helper/Swift file — I hit a miss where
    `mlx_run.py` wasn't bundled because xcodegen ran before it existed.)

- **Unified Model-Modify pipeline: expert CRUD + vision-strip + quantize in one
  pass.** Previously expert editing (`ExpertManagerView` / `ExpertManagementService`)
  and the strip→abliterate→quantize pipeline (`ModelModifyView` /
  `ModelModifyService`) were two separate flows. Now `ModelModifyService.run`
  takes an optional `expertOp: ExpertOperation` and runs a 4-stage pipeline:
  **1 strip → 2 manage-experts → 3 abliterate → 4 quantize** (each optional,
  intermediate stages write to `<final>.stageN-tmp` dirs cleaned up at the end;
  `destFor` was generalized to "temp if any later stage enabled"). `ModelModifyView`
  gained an **Edit experts** section (shown only when `model.isMoE`) with
  Add / Remove / Modify sub-modes — so e.g. *add 2 experts + remove vision +
  shrink to 8-bit* is one "Make new model" click. The standalone `ExpertManagerView`
  (context-menu "Manage experts") is kept for expert-only quick edits.
  - **Fixed a latent bf16 bug in `manage_experts.py`**: it used `safetensors.numpy`,
    which CANNOT load bfloat16 (the dtype of every modern MoE incl. Gemma-4). Ported
    all tensor I/O + the add/remove/modify math to `mlx.core` (same pattern
    `strip_vision.py` already uses): `mx.load` / `mx.save_safetensors(metadata={"format":"mlx"})`,
    math via `mx.stack`/`mx.concatenate`/`mx.take`/`mx.expand_dims`/`mx.mean` with a
    transient float32 upcast for noise, `mx.eval` after each layer to bound peak
    memory to ~model size. **Verified on the real Gemma-4-26B-A4B-it-bf16**: a
    targeted probe loaded `language_model.model.layers.0.experts.switch_glu.gate_proj.weight`
    as bf16 `[128, 704, 2816]` and confirmed add `[128→131]`, remove `[128→126]`,
    modify (shape kept, slot 7 changed / slot 6 untouched), and router resize all
    produce correct shapes + dtype. Compile-clean (BUILD SUCCEEDED) and helper
    re-copied on relaunch. NOT YET run as a full 52 GB end-to-end through the UI
    (math + orchestration both verified separately; a full run writes ~52 GB so it
    was left for the user to drive on demand).
  - **Non-MoE regression check (done):** the expert stage is purely additive and
    gated. For a dense model `model.isMoE` is false → the Edit-experts section
    isn't rendered, `buildExpertOp()` returns nil, `expertOpIsValid` is false (so
    `canRun` = strip||abliterate||quantize as before), and `expertSuffix()` is "".
    The generalized `destFor` is behavior-identical to the old two-element version
    for every non-expert stage combination (verified by tracing strip-only,
    strip+quant, abliterate+quant). The strip/abliterate/quantize stage methods
    were not touched. Confirmed live: `mlx-community/Qwen3.6-27B-bf16` (model_type
    `qwen3_5`, no `num_experts`) is detected non-MoE, and `manage_experts.py`
    refuses a non-MoE source in 0.04 s (exit 6, before any weight load, no output
    dir written) as defense-in-depth.

- **Big feature arc: Model Fusion (mergekit) + MoE fine-tuning + per-expert
  LoRA + sparse-upcycling expert addition + tooltips/hyperlinks across all
  advanced settings.** Built in a single autonomous session while user was AFK.
  Shipped (all compile-clean):
  - **Fusion tab** (new sidebar entry between Practice and Save & Use). Wraps
    mergekit via a new `merge_models.py` helper. Supports SLERP / Linear /
    TIES / DARE-TIES. Refuses quantized inputs with an actionable error
    (mergekit loads via HF transformers which doesn't understand MLX's
    quantization block). Lazy mergekit installer — `PythonRuntime.installMergekit`
    is called by `FusionService.run` before the first merge if mergekit isn't
    importable yet, so users with pre-feature venvs don't need to nuke the
    runtime. Per-method param UI: t-slider for SLERP, density-slider for
    TIES/DARE, per-model weight sliders for Linear.
  - **MoE detection.** `ModelRegistry.DetectedModel` now reads
    `num_local_experts` / `num_experts` (and `ffn_config.moe_num_experts` for
    DBRX) from config.json and exposes `isMoE` + `numExperts` +
    `expertsPerToken`. `AutoTuner.tune(model:duration:...)` is a new
    architecture-aware overload that swaps in MoE-appropriate LoRA target
    keys when MoE detected. Mixtral family targets
    `block_sparse_moe.experts.w1/w3`; Qwen-MoE / OlmoE / Granite-MoE / Gemma-MoE
    family target `mlp.experts.gate_proj/up_proj`. mlx-lm matches keys via
    substring, so these short patterns hit every expert across every layer.
  - **Per-expert LoRA targeting UI** in Teach Advanced. When the chosen base
    is MoE, a new Section appears with a "Pick specific experts" toggle. ON
    reveals an `ExpertPickerGrid` (LazyVGrid of chip-buttons numbered 0..N-1)
    with All/None shortcuts. Selected indices generate keys like
    `mlp.experts.3.gate_proj`. Defaults to "Tune all experts" via the auto
    MoE pattern.
  - **Sparse upcycling — Add experts.** New `add_expert.py` helper +
    `ExpertExpansionService` + `AddExpertView` sheet. Clones the last expert
    N times with small Gaussian noise + widens each layer's router. EXPERIMENTAL
    badge + warning banner: "Without follow-up fine-tuning, the expanded
    model behaves almost the same as the original. Plan a Teach run after this
    completes." Auto-detects Mixtral vs Qwen-style naming; updates
    config.json's expert count; writes single-shard safetensors. Triggered
    from Models tab context menu, only shown when `local.isMoE`.
  - **HelpHint reusable popover component.** Info-circle icon → popover with
    title + plain-language body + "Learn more →" hyperlink. Used everywhere
    Advanced settings appear. Convenience `LabeledHint` wrapper for label-
    plus-hint rows.
  - **Tooltips applied to:** Teach Advanced (LoRA method, Iterations, Batch
    size, Trainable layers, Max seq length, Learning rate, Gradient
    checkpointing, Mask prompt, Optimizer, LoRA rank/scale/dropout, Experts/MoE),
    Modify (strip vision, abliterate, quantize), Practice (rounds, candidates
    per problem, problems per round, training iterations per round), and
    Fusion (merge method, model picker, blend factor t, density). Hyperlinks
    point to mlx-lm docs, mergekit blog (Maxime Labonne), HuggingFace MoE
    blog, mergekit method papers (TIES → arxiv 2306.01708, DARE → arxiv
    2311.03099, sparse upcycling → arxiv 2212.05055), PEFT docs, HumanEval
    repo.
  - **C#/.NET dataset presets added.** Two new entries in
    `CodingDatasetCatalog` + corresponding splitters in `prepare_coding_dataset.py`:
    `dotnet-csharp-50k` (`Nan-Do/instructional_code-search-net-csharp`, ~50K
    pure C# instructions — best for .NET / Blazor focused fine-tunes) and
    `code-instructions-122k` (`iamtarun/code_instructions_122k_alpaca`,
    broad multi-language with C# included). The Nan-Do dataset uses
    UPPERCASE field names (INSTRUCTION / RESPONSE) — handled in
    `split_dotnet_csharp`.

  Status: all five phases compile clean (xcodebuild ** BUILD SUCCEEDED **).
  End-to-end UI tested by launching the app — Fusion sidebar entry appears,
  Models tab shows Add experts (MoE) context menu, HelpHint popovers
  render. Mergekit subprocess + add_expert.py NOT yet verified end-to-end
  via the UI — pending user follow-through on the actual merge / expert
  expansion. Both helpers were unit-checked by reading their JSON-event
  output structure; integration with FusionService / ExpertExpansionService
  follows the same proven pattern as ModelModifyService → strip_vision.py
  / abliterate.py.

- **LM Studio update wiped uploaded models — restored, layout still works.**
  User reported all their previously-uploaded models disappeared from LM
  Studio after updating. Investigation: `~/.lmstudio/models/` was empty
  except for a `.DS_Store` (the LM Studio updater clears that dir on
  upgrade). Confirmed the new LM Studio version still uses the same
  `<HOME>/.lmstudio/models/<publisher>/<name>/` layout — verified against
  `~/.lmstudio/.internal/bundled-models/` (which uses `nomic-ai/nomic-embed-
  text-v1.5-GGUF/<gguf>`) and `download-jobs-info.json`'s `rootDir` field
  (still `/Users/josh/.lmstudio/models`). So the LLMPro Send-to-LM-Studio
  path doesn't need code changes — the destination is unchanged.
  Restored the user's `Qwen3.6-27B-bf16-text` (27 GB) via the same
  `cp -cRL` clonefile trick. Free disk stayed at 1.5 TB throughout (APFS
  CoW). User can re-send any other models via the existing ✈ icon in the
  Models tab — same flow as before.
- **Re-ran full FT on "Qwen3.6-27B-bf16-text" + dotnet + Thorough; new detector
  now headlines correctly.** User wanted to test full FT on the strip-only
  bf16 model. Important finding: the model named `Qwen3.6-27B-bf16-text`
  on disk is **actually quantized 8-bit** (the user renamed an earlier
  strip+8bit output without the `-8bit` suffix) — `config.quantization = {bits:
  8, group_size: 64, mode: affine}`, 27 GB, 6 shards. So the run hit the
  same `QuantizedMatmul::vjp` wall. This time my detector — added in
  TrainingService's stderr watcher in the previous turn — correctly fired:
  headline read *"Full fine-tune doesn't work on quantized (8-bit / 4-bit)
  weights — mlx can't compute gradients through them. Switch to LoRA or
  DoRA in Advanced settings, or use the bf16 / fp16 version of this model
  as the base."* Important debug lesson learned along the way: the first
  attempt didn't fire the detector because the running app was a stale
  binary (PID started 31 min before the latest build). Rebuilding alone
  doesn't replace the running app on macOS — must `pkill && open` after
  every TrainingService change. Worth highlighting for future sessions.
  Also clarified an earlier user observation: "when I quantize and remove
  vision I cannot train" is overstated — job `B1AE1B9A` (strip+8bit + dotnet,
  LoRA + safe-mode) actually trained 50 iterations before failing. The
  loss went 1.493 → 1.770 → 1.637 → 1.794 → 1.989: training started,
  diverged around iter 20 (loss going UP), then crashed. So the issue isn't
  "can't train" — it's "Qwen3.6-27B-8bit numerical instability under SGD
  safe-mode + this dataset class diverges around iter 50". For a stable
  coding fine-tune on a 27B base, use the bf16 base (LoRA on it trained
  for 30 iters successfully in job `25894F6E` with loss going DOWN before
  OOMing around 90 GB peak memory).
- **Tested full FT on Qwen3.6-27B-bf16-8bit + dotnet + Thorough — confirmed
  it can't work, and improved the error surfacing.** User requested the run
  as a diagnostic. Pre-flight math: full FT of a 27B model needs ~95 GB
  minimum with SGD and no AdamW buffers; with AdamW (`m` + `v` state) it's
  ~300+ GB. The 128 GB Mac can't fit it regardless of base precision. AND
  mlx-lm 0.31 doesn't support full FT on quantized bases at all. Drove it
  through Teach → Advanced → Full fine-tune → Start. Loaded model (40 GB
  resident), reached iter 1's val pass (val loss 1.275 — forward pass
  works without gradients), then crashed on first train step with the
  expected error:
  `RuntimeError: [QuantizedMatmul::vjp] no gradient wrt the quantized
  weights.`
  Total wall-clock to failure: 26 seconds. Improvement shipped: added a
  detector in `TrainingService` stderr handler that matches
  `QuantizedMatmul::vjp` / `no gradient wrt the quantized weights` and
  surfaces an actionable message: "Full fine-tune doesn't work on quantized
  (8-bit / 4-bit) weights — mlx can't compute gradients through them.
  Switch to LoRA or DoRA in Advanced settings, or use the bf16 / fp16
  version of this model as the base." Mirrors the existing NaN-loss
  fail-fast pattern. Next attempt on this config will headline with the
  meaningful message instead of "exit 1".
- **Dataset Shrink action added — logic verified, UI button has a click bug.**
  New `Shrink…` context-menu item on every dataset row in the Lessons tab.
  Opens a sheet with two sliders (Keep at most N training rows, Drop rows
  over N characters), auto-named output `<orig>-small`. Backend: pure-Swift
  JSONL filter — reads source train/valid/test, takes first N rows under
  the char cap, writes to a new datasets dir, inserts SwiftData record.
  Logic verified via a direct Python port of the algorithm: dotnet 19.2 MB
  → 1.1 MB (94.5% reduction), exactly as designed.
  **Known issue**: the "Make smaller dataset" button's action isn't firing
  on mouse click for reasons I couldn't pin down — clicks register at the
  system level, button isn't disabled, cancel button on the same sheet
  works, both ButtonStyle and keyboardShortcut(.defaultAction) attempted.
  Possibly a SwiftUI focus-eating interaction with the auto-selected
  TextField, or a sheet-specific quirk on macOS 14+. The feature ships as
  intended structurally; UI click needs follow-up. For now users can
  invoke shrink-equivalent logic via the prepare flow with a smaller
  max_rows when downloading datasets fresh.
- **Combined strip+quantize verified end-to-end on Qwen3.6-27B-bf16 — 48%
  reduction in one click.** User wanted to see a bigger size cut from
  the strip flow. Chained both stages (Remove vision + Shrink → 8-bit) in
  a single Modify-sheet job. Result on disk:
  - **Original**: Qwen3.6-27B-bf16 — 54.74 GB
  - **Strip alone**: 53.81 GB (−921 MB, the vision tower only)
  - **Strip + 8-bit quantize**: **28.6 GB** (−48% from original)
  6 safetensors shards (down from 11), config has `vision_config` absent,
  `quantization: {group_size: 64, bits: 8, mode: affine}` set, `language_model_only: True`,
  `model_type: qwen3_5` preserved. mlx_lm.utils.load() succeeded in 2.7 s,
  generation works (Qwen's normal "Thinking Process" output). The output
  name `Qwen3.6-27B-bf16-text-only-8bit` will trigger AutoTuner's safe-mode
  automatically (matches `qwen3.6` + `8bit` in `isNumericallyUnstableBase`)
  so training the result is also stable. Also caught a small bug while
  driving the UI: `ModelModifyService.run` had `guard active == nil`
  which silently refused new runs when a previous job had ended in `.failed`
  (and the auto-clear only fired on `.finished`). Fixed to also clear
  stale terminal states on a fresh `run()` call.
- **Three asks in one pass: deep size audit + training-memory reduction +
  coding-agent shortcut.** User reported (1) suspicion that stripped size
  was still wrong, (2) OOM during training, (3) want a one-click "fine-tune
  this for coding and ship to LM Studio".
  1. **Deep audit of Qwen3.6-27B-bf16** (every tensor with bytes, grouped
     by top-level prefix): 851 `language_model.*` tensors = 53.79 GB; 333
     `vision_tower.*` tensors = 0.92 GB (already removed). The two biggest
     individual tensors are `embed_tokens.weight` and `lm_head.weight`,
     each 2.43 GB (248K vocab × 5120 hidden). Conclusion: **there is no
     more reducible mass at bf16** — the only paths to shrink further are
     `Shrink → 8-bit (~27 GB)` or `Shrink → 4-bit (~13 GB)`. Documented
     in CONVENTIONS as user-facing expectation.
  2. **AutoTuner huge-model defaults made memory-conservative.** Was
     `max_seq=2048, layers=16, grad_accum=4`; now `max_seq=1024, layers=8,
     grad_accum=1`. Large bucket also tightened (`max_seq=1536, layers=12,
     grad_accum=2`). Saves ~15–20 GB of peak unified memory on 27B bf16.
     Added `estimatedPeakMemoryGB` field to `AutoTunedConfig` that the Teach
     view renders as either *"Will use about 61 GB of your 128 GB unified
     memory"* (informational) or *"Might run out of memory: needs ~N GB of
     your X GB. Try shrinking the model first."* (warning, when headroom
     < 8 GB). Verified: Qwen3.6-27B-bf16 + dotnet + Standard now shows
     "61 GB / 128 GB" — well within bounds.
  3. **Coding-agent shortcut.** New green `</>` icon on each model row + a
     "Train for coding agent" context-menu item. Posts a new
     `.openTrainingForCoding` notification with the model's repoID; Teach
     handles it by auto-selecting the first coding-looking dataset (matches
     names containing `codealpaca`, `magicoder`, `dotnet`, `coder`, `code-`),
     auto-naming `<model>-coder`, and switching to Standard duration. User
     just hits Start Teaching. Verified end-to-end: click on Qwen 27B's
     `</>` icon → Teach pre-filled with model + dotnet dataset + name
     `Qwen3.6-27B-bf16-coder` + Standard + memory estimate visible.
- **Strip-vision size correctness audited byte-for-byte.** Re-ran strip on
  Qwen3.6-27B-bf16, then audited each of the 11 output shards against
  source. Result: shard 1 (which holds all 333 vision tensors) dropped
  exactly 921,497,944 bytes; shards 2–11 are functionally identical to
  source (±16 bytes of safetensors header alignment). Total stripped:
  50.098 GiB = 53.81 GB decimal. The 921.5 MB matches three independent
  measurements: (1) helper's `dropped_bytes` event, (2) on-disk shard delta,
  (3) sum of `mx.nbytes` for removed tensors. The UI's "54.74 GB" / "53.81 GB"
  uses decimal `ByteCountFormatter` (GB = 10⁹); the same bytes are 50.98 GiB
  / 50.10 GiB in binary. The probe also revealed Qwen3.6's vision tower is
  27 ViT blocks + merger + patch_embed + pos_embed = ~460M params at bf16 =
  0.86 GiB / 921 MB exactly, which is 1.7% of the model. **Nothing is wrong;
  the small absolute number is just the structural reality of a 27B text +
  small-ViT model.**
- **Strip-vision savings explained (probed).** User reasonably asked why
  the 921 MB strip-vision reduction on a 27B VLM was so small. Probed the
  source tensor-by-tensor: Qwen3.6-27B-bf16 has 1,184 tensors totaling
  50.96 GB; of those, 333 are in `vision_tower.*` (27 ViT blocks + merger
  + patch_embed + pos_embed) totaling exactly **0.86 GB (1.7% of model)**.
  A second sweep with a broader substring regex
  (`vis|visual|image|vit|projector|encoder_image|multi_modal|mm_|patch_embed|qformer|resampler`)
  returns the same 333 keys — nothing missed. Structurally, vision encoders
  for large VLMs are ~300–600M params; against a 27B text model that's
  always under 5%. Worth documenting in CONVENTIONS as user expectation:
  for meaningful shrinkage on big VLMs, strip+quantize in one click — strip
  alone is intentionally a 1–5% trim.
- **Strip-vision verified end-to-end on Qwen3.6-27B-bf16.** Modify dialog
  auto-detected the VLM (qwen3_5 architecture marker triggered the init
  heuristic), pre-checked "Remove vision capabilities", auto-named output
  `Qwen3.6-27B-bf16-text-only`. Strip ran in ~8 seconds for the 54 GB
  source. New UI feedback worked: **"Removed 921.5 MB of vision weights."**
  Source 54.74 GB → stripped 53.81 GB (matches the reported 921.5 MB delta
  exactly). Output validated:
  - Registry detected the new model with correct architecture (qwen3_5)
    and quantization (fp16) metadata
  - config.json correctly mutated — `vision_config` removed,
    `language_model_only: True` added, `text_config` preserved
  - `mlx_lm.utils.load()` succeeded on the stripped dir in 3.6 s
  - Generation works: producing the model's normal reasoning-style output
    ("Thinking Process: 1. **Deconstruct the request:** ...")
  Confirms physics-imposed savings limit for VLMs in this class: vision
  encoder is 1–2% of total params on a 27B model. For larger size cuts,
  pair with the Shrink (quantize) toggle.
- **Quantize verified end-to-end through the UI on GLM-4.7-Flash-bf16.**
  Followed the user's "run it" instruction: Modify → Shrink (quantize) →
  8-bit → Make new model. Live progress surfaced through the new
  `.quantizing(bits:, message:)` stage ("Shrinking to 8-bit — [INFO]
  Quantized model with 8.502 bits per weight."). Total wall-clock about
  2 minutes for a 60 GB → 30 GB conversion. Final state:
  `GLM-4.7-Flash-bf16-8bit · glm4_moe_lite · 8bit · 31.84 GB` appeared in
  the registry as MLX-ready, alongside the untouched 59.91 GB original.
  7 safetensors shards (vs 13 in source). Free disk dropped from 1.5 TB
  → 1.4 TB (i.e. ~30 GB consumed, exactly matching the new file size — no
  CoW magic possible here since quantize is a genuine bit-width transformation).
  The user can now train on the 30 GB version, fitting comfortably in memory.
- **Strip-vision: honest feedback + wider VLM coverage.** User reported
  strip-vision wasn't visibly shrinking models. Investigation: GLM-4.7-Flash
  isn't a VLM at all (probe showed 844 tensors, 0 vision-related); for
  actual VLMs the vision component is structurally 1–5 GB out of a 27B
  model's ~30 GB, so the savings ARE small. Fixes:
  1. **`dropped_bytes` is now plumbed through** from the helper's `done`
     event → `ModelModifyService.lastStripDroppedBytes` → `.finished`
     state's `droppedBytes` arg. UI's Done card now shows "Removed N GB of
     vision weights" so users can see exactly what was removed.
  2. **`VISION_PREFIXES` expanded** from 10 entries to 30 — covers Qwen2.5/3-VL
     (`visual`, `model.visual`), MiniCPM-V (`vpm`, `resampler`), InternVL
     (`mlp1`), DeepSeek-VL (`aligner`, `vision_encoder`), Idefics
     (`connector`, `vision_proj`), Phi-3-Vision (`img_processor`,
     `vision_embed_tokens`, `img_projection`), BLIP family (`query_tokens`,
     `qformer`), plus several already-supported patterns.
  3. **Toggle copy honest about expected savings**: "Saves roughly 1–5 GB
     depending on the vision tower… For big disk savings, pair this with
     Shrink below — that's where the real reduction comes from."
  4. **"Not a VLM" error reworded** to "This is already a text-only model
     — there are no vision components to remove. Vision-stripping only
     applies to vision-language models like Qwen-VL, LLaVA, MiniCPM-V, etc."
- **Shrink (quantize) any local model before fine-tuning.** New "Shrink
  (quantize)" toggle in the Modify sheet, third in the list alongside strip-
  vision and abliterate. When enabled, a segmented Precision picker appears
  with **8-bit (recommended)** and **4-bit (smallest)** options. Output suffix
  auto-appends `-8bit` or `-4bit`. The three stages chain: strip → abliterate
  → quantize, each writing to a temp dir if a later stage will consume it,
  cleaned up at the end. Backend: new `runQuantize` in `ModelModifyService`
  wraps `python -m mlx_lm convert --hf-path SRC --mlx-path DST -q --q-bits N`;
  ModificationStage gained a `.quantizing(bits:, message:)` case rendered in
  the UI as "Shrinking to N-bit — <latest output line>". `ActiveJob` gained
  `quantizeBits: Int?`. **UI verified end-to-end** on a 60 GB GLM-4.7-Flash-bf16:
  toggle reveals the picker, name auto-updates to `GLM-4.7-Flash-bf16-8bit`,
  save path preview correct, button armed. Conversion itself not run end-to-end
  to avoid burning a 5–10 min job for diagnostics; the helper call path is
  identical to the existing `ConversionService.convert` which is verified.
  Disk savings: 54 GB bf16 → ~28 GB at 8-bit → ~14 GB at 4-bit. Combined with
  AutoTuner's safe-mode for unstable 8-bit Qwens, the user can take a fp16
  base and shrink it knowing the downstream training will still work.
- **Send any local model to LM Studio.** New teal ✈ paperplane icon + "Send
  to LM Studio…" context-menu item on every local-model row. Opens an alert
  with publisher + name fields (auto-split from the HF repoID — e.g.
  `mlx-community/Qwen3.6-27B-bf16` → publisher=`mlx-community`,
  name=`Qwen3.6-27B-bf16`; bare folder names default to publisher
  `LLMPro`). Backend in `ModelRegistry.installInLMStudio` uses the same
  `/bin/cp -cRL` trick as duplicate — APFS CoW + symlink dereferencing —
  so the model lands at `~/.lmstudio/models/<publisher>/<name>/` ready to
  use, with **zero extra disk** on APFS. **Verified end-to-end through
  the UI**: 51 GB Qwen3.6-27B-bf16 transferred in seconds, 23 files
  present (config.json, tokenizer.json, chat_template.jinja, 11
  safetensors shards), success alert offers "Show in Finder", free disk
  still 1.5 TB. Also added `lmStudioDefault` to `PathResolver`.
  Companion: Save & Use's fused-safetensors target got an "Also install in
  LM Studio" checkbox + name field so a freshly fine-tuned adapter can be
  fused and dropped into LM Studio in one click — lands under
  `~/.lmstudio/models/LLMPro/<name>/`.
- **Duplicate model (APFS clonefile) + memory-pressure mitigations.** Two
  feature requests stacked into one pass:
  1. **Duplicate any local model into a new independent entry.** New blue
     `doc.on.doc` icon and context-menu item on each row in the Models tab.
     Pre-fills the name as `<orig>-copy` (with `-2`/`-3` suffixes if taken).
     Backend: `ModelRegistry.duplicate(source:, newName:)` shells out to
     `/bin/cp -cRL` — `-c` triggers APFS `clonefile()` (Copy-on-Write,
     near-zero extra disk), `-L` resolves the HF cache's snapshot symlinks
     so the destination is a self-contained model. **Verified end-to-end**:
     54 GB Qwen3.6-27B-bf16 duplicated in **0.009 seconds** with **zero
     bytes of extra disk consumed** (free disk unchanged at 1.5 TB).
     The "Total" display sums logical sizes (will read 109.48 GB on a 2× copy)
     but actual on-disk usage stays flat thanks to CoW. UX subtlety fixed:
     SwiftUI's `.alert` dismisses synchronously on button-tap, nulling
     `duplicateTarget` BEFORE the async commit reads it — now captured at
     button-tap time and passed into the async closure.
  2. **Memory: `clear_cache_threshold` + per-row cache clears.**
     - `TrainingConfig` got a new `clearCacheThreshold` field (default 1 GB)
       wired into the YAML; mlx-lm's allocator now frees its cache between
       steps when it exceeds the threshold instead of letting it grow
       unbounded (mlx-lm's own default is `0` = never clear).
     - `self_improve_round.py` and `eval_pass_rate.py` import `mlx.core`
       and call `mx.clear_cache()` after every row. These helpers load a
       model once and loop, so without the per-row clear the resident set
       drifts up across long Practice rounds.
- **Qwen-27B-8bit now actually fine-tunes (auto safe-mode in AutoTuner).**
  Two more bugs found and fixed for the user trying to train this base:
  1. **`resolveModelArg` only handled bare folder names.** HF repoIDs like
     `mlx-community/Qwen3.6-27B-8bit` passed through unchanged → mlx-lm's
     loader called `huggingface_hub` → respected `HF_HOME` but looked under
     `<HF_HOME>/hub/models--*/`, while our `hf_download.py` writes to
     `<HF_HOME>/models--*/`. Result: **mlx-lm silently triggered a 28 GB
     re-download** every time the user hit Start. UI showed it as "stuck on
     Opening the textbook". Fixed by checking `ModelRegistry` for ANY
     match (registry scans both layouts) before passing through. Removed
     the 15 GB partial re-download from `hf/hub/`. Verified: cold-load of
     the 27B from the absolute snapshot path is **2.9 seconds**.
  2. **Default AutoTuner settings NaN'd on Qwen-27B-8bit + most coding
     datasets** (the documented numerical-instability issue). Spent the
     better part of an hour bisecting; the combination that survives is
     SGD + grad_accumulation_steps=1 + mask_prompt=false + rank=4 + 8
     layers + max_seq_length=1024 + lr=5e-6. Adam's momentum/variance
     buffers cascade the NaN once one weight goes bad — SGD has no such
     buffers. AutoTuner now detects Qwen3.5/3.6 + "8bit" in the repoID via
     `isNumericallyUnstableBase(repoID:)` and auto-applies the safe overrides
     transparently. `AutoTunedConfig` got `optimizer` and `maskPrompt` fields
     so the safe values flow through to the YAML. Time estimates scaled 1.5×
     to reflect SGD's lower throughput. **End-to-end verified through the
     UI**: Qwen3.6-27B-8bit + Magicoder Evol + Quick = "Learning 10 of 50
     lessons" with ETA "about 6 minutes left", 50 GB unified mem, no NaN,
     no fail-fast trigger.
- **NaN-handler message-clobber bug + verified working base.** Follow-up
  to the previous fix: after the NaN handler SIGTERM'd the subprocess, the
  exit handler ran with `code=15` and called `markFailed("exit 15")`,
  overwriting my actionable NaN message. Fixed by guarding the exit handler
  with `JobRegistry.shared.jobs[jobID]?.status == .failed`. New failures
  show the full NaN guidance in the Progress headline.
  Also downloaded `mlx-community/Qwen2.5-Coder-7B-Instruct-4bit` (~4 GB) and
  verified it trains cleanly on Magicoder Evol-Instruct: Val loss 1.136 →
  0.692 in 10 iters at peak mem 10 GB (vs 60+ GB and NaN for Qwen3.6-27B-8bit).
  The 7B coder is now the recommended base for any real coding fine-tune
  until the 27B-8bit + mlx-lm numerical-instability issue is resolved upstream.
- **Training-failure debuggability + dataset-prep hardening.** User reported
  "errors training Qwen3.6-27B-8bit-text-only + dotnet-runtime on Thorough."
  Root-causing it exposed four separate bugs / shortcomings, all fixed in
  this pass:
  1. **stderr never persisted.** `TrainingService` wrote stdout to
     `training.log` but routed stderr only into the in-memory `JobRegistry`
     ring buffer. After an app restart the actual mlx-lm error vanished.
     Now both streams tee into the same log via a new `LogFileWriter` actor
     (serialised writes, Swift-6-strict-concurrency-safe), with stderr lines
     getting the `[stderr]` prefix.
  2. **Stale `DatasetRecord` rows.** When the on-disk directory for a
     prepared dataset gets wiped, the SwiftData row persists, the Teach UI
     happily offers it, and mlx-lm fails 2 seconds in with a cryptic "Loading
     Hugging Face dataset <path>" message. Now: `TrainingConfigView.launch()`
     checks `FileManager.fileExists(ds.trainFile)` before spawning, and
     `DatasetChoiceCard` renders missing datasets with a ⚠️ icon, grayed-out
     opacity, and a "Files missing on disk — re-prepare from the Lessons tab"
     subtitle.
  3. **Pathologically long rows nuked training.** `kotlarmilos/dotnet-runtime`
     contains entire C++ source files in single rows — the max was **40 MB**
     of text (~10 M tokens), with 8% of rows over 1 MB. When mlx-lm truncates
     a 40 MB row to 2048 tokens the result is gibberish that NaNs the loss on
     the first val pass. Added `max_chars_per_row` option to
     `download_hf_dataset.py` (default 32 KB ≈ 8 K tokens, safely within
     2048-token training; set to 0 to disable). Re-prepping dotnet-runtime
     with the filter dropped 5,713 of 20,000 rows; new max is 32 K chars.
  4. **NaN val loss silently produced garbage adapters.** Even with the
     dataset filter in place, Qwen3.6-27B-8bit + this kind of data NaNs the
     val loss on iter 1 — the documented numerical-instability issue that
     also affects Magicoder-Evol. Previously the training would run for
     hours and save a useless adapter. Added `LogStreamParser.hasNaNLoss(_:)`
     and a check in `TrainingService` that, on any `Iter N: Train|Val loss
     nan` line, terminates the subprocess and marks the job failed with an
     actionable message recommending fp16/bf16 base, smaller model, or a
     lower learning rate.

  Net effect: the user's specific training will still fail (the underlying
  Qwen-27B-8bit numerical issue is an mlx-lm bug we can't fix), but now it
  fails fast with a meaningful error and a recommendation, rather than
  silently burning an hour.
- **Lesson rename — two ways.** Previously every fine-tune defaulted to the
  literal string "Coding lesson" with no in-UI way to rename, so the Home /
  Progress / Save & Use lists became indistinguishable after a few runs.
  Fixed in two places:
  (1) `TrainingConfigView` now derives the default name from current selection
      — `"<model-short> + <dataset-name>"` (e.g. `"Llama-3.2-1B-Instruct-4bit
      + CodeAlpaca 20K"`). Shown as the textfield placeholder so the user
      sees what will be saved without having to type. Updates live as model
      or dataset changes.
  (2) `DashboardView`'s Recent-lessons rows have a context menu → "Rename…"
      → SwiftUI `.alert` with TextField pre-filled with the current name →
      Save mutates `TrainingJob.name`, persists via `context.save()`, and
      writes the sidecar. Verified end-to-end through the UI.
- **Custom-model delete bug fix.** `ModelRegistry.delete(repoID:)` only checked
  the four HF cache paths and silently skipped custom models under
  `modelsCustomDir/<name>/`. Clicking Delete on a vision-stripped /
  abliterated / manually-imported model showed the confirmation and then did
  nothing on disk. Fixed by also targeting `modelsCustomDir/<repoID>/` (and
  computing freed bytes via `directorySize(at:)` for that branch — custom dirs
  don't have the HF `blobs/` sibling). Verified via UI: deleting
  Qwen3.6-27B-8bit-Text-Gen produced the "Freed 28.6 GB" toast and the folder
  is gone from disk.
- **Practice tab UI smoke-test passed.** Drove the loop end-to-end through the
  SwiftUI front-end: Llama-3.2-1B + HumanEval + 2 rounds × 4 candidates × 20
  problems. Total wall-clock 2.9 min. Verified live: phase emoji transitions,
  headline copy, prompt_preview showing function signature, kept-lessons
  progress bar, "M passes / N tries" caption, the pass-at-one trend chart
  animating with each new round's eval point, status transition to completed,
  history row with delta + "Reveal adapter" button, and on-disk artifacts
  (run.json sidecar, round_N/dataset/{train,valid,test}.jsonl, adapter dirs).
  Result: 31% → 9% pass@1 (overfit on n=5 kept rows — expected on these
  defaults, see Half-done banner for the tuning discussion). **The Practice
  feature is functionally complete**; remaining work is defaults tuning, not
  plumbing.
- **Practice tab CLI smoke-test + bug fixes.** Drove the full
  `humaneval_pull → self_improve_round → mlx_lm lora → eval_pass_rate` chain
  via CLI against Llama-3.2-1B-Instruct-4bit (132 seed problems, 32 eval).
  Result: every subprocess works, JSON-event protocol decodes cleanly, sandbox
  test runner correctly grades 3/3 canonical HumanEval solutions. **Three real
  bugs caught and fixed:**
  1. `openai_humaneval` HF repo ID is deprecated — current `datasets` library
     requires `openai/openai_humaneval`. Similarly switched MBPP to
     `google-research-datasets/mbpp`.
  2. `self_improve_round.py` split logic stole the only row out of
     `train.jsonl` for tiny rounds, leaving training with 0 rows. For `n < 3`
     keepers, now writes all rows to all three splits (overfit accepted; held-out
     eval is what actually measures progress).
  3. mlx-lm requires `batch_size ≤ len(valid)`. `SelfImproveService.runOneRound`
     now reads the valid line count and clamps `batchSize` + `valBatches` to fit.
     Builds the YAML directly rather than via `AutoTuner.renderYAML` so the
     clamp survives.
  Also tightened `prompt_preview` in row_start events to grab the function
  signature instead of the import line. Smoke-test outcome on the tiny n=1
  training set was catastrophic-overfit (baseline pass@1 1/6 → adapter 0/6),
  exactly the failure mode you'd expect with this batch — confirms the
  measurement is honest. Real runs need rowsPerRound large enough to keep
  ≥10 passers per round to avoid this.
- **Practice tab (recursive self-improvement) added.** New sidebar tab that
  implements rejection-sampling self-distillation gated by unit-test execution.
  Pipeline: pull HumanEval/MBPP → baseline pass@1 → for N rounds {
  `self_improve_round.py` generates K candidates per prompt and sandbox-tests
  them, `mlx_lm lora` trains on the passers, `eval_pass_rate.py` re-measures
  pass@1 }. New files: [`SelfImproveRun.swift`](../LLMPro/Models/SelfImproveRun.swift),
  [`SelfImproveService.swift`](../LLMPro/Services/SelfImproveService.swift),
  [`SelfImproveView.swift`](../LLMPro/Features/SelfImprove/SelfImproveView.swift),
  and three helpers ([`humaneval_pull.py`](../LLMPro/Resources/helpers/humaneval_pull.py),
  [`self_improve_round.py`](../LLMPro/Resources/helpers/self_improve_round.py),
  [`eval_pass_rate.py`](../LLMPro/Resources/helpers/eval_pass_rate.py)).
  Sidebar wiring + SwiftData registration in place; helpers registered in
  `PythonRuntime.installHelpers`.
- **Doc-maintenance contract added.** `CLAUDE.md` now opens with an unmissable
  "Documentation is part of the work" section that maps every kind of change to
  the doc(s) it requires updating. Each `docs/*.md` file has a one-line
  maintenance banner at the top. `README.md` has a Contributing section pointing
  at the same contract. The expectation is now explicit: every session that
  touches code must update the relevant doc(s) before ending, with a minimum
  one-line entry in this Recent session log.
- **Documentation pass.** This entire `docs/` set + `CLAUDE.md`
  was written to prevent context loss between agent sessions.
- **Local-model path resolution bug.** Fixed in
  `TrainingConfigView.resolveModelArg()`. Symptom: training a vision-stripped
  or imported model failed with exit 1. Cause: mlx-lm interpreted a bare folder
  name as an HF repo ID. Resolver turns no-slash names into absolute paths.
- **Strip-vision verification.** Confirmed the helper drops only vision tensors
  (0 LM weights affected on Qwen3.6-27B). Training of stripped model works
  identically to original on the same dataset.
- **Dataset CRUD editor.** Added `DatasetDetailView` + `DatasetRowEditorView`
  with auto-save on every mutation, plus toolbar "New blank" + Rename +
  Duplicate + Delete actions.
- **HuggingFace dataset search.** New sheet for browsing any dataset, not just
  catalog presets. Auto-detects 6 source schemas; manual column-mapping fallback.
- **App icon.** Generated via PIL at [`tools/make_icon.py`](../tools/make_icon.py).
  Wired into Assets.xcassets, project.yml asset-catalog config, and Info.plist
  CFBundleIconName/IconFile. Dock cache flushed via `lsregister -f + killall Dock`.
- **Friendly UX redesign.** Sidebar relabelled (Datasets → Lessons, Training →
  Teach, Monitor → Progress, etc.). Progress UI replaced charts as primary with
  friendly narrator + star rating. Teach replaced YAML form with 3 cards.
- **AutoTuner.** Auto-picks every hyperparameter from (ModelSize, TrainingDuration).
  Time estimates calibrated against actual M-series runs.
- **Download progress fix.** Replaced tqdm monkey-patch in `hf_download.py`
  with a 250 ms blobs/-size poller (works for both xet and classic HTTP).
- **DownloadService "stuck row" fix.** Removed spurious `entry.done = true` in
  `handle()` — the cleanup block now properly moves rows to history.
- **ModelRegistry both-layouts fix.** Scans both `hf/models--*` and
  `hf/hub/models--*`. Sizes read from `blobs/` via `lstat` (no symlink
  double-counting).

### Session 2026-05-31 (cont.) — Abliteration ("Make uncensored") rewritten to actually work

**Problem:** `abliterate.py` was shipped but had only ever *completed* on small fp16
models; on the realistic (quantized / MoE) cases it silently produced a model that
was either unchanged or broken. Four distinct bugs, all now fixed + verified.

**Root causes found (each confirmed empirically against cached models):**
1. **Quantized silent no-op.** A `QuantizedLinear`'s `.weight` is packed uint32, so
   the old shape-guard skipped it → 0 matrices changed on any 4-bit/8-bit model.
2. **Lobotomization.** Direction was a *mean over all tokens*; the BOS token is a
   ~137× attention sink (norm 794 vs median 5.8 @layer9 on Llama-1B), so the mean
   captured the sink, not refusal. Also ablated `embed_tokens`, which Llama 3.2 ties
   to the unembedding → logit collapse → "anti anti anti…" gibberish.
3. **Requant snapping.** Even with the quantized path wired, re-quantizing the
   projected weight to 4-bit snapped ~85% of the edit back (measured), so behaviour
   didn't change (refusals 3/5→3/5, 54% signal reduction).
4. **MoE silently skipped.** The walk `break`-ed after `layer.mlp` and only looked
   for experts *under* mlp; Gemma-4 keeps routed experts at
   `layer.experts.switch_glu.down_proj` → all routed-expert writes were missed.

**Fixes (in `LLMPro/Resources/helpers/abliterate.py`):**
- Dequantize quantized inputs in memory via `mlx_lm.utils.dequantize_model`, ablate
  in full precision, save fp16 (config quantization keys stripped). Re-Shrink to
  recompress (Modify pipeline stage 4).
- Extract the refusal direction at the **last chat-template token** (chat template
  applied), mean over prompts — not over sequence positions.
- **Do not** ablate `embed_tokens` (tied-embedding safety). Only attention `o_proj`
  + MLP/MoE `down_proj` across all layers.
- Exhaustive MoE walk: dense `mlp.down_proj`, batched `switch_glu`/`switch_mlp`
  down_proj (3-D), shared-expert, and per-expert lists. Routers untouched.
- `done` event now self-reports `refusal_reduction`, `pre_gap`/`post_gap`,
  `mutated_{matrices,float,quant}`, `attn/mlp/moe_proj`, `was_quantized`,
  `output_dtype`.

**Verified:**
- E2E on Llama-3.2-1B-Instruct-4bit (the quantized path): coherence 0/4 failures
  after, refusals 3/5→1/5, refusal_reduction 1.0 (gap 4.08→0.00), 32 float matrices
  mutated, output fp16. ~8s.
- MoE walk unit-tested against mock Gemma/Qwen/dense/expert-list trees: correct
  matrices hit, routers skipped, max|dᵀW|<1e-6 on 2-D and 3-D.
- NOT run E2E on the 27B bf16 / Gemma-MoE this session (size/time) — same float code
  path as the verified 1B; MoE walk validated structurally.

**Follow-ups:** (a) optional UI hint in ModelModifyView when uncensoring a quantized
model (output becomes full-precision — suggest ticking Shrink); (b) E2E run on the
27B bf16 + Gemma-MoE through the actual app UI. **Done this session:** CONTRACTS.md
§2 updated (done-event fields, MoE tensors, dequantize-first / last-token / no-embed
rationale); CLAUDE.md "verified working" entry updated; app rebuilt so the bundle
ships the fixed helper (`** BUILD SUCCEEDED **`, bundled helper hash == repo).

### Session 2026-05-31 (cont.) — GitHub-readiness pass

Prepared the repo for public release on GitHub.com:
- **Security/privacy sweep** (Explore agent, whole tree minus `.git`): NO secrets
  (no `hf_`/`sk-`/AWS/private keys), NO hardcoded `/Users/josh` in any source file
  (only in docs, which is expected/illustrative). Verdict: safe to publish.
- Added **`.gitignore`** (macOS, Xcode incl. the generated `LLMPro.xcodeproj/`,
  SPM, Python `__pycache__`/`.venv`, `.claude/settings.local.json`, runtime weights).
- Added **`LICENSE`** (MIT, copyright holder left as `<Your Name>` placeholder).
- Added **`INSTALL.md`** earlier this session — beginner build/run guide; linked
  from README (callout + docs table).
- Removed committed junk: 2× `.DS_Store`, 2× `__pycache__/`.
- Reconciled `docs/BUILDING.md` (xcodeproj is now generated-not-committed, was
  "safe to commit") and README License section (was "not yet declared").
- Added a "PLANNED / NOT YET IMPLEMENTED" banner to `docs/API_MCP_PLAN.md` so
  public readers don't mistake the API+MCP design doc for shipped behaviour.
- **`git init` + first commit** on branch `main` (repo-local identity only; global
  git config untouched). 142 files, no ignored patterns leaked into the tree.

**Decisions (user):** MIT license, name placeholder, KEEP bundle id
`com.josh.llmpro`, init+commit. **Not done (intentionally):** did NOT create
the GitHub repo or push; did NOT change the bundle id. **Before pushing:** set the
real name in `LICENSE`, create the GitHub repo, `git remote add origin … && git
push -u origin main`. Optionally amend the initial commit's author to your own
identity first.

### Session 2026-06-03 — Project subagent team wired into CLAUDE.md

- A subagent team was added under `.claude/agents/` (8 agents): **Main**
  (orchestrator / sole user-facing agent), Planner, Researcher, and builders for
  Swift, SwiftUI, Python, Text, TypeScript. `Main.md` defines the orchestration
  loop + a compact-JSON inter-agent protocol.
- **CLAUDE.md**: added a top-of-file "🤖 Work through the agent team — start with
  `Main`" section (roster table mapped to THIS repo: Swift/SwiftUI/Python/Text are
  the relevant builders; TypeScript noted as unused). Stressed that the team does
  not exempt anyone from the load-bearing decisions or the doc-maintenance
  contract, and that dispatch prompts must carry the relevant rules (subagents
  don't inherit the conversation).
- **README.md**: Contributing section now points at the team + Main.
- `.claude/settings.local.json` stays gitignored; the agent definitions ARE
  tracked so they ship with the repo.

### Session 2026-06-03 (cont.) — Corrected the subagent framing (Main is not the entry point)

Verified against Claude Code docs (claude-code-guide) how project subagents
actually behave, and fixed CLAUDE.md/README which had overstated it:
- ✅ Confirmed: a cloned repo's `.claude/agents/*.md` ARE auto-discovered by a
  Claude Code session in the project — no opt-in/trust prompt. (All 8 files are
  committed and not gitignored; only `settings.local.json` is ignored.)
- ❌ Corrected misconception: a file named `Main.md` CANNOT be the top-level
  agent. Everything in `.claude/agents/` is a *subagent* the built-in session
  spawns; the running session is always the orchestrator + sole user-facing agent.
  Also, on stock Claude Code delegation is one level deep (a subagent generally
  can't spawn further subagents), so `Main.md`'s nested-dispatch design isn't
  guaranteed off this harness.
- **CLAUDE.md**: retitled the section "🤖 Specialist subagents live in
  `.claude/agents/`"; reframed it as "you (the session) are the orchestrator;
  delegate file-type work to the matching specialist"; demoted `Main.md` to an
  orchestration *playbook* (guidance the session follows), not a dispatchable
  role; kept all 8 links + the per-builder routing table; kept the
  rules-travel-in-the-dispatch-prompt note.
- **README.md**: Contributing now describes specialists + auto-discovery instead
  of "start with Main, the orchestrator"; anchor updated + verified.
- Left the 8 agent .md files themselves unchanged (Main.md is still useful as a
  written orchestration playbook).

### Session 2026-06-03 (cont.) — Full project rename MLXStudio → LLMPro

Rebranded the entire project from "MLX Studio"/MLXStudio to **LLMPro** (display
name + code identity + repo), per user request "no more refs to mlx-studio".

- **Content:** 724 case-sensitive replacements across 57 files (`MLX Studio`→
  `LLMPro`, `MLXStudio`→`LLMPro`, `mlxstudio`→`llmpro`, `MLXSTUDIO`→`LLMPRO`,
  `MLX-Studio`→`LLMPro`). Preserved neighbors: `mlx_lm`, `MLXServerService`,
  `LM Studio`/`lmstudio`, bare `MLX` (the framework).
- **Structure (git mv, history preserved):** `MLXStudio/` → `LLMPro/`;
  `MLXStudioApp.swift` → `LLMProApp.swift` (struct `LLMProApp`);
  `MLXStudio.entitlements` → `LLMPro.entitlements`; `Tests/MLXStudioTests` →
  `Tests/LLMProTests`.
- **Build identity:** bundle id `com.josh.mlxstudio` → `com.josh.llmpro`
  (`com.josh.llmpro.LLMPro`); `project.yml` name/paths/scheme; `.gitignore`
  (`LLMPro.xcodeproj/`); `Log.swift` subsystem fallback.
- **Env-var contract (Swift↔Python):** `MLXSTUDIO_*` → `LLMPRO_*` on both sides
  (`LLMPRO_MEMORY_LIMIT_BYTES`, `LLMPRO_CACHE_LIMIT_BYTES`, `LLMPRO_MEM_LIMIT_GB`,
  `LLMPRO_NO_AUTOTUNE`). Verified 0 leftover `MLXSTUDIO_`.
- **Data path + migration:** `PathResolver.appSupport` now points at
  `Application Support/LLMPro`. Added `migrateLegacyAppSupportIfNeeded` — a
  one-time same-volume `mv` of an existing `MLXStudio` dir to `LLMPro` on first
  launch (no copy, no re-download of the model cache; idempotent; never clobbers).
  The only intentional surviving "MLXStudio" strings are inside this migration.
- **Verified:** `xcodegen generate` + `xcodebuild` → `** BUILD SUCCEEDED **`,
  0 errors. Built bundle = `com.josh.llmpro.LLMPro`, display name LLMPro.
  Migration logic unit-simulated across all 4 cases (first-launch move, idempotent
  relaunch, fresh install, both-exist-don't-clobber) — all PASS; real 331 GB data
  dir left untouched by the test. NOT yet launched in the GUI (the live migration
  fires on the user's next real launch).

**Note:** product is now "LLMPro" everywhere user-facing; the on-disk legacy dir
migrates automatically. App still wraps mlx-lm (that name is unchanged).

### Session 2026-06-03 (cont.) — Rebrand follow-ups found by live testing

Launched the renamed LLMPro.app on the real 331 GB data dir and verified end-to-end.
Two latent rebrand bugs surfaced (neither caught by the build) and were fixed:

1. **First-launch venv re-create hard-failed.** After the 331 GB move, the cold
   `import mlx_lm` verify was slow, so bootstrap fell through to `uv venv` and
   errored "a virtual environment already exists". Fixed by adding `--clear`
   (`PythonRuntime.bootstrap`) so venv creation is idempotent. Self-heals on the
   next launch regardless; this removes the scary first-launch error.
2. **UserDefaults didn't survive the bundle-id change** (`com.josh.mlxstudio.MLXStudio`
   → `com.josh.llmpro.LLMPro`). The renamed app read empty defaults → re-showed
   First Run, would re-seed example skills, forgot the Code model/workspace. Added
   `Core/LegacyMigration.swift` (`migrateUserDefaultsIfNeeded`), called from
   `LLMProApp.init()` before any view reads `@AppStorage`. Copies non-`NS*` keys
   from the legacy domain once (idempotent flag `didMigrateFromMLXStudioDefaults`;
   never overwrites a key already set in the new domain).

**Verified live:** data dir migrated (legacy gone, LLMPro present, 331 GB, venv
`import mlx_lm 0.31.3` OK); clean relaunch 0 ERROR/FAULT, no .ips; UserDefaults
migration sets firstRunComplete=1 + didSeedExampleSkills=1 + carries
codeOrchestratorModel/codeWorkspacePath. **NOT done:** interactive click-through of
each tab's UI/Options — the computer-use MCP (native screenshot/click) is
disconnected this session; only browser controllers are available, which can't
drive a native SwiftUI app. Needs computer-use reconnected to complete.

### Session 2026-06-05 — Fix strip-vision → shrink on Qwen3.5-family VLMs

**Bug (from user's log):** modifying Qwen3.6-27B with strip-vision + shrink failed:
`mlx_lm convert … -q` → `ValueError: Model type qwen3_5_text not supported.`

**Cause:** `strip_vision.py`'s generic (non-gemma4) flatten path lifted
`text_config` to top level and let the nested `model_type` overwrite the top-level
one (`or k == "model_type"`). Qwen3.5 VLMs tag the inner LM `qwen3_5_text` — a
variant mlx-lm's registry doesn't know — so the stripped config advertised an
unsupported type and the Shrink stage (`mlx_lm convert`) bailed.

**Fix:** flatten lifts only keys the top level lacks; the top-level `model_type`
(`qwen3_5`, which loaders recognize) is preserved. Fallback: if there's no
top-level model_type, use the nested one with a trailing `_text` stripped.

**Verified end-to-end on the real cached Qwen3.6-27B-bf16:** strip → stripped
config `model_type: qwen3_5`, `architectures: [Qwen3_5ForCausalLM]`, no text_config;
then the exact failing `mlx_lm convert -q --q-bits 8` **completed** —
"Quantized model with 8.501 bits per weight", 0 "not supported" errors. gemma-4
path untouched (still keeps its nested config).

### Session 2026-06-05 (cont.) — Restore web access for Code agents (Researcher)

User asked for the Code agents to reach the internet to stay up to date. This
**reverses** the earlier "make agents fully offline" decision (their explicit call).

- `AgentTools.swift`: re-added `web_search` + `fetch_url` to `AgentToolName` (both
  `isReadOnly` → auto-run, network reads only). Pure-Swift implementations in
  `ToolExecutor` (no Python, no new file): `webSearch` hits the keyless DuckDuckGo
  HTML endpoint and parses title/url/snippet (redirect links un-wrapped); `fetchUrl`
  downloads + `htmlToText`-strips a page. `URLSession`, browser UA, 20 s timeout,
  graceful failure messages.
- Added the two `case`s to the three exhaustive `AgentToolName` switches that broke
  the build: `CodingAgentService.summary` (label), `CodeView.icon` (globe/link SF
  symbols). (`AgentTools.previewDiff` already had a `default`.)
- `researcher.md`: `tools:` now includes `web_search, fetch_url`; prompt rewritten
  from "you have no web access" to "use the web to check anything newer than your
  training data; prefer official/primary sources; cite files AND links." Only the
  Researcher carries web tools by default; add them to another agent's `tools:` to
  extend.
- App is **not sandboxed**, so outbound HTTP needs no entitlement change.
- Docs reconciled: most (ARCHITECTURE/CONTRACTS/WORKFLOWS/STATE) already *described*
  these tools (never fully reverted when they were removed), so this brings code back
  in line. Fixed CONVENTIONS "Real web research" (corrected the dead
  `WebSearch.swift` path → it's in `AgentTools.swift`; added the remove→restore
  history) and the WORKFLOWS "agents have no network tools" line.

**Verified:** `xcodebuild` → BUILD SUCCEEDED, 0 errors. Web logic live-tested in a
standalone Swift harness using the exact parsing code: `web_search('mlx-lm lora
fine-tuning')` → 10 real results with un-wrapped URLs + snippets; `fetch_url(
example.com)` → HTTP 200 stripped to text. NOT yet driven through the in-app agent
loop (would need a model session); the tool layer is proven.

### Session 2026-06-05 (cont.) — Code transcript follows the live agent task

The transcript auto-scrolled only when a NEW bubble was appended
(`transcript.count`) or `isRunning` flipped. But the *current* task streams text,
reasoning, and tool calls INTO the existing last bubble — count doesn't change — so
the bottom drifted off-screen and the user couldn't watch the active agent work.

Fix (`CodeView.transcript`): added an `onChange(of: transcriptTailSignature)` →
`scrollTo("BOTTOM")`. `transcriptTailSignature` is a single Int derived from the
last bubble's `text.count + reasoning.count + toolCalls.count*100k`, so it bumps on
every stream flush / new tool call and the view follows the live output down.
Unanimated scrollTo (per the existing perf note — animated scroll pegs the @MainActor
loop). Build green. Tradeoff: always-follow (no "user scrolled up" suppression),
matching the existing count/isRunning behavior; near-bottom detection was skipped on
purpose because the scroll-offset GeometryReader it needs reintroduces the per-frame
layout cost the transcript explicitly avoids.

### Session 2026-06-05 (cont.) — "Run teammates in parallel" toggle now controls the orchestrator's plan

**Symptom (user):** with "Run teammates in parallel" UNCHECKED, the orchestrator
still says/tries "dispatch these in parallel".

**Diagnosis:** execution was already correct — `runDelegations` serializes delegates
when `settings.parallelAgents` is off (only one request in flight). The bug was
prompt-side: `parallelAgents` never reached the system prompt, and `orchestrator.md`
hardcoded "To run builders IN PARALLEL, call them in the SAME turn." So the model was
*told* to go parallel regardless of the toggle — it kept emitting both `call_*` calls
in one turn and narrating "in parallel," even though they then ran sequentially.

**Fix:**
- `CodingAgentService.systemMessage`: for any role that delegates to >1 teammate
  (the orchestrator), append a "Teammate dispatch" directive that reflects the
  toggle — PARALLEL ON → "dispatch independent teammates in the same turn";
  OFF → "emit exactly ONE call_* per turn, wait, then the next; don't say
  'in parallel'." Injected after the .md body, so it's authoritative regardless of
  the installed agent file.
- `orchestrator.md`: replaced the hardcoded parallel instruction with "follow the
  Teammate dispatch directive below." Refreshed the installed copy too (it was the
  stock default, no custom edits).

Build green. NOT yet observed through a live model turn (needs a session); the prompt
now matches the setting and execution was already gated.

### Session 2026-06-07 — Remove the Adapter picker from the Code tab

User: "In the Code section I do not want the Adapter." Removed the LoRA-adapter
picker from `CodeView`'s top bar — the Code team now always runs the **base model
only**.

- Deleted the `Picker("Adapter", …)` from the toolbar (the "Base only / <job>"
  dropdown) and all its supporting state: `@AppStorage("codeAdapterJobID")`
  `savedAdapterID`, `@State selectedAdapterID`, the `onChange` persistence, the
  `completedAdapterJobs` + `selectedAdapterPath` computed props, the restore-on-
  launch block, and the now-unused `@Query var jobs` + `import SwiftData`.
- `startSession()` now calls `agent.startSession(model:, adapterPath: nil)`.
- `applyHandoff` keeps pre-filling the model from a Progress/Practice hand-off but
  ignores any adapter path.
- `CodingAgentService.startSession(model:adapterPath:)` signature unchanged (still
  takes the optional) — the Code tab just always passes nil. To re-fine-tune-and-run
  in one place, that's still the Try-it-out / Save & Use flows.

Verified: BUILD SUCCEEDED, 0 errors, no new warnings (the 6 build warnings are all
pre-existing, in other files). UI confirmed via screenshot: top bar is now
folder · Model · Start session, no Adapter dropdown; app launches clean, 0 log errors.

### Session 2026-06-07 — Swift/SwiftUI datasets + "build full Mac/iOS apps" path

User wants to fine-tune for Apple Swift/SwiftUI and "create full Mac and iOS apps."
Honest finding: no public dataset teaches whole multi-file Xcode apps (a full app is
a repo, not a prompt→answer pair). So shipped a 3-part path:

1. **Swift dataset presets** (all repo IDs + schemas verified live; download+transform
   to chat JSONL test-passed on real rows):
   - `swift-rlvr-133k` → saurabh5/rlvr-code-data-Swift (~133K; `translated_problem` →
     `translated_solution` — NOTE the dataset's own `messages` col has only the user
     turn, so we build the pair from problem+solution). Largest real Swift set; Swift
     LANGUAGE fluency, algorithm-style.
   - `swiftui-examples` → MCES10-Software/SwiftUI-Code-Examples (~1K; `prompt`→`output`).
     Only SwiftUI-specific set on HF. Small → specialization pass.
   - `swift-qa-4k` → mcorsa/swifterX-4k (~4.8K; columns are code=column0,
     instruction=column1 — we train instruction→code; skip the mislabeled header row).
   New splitters + PRESETS entries in `prepare_coding_dataset.py`; matching
   `CodingDatasetCatalog` entries (ids match — contract holds, 10/10).
2. **`swiftui-app-builder` Skill** — the piece that actually yields multi-file apps:
   scaffold via XcodeGen (`project.yml`), `@main App`, split Views/Models/Services,
   then BUILD with the exact `xcodebuild` commands (macOS + iOS-simulator) and iterate
   until `** BUILD SUCCEEDED **`. Written to the live skills dir AND added to
   `SkillStore.exampleSkills` so it ships for new installs (now 3 seeded skills).
3. **Build toolchain verified** on this machine: Swift 6.3.2, Xcode 26.5, xcodegen
   2.45.4, iOS 26.5 simulator; `swift build` smoke-tested OK → the Code agent's
   run_command can write→build→fix→rebuild.

Verified: BUILD SUCCEEDED 0 errors; all 3 presets download+transform to valid
chat JSONL on real rows; catalog↔helper id contract holds; skill well-formed.
Realistic expectation set in the card copy: datasets give fluency; the Skill + the
agent build loop give whole apps. Not yet run through a live fine-tune or a full
end-to-end "build me an app" agent session.

### Session 2026-06-07 (cont.) — Multi-language build support (generic build-verify skill)

User: will build projects in many languages (Rust, Zig, .NET, TypeScript, …), not
just Swift. Confirmed the Code agent is already language-agnostic — its tools are
read/write/edit_file + run_command (nothing Swift-specific); the only gate is whether
a language's toolchain is on PATH (run_command uses `/bin/zsh -lc`, inheriting it).

- Probed installed toolchains: **present** — cargo 1.94, dotnet 10.0.201, node 25.8/
  npm, swift 6.3.2, clang 21, cmake 4.3, python3, ruby. **Absent** — zig, go, java,
  deno, bun. (User chose not to install any now.)
- Added a generic **`project-build-verify`** Skill (live dir + SkillStore defaults →
  now 4 seeded): detect language by manifest (Cargo.toml/*.csproj/package.json/go.mod/
  build.zig/CMakeLists/pyproject/pom), scaffold with the language's own tool, then the
  build→read-errors→fix→rebuild loop until green; if a tool is "command not found",
  tell the user to install it rather than silently switching languages. Complements
  `swiftui-app-builder` (which stays the macOS/iOS-app specialist).
- Docs: ARCHITECTURE + CONTRACTS skill counts three→four.

Verified: BUILD SUCCEEDED 0 errors; skill scans in the live dir (4 skills present).
The earlier live agent test already proved the build-loop works end-to-end (it built
+ compiled a macOS SwiftUI app unaided); this skill generalizes that to any language
whose toolchain is installed.

### Session 2026-06-07 (cont.) — "Training modifies the model" → auto-fuse to a new model

User wanted training to modify the model it trains on. After weighing options
(in-place overwrite is irreversible + risks corrupting the shared HF cache; fusing
quantized dequantizes), settled on the **safe** design: when the toggle is on,
training auto-fuses the adapter into the base and saves a NEW `models/<name>-trained`
model on completion. The original is always kept.

- New `Services/ModelApplyService.swift` (`@MainActor @Observable`): fuse base+adapter
  into a temp dir → validate (config.json + a .safetensors present) → move into a
  unique `models/<name>-trained` → `ModelRegistry.scan()`. Nothing registers unless
  the fused output validates; a failed fuse leaves only a discardable temp dir.
- `TrainingJob` gained `applyToModelInPlace: Bool = false` (+ `applyOutcome: String?`).
  Name kept for SwiftData migration stability; semantics are "auto-fuse to a new
  model," NOT in-place overwrite. Lightweight migration (old jobs read false).
- `TrainingService` completion hook: on clean success + flag, calls
  `ModelApplyService.apply` and records the outcome on the job.
- Teach UI (`TrainingConfigView`): new "Save the trained model when done" toggle
  with an honest caption; no confirmation alert (non-destructive). Carries the flag
  into the `TrainingJob`.

**Verified end-to-end** (mechanism mirror on real artifacts): fused
mlx-community/Llama-3.2-1B-Instruct-4bit + a 6.5M adapter → valid model (config + 1
safetensors, 680M) → moved into models/ → **loads cleanly via mlx_lm.load**. Notable:
fusing an already-MLX-4bit model PRESERVED 4-bit quant (stayed 680M) — the
"dequantizes/larger" caveat is conservative; true for bf16/fp16 sources, not
necessarily for MLX-quantized ones. BUILD SUCCEEDED 0 errors.

**Gotcha logged for future:** `cp -cRL <model>/` on an HF snapshot can follow a
symlink that escapes to the filesystem root and recursively clone huge system trees
(hit during an abandoned in-place test). ModelApplyService avoids cp entirely (it
moves the fused temp dir), so it's not affected — but don't use `cp -L` on snapshot
dirs.

### Session 2026-06-07 (cont.) — Code Options: popover → inline collapsible section

User: the Code-tab Options should be a collapsible section, not a popover floating
over the transcript. Replaced the `.popover(isPresented:)` on the Options button
with an inline disclosure in the header: the button toggles `showOptions` (chevron
right→down) and, when expanded, renders `optionsForm` in a capped, rounded panel
right below it — pushing the IDE/transcript down instead of overlaying it.

Safety: the inline form's ScrollView lives IN THE HEADER (sibling of workspaceArea,
above the Divider), NOT nested in the chat column, so it does not reintroduce the
competing-ScrollView macOS layout cycle that `optionsForm`'s comment warns about.
Capped at maxHeight 360 so a long form scrolls internally rather than shoving the
IDE off-screen. The existing `showOptions = false` on the agents/skills/memory
buttons now just collapses the section when a sheet opens (still correct).

Verified live: expand shows the form inline (IDE moves down, transcript not
covered); collapse restores full height; 0 log errors, no beachball. BUILD SUCCEEDED.

### Session 2026-06-07 (cont.) — GGUF → MLX import (Models tab)

User wanted to convert GGUF model files to MLX. Investigated the real constraints
(mlx-lm's `convert` can't read GGUF; transformers' gguf loader needs PyTorch). Found
the lightweight path: **mlx.core has a NATIVE gguf loader** (`mx.load(path,
return_metadata=True)`) — no torch — that handles F16/F32/Q4_0/Q4_1/Q8_0 (NOT
K-quants). Tokenizer is rebuilt from the GGUF's embedded vocab via
`transformers.integrations.ggml.GGUF*Converter` (pure-python, the torch-gated
load_gguf_checkpoint bypassed by feeding the metadata dict directly).

- `Resources/helpers/gguf_to_mlx.py`: `precheck` (arch+quant → convertible?) and
  `convert` (mx.load → remap GGML→HF tensor names → rebuild config.json + tokenizer
  → write models/<name>/). JSON-event protocol. Registered in installHelpers; `gguf`
  added to bootstrap pip line (tiny, pure-python).
- `Services/GGUFImportService.swift` (`@MainActor @Observable`): precheck + convert +
  single-file HF download (huggingface_hub). Phase enum for the UI.
- `Features/Models/GGUFImportView.swift`: "Import GGUF" sheet (Local file picker /
  HuggingFace repo+file), shows the convertible verdict (arch/quant/reason) BEFORE
  converting, then converts. Button added to ModelsBrowserView search bar.
- Pre-check gates convert: K-quant GGUFs are refused with guidance ("download the MLX
  build from HuggingFace instead") rather than failing cryptically.

**Verified end-to-end (helper AND live UI):** precheck correct both ways (Q8_0
TinyLlama → convertible; nomic Q4_K_M → not, with reason). Converted the Q8_0
TinyLlama via the Import GGUF sheet → new MLX model appeared in the Models list
(llama·8bit·1.24GB) and **loads + generates via mlx_lm.load**. 0 log errors. BUILD
SUCCEEDED. Swift-first: no PyTorch added.

**Scope note (honest):** the common modern K-quant GGUFs (Q4_K_M etc.) are NOT
convertible by this lightweight path — the precheck flags them. Full K-quant support
would require adding PyTorch, which the app deliberately avoids.

### Session 2026-06-07 (cont.) — GGUF import now optimizes for MLX

Extended the GGUF→MLX importer to optionally OPTIMIZE the result with a proper MLX
quantization pass, gated on the source precision (verified the gating matters):
- **Full-precision GGUF (F16/F32)** → after convert, run `mlx_lm convert -q` →
  canonical MLX quant (group_size 64, affine). Measured: qwen2 fp16 1.2 GB → 4-bit
  349 MB (~3.4×), still loads + generates.
- **Already-quantized GGUF (Q4_0/Q8_0)** → SKIP. Re-quantizing an already-quantized
  model adds overhead + loses quality (measured ~9 bpw from an 8-bit source), so the
  imported model is left as-is — already optimal.

- `GGUFImportService.convert(path:outputName:optimize:optimizeBits:)`: after the
  helper writes the model, `modelIsQuantized(dir)` checks config.json; if
  full-precision and `optimize`, `quantizeInPlace` runs `mlx_lm convert -q` to a temp
  dir and swaps it in. Optimize failure is non-fatal (keeps the unquantized model).
- `GGUFImportView`: "Optimize for MLX (quantize)" toggle + 4/8-bit picker, shown only
  for full-precision GGUFs; already-quantized shows "imported as-is, already optimal".

Verified end-to-end: F16 path convert→quantize→swap→load (1.2GB→349MB, generates);
quantized path correctly skipped. BUILD SUCCEEDED.

### Session 2026-06-13 — autonomous improvement loop (deep-research + 10 iterations)

A self-paced `/loop` doing "deep research on LLMPro and improve it." Each
iteration: pick the next backlog item from the audit, dispatch a Builder, gate on
build + the 39-test suite, commit locally (push is the user's call). Running tally:

- **Iter 1 — GGUF→MLX chat-template fallback** (`d6be9ee`): templateless instruct
  GGUFs now get a per-arch fallback chat template on import (ChatML/Gemma/Llama3/
  Phi3/Mistral); metadata-present path stays byte-identical. Closes the half-done
  item at "GGUF→MLX importer does not reconstruct a chat template".
- **Iter 2 — first XCTest suite** (`0794373`): 37 tests on the loop's critical-path
  pure functions (LogStreamParser, DatasetService classify, AutoTuner,
  FuseService templates). Deleted the stale `Tests/MLXStudioTests/`.
- **Iter 3 — Code tab serves text-diffusion models** (`0eef282`): the agentic Code
  loop can now drive DiffusionGemma via `diffusion_server.py` (OpenAI-compatible,
  Gemma tool-call syntax → OpenAI `tool_calls`). Verified a live
  Orchestrator→Coder→write_file chain.
- **Iter 4 — ModelRegistry size dedup** (`3472ea7`): when a model appears in both HF
  cache layouts, keep the larger `sizeBytes` (fixes the wrong per-model size
  readout). +2 tests → 39 total.
- **Iter 5 — llama.cpp guard + one-click installer** (`a5d078c`): see the
  RESOLVED note above. `FuseError.llamaCppMissing` fail-fast guard +
  `PythonRuntime.installLlamaCpp` + Install buttons in Export & Settings. Build +
  39 tests green.
- **Iter 6 — Resume button for orphaned jobs** (`2ca6d78`): the Progress tab
  now offers a "Resume lesson" card for jobs orphaned by an app restart (see the
  RESOLVED note above). New `TrainingService.latestAdapterCheckpoint(in:)` +
  Monitor `resumeCard`/`attemptResume`. Build green.
- **Iter 7 — delete dead `AgentTemplate.swift`** (`afebf99`): the 8-preset
  starter-template type for the removed switchable-agent flow was unreferenced
  (grep-confirmed zero external uses) since the team model replaced it. Removed
  the file, regenerated the project, and corrected the current-state doc
  references (ARCHITECTURE/CONVENTIONS/WORKFLOWS/STATE/CLAUDE) that still called
  it "dead code" rather than deleted. Build green.
- **Iter 8 — low-disk warning banner** (`0299474`): new pure-Foundation
  `Core/DiskSpace.swift` (`freeGBForImportantUsage()` + pure `tier(freeGB:)`) and
  the first `Features/Shared/` view, `LowDiskWarningBanner` (amber <20 GB / red
  <5 GB / hidden otherwise; polls every 30s), placed atop the Models and Teach
  tabs — model downloads + training could previously exhaust the disk silently.
  Also folded in the stale-badge fix: Models-tab diffusion badge now reads
  "Diffusion · chat + Code" (was "chat only"), with the matching doc references
  de-staled. Build green (incl. the 80ms type-check gate).
- **Iter 9 — custom eval suites importable + delta confirmed** (`324ac9f`): the
  "Score it" delta vs the previous fine-tune was already implemented; the gap was
  custom suites being unreachable from the UI. `EvalService` gained `customSuites()`
  (discovery), `importCustomSuite(from:name:)` (validates each row has non-empty
  `prompt`+`tests`, copies to `evals/custom-<uuid>/`, writes `suite.json`),
  `deleteCustomSuite(id:)`, and a pure unit-testable `validateSuiteText`. ArenaView's
  suite picker is now a menu listing the built-ins + discovered custom suites, with
  an "Import suite…" button (NSOpenPanel) + delete. Resolves the long-standing
  "custom suites: on-disk only, no authoring UI" boundary (docs de-staled across
  WORKFLOWS/CONVENTIONS/CONTRACTS/EXTENDING/STATE/REFERENCES). Build + 39 tests green.
- **Iter 10 — Practice cumulative keeper buffer (overfit root-cause fix)** (this
  commit): each round trained on **only that round's keepers** (a handful of
  passers → the LoRA memorised then collapsed: the smoke run's 31%→9%). It now
  trains on a **cumulative deduped buffer of all rounds' keepers** (`round_N/
  cumulative/`, built by the pure `SelfImproveService.mergeAndSplitKeepers` —
  dedup by user-prompt, latest round's solution wins), so the training set grows
  monotonically. Held-out eval, seed/eval split, prior-adapter continual scheme,
  and the numeric defaults are all unchanged (those need a live run to tune).
  +6 unit tests (45 total). Build + tests green. See the Practice section above —
  the structural cause is fixed; whether the curve now *improves* still needs a
  live multi-round Practice run to confirm.

**Loop complete — 10/10 iterations.** Commits `d6be9ee`, `0794373`, `0eef282`,
`de2cf94`, `3472ea7`, `a5d078c`, `2ca6d78`, `afebf99`, `0299474`, `324ac9f`, +
this one. Resolved STATE.md items: GGUF chat-template, llama.cpp installer,
orphaned-job Resume, dead `AgentTemplate`, disk guard, custom-suite authoring UI,
Practice overfit root-cause. Iters 1–9 pushed to GitHub; iter 10 local.
