"""manage_experts.py — full CRUD on experts in a Mixture-of-Experts model.

Operations:
  add      — append N new experts (cloned from a source expert + noise)
  remove   — delete a comma-separated list of expert indices, trimming the router
  modify   — in-place change to one expert: re-init / add noise / clone-from-another-expert

Auto-detects two MoE tensor layouts:
  PER_EXPERT       — each expert stored separately
                     (Mixtral, Qwen-MoE, OlmoE, Granite-MoE, DBRX)
                     keys like `mlp.experts.<N>.{gate,up,down}_proj.weight`
                     OR `block_sparse_moe.experts.<N>.{w1,w2,w3}.weight`
  BATCHED          — all experts stacked into one tensor along axis 0
                     (Gemma-4 switch_glu)
                     keys like `experts.switch_glu.{gate,up,down}_proj.weight`
                     with shape [num_experts, *, *]

Output goes to a new dir under `<APP_SUPPORT>/LLMPro/models/`; the source is
never touched. The new dir is auto-rescanned by ModelRegistry.

Invoked as:
    python manage_experts.py <op> <src_dir> <dst_dir> <op-specific-args-as-json>

The op-args JSON shape (per operation):
    add:     {"count": 4, "noise_std": 0.01, "src_expert": -1}
    remove:  {"indices": [3, 7, 12]}
    modify:  {"index": 5, "op": "reinit"|"noise"|"clone",
              "noise_std": 0.01, "clone_src": 0}

Emits one JSON object per line on stdout (event: start | progress | done | error).

TENSOR I/O NOTE: we use `mlx.core` (mx.load / mx.save_safetensors) rather than
`safetensors.numpy`. The numpy backend CANNOT load bfloat16 — which is the dtype
of nearly every modern MoE (Gemma-4, Mixtral, Qwen-MoE ship bf16). mlx.core reads
and writes bf16 natively. All expert math is done in mlx as well, upcasting to
float32 only transiently per-tensor and calling `mx.eval()` after each layer so
peak memory stays bounded to roughly the model's on-disk size.
"""

from __future__ import annotations

import json
import re
import shutil
import sys
from pathlib import Path


