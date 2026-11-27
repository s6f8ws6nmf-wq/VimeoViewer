#!/bin/bash
# Zostaví aplikáciu a zabalí ju do „Vimeo Viewer.dmg“ (s odkazom na Aplikácie na pretiahnutie).
#   ./make_dmg.sh
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Vimeo Viewer"
BUILD="build"
APP="$BUILD/$APP_NAME.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist 2>/dev/null || echo 1.0)"
DMG="$BUILD/$APP_NAME $VERSION.dmg"
STAGE="$BUILD/dmg-stage"

echo "▶︎ Zostavujem aplikáciu…"
./build.sh

echo "▶︎ Pripravujem obsah DMG…"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp README.md "$STAGE/Návod.md"

echo "▶︎ Vytváram DMG…"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
rm -rf "$STAGE"

codesign --force --sign - "$DMG" >/dev/null 2>&1 || true

echo "✅ Hotovo: $DMG"
[ -z "${CI:-}" ] && open -R "$DMG" || true
