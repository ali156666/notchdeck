#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Xuanyu"
APP_DISPLAY_NAME="悬屿"
APP_BUNDLE="$ROOT_DIR/dist/$APP_DISPLAY_NAME.app"

cd "$ROOT_DIR"
NODE_BIN="/opt/homebrew/bin/node"
if [ ! -x "$NODE_BIN" ]; then
    NODE_BIN="$(command -v node || true)"
fi
if [ -z "$NODE_BIN" ]; then
    echo "Node.js is required for AgentRuntime" >&2
    exit 1
fi
"$NODE_BIN" "$ROOT_DIR/AgentRuntime/build.mjs"
swift build
BIN_DIR="$(swift build --show-bin-path)"

rm -rf "$ROOT_DIR/dist/$APP_NAME.app" "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

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

pkill -x "$APP_NAME" 2>/dev/null || true
open -n "$APP_BUNDLE" 2>/dev/null || true
PID=""
for _ in {1..20}; do
    PID="$(pgrep -x "$APP_NAME" | head -1 || true)"
    if [ -n "$PID" ]; then
        break
    fi
    sleep 0.25
done

if [ -z "$PID" ]; then
    nohup "$APP_BUNDLE/Contents/MacOS/$APP_NAME" >/tmp/xuanyu.log 2>&1 &
    PID="$!"
    sleep 2
fi

if ! kill -0 "$PID" 2>/dev/null; then
    echo "Failed to launch $APP_BUNDLE" >&2
    exit 1
fi

echo "Running $APP_BUNDLE (PID $PID)"
