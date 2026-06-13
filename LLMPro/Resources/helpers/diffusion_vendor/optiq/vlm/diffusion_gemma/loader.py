"""Load Google's DiffusionGemma (a masked/block-diffusion LM) for OptIQ.

Unlike OptIQ's other VLMs — where mlx-lm loads the language tower and a vision
sidecar carries the towers mlx-lm drops — ``diffusion_gemma`` has **no mlx-lm
model class at all**: the whole network (encoder + masked-canvas decoder + MoE
backbone + vision tower) lives in the vendored ``optiq.vlm._mlxvlm`` subset. So
OptIQ loads, quantizes, and runs it entirely through the vendored code, with no
runtime dependency on ``mlx-vlm``.

This module replicates the model-construction + weight-load logic of
``mlx_vlm.utils.load_model`` (which is NOT vendored, since upstream's ``utils``
imports the whole mlx-vlm model registry). The quantization predicate matches
mlx-vlm exactly so a published quant round-trips bit-for-bit.
"""

from __future__ import annotations

import glob
import json
import os

import mlx.core as mx
import mlx.nn as nn

from .._mlxvlm.models.diffusion_gemma.config import ModelConfig
from .._mlxvlm.models.diffusion_gemma.diffusion_gemma import Model


def _resolve_dir(model_path: str) -> str:
    if os.path.isdir(model_path):
        return model_path
    from huggingface_hub import snapshot_download

    return snapshot_download(model_path)


def load_config(model_path: str) -> dict:
    """Read ``config.json`` from a local dir or HF repo (downloads only config)."""
    if os.path.isdir(model_path):
        return json.load(open(os.path.join(model_path, "config.json")))
    from huggingface_hub import hf_hub_download

    return json.load(open(hf_hub_download(model_path, "config.json")))


def _gather_weights(model_dir: str) -> dict:
    weights: dict = {}
    for shard in sorted(glob.glob(os.path.join(model_dir, "model*.safetensors"))):
        weights.update(mx.load(shard))
    if not weights:
        raise FileNotFoundError(f"no model*.safetensors found in {model_dir}")
    return weights


def load_diffusion_gemma(model_path: str, *, lazy: bool = False):
    """Build + load a DiffusionGemma ``Model`` from a local dir or HF repo.

    Mirrors ``mlx_vlm.utils.load_model``: instantiate from ``config.json``,
    apply the saved quantization (per-module overrides honoured), then
    ``load_weights`` the sanitized checkpoint.

    Returns ``(model, config_dict)``. ``model.eval()`` is applied.
    """
    model_dir = _resolve_dir(model_path)
    config = json.load(open(os.path.join(model_dir, "config.json")))

    model = Model(ModelConfig.from_dict(config))

    weights = model.sanitize(_gather_weights(model_dir))

    quant = config.get("quantization")
    if quant is not None:
        def class_predicate(path, module):
            # Explicit per-module bit-width (e.g. the 8-bit router/MLP layers).
            if path in quant:
                return quant[path]
            if not hasattr(module, "to_quantized"):
                return False
            if hasattr(module, "weight") and module.weight.size % 64 != 0:
                return False
            # Only quantize modules the checkpoint actually carries scales for.
            return f"{path}.scales" in weights

        nn.quantize(
            model,
            group_size=quant["group_size"],
            bits=quant["bits"],
            mode=quant.get("mode", "affine"),
            class_predicate=class_predicate,
        )

    model.load_weights(list(weights.items()))
    if not lazy:
        mx.eval(model.parameters())
    model.eval()
    return model, config
