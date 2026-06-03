# The core concept — MLX Studio is one feedback loop

> 📝 **Maintainers**: this is the doc that explains *why the app is shaped the way
> it is*. The sidebar tabs are not a menu of unrelated tools — they are the stages
> of a **single closed loop** that one artifact travels through. If you add a stage,
> move a stage, or change how the artifact is handed between stages, update this
> doc first. See the
> [doc-maintenance contract](../CLAUDE.md#%EF%B8%8F-documentation-is-part-of-the-work--read-this-section-twice).

Read this before [`ARCHITECTURE.md`](ARCHITECTURE.md). Architecture tells you what
code lives where; this tells you the **shape** the whole app is trying to be, so
that when you add a feature you keep the loop intact instead of bolting on a
sibling tool.

---

## The one-sentence version

MLX Studio takes **one artifact** — a base **model**, and after fine-tuning its
**LoRA adapter** — and walks it around a closed loop: *download it → teach it →
test it → use it → if it's not good enough, teach it again.* Every sidebar tab is
one stage of that loop, and each transition hands the artifact forward to pre-fill
the next stage so the user never copies a disk path by hand.

---

## The loop in one diagram

```
                            ┌───────────────────────────────────────────┐
                            │                                           │
                            ▼                                           │
   ┌──────────┐      ┌──────────────┐      ┌──────────┐      ┌────────────────┐
   │ ① DOWNLOAD│ ───▶ │ ② FINE-TUNE  │ ───▶ │ ③ TEST   │ ───▶ │ ④ USE (coding) │
   │  "Models" │      │   "Teach"    │      │"Try it   │      │    "Code"      │
   │           │      │ (+ "Lessons" │      │  out"    │      │                │
   │           │      │   pick data) │      │          │      │                │
   └──────────┘      └──────────────┘      └────┬─────┘      └────────────────┘
        model              model + adapter      │  adapter
        (repo ID)          (TrainingJob)        │
                                                │ ⑤ "not good enough?"
                                                └──────────────────────┐
                                                  retrain back-edge →   │
                                                  ("Train again" CTA)   │
                                                                        ▼
                                                              back to ② FINE-TUNE

       inner automated loop ("Practice"):  generate → test → train → eval, per round,
       runs ②③ on its own without the user — emits the same model+adapter artifact.

       off-loop sink ("Save & Use"):  any completed adapter → Ollama / LM Studio / GGUF.
```

The **back-edge** (③ → ②, and also ④ → ②) is the whole point: a fine-tune is rarely
good on the first pass, so the loop is built to be travelled many times. The
artifact that flows is always the same shape: a base **model** plus an optional
**adapter**.

---

## What the artifact actually is

The thing travelling the loop is captured two ways:

1. **A SwiftData record** — a [`TrainingJob`](../MLXStudio/Models/TrainingJob.swift)
   (or, for the automated inner loop, a
   [`SelfImproveRun`](../MLXStudio/Models/SelfImproveRun.swift)). Its
   `baseModelRepoID` is the model and its `adapterRelativePath` (== `id.uuidString`,
   relative to `PathResolver.adaptersDir`) locates the LoRA. So
   `adapterURL = PathResolver.adapterDir(for: jobID)` and the final weights live at
   `<adapterURL>/adapters.safetensors`. This is the durable, on-disk truth.

2. **A hand-off payload** —
   [`ModelHandoff`](../MLXStudio/Core/LoopHandoff.swift), posted as the `object` of a
   cross-tab `Notification.Name`, carries `{ model: String, adapterPath: String? }`
   from one stage's view to the next so the next tab opens **pre-filled**. This is
   the in-flight truth — the glue between stages.

```swift
struct ModelHandoff: Sendable {
    let model: String          // base model repo ID or local name
    let adapterPath: String?   // absolute path to the LoRA adapter dir, if any
}
```

Receivers accept **either** a `ModelHandoff` **or** a bare `String` (model only),
so older posters that send just a repo ID keep working — see the dual-decode in
[`ArenaView`](../MLXStudio/Features/Chat/ArenaView.swift) and
[`CodeView`](../MLXStudio/Features/Code/CodeView.swift)
(`note.object as? ModelHandoff ?? note.object as? String`).

---

## The five stages

| # | Stage | Friendly tab | Code entry point | Artifact in → out |
|---|---|---|---|---|
| ① | **Download** a model | Models | [`ModelsBrowserView`](../MLXStudio/Features/Models/ModelsBrowserView.swift) / [`ModelDetailView`](../MLXStudio/Features/Models/ModelDetailView.swift), [`HuggingFaceClient`](../MLXStudio/Services/HuggingFaceClient.swift), [`DownloadService`](../MLXStudio/Services/DownloadService.swift), [`ModelRegistry`](../MLXStudio/Services/ModelRegistry.swift) | (nothing) → a local **model** on disk |
| — | **Pick the data** | Lessons | [`DatasetsView`](../MLXStudio/Features/Datasets/DatasetsView.swift), [`DatasetService`](../MLXStudio/Services/DatasetService.swift) / [`DatasetPrepService`](../MLXStudio/Services/DatasetPrepService.swift), [`DatasetRecord`](../MLXStudio/Models/DatasetRecord.swift) | (nothing) → a chat-JSONL **dataset** (the fuel, not the artifact) |
| ② | **Fine-tune** it | Teach | [`TrainingConfigView`](../MLXStudio/Features/Training/TrainingConfigView.swift), [`AutoTuner`](../MLXStudio/Services/AutoTuner.swift), [`TrainingService`](../MLXStudio/Services/TrainingService.swift), [`TrainingJob`](../MLXStudio/Models/TrainingJob.swift) | model + dataset → **model + adapter** (`TrainingJob`) |
| — | **Watch** it learn | Progress | [`TrainingMonitorView`](../MLXStudio/Features/Monitor/TrainingMonitorView.swift), [`JobRegistry`](../MLXStudio/Services/JobRegistry.swift), [`TrainingNarrator`](../MLXStudio/Services/TrainingNarrator.swift) | the running `TrainingJob` → a **completed** one (then offers the CTAs) |
| ③ | **Test** it | Try it out | [`ArenaView`](../MLXStudio/Features/Chat/ArenaView.swift) (base vs fine-tuned side-by-side), `ChatSession`, [`InferenceService`](../MLXStudio/Services/InferenceService.swift) | model + adapter → a judgement (keep / retrain) |
| ④ | **Use** it (coding) | Code | [`CodeView`](../MLXStudio/Features/Code/CodeView.swift), [`CodingAgentService`](../MLXStudio/Services/CodingAgentService.swift), [`MLXServerService`](../MLXStudio/Services/MLXServerService.swift) | model + adapter → the loaded Orchestrator-team server |
| ⑤ | **Iterate** (the back-edge) | back to Teach | the decision CTAs in Progress / Try-it-out → [`TrainingConfigView`](../MLXStudio/Features/Training/TrainingConfigView.swift) | model + adapter → a *new* `TrainingJob`, optionally resuming from the prior weights |

Two stages (**Lessons**, **Progress**) are marked with `—` because they aren't
distinct artifact transforms: Lessons produces the *fuel* (a dataset) and Progress
*observes* the ② transform in flight. They're real tabs, just not their own loop
nodes.

---

## The edges — how the artifact moves between stages

Every transition is a **user-driven CTA** (a button), not auto-navigation. Each
fires a `Notification.Name` whose `object` is a `ModelHandoff` (or a `SidebarSection`
for a plain tab switch). The receivers are wired in
[`RootView`](../MLXStudio/App/RootView.swift) (which selects the tab) and in the
destination view (which pre-fills its fields).

| Edge | Where the CTA lives | Mechanism (notification → object) | Effect at the destination |
|---|---|---|---|
| ① → ② (download → teach) | "Train for coding" on each local-model row, [`ModelsBrowserView`](../MLXStudio/Features/Models/ModelsBrowserView.swift) / [`ModelDetailView`](../MLXStudio/Features/Models/ModelDetailView.swift) | `.openTrainingWithModel` → `String` (repoID) | Teach pre-fills `selectedModelRepoID` |
| ② → Progress | "Start Teaching", [`TrainingConfigView.launch()`](../MLXStudio/Features/Training/TrainingConfigView.swift) | `.switchToMonitor` → (no payload) | switches to the Progress tab |
| Progress → ③ | **completion CTA card** ("Try it out"), [`TrainingMonitorView`](../MLXStudio/Features/Monitor/TrainingMonitorView.swift) | `.openChatWithModel` → `ModelHandoff` | Arena pre-fills **model + adapter**, enables compare |
| Progress → ④ | **completion CTA card** ("Use in Code") | `.openCodeWithModel` → `ModelHandoff` | Code selects the tab + the adapter, loads the server |
| Progress → Save & Use | **completion CTA card** ("Save & Use") | `.switchSidebar` → `SidebarSection.export` | switches to the Export tab |
| ③ → ② (test → retrain) | **decision bar** "Train again", [`ArenaView`](../MLXStudio/Features/Chat/ArenaView.swift) | `.openTrainingWithModel` → `String` | Teach pre-fills the model (the back-edge) |
| ③ → ④ | **decision bar** "Use in Code" | `.openCodeWithModel` → `ModelHandoff` | Code loads model + adapter |
| ③ → Save & Use | **decision bar** "Save & Use" | `.switchSidebar` → `SidebarSection.export` | switches to the Export tab |
| Practice → ③ / ④ | **"Use this fine-tune" menu** per completed run, [`SelfImproveView`](../MLXStudio/Features/SelfImprove/SelfImproveView.swift) | `.openChatWithModel` / `.openCodeWithModel` → `ModelHandoff` | Arena / Code pre-fill model + adapter |

`.openCodeWithModel` and the `ModelHandoff` payload are new — they're what closed
the loop's two previously-broken seams (see *History* below). The full
notification contract is in
[`CONTRACTS.md`](CONTRACTS.md#8-notificationname-extensions-cross-tab-events).

---

## The inner automated loop — Practice

The **Practice** tab ([`SelfImproveView`](../MLXStudio/Features/SelfImprove/SelfImproveView.swift)
/ [`SelfImproveService`](../MLXStudio/Services/SelfImproveService.swift) /
[`SelfImproveRun`](../MLXStudio/Models/SelfImproveRun.swift)) is the **same loop,
automated and tightened into a single Task**. Each round does, on its own:

```
generate candidates → run real unit tests → train on the passers → eval pass@1
```

That's stages ② (fine-tune) and ③ (test) run by the machine instead of the user,
once per round, with the round-N adapter feeding round N+1's generation. It emits
the *same* artifact shape — a model + a LoRA adapter under
`adapters/<round-job-uuid>/` — so a finished Practice run drops straight back onto
the outer loop: its **"Use this fine-tune" menu** posts a `ModelHandoff` to Try-it-out
or Code, exactly like a Teach job. (Rationale for the rejection-sampling design is
in [`CONVENTIONS.md`](CONVENTIONS.md#self-improvement-loop-the-practice-tab); the
per-event trace is [`WORKFLOWS.md §11`](WORKFLOWS.md).)

---

## Where Save & Use sits

**Save & Use** ([`ExportWizardView`](../MLXStudio/Features/Export/ExportWizardView.swift)
/ [`FuseService`](../MLXStudio/Services/FuseService.swift)) is **off the loop** — it's
the *exit*. Once the user is happy with a fine-tune, this stage takes the artifact
out of the loop and into the wider world (Ollama / LM Studio / GGUF). It accepts an
`ExportSource` value that wraps **either** a completed `TrainingJob` **or** a
completed `SelfImproveRun`, so adapters from both the outer loop (Teach) and the
inner loop (Practice) are exportable through the same panel. Note there is
deliberately **no `.exportCompleted` notification** — export is a terminal sink, so
a "back to the loop" hand-off from it would be dead code.

---

## If you add a stage — preserve the loop

The loop only stays a loop if new stages plug into the same artifact plumbing.
When you add or change a stage:

1. **Carry the artifact, don't re-derive it.** Move a model (+adapter) between tabs
   with [`ModelHandoff`](../MLXStudio/Core/LoopHandoff.swift) posted as a
   notification `object` — never a shared global, never asking the user to re-type a
   path. If your new receiver might also be targeted by an old `String`-only poster,
   accept both (`as? ModelHandoff ?? as? String`).
2. **Make the transition a user-driven CTA.** A stage completing must **not**
   auto-switch tabs — the user clicks the CTA. (This protects the
   "window-close ≠ quit, training survives in the background" ethos: yanking the
   user to another tab when a 30-minute fine-tune finishes would fight that.)
3. **Wire the tab switch in [`RootView`](../MLXStudio/App/RootView.swift)** and the
   field pre-fill in the destination view's `.onReceive`.
4. **Keep the on-disk shape.** A new stage that produces a fine-tune should write a
   `TrainingJob`-shaped adapter under `adapters/<uuid>/` so it shows up in Try-it-out
   and Save & Use with no special-casing (this is exactly why Practice's per-round
   adapters live under `adapters/`, not `selfimprove/`).
5. **Document the new edge** in the tables above and in
   [`CONTRACTS.md`](CONTRACTS.md#8-notificationname-extensions-cross-tab-events).

The anti-pattern to avoid: building a tab that produces or consumes a model but
leaves the user to copy a disk path between tabs by hand. That's a *sibling tool*,
not a loop stage — and it's exactly the seam the loop-wiring session (below) was
created to close.

---

## History — how the loop got wired shut

The loop was always physically complete in the **backend** (every stage could
produce and consume the artifact on disk) but was **broken at the UI seams**: the
user had to copy adapter paths between tabs by hand, and the **Code tab literally
could not load a fine-tuned adapter** (`startSession` passed `adapterPath: nil`). A
feedback-loop audit found these gaps and a follow-up session wired them via
[`ModelHandoff`](../MLXStudio/Core/LoopHandoff.swift) + completion CTAs across
Code / Progress / Try-it-out / Teach / Practice / Export:

- **④ now works**: [`CodeView`](../MLXStudio/Features/Code/CodeView.swift) gained an
  adapter picker (persisted via `@AppStorage("codeAdapterJobID")`) and threads the
  adapter into `CodingAgentService.startSession(model:adapterPath:)` →
  `mlx_lm server --adapter-path`.
- **Progress → next** : a completion CTA card in
  [`TrainingMonitorView`](../MLXStudio/Features/Monitor/TrainingMonitorView.swift).
- **③ now hands off + decides**:
  [`ArenaView`](../MLXStudio/Features/Chat/ArenaView.swift) accepts a `ModelHandoff`
  and gained the "Train again / Use in Code / Save & Use" decision bar (the
  back-edge).
- **⑤ refine-in-place**:
  [`TrainingConfigView`](../MLXStudio/Features/Training/TrainingConfigView.swift)'s
  "Continue a previous fine-tune?" picker reuses the source job's config and
  resumes from its weights via `TrainingService.start(…, resumeAdapterFile:)`.
- **Practice un-siloed**: the "Use this fine-tune" menu + `ExportSource` make
  Practice adapters first-class loop citizens.

See [`STATE.md`](STATE.md) for the session log entry and the smoke-test status.
