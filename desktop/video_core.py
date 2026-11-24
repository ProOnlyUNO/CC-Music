#!/usr/bin/env python3
"""Offline MP4/etc → CVID1 frame pack + DFPWM audio for CC:Tweaked monitors.

Pack layout (Importer-friendly, beside the song):
    Artist/Album/Song.dfpwm
    Artist/Album/Song.cvid

CVID1 matches jukebox.lua Video (Aurora):
    magic "CVID1", u8 ver=1, u16 w, u16 h (cells),
    u32 frameCount, u16 defaultDurationMs, 16×RGB palette,
    frames (2 bytes/cell: mask0..31 + fg/bg nibbles), duration table (u16 each).

Sextant cells: 2×3 sub-pixels; bottom-right is always bg (5-bit mask), same as
CanvasProto:quantizeCell. Audio stays on the existing DFPWM / jukebox path so
the music-video handoff can keep sound continuous.
"""

from __future__ import annotations

import os
import shutil
import struct
import subprocess
import tempfile
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Callable

from convert_core import AUDIO_EXTS, check_ffmpeg, convert_one
from nfp_core import CC_PALETTE, nearest_cc

LogFn = Callable[[str], None]
ProgressFn = Callable[[str, float | None, str], None]

VIDEO_EXTS = {".mp4", ".mkv", ".webm", ".mov", ".avi", ".m4v", ".mpeg", ".mpg"}

# Sensible defaults for a 9×3 advanced monitor @ scale 0.5 (~261×57 cells).
# Encode smaller than the wall so blit stays light; jukebox scales to fill.
DEFAULT_CELLS_W = 64
DEFAULT_CELLS_H = 18
DEFAULT_FPS = 8
DEFAULT_MAX_SECONDS = 0  # 0 = full clip


def _log(log: LogFn | None, msg: str) -> None:
    if log:
        log(msg)


def collect_videos(paths) -> list[Path]:
    files: list[Path] = []
    for p in paths:
        p = Path(p)
        if p.is_dir():
            files += sorted(
                f for f in p.rglob("*") if f.suffix.lower() in VIDEO_EXTS
            )
        elif p.is_file() and p.suffix.lower() in VIDEO_EXTS:
            files.append(p)
    return files


def _probe_duration(ffprobe: str, src: Path) -> float:
    try:
        r = subprocess.run(
            [
                ffprobe,
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "default=noprint_wrappers=1:nokey=1",
                str(src),
            ],
            capture_output=True,
            text=True,
        )
        return max(0.0, float((r.stdout or "0").strip() or 0))
    except (OSError, ValueError):
        return 0.0


def _nearest_palette_index(rgb: tuple[int, int, int], palette: list[tuple[int, int, int]]) -> int:
    best_i, best_d = 0, 1 << 30
    for i, pal in enumerate(palette):
        d = (rgb[0] - pal[0]) ** 2 + (rgb[1] - pal[1]) ** 2 + (rgb[2] - pal[2]) ** 2
        if d < best_d:
            best_i, best_d = i, d
    return best_i


def _quantize_cell(
    pixels: list[tuple[int, int, int]],
    palette: list[tuple[int, int, int]],
) -> tuple[int, int, int]:
    """Return (mask0..31, fg, bg) for six RGB samples in row-major 2×3 order.

    Bottom-right (index 5) is forced to bg — matches jukebox CanvasProto:quantizeCell
    and CVID's 5-bit mask (chars 0x80-0x9F).
    """
    idxs = [_nearest_palette_index(p, palette) for p in pixels]
    bg = idxs[5]
    counts: dict[int, int] = {}
    for i in idxs[:5]:
        if i != bg:
            counts[i] = counts.get(i, 0) + 1
    if not counts:
        return 0, bg, bg
    fg = max(counts.items(), key=lambda kv: kv[1])[0]
    mask = 0
    for k in range(5):
        c = idxs[k]
        if c == bg:
            continue
        if c == fg:
            mask |= 1 << k
            continue
        # Third colour → nearer of fg/bg in palette RGB.
        pr, pg, pb = pixels[k]
        fr, fgg, fb = palette[fg]
        br, bgg, bb = palette[bg]
        df = abs(pr - fr) + abs(pg - fgg) + abs(pb - fb)
        db = abs(pr - br) + abs(pg - bgg) + abs(pb - bb)
        if df < db:
            mask |= 1 << k
    if mask == 0:
        return 0, bg, bg
    return mask, fg, bg


