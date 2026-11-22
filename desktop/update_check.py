#!/usr/bin/env python3
"""Quiet GitHub release update check for CC Music Tools.

Compares the embedded ``BUILD_STAMP`` to remote ``build-info.json`` on the
v1.0.0 / latest release (semver tag stays 1.0.0 while Setup.exe is refreshed
in place). Falls back to Setup.exe ``updated_at`` only when build-info is
missing.
"""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable

import build_info

LogFn = Callable[[str], None]

API_TIMEOUT = 6.0
DOWNLOAD_TIMEOUT = 120.0
USER_AGENT = f"CC-Music-Tools/{build_info.APP_VERSION} (+https://github.com/{build_info.GITHUB_OWNER}/{build_info.GITHUB_REPO})"
RELEASE_PAGE = (
    f"https://github.com/{build_info.GITHUB_OWNER}/{build_info.GITHUB_REPO}"
    f"/releases/tag/{build_info.RELEASE_TAG}"
)


@dataclass
class UpdateInfo:
    local_build: str
    remote_build: str
    setup_url: str
    release_name: str
    release_tag: str
    source: str  # "build-info" | "asset-updated-at"


def _prefs_path(app_dir: Path) -> Path:
    return Path(app_dir) / "update_prefs.json"


def load_skipped_build(app_dir: Path) -> str | None:
    path = _prefs_path(app_dir)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        skipped = data.get("skipped_build")
        return str(skipped) if skipped else None
    except (OSError, ValueError, TypeError):
        return None


def save_skipped_build(app_dir: Path, build: str) -> None:
    path = _prefs_path(app_dir)
    try:
        path.write_text(
            json.dumps({"skipped_build": build}, indent=2) + "\n",
            encoding="utf-8",
        )
    except OSError:
        pass


def _http_json(url: str, timeout: float = API_TIMEOUT) -> object | None:
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": USER_AGENT,
            "Accept": "application/vnd.github+json",
        },
        method="GET",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            return json.loads(raw) if raw else None
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, ValueError, OSError):
        return None


def _http_bytes(url: str, timeout: float = DOWNLOAD_TIMEOUT) -> bytes | None:
    req = urllib.request.Request(
        url,
        headers={"User-Agent": USER_AGENT, "Accept": "application/octet-stream"},
        method="GET",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.read()
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError):
        return None


def _fetch_release() -> dict | None:
    owner = build_info.GITHUB_OWNER
    repo = build_info.GITHUB_REPO
    tag = build_info.RELEASE_TAG
    # Prefer the pinned first-release tag (refreshed in place), then latest.
    for url in (
        f"https://api.github.com/repos/{owner}/{repo}/releases/tags/{tag}",
        f"https://api.github.com/repos/{owner}/{repo}/releases/latest",
    ):
        data = _http_json(url)
        if isinstance(data, dict) and data.get("assets"):
            return data
    return None


def _asset(release: dict, name: str) -> dict | None:
    for asset in release.get("assets") or []:
        if isinstance(asset, dict) and str(asset.get("name") or "") == name:
            return asset
    return None


def _parse_github_time(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        # GitHub: 2026-11-22T08:30:11Z
        return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)
    except ValueError:
        return None


