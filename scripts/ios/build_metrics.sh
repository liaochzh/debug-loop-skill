#!/bin/bash
# build_metrics.sh — INTERNAL_METRICS 内测包：注入 → 构建 → strings 判据 → 还原 → 重编 → 归零
#
# 背景：iOS 侧埋点（如 `[P2PCameraOverlap]`）包在 `#if DEBUG || INTERNAL_METRICS` 里，
#   正式包不带符号；要采样必须临时给 Pods 的 `<pod>.release.xcconfig` 加编译条件再构建。
#   该文件被 Profile/Release 共用且常被 gitignore ⇒ 漏还原就会让正式包带上 NSLog。
#   本脚本把这条流程做成状态机：任一步失败都回滚并留 pending 标记，绝不静默留脏。
#
# 用法:
#   build_metrics.sh --pod <pod> --symbol <串> [--symbol <串> ...] [--control <串> ...]
#                    [--mode profile|release] [--project-root <目录>] [--keep] [--force]
#   build_metrics.sh --pod <pod> --symbol <串> [...] --restore [--mode ...] [--force]
#   build_metrics.sh --pod <pod> --clear-pending [--project-root <目录>]
#
# 参数:
#   --pod <名>        Pod 名（xcconfig 形如 `Pods/Target Support Files/<pod>/<pod>.release.xcconfig`）
#   --symbol <串>     注入后必须出现的符号串（可多次；`--restore` 时要求计数为 0）
#   --control <串>    对照串（可多次）：任何时刻都应 ≥1，用来证明 strings 通道没坏
#   --mode <模式>     profile | release（默认 profile）。**不接受 debug**：debug 走 debug.xcconfig，
#                     且 `#if DEBUG` 会让判据恒真 ⇒ 断言假阳性
#   --restore         只做后半段：还原 xcconfig → 重编 → 断言判据归零
#   --clear-pending   清除 pending 标记（仅当 xcconfig 已无 INTERNAL_METRICS）；确属误报时的人工出口
#   --keep            故意保留注入态（不自动还原）；会写 pending 标记，之后必须手工 --restore
#   --force           放宽两处守卫：覆盖来源不明的 .bak / 忽略「注入后被改写」的 sha 不符
#   --project-root    项目根（默认当前目录）
#
# 状态文件（都在 <项目根>/build/debug/metrics/）:
#   <pod>.xcconfig.bak     注入前原始文件
#   <pod>.state            注入时的 mode / sha_before / sha_injected（供 --restore 用同一模式）
#   pending_restore        未确认归零的标记：存在时拒绝再次注入
#   <pod>.strings.txt      最近一次 `strings` 快照（人工核对用）
#   build_metrics.log      审计日志
#
# 退出码: 0 成功 / 1 断言失败或状态异常 / 2 用法错 / 3 只能在宿主机执行（沙箱内构建不了）
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

usage() { awk 'NR<2 {next} /^[^#[:space:]]/ {exit} {sub(/^# ?/, ""); print}' "$0"; }
die_usage() { echo "build_metrics: $1" >&2; exit 2; }

POD=""; MODE="profile"; PROJECT_ROOT=""
DO_RESTORE=0; DO_CLEAR=0; KEEP=0; FORCE=0
SYMBOLS=(); CONTROLS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --pod)          [ $# -ge 2 ] || die_usage "--pod 需要参数值";           POD="$2"; shift 2 ;;
    --symbol)       [ $# -ge 2 ] || die_usage "--symbol 需要参数值";        SYMBOLS+=("$2"); shift 2 ;;
    --control)      [ $# -ge 2 ] || die_usage "--control 需要参数值";       CONTROLS+=("$2"); shift 2 ;;
    --mode)         [ $# -ge 2 ] || die_usage "--mode 需要参数值";          MODE="$2"; shift 2 ;;
    --project-root) [ $# -ge 2 ] || die_usage "--project-root 需要参数值";  PROJECT_ROOT="$2"; shift 2 ;;
    --restore)      DO_RESTORE=1; shift ;;
    --clear-pending) DO_CLEAR=1; shift ;;
    --keep)         KEEP=1; shift ;;
    --force)        FORCE=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *)              die_usage "未知参数: $1" ;;
  esac
