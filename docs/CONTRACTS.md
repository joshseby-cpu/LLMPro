# External contracts

> 📝 **Maintainers**: this is the highest-cost doc to let go stale. If you change
> a mlx-lm CLI invocation, an HF API endpoint, a helper JSON event, a path the
> app uses on disk, a SwiftData field, or a Notification.Name, update the
> relevant section the same session. See the
> [doc-maintenance contract](../CLAUDE.md#%EF%B8%8F-documentation-is-part-of-the-work--read-this-section-twice).

Every external interface this app depends on. If any of these change upstream we
will break — so they're documented here so an agent can spot regressions
quickly.

---

## 1. The mlx-lm CLI surface

The app shells out to `python -m mlx_lm <subcommand>` (NOT the deprecated
`python -m mlx_lm.<subcommand>` form). Tested against **mlx-lm 0.31.3**, installed
into the app's bundled venv at `~/Library/Application Support/MLXStudio/runtime/.venv/`.

### `mlx_lm lora` — training

Used by [`TrainingService.swift`](../MLXStudio/Services/TrainingService.swift).

Invocation:
```
python -m mlx_lm lora -c <config.yaml>
python -m mlx_lm lora -c <config.yaml> --resume-adapter-file <latest.safetensors>
```

Config-file keys we generate (see [`AutoTuner.swift`](../MLXStudio/Services/AutoTuner.swift)
and `TrainingConfig.renderYAML()` in [`TrainingService.swift`](../MLXStudio/Services/TrainingService.swift)):

```yaml
model: "<HF-repo-id-or-absolute-path>"
train: true
fine_tune_type: lora              # lora | dora | full
data: "<dataset-directory>"        # must contain train.jsonl, optionally valid.jsonl, test.jsonl
seed: 0
batch_size: 1                      # int
iters: 200                         # int
learning_rate: 1.0e-5              # float — see float-format note below
num_layers: 16                     # int — depth at which LoRA injects
grad_accumulation_steps: 1
max_seq_length: 2048
val_batches: 25
steps_per_report: 10
steps_per_eval: 100
save_every: 100
adapter_path: "<absolute-dir>"
grad_checkpoint: true              # bool
mask_prompt: true                  # bool — only compute loss on completion tokens
optimizer: adamw                   # adamw | adam | sgd | adafactor | muon
clear_cache_threshold: 1073741824  # int bytes — free mlx cache when it exceeds this (M-series win)
lr_schedule:                       # optional — warmup → cosine-decay (omit for a flat LR)
  name: cosine_decay               # any fn in mlx.optimizers.schedulers
  warmup: 25                       # linear ramp 0→peak over this many steps
  warmup_init: 1.0e-07
  arguments: [1.0e-5, 475, 1.0e-6] # [peak_lr, decay_steps, end_lr]; mlx-lm IGNORES learning_rate when present
lora_parameters:                   # omit this whole block for fine_tune_type: full
  keys:
    - "self_attn.q_proj"
    - "self_attn.v_proj"
  rank: 8
  scale: 20.0                      # = LoRA alpha; effective scale = scale/rank
  dropout: 0.0
```

**`fine_tune_type: dora`** = DoRA (weight-decomposed LoRA) — a higher-quality
adapter at the same rank for a small speed/memory cost; uses the same
`lora_parameters` block. `AutoTuner` auto-selects it for the **Thorough** tier and
always emits the `lr_schedule` above. These are the MLX-native, portable analogue
of what CUDA tools like Unsloth do (Unsloth's Triton kernels can't run on Metal).

**⚠️ YAML float gotcha.** PyYAML parses `2e-05` as a **string**, not a float (it
needs a mantissa dot: `2.0e-05`). Swift's `String(Double)` emits the dot-less form,
so `TrainingConfig.yamlNum(_:)` inserts `.0` before the exponent for every float we
write (`learning_rate`, `scale`, `dropout`, the `lr_schedule` args). Don't emit a
raw `\(double)` into training YAML.

Stdout format we parse (`LogStreamParser`):

```
# Training line, every <steps_per_report> iters:
Iter N: Train loss F, Learning Rate F, It/sec F, Tokens/sec F, Trained Tokens N, Peak mem F GB

# Eval line, every <steps_per_eval> iters:
Iter N: Val loss F, Val took Ts

# Save line, every <save_every> iters:
Iter N: Saved adapter weights to <path> and <checkpoint-path>.

# Final:
Saved final weights to <path>.
```

Regex in [`LogStreamParser.swift`](../MLXStudio/Core/LogStreamParser.swift):

```regex
# train:
Iter\s+(\d+):\s+Train\s+loss\s+([\d.]+)(?:,\s+Learning\s+Rate\s+([\d.eE+\-]+))?(?:,\s+It\/sec\s+([\d.]+))?(?:,\s+Tokens\/sec\s+([\d.]+))?(?:,\s+Trained\s+Tokens\s+(\d+))?(?:,\s+Peak\s+mem\s+([\d.]+)\s*GB)?

# eval:
Iter\s+(\d+):\s+Val\s+loss\s+([\d.]+)
```

### Resume

```
--resume-adapter-file <path-to-existing-adapters.safetensors>
```

Appended by **two** paths in [`TrainingService.swift`](../MLXStudio/Services/TrainingService.swift):

- `resume(job:, latestAdapterFile:, context:)` — crash-recovery resume of an
  *orphaned* job from its last checkpoint.
- `start(job:, context:, resumeAdapterFile: URL? = nil)` — the optional
  `resumeAdapterFile:` is the feedback loop's **refine-from-adapter** edge: Teach's
  "Continue a previous fine-tune?" picker calls `launchRefine(from:)`, which reuses
  the source job's config (swapping only `adapter_path`) and passes the source's
  `adapters.safetensors` here so mlx-lm continues from those weights. Reusing the
  exact config keeps the LoRA architecture resume-compatible. When `nil` (the
  default, a fresh fine-tune) no flag is appended.

### `mlx_lm generate` — inference

Used by [`InferenceService.swift`](../MLXStudio/Services/InferenceService.swift).

```
python -m mlx_lm generate \
  --model <path-or-repo> \
  [--adapter-path <adapter-dir>] \
  --prompt "<text>" \
  --max-tokens N \
  --temp F \
  --top-p F \
  [--seed N] \
  [--system-prompt "<text>"]
```

Stdout format we consume:

```
==========
<generated text on one or more lines>
==========
Prompt: N tokens, F tokens-per-sec
Generation: N tokens, F tokens-per-sec
Peak memory: F GB
```

We yield lines between the `==========` markers as streaming tokens.

### `mlx_lm fuse` — merge LoRA + GGUF export

Used by [`FuseService.swift`](../MLXStudio/Services/FuseService.swift).

```
python -m mlx_lm fuse \
  --model <base> \
  --adapter-path <adapter-dir> \
  --save-path <out-dir> \
  [--export-gguf --gguf-path <gguf-file>] \
  [--dequantize]
```

**Architecture limitation**: `--export-gguf` only works for `llama / mistral /
mixtral`. For Qwen / Gemma / Phi we fall back to llama.cpp's `convert_hf_to_gguf.py`.

### `mlx_lm convert` — quantize HF model to MLX format

Used by [`ConversionService.swift`](../MLXStudio/Services/ConversionService.swift).

```
python -m mlx_lm convert \
  --hf-path <repo-or-path> \
  --mlx-path <out-dir> \
  [-q --q-bits {4,8} --q-group-size 64]
```

### `mlx_lm server` — long-lived OpenAI-compatible server

Used by [`MLXServerService.swift`](../MLXStudio/Services/MLXServerService.swift) as
the coding agent's inference backbone. Unlike every other mlx-lm invocation this is
a **daemon** — it stays running and the model loads once.

```
python -m mlx_lm server \
  --model <resolved-path-or-repo> \
  --host 127.0.0.1 \
  --port <free-port> \
  --log-level INFO \
  [--adapter-path <adapter-dir>]
```

The port is a free localhost port chosen by binding a POSIX socket to port 0. The
model arg is resolved to an absolute path first (registry hit → `directory.path`)
so the server doesn't re-download a model that's already on disk — the same
resolver pattern as training/inference.

Endpoints exposed by the server (we use the first two + `/health`):

```
POST /v1/chat/completions    ← the agent loop
POST /v1/completions
GET  /v1/models
GET  /health                 ← polled until it listens, then a 1-token warm-up chat
```

**Verified against mlx-lm 0.31.3** — `server --help` lists `--model`,
`--adapter-path`, `--host`, `--port`, `--temp`, `--max-tokens`.

---

## 2. mlx-lm Python API we touch directly (from `abliterate.py`)

`abliterate.py` is the only helper that does real Python ML work (refusal-direction
projection — uncensoring; prior art: [heretic](https://github.com/p-e-w/heretic),
see [`REFERENCES.md`](REFERENCES.md)). It uses:

```python
from mlx_lm.utils import load, load_config, save
# load(repo_or_path) → (model, tokenizer)
# load_config(repo_or_path) → dict (the config.json contents)
# save(dst_path, src_path_or_repo, model, tokenizer, config, donate_model=True)
#   ↑ writes weights + tokenizer + config + index — full model save
```

Verified against mlx-lm 0.31.3. Beyond load/save, abliterate.py also uses
`dequantize_model` (from `mlx_lm.utils`), `mx.quantize`/`mx.dequantize`,
`mx.linalg.norm`, and `tokenizer.apply_chat_template`. It reads `config.json`
directly (not `load_config`) and falls back to a manual safetensors save if `save`'s
signature differs.

**Recipe (2026-05-31 rewrite — the version that actually works):**
- **Quantized inputs are dequantized first** via `dequantize_model(model)` and saved
  full-precision (fp16, quantization keys stripped from config). Projecting a refusal
  direction out of a 4-bit weight and re-quantizing snaps ~85% of the edit back
  (measured), so an in-place quantized abliteration is a near-no-op. Re-run Shrink to
  recompress.
- The refusal direction is taken at the **last chat-template token**, meaned over
  prompts — *not* a mean over sequence positions (the BOS token is a ~137× attention
  sink that dominates a token-mean and yields the wrong direction → lobotomy).
- **`embed_tokens` is NOT ablated** — many models (Llama 3.2, …) tie it to the
  unembedding, so ablating it collapses the logits into degenerate repetition.
- Orthogonalizes attention `o_proj` **and** every MLP/MoE down-projection across all
  layers: dense `mlp.down_proj`, Qwen `mlp.switch_mlp.down_proj` (3-D), Gemma
  `experts.switch_glu.down_proj` (3-D), and shared/per-expert down-projections.
  Routers and gate/up projections are left alone.
- The `done` event reports `refusal_reduction` (1.0 = signal fully removed) with
  `pre_gap`/`post_gap`, `mutated_{matrices,float,quant}`/`skipped`,
  `attn_proj`/`mlp_proj`/`moe_proj`, `was_quantized`, and `output_dtype`. A
  `mutated_matrices` of 0 is raised as an `error` (unrecognised architecture) rather
  than silently writing back an unchanged model. The Swift side
  (`ModelModifyService.handleAbliterateLine`) reads only `progress`/`error`; the
  `done` fields are informational.

If the mlx-lm API changes, update `abliterate.py`'s load/dequantize/save block.

---

## 3. Helper script protocol

All Python helpers in [`MLXStudio/Resources/helpers/`](../MLXStudio/Resources/helpers/)
follow the same conventions so Swift can parse them uniformly.

### Invocation

```bash
python <helper>.py <required-args...> [optional-args...]
```

Swift side: spawn via [`ProcessRunner.swift`](../MLXStudio/Core/ProcessRunner.swift)
with `PYTHONUNBUFFERED=1` in the environment so output flushes line-by-line.

**`mlx_run.py` launcher — Apple-Silicon MLX memory tuning (always on).**
`MemoryService.wrap()` **always** prepends `mlx_run.py` to the mlx_lm argv (so it
runs on every training, inference, and coding-agent-server invocation), and
`mlx_run.py` applies Apple-Silicon-aware MLX limits before `runpy`-executing the
real module:

- It reads the Metal **working-set ceiling** from `mx.device_info()`
  (`max_recommended_working_set_size`, ~84% of unified memory — e.g. ~107 GB of
  128 GB) and re-pins `set_memory_limit`, `set_wired_limit`, and `set_cache_limit`
  to it (cache to half). MLX's stock defaults sit *above* this ceiling, so a large
  run can grow past the safe point and hard-crash with
  `kIOGPUCommandBufferCallbackErrorOutOfMemory`; re-pinning makes MLX free its
  cache *before* crossing (graceful slowdown, not a crash). Limits are soft, so a
  run that genuinely needs more is still allowed — nothing that used to fit stops
  fitting. Raising the ceiling itself needs `sudo sysctl iogpu.wired_limit_mb`,
  which the app can't/shouldn't do, so `set_wired_limit` is clamped to the ceiling.
- Env overrides: `MLXSTUDIO_MEMORY_LIMIT_BYTES=<N>` (the Memory-tab budget, wins
  over the auto memory limit), `MLXSTUDIO_CACHE_LIMIT_BYTES=<M>`, and
  `MLXSTUDIO_NO_AUTOTUNE=1` (skip all tuning, use stock MLX defaults).

`TrainingService`, `InferenceService`, and `MLXServerService` all route their
`["-m","mlx_lm",…]` argv through `MemoryService.wrap(_:)`. If `mlx_run.py` is
somehow missing, `wrap` degrades to a transparent passthrough.

### Output format — JSON events

The helper emits **one JSON object per line** on stdout. Each line is a self-contained
event. **Never split a JSON object across lines.**

```python
def emit(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()
```

### Event taxonomy

Every helper emits at least these three event types:

```jsonc
{"event": "start",
 // dataset prep:
 "repo": "owner/name", "config": null, "split": "train", "max_rows": 20000,
 // model download:
 "repo": "owner/name", "total_bytes": 712593855, "cache_dir": "...",
 // strip-vision:
 "src": "...", "dst": "...",
 // abliteration:
 "src": "...", "dst": "..."}

{"event": "progress",
 // dataset prep / dataset prep / strip-vision use a "stage" field:
 "stage": "loading" | "schema" | "download" | "transform" | "write" | "reading" | "writing" | "harmful" | "harmless" | "ablating" | "saving",
 "message": "human-readable status",
 // download uses byte-precise progress instead:
 "downloaded": 419701084, "total": 712593855, "percent": 0.59, "file": "<hash>.incomplete",
 // strip-vision uses shard progress:
 "shard": "model-00001-of-00006.safetensors", "shard_num": 1, "total_shards": 6}

{"event": "done",
 // dataset prep:
 "train": 17994, "valid": 1000, "test": 1000, "schema": "chat", "source_schema": "instruction_output",
 // model download:
 "path": "/Users/.../snapshots/<rev>",
 // strip-vision:
 "dst": "...", "dropped_tensors": 333, "dropped_bytes": 921460192, "kept_bytes": 28579478528,
 // abliteration (mutated_layers was removed in the 2026-05-31 rewrite):
 "dst": "...", "probe_layer": 38, "n_layers": 64, "mutated_matrices": 196,
 "mutated_float": 196, "mutated_quant": 0, "skipped": 0,
 "attn_proj": 64, "mlp_proj": 64, "moe_proj": 0,
 "refusal_reduction": 0.98, "pre_gap": 5.1, "post_gap": 0.1,
 "was_quantized": false, "output_dtype": "source",
 // humaneval_pull:
 "seed": 132, "eval": 32,
 // self_improve_round:
 "kept": 18, "rows": 20, "pass_rate": 0.41, "train": 17, "valid": 1, "test": 1,
 // eval_pass_rate:
 "pass_at_1": 0.31, "passed": 10, "total": 32, "ms": 124400}

{"event": "error", "message": "human-readable, sourced from the exception"}
```

### Self-improvement helpers — extra event types

`self_improve_round.py` and `eval_pass_rate.py` extend the base vocabulary with
streaming per-row events so the UI can show a meaningful "Problem 7 of 20: …"
progress without polling. Consumed by
[`SelfImproveService.swift`](../MLXStudio/Services/SelfImproveService.swift).

```jsonc
{"event": "model_loaded", "ms": 14400, "with_adapter": false}

// self_improve_round only — per-prompt streaming:
{"event": "row_start",  "i": 7, "task_id": "HumanEval/12", "prompt_preview": "def has_close_elements(…)"}
{"event": "candidate",  "i": 7, "k": 0, "status": "fail", "fail_reason": "AssertionError"}
{"event": "candidate",  "i": 7, "k": 1, "status": "pass", "fail_reason": ""}
{"event": "row_done",   "i": 7, "passed": true, "passes": 1, "total": 4}

// eval_pass_rate only — one event per held-out problem:
{"event": "row", "i": 5, "task_id": "HumanEval/89", "passed": true,  "reason": ""}
{"event": "row", "i": 6, "task_id": "HumanEval/90", "passed": false, "reason": "TimeoutError"}
```

These helpers also re-emit a `start` event with `rows / candidates / model / adapter`
fields and a `done` event with `pass_at_1` (eval) or `pass_rate / kept / train / valid / test` (round).
The contracts of `start / done / error` are unchanged — see above.

### `inspect_attention.py` — Inspect tab attention capture

[`inspect_attention.py`](../MLXStudio/Resources/helpers/inspect_attention.py)
runs ONE forward pass, dumps per-layer attention for the Inspect tab's heatmap,
then exits. Consumed by
[`AttentionInspectService.swift`](../MLXStudio/Services/AttentionInspectService.swift).

CLI: `python <helpers>/inspect_attention.py --model <ABS-PATH> --prompt <text>
[--max-seq 64] [--layers all|0,5,10] [--head mean|<int>]`. `--model` must be an
absolute on-disk path (Swift resolves it). Env: `HF_HOME`, `MLXSTUDIO_MEM_LIMIT_GB`
(default 108 — self-pins MLX memory since it bypasses `mlx_run.py`), `PYTHONUNBUFFERED`.

Mechanism: monkeypatches `mx.fast.scaled_dot_product_attention` (the shared, fused
kernel that returns only the output) with a wrapper that recomputes
`softmax((Q*scale) @ Kᵀ)` with GQA head-expansion + the same mask, stashes it, then
delegates to the original (forward stays bit-identical); restores it in a `finally`.

```jsonc
{"event":"start","model":"…","model_type":"qwen3","tokens":["def"," add"],"n_layers":16,"n_heads":32,"seq_len":7,"truncated":false}
{"event":"unsupported","model_type":"gemma3n","message":"…bypasses the shared kernel"}  // then exit 0
{"event":"progress","stage":"forward"}
{"event":"layer","layer":0,"shape":[7,7],"weights":[[1.0,0.0,…],…]}   // mean-over-heads, 4dp
{"event":"done","n_layers":16}
```

Memory: attention is O(L²·heads·layers) — `--max-seq` capped at 64, heads averaged
by default, to stay under the Metal ceiling. The Inspect **Thinking** pane needs no
helper (reuses the live server's `reasoning` SSE delta via `OpenAIChatClient.stream`
+ `chat_template_kwargs:{enable_thinking:true}`); the **Weights** pane is pure-Swift
safetensors-header parsing ([`Core/SafetensorsHeader.swift`](../MLXStudio/Core/SafetensorsHeader.swift)).

### Exit codes

```
0   success
2   bad args (printed Usage)
3   missing dependency (e.g. `datasets` not installed)
4   HTTP error from HF
5   bad input file / shape
6+  helper-specific
130 keyboard interrupt
```

### Swift side parsing pattern

Every service that wraps a helper uses this pattern (see
[`DownloadService.swift`](../MLXStudio/Services/DownloadService.swift) and
[`DatasetPrepService.swift`](../MLXStudio/Services/DatasetPrepService.swift)):

```swift
_ = try await ProcessRunner.runCapturing(
    executable: python,
    arguments: [helper.path, …],
    environment: ["HF_HOME": …, "PYTHONUNBUFFERED": "1"],
    onStdout: { [weak self] line in
        Task { @MainActor in self?.handle(line: line, id: id) }
    },
    onStderr: { _ in }
)

private func handle(line: String, id: UUID) {
    guard let data = line.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return }
    switch json["event"] as? String {
    case "start":    …
    case "progress": …
    case "done":     …
    case "error":    …
    default:         break
    }
}
```

---

## 4. HuggingFace Hub API

Used by [`HuggingFaceClient.swift`](../MLXStudio/Services/HuggingFaceClient.swift).
No special SDK — plain `URLSession` with `Bearer` auth from Keychain when a token
exists.

### Endpoints

```
GET https://huggingface.co/api/models
    ?search=<query>
    [&author=mlx-community]
    [&limit=30]
    [&sort=downloads&direction=-1]
    [&full=false]
→ [HFModel]
    each: {id, author, downloads, likes, lastModified, library_name, pipeline_tag, tags}

GET https://huggingface.co/api/models/<repoID>
→ HFModelDetail
    {id, siblings: [{rfilename, size}], tags, pipeline_tag, library_name, cardData: {license, language}}

GET https://huggingface.co/api/datasets
    ?search=<query>
    [&limit=30]
    [&sort=downloads&direction=-1]
→ [HFDataset]
    {id, author, downloads, likes, lastModified, tags, cardData: {license, task_categories, language, size_categories}}

GET https://huggingface.co/api/datasets/<repoID>
→ HFDatasetDetail
    {id, siblings, tags, downloads, cardData}
```

### Dataset rows preview

We hit the public datasets-server (the same one the HF web viewer uses):

```
GET https://datasets-server.huggingface.co/rows
    ?dataset=<repoID>
    &config=default
    &split=train
    &offset=0
    &length=5
→ HFDatasetRows
    {features: [{name, type}], rows: [{row_idx, row: {col → AnyCodable}}], num_rows_total}
```

This endpoint is gated for some datasets (private / behind agreement) — we surface
"couldn't fetch rows" gracefully and let the user pick schema + columns manually.

### Auth

When a HF token is in the Keychain (`KeychainHelper.readHFToken`), it's sent as
`Authorization: Bearer <token>` on all requests. Without a token, Hub allows
unauthenticated reads at a lower rate limit; the user sees an HF banner about it
in the helper's stderr but it still works.

---

## 5. Ollama CLI

Used by [`FuseService.swift`](../MLXStudio/Services/FuseService.swift) in
`installInOllama()`.

We locate the binary by trying:
- `/opt/homebrew/bin/ollama`
- `/usr/local/bin/ollama`

Then run:

```
ollama create <tag> -f <Modelfile>
```

The Modelfile we generate has the form:

```
FROM <gguf-path>
TEMPLATE """<chat template body>"""
PARAMETER stop "<stop tokens>"
```

The TEMPLATE body comes from the user's choice of `OllamaChatTemplate` enum
(Qwen, DeepSeek, Llama 3, Phi, Mistral, raw). See `OllamaChatTemplate.modelfileBody`
for the exact strings.

---

## 6. Filesystem layout (the canonical paths)

Defined in [`PathResolver.swift`](../MLXStudio/Core/PathResolver.swift). Other code
**must** route every path lookup through here.

```
~/Library/Application Support/MLXStudio/
├── runtime/
│   ├── uv                          ← bundled uv binary (when shipped)
│   ├── .venv/                      ← uv-managed Python 3.11 venv
│   │   ├── bin/python3
│   │   └── lib/python3.11/site-packages/
│   │       ├── mlx_lm/             ← the actual mlx-lm install
│   │       ├── safetensors/
│   │       └── …
│   ├── helpers/                    ← Python scripts copied from app bundle on every launch
│   │   ├── hf_download.py
│   │   ├── prepare_coding_dataset.py
│   │   ├── download_hf_dataset.py
│   │   ├── strip_vision.py            ← mlx.core I/O (bf16-safe); Gemma-4-aware conservative path
│   │   ├── abliterate.py
│   │   ├── merge_models.py            ← model fusion (wraps mergekit)
│   │   ├── add_expert.py              ← sparse-upcycling: append cloned experts
│   │   ├── manage_experts.py          ← expert CRUD (add/remove/modify); mlx.core I/O (bf16-safe)
│   │   ├── humaneval_pull.py         ← seed + held-out eval set for Practice
│   │   ├── self_improve_round.py     ← generate → sandbox-test → write next dataset
│   │   ├── eval_pass_rate.py         ← measure pass@1 of a model + optional adapter
│   │   ├── mem_probe.py              ← Metal working-set ceiling + device facts (JSON, one-shot)
│   │   ├── model_memory.py           ← expert/non-expert byte breakdown from safetensors HEADERS
│   │   ├── profile_experts.py        ← router top-k activation histogram + cold-expert list
│   │   └── mlx_run.py                ← always-on MLX tuner (pin memory/wired/cache to the Metal ceiling → runpy the real cmd)
│   │
│   │   NOTE: any helper that rewrites weight tensors (strip_vision, manage_experts,
│   │   add_expert) MUST use mlx.core (mx.load / mx.save_safetensors with
│   │   metadata={"format":"mlx"}). The safetensors *numpy* backend cannot read
│   │   bfloat16, which is the dtype of nearly every modern model/MoE we touch.
│   └── llama.cpp/                  ← clone for non-Llama GGUF conversion (optional)
│
├── hf/                             ← HF_HOME (set in env when spawning helpers)
│   ├── models--<owner>--<name>/    ← snapshot_download(cache_dir=…) layout
│   │   ├── blobs/<sha>             ← real weight files
│   │   ├── snapshots/<rev>/        ← symlinks to blobs (the "snapshot")
│   │   └── refs/main
│   ├── hub/                        ← classic huggingface_hub layout
│   │   ├── models--<owner>--<name>/   ← created when mlx-lm runs with HF_HOME set
│   │   └── .locks/                    ← lock files
│   ├── .locks/                     ← lock files for snapshot_download path
│   ├── datasets/                   ← cached HF datasets (set by `datasets` lib)
│   │   └── <user>___<name>/
│   └── xet/                        ← chunked-transfer cache
│
├── adapters/<job-uuid>/            ← one folder per training job
│   ├── config.yaml                 ← what we passed mlx_lm
│   ├── adapter_config.json         ← mlx-lm's parameter snapshot
│   ├── adapters.safetensors        ← final LoRA weights
│   ├── 0000XXX_adapters.safetensors  ← periodic checkpoints
│   ├── training.log                ← raw stdout captured by TrainingService
│   └── job.json                    ← our sidecar for crash recovery
│
├── datasets/<dataset-uuid>/        ← prepared lessons
│   ├── train.jsonl                 ← chat schema: {"messages":[...]}
│   ├── valid.jsonl
│   └── test.jsonl
│
├── models/<custom-name>/           ← user-modified models (strip-vision, abliterate, manual imports)
│   ├── config.json
│   ├── tokenizer.json
│   ├── model-NNNNN-of-NNNNN.safetensors
│   └── model.safetensors.index.json
│
├── exports/<job-uuid>/             ← output of Save & Use
│   ├── <name>-adapter.zip          (for adapter export)
│   ├── fused/                      (for fused safetensors)
│   └── <ollama-tag>.gguf           (for GGUF export)
│
├── selfimprove/<run-uuid>/         ← one folder per Practice run
│   ├── seed.jsonl                  ← seed problems (with tests + canonical solutions)
│   ├── eval.jsonl                  ← held-out problems for pass@1 measurement
│   ├── run.json                    ← sidecar (status / round count / timestamps)
│   └── round_N/
│       ├── results.jsonl           ← per-prompt pass/fail tally
│       └── dataset/                ← passing solutions become the next-round training set
│           ├── train.jsonl
│           ├── valid.jsonl
│           └── test.jsonl
│   # Note: per-round adapters live under adapters/<round-job-uuid>/, NOT here,
│   # so they show up alongside ordinary training adapters in the Arena & Save & Use views.
│
├── skills/<skill-id>/             ← one folder per Code-tab Agent Skill (SkillStore — LIVE); folder name = stable skill id
│   ├── SKILL.md                   ← YAML frontmatter (name + description) + markdown instructions body
│   └── <optional bundled files>   ← scripts/references/assets; preserved on import; folder path handed to the agent so it can read them
│
├── agents/<role>.md               ← editable team-agent definitions (AgentStore); seeded from
│   #  orchestrator.md / planner.md / researcher.md / coder.md / ui.md  the bundle ONLY IF MISSING,
│   #  so user edits survive launches. Frontmatter + system-prompt body — see §"agent markdown format".
│
└── logs/                           ← currently unused — reserved for app-level diagnostic logs
```

The coding agent (Code tab) adds exactly **one** directory here: `skills/` (the
**Agent Skills** library — one folder per `SKILL.md` package; see [Agent Skills
(`use_skill` + the SKILL.md format)](#agent-skills-use_skill--the-skillmd-format)).
Its project/workspace folder is
user-chosen and lives *outside* Application Support; the agent is sandboxed to
that folder. New persistence is the `@AppStorage("codeWorkspacePath")`,
`@AppStorage("codeOrchestratorModel")`, and `@AppStorage("codeAdapterJobID")`
UserDefaults keys, plus `AgentSettings.useSkills` (the skills on/off toggle).

`MLXStudio/runtime/.venv/` is path-pinned (uv venvs hardcode the absolute path of
the Python interpreter in shebang lines). If the user moves the app or rename
the support dir, the venv breaks — `bootstrapIfNeeded()` would need to detect
and recreate it. Not currently implemented.

---

## 7. SwiftData schema

Defined in `MLXStudio/Models/`. SwiftData manages migration automatically. **If
you change a `@Model` field, expect existing user data to need a manual migration**
— there's no migration strategy in place yet. For now, prefer additive changes.

### `TrainingJob` (`@Model`)

```swift
id: UUID @Attribute(.unique)
name: String
statusRaw: String        // JobStatus rawValue: queued|running|completed|failed|cancelled|orphaned
configYAML: String       // snapshot of what mlx-lm received
baseModelRepoID: String  // friendly identifier for UI; absolute path resolved at run time
datasetID: UUID
adapterRelativePath: String  // = id.uuidString, relative to PathResolver.adaptersDir
pid: Int32?
startedAt: Date?
endedAt: Date?
lastIter: Int
lastLoss: Double?
lastEvalLoss: Double?
metricsBlob: Data        // JSON-encoded [TrainingStep], appended on every step
createdAt: Date
```

### `DatasetRecord` (`@Model`)

```swift
id: UUID @Attribute(.unique)
name: String
schemaRaw: String        // DatasetSchema rawValue: chat|completions|tools|text|unknown
trainRows: Int
validRows: Int
testRows: Int
relativePath: String     // = id.uuidString, relative to PathResolver.datasetsDir
createdAt: Date
notes: String
```

### `SelfImproveRun` (`@Model`)

```swift
id: UUID @Attribute(.unique)
name: String
baseModelRepoID: String
seedRaw: String              // SelfImproveSeed rawValue: humaneval | mbpp-sanitized
statusRaw: String            // SelfImproveStatus rawValue: queued|generating|testing|training|evaluating|completed|failed|cancelled
targetRounds: Int
candidatesPerPrompt: Int
rowsPerRound: Int            // 0 = all
trainIters: Int              // per round
startedAt: Date?
endedAt: Date?
roundsBlob: Data             // JSON-encoded [SelfImproveRoundRecord], appended each round
baselinePassAtOne: Double?
lastError: String?
createdAt: Date
```

`SelfImproveRoundRecord` (embedded as JSON, NOT a `@Model`):

```swift
id: UUID
roundNumber: Int                 // 1-based
startedAt: Date
endedAt: Date?
candidatesPerPrompt: Int
rowsAttempted: Int
rowsKept: Int                    // # prompts where ≥1 candidate passed
totalCandidates: Int             // = rowsAttempted * candidatesPerPrompt
totalPasses: Int
datasetRelativePath: String      // selfimprove/<run-uuid>/round_N/dataset
adapterRelativePath: String      // adapters/<round-job-uuid>
roundJobID: UUID                 // matches the directory under adapters/
evalPassAtOne: Double?           // pass@1 measured against eval.jsonl after training this round
notes: String
```

A `run.json` sidecar is written at `selfimprove/<uuid>/run.json` for crash
inspection (same pattern as `TrainingJob.writeSidecar`).

### `AgentProfile` (`@Model`)

One per saved Code-tab agent. Additive entity (consistent with the additive-only
stance above); registered in `MLXStudioApp`'s `modelContainer(for:)` list.

```swift
id: UUID @Attribute(.unique)
name: String
emoji: String
detail: String
modelRepoID: String          // friendly identifier; absolute path resolved at run time
adapterJobID: UUID?          // optional completed TrainingJob whose adapter to attach
instructions: String         // appended to the agent's system prompt
autoApproveEdits: Bool
autoRunCommands: Bool
useNativeTools: Bool
temperature: Double
maxTokens: Int
maxIterations: Int
enabledSkillIDs: [String]     // legacy per-agent skill ids — SUPERSEDED by SkillStore; per-agent scoping now lives in the agent's `skills:` frontmatter, not here
createdAt: Date
```

A computed `agentSettings: CodingAgentService.AgentSettings` bridges the
toggles + sampling fields into the value type the agent loop consumes.

### `LocalModel` (`@Model`) and `AppSettings` (`@Model`)

Currently defined but underused. Keep them; we'll need them when:
- LocalModel: persistent per-model preferences (favorite, alias, last-used adapter)
- AppSettings: a single settings record for app-wide preferences (HF token ref, default base, theme)

---

## 8. Notification.Name extensions (cross-tab events)

Declared next to the views that send them, listened-to in
[`RootView.swift`](../MLXStudio/App/RootView.swift). Adding a new one is fine; just
keep them sparse — see [`CONVENTIONS.md`](CONVENTIONS.md).

Current set:

```swift
// DashboardView
Notification.Name("MLXStudio.switchSidebar")        // object: SidebarSection
// TrainingConfigView
Notification.Name("MLXStudio.switchToMonitor")      // no payload
// ModelDetailView
Notification.Name("MLXStudio.openTrainingWithModel") // object: String (repoID)
Notification.Name("MLXStudio.openChatWithModel")    // object: ModelHandoff OR String (see below)
// LoopHandoff.swift
Notification.Name("MLXStudio.openCodeWithModel")    // object: ModelHandoff OR String (see below)
```

These carry the **feedback-loop hand-off** — moving a fine-tuned model (+adapter)
from the stage that produced it to the next tab so the user never copies a disk path
by hand. See [`CONCEPT.md`](CONCEPT.md#the-edges--how-the-artifact-moves-between-stages)
for the full edge map.

#### `ModelHandoff` (the hand-off payload)

Declared in [`LoopHandoff.swift`](../MLXStudio/Core/LoopHandoff.swift):

```swift
struct ModelHandoff: Sendable {
    let model: String          // base model repo ID or local name
    let adapterPath: String?   // absolute path to the LoRA adapter dir, if any
}
```

**Dual-payload contract.** Receivers of `.openChatWithModel` and
`.openCodeWithModel` accept **either** a `ModelHandoff` (model + adapter) **or** a
bare `String` (model only), so older posters that send just a repo ID keep working:

```swift
if let h = note.object as? ModelHandoff { /* model + adapter */ }
else if let model = note.object as? String { /* model only */ }
```

Posters & receivers (all user-driven CTAs — completion never auto-switches tabs):

| Notification | Posted by (CTA) | Object | Received by |
|---|---|---|---|
| `.openChatWithModel` | Progress completion card / Arena decision bar / Practice "Use this fine-tune" / `ModelDetailView` "Open in Chat" | `ModelHandoff` (the new posters) or `String` (`ModelDetailView`) | `RootView` → `.chat`; `ArenaView` pre-fills model + adapter |
| `.openCodeWithModel` | Progress completion card / Arena decision bar / Practice "Use this fine-tune" | `ModelHandoff` (or `String`) | `RootView` → `.code`; `CodeView.applyHandoff` pre-fills model + adapter |

`.openCodeWithModel` is the edge that lets the Code tab load a **fine-tuned** adapter
(previously its `MLXServerService` was started with `--adapter-path nil`).

The coding agent (Code tab) otherwise talks to its services directly. Its persisted
state is the `@AppStorage("codeWorkspacePath")`, `@AppStorage("codeOrchestratorModel")`
and `@AppStorage("codeAdapterJobID")` (the loop-selected adapter job) UserDefaults
keys plus the `AgentProfile` SwiftData entity (see §6, §7).

---

## 9. Local OpenAI-compatible chat API + agent tool protocol

The Code tab talks to the local `mlx_lm server` (see §1) over the OpenAI chat
subset, and runs a tool-use loop on top of it. Both halves are contracts the agent
depends on. Consumers: [`OpenAIChatClient.swift`](../MLXStudio/Services/OpenAIChatClient.swift),
[`AgentTools.swift`](../MLXStudio/Services/AgentTools.swift),
[`CodingAgentService.swift`](../MLXStudio/Services/CodingAgentService.swift).

### Request / response (the OpenAI subset we use)

`POST {baseURL}/v1/chat/completions`. The agent loop **streams** (`stream: true`)
via `OpenAIChatClient.stream`, parsing SSE `chat.completion.chunk` frames
(`choices[0].delta.content` + accumulated `delta.tool_calls`, terminated by
`data: [DONE]`) so assistant text shows live; `complete` (below, `stream: false`)
is still used for the server warm-up. Request shape:

> **Reasoning ("thinking") models** (Gemma-4, Qwen3-thinking, DeepSeek-R1…) stream
> their chain-of-thought in a **separate `choices[0].delta.reasoning`** field — NOT
> `content` — and `content`/`tool_calls` stay null until the think block closes
> (they can think for 1000s of tokens). `OpenAIChatClient` parses `delta.reasoning`
> into a `ChatStreamEvent.reasoningDelta` (shown as a dimmed "💭 Thinking" block);
> without that the agent turn looks empty and the loop ends. If you touch the SSE
> parser, keep reading `reasoning`.
>
> **Disabling thinking for agent work.** Thinking models over-think and often never
> emit a tool call. mlx-lm's server forwards a request field **`chat_template_kwargs`**
> straight into `apply_chat_template`, and these models' templates honor
> **`enable_thinking`**. The Code agent sends
> `"chat_template_kwargs": {"enable_thinking": false}` on every role request (toggle:
> Options → "Let the model think first") so the model acts directly. Verified: with
> `enable_thinking:false`, `gemma-4-26b-a4b` returns `finish_reason: tool_calls` and a
> real delegation instead of an endless think. Harmless for non-thinking templates
> (the kwarg is simply unused).

```jsonc
// request
{"model": "<served model>",
 "messages": [{"role": "system"|"user"|"assistant"|"tool", "content": "…",
               // assistant turns may carry tool calls:
               "tool_calls": [{"id": "…", "type": "function",
                               "function": {"name": "read_file", "arguments": "{…}"}}],
               // tool results come back to the model as:
               "tool_call_id": "…", "name": "read_file"}],
 "tools": [ /* ChatToolSpec array, see below */ ],
 "temperature": 0.2, "max_tokens": 2048, "stream": false}
```

A tool **result** is sent on the next request as a message with
`role:"tool"`, `tool_call_id` (matching the call), `name` (the tool), and
`content` (the tool output). This is the native path.

### Native vs fallback tool-calling caveat

mlx-lm parses tool calls out of the model's **generated text** using the
tokenizer's chat template + `tool_parser`. So native `tool_calls` only come back
for models whose tokenizer template is tool-aware (Qwen, Llama-3.1+, …). Other
models leave `tool_calls` empty and put their intent in `content` — which is why
`CodingAgentService` also ships a text fallback. **Verified**: Qwen3.6-27B-bf16's
template renders the `tools=` kwarg and emits `<tool_call>` markers, so the
fallback format below intentionally matches Qwen's native emission and doubles as
a safety net.

### Agent tool-call / tool-result text protocol (the fallback)

When `useNativeTools` is off, or the model can't emit native `tool_calls`, the
system prompt instructs the model to emit calls as text, and the agent parses them
with `AgentTools.parseFallbackCalls(from:)`:

```
<tool_call>{"name": "read_file", "arguments": {"path": "src/main.swift"}}</tool_call>
```

(a bare or ```` ```json ```` ``` ````-fenced JSON object is also accepted, and
`"parameters"` is accepted as an alias for `"arguments"` — some models emit that).
On this path tool results are fed back as **one** `role:"user"` message containing
one block per result (plain chat templates don't understand a `tool` role):

```
<tool_result name="read_file">…file contents (truncated to 16000 chars)…</tool_result>
```

The toolset (`AgentToolName`): `read_file`, `list_dir`, `glob`, `grep`,
`web_search`, `fetch_url` (read-only, auto-run), `write_file`, `edit_file`,
`run_command` (mutating, approval-gated), `ask_user`, `use_skill` and `todo_write`
(read-only, auto-run — see below). `glob(pattern)` finds files by `*`/`**`/`?`
pattern (no `/` ⇒ matches basename, else the project-relative path). `edit_file`
takes an optional `replace_all: "true"` to replace every occurrence. `run_command`
runs `/bin/zsh -lc <cmd>` with the workspace as cwd, a 120 s watchdog, and
16000-char output truncation; every path arg is checked against the workspace
sandbox. **Each role advertises only its own subset** — see the team graph below;
`AgentTools.specs(for:)` builds the `tools` array from a role's tool list.

`web_search(query)` and `fetch_url(url)` are the Researcher's web tools (→
`WebSearch`, no API key — DuckDuckGo HTML scrape + page-to-text). `ask_user(question)`
lets any role pause and ask the user; it is **intercepted by the orchestration engine,
not the executor** (it resolves through `pendingQuestion` + `answerUser`).
`ask_user` takes an **optional `options`** argument so a role can offer the user
fixed choices (buttons) instead of only free text. Because `ChatToolProperty` is
string-only, `options` is documented to the model as "a JSON array of 2–5 short
labels, e.g. `[\"Postgres\",\"SQLite\",\"MySQL\"]`". `CodingAgentService.parseOptions(_:)`
parses it leniently — a JSON array, or a fallback split on newlines / `|` / commas —
then dedups and caps at 6. `UserQuestion` carries the parsed `options: [String]`;
`CodeView`'s `questionBar` renders one button per option (clicking calls
`answerUser(option)` to steer the run) plus an "Or type your own answer…" free-text
fallback. A free-text question (no `options`) is unchanged.

`todo_write(todos)` records a role's plan — `todos` is a JSON array (or a JSON
string holding one) of `{content, status}` where status ∈ `pending | in_progress |
completed`. It updates the in-app plan panel only (never the workspace) and is
intercepted in `CodingAgentService`, not the executor.

### The Orchestrator team + delegation tools

The Code tab runs a **fixed five-role team** (`TeamRole`: orchestrator, planner,
researcher, coder, ui — see [`AgentRoles.swift`](../MLXStudio/Services/AgentRoles.swift)).
Roles call each other through **delegation tools** named `call_<role>(task)`, each
taking one `task` string (the callee does **not** see the caller's conversation).
Like `ask_user` / `todo_write`, delegation calls are **intercepted by the
orchestration engine, not `ToolExecutor`** — a `call_<role>` runs a nested role
loop and returns its final answer as the tool result.

Delegation graph (who may call whom):

```
orchestrator → call_planner, call_researcher, call_coder, call_ui
planner      → call_researcher
researcher   → (none)
coder        → (none)         # builders don't delegate
ui           → (none)
```

When the Orchestrator emits **>1 `call_*` in a single turn**, those sub-agents run
**concurrently** (interleaving on the one shared model server) — unless the user
turns off `AgentSettings.parallelAgents` (Options → "Run teammates in parallel"),
in which case they run **one at a time** (for smaller models). Delegation depth is
**capped at 5**; past that the call returns "Delegation depth limit reached."
**One shared `mlx_lm` model serves all five roles** (one `MLXServerService`
daemon) — there is no per-role model.

For `write_file` / `edit_file`, the executor also returns a UI-only
`ToolResult.displayDetail` (a colored `- / +` diff) and exposes `previewDiff(...)`
so the diff is shown on the tool card *before* the user approves the change — it's
never sent back to the model (only the concise `output` is). The model's system
prompt also receives a short top-level workspace listing for grounding. See
[`CONVENTIONS.md`](CONVENTIONS.md#the-coding-agent-code-tab) for the safety model.

### Agent Skills (`use_skill` + the SKILL.md format)

The team supports **Agent Skills** — reusable instruction packages modeled on the
OpenAI Codex / Anthropic Agent Skills standard. A skill is a folder under
`skills/<skill-id>/` (see §6) holding a `SKILL.md` file plus optional bundled
files (scripts / references / assets):

```
---
name: <display name>
description: <one-line summary of when to use this skill>
skills: [other-skill-id]   # optional — skill→skill links (alias: links:)
---

<markdown instructions body>
```

- **Frontmatter** keys: `name`, `description`, and an optional `skills:` (alias
  `links:`) list of **other skill ids this skill links to** (skill→skill). Parsed
  into `Skill` / `SkillContext.links: [String]`.
- **Fences are `---`.** A line consisting only of em-dash (`—`, U+2014) or en-dash
  (`–`, U+2013) characters is auto-normalized to `---` on parse
  (`SkillStore.normalizeFences`, run by both `SkillStore.parse` and
  `AgentStore.parse`), so a file whose fences got smart-substituted by an editor
  still loads. Real `---` and body horizontal rules are unaffected.
- **Skill→skill links** surface to the agent: `use_skill` appends the linked skills'
  names+descriptions ("Related skills you can also load with use_skill: …"), and a
  skill linked from an in-scope skill is itself offered (transitive). Deleting a
  skill **scrubs** its id from every other skill's links (no danglers).

The **folder name is the skill's stable id**. Renaming a skill rewrites the
frontmatter but keeps the folder. Any other files in the folder are preserved on
import; the folder path is handed to the agent (via `SkillContext.dirPath`) so it
can read them.

**Three-stage progressive disclosure** (the core of the spec):

1. **Discovery** — `CodingAgentService.systemMessage` appends ONLY each skill's
   `name: description` to every agent's system prompt under a
   `## Skills available to you` heading. Just enough for the model to know *when*
   to reach for one.
2. **Activation** — when ≥1 skill exists and `AgentSettings.useSkills` is on,
   `runRole` adds the `use_skill` tool. The agent calls `use_skill(name)` and
   `ToolExecutor.useSkill` returns the FULL instructions body plus the skill's
   folder path:

   ```
   use_skill(name)   →  returns the named skill's SKILL.md instructions body
                        + its folder path (or an error listing the skill names)
   ```
3. **Execution** — the agent follows the loaded instructions, optionally reading
   bundled files from the folder path.

`use_skill` is read-only (auto-approved). The executor is given
`SkillStore.shared.skills.map(\.context)` (each a `SkillContext` with `name`,
`description`, `dirPath`) when `useSkills` is on, so the handler can resolve a
name to its instructions.

**Seeding.** `SkillStore.installDefaultsAndScan()` runs at launch from
`MLXStudioApp`'s `.task`. It scans `skillsDir` and, on the very first launch only
(guarded by the `didSeedExampleSkills` `UserDefaults` flag so deletions don't
reappear), seeds two instruction-only example skills: `conventional-commits` and
`code-reviewer`.

Skills are **team-global by default** — an agent with no `skills:` frontmatter sees
the whole catalogue (matching the implicit-by-description model in Codex /
Anthropic). An agent can **opt into a subset** via its `agents/<role>.md` `skills:`
frontmatter (skill→agent link; see the agent-markdown format below): **`nil` (key
absent) = ALL skills, `[]` = none, a list = exactly those**.
`CodingAgentService.availableSkills(for: role)` scopes BOTH the discovery list AND
`use_skill` availability accordingly (following transitive skill→skill links). This
supersedes the old per-agent `enabledSkillIDs` on the dead `AgentProfile`. They are
local Markdown files with no network dependency.

### Agent markdown file format (team agents)

The five Code-tab roles (orchestrator, planner, researcher, coder, ui) are
defined by one Markdown file each — bundled at `MLXStudio/Resources/agents/<role>.md`
and seeded into `~/Library/Application Support/MLXStudio/agents/` (`PathResolver.agentsDir`)
by [`AgentStore`](../MLXStudio/Services/AgentStore.swift). The copy happens **only if
the file is missing** — unlike the Python helpers (refreshed every launch), agent
files are seeded once so **user edits persist across launches**. `TeamRole` reads
the parsed result from `AgentStore.overrides[<role>]`; each field falls back to a
compiled-in default when the file or field is absent — so the markdown is
authoritative, the Swift defaults are the fallback.

Each file is YAML-ish frontmatter + a system-prompt body:

```markdown
---
id: coder                                          # role raw value (orchestrator|planner|researcher|coder|ui)
name: Coder                                        # display name → TeamRole.displayName
emoji: 💻                                           # → TeamRole.emoji
tint: green                                        # color name (purple|blue|teal|green|orange) → TeamRole.tint
tools: [read_file, list_dir, glob, grep, write_file, edit_file, run_command, todo_write]
delegates: []                                      # role ids this role may call, e.g. [planner, researcher, coder, ui]
maxIterations: 28                                  # Int — the role's loop cap
skills: [conventional-commits]                     # optional — skill ids this agent may use (skill→agent link)
---
You are the CODER, a builder on the team. …        # body = the role's system-prompt "character"
```

Format rules (parsed by `AgentStore.parse`):

- **Frontmatter** is between the first two `---` lines. Keys: `id`, `name`,
  `emoji`, `tint`, `tools`, `delegates`, `maxIterations`, and an optional `skills:`.
  Lists (`tools`, `delegates`, `skills`) accept inline `[a, b, c]` or bare
  comma-separated; an explicit empty `[]` means "none" (distinct from an absent
  key → default).
- **`tools`** populates the role's `baseTools` (names from `AgentToolName`);
  unknown tool names are dropped. **`delegates`** lists the role ids it may call;
  the `call_<role>` delegation specs are still appended in code (`toolSpecs()`).
- **`skills`** is the **skill→agent link**: which skills this agent may use. Key
  **absent → ALL skills** (the default, team-global behavior); **`[]` → none**; a
  list → exactly those (plus their transitive skill→skill links). Parsed into
  `AgentDefinition.skills: [String]?`, exposed by `TeamRole.skillIDs`, and read by
  `CodingAgentService.availableSkills(for:)`.
- **Fences are `---`**; em-dash/en-dash-only fence lines are auto-normalized to
  `---` on parse (`AgentStore.parse` runs input through `SkillStore.normalizeFences`),
  so a smart-substituted file still loads.
- **Body** (everything after the closing `---`) is the role's system-prompt
  header — what used to be the hardcoded `header`. The project folder, workspace
  overview, and tool-calling footer are **still appended in code** (consistent
  across all roles), so the body is just the role's "character".
- A file with no frontmatter is treated as an all-body prompt. A missing or
  unparseable file → the role uses its compiled-in defaults.

The editor is [`AgentsManagerView`](../MLXStudio/Features/Code/AgentsManagerView.swift)
(Code tab → Options → "Edit team agents…"): edit the raw markdown, **Save** (writes
the file + reloads `AgentStore` so the next run obeys it), **Reset to default**
(re-copies the bundled version), **Show in Finder**. It edits the raw markdown via
the substitution-disabled `MarkdownEditor` (so `---` fences stay `---`); ＋ New
creates a role file immediately (rename via the `name:` line). This markdown-agent
system is **separate** from the dead `AgentProfile` (the removed single-agent
library; `AgentEditorView` was deleted); `SkillStore` / Agent Skills, by contrast,
are **live** (see the Agent Skills subsection above) and apply team-globally by
default (an agent's `skills:` frontmatter can scope them to a subset).
