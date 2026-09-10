#!/usr/bin/env bash
# Regenerates every image in docs/images.
#
# Two steps per shot: the window is captured through the window server with
# its own shadow, then stood on a backdrop. Nothing here draws a window frame,
# because the capture already contains the real one.
#
# Every launch carries DRAWER_DEMO, so no capture ever touches the real
# preferences domain or photographs whatever the person running this has
# pinned.
set -Eeuo pipefail
cd "$(dirname "$0")/../.."

BIN="$(xcodebuild -project Drawer.xcodeproj -scheme Drawer -configuration Debug -showBuildSettings 2>/dev/null \
    | awk '/ BUILT_PRODUCTS_DIR =/ {print $3}')/Drawer.app/Contents/MacOS/Drawer"
[[ -x "$BIN" ]] || { echo "build first: make build" >&2; exit 1; }

RAW="$(mktemp -d)"
trap 'rm -rf "$RAW"; pkill -x Drawer || true' EXIT
mkdir -p docs/images

settings_shot() {           # settings_shot <name> <ground> <env...>
    local name="$1" ground="$2"; shift 2
    pkill -x Drawer || true
    sleep 1
    env "$@" "$BIN" >/dev/null 2>&1 &
    sleep 6
    swift Scripts/window-shot.swift Drawer "$RAW/$name.png" --shadow >/dev/null
    swift Tools/Screenshots/FrameShot.swift "$RAW/$name.png" "docs/images/$name.png" "$ground"
}

panel_shot() {              # panel_shot <name> <ground> <env...>
    local name="$1" ground="$2"; shift 2
    pkill -x Drawer || true
    sleep 1
    env "$@" "$BIN" >/dev/null 2>&1 &
    sleep 6
    local id
    id="$(swift Scripts/window-id.swift Drawer)"
    screencapture -x -l "$id" "$RAW/$name.png"
    swift Tools/Screenshots/FrameShot.swift "$RAW/$name.png" "docs/images/$name.png" "$ground" wide
}

# The black drawer on paper rather than on more black: on the dark ground
# the product and the backdrop are the same colour and the shape disappears.
panel_shot    hero                light DRAWER_DEMO=states DRAWER_OPEN=1 DRAWER_HOVER=0
panel_shot    drawer-light        dark  DRAWER_DEMO=states DRAWER_OPEN=1 DRAWER_APPEARANCE=light DRAWER_THEME=bar=light
settings_shot settings-items      dark  DRAWER_DEMO=states DRAWER_SETTINGS=1 DRAWER_SETTINGS_PAGE=items
settings_shot settings-appearance dark  DRAWER_DEMO=states DRAWER_SETTINGS=1 DRAWER_SETTINGS_PAGE=appearance
settings_shot settings-general    light DRAWER_DEMO=states DRAWER_SETTINGS=1 DRAWER_SETTINGS_PAGE=general DRAWER_APPEARANCE=light
settings_shot library-remove      dark  DRAWER_DEMO=states DRAWER_SETTINGS=1 DRAWER_SETTINGS_PAGE=items DRAWER_LIBRARY_HOVER=action:wifi
settings_shot guide               dark  DRAWER_DEMO=states DRAWER_GUIDE=1

# docs/images/installer.png is not made here: it is the mounted release
# image photographed in the Finder, which only exists once release.sh has
# built one. `swift Tools/Screenshots/FrameShot.swift <capture> \
# docs/images/installer.png light` is the second half of it.

echo "docs/images:"
ls -1 docs/images