done

[ -n "$POD" ] || die_usage "缺少 --pod"
case "$MODE" in
  profile|release) ;;
  *) die_usage "--mode 只接受 profile|release（debug 下 #if DEBUG 会让判据恒真）" ;;
esac
if [ -n "${SAFE_RUN_PROFILE:-}" ]; then
  echo "build_metrics: 构建只能在宿主机执行（沙箱内 flutter build ios 会嵌套 sandbox-exec 被拒）" >&2
  echo "               请由主 agent 在宿主机运行本脚本" >&2
  exit 3
fi
if [ "$DO_RESTORE" -eq 1 ] && [ "$KEEP" -eq 1 ]; then
  die_usage "--restore 与 --keep 互斥"
fi
if [ "$DO_CLEAR" -eq 0 ] && [ "${#SYMBOLS[@]}" -eq 0 ]; then
  die_usage "至少需要一个 --symbol（--restore 也用它断言归零）"
fi

if [ -z "$PROJECT_ROOT" ]; then PROJECT_ROOT="$PWD"; fi
_r="$(cd "$PROJECT_ROOT" 2>/dev/null && pwd -P || true)"
[ -n "$_r" ] || die_usage "项目根不存在或不是目录：${PROJECT_ROOT}"
PROJECT_ROOT="$_r"
cd "$PROJECT_ROOT" || die_usage "无法进入项目根：${PROJECT_ROOT}"

LOG_DIR="${LOG_DIR:-build/debug}"
METRICS_DIR="${LOG_DIR}/metrics"
XCCONFIG="ios/Pods/Target Support Files/${POD}/${POD}.release.xcconfig"
BAK="${METRICS_DIR}/${POD}.xcconfig.bak"
STATE="${METRICS_DIR}/${POD}.state"
PENDING="${METRICS_DIR}/pending_restore"
STRINGS="${METRICS_DIR}/${POD}.strings.txt"
AUDIT="${METRICS_DIR}/build_metrics.log"

sha_of() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; }
audit() { printf '%s\tmode=%s\tpod=%s\t%s\n' "$(date '+%F %T')" "$MODE" "$POD" "$1" >> "$AUDIT" 2>/dev/null || true; }
pending_write() {
  {
    printf 'pod=%s\nxcconfig=%s\nmode=%s\nreason=%s\nts=%s\n' \
      "$POD" "$XCCONFIG" "$MODE" "$1" "$(date '+%F %T')"
  } > "$PENDING" 2>/dev/null || true
  # 标记写不进去时不能假装写了（否则下次注入不会被拒）
  [ -f "$PENDING" ] || echo "⚠️  无法写待处理标记 ${PENDING}：请手工确认 ${XCCONFIG} 是否已还原、产物是否已重编" >&2
}
count_of() { grep -c -F -- "$1" "$STRINGS" 2>/dev/null || true; }

