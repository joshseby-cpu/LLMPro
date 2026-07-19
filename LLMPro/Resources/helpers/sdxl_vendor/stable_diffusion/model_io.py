# Copyright © 2023-2024 Apple Inc.

import json
import os
from typing import Optional

import mlx.core as mx
from huggingface_hub import hf_hub_download
from mlx.utils import tree_unflatten

from .clip import CLIPTextModel
from .config import AutoencoderConfig, CLIPTextModelConfig, DiffusionConfig, UNetConfig
from .tokenizer import Tokenizer
from .unet import UNetModel
from .vae import Autoencoder

_DEFAULT_MODEL = "stabilityai/stable-diffusion-2-1-base"
_MODELS = {
    # See https://huggingface.co/stabilityai/sdxl-turbo for the model details and license
    "stabilityai/sdxl-turbo": {
        "unet_config": "unet/config.json",
        "unet": "unet/diffusion_pytorch_model.safetensors",
        "text_encoder_config": "text_encoder/config.json",
        "text_encoder": "text_encoder/model.safetensors",
        "text_encoder_2_config": "text_encoder_2/config.json",
        "text_encoder_2": "text_encoder_2/model.safetensors",
        "vae_config": "vae/config.json",
        "vae": "vae/diffusion_pytorch_model.safetensors",
        "diffusion_config": "scheduler/scheduler_config.json",
        "tokenizer_vocab": "tokenizer/vocab.json",
        "tokenizer_merges": "tokenizer/merges.txt",
        "tokenizer_2_vocab": "tokenizer_2/vocab.json",
        "tokenizer_2_merges": "tokenizer_2/merges.txt",
    },
    # See https://huggingface.co/stabilityai/stable-diffusion-2-1-base for the model details and license
    "stabilityai/stable-diffusion-2-1-base": {
        "unet_config": "unet/config.json",
        "unet": "unet/diffusion_pytorch_model.safetensors",
        "text_encoder_config": "text_encoder/config.json",
        "text_encoder": "text_encoder/model.safetensors",
        "vae_config": "vae/config.json",
        "vae": "vae/diffusion_pytorch_model.safetensors",
        "diffusion_config": "scheduler/scheduler_config.json",
        "tokenizer_vocab": "tokenizer/vocab.json",
        "tokenizer_merges": "tokenizer/merges.txt",
    },
}

# LLMPro: a LOCAL diffusers directory uses the standard diffusers file layout. The
# SDXL layout (dual text encoders + dual tokenizers) equals sdxl-turbo's; the SD
# 1.x/2.x layout equals sd-2-1-base's. We pick SDXL iff the dir has a text_encoder_2/.
_SDXL_LAYOUT = _MODELS["stabilityai/sdxl-turbo"]
_SD_LAYOUT = _MODELS["stabilityai/stable-diffusion-2-1-base"]

# LLMPro: filename variants a diffusers subfolder may use for the same weight, in
# preference order. Different exporters name the fp16/fp32 weight differently.
_WEIGHT_VARIANTS = {
    "unet/diffusion_pytorch_model.safetensors": [
        "unet/diffusion_pytorch_model.safetensors",
        "unet/diffusion_pytorch_model.fp16.safetensors",
    ],
    "vae/diffusion_pytorch_model.safetensors": [
        "vae/diffusion_pytorch_model.safetensors",
        "vae/diffusion_pytorch_model.fp16.safetensors",
    ],
    "text_encoder/model.safetensors": [
        "text_encoder/model.safetensors",
        "text_encoder/model.fp16.safetensors",
    ],
    "text_encoder_2/model.safetensors": [
        "text_encoder_2/model.safetensors",
        "text_encoder_2/model.fp16.safetensors",
    ],
}


def _file_map(key: str) -> Optional[dict]:
    """LLMPro: resolve the relative-path file map for a model key OR a local dir."""
    if key in _MODELS:
        return _MODELS[key]
    if os.path.isdir(key):
        return _SDXL_LAYOUT if os.path.isdir(os.path.join(key, "text_encoder_2")) else _SD_LAYOUT
    return None


def _resolve(key: str, rel: str) -> str:
    """LLMPro: resolve a model file to a local path. For a local diffusers dir, join
    (trying filename variants); otherwise download from the HF hub."""
    if os.path.isdir(key):
        for candidate in _WEIGHT_VARIANTS.get(rel, [rel]):
            p = os.path.join(key, candidate)
            if os.path.exists(p):
                return p
        return os.path.join(key, rel)  # let the caller raise a clear FileNotFound
    return hf_hub_download(key, rel)


def is_sdxl(key: str) -> bool:
    """LLMPro: True if this model key / local dir is an SDXL-family model (dual text
    encoders). Lets callers pick StableDiffusionXL vs StableDiffusion automatically."""
    fmap = _file_map(key)
    return bool(fmap) and "text_encoder_2" in fmap


