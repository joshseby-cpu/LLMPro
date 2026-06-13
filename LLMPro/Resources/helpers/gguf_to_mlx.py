"""gguf_to_mlx.py — convert a GGUF model file into an MLX model directory.

Uses MLX's NATIVE gguf loader (`mlx.core.load(path, return_metadata=True)`) — no
PyTorch, no transformers, no llama.cpp. MLX reads the GGUF tensors (dequantizing or
re-expressing supported quants into its own `.weight`/`.scales`/`.biases` form) and
the GGUF key-value metadata, from which we rebuild an HF-style `config.json` +
tokenizer and remap GGML tensor names to the HF/MLX convention.

Two modes:
    python gguf_to_mlx.py precheck <file.gguf>
        → emits {"event":"precheck", "convertible":bool, "arch":..., "quant":...,
                 "reason":...} and exits. Reads metadata + tensor types only (fast).
    python gguf_to_mlx.py convert <file.gguf> <dst_dir> [model_name]
        → converts and writes <dst_dir>/{config.json, model.safetensors,
          tokenizer files}. Emits start/progress/done/error JSON lines.

SUPPORTED (lightweight, no extra deps): GGUF whose tensor quant types MLX's loader
can read — F32/F16, Q4_0, Q4_1, Q8_0 — for the llama/qwen2/gemma/phi/mistral
families we can map. NOT supported: K-quants (Q4_K_M, Q5_K, Q6_K, …) — MLX's native
loader can't dequantize them; precheck flags these so the caller can warn the user
to download the MLX build instead.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path


def emit(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()


# GGML tensor quant types MLX's native load_gguf can handle. (Numeric ggml type
# ids: 0=F32, 1=F16, 2=Q4_0, 3=Q4_1, 8=Q8_0. The K-quants 12=Q4_K, 13=Q5_K,
# 14=Q6_K, etc. are NOT supported by the native loader.)
SUPPORTED_GGML_TYPES = {0, 1, 2, 3, 8}
GGML_TYPE_NAMES = {
    0: "F32", 1: "F16", 2: "Q4_0", 3: "Q4_1", 6: "Q5_0", 7: "Q8_0_old",
    8: "Q8_0", 9: "Q8_1", 10: "Q2_K", 11: "Q3_K", 12: "Q4_K", 13: "Q5_K",
    14: "Q6_K", 15: "Q8_K",
}
# Architectures whose GGML→HF name mapping we implement below.
SUPPORTED_ARCHS = {"llama", "qwen2", "qwen2moe", "gemma", "gemma2", "phi2", "phi3",
                   "mistral", "stablelm", "starcoder2"}


def _scalar(meta: dict, key: str, default=None):
    v = meta.get(key)
    if v is None:
        return default
    try:
        return v.tolist() if hasattr(v, "tolist") else v
    except Exception:
        return default


def _str(meta: dict, key: str, default: str = "") -> str:
    v = _scalar(meta, key, default)
    if isinstance(v, (bytes, bytearray)):
        return bytes(v).decode("utf-8", "replace")
    if isinstance(v, list) and v and isinstance(v[0], int):
        # GGUF stores strings as int-array byte sequences in some readers.
        try:
            return bytes(v).decode("utf-8", "replace")
        except Exception:
            return str(v)
    return str(v) if v is not None else default


def precheck(gguf_path: str) -> int:
    """Read metadata + tensor types; report whether MLX can convert it."""
    try:
        from gguf import GGUFReader  # lightweight pure-python reader
    except ImportError:
        emit({"event": "error", "message": "The `gguf` package isn't installed in the runtime."})
        return 3
    try:
        r = GGUFReader(gguf_path)
    except Exception as exc:
        emit({"event": "error", "message": f"Couldn't read GGUF: {exc}"})
        return 4

    def f(key: str) -> str:
        field = r.fields.get(key)
        if not field:
            return ""
        try:
            part = field.parts[field.data[0]]
            return bytes(part).decode("utf-8", "replace")
        except Exception:
            return ""

    arch = f("general.architecture").strip().lower()
    name = f("general.name").strip()
    type_ids = {int(t.tensor_type) for t in r.tensors}
    type_names = sorted({GGML_TYPE_NAMES.get(i, f"type{i}") for i in type_ids})
    unsupported_types = type_ids - SUPPORTED_GGML_TYPES

    arch_ok = arch in SUPPORTED_ARCHS
    quant_ok = not unsupported_types

    reason = ""
    if not quant_ok:
        bad = sorted({GGML_TYPE_NAMES.get(i, f"type{i}") for i in unsupported_types})
        reason = (f"Uses K-quant tensor types {bad}, which the lightweight (no-PyTorch) "
                  f"converter can't read. Download the MLX build from HuggingFace instead, "
                  f"or re-quantize the source to Q8_0/Q4_0.")
    elif not arch_ok:
        reason = (f"Architecture '{arch or 'unknown'}' isn't in the supported set "
                  f"({', '.join(sorted(SUPPORTED_ARCHS))}).")

    emit({
        "event": "precheck",
        "convertible": bool(arch_ok and quant_ok),
        "arch": arch or "unknown",
        "name": name,
        "quant": type_names,
        "n_tensors": len(r.tensors),
        "reason": reason,
    })
    return 0


# ── GGML → HF tensor-name mapping ──────────────────────────────────────────
# GGUF names use short GGML keys; HF/MLX models use the transformers convention.
# Per-layer blocks are `blk.<i>.<sub>`; we map <sub> → the HF suffix.
_SUB_MAP = {
    "attn_q":      "self_attn.q_proj",
    "attn_k":      "self_attn.k_proj",
    "attn_v":      "self_attn.v_proj",
    "attn_output": "self_attn.o_proj",
    "attn_norm":   "input_layernorm",
    "ffn_gate":    "mlp.gate_proj",
    "ffn_up":      "mlp.up_proj",
    "ffn_down":    "mlp.down_proj",
    "ffn_norm":    "post_attention_layernorm",
    "attn_q_norm": "self_attn.q_norm",
    "attn_k_norm": "self_attn.k_norm",
}
# Top-level (non-block) names.
_TOP_MAP = {
    "token_embd":  "model.embed_tokens",
    "output_norm": "model.norm",
    "output":      "lm_head",
}


def _map_name(gguf_name: str) -> str | None:
    """Translate one GGUF tensor name to its HF/MLX equivalent. The trailing
    quant component (.weight/.scales/.biases) is preserved. Returns None to drop."""
    parts = gguf_name.split(".")
    # quant suffix: weight / scales / biases (MLX quantized triplet) or just weight
    suffix = ""
    if parts[-1] in ("weight", "scales", "biases", "bias"):
        suffix = "." + parts[-1]
        stem = ".".join(parts[:-1])
    else:
        stem = gguf_name

    if stem.startswith("blk."):
        bits = stem.split(".")
        idx = bits[1]
        sub = ".".join(bits[2:])
        hf_sub = _SUB_MAP.get(sub)
        if hf_sub is None:
            return None
        return f"model.layers.{idx}.{hf_sub}{suffix}"
    if stem in _TOP_MAP:
        return f"{_TOP_MAP[stem]}{suffix}"
    return None


def _build_config(meta: dict, arch: str) -> dict:
    """Reconstruct an HF config.json from GGUF `<arch>.*` metadata keys."""
    p = f"{arch}."
    hidden = _scalar(meta, p + "embedding_length")
    n_layers = _scalar(meta, p + "block_count")
    n_heads = _scalar(meta, p + "attention.head_count")
    n_kv = _scalar(meta, p + "attention.head_count_kv", n_heads)
    inter = _scalar(meta, p + "feed_forward_length")
    ctx = _scalar(meta, p + "context_length", 4096)
    rms_eps = _scalar(meta, p + "attention.layer_norm_rms_epsilon", 1e-5)
    rope_base = _scalar(meta, p + "rope.freq_base", 10000.0)
    vocab = _scalar(meta, "tokenizer.ggml.tokens")
    vocab_size = len(vocab) if isinstance(vocab, list) else _scalar(meta, p + "vocab_size", 32000)
    # transformers model_type: GGUF arch names mostly match, with a couple of fixes.
    model_type = {"qwen2moe": "qwen2_moe", "phi2": "phi", "phi3": "phi3"}.get(arch, arch)
    cfg = {
        "model_type": model_type,
        "architectures": [_arch_class(model_type)],
        "hidden_size": hidden,
        "num_hidden_layers": n_layers,
        "num_attention_heads": n_heads,
        "num_key_value_heads": n_kv,
        "intermediate_size": inter,
        "max_position_embeddings": ctx,
        "rms_norm_eps": rms_eps,
        "rope_theta": rope_base,
        "vocab_size": vocab_size,
        "tie_word_embeddings": _scalar(meta, p + "tie_word_embeddings", False),
    }
    return {k: v for k, v in cfg.items() if v is not None}


def _arch_class(model_type: str) -> str:
    return {
        "llama": "LlamaForCausalLM", "qwen2": "Qwen2ForCausalLM",
        "qwen2_moe": "Qwen2MoeForCausalLM", "gemma": "GemmaForCausalLM",
        "gemma2": "Gemma2ForCausalLM", "phi": "PhiForCausalLM",
        "phi3": "Phi3ForCausalLM", "mistral": "MistralForCausalLM",
        "stablelm": "StableLmForCausalLM", "starcoder2": "Starcoder2ForCausalLM",
    }.get(model_type, "LlamaForCausalLM")


def _pin_memory():
    try:
        import mlx.core as mx
        gb = float(os.environ.get("LLMPRO_MEM_LIMIT_GB", "108"))
        if hasattr(mx, "set_memory_limit"):
            mx.set_memory_limit(int(gb * (1024 ** 3)))
    except Exception:
        pass


def _unwrap(x):
    while isinstance(x, (list, tuple)) and len(x) == 1:
        x = x[0]
    return x


# ── Per-architecture fallback chat templates ───────────────────────────────
# Many instruct GGUFs (notably Qwen's own *-GGUF builds) ship WITHOUT a
# `tokenizer.ggml.chat_template` key. Without a chat template the converted MLX
# model can't be chatted with: `apply_chat_template(...)` raises "Cannot use chat
# template functions because tokenizer.chat_template is not set." When the GGUF
# carries no template we fall back to the canonical per-family Jinja template
# below, keyed off the detected arch. These are the HF-Jinja equivalents of the
# Ollama Go-templates in FuseService.swift's `OllamaChatTemplate.modelfileBody`.
#
# Each entry is (jinja_template, special_tokens) where special_tokens is a dict of
# tokenizer_config keys (bos_token / eos_token / pad_token / add_bos_token) that
# the family needs and that may be missing from the rebuilt tokenizer_config.

_CHATML_TEMPLATE = (
    "{% for message in messages %}"
    "{% if loop.first and messages[0]['role'] != 'system' %}"
    "{{ '<|im_start|>system\nYou are a helpful assistant.<|im_end|>\n' }}"
    "{% endif %}"
    "{{ '<|im_start|>' + message['role'] + '\n' + message['content'] + '<|im_end|>\n' }}"
    "{% endfor %}"
    "{% if add_generation_prompt %}{{ '<|im_start|>assistant\n' }}{% endif %}"
)

_GEMMA_TEMPLATE = (
    "{{ bos_token }}"
    "{% for message in messages %}"
    "{% if message['role'] == 'system' %}"
    "{{ '<start_of_turn>user\n' + message['content'] | trim + '\n' }}"
    "{% else %}"
    "{% set role = 'model' if message['role'] == 'assistant' else 'user' %}"
    "{{ '<start_of_turn>' + role + '\n' + message['content'] | trim + '<end_of_turn>\n' }}"
    "{% endif %}"
    "{% endfor %}"
    "{% if add_generation_prompt %}{{ '<start_of_turn>model\n' }}{% endif %}"
)

_LLAMA3_TEMPLATE = (
    "{{ bos_token }}"
    "{% for message in messages %}"
    "{{ '<|start_header_id|>' + message['role'] + '<|end_header_id|>\n\n' "
    "+ message['content'] | trim + '<|eot_id|>' }}"
    "{% endfor %}"
    "{% if add_generation_prompt %}{{ '<|start_header_id|>assistant<|end_header_id|>\n\n' }}{% endif %}"
)

_PHI3_TEMPLATE = (
    "{% for message in messages %}"
    "{% if message['role'] == 'system' %}"
    "{{ '<|system|>\n' + message['content'] + '<|end|>\n' }}"
    "{% elif message['role'] == 'user' %}"
    "{{ '<|user|>\n' + message['content'] + '<|end|>\n' }}"
    "{% elif message['role'] == 'assistant' %}"
    "{{ '<|assistant|>\n' + message['content'] + '<|end|>\n' }}"
    "{% endif %}"
    "{% endfor %}"
    "{% if add_generation_prompt %}{{ '<|assistant|>\n' }}{% endif %}"
)

_MISTRAL_TEMPLATE = (
    "{{ bos_token }}"
    "{% for message in messages %}"
    "{% if message['role'] == 'user' %}"
    "{{ '[INST] ' + message['content'] + ' [/INST]' }}"
    "{% elif message['role'] == 'assistant' %}"
    "{{ ' ' + message['content'] + eos_token }}"
    "{% endif %}"
    "{% endfor %}"
)

# arch (as detected in `convert`/`precheck`) → (template, special_tokens_to_set).
# These special tokens are only WRITTEN if the rebuilt config doesn't already have
# them; they're the minimum a family needs for its template's stop token to work.
_FALLBACK_TEMPLATES: dict[str, tuple[str, dict]] = {
    "qwen2":    (_CHATML_TEMPLATE, {"bos_token": "<|endoftext|>", "eos_token": "<|im_end|>",
                                    "pad_token": "<|endoftext|>", "add_bos_token": False}),
    "qwen2moe": (_CHATML_TEMPLATE, {"bos_token": "<|endoftext|>", "eos_token": "<|im_end|>",
                                    "pad_token": "<|endoftext|>", "add_bos_token": False}),
    "qwen3":    (_CHATML_TEMPLATE, {"bos_token": "<|endoftext|>", "eos_token": "<|im_end|>",
                                    "pad_token": "<|endoftext|>", "add_bos_token": False}),
    "gemma":    (_GEMMA_TEMPLATE, {"bos_token": "<bos>", "eos_token": "<end_of_turn>",
                                   "pad_token": "<pad>", "add_bos_token": True}),
    "gemma2":   (_GEMMA_TEMPLATE, {"bos_token": "<bos>", "eos_token": "<end_of_turn>",
                                   "pad_token": "<pad>", "add_bos_token": True}),
    "gemma3":   (_GEMMA_TEMPLATE, {"bos_token": "<bos>", "eos_token": "<end_of_turn>",
                                   "pad_token": "<pad>", "add_bos_token": True}),
    "llama":    (_LLAMA3_TEMPLATE, {"bos_token": "<|begin_of_text|>", "eos_token": "<|eot_id|>",
                                    "add_bos_token": True}),
    "phi3":     (_PHI3_TEMPLATE, {"bos_token": "<s>", "eos_token": "<|end|>",
                                  "pad_token": "<|endoftext|>", "add_bos_token": False}),
    "mistral":  (_MISTRAL_TEMPLATE, {"bos_token": "<s>", "eos_token": "</s>",
                                     "pad_token": "</s>", "add_bos_token": True}),
}


def _fallback_chat_template(arch: str) -> tuple[str | None, dict]:
    """Return (jinja_template, extra_tokenizer_config) for an arch with no GGUF
    chat template, or (None, {}) if we don't have a safe default for it."""
    tpl = _FALLBACK_TEMPLATES.get((arch or "").strip().lower())
    if tpl is None:
        return None, {}
    return tpl[0], dict(tpl[1])


