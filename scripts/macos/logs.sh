#!/bin/bash
# logs.sh — 查看 macOS 应用日志（build/debug/app.log）
# 用法: ./logs.sh [行数] [关键词]   默认 200 行，无过滤
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_common.sh"

LINES="${1:-200}"
FILTER="${2:-}"

if [ ! -f "$APP_LOG" ]; then
   echo "❌ 日志文件不存在: ${APP_LOG}，请先运行 ./run.sh"
  exit 1
fi

if [ -n "$FILTER" ]; then
  # ⚠️ 末尾 `|| true`：无匹配时 `grep` 返回 1，经 `| tail` 在 `set -euo pipefail` 下会**静默终止**，
  #    使下面的「📭 无匹配」永不可达（2026-10-17 全树清扫发现：与 android 版修复前逐字同构）。
  MATCHES=$(grep -i "$FILTER" "$APP_LOG" | tail -n "$LINES" || true)
  if [ -n "$MATCHES" ]; then
    echo "$MATCHES"
  else
    echo "📭 无匹配 '$FILTER' 的日志"
  fi
else
  tail -n "$LINES" "$APP_LOG"
fi

echo ""
echo "=== 异常摘要 ==="
grep -iE "exception|error|fatal" "$APP_LOG" | head -20 || echo "无异常"
echo ""
echo "📁 完整日志: $APP_LOG"
