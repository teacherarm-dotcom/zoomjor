#!/bin/bash
# สร้างวิดีโอสอนการใช้งาน ZoomJor (16:9 · 1920x1080 · พากย์ไทย Kanya)
#   ./video/build-video.sh            → video/build/ZoomJor-สอนการใช้งาน.mp4
#   ./video/build-video.sh --preview  → ภาพตัวอย่างทุกฉากใน video/build/preview/
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p video/build
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
    -framework Cocoa -framework ScreenCaptureKit -framework Carbon -framework AVFoundation \
    $(ls Sources/*.swift | grep -v 'Sources/main.swift') video/tool/main.swift \
    -o video/build/zjvideo
./video/build/zjvideo "$(pwd)/video" "$@"
