#!/usr/bin/env python3
"""Generate the MLX Studio app icon at every size macOS needs.

Design: gradient indigo→purple squircle, centered graduation cap (mortarboard
diamond + trapezoid base + button + gold tassel), small sparkle accents in the
background. Ties to the app's "Teach" vocabulary.

Writes PNGs into ../MLXStudio/Resources/Assets.xcassets/AppIcon.appiconset/
plus a matching Contents.json.
"""

from __future__ import annotations

import json
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

OUTPUT_DIR = Path(__file__).resolve().parent.parent / "MLXStudio" / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"

# macOS AppIcon size manifest: (filename, point-size, scale)
MACOS_SIZES = [
    ("icon_16x16.png",       16,  1),
    ("icon_16x16@2x.png",    16,  2),
    ("icon_32x32.png",       32,  1),
    ("icon_32x32@2x.png",    32,  2),
    ("icon_128x128.png",     128, 1),
    ("icon_128x128@2x.png",  128, 2),
    ("icon_256x256.png",     256, 1),
    ("icon_256x256@2x.png",  256, 2),
    ("icon_512x512.png",     512, 1),
    ("icon_512x512@2x.png",  512, 2),
]


def lerp(a, b, t):
    return tuple(int(round(ax + (bx - ax) * t)) for ax, bx in zip(a, b))


