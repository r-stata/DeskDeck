#!/bin/bash
# 构建 DeskDeck 并打包成 DMG（通用二进制 + 单独 arm64 / x86_64 版本）
#
#   ./package_dmg.sh          # 生成 dist/DeskDeck-<版本>-universal.dmg 等三个安装包
#   ./package_dmg.sh universal # 只出通用版
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/DesktopMaster"
DIST="$ROOT/dist"
APPNAME="DeskDeck"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SRC/Resources/Info.plist" 2>/dev/null || echo 1.0)"
WHAT="${1:-all}"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/deskdeck-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

echo "==> 编译通用二进制（arm64 + x86_64）"
cd "$SRC"
swift build -c release --arch arm64 --arch x86_64
BIN="$SRC/.build/release/DeskDeck"

make_app() { # $1 = 目标 app 路径, $2 = 二进制
  local app="$1" bin="$2"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$bin" "$app/Contents/MacOS/$APPNAME"
  cp "$SRC/Resources/Info.plist" "$app/Contents/Info.plist"
  cp "$SRC/Resources/Icon/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
  printf 'APPL????' > "$app/Contents/PkgInfo"
  codesign --force --sign - --timestamp=none "$app" >/dev/null 2>&1 || true
  codesign --verify --verbose=1 "$app" 2>&1 | tail -1
}

make_dmg() { # $1 = app 路径, $2 = 输出 dmg
  local app="$1" out="$2" vol="${3:-$APPNAME}"
  local src="$STAGE/$(basename "$out" .dmg)"
  mkdir -p "$src"
  cp -R "$app" "$src/"
  ln -s /Applications "$src/Applications"
  rm -f "$out"
  hdiutil create -volname "$vol" -srcfolder "$src" -ov -format UDZO "$out" >/dev/null
  echo "    -> $out ($(du -h "$out" | cut -f1))"
}

mkdir -p "$DIST"

if [ "$WHAT" = "all" ] || [ "$WHAT" = "universal" ]; then
  echo "==> 通用版 ($(lipo -info "$BIN" | sed 's/.*are: //'))"
  make_app "$STAGE/u/$APPNAME.app" "$BIN"
  make_dmg "$STAGE/u/$APPNAME.app" "$DIST/$APPNAME-$VERSION-universal.dmg"
fi

if [ "$WHAT" = "all" ] || [ "$WHAT" = "arm64" ] || [ "$WHAT" = "apple" ]; then
  echo "==> Apple Silicon (arm64)"
  lipo "$BIN" -thin arm64 -output "$STAGE/bin-arm64"
  make_app "$STAGE/a/$APPNAME.app" "$STAGE/bin-arm64"
  make_dmg "$STAGE/a/$APPNAME.app" "$DIST/$APPNAME-$VERSION-arm64.dmg"
fi

if [ "$WHAT" = "all" ] || [ "$WHAT" = "x86_64" ] || [ "$WHAT" = "intel" ]; then
  echo "==> Intel (x86_64)"
  lipo "$BIN" -thin x86_64 -output "$STAGE/bin-x86_64"
  make_app "$STAGE/x/$APPNAME.app" "$STAGE/bin-x86_64"
  make_dmg "$STAGE/x/$APPNAME.app" "$DIST/$APPNAME-$VERSION-x86_64.dmg"
fi

echo "==> 完成，安装包在 $DIST"
ls -lh "$DIST" | tail -n +2 | awk '{print "   ", $9, $5}'
