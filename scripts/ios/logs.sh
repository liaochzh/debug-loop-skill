#!/bin/bash
# logs.sh — 查看 iOS 应用日志（模拟器 build/debug/app.log / 真机 app_device.log）
# 用法: ./logs.sh [--device] [--app-only] [行数] [关键词]
#   --device    切到真机日志（等价 IOS_TARGET=device）
#   --app-only  只保留 App 进程行（syslog 头部的 Runner(...)[pid]），过滤 Sandbox/kernel 噪声
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_common.sh"

APP_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --device)   IOS_TARGET=device; shift ;;
    --app-only) APP_ONLY=1; shift ;;
    --*) echo "❌ 未知参数: $1（支持 --device / --app-only）" >&2; exit 2 ;;
    *) break ;;
  esac
done

LINES="${1:-200}"
FILTER="${2:-}"

# 真机日志独立文件（run.sh --device 写入）
[ "$(resolve_ios_target)" = "device" ] && APP_LOG="$LOG_DIR/app_device.log"

if [ ! -f "$APP_LOG" ]; then
  echo "❌ 日志文件不存在: ${APP_LOG}，请先运行 ./run.sh" >&2
  exit 1
fi

# 只取「进程名就是 Runner」的行：syslog 头部形如
#   Oct 23 19:17:18 Runner(Flutter)[123] <Notice>: ...
# kernel(Sandbox)[0] <Error>: Sandbox: Runner(123) deny(...) 虽含 "Runner(" 但不是 App 进程，被过滤。
APP_LINE_RE='^[A-Z][a-z]{2} [ 0-9][0-9] [0-9:.]+ Runner[(\[]'
if [ "$APP_ONLY" = 1 ]; then
  VIEW=$(grep -E "$APP_LINE_RE" "$APP_LOG" || true)
else
  VIEW=$(cat "$APP_LOG")
fi

if [ -n "$FILTER" ]; then
  # ⚠️ 末尾 `|| true`：无匹配时 `grep` 返回 1，经 `| tail` 在 `set -euo pipefail` 下会**静默终止**，
  #    使下面的「📭 无匹配」永不可达（2026-10-17 全树清扫发现：与 android 版修复前逐字同构）。
  MATCHES=$(printf '%s\n' "$VIEW" | grep -i "$FILTER" | tail -n "$LINES" || true)
  if [ -n "$MATCHES" ]; then
    echo "$MATCHES"
  else
    echo "📭 无匹配 '$FILTER' 的日志"
  fi
else
  if [ -z "$VIEW" ]; then
    if [ "$APP_ONLY" = 1 ]; then
      echo "📭 无 App 日志（--app-only：可能尚未输出，或 App 进程名不是 Runner）"
    else
      echo "📭 无日志"
    fi
  else
    printf '%s\n' "$VIEW" | tail -n "$LINES"
  fi
fi

echo ""
echo "=== 异常摘要 ==="
# 用 awk 自己限行（不用 grep|head）：匹配行超管道缓冲时 head 提前退出会让 grep 收 SIGPIPE，
# 在 pipefail 下既打印了 20 行又追加「无异常」，自相矛盾。
EXC=$(printf '%s\n' "$VIEW" | awk 'tolower($0) ~ /exception|error|fatal/ { print; if (++n >= 20) exit }')
if [ -n "$EXC" ]; then echo "$EXC"; else echo "无异常"; fi
echo ""
echo "📁 完整日志: $APP_LOG"
