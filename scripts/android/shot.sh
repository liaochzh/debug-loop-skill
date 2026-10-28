#!/bin/bash
# shot.sh — 截图到 build/debug/screen.png（用 Read 工具查看图片）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_common.sh"

DEVICE=$(require_device)
SCREEN_FILE="$LOG_DIR/screen.png"

echo "📱 设备: $DEVICE — 📸 截图中..."
adb -s "$DEVICE" exec-out screencap -p > "$SCREEN_FILE"

if [ -s "$SCREEN_FILE" ]; then
  SIZE=$(wc -c < "$SCREEN_FILE" | xargs)
  echo "✅ 截图完成: $SCREEN_FILE (${SIZE} bytes)"
else
  echo "❌ 截图失败"
  exit 1
fi