def _encode_frame_bytes(
    img,  # PIL.Image RGB sized (cells_w*2, cells_h*3)
    cells_w: int,
    cells_h: int,
    palette: list[tuple[int, int, int]],
) -> bytes:
    px = img.load()
    out = bytearray(cells_w * cells_h * 2)
    o = 0
    for cy in range(cells_h):
        for cx in range(cells_w):
            samples: list[tuple[int, int, int]] = []
            for sy in range(3):
                for sx in range(2):
                    samples.append(px[cx * 2 + sx, cy * 3 + sy])
            mask, fg, bg = _quantize_cell(samples, palette)
            out[o] = mask & 31
            out[o + 1] = ((fg & 15) << 4) | (bg & 15)
            o += 2
    return bytes(out)


def _build_cvid(
    frame_paths: list[Path],
    cells_w: int,
    cells_h: int,
    duration_ms: int,
    palette: list[tuple[int, int, int]],
) -> bytes:
    from PIL import Image

    n = len(frame_paths)
    header = bytearray(64)
    header[0:5] = b"CVID1"
    header[5] = 1
    struct.pack_into("<H", header, 6, cells_w)
    struct.pack_into("<H", header, 8, cells_h)
    struct.pack_into("<I", header, 10, n)
    struct.pack_into("<H", header, 14, duration_ms)
    for i, (r, g, b) in enumerate(palette[:16]):
        o = 16 + i * 3
        header[o] = r & 255
        header[o + 1] = g & 255
        header[o + 2] = b & 255

    parts = [bytes(header)]
    target = (cells_w * 2, cells_h * 3)
    for fp in frame_paths:
        img = Image.open(fp).convert("RGB")
        if img.size != target:
            img = img.resize(target, Image.Resampling.BOX)
        parts.append(_encode_frame_bytes(img, cells_w, cells_h, palette))
    # Duration table: little-endian u16 per frame
    dur = struct.pack("<" + ("H" * n), *([duration_ms] * n))
    parts.append(dur)
    return b"".join(parts)


def convert_video_one(
    exe: str,
    src: Path,
    out_dir: Path,
    *,
    stem: str | None = None,
    cells_w: int = DEFAULT_CELLS_W,
    cells_h: int = DEFAULT_CELLS_H,
    fps: float = DEFAULT_FPS,
    max_seconds: float = DEFAULT_MAX_SECONDS,
    overwrite: bool = False,
    skip_audio: bool = False,
    log: LogFn | None = None,
) -> dict:
    """Convert one video → Song.dfpwm + Song.cvid under out_dir.

    Returns dict with keys: ok, dfpwm, cvid, frames, note.
    """
    from PIL import Image

    src = Path(src)
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    name = stem or src.stem
    # Keep filenames Importer-safe (no path separators).
    name = "".join(ch if ch not in '\\/:*?"<>|' else "-" for ch in name).strip(" .") or "video"
    dfpwm = out_dir / f"{name}.dfpwm"
    cvid = out_dir / f"{name}.cvid"

    if cvid.exists() and not overwrite:
        return {"ok": False, "dfpwm": dfpwm, "cvid": cvid, "frames": 0, "note": "exists"}

    ffprobe = shutil.which("ffprobe") or exe.replace("ffmpeg", "ffprobe")
    duration = _probe_duration(ffprobe, src) if ffprobe else 0.0
    if max_seconds and max_seconds > 0:
        duration = min(duration, max_seconds) if duration else max_seconds

    # --- audio (same pipeline as convert_core) ---
    if not skip_audio:
        if dfpwm.exists() and not overwrite:
            _log(log, f"  audio exists, kept: {dfpwm.name}")
        else:
            ok, info = convert_one(exe, src, dfpwm)
            if not ok:
                return {
                    "ok": False,
                    "dfpwm": dfpwm,
                    "cvid": cvid,
                    "frames": 0,
                    "note": f"audio: {info}",
                }
            _log(log, f"  audio {dfpwm.name} ({info / 1048576:.2f} MB)")

    # --- frames via ffmpeg ---
    duration_ms = max(1, int(round(1000.0 / max(0.5, fps))))
    px_w, px_h = cells_w * 2, cells_h * 3
    with tempfile.TemporaryDirectory(prefix="ccvid_") as tmp:
        tmp_path = Path(tmp)
        pattern = tmp_path / "f_%06d.png"
        vf = f"fps={fps},scale={px_w}:{px_h}:force_original_aspect_ratio=decrease,pad={px_w}:{px_h}:(ow-iw)/2:(oh-ih)/2"
        cmd = [
            exe,
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(src),
        ]
        if max_seconds and max_seconds > 0:
            cmd += ["-t", str(max_seconds)]
        cmd += ["-vf", vf, "-start_number", "1", str(pattern)]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            err = (r.stderr.strip().splitlines() or ["ffmpeg frame extract failed"])[-1]
            return {"ok": False, "dfpwm": dfpwm, "cvid": cvid, "frames": 0, "note": err}

        frames = sorted(tmp_path.glob("f_*.png"))
        if not frames:
            return {
                "ok": False,
                "dfpwm": dfpwm,
                "cvid": cvid,
                "frames": 0,
                "note": "no frames extracted",
            }

        # Fixed official CC palette — remaps cleanly via Video.rgbSlot on Theme.
        palette = list(CC_PALETTE)
        blob = _build_cvid(frames, cells_w, cells_h, duration_ms, palette)
        tmp_out = cvid.with_suffix(cvid.suffix + ".part")
        tmp_out.write_bytes(blob)
        os.replace(tmp_out, cvid)
        _log(
            log,
            f"  cvid {cvid.name}  {cells_w}x{cells_h} cells @ {fps:g} fps  "
            f"({len(frames)} frames, {len(blob) / 1048576:.2f} MB)",
        )
        return {
            "ok": True,
            "dfpwm": dfpwm,
            "cvid": cvid,
            "frames": len(frames),
            "bytes": len(blob),
            "note": "",
        }


