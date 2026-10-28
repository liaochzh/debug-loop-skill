#!/bin/bash
# logwatch.sh — 持续监听 App 日志，等「新的」指定签名出现或超时（App 重启自动跟随新 PID）
#
# 用法: ./logwatch.sh <签名> [超时秒=60] [轮询间隔秒=2]
#     前台直调时超时秒建议 ≤100（shell 工具前台 120s 上限）；更长等待用 bg.sh 包装本脚本。
# 退出码: 0=命中新签名 / 1=超时未命中 / 2=用法错误 / 3=环境问题（无设备、非项目根、App 全程未启动）
#
# 与 logs.sh 的区别：logs.sh 是一次性抓取（logcat -d），本脚本是「等到某个日志出现」。
# 关键设计：每轮动态 app_pid → App 重装/重启后自动跟上新 PID，不会像写死 PID 的
#           `adb logcat --pid=<旧PID>` 那样僵死成孤儿进程。
# 防假命中：以启动时刻为分界（logcat -T），只认「启动后新产生」的签名；无法取时间戳时退化为计数基线。
# 注意：判据签名必须真实存在——调用前先在源码里 grep 确认，勿用方法名猜测。

set -uo pipefail   # 不加 -e：轮询内单次 adb 失败不应中止整个等待

# 参数校验放在 source 之前：即便不在项目根，也能拿到 rc=2 而非环境错误
SIG="${1:-}"
TIMEOUT="${2:-60}"
INTERVAL="${3:-2}"
if [ -z "$SIG" ]; then
  echo "❌ 用法: logwatch.sh <签名> [超时秒=60] [轮询间隔秒=2]" >&2
  exit 2
fi
case "${TIMEOUT}${INTERVAL}" in
  *[!0-9]*) echo "❌ 超时/间隔需为非负整数（收到: ${TIMEOUT} / ${INTERVAL}）" >&2; exit 2 ;;
esac
[ "$INTERVAL" -ge 1 ] || { echo "❌ 轮询间隔需 ≥1（收到: ${INTERVAL}）" >&2; exit 2; }
[ "$INTERVAL" -le 30 ] || echo "⚠️  轮询间隔 ${INTERVAL}s 偏大，易撞前台 120s 上限；长等待请调小间隔并用 bg.sh" >&2
[ "$TIMEOUT" -gt 100 ] && echo "⚠️  超时 ${TIMEOUT}s > 100：前台直调会被 120s 强杀，请用 bg.sh start 包装本脚本" >&2

# 环境守卫：避免 _common.sh 在 source 时的环境校验 exit 1 被误读为「签名未命中」
# 注：只要求 .debug.env（Flutter 或原生 Android 工程均可 —— 工程类型由 _common.sh 探测）
if [ ! -f ".debug.env" ]; then
  echo "❌ 需在项目根执行，且已有 .debug.env（先跑 debug-loop 的 init.sh）" >&2
  exit 3
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_common.sh"

# require_device 失败 = 环境问题（rc=3），不得当作「签名未命中」
DEVICE="$(require_device)" || exit 3

# 解析真实 appId（含 flavor suffix）——必须在 app_pid 之前，否则 pidof 会抓错包。
# 不加 2>/dev/null：回退告警打 stderr，需透出以免静默抓错包。
APK_PATH="$(resolve_apk "$DEVICE" || true)"
if [ -n "$APK_PATH" ] && [ -f "$APK_PATH" ]; then
  EFFECTIVE_APP_ID="$(resolve_app_id "$APK_PATH" || echo "$ANDROID_APP_ID")"
else
  echo "⚠️  未能从 APK 解析 appId，按 ANDROID_APP_ID=${ANDROID_APP_ID} 匹配；flavor 项目可能 pidof 失败（请先 build.sh 或设 ANDROID_APK_PATH）" >&2
fi

