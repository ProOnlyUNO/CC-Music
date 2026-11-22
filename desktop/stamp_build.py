#!/usr/bin/env python3
"""Rewrite build_info.BUILD_STAMP and emit build-info.json for the release."""

from __future__ import annotations

import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
BUILD_INFO_PY = HERE / "build_info.py"
BUILD_INFO_JSON = HERE / "build-info.json"


def utc_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")


def stamp(stamp_value: str | None = None) -> str:
    value = stamp_value or utc_stamp()
    text = BUILD_INFO_PY.read_text(encoding="utf-8")
    new_text, n = re.subn(
        r'^BUILD_STAMP = ".*"$',
        f'BUILD_STAMP = "{value}"',
        text,
        count=1,
        flags=re.M,
    )
    if n != 1:
        raise SystemExit("Could not rewrite BUILD_STAMP in build_info.py")
    BUILD_INFO_PY.write_text(new_text, encoding="utf-8", newline="\n")

    # Import after rewrite for consistent JSON fields
    sys.path.insert(0, str(HERE))
    import build_info  # noqa: E402

    # Reload in case module was cached
    import importlib

    importlib.reload(build_info)

    payload = {
        "version": build_info.APP_VERSION,
        "build": value,
        "tag": build_info.RELEASE_TAG,
        "repo": f"{build_info.GITHUB_OWNER}/{build_info.GITHUB_REPO}",
        "setup": build_info.SETUP_ASSET_NAME,
    }
    BUILD_INFO_JSON.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    print(f"BUILD_STAMP={value}")
    print(f"Wrote {BUILD_INFO_JSON.name}")
    return value


if __name__ == "__main__":
    arg = sys.argv[1] if len(sys.argv) > 1 else None
    stamp(arg)
