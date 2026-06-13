"""Vendored ``optiq.vlm`` namespace — DiffusionGemma inference subset only.

The upstream ``optiq/vlm/__init__.py`` eagerly imported the VLM frontend/sidecar
registry and every per-architecture front-end (gemma4, gemma4_unified, qwen3_5),
which dragged in machinery (and other model families) the DiffusionGemma decode
path does not need. That eager surface is intentionally dropped here: this file
is docstring-only so ``import optiq.vlm.diffusion_gemma`` pulls in exactly the
diffusion closure via its own relative imports and nothing else.
"""