# Android 7+ 才支持 logcat --pid；已知低版本降级全量。SDK 未知/非数字时按现代设备处理（保守用 --pid）。
SDK="$(adb -s "$DEVICE" shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')"
case "$SDK" in ''|*[!0-9]*) SDK="" ;; esac
PID_ARG="--pid"
if [ -n "$SDK" ] && [ "$SDK" -lt 24 ]; then
  echo "  ⚠️  SDK=${SDK} < 24，logcat 不支持 --pid，降级全量抓取" >&2
  PID_ARG=""
fi

# 起始时刻：仅统计此后产生的日志，避免把「启动前已存在」的签名误判为新命中（logcat -T）
START_TS="$(adb -s "$DEVICE" shell 'date +"%m-%d %H:%M:%S.000"' 2>/dev/null | tr -d '\r')"
case "$START_TS" in
  [0-9][0-9]-[0-9][0-9]\ [0-9][0-9]:[0-9][0-9]:[0-9][0-9]*) : ;;
  *) START_TS="" ;;
esac
[ -z "$START_TS" ] && echo "  ⚠️  无法取得设备时间戳，改用计数基线（启动前已存在的同名签名可能被误判）" >&2

echo "📱 设备: ${DEVICE} | App: ${EFFECTIVE_APP_ID} | 签名: '${SIG}' | 超时: ${TIMEOUT}s"

# 输出当前 App 日志；有 START_TS 时只取启动后（$1=PID）
dump_app() {
  if [ -n "$PID_ARG" ]; then
    if [ -n "$START_TS" ]; then adb -s "$DEVICE" logcat -d -T "$START_TS" --pid="$1" 2>/dev/null || true
    else adb -s "$DEVICE" logcat -d --pid="$1" 2>/dev/null || true; fi
  else
    if [ -n "$START_TS" ]; then adb -s "$DEVICE" logcat -d -T "$START_TS" 2>/dev/null || true
    else adb -s "$DEVICE" logcat -d 2>/dev/null || true; fi
  fi
}
# 统计签名出现次数（无 -q：grep -q 命中即退出会给 printf 发 SIGPIPE，pipefail 下误判未命中）
count_hits() { printf '%s\n' "$1" | grep -F -c -e "$SIG" || true; }

START="$SECONDS"
BASE_PID=""; BASE_N=""; SEEN_PID=0
while :; do
  NOW=$(( SECONDS - START ))
  PID="$(app_pid "$DEVICE")"
  if [ -z "$PID" ]; then
    echo "  [${NOW}s] ⚠️  App 未运行，等待重启…" >&2
  else
    SEEN_PID=1
    DUMP="$(dump_app "$PID")"
    HIT=0
    if [ -n "$START_TS" ]; then
      [ "$(count_hits "$DUMP")" -gt 0 ] && HIT=1
    elif [ "$PID" != "$BASE_PID" ]; then
      BASE_PID="$PID"; BASE_N="$(count_hits "$DUMP")"
      echo "  [${NOW}s] 监听 PID=${PID}（计数基线 ${BASE_N} 条）"
    else
      [ "$(count_hits "$DUMP")" -gt "${BASE_N:-0}" ] && HIT=1
    fi
    if [ "$HIT" -eq 1 ]; then
      echo "✅ 命中新签名（PID=${PID}，耗时约 $(( SECONDS - START ))s）"
      [ -n "$PID_ARG" ] || echo "   ⚠️ 全量模式命中，请核对命中行是否属目标 App"
      printf '%s\n' "$DUMP" | grep -F -e "$SIG" | tail -10
      exit 0
    fi
  fi
  # 至少轮询一次后再判超时（TIMEOUT=0 ≡ 一次查询，与 bg.sh 语义一致）
  [ "$NOW" -ge "$TIMEOUT" ] && break
  sleep "$INTERVAL"
done

if [ "$SEEN_PID" -eq 0 ]; then
  echo "❌ 超时约 ${TIMEOUT}s：App 全程未启动（PID 一直为空）——请先 run.sh 启动 App" >&2
  exit 3
fi
echo "❌ 超时约 ${TIMEOUT}s 未出现新签名 '${SIG}'"
echo "   排查：1) 判据签名是否真实（先在源码 grep 确认）；2) 是否该签名在启动前已存在（基线已含，需触发新动作或先 logclear.sh）"
exit 1