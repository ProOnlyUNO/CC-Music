#!/usr/bin/env python3
"""Convert PNG/JPG (and similar) images to ComputerCraft paintutils .nfp.

.nfp is a text grid of hex nibbles 0-f, one character per pixel, matching the
16 CC palette colours. Transparent / near-black can be written as space.
"""

from __future__ import annotations

import re
import shutil
import subprocess
from pathlib import Path
from typing import Callable, Iterable, Sequence

LogFn = Callable[[str], None]

# Official CC:Tweaked default palette (approximate sRGB).
CC_PALETTE: list[tuple[int, int, int]] = [
    (0xF0, 0xF0, 0xF0),  # 0 white
    (0xF2, 0xB2, 0x33),  # 1 orange
    (0xE5, 0x7F, 0xD8),  # 2 magenta
    (0x99, 0xB2, 0xF2),  # 3 lightBlue
    (0xDE, 0xDE, 0x6C),  # 4 yellow
    (0x7F, 0xCC, 0x19),  # 5 lime
    (0xF2, 0xB2, 0xCC),  # 6 pink
    (0x4C, 0x4C, 0x4C),  # 7 gray
    (0x99, 0x99, 0x99),  # 8 lightGray
    (0x4C, 0x99, 0xB2),  # 9 cyan
    (0xB2, 0x66, 0xE5),  # a purple
    (0x33, 0x66, 0xCC),  # b blue
    (0x7F, 0x66, 0x4C),  # c brown
    (0x57, 0xA6, 0x4E),  # d green
    (0xCC, 0x4C, 0x4C),  # e red
    (0x11, 0x11, 0x11),  # f black
]

NFP_CHARS = "0123456789abcdef"
IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".webp", ".bmp", ".gif"}
# Default cover resolution for jukebox thumbs. Aurora UI resamples into
# slot sizes (Art.buildCells), so native .nfp size is not 1:1 on screen.
# Keep in sync with jukebox.lua decodeNfp NFP_MAX (raise both together for 256).
DEFAULT_NFP_SIZE = 128
COVER_NAMES = {
    "cover",
    "folder",
    "album",
    "front",
    "artwork",
    "art",
    "thumb",
    "thumbnail",
}


