#!/usr/bin/env python3
"""Genius.com album search + tracklist fetch (no API key).

Album pages expose ``window.__PRELOADED_STATE__`` with ``albumAppearances``.
Album search uses Genius's public ``/api/search/album`` JSON endpoint.
"""

from __future__ import annotations

import json
import re
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any, Callable

LogFn = Callable[[str], None]
ProgressFn = Callable[[str, float | None, str], None]

USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 CC-Music-Tools/1.0"
)

ALBUM_URL_RE = re.compile(
    r"^https?://(?:www\.)?genius\.com/albums/([^/?#]+)/([^/?#]+)/?(?:[?#].*)?$",
    re.I,
)
GENIUS_HOST_RE = re.compile(r"^https?://(?:www\.)?genius\.com/", re.I)


@dataclass
class GeniusAlbumHit:
    id: str
    name: str
    artist: str
    url: str
    full_title: str = ""


@dataclass
class GeniusTrack:
    index: int  # 1-based track number when known
    id: str
    title: str
    artist: str
    album: str
    url: str = ""
    disc_number: int | None = None


@dataclass
class GeniusAlbum:
    id: str
    name: str
    artist: str
    url: str
    tracks: list[GeniusTrack]


def is_genius_album_url(url: str) -> bool:
    return bool(ALBUM_URL_RE.match((url or "").strip()))


def is_genius_url(url: str) -> bool:
    return bool(GENIUS_HOST_RE.match((url or "").strip()))


def normalize_album_url(url: str) -> str:
    """Return a canonical ``https://genius.com/albums/.../...`` URL."""
    raw = (url or "").strip()
    m = ALBUM_URL_RE.match(raw)
    if not m:
        raise ValueError(
            "Paste a Genius album URL like:\n"
            "  https://genius.com/albums/Artist-name/Album-name"
        )
    artist_slug, album_slug = m.group(1), m.group(2)
    return f"https://genius.com/albums/{artist_slug}/{album_slug}"


def _http_get(url: str, *, accept: str = "text/html,application/xhtml+xml,*/*") -> str:
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": USER_AGENT,
            "Accept": accept,
            "Accept-Language": "en-US,en;q=0.9",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=45) as resp:
            charset = resp.headers.get_content_charset() or "utf-8"
            return resp.read().decode(charset, "replace")
    except urllib.error.HTTPError as e:
        body = ""
        try:
            body = e.read().decode("utf-8", "replace")[:200]
        except Exception:  # noqa: BLE001
            pass
        raise RuntimeError(f"Genius HTTP {e.code} for {url}: {body or e.reason}") from e
    except urllib.error.URLError as e:
        raise RuntimeError(f"Could not reach Genius: {e.reason}") from e


_JS_ESCAPE_RE = re.compile(r"\\u([0-9a-fA-F]{4})|\\(.)")


def _decode_js_string(content: str) -> str:
    """Decode a JS string body (Genius wraps JSON in JSON.parse('…'))."""

    def repl(m: re.Match[str]) -> str:
        if m.group(1):
            return chr(int(m.group(1), 16))
        ch = m.group(2)
        return {
            "n": "\n",
            "r": "\r",
            "t": "\t",
            '"': '"',
            "'": "'",
            "\\": "\\",
            "/": "/",
        }.get(ch, ch)

    return _JS_ESCAPE_RE.sub(repl, content)


def parse_preloaded_state(html: str) -> dict[str, Any]:
    m = re.search(
        r"window\.__PRELOADED_STATE__\s*=\s*JSON\.parse\(\s*(['\"])",
        html,
    )
    if not m:
        raise RuntimeError("Genius page had no __PRELOADED_STATE__ (layout changed?).")
    quote = m.group(1)
    start = m.end()
    parts: list[str] = []
    i = start
    while i < len(html):
        ch = html[i]
        if ch == "\\" and i + 1 < len(html):
            parts.append(html[i : i + 2])
            i += 2
            continue
        if ch == quote:
            break
        parts.append(ch)
        i += 1
    else:
        raise RuntimeError("Genius __PRELOADED_STATE__ string was truncated.")
    decoded = _decode_js_string("".join(parts))
    data = json.loads(decoded)
    if not isinstance(data, dict):
        raise RuntimeError("Genius __PRELOADED_STATE__ was not an object.")
    return data


def _artist_name(obj: Any, fallback: str = "Unknown") -> str:
    if isinstance(obj, dict):
        name = (obj.get("name") or obj.get("primary_artist_names") or "").strip()
        if name:
            return name
    if isinstance(obj, str) and obj.strip():
        return obj.strip()
    return fallback


