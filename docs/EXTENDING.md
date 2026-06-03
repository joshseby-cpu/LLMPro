# Extending LLMPro

> 📝 **Maintainers**: when you add a new kind of capability that future agents
> are likely to extend (a new helper, a new sidebar tab, a new model-modify
> operation), add a recipe to this doc so the next agent can follow your
> pattern instead of inventing a parallel one. See the
> [doc-maintenance contract](../CLAUDE.md#%EF%B8%8F-documentation-is-part-of-the-work--read-this-section-twice).

How to add features without breaking what's already there. Each section is a
recipe — follow the steps and you'll match the existing patterns automatically.

> If your change doesn't match any recipe below, read
> [`CONVENTIONS.md`](CONVENTIONS.md) first. Most "new" features turn out to fit
> an existing pattern.

---

## Add a new curated coding dataset to the catalog

The shortest recipe in this doc — proves the catalog/helper pattern.

1. **Pick a HuggingFace dataset**. Note its repo ID and its row schema. Decide
   how rows map to `{user, assistant}` chat messages.

2. **Add a splitter to [`prepare_coding_dataset.py`](../LLMPro/Resources/helpers/prepare_coding_dataset.py)**:

   ```python
   def split_<your_preset>(row: dict) -> list[dict] | None:
       q = (row.get("question_field") or "").strip()
       a = (row.get("answer_field")   or "").strip()
       if not q or not a:
           return None
       return [{"role": "user",      "content": q},
               {"role": "assistant", "content": a}]
   ```

3. **Add it to the `PRESETS` dict** in the same file:

   ```python
   PRESETS: dict[str, tuple[str, Callable[[dict], list[dict] | None]]] = {
       …existing entries…,
       "<your-preset-id>": ("owner/dataset-name", split_<your_preset>),
   }
   ```

4. **Add metadata to the Swift catalog**
   ([`CodingDatasetCatalog.swift`](../LLMPro/Services/CodingDatasetCatalog.swift)):

   ```swift
   .init(
       id: "<your-preset-id>",     // MUST match the PRESETS key above
       displayName: "Your Dataset 50K",
       hfRepo: "owner/dataset-name",
       approxRows: 50_000,
       description: "What this dataset is good for.",
       recommendedFor: "Which models fit best",
       licenseHint: "MIT-ish — check the HF card."
   ),
   ```

5. **No UI changes required.** The new card appears in
   [`DatasetsView`](../LLMPro/Features/Datasets/DatasetsView.swift) automatically.

6. **Verify** by clicking *Prepare* once. Open the resulting
   `<datasets-dir>/<uuid>/train.jsonl` and confirm the chat schema is correct.

---

## Add a new helper script

If you need a Python capability that doesn't exist (e.g. quantize-to-3bit,
distill, run an eval harness):