def render_master(size: int = 1024) -> Image.Image:
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    # 1) Squircle gradient background.
    corner = int(size * 0.225)  # macOS Sequoia corner radius ratio
    gradient = Image.new("RGB", (size, size), (0, 0, 0))
    top = (38, 28, 95)        # deep indigo
    bot = (124, 58, 237)      # vibrant purple
    px = gradient.load()
    for y in range(size):
        c = lerp(top, bot, y / (size - 1))
        for x in range(size):
            px[x, y] = c

    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size, size), radius=corner, fill=255)
    img.paste(gradient, (0, 0), mask)

    # 2) Subtle top-left highlight inside the squircle for depth.
    highlight = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    hd = ImageDraw.Draw(highlight)
    hd.ellipse(
        (-size // 4, -size // 4, size // 1.4, size // 2.4),
        fill=(255, 255, 255, 50),
    )
    highlight = highlight.filter(ImageFilter.GaussianBlur(radius=size // 18))
    masked_highlight = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    masked_highlight.paste(highlight, (0, 0), mask)
    img = Image.alpha_composite(img, masked_highlight)

    # 3) Sparkles in the background — small soft white dots.
    sparkles = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    sd = ImageDraw.Draw(sparkles)
    for (cx_rel, cy_rel, r_rel, alpha) in [
        (0.18, 0.22, 0.018, 220),
        (0.82, 0.30, 0.012, 180),
        (0.16, 0.78, 0.014, 200),
        (0.85, 0.74, 0.020, 230),
        (0.27, 0.50, 0.008, 150),
    ]:
        cx, cy, r = int(cx_rel * size), int(cy_rel * size), int(r_rel * size)
        sd.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(255, 255, 255, alpha))
    # 4-point cross-shine on the two brightest sparkles
    for (cx_rel, cy_rel, w_rel) in [(0.18, 0.22, 0.06), (0.85, 0.74, 0.07)]:
        cx, cy = int(cx_rel * size), int(cy_rel * size)
        w = int(w_rel * size)
        thin = max(1, int(size * 0.003))
        sd.polygon(
            [(cx, cy - w), (cx + thin, cy), (cx, cy + w), (cx - thin, cy)],
            fill=(255, 255, 255, 180),
        )
        sd.polygon(
            [(cx - w, cy), (cx, cy + thin), (cx + w, cy), (cx, cy - thin)],
            fill=(255, 255, 255, 180),
        )
    sparkles = sparkles.filter(ImageFilter.GaussianBlur(radius=max(1, size // 600)))
    sparkles_masked = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    sparkles_masked.paste(sparkles, (0, 0), mask)
    img = Image.alpha_composite(img, sparkles_masked)

    # 4) Graduation cap (mortarboard).
    cap = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    cd = ImageDraw.Draw(cap)

    center_x = size // 2
    center_y = int(size * 0.55)
    board_half_w = int(size * 0.30)
    board_half_h = int(size * 0.075)

    # Soft shadow under the cap
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    sd2 = ImageDraw.Draw(shadow)
    sd2.ellipse(
        (
            center_x - board_half_w,
            center_y + board_half_h + 30,
            center_x + board_half_w,
            center_y + board_half_h + 80,
        ),
        fill=(0, 0, 0, 80),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(radius=size // 60))
    img = Image.alpha_composite(img, shadow)

    # Mortarboard (the flat square seen as a diamond from this angle)
    board_color = (250, 250, 248, 255)
    board_pts = [
        (center_x, center_y - board_half_h),                 # top
        (center_x + board_half_w, center_y),                 # right
        (center_x, center_y + board_half_h),                 # bottom
        (center_x - board_half_w, center_y),                 # left
    ]
    cd.polygon(board_pts, fill=board_color)

    # Cap base (trapezoid that sits below the board, the part hugging the head)
    base_top_half = int(board_half_w * 0.48)
    base_bottom_half = int(board_half_w * 0.36)
    base_height = int(size * 0.14)
    base_y_top = center_y + int(board_half_h * 0.55)
    base_y_bot = base_y_top + base_height
    base_pts = [
        (center_x - base_top_half, base_y_top),
        (center_x + base_top_half, base_y_top),
        (center_x + base_bottom_half, base_y_bot),
        (center_x - base_bottom_half, base_y_bot),
    ]
    base_color = (235, 230, 220, 255)
    cd.polygon(base_pts, fill=base_color)

    # Subtle band where the board meets the base (slight shadow)
    band = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    bd = ImageDraw.Draw(band)
    bd.polygon(
        [
            (center_x - base_top_half, base_y_top),
            (center_x + base_top_half, base_y_top),
            (center_x + base_top_half, base_y_top + int(size * 0.014)),
            (center_x - base_top_half, base_y_top + int(size * 0.014)),
        ],
        fill=(0, 0, 0, 60),
    )
    band = band.filter(ImageFilter.GaussianBlur(radius=2))

    # Button on top of the board
    btn_r = int(size * 0.022)
    cd.ellipse(
        (center_x - btn_r, center_y - board_half_h - btn_r, center_x + btn_r, center_y - board_half_h + btn_r),
        fill=(255, 255, 255, 255),
        outline=(0, 0, 0, 90),
        width=max(1, size // 256),
    )

    # Tassel: cord from button down to the right corner, then a fluffy bit.
    tassel_color = (255, 200, 40, 255)        # gold
    tassel_dark = (220, 150, 20, 255)
    cord_start = (center_x, center_y - board_half_h + int(size * 0.005))
    cord_end_x = center_x + board_half_w - int(size * 0.02)
    cord_end_y = center_y + int(size * 0.012)
    # Slight curve via two-segment line — looks more cord-like than a perfect diagonal.
    mid_x = (cord_start[0] + cord_end_x) // 2 + int(size * 0.03)
    mid_y = (cord_start[1] + cord_end_y) // 2 - int(size * 0.01)
    cord_w = max(2, size // 200)
    cd.line([cord_start, (mid_x, mid_y), (cord_end_x, cord_end_y)], fill=tassel_color, width=cord_w)
    # Tassel body — a small rounded rectangle hanging from the corner
    tlen = int(size * 0.13)
    twidth = int(size * 0.04)
    tx = cord_end_x - twidth // 2
    ty = cord_end_y
    cd.rounded_rectangle((tx, ty, tx + twidth, ty + tlen), radius=twidth // 2, fill=tassel_color)
    # Vertical strands on the tassel
    strand_count = 4
    for i in range(1, strand_count):
        sx = tx + i * (twidth // strand_count)
        cd.line([(sx, ty + 4), (sx, ty + tlen - 4)], fill=tassel_dark, width=1)
    # Small knot connecting cord → tassel body
    knot_r = int(twidth * 0.55)
    cd.ellipse(
        (cord_end_x - knot_r, cord_end_y - knot_r, cord_end_x + knot_r, cord_end_y + knot_r),
        fill=tassel_color, outline=tassel_dark, width=max(1, size // 400),
    )

    # Composite cap + band onto base image.
    img = Image.alpha_composite(img, cap)
    img = Image.alpha_composite(img, band)

    # 5) Final mask the whole thing to the squircle.
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(img, (0, 0), mask)
    return out


def write_contents_json(directory: Path) -> None:
    images = []
    for (filename, point_size, scale) in MACOS_SIZES:
        images.append({
            "filename": filename,
            "idiom": "mac",
            "scale": f"{scale}x",
            "size": f"{point_size}x{point_size}",
        })
    contents = {
        "images": images,
        "info": {"author": "xcode", "version": 1},
    }
    (directory / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")


def write_assets_root(directory: Path) -> None:
    (directory / "Contents.json").write_text(json.dumps({
        "info": {"author": "xcode", "version": 1},
    }, indent=2) + "\n")


def main() -> int:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    print(f"Rendering master @ 1024×1024 …")
    master = render_master(1024)

    for (filename, point_size, scale) in MACOS_SIZES:
        px = point_size * scale
        target = OUTPUT_DIR / filename
        scaled = master.resize((px, px), Image.LANCZOS)
        scaled.save(target, "PNG", optimize=True)
        print(f"  wrote {filename}  ({px}×{px}, {target.stat().st_size // 1024} KB)")

    write_contents_json(OUTPUT_DIR)
    write_assets_root(OUTPUT_DIR.parent)
    print(f"Done. Assets at {OUTPUT_DIR}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
