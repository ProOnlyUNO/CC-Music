#!/usr/bin/env python3
"""Shared filename sanitizers for download + convert paths.

Strips trailing YouTube video-ID suffixes like `` [Iu0t538ltTs]`` so jukebox /
library names stay clean. When stripping would collide with an existing name,
appends a short disambiguator only then.
"""

from __future__ import annotations

import re
from pathlib import Path

# Trailing " [11-char YouTube id]" — alnum / _ / - inside square brackets.
YOUTUBE_ID_SUFFIX_RE = re.compile(r"\s*\[([A-Za-z0-9_-]{11})\]\s*$")


def strip_youtube_id_suffix(name: str) -> tuple[str, str | None]:
    """Remove a trailing `` [youtubeId]`` from a stem or basename.

    Returns ``(cleaned_name, stripped_id_or_None)``. Extension is preserved
    when *name* includes one (e.g. ``.mp3`` / ``.dfpwm`` / ``.lrc``).
    """
    if not name:
        return name, None

    path = Path(name)
    # Only treat as extension when it looks like a media/lyrics suffix.
    suffix = path.suffix
    if suffix and suffix.lower() in {
        ".mp3",
        ".m4a",
        ".wav",
        ".flac",
        ".ogg",
        ".opus",
        ".aac",
        ".webm",
        ".wma",
        ".dfpwm",
        ".lrc",
        ".part",
    }:
        stem, ext = path.stem, suffix
    else:
        stem, ext = name, ""

    m = YOUTUBE_ID_SUFFIX_RE.search(stem)
    if not m:
        return name, None

    cleaned = stem[: m.start()].rstrip(" .-")
    if not cleaned:
        cleaned = stem  # never empty the name entirely
        return cleaned + ext, None

    return cleaned + ext, m.group(1)


def _occupied(directory: Path, filename: str, reserved: set[str] | None) -> bool:
    lower = filename.lower()
    if reserved and lower in reserved:
        return True
    return (directory / filename).exists()


def unique_filename(
    directory: Path,
    filename: str,
    *,
    reserved: set[str] | None = None,
    disambiguator: str | None = None,
) -> str:
    """Return *filename* or a unique variant in *directory*.

    If the target already exists (or is in *reserved*), first try appending a
    short `` (xxxx)`` tag from *disambiguator* (e.g. first 4 of a YouTube id).
    Only if that also collides, fall back to `` (2)``, `` (3)``, …
    """
    directory = Path(directory)
    path = Path(filename)
    stem, ext = path.stem, path.suffix

    if not _occupied(directory, filename, reserved):
        return filename

    if disambiguator:
        tag = re.sub(r"[^A-Za-z0-9_-]", "", disambiguator)[:4]
        if tag:
            candidate = f"{stem} ({tag}){ext}"
            if not _occupied(directory, candidate, reserved):
                return candidate

    n = 2
    while True:
        candidate = f"{stem} ({n}){ext}"
        if not _occupied(directory, candidate, reserved):
            return candidate
        n += 1


def sanitize_media_path(
    path: Path,
    *,
    reserved: set[str] | None = None,
) -> Path:
    """Strip a YouTube-ID suffix from *path*'s filename; rename if needed.

    Also renames a sibling ``.lrc`` with the same stem when present.
    Returns the final path (unchanged when nothing to strip / already clean).
    """
    path = Path(path)
    cleaned_name, vid = strip_youtube_id_suffix(path.name)
    if vid is None or cleaned_name == path.name:
        return path

    final_name = unique_filename(
        path.parent,
        cleaned_name,
        reserved=reserved,
        disambiguator=vid,
    )
    dest = path.parent / final_name
    if dest.resolve() == path.resolve():
        return path

    path.rename(dest)

    # Keep lyrics paired with the audio/dfpwm file.
    old_lrc = path.with_suffix(".lrc")
    if old_lrc.exists() and old_lrc.resolve() != dest.resolve():
        new_lrc = dest.with_suffix(".lrc")
        if new_lrc.exists():
            # Extremely unlikely; leave the old .lrc rather than overwrite.
            pass
        else:
            old_lrc.rename(new_lrc)

    if reserved is not None:
        reserved.discard(path.name.lower())
        reserved.add(dest.name.lower())

    return dest


def clean_stem_for_output(stem: str) -> str:
    """Stem used for converter / library output titles (ID suffix removed)."""
    cleaned, _vid = strip_youtube_id_suffix(stem)
    return cleaned