def run_video_convert(
    inputs: list,
    out_dir: str | Path,
    *,
    cells_w: int = DEFAULT_CELLS_W,
    cells_h: int = DEFAULT_CELLS_H,
    fps: float = DEFAULT_FPS,
    max_seconds: float = DEFAULT_MAX_SECONDS,
    overwrite: bool = False,
    skip_audio: bool = False,
    dry_run: bool = False,
    log: LogFn | None = None,
    progress: ProgressFn | None = None,
    should_cancel: Callable[[], bool] | None = None,
) -> dict:
    """Batch-convert videos. Returns summary dict."""

    def _prog(frac: float | None, detail: str) -> None:
        if progress:
            progress("video", frac, detail)

    files = collect_videos(inputs)
    if not files:
        raise RuntimeError("No video files found (mp4/mkv/webm/mov/…).")

    out_root = Path(out_dir)
    _log(log, f"{len(files)} video(s) → {out_root}")
    _log(
        log,
        f"Defaults: {cells_w}×{cells_h} cells @ {fps:g} fps "
        f"(sextant {cells_w * 2}×{cells_h * 3} px)",
    )
    for f in files:
        _log(log, f"  {f.name}")

    if dry_run:
        _log(log, "Dry run — nothing converted.")
        return {"done": 0, "skipped": len(files), "failed": 0, "out": str(out_root.resolve())}

    exe = check_ffmpeg()
    done = failed = skipped = 0
    total = max(1, len(files))
    _prog(0.0, f"Video 0/{len(files)}…")

    for i, src in enumerate(files):
        if should_cancel and should_cancel():
            _log(log, "Cancelled.")
            break
        # Flat dump by default; caller may pass Artist/Album as out_dir.
        result = convert_video_one(
            exe,
            src,
            out_root,
            cells_w=cells_w,
            cells_h=cells_h,
            fps=fps,
            max_seconds=max_seconds,
            overwrite=overwrite,
            skip_audio=skip_audio,
            log=log,
        )
        if result.get("note") == "exists":
            skipped += 1
            _log(log, f"  exists, skipped: {result['cvid'].name}")
        elif result.get("ok"):
            done += 1
            _log(log, f"  ok  {result['cvid'].name}")
        else:
            failed += 1
            _log(log, f"  FAILED  {src.name}: {result.get('note')}")
        _prog((i + 1) / total, f"Video {i + 1}/{len(files)} — {src.name}")

    _prog(1.0, f"Video done {done}, skipped {skipped}, failed {failed}")
    _log(
        log,
        f"Video converted {done}, skipped {skipped}, failed {failed}. "
        f"Output: {out_root.resolve()}",
    )
    if done:
        _log(
            log,
            "Next: put Song.dfpwm + Song.cvid beside each other under "
            "music/Artist/Album/, then drag-drop via Importer (or copy onto the disk).",
        )
    return {
        "done": done,
        "skipped": skipped,
        "failed": failed,
        "out": str(out_root.resolve()),
    }
