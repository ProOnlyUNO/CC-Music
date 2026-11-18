#!/usr/bin/env python3
"""YouTube playlist → MP3 download core via yt-dlp.

Lists playlist/album entries, then downloads selected tracks as MP3
(using ffmpeg when available for audio extract/convert).

Prefer the yt-dlp Python API (works when bundled or pip-installed).
Falls back to a yt-dlp executable on PATH.
"""

from __future__ import annotations

import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Iterable, Sequence

LogFn = Callable[[str], None]
CancelFn = Callable[[], bool]

ILLEGAL_RE = re.compile(r'[<>:"/\\|?*\x00-\x1f]')


@dataclass
class PlaylistEntry:
    index: int  # 1-based playlist position
    id: str
    title: str
    url: str
    duration: int | None = None
    uploader: str | None = None


def _import_yt_dlp():
    try:
        import yt_dlp  # type: ignore

        return yt_dlp
    except ImportError:
        return None


def find_yt_dlp_exe() -> str | None:
    return shutil.which("yt-dlp") or shutil.which("yt-dlp.exe")


def check_yt_dlp() -> tuple[bool, str]:
    yt_dlp = _import_yt_dlp()
    if yt_dlp is not None:
        ver = getattr(getattr(yt_dlp, "version", None), "__version__", None) or "module"
        return True, f"yt-dlp {ver} (Python module)"

    exe = find_yt_dlp_exe()
    if not exe:
        return False, (
            "yt-dlp not found. Install with:\n"
            "  python -m pip install -U yt-dlp\n"
            "Or: winget install yt-dlp.yt-dlp\n"
            "Then restart CC Music Tools."
        )
    try:
        r = subprocess.run([exe, "--version"], capture_output=True, text=True, timeout=30)
        ver = (r.stdout or r.stderr or "").strip().splitlines()[0] if (r.stdout or r.stderr) else "unknown"
        if r.returncode != 0:
            return False, f"yt-dlp failed (--version): {ver}"
        return True, f"yt-dlp {ver} ({exe})"
    except (OSError, subprocess.TimeoutExpired) as e:
        return False, f"yt-dlp check failed: {e}"


def _safe_filename(name: str) -> str:
    name = ILLEGAL_RE.sub("", name)
    name = re.sub(r"\s+", " ", name).strip(" .-")
    return (name or "track")[:120].rstrip(" .-")


def _logger(log: LogFn | None):
    class _Quiet:
        def debug(self, msg):  # noqa: ANN001
            pass

        def info(self, msg):  # noqa: ANN001
            if log and msg:
                # Skip noisy download progress spam; keep useful lines.
                s = str(msg)
                if s.startswith("[download] Destination") or s.startswith("[ExtractAudio]") or "has already been downloaded" in s:
                    log(f"  {s}")

        def warning(self, msg):  # noqa: ANN001
            if log and msg:
                log(f"  warn: {msg}")

        def error(self, msg):  # noqa: ANN001
            if log and msg:
                log(f"  error: {msg}")

    return _Quiet()


_LIST_ID_RE = re.compile(r"(?:[?&]list=)([\w-]+)", re.IGNORECASE)
_WATCH_V_RE = re.compile(r"(?:[?&]v=)([\w-]{6,})", re.IGNORECASE)


def playlist_id_from_url(url: str) -> str | None:
    m = _LIST_ID_RE.search(url or "")
    return m.group(1) if m else None


def normalize_playlist_url(url: str) -> tuple[str, bool]:
    """Prefer a canonical playlist URL when list= is present.

    watch?v=…&list=… often resolves as a single video unless rewritten.
    Returns (url_to_fetch, had_playlist_id).
    """
    url = (url or "").strip()
    list_id = playlist_id_from_url(url)
    if not list_id:
        return url, False
    # Keep YouTube Music / other hosts if already a playlist path
    if "playlist" in url.lower() and f"list={list_id}" in url:
        return url, True
    return f"https://www.youtube.com/playlist?list={list_id}", True


