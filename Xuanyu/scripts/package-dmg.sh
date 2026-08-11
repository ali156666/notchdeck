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

USE_NATIVE_BUILD_SYSTEM=0
# 本工程的两个 binaryTarget 都带 Headers/module.modulemap；优先使用 native
# 构建系统，避免 swiftbuild 把它们复制到同一个 include 目录后发生冲突。
if swift build --help 2>/dev/null | grep -q -- "--build-system"; then
  USE_NATIVE_BUILD_SYSTEM=1
fi

run_swift_build() {
  if [ "$USE_NATIVE_BUILD_SYSTEM" -eq 1 ]; then
    swift build --build-system native "$@"
  else
    swift build "$@"
  fi
}

# 只有 Command Line Tools 时，macOS 27 SDK 需要完整 Xcode 才提供的 SwiftUI
# 宏插件。自动选择同一套 CLT 中的 macOS 26.x SDK，与应用部署目标保持一致。
if [ -z "${SDKROOT:-}" ] && [ ! -d "$(xcode-select -p)/Platforms" ]; then
  for candidate in /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk; do
    if [ -d "$candidate" ]; then
      export SDKROOT="$candidate"
      echo "Command Line Tools only: building against $(basename "$candidate")"
      break
    fi
  done
fi

run_swift_build -c release
BIN_DIR="$(run_swift_build -c release --show-bin-path)"

VERSION="$("$PLIST_BUDDY" -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Info.plist")"
DMG_PATH="$DIST_DIR/NotchDeck-$VERSION.dmg"

rm -rf "$DIST_DIR/$APP_NAME.app" "$APP_BUNDLE" "$STAGING_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$STAGING_DIR"

cp "$BIN_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$ROOT_DIR/Sources/Xuanyu/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
mkdir -p "$APP_BUNDLE/Contents/Resources/AgentRuntime"
# runtime.mjs 会从同一目录加载 memory / harness / subagents，必须整组打包。
cp "$ROOT_DIR"/AgentRuntime/dist/*.mjs "$APP_BUNDLE/Contents/Resources/AgentRuntime/"
cp -R "$ROOT_DIR/Sources/Xuanyu/Resources/AgentRuntime/skills" "$APP_BUNDLE/Contents/Resources/AgentRuntime/skills"

if [ -d "$BIN_DIR/Xuanyu_Xuanyu.bundle" ]; then
  cp -R "$BIN_DIR/Xuanyu_Xuanyu.bundle" "$APP_BUNDLE/Contents/Resources/"
fi

codesign --force --deep --options runtime --sign - "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

for required_module in runtime.mjs memory.mjs harness.mjs subagents.mjs; do
  if [ ! -f "$APP_BUNDLE/Contents/Resources/AgentRuntime/$required_module" ]; then
    echo "Missing AgentRuntime module: $required_module" >&2
    exit 1
  fi
done

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

hdiutil verify "$DMG_PATH"
DMG_SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
printf '%s  %s\n' "$DMG_SHA256" "$(basename "$DMG_PATH")" > "$DMG_PATH.sha256"

echo "Created $DMG_PATH"
echo "Checksum: $DMG_PATH.sha256"
