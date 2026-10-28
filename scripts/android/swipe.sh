#!/bin/bash
# swipe.sh — 滑动屏幕
# 用法: ./swipe.sh x1 y1 x2 y2 [ms]   默认 300ms
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_common.sh"

DEVICE=$(require_device)

X1="${1:-}" ; Y1="${2:-}" ; X2="${3:-}" ; Y2="${4:-}" ; DURATION="${5:-300}"

if [ -z "$X1" ] || [ -z "$Y1" ] || [ -z "$X2" ] || [ -z "$Y2" ]; then
  echo "❌ 用法: ./swipe.sh x1 y1 x2 y2 [ms]"
  exit 1
fi

echo "👆 滑动: ($X1, $Y1) -> ($X2, $Y2) 耗时 ${DURATION}ms"
adb -s "$DEVICE" shell input swipe "$X1" "$Y1" "$X2" "$Y2" "$DURATION"
echo "✅ 滑动完成"