def emit(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()


# -------- shared config helpers (dtype-agnostic, string/dict only) --------


def _get_config_expert_count(config: dict) -> tuple[int, str | None]:
    """Return (n_experts, path-of-the-field-we-found).

    The field can be at top level or nested under text_config / ffn_config.
    We return the path so we can write back to the same place.
    """
    sources = [
        (config, ""),
        (config.get("text_config", {}), "text_config."),
        (config.get("ffn_config", {}), "ffn_config."),
    ]
    for src, prefix in sources:
        if not isinstance(src, dict):
            continue
        for key in ("num_local_experts", "num_experts", "moe_num_experts"):
            v = src.get(key)
            if isinstance(v, int) and v > 1:
                return v, prefix + key
    return 0, None


def _set_config_expert_count(config: dict, new_count: int) -> None:
    """Update every expert-count field in the config to `new_count`."""
    for src in (config, config.get("text_config"), config.get("ffn_config")):
        if not isinstance(src, dict):
            continue
        for key in ("num_local_experts", "num_experts", "moe_num_experts"):
            if key in src and isinstance(src[key], int):
                src[key] = new_count


def _load_all_tensors(src: Path, mx) -> dict:
    """Load every safetensors shard into one dict of mx.arrays (bf16-safe)."""
    shards = sorted(src.glob("*.safetensors"))
    if not shards:
        raise FileNotFoundError(f"No safetensors files in {src}")
    out: dict = {}
    for sh in shards:
        emit({"event": "progress", "stage": "loading", "message": f"Loading {sh.name}"})
        out.update(mx.load(sh.as_posix()))
    return out


def _detect_num_layers(weights: dict) -> int:
    layers = set()
    pat = re.compile(r"(?:model\.|language_model\.model\.)layers\.(\d+)\.")
    for k in weights:
        m = pat.search(k)
        if m:
            layers.add(int(m.group(1)))
    if not layers:
        raise RuntimeError("Couldn't infer layer count from tensor names.")
    return max(layers) + 1


def _detect_layout(weights: dict) -> dict:
    """Return a dict describing the MoE layout, or {} if unrecognised.

    Two layout families:
      PER_EXPERT: each expert N stored as separate weight tensors. We need
        to know the per-layer prefix and how an expert's weight is named.
      BATCHED: all experts stacked into one tensor per layer along axis 0.
        We need to know the per-layer prefix and the batched-weight names.

    In both cases we also pin down the router/gate name so we can resize
    it when add/removing experts.
    """
    # Probe a few representative keys.
    sample = list(weights.keys())

    # PER_EXPERT — Mixtral style
    if any("block_sparse_moe.experts" in k for k in sample):
        return {
            "kind": "per_expert",
            "layer_pattern": "model.layers.{i}.block_sparse_moe",
            "gate_local": "gate.weight",
            "expert_template": "experts.{e}.{c}.weight",
            "expert_components": ["w1", "w2", "w3"],
        }

    # PER_EXPERT — Qwen-MoE / OlmoE / Granite-MoE style
    if any(re.search(r"mlp\.experts\.\d+\.(gate|up|down)_proj", k) for k in sample):
        return {
            "kind": "per_expert",
            "layer_pattern": "model.layers.{i}.mlp",
            "gate_local": "gate.weight",
            "expert_template": "experts.{e}.{c}.weight",
            "expert_components": ["gate_proj", "up_proj", "down_proj"],
        }

    # BATCHED — Gemma-4 switch_glu
    if any("experts.switch_glu" in k for k in sample):
        # The MoE block hangs directly off the layer (no `.mlp` wrapper) and
        # is prefixed with `language_model.model.layers.<i>`. The router lives
        # under `.router.proj.weight` per layer.
        return {
            "kind": "batched",
            "layer_pattern": "language_model.model.layers.{i}",
            "gate_local": "router.proj.weight",
            # The batched tensor names (one per component, holds all experts
            # stacked on axis 0).
            "batched_components": [
                "experts.switch_glu.gate_proj.weight",
                "experts.switch_glu.up_proj.weight",
                "experts.switch_glu.down_proj.weight",
            ],
            # Optional per-expert scale that's a 1-D tensor [num_experts]; we
            # have to extend/trim it the same way as the router.
            "router_extras": ["router.per_expert_scale"],
        }

    return {}


def _gate_tensor_lookup(weights: dict, prefix: str, gate_local: str):
    """Find the router/gate weight for a layer. Tolerates a couple of alternate
    names some architectures use."""
    primary = prefix + gate_local
    if primary in weights:
        return primary
    for alt in ("router.weight", "router.layer.weight"):
        candidate = prefix + alt
        if candidate in weights:
            return candidate
    return None


# -------- mlx tensor math primitives --------------------------------------


def _add_noise(arr, std, mx):
    """Return arr + N(0, std) computed in float32, cast back to arr's dtype.

    A copy of `arr` is returned even when std <= 0 (we still want a distinct
    array so cloning into a new slot doesn't alias the source)."""
    if std and std > 0:
        noise = mx.random.normal(arr.shape) * float(std)
        return (arr.astype(mx.float32) + noise).astype(arr.dtype)
    return arr.astype(mx.float32).astype(arr.dtype)


def _reinit(arr, mx):
    """Fresh random init, mean 0, std = 1/sqrt(fan_in), matching arr's dtype."""
    fan = arr.shape[-1] if arr.ndim >= 1 else 1
    std = (1.0 / fan) ** 0.5
    return (mx.random.normal(arr.shape) * std).astype(arr.dtype)


# -------- operations -------------------------------------------------------


def op_add(weights, layout, n_layers, n_existing, args, mx):
    """Append `count` new experts cloned from src_expert + Gaussian noise."""
    count = int(args.get("count", 1))
    noise_std = float(args.get("noise_std", 0.01))
    src_expert = int(args.get("src_expert", -1))
    if src_expert < 0:
        src_expert = n_existing - 1
    if not (0 <= src_expert < n_existing):
        raise ValueError(f"src_expert {src_expert} out of range (0..{n_existing - 1})")

    emit({"event": "progress", "stage": "cloning",
          "message": f"Adding {count} new experts cloned from expert {src_expert}"})

    new_total = n_existing + count

    for layer_i in range(n_layers):
        prefix = layout["layer_pattern"].format(i=layer_i) + "."

        if layout["kind"] == "per_expert":
            for new_idx in range(n_existing, n_existing + count):
                for comp in layout["expert_components"]:
                    src_key = prefix + layout["expert_template"].format(e=src_expert, c=comp)
                    dst_key = prefix + layout["expert_template"].format(e=new_idx,   c=comp)
                    if src_key not in weights:
                        continue
                    weights[dst_key] = _add_noise(weights[src_key], noise_std, mx)
                    mx.eval(weights[dst_key])
        else:  # batched — all experts stacked on axis 0
            for comp in layout["batched_components"]:
                tk = prefix + comp
                if tk not in weights:
                    continue
                t = weights[tk]
                src_slice = t[src_expert]
                clones = mx.stack(
                    [_add_noise(src_slice, noise_std, mx) for _ in range(count)], axis=0)
                weights[tk] = mx.concatenate([t, clones], axis=0)
                mx.eval(weights[tk])

        # Expand the router/gate to route to the new experts.
        gate_full = _gate_tensor_lookup(weights, prefix, layout["gate_local"])
        if gate_full is not None:
            gate_w = weights[gate_full]
            mean_row = mx.mean(gate_w.astype(mx.float32), axis=0, keepdims=True)
            new_rows = mx.concatenate([mean_row for _ in range(count)], axis=0)
            new_rows = (new_rows + mx.random.normal(new_rows.shape) * noise_std).astype(gate_w.dtype)
            weights[gate_full] = mx.concatenate([gate_w, new_rows], axis=0)
            mx.eval(weights[gate_full])

        # Batched layout sometimes carries auxiliary per-expert tensors.
        for aux in layout.get("router_extras", []):
            full = prefix + aux
            if full in weights:
                t = weights[full]
                if t.ndim > 1:
                    fill = mx.mean(t.astype(mx.float32), axis=0, keepdims=True)
                    pad = mx.concatenate([fill for _ in range(count)], axis=0).astype(t.dtype)
                else:
                    m = mx.mean(t.astype(mx.float32))
                    pad = (mx.zeros((count,)) + m).astype(t.dtype)
                weights[full] = mx.concatenate([t, pad], axis=0)
                mx.eval(weights[full])

        if (layer_i + 1) % 8 == 0 or layer_i == n_layers - 1:
            emit({"event": "progress", "stage": "cloning",
                  "message": f"Layer {layer_i + 1} / {n_layers} processed"})

    return new_total


def op_remove(weights, layout, n_layers, n_existing, args, mx):
    raw_indices = args.get("indices", [])
    indices = sorted({int(i) for i in raw_indices})
    indices = [i for i in indices if 0 <= i < n_existing]
    if not indices:
        raise ValueError("No valid expert indices to remove")
    if len(indices) >= n_existing - 1:
        raise ValueError(f"Refusing to leave fewer than 2 experts (would have {n_existing - len(indices)} left)")

    keep = [i for i in range(n_existing) if i not in set(indices)]
    new_total = len(keep)
    keep_idx = mx.array(keep, dtype=mx.int32)
    emit({"event": "progress", "stage": "removing",
          "message": f"Removing experts {indices} → {new_total} remain"})

    for layer_i in range(n_layers):
        prefix = layout["layer_pattern"].format(i=layer_i) + "."

        if layout["kind"] == "per_expert":
            # Re-number the surviving experts so the result has a contiguous
            # 0..new_total-1 set. This is what mlx-lm / transformers expect.
            new_weights_for_layer = {}
            for new_idx, old_idx in enumerate(keep):
                for comp in layout["expert_components"]:
                    old_key = prefix + layout["expert_template"].format(e=old_idx, c=comp)
                    new_key = prefix + layout["expert_template"].format(e=new_idx, c=comp)
                    if old_key in weights:
                        new_weights_for_layer[new_key] = weights[old_key]
            # Drop all expert tensors for this layer, then put back the renumbered ones.
            pat = re.compile(re.escape(prefix) + r"experts\.\d+\.")
            for k in [k for k in weights if pat.match(k)]:
                del weights[k]
            weights.update(new_weights_for_layer)
        else:  # batched
            for comp in layout["batched_components"]:
                tk = prefix + comp
                if tk in weights:
                    weights[tk] = mx.take(weights[tk], keep_idx, axis=0)
                    mx.eval(weights[tk])

        # Trim the router's gate weight rows.
        gate_full = _gate_tensor_lookup(weights, prefix, layout["gate_local"])
        if gate_full is not None:
            weights[gate_full] = mx.take(weights[gate_full], keep_idx, axis=0)
            mx.eval(weights[gate_full])

        for aux in layout.get("router_extras", []):
            full = prefix + aux
            if full in weights:
                weights[full] = mx.take(weights[full], keep_idx, axis=0)
                mx.eval(weights[full])

        if (layer_i + 1) % 8 == 0 or layer_i == n_layers - 1:
            emit({"event": "progress", "stage": "removing",
                  "message": f"Layer {layer_i + 1} / {n_layers} processed"})

    return new_total


def op_modify(weights, layout, n_layers, n_existing, args, mx):
    idx = int(args.get("index", -1))
    op = args.get("op", "noise")
    noise_std = float(args.get("noise_std", 0.01))
    clone_src = int(args.get("clone_src", -1))
    if not (0 <= idx < n_existing):
        raise ValueError(f"index {idx} out of range")
    if op == "clone" and not (0 <= clone_src < n_existing):
        raise ValueError(f"clone_src {clone_src} out of range")

    emit({"event": "progress", "stage": "modifying",
          "message": f"Modifying expert {idx}: {op}"})

    for layer_i in range(n_layers):
        prefix = layout["layer_pattern"].format(i=layer_i) + "."

        if layout["kind"] == "per_expert":
            for comp in layout["expert_components"]:
                tk = prefix + layout["expert_template"].format(e=idx, c=comp)
                if tk not in weights:
                    continue
                if op == "reinit":
                    weights[tk] = _reinit(weights[tk], mx)
                elif op == "noise":
                    weights[tk] = _add_noise(weights[tk], noise_std, mx)
                elif op == "clone":
                    src_key = prefix + layout["expert_template"].format(e=clone_src, c=comp)
                    if src_key in weights:
                        weights[tk] = _add_noise(weights[src_key], noise_std, mx)
                else:
                    raise ValueError(f"unknown modify op: {op}")
                mx.eval(weights[tk])
        else:  # batched — replace one slice along the expert axis
            for comp in layout["batched_components"]:
                tk = prefix + comp
                if tk not in weights:
                    continue
                t = weights[tk]
                if op == "reinit":
                    new_slice = _reinit(t[idx], mx)
                elif op == "noise":
                    new_slice = _add_noise(t[idx], noise_std, mx)
                elif op == "clone":
                    new_slice = _add_noise(t[clone_src], noise_std, mx)
                else:
                    raise ValueError(f"unknown modify op: {op}")
                # Rebuild the stacked tensor with the one slice swapped out;
                # mlx arrays don't support in-place item assignment reliably
                # under lazy eval, so we concatenate around the target index.
                weights[tk] = mx.concatenate(
                    [t[:idx], mx.expand_dims(new_slice, 0), t[idx + 1:]], axis=0)
                mx.eval(weights[tk])

        if (layer_i + 1) % 16 == 0 or layer_i == n_layers - 1:
            emit({"event": "progress", "stage": "modifying",
                  "message": f"Layer {layer_i + 1} / {n_layers} processed"})

    # Expert count doesn't change for modify.
    return n_existing


# -------- main -------------------------------------------------------------


def main() -> int:
    if len(sys.argv) < 5:
        emit({"event": "error",
              "message": "Usage: manage_experts.py <op> <src_dir> <dst_dir> <op_args_json>"})
        return 2

    op_name = sys.argv[1]
    src = Path(sys.argv[2])
    dst = Path(sys.argv[3])
    try:
        args = json.loads(sys.argv[4])
    except Exception as exc:
        emit({"event": "error", "message": f"Bad op_args JSON: {exc}"})
        return 3

    if not src.exists() or not (src / "config.json").exists():
        emit({"event": "error", "message": f"Source missing or invalid: {src}"})
        return 4

    # mlx.core is required: it's the only safetensors backend that reads/writes
    # bfloat16 (the dtype of every modern MoE we target).
    try:
        import mlx.core as mx  # type: ignore
    except ImportError as exc:
        emit({"event": "error", "message": f"mlx not installed: {exc}"})
        return 5

    emit({"event": "start", "op": op_name, "src": str(src), "dst": str(dst)})

    config = json.loads((src / "config.json").read_text())
    n_existing, count_path = _get_config_expert_count(config)
    if n_existing <= 1:
        emit({"event": "error",
              "message": "This isn't an MoE model — no num_experts / num_local_experts > 1 in config.json."})
        return 6

    mx.random.seed(int(args.get("seed", 42)))

    try:
        weights = _load_all_tensors(src, mx)
    except Exception as exc:
        emit({"event": "error", "message": f"Failed to load weights: {exc}"})
        return 7

    layout = _detect_layout(weights)
    if not layout:
        emit({"event": "error",
              "message": "Couldn't identify this MoE's tensor-naming convention. Supported: Mixtral-style, Qwen-MoE-style, Gemma-4 switch_glu."})
        return 8
    emit({"event": "progress", "stage": "detected",
          "message": f"Detected {layout['kind']} layout, {n_existing} experts, count-field at {count_path}"})

    try:
        n_layers = _detect_num_layers(weights)
    except Exception as exc:
        emit({"event": "error", "message": str(exc)})
        return 9

    try:
        if op_name == "add":
            new_total = op_add(weights, layout, n_layers, n_existing, args, mx)
        elif op_name == "remove":
            new_total = op_remove(weights, layout, n_layers, n_existing, args, mx)
        elif op_name == "modify":
            new_total = op_modify(weights, layout, n_layers, n_existing, args, mx)
        else:
            emit({"event": "error", "message": f"unknown op: {op_name} (expected add|remove|modify)"})
            return 10
    except Exception as exc:
        emit({"event": "error", "message": f"{op_name} failed: {exc}"})
        return 11

    _set_config_expert_count(config, new_total)

    emit({"event": "progress", "stage": "writing",
          "message": f"Writing {new_total}-expert model to disk"})

    if dst.exists():
        shutil.rmtree(dst)
    dst.mkdir(parents=True, exist_ok=True)

    # Copy non-weight artefacts (tokenizer, chat template, etc). We deliberately
    # skip the source's safetensors + index because we re-emit a single
    # consolidated model.safetensors below.
    for entry in src.iterdir():
        if entry.is_file() and entry.suffix == ".safetensors":
            continue
        if entry.is_file() and entry.name in ("model.safetensors.index.json", "config.json"):
            continue
        if entry.is_dir():
            shutil.copytree(entry, dst / entry.name)
        else:
            shutil.copy2(entry, dst / entry.name)

    (dst / "config.json").write_text(json.dumps(config, indent=2))
    # `format: mlx` metadata is required by LM Studio / HF transformers to
    # recognize the file. Without it indexing fails with
    # "Unsupported safetensors format: null".
    mx.eval(list(weights.values()))
    mx.save_safetensors((dst / "model.safetensors").as_posix(),
                        weights, metadata={"format": "mlx"})

    total_bytes = sum(p.stat().st_size for p in dst.glob("*.safetensors"))
    emit({
        "event": "done",
        "op": op_name,
        "dst": str(dst),
        "old_experts": n_existing,
        "new_experts": new_total,
        "bytes": int(total_bytes),
        "layout": layout["kind"],
    })
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SystemExit:
        raise
    except Exception as exc:
        emit({"event": "error", "message": f"{type(exc).__name__}: {exc}"})
        raise SystemExit(1)
