"""Public text-generation API for OptIQ-quantized DiffusionGemma.

DiffusionGemma is a masked/block-diffusion LM: it has no mlx-lm model class and
decodes by iteratively unmasking a fixed-size canvas, not autoregressively. This
module is the clean entry point users (and ``optiq serve`` / the eval harness)
call instead of reaching into the vendored decode loop.

    from optiq.vlm.diffusion_gemma import load, generate
    model, tokenizer = load("mlx-community/diffusiongemma-26B-A4B-it-OptiQ-4bit")
    print(generate(model, tokenizer, "Write a haiku about Apple Silicon."))

Decode defaults to the fast Apple-Silicon config (greedy + confidence-threshold
sampler), the quality/speed sweet spot for this model.
"""

from __future__ import annotations

import os
from pathlib import Path

import mlx.core as mx

from .._mlxvlm.generate.diffusion import stream_diffusion_generate
from .loader import load_config, load_diffusion_gemma

DEFAULT_SAMPLER = "confidence-threshold"
DEFAULT_MAX_TOKENS = 512


class _StoppingCriteria:
    """Minimal EOS stop check the vendored decode loop expects on the tokenizer.

    The loop calls ``tokenizer.stopping_criteria(last_token)`` and may
    ``add_eos_token_ids`` — mlx-vlm attaches this in its loader, which OptIQ does
    not vendor, so we provide the small equivalent here.
    """

    def __init__(self, eos_token_ids, tokenizer=None):
        self.eos_token_ids = (
            [eos_token_ids] if isinstance(eos_token_ids, int) else list(eos_token_ids)
        )
        self.tokenizer = tokenizer

    def add_eos_token_ids(self, new_eos_token_ids=None):
        if new_eos_token_ids is None:
            return
        if isinstance(new_eos_token_ids, (str, int)):
            new_eos_token_ids = [new_eos_token_ids]
        for token in new_eos_token_ids:
            if isinstance(token, int):
                self.eos_token_ids.append(token)
            elif isinstance(token, str) and self.tokenizer is not None:
                self.eos_token_ids.append(
                    self.tokenizer.encode(" " + token, add_special_tokens=False)[-1]
                )

    def reset(self, eos_token_ids=None):
        if eos_token_ids is not None:
            self.eos_token_ids = (
                [eos_token_ids] if isinstance(eos_token_ids, int) else list(eos_token_ids)
            )

    def __call__(self, last_token) -> bool:
        try:
            last_token = int(last_token)
        except (TypeError, ValueError):
            pass
        return last_token in self.eos_token_ids


def _attach_stopping_criteria(tokenizer, config) -> None:
    if getattr(tokenizer, "stopping_criteria", None) is not None:
        return
    eos = []
    tok_eos = getattr(tokenizer, "eos_token_id", None)
    if tok_eos is not None:
        eos.append(int(tok_eos))
    cfg_eos = config.get("eos_token_id")
    if isinstance(cfg_eos, int):
        eos.append(cfg_eos)
    elif isinstance(cfg_eos, (list, tuple)):
        eos.extend(int(x) for x in cfg_eos)
    tokenizer.stopping_criteria = _StoppingCriteria(eos or [1], tokenizer)


def load(model_path: str):
    """Load an OptIQ DiffusionGemma quant → ``(model, tokenizer)``.

    Uses the vendored ``TokenizerWrapper`` (its streaming detokenizer supports
    the ``skip_special_token_ids`` the decode loop needs) and attaches the
    EOS stopping criteria.
    """
    from .._mlxvlm.tokenizer_utils import load_tokenizer

    local = os.path.abspath(model_path) if os.path.isdir(model_path) else model_path
    model, config = load_diffusion_gemma(local)
    tokenizer = load_tokenizer(Path(local))
    _attach_stopping_criteria(tokenizer, config)
    model._optiq_config = config  # multimodal token ids for the image path
    return model, tokenizer


def _build_image_inputs(model, tokenizer, prompt, images):
    """Build (input_ids, pixel_values, mm_token_type_ids) for an image+text turn.

    Preprocessing reuses OptIQ's Gemma-4 SigLIP path (bit-exact to mlx-vlm for
    this 27-layer tower) and the single ``<|image|>`` token is expanded into
    ``[boi] image_token*N [eoi]`` where N is the per-image SigLIP token count.
    """
    import numpy as np
    from ..gemma4.image_processing import preprocess_images

    cfg = getattr(model, "_optiq_config", {})
    boi, eoi, img = cfg["boi_token_id"], cfg["eoi_token_id"], cfg["image_token_id"]

    pv, soft = preprocess_images(images)
    pixel_values = mx.array(np.stack([np.array(p) for p in pv])).astype(mx.bfloat16)

    text = tokenizer.apply_chat_template(
        [{"role": "user", "content": "<|image|>" * len(images) + prompt}],
        tokenize=False, add_generation_prompt=True,
    )
    raw = tokenizer.encode(text, add_special_tokens=False)
    out, k = [], 0
    for t in raw:
        if t == img:
            out += [boi] + [img] * int(soft[k]) + [eoi]
            k += 1
        else:
            out.append(t)
    input_ids = mx.array(out, dtype=mx.int32)[None]
    mm = mx.array([[1 if t == img else 0 for t in out]], dtype=mx.int32)
    return input_ids, pixel_values, mm


def stream_generate(
    model,
    tokenizer,
    prompt,
    *,
    images=None,
    max_tokens: int = DEFAULT_MAX_TOKENS,
    temperature: float = 0.0,
    sampler: str = DEFAULT_SAMPLER,
):
    """Yield ``GenerationResult`` objects from the masked-diffusion decode.

    ``prompt`` may be a raw string, a chat-templated string, or a list of token
    ids. With ``images=[PIL.Image, ...]`` the SigLIP vision tower encodes them
    and the features are spliced into the prompt (the prompt is chat-templated
    and an ``<|image|>`` placeholder is prepended per image).
    """
    pixel_values = mm = None
    if images:
        input_ids, pixel_values, mm = _build_image_inputs(
            model, tokenizer, prompt, images
        )
    else:
        ids = tokenizer.encode(prompt, add_special_tokens=True) if isinstance(prompt, str) else list(prompt)
        input_ids = mx.array(ids, dtype=mx.int32)[None]
    yield from stream_diffusion_generate(
        model, tokenizer, tokenizer, input_ids, pixel_values, None,
        max_tokens=max_tokens, skip_special_token_ids=set(),
        temperature=temperature, diffusion_sampler=sampler,
        mm_token_type_ids=mm,
    )


def generate(
    model,
    tokenizer,
    prompt,
    *,
    images=None,
    max_tokens: int = DEFAULT_MAX_TOKENS,
    temperature: float = 0.0,
    sampler: str = DEFAULT_SAMPLER,
    verbose: bool = False,
) -> str:
    """Generate text from a prompt (optionally with ``images=``) and return the
    decoded string.

    Concatenates the non-draft segments of the diffusion stream (drafts are the
    intermediate canvas-unmasking states). The canvas starts from random noise
    and occasionally collapses to an empty result, so an empty decode is retried.
    """
    for _attempt in range(3):
        text = ""
        for r in stream_generate(
            model, tokenizer, prompt, images=images,
            max_tokens=max_tokens, temperature=temperature, sampler=sampler,
        ):
            if not getattr(r, "is_draft", False):
                text += r.text
                if verbose:
                    print(r.text, end="", flush=True)
        if text.strip():
            break
    if verbose:
        print()
    return text
