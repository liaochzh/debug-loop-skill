#!/bin/bash
# pitfall_append.sh — 把「本次踩的坑」写进项目级台账（autoDebug 无编辑工具，必须由脚本自带落点）
#
# 为什么需要本脚本（2026-11-12 立项）：坑表沉淀若要求子代理「自己写文档」，会因
#   autoDebug 的 edit: deny + shell 重定向被硬化拒绝而成死条款 —— 每次收尾静默流失，
#   同一个坑下次照踩。落点固定在 `docs/test/debug-loop/pitfalls.md`（沙箱 ui profile 可写）。
#
# 用法:
#   ./pitfall_append.sh --symptom "登录页输入账号后值变成旧值+新值" \
#                       --judge "snapshot 读回 text 与期望不等" \
#                       --action "android/input.sh --field 账号 --text-from .debug-login.secret" \
#                       --evidence "build/debug/interact/1760000000-input.json"
#
# 选项:
#   --symptom <一句话症状>   必填；也是去重键（已存在同串则跳过，避免同一坑刷屏）
#   --judge <判据>           怎么确认它发生了（快照字段 / 日志签名 / rc）
#   --action <处置>          下次直接照做的那一步（最好是可复制的命令）
#   --evidence <证据路径>    可空
#   --root <目录>            缺省 docs/test/debug-loop
#
# 退出码: 0 已追加或已存在 / 2 用法错 / 3 无法写入（目录/权限）
set -euo pipefail

ROOT="docs/test/debug-loop"
SYM=""; JUDGE=""; ACTION=""; EVID=""

usage() {
  awk 'NR < 3 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --symptom)  [ $# -ge 2 ] || { echo "❌ --symptom 缺参数值"; exit 2; };  SYM="$2"; shift 2 ;;
    --judge)    [ $# -ge 2 ] || { echo "❌ --judge 缺参数值"; exit 2; };    JUDGE="$2"; shift 2 ;;
    --action)   [ $# -ge 2 ] || { echo "❌ --action 缺参数值"; exit 2; };   ACTION="$2"; shift 2 ;;
    --evidence) [ $# -ge 2 ] || { echo "❌ --evidence 缺参数值"; exit 2; }; EVID="$2"; shift 2 ;;
    --root)     [ $# -ge 2 ] || { echo "❌ --root 缺参数值"; exit 2; };     ROOT="$2"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    -*) echo "❌ 未知参数: $1"; exit 2 ;;
    *)  echo "❌ 未知参数: $1"; exit 2 ;;
  esac
done

[ -n "$SYM" ] || { echo "❌ 需要 --symptom <一句话症状>"; exit 2; }

# markdown 表格：字段里的 | 会破坏列，统一转义；换行压成空格
clean() {
  printf '%s' "$1" | tr '\n\t' '  ' | sed 's/|/\\|/g'
}

mkdir -p "$ROOT" 2>/dev/null || { echo "❌ 无法创建目录: $ROOT" >&2; exit 3; }
FILE="$ROOT/pitfalls.md"

if [ ! -f "$FILE" ]; then
  {
    echo "# 真机调试逐坑台账"
    echo
    echo "> 由 \`debug-loop/scripts/pitfall_append.sh\` 追加（重跑会去重），随项目版本走。"
    echo "> 用法：开工先读本表，命中同类症状直接照「处置」做；收工把新坑追加进来。"
    echo
    echo "| 日期 | 症状 | 判据 | 处置 | 证据 |"
    echo "|---|---|---|---|---|"
  } > "$FILE" 2>/dev/null || { echo "❌ 无法写入: $FILE" >&2; exit 3; }
fi

if grep -qF -- "$SYM" "$FILE" 2>/dev/null; then
  echo "♻️ 台账已有同类症状，未重复追加: $FILE"
  exit 0
fi

printf '| %s | %s | %s | %s | %s |\n' \
  "$(date +%F)" "$(clean "$SYM")" "$(clean "$JUDGE")" "$(clean "$ACTION")" "$(clean "${EVID:-—}")" \
  >> "$FILE" 2>/dev/null || { echo "❌ 无法写入: $FILE" >&2; exit 3; }

echo "📝 已追加到 $FILE"
echo "💡 下次开工先读它；可用 --root 指向别的台账目录"