"""self_improve_round.py — one round of the LLMPro self-improvement loop.

Pipeline (single Python process so the model loads once):

  1. Load <seed_jsonl>: list of {prompt, tests, entry_point, messages, ...}
  2. Load model (+ optional adapter) via mlx_lm.utils.load
  3. For each row, generate K candidate completions (temp > 0 for diversity)
  4. Extract a Python code block from each candidate
  5. Run the candidate's code + the row's `tests` in a sandboxed subprocess
     (15s wall-clock timeout, 1 GB RSS cap, no stdin) — pass = exit 0
  6. Keep the FIRST passing candidate per prompt (rejection-sampling self-distillation)
  7. Write `dataset/train.jsonl`, `dataset/valid.jsonl`, `dataset/test.jsonl` in the
     mlx-lm chat schema, where assistant content is the passing code block
  8. Write `results.jsonl` (one line per prompt: pass/fail counts, kept candidate)

CLI:
    python self_improve_round.py
        --seed   <path/to/seed.jsonl>
        --out    <path/to/round_N/>
        --model  <absolute-path-or-hf-repo>
        [--adapter <path>]
        [--candidates 4]
        [--max-tokens 512]
        [--temperature 0.7]
        [--top-p 0.95]
        [--row-timeout 15]
        [--limit 0]   # 0 = all

JSON events on stdout (one per line, key="event"):
    {"event":"start", "rows":N, "candidates":K, "model":..., "adapter":...}
    {"event":"model_loaded", "ms":..., "with_adapter":bool}
    {"event":"row_start",  "i":i, "task_id":..., "prompt_preview":"..."}
    {"event":"candidate",  "i":i, "k":k, "status":"pass"|"fail",
                            "fail_reason":"<short>"}
    {"event":"row_done",   "i":i, "passed":bool, "passes":m, "total":K}
    {"event":"progress",   "stage":"write", "message":"Wrote N rows to train.jsonl"}
    {"event":"done",       "kept":N, "rows":N_in, "pass_rate":float,
                            "train":N, "valid":N, "test":N}
    {"event":"error", "message":"..."}
"""

from __future__ import annotations

import argparse
import json
import os
import random
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
from pathlib import Path
from typing import Any, Iterable


# ─── stdout JSON-event protocol ───────────────────────────────────────────

