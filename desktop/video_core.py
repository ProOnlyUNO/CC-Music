#!/usr/bin/env python3
"""Offline MP4/etc → CVID1 frame pack + DFPWM audio for CC:Tweaked monitors.

Pack layout (Importer-friendly, beside the song):
    Artist/Album/Song.dfpwm
    Artist/Album/Song.cvid              (single file when ≤ ~15 MiB)
    Artist/Album/Song.cvid.1/.2/.3      (multipart when high-res exceeds budget)

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
import re
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

# Target wall: 9×3 advanced monitors @ scale 0.5 (~270×60 cells; INSTALL.md).
# Default encode: 256×72 @ 8 fps — near-wall. Packs that exceed the ~15 MiB
# per-file budget are auto-split into Song.cvid.1/.2/.3 (each a full CVID1 slice).
# Single-file fallback: 160×45 stays under ~15 MiB for ~2.5–3 min tracks.
DEFAULT_CELLS_W = 256
DEFAULT_CELLS_H = 72
SINGLE_FILE_CELLS_W = 160
SINGLE_FILE_CELLS_H = 45
DEFAULT_FPS = 8
DEFAULT_MAX_SECONDS = 0  # 0 = full clip
# Per-file budget (headroom under CC ~20 MiB disk). 0 disables multipart split.
MAX_PART_BYTES = 15 * 1024 * 1024
# Documented wall size (for CLI/UI hints).
TARGET_MONITOR_CELLS_W = 270
TARGET_MONITOR_CELLS_H = 60


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


def max_frames_per_part(
    cells_w: int,
    cells_h: int,
    max_part_bytes: int = MAX_PART_BYTES,
) -> int:
    """How many frames fit in one CVID1 file under max_part_bytes."""
    if max_part_bytes <= 0:
        return 10**9
    cell_bytes = cells_w * cells_h * 2
    per = cell_bytes + 2  # frame pixels + duration u16
    if per <= 0:
        return 1
    return max(1, (max_part_bytes - 64) // per)


def _assemble_cvid(
    frame_blobs: list[bytes],
    cells_w: int,
    cells_h: int,
    duration_ms: int,
    palette: list[tuple[int, int, int]],
) -> bytes:
    n = len(frame_blobs)
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
    dur = struct.pack("<" + ("H" * n), *([duration_ms] * n))
    return b"".join([bytes(header), *frame_blobs, dur])


def _build_cvid(
    frame_paths: list[Path],
    cells_w: int,
    cells_h: int,
    duration_ms: int,
    palette: list[tuple[int, int, int]],
) -> bytes:
    from PIL import Image

    target = (cells_w * 2, cells_h * 3)
    blobs: list[bytes] = []
    for fp in frame_paths:
        img = Image.open(fp).convert("RGB")
        if img.size != target:
            img = img.resize(target, Image.Resampling.BOX)
        blobs.append(_encode_frame_bytes(img, cells_w, cells_h, palette))
    return _assemble_cvid(blobs, cells_w, cells_h, duration_ms, palette)


def _encode_frame_blobs(
    frame_paths: list[Path],
    cells_w: int,
    cells_h: int,
    palette: list[tuple[int, int, int]],
) -> list[bytes]:
    from PIL import Image

    target = (cells_w * 2, cells_h * 3)
    blobs: list[bytes] = []
    for fp in frame_paths:
        img = Image.open(fp).convert("RGB")
        if img.size != target:
            img = img.resize(target, Image.Resampling.BOX)
        blobs.append(_encode_frame_bytes(img, cells_w, cells_h, palette))
    return blobs


def _list_cvid_parts(out_dir: Path, name: str) -> list[Path]:
    """Existing Song.cvid.N siblings (sorted by part index)."""
    found: list[tuple[int, Path]] = []
    for p in out_dir.glob(f"{name}.cvid.*"):
        m = re.fullmatch(re.escape(name) + r"\.cvid\.(\d+)", p.name, re.IGNORECASE)
        if m and p.is_file():
            found.append((int(m.group(1)), p))
    found.sort(key=lambda t: t[0])
    return [p for _, p in found]


def _cleanup_cvid_outputs(out_dir: Path, name: str, *, keep_single: bool, keep_parts: int) -> None:
    single = out_dir / f"{name}.cvid"
    if not keep_single and single.exists():
        try:
            single.unlink()
        except OSError:
            pass
    for p in _list_cvid_parts(out_dir, name):
        m = re.search(r"\.cvid\.(\d+)$", p.name, re.IGNORECASE)
        idx = int(m.group(1)) if m else 0
        if idx < 1 or idx > keep_parts:
            try:
                p.unlink()
            except OSError:
                pass


def _write_atomic(path: Path, blob: bytes) -> None:
    tmp_out = path.with_suffix(path.suffix + ".part")
    tmp_out.write_bytes(blob)
    os.replace(tmp_out, path)


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
    max_part_bytes: int = MAX_PART_BYTES,
    overwrite: bool = False,
    skip_audio: bool = False,
    log: LogFn | None = None,
) -> dict:
    """Convert one video → Song.dfpwm + Song.cvid (or .cvid.1/.2/…) under out_dir.

    Returns dict with keys: ok, dfpwm, cvid, parts, frames, note.
    """
    from PIL import Image  # noqa: F401 — ensure Pillow present before ffmpeg work

    src = Path(src)
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    name = stem or src.stem
    # Keep filenames Importer-safe (no path separators).
    name = "".join(ch if ch not in '\\/:*?"<>|' else "-" for ch in name).strip(" .") or "video"
    dfpwm = out_dir / f"{name}.dfpwm"
    cvid = out_dir / f"{name}.cvid"
    cvid1 = out_dir / f"{name}.cvid.1"

    if (cvid.exists() or cvid1.exists()) and not overwrite:
        return {
            "ok": False,
            "dfpwm": dfpwm,
            "cvid": cvid if cvid.exists() else cvid1,
            "parts": [],
            "frames": 0,
            "note": "exists",
        }

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
                    "parts": [],
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
            return {"ok": False, "dfpwm": dfpwm, "cvid": cvid, "parts": [], "frames": 0, "note": err}

        frames = sorted(tmp_path.glob("f_*.png"))
        if not frames:
            return {
                "ok": False,
                "dfpwm": dfpwm,
                "cvid": cvid,
                "parts": [],
                "frames": 0,
                "note": "no frames extracted",
            }

        # Fixed official CC palette — remaps cleanly via Video.rgbSlot on Theme.
        palette = list(CC_PALETTE)
        blobs = _encode_frame_blobs(frames, cells_w, cells_h, palette)
        per_part = max_frames_per_part(cells_w, cells_h, max_part_bytes)
        total_bytes = 64 + sum(len(b) for b in blobs) + 2 * len(blobs)

        if len(blobs) <= per_part:
            blob = _assemble_cvid(blobs, cells_w, cells_h, duration_ms, palette)
            _write_atomic(cvid, blob)
            _cleanup_cvid_outputs(out_dir, name, keep_single=True, keep_parts=0)
            _log(
                log,
                f"  cvid {cvid.name}  {cells_w}x{cells_h} cells @ {fps:g} fps  "
                f"({len(blobs)} frames, {len(blob) / 1048576:.2f} MB)",
            )
            return {
                "ok": True,
                "dfpwm": dfpwm,
                "cvid": cvid,
                "parts": [cvid],
                "frames": len(blobs),
                "bytes": len(blob),
                "note": "",
            }

        # Multipart: Song.cvid.1 … Song.cvid.N (each ≤ max_part_bytes).
        part_paths: list[Path] = []
        part_bytes = 0
        n_parts = (len(blobs) + per_part - 1) // per_part
        for i in range(n_parts):
            chunk = blobs[i * per_part : (i + 1) * per_part]
            blob = _assemble_cvid(chunk, cells_w, cells_h, duration_ms, palette)
            part = out_dir / f"{name}.cvid.{i + 1}"
            _write_atomic(part, blob)
            part_paths.append(part)
            part_bytes += len(blob)
            _log(
                log,
                f"  cvid {part.name}  {cells_w}x{cells_h} cells @ {fps:g} fps  "
                f"({len(chunk)} frames, {len(blob) / 1048576:.2f} MB)  "
                f"[part {i + 1}/{n_parts}]",
            )
        _cleanup_cvid_outputs(out_dir, name, keep_single=False, keep_parts=n_parts)
        _log(
            log,
            f"  multipart {n_parts}× ≤{max_part_bytes / 1048576:.0f} MB  "
            f"({len(blobs)} frames, {total_bytes / 1048576:.2f} MB total)",
        )
        return {
            "ok": True,
            "dfpwm": dfpwm,
            "cvid": part_paths[0],
            "parts": part_paths,
            "frames": len(blobs),
            "bytes": part_bytes,
            "note": f"multipart:{n_parts}",
        }


def run_video_convert(
    inputs: list,
    out_dir: str | Path,
    *,
    cells_w: int = DEFAULT_CELLS_W,
    cells_h: int = DEFAULT_CELLS_H,
    fps: float = DEFAULT_FPS,
    max_seconds: float = DEFAULT_MAX_SECONDS,
    max_part_bytes: int = MAX_PART_BYTES,
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
    if max_part_bytes > 0:
        _log(
            log,
            f"Part budget: ≤{max_part_bytes / 1048576:.0f} MB/file "
            f"(~{max_frames_per_part(cells_w, cells_h, max_part_bytes)} frames/part); "
            f"single-file fallback {SINGLE_FILE_CELLS_W}×{SINGLE_FILE_CELLS_H}",
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
            max_part_bytes=max_part_bytes,
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
            "Next: put Song.dfpwm + Song.cvid (or .cvid.1/.2) under "
            "music/Artist/Album/, then drag-drop via Importer (or copy onto the disk).",
        )
    return {
        "done": done,
        "skipped": skipped,
        "failed": failed,
        "out": str(out_root.resolve()),
    }
