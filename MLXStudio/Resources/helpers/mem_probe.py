"""mem_probe.py — one-shot snapshot of MLX / Metal GPU memory.

Apple Silicon's Metal layer has its own working-set ceiling that's separate from
system RAM — the OS "memory in use" gauge can show headroom while Metal refuses
to allocate one more buffer (this is what causes the
kIOGPUCommandBufferCallbackErrorOutOfMemory crashes during big training runs).
This helper reports the GPU-side numbers so the UI can show the *real* ceiling.

Emits a single JSON line on stdout, e.g.:
    {"event":"mem","active":1234,"peak":5678,"cache":910,
     "max_recommended_working_set":115964116992,"device_memory":137438953472,
     "device_name":"Apple M3 Max"}

All byte values may be null if the running mlx version doesn't expose that API
(the accessors moved between `mx.metal.*` and top-level `mx.*` across versions,
so we probe both).
"""

from __future__ import annotations

import json
import sys


def _call(mx, *dotted_names):
    """Return int(result) of the first callable found among dotted attribute
    paths (e.g. "get_active_memory", "metal.get_active_memory"), else None."""
    for name in dotted_names:
        obj = mx
        ok = True
        for part in name.split("."):
            if hasattr(obj, part):
                obj = getattr(obj, part)
            else:
                ok = False
                break
        if ok and callable(obj):
            try:
                return int(obj())
            except Exception:
                pass
    return None


def _device_info(mx):
    for name in ("device_info", "metal.device_info"):
        obj = mx
        ok = True
        for part in name.split("."):
            if hasattr(obj, part):
                obj = getattr(obj, part)
            else:
                ok = False
                break
        if ok and callable(obj):
            try:
                d = obj()
                if isinstance(d, dict):
                    return d
            except Exception:
                pass
    return {}


def main() -> int:
    try:
        import mlx.core as mx  # type: ignore
    except Exception as exc:  # noqa: BLE001
        sys.stdout.write(json.dumps({"event": "error", "message": f"mlx not available: {exc}"}) + "\n")
        return 1

    out = {
        "event": "mem",
        "active": _call(mx, "get_active_memory", "metal.get_active_memory"),
        "peak": _call(mx, "get_peak_memory", "metal.get_peak_memory"),
        "cache": _call(mx, "get_cache_memory", "metal.get_cache_memory"),
    }

    info = _device_info(mx)
    if info:
        mrws = info.get("max_recommended_working_set_size")
        memsz = info.get("memory_size")
        out["max_recommended_working_set"] = int(mrws) if mrws else None
        out["device_memory"] = int(memsz) if memsz else None
        out["device_name"] = info.get("device_name") or info.get("architecture")

    sys.stdout.write(json.dumps(out) + "\n")
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
