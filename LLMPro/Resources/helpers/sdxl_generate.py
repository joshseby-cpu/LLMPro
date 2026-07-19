"""sdxl_generate.py — local text-to-image for **SDXL / SD 1.5/2.x** checkpoints,
via a vendored copy of Apple's mlx-examples `stable_diffusion` package, running
fully offline on Apple Silicon. This is LLMPro's *second* image engine, alongside
mflux (which only does FLUX) — see generate_image.py for the FLUX path.

Invoked by LLMPro as either:
    python sdxl_generate.py --prompts-json <jsonl> --model <local-diffusers-dir> \
        --steps 28 --cfg 6.0 --negative "..." --width 1024 --height 1024
  where <jsonl> is one {"prompt": str, "output": abs_png_path, "seed": int} per line
  (batch mode — the model loads ONCE and is reused for every image);
or single-image:
    python sdxl_generate.py --prompt "..." --output out.png --seed 42 --model <dir>

--model is a LOCAL diffusers directory (the HF-cache snapshot dir), resolved by
Swift. The vendored loader (model_io.py, patched) reads weights straight from that
dir with no pre-conversion, and auto-detects SDXL (dual text encoders) vs SD.

Emits one JSON object per line on stdout (LLMPro parses line-by-line), matching
generate_image.py's contract so InferenceService/ImageGenService can share a parser:
    {"event": "start",    "count": N, "model": "<dir>"}
    {"event": "loading"}                        # before the model load
    {"event": "heartbeat"}                       # every ~8s while the model loads
    {"event": "progress", "index": i, "total": N, "stage": "generating",
        "step": s, "steps": S}                   # per denoise step (keeps stream alive)
    {"event": "progress", "index": i, "total": N, "stage": "saved", "path": "..."}
    {"event": "done",     "paths": ["/abs/...", ...]}
    {"event": "error",    "message": "...", "index": i}

Design notes:
- The vendored autoencoder always runs in fp32 (load_autoencoder(model, False)),
  which sidesteps the well-known SDXL fp16-VAE NaN → solid-black-image bug.
- UNet + text encoders load in fp16 (memory). On a 128 GB M-series this fits with
  huge headroom (~7 GB resident for SDXL), so we never quantize.
- Steps / CFG / negative are chosen by Swift per the checkpoint's variant (base vs
  Illustrious/Pony vs Turbo/Lightning) and passed in; this helper just executes.
- SDXL wants ~1 MP, dims aligned to /8 (latent); Swift snaps to SDXL buckets.
"""

from __future__ import annotations
import argparse
import json
import os
import sys
import threading

# The vendored `stable_diffusion` package sits next to this file under
# sdxl_vendor/ (installed by PythonRuntime.installHelpers). Put that dir on the
# path so `import stable_diffusion` resolves to the vendored, LLMPro-patched copy.
_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(_HERE, "sdxl_vendor"))


def emit(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()


def load_requests(args) -> list[dict]:
    if args.prompts_json:
        reqs = []
        with open(args.prompts_json, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                reqs.append(json.loads(line))
        return reqs
    if args.prompt and args.output:
        return [{"prompt": args.prompt, "output": args.output, "seed": args.seed}]
    raise SystemExit("sdxl_generate.py: need --prompts-json or --prompt + --output")


def _align8(v: int) -> int:
    # SDXL/SD need pixel dims divisible by 8 (VAE latent stride). Guard against a
    # caller passing an odd size — snap down to the nearest /8, floor 512.
    return max(512, (int(v) // 8) * 8)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--prompts-json")
    ap.add_argument("--prompt")
    ap.add_argument("--output")
    ap.add_argument("--seed", type=int, default=0)
    # A LOCAL diffusers directory (preferred) or an HF repo id the vendored loader
    # knows (stabilityai/sdxl-turbo, stabilityai/stable-diffusion-2-1-base).
    ap.add_argument("--model", required=True)
    ap.add_argument("--steps", type=int, default=28)
    ap.add_argument("--cfg", type=float, default=6.0)
    ap.add_argument("--negative", default="")
    ap.add_argument("--width", type=int, default=1024)
    ap.add_argument("--height", type=int, default=1024)
    ap.add_argument("--metadata", action="store_true")  # accepted for arg-parity; unused
    args = ap.parse_args()

    try:
        requests = load_requests(args)
    except Exception as e:  # noqa: BLE001
        emit({"event": "error", "message": f"bad request list: {e}"})
        return 1

    width, height = _align8(args.width), _align8(args.height)
    emit({"event": "start", "count": len(requests), "model": args.model})

    # Load the model once. Keep a heartbeat going so LLMPro's line-reader sees
    # activity during the (multi-GB) load and the UI doesn't look frozen.
    emit({"event": "loading"})
    stop_beat = threading.Event()

    def _beat() -> None:
        while not stop_beat.wait(8.0):
            emit({"event": "heartbeat"})

    beat = threading.Thread(target=_beat, daemon=True)
    beat.start()
    try:
        import mlx.core as mx
        import numpy as np
        from PIL import Image
        from stable_diffusion import StableDiffusion, StableDiffusionXL
        from stable_diffusion.model_io import is_sdxl

        sdxl = is_sdxl(args.model)
        # fp16 for unet + text encoders (memory); the VAE stays fp32 internally.
        sd = (StableDiffusionXL if sdxl else StableDiffusion)(args.model, float16=True)
        sd.ensure_models_are_loaded()
    except Exception as e:  # noqa: BLE001
        stop_beat.set()
        emit({"event": "error", "message": f"couldn't load the image model: {e}"})
        return 1
    finally:
        stop_beat.set()

    latent_size = (height // 8, width // 8)
    total = len(requests)
    paths: list[str] = []
    for i, req in enumerate(requests):
        out = req["output"]
        try:
            os.makedirs(os.path.dirname(out), exist_ok=True)
            emit({"event": "progress", "index": i, "total": total,
                  "stage": "generating", "step": 0, "steps": args.steps})

            latents = sd.generate_latents(
                str(req["prompt"]),
                n_images=1,
                cfg_weight=float(args.cfg),
                num_steps=int(args.steps),
                negative_text=str(args.negative),
                latent_size=latent_size,
                seed=int(req.get("seed", 0)),
            )
            x_t = None
            for step, x_t in enumerate(latents):
                mx.eval(x_t)
                # Per-step progress keeps the stream alive during a slow (20-60s)
                # SDXL denoise without flipping the UI back to the "loading" state.
                emit({"event": "progress", "index": i, "total": total,
                      "stage": "generating", "step": step + 1, "steps": args.steps})

            # Decode the final latent to an image (VAE is fp32 → no black-image bug).
            decoded = sd.decode(x_t)
            mx.eval(decoded)
            img = (np.array(decoded[0]) * 255).astype(np.uint8)
            Image.fromarray(img).save(out)
            paths.append(out)
            emit({"event": "progress", "index": i, "total": total, "stage": "saved", "path": out})
        except Exception as e:  # noqa: BLE001
            emit({"event": "error", "message": str(e), "index": i})
            # Keep going with the rest of the batch rather than aborting.

    emit({"event": "done", "paths": paths})
    return 0 if paths else 1


if __name__ == "__main__":
    sys.exit(main())
