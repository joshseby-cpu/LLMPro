"""eval_pass_rate.py — measure pass@k of a model (+ optional adapter) on a
held-out coding eval set.

Default (--k 1): one greedy generation per prompt = pass@1. This path is kept
byte-for-byte compatible with earlier versions — the `done` event still carries
`pass_at_1` (SelfImproveService depends on it) and the `row` event keeps its
original {passed, reason} shape.

With --k > 1: generate k candidates per prompt at a sampling temperature > 0 and
count the row as passing if ANY candidate passes its tests (standard pass@k).

Reads the same row shape humaneval_pull.py writes:
  {"task_id":..., "prompt":..., "tests":..., "entry_point":..., "messages":[...]}

CLI:
    python eval_pass_rate.py
        --eval <eval.jsonl>
        --model <repo-id-or-abs-path>
        [--adapter <path>]
        [--k 1]                # number of candidates per prompt (pass@k)
        [--max-tokens 512]
        [--temperature 0.0]    # for k>1, defaults to 0.2 unless set explicitly
        [--top-p 1.0]
        [--row-timeout 15]
        [--limit 0]

JSON events on stdout:
    {"event":"start", "rows":N, "k":K, "model":..., "adapter":...}
    {"event":"model_loaded", "ms":...}
  k == 1 (default, unchanged):
    {"event":"row", "i":i, "task_id":..., "passed":bool, "reason":"..."}
    {"event":"done", "pass_at_1":float, "pass_at_k":float, "k":1,
                     "passed":N, "total":N, "ms":...}
  k > 1:
    {"event":"row", "i":i, "task_id":..., "passed":bool, "reason":"...",
                    "passes":m, "k":K}
    {"event":"done", "pass_at_k":float, "k":K, "passed":N, "total":N, "ms":...}
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
    p.add_argument("--k",           type=int,   default=1,
                   help="candidates per prompt; row passes if any passes (pass@k)")
    p.add_argument("--max-tokens",  type=int,   default=512)
    # default=None so we can tell "user left it" from "user asked for 0.0".
    # For k>1 we fall back to 0.2 (a sampling temp) so candidates differ;
    # for k==1 we fall back to 0.0 (greedy) — the unchanged pass@1 path.
    p.add_argument("--temperature", type=float, default=None)
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

    k = max(1, args.k)
    # k==1 → greedy (temp 0.0) so the default path stays deterministic and
    # byte-for-byte unchanged. k>1 → need temp>0 or every candidate is the
    # same greedy completion; default to 0.2 unless the caller set --temperature.
    if args.temperature is not None:
        temperature = args.temperature
    else:
        temperature = 0.0 if k == 1 else 0.2

    adapter = args.adapter or None
    emit({"event": "start", "rows": len(rows), "k": k,
          "model": args.model, "adapter": adapter})

    try:
        t0 = time.monotonic()
        model, tokenizer = load_model(args.model, adapter)
        emit({"event": "model_loaded",
              "ms": int((time.monotonic() - t0) * 1000)})
        sampler = make_sampler(temperature, args.top_p)
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
            evt = {"event": "row", "i": i, "task_id": task_id,
                   "passed": False, "reason": "missing prompt/tests"}
            if k > 1:
                evt["passes"] = 0
                evt["k"] = k
            emit(evt)
            continue
        user_msg = (
            row.get("messages", [{}])[0].get("content")
            if row.get("messages") else None
        ) or (
            "Complete the following Python function. Return the full function "
            "inside a single ```python code block.\n\n"
            f"```python\n{prompt}```"
        )

        # Generate k candidates and count how many pass; the row passes if ANY
        # candidate passes (standard pass@k). We run all k (rather than
        # short-circuiting on the first pass) so the `passes` count is the true
        # number of passing candidates, matching self_improve_round's `passes`.
        # For k==1 this is exactly one generation + one test, i.e. the original
        # greedy pass@1 path.
        row_passes = 0
        ok = False
        last_reason = "no candidates"
        for _cand in range(k):
            try:
                resp = generate_one(model, tokenizer, sampler, user_msg,
                                    max_tokens=args.max_tokens,
                                    temperature=temperature,
                                    top_p=args.top_p)
            except Exception as exc:
                last_reason = f"gen: {exc.__class__.__name__}"
                continue
            code = extract_code(resp)
            cand_ok, reason = run_one_test(code, tests, entry, args.row_timeout)
            if cand_ok:
                row_passes += 1
                ok = True
                last_reason = ""
            elif not ok:
                # Only keep a fail reason if we haven't already seen a pass.
                last_reason = reason

        if ok:
            passed += 1
        evt = {"event": "row", "i": i, "task_id": task_id,
               "passed": ok, "reason": "" if ok else last_reason}
        if k > 1:
            evt["passes"] = row_passes
            evt["k"] = k
        emit(evt)
        if _has_mlx_clear:
            try: _mx.clear_cache()
            except Exception: pass

    total = max(1, len(rows))
    pass_at_k = passed / total
    done = {"event": "done",
            "pass_at_k": pass_at_k,
            "k":         k,
            "passed":    passed,
            "total":     len(rows),
            "ms":        int((time.monotonic() - t_start) * 1000)}
    # Keep `pass_at_1` for backward compatibility. When k==1 it IS the greedy
    # pass@1, so it equals pass_at_k. For k>1 we don't run a separate greedy
    # pass, so we omit `pass_at_1` and callers should read `pass_at_k`.
    if k == 1:
        done["pass_at_1"] = pass_at_k
    emit(done)
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
