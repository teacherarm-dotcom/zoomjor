#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="ZoomJor.app"
BIN="ZoomJor"
ARCH="$(uname -m)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# ไอคอน (ถ้ามี) — วางไฟล์ไว้ที่ Resources/
#   AppIcon.icns      = ไอคอนแอป
#   MenuBarIcon.pdf   = ไอคอนบนแถบเมนู (ขาวดำ/โปร่งใส ราว 18x18 pt)
for f in Resources/AppIcon.icns Resources/MenuBarIcon.pdf Resources/MenuBarIcon.png; do
    [ -f "$f" ] && cp "$f" "$APP/Contents/Resources/" && echo "==> ใส่ไอคอน: $f"
done

echo "==> compiling ($ARCH)…"
swiftc -O -swift-version 5 \
    -target "${ARCH}-apple-macos14.0" \
    -framework Cocoa -framework ScreenCaptureKit -framework Carbon -framework VideoToolbox \
    Sources/*.swift \
    -o "$APP/Contents/MacOS/$BIN"

echo "==> signing (ad-hoc)…"
codesign --force --sign - --timestamp=none "$APP"

echo "==> done: $(pwd)/$APP"
