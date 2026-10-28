#!/bin/bash
# flow.sh — Appium 单会话多步流程（iOS 真机 xcuitest / macOS mac2）
#
# 用法:
#   ./flow.sh <steps.json> --platform ios-device|macos
#            [--app-id <id>] [--udid <udid>] [--team-id <TeamID>]
#
# 说明:
#   - iOS 真机每次新建会话都会重启被测 App ⇒ 多步操作必须在一个会话内完成，故提供本脚本
#   - steps.json 为步骤数组，格式见 driver.py 头部注释（tap / type / assert / exec / shot / source / wait）
#   - 退出码: 0 全部步骤成功 / 1 某步失败 / 2 用法错误 / 3 会话或驱动错误
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_common.sh"

FLOW=""; PLATFORM=""; APP_ID=""; UDID=""; TEAM_ID=""

while [ $# -gt 0 ]; do
  case "$1" in
    --platform) [ $# -ge 2 ] || { echo "❌ --platform 缺参数值"; exit 2; }; PLATFORM="$2"; shift 2 ;;
    --app-id)   [ $# -ge 2 ] || { echo "❌ --app-id 缺参数值"; exit 2; };   APP_ID="$2"; shift 2 ;;
    --udid)     [ $# -ge 2 ] || { echo "❌ --udid 缺参数值"; exit 2; };     UDID="$2"; shift 2 ;;
    --team-id)  [ $# -ge 2 ] || { echo "❌ --team-id 缺参数值"; exit 2; };  TEAM_ID="$2"; shift 2 ;;
    -*) echo "❌ 未知参数: $1"; exit 1 ;;
    *)  FLOW="$1"; shift ;;
  esac
done

case "$PLATFORM" in
  macos|ios-device) ;;
  *) echo "❌ 用法: ./flow.sh <steps.json> --platform macos|ios-device [--app-id ...] [--udid ...] [--team-id ...]"; exit 2 ;;
esac
[ -n "$FLOW" ] || { echo "❌ 缺 steps.json 路径"; exit 2; }
[ -f "$FLOW" ] || { echo "❌ steps 文件不存在: $FLOW"; exit 2; }
case "$FLOW" in /*) : ;; *) FLOW="$(pwd)/$FLOW" ;; esac

require_appium
ensure_appium_server

CAPS="$LOG_DIR/.appium_caps.json"
case "$PLATFORM" in
  macos)      write_caps_macos "$CAPS" "$APP_ID" ;;
  ios-device) [ -n "$TEAM_ID" ] && export IOS_TEAM_ID="$TEAM_ID"; write_caps_ios_device "$CAPS" "$APP_ID" "$UDID" ;;
esac

echo "🎬 [$PLATFORM] flow steps: $FLOW"
python3 "$DRIVER_PY" flow --server "$APPIUM_SERVER" --caps "$CAPS" --steps "$FLOW"