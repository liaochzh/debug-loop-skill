#!/bin/bash
# test_build_metrics.sh — build_metrics.sh（INTERNAL_METRICS 内测包）状态机离线回归
#
# 用法:
#   bash <S>/scripts/test_build_metrics.sh        # 全量
#   bash <S>/scripts/test_build_metrics.sh -v     # 显示每一步输出
#
# 退出码: 0=全部通过 / 1=有用例失败 / 2=用法错误
#
# 为什么用 stub 构建：真实构建要 ~10 min 且会改写项目 `Pods/**/xcconfig`。
#   本测试只关心**状态机**（注入/还原/守卫/pending/模式沿用），故用假 SKILL 树 +
#   假 build.sh：按 xcconfig 是否含 INTERNAL_METRICS 产出对应「二进制」。
#
# 覆盖点（负控制）:
#   B1 正常注入 → 判据 ≥1 → 自动还原 → 重编归零 → pending/备份/state 清理
#   B2 `--keep` 保留注入态 + 写 pending；pending 期间再注入被拒（rc=1）；`--restore` 解除
#   B3 sha 守卫：注入后被改写 ⇒ `--restore` 拒绝（rc=2）且**不动文件**；`--force` 才还原
#   B4 判据缺失（注入未生效/模式错）⇒ rc=1 + 文件回滚 + pending；`--clear-pending` 清标记
#   B5 `--mode release` 落 state，`--restore` 沿用 release（不被默认 profile 覆盖）
#   B6 `--mode debug` ⇒ rc=2（`#if DEBUG` 会让判据恒真，必须拒绝）
#   B7 沙箱内（`SAFE_RUN_PROFILE` 非空）⇒ rc=3，且不改文件
#   B8 `--clear-pending` 在文件仍含标记时拒绝（rc=1）
set -uo pipefail   # 故意不加 -e：单例失败要继续跑完其余用例

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
VERBOSE=0
while [ $# -gt 0 ]; do
  case "$1" in
    -v) VERBOSE=1; shift ;;
    -h|--help) awk 'NR<2 {next} /^[^#[:space:]]/ {exit} {sub(/^# ?/, ""); print}' "$0"; exit 0 ;;
    *) echo "❌ 未知参数: $1" >&2; exit 2 ;;
  esac
done

if [ "$(uname -s)" != "Darwin" ]; then
  echo "⏭  非 macOS：跳过（依赖 shasum / strings / sed -i ''）"
  exit 0
fi
if [ -n "${SAFE_RUN_PROFILE:-}" ]; then
  echo "⏭  沙箱内跳过（build_metrics.sh 只允许在宿主机跑，自身会 rc=3）"
  exit 0
fi

T="$(mktemp -d "${TMPDIR:-/tmp}/bmtest.XXXXXX")" || { echo "❌ 无法创建临时目录" >&2; exit 1; }
cleanup() { rm -rf "$T"; }
trap cleanup EXIT

SK="$T/skill"; PROJ="$T/proj"
mkdir -p "$SK/scripts/ios" "$PROJ/ios/Pods/Target Support Files/fakepod" "$PROJ/build/debug"
cp "$SCRIPT_DIR/ios/build_metrics.sh" "$SCRIPT_DIR/ios/_common.sh" "$SK/scripts/ios/"
XCC="$PROJ/ios/Pods/Target Support Files/fakepod/fakepod.release.xcconfig"
printf 'HEADER_SEARCH_PATHS = $(inherited)\n' > "$XCC"

cat > "$SK/scripts/ios/build.sh" <<'EOS'
#!/bin/bash
# stub：按 xcconfig 是否含 INTERNAL_METRICS 产出「二进制」，并记录收到的参数
echo "stub-build.sh $*" >> build/debug/build_args.log
X="ios/Pods/Target Support Files/fakepod/fakepod.release.xcconfig"
APP="build/ios/iphoneos/Fake.app"
mkdir -p "$APP"
{
  printf 'ThingLogSDK.startLog done\n'
  if grep -q 'INTERNAL_METRICS' "$X" && [ "${STUB_DROP_SYMBOL:-0}" != "1" ]; then
    printf '[P2PCameraOverlap]\n'
  fi
} > "$APP/Fake"
echo "$PWD/$APP" > build/debug/.last_ios_app_device
exit 0
EOS
chmod +x "$SK/scripts/ios/build.sh"