def _tracks_from_appearances(
    appearances: list[Any],
    *,
    album_name: str,
    album_artist: str,
) -> list[GeniusTrack]:
    tracks: list[GeniusTrack] = []
    for i, raw in enumerate(appearances or [], start=1):
        if not isinstance(raw, dict):
            continue
        song = raw.get("song")
        if not isinstance(song, dict):
            continue
        title = str(song.get("title") or "").strip()
        if not title:
            continue
        sid = str(song.get("id") or "").strip() or f"idx-{i}"
        artist = (
            str(song.get("primaryArtistNames") or song.get("artistNames") or "").strip()
            or _artist_name(song.get("primaryArtist"), album_artist)
        )
        track_no = raw.get("trackNumber") or raw.get("discTrackNumber") or i
        try:
            index = int(track_no)
        except (TypeError, ValueError):
            index = i
        disc = raw.get("discNumber")
        try:
            disc_i = int(disc) if disc is not None else None
        except (TypeError, ValueError):
            disc_i = None
        url = str(song.get("url") or "").strip()
        tracks.append(
            GeniusTrack(
                index=max(1, index),
                id=sid,
                title=title,
                artist=artist or album_artist,
                album=album_name,
                url=url,
                disc_number=disc_i,
            )
        )
    # Stable order by disc then track number
    tracks.sort(key=lambda t: (t.disc_number or 1, t.index, t.title.lower()))
    # Re-number display index 1..N while keeping Genius track numbers in id label via title
    for n, t in enumerate(tracks, start=1):
        t.index = n
    return tracks


def fetch_album(
    url: str,
    *,
    log: LogFn | None = None,
    progress: ProgressFn | None = None,
) -> GeniusAlbum:
    """Fetch a Genius album page and return artist/album + ordered tracks."""
    album_url = normalize_album_url(url)
    if progress:
        progress("genius", None, "Fetching Genius album…")
    if log:
        log(f"Genius album: {album_url}")

    html = _http_get(album_url)
    state = parse_preloaded_state(html)
    islands = state.get("islands")
    if not isinstance(islands, dict):
        raise RuntimeError("Genius album page missing islands data.")

    album_obj = islands.get("album")
    if not isinstance(album_obj, dict):
        raise RuntimeError("Genius album page missing album metadata.")

    album_name = str(album_obj.get("name") or album_obj.get("fullTitle") or "Album").strip()
    # fullTitle often "Name by Artist" — prefer bare name
    if " by " in album_name and album_obj.get("name"):
        album_name = str(album_obj.get("name")).strip()
    album_artist = _artist_name(album_obj.get("artist"), "Unknown")
    album_id = str(album_obj.get("id") or "").strip()
    page_url = str(album_obj.get("url") or album_url).strip() or album_url

    appearances = islands.get("albumAppearances") or []
    if not isinstance(appearances, list):
        appearances = []
    tracks = _tracks_from_appearances(
        appearances, album_name=album_name, album_artist=album_artist
    )
    if not tracks:
        raise RuntimeError("Genius album had no tracks in the tracklist.")

    if log:
        log(f"  {album_artist} — {album_name}: {len(tracks)} track(s)")
    if progress:
        progress("genius", 1.0, f"Loaded {len(tracks)} Genius track(s)")

    return GeniusAlbum(
        id=album_id or page_url,
        name=album_name,
        artist=album_artist,
        url=page_url,
        tracks=tracks,
    )


def search_albums(
    query: str,
    *,
    limit: int = 8,
    log: LogFn | None = None,
    progress: ProgressFn | None = None,
) -> list[GeniusAlbumHit]:
    """Search Genius albums via the public search JSON API."""
    q = (query or "").strip()
    if not q:
        raise ValueError("Type an album or artist name to search Genius.")

    limit = max(1, min(25, int(limit)))
    if progress:
        progress("genius", None, f"Searching Genius for “{q}”…")
    if log:
        log(f"Genius album search: {q!r}")

    api = (
        "https://genius.com/api/search/album?q="
        + urllib.parse.quote_plus(q)
        + f"&per_page={limit}"
    )
    body = _http_get(api, accept="application/json,text/javascript,*/*")
    try:
        payload = json.loads(body)
    except json.JSONDecodeError as e:
        raise RuntimeError("Genius search returned non-JSON.") from e

    sections = (payload.get("response") or {}).get("sections") or []
    hits: list[GeniusAlbumHit] = []
    seen: set[str] = set()
    for sec in sections:
        if not isinstance(sec, dict):
            continue
        if str(sec.get("type") or "") not in ("album", "top_hit"):
            continue
        for hit in sec.get("hits") or []:
            if not isinstance(hit, dict):
                continue
            result = hit.get("result")
            if not isinstance(result, dict):
                continue
            # top_hit can mix types
            rtype = str(result.get("_type") or result.get("type") or "album").lower()
            if rtype not in ("album", ""):
                # empty type on dedicated album endpoint is fine
                if sec.get("type") != "album" and "albums/" not in str(result.get("url") or ""):
                    continue
            url = str(result.get("url") or "").strip()
            if not url or not is_genius_album_url(url):
                continue
            url = normalize_album_url(url)
            if url in seen:
                continue
            seen.add(url)
            artist = _artist_name(result.get("artist"), "")
            if not artist:
                artist = str(result.get("primary_artist_names") or "").strip()
            name = str(result.get("name") or "").strip()
            full = str(result.get("full_title") or result.get("name_with_artist") or "").strip()
            if not name and full:
                name = full.split(" by ")[0].strip() or full
            hits.append(
                GeniusAlbumHit(
                    id=str(result.get("id") or url),
                    name=name or "Album",
                    artist=artist or "Unknown",
                    url=url,
                    full_title=full or f"{name} by {artist}",
                )
            )
            if len(hits) >= limit:
                break
        if len(hits) >= limit:
            break

    if progress:
        progress("genius", 1.0, f"Found {len(hits)} Genius album(s)")
    if log:
        log(f"  Genius albums: {len(hits)}")
    if not hits:
        raise RuntimeError(f"No Genius albums for “{q}”. Try another query.")
    return hits
