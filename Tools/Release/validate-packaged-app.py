#!/usr/bin/env python3
"""Keeps a demo or test build from being shipped as the real app.

Every screenshot in this repository is taken from a build launched with a
`DRAWER_` environment flag, and those flags reach into the app's own
preferences. A build that carried one in `LSEnvironment` would open with
somebody else's pinned items on a stranger's Mac, so the packager refuses it.
"""

import pathlib
import plistlib
import re
import sys

BUNDLE_ID = "com.advegaf.drawer"


def marketing_version():
    """The version project.yml declares, so a bump there is the only bump."""
    project = pathlib.Path(__file__).resolve().parents[2] / "project.yml"
    match = re.search(r'MARKETING_VERSION:\s*"([^"]+)"', project.read_text())
    if not match:
        raise ValueError("MARKETING_VERSION missing from project.yml")
    return match.group(1)


def validate(app, mode):
    if mode not in {"preview", "development", "release"}:
        raise ValueError("mode must be preview, development or release")
    with (pathlib.Path(app) / "Contents" / "Info.plist").open("rb") as source:
        info = plistlib.load(source)
    if mode == "preview":
        return
    expected = marketing_version()
    if info.get("CFBundleShortVersionString") != expected:
        raise ValueError(f"usable installer requires app version {expected}")
    identifier = info.get("CFBundleIdentifier", "")
    if identifier != BUNDLE_ID:
        raise ValueError(f"usable installer requires {BUNDLE_ID}, got {identifier!r}")
    environment = info.get("LSEnvironment", {})
    if not isinstance(environment, dict):
        raise ValueError("LSEnvironment must be a dictionary")
    forbidden = sorted(key for key in environment if key.startswith("DRAWER_"))
    if forbidden:
        raise ValueError("usable installer refuses test environment keys: " + ", ".join(forbidden))
    if any("preview" in str(info.get(key, "")).lower() for key in ("CFBundleName", "CFBundleDisplayName")):
        raise ValueError("usable installer refuses preview product names")


if __name__ == "__main__":
    try:
        validate(sys.argv[1], sys.argv[2])
    except (IndexError, OSError, ValueError, plistlib.InvalidFileException) as error:
        print(f"dmg: {error}", file=sys.stderr)
        sys.exit(1)
