#!/bin/bash
# test_all.sh — 脚本层回归统一入口（离线，不需真机/模拟器）
#
# 用法:
#   bash <S>/scripts/test_all.sh           # 默认：common + bg 静态 + snapshot
#   bash <S>/scripts/test_all.sh --full    # 额外跑 bg.sh 全量（215 项，较慢）
#   bash <S>/scripts/test_all.sh -v        # 显示各子脚本完整输出
#
# 退出码: 0=全部通过 / 1=有子项失败 / 2=用法错误
#
# 说明:
#   - 默认只跑 bg 的「静态」组（语法检查 + 多字节隐患），已覆盖全部 .sh；
#     bg 的行为用例（215 项）与本次快照/断言改动无关，故默认不跑。
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
