#!/bin/bash
# logclear.sh — 清空 logcat 缓冲（复现前用）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_common.sh"

DEVICE=$(require_device)
echo "📱 设备: $DEVICE — 🧹 清空 logcat 缓冲..."
adb -s "$DEVICE" logcat -c
echo "✅ 已清空"
