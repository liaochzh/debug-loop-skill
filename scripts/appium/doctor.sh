#!/bin/bash
# doctor.sh — Appium 环境自检（macOS mac2 / iOS 真机 xcuitest）
#
# 用法: ./doctor.sh [--platform macos|ios-device]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_common.sh"

PLATFORM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --platform) [ $# -ge 2 ] || { echo "❌ --platform 缺参数值"; exit 2; }; PLATFORM="$2"; shift 2 ;;
    -*) echo "❌ 未知参数: $1"; exit 1 ;;
    *)  PLATFORM="$1"; shift ;;
  esac
done

echo "== Appium 自检 =="
if command -v appium >/dev/null 2>&1; then
  echo "✅ appium: $(appium --version 2>/dev/null)"
else
  echo "❌ appium 未安装: npm install -g appium@3"
fi
echo "--- 已装驱动 ---"
appium driver list --installed 2>&1 | grep -E '^\s*-' || true

echo "--- python3 / requests ---"
if python3 -c "import requests" 2>/dev/null; then echo "✅ requests ok"; else echo "❌ python3 缺 requests: pip3 install requests"; fi

echo "--- Xcode ---"
xcodebuild -version 2>/dev/null | head -1 || echo "❌ 未检测到 Xcode"

echo "--- Appium 服务 ---"
if appium_online; then echo "✅ 已在线 ($APPIUM_SERVER)"; else echo "ℹ️  未运行（脚本会自动启动）"; fi

case "$PLATFORM" in
  macos)
    echo "--- macOS (mac2) ---"
    bid=$(resolve_macos_bundle_id)
    echo "BundleID: ${bid:-<未解析，请先 build.sh 或设 MACOS_APP_BUNDLE>}"
    echo "提示：mac2 需为 Xcode Helper 开启「辅助功能」权限："
    echo "  open /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/"
    echo "  （把 Xcode Helper 拖入 系统设置→隐私与安全性→辅助功能）"
    ;;
  ios-device)
    echo "--- iOS 真机 (xcuitest) ---"
    udid=$(resolve_ios_device || true)
    echo "设备 UDID: ${udid:-<未检测到真机>}"
    echo "TeamID: ${IOS_TEAM_ID:-<未设置，需 export IOS_TEAM_ID>}"
    ;;
  *) echo "ℹ️  加 --platform macos|ios-device 可查看平台专项前置" ;;
esac