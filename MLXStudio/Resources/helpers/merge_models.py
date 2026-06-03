"""merge_models.py — merge two or more models into one using mergekit.

This is the engine behind MLX Studio's "Fusion" tab. The user picks several
local models, picks a merge method (SLERP / Linear / TIES / DARE-TIES), and
this script produces a brand-new model on disk.

We wrap mergekit's YAML-driven runner rather than calling its Python API
directly, because mergekit's API surface evolves between releases but the
YAML config has stayed stable. We translate our internal JSON config to a
mergekit YAML and shell out to `python -m mergekit.scripts.run_yaml`.

Invoked by MLXStudio as:
    python merge_models.py <config_json_path> <output_dir>

The JSON config is shaped like:
    {
      "method": "slerp",                # slerp | linear | ties | dare
      "models": [{"path": "...", "weight": 0.5}, ...],
      "t": 0.5,                          # SLERP-only: interpolation 0..1
      "density": 0.5,                    # TIES/DARE-only: pruning density
      "dtype": "bfloat16"
    }

Emits JSON progress lines on stdout (event: start | progress | done | error).
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path


def emit(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()


def build_yaml(cfg: dict) -> str:
    """Translate our internal JSON config to a mergekit YAML string.

    mergekit's grammar varies per method:
      - SLERP needs a base_model + exactly one other model, plus parameters.t
      - Linear takes N models with per-model weights
      - TIES needs a base_model + N others, each with weight + density
      - DARE-TIES is like TIES but with the merge_method 'dare_ties'
    """
    import yaml  # PyYAML — comes in via mergekit's deps

    method = cfg.get("method", "slerp")
    dtype = cfg.get("dtype", "bfloat16")
    models = cfg.get("models", [])
    if not models:
        raise ValueError("config.models is empty")

    out: dict = {"dtype": dtype}

    if method == "slerp":
        if len(models) != 2:
            raise ValueError("SLERP requires exactly two models")
        out["merge_method"] = "slerp"
        out["base_model"] = models[0]["path"]
        out["models"] = [
            {"model": models[0]["path"]},
            {"model": models[1]["path"]},
        ]
        # mergekit's SLERP can take a single t or per-filter t maps. Single is fine.
        out["parameters"] = {"t": float(cfg.get("t", 0.5))}

    elif method == "linear":
        out["merge_method"] = "linear"
        total = sum(float(m.get("weight", 1.0)) for m in models) or 1.0
        out["models"] = [
            {
                "model": m["path"],
                "parameters": {"weight": float(m.get("weight", 1.0)) / total},
            }
            for m in models
        ]

    elif method == "ties":
        if len(models) < 2:
            raise ValueError("TIES requires at least two models")
        out["merge_method"] = "ties"
        out["base_model"] = models[0]["path"]
        density = float(cfg.get("density", 0.5))
        # The base contributes its identity; the others contribute weighted deltas.
        out["models"] = [
            {
                "model": m["path"],
                "parameters": {
                    "weight": float(m.get("weight", 1.0 / max(1, len(models) - 1))),
                    "density": density,
                },
            }
            for m in models[1:]
        ]
        out["parameters"] = {"normalize": True, "int8_mask": True}

    elif method == "dare":
        if len(models) < 2:
            raise ValueError("DARE-TIES requires at least two models")
        out["merge_method"] = "dare_ties"
        out["base_model"] = models[0]["path"]
        density = float(cfg.get("density", 0.5))
        out["models"] = [
            {
                "model": m["path"],
                "parameters": {
                    "weight": float(m.get("weight", 1.0 / max(1, len(models) - 1))),
                    "density": density,
                },
            }
            for m in models[1:]
        ]
        out["parameters"] = {"normalize": True, "int8_mask": True}

    else:
        raise ValueError(f"Unknown merge method: {method}")

    return yaml.safe_dump(out, sort_keys=False)


def _validate_inputs(cfg: dict) -> None:
    """Check each input path exists and has a config.json."""
    for m in cfg.get("models", []):
        p = Path(m["path"])
        if not p.exists():
            raise FileNotFoundError(f"Input model not found: {p}")
        if not (p / "config.json").exists():
            raise FileNotFoundError(f"Input model missing config.json: {p}")
        # Reject MLX-quantized inputs — mergekit loads via HF transformers
        # which doesn't understand MLX's quantization block in config.json.
        try:
            cfg_text = (p / "config.json").read_text()
            if '"quantization"' in cfg_text and '"bits"' in cfg_text:
                raise ValueError(
                    f"{p.name} is quantized (MLX 4-bit/8-bit). Mergekit can only "
                    "merge full-precision weights. Use a bf16 / fp16 version."
                )
        except OSError:
            pass


def main() -> int:
    if len(sys.argv) < 3:
        emit({"event": "error", "message": "Usage: merge_models.py <config_json> <output_dir>"})
        return 2

    config_path = Path(sys.argv[1])
    output_dir = Path(sys.argv[2])

    try:
        cfg = json.loads(config_path.read_text())
    except Exception as exc:
        emit({"event": "error", "message": f"Bad config JSON: {exc}"})
        return 3

    try:
        _validate_inputs(cfg)
    except Exception as exc:
        emit({"event": "error", "message": str(exc)})
        return 4

    try:
        yaml_str = build_yaml(cfg)
    except Exception as exc:
        emit({"event": "error", "message": f"Failed to build mergekit config: {exc}"})
        return 5

    # Write the YAML next to the output dir so it's easy to find / inspect.
    yaml_path = output_dir.parent / f".mergekit-{output_dir.name}.yaml"
    yaml_path.parent.mkdir(parents=True, exist_ok=True)
    yaml_path.write_text(yaml_str)

    emit({"event": "start",
          "method": cfg.get("method"),
          "n_models": len(cfg.get("models", []))})

    # mergekit refuses to overwrite an existing output dir.
    if output_dir.exists():
        shutil.rmtree(output_dir)

    emit({"event": "progress",
          "stage": "loading",
          "message": "Loading models into memory (the slow part — each one fully loaded once)"})

    # Run mergekit. Capture stdout+stderr together so we can surface its
    # progress messages as our progress events. mergekit writes "Loading X",
    # "Merging tensor Y", "Saving" lines.
    try:
        proc = subprocess.Popen(
            [sys.executable, "-m", "mergekit.scripts.run_yaml",
             str(yaml_path), str(output_dir),
             "--copy-tokenizer", "--allow-crimes"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
    except FileNotFoundError:
        emit({"event": "error", "message": "mergekit not installed in the venv. Restart MLXStudio so it can re-bootstrap the Python runtime."})
        return 6
    except Exception as exc:
        emit({"event": "error", "message": f"Couldn't launch mergekit: {exc}"})
        return 7

    last_msg = ""
    assert proc.stdout is not None
    for raw in proc.stdout:
        line = raw.rstrip()
        if not line:
            continue
        last_msg = line[:200]
        # Classify a few common mergekit lines into stages so the UI has a
        # coarse "what's happening right now" rather than just raw log spam.
        lower = line.lower()
        if "loading" in lower or "load:" in lower:
            stage = "loading"
        elif "saving" in lower or "writing" in lower or "save:" in lower:
            stage = "saving"
        elif "tokenizer" in lower:
            stage = "tokenizer"
        else:
            stage = "merging"
        emit({"event": "progress", "stage": stage, "message": last_msg})

    proc.wait()
    if proc.returncode != 0:
        emit({"event": "error", "message": f"mergekit failed (exit {proc.returncode}): {last_msg or 'see logs'}"})
        return 8

    # Best-effort cleanup of the temp YAML.
    yaml_path.unlink(missing_ok=True)

    # Sanity-check the output landed.
    if not (output_dir / "config.json").exists():
        emit({"event": "error", "message": "mergekit completed but produced no config.json. Output may be corrupt."})
        return 9

    safetensors = list(output_dir.glob("*.safetensors")) + list(output_dir.glob("model-*-of-*.safetensors"))
    total_bytes = sum(p.stat().st_size for p in safetensors)

    emit({
        "event": "done",
        "dst": str(output_dir),
        "bytes": int(total_bytes),
        "n_safetensors": len(safetensors),
        "method": cfg.get("method"),
    })
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
