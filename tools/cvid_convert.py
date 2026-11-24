#!/usr/bin/env python3
"""CLI: MP4/etc → Song.cvid + Song.dfpwm (see desktop/video_core.py).

Usage:
  python tools/cvid_convert.py path/to/clip.mp4 -o out/Artist/Album
  python tools/cvid_convert.py folder_of_videos -o dfpwm_out --fps 8 --cells 256x72

Defaults: 256×72 @ 8 fps for a 9×3 Advanced Monitor @ scale 0.5 (~270×60 wall).
Packs over ~18 MiB auto-split into Song.cvid.1/.2/.3. Single-file fallback:
--cells 160x45 (fits ~2.5–3 min under 18 MiB without parts).
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DESKTOP = ROOT / "desktop"
if str(DESKTOP) not in sys.path:
    sys.path.insert(0, str(DESKTOP))

import video_core  # noqa: E402


def main() -> int:
    p = argparse.ArgumentParser(description="Convert video → CVID1 + DFPWM for CC:Tweaked")
    p.add_argument("inputs", nargs="+", help="Video file(s) or folder(s)")
    p.add_argument("-o", "--out", required=True, help="Output folder (put Artist/Album here)")
    p.add_argument("--fps", type=float, default=video_core.DEFAULT_FPS)
    p.add_argument(
        "--cells",
        default=f"{video_core.DEFAULT_CELLS_W}x{video_core.DEFAULT_CELLS_H}",
        help="Cell size WxH (default 256x72; single-file fallback 160x45)",
    )
    p.add_argument("--max-seconds", type=float, default=0, help="Trim length (0 = full)")
    p.add_argument(
        "--max-part-mb",
        type=float,
        default=video_core.MAX_PART_BYTES / 1048576,
        help="Max MiB per .cvid / .cvid.N file (default 18; 0 = no split)",
    )
    p.add_argument("--overwrite", action="store_true")
    p.add_argument("--skip-audio", action="store_true", help="Only write .cvid")
    p.add_argument("--dry-run", action="store_true")
    args = p.parse_args()

    try:
        w_s, h_s = args.cells.lower().split("x", 1)
        cells_w, cells_h = int(w_s), int(h_s)
    except ValueError:
        print("Bad --cells; use e.g. 256x72 or 160x45", file=sys.stderr)
        return 2

    max_part_bytes = 0
    if args.max_part_mb and args.max_part_mb > 0:
        max_part_bytes = int(args.max_part_mb * 1048576)

    def log(msg: str) -> None:
        print(msg)

    try:
        summary = video_core.run_video_convert(
            args.inputs,
            args.out,
            cells_w=cells_w,
            cells_h=cells_h,
            fps=args.fps,
            max_seconds=args.max_seconds,
            max_part_bytes=max_part_bytes,
            overwrite=args.overwrite,
            skip_audio=args.skip_audio,
            dry_run=args.dry_run,
            log=log,
        )
    except RuntimeError as e:
        print(str(e), file=sys.stderr)
        return 1

    if summary.get("failed"):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
