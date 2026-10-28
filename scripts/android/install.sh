#!/bin/bash
# install.sh — 安装 debug APK 到设备
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_common.sh"

DEVICE=$(require_device)

APK_PATH=$(resolve_apk "$DEVICE" || true)   # ⚠️ 守卫：无守卫时 resolve_apk 失败会在 set -e 下静默终止
if [ -z "$APK_PATH" ] || [ ! -f "$APK_PATH" ]; then
  echo "❌ 未找到可用 APK，请先运行 ./build.sh"
  exit 1
fi
EFFECTIVE_APP_ID=$(resolve_app_id "$APK_PATH")

# release 包去 -t（test 标记），debug 保持 -r -t
INSTALL_FLAGS="-r -t"
case "$APK_PATH" in
  *-release.apk) INSTALL_FLAGS="-r" ;;
esac

echo "📱 设备: $DEVICE"
echo "📦 安装: ${APK_PATH}（appId: ${EFFECTIVE_APP_ID}）"
adb -s "$DEVICE" install $INSTALL_FLAGS "$APK_PATH"
echo "✅ 安装完成"