def map_unet_weights(key, value):
    # Map up/downsampling
    if "downsamplers" in key:
        key = key.replace("downsamplers.0.conv", "downsample")
    if "upsamplers" in key:
        key = key.replace("upsamplers.0.conv", "upsample")

    # Map the mid block
    if "mid_block.resnets.0" in key:
        key = key.replace("mid_block.resnets.0", "mid_blocks.0")
    if "mid_block.attentions.0" in key:
        key = key.replace("mid_block.attentions.0", "mid_blocks.1")
    if "mid_block.resnets.1" in key:
        key = key.replace("mid_block.resnets.1", "mid_blocks.2")

    # Map attention layers
    if "to_k" in key:
        key = key.replace("to_k", "key_proj")
    if "to_out.0" in key:
        key = key.replace("to_out.0", "out_proj")
    if "to_q" in key:
        key = key.replace("to_q", "query_proj")
    if "to_v" in key:
        key = key.replace("to_v", "value_proj")

    # Map transformer ffn
    if "ff.net.2" in key:
        key = key.replace("ff.net.2", "linear3")
    if "ff.net.0" in key:
        k1 = key.replace("ff.net.0.proj", "linear1")
        k2 = key.replace("ff.net.0.proj", "linear2")
        v1, v2 = mx.split(value, 2)

        return [(k1, v1), (k2, v2)]

    if "conv_shortcut.weight" in key:
        value = value.squeeze()

    # Transform the weights from 1x1 convs to linear
    if len(value.shape) == 4 and ("proj_in" in key or "proj_out" in key):
        value = value.squeeze()

    if len(value.shape) == 4:
        value = value.transpose(0, 2, 3, 1)
        value = value.reshape(-1).reshape(value.shape)

    return [(key, value)]


def map_clip_text_encoder_weights(key, value):
    # Remove prefixes
    if key.startswith("text_model."):
        key = key[11:]
    if key.startswith("embeddings."):
        key = key[11:]
    if key.startswith("encoder."):
        key = key[8:]

    # Map attention layers
    if "self_attn." in key:
        key = key.replace("self_attn.", "attention.")
    if "q_proj." in key:
        key = key.replace("q_proj.", "query_proj.")
    if "k_proj." in key:
        key = key.replace("k_proj.", "key_proj.")
    if "v_proj." in key:
        key = key.replace("v_proj.", "value_proj.")

    # Map ffn layers
    if "mlp.fc1" in key:
        key = key.replace("mlp.fc1", "linear1")
    if "mlp.fc2" in key:
        key = key.replace("mlp.fc2", "linear2")

    return [(key, value)]


def map_vae_weights(key, value):
    # Map up/downsampling
    if "downsamplers" in key:
        key = key.replace("downsamplers.0.conv", "downsample")
    if "upsamplers" in key:
        key = key.replace("upsamplers.0.conv", "upsample")

    # Map attention layers
    if "to_k" in key:
        key = key.replace("to_k", "key_proj")
    if "to_out.0" in key:
        key = key.replace("to_out.0", "out_proj")
    if "to_q" in key:
        key = key.replace("to_q", "query_proj")
    if "to_v" in key:
        key = key.replace("to_v", "value_proj")

    # Map the mid block
    if "mid_block.resnets.0" in key:
        key = key.replace("mid_block.resnets.0", "mid_blocks.0")
    if "mid_block.attentions.0" in key:
        key = key.replace("mid_block.attentions.0", "mid_blocks.1")
    if "mid_block.resnets.1" in key:
        key = key.replace("mid_block.resnets.1", "mid_blocks.2")

    # Map the quant/post_quant layers
    if "quant_conv" in key:
        key = key.replace("quant_conv", "quant_proj")
        value = value.squeeze()

    # Map the conv_shortcut to linear
    if "conv_shortcut.weight" in key:
        value = value.squeeze()

    if len(value.shape) == 4:
        value = value.transpose(0, 2, 3, 1)
        value = value.reshape(-1).reshape(value.shape)

    return [(key, value)]


def _flatten(params):
    return [(k, v) for p in params for (k, v) in p]


def _load_safetensor_weights(mapper, model, weight_file, float16: bool = False):
    dtype = mx.float16 if float16 else mx.float32
    weights = mx.load(weight_file)
    weights = _flatten([mapper(k, v.astype(dtype)) for k, v in weights.items()])
    model.update(tree_unflatten(weights))


def _check_key(key: str, part: str):
    # LLMPro: also accept a local diffusers directory, not just a known HF repo id.
    if _file_map(key) is None:
        raise ValueError(
            f"[{part}] '{key}' model not found, choose one of {{{','.join(_MODELS.keys())}}} "
            f"or pass a local diffusers directory"
        )


