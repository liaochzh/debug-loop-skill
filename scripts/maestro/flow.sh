#!/bin/bash
# flow.sh — 执行 Maestro YAML 流程（Android / iOS 模拟器通用，同 YAML 跨端）
#
# 用法:
#   ./flow.sh <flow.yaml> [--platform android|ios] [--device <id>] [--app-id <id>]
#
# 说明:
#   - <flow.yaml> 为相对路径或绝对路径；若未含 appId 头，按平台从 .debug.env 注入
#   - 未指定 --platform 时按在线设备自动判定；--device 为空则 Maestro 自行选择
#   - 整流程一次调用，避免逐击 CLI 的驱动启动开销
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_common.sh"

FLOW=""; PLATFORM=""; DEVICE=""; APP_ID=""; DEVICE_SET=false

while [ $# -gt 0 ]; do
  case "$1" in
    --platform) [ $# -ge 2 ] || { echo "❌ --platform 缺参数值"; exit 2; }; PLATFORM="$2"; shift 2 ;;
    --device)   [ $# -ge 2 ] || { echo "❌ --device 缺参数值"; exit 2; };   DEVICE="$2"; DEVICE_SET=true; shift 2 ;;
    --app-id)   [ $# -ge 2 ] || { echo "❌ --app-id 缺参数值"; exit 2; };   APP_ID="$2"; shift 2 ;;
    -*) echo "❌ 未知参数: $1"; exit 1 ;;
    *)  FLOW="$1"; shift ;;
  esac
done

[ -n "$FLOW" ] || { echo "❌ 用法: ./flow.sh <flow.yaml> [--platform android|ios] [--device <id>] [--app-id <id>]"; exit 1; }
# 兼容相对项目根解析
case "$FLOW" in /*) : ;; *) FLOW="$(pwd)/$FLOW" ;; esac

require_maestro
PLATFORM=$(detect_platform "$PLATFORM")
[ -n "$APP_ID" ] || APP_ID=$(resolve_app_id "$PLATFORM")
[ "$DEVICE_SET" = true ] || DEVICE=$(resolve_device "$PLATFORM" || true)

echo "🎭 平台: $PLATFORM ${DEVICE:+| 设备: $DEVICE} | appId: ${APP_ID:-<流程自带>}"

TMP_YAML="$LOG_DIR/.maestro_flow.yaml"
prepare_flow "$FLOW" "$APP_ID" "$TMP_YAML"

run_maestro "$TMP_YAML" "$DEVICE"