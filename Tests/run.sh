#!/bin/bash
# เทสต์ทางลัดเครื่องมือ (ปากกา / ⇧ ลูกศร / ⌃⇧ สี่เหลี่ยม / ⌥ บังคับมุม)
#   ./Tests/run.sh
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)/toolmodifiertests"
swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
    -framework Cocoa -framework ScreenCaptureKit -framework Carbon \
    $(ls Sources/*.swift | grep -v 'Sources/main.swift') \
    Tests/main.swift -o "$OUT"
"$OUT"
