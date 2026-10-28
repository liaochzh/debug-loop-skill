#!/bin/bash
# assert.sh — Appium 语义断言（macOS mac2 / iOS 真机 xcuitest）
#
# 用法:
#   ./assert.sh "<selector>" --platform macos|ios-device [--using ...] [--app-id] [--udid] [--team-id]
#   ./assert.sh "<selector>" --not-visible ...     # 断言不存在
#
# 退出码: 0 = 断言成立；1 = 断言失败；3 = 驱动/会话错误
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_common.sh"

PLATFORM=""; VALUE=""; USING="accessibility id"; APP_ID=""; UDID=""; TEAM_ID=""; NOT_VISIBLE=false
while [ $# -gt 0 ]; do
  case "$1" in
    --platform) [ $# -ge 2 ] || { echo "❌ --platform 缺参数值"; exit 2; }; PLATFORM="$2"; shift 2 ;;
    --using)    [ $# -ge 2 ] || { echo "❌ --using 缺参数值"; exit 2; };    USING="$2"; shift 2 ;;
    --app-id)   [ $# -ge 2 ] || { echo "❌ --app-id 缺参数值"; exit 2; };   APP_ID="$2"; shift 2 ;;
    --udid)     [ $# -ge 2 ] || { echo "❌ --udid 缺参数值"; exit 2; };     UDID="$2"; shift 2 ;;
    --team-id)  [ $# -ge 2 ] || { echo "❌ --team-id 缺参数值"; exit 2; };  TEAM_ID="$2"; shift 2 ;;
    --not-visible) NOT_VISIBLE=true; shift ;;
    -*) echo "❌ 未知参数: $1"; exit 1 ;;
    *)  VALUE="$1"; shift ;;
  esac
done

case "$PLATFORM" in
  macos|ios-device) ;;
  *) echo "❌ 用法: ./assert.sh \"<selector>\" --platform macos|ios-device [--using ...]"; exit 1 ;;
esac
[ -n "$VALUE" ] || { echo "❌ 缺 selector"; exit 1; }

require_appium
ensure_appium_server

CAPS="$LOG_DIR/.appium_caps.json"
case "$PLATFORM" in
  macos)      write_caps_macos "$CAPS" "$APP_ID" ;;
  ios-device) [ -n "$TEAM_ID" ] && export IOS_TEAM_ID="$TEAM_ID"; write_caps_ios_device "$CAPS" "$APP_ID" "$UDID" ;;
esac

set +e
python3 "$DRIVER_PY" find-assert --server "$APPIUM_SERVER" --caps "$CAPS" --using "$USING" --value "$VALUE"
code=$?
set -e

if [ "$NOT_VISIBLE" = true ]; then
  if [ "$code" -eq 1 ]; then echo "✅ 断言成立：'$VALUE' 不存在"; exit 0; fi
  if [ "$code" -eq 0 ]; then echo "❌ 断言失败：'$VALUE' 存在"; exit 1; fi
  exit "$code"
else
  if [ "$code" -eq 0 ]; then echo "✅ 断言成立：'$VALUE' 存在"; exit 0; fi
  if [ "$code" -eq 1 ]; then echo "❌ 断言失败：'$VALUE' 不存在"; exit 1; fi
  exit "$code"
fi