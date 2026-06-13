"""Gemma-4 image preprocessing (vendored from mlx-vlm, BSD-3).

Native-resolution, aspect-ratio-preserving resize into a fixed soft-token
budget, then rescale to [0, 1]. Deliberately depends only on Pillow + numpy
(no transformers / torchvision) so OptIQ carries no extra runtime engine.

The math mirrors ``Gemma4ImageProcessor.aspect_ratio_preserving_resize`` /
``preprocess`` exactly (BICUBIC resample, do_rescale, do_normalize=False), so
the pixel_values it emits are bit-identical to mlx-vlm's.
"""

from __future__ import annotations

import math

import numpy as np
from PIL import Image

# Gemma-4 defaults (from the published processor config).
PATCH_SIZE = 16
MAX_SOFT_TOKENS = 280
POOLING_KERNEL_SIZE = 3
RESCALE_FACTOR = 1.0 / 255.0


def _aspect_ratio_preserving_resize(
    img: Image.Image,
    patch_size: int,
    max_patches: int,
    pooling_kernel_size: int,
) -> Image.Image:
    """Resize so the image (a) yields at most ``max_patches`` patches and
    (b) has H and W divisible by ``pooling_kernel_size * patch_size``."""
    width, height = img.size  # PIL is (W, H)
    target_px = max_patches * (patch_size**2)
    factor = math.sqrt(target_px / (height * width))
    side_mult = pooling_kernel_size * patch_size

    target_height = int(math.floor(factor * height / side_mult)) * side_mult
    target_width = int(math.floor(factor * width / side_mult)) * side_mult

    if target_height == 0 and target_width == 0:
        raise ValueError("Attempting to resize to a 0 x 0 image.")

    max_side_length = (max_patches // pooling_kernel_size**2) * side_mult
    if target_height == 0:
        target_height = side_mult
        target_width = min(int(math.floor(width / height)) * side_mult, max_side_length)
    elif target_width == 0:
        target_width = side_mult
        target_height = min(
            int(math.floor(height / width)) * side_mult, max_side_length
        )

    if target_height == height and target_width == width:
        return img
    return img.resize((target_width, target_height), resample=Image.BICUBIC)


def preprocess_images(
    images: Image.Image | list[Image.Image],
    *,
    patch_size: int = PATCH_SIZE,
    max_soft_tokens: int = MAX_SOFT_TOKENS,
    pooling_kernel_size: int = POOLING_KERNEL_SIZE,
) -> tuple[list[np.ndarray], list[int]]:
    """Return ``(pixel_values_per_image, soft_tokens_per_image)``.

    Each ``pixel_values`` entry is a float32 ``[3, H, W]`` array in [0, 1].
    Images may have different shapes (native resolution), so the result is a
    list rather than a stacked batch.
    """
    if isinstance(images, Image.Image):
        images = [images]
    max_patches = max_soft_tokens * pooling_kernel_size**2

    processed: list[np.ndarray] = []
    soft_tokens: list[int] = []
    for img in images:
        img = img.convert("RGB")
        img = _aspect_ratio_preserving_resize(
            img, patch_size, max_patches, pooling_kernel_size
        )
        arr = np.asarray(img, dtype=np.float32) * RESCALE_FACTOR  # [H, W, 3], [0,1]
        arr = np.transpose(arr, (2, 0, 1))  # -> [3, H, W]
        processed.append(arr)

        h, w = arr.shape[-2], arr.shape[-1]
        n_patches = (h // patch_size) * (w // patch_size)
        soft_tokens.append(n_patches // (pooling_kernel_size**2))

    return processed, soft_tokens
