#!/bin/bash
# pull.sh — 把设备上的文件拉到项目 build/debug/（autoDebug 无 mkdir 权限时的「落点载体」）
# 用法: pull.sh <设备侧路径> [本地文件名]
#   例: pull.sh /sdcard/Download/a.png a.png
#   不给本地文件名时取设备侧路径的 basename
#
# 为什么存在：subagent（autoDebug）档的 shell 白名单里没有 mkdir / 重定向写盘，
#   而 `adb pull` 要求目标目录**已存在** ⇒ 由本脚本内部 `mkdir -p "$LOG_DIR"` 承载体。
# 退出码: 0=成功 / 1=失败（设备离线、文件不存在、拉取失败）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_common.sh"

REMOTE="${1:-}"
if [ -z "$REMOTE" ]; then
  echo "❌ 用法: pull.sh <设备侧路径> [本地文件名]" >&2
  exit 1
fi
if [ "$#" -ge 2 ] && [ -n "${2:-}" ]; then
  NAME="$2"
else
  NAME="$(basename "$REMOTE")"
fi
# 本地文件名必须是单层合法文件名（防路径穿越 / 写项目外）
case "$NAME" in
  ""|*/*|*\\*) echo "❌ 本地文件名不能含路径分隔符: $NAME" >&2; exit 1 ;;
  .|..) echo "❌ 本地文件名不能为 . 或 ..: $NAME" >&2; exit 1 ;;
  .*) echo "❌ 本地文件名不能以 . 开头: $NAME" >&2; exit 1 ;;
esac

DEVICE=$(require_device)

mkdir -p "$LOG_DIR"
OUT="$LOG_DIR/$NAME"

echo "📱 设备: $DEVICE"
echo "📥 拉取: $REMOTE → $OUT"
adb -s "$DEVICE" pull "$REMOTE" "$OUT" || { echo "❌ adb pull 失败: $REMOTE" >&2; exit 1; }

if [ -s "$OUT" ]; then
  SIZE=$(wc -c < "$OUT" | xargs)
  echo "✅ 拉取完成: ${OUT}（${SIZE} bytes）"
else
  echo "❌ 拉取失败或文件为空: $OUT" >&2
  exit 1
fi
