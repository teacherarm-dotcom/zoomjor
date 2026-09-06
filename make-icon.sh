#!/bin/bash
# ใช้: ./make-icon.sh path/to/icon-1024.png
# แปลงภาพ PNG (แนะนำ 1024x1024 พื้นหลังโปร่งใส) เป็น Resources/AppIcon.icns
set -euo pipefail
cd "$(dirname "$0")"

SRC="${1:-}"
if [ -z "$SRC" ] || [ ! -f "$SRC" ]; then
    echo "ใช้: ./make-icon.sh path/to/icon-1024.png"
    exit 1
fi

SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"
for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
            "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
            "512 512x512" "1024 512x512@2x"; do
    set -- $spec
    sips -z "$1" "$1" "$SRC" --out "$SET/icon_$2.png" >/dev/null
done

mkdir -p Resources
iconutil -c icns "$SET" -o Resources/AppIcon.icns
rm -rf "$(dirname "$SET")"
echo "==> สร้างแล้ว: Resources/AppIcon.icns"
echo "    รันต่อ: ./build.sh"
