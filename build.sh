#!/bin/bash
# 构建「DeskDeck」并打包成 .app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/DesktopMaster"
APP="$ROOT/DeskDeck.app"

echo "==> 编译"
cd "$SRC"
swift build -c release

echo "==> 打包"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SRC/.build/release/DeskDeck" "$APP/Contents/MacOS/DeskDeck"
cp "$SRC/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$SRC/Resources/Icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> 签名（ad-hoc）"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || true
codesign --verify --verbose=1 "$APP" 2>&1 | tail -2

echo "==> 完成：$APP"
