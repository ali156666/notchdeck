#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Xuanyu"
DISPLAY_NAME="悬屿"
DMG_APP_NAME="悬屿"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$DMG_APP_NAME.app"
STAGING_DIR="$DIST_DIR/dmg-staging"
NODE_BIN="/opt/homebrew/bin/node"
PLIST_BUDDY="/usr/libexec/PlistBuddy"

if [ ! -x "$NODE_BIN" ]; then
  NODE_BIN="$(command -v node || true)"
fi
if [ -z "$NODE_BIN" ]; then
  echo "Node.js is required for AgentRuntime" >&2
  exit 1
fi

cd "$ROOT_DIR"
"$NODE_BIN" "$ROOT_DIR/AgentRuntime/build.mjs"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

VERSION="$("$PLIST_BUDDY" -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Info.plist")"
DMG_PATH="$DIST_DIR/$DISPLAY_NAME-$VERSION.dmg"

rm -rf "$DIST_DIR/$APP_NAME.app" "$APP_BUNDLE" "$STAGING_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$STAGING_DIR"

cp "$BIN_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$ROOT_DIR/Sources/Xuanyu/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
mkdir -p "$APP_BUNDLE/Contents/Resources/AgentRuntime"
cp "$ROOT_DIR/AgentRuntime/dist/runtime.mjs" "$APP_BUNDLE/Contents/Resources/AgentRuntime/runtime.mjs"
cp -R "$ROOT_DIR/Sources/Xuanyu/Resources/AgentRuntime/skills" "$APP_BUNDLE/Contents/Resources/AgentRuntime/skills"

if [ -d "$BIN_DIR/Xuanyu_Xuanyu.bundle" ]; then
  cp -R "$BIN_DIR/Xuanyu_Xuanyu.bundle" "$APP_BUNDLE/Contents/Resources/"
fi

codesign --force --deep --sign - "$APP_BUNDLE"

cp -R "$APP_BUNDLE" "$STAGING_DIR/$DMG_APP_NAME.app"
cp "$ROOT_DIR/docs/使用说明.txt" "$STAGING_DIR/使用说明.txt"
ln -s /Applications "$STAGING_DIR/Applications"
rm -f "$DMG_PATH"
hdiutil create \
  -volname "$DISPLAY_NAME $VERSION" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"
rm -rf "$STAGING_DIR"

echo "Created $DMG_PATH"
