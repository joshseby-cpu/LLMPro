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
into the app's bundled venv at `~/Library/Application Support/LLMPro/runtime/.venv/`.

### `mlx_lm lora` — training

Used by [`TrainingService.swift`](../LLMPro/Services/TrainingService.swift).

Invocation:
```
python -m mlx_lm lora -c <config.yaml>
python -m mlx_lm lora -c <config.yaml> --resume-adapter-file <latest.safetensors>
```

Config-file keys we generate (see [`AutoTuner.swift`](../LLMPro/Services/AutoTuner.swift)
and `TrainingConfig.renderYAML()` in [`TrainingService.swift`](../LLMPro/Services/TrainingService.swift)):

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

Regex in [`LogStreamParser.swift`](../LLMPro/Core/LogStreamParser.swift):

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

Appended by **two** paths in [`TrainingService.swift`](../LLMPro/Services/TrainingService.swift):

- `resume(job:, latestAdapterFile:, context:)` — crash-recovery resume of an
  *orphaned* job from its last checkpoint.
- `start(job:, context:, resumeAdapterFile: URL? = nil)` — the optional
  `resumeAdapterFile:` is the feedback loop's **refine-from-adapter** edge: Teach's
  "Continue a previous fine-tune?" picker calls `launchRefine(from:)`, which reuses
  the source job's config (swapping only `adapter_path`) and passes the source's
  `adapters.safetensors` here so mlx-lm continues from those weights. Reusing the
  exact config keeps the LoRA architecture resume-compatible. When `nil` (the
  default, a fresh fine-tune) no flag is appended.

### `mlx_lm_lora.train` — DPO preference training (separate package)

Used by [`TrainingService.swift`](../LLMPro/Services/TrainingService.swift) when a
job's `trainMode == .dpo` (the **"Teach by preference"** loop — see the
`DatasetSchema.preference` and `PreferenceHandoff` entries below). **Verified live
end-to-end** on `qwen2.5-0.5b-instruct-mlx` (a Quick DPO run, 66/66 iters, real DPO
loss lines, `adapters.safetensors` 22 MB + checkpoints written, `job.json`
`status: completed`).

**The installed `mlx-lm` (0.31.3) has NO DPO trainer.** DPO runs through a *separate*
package, **`mlx-lm-lora` (v2.1.0)**, installed **on-demand** like mergekit
(`PythonRuntime.dpoTrainerInstalled()` / `installDPOTrainer()`; it's also in the
`bootstrap()` pip list, but its absence does **not** gate the `.ready` state — a DPO
launch installs it lazily if missing). Invoked as a module, not a subcommand:

```
python -m mlx_lm_lora.train \
  --train-mode dpo \
  --model <HF-repo-id-or-absolute-path> \
  --data <dataset-directory> \           # contains train.jsonl + valid.jsonl
  --adapter-path <absolute-dir> \
  --iters N --batch-size B \
  --beta 0.1 --dpo-cpo-loss-type sigmoid \
  --gradient-accumulation-steps 1 \
  -c <config.yaml>                        # None-default / nested keys only — see gotcha
```

#### ⚠️ CRITICAL gotcha: CLI flags vs `-c config.yaml` (NOT interchangeable)

`mlx_lm_lora.train` merges a `-c config.yaml` into argparse **only for args that are
still `None`**:

```python
if getattr(args, k, None) is None:
    setattr(args, k, yaml_value)
```

So any arg whose argparse default is **non-`None`** silently **IGNORES the YAML** and
keeps the argparse default. The DPO-controlling args all have non-`None` defaults —
notably **`--train-mode` (default `"sft"`)**, **`--beta`**,
**`--dpo-cpo-loss-type`**, and **`--gradient-accumulation-steps`**. Putting
`train_mode: dpo` (etc.) in the YAML does nothing — the run trains **SFT**.
Therefore `TrainingService` passes the DPO-controlling hyperparameters as **CLI
flags** AND still passes `-c config.yaml` for the keys that *do* have `None`/nested
defaults (`lora_parameters`, `lr_schedule`, learning rate, layers, seq length, and
`fuse: false`). Treat this as the rule: **DPO knobs → CLI flag; LoRA-shape / schedule
/ nested keys → YAML.**

**`fuse: false` is REQUIRED.** `mlx_lm_lora`'s `fuse` defaults **true**, which would
fuse the adapter and dump a full **~1.3 GB `model.safetensors`** into every
`adapter_path` dir on completion. We want a plain LoRA adapter that flows back
through the loop, so the generated YAML sets `fuse: false`.

#### DPO dataset schema + `--data` convention

The DPO dataset directory holds `train.jsonl` + `valid.jsonl` (the same
`datasets/<uuid>/` dir as any lesson), but each line is a **preference pair**, not a
chat row:

```jsonc
{"prompt": "<user prompt>", "chosen": "<preferred answer>", "rejected": "<worse answer>"}
{"prompt": "…", "chosen": "…", "rejected": "…", "system": "<optional system prompt>"}
```

`system` is optional. This is the on-disk form of the new `DatasetSchema.preference`
case (see §7); the rows are written by
[`PreferenceService.swift`](../LLMPro/Services/PreferenceService.swift)
(`appendPair(prompt:chosen:rejected:system:to:context:)`, atomic append + de-dup,
bumps `DatasetRecord.trainRows`) and `splitForTraining(dataset:)` carves ~10% of
`train.jsonl` into `valid.jsonl` at launch.

#### ⚠️ Batch-size MUST be clamped to `min(trainRows, validRows)`

`mlx_lm_lora`'s `iterate_dpo_batches` **HANGS** (infinite 100%-CPU spin, the process
never exits) when `batch_size > number-of-rows` in either split. `TrainingService`
reads the on-disk row counts of `train.jsonl`/`valid.jsonl` and clamps
`--batch-size` to `max(1, min(trainRows, validRows))` before launching (verified
live: a 4→1 clamp on a 3-train/1-valid split). Never pass an unclamped AutoTuner
batch size to the DPO trainer.

#### Output + memory

