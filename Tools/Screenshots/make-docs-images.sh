#!/usr/bin/env bash
# Regenerates every image in docs/images.
#
# Two steps. First the captures: each one is a real window photographed
# through the window server, with its own shadow, into a scratch directory.
# Then one pass of ArticleImages.swift, which draws the backdrop, composites
# the captures onto it and writes the files the README embeds.
#
# Every launch carries DRAWER_DEMO=curated, so no capture touches the real
# preferences domain or photographs whatever the person running this has
# pinned. The curated fixture is eight cells that all work; the older
# DRAWER_DEMO=states fixture is a catalogue of every state, broken ones
# included, and it photographs as a bug report.
set -Eeuo pipefail
cd "$(dirname "$0")/../.."

BIN="$(xcodebuild -project Drawer.xcodeproj -scheme Drawer -configuration Debug -showBuildSettings 2>/dev/null \
    | awk '/ BUILT_PRODUCTS_DIR =/ {print $3}')/Drawer.app/Contents/MacOS/Drawer"
[[ -x "$BIN" ]] || { echo "build first: make build" >&2; exit 1; }

RAW="${DRAWER_RAW_DIR:-$(mktemp -d)}"
mkdir -p "$RAW" docs/images
trap 'pkill -x Drawer || true' EXIT

settings_shot() {           # settings_shot <name> <env...>
    local name="$1"; shift
    pkill -x Drawer || true
    sleep 1
    env "$@" "$BIN" >/dev/null 2>&1 &
    # Eight rather than six: at six the third or fourth launch in a run
    # sometimes had no titled window yet, and the capture came back either
    # empty or the wrong size.
    sleep 8
    swift Scripts/window-shot.swift Drawer "$RAW/$name.png" --shadow >/dev/null
}

panel_shot() {              # panel_shot <name> <env...>
    local name="$1"; shift
    pkill -x Drawer || true
    sleep 1
    env "$@" "$BIN" >/dev/null 2>&1 &
    # Eight rather than six: at six the third or fourth launch in a run
    # sometimes had no titled window yet, and the capture came back either
    # empty or the wrong size.
    sleep 8
    local id
    id="$(swift Scripts/window-id.swift Drawer)"
    screencapture -x -l "$id" "$RAW/$name.png"
}

panel_shot    drawer              DRAWER_DEMO=curated DRAWER_OPEN=1 DRAWER_HOVER=0
settings_shot settings-items      DRAWER_DEMO=curated DRAWER_SETTINGS=1 DRAWER_SETTINGS_PAGE=items
settings_shot settings-appearance DRAWER_DEMO=curated DRAWER_SETTINGS=1 DRAWER_SETTINGS_PAGE=appearance
settings_shot guide               DRAWER_DEMO=curated DRAWER_GUIDE=1
pkill -x Drawer || true

# The icon, at the size the README asks for it and at the size the hero draws
# it. Copied rather than re-exported: this is the same file the app ships.
cp Design/icon/exports/Default-1024x1024@1x.png "$RAW/logo.png"
cp Design/icon/exports/Default-1024x1024@1x.png docs/images/logo.png

swift Tools/Screenshots/ArticleImages.swift "$RAW" docs/images

echo "docs/images:"
ls -1 docs/images
