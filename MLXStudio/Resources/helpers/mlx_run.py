"""mlx_run.py — thin launcher that applies Apple-Silicon-aware MLX memory tuning,
then runs the real mlx_lm command via runpy.

MLX Studio prepends this to EVERY mlx_lm invocation — training, inference, AND the
coding-agent server — so MLX manages unified memory correctly on Apple Silicon,
not only when the Memory-tab budget is on.

Why this matters: a Mac's Metal GPU has a *recommended working-set ceiling*
(~84% of unified memory — e.g. ~107 GB on a 128 GB machine). MLX's stock memory
and cache limits default to a value ABOVE that ceiling, so a large run can grow
past the safe point and hard-crash with
`kIOGPUCommandBufferCallbackErrorOutOfMemory`. We re-pin the soft memory limit
and the cache limit to the real ceiling so MLX frees its buffer cache *before*
crossing it (a graceful slowdown instead of a crash), and we wire the working
set so big models stay resident instead of being paged out.

The limits are soft (relaxed): a run that genuinely needs more is still allowed
through, so nothing that used to fit stops fitting — we only prevent the runaway
growth that crashes. Raising the ceiling itself would need `sudo sysctl
iogpu.wired_limit_mb`, which a sandboxed app can't and shouldn't do.

Env (all optional):
    MLXSTUDIO_MEMORY_LIMIT_BYTES   override the soft memory limit (Memory tab cap)
    MLXSTUDIO_CACHE_LIMIT_BYTES    override the buffer-cache limit
    MLXSTUDIO_NO_AUTOTUNE=1        skip all auto-tuning (use stock MLX defaults)

Usage (as prepended by MLX Studio):
    python mlx_run.py -m mlx_lm lora -c config.yaml
    python mlx_run.py -m mlx_lm generate --model ... --prompt ...
    python mlx_run.py -m mlx_lm server --model ... --port ...
"""

from __future__ import annotations

import os
import runpy
import sys


def _setlimit(mx, name: str, val) -> None:
    """Call mx.<name>(val) (or mx.metal.<name>) defensively across MLX versions."""
    if not val or int(val) <= 0:
        return
    fn = getattr(mx, name, None)
    if fn is None and hasattr(mx, "metal"):
        fn = getattr(mx.metal, name, None)
    if callable(fn):
        try:
            fn(int(val))
        except Exception:
            pass


def _apply_limits() -> None:
    if os.environ.get("MLXSTUDIO_NO_AUTOTUNE") == "1":
        return
    try:
        import mlx.core as mx  # type: ignore
    except Exception:
        return

    # Discover this device's Metal working-set ceiling (the real OOM threshold).
    ceiling = 0
    try:
        info = mx.device_info()
        ceiling = int(info.get("max_recommended_working_set_size", 0) or 0)
    except Exception:
        ceiling = 0

    # Soft memory limit: the explicit Memory-tab budget wins, otherwise the Metal
    # ceiling so MLX reclaims its cache before a hard OOM.
    mem_limit = None
    raw = os.environ.get("MLXSTUDIO_MEMORY_LIMIT_BYTES")
    if raw:
        try:
            mem_limit = int(raw)
        except ValueError:
            mem_limit = None
    if mem_limit is None and ceiling > 0:
        mem_limit = ceiling
    if mem_limit:
        _setlimit(mx, "set_memory_limit", mem_limit)

    # Keep the working set resident up to the ceiling (MLX rejects a higher value;
    # never exceed the soft memory limit either).
    if ceiling > 0:
        wired = min(ceiling, mem_limit) if mem_limit else ceiling
        _setlimit(mx, "set_wired_limit", wired)

    # Bound the reusable buffer cache so it doesn't crowd out model weights on a
    # near-ceiling run (MLX still reclaims it under the memory limit when needed).
    craw = os.environ.get("MLXSTUDIO_CACHE_LIMIT_BYTES")
    if craw and craw.isdigit():
        _setlimit(mx, "set_cache_limit", int(craw))
    elif mem_limit:
        _setlimit(mx, "set_cache_limit", mem_limit // 2)


def main() -> int:
    _apply_limits()
    args = sys.argv[1:]
    if not args:
        sys.stderr.write("mlx_run.py: nothing to run\n")
        return 2
    if args[0] == "-m":
        if len(args) < 2:
            sys.stderr.write("mlx_run.py: -m needs a module name\n")
            return 2
        mod = args[1]
        sys.argv = [mod] + args[2:]
        runpy.run_module(mod, run_name="__main__", alter_sys=True)
    else:
        sys.argv = args
        runpy.run_path(args[0], run_name="__main__")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
