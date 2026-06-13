"""Stub for mlx-vlm's TurboQuant KV-cache path (NOT vendored).

OptiQ does its own KV-cache mixed-precision (``optiq.core.kv_cache`` +
``optiq.runtime.kv``), so the upstream 6.3k-line TurboQuant module is not
vendored. ``turboquant_enabled`` always returns False, which short-circuits the
only call sites (``generate/common.py``), so ``TurboQuantKVCache`` is never
constructed. Kept only so the vendored imports resolve.
"""
from __future__ import annotations


def turboquant_enabled(kv_bits=None, kv_quant_scheme=None) -> bool:  # noqa: ARG001
    return False


class TurboQuantKVCache:  # pragma: no cover - never instantiated (enabled=False)
    def __init__(self, *a, **k):
        raise RuntimeError(
            "TurboQuantKVCache is stubbed out in OptiQ; use optiq.runtime.kv instead."
        )

    @classmethod
    def from_cache(cls, *a, **k):
        raise RuntimeError("TurboQuantKVCache is stubbed out in OptiQ.")


class BatchTurboQuantKVCache(TurboQuantKVCache):  # pragma: no cover
    """Stub — only referenced in isinstance() checks (always False)."""
