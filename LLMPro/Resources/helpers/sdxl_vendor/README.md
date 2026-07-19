# sdxl_vendor — vendored MLX Stable Diffusion (SD / SDXL)

This is the `stable_diffusion` package from Apple's **ml-explore/mlx-examples**
(MIT-licensed), vendored so LLMPro can run **SDXL** (and SD 1.5/2.x) text-to-image
locally via MLX — the second image engine alongside mflux (FLUX).

Source: https://github.com/ml-explore/mlx-examples/tree/main/stable_diffusion
Vendored at commit 796f5b5 (2026-04-06). Consumed by `sdxl_generate.py`.

**Local LLMPro patches** (search for `LLMPro:` in the files):
- `model_io.py` — resolve weights from a LOCAL diffusers directory (not just a
  hardcoded HF repo id), with a filename-variant fallback; synthesize the SD/SDXL
  file map for any local dir (SDXL iff it has `text_encoder_2/`).
- `stable_diffusion/__init__.py` — SDXL `generate_latents` derives the SDXL
  `add_time_ids` micro-conditioning from the real `latent_size` (the upstream
  hardcodes 512×512, which degrades 1024² composition).
