#!/bin/bash
# findtap.sh — 滑动查找并点击（等价 agent-device 的 `scroll --until <selector>` 思路）
# 用法: ./findtap.sh <关键词> [--max 6] [--dir down|up] [--wait 0.4]
#   --max    最多滑动次数（默认 6；含首次当前屏尝试）
#   --dir    down=向下浏览内容（手指上滑，默认）/ up=向上浏览内容（手指下滑）
#   --wait   每次滑动后等待秒数（默认 0.4，让列表停顿；动画复杂的页面建议配合 settle.sh）
# 退出码: 0 = 命中并点击完成 / 1 = 未命中（滑动 --max 次）或**语义树无内容**（立即返回，不滑动） / 2 = 用法错误
#
# 匹配语义与 tap.sh --text **严格一致**（字面包含、忽略大小写、非正则），避免两套规则漂移。
# 依赖 uiautomator 语义树：Flutter 未暴露语义树时首轮即失败（rc=1），改用 Maestro / Vision / 坐标。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_common.sh"

KEYWORD="${1:-}"
[ -n "$KEYWORD" ] || { echo "❌ 用法: ./findtap.sh <关键词> [--max 6] [--dir down|up] [--wait 0.4]" >&2; exit 2; }
shift

MAX=6
DIR="down"
WAIT=0.4
while [ $# -gt 0 ]; do
  case "$1" in
    --max)  [ $# -ge 2 ] || { echo "❌ --max 需要取值" >&2; exit 2; }; MAX="$2"; shift 2 ;;
    --dir)  [ $# -ge 2 ] || { echo "❌ --dir 需要取值" >&2; exit 2; }; DIR="$2"; shift 2 ;;
    --wait) [ $# -ge 2 ] || { echo "❌ --wait 需要取值" >&2; exit 2; }; WAIT="$2"; shift 2 ;;
    -h|--help) echo "用法: ./findtap.sh <关键词> [--max 6] [--dir down|up] [--wait 0.4]"; exit 0 ;;
    *) echo "❌ 未知参数: $1" >&2; exit 2 ;;
  esac
done
case "$MAX" in ''|*[!0-9]*) echo "❌ --max 必须是正整数（收到: ${MAX}）" >&2; exit 2 ;; esac
[ "$MAX" -ge 1 ] || { echo "❌ --max 至少为 1" >&2; exit 2; }
case "$DIR" in down|up) ;; *) echo "❌ --dir 只支持 down|up（收到: ${DIR}）" >&2; exit 2 ;; esac
case "$WAIT" in ''|*[!0-9.]*) echo "❌ --wait 必须是数字（收到: ${WAIT}）" >&2; exit 2 ;; esac

DEVICE=$(require_device)

# 屏幕尺寸（取 Override size 优先于 Physical size，兼容尺寸覆盖过的设备）
SIZE_LINE=$(adb -s "$DEVICE" shell wm size 2>/dev/null | tr -d '\r' | grep -E 'size:' | tail -1 || true)
W=$(echo "$SIZE_LINE" | sed 's/.*size: *//' | cut -dx -f1)
H=$(echo "$SIZE_LINE" | sed 's/.*size: *//' | cut -dx -f2)
case "${W:-}" in ''|*[!0-9]*) W=1080 ;; esac
case "${H:-}" in ''|*[!0-9]*) H=1920 ;; esac
CX=$((W / 2))
if [ "$DIR" = "down" ]; then
  Y1=$((H * 3 / 4)); Y2=$((H / 4))       # 手指上滑 ⇒ 内容向下滚动
else
  Y1=$((H / 4)); Y2=$((H * 3 / 4))
fi

TSV_RE='^[^|]+\|.*\| [0-9]+ [0-9]+$'
DUMP_OUT="$LOG_DIR/ui_findtap.txt"

