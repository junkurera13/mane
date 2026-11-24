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
[ -d Resources/styles ] && cp -R Resources/styles "$APP/Contents/Resources/styles"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
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
