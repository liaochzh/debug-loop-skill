#!/bin/bash
# tap.sh — 点击坐标或按文本查找点击
# 用法: ./tap.sh <x> <y>   或   ./tap.sh --text <关键词>
# 退出码（`--text` 路径三失败态**统一 rc=1**、只靠消息区分；契约由 test_bg.sh 组 14/15 钉死）：
#   0 = 命中并点击完成（`✅ 点击完成`）
#   1 = ① `❌ 无法获取 UI（ui.sh rc=N）` + `💡 ui.sh 输出末 5 行:`（dump 级失败）
#       ② `❌ 页面无可点击节点（ui.sh rc=0 / TSV 0 行）` + 透传 `共 N 个可点击节点`（N>0 ⇒ 有节点但被 text/desc 过滤）
#       ③ `❌ 未找到包含 '…' 的可点击元素` + `💡 可用元素:` 候选清单
# 为什么统一 rc=1 而非分码：调用方（autoDebug 决策 / 组 14 断言）现按「未命中恒 rc=1」判分支，
#   且注释已明言「不随上游漂移」⇒ 分码会破坏既有契约（B2 档复审 P2-5 写死）。
# 关键词语义：**字面包含（忽略大小写）**、**非正则**（2026-10-18 改 `-iF --`；SKILL.md 同名契约行）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_common.sh"

DEVICE=$(require_device)

if [ "${1:-}" = "--text" ]; then
  KEYWORD="${2:-}"
  if [ -z "$KEYWORD" ]; then
    echo "❌ 用法: ./tap.sh --text <关键词>"
    exit 1
  fi

  echo "🔍 查找包含 '$KEYWORD' 的可点击元素..."
  DUMP_OUT="$LOG_DIR/ui_dump.txt"
  # ⚠️ 三态可分辨（2026-10-18）：**捕获 `ui.sh` 的 rc**。原写法 `bash ui.sh … || true` 把
  #    「dump 级失败 / 页面无可点击节点 / 关键词未命中」三态**坍缩成同一形态**，
  #    使 autoDebug 的降级决策拿不到区分证据（B2 档 §5「B3-b」立项理由；SKILL.md 三态交叉核对）。
  #    退出码仍**统一 rc=1**（只分消息不分码，见头注）。
  UI_RC=0
  bash "$SCRIPT_DIR/ui.sh" > "$DUMP_OUT" 2>&1 || UI_RC=$?
  if [ "$UI_RC" -ne 0 ]; then
    echo "❌ 无法获取 UI（ui.sh rc=${UI_RC}）"
    echo "💡 ui.sh 输出末 5 行:"
    tail -5 "$DUMP_OUT"          # 无管道 ⇒ 不引入 SIGPIPE/141 面
    exit 1
  fi

  # 「页面无节点」判据：TSV 行数用与候选清单**同一条**正则计数（`grep -c` 无命中时打印 `0`
  # 且 rc=1 ⇒ `|| true` 只吞 rc，不吞输出）。
  ROWS=$(grep -cE '^[^|]+\|.*\| [0-9]+ [0-9]+$' "$DUMP_OUT" || true)
  if [ "${ROWS:-0}" -eq 0 ]; then
    echo "❌ 页面无可点击节点（ui.sh rc=0 / TSV 0 行）"
    # 透传 ui.sh 的**解析计数**（review P3-6）：`共 N 个可点击节点` 中 N>0 说明「有可点击节点但
    # 全被 text/desc 过滤」⇒ 与「页面确实无节点」可区分（缓解 §9.3 登记的判据局限）。
    grep -m1 '个可点击节点' "$DUMP_OUT" || true     # 无匹配时 grep rc=1 ⇒ `|| true` 吞 rc
    echo "💡 改用 ./shot.sh + 坐标点击（Flutter 页面语义树可能未暴露）"
    exit 1
  fi

  # ⚠️ 末尾 `|| true`：关键词未命中时 `grep` 返回 1，经 `| head` 在 `set -euo pipefail` 下会**静默终止**，
  #    使下面的「❌ 未找到 + 💡 可用元素」永不可达 —— 正是 autoDebug 降级决策所依赖的**候选清单证据**
  #    （2026-10-17 全树清扫发现；与 android/logs.sh 修复前同类）。
  # `-iF --`（2026-10-18）：关键词是**界面文本** ⇒ 字面语义；`-F` 消除「含正则元字符 ⇒ grep rc=2 被吞
  #    ⇒ 误报未找到」与「`a.c` 误命中 `abc`」两类问题；`--` 防关键词以 `-` 开头被当选项。
  MATCH=$(grep -iF -- "$KEYWORD" "$DUMP_OUT" | grep -E '^[^|]+\|.*\| [0-9]+ [0-9]+$' | head -1 || true)
  if [ -z "$MATCH" ]; then
    echo "❌ 未找到包含 '$KEYWORD' 的可点击元素"
    echo "💡 可用元素:"
    # ⚠️ 末尾 `|| true`：候选 >20 且输出超管道缓冲时 `head` 早退 ⇒ 上游 `grep` 收 SIGPIPE(141)，
    #    经 `set -euo pipefail` 会**跳过紧随的 `exit 1`** ⇒ 退出码契约由「恒 1」退化为「1 或 141」，调用方按 rc 判分支即误判。
    #    （2026-10-17 形态清单清扫发现；机制实测：同形态无守卫 rc=141、有守卫 rc=0。）
    grep -E '^[^|]+\|.*\| [0-9]+ [0-9]+$' "$DUMP_OUT" | head -20 || true
    exit 1
  fi

  X=$(echo "$MATCH" | awk '{print $(NF-1)}')
  Y=$(echo "$MATCH" | awk '{print $NF}')
  LABEL=$(echo "$MATCH" | cut -d'|' -f1 | xargs)

  echo "✅ 匹配到: $LABEL -> 坐标 ($X, $Y)"
  adb -s "$DEVICE" shell input tap "$X" "$Y"
  echo "✅ 点击完成"
else
  X="${1:-}"
  Y="${2:-}"
  if [ -z "$X" ] || [ -z "$Y" ]; then
    echo "❌ 用法: ./tap.sh <x> <y> 或 ./tap.sh --text <关键词>"
    exit 1
  fi
  echo "👆 点击坐标 ($X, $Y)"
  adb -s "$DEVICE" shell input tap "$X" "$Y"
  echo "✅ 点击完成"
fi
