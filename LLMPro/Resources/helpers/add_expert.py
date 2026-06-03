"""add_expert.py — sparse upcycling: add N new experts to an existing MoE model.

This is the "expert expansion" variant of sparse upcycling (Komatsuzaki et
al, 2023 — https://arxiv.org/abs/2212.05055). The classic paper goes from a
DENSE model to an MoE; here we extend an existing MoE by cloning its last
expert N times (with small Gaussian noise so the clones diverge during
training) and widening every router so it can route to the new experts.

The output is a NEW model in `<dst_dir>/`. The original is untouched.

EXPERIMENTAL: the model will load (we preserve the architecture's tensor
naming convention), but whether the expanded experts give you anything
useful depends entirely on follow-up fine-tuning. Without fine-tuning, the
new experts are noise-perturbed copies of one existing expert — the model
will behave nearly identically to the original.

Invoked as:
    python add_expert.py <src_dir> <dst_dir> <num_new_experts> [noise_std]

Emits JSON progress lines on stdout (event: start | progress | done | error).
"""

from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path


def emit(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()


def _detect_moe_naming(config: dict, weight_names: list[str]) -> dict:
    """Figure out which tensor-name convention this MoE uses.

    Returns a dict with:
        prefix    — the per-layer prefix, e.g. "model.layers.{i}.block_sparse_moe"
        gate_key  — within prefix, the router weight's local name (e.g. "gate.weight")
        expert_template — within prefix, how an expert's weights are named
                          (e.g. "experts.{i}.w1.weight")
        expert_components — list of sub-weight names per expert (["w1", "w2", "w3"]
                            or ["gate_proj", "up_proj", "down_proj"])
        num_experts_key — config.json field name for expert count
                         ("num_local_experts" or "num_experts")
    """
    # Mixtral / DeepSeek-MoE style
    if any("block_sparse_moe" in n for n in weight_names):
        return {
            "layer_pattern": "model.layers.{i}.block_sparse_moe",
            "gate_local":    "gate.weight",
            "expert_template": "experts.{e}.{c}.weight",
            "expert_components": ["w1", "w2", "w3"],
            "num_experts_key": "num_local_experts",
        }
    # Qwen-MoE / OlmoE / Granite-MoE / Gemma-MoE — mlp.experts.<N>.{gate,up,down}_proj
    if any(".mlp.experts." in n for n in weight_names):
        return {
            "layer_pattern": "model.layers.{i}.mlp",
            "gate_local":    "gate.weight",
            "expert_template": "experts.{e}.{c}.weight",
            "expert_components": ["gate_proj", "up_proj", "down_proj"],
            "num_experts_key": "num_local_experts" if config.get("num_local_experts") else "num_experts",
        }
    return {}


def _load_all_tensors(src: Path) -> dict:
    """Load every safetensors tensor in `src` into a dict {name: numpy_array}."""
    from safetensors.numpy import load_file
    out: dict = {}
    shards = sorted(src.glob("*.safetensors"))
    if not shards:
        shards = sorted(src.glob("model-*-of-*.safetensors"))
    if not shards:
        raise FileNotFoundError(f"No safetensors files in {src}")
    for sh in shards:
        emit({"event": "progress", "stage": "loading",
              "message": f"Loading {sh.name}"})
        out.update(load_file(sh.as_posix()))
    return out


def _detect_num_layers(weights: dict) -> int:
    """Scan tensor names for the largest layers.N index."""
    layers = set()
    for k in weights:
        # Match "model.layers.<i>.something"
        if not k.startswith("model.layers."):
            continue
        tail = k[len("model.layers."):]
        idx_str = tail.split(".", 1)[0]
        if idx_str.isdigit():
            layers.add(int(idx_str))
    if not layers:
        raise RuntimeError("Couldn't infer layer count from tensor names — unsupported MoE layout.")
    return max(layers) + 1


def main() -> int:
    if len(sys.argv) < 4:
        emit({"event": "error", "message": "Usage: add_expert.py <src_dir> <dst_dir> <num_new_experts> [noise_std]"})
        return 2

    src = Path(sys.argv[1])
    dst = Path(sys.argv[2])
    try:
        num_new = int(sys.argv[3])
    except ValueError:
        emit({"event": "error", "message": "<num_new_experts> must be an integer"})
        return 2
    noise_std = float(sys.argv[4]) if len(sys.argv) > 4 else 0.01

    if num_new < 1:
        emit({"event": "error", "message": "num_new_experts must be >= 1"})
        return 2

    if not src.exists():
        emit({"event": "error", "message": f"Source not found: {src}"})
        return 3
    cfg_path = src / "config.json"
    if not cfg_path.exists():
        emit({"event": "error", "message": f"Source missing config.json: {src}"})
        return 3

    try:
        import numpy as np
        from safetensors.numpy import save_file
    except ImportError as exc:
        emit({"event": "error", "message": f"Missing dep: {exc}"})
        return 4

    emit({"event": "start", "src": str(src), "dst": str(dst), "num_new_experts": num_new})

    config = json.loads(cfg_path.read_text())

    # Confirm this IS an MoE.
    existing_experts = (
        config.get("num_local_experts")
        or config.get("num_experts")
        or (config.get("ffn_config", {}) or {}).get("moe_num_experts")
        or 0
    )
    if existing_experts <= 1:
        emit({"event": "error",
              "message": "This isn't an MoE model — it has no experts to clone. (For dense models, sparse upcycling needs a different recipe.)"})
        return 5

    emit({"event": "progress", "stage": "loading",
          "message": f"Loading current weights ({existing_experts} experts → {existing_experts + num_new})"})

    try:
        weights = _load_all_tensors(src)
    except Exception as exc:
        emit({"event": "error", "message": f"Failed to load weights: {exc}"})
        return 6

    weight_names = list(weights.keys())
    naming = _detect_moe_naming(config, weight_names)
    if not naming:
        emit({"event": "error",
              "message": "Couldn't identify this MoE's tensor-naming convention. Only Mixtral-style and Qwen-MoE-style layouts are supported."})
        return 7

    try:
        n_layers = _detect_num_layers(weights)
    except Exception as exc:
        emit({"event": "error", "message": str(exc)})
        return 7

    last_expert = existing_experts - 1
    rng = np.random.default_rng(seed=42)
    n_cloned = 0

    for layer_i in range(n_layers):
        prefix = naming["layer_pattern"].format(i=layer_i) + "."

        # Look up the router/gate weight for this layer. Some MoE families
        # don't have a per-layer gate (rare), so we tolerate missing gates.
        gate_full = prefix + naming["gate_local"]
        gate_w = weights.get(gate_full)
        if gate_w is None:
            # Try a couple of alternate gate names.
            for alt in ("router.weight", "router.layer.weight"):
                gate_w = weights.get(prefix + alt)
                if gate_w is not None:
                    gate_full = prefix + alt
                    break

        # For each new expert: clone the last expert's tensors with noise.
        for new_idx in range(existing_experts, existing_experts + num_new):
            for comp in naming["expert_components"]:
                src_key = prefix + naming["expert_template"].format(e=last_expert, c=comp)
                dst_key = prefix + naming["expert_template"].format(e=new_idx,   c=comp)
                if src_key not in weights:
                    # Not all components exist in all architectures — skip silently.
                    continue
                w = weights[src_key].astype(np.float32, copy=True)
                noise = rng.normal(0.0, noise_std, size=w.shape).astype(w.dtype)
                weights[dst_key] = (w + noise).astype(weights[src_key].dtype)
                n_cloned += 1

        # Expand the router. The router weight is [num_experts, hidden_size];
        # we need to add num_new rows. Init to the mean of existing rows +
        # small noise so the new experts get *some* routing probability
        # without dominating.
        if gate_w is not None:
            mean_row = gate_w.mean(axis=0, keepdims=True)
            new_rows = np.repeat(mean_row, num_new, axis=0)
            row_noise = rng.normal(0.0, noise_std, size=new_rows.shape).astype(new_rows.dtype)
            new_rows = (new_rows + row_noise).astype(gate_w.dtype)
            weights[gate_full] = np.concatenate([gate_w, new_rows], axis=0)

        if (layer_i + 1) % 4 == 0 or layer_i == n_layers - 1:
            emit({"event": "progress", "stage": "cloning",
                  "message": f"Layer {layer_i + 1} / {n_layers}: cloned {n_cloned} expert tensors so far"})

    # Update config.json with the new expert count.
    new_total = existing_experts + num_new
    if "num_local_experts" in config:
        config["num_local_experts"] = new_total
    if "num_experts" in config:
        config["num_experts"] = new_total
    ffn_cfg = config.get("ffn_config")
    if isinstance(ffn_cfg, dict) and "moe_num_experts" in ffn_cfg:
        ffn_cfg["moe_num_experts"] = new_total

    emit({"event": "progress", "stage": "writing",
          "message": f"Writing expanded model ({new_total} experts) to disk"})

    # Wipe target dir if it exists, then re-create it.
    if dst.exists():
        shutil.rmtree(dst)
    dst.mkdir(parents=True, exist_ok=True)

    # Copy everything from src except the safetensors (we'll write fresh ones).
    for entry in src.iterdir():
        if entry.is_file() and entry.suffix == ".safetensors":
            continue
        if entry.is_file() and entry.name == "model.safetensors.index.json":
            continue   # we'll regenerate
        if entry.is_file() and entry.name == "config.json":
            continue   # we'll write the updated one
        if entry.is_dir():
            shutil.copytree(entry, dst / entry.name)
        else:
            shutil.copy2(entry, dst / entry.name)

    # Write the updated config.
    (dst / "config.json").write_text(json.dumps(config, indent=2))

    # Write all weights as a single shard. (mlx-lm copes with either layout —
    # single-file or sharded — and a single file simplifies the helper.)
    # `format: mlx` metadata is required by LM Studio / HF transformers to
    # recognize the file. Without it indexing fails with
    # "Unsupported safetensors format: null".
    save_file({k: v for k, v in weights.items()},
              (dst / "model.safetensors").as_posix(),
              metadata={"format": "mlx"})

    total_bytes = sum(p.stat().st_size for p in dst.glob("*.safetensors"))
    emit({
        "event": "done",
        "dst": str(dst),
        "old_experts": existing_experts,
        "new_experts": new_total,
        "bytes": int(total_bytes),
    })
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
