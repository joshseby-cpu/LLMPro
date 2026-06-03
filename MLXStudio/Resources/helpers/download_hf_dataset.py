"""download_hf_dataset.py — download any HuggingFace dataset and normalize it to
mlx-lm's `chat` JSONL schema.

Invoked by MLXStudio as:
    python download_hf_dataset.py <repo_id> <output_dir> [options_json]

Where options_json is a JSON object with optional keys:
    {
        "config": "default",                  # HF dataset config name
        "split": "train",                     # which split to read
        "max_rows": 20000,                    # cap rows for memory
        "schema": "auto" | "messages" | "instruction_output" | "prompt_completion"
                  | "question_answer" | "text",
        "fields": {                           # column-name overrides (used when schema != "auto")
            "messages": "...", "instruction": "...", "input": "...", "output": "...",
            "prompt": "...", "completion": "...", "question": "...", "answer": "..."
        }
    }

Emits JSON progress lines on stdout (same shape as the other helpers).
"""

from __future__ import annotations

import json
import random
import sys
from pathlib import Path
from typing import Any, Iterable

MAX_ROWS_DEFAULT = 20_000


def emit(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()


# ---------- schema auto-detection ------------------------------------------------

def _looks_chat(row: dict) -> bool:
    msgs = row.get("messages")
    return isinstance(msgs, list) and bool(msgs) and \
        all(isinstance(m, dict) and "role" in m and "content" in m for m in msgs)


def _looks_sharegpt(row: dict) -> bool:
    convs = row.get("conversations")
    return isinstance(convs, list) and bool(convs) and \
        all(isinstance(m, dict) and ("from" in m or "role" in m) and ("value" in m or "content" in m) for m in convs)


def _looks_instruction_output(row: dict) -> bool:
    has_instr = "instruction" in row or "prompt" in row or "problem" in row
    has_out = "output" in row or "completion" in row or "response" in row or "solution" in row or "answer" in row
    # require not the more specific 'messages' shape
    return has_instr and has_out and not _looks_chat(row) and not _looks_sharegpt(row)


def _looks_question_answer(row: dict) -> bool:
    return ("question" in row and "answer" in row) and not _looks_instruction_output(row)


def _looks_text(row: dict) -> bool:
    return "text" in row and isinstance(row["text"], str) and "instruction" not in row


def detect_schema(row: dict) -> str:
    if _looks_chat(row): return "messages"
    if _looks_sharegpt(row): return "sharegpt"
    if _looks_instruction_output(row): return "instruction_output"
    if _looks_question_answer(row): return "question_answer"
    if _looks_text(row): return "text"
    return "unknown"


# ---------- row → mlx-lm chat messages ------------------------------------------

def _pick(row: dict, *candidates: str, default: str = "") -> str:
    for c in candidates:
        v = row.get(c)
        if isinstance(v, str) and v.strip():
            return v
    return default


def normalize_row(row: dict, schema: str, fields: dict | None) -> list[dict] | None:
    fields = fields or {}

    if schema == "messages":
        key = fields.get("messages", "messages")
        msgs = row.get(key)
        if not isinstance(msgs, list) or not msgs: return None
        # Pass-through, but normalize role/content keys.
        out = []
        for m in msgs:
            if not isinstance(m, dict): continue
            role = m.get("role") or m.get("from") or "user"
            content = m.get("content") or m.get("value") or ""
            if isinstance(content, list):
                content = "".join(p.get("text", "") if isinstance(p, dict) else str(p) for p in content)
            if not isinstance(content, str): content = str(content)
            out.append({"role": role, "content": content})
        return out or None

    if schema == "sharegpt":
        key = fields.get("messages", "conversations")
        convs = row.get(key)
        if not isinstance(convs, list) or not convs: return None
        role_map = {"human": "user", "user": "user", "gpt": "assistant", "assistant": "assistant",
                    "system": "system", "tool": "tool"}
        out = []
        for m in convs:
            if not isinstance(m, dict): continue
            raw_role = m.get("from") or m.get("role") or "user"
            role = role_map.get(str(raw_role).lower(), "user")
            content = m.get("value") or m.get("content") or ""
            if not isinstance(content, str): content = str(content)
            out.append({"role": role, "content": content})
        return out or None

    if schema == "instruction_output":
        instr_key = fields.get("instruction", "instruction") or "instruction"
        in_key    = fields.get("input", "input") or "input"
        out_key   = fields.get("output", "output") or "output"
        instr = _pick(row, instr_key, "prompt", "problem")
        out   = _pick(row, out_key, "completion", "response", "solution", "answer")
        if not instr or not out: return None
        extra = _pick(row, in_key)
        user = instr if not extra else f"{instr}\n\n{extra}"
        return [{"role": "user", "content": user}, {"role": "assistant", "content": out}]

    if schema == "prompt_completion":
        p_key = fields.get("prompt", "prompt") or "prompt"
        c_key = fields.get("completion", "completion") or "completion"
        p = _pick(row, p_key)
        c = _pick(row, c_key)
        if not p or not c: return None
        return [{"role": "user", "content": p}, {"role": "assistant", "content": c}]

    if schema == "question_answer":
        q_key = fields.get("question", "question") or "question"
        a_key = fields.get("answer", "answer") or "answer"
        q = _pick(row, q_key)
        a = _pick(row, a_key)
        if not q or not a: return None
        return [{"role": "user", "content": q}, {"role": "assistant", "content": a}]

    if schema == "text":
        key = fields.get("text", "text") or "text"
        t = _pick(row, key)
        if not t: return None
        return [{"role": "user", "content": t}]

    return None


# ---------- main flow -----------------------------------------------------------

def main() -> int:
    if len(sys.argv) < 3:
        emit({"event": "error", "message": "Usage: download_hf_dataset.py <repo_id> <out_dir> [options_json]"})
        return 2

    repo_id = sys.argv[1]
    out_dir = Path(sys.argv[2])
    opts: dict = {}
    if len(sys.argv) > 3 and sys.argv[3]:
        try:
            opts = json.loads(sys.argv[3])
        except json.JSONDecodeError as exc:
            emit({"event": "error", "message": f"Invalid options JSON: {exc}"})
            return 2

    config = opts.get("config")
    split = opts.get("split") or "train"
    max_rows = int(opts.get("max_rows") or MAX_ROWS_DEFAULT)
    requested_schema = (opts.get("schema") or "auto").lower()
    fields = opts.get("fields") or {}
    # ~32 K characters ≈ 8 K tokens. Default cap protects mlx-lm from rows
    # that contain entire source files (kotlarmilos/dotnet-runtime had 40 MB
    # single entries). When mlx-lm truncates them to max_seq_length the result
    # is gibberish that NaNs the loss. Set max_chars_per_row=0 in options to
    # disable the filter when you genuinely want full-document training.
    max_chars_per_row = int(opts.get("max_chars_per_row") or 32_000)

    try:
        from datasets import load_dataset
    except ImportError as exc:
        emit({"event": "error", "message": f"`datasets` not installed: {exc}"})
        return 3

    out_dir.mkdir(parents=True, exist_ok=True)
    emit({"event": "start", "repo": repo_id, "config": config, "split": split, "max_rows": max_rows})

    try:
        ds = load_dataset(repo_id, config, split=split, streaming=False) if config \
            else load_dataset(repo_id, split=split, streaming=False)
    except Exception as exc:
        # Some datasets require trust_remote_code or a config. Surface clearly.
        emit({"event": "error", "message": f"Could not load dataset: {type(exc).__name__}: {exc}"})
        return 4

    # Probe the first row to lock in the schema.
    try:
        first = ds[0]
    except (KeyError, IndexError):
        emit({"event": "error", "message": "Dataset is empty."})
        return 5

    schema = requested_schema if requested_schema != "auto" else detect_schema(first)
    emit({"event": "progress", "stage": "schema", "message": f"Detected schema: {schema}", "row_keys": list(first.keys())})

    if schema == "unknown":
        emit({"event": "error", "message": "Could not auto-detect the dataset shape. Pass an explicit schema + fields in options_json.",
              "row_keys": list(first.keys())})
        return 6

    # Iterate and normalize. Apply the size cap here — rows that exceed
    # max_chars_per_row (when > 0) are dropped so they never reach mlx-lm.
    rows: list[list[dict]] = []
    skipped = 0
    skipped_too_long = 0
    total = min(len(ds), max_rows) if hasattr(ds, "__len__") else max_rows
    for i, row in enumerate(ds):
        if i >= max_rows: break
        msgs = normalize_row(row, schema, fields)
        if msgs is None:
            skipped += 1
            continue
        if max_chars_per_row > 0:
            total_chars = sum(len(m.get("content", "")) for m in msgs)
            if total_chars > max_chars_per_row:
                skipped_too_long += 1
                continue
        rows.append(msgs)
        if (i + 1) % 1000 == 0 or (i + 1) == total:
            emit({"event": "progress", "stage": "transform",
                  "message": f"Transformed {len(rows)} rows (skipped {skipped + skipped_too_long}: {skipped_too_long} too long)",
                  "processed": i + 1, "total": total})

    if not rows:
        emit({"event": "error", "message": f"Produced 0 valid rows after filtering. Schema={schema}. Check column names."})
        return 7

    # Deterministic 90/5/5 split.
    rng = random.Random(0)
    rng.shuffle(rows)
    n = len(rows)
    cut1 = int(n * 0.90)
    cut2 = int(n * 0.95)
    splits = {
        "train.jsonl": rows[:cut1],
        "valid.jsonl": rows[cut1:cut2],
        "test.jsonl":  rows[cut2:],
    }
    for fname, subset in splits.items():
        path = out_dir / fname
        with path.open("w", encoding="utf-8") as f:
            for msgs in subset:
                f.write(json.dumps({"messages": msgs}, ensure_ascii=False) + "\n")
        emit({"event": "progress", "stage": "write",
              "message": f"Wrote {len(subset)} rows → {fname}"})

    emit({
        "event": "done",
        "train": len(splits["train.jsonl"]),
        "valid": len(splits["valid.jsonl"]),
        "test":  len(splits["test.jsonl"]),
        "schema": "chat",          # mlx-lm-side schema (we always normalize to chat/messages)
        "source_schema": schema,   # what we detected on the way in
    })
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
