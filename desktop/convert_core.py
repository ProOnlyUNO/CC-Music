#!/usr/bin/env python3
"""DFPWM conversion core (from mp3_to_dfpwm). Needs ffmpeg 5.1+ with dfpwm encoder."""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import unicodedata
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Callable

from name_sanitize import clean_stem_for_output

AUDIO_EXTS = {".mp3", ".m4a", ".wav", ".flac", ".ogg", ".opus", ".aac", ".webm", ".wma"}

JUNK_WORDS = {
    "official", "audio", "video", "music", "lyric", "lyrics", "visualizer", "visualiser",
    "hd", "hq", "4k", "explicit", "clean", "dirty", "full", "song", "version", "clip",
    "mv", "m/v", "oficial", "videoclip", "videoclipe", "lyrical", "soundtrack",
}

CHANNEL_WORDS = ("official", "vevo")

BITRATE_ONLY = re.compile(r"\d{2,3}\s*k(?:bps)?", re.I)
BRACKET_RE = re.compile(r"\s*[\(\[]([^\(\)\[\]]*)[\)\]]")
SPLIT_RE = re.compile(r"\s+[-\u2013\u2014|]\s+")
CHANNEL_RE = re.compile(r"\s*\b(?:" + "|".join(CHANNEL_WORDS) + r")\s*$", re.I)
ARTIST_SPLIT_RE = re.compile(r"\s*(?:,|;|&|\bfeat\.?|\bft\.?|\bfeaturing\b|\bx\b|\band\b)\s*", re.I)
ILLEGAL_RE = re.compile(r'[<>:"/\\|?*\x00-\x1f]')

LogFn = Callable[[str], None]


def _is_junk_group(text: str) -> bool:
    text = text.strip()
    if BITRATE_ONLY.fullmatch(text):
        return True
    words = re.findall(r"[a-z0-9/]+", text.lower())
    return bool(words) and all(w in JUNK_WORDS for w in words)


def _strip_junk_groups(s: str) -> str:
    return BRACKET_RE.sub(lambda m: "" if _is_junk_group(m.group(1)) else m.group(0), s)


def _fold(s: str, keep_unicode: bool) -> str:
    if keep_unicode:
        return s
    folded = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode("ascii")
    return folded if folded.strip() else s


def _safe(s: str, keep_unicode: bool) -> str:
    s = _fold(s, keep_unicode)
    s = ILLEGAL_RE.sub("", s)
    s = re.sub(r"\s+", " ", s).strip(" .-")
    return s[:100].rstrip(" .-")


def read_tags(ffprobe: str, path: Path) -> dict:
    try:
        r = subprocess.run(
            [ffprobe, "-v", "error", "-show_entries", "format_tags", "-of", "json", str(path)],
            capture_output=True,
            text=True,
        )
        tags = json.loads(r.stdout or "{}").get("format", {}).get("tags", {})
    except (OSError, ValueError):
        return {}
    return {k.lower(): str(v).strip() for k, v in tags.items() if str(v).strip()}


def parse_name(stem: str, title_first: bool = False):
    s = stem if " " in stem else stem.replace("_", " ")
    # Drop trailing [youtubeId] before junk/artist parsing so titles stay clean.
    s = clean_stem_for_output(s)
    s = _strip_junk_groups(s)
    s = re.sub(r"\s+", " ", s).strip()

    tokens = [t.strip() for t in SPLIT_RE.split(s) if t.strip()]
    channel = None

    if len(tokens) >= 3 and tokens[-1].lower() == "topic":
        channel = tokens[-2]
        tokens = tokens[:-2]
    elif len(tokens) >= 2 and CHANNEL_RE.search(tokens[-1]):
        channel = CHANNEL_RE.sub("", tokens[-1]).strip() or None
        tokens = tokens[:-1]

    if tokens and re.fullmatch(r"\d{1,3}", tokens[0]) and len(tokens) > 1:
        tokens = tokens[1:]

    if not tokens:
        return channel, stem.strip()
    if len(tokens) >= 2 and title_first:
        artist, title = tokens[-1], " - ".join(tokens[:-1])
    elif len(tokens) >= 2:
        artist, title = tokens[0], " - ".join(tokens[1:])
    else:
        artist, title = channel, tokens[0]

    title = re.sub(r"\s+", " ", title).strip(" -\u2013\u2014|")
    return artist, title


def primary_artist(artist):
    if not artist:
        return None
    for part in ARTIST_SPLIT_RE.split(artist):
        if part.strip():
            return part.strip()
    return artist.strip()


def collect_inputs(paths) -> list[Path]:
    files: list[Path] = []
    for p in paths:
        p = Path(p)
        if p.is_dir():
            files += sorted(f for f in p.rglob("*") if f.suffix.lower() in AUDIO_EXTS)
        elif p.is_file() and p.suffix.lower() in AUDIO_EXTS:
            files.append(p)
    return files


