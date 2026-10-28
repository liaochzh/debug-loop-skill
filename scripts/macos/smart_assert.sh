#!/bin/bash
# smart_assert.sh — macOS 智能断言：截图 → Vision 分析 → 判断关键词是否可见
#
# 用法:
#   ./smart_assert.sh "<关键词>" [--not-visible]
#
# 退出码: 0 = 断言成立；1 = 断言失败；3 = Vision 调用失败
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_common.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../vision/smart_lib.sh"

KEYWORD=""; NOT_VISIBLE=false
while [ $# -gt 0 ]; do
  case "$1" in
    --not-visible) NOT_VISIBLE=true; shift ;;
    -*) echo "❌ 未知参数: $1"; exit 1 ;;
    *)  KEYWORD="$1"; shift ;;
  esac
done

[ -n "$KEYWORD" ] || { echo "❌ 用法: ./smart_assert.sh \"<关键词>\" [--not-visible]"; exit 1; }

sl_activate "$MACOS_APP_NAME"

echo "📸 截图 + Vision 分析: '$KEYWORD'"
IMG=$(sl_shot)
JSON=$(sl_vision "$IMG" ui_analysis "页面是否出现 '$KEYWORD'")

# 页面处于非 normal（loading/白屏/异常）时，可见性判定不可靠 → fail-closed
STATE=$(sl_state "$JSON")
if [ "$STATE" != "normal" ]; then
  echo "❌ 页面状态非 normal（state=${STATE}），断言不可靠，拒绝判定" >&2
  exit 3
fi

MATCH=$(sl_exists "$JSON" "$KEYWORD") && FOUND=true || FOUND=false

if [ "$NOT_VISIBLE" = true ]; then
  if [ "$FOUND" = false ]; then echo "✅ 断言成立：'$KEYWORD' 未出现"; exit 0; fi
  echo "❌ 断言失败：'$KEYWORD' 出现了（匹配: ${MATCH}）"; exit 1
else
  if [ "$FOUND" = true ]; then
    echo "✅ 断言成立：'$MATCH' 可见"; exit 0
  fi
  echo "❌ 断言失败：'$KEYWORD' 未找到"; exit 1
fi