# Vendored code — DiffusionGemma inference (from `mlx-optiq`)

This directory contains a **vendored copy** (not a pip dependency) of a minimal
subset of the [`mlx-optiq`](https://pypi.org/project/mlx-optiq/) package, used so
LLMPro can run Google's **DiffusionGemma** (a masked/block-diffusion LM) on MLX
without depending on `mlx-optiq` at runtime.

## What was copied

- **Source:** `mlx-optiq` **v0.2.3**, from PyPI
  (wheel `mlx_optiq-0.2.3-py3-none-any.whl`).
- **License:** **MIT** (see the full text below; from the wheel's
  `METADATA` → `License: MIT`).
- **Author:** `mlx-optiq` (per wheel metadata).
- **Scope:** ONLY the `optiq/vlm` DiffusionGemma **inference** closure — the
  package `optiq.vlm.diffusion_gemma` (`load` / `generate` / `stream_generate` /
  `load_diffusion_gemma` / `load_config`) and exactly the modules it imports
  transitively:
  - `optiq/vlm/diffusion_gemma/{__init__,generate,loader}.py`
  - `optiq/vlm/gemma4/image_processing.py` (Gemma-4 SigLIP image preprocessing)
  - `optiq/vlm/_mlxvlm/**` — the vendored mlx-vlm fork's diffusion decode loop,
    the Gemma-4 backbone (`gemma4/`), the DiffusionGemma model (`diffusion_gemma/`),
    the `qwen3_vl/config.py` (a config dependency), the tokenizer/streaming
    detokenizer utilities, and the KV-cache classes.

The package layout under `optiq/` is preserved so the original relative imports
(`from ..gemma4 import …`) keep working when this `diffusion_vendor/` directory
is placed on `sys.path`. The local LLMPro helper that drives it is
`../diffusion_generate.py`.

## Runtime dependencies

The vendored closure depends ONLY on libraries already in the LLMPro runtime
venv: `mlx`, `mlx-lm` (it imports `mlx_lm.models.{cache,base,switch_layers}` and
`mlx_lm.generate`), `transformers`, `numpy`, `Pillow`, and `huggingface_hub`
(the last only to fetch a model/config when given an HF repo id rather than a
local path — the same sanctioned fetch path LLMPro uses elsewhere). **No PyTorch.**

## What was deliberately EXCLUDED (security)

The DANGEROUS parts of `mlx-optiq` — anything that runs subprocesses, opens
sockets, makes HTTP requests, serves an API, or registers runtime patches — were
**deliberately not copied**. The excluded top-level subtrees include
`optiq/{lab,runtime,serve,cli,core,eval,lora,ops}`, `optiq/sandbox.py`,
`optiq/mlx_lm_patches/`, and the various `*_server.py` / `*_shim.py` modules.
**None of those are in the diffusion inference closure.**

Two upstream `__init__.py` files that had eager side-effect imports were replaced
with minimal docstring-only versions in this vendor copy:

- `optiq/__init__.py` — upstream imported `optiq.mlx_lm_patches` at import time.
- `optiq/vlm/__init__.py` — upstream eagerly imported the VLM frontend/sidecar
  registry and other model families' front-ends.

The vendored tree has been grepped to confirm **zero** imports from the excluded
subtrees and **zero** `subprocess` / `socket` / `urllib` / `requests` /
`http.client` / `os.system` / `base64.b64decode` / `pickle.load` / `__import__` /
`exec()` usage. (The only `eval(` occurrences are `mx.eval(...)` and `model.eval()`,
which are MLX graph-evaluation / module-mode calls, not Python `eval`.)

## Modules from other upstream projects

Some of the `optiq/vlm/_mlxvlm/**` and `optiq/vlm/gemma4/**` files are themselves
derived by `mlx-optiq` from the **mlx-vlm** project (BSD-3-Clause), as noted in
their own module docstrings (e.g. `gemma4/image_processing.py`,
`gemma4/__init__.py`). They are redistributed here under the same terms as their
originals; the MIT grant below covers the `mlx-optiq`-authored portions.

---

## MIT License (mlx-optiq, v0.2.3)

```
MIT License

Copyright (c) mlx-optiq contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
