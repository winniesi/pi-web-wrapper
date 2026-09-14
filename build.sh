#!/bin/bash
# 编译 Pi Web wrapper 并安装到 ~/Applications/Pi Web.app
set -euo pipefail
cd "$(dirname "$0")"

APP="$HOME/Applications/Pi Web.app"

[ -f ApplicationIcon.icns ] || { echo "缺少 ApplicationIcon.icns（从旧 Safari Web App 提取）" >&2; exit 1; }

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -framework AppKit -framework WebKit main.swift -o "$APP/Contents/MacOS/PiWeb"
cp Info.plist "$APP/Contents/Info.plist"
cp ApplicationIcon.icns "$APP/Contents/Resources/ApplicationIcon.icns"
codesign --force -s - "$APP"

echo "已安装：$APP"
