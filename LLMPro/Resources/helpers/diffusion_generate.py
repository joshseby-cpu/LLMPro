"""diffusion_generate.py — text generation with Google's DiffusionGemma on MLX.

DiffusionGemma is a masked/block-diffusion LM (no autoregressive mlx-lm class):
it decodes by iteratively unmasking a fixed-size canvas. This short-lived helper
loads an OptiQ-quantized DiffusionGemma checkpoint and streams a generation,
emitting the standard LLMPro JSON-event protocol (one object per line) so the
Swift side (ProcessRunner) can render tokens as they denoise — see
docs/CONTRACTS.md §3.

The inference code is NOT a pip dependency: it is the vendored ``optiq.vlm``
DiffusionGemma subset that lives next to this file in ``diffusion_vendor/``
(vendored from mlx-optiq v0.2.3, MIT — see ``diffusion_vendor/VENDORED.md`` for
provenance, license, and the deliberately excluded network/subprocess subtrees).
This helper adds that directory to ``sys.path`` and imports
``optiq.vlm.diffusion_gemma``; it needs only mlx / mlx-lm / transformers / numpy,
all already in the LLMPro runtime venv. No torch.

Unlike most mlx_lm helpers this one does NOT go through ``mlx_run.py`` (it is a
direct one-shot), so it self-pins the MLX memory limit like ``inspect_attention``.

CLI:
    python diffusion_generate.py --model <ABS-PATH-or-repo-id> --prompt <text>
        [--max-tokens 512] [--temperature 0.0]
        [--sampler confidence-threshold|entropy-bound]

JSON events on stdout (one object per line):
    {"event":"start","model":...,"max_tokens":N,"temperature":F,"sampler":...}
    {"event":"progress","stage":"load"|"generate"}
    {"event":"token","text":...}                 # one per revealed text segment
    {"event":"done","text":<full>,"prompt_tokens":N,"generation_tokens":N,
     "finish_reason":...,"peak_memory_gb":F,"ms":N}
    {"event":"error","message":...}
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import traceback

# Make the vendored optiq.vlm.diffusion_gemma subtree importable. The package is
# a sibling ``diffusion_vendor/`` dir; everything inside resolves via relative
# imports once that dir is on sys.path.
_VENDOR_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "diffusion_vendor")
if _VENDOR_DIR not in sys.path:
    sys.path.insert(0, _VENDOR_DIR)


def emit(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Generate text with DiffusionGemma on MLX.")
    p.add_argument("--model", required=True, help="Local model dir (abs path) or HF repo id.")
    p.add_argument("--prompt", required=True)
    p.add_argument("--max-tokens", type=int, default=512)
    p.add_argument("--temperature", type=float, default=0.0)
    p.add_argument(
        "--sampler",
        default="confidence-threshold",
        choices=["confidence-threshold", "entropy-bound"],
        help="Diffusion unmasking sampler (default: confidence-threshold).",
    )
    return p.parse_args()


def resolve_model(model: str) -> str:
    """Expand ``~`` for local paths; pass repo ids through untouched.

    ``dg.load`` already converts an existing directory to an absolute path and
    treats anything else as an HF repo id, so this only needs to handle the
    user-home shorthand before that check runs.
    """
    expanded = os.path.expanduser(model)
    return expanded if os.path.isdir(expanded) else model


def pin_memory() -> None:
    """Self-pin MLX memory (this helper bypasses mlx_run.py)."""
    try:
        import mlx.core as mx

        gb = float(os.environ.get("LLMPRO_MEM_LIMIT_GB", "108"))
        limit = int(gb * (1024**3))
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


def main() -> int:
    args = parse_args()
    model_arg = resolve_model(args.model)

    pin_memory()
    emit({"event": "progress", "stage": "load"})

    try:
        import optiq.vlm.diffusion_gemma as dg
    except Exception as exc:
        emit({"event": "error", "message": f"vendored diffusion import failed: {exc}"})
        return 3

    try:
        model, tokenizer = dg.load(model_arg)
    except Exception as exc:
        emit({"event": "error", "message": f"model load failed: {exc}"})
        return 3

    emit(
        {
            "event": "start",
            "model": args.model,
            "max_tokens": args.max_tokens,
            "temperature": args.temperature,
            "sampler": args.sampler,
        }
    )
    # DiffusionGemma is an instruct (-it) model. The vendored stream_generate
    # encodes a raw string with add_special_tokens=True and does NOT apply the
    # chat template, so an un-templated prompt yields garbage. Apply the Gemma
    # chat template and pre-tokenize WITHOUT extra specials (the template already
    # carries BOS), then pass the token-id list so stream_generate uses it
    # directly (its string path would otherwise add a second BOS). Fall back to
    # the raw string if the tokenizer exposes no chat template.
    try:
        templated = tokenizer.apply_chat_template(
            [{"role": "user", "content": args.prompt}],
            tokenize=False,
            add_generation_prompt=True,
        )
        prompt_for_gen = tokenizer.encode(templated, add_special_tokens=False)
    except Exception:
        prompt_for_gen = args.prompt

    emit({"event": "progress", "stage": "generate"})

    full_text = ""
    last_result = None
    t0 = time.perf_counter()
    try:
        for r in dg.stream_generate(
            model,
            tokenizer,
            prompt_for_gen,
            max_tokens=args.max_tokens,
            temperature=args.temperature,
            sampler=args.sampler,
        ):
            last_result = r
            # Draft frames are intermediate canvas-unmasking states, not final
            # text; only revealed (non-draft) segments contribute to the output.
            if getattr(r, "is_draft", False):
                continue
            text = r.text
            if text:
                full_text += text
                emit({"event": "token", "text": text})
    except Exception as exc:
        emit({"event": "error", "message": f"generation failed: {exc}"})
        return 4

    elapsed_ms = int((time.perf_counter() - t0) * 1000)
    done: dict = {"event": "done", "text": full_text, "ms": elapsed_ms}
    if last_result is not None:
        done["prompt_tokens"] = int(getattr(last_result, "prompt_tokens", 0))
        done["generation_tokens"] = int(getattr(last_result, "generation_tokens", 0))
        done["finish_reason"] = getattr(last_result, "finish_reason", None)
        peak = getattr(last_result, "peak_memory", None)
        if peak is not None:
            done["peak_memory_gb"] = round(float(peak), 3)
    emit(done)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        emit({"event": "error", "message": "Interrupted"})
        raise SystemExit(130)
    except Exception as exc:
        emit(
            {
                "event": "error",
                "message": f"{type(exc).__name__}: {exc}\n{traceback.format_exc()[:500]}",
            }
        )
        raise SystemExit(1)
