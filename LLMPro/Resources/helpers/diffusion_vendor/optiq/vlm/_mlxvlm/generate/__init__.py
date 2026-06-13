"""Minimal generation API vendored for OptiQ (diffusion decode only).

Upstream mlx-vlm exposes ar/cli/dispatch/image/edit_image here too; OptiQ only
needs the masked-diffusion decode loop and its shared helpers.
"""
from .common import (
    GenerationResult,
    generation_stream,
    maybe_quantize_kv_cache,
    wired_limit,
)