def build_plan(
    files,
    out_root: Path,
    forced_artist,
    flat: bool,
    keep_unicode: bool,
    keep_duplicates: bool,
    title_first: bool = False,
    ffprobe=None,
):
    plan, seen = [], {}
    for src in files:
        artist, title = parse_name(src.stem, title_first)
        album = None
        if ffprobe:
            tags = read_tags(ffprobe, src)
            if tags.get("title"):
                title = re.sub(
                    r"\s+",
                    " ",
                    _strip_junk_groups(clean_stem_for_output(tags["title"])),
                ).strip()
            artist = tags.get("album_artist") or tags.get("artist") or artist
            album = tags.get("album")
        # Fallback stem also strips [youtubeId] so convert of already-suffixed
        # downloads (or old libraries) does not keep the ID in .dfpwm names.
        title = _safe(title, keep_unicode) or _safe(
            clean_stem_for_output(src.stem), keep_unicode
        ) or "Untitled"

        folder_artist = forced_artist or primary_artist(artist) or "Unsorted"
        folder_artist = _safe(folder_artist, keep_unicode) or "Unsorted"

        folder = out_root if flat else out_root / folder_artist
        if album and not flat:
            album_dir = _safe(album, keep_unicode)
            if album_dir:
                folder = folder / album_dir

        key = (str(folder).lower(), title.lower())
        if key in seen:
            if not keep_duplicates:
                plan.append(
                    {
                        "src": src,
                        "dst": None,
                        "shown": "",
                        "note": f"duplicate of {seen[key].name}",
                    }
                )
                continue
            n = 2
            while (str(folder).lower(), f"{title} ({n})".lower()) in seen:
                n += 1
            title = f"{title} ({n})"
            key = (str(folder).lower(), title.lower())
        seen[key] = src
        dst = folder / f"{title}.dfpwm"
        plan.append(
            {
                "src": src,
                "dst": dst,
                "shown": dst.relative_to(out_root).as_posix(),
                "note": "",
            }
        )
    return plan


def check_ffmpeg() -> str:
    exe = shutil.which("ffmpeg")
    if not exe:
        raise RuntimeError(
            "ffmpeg was not found on PATH.\n"
            "  Windows: winget install ffmpeg  (or https://ffmpeg.org)\n"
            "  Then open a NEW terminal / restart this app."
        )
    try:
        enc = subprocess.run(
            [exe, "-hide_banner", "-encoders"], capture_output=True, text=True
        ).stdout
    except OSError as e:
        raise RuntimeError(f"Could not run ffmpeg: {e}") from e
    if "dfpwm" not in enc.lower():
        raise RuntimeError("Your ffmpeg has no DFPWM encoder. Need ffmpeg 5.1 or newer.")
    return exe


def convert_one(exe: str, src: Path, dst: Path):
    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = dst.with_name(dst.name + ".part")
    cmd = [
        exe,
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-i",
        str(src),
        "-vn",
        "-ac",
        "1",
        "-ar",
        "48000",
        "-c:a",
        "dfpwm",
        "-f",
        "dfpwm",
        str(tmp),
    ]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0 or not tmp.exists() or tmp.stat().st_size == 0:
        if tmp.exists():
            tmp.unlink()
        return False, (r.stderr.strip().splitlines() or ["ffmpeg failed"])[-1]
    os.replace(tmp, dst)
    return True, dst.stat().st_size


def run_convert(
    inputs: list,
    out_dir: str | Path,
    *,
    artist: str | None = None,
    flat: bool = False,
    dry_run: bool = False,
    overwrite: bool = False,
    keep_duplicates: bool = False,
    title_first: bool = False,
    use_tags: bool = False,
    keep_unicode: bool = False,
    jobs: int | None = None,
    log: LogFn | None = None,
    should_cancel: Callable[[], bool] | None = None,
) -> dict:
    """Run conversion. Returns summary dict. log() receives progress lines."""

    def _log(msg: str) -> None:
        if log:
            log(msg)

    files = collect_inputs(inputs)
    if not files:
        raise RuntimeError("No audio files found in the selected folder/files.")

    out_root = Path(out_dir)
    ffprobe = None
    if use_tags:
        ffprobe = shutil.which("ffprobe")
        if not ffprobe:
            _log("! ffprobe not found — ignoring Use tags (comes with ffmpeg)")

    plan = build_plan(
        files,
        out_root,
        artist,
        flat,
        keep_unicode,
        keep_duplicates,
        title_first,
        ffprobe,
    )

    _log(f"{len(plan)} file(s) planned → {out_root}")
    for item in plan:
        if item["dst"] is None:
            _log(f"  SKIP {item['src'].name} ({item['note']})")
        else:
            _log(f"  {item['src'].name} → {item['shown']}")

    if dry_run:
        _log("Dry run — nothing converted.")
        return {"done": 0, "skipped": len(plan), "failed": 0, "out": str(out_root.resolve())}

    exe = check_ffmpeg()
    todo = []
    skipped = 0
    for item in plan:
        if item["dst"] is None:
            skipped += 1
        elif item["dst"].exists() and not overwrite:
            _log(f"  exists, skipped: {item['dst']}")
            skipped += 1
        else:
            todo.append(item)

    workers = jobs if jobs is not None else max(1, (os.cpu_count() or 2) // 2)
    done = failed = total_bytes = 0

    with ThreadPoolExecutor(max_workers=max(1, workers)) as pool:
        futures = {pool.submit(convert_one, exe, it["src"], it["dst"]): it for it in todo}
        for fut in as_completed(futures):
            if should_cancel and should_cancel():
                _log("Cancelled — waiting for in-flight jobs…")
                break
            it = futures[fut]
            ok, info = fut.result()
            if ok:
                done += 1
                total_bytes += info
                _log(f"  ok  {it['shown']}  ({info / 1048576:.2f} MB)")
            else:
                failed += 1
                _log(f"  FAILED  {it['src'].name}: {info}")

    _log(
        f"Converted {done}, skipped {skipped}, failed {failed}. "
        f"Output: {out_root.resolve()}  ({total_bytes / 1048576:.1f} MB)"
    )
    if done:
        _log("Next: drag artist folders into Importer.lua / uploader in-game.")
    return {
        "done": done,
        "skipped": skipped,
        "failed": failed,
        "bytes": total_bytes,
        "out": str(out_root.resolve()),
    }
