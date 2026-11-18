#!/usr/bin/env python3
"""LRCLIB lyrics fetch core (from fetch_lyrics). Public API only — https://lrclib.net"""

from __future__ import annotations

import json
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Iterable

USER_AGENT = "CC-Music-Tools/1.0 (https://lrclib.net/docs; alex-cc-jukebox)"
API_BASE = "https://lrclib.net"
DEFAULT_DELAY = 0.55

SKIP_DIR_NAMES = {
    "sfx",
    "main startup cc",
    "remote cc",
    "z convert",
    ".git",
    "node_modules",
    "__pycache__",
    "lyrics",
    "dfpwm_out",
}

ARTIST_ALIASES: dict[str, list[str]] = {
    "$uicideboy$": ["$uicideboy$", "Suicideboys", "$UICIDEBOY$"],
    "$UICIDEBOY$": ["$uicideboy$", "Suicideboys", "$UICIDEBOY$"],
}

LogFn = Callable[[str], None]


@dataclass
class Track:
    path: Path
    root: Path
    artist: str
    album: str
    title: str
    rel_pack: Path


@dataclass
class Stats:
    scanned: int = 0
    skipped_existing: int = 0
    matched: int = 0
    instrumental: int = 0
    missed: int = 0
    errors: int = 0
    misses: list[str] = field(default_factory=list)


def split_camel(s: str) -> str:
    if " " in s or "_" in s:
        return s
    if not re.search(r"[a-z][A-Z]", s):
        return s
    out = re.sub(r"([a-z])([A-Z])", r"\1 \2", s)
    out = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1 \2", out)
    return out


def clean_title(stem: str) -> str:
    t = stem.strip()
    t = re.sub(r"[\._]+", " ", t)
    t = re.sub(r"^\d{1,3}[\s\-_.]+", "", t)
    t = re.sub(r"\s+LYRICS\s*$", "", t, flags=re.I)
    t = re.sub(r"\s+\(lyrics\)\s*$", "", t, flags=re.I)
    t = split_camel(t)
    t = re.sub(r"\s+", " ", t).strip(" -_.")
    return t or stem.strip()


def parse_meta(dfpwm: Path, root: Path) -> Track | None:
    try:
        rel = dfpwm.relative_to(root)
    except ValueError:
        rel = Path(dfpwm.name)

    parts = list(rel.parts)
    if not parts:
        return None
    if parts and parts[0].lower() == "music":
        parts = parts[1:]
    if not parts:
        return None

    stem = Path(parts[-1]).stem
    title = clean_title(stem)
    dirs = parts[:-1]

    artist, album = "Unknown", "Singles"
    if len(dirs) >= 2:
        artist, album = dirs[-2], dirs[-1]
    elif len(dirs) == 1:
        folder = dirs[0]
        if " - " in folder:
            a, b = folder.split(" - ", 1)
            artist, album = a.strip() or "Unknown", b.strip() or "Singles"
        else:
            artist, album = folder, "Singles"

    if artist.lower() in SKIP_DIR_NAMES:
        return None

    pack_rel = Path(artist) / album / f"{stem}.lrc"
    return Track(
        path=dfpwm,
        root=root,
        artist=artist,
        album=album,
        title=title,
        rel_pack=pack_rel,
    )


def should_skip_dir(name: str) -> bool:
    return name.lower() in SKIP_DIR_NAMES


def iter_dfpwm(roots: Iterable[Path]) -> list[Track]:
    tracks: list[Track] = []
    seen: set[Path] = set()
    for root in roots:
        root = root.resolve()
        if not root.is_dir():
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if not should_skip_dir(d) and not d.startswith(".")]
            for name in filenames:
                if not name.lower().endswith(".dfpwm"):
                    continue
                p = Path(dirpath) / name
                key = p.resolve()
                if key in seen:
                    continue
                seen.add(key)
                meta = parse_meta(p, root)
                if meta:
                    tracks.append(meta)
    tracks.sort(key=lambda t: (t.artist.lower(), t.album.lower(), t.title.lower(), str(t.path)))
    return tracks


