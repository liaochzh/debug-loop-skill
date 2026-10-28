#!/bin/bash
# tap.sh — Appium 语义点击（macOS mac2 / iOS 真机 xcuitest；无障碍定位，无需坐标）
#
# 用法:
#   ./tap.sh "<selector>" --platform macos|ios-device
#            [--using "accessibility id"] [--app-id <id>] [--udid <udid>] [--team-id <TeamID>]
#
# selector 默认按 accessibility id 查找（Flutter Semantics.identifier → accessibilityIdentifier）
# 其它 using: id / xpath / class name / -ios predicate string / -ios class chain
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_common.sh"

PLATFORM=""; VALUE=""; USING="accessibility id"; APP_ID=""; UDID=""; TEAM_ID=""; WAIT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --platform) [ $# -ge 2 ] || { echo "❌ --platform 缺参数值"; exit 2; }; PLATFORM="$2"; shift 2 ;;
    --using)    [ $# -ge 2 ] || { echo "❌ --using 缺参数值"; exit 2; };    USING="$2"; shift 2 ;;
    --app-id)   [ $# -ge 2 ] || { echo "❌ --app-id 缺参数值"; exit 2; };   APP_ID="$2"; shift 2 ;;
    --udid)     [ $# -ge 2 ] || { echo "❌ --udid 缺参数值"; exit 2; };     UDID="$2"; shift 2 ;;
    --team-id)  [ $# -ge 2 ] || { echo "❌ --team-id 缺参数值"; exit 2; };  TEAM_ID="$2"; shift 2 ;;
    --wait)     [ $# -ge 2 ] || { echo "❌ --wait 缺参数值"; exit 2; };     WAIT="$2"; shift 2 ;;
    -*) echo "❌ 未知参数: $1"; exit 1 ;;
    *)  VALUE="$1"; shift ;;
  esac
done

# --wait 会不加引号展开成参数，必须先挡掉非数字，避免分词/通配符产生晦涩报错
if [ -n "$WAIT" ]; then
  case "$WAIT" in
    .|*[!0-9.]*|*.*.*) echo "❌ --wait 需为非负数字（秒）: $WAIT"; exit 2 ;;
  esac
fi

case "$PLATFORM" in
  macos|ios-device) ;;
  *) echo "❌ 用法: ./tap.sh \"<selector>\" --platform macos|ios-device [--using ...]"; exit 1 ;;
esac
[ -n "$VALUE" ] || { echo "❌ 缺 selector"; exit 1; }

require_appium
ensure_appium_server

CAPS="$LOG_DIR/.appium_caps.json"
case "$PLATFORM" in
  macos)      write_caps_macos "$CAPS" "$APP_ID" ;;
  ios-device) [ -n "$TEAM_ID" ] && export IOS_TEAM_ID="$TEAM_ID"; write_caps_ios_device "$CAPS" "$APP_ID" "$UDID" ;;
esac

WAIT_ARGS=""
[ -n "$WAIT" ] && WAIT_ARGS="--wait $WAIT"
echo "🖱️  [$PLATFORM] find-click: using=$USING value='$VALUE'"
# shellcheck disable=SC2086  # WAIT_ARGS 为空时必须展开成 0 个参数
python3 "$DRIVER_PY" find-click --server "$APPIUM_SERVER" --caps "$CAPS" --using "$USING" --value "$VALUE" $WAIT_ARGS