#!/bin/bash
# _platform_detect.sh — 平台自动判定（`snapshot.sh` / `tap_snapshot.sh` 共用，避免两份逻辑漂移）
#
# 用法（在 `set -euo pipefail` 下）:
#   source "$SCRIPT_DIR/_platform_detect.sh"
#   PLATFORM=$(detect_platform || true)
#   [ -n "$PLATFORM" ] || { echo "❌ 无法自动判定平台…" >&2; exit 3; }
#
# 判定顺序:
#   1. `adb devices` 有 state=device 的设备 ⇒ android
#   2. 有已启动的 iOS 模拟器（`xcrun simctl list devices booted` 含 Booted）⇒ ios
#   3. 都不满足 ⇒ 返回 1（**不打印、不退出**，提示与退出码由调用方决定）
#
# ⚠️ 本文件只定义函数，不执行任何动作，可安全 source。

detect_platform() {
  if command -v adb >/dev/null 2>&1 && adb devices 2>/dev/null | awk 'NR>1 && $2=="device"{f=1} END{exit !f}'; then
    echo android
  elif command -v xcrun >/dev/null 2>&1 && xcrun simctl list devices booted 2>/dev/null | grep -q "Booted"; then
    echo ios
  else
    return 1
  fi
}
