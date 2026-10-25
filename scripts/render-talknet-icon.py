#!/usr/bin/env python3
"""Render design/talknet-icon.svg into the iOS icon set, the login image, and the PWA icon.

Requires cairosvg (CairoSVG) and Pillow. From the repo root:

    python3 scripts/render-talknet-icon.py
"""

import io
from pathlib import Path

import cairosvg
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SVG = ROOT / "design" / "talknet-icon.svg"
APPICON = ROOT / "ios" / "Walkie" / "Assets.xcassets" / "AppIcon.appiconset"
LOGO = ROOT / "ios" / "Walkie" / "Assets.xcassets" / "TalkNetLogo.imageset"
BACKGROUND = (5, 8, 20)

SIZES = {
    "Icon-20.png": 20,
    "Icon-29.png": 29,
    "Icon-40.png": 40,
    "Icon-58.png": 58,
    "Icon-60.png": 60,
    "Icon-76.png": 76,
    "Icon-80.png": 80,
    "Icon-87.png": 87,
    "Icon-120.png": 120,
    "Icon-152.png": 152,
    "Icon-167.png": 167,
    "Icon-180.png": 180,
    "AppIcon.png": 1024,
}


def render(size: int) -> Image.Image:
    raw = cairosvg.svg2png(url=str(SVG), output_width=size, output_height=size)
    image = Image.open(io.BytesIO(raw)).convert("RGBA")
    plate = Image.new("RGB", (size, size), BACKGROUND)
    plate.paste(image, mask=image.getchannel("A"))
    return plate


def write(path: Path, size: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    render(size).save(path, format="PNG")


def main() -> None:
    if not SVG.is_file():
        raise SystemExit(f"missing {SVG}")
    for name, size in SIZES.items():
        write(APPICON / name, size)
    write(LOGO / "TalkNetLogo.png", 1024)
    write(ROOT / "public" / "icon.png", 512)
    print(f"rendered {len(SIZES)} app icons, login logo, and public/icon.png")


if __name__ == "__main__":
    main()
