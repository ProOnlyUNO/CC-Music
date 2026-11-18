#!/usr/bin/env python3
"""Build multi-size app-icon.ico from assets/app-icon.png."""
from __future__ import annotations

from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent
SRC = ROOT / "assets" / "app-icon.png"
ICO = ROOT / "assets" / "app-icon.ico"
SIZES = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]


def main() -> None:
    im = Image.open(SRC).convert("RGBA")
    pixels = im.load()
    w, h = im.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = pixels[x, y]
            if a == 0:
                continue
            # Knock out near-black canvas so the circular badge is clean on taskbar
            if r <= 18 and g <= 18 and b <= 18:
                pixels[x, y] = (0, 0, 0, 0)

    im.save(SRC, format="PNG", optimize=True)
    im.save(ICO, format="ICO", sizes=SIZES)
    print(f"wrote {ICO} ({ICO.stat().st_size} bytes)")
    print(f"png  {SRC} ({SRC.stat().st_size} bytes) mode={Image.open(SRC).mode}")
    ico_im = Image.open(ICO)
    if hasattr(ico_im, "ico") and ico_im.ico is not None:
        print("ico sizes:", sorted(ico_im.ico.sizes()))


if __name__ == "__main__":
    main()
