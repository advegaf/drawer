#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

NAME="$1"
shift

BUILT_PRODUCTS_DIR=$(xcodebuild -project Drawer.xcodeproj -scheme Drawer -configuration Debug \
    -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR =/ {print $3}')
BIN="$BUILT_PRODUCTS_DIR/Drawer.app/Contents/MacOS/Drawer"

if [ ! -d "$BUILT_PRODUCTS_DIR/Drawer.app" ]; then
    make build
fi

pkill -x Drawer || true

# DRAWER_SHOT_WINDOW=settings in ENV picks the Settings window instead of
# window-id.swift's default, which prefers the status bar layer: that is
# the notch panel, still on screen behind Settings during these
# screenshots, and would otherwise win even though it is not the one being
# captured. Settings is picked by *not* being on that layer, not by title:
# its title bar tracks the selected sidebar page (Items, Appearance,
# General), never the literal string "Drawer Settings".
WINDOW_NAME=""
for arg in "$@"; do
    if [ "$arg" = "DRAWER_SHOT_WINDOW=settings" ]; then
        WINDOW_NAME="settings"
    fi
done

# Redirected away from this script's own stdout/stderr: left inherited, the
# backgrounded app keeps that file descriptor open for as long as it keeps
# running, which is normally invisible at an interactive prompt but hangs a
# caller that reads this script's output by waiting for it to close (a pipe
# such as `| tail`, or a harness that captures output the same way).
env "$@" "$BIN" > /dev/null 2>&1 &

sleep 4

mkdir -p docs/qa/evidence
OUT="docs/qa/evidence/$NAME.png"

if [ "$WINDOW_NAME" = "settings" ]; then
    # window-shot.swift rather than a window id and a bare screencapture:
    # this machine hands back a stale bounds rect for a freshly created
    # Settings window, and screencapture sizes a windowed capture from
    # those bounds, so it writes the right window squeezed into the wrong
    # size. That script activates the app first, which is what refreshes
    # the bounds, and then measures the file against the frame
    # Accessibility reports before letting it stand.
    swift Scripts/window-shot.swift Drawer "$OUT"
    exit 0
fi

ID=$(swift Scripts/window-id.swift Drawer)

if ! screencapture -l "$ID" -o "$OUT" || [ ! -s "$OUT" ]; then
    echo "screencapture failed; Screen Recording permission may be missing for this terminal" >&2
    exit 1
fi

echo "$OUT"
