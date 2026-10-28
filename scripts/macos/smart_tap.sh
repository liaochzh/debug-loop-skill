#!/bin/bash
# smart_tap.sh — macOS 智能点击：截图 → Vision 定位 → 坐标换算 → 点击（无需人工估算坐标）
#
# 用法:
#   ./smart_tap.sh "<关键词>" [--stable] [--allow-danger] [--min-conf 0.7] [--dry-run]
#
# 退出码: 0 = 点击成功/已 dry-run；1 = 未定位/页面不稳定等安全拒绝；2 = 命中危险词；3 = Vision 调用失败
#
# 安全护栏:
#   - confidence < 阈值（默认 0.7）→ 拒绝自动点击，打印候选
#   - 命中危险词（解绑/删除/付款…）→ 拒绝（exit 2），除非 --allow-danger
#   - screen.state = loading/white_screen/obscured → 拒绝（页面不稳定）
#   - --stable：间隔双采样，两次中心点偏移 > 10px 则拒绝（规避动画误击）
#   - --dry-run：只报告将点击的坐标与置信度，不实际点击
set -euo pipefail

STABLE_TOL=10   # 双采样中心点允许偏移（px）

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_common.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../vision/smart_lib.sh"

KEYWORD=""; STABLE=false; ALLOW_DANGER=false; DRY=false; MIN_CONF="$SMART_MIN_CONF"
while [ $# -gt 0 ]; do
  case "$1" in
    --stable) STABLE=true; shift ;;
    --allow-danger) ALLOW_DANGER=true; shift ;;
    --dry-run) DRY=true; shift ;;
    --min-conf) [ $# -ge 2 ] || { echo "❌ --min-conf 缺参数值"; exit 2; }
                [[ "$2" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "❌ --min-conf 需为 0~1 的数字: $2"; exit 2; }
                MIN_CONF="$2"; shift 2 ;;
    -*) echo "❌ 未知参数: $1"; exit 1 ;;
    *)  KEYWORD="$1"; shift ;;
  esac
done

[ -n "$KEYWORD" ] || { echo "❌ 用法: ./smart_tap.sh \"<关键词>\" [--stable] [--allow-danger] [--min-conf 0.7] [--dry-run]"; exit 1; }

# 页面不稳定状态拒绝自动操作
unstable() { case "$1" in loading|white_screen|obscured) return 0 ;; *) return 1 ;; esac; }

sl_activate "$MACOS_APP_NAME"

echo "📸 截图 + Vision 定位: '$KEYWORD'"
IMG=$(sl_shot)
JSON=$(sl_vision "$IMG" find_element "定位包含 '$KEYWORD' 的可点击元素（按钮/链接/输入框）")
LINE=$(sl_select "$JSON" "$KEYWORD" "$MIN_CONF") || { echo "⚠️ 未定位到可信元素，已终止（未点击）"; exit 1; }
IFS=$'\t' read -r CX CY CONF STATE TEXT <<< "$LINE"

echo "🎯 命中: '$TEXT' | conf=$CONF | state=$STATE | px=($CX,$CY)"

if unstable "$STATE"; then
  echo "⚠️ 页面状态 '$STATE' 不稳定，拒绝自动点击"; exit 1
fi
if sl_is_dangerous "$TEXT" && [ "$ALLOW_DANGER" != true ]; then
  echo "🛑 命中危险词（${SMART_DANGER_RE}）：'$TEXT' — 拒绝自动点击。确认无误请加 --allow-danger"; exit 2
fi

# 稳定性双采样：两次中心点偏移 > 10px 视为页面在动
if [ "$STABLE" = true ]; then
  sleep 1
  IMG2=$(sl_shot)
  JSON2=$(sl_vision "$IMG2" find_element "定位包含 '$KEYWORD' 的可点击元素（按钮/链接/输入框）")
  LINE2=$(sl_select "$JSON2" "$KEYWORD" "$MIN_CONF") || { echo "⚠️ 二次采样未命中，拒绝点击"; exit 1; }
  IFS=$'\t' read -r CX2 CY2 _ _ _ <<< "$LINE2"
  DX=$(( CX > CX2 ? CX - CX2 : CX2 - CX ))
  DY=$(( CY > CY2 ? CY - CY2 : CY2 - CY ))
  if [ "$DX" -gt "$STABLE_TOL" ] || [ "$DY" -gt "$STABLE_TOL" ]; then
    echo "⚠️ 页面不稳定（偏移 ${DX},${DY}px），拒绝点击"; exit 1
  fi
  echo "✅ 双采样稳定（偏移 ${DX},${DY}px）"
fi

SP=$(sl_screen_points || true)
[ -n "$SP" ] || { echo "❌ 无法获取屏幕 point 尺寸（需「屏幕录制」权限）"; exit 1; }
SW=$(echo "$SP" | awk '{print $1}'); SH=$(echo "$SP" | awk '{print $2}')
PT=$(sl_px_to_point "$IMG" "$CX" "$CY" "$SW" "$SH")
PX=$(echo "$PT" | awk '{print $1}'); PY=$(echo "$PT" | awk '{print $2}')
echo "🖱️  换算 point=($PX,$PY)（屏幕 ${SW}x${SH}pt）"

if [ "$DRY" = true ]; then
  echo "🧪 --dry-run：仅报告，不点击"; exit 0
fi
sl_click_point "$PX" "$PY"