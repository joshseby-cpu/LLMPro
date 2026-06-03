"""eval_pass_rate.py — measure pass@1 of a model (+ optional adapter) on a
held-out coding eval set. One generation per prompt, greedy by default.

Reads the same row shape humaneval_pull.py writes:
  {"task_id":..., "prompt":..., "tests":..., "entry_point":..., "messages":[...]}

CLI:
    python eval_pass_rate.py
        --eval <eval.jsonl>
        --model <repo-id-or-abs-path>
        [--adapter <path>]
        [--max-tokens 512]
        [--temperature 0.0]
        [--top-p 1.0]
        [--row-timeout 15]
        [--limit 0]

JSON events on stdout:
    {"event":"start", "rows":N, "model":..., "adapter":...}
    {"event":"model_loaded", "ms":...}
    {"event":"row", "i":i, "task_id":..., "passed":bool, "reason":"..."}
    {"event":"done", "pass_at_1": float, "passed":N, "total":N, "ms":...}
    {"event":"error", "message":"..."}
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

# Reuse the round helper's primitives. They sit next to us in the helpers dir.
HERE = Path(__file__).parent
sys.path.insert(0, str(HERE))
from self_improve_round import (  # type: ignore  noqa: E402
    emit, read_jsonl, extract_code, run_one_test,
    load_model, make_sampler, generate_one,
)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--eval", required=True)
    p.add_argument("--model", required=True)
    p.add_argument("--adapter", default="")
    p.add_argument("--max-tokens",  type=int,   default=512)
    p.add_argument("--temperature", type=float, default=0.0)
    p.add_argument("--top-p",       type=float, default=1.0)
    p.add_argument("--row-timeout", type=int,   default=15)
    p.add_argument("--limit",       type=int,   default=0)
    return p.parse_args()


def main() -> int:
    args = parse_args()
    eval_path = Path(args.eval)
    if not eval_path.exists():
        emit({"event": "error", "message": f"eval not found: {eval_path}"})
        return 2

    rows = read_jsonl(eval_path)
    if args.limit and args.limit > 0:
        rows = rows[: args.limit]

    adapter = args.adapter or None
    emit({"event": "start", "rows": len(rows),
          "model": args.model, "adapter": adapter})

    try:
        t0 = time.monotonic()
        model, tokenizer = load_model(args.model, adapter)
        emit({"event": "model_loaded",
              "ms": int((time.monotonic() - t0) * 1000)})
        sampler = make_sampler(args.temperature, args.top_p)
    except Exception as exc:
        emit({"event": "error", "message": f"model load failed: {exc}"})
        return 3

    passed = 0
    t_start = time.monotonic()

    # See self_improve_round for the rationale — clear mlx allocator cache
    # between rows so the resident set doesn't drift up across 30+ generations.
    try:
        import mlx.core as _mx  # type: ignore
        _has_mlx_clear = hasattr(_mx, "clear_cache")
    except Exception:
        _mx = None
        _has_mlx_clear = False

    for i, row in enumerate(rows):
        prompt   = row.get("prompt") or ""
        tests    = row.get("tests")  or ""
        entry    = row.get("entry_point") or ""
        task_id  = row.get("task_id") or f"row-{i}"
        if not (prompt and tests):
            emit({"event": "row", "i": i, "task_id": task_id,
                  "passed": False, "reason": "missing prompt/tests"})
            continue
        user_msg = (
            row.get("messages", [{}])[0].get("content")
            if row.get("messages") else None
        ) or (
            "Complete the following Python function. Return the full function "
            "inside a single ```python code block.\n\n"
            f"```python\n{prompt}```"
        )
        try:
            resp = generate_one(model, tokenizer, sampler, user_msg,
                                max_tokens=args.max_tokens,
                                temperature=args.temperature,
                                top_p=args.top_p)
        except Exception as exc:
            emit({"event": "row", "i": i, "task_id": task_id,
                  "passed": False, "reason": f"gen: {exc.__class__.__name__}"})
            continue
        code = extract_code(resp)
        ok, reason = run_one_test(code, tests, entry, args.row_timeout)
        if ok:
            passed += 1
        emit({"event": "row", "i": i, "task_id": task_id,
              "passed": ok, "reason": "" if ok else reason})
        if _has_mlx_clear:
            try: _mx.clear_cache()
            except Exception: pass

    total = max(1, len(rows))
    pass_at_1 = passed / total
    emit({"event": "done",
          "pass_at_1": pass_at_1,
          "passed":    passed,
          "total":     len(rows),
          "ms":        int((time.monotonic() - t_start) * 1000)})
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        emit({"event": "error", "message": "Interrupted"})
        raise SystemExit(130)
    except Exception as exc:
        emit({"event": "error", "message": f"{type(exc).__name__}: {exc}"})
        raise SystemExit(1)
