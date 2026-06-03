"""strip_vision.py — make a text-only copy of a vision-language model.

Reads a VLM's safetensors shards, drops every tensor whose name starts with a
vision prefix, and writes the trimmed shards + a modified config.json into a new
directory. Tokenizer, generation_config, and chat-template files are copied
unchanged.

Invoked by MLXStudio as:
    python strip_vision.py <src_dir> <dst_dir>

Emits JSON progress lines on stdout, matching the format other helpers use:
    {"event": "start", "src": "...", "dst": "..."}
    {"event": "progress", "stage": "reading"|"writing", "shard": "...", "shard_num": N, "total_shards": M}
    {"event": "done", "dropped_tensors": N, "dropped_bytes": N, "kept_bytes": N}
    {"event": "error", "message": "..."}
"""

from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path

VISION_PREFIXES = (
    # LLaVA / PaliGemma / Gemma-3-VL
    "vision_tower",
    "model.vision_tower",
    "multi_modal_projector",
    "model.multi_modal_projector",
    # Qwen2.5-VL, Qwen3-VL, Qwen3.6-VL
    "visual",
    "model.visual",
    "vision",
    "model.vision",
    "vision_model",
    "model.vision_model",
    # MiniCPM-V
    "vpm",
    "model.vpm",
    "resampler",
    "model.resampler",
    # InternVL
    "mlp1",
    "model.mlp1",
    # DeepSeek-VL
    "aligner",
    "model.aligner",
    "vision_encoder",
    # Idefics
    "connector",
    "model.connector",
    "vision_proj",
    # Phi-3-Vision
    "img_processor",
    "vision_embed_tokens",
    "img_projection",
    "model.img_processor",
    "model.vision_embed_tokens",
    "model.img_projection",
    # BLIP / InstructBLIP
    "query_tokens",
    "qformer",
    "model.qformer",
    # Newline tokens used in some VLMs
    "image_newline",
    "model.image_newline",
    # Gemma-4 / generic multimodal vision-bridge embedder
    "embed_vision",
    "language_model.embed_vision",
)

VISION_CONFIG_KEYS = (
    "vision_config",
    "vision_tower_config",
    "image_token_id",
    "vision_feature_layer",
    "vision_feature_select_strategy",
    "image_aspect_ratio",
    "image_grid_pinpoints",
    "image_seq_length",
    "image_seq_len",
    "image_size",
    "mm_patch_merge_type",
    "mm_projector_type",
    "patch_size",
)


