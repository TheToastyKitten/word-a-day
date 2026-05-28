#!/usr/bin/env python3
"""Render the AppIcon: 1024x1024 white square with bold black 'да!' centered.

Run from repo root:
    python3 scripts/make_appicon.py
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

OUT = Path("RussianWordADayApp/Resources/Assets.xcassets/AppIcon.appiconset/appicon_da_1024.png")
SIZE = 1024
TEXT = "да!"

# Prefer a bold sans-serif TrueType that ships with macOS and supports Cyrillic.
FONT_CANDIDATES = [
    "/System/Library/Fonts/Helvetica.ttc",
    "/System/Library/Fonts/HelveticaNeue.ttc",
    "/System/Library/Fonts/Avenir Next.ttc",
    "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
    "/System/Library/Fonts/Supplemental/Arial.ttf",
]


def load_font(target_px: int) -> ImageFont.FreeTypeFont:
    last_err: Exception | None = None
    for path in FONT_CANDIDATES:
        if not os.path.exists(path):
            continue
        # TTC files: try a few collection indices to find a bold cut.
        if path.endswith(".ttc"):
            for idx in (1, 2, 0, 3, 4):
                try:
                    return ImageFont.truetype(path, target_px, index=idx)
                except Exception as e:
                    last_err = e
                    continue
        else:
            try:
                return ImageFont.truetype(path, target_px)
            except Exception as e:
                last_err = e
                continue
    raise RuntimeError(f"No usable Cyrillic-capable font found: {last_err}")


def render() -> None:
    img = Image.new("RGB", (SIZE, SIZE), color="white")
    draw = ImageDraw.Draw(img)

    # Pick a font size that fits ~70% of the icon width with the text we need.
    font_size = 720
    while font_size > 50:
        font = load_font(font_size)
        bbox = draw.textbbox((0, 0), TEXT, font=font)
        w = bbox[2] - bbox[0]
        h = bbox[3] - bbox[1]
        if w <= SIZE * 0.78 and h <= SIZE * 0.78:
            break
        font_size -= 16

    bbox = draw.textbbox((0, 0), TEXT, font=font)
    w = bbox[2] - bbox[0]
    h = bbox[3] - bbox[1]
    x = (SIZE - w) / 2 - bbox[0]
    y = (SIZE - h) / 2 - bbox[1]

    draw.text((x, y), TEXT, fill="black", font=font)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    img.save(OUT, format="PNG")
    print(f"Wrote {OUT} ({font_size}px)")


if __name__ == "__main__":
    try:
        render()
    except Exception as e:
        print(f"Failed: {e}", file=sys.stderr)
        sys.exit(1)
