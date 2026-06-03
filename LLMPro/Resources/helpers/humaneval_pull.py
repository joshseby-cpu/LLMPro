"""humaneval_pull.py — download a coding-eval dataset (HumanEval, MBPP) from
HuggingFace and emit:

  <out_dir>/seed.jsonl     # rows for round-0 training + later self-grading
  <out_dir>/eval.jsonl     # held-out rows for measuring pass@1 each round

Each row is the same shape — the difference is just the train/eval split:
{
  "task_id":           "HumanEval/0",
  "prompt":            "<function signature + docstring>",   # what the model gets
  "tests":             "<assertion code that calls entry_point>",
  "entry_point":       "<name of function the tests call>",
  "canonical_solution":"<reference body>",                   # for round-0 SFT
  "messages":          [{"role":"user","content":"..."},     # chat-schema view of
                        {"role":"assistant","content":"..."}] # the canonical solve
}

Invoked by LLMPro as:
    python humaneval_pull.py <preset_id> <out_dir> [token]

JSON-event protocol on stdout:
    {"event":"start",    "preset":"...", "hf_repo":"..."}
    {"event":"progress", "stage":"download"|"transform"|"write", "message":"..."}
    {"event":"done",     "seed":N, "eval":M}
    {"event":"error",    "message":"..."}
"""

from __future__ import annotations

import json
import random
import sys
from pathlib import Path
from typing import Callable, Iterable


def emit(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()


# --- preset adapters: source HF row -> normalized row ----------------------

def adapt_humaneval(row: dict) -> dict | None:
    prompt = row.get("prompt")
    sol    = row.get("canonical_solution")
    test   = row.get("test")
    ep     = row.get("entry_point")
    tid    = row.get("task_id")
    if not (prompt and test and ep and tid is not None):
        return None
    user = (
        "Complete the following Python function. Return the full function "
        "(signature + body) inside a single ```python code block — no extra "
        f"explanation.\n\n```python\n{prompt}```"
    )
    assistant = f"```python\n{prompt}{sol}```"
    return {
        "task_id":           str(tid),
        "prompt":            prompt,
        "tests":             test,
        "entry_point":       ep,
        "canonical_solution":sol or "",
        "messages": [
            {"role": "user",      "content": user},
            {"role": "assistant", "content": assistant},
        ],
    }


def adapt_mbpp(row: dict) -> dict | None:
    # MBPP "sanitized" split has: task_id, text (problem), code (solution),
    # test_list (list of asserts), test_setup_code (often "").
    text  = (row.get("text") or row.get("prompt") or "").strip()
    code  = (row.get("code") or "").strip()
    tests = row.get("test_list") or []
    setup = row.get("test_setup_code") or ""
    tid   = row.get("task_id")
    if not (text and tests and tid is not None):
        return None

    # MBPP doesn't ship an explicit "entry_point" — sniff "def NAME(" from the solution.
    entry_point = ""
    for line in code.splitlines():
        line = line.strip()
        if line.startswith("def "):
            entry_point = line[4:].split("(", 1)[0].strip()
            break

    test_block = "\n".join(tests)
    test_code = (
        (setup + "\n" if setup else "")
        + "def check(candidate):\n"
        + "    "
        + test_block.replace("\n", "\n    ")
    )

    user = (
        "Write a Python function for this task. Return the function inside a "
        f"single ```python code block — no extra explanation.\n\n{text}"
    )
    assistant = f"```python\n{code}\n```"
    return {
        "task_id":           f"mbpp/{tid}",
        "prompt":            text,
        "tests":             test_code,
        "entry_point":       entry_point,
        "canonical_solution":code,
        "messages": [
            {"role": "user",      "content": user},
            {"role": "assistant", "content": assistant},
        ],
    }


PRESETS: dict[str, tuple[str, str, Callable[[dict], dict | None]]] = {
    # preset id            (hf_repo,                       hf_split, adapter)
    # HumanEval used to be uploaded as `openai_humaneval`; the namespaced form
    # `openai/openai_humaneval` is the one current `datasets` versions accept.
    "humaneval":          ("openai/openai_humaneval",     "test",   adapt_humaneval),
    "mbpp-sanitized":     ("google-research-datasets/mbpp", "train", adapt_mbpp),
}


def iter_rows(repo: str, split: str, token: str | None) -> Iterable[dict]:
    from datasets import load_dataset  # type: ignore
    # MBPP has multiple configs; "sanitized" is the human-vetted one (974 problems).
    if repo.endswith("/mbpp"):
        ds = load_dataset(repo, "sanitized", split=split, token=token or None,
                          trust_remote_code=False)
    else:
        ds = load_dataset(repo, split=split, token=token or None)
    for row in ds:
        yield row


def main() -> int:
    if len(sys.argv) < 3:
        emit({"event": "error",
              "message": "Usage: humaneval_pull.py <preset> <out_dir> [token] [eval_count]"})
        return 2
    preset = sys.argv[1]
    out_dir = Path(sys.argv[2])
    token = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else None
    eval_count = int(sys.argv[4]) if len(sys.argv) > 4 else 32

    if preset not in PRESETS:
        emit({"event": "error",
              "message": f"Unknown preset '{preset}'. Available: {sorted(PRESETS)}"})
        return 2

    repo, split, adapt = PRESETS[preset]
    out_dir.mkdir(parents=True, exist_ok=True)
    emit({"event": "start", "preset": preset, "hf_repo": repo})

    try:
        try:
            import datasets  # noqa: F401
        except ImportError:
            emit({"event": "error",
                  "message": "Python `datasets` not installed. Run: uv pip install datasets"})
            return 3

        emit({"event": "progress", "stage": "download", "message": f"Loading {repo}…"})

        rows: list[dict] = []
        for i, src in enumerate(iter_rows(repo, split, token)):
            adapted = adapt(src)
            if adapted is None:
                continue
            rows.append(adapted)
            if (i + 1) % 200 == 0:
                emit({"event": "progress", "stage": "transform",
                      "message": f"Transformed {len(rows)} rows…"})

        if not rows:
            emit({"event": "error", "message": "Dataset produced 0 valid rows."})
            return 4

        rng = random.Random(0)
        rng.shuffle(rows)
        eval_count = min(eval_count, max(8, len(rows) // 5))
        eval_rows = rows[:eval_count]
        seed_rows = rows[eval_count:]

        seed_path = out_dir / "seed.jsonl"
        eval_path = out_dir / "eval.jsonl"
        with seed_path.open("w", encoding="utf-8") as fh:
            for r in seed_rows:
                fh.write(json.dumps(r, ensure_ascii=False) + "\n")
        with eval_path.open("w", encoding="utf-8") as fh:
            for r in eval_rows:
                fh.write(json.dumps(r, ensure_ascii=False) + "\n")

        emit({"event": "progress", "stage": "write",
              "message": f"Wrote {len(seed_rows)} seed rows and {len(eval_rows)} eval rows"})
        emit({"event": "done", "seed": len(seed_rows), "eval": len(eval_rows)})
        return 0
    except KeyboardInterrupt:
        emit({"event": "error", "message": "Interrupted"})
        return 130
    except Exception as exc:
        emit({"event": "error", "message": f"{type(exc).__name__}: {exc}"})
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
