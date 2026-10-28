#!/bin/bash
# run.sh — 冷启动 App（force-stop → install → am start）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_common.sh"

DEVICE=$(require_device)

# 先解析产物以拿到真实 appId（含 flavor suffix），再 force-stop
# ⚠️ `|| true`：非 Flutter 项目可能没有 APK（resolve_apk 返回 1）—— 无守卫时会在 set -e 下**静默终止**
APK_PATH=$(resolve_apk "$DEVICE" || true)
if [ -n "$APK_PATH" ] && [ -f "$APK_PATH" ]; then
  EFFECTIVE_APP_ID=$(resolve_app_id "$APK_PATH")
fi
ACTIVITY=$(full_activity)

echo "📱 设备: $DEVICE"
echo "🛑 停止已运行的 App: $EFFECTIVE_APP_ID"
adb -s "$DEVICE" shell am force-stop "$EFFECTIVE_APP_ID"

if [ -n "$APK_PATH" ] && [ -f "$APK_PATH" ]; then
  bash "$SCRIPT_DIR/install.sh"
else
  echo "ℹ️  未找到 APK —— 跳过安装，使用设备上已安装的版本"
fi

echo "🚀 启动: $ACTIVITY"
adb -s "$DEVICE" shell am start -n "$ACTIVITY"

sleep 3

PID=$(app_pid "$DEVICE")
if [ -n "$PID" ]; then
  echo "✅ App 已启动，PID: $PID"
else
  echo "⚠️  App 可能未完全启动，稍后可用 ./logs.sh 检查"
fi