def _entries_from_info(
    data: dict[str, Any],
    fallback_url: str,
    log: LogFn | None,
    *,
    expect_playlist: bool = False,
) -> tuple[str, list[PlaylistEntry]]:
    entries_raw = data.get("entries")
    if entries_raw is None:
        entries_raw = []
    elif not isinstance(entries_raw, list):
        entries_raw = list(entries_raw)

    playlist_title = str(data.get("title") or data.get("id") or "YouTube playlist").strip()
    webpage = str(data.get("webpage_url") or data.get("original_url") or fallback_url)
    data_type = str(data.get("_type") or "").lower()

    # Only collapse to a single video when the user did not ask for a playlist.
    if not entries_raw and data.get("id") and not expect_playlist and data_type in ("", "video", "url"):
        entries_raw = [data]
    elif not entries_raw and expect_playlist:
        # Avoid the old bug: treating the playlist object itself as one "track".
        if log:
            log("  yt-dlp returned no flat entries for this playlist URL.")

    entries: list[PlaylistEntry] = []
    for i, raw in enumerate(entries_raw, start=1):
        if not raw or not isinstance(raw, dict):
            continue
        vid = str(raw.get("id") or "").strip()
        title = str(raw.get("title") or vid or f"Track {i}").strip()
        if title in ("[Deleted video]", "[Private video]") or not vid:
            if log:
                log(f"  skip #{i}: {title or '(missing id)'}")
            continue
        # Skip url-opaque playlist stubs that have no video id shape
        if raw.get("_type") in ("playlist", "multi_video"):
            continue
        entry_url = str(raw.get("url") or raw.get("webpage_url") or "").strip()
        if not entry_url.startswith("http"):
            if re.fullmatch(r"[\w-]{6,}", vid):
                entry_url = f"https://www.youtube.com/watch?v={vid}"
            else:
                entry_url = webpage
        duration = raw.get("duration")
        try:
            duration_i = int(duration) if duration is not None else None
        except (TypeError, ValueError):
            duration_i = None
        uploader = raw.get("uploader") or raw.get("channel") or raw.get("artist")
        entries.append(
            PlaylistEntry(
                index=i,
                id=vid,
                title=title,
                url=entry_url,
                duration=duration_i,
                uploader=str(uploader).strip() if uploader else None,
            )
        )
    return playlist_title, entries


def _extract_flat_api(yt_dlp, url: str, log: LogFn | None) -> dict[str, Any]:
    opts = {
        "quiet": True,
        "no_warnings": True,
        "extract_flat": "in_playlist",
        "skip_download": True,
        "noplaylist": False,
        "ignoreerrors": True,
        "logger": _logger(log),
    }
    with yt_dlp.YoutubeDL(opts) as ydl:
        data = ydl.extract_info(url, download=False)
    if not isinstance(data, dict):
        raise RuntimeError("Unexpected yt-dlp response (expected playlist object).")
    return data


def _extract_flat_exe(exe: str, url: str) -> dict[str, Any]:
    import json

    r = subprocess.run(
        [
            exe,
            "--flat-playlist",
            "--yes-playlist",
            "--ignore-errors",
            "--no-warnings",
            "-J",
            "--no-download",
            "--",
            url,
        ],
        capture_output=True,
        text=True,
    )
    raw_out = (r.stdout or "").strip()
    if r.returncode != 0 and not raw_out:
        err = (r.stderr or r.stdout or "").strip()
        lines = [ln for ln in err.splitlines() if ln.strip()]
        raise RuntimeError("\n".join(lines[-12:]) if lines else f"exit {r.returncode}")
    data = json.loads(raw_out or "{}")
    if not isinstance(data, dict):
        raise RuntimeError("Unexpected yt-dlp response (expected playlist object).")
    return data


def list_playlist(url: str, log: LogFn | None = None) -> tuple[str, list[PlaylistEntry]]:
    """Fetch flat playlist metadata. Returns (playlist_title, entries)."""
    original = (url or "").strip()
    if not original:
        raise ValueError("Paste a YouTube playlist or album URL first.")

    ok, msg = check_yt_dlp()
    if not ok:
        raise RuntimeError(msg)

    fetch_url, expect_playlist = normalize_playlist_url(original)
    if log:
        log(f"Fetching playlist via {msg}…")
        if expect_playlist and fetch_url != original:
            log(f"  Using flat playlist URL (list=): {fetch_url}")

    yt_dlp = _import_yt_dlp()
    data: dict[str, Any]
    if yt_dlp is not None:
        data = _extract_flat_api(yt_dlp, fetch_url, log)
    else:
        exe = find_yt_dlp_exe()
        assert exe
        data = _extract_flat_exe(exe, fetch_url)

    playlist_title, entries = _entries_from_info(
        data, fetch_url, log, expect_playlist=expect_playlist
    )

    # If playlist URL failed / empty but the user pasted watch?v=&list=, try the
    # original once more only when it was already a playlist path; otherwise
    # fall back to single-video listing from the watch URL so Download still works.
    if not entries and expect_playlist:
        watch = _WATCH_V_RE.search(original)
        if watch and log:
            log(
                "  Playlist had no entries (private, deleted, or blocked). "
                "Falling back to the single video from this link."
            )
        if watch:
            single = f"https://www.youtube.com/watch?v={watch.group(1)}"
            if yt_dlp is not None:
                data = _extract_flat_api(yt_dlp, single, log)
            else:
                exe = find_yt_dlp_exe()
                assert exe
                data = _extract_flat_exe(exe, single)
            playlist_title, entries = _entries_from_info(
                data, single, log, expect_playlist=False
            )

    if log:
        log(f"Playlist: {playlist_title}")
        log(f"Found {len(entries)} downloadable track(s).")

    if not entries:
        raise RuntimeError(
            "No downloadable tracks found in that URL. "
            "If this is a playlist, open it on YouTube and confirm it is public, "
            "then paste the playlist URL (youtube.com/playlist?list=…)."
        )

    return playlist_title, entries


