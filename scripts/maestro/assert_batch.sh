#!/bin/bash
# assert_batch.sh — 多条语义断言合并为单个 Maestro 流程（iOS 模拟器省时路径）
#
# 用法:
#   ./assert_batch.sh --file <断言文件> [--platform android|ios] [--device <id>] [--app-id <id>]
#   ./assert_batch.sh <断言文件> [同上]
#
# 断言文件只接受 has / has-not（count / match 无 Maestro 对应物，请走 snapshot + assert_page）。
# ⚠️ 语义差异：本命令按 Maestro `assertVisible` 的**精确文本、大小写敏感**匹配；
#    `assert_page.sh` 的 `has` 是**子串包含、忽略大小写**。需要子串/数量断言请用 assert_page。
#
# 退出码: 0 全部通过 / 1 有断言失败 / 2 用法错（含不支持的断言类型）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_common.sh"

FILE=""; FWD=()
while [ $# -gt 0 ]; do
  case "$1" in
    --file)     [ $# -ge 2 ] || { echo "❌ --file 缺参数值"; exit 2; };     FILE="$2"; shift 2 ;;
    --platform|--device|--app-id) [ $# -ge 2 ] || { echo "❌ $1 缺参数值"; exit 2; }; FWD+=("$1" "$2"); shift 2 ;;
    -*) echo "❌ 未知参数: $1"; exit 2 ;;
    *)  [ -z "$FILE" ] || { echo "❌ 只能指定一个断言文件（已有: ${FILE}）"; exit 2; }; FILE="$1"; shift ;;
  esac
done

[ -n "$FILE" ] || { echo "❌ 用法: ./assert_batch.sh --file <断言文件> [--platform android|ios]"; exit 2; }
[ -f "$FILE" ] || { echo "❌ 断言文件不存在: $FILE"; exit 2; }

yaml_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

YAML="$LOG_DIR/.maestro_batch.yaml"
: > "$YAML"
TOTAL=0

while IFS= read -r raw || [ -n "$raw" ]; do
  line="$(printf '%s' "$raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  case "$line" in ''|'#'*) continue ;; esac
  kind="${line%% *}"
  arg="${line#* }"
  case "$kind" in
    has)
      [ "$arg" != "$line" ] || { echo "❌ 断言缺少文本: $line"; exit 2; }
      printf -- '- assertVisible: "%s"\n' "$(yaml_escape "$arg")" >> "$YAML"
      ;;
    has-not)
      [ "$arg" != "$line" ] || { echo "❌ 断言缺少文本: $line"; exit 2; }
      printf -- '- assertNotVisible: "%s"\n' "$(yaml_escape "$arg")" >> "$YAML"
      ;;
    count|match|not-match)
      echo "❌ assert_batch 不支持 '$kind'（Maestro 无数量/正则断言）—— 请改用 snapshot.sh + assert_page.sh" >&2
      exit 2
      ;;
    *)
      echo "❌ 未知断言类型: $kind" >&2
      exit 2
      ;;
  esac
  TOTAL=$((TOTAL + 1))
done < "$FILE"

[ "$TOTAL" -gt 0 ] || { echo "❌ 断言文件为空: $FILE"; exit 2; }

if [ "${#FWD[@]}" -gt 0 ]; then
  set +e
  bash "$SCRIPT_DIR/flow.sh" "$YAML" "${FWD[@]}" > /dev/null 2>&1
  FLOW_RC=$?
  set -e
else
  set +e
  bash "$SCRIPT_DIR/flow.sh" "$YAML" > /dev/null 2>&1
  FLOW_RC=$?
  set -e
fi

if [ "$FLOW_RC" -eq 0 ]; then
  echo "✅ ${TOTAL}/${TOTAL} PASS (maestro)"
  exit 0
fi

LOG="$LOG_DIR/maestro_output.log"
PASSED=$(grep -c 'COMPLETED' "$LOG" 2>/dev/null || true)
FAILED_LINE=$(grep 'FAILED' "$LOG" 2>/dev/null | head -1 || true)

if [ "$FLOW_RC" -eq 2 ]; then
  echo "❌ 用法错（flow.sh rc=2，见 ${LOG}）"
  exit 2
fi

echo "❌ ${PASSED:-0}/${TOTAL} FAIL (maestro)"
if [ -n "$FAILED_LINE" ]; then
  echo "  - $(printf '%s' "$FAILED_LINE" | sed -e 's/^[[:space:]]*//')"
else
  echo "  - 未捕获到 FAILED 行，可能是驱动/超时问题（见 ${LOG}）"
fi
exit 1
