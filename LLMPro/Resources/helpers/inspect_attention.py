"""inspect_attention.py — capture attention weights from ONE forward pass.

The Inspect tab's "Attention" pane calls this short-lived sidecar: load a model,
run a single forward pass over a short prompt, recompute the per-head
softmax(QK^T) attention matrices, and emit them (averaged over heads by default)
as JSON for a heatmap — then exit. The long-lived `mlx_lm server` does NOT expose
attention, so this is a one-shot helper.

How it works: every mainstream model in mlx-lm computes attention through the
single shared kernel `mx.fast.scaled_dot_product_attention`, which is fused and
returns ONLY the output (never the weights). So we monkeypatch that symbol with a
wrapper that ALSO recomputes scores = (Q*scale) @ Kᵀ (expanding KV heads for GQA),
applies the same mask, softmaxes over the last axis, stashes the matrix, and then
delegates to the original kernel so the model output is bit-identical. Architectures
that bypass the shared kernel (gemma3n, llama4, qwen3_next, …) capture nothing —
we detect those by model_type and emit a clean `unsupported` event.

Memory: attention is O(L^2 * heads * layers), so we cap sequence length hard and
self-pin the MLX memory limit (this helper does NOT go through mlx_run.py).

CLI:
    python inspect_attention.py --model <ABS-PATH-or-repo-id> --prompt <text>
        [--max-seq 64] [--layers all|0,5,10] [--head mean|<int>]

JSON events on stdout (one object per line):
    {"event":"start","model":...,"model_type":...,"tokens":[...],"n_layers":N,
     "n_heads":N,"seq_len":N,"truncated":bool}
    {"event":"unsupported","model_type":...,"message":...}   # then exit 0
    {"event":"progress","stage":"load"|"forward"}
    {"event":"layer","layer":i,"shape":[Lq,Lk],"weights":[[float,...],...]}
    {"event":"done","n_layers":N}
    {"event":"error","message":...}
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import traceback


def emit(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()


# Architectures whose attention does NOT route through the shared
# mx.fast.scaled_dot_product_attention kernel — the monkeypatch can't see them.
UNSUPPORTED_TYPES = {
    "gemma3n",       # AltUp / MatFormer
    "llama4",        # chunked attention
    "qwen3_next",    # gated-delta linear attention
    "mamba", "mamba2", "rwkv", "recurrent_gemma",
}


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--model", required=True)
    p.add_argument("--prompt", required=True)
    p.add_argument("--max-seq", type=int, default=64)
    p.add_argument("--layers", default="all")        # "all" or "0,5,10"
    p.add_argument("--head", default="mean")          # "mean" or an int head index
    return p.parse_args()


def pin_memory() -> None:
    """Self-pin MLX memory (this helper bypasses mlx_run.py)."""
    try:
        import mlx.core as mx
        gb = float(os.environ.get("LLMPRO_MEM_LIMIT_GB", "108"))
        limit = int(gb * (1024 ** 3))
        if hasattr(mx, "set_memory_limit"):
            mx.set_memory_limit(limit)
        if hasattr(mx, "set_wired_limit"):
            try:
                mx.set_wired_limit(limit)
            except Exception:
                pass
        if hasattr(mx, "set_cache_limit"):
            mx.set_cache_limit(limit // 2)
    except Exception:
        pass


def detect_model_type(model_path: str) -> str:
    """Read model_type from config.json (top level or nested text_config)."""
    cfg_path = os.path.join(model_path, "config.json")
    try:
        with open(cfg_path, "r", encoding="utf-8") as fh:
            cfg = json.load(fh)
    except Exception:
        return "unknown"
    mt = cfg.get("model_type")
    if not mt and isinstance(cfg.get("text_config"), dict):
        mt = cfg["text_config"].get("model_type")
    return mt or "unknown"


def main() -> int:
    args = parse_args()

    # Cheap architecture gate BEFORE loading multi-GB weights.
    model_type = detect_model_type(args.model)
    if model_type in UNSUPPORTED_TYPES:
        emit({"event": "unsupported", "model_type": model_type,
              "message": f"{model_type} doesn't use the standard attention kernel the inspector taps into."})
        return 0

    pin_memory()
    emit({"event": "progress", "stage": "load"})

    try:
        import mlx.core as mx
        from mlx_lm.utils import load
    except Exception as exc:
        emit({"event": "error", "message": f"mlx import failed: {exc}"})
        return 3

    try:
        model, tokenizer = load(args.model)
    except Exception as exc:
        emit({"event": "error", "message": f"model load failed: {exc}"})
        return 3

    # Locate the fused-attention symbol. If it's absent, this mlx build/arch path
    # doesn't go through it → unsupported.
    try:
        fast = mx.fast
        original_sdpa = fast.scaled_dot_product_attention
    except Exception:
        emit({"event": "unsupported", "model_type": model_type,
              "message": "This MLX build doesn't expose the shared attention kernel."})
        return 0

    store: list = []   # (call_index, attention matrix as (B, heads, Lq, Lk) mx.array)

    def patched(q, k, v, *, scale=1.0, mask=None, **kwargs):
        try:
            nq = q.shape[-3]      # query heads
            nk = k.shape[-3]      # kv heads (GQA: nk < nq)
            kk = k
            if nk != nq and nk > 0 and nq % nk == 0:
                # Expand KV heads to match query heads (grouped-query attention).
                kk = mx.repeat(k, nq // nk, axis=-3)
            scores = (q * scale) @ kk.swapaxes(-1, -2)
            if isinstance(mask, mx.array):
                scores = scores + mask.astype(scores.dtype)
            elif isinstance(mask, str) and mask == "causal":
                L, S = scores.shape[-2], scores.shape[-1]
                causal = mx.tril(mx.ones((L, S), dtype=mx.bool_), k=S - L)
                scores = mx.where(causal, scores, mx.array(-1e9, dtype=scores.dtype))
            weights = mx.softmax(scores.astype(mx.float32), axis=-1)
            store.append((len(store), weights))
        except Exception:
            # Never let capture break the real forward pass.
            pass
        return original_sdpa(q, k, v, scale=scale, mask=mask, **kwargs)

    # Tokenize + truncate.
    ids = tokenizer.encode(args.prompt)
    truncated = len(ids) > args.max_seq
    ids = ids[: args.max_seq]
    seq_len = len(ids)
    try:
        token_strs = [tokenizer.decode([t]) for t in ids]
    except Exception:
        token_strs = [str(t) for t in ids]

    emit({"event": "progress", "stage": "forward"})
    fast.scaled_dot_product_attention = patched
    try:
        out = model(mx.array([ids]))
        mx.eval(out)
    except Exception as exc:
        fast.scaled_dot_product_attention = original_sdpa
        emit({"event": "error", "message": f"forward pass failed: {exc}"})
        return 4
    finally:
        fast.scaled_dot_product_attention = original_sdpa

    if not store:
        emit({"event": "unsupported", "model_type": model_type,
              "message": "No attention captured — this model bypasses the shared kernel."})
        return 0

    n_layers = len(store)
    # n_heads from the first captured matrix: (B, heads, Lq, Lk)
    first = store[0][1]
    n_heads = first.shape[1] if first.ndim == 4 else 1

    # Which layers to emit.
    if args.layers == "all":
        wanted = list(range(n_layers))
    else:
        try:
            wanted = [int(x) for x in args.layers.split(",") if x.strip() != ""]
        except ValueError:
            wanted = list(range(n_layers))
    wanted = [i for i in wanted if 0 <= i < n_layers]

    emit({"event": "start", "model": args.model, "model_type": model_type,
          "tokens": token_strs, "n_layers": n_layers, "n_heads": int(n_heads),
          "seq_len": seq_len, "truncated": truncated})

    head_mode = args.head
    for idx in wanted:
        _, w = store[idx]
        # w: (B, heads, Lq, Lk) — take batch 0.
        m = w[0]
        if head_mode == "mean":
            reduced = mx.mean(m, axis=0)          # (Lq, Lk)
        else:
            try:
                h = int(head_mode)
                reduced = m[max(0, min(h, m.shape[0] - 1))]
            except ValueError:
                reduced = mx.mean(m, axis=0)
        mx.eval(reduced)
        rows = reduced.tolist()
        rounded = [[round(float(x), 4) for x in row] for row in rows]
        emit({"event": "layer", "layer": idx,
              "shape": [len(rounded), len(rounded[0]) if rounded else 0],
              "weights": rounded})

    emit({"event": "done", "n_layers": len(wanted)})
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        emit({"event": "error", "message": "Interrupted"})
        raise SystemExit(130)
    except Exception as exc:
        emit({"event": "error", "message": f"{type(exc).__name__}: {exc}\n{traceback.format_exc()[:500]}"})
        raise SystemExit(1)
