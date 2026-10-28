#!/bin/bash
# shot.sh — macOS 全屏截图到 build/debug/screen.png
# 注意：终端需要「屏幕录制」权限（系统设置 → 隐私与安全性 → 屏幕录制），否则输出黑图
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_common.sh"

SCREEN_FILE="$LOG_DIR/screen.png"

echo "📸 截图中..."
# -D 1 仅捕获主显示器，避免多显示器时拼合画布导致坐标换算错位
if screencapture -x -D 1 "$SCREEN_FILE" 2>/dev/null && [ -s "$SCREEN_FILE" ]; then
  SIZE=$(wc -c < "$SCREEN_FILE" | xargs)
  echo "✅ 截图完成: $SCREEN_FILE (${SIZE} bytes)"
else
  echo "❌ 截图失败"
  echo "💡 多数情况是终端缺少「屏幕录制」权限："
  echo "   系统设置 → 隐私与安全性 → 屏幕录制 → 勾选你的终端 App（iTerm/Terminal/VSCode），重启终端后重试"
  exit 1
fi
