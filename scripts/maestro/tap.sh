#!/bin/bash
# tap.sh — 语义点击（Maestro，无需坐标；Android / iOS 模拟器通用）
#
# 用法:
#   ./tap.sh "<文本>"   [--platform android|ios] [--device <id>] [--app-id <id>]
#   ./tap.sh "<id>"     --id [同上]
#   ./tap.sh "<文本>"   --index 1 [同上]      # 多个匹配时取第 N 个（1-based）
#
# 说明:
#   - 优先用可见文本；无文本控件（Icon/图片按钮）需 App 侧 Semantics(identifier:) 后用 --id
#   - 不自动 launchApp（保持调用前页面状态）；需要冷启动请先跑 <platform>/run.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_common.sh"

TARGET=""; AS_ID=false; INDEX=""; FWD=()
while [ $# -gt 0 ]; do
  case "$1" in
    --id) AS_ID=true; shift ;;
    --index) [ $# -ge 2 ] || { echo "❌ --index 缺参数值"; exit 2; }; INDEX="$2"; shift 2 ;;
    --platform|--device|--app-id) [ $# -ge 2 ] || { echo "❌ $1 缺参数值"; exit 2; }; FWD+=("$1" "$2"); shift 2 ;;
    -*) echo "❌ 未知参数: $1"; exit 1 ;;
    *)  TARGET="$1"; shift ;;
  esac
done

[ -n "$TARGET" ] || { echo "❌ 用法: ./tap.sh \"<文本>\" [--id] [--index N] [--platform android|ios]"; exit 1; }

yaml_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
ESC=$(yaml_escape "$TARGET")

STEP="$LOG_DIR/.maestro_step.yaml"
if [ "$AS_ID" = true ]; then
  {
    echo "- tapOn:"
    echo "    id: \"$ESC\""
    [ -n "$INDEX" ] && { echo "    index: $INDEX"; }
  } > "$STEP"
else
  if [ -n "$INDEX" ]; then
    { echo "- tapOn:"; echo "    text: \"$ESC\""; echo "    index: $INDEX"; } > "$STEP"
  else
    echo "- tapOn: \"$ESC\"" > "$STEP"
  fi
fi

if [ "${#FWD[@]}" -gt 0 ]; then
  bash "$SCRIPT_DIR/flow.sh" "$STEP" "${FWD[@]}"
else
  bash "$SCRIPT_DIR/flow.sh" "$STEP"
fi