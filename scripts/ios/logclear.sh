#!/bin/bash
# logclear.sh — 清理 iOS 日志（模拟器清 app.log；真机先停常驻采集再清 app_device.log）
#
# 用法: logclear.sh [--device]
#   --device 等价 IOS_TARGET=device。
#
# ⚠️ 真机采集由 run.sh --device 启动的 idevicesyslog 常驻写入，只清文件不停进程 ⇒
#    文件会立刻续写。故真机分支必须「先 kill 采集进程，再清空文件」，且停不掉时报错。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_common.sh"

# 首参 --device ⇒ 真机目标（等价 IOS_TARGET=device）
[ "${1:-}" = "--device" ] && { IOS_TARGET=device; shift; }

if [ "$(resolve_ios_target)" = "device" ]; then
  APP_LOG="$LOG_DIR/app_device.log"

  # pid 文件第 2 行记录了启动采集时的 UDID（多设备场景避免杀错其它设备的采集）
  REC_UDID=""
  if [ -f "$LOG_DIR/syslog.pid" ]; then
    REC_UDID=$(sed -n '2p' "$LOG_DIR/syslog.pid" 2>/dev/null || true)
  fi
  UDID="${REC_UDID:-$(detect_ios_device_udid 2>/dev/null || true)}"

  stop_ios_syslog_capture "${UDID:-}"
  sleep 1

  # 存活复核：进程异常未退时清空会被立刻续写（稀疏回填），必须显式失败而不是假装成功
  if ios_syslog_capture_running "${UDID:-}"; then
    echo "❌ 采集进程仍在运行，未清空日志（请检查: pgrep -fl idevicesyslog）" >&2
    exit 1
  fi

  : > "$APP_LOG"
  echo "✅ 已停止真机采集并清空 $APP_LOG"
else
  : > "$APP_LOG"
  echo "✅ 已清空 $APP_LOG"
fi