# ---- 状态机：任何退出路径都要么「文件干净 + 已重编」，要么留下 pending 标记 ----
INJECTED=0; RESTORING=0; RESTORED=0; RECOMPILED=0; GUARD_BLOCKED=0
on_exit() {
  local rc=$?
  if [ "$KEEP" -eq 1 ]; then
    if [ "$INJECTED" -eq 1 ]; then
      pending_write "--keep：二进制与 xcconfig 均含 INTERNAL_METRICS，必须手工 --restore"
    fi
    exit "$rc"
  fi
  if [ "$GUARD_BLOCKED" -eq 0 ] && [ "$INJECTED" -eq 1 ] && [ "$RESTORED" -eq 0 ] && [ -f "$BAK" ]; then
    # 中断/失败：先回滚文件（避免「文件干净但二进制脏」之外的情况继续跑），再记 pending
    cp "$BAK" "$XCCONFIG" 2>/dev/null || true
    RESTORED=1
    echo "⚠️  已回滚 ${XCCONFIG}（构建被中断或失败）" >&2
  fi
  if [ "$GUARD_BLOCKED" -eq 0 ] \
     && [ $((INJECTED + RESTORING)) -gt 0 ] && [ "$RESTORED" -eq 1 ] && [ "$RECOMPILED" -eq 0 ]; then
    pending_write "xcconfig 已还原但未重编（二进制可能仍含 INTERNAL_METRICS）"
    if [ -f "$PENDING" ]; then
      echo "⚠️  未重编 ⇒ 已写待处理标记 ${PENDING}；下次注入前必须 --restore" >&2
    fi
  fi
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

build_once() {
  local mode_args="--profile"
  [ "$MODE" = "release" ] && mode_args="--release"
  echo "🔨 构建（--device ${mode_args}）…"
  bash "${SKILL_DIR}/scripts/ios/build.sh" --device "$mode_args"
}

collect_strings() {
  local app="" exe=""
  app="$(cat "${LOG_DIR}/.last_ios_app_device" 2>/dev/null || true)"
  if [ -z "$app" ] || [ ! -d "$app" ]; then
    echo "❌ 构建产物缺失（${LOG_DIR}/.last_ios_app_device = '${app}'）" >&2
    return 1
  fi
  # 可执行名不写死：优先复用 _common.sh 的解析（PlistBuddy → .app 名 → Runner）；
  #   `_common.sh` 要求 cwd 是标准 Flutter 工程（pubspec.yaml/.debug.env），不满足时
  #   在子 shell 里 source 会 exit ⇒ 退回同语义的本地解析，不让判据因目录布局失败。
  exe="$( . "${SCRIPT_DIR}/_common.sh" >/dev/null 2>&1 && resolve_ios_app_name "$app" device )" || true
  if [ -z "$exe" ] && [ -f "${app}/Info.plist" ]; then
    exe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${app}/Info.plist" 2>/dev/null || true)"
  fi
  [ -n "$exe" ] || exe="$(basename "$app" .app)"
  if [ -z "$exe" ] || [ ! -f "${app}/${exe}" ]; then
    echo "❌ 找不到可执行文件：${app}/${exe}" >&2
    return 1
  fi
  strings -a "${app}/${exe}" > "$STRINGS" 2>/dev/null || true
  if [ ! -s "$STRINGS" ]; then
    echo "❌ strings 输出为空：${app}/${exe}" >&2
    return 1
  fi
  echo "🔤 strings 快照: ${STRINGS}（可执行 ${exe}）"
}

assert_symbols_ge1() {
  local s c bad=0
  for s in "${SYMBOLS[@]}"; do
    c="$(count_of "$s")"; c="${c:-0}"
    printf '   · %s = %s（要求 ≥1）\n' "$s" "$c"
    [ "$c" -ge 1 ] || bad=1
  done
  return "$bad"
}
assert_symbols_zero() {
  local s c bad=0
  for s in "${SYMBOLS[@]}"; do
    c="$(count_of "$s")"; c="${c:-0}"
    printf '   · %s = %s（要求 =0）\n' "$s" "$c"
    [ "$c" -eq 0 ] || bad=1
  done
  return "$bad"
}
assert_controls_ge1() {
  local s c bad=0
  [ "${#CONTROLS[@]}" -eq 0 ] && return 0
  for s in "${CONTROLS[@]}"; do
    c="$(count_of "$s")"; c="${c:-0}"
    printf '   · 对照 %s = %s（要求 ≥1）\n' "$s" "$c"
    [ "$c" -ge 1 ] || bad=1
  done
  return "$bad"
}

# ---- --clear-pending：人工出口（只清标记，不改文件、不构建） ----
if [ "$DO_CLEAR" -eq 1 ]; then
  [ -f "$XCCONFIG" ] || die_usage "找不到 xcconfig：${XCCONFIG}（先在该项目跑 pod install）"
  if grep -q 'INTERNAL_METRICS' "$XCCONFIG" 2>/dev/null; then
    echo "❌ ${XCCONFIG} 仍含 INTERNAL_METRICS ⇒ 先跑 --restore（本参数只清标记）" >&2
    exit 1
  fi
  rm -f "$PENDING"
  echo "✅ 已清除待处理标记 ${PENDING}（仍需自行重编并复核 strings 归零）"
  audit "clear-pending"
  exit 0
fi

[ -f "$XCCONFIG" ] || die_usage "找不到 xcconfig：${XCCONFIG}（先在该项目跑 pod install）"
mkdir -p "$METRICS_DIR" 2>/dev/null || true

# ---- --restore：还原 → 同模式重编 → 归零断言 ----
restore_flow() {
  local state_mode="" sha_exp="" sha_cur=""
  if [ ! -f "$BAK" ]; then
    echo "❌ 没有备份 ${BAK}，无法还原（文件若已含标记请人工处理，或 --clear-pending 清标记）" >&2
    return 2
  fi
  # 用注入时记录的 mode（独立进程默认 profile，会和 release 注入产物错配）
  state_mode="$(sed -n 's/^mode=//p' "$STATE" 2>/dev/null | head -1 || true)"
  if [ -n "$state_mode" ]; then
    MODE="$state_mode"
  else
    echo "⚠️  缺少 ${STATE}（mode 未知）⇒ 按当前 --mode=${MODE} 重编"
  fi
  # sha 守卫：注入后若被 `pod install` 重写，还原会把别人的新文件覆盖成旧备份
  sha_exp="$(sed -n 's/^sha_injected=//p' "$STATE" 2>/dev/null | head -1 || true)"
  sha_cur="$(sha_of "$XCCONFIG")"
  if [ -n "$sha_exp" ] && [ "$sha_exp" != "$sha_cur" ]; then
    echo "⚠️  xcconfig 在注入后被改写（sha 不符）：" >&2
    echo "     期望(注入时)=${sha_exp}" >&2
    echo "     当前         =${sha_cur}" >&2
    if [ "$FORCE" -ne 1 ]; then
      echo "     拒绝还原（可能是 pod install 重新生成了文件）。确认要覆盖请加 --force" >&2
      GUARD_BLOCKED=1
      return 2
    fi
    echo "     --force：仍按备份还原" >&2
  fi
  cp "$BAK" "$XCCONFIG" || { echo "❌ 还原失败：${XCCONFIG}" >&2; return 1; }
  RESTORED=1
  # 保留 mode 供重试（重编失败后 `--restore` 仍按同一模式），但**去掉 sha_injected**：
  #   文件已还原，再拿它比对会把「重试」误判成「注入后被改写」。
  {
    printf 'pod=%s\nmode=%s\nrestored_ts=%s\n' "$POD" "$MODE" "$(date '+%F %T')"
  } > "$STATE" 2>/dev/null || true
  if grep -q 'INTERNAL_METRICS' "$XCCONFIG" 2>/dev/null; then
    echo "❌ 还原后 xcconfig 仍含 INTERNAL_METRICS（备份本身被污染？）：${BAK}" >&2
    return 1
  fi
  echo "♻️  已还原 ${XCCONFIG}，开始重编（mode=${MODE}）…"
  build_once || { echo "❌ 还原后构建失败" >&2; return 1; }
  collect_strings || { echo "❌ 还原后取 strings 失败" >&2; return 1; }
  echo "🔍 归零校验（要求 =0）："
  if ! assert_symbols_zero; then echo "❌ 判据未归零：二进制仍带 INTERNAL_METRICS" >&2; return 1; fi
  if ! assert_controls_ge1; then echo "❌ 对照串缺失：strings 通道异常，判据不可信" >&2; return 1; fi
  RECOMPILED=1
  rm -f "$PENDING" "$BAK" "$STATE"
  audit "restore-ok sha_before=${sha_exp:-?} symbols=0"
  echo "✅ 还原完成：判据归零，待处理标记已清除"
  return 0
}

if [ "$DO_RESTORE" -eq 1 ]; then
  RESTORING=1
  restore_flow; _rc=$?
  if [ "$_rc" -ne 0 ]; then
    [ "$_rc" -eq 2 ] || pending_write "还原流程失败（rc=${_rc}）"
    exit "$_rc"
  fi
  exit 0
fi

# ---- 注入路径 ----
if grep -q 'INTERNAL_METRICS' "$XCCONFIG" 2>/dev/null; then
  echo "❌ ${XCCONFIG} 已含 INTERNAL_METRICS（上次未还原？）⇒ 先跑 --restore" >&2
  exit 1
fi
if [ -f "$PENDING" ]; then
  echo "❌ 存在待处理标记（上次注入后未确认归零）：${PENDING}" >&2
  sed 's/^/     /' "$PENDING" >&2
  echo "     先跑 --restore；确属误报可用 --clear-pending 人工裁决" >&2
  exit 1
fi
if [ -f "$BAK" ] && [ ! -f "$STATE" ]; then
  if [ "$FORCE" -ne 1 ]; then
    echo "❌ 存在来源不明的备份 ${BAK}（无对应 .state）⇒ 确认无用后加 --force" >&2
    exit 2
  fi
  echo "⚠️  --force：将覆盖来源不明的备份 ${BAK}" >&2
fi

cp "$XCCONFIG" "$BAK" || { echo "❌ 备份失败：${BAK}" >&2; exit 1; }
SHA_BEFORE="$(sha_of "$XCCONFIG")"
if grep -qE '^[[:space:]]*SWIFT_ACTIVE_COMPILATION_CONDITIONS[[:space:]]*=' "$XCCONFIG"; then
  # 已有该行 ⇒ 行尾追加 token（重定义整行会把文件里原有的条件丢掉）
  /usr/bin/sed -i '' -E \
    's/^([[:space:]]*SWIFT_ACTIVE_COMPILATION_CONDITIONS[[:space:]]*=.*)$/\1 INTERNAL_METRICS/' \
    "$XCCONFIG"
else
  printf '\nSWIFT_ACTIVE_COMPILATION_CONDITIONS = $(inherited) INTERNAL_METRICS\n' >> "$XCCONFIG"
fi
if ! grep -q 'INTERNAL_METRICS' "$XCCONFIG" 2>/dev/null; then
  echo "❌ 注入未生效（可能该文件是只读或路径不对）：${XCCONFIG}" >&2
  exit 1
fi
SHA_INJECTED="$(sha_of "$XCCONFIG")"
INJECTED=1
{
  printf 'pod=%s\nmode=%s\nsha_before=%s\nsha_injected=%s\nts=%s\n' \
    "$POD" "$MODE" "$SHA_BEFORE" "$SHA_INJECTED" "$(date '+%F %T')"
} > "$STATE" 2>/dev/null || true
audit "inject sha_before=${SHA_BEFORE} sha_injected=${SHA_INJECTED}"
echo "💉 已注入 INTERNAL_METRICS → ${XCCONFIG}（备份 ${BAK}）"

build_once || { echo "❌ 注入后构建失败" >&2; exit 1; }
collect_strings || { echo "❌ 取 strings 失败" >&2; exit 1; }
echo "🔍 注入校验（要求 ≥1）："
if ! assert_symbols_ge1; then
  echo "❌ 判据未出现：注入没生效，或构建模式与 xcconfig 不匹配（mode=${MODE}）" >&2
  audit "assert-fail symbol-missing mode=${MODE}"
  exit 1
fi
if ! assert_controls_ge1; then
  echo "❌ 对照串缺失：strings 通道异常，判据不可信" >&2
  audit "assert-fail control-missing"
  exit 1
fi
audit "inject-ok sha_before=${SHA_BEFORE} sha_injected=${SHA_INJECTED}"

if [ "$KEEP" -eq 1 ]; then
  echo "⚠️  --keep：二进制与 xcconfig 均含 INTERNAL_METRICS；必须手工跑 --restore 才能出正式包"
  exit 0
fi

echo "♻️  自动还原（无需 --keep）…"
restore_flow; _rc=$?
if [ "$_rc" -ne 0 ]; then
  [ "$_rc" -eq 2 ] || pending_write "注入成功后还原失败（rc=${_rc}）"
  exit "$_rc"
fi
exit 0
