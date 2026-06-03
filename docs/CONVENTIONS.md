# Conventions and design decisions

> 📝 **Maintainers**: when you make a design decision (chose X over Y) or
> reverse an existing one, add or amend the relevant section here. If you're
> tempted to deviate from a convention listed below, update the convention first
> and explain *why* — don't silently violate it. See the
> [doc-maintenance contract](../CLAUDE.md#%EF%B8%8F-documentation-is-part-of-the-work--read-this-section-twice).

Why the code is the way it is. Read this *before* making structural changes.
Every entry exists because we evaluated alternatives and chose this approach for
a reason that's not always obvious from the code.

---

## Platform & framework

### Why SwiftUI (not Tauri/Electron)?

The user picked native SwiftUI explicitly during the planning phase. Native gives
us the cleanest macOS feel, the smallest shell footprint, real menu integration,
and access to Swift Charts for the live loss curves. The tradeoff vs Tauri is
that we wrote more Rust-free glue but didn't have to ship a JavaScript runtime
inside the app.

If you find yourself wanting to add Electron-style web rendering for a view, push
back. We have Swift Charts, AttributedString, TextEditor — every UI we've needed
has been built natively.

### Why Apple Silicon only?

The whole product depends on `mlx-lm`, which is Apple-Silicon-native (Metal). On
Intel Macs it'd be ~10x slower without GPU acceleration. We set `ARCHS: arm64` in
`project.yml`. Don't add x86_64 to the slice list.

### Why macOS 14 minimum?

We use:
- `@Observable` macros (Swift 5.9+ / macOS 14)
- `NavigationStack` / `NavigationSplitView` modern API
- `Swift Charts` modern chart styles
- SwiftData (macOS 14+)

These all bake into the minimum target. Bumping down to macOS 13 would mean
rewriting persistence (drop SwiftData for Core Data or GRDB) and observation
(drop `@Observable` for `ObservableObject`). Not worth it.

---

## Python integration

### Use as little Python as possible (Swift-first rule)

**Default to Swift. Reach for Python only for work that genuinely cannot be done
natively.** Python here is a *sidecar for the ML runtime*, not a general-purpose
scripting layer — every line of it is a signing/notarization liability, a venv
dependency, a subprocess round-trip, and a thing the next agent has to keep in
sync with the Swift side. The less of it, the smaller and more robust the app.

Concretely, before adding (or growing) a `.py` helper, ask: *can Swift do this?*
If yes, do it in Swift.

- **Belongs in Python** — only what requires the Python ML stack: the `mlx-lm`
  CLI (train / generate / server / fuse), `huggingface_hub` transfers, and direct
  model-weight surgery via `mlx`/`mlx_lm.utils` (strip-vision, abliterate, expert
  merge/prune). These have no Swift equivalent — see
  [`CONTRACTS.md`](CONTRACTS.md#1-the-mlx-lm-cli-surface).
- **Belongs in Swift** — networking (`URLSession`), JSON, file I/O, path logic,
  process orchestration, dataset/JSONL transforms, scanning the HF cache, parsing
  helper output, anything UI-adjacent. Foundation already covers these; a helper
  that mostly does plumbing should be Swift.
- **Don't reach for Python out of habit.** "It's easier to script in Python" is
  not a reason when the result ships in the bundle forever. A Swift function in a
  Service is cheaper to maintain than a 16th helper.
- **If you must add a helper,** keep it minimal and single-purpose (see "Helper
  scripts: one file per capability" below), and register it in
  `PythonRuntime.installHelpers()` + the `pip install` line. But first re-read this
  rule — most "I'll add a Python script" impulses are better as Swift.

This sharpens, not contradicts, the sidecar decision below: Python *exists* for the
ML runtime; it should not creep beyond it.

### Why a sidecar venv (not embedded Python)?

We considered embedding Python via PythonKit or static-linking `libpython`. Both
were rejected because:

1. **Signing/notarization** for an embedded Python interpreter is painful (every
   `.so`, `.dylib`, every site-package binary needs to be signed).
2. **Updating mlx-lm** would mean shipping a new app build every time mlx-lm
   ships a fix. With a sidecar venv we can `uv pip install -U mlx-lm` without
   touching the app.
3. **PythonKit's stdout capture** is unreliable for long-running training jobs
   (we'd lose mlx-lm progress lines).

The sidecar approach: bundled `uv` binary (or system one), venv at
`~/Library/Application Support/MLXStudio/runtime/.venv/`, helper scripts copied
out of the bundle on every launch. Communication is one-way JSON-event lines on
stdout. Simple and robust.

### Why `python -m mlx_lm <subcommand>` (not `python -m mlx_lm.<subcommand>`)?

`python -m mlx_lm.lora` was the old form. mlx-lm 0.31.x emits a deprecation
warning and the spec is moving to subcommand-style (`mlx_lm lora`). We use the
new form everywhere — see [`CONTRACTS.md#1-the-mlx-lm-cli-surface`](CONTRACTS.md#1-the-mlx-lm-cli-surface).
If you grep for the old form, replace it.

### Why the disk-size poller (not tqdm)?

`hf_download.py` used to monkey-patch `huggingface_hub.utils.tqdm.tqdm` to emit
progress events. That worked for HTTP downloads but **HuggingFace switched to xet**
(chunked, parallel transport) for many repos, which bypasses tqdm entirely. So
progress events stopped flowing.

The current design: spawn a background thread that polls
`<cache>/blobs/` size every 250 ms and emits a `{"event": "progress", "downloaded", "total"}`
line. The poller works regardless of which transport huggingface_hub uses
internally. Filesystem-based, brittle to nothing.

If you "improve" this, make sure it survives a future HF transport change.

### Helper scripts: one file per capability

The Python helpers (currently ~15: `hf_download`, `prepare_coding_dataset`,
`download_hf_dataset`, `strip_vision`, `abliterate`, `merge_models`, `add_expert`,
`manage_experts`, `humaneval_pull`, `self_improve_round`, `eval_pass_rate`,
`mlx_run`, `mem_probe`, `model_memory`, `profile_experts`) share **no Python
imports** with each other — each is a self-contained file that knows the
JSON-event protocol. This keeps the bundle simple and lets agents add a new
helper without touching anything else.

If a helper needs a shared utility, copy-paste the function (small enough).
Don't introduce a `lib/` module — it complicates the bundle-copy logic.

(But per the **Swift-first rule** above: prefer not adding a helper at all. Each
one is permanent bundle weight — only add it for work that truly needs the Python
ML stack.)

### Apple-Silicon MLX memory tuning runs on every mlx_lm call

Every mlx_lm invocation (training, inference, the coding-agent server) is routed
through `mlx_run.py` by `MemoryService.wrap()` — **always**, not just when the
Memory-tab budget is on. The reason: on Apple Silicon, MLX's stock memory and
cache limits default *above* the Metal recommended working-set ceiling (~84% of
unified memory), so a large run grows past the safe point and hard-crashes with
`kIOGPUCommandBufferCallbackErrorOutOfMemory`. `mlx_run.py` reads the real ceiling
from `mx.device_info()` and re-pins `set_memory_limit` / `set_wired_limit` /
`set_cache_limit` to it, so MLX frees its cache *before* crossing — a graceful
slowdown instead of a crash. The limits are **soft**: a run that genuinely needs
more is still allowed, so nothing that used to fit stops fitting. We can't raise
the ceiling itself (that needs `sudo sysctl iogpu.wired_limit_mb`), so
`set_wired_limit` is clamped to it. `MLXSTUDIO_NO_AUTOTUNE=1` opts out. See
[`CONTRACTS.md#3-helper-script-protocol`](CONTRACTS.md#3-helper-script-protocol).

Corollary: `AutoTuner`'s hyperparameter table stays the conservative source of
truth for *what fits*; the `mlx_run.py` tuning is a safety net that makes
over-budget runs degrade gracefully rather than a license to over-allocate.

---

## SwiftUI structure

### Why @MainActor @Observable singletons for services?

SwiftData's `ModelContext` is `@MainActor`-bound. Our views read from
`@Environment(\.modelContext)` which is the main-actor context. So if a service
mutates SwiftData, it has to be on the main actor anyway. Combining that with
`@Observable` so SwiftUI can subscribe to service state is the cleanest design.

We tried `actor TrainingService` originally. It triggered ~15 Swift 6 strict-
concurrency errors around passing `@Model` types into actor isolation contexts.
Refactoring to `@MainActor` cleaned them up. The background work (Process I/O)
happens on Foundation queues already, so MainActor isolation doesn't bottleneck.

### Pattern: services do, views show

```
View   → reads from a Service's @Observable state, dispatches user actions
       → @Query for SwiftData reads
Service → @MainActor singleton, owns business state and Process orchestration
       → mutates SwiftData via modelContext from a Task { @MainActor in } block
Core   → pure utility types: ProcessRunner, PathResolver, LogStreamParser
```

If a View file grows past ~300 lines OR contains nontrivial side effects (file
I/O, subprocess launches, network), refactor: extract to or augment a service.

### Pattern: re-fetch SwiftData @Model by UUID inside Tasks

```swift
// Wrong (Swift 6 strict concurrency rejects):
Task.detached {
    job.appendStep(step)              // ← capturing @Model into Sendable closure: error
    try? context.save()
}

// Right:
Task { @MainActor in
    if let job = fetchJob(id: jobID, context: context) {  // ← re-fetch by UUID
        job.appendStep(step)
        try? context.save()
    }
}

private static func fetchJob(id: UUID, context: ModelContext) -> TrainingJob? {
    let descriptor = FetchDescriptor<TrainingJob>(predicate: #Predicate { $0.id == id })
    return (try? context.fetch(descriptor))?.first
}
```

This pattern appears in [`TrainingService.swift`](../MLXStudio/Services/TrainingService.swift)
and is the cleanest way to handle long-running background work that needs to
mutate a SwiftData record. Use it.

### Pattern: NotificationCenter only for cross-tab events

The only cross-tab signalling is via `Notification.Name` extensions, declared
next to the senders and consumed in `RootView.sidebar.onReceive`. Don't expand
the pattern past a handful of named events.

For more complex shared state, add a service. Cross-tab "open this in another
tab" is the only legitimate use.

---

## The feedback loop (the app's organizing spine)

### The sidebar is a loop, not a menu

The tabs are the stages of **one closed feedback loop** — *download → fine-tune →
test → use → (retrain)* — that a single artifact (a base **model**, and after
fine-tuning its **LoRA adapter**) travels through. This is the app's organizing
principle, documented in full in [`CONCEPT.md`](CONCEPT.md). When you add a tab or
a cross-tab flow, ask "which loop edge is this?" If the answer is "none — it's a
standalone tool," reconsider: a feature that produces or consumes a model but leaves
the user to copy a disk path by hand is a *sibling tool*, not a loop stage, and it
breaks the spine.

### Cross-tab artifact hand-off goes through `ModelHandoff` + notifications

When one stage hands a model (+adapter) to the next tab, carry it as a
[`ModelHandoff`](../MLXStudio/Core/LoopHandoff.swift) `{model, adapterPath?}` posted
as the `object` of a cross-tab `Notification.Name` — **not** a shared global, a
singleton field, or asking the user to re-type a path. Receivers accept **either** a
`ModelHandoff` **or** a bare `String` (model only) for backward compatibility with
older posters (`as? ModelHandoff ?? as? String`). This is the loop's glue; keep it
notification-shaped so the `RootView` tab-switch and the destination view's pre-fill
stay decoupled.

### Hand-offs are user-driven CTAs — no surprise auto-navigation

A stage completing must **not** auto-switch the user to another tab. Training and
Practice completion show a **CTA card** ("Try it out" / "Use in Code" / "Save &
Use"); the user clicks it. This protects the
[window-close ≠ quit](#detached-subprocesses-for-long-running-work) ethos — yanking
the user away when a 30-minute fine-tune finishes (they may be elsewhere on
purpose) would fight it. The completion → next-stage edges
([`TrainingMonitorView`](../MLXStudio/Features/Monitor/TrainingMonitorView.swift)
card, [`ArenaView`](../MLXStudio/Features/Chat/ArenaView.swift) decision bar,
[`SelfImproveView`](../MLXStudio/Features/SelfImprove/SelfImproveView.swift) "Use
this fine-tune" menu) are all buttons, never `onChange`-driven navigation.

### Refine-from-adapter reuses the source config (resume-compatibility)

The retrain back-edge (③/④ → ②) is "continue a previous fine-tune." Teach's
"Continue a previous fine-tune?" picker → `launchRefine(from:)` **reuses the source
job's exact `configYAML`** (swapping only `adapter_path`) and continues from its
weights via `TrainingService.start(…, resumeAdapterFile:)` (→ mlx-lm
`--resume-adapter-file`). Reuse the source config rather than re-deriving one: a
resumed LoRA must keep the *same* architecture (rank, keys, layers) as the
checkpoint it resumes from, or mlx-lm can't load the adapter. Don't run a refine
through a fresh `AutoTuner.tune()` — that could change the LoRA shape.

---

## UX

### "9-year-old friendly" by default; technical by disclosure

Following an explicit user request, the primary UI uses:
- Plain-language status ("Opening the textbook…")
- Emoji for non-decorative semantic meaning (🐭 = Tiny, 📚 = Learning, etc.)
- Star ratings (TrainingNarrator) instead of raw loss numbers
- Time estimates and ETAs in plain English ("less than a minute left")

The technical surface (charts, raw log lines, mlx-lm YAML) **always lives behind
a `DisclosureGroup` labelled "Technical details" or "Advanced settings"**. Don't
expose loss numbers, learning rates, or iter counts in primary copy. The Narrator
gives you a friendly version of every state.

### AutoTuner picks hyperparameters

The Teach view shows the user three choices:

1. Which model to teach
2. Which dataset to teach it
3. How long (Quick / Standard / Thorough)

Every other hyperparameter (batch_size, iters, num_layers, learning_rate,
grad_accumulation_steps, max_seq_length, gradient checkpointing, LoRA rank,
LoRA scale, LoRA target keys, optimizer, **the warmup→cosine LR schedule, and
whether to use DoRA**) is picked by
[`AutoTuner.swift`](../MLXStudio/Services/AutoTuner.swift) based on
`(ModelSize, TrainingDuration)`. If you find yourself adding a fourth picker to
the Teach view, stop and ask whether AutoTuner should pick it instead.

### Smarter fine-tune recipe (DoRA + LR schedule) — the MLX-native answer to "Unsloth"

A user asked us to "improve capability like Unsloth / densification." The honest
reality (researched, sourced in [`STATE.md`](STATE.md); see also
[`REFERENCES.md`](REFERENCES.md)): **[Unsloth](https://github.com/unslothai/unsloth)
can't run here** — its speedups are NVIDIA Triton / xformers / BitsandBytes kernels
(CUDA 7.0+); the
"macOS/MLX" in their README is a separate product (Unsloth Studio), not the
importable library. **"Densification" isn't a real Unsloth/fine-tuning technique**
(it's an academic MoE→dense distillation term — a conflation). What *is* portable
are the algorithm/data-side recipe ideas, and mlx-lm already supports the best ones:

- **DoRA** (`fine_tune_type: dora`) — weight-decomposed LoRA; better quality at the
  same rank for a small cost. AutoTuner auto-selects it for the **Thorough** tier.
- **Warmup → cosine-decay LR schedule** (`lr_schedule`) — emitted on every run.
  Steadier early steps, better final minimum than a flat LR.

So we lean on these (and get fused attention / grad-checkpointing for free from
MLX's own Metal backend) instead of pretending to bolt on a CUDA library. If you
extend this, stay on the portable side (rsLoRA scaling, muon optimizer, NEFTune,
sample packing) — never add a hard dependency that needs CUDA/Triton.

### Why the time estimates are hard-coded by size bucket

We tried a tokens-per-second model: `seconds_per_iter = batch * seq_len / tok_s`.
Result: the estimate said "300 minutes" for a Llama 1B run that actually took 3.
Two problems:

1. Real example token counts average ~150 tokens per row in CodeAlpaca, but the
   formula assumed max_seq_length. 10x overestimate.
2. The throughput numbers we picked were too conservative.

Current approach: per-size empirical seconds-per-iter constants in
`AutoTuner.swift`, calibrated against actual M-series runs. Update them when we
get new measurements. Don't go back to the formula.

### Why we don't show raw loss anywhere primary

Loss is unintuitive: "your model went from 1.5 to 0.7" doesn't mean much to a
human. The star rating ("4 stars / Getting good!") and the descending curve in
Technical Details convey the same information to different audiences.

---

## File / path discipline

### All paths go through `PathResolver`

Never write `URL(fileURLWithPath: "~/Library/...")` directly. Always:

```swift
PathResolver.appSupport
PathResolver.runtimeDir
PathResolver.venvPython
PathResolver.hfHome
PathResolver.adaptersDir
PathResolver.adapterDir(for: jobID)
PathResolver.datasetsDir
PathResolver.datasetDir(for: dsID)
PathResolver.modelsCustomDir
PathResolver.exportsDir
```

This lets us change the layout in one place. If you find a hardcoded path
elsewhere, refactor it through PathResolver.

### Local-model paths must be resolved before being passed to mlx-lm

Custom local models live at `~/Library/Application Support/MLXStudio/models/<name>/`.
Their `DetectedModel.repoID` is just `<name>` (a folder name, no slash). mlx-lm
interprets a bare string with no slash as a HuggingFace repo ID and bails.

The resolver is `TrainingConfigView.resolveModelArg()`. **Always run user model
selections through this** before writing `model:` into a YAML or passing to mlx-lm:

```swift
let modelArg: String = repo.contains("/") ? repo : (localModel?.directory.path ?? repo)
```

Symptom of forgetting this: mlx-lm exits 1 immediately after "Loading pretrained
model" with no helpful stderr. We fixed this once; don't reintroduce it.

---

## Process management

### Detached subprocesses for long-running work

Training subprocesses are children of the app. When the user closes the window,
we override `applicationShouldTerminateAfterLastWindowClosed → false` to keep the
process alive. When the user picks "Quit", we offer a "Detach and Quit" option
that uses `setpgid` to keep the subprocess independent of the parent, with a
`job.json` sidecar so we can re-attach on next launch.

Don't kill processes silently. The user might have a 30-minute fine-tune
running. Always show the quit prompt.

---

## Self-improvement loop (the Practice tab)

### Why rejection-sampling self-distillation, not DPO / RLAIF / agent-rewriting-code?

We considered three other shapes before landing on rejection-sampling:

| Considered | Why we passed |
|---|---|
| **DPO / preference fine-tuning** | Requires a reliable judge for *every* generated pair. mlx-lm's DPO support is newer and the judge bottleneck (LLM-as-judge is noisy, slow, reward-hackable) is harder than the training. Full RLHF ([OpenRLHF](https://github.com/OpenRLHF/OpenRLHF), see [`REFERENCES.md`](REFERENCES.md)) is heavier still — a future direction, not used today. |
| **autoresearch-style code mutation** (Karpathy's loop) | Improves the *training recipe*, not the model's capability. AutoTuner already picks good defaults — we'd be optimizing in a small, well-understood search space. And it requires an editable training script, which breaks our "AutoTuner is the only knob" principle. |
| **Self-judging via the same model** | Drifts. Without an external ground-truth signal the model rewards its own confident-sounding mistakes. |

What we picked — **rejection sampling + unit-test gating** — gives us a hard, deterministic ground-truth signal: the test either runs and asserts or it doesn't. No judge bias, no reward-hacking, no drift. The downside is that it only works for tasks where you can write tests (coding, in our case) — but that's the exact use case the app is designed around.

### Why the model loads once per round (not per prompt)

`mlx_lm generate` as a CLI is per-prompt subprocess: load model → generate → exit. A round of self-improve generates ~80–500 candidates (rows × K). Loading a 27B model 500 times would dominate wall-clock. So `self_improve_round.py` and `eval_pass_rate.py` are **long-running Python processes** that import `mlx_lm` once, then loop. The CLI per-turn shape (used by `InferenceService` for chat) is right for chat (low latency, one turn at a time); the in-process loop shape is right here. Don't mix.

### Why the test runner is a subprocess sandbox (not exec inside the round helper)

Generated code is mostly-trusted (from a fine-tune we control) but not entirely: a bad sample could `os.remove(...)`, hang, or OOM. So `run_one_test()` in `self_improve_round.py` writes the candidate + tests to a temp file and spawns a fresh `python` subprocess with:

- `resource.setrlimit(RLIMIT_AS, 1GB)` — caps memory inside the child
- `signal.alarm(timeout)` — child SIGALRM safety net
- `subprocess.run(..., timeout=timeout + 5)` — parent kill if the child misses its own alarm

We deliberately do **not** restrict network or filesystem access — that would require `sandbox-exec` and start fighting macOS's evolving sandbox rules. The trust model is "this is a model the user just fine-tuned" — not "this is untrusted code from the internet." If we ever generalize the loop to user-supplied prompts of arbitrary origin, revisit.

### Per-round adapters live under `adapters/`, not under `selfimprove/`

Each round produces a real LoRA adapter that the user might want to chat with or export. Putting them under `adapters/<round-job-uuid>/` (same as ordinary `TrainingJob` adapters) means they show up automatically in the Arena and Save & Use tabs, with no special-case code. The `SelfImproveRoundRecord.adapterRelativePath` is the round-job UUID — same shape as `TrainingJob.adapterRelativePath`.

### The loop is a single big `Task { @MainActor in }` block

`SelfImproveService.start(run:, context:)` runs the entire end-to-end pipeline in one Task. That's intentional — the loop has long ordering dependencies (round N's adapter is the input to round N+1's generation) and threading the state machine through callbacks or NotificationCenter would be miserable. The trade-off: cancellation has to be done by killing the active subprocess (`cancel()` sets phase to `.cancelled` and SIGTERMs `activeProcess`), and we have to be careful never to capture `@Model` instances into nested closures (we use the `Self.fetchRun(id:context:)` pattern, mirroring TrainingService).

---

## The coding agent (Code tab)

### Why a persistent `mlx_lm server` daemon (not per-turn `mlx_lm generate`)

The agent loops — one task can take a dozen model turns. Cold-loading a 27B model
on every turn (what `InferenceService` does for Arena chat) would be unusable. So
[`MLXServerService`](../MLXStudio/Services/MLXServerService.swift) runs
`python -m mlx_lm server` as a **long-lived daemon**: the model loads once and is
reused for every turn. This is the answer to STATE.md's long-open "should there be
a model pinning / pre-load step?" design question — mlx-lm *does* have a server
now. The Arena keeps the per-turn cold-load shape (one-shot chat, lower setup
cost); the agent uses the daemon. Don't mix the two — they're right for different
access patterns.

### Why dual tool-calling (native `tools` AND a `<tool_call>` text fallback)

We send the OpenAI `tools` array on every request *and* instruct the model (in the
system prompt) to emit `<tool_call>{…}</tool_call>` text, then parse whichever we
get back. The reason: mlx-lm only produces native `tool_calls` for models whose
tokenizer template is tool-aware, and the small coding fine-tunes this app
produces often aren't. The fallback format is deliberately the one Qwen's template
emits natively (Qwen3.6-27B-bf16 renders the `tools=` kwarg and emits
`<tool_call>` markers), so it doubles as a safety net rather than a separate
protocol. See [`CONTRACTS.md#9-local-openai-compatible-chat-api--agent-tool-protocol`](CONTRACTS.md#9-local-openai-compatible-chat-api--agent-tool-protocol).

**But the two instructions are mutually exclusive in the prompt.** When native
tools are on (the "Use native tool-calling" toggle, default), `TeamRole.systemPrompt`
takes `nativeTools: true` and **omits** the `<tool_call>` text example entirely —
it only says "use your function-calling interface." This is load-bearing for
reasoning models: Gemma-4 *follows* the text example when you give it one and emits
malformed text JSON containing its special quote token `<|"|>` (which breaks the
parser) instead of using the clean native path. Only when the user turns native
tools **off** does the prompt teach the `<tool_call>` text format. The parser still
accepts both at runtime (and `AgentTools.sanitizeToolBlock` repairs a stray
`<|"|>`→`"`), but the *prompt* should never advertise both at once.

### Safety model: workspace sandbox + per-action approval

The agent can write files and run shell commands, so two guardrails apply:

1. **Workspace sandbox.** `ToolExecutor.sandboxed()` lexically resolves `..` and
   rejects any path that escapes the user-chosen project root; `run_command` runs
   with cwd set to the workspace. Output is truncated to 16000 chars.
2. **Per-action approval.** Read-only tools (`read_file`/`list_dir`/`grep`) run
   automatically; mutating tools (`write_file`/`edit_file`/`run_command`) are gated
   behind an inline Allow/Deny bar unless the user opts into the `autoApproveEdits`
   / `autoRunCommands` toggles. Default is ask-before-edit/command.

This mirrors claw-code / opencode's permission posture, scaled down to two toggles.
If you add a new mutating tool, mark it non-read-only so the gate covers it
automatically.

### Friendly-first still holds

The Code tab follows the same rule as the rest of the app: warm copy + the
server-status dot + plain-language tool cards lead; the technical surface
(native-tools toggle, temperature/max-tokens, the raw server log) lives behind the
**Options → Advanced** and **Server log** disclosures. Don't invert.

### The Code tab is a fixed five-role Orchestrator team (replaced the agent library)

Per an **explicit user decision**, the Code tab's switchable single-agent library
was replaced by a **fixed five-role team** ([`TeamRole`](../MLXStudio/Services/AgentRoles.swift):
orchestrator · planner · researcher · coder · ui). The user talks **only to the
Orchestrator**, which delegates to the others. There is no agent picker and no saved
profiles. The old single-agent *profile* plumbing
([`AgentProfile`](../MLXStudio/Models/AgentProfile.swift),
[`AgentTemplate`](../MLXStudio/Features/Code/AgentTemplate.swift)) is now **dead
code** — it still compiles but nothing references it (`AgentProfile` stays in the
SwiftData schema only because the schema is additive-only); the old
`AgentEditorView` was **deleted**. Don't reintroduce a
picker; the team is fixed by design. **Exception:** `SkillStore` /
`SkillsManagerView` / the `use_skill` tool — also originally part of that library —
were **revived as Agent Skills** and wired into the live team (see "Agent Skills:
progressive disclosure + linking" above); they are NOT dead.

### Team agents are Markdown files (editable; compiled defaults are the fallback)

The five roles are **defined by Markdown files**, not only hardcoded Swift. Each
role has a bundled `Resources/agents/<role>.md` (YAML-ish frontmatter +
system-prompt body) that [`AgentStore`](../MLXStudio/Services/AgentStore.swift)
seeds into `PathResolver.agentsDir` **only if missing** — so a user (or an agent
writing the file) can edit a role's character, tools, delegates, emoji/tint, or
iteration cap, and the edit **survives launches** (unlike the Python helpers, which
overwrite every launch). The design pattern: `AgentStore.load()` parses each file
into an `AgentDefinition` and publishes a `nonisolated(unsafe) static var overrides:
[String: AgentDefinition]` snapshot; `TeamRole`'s computed properties read
`AgentStore.overrides[rawValue]` and fall back to a compiled-in `defaultX` per
field — so **the markdown is authoritative and the Swift values are the fallback**
(a missing file or absent field is harmless). The project folder, workspace
overview, and tool-calling footer are still appended in code so they stay
consistent across roles; the markdown body is just the role's "character". Editing
is via [`AgentsManagerView`](../MLXStudio/Features/Code/AgentsManagerView.swift)
(Options → "Edit team agents…"), which Saves the file + reloads `AgentStore`, or
Resets to the bundled default. This is **separate** from the dead
`AgentProfile`/`SkillStore` library — don't conflate them. If you add a role field,
add it to `AgentDefinition` + the parser + the `TeamRole` fallback together. Format
contract: [`CONTRACTS.md`](CONTRACTS.md#agent-markdown-file-format-team-agents).

### One shared model; "parallel" agents = concurrent in-flight requests

All five roles run on **one** `mlx_lm server` daemon — there is no per-role model.
When the Orchestrator dispatches two builders in the same turn, they run as
unstructured Tasks whose `await` points **interleave on the one shared GPU/server**;
"parallel" here means concurrent in-flight requests, not two models loaded at once.
Keep the one-model invariant — loading a second model would blow the memory budget.

This is **user-toggleable**: `AgentSettings.parallelAgents` (Options → "Run teammates
in parallel", default ON). When **off**, `runDelegations` runs each delegate to
completion before starting the next, so only one request is ever in flight — the
intended choice for a smaller model where two concurrent decodes thrash. The engine
enforces the order regardless of how many `call_*` the Orchestrator emits in a turn.

### Sub-agents-as-tools (a delegation tool runs a nested role loop)

Delegation is modeled as a **tool**: `call_<role>(task)` runs the named role's loop
to completion (in [`CodingAgentService.runDelegations` / `runDelegate`]
(../MLXStudio/Services/CodingAgentService.swift)) and returns its final answer as the
tool result. The callee gets a self-contained `task` and does **not** see the
caller's conversation. Delegation is **depth-capped at 5**. `call_*`, `ask_user`,
and `todo_write` are intercepted by the orchestration engine, not `ToolExecutor`.
Keep this shape when adding a role or a coordination tool — don't build a separate
scheduler.

### Real web research via DuckDuckGo (no API key)

The Researcher gets real web tools ([`WebSearch`](../MLXStudio/Services/WebSearch.swift)):
`web_search` scrapes the **DuckDuckGo HTML endpoint** (no key, no account) and
`fetch_url` downloads + strips a page to readable text. It's deliberately key-free
and best-effort (degrades gracefully) to stay in the app's no-account, local-first
posture. Don't add a paid search API or require credentials.

### Agent Skills: progressive disclosure + linking

**Agent Skills** are reusable `SKILL.md` instruction packages
([`SkillStore`](../MLXStudio/Services/SkillStore.swift)), modeled on the OpenAI
Codex / Anthropic Agent Skills standard. They follow a **3-stage progressive
disclosure** design — the reason the skill catalogue doesn't bloat every prompt:

1. **Discovery** — `CodingAgentService.systemMessage` injects only each in-scope
   skill's `name: description` under a `## Skills available to you` heading. Cheap;
   just enough for the model to know *when* to use one.
2. **Activation** — when ≥1 in-scope skill exists and `AgentSettings.useSkills` is
   on, `runRole` adds the `use_skill` tool; `use_skill(name)` returns the FULL
   instructions body + the skill's folder path (`SkillContext.dirPath`).
3. **Execution** — the agent follows the loaded instructions, optionally reading
   bundled files from the folder path.

**Skills are team-global *by default*, with optional per-agent scoping.** An agent
with **no `skills:` frontmatter sees every installed skill** — this preserves the
implicit-by-description model in Codex / Anthropic (the model decides *when* a skill
applies from its description) and is the default. But an agent can now **opt into a
subset** via its `agents/<role>.md` `skills: [skill-id, …]` frontmatter (a
skill→agent link): `nil` (key absent) = ALL skills, `[]` = none, a list = exactly
those. `CodingAgentService.availableSkills(for: role)` (reading
`TeamRole.skillIDs`) scopes BOTH the discovery list AND `use_skill` availability.
This **supersedes** the old per-agent `enabledSkillIDs` on the dead `AgentProfile`
(which was a UI toggle list, not frontmatter) — don't reintroduce that.

**Skills can link to other skills.** A `SKILL.md` `skills: [other-id, …]`
frontmatter field (alias `links:`) carries skill→skill links; `Skill` /
`SkillContext` expose `links: [String]`. When an agent loads a skill via
`use_skill`, the tool output appends the linked skills' names+descriptions
("Related skills you can also load with use_skill: …"), and a skill linked from an
in-scope skill is itself offered (**transitive** links are followed). `delete(id:)`
**scrubs** the removed id from every other skill's links so there are no danglers.

This **revived** the previously-dead `SkillStore` / `SkillsManagerView` /
`use_skill` code (left over from the removed single-agent library) and wired it
into the live dynamic `TeamRole` team. Skills are local Markdown files, no network —
consistent with the app's offline, no-account posture. Format contract:
[`CONTRACTS.md`](CONTRACTS.md#agent-skills-use_skill--the-skillmd-format).

### Skills and team agents are edited as raw markdown (smart substitution OFF)

Both [`SkillsManagerView`](../MLXStudio/Features/Code/SkillsManagerView.swift) and
[`AgentsManagerView`](../MLXStudio/Features/Code/AgentsManagerView.swift) edit the
**actual `SKILL.md` / `<role>.md` text**, not a form — a list on the left + a
monospace editor on the right + toolbar **＋ New / − Delete / Duplicate** + Reveal
and Save. Two decisions make this work reliably:

- **Custom [`MarkdownEditor`](../MLXStudio/Features/Code/MarkdownEditor.swift), not
  SwiftUI `TextEditor`.** `TextEditor` inherited macOS smart substitution, so typing
  `---` (the frontmatter fence) became `—` (em-dash, U+2014) and silently broke YAML
  parsing — a file saved through the old editor started with U+2014 and parsed to
  `name=nil`/`links=[]`. `MarkdownEditor` is an `NSTextView` wrapper with automatic
  dash/quote/text substitution, smart-insert-delete, spelling correction, and
  data/link detection all **disabled**, `isRichText = false`, monospaced, undo on —
  so it saves exactly what's typed (a saved file now begins with bytes `2d 2d 2d`).
  As a **safety net**, `SkillStore.normalizeFences(_:)` rewrites any dash-only line
  (`-`, en-dash `–`, em-dash `—`) to a canonical `---`, and both `SkillStore.parse`
  and `AgentStore.parse` run input through it first, so older/hand-edited
  smart-substituted files still parse (real `---` and body horizontal rules survive).
- **Create-immediately for New.** The old `.alert`-with-TextField New flow didn't
  fire reliably from a sheet-inside-a-popover, so ＋ now **creates the item
  immediately** with a placeholder name ("new skill" / "new agent") and selects it;
  the user renames by editing the `name:` line in the raw markdown (the folder id
  stays stable). The `showNew`/`newName` alert state was removed from both views.

### Auto-approve defaults ON for the team

`AgentSettings.autoApproveEdits` now defaults **ON** because the builders run
unattended under the Orchestrator. There is a single approval slot, so it
serializes — auto-approve avoids parallel-approval conflicts when two builders
both want to write. The workspace sandbox (above) is still the hard guardrail; the
user can flip auto-approve off in Options to get the per-action gate back.

### `ask_user` lets agents pause for the user

Any role can call `ask_user(question)` to pause the run and ask the user; the loop
awaits the reply (`pendingQuestion` + an answer continuation, resolved by
`answerUser`), surfaced in `CodeView`'s `questionBar`. This is how the team stays
interactive even though the user only ever talks to the Orchestrator. Keep
`ask_user` engine-handled (not a `ToolExecutor` tool) — it's a control-flow pause,
not a workspace action. `ask_user` also takes an **optional `options`** list — the
preferred way for an agent to *steer* the user: offering 2–5 fixed choices renders
one button each (clicking feeds the choice straight back), so a model can pin down
a framework / yes-no / approach without parsing free text. Free-text questions
still work; options are additive (`CodingAgentService.parseOptions` parses them
leniently — see [`CONTRACTS.md`](CONTRACTS.md#9-local-openai-compatible-chat-api--agent-tool-protocol)).

### Why a native, regex-based syntax highlighter (not Monaco / CodeMirror / a WebView)

[`SyntaxHighlighter`](../MLXStudio/Core/SyntaxHighlighter.swift) is a small,
dependency-free highlighter that produces `AttributedString` (for SwiftUI `Text`)
and `NSAttributedString` (for the editor's `NSTextView`). We deliberately did **not**
embed Monaco / CodeMirror in a `WKWebView`: that would reintroduce a JavaScript
runtime — exactly the dependency the whole app avoids (see "Why SwiftUI" above) —
plus WKWebView's macOS-sheet quirks. The tradeoff is honest: the highlighter is a
regex approximation, not a full grammar (it can mis-tint pathological cases), which
is fine for reading diffs and lightly editing files. If you want richer highlighting,
extend the regex rules — don't reach for a web engine.

### Why the Code tab is a 3-pane IDE (toggleable)

The Code tab is **file explorer | editable highlighted editor | agent chat**
([`FileExplorerView`](../MLXStudio/Features/Code/FileExplorerView.swift) /
[`CodeEditorView`](../MLXStudio/Features/Code/CodeEditorView.swift) /
`chatColumn`), so the user can watch and hand-edit the files the agent touches
without leaving the app. The panes are toggleable from a header sidebar button
(`@AppStorage("codeShowWorkspacePanes")`, default on) and collapse to the
full-width chat — friendly-first still holds: the IDE is a power surface layered
over the chat, not a replacement for it.

### Tool diffs and code render syntax-highlighted in the transcript

`write_file` / `edit_file` diffs and `read_file` output render through
`SyntaxHighlighter` in the transcript (`DiffText` colors the `+`/`-` gutters and
highlights each code line; language inferred from the tool call's `path`). Changes
should read as **code, not JSON** — never show the user a raw tool-call/argument
blob where a highlighted diff would do.

### Streaming-transcript rendering must stay cheap (the agent loop is @MainActor)

`CodingAgentService` runs the whole agent loop on the **main actor**, and the
transcript is an `@Observable [AgentBubble]` rendered in a `LazyVStack`. That
combination is a performance trap: anything expensive in transcript *layout*
blocks the *agent loop itself*, so a slow render doesn't just stutter the UI — it
**stalls the run** (symptom: server idle at 0% CPU, app pinned at 100%, the run
appears to "stop after the Planner"). A live `sample(1)` of a hung run showed the
main thread spinning in SwiftUI `StackLayout` re-measurement. Three rules keep it
cheap; don't regress them:

1. **Never wrap the transcript auto-scroll in `withAnimation`.** An animated
   `proxy.scrollTo` runs inside an animation transaction, so SwiftUI animates the
   placement of every lazy subview (`Array.motionVectors`) and re-runs the full
   nested-stack layout per frame. Use a plain `scrollTo`.
2. **Long bubble `Text` needs `.fixedSize(horizontal: false, vertical: true)`**
   so it computes height once from the offered width instead of entering the
   stack's width/height re-proposal loop, and **`.textSelection` is enabled only
   once streaming ends** (it's costly to lay out on long, growing text).
3. **Coalesce streaming deltas.** `runRole` buffers `textDelta`/`reasoningDelta`
   and flushes to the `@Observable` transcript at most ~12×/sec — mutating it
   per-token re-lays-out the whole growing bubble, which is O(n²) over the message
   and saturates the main thread. If you add a new streamed surface, throttle it
   the same way.
4. **Hard-disable implicit animation on the transcript `LazyVStack`** with
   `.transaction { $0.animation = nil }`. Removing the explicit `withAnimation`
   (rule 1) is not enough on its own: indeterminate `ProgressView` spinners and
   *parallel* builders (two roles streaming into the list at once) keep an ambient
   animation alive, so subview placement animates anyway (`Array.motionVectors`)
   and the main thread pegs at 100% — starving the `@MainActor` agent loop. This
   was the difference between the blazor run (one builder) finishing and the same
   run with parallel Coder+UI dead-locking. Nilling the transaction makes
   placement instant regardless of the ambient animation. (A brief, self-resolving
   layout burst can still happen when a very long Planner message finalizes and
   the parallel dispatch lands at once — but it recovers; it no longer hangs.)

### Agent templates: one-click specialized programming agents

The New-agent flow offers [`AgentTemplate.all`](../MLXStudio/Features/Code/AgentTemplate.swift)
— 8 presets (frontend / backend / tests / refactor / debug / review / docs +
general) that prefill the role instructions and the auto-approve toggles for a
given kind of work (test/refactor/debug default `autoRunCommands` on). Templates
are starter content, not a separate type: they just seed an `AgentProfile` the
user can then edit. Add a role here rather than hard-coding behavior into the loop.

---

## Things we considered and rejected

A short list of "no" decisions so you don't waste time re-evaluating:

- **GRDB or Core Data**: SwiftData is sufficient and modern. Don't switch.
- **PythonKit / static libpython**: see "Why a sidecar venv" above.
- **Tauri / Electron**: see "Why SwiftUI" above.
- **Logging framework (swift-log / CocoaLumberjack, etc.)**: still no third-party
  dep — but the "plain `print` is enough" stance was **reversed (2026-05-31)** in
  favour of a tiny first-party [`Core/Log.swift`](../MLXStudio/Core/Log.swift)
  (`os.Logger` + rotating file + crash/signal breadcrumb). **Use `Log.*` at error
  chokepoints; do NOT add a third-party logging library.** See "Always read the logs
  after testing" under Build hygiene.
- **A general "tasks" abstraction (active jobs of any kind)**: tried it; YAGNI.
  `DownloadService.active`, `DatasetPrepService.active`,
  `ModelModifyService.active`, `JobRegistry.runningJobs` are all per-feature
  lists. Cleaner to keep them domain-specific than to unify under a generic.
- **WebView for the Try-it-out tab**: pure SwiftUI markdown rendering works fine
  and avoids WKWebView's quirks on macOS sheets.
- **Background workers via XPC**: subprocesses + `setpgid` give us 95% of the
  XPC benefit at 10% of the complexity. Don't add XPC unless we have a concrete
  need.
- **App Store distribution**: out of scope for this iteration. Sandboxing is off
  in entitlements; Apple Store would require a real rethink of the Python sidecar.

---

## Style

### Comments

Default: write **no comments**. Names should be enough. Only add a comment when
the *why* is non-obvious — a numeric constant from empirical measurement, a
workaround for a specific upstream bug, an invariant the type system can't
express.

Bad:
```swift
// Set the status to running
job.status = .running
```

Good:
```swift
// mlx-lm 0.31 deprecates the `python -m mlx_lm.lora` form but still accepts it;
// switch to subcommand form for forward compatibility.
arguments: ["-m", "mlx_lm", "lora", "-c", configURL.path]
```

### Identifier conventions

- Services: `<Capability>Service` (`TrainingService`, `InferenceService`).
- View files: `<Section>View.swift` for tab roots, `<Section><Form>View.swift`
  for sheets (`DatasetRowEditorView`, `HuggingFaceDatasetSearchView`).
- Notification.Name: `MLXStudio.<verbAction>` (`MLXStudio.switchToMonitor`).
- Filesystem dirs: lowercase plurals (`adapters/`, `datasets/`, `models/`).
- SwiftData @Model classes: singular (`TrainingJob`, `DatasetRecord`).

### Strings

User-facing strings: plain English, lowercase except sentence start, no
exclamation points unless celebratory (the "All done!" / "Excellent!" copy in
TrainingNarrator is intentional).

Identifier strings (event names, dict keys, JSONL field names): snake_case to
match Python conventions, since they cross the Swift↔Python boundary often.

---

## Build hygiene

### Always regenerate the Xcode project after adding a file

```bash
xcodegen generate
```

XcodeGen reads `project.yml` and globs the source tree. New `.swift` files won't
be picked up by `xcodebuild` until you regenerate. **A common-but-subtle failure
mode is adding a new service file and getting `cannot find type 'NewService'`
errors from the build — that's a missing regen.**

### Swift 6 strict concurrency

We compile with Swift 6. The compiler will reject:
- Static `Regex` properties (not Sendable) — mark `nonisolated(unsafe) let`.
- Captures of `@Model` instances into detached Tasks — use the re-fetch pattern
  (see above).
- Non-Sendable closures (`((String) -> Void)?`) used as `@Sendable` parameters —
  mark the closure type explicitly: `(@Sendable (String) -> Void)?`.
- Global mutable variables — use `nonisolated(unsafe)` or compute on demand
  (e.g. `host_page_size()` instead of `vm_kernel_page_size` global).

### Always read the logs after testing

**A green UI is not a pass. After any test — a build-and-run, a UI walkthrough, a
live model run, a stress sweep — READ THE LOG before you call it good.** The app
writes to [`Core/Log.swift`](../MLXStudio/Core/Log.swift)'s file sink at
`~/Library/Application Support/MLXStudio/logs/mlxstudio.log`; check it three ways
(any one is fine, the file is the most reliable):

```bash
# 1. Tail the persistent file (survives crashes; what to grep)
tail -50 ~/Library/Application\ Support/MLXStudio/logs/mlxstudio.log
grep -nE 'ERROR|FAULT|CRASH' ~/Library/Application\ Support/MLXStudio/logs/mlxstudio.log
# 2. Live unified-log stream while reproducing
log stream --predicate 'subsystem == "com.josh.mlxstudio.MLXStudio"' --level debug
# 3. In-app: Settings → Logs (live tail + Reveal + Copy)
```

Also glance at `~/Library/Logs/DiagnosticReports/MLXStudio-*.ips` for any OS crash
report newer than your test:

```bash
find ~/Library/Logs/DiagnosticReports -name 'MLXStudio*' -mmin -30
```

**Why this is a rule, not a nicety:** the 2026-05-31 stress test reported every one
of the 13 tabs as "PASS" from screenshots alone — yet a real `EXC_BAD_ACCESS` was
sitting in the OS `.ips` the whole time (the alert-dismiss use-after-free). A test
that doesn't read the logs can't see the failure it just triggered. A clean visual +
**zero `ERROR`/`FAULT` lines and no new `.ips`** is the actual bar for "it works."
If the log shows an error the UI didn't, the log wins — investigate before reporting
success.