def _dist2(a: tuple[int, int, int], b: tuple[int, int, int]) -> int:
    return (a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2 + (a[2] - b[2]) ** 2


def nearest_cc(rgb: tuple[int, int, int], *, allow_transparent: bool = False) -> str:
    """Map an RGB triple to an .nfp nibble (or space if near-black + transparent)."""
    if allow_transparent and rgb[0] < 12 and rgb[1] < 12 and rgb[2] < 12:
        return " "
    best_i, best_d = 15, 1 << 30
    for i, pal in enumerate(CC_PALETTE):
        d = _dist2(rgb, pal)
        if d < best_d:
            best_i, best_d = i, d
    return NFP_CHARS[best_i]


def image_to_nfp_lines(
    path: Path | str,
    *,
    size: int = DEFAULT_NFP_SIZE,
    allow_transparent: bool = False,
) -> list[str]:
    """Resize + quantize an image file to .nfp row strings."""
    from PIL import Image

    img = Image.open(path).convert("RGBA")
    # Flatten onto dark bg so translucent covers stay readable on CC monitors.
    bg = Image.new("RGBA", img.size, (17, 17, 17, 255))
    flat = Image.alpha_composite(bg, img).convert("RGB")
    flat = flat.resize((max(1, size), max(1, size)), Image.Resampling.LANCZOS)

    rows: list[str] = []
    px = flat.load()
    w, h = flat.size
    for y in range(h):
        chars: list[str] = []
        for x in range(w):
            r, g, b = px[x, y]
            chars.append(nearest_cc((r, g, b), allow_transparent=allow_transparent))
        rows.append("".join(chars))
    return rows


def write_nfp(
    src: Path | str,
    dst: Path | str,
    *,
    size: int = DEFAULT_NFP_SIZE,
    allow_transparent: bool = False,
) -> Path:
    src_p, dst_p = Path(src), Path(dst)
    lines = image_to_nfp_lines(src_p, size=size, allow_transparent=allow_transparent)
    dst_p.parent.mkdir(parents=True, exist_ok=True)
    tmp = dst_p.with_suffix(dst_p.suffix + ".part")
    tmp.write_text("\n".join(lines) + "\n", encoding="ascii", newline="\n")
    tmp.replace(dst_p)
    return dst_p


def find_cover_image(src_audio: Path, *, also_album_dir: bool = True) -> Path | None:
    """Locate a cover image next to an audio file or in its album folder."""
    src_audio = Path(src_audio)
    stem = src_audio.stem
    parent = src_audio.parent

    # Same-stem sidecar: Song.png / Song.jpg
    for ext in (".png", ".jpg", ".jpeg", ".webp"):
        cand = parent / f"{stem}{ext}"
        if cand.is_file():
            return cand

    if not also_album_dir:
        return None

    for name in COVER_NAMES:
        for ext in (".png", ".jpg", ".jpeg", ".webp"):
            cand = parent / f"{name}{ext}"
            if cand.is_file():
                return cand
    return None


def extract_embedded_cover(
    ffmpeg: str | None,
    audio: Path,
    out_image: Path,
) -> Path | None:
    """Try to pull the first embedded cover art stream via ffmpeg."""
    exe = ffmpeg or shutil.which("ffmpeg")
    if not exe:
        return None
    audio = Path(audio)
    out_image = Path(out_image)
    out_image.parent.mkdir(parents=True, exist_ok=True)
    tmp = out_image.with_suffix(".png.part")
    if tmp.exists():
        tmp.unlink()
    cmd = [
        exe,
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-i",
        str(audio),
        "-an",
        "-vcodec",
        "png",
        "-frames:v",
        "1",
        str(tmp),
    ]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0 or not tmp.exists() or tmp.stat().st_size == 0:
        if tmp.exists():
            tmp.unlink(missing_ok=True)
        return None
    final = out_image if out_image.suffix.lower() == ".png" else out_image.with_suffix(".png")
    tmp.replace(final)
    return final


def convert_art_for_track(
    src_audio: Path,
    dst_dfpwm: Path,
    *,
    size: int = DEFAULT_NFP_SIZE,
    overwrite: bool = False,
    ffmpeg: str | None = None,
    log: LogFn | None = None,
) -> Path | None:
    """Write ``Song.nfp`` beside the converted .dfpwm (and album ``cover.nfp``)."""
    dst_dfpwm = Path(dst_dfpwm)
    song_nfp = dst_dfpwm.with_suffix(".nfp")
    album_nfp = dst_dfpwm.parent / "cover.nfp"

    if song_nfp.exists() and not overwrite:
        if not album_nfp.exists():
            try:
                album_nfp.write_bytes(song_nfp.read_bytes())
            except OSError:
                pass
        return song_nfp

    img = find_cover_image(src_audio)
    temp_embed: Path | None = None
    if img is None:
        temp_embed = dst_dfpwm.parent / f".{dst_dfpwm.stem}.cover.png"
        img = extract_embedded_cover(ffmpeg, src_audio, temp_embed)

    if img is None or not Path(img).is_file():
        if temp_embed and temp_embed.exists():
            temp_embed.unlink(missing_ok=True)
        return None

    try:
        write_nfp(img, song_nfp, size=size)
        if not album_nfp.exists() or overwrite:
            write_nfp(img, album_nfp, size=size)
        if log:
            log(f"  art  {song_nfp.name}")
        return song_nfp
    except Exception as e:  # noqa: BLE001 — surface as warn in caller log
        if log:
            log(f"  warn: art convert failed: {e}")
        return None
    finally:
        if temp_embed and temp_embed.exists():
            temp_embed.unlink(missing_ok=True)


def convert_image_file(
    src: Path | str,
    dst: Path | str | None = None,
    *,
    size: int = DEFAULT_NFP_SIZE,
) -> Path:
    src_p = Path(src)
    dst_p = Path(dst) if dst else src_p.with_suffix(".nfp")
    return write_nfp(src_p, dst_p, size=size)


def batch_convert_images(
    paths: Iterable[Path | str],
    *,
    size: int = DEFAULT_NFP_SIZE,
    log: LogFn | None = None,
) -> list[Path]:
    out: list[Path] = []
    for p in paths:
        p = Path(p)
        if p.is_dir():
            files = sorted(
                f for f in p.rglob("*") if f.suffix.lower() in IMAGE_EXTS
            )
        elif p.is_file() and p.suffix.lower() in IMAGE_EXTS:
            files = [p]
        else:
            continue
        for img in files:
            try:
                nfp = convert_image_file(img, size=size)
                out.append(nfp)
                if log:
                    log(f"  nfp {nfp}")
            except Exception as e:  # noqa: BLE001
                if log:
                    log(f"  warn: {img.name}: {e}")
    return out


def is_image_name(name: str) -> bool:
    return Path(name).suffix.lower() in IMAGE_EXTS
