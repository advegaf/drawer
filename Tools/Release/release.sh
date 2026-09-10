#!/bin/bash
# Builds the app the way a stranger will run it: archived, exported with the
# Developer ID identity, notarized, stapled, and wrapped in a disk image that
# is notarized and stapled in its own right.
#
#   NOTARY_KEYCHAIN_PROFILE=<profile> bash Tools/Release/release.sh
#
# Nothing here is clever. It is a list of gates, and every one of them has to
# pass before the image reaches dist/: an unsigned build, a build carrying a
# DRAWER_ test flag, a version that disagrees with project.yml, an unstapled
# app, or a Gatekeeper refusal all stop the run with the reason.
#
# The notary profile is one `xcrun notarytool store-credentials` made once.
# Without it this refuses to start rather than producing something that would
# be blocked on the far side of a download.
set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
readonly TEAM_IDENTIFIER="DV483F72N3"
readonly BUNDLE_ID="com.advegaf.drawer"
readonly BUILD_DIR="$ROOT_DIR/.build-release"
PYTHON="${DRAWER_DMG_PYTHON:-python3}"

fail() { printf 'release: %s\n' "$*" >&2; exit 1; }

VERSION="$(awk -F'"' '/MARKETING_VERSION/{print $2; exit}' "$ROOT_DIR/project.yml")"
[[ -n "$VERSION" ]] || fail "MARKETING_VERSION missing from project.yml"
readonly VERSION
readonly ARCHIVE_PATH="$BUILD_DIR/Drawer.xcarchive"
readonly EXPORT_PATH="$BUILD_DIR/export"
readonly APP_PATH="$EXPORT_PATH/Drawer.app"
readonly DMG_PATH="$BUILD_DIR/Drawer-$VERSION.dmg"
readonly OUTPUT_PATH="$ROOT_DIR/dist/Drawer-$VERSION.dmg"

[[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]] || fail "set NOTARY_KEYCHAIN_PROFILE to a notarytool keychain profile"
xcrun notarytool history --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" >/dev/null 2>&1 \
    || fail "the notary profile '$NOTARY_KEYCHAIN_PROFILE' is missing or invalid"
security find-identity -v -p codesigning | grep -Fq "Developer ID Application: " \
    || fail "no Developer ID Application identity in the keychain"
"$PYTHON" -c 'import ds_store, mac_alias' >/dev/null 2>&1 \
    || fail "install the build tools: python3 -m venv /tmp/drawer-dmg && /tmp/drawer-dmg/bin/pip install -r Tools/Release/dmg-requirements.txt, then set DRAWER_DMG_PYTHON"
[[ ! -e "$OUTPUT_PATH" ]] || fail "$OUTPUT_PATH already exists; bump the version or move it aside"

cd "$ROOT_DIR"
printf 'release: building %s\n' "$VERSION"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$ROOT_DIR/dist"

xcodegen generate >/dev/null
xcodebuild -project Drawer.xcodeproj -scheme Drawer -configuration Release \
    -destination 'platform=macOS,arch=arm64' -archivePath "$ARCHIVE_PATH" \
    CODE_SIGN_IDENTITY="Developer ID Application" CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="$TEAM_IDENTIFIER" OTHER_CODE_SIGN_FLAGS="--timestamp" \
    archive >"$BUILD_DIR/archive.log" 2>&1 || { tail -30 "$BUILD_DIR/archive.log"; fail "the archive failed"; }

xcodebuild -exportArchive -archivePath "$ARCHIVE_PATH" -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$SCRIPT_DIR/ExportOptions.plist" \
    >"$BUILD_DIR/export.log" 2>&1 || { tail -30 "$BUILD_DIR/export.log"; fail "the Developer ID export failed"; }

[[ -d "$APP_PATH" ]] || fail "no app at $APP_PATH"
"$PYTHON" "$SCRIPT_DIR/validate-packaged-app.py" "$APP_PATH" release
/usr/bin/codesign --verify --deep --strict "$APP_PATH" || fail "the exported app does not verify"
signing_info="$(/usr/bin/codesign -dvv "$APP_PATH" 2>&1)"
[[ "$signing_info" == *'Authority=Developer ID Application:'* ]] || fail "the export is not Developer ID signed"
[[ "$signing_info" == *"TeamIdentifier=$TEAM_IDENTIFIER"* ]] || fail "the export carries the wrong team"
/usr/bin/codesign -d --entitlements - --xml "$APP_PATH" 2>/dev/null \
    | grep -Fq 'com.apple.security.automation.apple-events' \
    || fail "the export lost the Apple Events entitlement, so dark mode and Empty Trash would fail silently"

printf 'release: notarizing the app\n'
ditto -c -k --keepParent "$APP_PATH" "$BUILD_DIR/Drawer.zip"
xcrun notarytool submit "$BUILD_DIR/Drawer.zip" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait \
    | tee "$BUILD_DIR/notarize-app.log" >/dev/null
grep -Eq '"?status"?:[[:space:]]+"?Accepted"?' "$BUILD_DIR/notarize-app.log" \
    || { submission="$(sed -nE 's/.*"?id"?:[[:space:]]+"?([0-9a-f-]{36})"?.*/\1/p' "$BUILD_DIR/notarize-app.log" | head -1)"
         [[ -n "$submission" ]] && xcrun notarytool log "$submission" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" || true
         fail "the app was not notarized"; }
xcrun stapler staple "$APP_PATH" || fail "the ticket would not staple to the app"
/usr/sbin/spctl --assess --type execute -vv "$APP_PATH" || fail "Gatekeeper refuses the app"

printf 'release: packaging the disk image\n'
bash "$SCRIPT_DIR/package-dmg.sh" "$APP_PATH" "$DMG_PATH" release

# The image is signed with the same identity the app carries, and only then
# notarized. Notarizing an unsigned image works and staples fine, but
# Gatekeeper still refuses it on the far side of a download: "no usable
# signature", which is what the first attempt at this release hit.
printf 'release: signing the disk image\n'
identity="$(/usr/bin/codesign --display --verbose=4 "$APP_PATH" 2>&1 \
    | /usr/bin/sed -n 's/^Authority=\(Developer ID Application:.*\)/\1/p' | /usr/bin/head -1)"
[[ -n "$identity" ]] || fail "cannot read the app's Developer ID identity"
/usr/bin/codesign --sign "$identity" --timestamp "$DMG_PATH" || fail "the image would not sign"

printf 'release: notarizing the disk image\n'
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait \
    | tee "$BUILD_DIR/notarize-dmg.log" >/dev/null
grep -Eq '"?status"?:[[:space:]]+"?Accepted"?' "$BUILD_DIR/notarize-dmg.log" \
    || { submission="$(sed -nE 's/.*"?id"?:[[:space:]]+"?([0-9a-f-]{36})"?.*/\1/p' "$BUILD_DIR/notarize-dmg.log" | head -1)"
         [[ -n "$submission" ]] && xcrun notarytool log "$submission" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" || true
         fail "the disk image was not notarized"; }
xcrun stapler staple "$DMG_PATH" || fail "the ticket would not staple to the image"
xcrun stapler validate "$DMG_PATH" || fail "the stapled image does not validate"
/usr/bin/codesign --verify --strict "$DMG_PATH" || fail "the image signature does not verify"
/usr/sbin/spctl --assess --type open --context context:primary-signature -vv "$DMG_PATH" \
    || fail "Gatekeeper refuses the image"

mv "$DMG_PATH" "$OUTPUT_PATH"
printf 'release: ready at %s\n' "$OUTPUT_PATH"
/usr/bin/shasum -a 256 "$OUTPUT_PATH"
