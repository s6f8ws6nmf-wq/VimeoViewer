#!/bin/bash
# Zostaví „Vimeo Viewer.app“ pre macOS 11 Big Sur a novší.
# Potrebné: Xcode alebo Command Line Tools (xcode-select --install).
#
#   ./build.sh            – zostaví aplikáciu do priečinka build/
#   ./build.sh install    – zostaví a nainštaluje do /Applications (alebo ~/Applications)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Vimeo Viewer"
EXEC="VimeoViewer"
BUILD="build"
APP="$BUILD/$APP_NAME.app"
MIN_OS="11.0"

if ! command -v xcrun >/dev/null 2>&1 || ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "❌ Chýba kompilátor Swift. Nainštalujte Command Line Tools príkazom:  xcode-select --install"
  exit 1
fi

SDK="$(xcrun --show-sdk-path --sdk macosx)"
SOURCES=(Sources/*.swift)
mkdir -p "$BUILD"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

compile() {
  local arch="$1"
  xcrun swiftc "${SOURCES[@]}" \
    -O -module-name "$EXEC" \
    -sdk "$SDK" -target "${arch}-apple-macos${MIN_OS}" \
    -o "$BUILD/$EXEC-$arch"
}

HOST_ARCH="$(uname -m)"
OTHER_ARCH="x86_64"; [ "$HOST_ARCH" = "x86_64" ] && OTHER_ARCH="arm64"

echo "▶︎ Kompilujem ($HOST_ARCH)…"
compile "$HOST_ARCH"
BINARIES=("$BUILD/$EXEC-$HOST_ARCH")

echo "▶︎ Kompilujem ($OTHER_ARCH) pre univerzálnu aplikáciu…"
if compile "$OTHER_ARCH" 2>/dev/null; then
  BINARIES+=("$BUILD/$EXEC-$OTHER_ARCH")
else
  echo "  (preskočené – aplikácia bude len pre $HOST_ARCH)"
fi
lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/$EXEC"
rm -f "${BINARIES[@]}"

cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▶︎ Vytváram ikonu…"
ICONSET="$BUILD/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
if xcrun swift Tools/make_icon.swift "$BUILD/icon_1024.png" >/dev/null 2>&1; then
  for s in 16 32 128 256 512; do
    sips -z $s $s "$BUILD/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d "$BUILD/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" || echo "  (ikonu sa nepodarilo vytvoriť)"
else
  echo "  (ikonu sa nepodarilo vytvoriť – aplikácia použije predvolenú)"
fi
rm -rf "$ICONSET"

echo "▶︎ Podpisujem (ad-hoc)…"
codesign --force --deep --sign - "$APP" >/dev/null

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [ "${1:-}" = "install" ]; then
  DEST="/Applications"
  if [ ! -w "$DEST" ]; then DEST="$HOME/Applications"; mkdir -p "$DEST"; fi
  pkill -x "$EXEC" 2>/dev/null || true
  rm -rf "$DEST/$APP_NAME.app"
  cp -R "$APP" "$DEST/"
  "$LSREGISTER" -f "$DEST/$APP_NAME.app" || true
  echo "✅ Nainštalované: $DEST/$APP_NAME.app"
  open "$DEST/$APP_NAME.app"
else
  "$LSREGISTER" -f "$APP" || true
  echo "✅ Hotovo: $APP"
  echo "   Inštalácia do Aplikácií:  ./build.sh install"
fi