def emit(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()


def is_vision_tensor(name: str) -> bool:
    return any(name == p or name.startswith(p + ".") for p in VISION_PREFIXES)


def main() -> int:
    if len(sys.argv) < 3:
        emit({"event": "error", "message": "Usage: strip_vision.py <src_dir> <dst_dir>"})
        return 2

    src = Path(sys.argv[1])
    dst = Path(sys.argv[2])

    if not src.exists():
        emit({"event": "error", "message": f"Source not found: {src}"})
        return 3

    # We use mlx's native safetensors loader because the numpy backend can't read
    # bfloat16 (most modern MLX-quantized weights). mlx.core handles bf16 directly.
    try:
        import mlx.core as mx  # type: ignore
    except ImportError as exc:
        emit({"event": "error", "message": f"mlx not installed: {exc}"})
        return 4

    cfg_path = src / "config.json"
    if not cfg_path.exists():
        emit({"event": "error", "message": "No config.json — not a HuggingFace-format model directory"})
        return 5

    cfg = json.loads(cfg_path.read_text())
    has_vlm_marker = any(k in cfg for k in VISION_CONFIG_KEYS) or "text_config" in cfg
    if not has_vlm_marker:
        emit({"event": "error",
              "message": "This is already a text-only model — there are no vision components to remove. Vision-stripping only applies to vision-language models like Qwen-VL, LLaVA, MiniCPM-V, etc."})
        return 6

    # Gemma-4 needs a more conservative strip than the generic path. Empirical
    # findings (verified end-to-end via mlx-lm):
    #   - Dropping `vision_tower.*` is safe and saves ~1 GB.
    #   - Dropping `embed_vision.embedding_projection.weight` BREAKS the text
    #     path (model emits only `<pad>` tokens). Keep it.
    #   - Renaming `language_model.` → `model.` BREAKS the text path the same
    #     way. Keep the prefix.
    #   - Flattening `text_config` up to top level isn't needed either —
    #     mlx-lm handles the nested config fine for Gemma-4 when we just
    #     rewrite `architectures` to the text-only class.
    # So Gemma-4 gets a dedicated path that drops only vision_tower.* and
    # rewrites architectures + removes the vision_config block — nothing else.
    cfg_model_type = cfg.get("model_type", "")
    inner_model_type = (cfg.get("text_config", {}) or {}).get("model_type", "")
    is_gemma4 = cfg_model_type.startswith("gemma4") or inner_model_type.startswith("gemma4")

    dst.mkdir(parents=True, exist_ok=True)
    emit({"event": "start", "src": str(src), "dst": str(dst)})

    # Figure out the shard layout.
    index_path = src / "model.safetensors.index.json"
    if index_path.exists():
        index = json.loads(index_path.read_text())
        weight_map = index.get("weight_map", {})
        # group keys by source file
        shards: dict[str, list[str]] = {}
        for key, fname in weight_map.items():
            shards.setdefault(fname, []).append(key)
    else:
        # single-file model
        single = src / "model.safetensors"
        if not single.exists():
            emit({"event": "error", "message": "No safetensors files found (no index, no model.safetensors)"})
            return 7
        shards = {"model.safetensors": None}  # None → read all keys from the file

    new_weight_map: dict[str, str] = {}
    dropped_tensors = 0
    dropped_bytes = 0
    kept_bytes = 0
    total_shards = len(shards)

    # For most multimodal models (Llama-4-Vision style) the LLM is wrapped
    # under `language_model.<...>`, and the text-only model class expects
    # bare `model.<...>` tensor names — so we strip the prefix. Gemma-4 is
    # the exception: empirically renaming the prefix kills its forward pass,
    # so we keep `language_model.<...>` intact when is_gemma4 is true.
    def needs_prefix_strip() -> bool:
        if is_gemma4:
            return False
        sample_keys: list[str] = []
        if index_path.exists():
            sample_keys = list(weight_map.keys())
        else:
            from safetensors import safe_open
            with safe_open((src / "model.safetensors").as_posix(), framework="numpy") as f:
                sample_keys = list(f.keys())
        non_vision = [k for k in sample_keys if not is_vision_tensor_for(k)]
        if not non_vision:
            return False
        return all(k.startswith("language_model.") for k in non_vision)

    # Gemma-4 needs its own "is vision" predicate too: ONLY `vision_tower.*`
    # gets dropped. Generic predicate (which also drops `embed_vision.*`)
    # would break the text path.
    def is_vision_tensor_for(name: str) -> bool:
        if is_gemma4:
            return name.startswith("vision_tower.")
        return is_vision_tensor(name)

    strip_prefix = needs_prefix_strip()
    if strip_prefix:
        emit({"event": "progress", "stage": "renaming",
              "message": "Multimodal wrapper detected: stripping `language_model.` prefix from text tensors so the text-only loader (Gemma4TextModel etc) recognizes them"})
    elif is_gemma4:
        emit({"event": "progress", "stage": "gemma4-safe",
              "message": "Gemma-4 detected — using conservative strip (only vision_tower.* dropped; embed_vision + language_model.* prefix preserved to keep text inference working)"})

    def rename(key: str) -> str:
        return key[len("language_model."):] if strip_prefix and key.startswith("language_model.") else key

    def tensor_nbytes(t) -> int:
        return getattr(t, "nbytes", t.size * t.itemsize)

    for shard_idx, (fname, keys) in enumerate(shards.items(), start=1):
        in_path = src / fname
        out_path = dst / fname
        emit({"event": "progress", "stage": "reading", "shard": fname,
              "shard_num": shard_idx, "total_shards": total_shards})

        # mx.load returns the full dict of arrays in this safetensors file.
        # For multi-GB shards this peaks at the shard's size in RAM (fine for typical 4-8 GB shards).
        shard_arrays = mx.load(in_path.as_posix())
        file_keys = keys if keys is not None else list(shard_arrays.keys())

        out_arrays = {}
        for key in file_keys:
            arr = shard_arrays.get(key)
            if arr is None:
                continue
            sz = tensor_nbytes(arr)
            if is_vision_tensor_for(key):
                dropped_tensors += 1
                dropped_bytes += sz
                continue
            new_key = rename(key)
            out_arrays[new_key] = arr
            new_weight_map[new_key] = fname
            kept_bytes += sz

        if out_arrays:
            emit({"event": "progress", "stage": "writing", "shard": fname,
                  "shard_num": shard_idx, "total_shards": total_shards})
            # Set `format: mlx` metadata. Without it LM Studio reads the
            # file's metadata as null and refuses to index with
            # "Unsupported safetensors format: null". HF transformers also
            # uses this field to pick the right tensor loader.
            mx.save_safetensors(out_path.as_posix(), out_arrays,
                                metadata={"format": "mlx"})

    # Rewrite the index (only relevant if multi-shard).
    if index_path.exists() and total_shards > 1:
        new_index = {
            "metadata": {"total_size": kept_bytes},
            "weight_map": new_weight_map,
        }
        (dst / "model.safetensors.index.json").write_text(json.dumps(new_index, indent=2))

    # Rewrite config.json: drop vision-specific keys; mark as language-model-only;
    # FLATTEN `text_config` up to top level + REWRITE `architectures` to the
    # text-only class. The flatten + rewrite combo is critical for downstream
    # loaders (LM Studio, plain HF transformers) — they pick the model class
    # from `architectures`, and if it still says
    # `Gemma4ForConditionalGeneration` they'll try to load the now-stripped
    # vision tensors and fail to index. mlx-lm tolerates nested configs so
    # this also keeps the stripped model loadable everywhere.
    new_cfg = {k: v for k, v in cfg.items() if k not in VISION_CONFIG_KEYS}
    new_cfg["language_model_only"] = True
    # Lift text_config keys to top level for the GENERIC path (Llama-4 vision,
    # MiniCPM-V style). Gemma-4 needs the nested config kept intact — flatten
    # there empirically breaks inference, same way the prefix strip does.
    if not is_gemma4:
        text_config = new_cfg.pop("text_config", None)
        if isinstance(text_config, dict):
            for k, v in text_config.items():
                if k not in new_cfg or k == "model_type":
                    new_cfg[k] = v
            for k in ("audio_config", "vision_tower", "image_processor_config",
                      "audio_token_id", "boa_token_id", "boi_token_id",
                      "eoa_token_id", "eoa_token_index", "eoi_token_id",
                      "video_token_id", "vision_soft_tokens_per_image"):
                new_cfg.pop(k, None)
    # Rewrite architectures: strip multimodal suffix/infix tokens.
    archs = new_cfg.get("architectures")
    if isinstance(archs, list):
        rewritten: list[str] = []
        for a in archs:
            new_a = (a
                .replace("ForConditionalGeneration", "ForCausalLM")
                .replace("VLForCausalLM", "ForCausalLM")
                .replace("VisionForCausalLM", "ForCausalLM")
                .replace("VForCausalLM", "ForCausalLM"))
            rewritten.append(new_a)
        new_cfg["architectures"] = rewritten
    (dst / "config.json").write_text(json.dumps(new_cfg, indent=2))

    # Copy companion files unchanged.
    for fname in (
        "tokenizer.json",
        "tokenizer_config.json",
        "tokenizer.model",
        "special_tokens_map.json",
        "added_tokens.json",
        "chat_template.jinja",
        "generation_config.json",
        "configuration.json",
        # NOTE: preprocessor_config.json / processor_config.json are vision-related;
        # we skip them because the text-only model doesn't need them and their presence
        # confuses some loaders.
        "README.md",
        "LICENSE",
        "LICENSE.txt",
    ):
        src_f = src / fname
        if src_f.exists():
            shutil.copy2(src_f, dst / fname)

    emit({
        "event": "done",
        "dst": str(dst),
        "dropped_tensors": dropped_tensors,
        "dropped_bytes": dropped_bytes,
        "kept_bytes": kept_bytes,
    })
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
