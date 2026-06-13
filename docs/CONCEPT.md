# The core concept — LLMPro is one feedback loop

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

LLMPro takes **one artifact** — a base **model**, and after fine-tuning its
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
        (repo ID)          (TrainingJob)        │  (+ a pass@k EvalRun)
                                                │ ⑤ "did the score go up?"
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

1. **A SwiftData record** — a [`TrainingJob`](../LLMPro/Models/TrainingJob.swift)
   (or, for the automated inner loop, a
   [`SelfImproveRun`](../LLMPro/Models/SelfImproveRun.swift)). Its
   `baseModelRepoID` is the model and its `adapterRelativePath` (== `id.uuidString`,
   relative to `PathResolver.adaptersDir`) locates the LoRA. So
   `adapterURL = PathResolver.adapterDir(for: jobID)` and the final weights live at
   `<adapterURL>/adapters.safetensors`. This is the durable, on-disk truth.

2. **A hand-off payload** —
   [`ModelHandoff`](../LLMPro/Core/LoopHandoff.swift), posted as the `object` of a
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
[`ArenaView`](../LLMPro/Features/Chat/ArenaView.swift) and
[`CodeView`](../LLMPro/Features/Code/CodeView.swift)
(`note.object as? ModelHandoff ?? note.object as? String`).

---

## The five stages

| # | Stage | Friendly tab | Code entry point | Artifact in → out |
|---|---|---|---|---|
| ① | **Download** a model | Models | [`ModelsBrowserView`](../LLMPro/Features/Models/ModelsBrowserView.swift) / [`ModelDetailView`](../LLMPro/Features/Models/ModelDetailView.swift), [`HuggingFaceClient`](../LLMPro/Services/HuggingFaceClient.swift), [`DownloadService`](../LLMPro/Services/DownloadService.swift), [`ModelRegistry`](../LLMPro/Services/ModelRegistry.swift) | (nothing) → a local **model** on disk |
| — | **Pick the data** | Lessons | [`DatasetsView`](../LLMPro/Features/Datasets/DatasetsView.swift), [`DatasetService`](../LLMPro/Services/DatasetService.swift) / [`DatasetPrepService`](../LLMPro/Services/DatasetPrepService.swift), [`DatasetRecord`](../LLMPro/Models/DatasetRecord.swift) | (nothing) → a chat-JSONL **dataset** (the fuel, not the artifact) |
| ② | **Fine-tune** it | Teach | [`TrainingConfigView`](../LLMPro/Features/Training/TrainingConfigView.swift), [`AutoTuner`](../LLMPro/Services/AutoTuner.swift), [`TrainingService`](../LLMPro/Services/TrainingService.swift), [`TrainingJob`](../LLMPro/Models/TrainingJob.swift) | model + dataset → **model + adapter** (`TrainingJob`) |
| — | **Watch** it learn | Progress | [`TrainingMonitorView`](../LLMPro/Features/Monitor/TrainingMonitorView.swift), [`JobRegistry`](../LLMPro/Services/JobRegistry.swift), [`TrainingNarrator`](../LLMPro/Services/TrainingNarrator.swift) | the running `TrainingJob` → a **completed** one (then offers the CTAs) |
| ③ | **Test** it | Try it out | [`ArenaView`](../LLMPro/Features/Chat/ArenaView.swift) (base vs fine-tuned side-by-side), `ChatSession`, [`InferenceService`](../LLMPro/Services/InferenceService.swift); **"Score it"** → [`EvalService`](../LLMPro/Services/EvalService.swift) → an [`EvalRun`](../LLMPro/Models/EvalRun.swift) | model + adapter → a **tracked pass@k score** (an `EvalRun`) + a subjective read → keep / retrain |
| ④ | **Use** it (coding) | Code | [`CodeView`](../LLMPro/Features/Code/CodeView.swift), [`CodingAgentService`](../LLMPro/Services/CodingAgentService.swift), [`MLXServerService`](../LLMPro/Services/MLXServerService.swift) | model + adapter → the loaded Orchestrator-team server |
| ⑤ | **Iterate** (the back-edge) | back to Teach | the decision CTAs in Progress / Try-it-out → [`TrainingConfigView`](../LLMPro/Features/Training/TrainingConfigView.swift) | model + adapter → a *new* `TrainingJob`, optionally resuming from the prior weights |

