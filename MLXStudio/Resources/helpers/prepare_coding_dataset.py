"""prepare_coding_dataset.py — download a known coding dataset from HuggingFace
and normalize it into mlx-lm's `chat` JSONL schema (train.jsonl / valid.jsonl / test.jsonl).

Invoked by MLX Studio as:
    python prepare_coding_dataset.py <preset_id> <output_dir> [token]

Emits one JSON object per line on stdout:
    {"event": "start",     "preset": "...", "hf_repo": "..."}
    {"event": "progress",  "stage": "download" | "transform" | "write", "message": "..."}
    {"event": "done",      "train": N, "valid": N, "test": N, "schema": "chat"}
    {"event": "error",     "message": "..."}

Each preset knows how to download from HF and convert the source schema to mlx-lm's
chat schema:  {"messages": [{"role": "user", "content": "..."},
                            {"role": "assistant", "content": "..."}]}

Presets shipped:
    codealpaca-20k        sahil2801/CodeAlpaca-20k         (instruction/input/output)
    magicoder-evol-110k   ise-uiuc/Magicoder-Evol-Instruct-110K  (instruction/response)
    magicoder-oss-75k     ise-uiuc/Magicoder-OSS-Instruct-75K    (problem/solution)
    evol-codealpaca       theblackcat102/evol-codealpaca-v1      (instruction/output)
    open-coderpair-20k    glaiveai/glaive-code-assistant         (question/answer)  *small subset*
"""

from __future__ import annotations
import json
import os
import random
import sys
from pathlib import Path
from typing import Callable, Iterable