def _stamp_from_datetime(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y%m%d-%H%M%S")


def _is_newer(remote: str, local: str) -> bool:
    """Lexicographic compare works for YYYYMMDD-HHMMSS stamps."""
    return bool(remote) and bool(local) and remote > local


def check_for_update(
    *,
    app_dir: Path | None = None,
    log: LogFn | None = None,
) -> UpdateInfo | None:
    """Return UpdateInfo when a newer build is available; else None.

    Never raises — offline / timeout / API errors → None.
    """
    local = build_info.BUILD_STAMP
    if log:
        log(f"Update check: local build {local} (v{build_info.APP_VERSION})")

    release = _fetch_release()
    if not release:
        if log:
            log("Update check: no release metadata (offline or timeout).")
        return None

    tag = str(release.get("tag_name") or build_info.RELEASE_TAG)
    name = str(release.get("name") or tag)
    setup = _asset(release, build_info.SETUP_ASSET_NAME)
    if not setup or not setup.get("browser_download_url"):
        if log:
            log("Update check: Setup.exe asset missing on release.")
        return None
    setup_url = str(setup["browser_download_url"])

    remote_build = ""
    source = "build-info"
    info_asset = _asset(release, build_info.BUILD_INFO_ASSET_NAME)
    if info_asset and info_asset.get("browser_download_url"):
        raw = _http_bytes(str(info_asset["browser_download_url"]), timeout=API_TIMEOUT)
        if raw:
            try:
                payload = json.loads(raw.decode("utf-8"))
                remote_build = str(payload.get("build") or "").strip()
            except (ValueError, TypeError):
                remote_build = ""

    if not remote_build:
        # Fallback: Setup.exe uploaded_at / updated_at as a stamp.
        # Less precise after install (may re-prompt until build-info exists).
        dt = _parse_github_time(str(setup.get("updated_at") or setup.get("created_at") or ""))
        if dt:
            remote_build = _stamp_from_datetime(dt)
            source = "asset-updated-at"

    if not remote_build:
        if log:
            log("Update check: could not determine remote build stamp.")
        return None

    if log:
        log(f"Update check: remote build {remote_build} ({source}, {tag})")

    if not _is_newer(remote_build, local):
        return None

    if app_dir is not None:
        skipped = load_skipped_build(app_dir)
        if skipped and skipped == remote_build:
            if log:
                log(f"Update check: skipped build {remote_build} (Later).")
            return None

    return UpdateInfo(
        local_build=local,
        remote_build=remote_build,
        setup_url=setup_url,
        release_name=name,
        release_tag=tag,
        source=source,
    )


def download_setup(url: str, dest: Path, log: LogFn | None = None) -> Path | None:
    if log:
        log(f"Downloading update → {dest.name}")
    data = _http_bytes(url, timeout=DOWNLOAD_TIMEOUT)
    if not data or len(data) < 1_000_000:
        if log:
            log("Download failed or file too small.")
        return None
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(dest.suffix + ".part")
    try:
        tmp.write_bytes(data)
        if dest.exists():
            dest.unlink()
        tmp.replace(dest)
    except OSError as e:
        if log:
            log(f"Could not save Setup.exe: {e}")
        if tmp.exists():
            try:
                tmp.unlink()
            except OSError:
                pass
        return None
    if log:
        log(f"Saved {dest} ({len(data)} bytes)")
    return dest


def run_setup(setup_path: Path, log: LogFn | None = None) -> bool:
    setup_path = Path(setup_path)
    if not setup_path.is_file():
        return False
    try:
        if log:
            log(f"Launching installer: {setup_path}")
        # Detach so the app can quit while Setup runs.
        kwargs: dict = {}
        if os.name == "nt":
            kwargs["creationflags"] = subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP  # type: ignore[attr-defined]
        subprocess.Popen([str(setup_path)], cwd=str(setup_path.parent), close_fds=True, **kwargs)
        return True
    except OSError as e:
        if log:
            log(f"Could not launch Setup.exe: {e}")
        return False


def open_release_page(log: LogFn | None = None) -> None:
    try:
        if os.name == "nt":
            os.startfile(RELEASE_PAGE)  # type: ignore[attr-defined]
        else:
            subprocess.Popen(["xdg-open", RELEASE_PAGE])
        if log:
            log(f"Opened {RELEASE_PAGE}")
    except OSError as e:
        if log:
            log(f"Could not open release page: {e}")


def download_and_run_update(info: UpdateInfo, *, log: LogFn | None = None) -> bool:
    """Download Setup.exe to a temp folder and launch it. Returns True if launched."""
    dest_dir = Path(tempfile.gettempdir()) / "CC-Music-Tools-Update"
    dest = dest_dir / build_info.SETUP_ASSET_NAME
    path = download_setup(info.setup_url, dest, log=log)
    if path is None:
        open_release_page(log=log)
        return False
    if run_setup(path, log=log):
        return True
    open_release_page(log=log)
    return False