def http_json(url: str, retries: int = 4) -> tuple[int, object | None]:
    for attempt in range(retries):
        req = urllib.request.Request(
            url,
            headers={"User-Agent": USER_AGENT, "Accept": "application/json"},
            method="GET",
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                body = resp.read().decode("utf-8", errors="replace")
                status = getattr(resp, "status", 200) or 200
                if not body:
                    return status, None
                return status, json.loads(body)
        except urllib.error.HTTPError as e:
            status = e.code
            retry_after = e.headers.get("Retry-After") if e.headers else None
            if status in (429, 503):
                wait = float(retry_after) if retry_after else (2**attempt)
                wait = wait * (1.0 + 0.15 * attempt)
                time.sleep(wait)
                continue
            if status == 404:
                return 404, None
            return status, None
        except Exception:
            time.sleep(1.0 + attempt)
    return 0, None


def pick_best(records: list[dict], artist: str, title: str, album: str) -> dict | None:
    if not records:
        return None
    al = artist.lower()
    tl = title.lower()
    abl = album.lower()

    def score(r: dict) -> tuple:
        ra = (r.get("artistName") or "").lower()
        rt = (r.get("trackName") or r.get("name") or "").lower()
        rb = (r.get("albumName") or "").lower()
        synced = 1 if r.get("syncedLyrics") else 0
        plain = 1 if r.get("plainLyrics") else 0
        instr = 1 if r.get("instrumental") else 0
        artist_eq = 1 if ra == al or al in ra or ra in al else 0
        title_eq = 1 if rt == tl else (1 if tl in rt or rt in tl else 0)
        album_eq = 1 if abl and (rb == abl or abl in rb) else 0
        return (synced, plain, artist_eq, title_eq, album_eq, -instr)

    ranked = sorted(records, key=score, reverse=True)
    best = ranked[0]
    if best.get("instrumental") and not best.get("syncedLyrics") and not best.get("plainLyrics"):
        return best
    if not best.get("syncedLyrics") and not best.get("plainLyrics") and not best.get("instrumental"):
        for r in ranked:
            if r.get("syncedLyrics") or r.get("plainLyrics") or r.get("instrumental"):
                return r
    return best


def artist_queries(artist: str) -> list[str]:
    aliases = ARTIST_ALIASES.get(artist) or ARTIST_ALIASES.get(artist.lower())
    if aliases:
        out: list[str] = []
        for a in aliases:
            if a not in out:
                out.append(a)
        if artist not in out:
            out.insert(0, artist)
        return out
    return [artist]


def fetch_lyrics(artist: str, title: str, album: str, delay: float) -> tuple[str | None, str]:
    for a in artist_queries(artist):
        q = urllib.parse.urlencode(
            {"artist_name": a, "track_name": title, "album_name": album}
        )
        status, data = http_json(f"{API_BASE}/api/search?{q}")
        time.sleep(delay)
        if status == 0:
            return None, "error"
        if isinstance(data, list) and data:
            best = pick_best(data, a, title, album)
            if best:
                if best.get("instrumental") and not best.get("syncedLyrics"):
                    return None, "instrumental"
                synced = best.get("syncedLyrics")
                if isinstance(synced, str) and synced.strip():
                    return synced.strip() + "\n", "matched"
                plain = best.get("plainLyrics")
                if isinstance(plain, str) and plain.strip():
                    lines = ["[00:00.00] " + ln for ln in plain.strip().splitlines() if ln.strip()]
                    return ("\n".join(lines) + "\n") if lines else None, "matched" if lines else "miss"

    q = urllib.parse.urlencode({"q": f"{artist} {title}"})
    status, data = http_json(f"{API_BASE}/api/search?{q}")
    time.sleep(delay)
    if isinstance(data, list) and data:
        best = pick_best(data, artist, title, album)
        if best:
            if best.get("instrumental") and not best.get("syncedLyrics"):
                return None, "instrumental"
            synced = best.get("syncedLyrics")
            if isinstance(synced, str) and synced.strip():
                return synced.strip() + "\n", "matched"
            plain = best.get("plainLyrics")
            if isinstance(plain, str) and plain.strip():
                lines = ["[00:00.00] " + ln for ln in plain.strip().splitlines() if ln.strip()]
                return ("\n".join(lines) + "\n") if lines else None, "matched" if lines else "miss"

    return None, "miss"


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8", newline="\n")


def run_fetch(
    roots: list[str | Path],
    *,
    pack_dir: str | Path,
    report_path: str | Path | None = None,
    delay: float = DEFAULT_DELAY,
    dry_run: bool = False,
    log: LogFn | None = None,
    should_cancel: Callable[[], bool] | None = None,
) -> dict:
    def _log(msg: str) -> None:
        if log:
            log(msg)

    root_paths = [Path(r) for r in roots]
    root_paths = [r for r in root_paths if r.is_dir()]
    if not root_paths:
        raise RuntimeError("No valid music folder selected.")

    _log("Roots:")
    for r in root_paths:
        _log(f"  - {r}")

    tracks = iter_dfpwm(root_paths)
    _log(f"Tracks to consider: {len(tracks)}")
    if not tracks:
        raise RuntimeError("No .dfpwm files found under the selected folder.")

    pack_root = Path(pack_dir).resolve()
    lyrics_pack = pack_root / "lyrics"
    stats = Stats(scanned=len(tracks))
    delay = max(0.2, float(delay))

    for i, t in enumerate(tracks, 1):
        if should_cancel and should_cancel():
            _log("Cancelled.")
            break

        beside = t.path.with_suffix(".lrc")
        pack_path = lyrics_pack / t.rel_pack

        if beside.is_file() and beside.stat().st_size > 0:
            stats.skipped_existing += 1
            if not dry_run and (not pack_path.is_file() or pack_path.stat().st_size == 0):
                write_text(pack_path, beside.read_text(encoding="utf-8", errors="replace"))
            if i % 25 == 0 or i == len(tracks):
                _log(f"[{i}/{len(tracks)}] skip existing …")
            continue

        _log(f"[{i}/{len(tracks)}] {t.artist} / {t.album} / {t.title}")
        if dry_run:
            continue

        text, status = fetch_lyrics(t.artist, t.title, t.album, delay)
        if status == "matched" and text:
            write_text(beside, text)
            write_text(pack_path, text)
            stats.matched += 1
            _log("  → matched")
        elif status == "instrumental":
            stats.instrumental += 1
            marker = "; instrumental (lrclib)\n"
            write_text(beside, marker)
            write_text(pack_path, marker)
            _log("  → instrumental")
        elif status == "error":
            stats.errors += 1
            stats.misses.append(f"ERROR\t{t.artist}\t{t.album}\t{t.title}\t{t.path}")
            _log("  → error")
        else:
            stats.missed += 1
            stats.misses.append(f"MISS\t{t.artist}\t{t.album}\t{t.title}\t{t.path}")
            _log("  → miss")

    if report_path is None:
        report_path = pack_root / "fetch-report.txt"
    else:
        report_path = Path(report_path)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        "CC Music Tools — Lyrics Fetch Report",
        f"time: {time.strftime('%Y-%m-%d %H:%M:%S')}",
        f"roots: {', '.join(str(r) for r in root_paths)}",
        f"pack: {lyrics_pack}",
        f"scanned: {stats.scanned}",
        f"skipped_existing: {stats.skipped_existing}",
        f"matched: {stats.matched}",
        f"instrumental: {stats.instrumental}",
        f"missed: {stats.missed}",
        f"errors: {stats.errors}",
        "",
        "Misses / errors:",
        *stats.misses,
        "",
    ]
    if not dry_run:
        report_path.write_text("\n".join(lines), encoding="utf-8")
        miss_log = pack_root / "misses.log"
        miss_log.write_text(
            "\n".join(stats.misses) + ("\n" if stats.misses else ""), encoding="utf-8"
        )

    _log("")
    _log("=== Summary ===")
    _log(f"Scanned       : {stats.scanned}")
    _log(f"Skipped (.lrc): {stats.skipped_existing}")
    _log(f"Matched       : {stats.matched}")
    _log(f"Instrumental  : {stats.instrumental}")
    _log(f"Missed        : {stats.missed}")
    _log(f"Errors        : {stats.errors}")
    _log(f"Pack          : {lyrics_pack}")
    if not dry_run:
        _log(f"Report        : {report_path}")

    return {
        "scanned": stats.scanned,
        "matched": stats.matched,
        "missed": stats.missed,
        "pack": str(lyrics_pack),
        "report": str(report_path),
    }
