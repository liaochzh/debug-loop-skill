#!/bin/bash
# click.sh — macOS 桌面点击（屏幕全局 point 坐标）
#
# 用法:
#   ./click.sh <x> <y>            # 点击屏幕 point 坐标
#   ./click.sh --activate <AppName>   # 仅将应用切到前台（不点击）
#
# 说明:
#   - 优先 cliclick（brew install cliclick）；缺失时回退 osascript System Events
#   - 坐标为「屏幕 point」（AppleScript 坐标系，左上为原点），非 Retina 像素
#   - 需要「辅助功能」权限：系统设置 → 隐私与安全性 → 辅助功能 → 勾选终端
set -euo pipefail

# 仅允许整数/小数坐标，防止坐标注入进 osascript 源码
is_coord() { [[ "$1" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; }
# 应用名禁止双引号与反斜杠，防止逃逸 AppleScript 字符串字面量
has_unsafe_quote() { case "$1" in *\"*|*\\*) return 0;; *) return 1;; esac; }

if [ "${1:-}" = "--activate" ]; then
  APP="${2:-}"
  [ -n "$APP" ] || { echo "❌ 用法: ./click.sh --activate <AppName>"; exit 2; }
  has_unsafe_quote "$APP" && { echo "❌ 非法应用名（含引号/反斜杠）: $APP"; exit 2; }
  osascript -e "tell application \"$APP\" to activate" >/dev/null 2>&1 || {
    echo "❌ 无法激活应用: $APP"; exit 1; }
  echo "✅ 已激活: $APP"
  exit 0
fi

X="${1:-}"; Y="${2:-}"
if [ -z "$X" ] || [ -z "$Y" ]; then
  echo "❌ 用法: ./click.sh <x> <y>  或  ./click.sh --activate <AppName>"
  exit 2
fi
is_coord "$X" && is_coord "$Y" || { echo "❌ 坐标必须为数字: ($X, $Y)"; exit 2; }

if command -v cliclick >/dev/null 2>&1; then
  echo "👆 点击 ($X, $Y) [cliclick]"
  cliclick "c:$X,$Y"
else
  echo "👆 点击 ($X, $Y) [osascript]"
  echo "💡 建议安装 cliclick 提升稳定性: brew install cliclick"
  osascript -e "tell application \"System Events\" to click at {$X, $Y}"
fi
echo "✅ 点击完成"