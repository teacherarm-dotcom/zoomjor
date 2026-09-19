#!/bin/bash
# สร้างไฟล์ .dmg สำหรับติดตั้งแบบลากไอคอน (เหมือนโปรแกรม Mac ทั่วไป)
#   ./make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")"

APP="ZoomJor.app"
VOLNAME="ZoomJor"

[ -d "$APP" ] || ./build.sh

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="ZoomJor-$VERSION.dmg"

STAGE="$(mktemp -d)/$VOLNAME"
mkdir -p "$STAGE"

echo "==> จัดของลง disk image…"
ditto "$APP" "$STAGE/$APP"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/อ่านก่อนติดตั้ง.txt" <<'TXT'
ZoomJor (ซูมจอ) — วิธีติดตั้ง
=================================

1. ลากไอคอน ZoomJor ไปวางบนโฟลเดอร์ Applications ที่อยู่ข้าง ๆ
2. เปิดโฟลเดอร์ Applications แล้วดับเบิลคลิก ZoomJor

ครั้งแรกจะขึ้นเตือนว่า "Apple ตรวจสอบหามัลแวร์ไม่ได้" — เป็นเรื่องปกติ
เพราะโปรแกรมนี้แจกฟรีและยังไม่ได้ซื้อใบรับรองนักพัฒนาของ Apple

  กด "เสร็จสิ้น" แล้วไปที่
  การตั้งค่าระบบ > ความเป็นส่วนตัวและความปลอดภัย
  เลื่อนลงไปจะเห็นบรรทัด "ZoomJor ถูกบล็อก..." กดปุ่ม "เปิดอยู่ดี"
  แล้วยืนยันอีกครั้ง

  (ทำครั้งเดียวจบ ครั้งต่อไปเปิดได้ตามปกติ)

3. เปิดแล้วจะไม่มีหน้าต่างโปรแกรม — ให้ดูไอคอนแว่นขยายบนแถบเมนูขวาบน

4. กด Control+1 ครั้งแรก ระบบจะขอสิทธิ์ "การบันทึกหน้าจอ"
   อนุญาตแล้วปิดเปิดโปรแกรมใหม่หนึ่งครั้ง

คีย์ลัดหลัก
-----------
  Control+1   ซูมหน้าจอ (แช่ภาพ)
  Control+2   วาดทับหน้าจอ
  Control+3   นาฬิกาจับเวลาพัก
  Control+4   ซูมสด
  Esc         ออกจากโหมด
  Control+Option+Q   ปิดโปรแกรม

คู่มือฉบับเต็ม: https://github.com/teacherarm-dotcom/zoomjor
TXT

echo "==> สร้าง $DMG…"
rm -f "$DMG"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" \
    -ov -format UDZO -fs HFS+ "$DMG" >/dev/null

rm -rf "$(dirname "$STAGE")"
echo "==> เสร็จ: $(pwd)/$DMG  ($(du -h "$DMG" | cut -f1))"
