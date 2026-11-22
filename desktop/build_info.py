#!/usr/bin/env python3
"""App version + build stamp for update checks.

``BUILD_STAMP`` is rewritten by ``build_exe.bat`` / ``stamp_build.py`` at
packaging time (UTC ``YYYYMMDD-HHMMSS``). Keep ``APP_VERSION`` at ``1.0.0``
while refreshing the same GitHub release tag in place — comparison uses the
stamp (and remote ``build-info.json``), not semver alone.
"""

from __future__ import annotations

APP_VERSION = "1.0.0"
# Overwritten on each official build. Source / unstamped runs use this baseline.
BUILD_STAMP = "20261122-103855"
GITHUB_OWNER = "ProOnlyUNO"
GITHUB_REPO = "CC-Music"
RELEASE_TAG = "v1.0.0"
SETUP_ASSET_NAME = "Setup.exe"
BUILD_INFO_ASSET_NAME = "build-info.json"