def emit(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()


# ─── code-block extraction ────────────────────────────────────────────────

_FENCED_PY = re.compile(r"```(?:python|py)?\s*\n(.*?)```", re.DOTALL | re.IGNORECASE)


def _normalize_code(code: str) -> str:
    """Whitespace-insensitive key for de-duplicating passing candidates."""
    return " ".join(code.split())


def extract_code(response: str) -> str:
    """Pull a python code block out of a model response.

    Strategy: prefer the LAST ```python ... ``` block (models often re-state
    the prompt then write the real solution second). Fall back to the FIRST
    fenced block of any kind. Fall back to the raw response.
    """
    matches = _FENCED_PY.findall(response)
    if matches:
        return matches[-1].strip("\n")
    # generic fenced block (no language marker)
    generic = re.findall(r"```\s*\n(.*?)```", response, re.DOTALL)
    if generic:
        return generic[-1].strip("\n")
    return response.strip()


# ─── sandboxed test execution ─────────────────────────────────────────────

# Run inside a separate process so a bad sample (infinite loop, segfault, OOM,
# silly imports) can't take down the round.

_RUNNER_TEMPLATE = textwrap.dedent("""
    import resource, signal, sys, traceback

    # Resource caps so a malicious / runaway sample can't harm the host. Each is
    # best-effort (wrapped) — a missing rlimit on some platform shouldn't abort
    # the test, the parent's timeout + process-group kill is the real backstop.
    #   RLIMIT_AS    — address space, blocks OOM of the host
    #   RLIMIT_NPROC — max processes for this uid, blocks fork bombs
    #   RLIMIT_FSIZE — max bytes any single file write, caps disk abuse
    #   RLIMIT_CPU   — CPU-seconds, belt for the wall-clock alarm below
    for _name, _limit in (
        ("RLIMIT_AS",    1_073_741_824),       # 1 GiB address space
        ("RLIMIT_NPROC", 64),                   # no fork bombs
        ("RLIMIT_FSIZE", 67_108_864),           # 64 MiB max single-file write
        ("RLIMIT_CPU",   {timeout} + 5),        # CPU-seconds backstop
    ):
        try:
            _r = getattr(resource, _name)
            resource.setrlimit(_r, (_limit, _limit))
        except Exception:
            pass

    # Hard wall-clock cap inside the child as a belt for the parent's
    # `timeout` belt-and-suspenders.
    def _alarm(_sig, _frm):
        sys.exit(124)
    try:
        signal.signal(signal.SIGALRM, _alarm)
        signal.alarm({timeout})
    except Exception:
        pass

    SOURCE = {source!r}
    TESTS  = {tests!r}
    ENTRY  = {entry!r}

    namespace = {{}}
    try:
        exec(SOURCE, namespace)
    except SystemExit as e:
        sys.exit(11)
    except BaseException:
        traceback.print_exc()
        sys.exit(2)

    if ENTRY and ENTRY not in namespace:
        sys.stderr.write(f"missing entry_point: {{ENTRY}}\\n")
        sys.exit(3)

    try:
        exec(TESTS, namespace)
    except BaseException:
        traceback.print_exc()
        sys.exit(4)

    # If tests define a `check(candidate)` (HumanEval/MBPP convention) — call it.
    if "check" in namespace and ENTRY in namespace:
        try:
            namespace["check"](namespace[ENTRY])
        except BaseException:
            traceback.print_exc()
            sys.exit(5)
    sys.exit(0)
""")


# Minimal env handed to model-generated code. We deliberately do NOT forward the
# full process environment — that would leak any HF token / API secrets into
# arbitrary generated code. Only the bare essentials a normal Python program
# needs to start are allowlisted.
_ENV_ALLOWLIST = ("PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE")


def _sandbox_env() -> dict[str, str]:
    env = {k: os.environ[k] for k in _ENV_ALLOWLIST if k in os.environ}
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    return env


def run_one_test(code: str, tests: str, entry: str, timeout: int) -> tuple[bool, str]:
    """Run `code + tests` in a hardened subprocess. Returns (passed, short_reason).

    Containment layers (defence in depth — none is load-bearing alone):
      • child runs in a fresh process group (`start_new_session=True`) so on a
        timeout we can SIGKILL the WHOLE group, reaping any forked grandchildren
        that `subprocess`'s direct-child kill would otherwise orphan;
      • child gets a STRIPPED env (no HF/API secrets — see _sandbox_env);
      • child's cwd is a throwaway tempdir, so any file writes land there, never
        in the app's project tree (cleaned up in the finally);
      • additional rlimits (NPROC/FSIZE/CPU/AS) + SIGALRM are set in the child
        via _RUNNER_TEMPLATE.
    """
    runner = _RUNNER_TEMPLATE.format(source=code, tests=tests, entry=entry, timeout=timeout)
    with tempfile.NamedTemporaryFile("w", suffix=".py", delete=False) as fh:
        fh.write(runner)
        runner_path = fh.name
    work_dir = tempfile.mkdtemp(prefix="llmpro_si_")
    proc: subprocess.Popen | None = None
    try:
        proc = subprocess.Popen(
            [sys.executable, runner_path],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            cwd=work_dir,                  # writes land in throwaway space
            env=_sandbox_env(),            # no inherited secrets
            start_new_session=True,        # own process group → group-kill on timeout
        )
        try:
            out, err = proc.communicate(timeout=timeout + 5)  # belt: parent kills if child's alarm misses
        except subprocess.TimeoutExpired:
            # Kill the WHOLE group so forked grandchildren don't survive as orphans.
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            except (ProcessLookupError, PermissionError, OSError):
                try:
                    proc.kill()
                except Exception:
                    pass
            try:
                proc.communicate(timeout=5)   # reap the now-dead group
            except Exception:
                pass
            return False, "timeout"
        if proc.returncode == 0:
            return True, "ok"
        msg = (err or out or "").strip().splitlines()
        short = msg[-1][:120] if msg else f"exit {proc.returncode}"
        return False, short
    except Exception as exc:
        # Last-ditch: ensure no stray group is left running before we return.
        if proc is not None and proc.poll() is None:
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            except Exception:
                try: proc.kill()
                except Exception: pass
        return False, f"runner: {exc.__class__.__name__}"
    finally:
        try: os.unlink(runner_path)
        except Exception: pass
        try: shutil.rmtree(work_dir, ignore_errors=True)
        except Exception: pass


# ─── data IO ──────────────────────────────────────────────────────────────

def read_jsonl(path: Path) -> list[dict]:
    rows: list[dict] = []
    with path.open("r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def write_jsonl(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as fh:
        for r in rows:
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")


# ─── mlx_lm bindings (loaded lazily so an import error gets a clean event) ───

def load_model(model_path: str, adapter_path: str | None):
    from mlx_lm.utils import load
    if adapter_path:
        return load(model_path, adapter_path=adapter_path)
    return load(model_path)


def make_sampler(temperature: float, top_p: float):
    """Return whatever sampler the installed mlx_lm version expects."""
    try:
        from mlx_lm.sample_utils import make_sampler as _ms  # newer mlx_lm
        return _ms(temp=temperature, top_p=top_p)
    except Exception:
        return None  # generate() will read temp/top_p positionally


def generate_one(model, tokenizer, sampler, user_prompt: str,
                 max_tokens: int, temperature: float, top_p: float) -> str:
    from mlx_lm.generate import generate as _generate
    full_prompt = tokenizer.apply_chat_template(
        [{"role": "user", "content": user_prompt}],
        tokenize=False,
        add_generation_prompt=True,
    )
    # mlx_lm.generate has shifted signatures across versions — try the modern
    # (sampler=) call first, fall back to legacy positional temp/top_p.
    try:
        if sampler is not None:
            return _generate(model, tokenizer, prompt=full_prompt,
                              max_tokens=max_tokens, sampler=sampler, verbose=False)
        return _generate(model, tokenizer, prompt=full_prompt,
                          max_tokens=max_tokens, temp=temperature, top_p=top_p,
                          verbose=False)
    except TypeError:
        return _generate(model, tokenizer, full_prompt, max_tokens)


# ─── main ────────────────────────────────────────────────────────────────

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--seed", required=True)
    p.add_argument("--out",  required=True)
    p.add_argument("--model", required=True)
    p.add_argument("--adapter", default="")
    p.add_argument("--candidates",  type=int,   default=4)
    p.add_argument("--keep-per-problem", type=int, default=1)
    p.add_argument("--max-tokens",  type=int,   default=512)
    p.add_argument("--temperature", type=float, default=0.7)
    p.add_argument("--top-p",       type=float, default=0.95)
    p.add_argument("--row-timeout", type=int,   default=15)
    p.add_argument("--limit",       type=int,   default=0)
    return p.parse_args()


def main() -> int:
    args = parse_args()
    seed_path = Path(args.seed)
    out_dir   = Path(args.out)
    if not seed_path.exists():
        emit({"event": "error", "message": f"seed not found: {seed_path}"})
        return 2
    out_dir.mkdir(parents=True, exist_ok=True)

    rows = read_jsonl(seed_path)
    if args.limit and args.limit > 0:
        rows = rows[: args.limit]

    adapter = args.adapter or None
    emit({"event": "start",
          "rows": len(rows),
          "candidates": args.candidates,
          "model": args.model,
          "adapter": adapter})

    try:
        t0 = time.monotonic()
        model, tokenizer = load_model(args.model, adapter)
        emit({"event": "model_loaded",
              "ms": int((time.monotonic() - t0) * 1000),
              "with_adapter": bool(adapter)})
        sampler = make_sampler(args.temperature, args.top_p)
    except Exception as exc:
        emit({"event": "error", "message": f"model load failed: {exc}"})
        return 3

    kept: list[dict] = []
    results: list[dict] = []
    total_passes = 0
    total_attempts = 0

    # mlx's allocator caches freed buffers for reuse — great for steady-state
    # but for long-running scripts that load a 27B model then sit on it, the
    # cache grows multi-GB. Periodic clear keeps the resident set in check.
    try:
        import mlx.core as _mx  # type: ignore
        _has_mlx_clear = hasattr(_mx, "clear_cache")
    except Exception:
        _mx = None
        _has_mlx_clear = False

    def _maybe_clear_cache():
        if _has_mlx_clear:
            try: _mx.clear_cache()
            except Exception: pass

    for i, row in enumerate(rows):
        prompt   = row.get("prompt") or ""
        tests    = row.get("tests")  or ""
        entry    = row.get("entry_point") or ""
        task_id  = row.get("task_id") or f"row-{i}"
        if not (prompt and tests):
            emit({"event": "row_done", "i": i, "passed": False,
                  "passes": 0, "total": 0})
            results.append({"task_id": task_id, "passed": False, "passes": 0,
                            "total": 0, "reason": "missing prompt/tests"})
            continue

        # We surface the user-facing instruction (which already contains the
        # function signature) — that's what the model needs to see.
        user_msg = (
            row.get("messages", [{}])[0].get("content")
            if row.get("messages") else None
        ) or (
            "Complete the following Python function. Return the full function "
            "inside a single ```python code block.\n\n"
            f"```python\n{prompt}```"
        )

        # Pick the most informative line for the preview: prefer the function
        # signature, fall back to the first non-import non-blank line. HumanEval
        # prompts start with `from typing import …` which isn't useful here.
        preview = ""
        for line in (prompt or "").splitlines():
            stripped = line.strip()
            if not stripped:
                continue
            if stripped.startswith(("def ", "class ", "async def ")):
                preview = stripped[:90]
                break
            if not stripped.startswith(("from ", "import ", "#")):
                preview = stripped[:90]
                break
        emit({"event": "row_start", "i": i, "task_id": task_id,
              "prompt_preview": preview})

        row_passes = 0
        kept_codes: list[str] = []
        seen_norm: set[str] = set()
        for k in range(args.candidates):
            total_attempts += 1
            try:
                resp = generate_one(model, tokenizer, sampler, user_msg,
                                    max_tokens=args.max_tokens,
                                    temperature=args.temperature,
                                    top_p=args.top_p)
            except Exception as exc:
                emit({"event": "candidate", "i": i, "k": k,
                      "status": "fail", "fail_reason": f"gen: {exc.__class__.__name__}"})
                continue
            code = extract_code(resp)
            passed, reason = run_one_test(code, tests, entry, args.row_timeout)
            emit({"event": "candidate", "i": i, "k": k,
                  "status": "pass" if passed else "fail",
                  "fail_reason": "" if passed else reason})
            if passed:
                row_passes += 1
                total_passes += 1
                # Keep up to N DISTINCT passing solutions per problem (dedup'd by
                # normalized whitespace) — more diverse training signal + a larger
                # dataset, the main lever against the tiny-keeper-set overfit
                # (see docs/STATE.md Practice notes).
                norm = _normalize_code(code)
                if len(kept_codes) < args.keep_per_problem and norm not in seen_norm:
                    seen_norm.add(norm)
                    kept_codes.append(code)

        for kept_code in kept_codes:
            kept.append({
                "task_id": task_id,
                "messages": [
                    {"role": "user",      "content": user_msg},
                    {"role": "assistant", "content": f"```python\n{kept_code}\n```"},
                ],
            })
        results.append({
            "task_id": task_id,
            "passed":  bool(kept_codes),
            "passes":  row_passes,
            "total":   args.candidates,
        })
        emit({"event": "row_done", "i": i,
              "passed": bool(kept_codes),
              "passes": row_passes, "total": args.candidates})
        # Free the per-prompt KV cache / activation buffers between rows.
        _maybe_clear_cache()

    # Persist results regardless of how many passed.
    write_jsonl(out_dir / "results.jsonl", results)

    if not kept:
        emit({"event": "error",
              "message": "0 passing samples — round produced no dataset. "
                         "Increase candidates / temperature / max-tokens, or start "
                         "from a stronger base model."})
        return 4

    rng = random.Random(0)
    rng.shuffle(kept)
    n = len(kept)
    msg_rows = [{"messages": r["messages"]} for r in kept]
    # mlx-lm needs all three files non-empty. For tiny rounds we duplicate
    # rather than over-shrink the training set — the next round's generations
    # are produced from the resulting adapter, and a single passing row in
    # train is better than zero. We accept the overfit risk; the loop's pass@1
    # eval against the held-out eval.jsonl is what actually measures progress.
    if n < 3:
        # mlx-lm needs at least `batch_size` rows in valid.jsonl. We don't know
        # the caller's batch size — write all kept rows into every split so any
        # reasonable batch size will fit. Overfit risk is real but the next
        # round's pass@1 measurement is what counts.
        splits = {
            "train.jsonl": msg_rows,
            "valid.jsonl": msg_rows,
            "test.jsonl":  msg_rows,
        }
    else:
        train_cut = max(1, int(n * 0.90))
        valid_cut = max(train_cut + 1, int(n * 0.95)) if n > train_cut else train_cut
        splits = {
            "train.jsonl": msg_rows[:train_cut],
            "valid.jsonl": msg_rows[train_cut:valid_cut],
            "test.jsonl":  msg_rows[valid_cut:],
        }
        # Both valid and test must have at least 1 row, but we don't want to
        # pull the LAST row out of train — clone instead when train has only 1.
        for required in ("valid.jsonl", "test.jsonl"):
            if not splits[required]:
                if len(splits["train.jsonl"]) > 1:
                    splits[required] = [splits["train.jsonl"].pop()]
                else:
                    splits[required] = [splits["train.jsonl"][0]]

    dataset_dir = out_dir / "dataset"
    for fname, subset in splits.items():
        write_jsonl(dataset_dir / fname, subset)
        emit({"event": "progress", "stage": "write",
              "message": f"Wrote {len(subset)} rows to {fname}"})

    pass_rate = total_passes / max(1, total_attempts)
    emit({"event": "done",
          "kept":      len(kept),
          "rows":      len(rows),
          "pass_rate": pass_rate,
          "train":     len(splits["train.jsonl"]),
          "valid":     len(splits["valid.jsonl"]),
          "test":      len(splits["test.jsonl"])})
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
