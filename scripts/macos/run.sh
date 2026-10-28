#!/bin/bash
# run.sh — 启动 macOS 应用（stdout/stderr → build/debug/app.log）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_common.sh"

APP_BUNDLE=$(resolve_macos_app)
if [ -z "$APP_BUNDLE" ] || [ ! -d "$APP_BUNDLE" ]; then
  echo "❌ 未找到 macOS .app，请先运行 ./build.sh"
  exit 1
fi
# 可执行名取自实际 bundle（兼容 PRODUCT_NAME 变化），回退 MACOS_APP_NAME
BIN_NAME=$(basename "$APP_BUNDLE" .app)
[ -x "$APP_BUNDLE/Contents/MacOS/$BIN_NAME" ] && BIN_PATH="$APP_BUNDLE/Contents/MacOS/$BIN_NAME" \
  || BIN_PATH="$APP_BUNDLE/Contents/MacOS/$MACOS_APP_NAME"

if [ ! -x "$BIN_PATH" ]; then
  echo "❌ 未找到可执行文件: ${BIN_PATH}，请先运行 ./build.sh"
  exit 1
fi

# 停止已运行实例
pkill -f "$BIN_PATH" 2>/dev/null || true
sleep 1

echo "🚀 启动: ${MACOS_APP_NAME}（日志 → ${APP_LOG}）"
: > "$APP_LOG"
nohup "$BIN_PATH" >> "$APP_LOG" 2>&1 &
echo $! > "$LOG_DIR/app.pid"

sleep 3

if kill -0 "$(cat "$LOG_DIR/app.pid")" 2>/dev/null; then
  echo "✅ App 已启动，PID: $(cat "$LOG_DIR/app.pid")"
else
  echo "⚠️  进程可能已退出，用 ./logs.sh 查看日志排查"
fi
