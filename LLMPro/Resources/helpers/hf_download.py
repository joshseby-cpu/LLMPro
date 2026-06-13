"""hf_download.py — JSON-progress wrapper around huggingface_hub.snapshot_download.

Invoked by LLMPro as:
    python hf_download.py <repo_id> <cache_dir> [token_or_empty]

Emits one JSON object per line on stdout, e.g.:
    {"event": "start",    "repo": "...", "total_bytes": N, "files": N}
    {"event": "progress", "downloaded": N, "total": N, "percent": F, "file": "..."}
    {"event": "done",     "path": "/abs/path/to/snapshot"}
    {"event": "error",    "message": "..."}

Progress is computed by polling the cache directory size from a background thread,
which works regardless of whether the transport is the classic HTTP path (per-file
tqdm) or the newer xet chunked protocol (which bypasses tqdm entirely).
"""

from __future__ import annotations
import json
import os
import re
import sys
import threading
import time
from pathlib import Path


def emit(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()


def _hub_cache_dir(cache_dir: str, repo_id: str) -> Path:
    """Resolve the per-repo dir inside the HF Hub cache."""
    safe = "models--" + repo_id.replace("/", "--")
    return Path(cache_dir) / safe


def _dir_bytes(path: Path) -> int:
    """Total bytes of real blob files under <repo_cache>/blobs/.

    huggingface_hub stores real bytes in `blobs/<hash>` (or `blobs/<hash>.incomplete`
    while in flight); `snapshots/<rev>/<filename>` is just symlinks pointing back
    to blobs. Counting `blobs/` directly avoids double-counting via the symlinks.
    """
    blobs = path / "blobs"
    if not blobs.exists():
        return 0
    total = 0
    try:
        for entry in blobs.iterdir():
            try:
                total += entry.lstat().st_size
            except OSError:
                pass
    except OSError:
        return 0
    return total


def _expected_total_bytes(repo_id: str, token: str | None) -> int:
    """Sum the expected file sizes from HF model_info siblings.

    Returns 0 if we can't fetch (then the UI shows indeterminate progress).
    """
    try:
        from huggingface_hub import HfApi  # type: ignore
        info = HfApi(token=token).model_info(repo_id, files_metadata=True)
        return sum((s.size or 0) for s in (info.siblings or []))
    except Exception:
        return 0


def _start_poller(repo_cache_dir: Path, total_bytes: int) -> threading.Event:
    """Spawn a background thread that emits {"event":"progress"} every 250 ms.

    Returns an Event the caller `.set()`s to stop the poller.
    """
    stop = threading.Event()

    def loop() -> None:
        last_downloaded = -1
        while not stop.is_set():
            downloaded = _dir_bytes(repo_cache_dir)
            if downloaded != last_downloaded:
                last_downloaded = downloaded
                # Clamp: a reported total that under-counts (e.g. xet chunk
                # overhead, .incomplete padding) can push the raw ratio > 1.0.
                percent = min(1.0, downloaded / total_bytes) if total_bytes > 0 else 0.0
                emit({
                    "event": "progress",
                    "downloaded": downloaded,
                    "total": total_bytes,
                    "percent": percent,
                    "file": _newest_partial(repo_cache_dir),
                })
            stop.wait(0.25)

    t = threading.Thread(target=loop, daemon=True)
    t.start()
    return stop


def _newest_partial(repo_cache_dir: Path) -> str:
    """Friendly label for the in-flight file (best-effort)."""
    blobs = repo_cache_dir / "blobs"
    if not blobs.exists():
        return ""
    incompletes = sorted(
        (p for p in blobs.iterdir() if p.name.endswith(".incomplete")),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    if incompletes:
        return incompletes[0].name
    return ""


def main() -> int:
    if len(sys.argv) < 3:
        emit({"event": "error", "message": "Usage: hf_download.py <repo_id> <cache_dir> [token]"})
        return 2

    repo_id = sys.argv[1]
    cache_dir = sys.argv[2]
    token = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else None

    try:
        from huggingface_hub import snapshot_download
        from huggingface_hub.utils import HfHubHTTPError
    except ImportError as exc:
        emit({"event": "error", "message": f"huggingface_hub not installed: {exc}"})
        return 3

    os.makedirs(cache_dir, exist_ok=True)
    repo_cache_dir = _hub_cache_dir(cache_dir, repo_id)

    total = _expected_total_bytes(repo_id, token)
    emit({"event": "start", "repo": repo_id, "total_bytes": total, "cache_dir": cache_dir})

    stop = _start_poller(repo_cache_dir, total)
    try:
        local_path = snapshot_download(
            repo_id=repo_id,
            cache_dir=cache_dir,
            token=token,
            local_files_only=False,
            allow_patterns=None,
            # Force the classic transport off if available — xet is great for speed
            # but our poller works the same either way; keep the default.
        )
        # One final flush so the bar lands at 100%.
        downloaded = _dir_bytes(repo_cache_dir)
        emit({
            "event": "progress",
            "downloaded": downloaded,
            "total": max(total, downloaded),
            "percent": 1.0,
            "file": "",
        })
        emit({"event": "done", "path": str(local_path)})
        return 0
    except HfHubHTTPError as exc:
        emit({"event": "error", "message": f"HTTP error: {exc}"})
        return 4
    except KeyboardInterrupt:
        emit({"event": "error", "message": "Interrupted"})
        return 130
    except Exception as exc:
        emit({"event": "error", "message": f"{type(exc).__name__}: {exc}"})
        return 1
    finally:
        stop.set()


if __name__ == "__main__":
    raise SystemExit(main())