# GGUF tokenizer model → the transformers GGUF converter class that builds a
# real `tokenizers` fast tokenizer from it (pure-Python; no torch needed).
def _tokenizer_converter(tok_model: str, arch: str):
    from transformers.integrations import ggml as G
    name = (tok_model or "").lower()
    if name in ("llama", "spm") or arch in ("llama", "mistral"):
        return G.GGUFLlamaConverter
    if name == "gpt2" or arch in ("qwen2", "qwen2moe", "phi2", "stablelm", "starcoder2"):
        return getattr(G, "GGUFQwen2Converter", G.GGUFGPTConverter) if arch.startswith("qwen") \
            else G.GGUFGPTConverter
    if arch in ("gemma", "gemma2"):
        return G.GGUFGemmaConverter
    if arch == "phi3":
        return G.GGUFPhi3Converter
    return G.GGUFLlamaConverter


def _write_tokenizer(gguf_path: str, meta: dict, arch: str, dst: Path) -> str | None:
    """Reconstruct a real HF tokenizer from the GGUF's embedded vocab, using
    transformers' GGUF tokenizer converters (tokens + scores + merges → a
    `tokenizers` fast tokenizer). Pure-Python — does NOT require PyTorch (we feed
    the converter the metadata dict directly, bypassing the torch-gated
    load_gguf_checkpoint). Writes tokenizer.json + tokenizer_config.json.

    Returns a `chat_template_source` string describing where the written chat
    template came from — "metadata" (carried by the GGUF), "fallback-<arch>" (a
    per-architecture default we injected because the GGUF had none), or "none"
    (no template available and no safe default) — or None if the GGUF had no
    embedded vocabulary and no tokenizer could be rebuilt at all."""
    from gguf import GGUFReader
    r = GGUFReader(gguf_path)

    def strings(key):
        f = r.fields.get(key)
        return [bytes(f.parts[d]).decode("utf-8", "replace") for d in f.data] if f else None

    def nums(key):
        f = r.fields.get(key)
        if not f:
            return None
        return [f.parts[d].tolist() if hasattr(f.parts[d], "tolist") else f.parts[d] for d in f.data]

    def sid(key):
        f = r.fields.get(key)
        if not f:
            return None
        p = f.parts[f.data[0]]
        v = p.tolist() if hasattr(p, "tolist") else p
        return int(_unwrap(v))

    tokens = strings("tokenizer.ggml.tokens")
    if not tokens:
        return None
    skel = {
        "tokens": tokens,
        "scores": nums("tokenizer.ggml.scores"),
        "token_type": nums("tokenizer.ggml.token_type"),
        "merges": strings("tokenizer.ggml.merges"),
        "unk_token_id": sid("tokenizer.ggml.unknown_token_id"),
        "bos_token_id": sid("tokenizer.ggml.bos_token_id"),
        "eos_token_id": sid("tokenizer.ggml.eos_token_id"),
        "add_bos_token": True,
        "add_eos_token": False,
    }
    skel = {k: v for k, v in skel.items() if v is not None}
    tok_model = _str(meta, "tokenizer.ggml.model", "llama")
    Converter = _tokenizer_converter(tok_model, arch)
    fast = Converter(skel).converted()
    fast.save((dst / "tokenizer.json").as_posix())

    chat_template = _str(meta, "tokenizer.ggml.chat_template")
    tok_cfg = {
        "tokenizer_class": "PreTrainedTokenizerFast",
        "bos_token_id": skel.get("bos_token_id"),
        "eos_token_id": skel.get("eos_token_id"),
        "unk_token_id": skel.get("unk_token_id"),
        "pad_token_id": sid("tokenizer.ggml.padding_token_id"),
    }
    if chat_template:
        # The GGUF shipped its own template — write it through unchanged.
        tok_cfg["chat_template"] = chat_template
        source = "metadata"
    else:
        # No template in the GGUF. Fall back to the canonical per-arch default so
        # the converted instruct model can actually be chatted with.
        fallback, extra = _fallback_chat_template(arch)
        if fallback:
            tok_cfg["chat_template"] = fallback
            # Only add special-token strings the rebuilt config doesn't already
            # carry; don't clobber anything the GGUF vocab gave us.
            for k, v in extra.items():
                tok_cfg.setdefault(k, v)
            source = f"fallback-{(arch or '').strip().lower()}"
        else:
            source = "none"
    (dst / "tokenizer_config.json").write_text(
        json.dumps({k: v for k, v in tok_cfg.items() if v is not None}, indent=2))
    return source


