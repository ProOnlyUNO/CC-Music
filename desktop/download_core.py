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

import lyrics_core
from meta_parse import TrackMeta, artist_album_dest, resolve_track_meta, safe_filename_stem
from name_sanitize import sanitize_media_path, unique_filename
from nfp_core import convert_art_for_track, find_cover_image, write_nfp

LogFn = Callable[[str], None]
CancelFn = Callable[[], bool]
# phase, fraction 0..1 (None = indeterminate / busy), detail message
ProgressFn = Callable[[str, float | None, str], None]

ILLEGAL_RE = re.compile(r'[<>:"/\\|?*\x00-\x1f]')


@dataclass
class PlaylistEntry:
    index: int  # 1-based playlist position
    id: str
    title: str
    url: str
    duration: int | None = None
    uploader: str | None = None
    artist: str | None = None
    album: str | None = None
    track_title: str | None = None


@dataclass
class DownloadedTrack:
    path: Path
    meta: TrackMeta
    entry: PlaylistEntry
    lrc: Path | None = None
    art: Path | None = None  # sibling cover image or .nfp


@dataclass
class SearchResult:
    kind: str  # "song" | "playlist" | "album"
    title: str
    url: str
    id: str = ""
    uploader: str | None = None
    duration: int | None = None
    channel: str | None = None


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
        uploader_s = str(uploader).strip() if uploader else None
        raw_artist = raw.get("artist") or raw.get("creator") or raw.get("album_artist")
        # Prefer real album tags; avoid playlist *id* strings from flat entries.
        raw_album = raw.get("album")
        if not raw_album:
            cand = raw.get("playlist_title") or raw.get("playlist")
            if cand and not re.fullmatch(r"[\w-]{10,}", str(cand).strip()):
                raw_album = cand
        raw_track = raw.get("track") or raw.get("alt_title")
        meta = resolve_track_meta(
            title=title,
            uploader=uploader_s,
            playlist_title=playlist_title,
            artist_hint=str(raw_artist).strip() if raw_artist else None,
            album_hint=str(raw_album).strip() if raw_album else None,
            track_title_hint=str(raw_track).strip() if raw_track else None,
        )
        entries.append(
            PlaylistEntry(
                index=i,
                id=vid,
                title=title,
                url=entry_url,
                duration=duration_i,
                uploader=uploader_s,
                artist=meta.artist,
                album=meta.album,
                track_title=meta.title,
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


def list_playlist(
    url: str,
    log: LogFn | None = None,
    progress: ProgressFn | None = None,
) -> tuple[str, list[PlaylistEntry]]:
    """Fetch flat playlist metadata. Returns (playlist_title, entries)."""
    original = (url or "").strip()
    if not original:
        raise ValueError("Paste a YouTube playlist or album URL first.")

    ok, msg = check_yt_dlp()
    if not ok:
        raise RuntimeError(msg)

    fetch_url, expect_playlist = normalize_playlist_url(original)
    if progress:
        progress("fetch", None, "Fetching playlist titles…")
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
    if progress:
        progress(
            "fetch",
            1.0,
            f"Found {len(entries)} track(s) — {playlist_title}",
        )

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


def _search_entries_from_info(data: dict[str, Any], *, kind: str) -> list[SearchResult]:
    raw = data.get("entries")
    if raw is None:
        raw = [data] if data.get("id") else []
    elif not isinstance(raw, list):
        raw = list(raw)
    out: list[SearchResult] = []
    for item in raw:
        if not item or not isinstance(item, dict):
            continue
        vid = str(item.get("id") or "").strip()
        title = str(item.get("title") or vid or "Untitled").strip()
        if not vid or title in ("[Deleted video]", "[Private video]"):
            continue
        ie_key = str(item.get("ie_key") or item.get("_type") or "").lower()
        item_kind = kind
        if "playlist" in ie_key:
            item_kind = "playlist"
        url = str(item.get("url") or item.get("webpage_url") or "").strip()
        if not url.startswith("http"):
            if item_kind == "playlist":
                url = f"https://www.youtube.com/playlist?list={vid}"
            else:
                url = f"https://www.youtube.com/watch?v={vid}"
        duration = item.get("duration")
        try:
            duration_i = int(duration) if duration is not None else None
        except (TypeError, ValueError):
            duration_i = None
        uploader = item.get("uploader") or item.get("channel") or item.get("creator")
        out.append(
            SearchResult(
                kind=item_kind,
                title=title,
                url=url,
                id=vid,
                uploader=str(uploader).strip() if uploader else None,
                duration=duration_i,
                channel=str(item.get("channel") or "").strip() or None,
            )
        )
    return out


def search_youtube(
    query: str,
    *,
    limit: int = 8,
    include_songs: bool = True,
    include_playlists: bool = True,
    log: LogFn | None = None,
    progress: ProgressFn | None = None,
) -> list[SearchResult]:
    """Search YouTube for songs and/or playlists via yt-dlp.

    Songs use ``ytsearchN:query``. Playlists use the YouTube results URL with
    the playlist filter (``sp=EgIQAw%3D%3D``).
    """
    q = (query or "").strip()
    if not q:
        raise ValueError("Type a search query first.")
    if not include_songs and not include_playlists:
        raise ValueError("Enable songs and/or playlists to search.")

    ok, msg = check_yt_dlp()
    if not ok:
        raise RuntimeError(msg)

    limit = max(1, min(25, int(limit)))
    if progress:
        progress("search", None, f"Searching YouTube for “{q}”…")
    if log:
        log(f"YouTube search via {msg}: {q!r} (limit {limit})")

    results: list[SearchResult] = []
    yt_dlp = _import_yt_dlp()
    exe = None if yt_dlp is not None else find_yt_dlp_exe()

    if include_songs:
        song_url = f"ytsearch{limit}:{q}"
        if progress:
            progress("search", None, "Searching songs…")
        if yt_dlp is not None:
            data = _extract_flat_api(yt_dlp, song_url, log)
        else:
            assert exe
            data = _extract_flat_exe(exe, song_url)
        songs = _search_entries_from_info(data, kind="song")
        results.extend(songs)
        if log:
            log(f"  songs: {len(songs)}")

    if include_playlists:
        from urllib.parse import quote_plus

        # YouTube search results filtered to Playlists
        pl_url = (
            "https://www.youtube.com/results?search_query="
            + quote_plus(q)
            + "&sp=EgIQAw%3D%3D"
        )
        if progress:
            progress("search", None, "Searching playlists…")
        try:
            if yt_dlp is not None:
                data = _extract_flat_api(yt_dlp, pl_url, log)
            else:
                assert exe
                data = _extract_flat_exe(exe, pl_url)
            playlists = _search_entries_from_info(data, kind="playlist")[:limit]
            # Dedupe against songs by id
            seen = {r.id for r in results}
            added = 0
            for p in playlists:
                if p.id in seen:
                    continue
                # Force playlist URLs when id looks like a list id
                if not p.url.startswith("http") or "list=" not in p.url:
                    p.url = f"https://www.youtube.com/playlist?list={p.id}"
                p.kind = "playlist"
                results.append(p)
                seen.add(p.id)
                added += 1
            if log:
                log(f"  playlists: {added}")
        except Exception as e:  # noqa: BLE001
            if log:
                log(f"  playlist search warn: {e}")

    # Prefer playlists first, then songs (stable within each group)
    results.sort(key=lambda r: (0 if r.kind == "playlist" else 1, r.title.lower()))
    if progress:
        progress("search", 1.0, f"Found {len(results)} result(s)")
    if log:
        log(f"Search done — {len(results)} result(s).")
    if not results:
        raise RuntimeError(f"No YouTube results for “{q}”. Try another query.")
    return results


_OFFICIAL_BAD = (
    "cover",
    "karaoke",
    "instrumental",
    "nightcore",
    "8d audio",
    "reaction",
    "fan made",
    "fanmade",
    "sped up",
    "slowed",
    "remix",
    "mashup",
    "lyric video",  # prefer Topic/audio over random lyric uploads when both exist
    "version 2",
    "version 3",
    "edit",
    "bootleg",
)


def _norm_match_text(s: str) -> str:
    s = (s or "").lower()
    s = re.sub(r"[^\w\s]+", " ", s)
    return re.sub(r"\s+", " ", s).strip()


def score_youtube_match(
    result: SearchResult,
    artist: str,
    title: str,
) -> int:
    """Higher is better — prefer Topic / VEVO / official artist uploads."""
    ch = _norm_match_text(result.channel or result.uploader or "")
    up = _norm_match_text(result.uploader or "")
    rt = _norm_match_text(result.title or "")
    artist_n = _norm_match_text(artist)
    title_n = _norm_match_text(title)
    score = 0

    # Auto-generated Topic channels are usually clean audio
    if ch.endswith(" topic") or " topic" in ch or up.endswith(" topic"):
        score += 120
    if "vevo" in ch or "vevo" in up:
        score += 100
    if artist_n and (ch == artist_n or ch.startswith(artist_n + " ") or artist_n in ch):
        score += 55
    if "official" in ch or "official" in rt:
        score += 45
    if "official audio" in rt or "official music video" in rt:
        score += 35
    if title_n and (rt == title_n or rt.startswith(title_n + " ") or f" {title_n} " in f" {rt} "):
        score += 55
    elif title_n and title_n in rt:
        score += 40
    elif title_n:
        # partial token overlap
        tokens = [t for t in title_n.split() if len(t) > 2]
        if tokens:
            hit = sum(1 for t in tokens if t in rt)
            score += int(30 * hit / len(tokens))
    if artist_n and artist_n in rt:
        score += 20
    # Extra junk after the title (e.g. "Jesus Walks (Version 2)") when not in Genius title
    if title_n and title_n in rt:
        rest = rt.replace(title_n, " ", 1)
        if any(x in rest for x in ("version", "remaster", "remix", "edit", "live")) and not any(
            x in title_n for x in ("version", "remaster", "remix", "edit", "live")
        ):
            score -= 35

    for bad in _OFFICIAL_BAD:
        bad_n = _norm_match_text(bad)
        if bad_n in rt and bad_n not in title_n:
            score -= 55
    if "live" in rt and "live" not in title_n:
        score -= 25
    return score


def is_youtube_watch_url(url: str) -> bool:
    u = (url or "").strip().lower()
    return "youtube.com/watch" in u or "youtu.be/" in u or "youtube.com/shorts/" in u


def needs_youtube_match(entry: PlaylistEntry) -> bool:
    """True when the entry still needs a YouTube watch URL (e.g. Genius track)."""
    return not is_youtube_watch_url(entry.url or "")


def find_best_youtube_match(
    artist: str,
    title: str,
    *,
    limit: int = 6,
    log: LogFn | None = None,
    progress: ProgressFn | None = None,
) -> SearchResult:
    """yt-dlp search ``Artist Title``; pick the best official/Topic-leaning hit."""
    a = (artist or "").strip()
    t = (title or "").strip()
    if not t:
        raise ValueError("Missing track title for YouTube match.")
    query = f"{a} {t}".strip() if a else t
    if progress:
        progress("match", None, f"Matching YouTube — {a} — {t}" if a else f"Matching YouTube — {t}")
    if log:
        log(f"  yt match search: {query!r}")

    results = search_youtube(
        query,
        limit=max(3, min(10, int(limit))),
        include_songs=True,
        include_playlists=False,
        log=log,
        progress=None,  # keep outer progress as match phase
    )
    ranked = sorted(
        results,
        key=lambda r: (-score_youtube_match(r, a, t), r.title.lower()),
    )
    best = ranked[0]
    if log:
        sc = score_youtube_match(best, a, t)
        who = best.channel or best.uploader or "?"
        log(f"  yt match → {best.title} [{who}] (score {sc})")
    if progress:
        progress("match", 1.0, f"Matched — {best.title}")
    return best


def entries_from_genius_album(album) -> tuple[str, list[PlaylistEntry]]:
    """Convert a ``genius_core.GeniusAlbum`` into playlist entries (YouTube URL empty)."""
    playlist_title = f"{album.artist} - {album.name}"
    entries: list[PlaylistEntry] = []
    for track in album.tracks:
        entries.append(
            PlaylistEntry(
                index=track.index,
                id=f"genius-{track.id}",
                title=track.title,
                url=track.url or album.url,
                duration=None,
                uploader=track.artist,
                artist=track.artist or album.artist,
                album=track.album or album.name,
                track_title=track.title,
            )
        )
    return playlist_title, entries


def resolve_youtube_for_entries(
    entries: Sequence[PlaylistEntry],
    *,
    log: LogFn | None = None,
    progress: ProgressFn | None = None,
    should_cancel: CancelFn | None = None,
) -> list[PlaylistEntry]:
    """Fill watch URLs for Genius (or other) entries via best YouTube match."""
    selected = list(entries)
    need = [e for e in selected if needs_youtube_match(e)]
    if not need:
        return selected

    total = len(need)
    if log:
        log(f"Matching {total} track(s) on YouTube (prefer Topic / official)…")
    matched = 0
    for n, entry in enumerate(need, start=1):
        if should_cancel and should_cancel():
            if log:
                log("YouTube match cancelled.")
            break
        artist = (entry.artist or entry.uploader or "").strip()
        title = (entry.track_title or entry.title or "").strip()
        label = f"{artist} — {title}" if artist else title
        if progress:
            overall = (n - 1) / total
            progress("match", overall, f"Match {n}/{total}: {label}")
        try:
            best = find_best_youtube_match(
                artist,
                title,
                log=log,
                progress=None,
            )
            entry.url = best.url
            # Keep Genius artist/album/title; only adopt YouTube id for download
            if best.id:
                entry.id = best.id
            if best.uploader and not entry.uploader:
                entry.uploader = best.uploader
            if best.duration is not None:
                entry.duration = best.duration
            matched += 1
        except Exception as e:  # noqa: BLE001
            if log:
                log(f"  match FAIL [{n}/{total}] {label}: {e}")
    if progress:
        progress("match", 1.0, f"Matched {matched}/{total} on YouTube")
    if log:
        log(f"YouTube match done — {matched}/{total}.")
    return selected


def entry_meta(entry: PlaylistEntry, playlist_title: str | None = None) -> TrackMeta:
    """Resolve artist/album/title for an entry (playlist meta preferred)."""
    return resolve_track_meta(
        title=entry.title,
        uploader=entry.uploader,
        playlist_title=playlist_title,
        artist_hint=entry.artist,
        album_hint=entry.album,
        track_title_hint=entry.track_title,
    )


def _embed_tags_ffmpeg(path: Path, meta: TrackMeta, log: LogFn | None = None) -> None:
    """Write artist/title/album tags so LRCLIB + convert still see them after rename."""
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg or not path.is_file():
        return
    tmp = path.with_name(path.stem + ".tagpart" + path.suffix)
    cmd = [
        ffmpeg,
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-i",
        str(path),
        "-codec",
        "copy",
        "-map_metadata",
        "0",
        "-metadata",
        f"artist={meta.artist}",
        "-metadata",
        f"album_artist={meta.artist}",
        "-metadata",
        f"title={meta.title}",
        "-metadata",
        f"album={meta.album}",
        str(tmp),
    ]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        if r.returncode == 0 and tmp.exists() and tmp.stat().st_size > 0:
            tmp.replace(path)
        elif tmp.exists():
            tmp.unlink(missing_ok=True)
            if log:
                log("  warn: could not embed tags (ffmpeg)")
    except (OSError, subprocess.TimeoutExpired) as e:
        if tmp.exists():
            tmp.unlink(missing_ok=True)
        if log:
            log(f"  warn: tag embed failed: {e}")


def _yt_dlp_progress_hook(progress: ProgressFn | None, label: str):
    """Map yt-dlp download dict → progress(phase, frac, detail)."""

    def hook(d: dict) -> None:  # noqa: ANN001
        if not progress:
            return
        status = d.get("status")
        if status == "downloading":
            total = d.get("total_bytes") or d.get("total_bytes_estimate") or 0
            done = d.get("downloaded_bytes") or 0
            frac = (done / total) if total else None
            speed = d.get("speed")
            eta = d.get("eta")
            bits = []
            if frac is not None:
                bits.append(f"{frac * 100:.0f}%")
            if speed:
                try:
                    bits.append(f"{float(speed) / 1048576:.1f} MB/s")
                except (TypeError, ValueError):
                    pass
            if eta is not None:
                bits.append(f"ETA {eta}s")
            detail = f"{label} — " + (" · ".join(bits) if bits else "downloading…")
            progress("track", frac, detail)
        elif status == "finished":
            progress("track", 1.0, f"{label} — converting to MP3…")
        elif status == "error":
            progress("track", None, f"{label} — download error")

    return hook


def _download_one_api(
    yt_dlp,
    entry: PlaylistEntry,
    outtmpl: str,
    meta: TrackMeta,
    log: LogFn | None,
    progress: ProgressFn | None = None,
) -> Path | None:
    label = f"{meta.artist} — {meta.title}"
    opts = {
        "quiet": True,
        "no_warnings": True,
        "noplaylist": True,
        "format": "bestaudio/best",
        "outtmpl": outtmpl,
        "writethumbnail": True,
        # Prefer keeping artist/title in tags even after filename cleanup.
        "postprocessors": [
            {
                "key": "FFmpegExtractAudio",
                "preferredcodec": "mp3",
                "preferredquality": "0",
            },
            {"key": "FFmpegMetadata", "add_metadata": True},
            {"key": "FFmpegThumbnailsConvertor", "format": "jpg"},
        ],
        "postprocessor_args": {
            "ffmpeg": [
                "-metadata",
                f"artist={meta.artist}",
                "-metadata",
                f"album_artist={meta.artist}",
                "-metadata",
                f"title={meta.title}",
                "-metadata",
                f"album={meta.album}",
            ]
        },
        "progress_hooks": [_yt_dlp_progress_hook(progress, label)],
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


def _download_one_exe(
    exe: str,
    entry: PlaylistEntry,
    outtmpl: str,
    meta: TrackMeta,
    log: LogFn | None,
) -> Path | None:
    cmd = [
        exe,
        "--no-warnings",
        "--no-playlist",
        "-x",
        "--audio-format",
        "mp3",
        "--audio-quality",
        "0",
        "--embed-metadata",
        "--write-thumbnail",
        "--convert-thumbnails",
        "jpg",
        "--parse-metadata",
        f"{meta.artist}:%(artist)s",
        "--parse-metadata",
        f"{meta.title}:%(title)s",
        "--parse-metadata",
        f"{meta.album}:%(album)s",
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


def organize_tracks(
    tracks: Sequence[DownloadedTrack],
    library_root: str | Path,
    *,
    log: LogFn | None = None,
    progress: ProgressFn | None = None,
) -> Path:
    """Move MP3 + sibling .lrc / cover art into ``library_root/Artist/Album/Song.*``."""
    root = Path(library_root).expanduser().resolve()
    root.mkdir(parents=True, exist_ok=True)
    reserved: set[str] = set()
    total = max(1, len(tracks))
    if progress:
        progress("organize", 0.0, f"Organizing 0/{len(tracks)} into Artist/Album…")
    for i, t in enumerate(tracks, start=1):
        if not t.path.exists():
            if progress:
                progress("organize", i / total, f"Organize {i}/{len(tracks)} (missing file)")
            continue
        old_path = t.path
        old_lrc = None
        if t.lrc and t.lrc.exists():
            old_lrc = t.lrc
        elif old_path.with_suffix(".lrc").exists():
            old_lrc = old_path.with_suffix(".lrc")

        old_art = None
        if t.art and Path(t.art).exists():
            old_art = Path(t.art)
        else:
            old_art = find_cover_image(old_path)

        dest = artist_album_dest(root, t.meta, t.path.suffix, reserved=reserved)
        dest.parent.mkdir(parents=True, exist_ok=True)
        if dest.resolve() != old_path.resolve():
            if dest.exists():
                dest.unlink()
            old_path.rename(dest)
            if log:
                log(f"  organize → {dest.relative_to(root).as_posix()}")
        t.path = dest

        new_lrc = dest.with_suffix(".lrc")
        if old_lrc is not None and old_lrc.exists():
            if old_lrc.resolve() != new_lrc.resolve():
                if new_lrc.exists():
                    new_lrc.unlink()
                old_lrc.rename(new_lrc)
            t.lrc = new_lrc
        else:
            t.lrc = new_lrc if new_lrc.exists() else None

        # Keep song cover beside the track; also seed album cover.nfp for the jukebox.
        if old_art is not None and old_art.exists():
            art_dest = dest.with_suffix(old_art.suffix.lower())
            try:
                if old_art.resolve() != art_dest.resolve():
                    if art_dest.exists():
                        art_dest.unlink()
                    old_art.rename(art_dest)
                # Convert PNG/JPG → Song.nfp (+ album cover.nfp) beside the track.
                nfp = convert_art_for_track(
                    dest,
                    dest,
                    overwrite=False,
                    ffmpeg=shutil.which("ffmpeg"),
                    log=log,
                )
                if nfp is None and art_dest.suffix.lower() != ".nfp":
                    song_nfp = dest.with_suffix(".nfp")
                    write_nfp(art_dest, song_nfp)
                    cover_nfp = dest.parent / "cover.nfp"
                    if not cover_nfp.exists():
                        write_nfp(art_dest, cover_nfp)
                    nfp = song_nfp
                    if log:
                        log(f"  art  {song_nfp.relative_to(root).as_posix()}")
                t.art = nfp or art_dest
            except OSError as e:
                if log:
                    log(f"  warn: could not keep cover art: {e}")
        if progress:
            progress(
                "organize",
                i / total,
                f"Organize {i}/{len(tracks)} — {t.meta.artist} / {t.meta.album}",
            )
    if log:
        log(f"Organized into Artist/Album under {root}")
    if progress:
        progress("organize", 1.0, f"Organized {len(tracks)} track(s)")
    return root


def download_entries(
    entries: Sequence[PlaylistEntry],
    out_dir: str | Path,
    *,
    playlist_title: str | None = None,
    fetch_lyrics: bool = True,
    lyrics_delay: float = lyrics_core.DEFAULT_DELAY,
    log: LogFn | None = None,
    progress: ProgressFn | None = None,
    should_cancel: CancelFn | None = None,
) -> tuple[int, int, Path, list[DownloadedTrack]]:
    """Download selected playlist entries as MP3 into out_dir.

    Lyrics are fetched **before** the clean rename finishes pairing, using
    playlist/artist metadata so LRCLIB still sees the real artist after any
    ``[videoId]`` strip. Returns (ok_count, fail_count, out_path, tracks).

    ``progress(phase, frac, detail)`` reports overall + per-track updates.
    Phases: ``overall``, ``track``, ``lyrics``.
    """
    out = Path(out_dir).expanduser().resolve()
    out.mkdir(parents=True, exist_ok=True)

    ok_yt, msg = check_yt_dlp()
    if not ok_yt:
        raise RuntimeError(msg)

    selected = list(entries)
    if not selected:
        raise ValueError("Select at least one track to download.")

    total = len(selected)
    if log:
        log(f"Downloading {total} track(s) as MP3 → {out}")
        log(msg)
        if fetch_lyrics:
            log("Auto-fetch lyrics (LRCLIB) using playlist artist/title before clean rename.")
        if not shutil.which("ffmpeg"):
            log("Note: ffmpeg not on PATH — MP3 extract may fail. Install: winget install ffmpeg")

    def _overall(n: int, track_frac: float, detail: str) -> None:
        if not progress:
            return
        # Within each track: download ~0–70%, lyrics ~70–95%, finish ~95–100%
        overall = min(1.0, max(0.0, (n - 1 + track_frac) / total))
        progress("overall", overall, detail)

    yt_dlp = _import_yt_dlp()
    exe = None if yt_dlp is not None else find_yt_dlp_exe()

    ok_count = 0
    fail_count = 0
    downloaded: list[DownloadedTrack] = []

    for n, entry in enumerate(selected, start=1):
        if should_cancel and should_cancel():
            if log:
                log("Cancelled.")
            if progress:
                progress("overall", (n - 1) / total, "Cancelled")
            break

        meta = entry_meta(entry, playlist_title)
        # Keep entry fields in sync for later organize / UI
        entry.artist = meta.artist
        entry.album = meta.album
        entry.track_title = meta.title
        label = f"{meta.artist} — {meta.title}"

        safe = _safe_filename(entry.track_title or entry.title)
        # Clean outtmpl — no [youtubeId] suffix (kept unique via index + disambiguator).
        base_stem = f"{entry.index:03d} - {safe}"
        reserved_names = {p.name.lower() for p in out.iterdir()} if out.exists() else set()
        # Pre-claim the intended mp3 name so parallel-ish loops stay unique.
        claimed = unique_filename(
            out,
            f"{base_stem}.mp3",
            reserved=reserved_names,
            disambiguator=entry.id,
        )
        claimed_stem = Path(claimed).stem
        reserved_names.add(claimed.lower())
        outtmpl = str(out / f"{claimed_stem}.%(ext)s")

        if log:
            log(f"[{n}/{total}] {label}")
        _overall(n, 0.0, f"Track {n}/{total}: {label}")
        if progress:
            progress("track", 0.0, f"Starting download — {label}")

        def _track_progress(phase: str, frac: float | None, detail: str, _n=n) -> None:
            if progress:
                progress(phase, frac, detail)
            # Map track download frac into overall (0–0.70 of this track slot)
            tf = 0.0 if frac is None else max(0.0, min(1.0, frac)) * 0.70
            _overall(_n, tf, detail)

        try:
            produced: Path | None
            if yt_dlp is not None:
                produced = _download_one_api(
                    yt_dlp, entry, outtmpl, meta, log, progress=_track_progress
                )
            else:
                assert exe
                if progress:
                    progress("track", None, f"Downloading (yt-dlp exe) — {label}")
                produced = _download_one_exe(exe, entry, outtmpl, meta, log)

            if produced is None:
                matches = list(out.glob(f"{claimed_stem}.*"))
                audio_matches = [p for p in matches if p.suffix.lower() != ".lrc"]
                produced = audio_matches[0] if audio_matches else (matches[0] if matches else None)

            lrc_path: Path | None = None
            if produced is not None and produced.exists():
                # Prefer tags even if yt-dlp metadata PP was skipped.
                _embed_tags_ffmpeg(produced, meta, log=log)
                _overall(n, 0.72, f"Track {n}/{total}: tagging — {label}")

                # Lyrics WHILE artist/title are known — write beside current file,
                # then sanitize_media_path renames .lrc in lockstep with the audio.
                if fetch_lyrics:
                    if progress:
                        progress("lyrics", None, f"Fetching lyrics — {label}")
                    _overall(n, 0.75, f"Track {n}/{total}: lyrics — {label}")
                    _status, lrc_path = lyrics_core.fetch_beside(
                        produced,
                        artist=meta.artist,
                        title=meta.title,
                        album=meta.album,
                        delay=lyrics_delay,
                        log=log,
                    )
                    if progress:
                        progress("lyrics", 1.0, f"Lyrics {_status} — {label}")
                    _overall(n, 0.92, f"Track {n}/{total}: lyrics {_status} — {label}")

                cleaned = sanitize_media_path(produced, reserved=reserved_names)
                if cleaned != produced and log:
                    log(f"  renamed → {cleaned.name}")
                produced = cleaned
                if lrc_path is not None:
                    sibling = produced.with_suffix(".lrc")
                    lrc_path = sibling if sibling.exists() else (lrc_path if lrc_path.exists() else None)

                # Prefer final clean title as filename stem (drop 001 - prefix when organizing later)
                final_stem = safe_filename_stem(meta.title)
                if produced.stem != final_stem:
                    target_name = unique_filename(
                        produced.parent,
                        f"{final_stem}{produced.suffix}",
                        reserved=reserved_names,
                        disambiguator=entry.id,
                    )
                    target = produced.parent / target_name
                    if target.resolve() != produced.resolve():
                        old_lrc = produced.with_suffix(".lrc")
                        produced.rename(target)
                        if old_lrc.exists():
                            new_lrc = target.with_suffix(".lrc")
                            if not new_lrc.exists():
                                old_lrc.rename(new_lrc)
                            lrc_path = new_lrc if new_lrc.exists() else lrc_path
                        produced = target
                        if log:
                            log(f"  clean name → {produced.name}")

                downloaded.append(
                    DownloadedTrack(path=produced, meta=meta, entry=entry, lrc=lrc_path)
                )

            if log:
                log(f"  OK → {produced.name if produced else '(done)'}")
            ok_count += 1
            _overall(n, 1.0, f"Track {n}/{total} done — {label}")
            if progress:
                progress("track", 1.0, f"Done — {label}")
        except Exception as e:  # noqa: BLE001
            fail_count += 1
            if log:
                log(f"  FAIL: {e}")
            _overall(n, 1.0, f"Track {n}/{total} failed — {label}")
            if progress:
                progress("track", 1.0, f"Failed — {label}")

    if log:
        log(f"Done. Saved {ok_count}, failed {fail_count}. Folder: {out}")
    if progress:
        progress(
            "overall",
            1.0,
            f"Download complete — saved {ok_count}, failed {fail_count}",
        )

    return ok_count, fail_count, out, downloaded


def download_by_indices(
    url: str,
    indices: Iterable[int],
    out_dir: str | Path,
    *,
    fetch_lyrics: bool = True,
    log: LogFn | None = None,
    should_cancel: CancelFn | None = None,
) -> tuple[int, int, Path, list[DownloadedTrack]]:
    """Convenience: re-list playlist and download by 1-based indices."""
    title, entries = list_playlist(url, log=log)
    wanted = {int(i) for i in indices}
    selected = [e for e in entries if e.index in wanted]
    missing = wanted - {e.index for e in selected}
    if missing and log:
        log(f"Note: indices not in playlist: {sorted(missing)}")
    return download_entries(
        selected,
        out_dir,
        playlist_title=title,
        fetch_lyrics=fetch_lyrics,
        log=log,
        should_cancel=should_cancel,
    )