Two stages (**Lessons**, **Progress**) are marked with `—` because they aren't
distinct artifact transforms: Lessons produces the *fuel* (a dataset) and Progress
*observes* the ② transform in flight. They're real tabs, just not their own loop
nodes.

### Inference-only "guest" models (DiffusionGemma) — on ③ Test, off the fine-tune loop

Not every model can travel the *whole* loop. Google's **DiffusionGemma**
(`model_type: diffusion_gemma`) is a **masked / block-diffusion** LM — it decodes by
iteratively unmasking a fixed canvas, not autoregressively — so mlx-lm's
`generate`/`server` can't run it and mlx-lm LoRA/AutoTuner **can't fine-tune** it. In
LLMPro it is therefore an **inference-only "guest"**: it plugs into **① Download**
(it's a normal HF model on disk) and **③ Test** ("Try it out" routes it to the
vendored `diffusion_generate.py` decoder instead of `mlx_lm generate`), but it is
**deliberately excluded from ② Teach, the Practice inner loop, and the DPO preference
back-edge** — there is no fine-tune transform a diffusion model can undergo here. The
Models tab flags it with a "Diffusion · chat only" badge, and the Teach/Practice model
pickers omit it (via `ModelRegistry.DetectedModel.isDiffusion`).

This **does not bend the loop** — it's the honest shape of the artifact. A guest model
joins the loop only at the nodes it can support (download + test/chat); the loop's
spine (download → teach → test → use → retrain) is for fine-tunable models and is
unchanged. The decision to make it inference-only (rather than fake a fine-tune path)
is recorded in [`CONVENTIONS.md`](CONVENTIONS.md#diffusiongemma-is-an-inference-only-guest-model); the inference
contract is in [`CONTRACTS.md`](CONTRACTS.md#diffusion_generatepy--diffusiongemma-inference-non-mlx-lm).

### ③ Test now emits a tracked score (the back-edge is score-delta-driven)

The Test node used to produce only a *subjective* read (eyeball the two panes). It
now also produces a **quantitative, tracked score**: the **"Score it"** action runs
the eval engine ([`EvalService`](../LLMPro/Services/EvalService.swift) →
[`eval_pass_rate.py`](../LLMPro/Resources/helpers/eval_pass_rate.py)) over a coding
suite (HumanEval / MBPP) and writes a **pass@k** result into an
[`EvalRun`](../LLMPro/Models/EvalRun.swift), keyed by `(base model + adapter)` so it
is **comparable across retrains** (a base model is the empty-adapter case; Practice
adapters score too). This sharpens the ⑤ back-edge decision from "does it *feel*
better?" to a concrete **"did pass@k go up vs the previous fine-tune of the same
base?"** — the report card and the decision bar both surface that delta, and
Progress's **"Grade it"** CTA lands a fresh fine-tune in the Test node and scores it
immediately (`ModelHandoff.autoScore`).

Per the **"don't bolt on a sibling tool"** rule below, the score **grew the existing
Test node** — it is *not* a new "Grades" tab. The Test node already owns the
artifact hand-off and the back-edge decision, so the score lives where the keep/
retrain choice is made. (It reuses Practice's eval engine + sandbox rather than the
Code tab's persistent server — see
[`CONVENTIONS.md`](CONVENTIONS.md#the-scored-test-node-evalservice--evalrun).)

### The preference back-edge (the Arena also produces fuel)

The Test node (③) now has a **second** back-edge to ② alongside "Train again": the
**DPO preference loop**. While comparing the two panes, the user marks **which answer
is better** (a 👍 "Which answer is better?" capture row, separate from the "Score it"
report card). Each judgment becomes a **preference pair** —
`{prompt, chosen, rejected}` — accumulated into a `.preference`
[`DatasetRecord`](../LLMPro/Models/DatasetRecord.swift) by
[`PreferenceService`](../LLMPro/Services/PreferenceService.swift). At ≥4 pairs, a
**"Teach by preference →"** CTA hands them to Teach (a `PreferenceHandoff`), which
runs a **DPO fine-tune** ([`AutoTuner.tuneDPO`](../LLMPro/Services/AutoTuner.swift) +
`mlx_lm_lora.train`, see [`CONTRACTS.md`](CONTRACTS.md#mlx_lm_loratrain--dpo-preference-training-separate-package))
and emits **a normal LoRA adapter** under `adapters/<uuid>/`.

So testing now yields **two kinds of output**: the loop's familiar **artifact** (a
model + adapter to keep/retrain) *and* **fuel** (a preference set that drives the next
fine-tune) — the same way Lessons produces the dataset-fuel for an ordinary SFT run.
Crucially this **stayed inside the existing Test → Teach loop** — it is **not a new
tab**. The artifact discipline is unchanged: the DPO adapter is `TrainingJob`-shaped,
lands under `adapters/`, and travels the rest of the loop (Progress / Try-it-out /
Save & Use) through the **same user-driven CTAs** — completion never auto-switches
tabs. (Rejection-sampling Practice uses an *automated* unit-test judge; this loop uses
the *human's* preference as the signal — see
[`CONVENTIONS.md`](CONVENTIONS.md#dpo-preference-loop-via-on-demand-mlx-lm-lora).)

---

## The edges — how the artifact moves between stages

Every transition is a **user-driven CTA** (a button), not auto-navigation. Each
fires a `Notification.Name` whose `object` is a `ModelHandoff` (or a `SidebarSection`
for a plain tab switch). The receivers are wired in
[`RootView`](../LLMPro/App/RootView.swift) (which selects the tab) and in the
destination view (which pre-fills its fields).

| Edge | Where the CTA lives | Mechanism (notification → object) | Effect at the destination |
|---|---|---|---|
| ① → ② (download → teach) | "Train for coding" on each local-model row, [`ModelsBrowserView`](../LLMPro/Features/Models/ModelsBrowserView.swift) / [`ModelDetailView`](../LLMPro/Features/Models/ModelDetailView.swift) | `.openTrainingWithModel` → `String` (repoID) | Teach pre-fills `selectedModelRepoID` |
| ② → Progress | "Start Teaching", [`TrainingConfigView.launch()`](../LLMPro/Features/Training/TrainingConfigView.swift) | `.switchToMonitor` → (no payload) | switches to the Progress tab |
| Progress → ③ | **completion CTA card** ("Try it out"), [`TrainingMonitorView`](../LLMPro/Features/Monitor/TrainingMonitorView.swift) | `.openChatWithModel` → `ModelHandoff` | Arena pre-fills **model + adapter**, enables compare |
| Progress → ③ (auto-score) | **completion CTA card** ("Grade it") | `.openChatWithModel` → `ModelHandoff{autoScore: true}` | Arena pre-fills model + adapter **and auto-runs "Score it"** (writes an `EvalRun`) |
| Progress → ④ | **completion CTA card** ("Use in Code") | `.openCodeWithModel` → `ModelHandoff` | Code selects the tab + the adapter, loads the server |
| Progress → Save & Use | **completion CTA card** ("Save & Use") | `.switchSidebar` → `SidebarSection.export` | switches to the Export tab |
| ③ → ② (test → retrain) | **decision bar** "Train again", [`ArenaView`](../LLMPro/Features/Chat/ArenaView.swift) | `.openTrainingWithModel` → `String` | Teach pre-fills the model (the back-edge) |
| ③ → ② (preference back-edge) | **"Teach by preference →"** (≥4 👍 captures), [`ArenaView`](../LLMPro/Features/Chat/ArenaView.swift) | `.openTrainingWithPreferences` → `PreferenceHandoff` | Teach pre-fills model + the `.preference` dataset, switches to **DPO mode** |
| ③ → ④ | **decision bar** "Use in Code" | `.openCodeWithModel` → `ModelHandoff` | Code loads model + adapter |
| ③ → Save & Use | **decision bar** "Save & Use" | `.switchSidebar` → `SidebarSection.export` | switches to the Export tab |
| Practice → ③ / ④ | **"Use this fine-tune" menu** per completed run, [`SelfImproveView`](../LLMPro/Features/SelfImprove/SelfImproveView.swift) | `.openChatWithModel` / `.openCodeWithModel` → `ModelHandoff` | Arena / Code pre-fill model + adapter |

`.openCodeWithModel` and the `ModelHandoff` payload are new — they're what closed
the loop's two previously-broken seams (see *History* below). The full
notification contract is in
[`CONTRACTS.md`](CONTRACTS.md#8-notificationname-extensions-cross-tab-events).

---

## The inner automated loop — Practice

The **Practice** tab ([`SelfImproveView`](../LLMPro/Features/SelfImprove/SelfImproveView.swift)
/ [`SelfImproveService`](../LLMPro/Services/SelfImproveService.swift) /
[`SelfImproveRun`](../LLMPro/Models/SelfImproveRun.swift)) is the **same loop,
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

**Save & Use** ([`ExportWizardView`](../LLMPro/Features/Export/ExportWizardView.swift)
/ [`FuseService`](../LLMPro/Services/FuseService.swift)) is **off the loop** — it's
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
   with [`ModelHandoff`](../LLMPro/Core/LoopHandoff.swift) posted as a
   notification `object` — never a shared global, never asking the user to re-type a
   path. If your new receiver might also be targeted by an old `String`-only poster,
   accept both (`as? ModelHandoff ?? as? String`).
2. **Make the transition a user-driven CTA.** A stage completing must **not**
   auto-switch tabs — the user clicks the CTA. (This protects the
   "window-close ≠ quit, training survives in the background" ethos: yanking the
   user to another tab when a 30-minute fine-tune finishes would fight that.)
3. **Wire the tab switch in [`RootView`](../LLMPro/App/RootView.swift)** and the
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
[`ModelHandoff`](../LLMPro/Core/LoopHandoff.swift) + completion CTAs across
Code / Progress / Try-it-out / Teach / Practice / Export:

- **④ now works**: [`CodeView`](../LLMPro/Features/Code/CodeView.swift) gained an
  adapter picker (persisted via `@AppStorage("codeAdapterJobID")`) and threads the
  adapter into `CodingAgentService.startSession(model:adapterPath:)` →
  `mlx_lm server --adapter-path`.
- **Progress → next** : a completion CTA card in
  [`TrainingMonitorView`](../LLMPro/Features/Monitor/TrainingMonitorView.swift).
- **③ now hands off + decides**:
  [`ArenaView`](../LLMPro/Features/Chat/ArenaView.swift) accepts a `ModelHandoff`
  and gained the "Train again / Use in Code / Save & Use" decision bar (the
  back-edge).
- **⑤ refine-in-place**:
  [`TrainingConfigView`](../LLMPro/Features/Training/TrainingConfigView.swift)'s
  "Continue a previous fine-tune?" picker reuses the source job's config and
  resumes from its weights via `TrainingService.start(…, resumeAdapterFile:)`.
- **Practice un-siloed**: the "Use this fine-tune" menu + `ExportSource` make
  Practice adapters first-class loop citizens.

See [`STATE.md`](STATE.md) for the session log entry and the smoke-test status.
