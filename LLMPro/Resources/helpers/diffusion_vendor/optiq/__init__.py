"""Vendored subset of mlx-optiq (v0.2.3, MIT) — DiffusionGemma inference only.

This is NOT the full mlx-optiq package. LLMPro vendors only the
``optiq.vlm.diffusion_gemma`` inference closure so it can run Google's
DiffusionGemma on MLX without a pip dependency on mlx-optiq. See
``diffusion_vendor/VENDORED.md`` for provenance, license, and the list of
deliberately excluded (network/subprocess) subtrees.

The upstream ``optiq/__init__.py`` registered extra mlx-lm model types via an
import-time side effect that reached into ``optiq.mlx_lm_patches`` (not vendored
here); that side effect is intentionally removed so importing this package pulls
in nothing beyond the diffusion inference code and its mlx/mlx-lm/transformers
dependencies.
"""

__version__ = "0.2.3+llmpro-vendored"
