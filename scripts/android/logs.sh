#!/bin/bash
# logs.sh — 抓取当前 App 的 logcat 日志
# 用法: ./logs.sh [行数] [关键词]   默认 200 行，无过滤
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_common.sh"

LINES="${1:-200}"
FILTER="${2:-}"

DEVICE=$(require_device)

# 解析真实 appId（含 flavor suffix），避免 pidof 抓错包
APK_PATH=$(resolve_apk "$DEVICE" 2>/dev/null || true)
if [ -n "$APK_PATH" ] && [ -f "$APK_PATH" ]; then
  EFFECTIVE_APP_ID=$(resolve_app_id "$APK_PATH" 2>/dev/null || echo "$ANDROID_APP_ID")
fi
PID=$(app_pid "$DEVICE")

if [ -z "$PID" ]; then
  echo "❌ App 未运行 (package: $EFFECTIVE_APP_ID)，请先运行 ./run.sh"
  exit 1
fi

LOG_FILE="$LOG_DIR/latest.log"

echo "📱 设备: $DEVICE"
echo "📦 App: $EFFECTIVE_APP_ID (PID: $PID)"

# Android 7+ 支持 --pid，旧版本降级全量
# ⚠️ 末尾 `|| true`：adb 瞬时失败（offline 竞态/设备重启）时管道退非 0，在 `set -euo pipefail` 下会**静默终止**，
#    使下面的「⚠️ Android < 7.0」降级提示与日志抓取永不可达（2026-10-17 形态清单清扫发现；同为第 44 行的取舍）。
#    注意：`SDK` 为空在此处是**合法状态**（设计上按 <7.0 全量降级），故不可让 adb 的失败语义穿透。
SDK=$(adb -s "$DEVICE" shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r' || true)
if [ "$SDK" -ge 24 ] 2>/dev/null; then
  # ⚠️ 失败须**可见**：裸 `adb logcat … 2>/dev/null` 在 adb 掉线/App 退出时会静默终止、零提示
  #    （F1 修好后同一条 adb 竞态的终止点即下移到此）。（2026-10-17 复审发现）
  adb -s "$DEVICE" logcat -d --pid="$PID" > "$LOG_FILE" 2>/dev/null \
    || { echo "❌ logcat 抓取失败（adb 掉线或 App 已退出？），请重试"; exit 1; }
else
  echo "⚠️  Android < 7.0，无法按 PID 过滤，抓取全量日志"
  adb -s "$DEVICE" logcat -d > "$LOG_FILE" 2>/dev/null \
    || { echo "❌ logcat 抓取失败（adb 掉线？），请重试"; exit 1; }
fi

if [ -n "$FILTER" ]; then
  # ⚠️ 末尾 `|| true`：无匹配时 `grep` 返回 1，经 `| tail` 在 `set -euo pipefail` 下会**静默终止**，
  #    使下面的「📭 无匹配」永不可达（2026-10-17 由审查发现；旁证：同文件第 54 行同类写法早有 `|| echo`）。
  MATCHES=$(grep -iE "$FILTER" "$LOG_FILE" | tail -n "$LINES" || true)
  if [ -n "$MATCHES" ]; then
    echo "$MATCHES"
  else
    echo "📭 无匹配 '$FILTER' 的日志"
  fi
else
  tail -n "$LINES" "$LOG_FILE"
fi

echo ""
echo "=== 异常摘要 ==="
grep -iE "exception|error|fatal" "$LOG_FILE" | head -20 || echo "无异常"
echo ""
echo "📁 完整日志: $LOG_FILE"
