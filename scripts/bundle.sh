#!/bin/bash
# Builds Mane.app (universal: Apple Silicon + Intel), signs it ad hoc, and packs
# build/Mane.dmg and build/Mane.zip. Run on a Mac with Xcode (or its command line tools).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-1}"

swift build -c release --arch arm64 --arch x86_64
BIN=".build/apple/Products/Release/Mane"

rm -rf build
APP="build/Mane.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/web"
cp "$BIN" "$APP/Contents/MacOS/Mane"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
cp web/mirror.html "$APP/Contents/Resources/web/"
mkdir -p "$APP/Contents/Resources/web/vendor"
cp web/vendor/fal-realtime.js "$APP/Contents/Resources/web/vendor/"
[ -d Resources/styles ] && cp -R Resources/styles "$APP/Contents/Resources/styles"
if [ -f Resources/AppIcon-1024.png ]; then
  ICONSET="build/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad hoc signature: enough for macOS to run it after a right-click → Open the first time.
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --verbose "$APP"

ditto -c -k --keepParent "$APP" build/Mane.zip

STAGE="build/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Mane" -srcfolder "$STAGE" -ov -format UDZO build/Mane.dmg >/dev/null
rm -rf "$STAGE"

du -sh "$APP" build/Mane.dmg build/Mane.zip