BM="$SK/scripts/ios/build_metrics.sh"
MET="$PROJ/build/debug/metrics"
PASS=0; FAIL=0; FAILED=()
ok()  { PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); FAILED+=("$1"); printf '  ❌ %s（%s）\n' "$1" "$2"; }
has_mark() { grep -q 'INTERNAL_METRICS' "$XCC" 2>/dev/null && printf yes || printf no; }
run_bm() {  # run_bm <log> <args...>
  local log="$1"; shift
  bash "$BM" "$@" --project-root "$PROJ" > "$log" 2>&1
  local rc=$?
  [ "$VERBOSE" = "1" ] && sed 's/^/    /' "$log"
  return "$rc"
}

echo "🧪 build_metrics.sh 状态机离线回归"
echo ""

echo "== B1 正常注入 → 自动还原 =="
run_bm "$T/1.log" --pod fakepod --symbol P2PCameraOverlap --control 'ThingLogSDK.startLog done'
RC=$?
[ "$RC" -eq 0 ] && ok "rc=0" || bad "rc=0" "rc=$RC"
[ "$(has_mark)" = "no" ] && ok "xcconfig 已还原" || bad "xcconfig 已还原" "仍含标记"
[ ! -f "$MET/pending_restore" ] && ok "无 pending" || bad "无 pending" "存在"
[ ! -f "$MET/fakepod.xcconfig.bak" ] && ok "备份已清理" || bad "备份已清理" "存在"
[ ! -f "$MET/fakepod.state" ] && ok "state 已清理" || bad "state 已清理" "存在"
grep -q 'symbols=0' "$MET/build_metrics.log" 2>/dev/null && ok "审计记了归零" || bad "审计记了归零" "日志缺 symbols=0"
echo ""

echo "== B2 --keep → 拒绝再注入 → --restore 解除 =="
run_bm "$T/2.log" --pod fakepod --symbol P2PCameraOverlap --keep
RC=$?
[ "$RC" -eq 0 ] && ok "--keep rc=0" || bad "--keep rc=0" "rc=$RC"
[ "$(has_mark)" = "yes" ] && ok "--keep 保留注入态" || bad "--keep 保留注入态" "标记丢了"
run_bm "$T/2b.log" --pod fakepod --symbol P2PCameraOverlap
RC=$?
[ "$RC" -eq 1 ] && ok "pending 存在 ⇒ 拒绝注入 rc=1" || bad "pending 拒绝注入" "rc=$RC"
run_bm "$T/2c.log" --pod fakepod --symbol P2PCameraOverlap --restore
RC=$?
[ "$RC" -eq 0 ] && ok "--restore rc=0" || bad "--restore rc=0" "rc=$RC"
[ "$(has_mark)" = "no" ] && ok "--restore 后无标记" || bad "--restore 后无标记" "仍含"
[ ! -f "$MET/pending_restore" ] && ok "pending 已清除" || bad "pending 已清除" "存在"
echo ""

echo "== B3 sha 守卫（注入后被改写）=="
run_bm "$T/3a.log" --pod fakepod --symbol P2PCameraOverlap --keep
printf '# touched by pod install\n' >> "$XCC"
run_bm "$T/3.log" --pod fakepod --symbol P2PCameraOverlap --restore
RC=$?
[ "$RC" -eq 2 ] && ok "sha 不符 ⇒ 拒绝还原 rc=2" || bad "sha 不符 rc=2" "rc=$RC"
[ "$(has_mark)" = "yes" ] && ok "拒绝时未改动文件" || bad "拒绝时未改动文件" "被覆盖"
run_bm "$T/3b.log" --pod fakepod --symbol P2PCameraOverlap --restore --force
RC=$?
[ "$RC" -eq 0 ] && ok "--force 还原 rc=0" || bad "--force 还原 rc=0" "rc=$RC"
[ "$(has_mark)" = "no" ] && ok "--force 后无标记" || bad "--force 后无标记" "仍含"
echo ""

