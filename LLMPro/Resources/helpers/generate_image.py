"""generate_image.py — local text-to-image for Story illustrations, via mflux
(MLX FLUX) running fully offline on Apple Silicon.

Invoked by LLMPro as either:
    python generate_image.py --prompts-json <jsonl> --model schnell --quantize 8 \
        --steps 4 --width 1024 --height 768
  where <jsonl> is one {"prompt": str, "output": abs_png_path, "seed": int} per line
  (batch mode — the ~12B model loads ONCE and is reused for every image in a chapter);
or single-image:
    python generate_image.py --prompt "..." --output out.png --seed 42 [--model ...]

Emits one JSON object per line on stdout (LLMPro parses line-by-line):
    {"event": "start",    "count": N, "model": "schnell"}
    {"event": "loading"}                       # before the (first-run: downloading) model load
    {"event": "heartbeat"}                      # every ~8s while the model loads
    {"event": "progress", "index": i, "total": N, "stage": "generating"|"saved", "path": "..."}
    {"event": "done",     "paths": ["/abs/...", ...]}
    {"event": "error",    "message": "...", "index": i}

Design notes:
- FLUX.1-schnell (Apache-2.0, ungated) is timestep-distilled → 2-4 steps, fast.
- It is guidance-distilled (CFG≈1): classic negative prompts are NOT honored, so
  the caller bakes any exclusions into the positive prompt. --quantize 8 keeps
  memory modest (~12.6 GB) so it can coexist with a resident LLM.
- First run downloads the model (the default ungated mflux mirror is ~10 GB) into
  HF_HOME; a background heartbeat keeps the stream alive so the UI doesn't look hung.
"""

from __future__ import annotations
import argparse
import json
import os
import sys
import threading


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
    raise SystemExit("generate_image.py: need --prompts-json or --prompt + --output")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--prompts-json")
    ap.add_argument("--prompt")
    ap.add_argument("--output")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--model", default="schnell")
    # Architecture hint used when --model is a custom HF repo (a mirror). FLUX.1
    # variants: "schnell" (default), "dev".
    ap.add_argument("--base-model", dest="base_model", default="schnell")
    ap.add_argument("--quantize", type=int, default=8)
    ap.add_argument("--steps", type=int, default=4)
    ap.add_argument("--width", type=int, default=1024)
    ap.add_argument("--height", type=int, default=768)
    ap.add_argument("--metadata", action="store_true")
    args = ap.parse_args()

    try:
        requests = load_requests(args)
    except Exception as e:  # noqa: BLE001
        emit({"event": "error", "message": f"bad request list: {e}"})
        return 1

    emit({"event": "start", "count": len(requests), "model": args.model})

    # Load the model once. First run downloads it (large) — keep a heartbeat going
    # so LLMPro's line-reader sees activity and the UI doesn't look frozen.
    emit({"event": "loading"})
    stop_beat = threading.Event()

    def _beat() -> None:
        while not stop_beat.wait(8.0):
            emit({"event": "heartbeat"})

    beat = threading.Thread(target=_beat, daemon=True)
    beat.start()
    try:
        # Full module paths: mflux 0.18.0 does NOT re-export these from the package
        # root, and generate_image() takes steps/width/height directly (no Config
        # object). Verified against the mflux 0.18.0 sdist.
        from mflux.models.common.config import ModelConfig
        from mflux.models.flux.variants.txt2img.flux import Flux1
        # A model name with "/" is an HF repo — typically a pre-quantized mflux
        # mirror (the default is the ungated dhairyashil/FLUX.1-schnell-mflux-4bit,
        # since black-forest-labs/FLUX.1-schnell is gated). Load via from_name with
        # the architecture hint and DON'T re-quantize: its quantization is baked in,
        # so pass quantize=None and let mflux use the stored level.
        if "/" in args.model:
            model_config = ModelConfig.from_name(model_name=args.model, base_model=args.base_model)
            quantize = None
        elif args.model == "dev":
            model_config = ModelConfig.dev()
            quantize = args.quantize
        else:
            model_config = ModelConfig.schnell()
            quantize = args.quantize
        flux = Flux1(model_config=model_config, quantize=quantize)
    except Exception as e:  # noqa: BLE001
        stop_beat.set()
        emit({"event": "error", "message": f"couldn't load the image model: {e}"})
        return 1
    finally:
        stop_beat.set()

    paths: list[str] = []
    total = len(requests)
    for i, req in enumerate(requests):
        out = req["output"]
        try:
            os.makedirs(os.path.dirname(out), exist_ok=True)
            emit({"event": "progress", "index": i, "total": total, "stage": "generating"})
            image = flux.generate_image(
                seed=int(req.get("seed", 0)),
                prompt=str(req["prompt"]),
                num_inference_steps=args.steps,
                width=args.width,
                height=args.height,
            )
            # 0.18.0's GeneratedImage.save: `export_json_metadata` (not
            # `export_metadata`); overwrite=True since we own unique filenames.
            image.save(path=out, export_json_metadata=bool(args.metadata), overwrite=True)
            paths.append(out)
            emit({"event": "progress", "index": i, "total": total, "stage": "saved", "path": out})
        except Exception as e:  # noqa: BLE001
            emit({"event": "error", "message": str(e), "index": i})
            # Keep going with the rest of the batch rather than aborting the chapter.

    emit({"event": "done", "paths": paths})
    return 0 if paths else 1


if __name__ == "__main__":
    sys.exit(main())