def load_unet(key: str = _DEFAULT_MODEL, float16: bool = False):
    """Load the stable diffusion UNet from Hugging Face Hub."""
    _check_key(key, "load_unet")

    # Download the config and create the model
    unet_config = _file_map(key)["unet_config"]
    with open(_resolve(key, unet_config)) as f:
        config = json.load(f)

    n_blocks = len(config["block_out_channels"])
    model = UNetModel(
        UNetConfig(
            in_channels=config["in_channels"],
            out_channels=config["out_channels"],
            block_out_channels=config["block_out_channels"],
            layers_per_block=[config["layers_per_block"]] * n_blocks,
            transformer_layers_per_block=config.get(
                "transformer_layers_per_block", (1,) * 4
            ),
            num_attention_heads=(
                [config["attention_head_dim"]] * n_blocks
                if isinstance(config["attention_head_dim"], int)
                else config["attention_head_dim"]
            ),
            cross_attention_dim=[config["cross_attention_dim"]] * n_blocks,
            norm_num_groups=config["norm_num_groups"],
            down_block_types=config["down_block_types"],
            up_block_types=config["up_block_types"][::-1],
            addition_embed_type=config.get("addition_embed_type", None),
            addition_time_embed_dim=config.get("addition_time_embed_dim", None),
            projection_class_embeddings_input_dim=config.get(
                "projection_class_embeddings_input_dim", None
            ),
        )
    )

    # Download the weights and map them into the model
    unet_weights = _file_map(key)["unet"]
    weight_file = _resolve(key, unet_weights)
    _load_safetensor_weights(map_unet_weights, model, weight_file, float16)

    return model


def load_text_encoder(
    key: str = _DEFAULT_MODEL,
    float16: bool = False,
    model_key: str = "text_encoder",
    config_key: Optional[str] = None,
):
    """Load the stable diffusion text encoder from Hugging Face Hub."""
    _check_key(key, "load_text_encoder")

    config_key = config_key or (model_key + "_config")

    # Download the config and create the model
    text_encoder_config = _file_map(key)[config_key]
    with open(_resolve(key, text_encoder_config)) as f:
        config = json.load(f)

    with_projection = "WithProjection" in config["architectures"][0]

    model = CLIPTextModel(
        CLIPTextModelConfig(
            num_layers=config["num_hidden_layers"],
            model_dims=config["hidden_size"],
            num_heads=config["num_attention_heads"],
            max_length=config["max_position_embeddings"],
            vocab_size=config["vocab_size"],
            projection_dim=config["projection_dim"] if with_projection else None,
            hidden_act=config.get("hidden_act", "quick_gelu"),
        )
    )

    # Download the weights and map them into the model
    text_encoder_weights = _file_map(key)[model_key]
    weight_file = _resolve(key, text_encoder_weights)
    _load_safetensor_weights(map_clip_text_encoder_weights, model, weight_file, float16)

    return model


def load_autoencoder(key: str = _DEFAULT_MODEL, float16: bool = False):
    """Load the stable diffusion autoencoder from Hugging Face Hub."""
    _check_key(key, "load_autoencoder")

    # Download the config and create the model
    vae_config = _file_map(key)["vae_config"]
    with open(_resolve(key, vae_config)) as f:
        config = json.load(f)

    model = Autoencoder(
        AutoencoderConfig(
            in_channels=config["in_channels"],
            out_channels=config["out_channels"],
            latent_channels_out=2 * config["latent_channels"],
            latent_channels_in=config["latent_channels"],
            block_out_channels=config["block_out_channels"],
            layers_per_block=config["layers_per_block"],
            norm_num_groups=config["norm_num_groups"],
            scaling_factor=config.get("scaling_factor", 0.18215),
        )
    )

    # Download the weights and map them into the model
    vae_weights = _file_map(key)["vae"]
    weight_file = _resolve(key, vae_weights)
    _load_safetensor_weights(map_vae_weights, model, weight_file, float16)

    return model


def load_diffusion_config(key: str = _DEFAULT_MODEL):
    """Load the stable diffusion config from Hugging Face Hub."""
    _check_key(key, "load_diffusion_config")

    diffusion_config = _file_map(key)["diffusion_config"]
    with open(_resolve(key, diffusion_config)) as f:
        config = json.load(f)

    return DiffusionConfig(
        beta_start=config["beta_start"],
        beta_end=config["beta_end"],
        beta_schedule=config["beta_schedule"],
        num_train_steps=config["num_train_timesteps"],
    )


def load_tokenizer(
    key: str = _DEFAULT_MODEL,
    vocab_key: str = "tokenizer_vocab",
    merges_key: str = "tokenizer_merges",
):
    _check_key(key, "load_tokenizer")

    vocab_file = _resolve(key, _file_map(key)[vocab_key])
    with open(vocab_file, encoding="utf-8") as f:
        vocab = json.load(f)

    merges_file = _resolve(key, _file_map(key)[merges_key])
    with open(merges_file, encoding="utf-8") as f:
        bpe_merges = f.read().strip().split("\n")[1 : 49152 - 256 - 2 + 1]
    bpe_merges = [tuple(m.split()) for m in bpe_merges]
    bpe_ranks = dict(map(reversed, enumerate(bpe_merges)))

    return Tokenizer(bpe_ranks, vocab)