echo "== B4 判据缺失 ⇒ 回滚 + pending + --clear-pending =="
STUB_DROP_SYMBOL=1 run_bm "$T/4.log" --pod fakepod --symbol P2PCameraOverlap --control 'ThingLogSDK.startLog done'
RC=$?
[ "$RC" -eq 1 ] && ok "判据缺失 rc=1" || bad "判据缺失 rc=1" "rc=$RC"
[ "$(has_mark)" = "no" ] && ok "失败后 xcconfig 已回滚" || bad "失败后已回滚" "仍含"
[ -f "$MET/pending_restore" ] && ok "失败后留 pending" || bad "失败后留 pending" "缺失"
run_bm "$T/4b.log" --pod fakepod --clear-pending
RC=$?
[ "$RC" -eq 0 ] && ok "--clear-pending rc=0" || bad "--clear-pending rc=0" "rc=$RC"
[ ! -f "$MET/pending_restore" ] && ok "pending 已清" || bad "pending 已清" "存在"
echo ""

echo "== B5 --mode release 落 state，--restore 沿用 =="
run_bm "$T/5a.log" --pod fakepod --symbol P2PCameraOverlap --mode release --keep
grep -q '^mode=release$' "$MET/fakepod.state" 2>/dev/null && ok "state 记 release" || bad "state 记 release" "$(cat "$MET/fakepod.state" 2>/dev/null)"
: > "$PROJ/build/debug/build_args.log"
run_bm "$T/5.log" --pod fakepod --symbol P2PCameraOverlap --restore
RC=$?
grep -q -- '--release' "$PROJ/build/debug/build_args.log" 2>/dev/null && ok "--restore 用 release 重编" || bad "--restore 用 release 重编" "$(cat "$PROJ/build/debug/build_args.log" 2>/dev/null)"
[ "$RC" -eq 0 ] && ok "--restore rc=0" || bad "--restore rc=0" "rc=$RC"
echo ""

echo "== B6/B7/B8 用法与前置守卫 =="
run_bm "$T/6.log" --pod fakepod --symbol X --mode debug
RC=$?
[ "$RC" -eq 2 ] && ok "--mode debug ⇒ rc=2" || bad "--mode debug ⇒ rc=2" "rc=$RC"
SAFE_RUN_PROFILE=ios run_bm "$T/7.log" --pod fakepod --symbol X
RC=$?
[ "$RC" -eq 3 ] && ok "沙箱内 ⇒ rc=3" || bad "沙箱内 ⇒ rc=3" "rc=$RC"
printf '\nSWIFT_ACTIVE_COMPILATION_CONDITIONS = $(inherited) INTERNAL_METRICS\n' >> "$XCC"
run_bm "$T/8.log" --pod fakepod --clear-pending
RC=$?
[ "$RC" -eq 1 ] && ok "文件仍含标记 ⇒ --clear-pending 拒绝" || bad "--clear-pending 拒绝" "rc=$RC"
cp "$MET/fakepod.xcconfig.bak" "$XCC" 2>/dev/null || sed -i '' '/INTERNAL_METRICS/d' "$XCC"
rm -f "$MET/pending_restore" "$MET/fakepod.xcconfig.bak" "$MET/fakepod.state"
echo ""

echo "================================"
if [ "$FAIL" -eq 0 ]; then
  echo "✅ 全部通过（${PASS} 项）"
  exit 0
fi
echo "❌ 失败 ${FAIL} 项（通过 ${PASS} 项）"
for f in "${FAILED[@]}"; do echo "   - ${f}"; done
exit 1
