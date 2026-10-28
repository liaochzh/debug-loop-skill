#!/bin/bash
# source.sh — 导出当前页面 page source（元素结构；排查元素可否寻址的关键手段）
#
# 用法: ./source.sh --platform macos|ios-device [--app-id <id>] [--udid <udid>] [--team-id <TeamID>] [--out <path>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_common.sh"

PLATFORM=""; APP_ID=""; UDID=""; TEAM_ID=""; OUT=""; WAIT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --platform) [ $# -ge 2 ] || { echo "❌ --platform 缺参数值"; exit 2; }; PLATFORM="$2"; shift 2 ;;
    --app-id)   [ $# -ge 2 ] || { echo "❌ --app-id 缺参数值"; exit 2; };   APP_ID="$2"; shift 2 ;;
    --udid)     [ $# -ge 2 ] || { echo "❌ --udid 缺参数值"; exit 2; };     UDID="$2"; shift 2 ;;
    --team-id)  [ $# -ge 2 ] || { echo "❌ --team-id 缺参数值"; exit 2; };  TEAM_ID="$2"; shift 2 ;;
    --out)      [ $# -ge 2 ] || { echo "❌ --out 缺参数值"; exit 2; };      OUT="$2"; shift 2 ;;
    --wait)     [ $# -ge 2 ] || { echo "❌ --wait 缺参数值"; exit 2; };     WAIT="$2"; shift 2 ;;
    -*) echo "❌ 未知参数: $1"; exit 1 ;;
    *)  echo "❌ 未知参数: $1"; exit 1 ;;
  esac
done

# --wait 会不加引号展开成参数，必须先挡掉非数字，避免分词/通配符产生晦涩报错
if [ -n "$WAIT" ]; then
  case "$WAIT" in
    .|*[!0-9.]*|*.*.*) echo "❌ --wait 需为非负数字（秒）: $WAIT"; exit 2 ;;
  esac
fi

[ -n "$PLATFORM" ] || { echo "❌ 用法: ./source.sh --platform macos|ios-device [...]"; exit 1; }

case "$PLATFORM" in
  macos)     ;;
  ios-device) [ -n "$TEAM_ID" ] && export IOS_TEAM_ID="$TEAM_ID";;
  *) echo "❌ --platform 仅支持 macos|ios-device"; exit 1 ;;
esac

require_appium
ensure_appium_server

CAPS="$LOG_DIR/.appium_caps.json"
case "$PLATFORM" in
  macos)      write_caps_macos "$CAPS" "$APP_ID" ;;
  ios-device) write_caps_ios_device "$CAPS" "$APP_ID" "$UDID" ;;
esac

OUT="${OUT:-$LOG_DIR/page_source.xml}"
WAIT_ARGS=""
[ -n "$WAIT" ] && WAIT_ARGS="--wait $WAIT"
# shellcheck disable=SC2086  # WAIT_ARGS 为空时必须展开成 0 个参数
python3 "$DRIVER_PY" source --server "$APPIUM_SERVER" --caps "$CAPS" $WAIT_ARGS > "$OUT"
echo "✅ page source 已写入: $OUT ($(wc -c < "$OUT" | xargs) bytes)"