def format_duration(seconds: int | None) -> str:
    if seconds is None or seconds < 0:
        return "--:--"
    m, s = divmod(int(seconds), 60)
    h, m = divmod(m, 60)
    if h:
        return f"{h}:{m:02d}:{s:02d}"
    return f"{m}:{s:02d}"


def _download_one_api(yt_dlp, entry: PlaylistEntry, outtmpl: str, log: LogFn | None) -> Path | None:
    opts = {
        "quiet": True,
        "no_warnings": True,
        "noplaylist": True,
        "format": "bestaudio/best",
        "outtmpl": outtmpl,
        "postprocessors": [
            {
                "key": "FFmpegExtractAudio",
                "preferredcodec": "mp3",
                "preferredquality": "0",
            }
        ],
        "logger": _logger(log),
    }
    with yt_dlp.YoutubeDL(opts) as ydl:
        info = ydl.extract_info(entry.url, download=True)
    if not info:
        return None
    # Prefer requested downloads / filepath after postprocess
    req = info.get("requested_downloads") or []
    for item in req:
        fp = item.get("filepath")
        if fp and Path(fp).exists():
            return Path(fp)
    fp = info.get("filepath")
    if fp and Path(fp).exists():
        return Path(fp)
    return None


def _download_one_exe(exe: str, entry: PlaylistEntry, outtmpl: str, log: LogFn | None) -> Path | None:
    cmd = [
        exe,
        "--no-warnings",
        "--no-playlist",
        "-x",
        "--audio-format",
        "mp3",
        "--audio-quality",
        "0",
        "-o",
        outtmpl,
        "--print",
        "after_move:filepath",
        "--",
        entry.url,
    ]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        err = (r.stderr or r.stdout or "").strip()
        lines = [ln for ln in err.splitlines() if ln.strip()]
        raise RuntimeError("\n".join(lines[-8:]) if lines else f"exit {r.returncode}")
    for ln in (r.stdout or "").splitlines():
        ln = ln.strip()
        if ln and Path(ln).exists():
            return Path(ln)
    return None


def download_entries(
    entries: Sequence[PlaylistEntry],
    out_dir: str | Path,
    *,
    log: LogFn | None = None,
    should_cancel: CancelFn | None = None,
) -> tuple[int, int, Path]:
    """Download selected playlist entries as MP3 into out_dir.

    Returns (ok_count, fail_count, out_path).
    """
    out = Path(out_dir).expanduser().resolve()
    out.mkdir(parents=True, exist_ok=True)

    ok_yt, msg = check_yt_dlp()
    if not ok_yt:
        raise RuntimeError(msg)

    selected = list(entries)
    if not selected:
        raise ValueError("Select at least one track to download.")

    if log:
        log(f"Downloading {len(selected)} track(s) as MP3 → {out}")
        log(msg)
        if not shutil.which("ffmpeg"):
            log("Note: ffmpeg not on PATH — MP3 extract may fail. Install: winget install ffmpeg")

    yt_dlp = _import_yt_dlp()
    exe = None if yt_dlp is not None else find_yt_dlp_exe()

    ok_count = 0
    fail_count = 0

    for n, entry in enumerate(selected, start=1):
        if should_cancel and should_cancel():
            if log:
                log("Cancelled.")
            break

        safe = _safe_filename(entry.title)
        # Extension placeholder filled by yt-dlp / postprocessor
        outtmpl = str(out / f"{entry.index:03d} - {safe} [{entry.id}].%(ext)s")

        if log:
            log(f"[{n}/{len(selected)}] {entry.title}")

        try:
            produced: Path | None
            if yt_dlp is not None:
                produced = _download_one_api(yt_dlp, entry, outtmpl, log)
            else:
                assert exe
                produced = _download_one_exe(exe, entry, outtmpl, log)

            if produced is None:
                matches = list(out.glob(f"{entry.index:03d} - {safe} [{entry.id}].*"))
                produced = matches[0] if matches else None
            if log:
                log(f"  OK → {produced.name if produced else '(done)'}")
            ok_count += 1
        except Exception as e:  # noqa: BLE001
            fail_count += 1
            if log:
                log(f"  FAIL: {e}")

    if log:
        log(f"Done. Saved {ok_count}, failed {fail_count}. Folder: {out}")

    return ok_count, fail_count, out


def download_by_indices(
    url: str,
    indices: Iterable[int],
    out_dir: str | Path,
    *,
    log: LogFn | None = None,
    should_cancel: CancelFn | None = None,
) -> tuple[int, int, Path]:
    """Convenience: re-list playlist and download by 1-based indices."""
    _title, entries = list_playlist(url, log=log)
    wanted = {int(i) for i in indices}
    selected = [e for e in entries if e.index in wanted]
    missing = wanted - {e.index for e in selected}
    if missing and log:
        log(f"Note: indices not in playlist: {sorted(missing)}")
    return download_entries(selected, out_dir, log=log, should_cancel=should_cancel)
