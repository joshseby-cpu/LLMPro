"""profile_experts.py — measure which experts a MoE actually uses.

Loads a Mixture-of-Experts model, runs a batch of representative prompts through
a single forward pass each, and records which experts the router selects for
every token at every layer. The output is a per-expert activation histogram plus
a recommendation of "cold" experts (rarely or never selected) that could be
pruned to reclaim resident GPU memory — the experts are usually the bulk of an
MoE's footprint, but only top-k fire per token.

How routers are found (architecture-agnostic): a router/gate is a projection
whose output dimension equals num_experts. We scan every module for a `.weight`
of shape [num_experts, hidden] and tag it; then we patch nn.Linear /
nn.QuantizedLinear `__call__` to record the top-k selection of the tagged
modules' outputs. This works for Mixtral (`block_sparse_moe.gate`), Qwen-MoE /
OlmoE / Granite-MoE (`mlp.gate`), and Gemma-4 (`router.proj`).

Invoked as:  python profile_experts.py <model_dir> <args_json>
  args_json: {"max_prompts": 24, "prompts": [...], "dataset": "/path.jsonl"}
             (all optional; a built-in coding prompt set is used by default)

Emits JSON lines: start | progress | done | error.
  done: {"event":"done","num_experts":N,"top_k":K,"decisions":D,
         "counts":[...N...],"fractions":[...N...],"cold":[idx,...],
         "cold_threshold":F,"prompts":P}
"""

from __future__ import annotations

import json
import sys
from pathlib import Path


