#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/Xuanyu"

case "${1:-run}" in
  --probe-airpods|probe-airpods)
    cd "$APP_DIR"
    swift test --filter MediaIslandAirPodsProbeTests
    ;;
  --test|test)
    cd "$APP_DIR"
    swift build
    (cd AgentRuntime && npm test)
    ;;
  run|--verify|verify)
    "$APP_DIR/build.sh"
    ;;
  --debug|debug|--logs|logs|--telemetry|telemetry)
    echo "Xuanyu is the active app. Use Xuanyu/build.sh for foreground runs; logs are in /tmp/xuanyu.log." >&2
    "$APP_DIR/build.sh"
    ;;
  *)
    echo "usage: $0 [run|--verify|--probe-airpods|--test]" >&2
    exit 2
    ;;
esac