# 兜底匹配：文本节点未必 `clickable="true"`（Compose / RecyclerView 常见），但点其中心通常命中父级。
# 与 ui.sh 用同一套字段解析，只是**去掉 clickable 过滤**；命中即输出 "x y label"。
_node_center() {  # <关键词> → 命中输出 "x y label"，否则空
  awk -v kw="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" -F'[<>]' '
    {
      for (i = 1; i <= NF; i++) {
        if ($i !~ /^node[[:space:]]/) continue
        l = " " $i
        text = ""; desc = ""; bounds = ""
        if (match(l, /[[:space:]]text="[^"]*"/))         text   = substr(l, RSTART + 7,  RLENGTH - 8)
        if (match(l, /[[:space:]]content-desc="[^"]*"/)) desc   = substr(l, RSTART + 15, RLENGTH - 16)
        if (match(l, /[[:space:]]bounds="[^"]*"/))       bounds = substr(l, RSTART + 9,  RLENGTH - 10)
        if (bounds == "") continue
        label = (text != "" ? text : desc)
        if (label == "") continue
        if (index(tolower(label), kw) == 0) continue
        b = bounds; gsub(/[][,]/, " ", b); split(b, c, " ")
        if (length(c) < 4) continue
        gsub(/[[:space:]]+/, " ", label)
        printf "%d %d %s\n", int((c[1] + c[3]) / 2), int((c[2] + c[4]) / 2), label
        exit
      }
    }
  ' "$LOG_DIR/ui.xml"
}

i=1
while [ "$i" -le "$MAX" ]; do
  if ! bash "$SCRIPT_DIR/ui.sh" > "$DUMP_OUT" 2>&1; then
    # ⚠️ dump 级失败 ≠ 页面无内容：ui.sh 失败时**不清理**旧 ui.xml（ui.sh:21-35），
    #    这里必须继续走重试分支，绝不能拿残留文件判「语义树无内容」（2026-10-27 评审 A-2）。
    echo "⚠️  第 ${i} 次 ui.sh 失败（动画中？）— 等待后重试"
    tail -3 "$DUMP_OUT"
    sleep "$WAIT"
    i=$((i + 1))
    continue
  fi

  # 首轮（仅 rc=0 分支）判语义树：Flutter 未暴露语义树时 findtap 无法定位，
  # 与其白滑 --max 屏（每屏一次 dump，慢且无意义），不如立即失败并给正确降级路径。
  if [ "$i" -eq 1 ]; then
    NODES=$(ui_has_semantics "$LOG_DIR/ui.xml")
    if [ -z "$NODES" ]; then NODES=0; fi
    if [ "$NODES" -eq 0 ]; then
      echo "❌ 语义树无内容（dump 中无 text/content-desc 节点）⇒ findtap 不可用"
      echo "💡 处置顺序：① maestro/tap.sh \"${KEYWORD}\"（语义定位首选）"
      echo "   ② 语义树同样缺失时用 Vision 视觉定位 ③ ./shot.sh + ./tap.sh x y 坐标兜底（须先截图确认）"
      exit 1
    fi
  fi

  MATCH=$(grep -iF -- "$KEYWORD" "$DUMP_OUT" 2>/dev/null | grep -E "$TSV_RE" | head -1 || true)
  if [ -n "$MATCH" ]; then
    X=$(echo "$MATCH" | awk '{print $(NF-1)}')
    Y=$(echo "$MATCH" | awk '{print $NF}')
    LABEL=$(echo "$MATCH" | cut -d'|' -f1 | xargs)
    echo "✅ 第 ${i} 屏命中: ${LABEL} -> 坐标 (${X}, ${Y})"
    adb -s "$DEVICE" shell input tap "$X" "$Y"
    echo "✅ 点击完成"
    exit 0
  fi
  FB=$(_node_center "$KEYWORD")
  if [ -n "$FB" ]; then
    X=$(echo "$FB" | awk '{print $1}')
    Y=$(echo "$FB" | awk '{print $2}')
    LABEL=$(echo "$FB" | cut -d' ' -f3-)
    echo "✅ 第 ${i} 屏命中: ${LABEL} -> 坐标 (${X}, ${Y})（文本节点非 clickable，按坐标兜底）"
    adb -s "$DEVICE" shell input tap "$X" "$Y"
    echo "✅ 点击完成"
    exit 0
  fi
  if [ "$i" -eq "$MAX" ]; then break; fi
  echo "🔄 第 ${i} 屏未命中 '${KEYWORD}'，滑动（${DIR}）…"
  adb -s "$DEVICE" shell input swipe "$CX" "$Y1" "$CX" "$Y2" 300
  sleep "$WAIT"
  i=$((i + 1))
done

echo "❌ 滑动 ${MAX} 次仍未找到包含 '${KEYWORD}' 的可点击元素"
echo "💡 处置顺序：① ./settle.sh 后重试（可能是过渡态） ② ./ui.sh 看候选清单"
echo "   ③ 关键词改用界面上更短的稳定子串 ④ ./shot.sh + ./tap.sh x y 坐标兜底"
exit 1
