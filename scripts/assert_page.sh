#!/bin/bash
# assert_page.sh — 声明式页面断言（一行结论，供 agent 判定）
#
# 用法:
#   ./assert_page.sh --file <断言文件> [--platform P] [--with-logs N]
#   ./assert_page.sh --has "订单列表" --has-not "加载中" --count "订单" 3 --platform android
#
# 断言文件语法见 _assert_page.py 头部注释。
#
# 退出码:
#   0 全过 / 1 有断言失败 / 2 用法错 / 3 平台不可用 / 4 语义树为空 / 5 快照失败
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PLATFORM=""; FILE=""; WITH_LOGS=""; ASSERTS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --platform) [ $# -ge 2 ] || { echo "❌ --platform 缺参数值"; exit 2; }; PLATFORM="$2"; shift 2 ;;
    --file)     [ $# -ge 2 ] || { echo "❌ --file 缺参数值"; exit 2; };     FILE="$2"; shift 2 ;;
    --with-logs) [ $# -ge 2 ] || { echo "❌ --with-logs 缺参数值"; exit 2; }; WITH_LOGS="$2"; shift 2 ;;
    --has)      [ $# -ge 2 ] || { echo "❌ --has 缺参数值"; exit 2; };      ASSERTS+=("has $2"); shift 2 ;;
    --has-not)  [ $# -ge 2 ] || { echo "❌ --has-not 缺参数值"; exit 2; };  ASSERTS+=("has-not $2"); shift 2 ;;
    --match)    [ $# -ge 2 ] || { echo "❌ --match 缺参数值"; exit 2; };    ASSERTS+=("match $2"); shift 2 ;;
    --count)    [ $# -ge 3 ] || { echo "❌ --count 需要 <正则> <N>"; exit 2; }; ASSERTS+=("count $2 $3"); shift 3 ;;
    -*) echo "❌ 未知参数: $1"; exit 2 ;;
    *)  echo "❌ 未知参数: $1"; exit 2 ;;
  esac
done

TMP_ASSERT=""; TMP_ERR=""
cleanup() {
  [ -n "$TMP_ASSERT" ] && rm -f "$TMP_ASSERT"
  [ -n "$TMP_ERR" ] && rm -f "$TMP_ERR"
}
trap cleanup EXIT

if [ -n "$FILE" ] && [ "${#ASSERTS[@]}" -gt 0 ]; then
  echo "❌ --file 与内联断言不能同时使用（避免断言被静默丢弃）"
  exit 2
fi

if [ -z "$FILE" ]; then
  [ "${#ASSERTS[@]}" -gt 0 ] || { echo "❌ 需要 --file 或至少一条断言（--has/--has-not/--match/--count）"; exit 2; }
  TMP_ASSERT=$(mktemp)
  printf '%s\n' "${ASSERTS[@]}" > "$TMP_ASSERT"
  FILE="$TMP_ASSERT"
fi

SNAP_ARGS=(--json)
[ -n "$PLATFORM" ] && SNAP_ARGS+=(--platform "$PLATFORM")

TMP_ERR=$(mktemp)
set +e
JSON_OUT=$(bash "$SCRIPT_DIR/snapshot.sh" "${SNAP_ARGS[@]}" 2>"$TMP_ERR")
SNAP_RC=$?
set -e
SNAP_MSG=$(tail -n 3 "$TMP_ERR" 2>/dev/null | tr '\n' ' ' || true)

case "$SNAP_RC" in
  0) ;;
  4) echo "⚠️ 语义树为空（页面无文本/可点击节点，非页面空白）— 需 App 侧 Semantics 或改用 shot.sh"; exit 4 ;;
  3) echo "❌ 平台不支持或未指定（见下方 snapshot 提示；可加 --platform 重试）"; if [ -n "$SNAP_MSG" ]; then echo "  ${SNAP_MSG}"; fi; exit 3 ;;
  1) echo "❌ 快照失败（设备/dump/解析，可重试）"; if [ -n "$SNAP_MSG" ]; then echo "  ${SNAP_MSG}"; fi; exit 5 ;;
  *) echo "❌ 快照失败（snapshot rc=${SNAP_RC}）"; if [ -n "$SNAP_MSG" ]; then echo "  ${SNAP_MSG}"; fi; exit 5 ;;
esac

DIALECT=$(printf '%s' "$JSON_OUT" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("dialect",""))' 2>/dev/null || true)
case "$DIALECT" in
  uiautomator) RESOLVED=android ;;
  xcuitest)    RESOLVED=ios ;;
  mac2)        RESOLVED=macos ;;
  *)           RESOLVED="${PLATFORM:-auto}" ;;
esac

set +e
printf '%s' "$JSON_OUT" | python3 "$SCRIPT_DIR/_assert_page.py" --file "$FILE" --platform "$RESOLVED"
RC=$?
set -e

if [ "$RC" -ne 0 ] && [ -n "$WITH_LOGS" ]; then
  case "$RESOLVED" in
    android) bash "$SCRIPT_DIR/android/logs.sh" "$WITH_LOGS" 2>/dev/null | tail -n 20 || true ;;
    ios)     bash "$SCRIPT_DIR/ios/logs.sh" "$WITH_LOGS" 2>/dev/null | tail -n 20 || true ;;
    macos)   bash "$SCRIPT_DIR/macos/logs.sh" "$WITH_LOGS" 2>/dev/null | tail -n 20 || true ;;
    *)       : ;;
  esac
fi

exit "$RC"
