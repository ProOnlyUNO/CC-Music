#!/usr/bin/env python3
"""Artist / album / title inference for download organize + lyrics.

Used while playlist metadata is still known (before clean rename) and when
laying out Artist/Album/Song trees after download or convert.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

from name_sanitize import clean_stem_for_output

ILLEGAL_RE = re.compile(r'[<>:"/\\|?*\x00-\x1f]')
SPLIT_RE = re.compile(r"\s+[-\u2013\u2014|]\s+")
CHANNEL_RE = re.compile(r"\s*\b(?:official|vevo|topic)\s*$", re.I)
INDEX_PREFIX_RE = re.compile(r"^\d{1,3}\s*[-.)]\s*")


@dataclass
class TrackMeta:
    artist: str
    album: str
    title: str


def safe_folder(name: str, fallback: str = "Unknown") -> str:
    name = ILLEGAL_RE.sub("", (name or "").strip())
    name = re.sub(r"\s+", " ", name).strip(" .-")
    name = (name or fallback)[:100].rstrip(" .-")
    return name or fallback


def safe_filename_stem(name: str, fallback: str = "track") -> str:
    return safe_folder(name, fallback=fallback)


def _clean_title_token(s: str) -> str:
    s = clean_stem_for_output((s or "").strip())
    s = INDEX_PREFIX_RE.sub("", s)
    s = re.sub(r"\s+", " ", s).strip(" -_.")
    return s


def parse_artist_title(raw_title: str, uploader: str | None = None) -> tuple[str | None, str]:
    """Split ``Artist - Title`` (or Title alone) from a YouTube / file title."""
    s = _clean_title_token(raw_title)
    if not s:
        return None, "Untitled"

    tokens = [t.strip() for t in SPLIT_RE.split(s) if t.strip()]
    channel = None
    if uploader:
        channel = CHANNEL_RE.sub("", uploader).strip() or uploader.strip()

    if len(tokens) >= 3 and tokens[-1].lower() == "topic":
        channel = tokens[-2]
        tokens = tokens[:-2]
    elif len(tokens) >= 2 and CHANNEL_RE.search(tokens[-1]):
        channel = CHANNEL_RE.sub("", tokens[-1]).strip() or channel
        tokens = tokens[:-1]

    if tokens and re.fullmatch(r"\d{1,3}", tokens[0]) and len(tokens) > 1:
        tokens = tokens[1:]

    if len(tokens) >= 2:
        return tokens[0], " - ".join(tokens[1:])
    if tokens:
        return channel, tokens[0]
    return channel, "Untitled"


def parse_playlist_album(playlist_title: str | None) -> tuple[str | None, str | None]:
    """Infer (artist, album) from a playlist / album title when possible."""
    if not playlist_title:
        return None, None
    s = re.sub(r"\s+", " ", playlist_title.strip())
    # Drop common YouTube Music / Album suffixes
    s = re.sub(r"\s*[-–—|]\s*Album\s*$", "", s, flags=re.I)
    s = re.sub(r"\s*\(Full Album\)\s*$", "", s, flags=re.I)
    s = re.sub(r"\s*\[Full Album\]\s*$", "", s, flags=re.I)
    if " - " in s:
        a, b = s.split(" - ", 1)
        a, b = a.strip(), b.strip()
        if a and b:
            return a, b
    if s:
        return None, s
    return None, None


def resolve_track_meta(
    *,
    title: str,
    uploader: str | None = None,
    playlist_title: str | None = None,
    artist_hint: str | None = None,
    album_hint: str | None = None,
    track_title_hint: str | None = None,
) -> TrackMeta:
    """Best-effort artist / album / title for lyrics + folder layout."""
    parsed_artist, parsed_title = parse_artist_title(title, uploader)
    pl_artist, pl_album = parse_playlist_album(playlist_title)

    artist = (
        (artist_hint or "").strip()
        or (parsed_artist or "").strip()
        or (pl_artist or "").strip()
        or (uploader or "").strip()
        or "Unknown"
    )
    # Topic channels → strip trailing " - Topic"
    artist = re.sub(r"\s*-\s*Topic\s*$", "", artist, flags=re.I).strip() or "Unknown"

    title_out = (
        (track_title_hint or "").strip()
        or parsed_title
        or _clean_title_token(title)
        or "Untitled"
    )

    album = (
        (album_hint or "").strip()
        or (pl_album or "").strip()
        or "Singles"
    )
    # If playlist title was the only album and equals the track title, treat as Singles
    if album.lower() == title_out.lower():
        album = "Singles"

    return TrackMeta(
        artist=safe_folder(artist, "Unknown"),
        album=safe_folder(album, "Singles"),
        title=safe_filename_stem(title_out, "Untitled"),
    )


def meta_from_path(path: Path, library_root: Path | None = None) -> TrackMeta:
    """Infer meta from Artist/Album/Song.ext layout or filename."""
    path = Path(path)
    stem = _clean_title_token(path.stem) or "Untitled"
    artist, album = "Unknown", "Singles"

    parts = list(path.parent.parts)
    if library_root is not None:
        try:
            rel = path.parent.resolve().relative_to(Path(library_root).resolve())
            parts = list(rel.parts)
        except ValueError:
            parts = list(path.parent.parts[-2:]) if len(path.parent.parts) >= 2 else list(path.parent.parts)

    if len(parts) >= 2:
        artist, album = parts[-2], parts[-1]
    elif len(parts) == 1:
        folder = parts[0]
        if " - " in folder:
            a, b = folder.split(" - ", 1)
            artist, album = a.strip() or "Unknown", b.strip() or "Singles"
        else:
            artist, album = folder, "Singles"

    parsed_artist, parsed_title = parse_artist_title(stem)
    if artist.lower() in {"unknown", "unsorted", "."} and parsed_artist:
        artist = parsed_artist
    title = parsed_title if parsed_artist else stem

    return TrackMeta(
        artist=safe_folder(artist, "Unknown"),
        album=safe_folder(album, "Singles"),
        title=safe_filename_stem(title, "Untitled"),
    )


def artist_album_dest(
    root: Path,
    meta: TrackMeta,
    ext: str,
    *,
    reserved: set[str] | None = None,
) -> Path:
    """Return ``root/Artist/Album/Title.ext`` with collision-safe filename."""
    from name_sanitize import unique_filename

    root = Path(root)
    folder = root / meta.artist / meta.album
    folder.mkdir(parents=True, exist_ok=True)
    name = unique_filename(
        folder,
        f"{meta.title}{ext if ext.startswith('.') else '.' + ext}",
        reserved=reserved,
    )
    if reserved is not None:
        reserved.add(name.lower())
    return folder / name
