"""OptIQ support for Google's DiffusionGemma (masked/block-diffusion LM).

The model runs entirely on the vendored ``optiq.vlm._mlxvlm`` subset (no
``mlx-vlm`` runtime dependency). ``load_diffusion_gemma`` builds + loads it; the
sensitivity + convert wiring lives alongside.
"""

from .generate import generate, load, stream_generate
from .loader import load_config, load_diffusion_gemma

__all__ = [
    "load",
    "generate",
    "stream_generate",
    "load_diffusion_gemma",
    "load_config",
]