Output under `adapter_path` is a standard **`adapters.safetensors`** (+
`adapter_config.json` + periodic `NNNNNNN_adapters.safetensors` checkpoints) — the
exact shape an `mlx_lm lora` job produces, so the adapter is interchangeable in
Progress / Try-it-out / Save & Use with no special-casing. The DPO trainer holds a
**second full frozen reference copy** of the model, so peak memory is **~2× the base
model** (AutoTuner's `tuneDPO` accounts for this in its memory estimate).

#### DPO stdout / loss-line format

The DPO training line differs from the SFT `Iter N: Train loss …` line:

```
# DPO training line:
Iter N: loss X.XXX, chosen_r …, acc …, margin …, lr …, tok/s …, peak_mem …GB

# DPO eval line (same shape as SFT's val line):
Iter N: Val loss F, Val took Ts
```

`LogStreamParser` gained a DPO regex anchored on `: loss ` (so it can NOT match the
SFT `Train loss` / `Val loss` lines):

```regex
# DPO train:
Iter (\d+): loss ([\d.]+)

# DPO eval reuses the existing SFT val regex:
Iter\s+(\d+):\s+Val\s+loss\s+([\d.]+)
```

This drives the Progress chart + star rating for DPO runs exactly as the SFT train
line does for ordinary fine-tunes.

#### Abnormal-exit hardening

The training exit handler was hardened so abnormal termination (signal / crash /
stdout-stream close) always transitions the job to `.failed` rather than leaving it
stuck `.running` — relevant because the `iterate_dpo_batches` hang above was the
original way a DPO job could wedge.

### `mlx_lm generate` — inference

Used by [`InferenceService.swift`](../LLMPro/Services/InferenceService.swift).

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

**Diffusion models do NOT go through this path.** A `model_type: diffusion_gemma`
checkpoint (Google's DiffusionGemma — a masked/block-diffusion LM with no
autoregressive mlx-lm class) is detected by `ModelRegistry.DetectedModel.isDiffusion`
and routed by `InferenceService.stream` to the vendored `diffusion_generate.py`
helper instead of `mlx_lm generate` (see [§3 `diffusion_generate.py`](#diffusion_generatepy--diffusiongemma-inference-non-mlx-lm)).
`mlx_lm generate`/`server`/`lora` **cannot run a diffusion LM**, so these models are
non-fine-tunable "guests": chat works here, the **Code** tab works via the vendored
`diffusion_server.py` (agentic, experimental — see that subsection), and only Teach /
Practice / DPO exclude them.

**`--model` is resolved to an absolute path for local models (Arena fix).**
`InferenceService.stream` now resolves a **bare local-model name** (a custom
`models/<name>` from GGUF import / strip-vision / abliterate / trained-and-saved) to
its **absolute on-disk path** before invoking `mlx_lm generate` — mirroring the
training (`TrainingConfigView.resolveModelArg`), eval (`EvalService`), and server
(`MLXServerService`) resolvers. Previously the Arena passed the bare name through, and
because mlx-lm treats a string with no `/` as an HF repo id, any local custom model
failed with "exited with code 1". **HF repo ids (containing `/`) still pass through
unchanged.** See [`CONVENTIONS.md`](CONVENTIONS.md#local-model-paths-must-be-resolved-before-being-passed-to-mlx-lm).

### GGUF export pipeline (fuse → convert → quantize → self-test)

Used by [`FuseService.swift`](../LLMPro/Services/FuseService.swift). The Save & Use
adapter export and the per-model "Export to GGUF" share one converter
(`convertDirToGGUF`) + one self-test (`verifyGGUF`). The pipeline:

1. **Fuse** (adapter export only) — merge the LoRA and **dequantize** to an HF
   checkpoint the converter can read (an MLX-quantized base is affine
   `.scales`/`.biases`, NOT an HF/llama.cpp quant format):
   ```
   python -m mlx_lm fuse --model <base> --adapter-path <dir> --save-path <out> --dequantize
   ```
   (`FuseService.fuse(dequantize: true)`. The plain "Fused safetensors" export keeps
   the default, no `--dequantize`.) We no longer use mlx_lm's `--export-gguf` (it
   hardcodes `general.architecture=llama` and refuses quantized inputs).
2. **Convert** HF dir → GGUF via llama.cpp's `convert_hf_to_gguf.py`:
   ```
   python convert_hf_to_gguf.py <dir> --outfile <gguf> --outtype {f16|bf16|q8_0} [--no-mtp]
   ```
   `--outtype` only accepts `f32/f16/bf16/q8_0/tq1_0/tq2_0/auto` — NOT k-quants.
3. **Quantize** (k-quants only) — base type is `f16`, then the compiled
   `llama-quantize` makes the k-quant and the temp f16 is deleted:
   ```
   <build/bin>/llama-quantize <f16.gguf> <out.gguf> {Q4_K_M|Q5_K_M|Q6_K} <nthreads>
   ```
4. **Self-test** (`verifyGGUF`) — run the GGUF and require coherent UTF-8 before
   declaring success ("a green UI is not a pass"):
   ```
   <build/bin>/llama-completion -m <gguf> -p "The capital of France is" -n 24 -st -ngl 999 --no-warmup --temp 0
   ```
   Fails the export if the output is empty or contains U+FFFD (the hybrid-arch
   garbage signature). **NOTE**: this llama.cpp split completion out of `llama-cli`
   (which now rejects `-no-cnv`) — use `llama-completion`.

`llama-quantize` + `llama-completion` are built from source by
`PythonRuntime.buildLlamaCppTools` (cmake `-DGGML_METAL=ON -DLLAMA_CURL=OFF`, targets
`llama-quantize llama-completion`) into `runtime/llama.cpp/build/bin/`. The Python
`convert_hf_to_gguf.py` alone (f16/bf16/q8_0) needs only `installLlamaCpp`.

**Architecture limitation (hard block)**: converting the **MLX build** of a hybrid
Qwen3.5/3.6 (`qwen3_5`, Gated-DeltaNet linear-attention + MTP) is broken — MLX bakes
Qwen3-Next's zero-centered RMSNorm `+1` shift into the saved weights and
`convert_hf_to_gguf.py` (conversion/qwen.py) applies `+1` again → ~2× wrong norms →
garbled output. (llama.cpp's *runtime* runs `qwen35` GGUFs fine; it's the MLX→convert
input that's wrong.) `FuseService.ggufRoundTripWarning` detects these archs and both
export UIs hard-block them. Standard archs (llama/qwen2.5/gemma2/mistral/phi3/qwen3-dense)
convert + run correctly — validated end-to-end: MLX → f16 → Q4_K_M → self-test coherent.

### App-support JSON side-stores (no SwiftData)

User-authored metadata that doesn't belong in the SwiftData schema lives as small
Codable JSON files directly under `~/Library/Application Support/LLMPro/`. All
follow one pattern: `@MainActor @Observable final class` singleton, `load()` on
init, atomic write on every mutation. Adding one does NOT touch
`LLMProApp.modelContainer`.

| File | Store | Contents |
|---|---|---|
| `system_prompt_presets.json` | `SystemPromptPresetStore` | custom chat personas (built-ins are code constants) |
| `prompt_library.json` | `PromptLibraryStore` | custom reusable prompts for Try it out |
| `favorites.json` | `FavoritesStore` | pinned model ids + dataset UUIDs |
| `model_meta.json` | `ModelMetaStore` | per-model notes + tags, keyed by `DetectedModel.id` |
| `training_presets.json` | `TrainingPresetStore` | saved `TrainingConfig` recipes (per-run model/data/adapter stripped on apply) |

### "Host to the cloud" export (HF safetensors)

`ExportTarget.cloud` in Save & Use: `mlx_lm fuse --dequantize` into
`exports/<id>/cloud/` (full-precision HF layout — what vLLM/TGI/SGLang serve
directly) + a generated `README.md` (`ModelCardBuilder.cloudREADME`) with the
exact serve commands. Arch-agnostic; this is the supported path for hybrid
architectures (Qwen3.5/3.6) whose MLX→GGUF conversion is blocked.

### `mlx_lm convert` — quantize HF model to MLX format

Used by [`ConversionService.swift`](../LLMPro/Services/ConversionService.swift).

```
python -m mlx_lm convert \
  --hf-path <repo-or-path> \
  --mlx-path <out-dir> \
  [-q --q-bits {4,8} --q-group-size 64]
```

### `mlx_lm server` — long-lived OpenAI-compatible server

Used by [`MLXServerService.swift`](../LLMPro/Services/MLXServerService.swift) as
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

**Diffusion models are NOT served by `mlx_lm server`.** `mlx_lm server` has no class
for a `model_type: diffusion_gemma` checkpoint, so `MLXServerService.start` branches
on `ModelRegistry`'s `isDiffusion` flag and launches the vendored
**[`diffusion_server.py`](#diffusion_serverpy--long-lived-openai-compatible-diffusion-server-code-tab)**
(also via `mlx_run.py`) instead — same free-port / `/health` / warm-up / state
machine, so `OpenAIChatClient` + `CodingAgentService` are unchanged. `--adapter-path`
is dropped for diffusion (no LoRA). See §3 `diffusion_server.py`.

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

All Python helpers in [`LLMPro/Resources/helpers/`](../LLMPro/Resources/helpers/)
follow the same conventions so Swift can parse them uniformly.

### Invocation

```bash
python <helper>.py <required-args...> [optional-args...]
```

Swift side: spawn via [`ProcessRunner.swift`](../LLMPro/Core/ProcessRunner.swift)
with `PYTHONUNBUFFERED=1` in the environment so output flushes line-by-line.

**⚠️ HF token travels via the `HF_TOKEN` env var, NOT argv (2026-06-13 audit).** The
two HF-authenticated helpers — [`hf_download.py`](../LLMPro/Resources/helpers/hf_download.py)
and [`prepare_coding_dataset.py`](../LLMPro/Resources/helpers/prepare_coding_dataset.py)
— now receive the HuggingFace token through the **`HF_TOKEN` environment variable**
(set by Swift's `DownloadService` / `DatasetPrepService` from the Keychain via
`KeychainHelper.readHFToken`), so the secret never appears in the process argv / `ps`
output. The Python reads `os.environ.get("HF_TOKEN")`; a **positional argv token is a
deprecated fallback** kept only for backward compatibility. New invocation shape:

```bash
HF_TOKEN=<token> python hf_download.py <repo_id> <cache_dir>
HF_TOKEN=<token> python prepare_coding_dataset.py <preset_id> <output_dir> [max_rows]
```

Don't reintroduce the token as a positional argument — pass it in the environment.

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
- Env overrides: `LLMPRO_MEMORY_LIMIT_BYTES=<N>` (the Memory-tab budget, wins
  over the auto memory limit), `LLMPRO_CACHE_LIMIT_BYTES=<M>`, and
  `LLMPRO_NO_AUTOTUNE=1` (skip all tuning, use stock MLX defaults).

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
 // eval_pass_rate (k==1; pass_at_1 == pass_at_k):
 "pass_at_1": 0.31, "pass_at_k": 0.31, "k": 1, "passed": 10, "total": 32, "ms": 124400
 // eval_pass_rate (k>1; pass_at_1 absent, pass_at_k present): "pass_at_k": 0.44, "k": 4, …
 }

{"event": "error", "message": "human-readable, sourced from the exception"}
```

### Self-improvement helpers — extra event types

`self_improve_round.py` and `eval_pass_rate.py` extend the base vocabulary with
streaming per-row events so the UI can show a meaningful "Problem 7 of 20: …"
progress without polling. Consumed by
[`SelfImproveService.swift`](../LLMPro/Services/SelfImproveService.swift).

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
// eval_pass_rate with --k > 1 — the row also reports how many of the k candidates passed:
{"event": "row", "i": 6, "task_id": "HumanEval/90", "passed": true, "reason": "", "passes": 2, "k": 4}
```

These helpers also re-emit a `start` event with `rows / candidates / model / adapter`
fields and a `done` event with `pass_at_1` (eval) or `pass_rate / kept / train / valid / test` (round).
The contracts of `start / done / error` are unchanged — see above.

#### `self_improve_round.py` — model-generated-code sandbox (hardened 2026-06-13 audit)

`self_improve_round.py` runs **model-generated** code to unit-test each candidate, so
its sandbox was hardened. Each candidate now runs:

- in its **own process group** (`start_new_session=True`), so a timeout escalates to a
  **`killpg`** of the whole group — a candidate can't outlive the wall-clock alarm by
  forking;
- in a **throwaway cwd** (a temp dir), so writes don't touch the run's output;
- with a **stripped environment** — only an explicit allowlist is passed through, so
  generated code **no longer sees `HF_TOKEN` or any other inherited secret**;
- under `RLIMIT_NPROC` (fork-bomb cap), `RLIMIT_FSIZE` (64 MiB single-file write cap),
  and `RLIMIT_CPU` (a CPU-seconds backstop), on top of the pre-existing
  `RLIMIT_AS=1 GB + SIGALRM`.

This is still a "code from a model we just fine-tuned" trust model, not a
general-purpose sandbox, but the obvious fork-bomb / disk-abuse / secret-leak holes
are closed. The JSON-event contract is unchanged.

#### `eval_pass_rate.py` — `--k` / `--temperature` (pass@k)

[`eval_pass_rate.py`](../LLMPro/Resources/helpers/eval_pass_rate.py) takes two
optional flags so the Test node ([`ArenaView`](../LLMPro/Features/Chat/ArenaView.swift)
"Score it") and Practice can score a `(model + adapter)` at pass@k. Consumed by
both [`EvalService.swift`](../LLMPro/Services/EvalService.swift) and
[`SelfImproveService.swift`](../LLMPro/Services/SelfImproveService.swift):

```
python <helpers>/eval_pass_rate.py --eval <eval.jsonl> --model <ABS-PATH>
  [--adapter <adapter-dir>] [--limit N] [--k 1] [--temperature 0.2]
```

- **`--k`** (default `1`): candidates generated per problem. A row passes if **any**
  of its `k` candidates passes the row's `tests`.
- **`--temperature`** (default `0.2`, used only when `k > 1`): sampling temperature
  for the `k` candidates.

**`--k 1` is byte-for-byte unchanged** — greedy (`temperature=0.0`), deterministic,
one candidate, and the `done` event still carries `pass_at_1`. This keeps the
existing `SelfImproveService` caller (which never passes `--k`) unaffected.

Event-field deltas by `k`:

| Event | Field | `k == 1` | `k > 1` |
|---|---|---|---|
| `start` | `k` | present (`1`) | present |
| `row` | `passes`, `k` | absent | present (`passes` of `k` candidates passed) |
| `done` | `pass_at_k`, `k` | present (`pass_at_k` == `pass_at_1`) | present |
| `done` | `pass_at_1` | present (the canonical field) | **present only as an alias when k==1** |

So at `k == 1` the `done` event has **both** `pass_at_1` and `pass_at_k` (equal); at
`k > 1` it has `pass_at_k` + `k` but **no** `pass_at_1`. `EvalService` reads
`pass_at_k` (falling back to `pass_at_1`); the legacy `SelfImproveService` path reads
`pass_at_1` and only ever runs at `k == 1`.

### `inspect_attention.py` — Inspect tab attention capture

[`inspect_attention.py`](../LLMPro/Resources/helpers/inspect_attention.py)
runs ONE forward pass, dumps per-layer attention for the Inspect tab's heatmap,
then exits. Consumed by
[`AttentionInspectService.swift`](../LLMPro/Services/AttentionInspectService.swift).

CLI: `python <helpers>/inspect_attention.py --model <ABS-PATH> --prompt <text>
[--max-seq 64] [--layers all|0,5,10] [--head mean|<int>]`. `--model` must be an
absolute on-disk path (Swift resolves it). Env: `HF_HOME`, `LLMPRO_MEM_LIMIT_GB`
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
safetensors-header parsing ([`Core/SafetensorsHeader.swift`](../LLMPro/Core/SafetensorsHeader.swift)).

### `diffusion_generate.py` — DiffusionGemma inference (non-mlx-lm)

[`diffusion_generate.py`](../LLMPro/Resources/helpers/diffusion_generate.py) runs
Google's **DiffusionGemma** (`model_type: diffusion_gemma`) — a **masked / block-
diffusion** LM that decodes by iteratively unmasking a fixed-size canvas, **not**
autoregressively. mlx-lm's `generate`/`server`/`lora` have no class for it, so this is
the **only** path that can run it, and it is **inference-only** (it cannot be
fine-tuned by mlx-lm LoRA/AutoTuner — it's excluded from Teach/Practice). Consumed by
[`InferenceService.swift`](../LLMPro/Services/InferenceService.swift) (the Arena routes
diffusion models here; see [`mlx_lm generate`](#mlx_lm-generate--inference) above). The
verified target is the prebuilt `mlx-community/diffusiongemma-26B-A4B-it-OptiQ-4bit`
(~15 GB).

CLI:
```
python <helpers>/diffusion_generate.py --model <ABS-PATH-or-repo-id> --prompt <text>
  [--max-tokens 512] [--temperature 0.0]
  [--sampler confidence-threshold|entropy-bound]
```

- **`--sampler`** (default `confidence-threshold`) is the diffusion **unmasking**
  sampler, not a token sampler — a diffusion-specific knob with no mlx-lm analogue.
- **`--model`** accepts a local dir (resolved/abs) or an HF repo id (the vendored
  `dg.load` treats an existing directory as a local path, else an HF repo id).

Env: `LLMPRO_MEM_LIMIT_GB` (default 108 — **self-pins** MLX memory because this
helper bypasses `mlx_run.py`, exactly like `inspect_attention.py`), `HF_HOME`,
`PYTHONUNBUFFERED`.

**The helper applies the Gemma chat template (load-bearing).** The model is an
instruct (`-it`) checkpoint, but the vendored `stream_generate` does **not** template
a raw string — feeding it an un-templated prompt produced garbage (a bug found and
fixed during live verification). So the helper calls
`tokenizer.apply_chat_template([{role:"user",content:prompt}], add_generation_prompt=True)`
and **pre-tokenizes with `add_special_tokens=False`** (the template already carries
BOS; the string path would add a second BOS), then passes the token-id list to
`stream_generate`. It falls back to the raw string only if the tokenizer exposes no
chat template.

JSON events on stdout (one object per line, standard protocol):

```jsonc
{"event": "start", "model": "…", "max_tokens": 512, "temperature": 0.0, "sampler": "confidence-threshold"}
{"event": "progress", "stage": "load" | "generate"}
{"event": "token", "text": "<revealed text segment>"}   // one per non-draft canvas reveal
{"event": "done", "text": "<full output>", "ms": 1234,
 "prompt_tokens": 41, "generation_tokens": 80,
 "finish_reason": "stop", "peak_memory_gb": 16.8}
{"event": "error", "message": "<sourced from the exception>"}
```

Intermediate **draft** frames (partial canvas-unmasking states) are skipped — only
non-draft revealed segments are emitted as `token` events and accumulated into the
final `text`. Helper-specific exit codes: **3** (vendored import / model-load
failure), **4** (generation failure), in addition to the shared `0`/`130`.

#### Vendored decoder: `diffusion_vendor/` (copied, NOT pip-installed)

The DiffusionGemma decoder is **vendored into the repo**, not a pip dependency:
[`LLMPro/Resources/helpers/diffusion_vendor/`](../LLMPro/Resources/helpers/diffusion_vendor/)
holds the `optiq/vlm/...` subtree from the MIT-licensed
[`mlx-optiq`](https://pypi.org/project/mlx-optiq/) package (**v0.2.3**) — ~34 `.py`
files: the `optiq.vlm.diffusion_gemma` `load`/`stream_generate` closure, the Gemma-4
backbone, and the `_mlxvlm` masked-diffusion decode loop. Provenance, the full MIT
license text, and the deliberately-excluded subtrees are in
[`diffusion_vendor/VENDORED.md`](../LLMPro/Resources/helpers/diffusion_vendor/VENDORED.md).

- **Why vendored, not installed:** copying a *reviewed* subset keeps it pinned and
  auditable and shrinks the attack surface — the upstream package's
  network/subprocess/agent machinery (`optiq/{lab,runtime,serve,cli,core,eval,lora,ops}`,
  `sandbox.py`, `mlx_lm_patches/`, the `*_server.py`/`*_shim.py` modules) is
  **deliberately not copied**. The two `__init__.py` files that had eager side-effect
  imports upstream were replaced with docstring-only stubs. See
  [`CONVENTIONS.md`](CONVENTIONS.md#vendoring-the-diffusiongemma-decoder-copy-not-pip).
- **Self-contained deps:** the closure imports only `mlx`, `mlx-lm`
  (`mlx_lm.models.{cache,base,switch_layers}`, `mlx_lm.generate`), `transformers`,
  `numpy`, `Pillow`, and `huggingface_hub` — **all already in the venv, no torch**.
  Only `pillow` was newly added to `PythonRuntime.bootstrap()` for it (see §1 / the
  bootstrap pip list).
- **Layout matters:** the `optiq/` package layout is preserved so the original
  relative imports (`from ..gemma4 import …`) resolve once `diffusion_vendor/` is on
  `sys.path`. `diffusion_generate.py` computes that path relative to its own
  `__file__` and `sys.path.insert(0, …)`s it, then `import optiq.vlm.diffusion_gemma`.
- **Bundle copy is recursive:** `PythonRuntime.installHelpers()` (which previously
  copied only flat `.py` files) now **also recursively copies the whole
  `diffusion_vendor/` subtree** out of the bundle into
  `runtime/helpers/diffusion_vendor/`, alongside `diffusion_generate.py` — a flattened
  copy would break `import optiq.vlm.diffusion_gemma`. See §6 (filesystem layout).

#### `ModelRegistry.DetectedModel.isDiffusion` (config detection)

`ModelRegistry.scan()` sets `DetectedModel.isDiffusion = true` when a repo's
`config.json` has **top-level `model_type == "diffusion_gemma"`** *or* an
`architectures` entry whose name **starts with `DiffusionGemma`**. (The wrapper's
top-level `model_type` stays `"diffusion_gemma"` even though the inner text tower is
`"diffusion_gemma_text"`, so the match is on the wrapper.) This flag is the single
source of truth that fans out to: `InferenceService` routing (→ `diffusion_generate.py`,
chat), `MLXServerService` routing (→ `diffusion_server.py` instead of `mlx_lm server`,
the Code-tab agentic loop — see below), and the Teach + Practice model-picker
exclusions (`!isDiffusion`). DiffusionGemma is **not** fine-tunable (mlx-lm has no
LoRA path for it), so it is excluded ONLY from Teach / Practice / DPO — it now works
in both **Try-it-out** (chat) and **Code** (agentic, experimental).

### `diffusion_server.py` — long-lived OpenAI-compatible diffusion server (Code tab)

[`diffusion_server.py`](../LLMPro/Resources/helpers/diffusion_server.py) is the
**daemon** counterpart to the one-shot `diffusion_generate.py`: it serves a
DiffusionGemma model over an **OpenAI-compatible HTTP API** so the Code tab's
Orchestrator team can drive a diffusion model through the *same*
`OpenAIChatClient` + `CodingAgentService` loop as an `mlx_lm server`-backed model.
`mlx_lm server` **cannot** load a diffusion LM (no autoregressive class), so for a
diffusion model [`MLXServerService.start`](../LLMPro/Services/MLXServerService.swift)
launches this helper instead (see `mlx_lm server` in §1 and the `MLXServerService`
note below). This makes DiffusionGemma usable in **Code** (agentic, experimental) —
it is no longer chat-only; it remains excluded only from Teach / Practice / DPO.

**Stdlib HTTP, no Flask.** The server is built on Python's
**`http.server.ThreadingHTTPServer`** — no new pip dependency (stdlib + the existing
`mlx` / `mlx-lm` / `transformers` / `pillow` / `numpy` the vendored decoder already
needs). It is launched **via `mlx_run.py`** (like `mlx_lm server`), so it is
memory-wrapped by the same Apple-Silicon MLX tuner (§3); `mlx_run.py` runs a bare
script path through `runpy.run_path`. Env: `HF_HOME`, `PYTHONUNBUFFERED`, plus the
`LLMPRO_MEMORY_LIMIT_BYTES` / `LLMPRO_CACHE_LIMIT_BYTES` overrides `mlx_run.py`
honors.

**One dedicated MLX worker thread (load-bearing).** The vendored decode binds a
**thread-local `mx` stream at import**, so the model load **and every generation
must run on the same thread**. The server loads the model **once** on a single
dedicated MLX worker thread; the `ThreadingHTTPServer` request threads **submit jobs
to that worker via a queue** and block on the result. Do not move generation onto the
HTTP threads — it will use the wrong (or no) stream and fail.

CLI (positional, launched by `MLXServerService`):
```
python <helpers>/diffusion_server.py --model <ABS-PATH-or-repo-id> \
  --host 127.0.0.1 --port <free-port>
```
`--adapter-path` is **not** accepted — diffusion has no LoRA adapter, so
`MLXServerService` **ignores** the selected adapter for diffusion models.

**Readiness line.** When the model is loaded and the socket is listening, the helper
prints exactly:
```
LLMPRO_DIFFUSION_SERVER_READY port=<port>
```
to stdout. `MLXServerService` reuses its existing free-port / `waitForServerUp`
(polls `GET /health`) / 1-token warm-up / state-machine path, so the ready line is
informational; `/health` is the gate.

Endpoints (the subset `OpenAIChatClient` uses):
```
GET  /health                 → 200 {"status":"ok","model":"…"} once loaded
GET  /v1/models              → {"object":"list","data":[{"id":"…","object":"model"}]}
POST /v1/chat/completions    → non-streaming OR SSE (stream:true), see below
```

**`POST /v1/chat/completions` response shapes** are emitted in the **exact form
`OpenAIChatClient` decodes** (§9):

- **Non-streaming** (`stream:false`): a `chat.completion` object with
  `choices[0].message` (`role:"assistant"`, `content`, and `tool_calls` when the
  model called a tool), `finish_reason` (`stop` | `tool_calls`), and a `usage` block.
- **Streaming** (`stream:true`): `text/event-stream` of `chat.completion.chunk`
  frames — `choices[0].delta.content` text deltas, accumulated
  `choices[0].delta.tool_calls` deltas, a final `finish_reason`, terminated by
  `data: [DONE]`. This is the same frame shape `OpenAIChatClient.stream` parses for
  `mlx_lm server`.

**Tool-call translation: DiffusionGemma grammar ↔ OpenAI.** DiffusionGemma emits
tool calls in its **own native grammar**, not OpenAI JSON:
```
<|tool_call>call:NAME{key:value,...}<tool_call|>
```
with **string argument values wrapped** in the model's special quote token,
`<|"|>…<|"|>`. The server **translates** these into OpenAI `tool_calls`
(`{"id","type":"function","function":{"name","arguments":<JSON string>}}`) so the
agent's native-tool path works unchanged. The parser is **tolerant** and
**fail-open**: if nothing parses as a tool call, the raw text is returned as plain
`content` (the agent's `<tool_call>` / fenced-JSON text fallback still runs on top —
see §9). **Inbound needs no translation:** tool RESULTS (`role:"tool"` messages) are
consumed by the model's own chat template, so they are passed through as-is.

Because the translation produces clean OpenAI `tool_calls`, **native tool-calling
stays ON by default** for diffusion models in the Code tab (the Code UI shows the
caption "Diffusion model — chat works; agentic tool-use is experimental.").

**Verified live:** DiffusionGemma-8bit served in the Code tab drove the full
Orchestrator loop (Orchestrator → Coder → `write_file` → `list_dir`) and created a
file on disk; logs clean, no crash. Tool-calling works, with an **occasional
unusable diffusion turn that the Orchestrator recovers from** (a canvas-256
reliability caveat of the diffusion decode, not a protocol bug).

### `gguf_to_mlx.py` — GGUF → MLX import (chat-template fallback)

[`gguf_to_mlx.py`](../LLMPro/Resources/helpers/gguf_to_mlx.py) converts a `.gguf`
file to an MLX `models/<name>/` model via mlx.core's native GGUF loader (no
PyTorch). Consumed by [`GGUFImportService.swift`](../LLMPro/Services/GGUFImportService.swift)
with two subcommands: `precheck` (reports arch + quant — F16/Q4_0/Q4_1/Q8_0 are
convertible, K-quants are not) and `convert`.

**Chat-template fallback (the import now produces a chattable INSTRUCT model).**
A GGUF carries a chat template in its `tokenizer.ggml.chat_template` metadata only
*sometimes*. When that key is **present**, the converter copies it verbatim
(behavior unchanged). When it is **absent**, the converter now **writes a
per-architecture default chat template** into `tokenizer_config.json` instead of
leaving none:

| GGUF architecture | Fallback template |
|---|---|
| `qwen2`, `qwen2moe`, `qwen3` | ChatML (`<|im_start|>`/`<|im_end|>`) |
| `gemma`, `gemma2`, `gemma3` | Gemma turn format (`<start_of_turn>`/`<end_of_turn>`) |
| `llama` (Llama-3) | Llama-3 header format (`<|start_header_id|>` …) |
| `phi3` | Phi-3 format |
| `llama` (Mistral) / Mistral | Mistral `[INST]` format |

Previously a converted instruct model whose GGUF lacked the metadata had **no**
chat template and failed in chat / Code / eval with
`"tokenizer.chat_template is not set"` until one was hand-injected; the fallback
makes such models chat **out of the box**.

The `done` event gained a **`chat_template_source`** field reporting which path was
taken:

```jsonc
{"event": "done", "path": "/…/models/<name>", "architecture": "qwen3",
 "chat_template_source": "metadata" | "fallback-<arch>" | "none"}
```

- `"metadata"` — copied from the GGUF's `tokenizer.ggml.chat_template`.
- `"fallback-<arch>"` — the GGUF had none; a per-architecture default was written
  (e.g. `"fallback-qwen3"`, `"fallback-gemma"`).
- `"none"` — no metadata and no fallback matched the architecture (a base /
  non-instruct model, or an arch with no default) → no template written.

### `InferenceService` ↔ `ChatSession` streaming contract (yield-ready-to-append)

`InferenceService.stream` yields **chunks that the consumer appends RAW** — the caller
no longer adds a separator. The two inference paths now agree on this contract:

- **mlx_lm path** (`mlx_lm generate`) yields each stdout line **with its newline
  re-added** (`continuation.yield(line + "\n")`), because mlx-lm's output is
  line-granular.
- **Diffusion path** (`diffusion_generate.py`) yields the **raw `token` text segment**
  as it denoises (no added newline) — diffusion output is not line-oriented.

[`ChatSession.send`](../LLMPro/Features/Chat/ChatModels.swift) consumes both with
`messages[i].text.append(chunk)` — **raw, not `chunk + "\n"`**. This fixed a
per-token-newline bug where diffusion output rendered **one token per line** (the old
`chunk + "\n"` append double-spaced the diffusion path). The rule for any future
inference path: **yield chunks ready to append; whoever produces them adds whatever
separator they need.** mlx-lm re-adds `\n`; diffusion yields raw tokens.

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
[`DownloadService.swift`](../LLMPro/Services/DownloadService.swift) and
[`DatasetPrepService.swift`](../LLMPro/Services/DatasetPrepService.swift)):

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

### `ProcessRunner` process model (EOF/cancel semantics — 2026-06-13 audit)

`ProcessRunner` exposes two entry points — `runCapturing()` (await full completion)
and `spawn()` (returns a `RunningProcess` streaming handle). Two contract details
matter when wrapping a helper:

- **The pipe reader (not the exit handler) finishes the output streams on EOF.** The
  `readabilityHandler` owns stream termination: it finishes the stdout/stderr
  `AsyncStream` continuations when it reads EOF. This was the fix for a **dropped final
  line** — the previous code finished the streams in the process-exit handler, which
  could fire before the reader had drained the last buffered line, silently losing the
  **error/traceback tail** of a helper that died. Any helper's final `{"event":"error"}`
  line is now guaranteed to be delivered.
- **A cancelled consumer reaps the child.** The streaming continuation's
  `onTermination` now **terminates the child process** when the consuming `Task` is
  cancelled, so a cancelled stream no longer **orphans** the subprocess. For the hard
  case, `RunningProcess.kill()` sends **SIGKILL** (the escalation when `terminate()`'s
  SIGTERM is ignored — `Foundation.Process` has no kill API, so it signals the PID
  directly).

---

## 4. HuggingFace Hub API

Used by [`HuggingFaceClient.swift`](../LLMPro/Services/HuggingFaceClient.swift).
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

Used by [`FuseService.swift`](../LLMPro/Services/FuseService.swift) in
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

Defined in [`PathResolver.swift`](../LLMPro/Core/PathResolver.swift). Other code
**must** route every path lookup through here.

```
~/Library/Application Support/LLMPro/
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
│   │   ├── mlx_run.py                ← always-on MLX tuner (pin memory/wired/cache to the Metal ceiling → runpy the real cmd)
│   │   ├── diffusion_generate.py     ← DiffusionGemma (masked/block-diffusion) inference; self-pins mem, streams token events
│   │   ├── diffusion_server.py       ← DiffusionGemma OpenAI-compatible HTTP daemon (Code tab); stdlib http.server, single MLX worker thread, Gemma↔OpenAI tool translation
│   │   ├── gguf_to_mlx.py            ← GGUF → MLX import (precheck/convert); writes a per-arch default chat template when the GGUF carries none
│   │   └── diffusion_vendor/         ← VENDORED (copied, not pip) optiq.vlm DiffusionGemma decoder (MIT, mlx-optiq v0.2.3)
│   │       ├── optiq/vlm/...         ← the ~34-file inference closure; subtree copied recursively, layout preserved
│   │       └── VENDORED.md           ← provenance + MIT license + the excluded subtrees
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
│   │                                  OR preference schema: {"prompt","chosen","rejected"[,"system"]}
│   │                                  (DatasetSchema.preference — DPO sets; PreferenceService)
│   ├── valid.jsonl                 ← preference sets: ~10% carved from train.jsonl by splitForTraining
│   └── test.jsonl
│
├── models/<custom-name>/           ← user-modified models (strip-vision, abliterate, manual imports)
│   ├── config.json
│   ├── tokenizer.json
│   ├── model-NNNNN-of-NNNNN.safetensors
│   └── model.safetensors.index.json
│
├── exports/<job-uuid>/             ← Save & Use output (fused/, <tag>.gguf, cloud/)
├── exports/<model-displayName>/    ← per-model "Export to GGUF" output (Models tab)
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
│       ├── dataset/                ← THIS round's passing solutions (per-round keepers, from self_improve_round.py)
│       │   ├── train.jsonl
│       │   ├── valid.jsonl
│       │   └── test.jsonl
│       └── cumulative/             ← deduped union of rounds 1..N keepers — the ACTUAL training set
│           ├── train.jsonl          (growing buffer; anti-overfit. dedup by user-prompt, latest round wins)
│           ├── valid.jsonl
│           └── test.jsonl
│   # Note: per-round adapters live under adapters/<round-job-uuid>/, NOT here,
│   # so they show up alongside ordinary training adapters in the Arena & Save & Use views.
│
├── evals/                         ← scored-eval harness (EvalService); see §7 EvalRun
│   ├── <suiteID>/eval.jsonl       ← cached built-in suite (humaneval / mbpp-sanitized),
│   │                                 pulled lazily via humaneval_pull.py on first use
│   ├── custom-<uuid>/eval.jsonl   ← user-supplied custom suite (imported via the Test node
│   │                                 "Import suite…", or hand-dropped); optional suite.json {name,problemCount}
│   └── <run-uuid>/eval_run.json   ← per-run sidecar (one per EvalRun; same pattern as job.json)
│
├── skills/<skill-id>/             ← one folder per Code-tab Agent Skill (SkillStore — LIVE); folder name = stable skill id
│   ├── SKILL.md                   ← YAML frontmatter (name + description) + markdown instructions body
│   └── <optional bundled files>   ← scripts/references/assets; preserved on import; folder path handed to the agent so it can read them
│
├── agents/<role>.md               ← editable team-agent definitions (AgentStore); seeded from
│   #  orchestrator.md / planner.md / researcher.md / coder.md / ui.md  the bundle ONLY IF MISSING,
│   #  so user edits survive launches. Frontmatter + system-prompt body — see §"agent markdown format".
│
└── logs/llmpro.log                 ← app diagnostic log (Core/Log.swift; live-tailed in Settings → Logs)
```

The coding agent (Code tab) adds exactly **one** directory here: `skills/` (the
**Agent Skills** library — one folder per `SKILL.md` package; see [Agent Skills
(`use_skill` + the SKILL.md format)](#agent-skills-use_skill--the-skillmd-format)).
Its project/workspace folder is
user-chosen and lives *outside* Application Support; the agent is sandboxed to
that folder. New persistence is the `@AppStorage("codeWorkspacePath")`,
`@AppStorage("codeOrchestratorModel")`, and `@AppStorage("codeAdapterJobID")`
UserDefaults keys, plus `AgentSettings.useSkills` (the skills on/off toggle).

`LLMPro/runtime/.venv/` is path-pinned (uv venvs hardcode the absolute path of
the Python interpreter in shebang lines). If the user moves the app or rename
the support dir, the venv breaks — `bootstrapIfNeeded()` would need to detect
and recreate it. Not currently implemented.

---

## 7. SwiftData schema

Defined in `LLMPro/Models/`. SwiftData manages migration automatically. **If
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
trainModeRaw: String     // TrainMode rawValue: sft (default) | dpo — additive, no migration
createdAt: Date
```

**`trainModeRaw`** is **additive** (defaults `"sft"`, so existing records load with no
migration). A `.dpo` job was trained via `mlx_lm_lora.train` (see the DPO trainer
section in §1) instead of `mlx_lm lora`; `TrainingService.start()` branches SFT vs DPO
on it. Its output adapter is the same shape, so a DPO job is interchangeable with an
SFT job everywhere downstream.

### `DatasetRecord` (`@Model`)

```swift
id: UUID @Attribute(.unique)
name: String
schemaRaw: String        // DatasetSchema rawValue: chat|completions|tools|text|preference|unknown
trainRows: Int
validRows: Int
testRows: Int
relativePath: String     // = id.uuidString, relative to PathResolver.datasetsDir
createdAt: Date
notes: String
```

**`DatasetSchema.preference`** (the new case) is how the **DPO preference loop**
stores its data — preferences are a **first-class `DatasetRecord`, NOT a new
`@Model`** (so there is **no SwiftData migration**). On disk the rows are
`{"prompt","chosen","rejected"[,"system"]}` JSONL in `datasets/<uuid>/train.jsonl`
(+ `valid.jsonl`), written by
[`PreferenceService`](../LLMPro/Services/PreferenceService.swift). `DatasetService.classify()`
gained a **`preference` vote** (a row with `prompt`+`chosen`+`rejected` keys), checked
**before `completions`** so a preference file is never misread as a completions set.

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

### `EvalRun` (`@Model`)

One per scored eval of a `(model + adapter)`. Mirrors `SelfImproveRun`'s
blob-in-model + sidecar pattern. Owned by
[`EvalService.swift`](../LLMPro/Services/EvalService.swift); written when the Test
node's "Score it" (or Progress's "Grade it") action runs. A **base model** is
`adapterRelativePath == ""`; a fine-tune's value equals the source
`TrainingJob.adapterRelativePath`, so scores are comparable across retrains.

```swift
id: UUID @Attribute(.unique)
createdAt: Date
baseModelRepoID: String      // friendly identifier; absolute path resolved at run time
adapterRelativePath: String  // "" = base model; else == TrainingJob.adapterRelativePath
suiteRaw: String             // EvalSuite rawValue: humaneval | mbpp-sanitized | custom
customSuiteID: String        // the custom-<uuid> suite id when suite == .custom (else "")
k: Int                       // pass@k (default 1)
problemCount: Int            // how many problems were requested (the depth limit; 0 = all)
passAtK: Double              // the score
passedCount: Int
totalCount: Int
elapsedMs: Int
statusRaw: String            // EvalStatus rawValue: queued | running | completed | failed | cancelled
sourceLabel: String          // human-readable provenance ("Coding fine-tune", "Base", …)
sourceJobID: UUID?           // the TrainingJob/SelfImproveRun this adapter came from, if any
perTaskBlob: Data            // JSON-encoded [EvalTaskResult]
lastError: String?
```

Embedded `EvalTaskResult` (JSON inside `perTaskBlob`, NOT a `@Model`):

```swift
struct EvalTaskResult: Codable, Identifiable, Hashable {
    var taskID: String       // e.g. "HumanEval/42"
    var passed: Bool
    var reason: String       // "" on pass; the failure reason otherwise
    var id: String { taskID }
}
```

Enums and helpers:

- **`EvalSuite`** (`humaneval` / `mbpp-sanitized` / `custom`) with `displayName`,
  `oneLine`, and `pullPreset: String?` (the `humaneval_pull.py` preset name for
  built-in suites; `nil` for `.custom`).
- **`EvalStatus`** (`queued` / `running` / `completed` / `failed` / `cancelled`).
- `adapterURL`, `suite` / `status` get-set bridges, `passPercent`,
  `decodedTasks()` / `setTasks(_:)`, and `writeSidecar()` →
  `evals/<run-uuid>/eval_run.json` (§6).

**Schema registration**: `EvalRun.self` is registered in **both** schema arrays —
`LLMProApp`'s `.modelContainer(for:)` list **and** `Core/PreviewSupport.swift`'s
in-memory container (with a `sampleEvalRun`) — per the "register a new `@Model` in
both places" rule (see [`ARCHITECTURE.md`](ARCHITECTURE.md) `PreviewSupport`).

### `AgentProfile` (`@Model`)

One per saved Code-tab agent. Additive entity (consistent with the additive-only
stance above); registered in `LLMProApp`'s `modelContainer(for:)` list.

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
[`RootView.swift`](../LLMPro/App/RootView.swift). Adding a new one is fine; just
keep them sparse — see [`CONVENTIONS.md`](CONVENTIONS.md).

Current set:

```swift
// DashboardView
Notification.Name("LLMPro.switchSidebar")        // object: SidebarSection
// TrainingConfigView
Notification.Name("LLMPro.switchToMonitor")      // no payload
// ModelDetailView
Notification.Name("LLMPro.openTrainingWithModel") // object: String (repoID)
Notification.Name("LLMPro.openChatWithModel")    // object: ModelHandoff OR String (see below)
// LoopHandoff.swift
Notification.Name("LLMPro.openCodeWithModel")    // object: ModelHandoff OR String (see below)
Notification.Name("LLMPro.openTrainingWithPreferences") // object: PreferenceHandoff (see below)
```

These carry the **feedback-loop hand-off** — moving a fine-tuned model (+adapter)
from the stage that produced it to the next tab so the user never copies a disk path
by hand. See [`CONCEPT.md`](CONCEPT.md#the-edges--how-the-artifact-moves-between-stages)
for the full edge map.

#### `ModelHandoff` (the hand-off payload)

Declared in [`LoopHandoff.swift`](../LLMPro/Core/LoopHandoff.swift):

```swift
struct ModelHandoff: Sendable {
    let model: String          // base model repo ID or local name
    let adapterPath: String?   // absolute path to the LoRA adapter dir, if any
    var autoScore: Bool = false // Test node auto-runs the eval on arrival when true
}
```

**`autoScore`** (additive, default `false`, struct stays `Sendable`): when a poster
sets it `true`, the Test node ([`ArenaView`](../LLMPro/Features/Chat/ArenaView.swift))
**auto-runs "Score it"** on arrival instead of waiting for the user to click it.
Progress's **"Grade it"** CTA posts `.openChatWithModel` with this flag set, so the
fine-tune lands in the Test node and scores immediately. The default-`false` posters
(Try-it-out, Practice, the other completion CTAs) are unaffected.

**Dual-payload contract (unchanged).** Receivers of `.openChatWithModel` and
`.openCodeWithModel` still accept **either** a `ModelHandoff` (now with the optional
`autoScore`) **or** a bare `String` (model only), so older posters that send just a
repo ID keep working — adding `autoScore` did **not** change the
`as? ModelHandoff ?? as? String` decode:

```swift
if let h = note.object as? ModelHandoff { /* model + adapter */ }
else if let model = note.object as? String { /* model only */ }
```

#### `PreferenceHandoff` (the DPO "Teach by preference" hand-off)

Declared in [`LoopHandoff.swift`](../LLMPro/Core/LoopHandoff.swift), carried by the
**new** `.openTrainingWithPreferences` notification. It is the ③ → ② back-edge for the
**preference loop**: the Arena's **"Teach by preference →"** CTA posts it after the
user has marked enough answers, and `RootView` routes it to the Teach tab.

```swift
struct PreferenceHandoff: Sendable {
    let model: String          // base model repo ID or local name
    let adapterPath: String?   // absolute path to a LoRA adapter dir, if any
    let datasetID: UUID        // the .preference DatasetRecord to fine-tune on
}
```

Unlike `ModelHandoff`, it carries the **preference `datasetID`** (not just a
model+adapter). On arrival, [`TrainingConfigView`](../LLMPro/Features/Training/TrainingConfigView.swift)
pre-fills the model + the `.preference` dataset, **auto-detects the `.preference`
schema → shows a "teach by preference (DPO)" banner + sets DPO mode**, and `launch()`
branches to `PreferenceService.splitForTraining` + `AutoTuner.tuneDPO` +
`job.trainMode = .dpo`. The produced adapter lands under `adapters/<uuid>/` like any
job, so the ordinary Progress / Try-it-out / Save & Use completion CTAs carry it back
into the loop unchanged.

Posters & receivers (all user-driven CTAs — completion never auto-switches tabs):

| Notification | Posted by (CTA) | Object | Received by |
|---|---|---|---|
| `.openChatWithModel` | Progress completion card ("Try it out") + Progress **"Grade it"** (`autoScore: true`) / Arena decision bar / Practice "Use this fine-tune" / `ModelDetailView` "Open in Chat" | `ModelHandoff` (the new posters; "Grade it" sets `autoScore`) or `String` (`ModelDetailView`) | `RootView` → `.chat`; `ArenaView` pre-fills model + adapter, and auto-runs "Score it" when `autoScore` |
| `.openCodeWithModel` | Progress completion card / Arena decision bar / Practice "Use this fine-tune" | `ModelHandoff` (or `String`) | `RootView` → `.code`; `CodeView.applyHandoff` pre-fills model + adapter |
| `.openTrainingWithPreferences` | Arena **"Teach by preference →"** CTA (enabled at ≥4 captured preferences) | `PreferenceHandoff` | `RootView` → `.training`; `TrainingConfigView` pre-fills model + the `.preference` dataset, sets DPO mode + banner |

`.openCodeWithModel` is the edge that lets the Code tab load a **fine-tuned** adapter
(previously its `MLXServerService` was started with `--adapter-path nil`).
`.openTrainingWithPreferences` is the **preference back-edge** — the Arena's
👍-capture feeds a DPO fine-tune (see [`CONCEPT.md`](CONCEPT.md#the-preference-back-edge-the-arena-also-produces-fuel)).

The coding agent (Code tab) otherwise talks to its services directly. Its persisted
state is the `@AppStorage("codeWorkspacePath")`, `@AppStorage("codeOrchestratorModel")`
and `@AppStorage("codeAdapterJobID")` (the loop-selected adapter job) UserDefaults
keys plus the `AgentProfile` SwiftData entity (see §6, §7).

---

## 9. Local OpenAI-compatible chat API + agent tool protocol

The Code tab talks to the local `mlx_lm server` (see §1) over the OpenAI chat
subset, and runs a tool-use loop on top of it. Both halves are contracts the agent
depends on. Consumers: [`OpenAIChatClient.swift`](../LLMPro/Services/OpenAIChatClient.swift),
[`AgentTools.swift`](../LLMPro/Services/AgentTools.swift),
[`CodingAgentService.swift`](../LLMPro/Services/CodingAgentService.swift).

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
researcher, coder, ui — see [`AgentRoles.swift`](../LLMPro/Services/AgentRoles.swift)).
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
`LLMProApp`'s `.task`. It scans `skillsDir` and, on the very first launch only
(guarded by the `didSeedExampleSkills` `UserDefaults` flag so deletions don't
reappear), seeds four instruction-only example skills: `conventional-commits`,
`code-reviewer`, `swiftui-app-builder` (scaffolds + builds a full macOS/iOS SwiftUI
app), and `project-build-verify` (language-agnostic: detect the build tool, scaffold,
then compile/test until green — Rust/.NET/TS/Go/Zig/Python/C++/Java/…).

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
defined by one Markdown file each — bundled at `LLMPro/Resources/agents/<role>.md`
and seeded into `~/Library/Application Support/LLMPro/agents/` (`PathResolver.agentsDir`)
by [`AgentStore`](../LLMPro/Services/AgentStore.swift). The copy happens **only if
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

The editor is [`AgentsManagerView`](../LLMPro/Features/Code/AgentsManagerView.swift)
(Code tab → Options → "Edit team agents…"): edit the raw markdown, **Save** (writes
the file + reloads `AgentStore` so the next run obeys it), **Reset to default**
(re-copies the bundled version), **Show in Finder**. It edits the raw markdown via
the substitution-disabled `MarkdownEditor` (so `---` fences stay `---`); ＋ New
creates a role file immediately (rename via the `name:` line). This markdown-agent
system is **separate** from the dead `AgentProfile` (the removed single-agent
library; `AgentEditorView` was deleted); `SkillStore` / Agent Skills, by contrast,
are **live** (see the Agent Skills subsection above) and apply team-globally by
default (an agent's `skills:` frontmatter can scope them to a subset).
