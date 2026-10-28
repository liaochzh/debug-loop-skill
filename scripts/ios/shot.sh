#!/bin/bash
# shot.sh — iOS 截图到 build/debug/screen.png
#   模拟器：simctl io screenshot
#   真机：devicectl device capture screenshot（失败时回退 idevicescreenshot）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_common.sh"

# 命令行 --device ⇒ 真机目标（等价 IOS_TARGET=device；避免 env 前缀破坏 shell 白名单匹配）
for _arg in "$@"; do
  [ "$_arg" = "--device" ] && IOS_TARGET=device
done

SCREEN_FILE="$LOG_DIR/screen.png"
TARGET=$(resolve_ios_target)

if [ "$TARGET" = "device" ]; then
  UDID=$(require_ios_device)
  echo "📱 真机: ${UDID} — 📸 截图中..."
  if ! xcrun devicectl device capture screenshot --device "$UDID" --destination "$SCREEN_FILE" >/dev/null 2>&1; then
    echo "⚠️  devicectl 截图失败，回退 idevicescreenshot（需已挂载 DDI）"
    idevicescreenshot -u "$UDID" "$SCREEN_FILE"
  fi
else
  UDID=$(require_simulator)
  echo "📱 模拟器: ${UDID} — 📸 截图中..."
  # 外置卷（/Volumes/*）上 simctl 直写会被 TCC 拒（NSPOSIXErrorDomain 1）；
  # 先落 $TMPDIR 再 cp（宿主 shell 有该卷权限）。
  if ! xcrun simctl io "$UDID" screenshot "$SCREEN_FILE" 2>/dev/null; then
    TMP_PNG="${TMPDIR:-/tmp}/debug-loop-sim-${UDID}.png"
    xcrun simctl io "$UDID" screenshot "$TMP_PNG" >/dev/null 2>&1 || { echo "❌ 模拟器截图失败"; exit 1; }
    cp "$TMP_PNG" "$SCREEN_FILE" && rm -f "$TMP_PNG"
  fi
fi

if [ -s "$SCREEN_FILE" ]; then
  SIZE=$(wc -c < "$SCREEN_FILE" | xargs)
  echo "✅ 截图完成: $SCREEN_FILE (${SIZE} bytes)"
else
  echo "❌ 截图失败"
  exit 1
fi