1. **Write the helper** in
   [`LLMPro/Resources/helpers/<name>.py`](../LLMPro/Resources/helpers/).
   Follow the [JSON-event protocol](CONTRACTS.md#3-helper-script-protocol):

   ```python
   import json, sys
   def emit(p): sys.stdout.write(json.dumps(p) + "\n"); sys.stdout.flush()
   
   def main() -> int:
       if len(sys.argv) < 2:
           emit({"event": "error", "message": "Usage: …"})
           return 2
       emit({"event": "start", …})
       # … do work, emit progress events along the way …
       emit({"event": "done", …})
       return 0
   
   if __name__ == "__main__":
       raise SystemExit(main())
   ```

2. **Add the name to the install list** in
   [`PythonRuntime.installHelpers()`](../LLMPro/Services/PythonRuntime.swift):

   ```swift
   for name in ["hf_download", "prepare_coding_dataset", "download_hf_dataset",
                "strip_vision", "abliterate", "<your_helper>"] {
   ```

3. **If you need new Python deps**, add them to the `uv pip install …` line in
   `PythonRuntime.bootstrap()`. **Then either restart with a fresh venv** or
   `uv pip install` them by hand once into the existing venv.

4. **Write a Swift service** that wraps it
   ([`LLMPro/Services/<Capability>Service.swift`](../LLMPro/Services/)):

   ```swift
   import Foundation
   import SwiftUI
   
   @MainActor @Observable
   final class YourCapabilityService {
       static let shared = YourCapabilityService()
       
       struct ActiveJob: Identifiable { … }
       private(set) var active: [ActiveJob] = []
       
       private init() {}
       
       func run(inputs: …) {
           guard PythonRuntime.shared.isReady, let python = PythonRuntime.shared.pythonURL else { return }
           let helper = PathResolver.helpersDir.appendingPathComponent("<your_helper>.py")
           Task {
               do {
                   _ = try await ProcessRunner.runCapturing(
                       executable: python,
                       arguments: [helper.path, …],
                       environment: ["PYTHONUNBUFFERED": "1", "HF_HOME": PathResolver.hfHome.path],
                       onStdout: { [weak self] line in
                           Task { @MainActor in self?.handle(line) }
                       },
                       onStderr: { _ in }
                   )
               } catch { … }
           }
       }
       
       private func handle(_ line: String) {
           guard let data = line.data(using: .utf8),
                 let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
           else { return }
           switch json["event"] as? String {
           case "start": …; case "progress": …; case "done": …; case "error": …
           default: break
           }
       }
   }
   ```

5. **Build it into a feature** — pick the right sidebar tab and add a sheet/
   action that calls `YourCapabilityService.shared.run(…)`. Show progress from
   `service.active` in the UI.

6. **`xcodegen generate`** so the new files are picked up by Xcode.

---

## Add a new training-time hyperparameter

If a new mlx-lm flag becomes important and you want users to be able to set it
(or have AutoTuner pick it):

1. **Add the field to `TrainingConfig`** in
   [`TrainingService.swift`](../LLMPro/Services/TrainingService.swift):
   
   ```swift
   struct TrainingConfig {
       …
       var newKnob: Double
   }
   ```
   
   Update `TrainingConfig.default` and `renderYAML()`.

2. **Auto-tuned?** Add it to `AutoTunedConfig` and the `tune()` body in
   [`AutoTuner.swift`](../LLMPro/Services/AutoTuner.swift). Pick a value per
   size bucket. Update `renderYAML(...)` to write it.

3. **Power-user knob?** Add a `Stepper` or `TextField` to the **Advanced
   settings** disclosure in
   [`TrainingConfigView.swift`](../LLMPro/Features/Training/TrainingConfigView.swift).
   **Do not add it to the primary 3-card UI** — see
   [`CONVENTIONS.md#autotuner-picks-hyperparameters`](CONVENTIONS.md#autotuner-picks-hyperparameters).

4. **Verify** by running a small training job through Teach. Inspect the
   generated `config.yaml` to confirm the new key appears.

---

## Add a new source schema for dataset auto-detection

If a HuggingFace dataset uses a shape you haven't seen (e.g. `prompt + chosen +
rejected` for DPO data):

1. **Add detection** to `detect_schema()` in
   [`download_hf_dataset.py`](../LLMPro/Resources/helpers/download_hf_dataset.py):

   ```python
   def _looks_dpo(row: dict) -> bool:
       return ("prompt" in row and "chosen" in row and "rejected" in row)
   
   def detect_schema(row: dict) -> str:
       …existing checks…
       if _looks_dpo(row): return "dpo"
       …
   ```

2. **Add normalization** to `normalize_row()`. Decide which side of the contrast
   you keep (DPO data → keep `chosen` as the assistant message):

   ```python
   if schema == "dpo":
       p = _pick(row, fields.get("prompt", "prompt"))
       c = _pick(row, fields.get("chosen", "chosen"))
       if not p or not c: return None
       return [{"role": "user", "content": p}, {"role": "assistant", "content": c}]
   ```

3. **Update the Swift schema picker** in
   [`HuggingFaceDatasetSearchView.swift`](../LLMPro/Features/Datasets/HuggingFaceDatasetSearchView.swift)
   `SchemaChoice` enum + `columnMappingFields(for:)` — so users can manually
   override if auto-detection misses.

4. **Update [`DatasetEditorService.parseRow`](../LLMPro/Services/DatasetEditorService.swift)**
   to handle the new shape too. The dataset editor always works in chat shape;
   `parseRow` is what auto-promotes legacy rows. The promotion logic mirrors the
   Python normaliser — keep them in sync.

---

## Add a new sidebar tab

Don't do this lightly — we have a dozen already. But the recipe:

1. **Add a case** to
   [`SidebarSection`](../LLMPro/App/RootView.swift) with title + SF Symbol.

2. **Add the case** to the `detail` switch in `RootView.swift`:

   ```swift
   case .yourtab: YourTabView()
   ```

3. **Create the view** at `LLMPro/Features/<YourTab>/<YourTab>View.swift`.
   Follow the per-tab template (NavigationStack root, services in
   `@Environment` / `@State`, no business logic in the view).

4. **`xcodegen generate`** and build.

---

## Add cross-tab navigation

If a button in tab A should jump to tab B:

1. **Declare a Notification.Name** next to the sender:

   ```swift
   extension Notification.Name {
       static let openYourTabWithContext = Notification.Name("LLMPro.openYourTabWithContext")
   }
   ```

2. **Post it** from the sending view:

   ```swift
   Button("Open YourTab") {
       NotificationCenter.default.post(name: .openYourTabWithContext, object: contextString)
   }
   ```

3. **Receive it** in [`RootView.swift`](../LLMPro/App/RootView.swift)'s
   `sidebar` view modifier chain:

   ```swift
   .onReceive(NotificationCenter.default.publisher(for: .openYourTabWithContext)) { note in
       selection = .yourtab
       if let ctx = note.object as? String { /* propagate */ }
   }
   ```

4. **In the receiving view**, also listen if it needs to react:

   ```swift
   .onReceive(NotificationCenter.default.publisher(for: .openYourTabWithContext)) { note in
       if let ctx = note.object as? String {
           self.someState = ctx
       }
   }
   ```

Keep the total event count in single digits. If you find yourself adding many,
think about whether a shared service would be cleaner.

---

## Add a new modify-model capability (alongside strip-vision / abliterate)

If you want to add e.g. "Quantize this model to 4-bit":

1. **Write the helper** (see "Add a new helper script" recipe above).

2. **Extend [`ModelModifyService.swift`](../LLMPro/Services/ModelModifyService.swift)**:
   - Add a new `ModificationStage` case
   - Add a new boolean param to `run(input:outputName:stripVision:abliterate:)`
   - Add a new private `runYourThing(python:, src:, dst:)` async method
   - Update the chain logic in `run(...)` to handle the new flag

3. **Extend [`ModelModifyView.swift`](../LLMPro/Features/Models/ModelModifyView.swift)**:
   - Add a `@State private var doYourThing: Bool`
   - Add a `Toggle` in the options form with a clear blurb
   - Update `regenerateName()` to append a suffix when the new flag is set
   - Update `canRun` to allow this flag in isolation

4. **Update the default-output-name** helper to reflect the new suffix.

5. **Test**: click ✨ on a local model, toggle just your new capability, hit
   "Make new model". Verify a new entry appears in Local Models.

---

## Add a new chat-template for Ollama export

If you fine-tune a model whose chat template we don't ship:

1. **Add a case** to `OllamaChatTemplate` in
   [`FuseService.swift`](../LLMPro/Services/FuseService.swift):

   ```swift
   case yourArch
   
   var displayName: String { … case .yourArch: "Your Arch (Pretty Name)" … }
   
   var modelfileBody: String {
       switch self {
       case .yourArch:
           return """
           TEMPLATE \"\"\"<the actual template body>\"\"\"
           PARAMETER stop "<stop-token>"
           """
       …
       }
   }
   ```

2. **Map it in `OllamaChatTemplate.suggestion(forArchitecture:)`** so the export
   wizard auto-selects the right template based on `config.json`'s `model_type`.

3. **Test**: export a model of that architecture as GGUF, install in Ollama,
   confirm `ollama run <tag>` produces sane output.

---

## Add a new seed preset to the Practice tab

The Practice loop ships with two seed datasets (HumanEval and MBPP). To add a third:

1. **Add an adapter in [`humaneval_pull.py`](../LLMPro/Resources/helpers/humaneval_pull.py)**: write an `adapt_<name>(row: dict) -> dict | None` that turns a source HF row into the normalized shape:
   ```python
   {"task_id": str, "prompt": str, "tests": str, "entry_point": str,
    "canonical_solution": str, "messages": [{"role":..., "content":...}, ...]}
   ```
   `tests` must be Python code that — when run with the candidate's code already `exec`'d in `namespace` — either passes (no exception) or raises. If the source uses HumanEval-style `def check(candidate): ...`, leave that shape alone — the runner detects it and calls `check(namespace[entry_point])` automatically.

2. **Register in the PRESETS dict** at the bottom of `humaneval_pull.py`:
   ```python
   PRESETS["bigcodebench"] = ("bigcode/bigcodebench", "v0.1.4", adapt_bigcodebench)
   ```
   The tuple is `(hf_repo, split, adapter)`. Add a special-case in `iter_rows` if the repo needs `load_dataset(name, config_id, split=...)` rather than the plain `(name, split=...)` form.

3. **Add a case to [`SelfImproveSeed`](../LLMPro/Models/SelfImproveRun.swift)**:
   ```swift
   case bigcodebench = "bigcodebench"
   ```
   Plus a `displayName` and a `oneLine` blurb. The case's rawValue must match the key in PRESETS.

That's it — `SelfImproveView`'s picker uses `SelfImproveSeed.allCases`, so the new option appears automatically.

---

## Swap or augment the judge

The default judge in [`self_improve_round.py`](../LLMPro/Resources/helpers/self_improve_round.py) is code-execution against the row's `tests` field (`run_one_test()`). To plug in a different judge — say, a larger MLX model scoring outputs against a rubric — replace the body of `run_one_test()` only. Keep the same `(passed: bool, reason: str)` return shape so the calling site doesn't change.

Two patterns we'd accept:

- **Multi-judge AND**: code-exec OR rubric — useful when only some prompts ship tests. Currently the helper rejects rows without `tests` early, so you'd also need to soften that gate.
- **Multi-judge OR with severity**: code-exec is hard pass/fail; rubric scores 1–5; keep candidates that pass tests OR score ≥4. Bookkeeping changes only inside `self_improve_round.py`; the JSON-event protocol stays the same as long as `candidate.status` is still `"pass" | "fail"`.

Don't change the protocol unless you've also updated `SelfImproveService.handleRoundEvent` AND `docs/CONTRACTS.md`. The contract is what lets Swift and Python evolve independently.

---

## Add a new agent tool (Code tab)

To give the coding agent a new capability (say `move_file`):

1. **Add a case to `AgentToolName`** in
   [`AgentTools.swift`](../LLMPro/Services/AgentTools.swift) and set its
   `isReadOnly` flag. Read-only tools auto-run; **any non-read-only tool is
   automatically approval-gated** by `CodingAgentService` — no extra wiring.

2. **Add a `spec(...)` entry to `AgentTools.specs`** — the OpenAI tool definition
   (`ChatToolSpec`) sent on every request. The model discovers the tool from its
   `description` + the JSON-schema `parameters`, so write the description as the
   one-line instruction you'd give a teammate.

3. **Add an `execute` branch + a private method to `ToolExecutor`** (same file).
   Run any path argument through `sandboxed()` (rejects workspace escapes) and pass
   the result through `truncate()` (16000-char cap) before returning the
   `ToolResult`.

4. **Add the tool to the system prompt** in `CodingAgentService.resetConversation`
   (the prompt lists every tool + the `<tool_call>` fallback format) so models on
   the text-fallback path know it exists.

5. **Give it UI in [`CodeView.swift`](../LLMPro/Features/Code/CodeView.swift)**:
   add an SF Symbol for the tool in `ToolCardView` and a friendly `title` case in
   `AgentToolCallView.title`.

6. **`xcodegen generate`** is not needed (no new file), but rebuild and drive the
   agent once to confirm the tool is called and its card renders.

---

## Edit or add a team agent (Code tab)

The five Code-tab roles (orchestrator · planner · researcher · coder · ui) are
defined by **editable Markdown files** — no rebuild needed to change a role's
character, tools, delegates, emoji/tint, or iteration cap.

1. **The easy path — edit in the app.** Code tab → **Options** (gear) → **"Edit
   team agents…"** opens [`AgentsManagerView`](../LLMPro/Features/Code/AgentsManagerView.swift).
   Pick a role, edit its raw markdown, **Save** (writes the file + reloads
   [`AgentStore`](../LLMPro/Services/AgentStore.swift), so the **next run** obeys
   the edit). **Reset to default** re-copies the bundled version; **Show in Finder**
   reveals the file.

2. **By hand** — edit `~/Library/Application Support/LLMPro/agents/<role>.md`
   directly (it persists; `AgentStore` only seeds it from the bundle when missing).
   The format is YAML-ish frontmatter + a system-prompt body:

   ```markdown
   ---
   id: coder                 # role raw value (must match the filename's role)
   name: Coder               # display name
   emoji: 💻
   tint: green               # purple | blue | teal | green | orange
   tools: [read_file, list_dir, glob, grep, write_file, edit_file, run_command, todo_write]
   delegates: []             # role ids this role may call, e.g. [planner, researcher, coder, ui]
   maxIterations: 28         # the role's loop cap
   ---
   You are the CODER, a builder on the team. …   # the role's "character"
   ```

   What each key does:
   - `name` / `emoji` / `tint` — how the role shows in the transcript + team indicator.
   - `tools` — the role's non-delegation tool set (names from `AgentToolName`).
     **Unknown tool names are silently ignored.** The `call_<role>` delegation
     specs are added in code, not here.
   - `delegates` — which roles this one may call. **Unknown role ids are ignored.**
     An explicit `[]` means "delegates to no one" (distinct from omitting the key).
   - `maxIterations` — caps the role's tool-use loop.
   - **Body** — the system-prompt "character". The project folder, workspace
     overview, and tool-calling footer are appended in code, so don't restate them.

   Any field you omit falls back to the role's compiled-in default
   ([`AgentRoles.swift`](../LLMPro/Services/AgentRoles.swift) `defaultX`), and an
   unparseable file falls back entirely — the markdown is authoritative, the Swift
   values are the safety net. To **edit the shipped default** (so a fresh install
   gets it), change the bundled `LLMPro/Resources/agents/<role>.md` and
   `xcodegen generate` — but note existing users keep their on-disk copy until they
   Reset. The five role ids are fixed; this recipe edits the existing roles, it does
   not add a sixth (the team is fixed by design — see
   [`CONVENTIONS.md`](CONVENTIONS.md#the-code-tab-is-a-fixed-five-role-orchestrator-team-replaced-the-agent-library)).

3. **Verify** by starting a Code session and driving a task — the edited
   instruction takes effect on the next run.

---

## Add or edit an Agent Skill (Code tab)

**Agent Skills** are reusable `SKILL.md` instruction packages the team can load on
demand (modeled on the OpenAI Codex / Anthropic Agent Skills standard). They are
**team-global by default** — every role sees them unless an agent opts into a subset
via its `skills:` frontmatter (see Linking below). Two ways to add one:

1. **From the UI (raw markdown).** Code tab → **Options** (gear) → make sure the
   **"Skills: load instruction packs on demand"** toggle (`AgentSettings.useSkills`,
   default on) is on → **"Manage skills (N)…"** opens
   [`SkillsManagerView`](../LLMPro/Features/Code/SkillsManagerView.swift) — a
   raw-`SKILL.md` editor (skill list + monospace markdown editor) mirroring
   `AgentsManagerView`. Click **＋ New** and the skill is **created immediately**
   with a placeholder name; **rename it by editing the `name:` line** in the raw
   markdown (the folder id stays stable). Edit the actual `SKILL.md` text, then
   Save; **Duplicate** and **Delete** (which scrubs the id from other skills' links)
   are on the toolbar. The editor is a custom
   [`MarkdownEditor`](../LLMPro/Features/Code/MarkdownEditor.swift) with smart
   substitution **disabled**, so typing `---` stays `---` (SwiftUI `TextEditor`
   turned it into an em-dash and broke YAML). [`SkillStore`](../LLMPro/Services/SkillStore.swift)
   writes `skills/<slug-id>/SKILL.md`. The skill is available on the next run —
   nothing else to enable.

2. **By hand-authoring** under `~/Library/Application Support/LLMPro/skills/`
   ([`PathResolver.skillsDir`](../LLMPro/Core/PathResolver.swift)). Make a folder
   and drop a `SKILL.md` in it:

   ```
   skills/my-skill/SKILL.md:

   ---
   name: My Skill
   description: One line the agent sees before it loads the full body.
   skills: [another-skill-id]   # optional — skill→skill links
   ---

   <markdown instructions the agent reads after calling use_skill("My Skill")>
   ```

   The **folder name is the stable id** — pick a slug you won't want to change
   (renaming the skill in the UI rewrites the frontmatter but keeps the folder).
   Optional bundled files (scripts / references / assets) in the folder are
   preserved on import; the folder path is handed to the agent (via
   `SkillContext.dirPath`) so it can read them. `SkillStore.scan()` picks the
   folder up on next launch. No Swift or schema changes are needed.

**Linking.** A skill can link to **other skills** via its own `skills:` (alias
`links:`) frontmatter — `use_skill` then tells the agent about the linked skills and
follows the links transitively. A skill can be scoped to **specific agents** by
listing its id in an agent's `agents/<role>.md` `skills:` frontmatter (edit it the
same way via Options → "Edit team agents…"): **no `skills:` key on the agent = it
sees every skill (default); `[]` = none; a list = exactly those.**

How it surfaces — **3-stage progressive disclosure**: (1) **discovery** —
`CodingAgentService.systemMessage` appends only `name: description` under a
`## Skills available to you` heading so the model knows *when* to use it; (2)
**activation** — when ≥1 skill exists and `useSkills` is on, `runRole` adds the
`use_skill` tool and the agent calls `use_skill(name)` to load the full
instructions body + folder path; (3) **execution** — the agent follows them. See
[`CONTRACTS.md`](CONTRACTS.md#agent-skills-use_skill--the-skillmd-format).

(On first launch only, `SkillStore.installDefaultsAndScan()` seeds two example
skills — `conventional-commits` and `code-reviewer` — guarded by a `UserDefaults`
flag so deleting them doesn't bring them back.)

---

## Add a field to an agent

To give [`AgentProfile`](../LLMPro/Models/AgentProfile.swift) a new setting
(say a per-agent `topP`):

1. **Add the stored property** to `AgentProfile` with a default (additive only —
   see "Migrate SwiftData schema" below). The entity is already registered in
   `LLMProApp`'s `modelContainer(for:)` list, so no container change is needed.

2. **If it's a runtime setting** the loop consumes, thread it through the
   `agentSettings` computed bridge → `CodingAgentService.AgentSettings` →
   `OpenAIChatClient` request. (If it's purely descriptive, like `detail`, skip
   this step.)

3. **Add a control** to the editor — a `TextField` / `Toggle` / `Slider` /
   `Stepper` in the matching section (identity, instructions, Skills, or permissions
   & sampling) bound to the new field, saving through the SwiftData `modelContext`
   like the existing fields. **Note:** this recipe describes the dead single-agent
   `AgentProfile` path; the old `AgentEditorView` editor has been **deleted** (the
   live team is the markdown-backed `TeamRole` system edited via `AgentsManagerView`,
   so for the live team you'd add the field to `agents/<role>.md` + `AgentDefinition`
   + `AgentStore.parse` + the `TeamRole` fallback instead).

4. **Verify** by editing an agent, setting the field, starting a session, and
   confirming the value reaches the request (or the behaviour it controls).

---

## Migrate SwiftData schema

There's no SwiftData migration strategy in place. Until there is:

- **Additive changes are safe** (new optional fields with defaults).
- **Renaming or removing a field** will fail to load existing user data. The
  user's `default.store` lives in
  `~/Library/Containers/<bundle-id>/Data/Library/Application Support/...` (or
  `~/Library/Application Support/LLMPro/` for unsandboxed builds). You'll
  need to either nuke the store or implement a `Schema` migration plan.

If you must do a breaking change, document it in [`STATE.md`](STATE.md) under
"Breaking changes since vX" so a future agent doesn't get bitten.

---

## Things you probably *shouldn't* add

A short list of "no" decisions to save you time. Each has a reason in
[`CONVENTIONS.md`](CONVENTIONS.md).

- **A CLI front-end.** This is a polished app for non-engineers. Stay on the app.
- **A "tasks panel" listing all active jobs across services.** YAGNI; per-feature
  active lists are fine.
- **A separate logging framework.** `print` + `training.log` is enough.
- **Telemetry / analytics.** `AppSettings.telemetryEnabled` defaults false and
  there's no implementation. Don't change that without explicit user request.
- **A second persistence layer (Core Data, GRDB).** SwiftData is enough.
- **A web view for any tab.** Pure SwiftUI rendering everywhere.
- **An `Action` / `Command` abstraction layer.** Direct service calls are clearer.

If you have a concrete need that pushes against one of these, document the case
in [`STATE.md`](STATE.md#open-design-questions) before implementing.