def convert(gguf_path: str, dst_dir: str, model_name: str = "") -> int:
    try:
        import mlx.core as mx
    except ImportError as exc:
        emit({"event": "error", "message": f"mlx not installed: {exc}"})
        return 4
    _pin_memory()

    dst = Path(dst_dir)
    emit({"event": "start", "src": gguf_path, "dst": dst_dir})
    emit({"event": "progress", "stage": "loading",
          "message": "Reading the GGUF with MLX's native loader…"})
    try:
        weights, meta = mx.load(gguf_path, return_metadata=True)
    except Exception as exc:
        emit({"event": "error",
              "message": f"MLX couldn't read this GGUF ({exc}). It's likely a K-quant "
                         f"(Q4_K_M etc.) — not supported by the lightweight converter."})
        return 5

    arch = _str(meta, "general.architecture").strip().lower()
    if arch not in SUPPORTED_ARCHS:
        emit({"event": "error", "message": f"Architecture '{arch}' isn't supported by the converter."})
        return 6

    emit({"event": "progress", "stage": "mapping",
          "message": f"Remapping {len(weights)} tensors ({arch}) to MLX layout…"})
    mapped: dict = {}
    dropped = 0
    for gname, arr in weights.items():
        hf = _map_name(gname)
        if hf is None:
            dropped += 1
            continue
        mapped[hf] = arr
    if not mapped:
        emit({"event": "error", "message": "No tensors could be mapped — unsupported GGUF layout."})
        return 7

    dst.mkdir(parents=True, exist_ok=True)
    emit({"event": "progress", "stage": "config", "message": "Rebuilding config.json + tokenizer…"})
    cfg = _build_config(meta, arch)
    # Carry MLX quantization metadata if the GGUF was quantized (scales/biases present).
    if any(k.endswith(".scales") for k in mapped):
        # MLX's load_gguf re-expresses Q4_0/Q8_0 as group-size-32 affine quant.
        cfg["quantization"] = {"group_size": 32,
                               "bits": 8 if "Q8" in "".join(_gguf_types(meta)) else 4}
    (dst / "config.json").write_text(json.dumps(cfg, indent=2))

    emit({"event": "progress", "stage": "tokenizer", "message": "Rebuilding the tokenizer from the GGUF vocab…"})
    chat_template_source = "none"
    try:
        chat_template_source = _write_tokenizer(gguf_path, meta, arch, dst)
        if chat_template_source is None:
            emit({"event": "error", "message": "The GGUF had no embedded vocabulary, so a tokenizer couldn't be rebuilt."})
            return 9
    except Exception as exc:
        emit({"event": "error",
              "message": f"Couldn't rebuild the tokenizer from the GGUF ({type(exc).__name__}: {exc}). "
                         f"The weights converted, but without a tokenizer the model won't run."})
        return 9

    emit({"event": "progress", "stage": "saving", "message": "Writing model.safetensors…"})
    try:
        mx.save_safetensors((dst / "model.safetensors").as_posix(), mapped,
                            metadata={"format": "mlx"})
    except Exception as exc:
        emit({"event": "error", "message": f"Couldn't write safetensors: {exc}"})
        return 8

    emit({"event": "done", "dst": dst_dir, "name": model_name or dst.name,
          "arch": arch, "tensors": len(mapped), "dropped": dropped,
          "quantized": "quantization" in cfg,
          "chat_template_source": chat_template_source})
    return 0


def _gguf_types(meta: dict) -> list[str]:
    # best-effort: file_type hint
    ft = _scalar(meta, "general.file_type", 0)
    return [GGML_TYPE_NAMES.get(int(ft), "")] if ft is not None else []


def main() -> int:
    if len(sys.argv) < 3:
        emit({"event": "error", "message": "Usage: gguf_to_mlx.py precheck <file> | convert <file> <dst> [name]"})
        return 2
    mode = sys.argv[1]
    if mode == "precheck":
        return precheck(sys.argv[2])
    if mode == "convert":
        if len(sys.argv) < 4:
            emit({"event": "error", "message": "convert needs <file> <dst_dir>"})
            return 2
        name = sys.argv[4] if len(sys.argv) > 4 else ""
        return convert(sys.argv[2], sys.argv[3], name)
    emit({"event": "error", "message": f"Unknown mode '{mode}'."})
    return 2


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001
        emit({"event": "error", "message": f"{type(exc).__name__}: {exc}"})
        raise SystemExit(1)
