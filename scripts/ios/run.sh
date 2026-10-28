#!/bin/bash
# run.sh — 安装并冷启动 iOS 应用（模拟器走 simctl；真机走 devicectl）
#
# 目标选择：IOS_TARGET=device|simulator（默认 simulator）；IOS_DEVICE_UDID 非空 ⇒ device。
#
# 模拟器日志：`simctl launch --console-pty` 把 App stdout/stderr 写入 build/debug/app.log。
# 真机日志：后台 `idevicesyslog --syslog-relay \| grep "Runner("` 过滤采集到 app.log（采集器未存活会告警）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_common.sh"

# 命令行 --device ⇒ 真机目标（等价 IOS_TARGET=device；避免 env 前缀破坏 shell 白名单匹配）
for _arg in "$@"; do
  [ "$_arg" = "--device" ] && IOS_TARGET=device
done

TARGET=$(resolve_ios_target)
echo "🎯 目标: $TARGET"

if [ "$TARGET" = "device" ]; then
  # 真机日志与模拟器日志分文件，避免同卷交叉写入
  APP_LOG="$LOG_DIR/app_device.log"
  APP_PATH=$(resolve_ios_app device) || exit 1
  if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    echo "❌ 未找到真机 .app（build/ios/iphoneos），请先运行 ./build.sh"
    exit 1
  fi
  EFFECTIVE_BUNDLE_ID=$(resolve_bundle_id "$APP_PATH")
  UDID=$(require_ios_device)
  echo "📱 真机: ${UDID}（bundle: ${EFFECTIVE_BUNDLE_ID}）"

  # 日志：先清理旧采集进程，再后台采集
  # `--syslog-relay` 只取 relay 流（默认流是全设备历史，几秒可涨到 ~95MB）；
  # 再按进程名 `Runner(`/`Runner[` 过滤，只留本 App 行。
  # ⚠️ 整段放进子 shell 并重定向 fd：否则后台进程继承调用方 stdout，
  #    调用方管道（如 `| tail`）会一直等 EOF 而挂死。
  # 停掉上一次采集（pid 文件第 2 行记了 UDID ⇒ 多设备时不杀错）
  stop_ios_syslog_capture "$UDID"
  sleep 1

  : > "$APP_LOG"
  (
    idevicesyslog --syslog-relay -u "$UDID" --no-colors 2>/dev/null \
      | grep --line-buffered -E "Runner[(\[]" >> "$APP_LOG"
  ) >/dev/null 2>&1 &
  printf '%s\n%s\n' "$!" "$UDID" > "$LOG_DIR/syslog.pid"

  # 采集器存活检查（命令缺失/DDI 不可用时明确告警，避免空日志被当成「无异常」）
  sleep 1
  if ! ios_syslog_capture_running "$UDID"; then
    echo "⚠️  idevicesyslog 未在运行（日志可能为空）：检查 idevicesyslog 是否安装、设备是否已挂载 DDI"
  fi

  echo "📦 安装: ${APP_PATH}"
  xcrun devicectl device install app --device "$UDID" "$APP_PATH"

  echo "🚀 启动: ${EFFECTIVE_BUNDLE_ID}"
  LAUNCH_ERR_FILE="$LOG_DIR/.launch_stderr.log"
  LAUNCH_RC=0
  LAUNCH_JSON=$(xcrun devicectl device process launch --device "$UDID" --terminate-existing \
    --json-output - "$EFFECTIVE_BUNDLE_ID" 2>"$LAUNCH_ERR_FILE") || LAUNCH_RC=$?
  if [ "$LAUNCH_RC" -ne 0 ]; then
    echo "❌ 启动失败（devicectl rc=${LAUNCH_RC}）"
    tail -20 "$LAUNCH_ERR_FILE" 2>/dev/null || true
    exit 1
  fi
  PID=$(printf '%s' "$LAUNCH_JSON" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin)["result"]["process"]["processIdentifier"])
except Exception:
    pass
' 2>/dev/null || true)

  if [ -n "$PID" ]; then
    echo "   devicectl 返回 PID: $PID"
  fi
  sleep 3
  if [ -n "$PID" ] && xcrun devicectl device info processes --device "$UDID" 2>/dev/null \
      | awk -v p="$PID" '$1 == p { found = 1 } END { exit found ? 0 : 1 }'; then
    echo "✅ App 已启动（PID: ${PID}）"
  else
    echo "⚠️  未确认到 App 进程（PID=${PID:-未知}）：用 ./shot.sh 与 ./logs.sh 复核；启动 stderr 见 ${LAUNCH_ERR_FILE}"
  fi
  echo "ℹ️  日志采集进程常驻中（持续写 app_device.log）；结束调试请运行: bash ${SCRIPT_DIR}/logclear.sh --device"
  exit 0
fi

# 模拟器目标：若真机采集进程还在跑，先停掉（pid 文件里的 UDID 保证只杀自己那台）
stop_ios_syslog_capture

SIM_APP_PATH=$(resolve_ios_app simulator)
if [ -z "$SIM_APP_PATH" ] || [ ! -d "$SIM_APP_PATH" ]; then
  echo "❌ 未找到 .app，请先运行 ./build.sh"
  exit 1
fi
EFFECTIVE_BUNDLE_ID=$(resolve_bundle_id "$SIM_APP_PATH")

UDID=$(require_simulator)
echo "📱 模拟器: $UDID"

# 停止已运行的 App
xcrun simctl terminate "$UDID" "$EFFECTIVE_BUNDLE_ID" 2>/dev/null || true

echo "📦 安装: ${SIM_APP_PATH}（bundle: ${EFFECTIVE_BUNDLE_ID}）"
xcrun simctl install "$UDID" "$SIM_APP_PATH"

echo "🚀 启动: ${EFFECTIVE_BUNDLE_ID}（日志 → ${APP_LOG}）"
: > "$APP_LOG"
nohup xcrun simctl launch --console-pty "$UDID" "$EFFECTIVE_BUNDLE_ID" >> "$APP_LOG" 2>&1 &
echo $! > "$LOG_DIR/app.pid"

sleep 3

# 校验 App 进程已启动
if xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | grep -q "$EFFECTIVE_BUNDLE_ID"; then
  echo "✅ App 已启动"
else
  echo "⚠️  未确认到 App 进程，请用 ./shot.sh 或 ./logs.sh 检查"
fi