def emit(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()


# A preset is a (hf_repo, splitter) tuple where `splitter` turns each row into a chat message list.

def split_codealpaca(row: dict) -> list[dict] | None:
    instr = (row.get("instruction") or "").strip()
    if not instr:
        return None
    extra = (row.get("input") or "").strip()
    user = instr if not extra else f"{instr}\n\n{extra}"
    out = (row.get("output") or "").strip()
    if not out:
        return None
    return [{"role": "user", "content": user}, {"role": "assistant", "content": out}]


def split_magicoder_evol(row: dict) -> list[dict] | None:
    instr = (row.get("instruction") or "").strip()
    out = (row.get("response") or "").strip()
    if not instr or not out:
        return None
    return [{"role": "user", "content": instr}, {"role": "assistant", "content": out}]


def split_magicoder_oss(row: dict) -> list[dict] | None:
    instr = (row.get("problem") or "").strip()
    out = (row.get("solution") or "").strip()
    if not instr or not out:
        return None
    return [{"role": "user", "content": instr}, {"role": "assistant", "content": out}]


def split_evol_codealpaca(row: dict) -> list[dict] | None:
    instr = (row.get("instruction") or "").strip()
    out = (row.get("output") or "").strip()
    if not instr or not out:
        return None
    return [{"role": "user", "content": instr}, {"role": "assistant", "content": out}]


def split_glaive_code(row: dict) -> list[dict] | None:
    q = (row.get("question") or row.get("input") or "").strip()
    a = (row.get("answer") or row.get("output") or "").strip()
    if not q or not a:
        return None
    return [{"role": "user", "content": q}, {"role": "assistant", "content": a}]


def split_code_instructions_120k(row: dict) -> list[dict] | None:
    """iamtarun/code_instructions_120k_alpaca — Alpaca-style fields lowercased.

    Multi-language; C# / .NET examples are mixed in among Python / JS / etc.
    ~122K rows; default cap of 20K is plenty for first-pass training.
    """
    instr = (row.get("instruction") or row.get("prompt") or "").strip()
    inp = (row.get("input") or "").strip()
    out = (row.get("output") or row.get("response") or "").strip()
    if not instr or not out:
        return None
    user = instr if not inp else f"{instr}\n\n{inp}"
    return [{"role": "user", "content": user}, {"role": "assistant", "content": out}]


def split_tiny_codes_csharp(row: dict) -> list[dict] | None:
    """layoric/tiny-codes-alpaca-csharp — pure C# Alpaca-style.

    ~125K rows of synthesized C# instruction data with rich scenario tagging
    (main_topic / subtopic / target_audience / scenario / etc.). For training
    we only consume the instruction + output; the metadata is dropped.
    The best off-the-shelf C# / .NET / Blazor option that actually exists
    on HF — verified live via the datasets-server API.
    """
    instr = (row.get("instruction") or "").strip()
    out = (row.get("output") or "").strip()
    if not instr or not out:
        return None
    return [{"role": "user", "content": instr}, {"role": "assistant", "content": out}]


PRESETS: dict[str, tuple[str, Callable[[dict], list[dict] | None]]] = {
    "codealpaca-20k":      ("sahil2801/CodeAlpaca-20k",                split_codealpaca),
    "magicoder-evol-110k": ("ise-uiuc/Magicoder-Evol-Instruct-110K",  split_magicoder_evol),
    "magicoder-oss-75k":   ("ise-uiuc/Magicoder-OSS-Instruct-75K",    split_magicoder_oss),
    "evol-codealpaca":     ("theblackcat102/evol-codealpaca-v1",       split_evol_codealpaca),
    "open-coderpair-20k":  ("glaiveai/glaive-code-assistant",          split_glaive_code),
    "code-instructions-120k":    ("iamtarun/code_instructions_120k_alpaca",      split_code_instructions_120k),
    "tiny-codes-csharp-125k":    ("layoric/tiny-codes-alpaca-csharp",            split_tiny_codes_csharp),
}

MAX_ROWS_DEFAULT = 20_000   # cap for memory-bound Macs; user can re-run with more later


def iter_rows(repo: str, token: str | None, max_rows: int) -> Iterable[dict]:
    from datasets import load_dataset  # type: ignore
    ds = load_dataset(repo, split="train", token=token or None)
    n = 0
    for row in ds:
        yield row
        n += 1
        if n >= max_rows:
            break


def main() -> int:
    if len(sys.argv) < 3:
        emit({"event": "error", "message": "Usage: prepare_coding_dataset.py <preset> <out_dir> [token] [max_rows]"})
        return 2
    preset = sys.argv[1]
    out_dir = Path(sys.argv[2])
    token = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else None
    if len(sys.argv) > 4:
        try:
            max_rows = int(sys.argv[4])
        except ValueError:
            emit({"event": "error", "message": f"max_rows must be an integer, got '{sys.argv[4]}'."})
            return 2
    else:
        max_rows = MAX_ROWS_DEFAULT

    if preset not in PRESETS:
        emit({"event": "error", "message": f"Unknown preset '{preset}'. Available: {sorted(PRESETS)}"})
        return 2

    repo, splitter = PRESETS[preset]
    out_dir.mkdir(parents=True, exist_ok=True)
    emit({"event": "start", "preset": preset, "hf_repo": repo})

    try:
        # Lazy import — gives a clean error if `datasets` isn't installed.
        try:
            import datasets  # noqa: F401
        except ImportError:
            emit({"event": "error", "message": "Python `datasets` package not installed. Run: uv pip install datasets"})
            return 3

        emit({"event": "progress", "stage": "download", "message": f"Loading {repo}…"})

        rows: list[list[dict]] = []
        skipped = 0
        for i, row in enumerate(iter_rows(repo, token, max_rows)):
            msgs = splitter(row)
            if msgs is None:
                skipped += 1
                continue
            rows.append(msgs)
            if (i + 1) % 1000 == 0:
                emit({"event": "progress", "stage": "transform",
                      "message": f"Transformed {len(rows)} rows (skipped {skipped})…"})

        if not rows:
            emit({"event": "error", "message": "Dataset produced 0 valid rows after filtering."})
            return 4

        # Deterministic 90/5/5 split.
        rng = random.Random(0)
        rng.shuffle(rows)
        n = len(rows)
        train_cut = int(n * 0.90)
        valid_cut = int(n * 0.95)
        splits = {
            "train.jsonl": rows[:train_cut],
            "valid.jsonl": rows[train_cut:valid_cut],
            "test.jsonl":  rows[valid_cut:],
        }
        for fname, subset in splits.items():
            path = out_dir / fname
            with path.open("w", encoding="utf-8") as fh:
                for msgs in subset:
                    fh.write(json.dumps({"messages": msgs}, ensure_ascii=False) + "\n")
            emit({"event": "progress", "stage": "write",
                  "message": f"Wrote {len(subset)} rows to {fname}"})

        emit({"event": "done",
              "train": len(splits["train.jsonl"]),
              "valid": len(splits["valid.jsonl"]),
              "test":  len(splits["test.jsonl"]),
              "schema": "chat"})
        return 0
    except KeyboardInterrupt:
        emit({"event": "error", "message": "Interrupted"})
        return 130
    except Exception as exc:
        emit({"event": "error", "message": f"{type(exc).__name__}: {exc}"})
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
