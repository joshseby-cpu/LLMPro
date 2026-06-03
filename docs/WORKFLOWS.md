# Workflows

> 📝 **Maintainers**: when you change a user-facing flow (add a button, change a
> click → effect chain, alter the order of operations in a service), update the
> trace below in the same session. If you add a new flow, add a new numbered
> section. See the [doc-maintenance contract](../CLAUDE.md#%EF%B8%8F-documentation-is-part-of-the-work--read-this-section-twice).

End-to-end traces of every user action through the codebase. Read after
[`ARCHITECTURE.md`](ARCHITECTURE.md). Use this to understand what touches what,
and to know which code paths an agent must not break when changing one feature.

---

## 0. App launch + first run

```
LLMProApp.body
  → WindowGroup contains RootView()
    → @AppStorage("firstRunComplete")
      false → FirstRunView (5-step TabView)
        step 2 (Python runtime) → PythonRuntime.shared.bootstrap()
          1. PythonRuntime.resolveUV()  (bundled / app-support / PATH)
          2. uv venv /Library/.../runtime/.venv --python 3.11
          3. uv pip install mlx-lm huggingface_hub datasets safetensors sentencepiece protobuf
          4. installHelpers()  ← copies all .py from Bundle to runtime/helpers/
          5. verifyMLXLM()  ← runs `import mlx_lm` in the venv
        step 4 (starter models) → DownloadService.download(repoID:) for each selected
        step 5 (done) → onComplete sets firstRunComplete=true
      true → RootView NavigationSplitView shell
    
On *every* launch (independent of first run):
  - PythonRuntime.shared.bootstrapIfNeeded()
    if venv exists AND verifyMLXLM() passes:
      installHelpers()  ← ALWAYS, so bundle changes propagate
      phase = .ready
    else:
      full bootstrap()
  - JobRegistry.shared.recoverOrphans()
    scans adapters/*/job.json
    PID alive → reattach (status=running, tail log file)
    PID dead + checkpoint → mark .orphaned, offer Resume
```

**Files involved**: [`LLMProApp.swift`](../LLMPro/App/LLMProApp.swift),
[`FirstRunView.swift`](../LLMPro/Features/Settings/FirstRunView.swift),
[`PythonRuntime.swift`](../LLMPro/Services/PythonRuntime.swift),
[`JobRegistry.swift`](../LLMPro/Services/JobRegistry.swift).

---

## 0b. The feedback loop, end-to-end (the through-line)

The individual flows below (§1–§13) are the **stages of one closed loop** — a base
**model**, and after fine-tuning its **LoRA adapter**, travels *download → fine-tune
→ test → use → (retrain)*. This trace stitches them together via the **cross-tab
CTAs** that hand the artifact forward so the user never copies a disk path by hand.
The conceptual model is in [`CONCEPT.md`](CONCEPT.md); each transition's mechanism is
a `Notification.Name` carrying a [`ModelHandoff`](../LLMPro/Core/LoopHandoff.swift)
`{model, adapterPath?}` (received in [`RootView`](../LLMPro/App/RootView.swift) +
the destination view).

```
① DOWNLOAD (Models, §1)
   model on disk
   └─ local-model row "Train for coding" → .openTrainingWithModel(String) ─┐
                                                                            ▼
② FINE-TUNE (Teach, §5)  —— + pick data (Lessons, §2/§3/§4) ——
   user picks model + dataset + duration → "Start Teaching"
   AutoTuner picks every hyperparameter; TrainingService spawns mlx_lm lora
   └─ .switchToMonitor ─┐
                        ▼
   WATCH (Progress, §5)
   TrainingMonitorView narrates phases + stars; on job.status == .completed it
   shows the COMPLETION CTA CARD:
     • "Try it out"  → .openChatWithModel(ModelHandoff{model, adapterURL})
     • "Use in Code" → .openCodeWithModel(ModelHandoff)
     • "Save & Use"  → .switchSidebar(.export)
        │
        ▼ (user clicks "Try it out")
③ TEST (Try it out, §6)
   ArenaView .openChatWithModel receiver pre-fills BOTH model + adapter, enables
   compare (base vs fine-tune). Once an adapter is loaded, the DECISION BAR appears:
     • "Train again"  → .openTrainingWithModel(String)  ── back-edge to ② ──┐
     • "Use in Code"  → .openCodeWithModel(ModelHandoff)                    │
     • "Save & Use"   → .switchSidebar(.export)                            (loop again)
        │
        ▼ (good enough, and it's a coding model → "Use in Code")
④ USE (Code, §13)
   CodeView's adapter Picker (or the .openCodeWithModel hand-off) selects a
   completed job's adapter; startSession threads it into
   CodingAgentService.startSession(model:adapterPath:) → mlx_lm server --adapter-path.
   The fine-tuned coder runs the Orchestrator team.

⑤ ITERATE — two ways back to ②:
   • manual:    Teach's "Continue a previous fine-tune?" picker → launchRefine(from:)
                reuses the source config + TrainingService.start(…, resumeAdapterFile:)
                (→ mlx_lm --resume-adapter-file)
   • automated: Practice (§11) runs generate→test→train→eval per round on its own,
                then its "Use this fine-tune" menu posts a ModelHandoff back to ③/④.

EXIT — Save & Use (§7): ExportWizardView's ExportSource wraps a TrainingJob OR a
   completed SelfImproveRun → Ollama / LM Studio / GGUF. Terminal sink (no
   .exportCompleted notification — nothing observes the loop's exit).
```

**The new CTAs (all user-driven — completion never auto-navigates):**
- **Completion card** — [`TrainingMonitorView`](../LLMPro/Features/Monitor/TrainingMonitorView.swift)
  when `job.status == .completed`.
- **Arena decision bar** — [`ArenaView`](../LLMPro/Features/Chat/ArenaView.swift)
  once an adapter is loaded.
- **Practice "Use this fine-tune" menu** — per completed run in
  [`SelfImproveView`](../LLMPro/Features/SelfImprove/SelfImproveView.swift).
- **Teach "Continue a previous fine-tune?"** picker —
  [`TrainingConfigView`](../LLMPro/Features/Training/TrainingConfigView.swift).

**Files involved**: [`LoopHandoff.swift`](../LLMPro/Core/LoopHandoff.swift),
[`RootView.swift`](../LLMPro/App/RootView.swift),
[`TrainingMonitorView.swift`](../LLMPro/Features/Monitor/TrainingMonitorView.swift),
[`ArenaView.swift`](../LLMPro/Features/Chat/ArenaView.swift),
[`CodeView.swift`](../LLMPro/Features/Code/CodeView.swift),
[`TrainingConfigView.swift`](../LLMPro/Features/Training/TrainingConfigView.swift),
[`SelfImproveView.swift`](../LLMPro/Features/SelfImprove/SelfImproveView.swift),
[`ExportWizardView.swift`](../LLMPro/Features/Export/ExportWizardView.swift),
[`TrainingService.swift`](../LLMPro/Services/TrainingService.swift).

---

## 1. Download a model from HuggingFace

```
ModelsBrowserView search field → search() → HuggingFaceClient.shared.search(query, mlxOnly)
  → URLSession GET https://huggingface.co/api/models?search=...&author=mlx-community
  → results: [HFModel] rendered as ModelResultRow list

user clicks a result → selected = HFModel
  → ModelDetailView pane appears
    .task(id: model.id) → HuggingFaceClient.detail + resolveTotalSize

user clicks Download (the ⬇ icon at bottom of detail pane)
  → DownloadService.shared.download(repoID:)
    1. spawn `python <runtime>/helpers/hf_download.py <repoID> <HF_HOME> <token>`
    2. helper emits JSON events on stdout (line by line):
       {"event": "start",     "repo": "...", "total_bytes": N}
       {"event": "progress",  "downloaded": N, "total": N, "percent": F, "file": "..."}
       {"event": "done",      "path": "..."}
    3. DownloadService.handle(line:) parses each line, updates the active row
    4. on process exit, cleanup block moves the row from active → history
       (the bug fixed in DOWNLOAD-PROGRESS-FIX: don't set entry.done = true in handle())
    5. ModelRegistry.shared.scan() is triggered → local list refreshes

Disk layout after download:
  ~/Library/Application Support/LLMPro/hf/models--owner--repo/
    snapshots/<rev>/        ← symlinks
      config.json
      tokenizer.json
      model.safetensors.index.json
      ...
    blobs/                  ← real files
      <sha-256>             ← weight shards
      <sha-256>.incomplete  ← in-flight chunks (xet protocol)

Note: when mlx_lm.lora later loads the model with HF_HOME=hf/, it creates a
SECOND copy under hf/hub/models--owner--repo/ (standard hub layout).
ModelRegistry.scan() walks both.
```

**Files involved**: [`ModelsBrowserView.swift`](../LLMPro/Features/Models/ModelsBrowserView.swift),
[`ModelDetailView.swift`](../LLMPro/Features/Models/ModelDetailView.swift),
[`HuggingFaceClient.swift`](../LLMPro/Services/HuggingFaceClient.swift),
[`DownloadService.swift`](../LLMPro/Services/DownloadService.swift),
[`ModelRegistry.swift`](../LLMPro/Services/ModelRegistry.swift),
[`hf_download.py`](../LLMPro/Resources/helpers/hf_download.py).

---

## 2. Prepare a curated coding dataset

```
DatasetsView → Coding-instruction datasets section
  CodingDatasetCatalog.all → ForEach renders 5 cards

user adjusts the sample-size stepper (per-preset state in @State maxRowsByPreset)
user clicks "Prepare"
  → DatasetPrepService.shared.prepare(preset:, maxRows:, onComplete:)
    1. spawn `python helpers/prepare_coding_dataset.py <preset.id> <datasetDir> "" <maxRows>`
    2. helper loads from HF via datasets.load_dataset(preset.hfRepo, split="train")
    3. iterates rows, applies preset-specific splitter (Alpaca/Magicoder/etc.)
       → [{"role":"user","content":...},{"role":"assistant","content":...}]
    4. 90/5/5 deterministic split → writes train/valid/test.jsonl
    5. emits {"event":"done", "train": N, "valid": N, "test": N, "schema": "chat"}
  → DatasetPrepService cleanup: moves entry to history with resultDatasetID

DatasetsView.onChange(of: prep.history.count) { registerCompletedPreps() }
  → walks prep.history, for each completed entry not yet in SwiftData:
    creates DatasetRecord(id: entry.resultDatasetID!, ...) → modelContext.insert
```

**Files involved**: [`DatasetsView.swift`](../LLMPro/Features/Datasets/DatasetsView.swift),
[`DatasetPrepService.swift`](../LLMPro/Services/DatasetPrepService.swift),
[`CodingDatasetCatalog.swift`](../LLMPro/Services/CodingDatasetCatalog.swift),
[`prepare_coding_dataset.py`](../LLMPro/Resources/helpers/prepare_coding_dataset.py).

---

## 3. Browse + download an arbitrary HF dataset

```
DatasetsView → toolbar Search HuggingFace OR "Browse HuggingFace for any dataset" card
  → showingHFSearch = true → sheet(HuggingFaceDatasetSearchView)

inside the sheet:
  Search bar submits → HuggingFaceClient.shared.searchDatasets(query)
    → URLSession GET /api/datasets?search=...&sort=downloads
    → results: [HFDataset]

user picks a result → selected = HFDataset
  → .task(id:) fetches:
    - HuggingFaceClient.datasetDetail(repoID)
    - HuggingFaceClient.datasetFirstRows(repoID, config="default", split="train", length=5)
      ↑ uses public datasets-server.huggingface.co/rows endpoint
  → preview pane shows column names + truncated sample row content

user picks schema (auto / messages / sharegpt / instruction_output / etc.)
  if non-auto: column-mapping TextFields appear, user can rename fields

user clicks "Download & Prepare"
  → DatasetPrepService.prepareArbitrary(request: ArbitraryHFRequest)
    1. JSONSerialize options: {config, split, max_rows, schema, fields: {...}}
    2. spawn `python helpers/download_hf_dataset.py <repoID> <outDir> <optionsJSON>`
    3. helper: datasets.load_dataset(repoID, config, split)
       → detect_schema(first_row) OR use requested schema
       → normalize_row(row, schema, fields) for each row
       → 90/5/5 split, write chat-shape JSONL
    4. same done/error events as #2
  → dismiss() the sheet; DatasetsView's onChange registers the new dataset
```

**Files involved**: [`HuggingFaceDatasetSearchView.swift`](../LLMPro/Features/Datasets/HuggingFaceDatasetSearchView.swift),
[`HuggingFaceClient.swift`](../LLMPro/Services/HuggingFaceClient.swift),
[`DatasetPrepService.swift`](../LLMPro/Services/DatasetPrepService.swift),
[`download_hf_dataset.py`](../LLMPro/Resources/helpers/download_hf_dataset.py).

---

## 4. Create / edit a dataset manually (CRUD)

```
Create blank:
  DatasetsView toolbar "+ New blank"
    → createBlankDataset()
      1. id = UUID()
      2. PathResolver.datasetDir(for: id) → creates the dir
      3. DatasetEditorService.createEmpty(at: dir) → writes empty train/valid/test.jsonl
      4. modelContext.insert(DatasetRecord(id, name="New dataset", schema=.chat, ...))
      5. editingDataset = record → sheet(DatasetDetailView) opens

Edit existing row:
  DatasetsView row tap (or context-menu "Edit rows…") → editingDataset = ds
  DatasetDetailView .task(id: split) → loadCurrent()
    → DatasetEditorService.load(directory, split)
      reads <dir>/train.jsonl line-by-line
      auto-promotes legacy schemas (instruction_output → chat, etc.)
      returns [ChatRow]
  user clicks a row → editingRow = rows[idx] → sheet(DatasetRowEditorView)
  user edits messages, clicks Add/Save → applyRowEdit(original, updated)
    1. filter empty messages
    2. replace at idx OR append (if isNewRow)
    3. dirty = true
    4. Task { await save() }   ← AUTO-SAVE
  save():
    1. DatasetEditorService.save(rows, to: dir, split)
       → encode + write to <split>.jsonl.tmp
       → FileManager.replaceItemAt(file, withItemAt: tmp)   ← atomic
    2. update DatasetRecord.trainRows / validRows / testRows
    3. dirty = false
    4. modelContext.save()

Delete row: swipe / context-menu → deleteRow(at:) → save()
Duplicate row: context-menu → duplicateRow(at:) → save()
Rename dataset: name field bound via @Bindable; onChange → modelContext.save()
Delete dataset: confirmDeleteDataset alert → deleteDataset()
  → FileManager.removeItem(at: dir) → modelContext.delete(ds) → save() → dismiss()
```

**Files involved**: [`DatasetsView.swift`](../LLMPro/Features/Datasets/DatasetsView.swift),
[`DatasetDetailView.swift`](../LLMPro/Features/Datasets/DatasetDetailView.swift),
[`DatasetRowEditorView.swift`](../LLMPro/Features/Datasets/DatasetRowEditorView.swift),
[`DatasetEditorService.swift`](../LLMPro/Services/DatasetEditorService.swift).

---

## 5. Run a training job (the central workflow)

```
TrainingConfigView (Teach tab):

1. Pick model card → selectedModelRepoID = model.repoID
2. Pick dataset card → selectedDatasetID = ds.id
3. Pick duration → duration = .quick | .standard | .thorough
4. (Live preview) AutoTuner.tune(...) recomputes time + iters labels

user clicks "Start Teaching" → launch()
  1. Look up the dataset
  2. jobID = UUID()
  3. adapterURL = PathResolver.adapterDir(for: jobID)
  4. tuned = AutoTuner.tune(repoID: repo, dataPath: ds.dir, adapterPath: ..., duration: ...)
  5. modelArg = resolveModelArg(repo)  ← CRITICAL: turns "Qwen3.6-…-Text-Gen" into /Users/.../models/Qwen3.6-…-Text-Gen
  6. yaml = AutoTuner.renderYAML(...)
  7. job = TrainingJob(id: jobID, configYAML: yaml, ...) → modelContext.insert
  8. TrainingService.shared.start(job:, context:)
  9. NotificationCenter.post(.switchToMonitor)

TrainingService.start():
  guard PythonRuntime.shared.isReady
  Write configYAML to job.configURL
  Set job.status = .running, job.startedAt
  JobRegistry.shared.register(job)  ← in-memory LiveJob created
  job.writeSidecar()  ← writes job.json for crash recovery
  
  process = ProcessRunner.spawn(python, ["-m", "mlx_lm", "lora", "-c", configURL.path])
  job.pid = process.pid
  JobRegistry.shared.attach(job, process: process)

  Three concurrent Task { @MainActor in } blocks:
    stdout tail:
      for await line in process.stdout {
        write line to job.logURL (file)
        JobRegistry.recordLog(jobID, line)
        if step = LogStreamParser.parse(line) {
          JobRegistry.recordStep(jobID, step)
          fetchJob(id: jobID, context:).appendStep(step)
          context.save()
          job.writeSidecar()
        }
      }
    stderr tail:
      for await line in process.stderr → recordLog("[stderr] " + line)
    exit watcher:
      exit = await process.exit.value
      fetchJob(id:, context:).status = .completed or .failed
      JobRegistry.markCompleted/Failed
      context.save() + writeSidecar()

The user's view switches to Progress tab:
TrainingMonitorView:
  job = JobRegistry.activeJob ?? most recent
  phase = TrainingNarrator.phase(for: job)
    inspects job.lastStep (if any) for iter / total
    inspects job.logTail for "Loading pretrained model" / "Loading datasets" markers
    returns .openingBook / .settingUp / .learning(n, m) / .popQuiz / .finished / .failed
  stars = TrainingNarrator.stars(initial: initialLoss(job), current: currentLoss(job))
  eta = TrainingNarrator.eta(for: job) using lastStep.itersPerSec
  
  Renders:
    title card (phase emoji + headline + subtitle)
    progress card (N of M, percent, ETA)
    star rating card
    memory gauge (SystemMetrics.shared.current)
    Stop early button (running) → JobRegistry.shared.stop(jobID)
    Technical details disclosure → stat strip + 2×2 Swift Charts grid + log tail

When training finishes:
  job.status = .completed in SwiftData (persists)
  JobRegistry.LiveJob.status = .completed
  The Monitor view shows 🎉 "All done!"
  + the COMPLETION CTA CARD (the loop's hand-off to the next stage):
    "Try it out" → .openChatWithModel(ModelHandoff{model, adapterURL.path})
    "Use in Code"→ .openCodeWithModel(ModelHandoff)
    "Save & Use" → .switchSidebar(.export)
    (user-driven — completion does NOT auto-switch tabs; see §0b)
  adapter dir contains:
    config.yaml
    adapter_config.json   ← mlx-lm-generated, full param snapshot
    adapters.safetensors  ← final LoRA weights
    0000XXX_adapters.safetensors  ← periodic checkpoints
    training.log
    job.json  ← our sidecar
```

**Refine a previous fine-tune (the loop's manual retrain back-edge):** Teach also
has an optional **"Continue a previous fine-tune?" picker** over completed jobs. It
routes to `launchRefine(from: src)`, which **reuses the source job's `configYAML`**
(swapping only `adapter_path`) and passes the source's `adapters.safetensors` to
`TrainingService.shared.start(job:, context:, resumeAdapterFile:)`, which appends
mlx-lm `--resume-adapter-file` so training continues from those weights. Reusing the
exact config keeps the LoRA architecture resume-compatible.

**Files involved**:
[`TrainingConfigView.swift`](../LLMPro/Features/Training/TrainingConfigView.swift),
[`TrainingService.swift`](../LLMPro/Services/TrainingService.swift),
[`AutoTuner.swift`](../LLMPro/Services/AutoTuner.swift),
[`JobRegistry.swift`](../LLMPro/Services/JobRegistry.swift),
[`LogStreamParser.swift`](../LLMPro/Core/LogStreamParser.swift),
[`TrainingMonitorView.swift`](../LLMPro/Features/Monitor/TrainingMonitorView.swift),
[`TrainingNarrator.swift`](../LLMPro/Services/TrainingNarrator.swift),
[`SystemMetrics.swift`](../LLMPro/Services/SystemMetrics.swift),
[`ProcessRunner.swift`](../LLMPro/Core/ProcessRunner.swift),
[`TrainingJob.swift`](../LLMPro/Models/TrainingJob.swift).

---

## 6. Chat with a fine-tuned model

```
ArenaView .task / .onAppear:
  baseSession = ChatSession(model: defaultModel, adapterPath: nil, label: "Base (general)")
  adapterSession = ChatSession(model: defaultModel, adapterPath: nil, label: "Coding fine-tune")

Loop hand-off IN (.openChatWithModel receiver):
  if note.object is a ModelHandoff → pre-fill BOTH modelText + adapterText,
     turn arena compare ON (base vs the fine-tune just produced)
  else if it's a bare String → pre-fill modelText only (back-compat)

user fills in:
  - modelText (HF repo or local path)
  - adapterText (path to adapters.safetensors)
  - system prompt
  - temperature slider, max-tokens stepper
clicks Apply → both sessions update their model/adapter/params

user types prompt + Send (or Mini-eval button picks a random coding probe)
  → arenaMode: send the same prompt to BOTH sessions in parallel
  → single mode: send only to adapterSession
  
ChatSession.send(prompt):
  append ChatMessage(role: .user)
  append ChatMessage(role: .assistant, isStreaming: true)
  Task:
    stream = InferenceService.shared.stream(model:, adapterPath:, prompt: fullContext, params:)
      InferenceService spawns `python -m mlx_lm generate --model X [--adapter-path Y] ...`
      tails stdout, yields lines between the ====== output markers
    for try await line in stream:
      messages[assistant.id].text.append(line + "\n")
    set isStreaming = false

Loop decision OUT (the DECISION BAR, shown once an adapter is loaded — the
"is it good enough?" fork):
  "Train again" → .openTrainingWithModel(modelText)        # back-edge to Teach (§5)
  "Use in Code" → .openCodeWithModel(ModelHandoff{model, adapter})   # → Code (§13)
  "Save & Use"  → .switchSidebar(.export)                  # → Save & Use (§7)
```

**Files involved**: [`ArenaView.swift`](../LLMPro/Features/Chat/ArenaView.swift),
[`ChatView.swift`](../LLMPro/Features/Chat/ChatView.swift),
[`ChatModels.swift`](../LLMPro/Features/Chat/ChatModels.swift),
[`InferenceService.swift`](../LLMPro/Services/InferenceService.swift).

---

## 7. Export to Ollama (the Save & Use flow)

```
ExportWizardView:
  Job picker (left) → @Query<TrainingJob> sort by createdAt desc
  user selects a completed job → detail pane

Detail pane:
  Picker: target = .adapter | .fusedSafetensors | .gguf
  (if .gguf) Ollama tag field + chat-template picker + warning if non-Llama arch

user clicks "Run export" → run(for: job)
  exportsDir = PathResolver.exportsDir/<jobID>/
  
  .adapter:
    zipDirectory(job.adapterURL, to: exportsDir/<jobName>-adapter.zip)
      uses NSFileCoordinator.coordinate(readingItemAt:, options: .forUploading)
      which creates a temp zip, then moves it
  
  .fusedSafetensors:
    FuseService.fuse(baseModel, adapterPath, savePath: exportsDir/fused/, onProgress:)
      spawns `python -m mlx_lm fuse --model <base> --adapter-path <adapter> --save-path <out>`
  
  .gguf:
    isNativelyGGUFExportable(job) — checks if architecture is llama/mistral/mixtral
      yes: FuseService.fuseToGGUF(...)  → mlx_lm fuse --export-gguf
      no:  FuseService.fuseAndConvertExternalGGUF(...)
           → fuse to fp16 safetensors, then llama.cpp/convert_hf_to_gguf.py
    if ollamaInstalled:
      FuseService.installInOllama(ggufPath, tag, chatTemplate)
        builds a Modelfile from chatTemplate.modelfileBody
        runs `ollama create <tag> -f Modelfile`
      
  All progress streams via onProgress closure → appends to log[] which renders in
  a monospace panel.
```

**Files involved**: [`ExportWizardView.swift`](../LLMPro/Features/Export/ExportWizardView.swift),
[`FuseService.swift`](../LLMPro/Services/FuseService.swift).

---

## 8. Modify a model (strip vision / abliterate)

```
ModelsBrowserView local-model row ✨ icon → modifyTarget = local
  → sheet(ModelModifyView)

ModelModifyView:
  doStripVision toggle (auto-checked if model.architecture contains "vl" / "_5" / etc.)
  doAbliterate toggle (EXPERIMENTAL badge)
  output name (auto-derived from displayName + suffixes)
  user clicks "Make new model"
  
  → ModelModifyService.shared.run(input:, outputName:, stripVision:, abliterate:)
    finalDir = PathResolver.modelsCustomDir/<outputName>/
    
    if stripVision (and not abliterate):
      runStripVision(python, src=input.directory, dst=finalDir)
        spawns `python helpers/strip_vision.py <src> <dst>`
        helper:
          read each shard with mx.load (handles bf16)
          filter out vision_tower.* / model.visual.* / multi_modal_projector.* etc.
          write shards with mx.save_safetensors
          rewrite model.safetensors.index.json with filtered weight_map
          drop vision_config/image_token_id/etc. from config.json
          copy tokenizer + chat_template
    
    if stripVision and abliterate:
      intermediateDir = finalDir + ".strip-tmp"
      runStripVision(python, src=input.directory, dst=intermediateDir)
      runAbliterate(python, src=intermediateDir, dst=finalDir)
      cleanup intermediateDir
    
    if abliterate only:
      runAbliterate(python, src=input.directory, dst=finalDir)
        spawns `python helpers/abliterate.py <src> <dst>`
        helper:
          load model via mlx_lm.utils.load
          find inner transformer module
          target_layer = int(n_layers * 0.6)
          for 20 harmful prompts: get residual stream at target_layer, mean → harm_mean
          for 20 harmless prompts: same → harmless_mean
          direction = (harm_mean - harmless_mean) / ||...||
          for each layer from target onward:
            project direction out of self_attn.o_proj.weight
            project direction out of mlp.down_proj.weight
          save via mlx_lm.utils.save(dst, src, model, tokenizer, config)
    
    ModelRegistry.shared.scan() → new model appears in local list
```

**Files involved**: [`ModelsBrowserView.swift`](../LLMPro/Features/Models/ModelsBrowserView.swift),
[`ModelModifyView.swift`](../LLMPro/Features/Models/ModelModifyView.swift),
[`ModelModifyService.swift`](../LLMPro/Services/ModelModifyService.swift),
[`strip_vision.py`](../LLMPro/Resources/helpers/strip_vision.py),
[`abliterate.py`](../LLMPro/Resources/helpers/abliterate.py).

---

## 9. Delete a local model

```
ModelsBrowserView local-model row 🗑 icon (disabled if model is in active training)
  → deletionTarget = local
  → alert("Delete <name>?") with bytes-freed warning

user confirms → confirmDelete(model:)
  → ModelRegistry.shared.delete(repoID:)
    For each of 4 cache locations:
      hf/models--<safe-name>/                    ← snapshot_download layout
      hf/hub/models--<safe-name>/                ← standard hub layout
      hf/.locks/models--<safe-name>/             ← top-level locks
      hf/hub/.locks/models--<safe-name>/         ← hub locks
    Measure blobs/ size first, then FileManager.removeItem
  
  → showDeletionResult alert with formatted bytes
  → ModelRegistry rescan → list updates
```

**Files involved**: [`ModelsBrowserView.swift`](../LLMPro/Features/Models/ModelsBrowserView.swift),
[`ModelRegistry.swift`](../LLMPro/Services/ModelRegistry.swift),
[`JobRegistry.swift`](../LLMPro/Services/JobRegistry.swift) (for `isModelInUse`).

---

## 10. Crash recovery

```
On launch (LLMProApp.task):
  JobRegistry.shared.recoverOrphans()
    scan PathResolver.adaptersDir/*/job.json
    for each sidecar:
      if its UUID is already in jobs[]: skip
      parse: pid, name, status, baseModel, datasetID, adapterPath, lastIter, startedAt, endedAt
      check kill(pid, 0) == 0:
        alive   → status = .running, reattach (tail log file from where we left off)
        dead    → status = .orphaned (the Monitor view will surface a Resume button)

(Resume button — partially implemented):
  TrainingService.resume(job:, latestAdapterFile:, context:)
    spawns `python -m mlx_lm lora -c config.yaml --resume-adapter-file <latest.safetensors>`
```

**Files involved**: [`LLMProApp.swift`](../LLMPro/App/LLMProApp.swift),
[`JobRegistry.swift`](../LLMPro/Services/JobRegistry.swift),
[`TrainingJob.swift`](../LLMPro/Models/TrainingJob.swift),
[`TrainingService.swift`](../LLMPro/Services/TrainingService.swift).

---

## 11. Recursive self-improvement (the Practice tab)

The Practice tab implements **rejection-sampling self-distillation gated by unit-test
execution** — the model practices coding problems, we run real tests against its
output, and only solutions that pass become the next round's training data.

```
SelfImproveView setup card:
  user picks model + seed (HumanEval / MBPP) + sliders:
    targetRounds (default 3), candidatesPerPrompt (default 4),
    rowsPerRound (default 20), trainIters (advanced, default 80)
  click "Start Practice"
  → modelContext.insert(SelfImproveRun(...))
  → Task { await SelfImproveService.shared.start(run:, context:) }

SelfImproveService.start(run, context):                   (@MainActor, one big Task)
  status.phase = .pullingSeed
  resolveModelArg(run.baseModelRepoID)               # bare folder → absolute path
  if !FileManager.fileExists(run.seedFile):
    spawn humaneval_pull.py <preset> <run.directory>
      ProcessRunner streams JSON events; UI shows "Loading openai_humaneval…"
      → writes seed.jsonl + eval.jsonl
  
  status.phase = .baselineEval
  if run.baselinePassAtOne == nil:
    spawn eval_pass_rate.py --eval <eval.jsonl> --model <abs-path>
      ProcessRunner streams {"event":"row", ...} for each problem
      collects {"event":"done", "pass_at_1": float}
    run.baselinePassAtOne = baseline
    status.passAtOneTrend = [baseline]
  
  for n in 1...targetRounds:
    # ─── round n ───
    create SelfImproveRoundRecord, append to run.roundsBlob via appendRound
    
    status.phase = .generating  ("Round n: trying problems…")
    spawn self_improve_round.py
        --seed   <seed.jsonl>
        --out    <round_n/>
        --model  <abs path>
        [--adapter <prior round's adapter dir>]
        --candidates K --max-tokens 512 --temperature 0.7 --top-p 0.95
        --row-timeout 15 --limit rowsPerRound
      ProcessRunner streams events:
        {"event":"start", "rows":N, "candidates":K}   → roundRecord.rowsAttempted = N
        {"event":"row_start", "i":i, "prompt_preview":...}
        {"event":"candidate", "i":i, "k":k, "status":"pass"|"fail"}
        {"event":"row_done",  "i":i, "passed":bool, "passes":m, "total":K}
        {"event":"done", "kept":N, "pass_rate":float}
      → helper writes round_n/dataset/{train,valid,test}.jsonl (chat schema)
    
    status.phase = .training  ("Round n: studying what it got right…")
    AutoTuner.tune(repoID: run.baseModelRepoID, duration: .quick)
       → cap iters at min(tuned.iters, run.trainIters)
    AutoTuner.renderYAML → write config.yaml into adapters/<round-job-id>/
    spawn python -m mlx_lm lora -c config.yaml
      LogStreamParser parses "Iter N: Train loss …" → status.detail updates
      stdout also tee'd to <adapter-dir>/training.log
      wait for exit code 0
    
    status.phase = .evaluating  ("Round n: grading the practice…")
    spawn eval_pass_rate.py --eval <eval.jsonl> --model <abs-path> --adapter <new adapter dir>
      → emits {"event":"done", "pass_at_1": float}
    roundRecord.evalPassAtOne = pass; status.passAtOneTrend = run.passAtOneTrend
    run.updateRound(roundRecord); context.save(); writeSidecar()
  
  status.phase = .completed  ("Done — see Try it out to chat with the improved model.")
```

UI side effects on each event:
- `pullingSeed`: 📚 "Getting the practice problems"
- `baselineEval`: 🧪 "Checking how it does without practice"
- `generating`: ✏️ "Round n: trying problems…" — progress bar (kept/attempted), "M passes / N tries" caption
- `training`: 🧠 "Round n: studying what it got right…" — shows iter + loss
- `evaluating`: ✅ "Round n: grading the practice…" — pass-at-1 trend chart updates on completion
- `completed`: 🎓 "Done — see Try it out to chat with the improved model."

The final adapter (the highest-numbered round) lives at
`~/Library/Application Support/LLMPro/adapters/<round-job-uuid>/adapters.safetensors`
and can be used directly from the Arena (Try it out) and Save & Use tabs. Each
completed run in the History list also carries a **"Use this fine-tune" menu** —
Try it out / Use in Code (both post a `ModelHandoff` of the run's model + final
adapter, the same hand-off a Teach job uses) / Reveal in Finder / Copy adapter path
— so a Practice result re-enters the outer loop (§0b) rather than being siloed. And
because [`ExportWizardView`](../LLMPro/Features/Export/ExportWizardView.swift)'s
`ExportSource` wraps a `SelfImproveRun` as well as a `TrainingJob`, Practice adapters
are exportable through Save & Use (§7) too.

**Files involved**:
[`SelfImproveView.swift`](../LLMPro/Features/SelfImprove/SelfImproveView.swift),
[`SelfImproveService.swift`](../LLMPro/Services/SelfImproveService.swift),
[`SelfImproveRun.swift`](../LLMPro/Models/SelfImproveRun.swift),
[`humaneval_pull.py`](../LLMPro/Resources/helpers/humaneval_pull.py),
[`self_improve_round.py`](../LLMPro/Resources/helpers/self_improve_round.py),
[`eval_pass_rate.py`](../LLMPro/Resources/helpers/eval_pass_rate.py),
[`AutoTuner.swift`](../LLMPro/Services/AutoTuner.swift),
[`LogStreamParser.swift`](../LLMPro/Core/LogStreamParser.swift).

---

## 12. Quit-while-training behaviour

```
NSApplication "Quit" → AppDelegate.applicationShouldTerminate(_:)
  running = JobRegistry.shared.runningJobs
  if running.isEmpty: return .terminateNow
  
  show NSAlert: "Training in progress" — N running jobs
    Stop and Quit   → JobRegistry.stopAll(); return .terminateLater
    Detach and Quit → JobRegistry.detachAll(); return .terminateNow
                       (detached subprocesses keep running independently, logs still tail to file;
                        on next launch, recoverOrphans picks them up via job.json + alive pid)
    Cancel          → return .terminateCancel
```

`applicationShouldTerminateAfterLastWindowClosed → false` so closing the last
window does NOT trigger the above — training continues in the background and the
app stays in the Dock.

**Files involved**: [`AppDelegate.swift`](../LLMPro/App/AppDelegate.swift),
[`JobRegistry.swift`](../LLMPro/Services/JobRegistry.swift).

---

## 13. Code with it (the Code tab — the Orchestrator team)

The Code tab runs a **fixed five-role agent team** over the user's local
(optionally fine-tuned) MLX model. The user talks **only to the Orchestrator**,
which delegates to the Planner / Researcher / Coder / UI agents. The Researcher does
**real web research**. **One shared `mlx_lm` model serves all five roles** (one
server daemon). The builders (Coder / UI) read/edit files and run commands inside a
user-chosen project folder. (See [`AgentRoles.swift`](../LLMPro/Services/AgentRoles.swift)
for the role definitions and [`CONTRACTS.md#the-orchestrator-team--delegation-tools`](CONTRACTS.md#the-orchestrator-team--delegation-tools)
for the tool/delegation graph.)

The tab is also a **3-pane IDE** (toggleable from the header sidebar button):
[`FileExplorerView`](../LLMPro/Features/Code/FileExplorerView.swift) (left) lists
the project tree; selecting a file opens it in
[`CodeEditorView`](../LLMPro/Features/Code/CodeEditorView.swift) (center) as a
syntax-highlighted, editable `NSTextView` with Save (⌘S). The explorer
auto-refreshes on every `agent.transcript.count` change, and the chat transcript
(right) renders **role-labeled, depth-indented** bubbles (emoji + role name in the
role's tint) plus tool diffs / `read_file` output syntax-highlighted via
[`SyntaxHighlighter`](../LLMPro/Core/SyntaxHighlighter.swift).

```
CodeView:
  user picks a project folder (NSOpenPanel) → @AppStorage("codeWorkspacePath")
  user picks the SHARED model               → @AppStorage("codeOrchestratorModel")
                                            #  (one model for the whole team — no agent picker)
  user picks an ADAPTER (optional)          → @AppStorage("codeAdapterJobID")
                                            #  loop stage ④: the fine-tune to run. The Picker lists
                                            #  completed TrainingJobs whose adapters.safetensors exists.
                                            #  Also pre-filled by .openCodeWithModel (applyHandoff:
                                            #  ModelHandoff or bare String) from Progress/Arena/Practice.
  click Start session → startSession() → CodingAgentService.shared.startSession(model:, adapterPath:)
                                            #  threads the selected adapter path through to
                                            #  MLXServerService --adapter-path (was hardcoded nil)
        MLXServerService.shared.start(model:, adapterPath:)   # one shared daemon
          1. resolveModelArg(model)         # registry hit → directory.path (don't re-download)
          2. pick a FREE localhost port; spawn `python -m mlx_lm server …`
          3. poll GET /health; fire a 1-token warm-up; state = .ready(port:)
        seed the Orchestrator convo (its system prompt + the workspace overview)

user types a task + Send (⌘-Return) → CodingAgentService.send(text):
  append the user message; runRole(.orchestrator, convo, depth: 0):

  runRole(role, convo, depth):              # capped at role.maxIterations
    repeat:
      resp = OpenAIChatClient.stream(baseURL, request)   # POST /v1/chat/completions (SSE)
             text streams live into a role-tagged bubble; tools = role.toolSpecs()
             (its baseTools + a call_<role> spec per delegate)
      parse native `tool_calls` OR <tool_call>/fenced-JSON fallback
      executeRoleCalls(calls):
        • call_<role>(task)  → collect → runDelegations (recursive sub-agent run);
                               >1 in ONE turn run CONCURRENTLY (unstructured Tasks,
                               interleaved on the shared server); depth-capped at 5;
                               each returns its final answer as the tool result
        • ask_user(question) → pendingQuestion set; the loop AWAITS the user's reply
                               (questionBar text field → answerUser(text))
        • todo_write(todos)  → updates the shared plan (PlanView), never the workspace
        • file/web tools     → ToolExecutor.execute (APPROVAL GATE below)
      no tool calls → this role's final answer; return it (END the role's loop)

  Typical shape:
    orchestrator → call_planner
                     planner → (maybe call_researcher → web_search / fetch_url,
                                scientific method) → returns a numbered plan
                   ← plan
    orchestrator → call_coder + call_ui IN THE SAME TURN (run in parallel)
                   ← each builder's summary
    orchestrator → short plain-text summary to the user (or ask_user to clarify)

APPROVAL GATE (per builder tool call):
  read_file / list_dir / glob / grep / web_search / fetch_url → read-only, auto-run
  write_file / edit_file → auto-run when AgentSettings.autoApproveEdits (default ON
                           for the team); else a `- / +` diff preview + Allow/Deny bar
  run_command            → gated unless autoRunCommands
  gated calls suspend on a CheckedContinuation; the inline Allow/Deny bar
  (agent.pendingApproval) resolves it via resolveApproval(_:). A single approval
  slot serializes, so auto-approve avoids parallel-approval conflicts.

ToolExecutor (workspace-sandboxed): sandboxed() rejects path escapes; run_command
  runs `/bin/zsh -lc <cmd>` with cwd = workspace + a 120 s watchdog; output
  truncated to 16000 chars; write_file/edit_file return a UI-only diff.

Stop button → CodingAgentService.stop() cancels the run and denies any pending
approval/question. The server keeps running until the user stops/restarts.
```

**Files involved**:
[`CodeView.swift`](../LLMPro/Features/Code/CodeView.swift),
[`AgentRoles.swift`](../LLMPro/Services/AgentRoles.swift),
[`WebSearch.swift`](../LLMPro/Services/WebSearch.swift),
[`CodingAgentService.swift`](../LLMPro/Services/CodingAgentService.swift),
[`AgentTools.swift`](../LLMPro/Services/AgentTools.swift),
[`MLXServerService.swift`](../LLMPro/Services/MLXServerService.swift),
[`OpenAIChatClient.swift`](../LLMPro/Services/OpenAIChatClient.swift),
[`FileExplorerView.swift`](../LLMPro/Features/Code/FileExplorerView.swift),
[`CodeEditorView.swift`](../LLMPro/Features/Code/CodeEditorView.swift),
[`SyntaxHighlighter.swift`](../LLMPro/Core/SyntaxHighlighter.swift),
[`ModelRegistry.swift`](../LLMPro/Services/ModelRegistry.swift),
[`RootView.swift`](../LLMPro/App/RootView.swift).

---

## 14. Manage team agents + skills (Code tab -> Options)

The Code tab's agents and skills are **live, editable Markdown files** -- managed
in-app, no rebuild required. Open **Code -> Options** in the Code tab toolbar.

**Edit team agents** (`AgentsManagerView`)
- "Edit team agents..." opens a raw-Markdown editor over `agents/<role>.md`
  (the roles orchestrator / planner / researcher / coder / ui, plus any you add).
- Full CRUD: + New (creates a file immediately), - Delete, edit the frontmatter
  (`id`/`name`/`emoji`/`tint`/`tools`/`delegates`/`maxIterations`/`skills`) + the
  system-prompt body, Save (writes the file + reloads `AgentStore`), Reveal in Finder.
- Agents reference each other via `delegates:` (-> `call_<id>` tools); depth-capped
  by `CodingAgentService.maxDelegationDepth`.
- Editing uses `MarkdownEditor` (an NSTextView with smart-substitution OFF) so the
  `---` frontmatter fences are never mangled into an em dash.

**Manage skills** (`SkillsManagerView`)
- "Manage skills (N)..." opens a raw-`SKILL.md` editor over `skills/<id>/SKILL.md`,
  with the same CRUD + Reveal + Duplicate.
- **3-stage progressive disclosure** (modeled on OpenAI Codex / Anthropic Agent
  Skills): the system prompt advertises only each in-scope skill's `name: description`
  (discovery); the agent calls `use_skill(name)` to load the full body + folder path
  (activation); then follows it, optionally reading bundled files (execution).
- Skills are **team-global by default**. An agent scopes to a subset via its
  `skills:` frontmatter (skill->agent; key absent = all, `[]` = none). A skill links
  to others via its own `skills:`/`links:` frontmatter (skill->skill, transitive),
  resolved by `CodingAgentService.availableSkills(for:)`.
- Gated by the **Skills** toggle in Options (`AgentSettings.useSkills`, default on).
  Two example skills (`conventional-commits`, `code-reviewer`) are seeded on first
  launch.

Both managers are **fully offline** (local Markdown only; the agents have no network
tools). See `docs/CONTRACTS.md` for the agent/SKILL.md frontmatter format and
`docs/ARCHITECTURE.md` for the `AgentStore` / `SkillStore` services.

> **History:** an earlier design had a single switchable "Agent" with an
> `AgentEditorView` picker and per-agent skill toggles backed by `AgentProfile` /
> `AgentTemplate`. That was replaced by the fixed Orchestrator **team** (section 13)
> with Markdown-defined roles. `AgentProfile` survives only as a (dead) SwiftData
> schema pin; `AgentTemplate` is unreferenced dead code; `AgentEditorView` was deleted.

---

## 15. Look inside a model (the Inspect tab)

A read-only window into any local model — three views over the same model picker.
Pick a model (reuses `ModelRegistry.shared.localModels`), then a Weights / Attention
/ Thinking segment.

```
ModelInspectorView:
  model Picker (ModelRegistry.shared.localModels) + 3-segment Picker

  WEIGHTS  (pure Swift — no model load, no Python)
    WeightsInspectService.load(model)  → Task.detached:
      ModelWeightsReport.build(directory:, repoID:)
        SafetensorsHeader.enumerateModel(directory:)   # reads model.safetensors.index.json
          → per shard: FileHandle reads 8-byte LE u64 header length N, then N bytes
            of JSON {name:{dtype,shape,data_offsets}} — NEVER the tensor blob
        config.json (prefers text_config) → layers/heads/kv/headDim/experts/quant
      → friendly card (params "7.1B", dtype, layers, GQA, MoE, quant/tied badges)
      → disclosure: param-by-layer Canvas bar chart + searchable per-tensor table

  ATTENTION  (one-forward MLX sidecar)
    AttentionInspectService.run(model:, prompt:)
      ProcessRunner.spawn(python, inspect_attention.py --model <abs> --prompt … --max-seq 64)
        helper monkeypatches mx.fast.scaled_dot_product_attention, ONE forward,
        recomputes softmax(QK^T) per layer (mean over heads), emits JSON per layer
      → Canvas heatmap (brighter = stronger attention); layer slider in a disclosure
      → clean "not available for this architecture" card on an `unsupported` event

  THINKING  (live — reuses the running server, no new wire-parsing)
    needs MLXServerService.isReady (a model loaded via the Code tab)
    OpenAIChatClient.stream(req with chat_template_kwargs:{enable_thinking:true})
      .reasoningDelta → 💭 Thinking disclosure   |   .textDelta → Answer
    → friendly "open the Code tab and Start session" hint when no server is running
```

**Files involved**:
[`ModelInspectorView.swift`](../LLMPro/Features/Inspect/ModelInspectorView.swift),
[`WeightsInspectorView.swift`](../LLMPro/Features/Inspect/WeightsInspectorView.swift),
[`AttentionInspectorView.swift`](../LLMPro/Features/Inspect/AttentionInspectorView.swift),
[`CoTInspectorView.swift`](../LLMPro/Features/Inspect/CoTInspectorView.swift),
[`SafetensorsHeader.swift`](../LLMPro/Core/SafetensorsHeader.swift),
[`WeightsInspectService.swift`](../LLMPro/Services/WeightsInspectService.swift),
[`AttentionInspectService.swift`](../LLMPro/Services/AttentionInspectService.swift),
[`inspect_attention.py`](../LLMPro/Resources/helpers/inspect_attention.py).
