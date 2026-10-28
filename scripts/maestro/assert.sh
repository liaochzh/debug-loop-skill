#!/bin/bash
# assert.sh — 语义断言（Maestro，Android / iOS 模拟器通用）
#
# 用法:
#   ./assert.sh "<文本>"        [--platform android|ios] [--device <id>] [--app-id <id>]
#   ./assert.sh "<id>"  --id    [同上]
#   ./assert.sh "<文本>" --not-visible   # 断言不可见
#
# 退出码: 0 = 断言成立；非 0 = 断言失败（供 agent 判定）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_common.sh"

TARGET=""; AS_ID=false; NOT_VISIBLE=false; FWD=()
while [ $# -gt 0 ]; do
  case "$1" in
    --id) AS_ID=true; shift ;;
    --not-visible) NOT_VISIBLE=true; shift ;;
    --platform|--device|--app-id) [ $# -ge 2 ] || { echo "❌ $1 缺参数值"; exit 2; }; FWD+=("$1" "$2"); shift 2 ;;
    -*) echo "❌ 未知参数: $1"; exit 1 ;;
    *)  TARGET="$1"; shift ;;
  esac
done

[ -n "$TARGET" ] || { echo "❌ 用法: ./assert.sh \"<文本>\" [--id] [--not-visible] [--platform android|ios]"; exit 1; }

yaml_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
ESC=$(yaml_escape "$TARGET")

CMD="assertVisible"
[ "$NOT_VISIBLE" = true ] && CMD="assertNotVisible"

STEP="$LOG_DIR/.maestro_step.yaml"
if [ "$AS_ID" = true ]; then
  { echo "- $CMD:"; echo "    id: \"$ESC\""; } > "$STEP"
else
  echo "- $CMD: \"$ESC\"" > "$STEP"
fi

if [ "${#FWD[@]}" -gt 0 ]; then
  bash "$SCRIPT_DIR/flow.sh" "$STEP" "${FWD[@]}"
else
  bash "$SCRIPT_DIR/flow.sh" "$STEP"
fi