#!/bin/bash
# test_all.sh — 脚本层回归统一入口（离线，不需真机/模拟器）
#
# 用法:
#   bash <S>/scripts/test_all.sh           # 默认：common + bg 静态 + snapshot + safe_run + build_metrics + ios_common
#   bash <S>/scripts/test_all.sh --full    # 额外跑 bg.sh 全量（215 项，较慢）
#   bash <S>/scripts/test_all.sh -v        # 显示各子脚本完整输出
#
# 退出码: 0=全部通过 / 1=有子项失败 / 2=用法错误
#
# 说明:
#   - 默认只跑 bg 的「静态」组（语法检查 + 多字节隐患），已覆盖全部 .sh；
#     bg 的行为用例（215 项）与本次快照/断言改动无关，故默认不跑。
#   - test_safe_run.sh（2026-11-03）：safe_run.sh 沙箱入口的负控制（非 macOS 自动跳过）。
#   - test_build_metrics.sh（2026-11-04）：build_metrics.sh 状态机（stub 构建；非 macOS / 沙箱内跳过）。
#   - 任一子项非零即判失败，但仍跑完其余子项（便于一次看全）。
set -uo pipefail   # 故意不加 -e：单个子项失败要继续跑完其余子项

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

FULL=0; VERBOSE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --full) FULL=1; shift ;;
    -v) VERBOSE=1; shift ;;
    -h|--help) awk 'NR<3 {next} /^[^#[:space:]]/ {exit} {sub(/^# ?/, ""); print}' "$0"; exit 0 ;;
    *) echo "❌ 未知参数: $1" >&2; exit 2 ;;
  esac
done

FAILED=()
run_one() {
  local name="$1"; shift
  local out rc
  echo "=== ${name} ==="
  if [ "$VERBOSE" = 1 ]; then
    bash "$@"
    rc=$?
  else
    out=$(bash "$@" 2>&1)
    rc=$?
    printf '%s\n' "$out" | tail -n 6
  fi
  if [ "$rc" -eq 0 ]; then
    echo "✅ ${name} 通过"
  else
    echo "❌ ${name} 失败（rc=${rc}）"
    FAILED+=("$name")
  fi
  echo ""
  return 0
}

run_one "test_common.sh" "$SCRIPT_DIR/test_common.sh"
run_one "test_bg.sh 静态" "$SCRIPT_DIR/test_bg.sh" -f 静态
run_one "test_snapshot.sh" "$SCRIPT_DIR/test_snapshot.sh"
# 2026-11-03：沙箱入口负控制（凭证面/写面/出网面/fail-closed）—— 边界必须可证伪
run_one "test_safe_run.sh" "$SCRIPT_DIR/test_safe_run.sh"
# 2026-11-04：埋点内测包状态机（注入/还原/pending/sha 守卫）——用 stub 构建，不碰真机构建
run_one "test_build_metrics.sh" "$SCRIPT_DIR/test_build_metrics.sh"
# 2026-11-04：ios/_common.sh 纯函数（syslog 行正则转义 / App 可执行名四级回退）——
#   这两个函数被 run.sh 与 logs.sh 依赖，且历史上出现过「调用未定义函数」的悬空引用
run_one "test_ios_common.sh" "$SCRIPT_DIR/test_ios_common.sh"

if [ "$FULL" = 1 ]; then
  run_one "test_bg.sh 全量" "$SCRIPT_DIR/test_bg.sh"
fi

echo "================================"
if [ "${#FAILED[@]}" -eq 0 ]; then
  echo "✅ 全部通过"
  exit 0
fi
echo "❌ 失败 ${#FAILED[@]} 项"
for f in "${FAILED[@]}"; do echo "   - ${f}"; done
exit 1
