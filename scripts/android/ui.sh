#!/bin/bash
# ui.sh — 提取当前界面可点击元素清单（uiautomator dump）
# 输出格式: text/desc | bounds | 中心坐标
# 清单为空有两种含义：① 页面「确实没有带文本的可点击节点」（Flutter 未暴露语义树属此）
#   ② 解析失败 —— 不可把 ② 当作 ① 忽略（2026-10-17 全树形态清单发现：本脚本曾因解析缺陷**恒空**）
# 已知低概率反例（登记未修）：**任一登记属性名**（text / content-desc / bounds / clickable）的值若**字面以
#   ` <属性名>=` 收尾**（如 content-desc="see text="），会被空格锚误命中；其中 **clickable 误取会直接翻转判定**
#   （比 label 取错更重）。另 label 内含 `|` 时下游 `tap.sh` 按 `|` 切分有既有歧义。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_common.sh"

DEVICE=$(require_device)
UI_FILE="$LOG_DIR/ui.xml"

echo "📱 设备: $DEVICE — 📋 Dump UI 层级..."

# 10 秒超时防止动画中卡死（macOS 无 timeout 命令，用 perl 实现）
perl -e 'alarm 10; exec @ARGV' adb -s "$DEVICE" shell uiautomator dump /sdcard/ui.xml 2>/dev/null || {
  echo "❌ uiautomator dump 失败（超时或界面动画中）"
  echo "💡 Flutter 页面可能未暴露语义树，建议改用 ./shot.sh + 坐标点击"
  exit 1
}

adb -s "$DEVICE" pull /sdcard/ui.xml "$UI_FILE" > /dev/null 2>&1 || {
  echo "❌ 无法拉取 ui.xml"
  exit 1
}

if [ ! -s "$UI_FILE" ]; then
  echo "❌ ui.xml 为空（Flutter 页面语义树未暴露），改用 ./shot.sh + 坐标点击"
  exit 1
fi

echo "✅ UI dump 完成，可点击元素："
echo ""

# ⚠️ 按 `-F'[<>]'` 的**字段**解析（一个 `<node …>` 标签 = 一个字段），**不依赖 dump 的行形态**：
#   真机 `uiautomator dump` 可能是「每行一节点」也可能是**单行压缩**；记录级 `match($0,…)` 在单行形态下
#   只会输出 1 行且属性可能跨节点混取（2026-10-17 plan-review 命中 + 实测复现）。
#   改前实现用 `gsub(/".*/, "", $i)` **就地截断**字段 ⇒ 同轮后续 `bounds=`/`clickable=` 检查全落空 ⇒ 判定恒假
#   ⇒ TSV **恒 0 行** ⇒ `tap.sh --text` 主路径恒死（详见 docs/plan/20261017-debugloop-guard-inventory.md §7）。
awk -F'[<>]' '
  {
    for (i=1; i<=NF; i++) {
      if ($i !~ /^node[[:space:]]/) continue
      l = " " $i                       # 前置空格：属性位于字段首时也能被空格锚命中
      text=""; desc=""; bounds=""; clickable="false"
      if (match(l, /[[:space:]]text="[^"]*"/))         { text=substr(l, RSTART+7,  RLENGTH-8)  }
      if (match(l, /[[:space:]]content-desc="[^"]*"/)) { desc=substr(l, RSTART+15, RLENGTH-16) }
      if (match(l, /[[:space:]]bounds="[^"]*"/))       { bounds=substr(l, RSTART+9,  RLENGTH-10) }
      if (match(l, /[[:space:]]clickable="[^"]*"/))    { clickable=substr(l, RSTART+12, RLENGTH-13) }
      if ((text != "" || desc != "") && bounds != "" && clickable == "true") {
        b=bounds; gsub(/[][,]/, " ", b)
        # ⚠️ 第三参**必须显式写 " "**（单空格）：`split(b,c)` 会**继承命令行 -F 的 FS**（此处是 [<>] 正则）
        #    ⇒ 不按空格切分（实测 n=1）。也不能用 `split(b,c,"[, ]+")`（正则 FS）：串首命中分隔符会产生
        #    **空首字段**（实测 n=6、c[1]=""）⇒ 索引整体错位 ⇒ 打印的「中心坐标」实为 `(y1/2, 真中心X)`、
        #    真中心 Y **整体丢失**（如 [100,200][300,280] 打 `100 200`，真中心 `200 240`）。后者系**改前既有
        #    缺陷**，因 TSV 恒 0 行从未被执行过（2026-10-17 异模型复审 P1-1 命中；落档 §9.6）。
        split(b, c, " ")
        if (length(c) >= 4) {
          label = (text != "" ? text : desc)
          gsub(/[[:space:]]+/, " ", label)
          printf "%s | %s | %d %d\n", label, bounds, int((c[1]+c[3])/2), int((c[2]+c[4])/2)
        }
      }
    }
  }
' "$UI_FILE"

# ⚠️ 用 `grep -o | wc -l` 而非 `grep -c`：`grep -c` **计行**（单行压缩 dump 下恒 ≤1）；
#   空格锚同时排除 `long-clickable="true"` 的误计（2026-10-17 实证）。
#   末尾 `|| true`：无命中时 grep 返回 1，经 `set -euo pipefail` 会终止脚本（同文件其余守卫口径一致）。
COUNT=$(grep -o '[[:space:]]clickable="true"' "$UI_FILE" | wc -l | tr -d ' ' || true)
echo ""
echo "共 $COUNT 个可点击节点（含无文本节点）"
