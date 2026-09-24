#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift build -c release
APP="dist/Locus.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Locus "$APP/Contents/MacOS/Locus"
cp Info.plist "$APP/Contents/Info.plist"
if [ ! -f Resources/Locus.icns ]; then
  .venv/bin/python scripts/make-icon.py
  SET="Resources/Locus.iconset"
  rm -rf "$SET"
  mkdir -p "$SET"
  SRC="Resources/Locus-icon.png"
  sips -z 16 16 "$SRC" --out "$SET/icon_16x16.png" >/dev/null
  sips -z 32 32 "$SRC" --out "$SET/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$SRC" --out "$SET/icon_32x32.png" >/dev/null
  sips -z 64 64 "$SRC" --out "$SET/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$SRC" --out "$SET/icon_128x128.png" >/dev/null
  sips -z 256 256 "$SRC" --out "$SET/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$SRC" --out "$SET/icon_256x256.png" >/dev/null
  sips -z 512 512 "$SRC" --out "$SET/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$SRC" --out "$SET/icon_512x512.png" >/dev/null
  cp "$SRC" "$SET/icon_512x512@2x.png"
  iconutil -c icns "$SET" -o Resources/Locus.icns
fi
cp Resources/Locus.icns "$APP/Contents/Resources/Locus.icns"
codesign --force --sign - "$APP"
echo "built $PWD/$APP"