def emit(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()


DEFAULT_PROMPTS = [
    "Write a Python function that returns the nth Fibonacci number.",
    "Explain the difference between a list and a tuple in Python.",
    "Write a C# method that reverses a string.",
    "Create a Blazor component that shows a counter with an increment button.",
    "Implement binary search in JavaScript.",
    "What is a closure? Give an example in Python.",
    "Write a SQL query to find the second highest salary in an Employees table.",
    "Refactor this loop into a list comprehension: result = []\\nfor x in nums:\\n    if x > 0:\\n        result.append(x*x)",
    "Write a unit test for a function add(a, b) using pytest.",
    "Explain async/await in C# with a short example.",
    "Implement a debounce function in TypeScript.",
    "Write a regular expression that matches a valid email address.",
    "How do I read a file line by line in Python?",
    "Write a function to check whether a string is a palindrome.",
    "Create a REST controller in ASP.NET Core that returns a list of products.",
    "Explain the time complexity of quicksort.",
]


def _find_int(cfg: dict, *keys):
    for d in (cfg, cfg.get("text_config", {}) or {}, cfg.get("ffn_config", {}) or {}):
        if isinstance(d, dict):
            for k in keys:
                v = d.get(k)
                if isinstance(v, int):
                    return v
    return 0


def main() -> int:
    if len(sys.argv) < 2:
        emit({"event": "error", "message": "Usage: profile_experts.py <model_dir> [args_json]"})
        return 2
    src = Path(sys.argv[1])
    try:
        args = json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}
    except Exception as exc:  # noqa: BLE001
        emit({"event": "error", "message": f"Bad args JSON: {exc}"})
        return 3

    if not (src / "config.json").exists():
        emit({"event": "error", "message": f"No config.json in {src}"})
        return 4
    cfg = json.loads((src / "config.json").read_text())
    num_experts = _find_int(cfg, "num_local_experts", "num_experts", "moe_num_experts")
    top_k = _find_int(cfg, "num_experts_per_tok", "top_k_experts", "moe_top_k", "num_experts_per_token")
    if num_experts <= 1:
        emit({"event": "error", "message": "Not an MoE model (num_experts <= 1)."})
        return 5
    if top_k <= 0:
        top_k = 1

    try:
        import numpy as np
        import mlx.core as mx
        import mlx.nn as nn
        from mlx_lm import load
    except Exception as exc:  # noqa: BLE001
        emit({"event": "error", "message": f"Missing dependency: {exc}"})
        return 6

    emit({"event": "start", "src": str(src), "num_experts": num_experts, "top_k": top_k})
    emit({"event": "progress", "stage": "loading", "message": "Loading model (this can take a minute for large MoEs)…"})
    try:
        model, tokenizer = load(str(src))
    except Exception as exc:  # noqa: BLE001
        emit({"event": "error", "message": f"Failed to load model: {exc}"})
        return 7

    # Identify router/gate modules: any module exposing a 2-D weight whose first
    # dim equals num_experts. Quantized layers store the unpacked shape too.
    routers = set()
    try:
        named = list(model.named_modules())
    except Exception:
        named = []
    for _name, mod in named:
        w = getattr(mod, "weight", None)
        shape = getattr(w, "shape", None)
        if shape is not None and len(shape) == 2 and int(shape[0]) == num_experts:
            routers.add(id(mod))
    if not routers:
        emit({"event": "error",
              "message": "Couldn't locate any router/gate projection (no module weight with first dim == num_experts). This MoE's routing may be implemented in a way the profiler doesn't recognize yet."})
        return 8
    emit({"event": "progress", "stage": "instrumenting",
          "message": f"Found {len(routers)} router projections across the layers."})

    counts = np.zeros(num_experts, dtype=np.int64)
    decisions = {"n": 0}

    def record(out):
        try:
            logits = out
            E = int(logits.shape[-1])
            k = min(top_k, E)
            # top-k indices over last axis (largest values)
            part = mx.argpartition(logits, kth=E - k, axis=-1)
            idx = part[..., E - k:]
            arr = np.array(idx).reshape(-1).astype(np.int64)
            binc = np.bincount(arr, minlength=num_experts)
            counts[:binc.shape[0]] += binc
            decisions["n"] += int(arr.size // k)
        except Exception:
            pass

    # Patch Linear-family __call__ to tap the tagged routers.
    patched = []

    def patch(cls):
        if cls is None or not hasattr(cls, "__call__"):
            return
        orig = cls.__call__

        def wrapped(self, x, *a, **k):
            out = orig(self, x, *a, **k)
            if id(self) in routers:
                record(out)
            return out

        cls.__call__ = wrapped
        patched.append((cls, orig))

    patch(getattr(nn, "Linear", None))
    patch(getattr(nn, "QuantizedLinear", None))

    # Prompts.
    prompts = list(args.get("prompts") or [])
    ds = args.get("dataset")
    if ds and Path(ds).exists():
        for line in Path(ds).read_text().splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except Exception:
                continue
            msgs = row.get("messages")
            if isinstance(msgs, list) and msgs:
                first_user = next((m.get("content", "") for m in msgs if m.get("role") == "user"), "")
                if first_user:
                    prompts.append(first_user)
            elif isinstance(row.get("prompt"), str):
                prompts.append(row["prompt"])
    if not prompts:
        prompts = list(DEFAULT_PROMPTS)
    max_prompts = int(args.get("max_prompts", 24))
    prompts = prompts[:max_prompts]

    try:
        for i, p in enumerate(prompts, start=1):
            try:
                ids = tokenizer.encode(p)
            except Exception:
                ids = tokenizer(p)["input_ids"] if hasattr(tokenizer, "__call__") else []
            if not ids:
                continue
            x = mx.array([ids])
            out = model(x)
            mx.eval(out)
            emit({"event": "progress", "stage": "profiling",
                  "message": f"Prompt {i} / {len(prompts)} · {decisions['n']} routing decisions so far"})
    finally:
        for cls, orig in patched:
            cls.__call__ = orig

    total = max(1, decisions["n"])
    fractions = (counts / total).tolist()
    avg = float(counts.sum()) / max(1, num_experts)
    cold_threshold = 0.2  # selected < 20% of an even share
    even_share = float(counts.sum()) / num_experts if num_experts else 0.0
    cold = [int(i) for i in range(num_experts)
            if counts[i] < cold_threshold * even_share]

    emit({
        "event": "done",
        "num_experts": num_experts,
        "top_k": top_k,
        "decisions": int(decisions["n"]),
        "counts": [int(c) for c in counts.tolist()],
        "fractions": fractions,
        "cold": cold,
        "cold_threshold": cold_threshold,
        "avg_count": avg,
        "prompts": len(prompts),
    })
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
