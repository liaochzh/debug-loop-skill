#!/bin/bash
# evidence.sh — 一条命令产出取证包（settle → 快照摘要 → 日志异常摘要 → 可选断言；--artifact 校验产物）
#
# 为什么需要本脚本（2026-11-17 立项）：
#   autoDebug 每轮回报都要「截图 / 快照 / 日志 / 断言」四件套，逐个命令跑 = 4 轮推理 + 4 处手工汇总；
#   而且四处产物散落在 build/debug/ 下，回报时经常漏项。本脚本把四件套收敛成**一个落点**
#   （build/debug/evidence/<ts>/）+ **一行结论**，agent 只需读目录名与结论行。
#
# 设计要点：
#   · 落点固定 build/debug/evidence/<ts>/（沙箱 ui profile 可写），每项一个文件，缺项也留占位说明；
#   · 子脚本 rc 只作**证据项状态**记录，不冒泡成「崩溃」：日志文件不存在（App 未运行）属正常观测；
#   · iOS 模拟器语义不可用（snapshot rc=3 既有契约）⇒ 自动降级 shot.sh + logs.sh 并在结论里注明；
#   · `--artifact` 走**无设备路径**：只读构建锁文件（$LOG_DIR/.last_*）输出 路径 / 是否存在 / sha256，
#     供构建后校验（构建慢、取证不该再依赖设备在线）。
#
# 用法:
#   evidence.sh                                 # 自动判平台，产出四件套
#   evidence.sh --platform android --has 首页 --wait 10
#   evidence.sh --platform ios --assert <断言文件>
#   evidence.sh --artifact                      # 只校验构建产物（不需要设备）
#   evidence.sh --platform android --artifact   # 只校验 Android 产物
#
# 选项:
#   --platform P     android（默认自动判定）| ios | ios-device | macos
#   --assert FILE    断言文件（转发 assert_page.sh --file；断言失败 ⇒ 结论 FAIL + rc=1）
#   --has TEXT       断言行（可重复，转发 assert_page.sh --has）
#   --has-not TEXT   反向断言行（可重复，转发 assert_page.sh --has-not）
#   --wait N         断言轮询秒数（转发 assert_page.sh --wait，默认 0）
#   --lines N        日志行数（默认 200）
#   --no-settle      跳过 settle（快速取证）
#   --no-logs        跳过日志采集
#   --artifact       只做产物校验（跳过 settle/快照/日志/断言）
#   --note TEXT      备注（写入 meta.txt）
#
# 退出码:
#   0 取证包已生成且无失败项（含断言通过；--artifact 时全部产物存在）
#   1 有失败项（断言 FAIL / 证据采集失败 / --artifact 有缺失）
#   2 用法错
#   3 平台不可判定或不受支持
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_platform_detect.sh"

LOG_DIR="${LOG_DIR:-build/debug}"

PLATFORM=""; ASSERT_FILE=""; WAIT=0; LINES=200
DO_SETTLE=1; DO_LOGS=1; ARTIFACT=0; NOTE=""
HAS_ARGS=()

usage() {
  awk 'NR < 3 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"
}
die_usage() { echo "❌ $1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --platform) [ $# -ge 2 ] || die_usage "--platform 缺参数值"; PLATFORM="$2"; shift 2 ;;
    --assert)   [ $# -ge 2 ] || die_usage "--assert 缺参数值";   ASSERT_FILE="$2"; shift 2 ;;
    --has)      [ $# -ge 2 ] || die_usage "--has 缺参数值";      HAS_ARGS+=(--has "$2"); shift 2 ;;
    --has-not)  [ $# -ge 2 ] || die_usage "--has-not 缺参数值";  HAS_ARGS+=(--has-not "$2"); shift 2 ;;
    --wait)     [ $# -ge 2 ] || die_usage "--wait 缺参数值";     WAIT="$2"; shift 2 ;;
    --lines)    [ $# -ge 2 ] || die_usage "--lines 缺参数值";    LINES="$2"; shift 2 ;;
    --no-settle) DO_SETTLE=0; shift ;;
    --no-logs)   DO_LOGS=0; shift ;;
    --artifact)  ARTIFACT=1; shift ;;
    --note)      [ $# -ge 2 ] || die_usage "--note 缺参数值";    NOTE="$2"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "❌ 未知参数: $1" >&2; exit 2 ;;
  esac
done

case "$LINES" in ''|*[!0-9]*) die_usage "--lines 需为正整数（收到: ${LINES}）" ;; esac
case "$WAIT" in ''|*[!0-9]*) die_usage "--wait 需为非负整数（收到: ${WAIT}）" ;; esac

# 项目根判据：与既有脚本家族一致（按 $PWD 找 .debug.env）
if [ ! -f ".debug.env" ]; then
  echo "❌ 请在项目根执行（当前目录无 .debug.env）" >&2
  exit 3
fi

if [ -z "$PLATFORM" ]; then
  PLATFORM="$(detect_platform || true)"
  if [ -z "$PLATFORM" ]; then
    if [ "$ARTIFACT" -eq 1 ]; then
      # 产物校验是**无设备路径**（构建后设备常不在线）⇒ 判平台失败不阻断，改为扫描全部锁文件
      PLATFORM="any"
    else
      echo "❌ 无法自动判定平台（adb 无在线设备、无已启动 iOS 模拟器）：请显式 --platform" >&2
      echo "   只校验构建产物可直接用 --artifact（不需要设备）" >&2
      exit 3
    fi
  fi
fi
case "$PLATFORM" in
  android|ios|ios-device|macos|any) ;;
  *) echo "❌ 平台不受支持: ${PLATFORM}（支持 android|ios|ios-device|macos）" >&2; exit 3 ;;
esac
if [ "$PLATFORM" = "any" ] && [ "$ARTIFACT" -ne 1 ]; then
  echo "❌ --platform any 只用于 --artifact（全平台产物扫描）；取证请给具体平台" >&2
  exit 3
fi

case "$PLATFORM" in
  android)   PLAT_DIR="android" ;;
  ios)       PLAT_DIR="ios" ;;
  ios-device) PLAT_DIR="ios" ;;
  macos)     PLAT_DIR="macos" ;;
  any)       PLAT_DIR="" ;;
esac

TS="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOG_DIR/evidence" 2>/dev/null || true
OUT="$LOG_DIR/evidence/$TS"
# 同秒并发：用 mkdir 返回码判定（check-then-mkdir 有竞态）
_n=1
until mkdir "$OUT" 2>/dev/null; do
  _n=$((_n + 1))
  OUT="$LOG_DIR/evidence/${TS}-${_n}"
  if [ "$_n" -gt 50 ]; then
    echo "❌ 无法创建取证目录: ${LOG_DIR}/evidence/${TS}*" >&2
    exit 3
  fi
done

SUMMARY="$OUT/summary.txt"
: > "$SUMMARY"
say() { printf '%s\n' "$*" | tee -a "$SUMMARY"; }

say "# 取证包 ${TS}"
say "平台=${PLATFORM} 目录=${OUT}"
if [ -n "$NOTE" ]; then say "备注=${NOTE}"; fi
say ""

FAILED=0
FAIL_ITEMS=()

# ---------------- --artifact：无设备路径 ----------------
artifact_report() {
  local locks lock path type exists hash size extra lenient=0
  case "$PLATFORM" in
    android)    locks=".last_android_apk" ;;
    ios)        locks=".last_ios_app" ;;
    ios-device) locks=".last_ios_app_device" ;;
    macos)      locks=".last_macos_app" ;;
    any)        locks=".last_android_apk .last_ios_app .last_ios_app_device .last_macos_app"; lenient=1 ;;
  esac
  local found=0 missing=0
  if [ "$PLATFORM" = "any" ]; then
    say "== 产物校验（--artifact，全平台扫描） =="
  else
    say "== 产物校验（--artifact，平台=${PLATFORM}） =="
  fi
  for lock in $locks; do
    local lockfile="$LOG_DIR/$lock"
    if [ ! -f "$lockfile" ]; then
      if [ "$lenient" -eq 1 ]; then
        say "⏭  ${lock}: 无锁文件（该平台未构建，跳过）"
      else
        say "❌ ${lock}: 锁文件不存在（${lockfile}）—— 先构建"
        missing=$((missing + 1))
      fi
      continue
    fi
    found=$((found + 1))
    path="$(head -n 1 "$lockfile" 2>/dev/null || true)"
    if [ -z "$path" ]; then
      say "❌ ${lock}: 锁文件为空（${lockfile}）"
      missing=$((missing + 1))
      continue
    fi
    case "$path" in
      /*) ;;
      *) path="$PWD/$path" ;;
    esac
    if [ -e "$path" ]; then exists="yes"; else exists="no"; fi
    if [ ! -e "$path" ]; then
      say "❌ ${lock}: 路径不存在 exists=no"
      say "   path=${path}"
      missing=$((missing + 1))
      continue
    fi
    if [ -d "$path" ]; then
      type="dir"
      size="—"
      extra="files=$(find "$path" -type f 2>/dev/null | wc -l | tr -d ' ')"
      if [ -f "$path/Info.plist" ]; then
        hash="$(shasum -a 256 "$path/Info.plist" | awk '{print $1}')"
        extra="${extra} sha256(Info.plist)=${hash}"
      elif [ -f "$path/Contents/Info.plist" ]; then
        # macOS .app 的 Info.plist 在 Contents/ 下（iOS 模拟器 bundle 在根）
        hash="$(shasum -a 256 "$path/Contents/Info.plist" | awk '{print $1}')"
        extra="${extra} sha256(Contents/Info.plist)=${hash}"
      else
        extra="${extra} sha256=—（目录，无 Info.plist）"
      fi
    else
      type="file"
      size="$(wc -c < "$path" | tr -d ' ')"
      hash="$(shasum -a 256 "$path" | awk '{print $1}')"
      extra="sha256=${hash}"
    fi
    say "✅ ${lock}: exists=${exists} type=${type} size=${size} ${extra}"
    say "   path=${path}"
  done
  say ""
  if [ "$found" -eq 0 ]; then
    say "结论: FAIL（无可校验产物：先构建写出 ${LOG_DIR}/.last_* 锁）"
    return 1
  fi
  if [ "$missing" -gt 0 ]; then
    say "结论: FAIL（${missing} 项缺失）"
    return 1
  fi
  say "结论: PASS（产物存在；文件给 sha256，目录给文件数 + Info.plist sha）"
  return 0
}

if [ "$ARTIFACT" -eq 1 ]; then
  # artifact_report 内部已用 say（同时写 stdout 与 summary.txt），不能再外层重定向
  if artifact_report; then :; else FAILED=1; FAIL_ITEMS+=("artifact"); fi
  say "📦 取证包: ${OUT}"
  echo "---- 结论 ----" >&2
  sed -n '/^结论:/p' "$SUMMARY" >&2 || true
  [ "$FAILED" -eq 0 ] || exit 1
  exit 0
fi

# ---------------- 1. settle ----------------
SETTLE_SH="$SCRIPT_DIR/$PLAT_DIR/settle.sh"
if [ "$DO_SETTLE" -eq 0 ]; then
  say "== settle == 跳过（--no-settle）"
elif [ ! -f "$SETTLE_SH" ]; then
  say "== settle == 跳过（${PLAT_DIR} 无 settle.sh）"
else
  set +e
  bash "$SETTLE_SH" > "$OUT/settle.txt" 2>&1
  rc=$?
  set -e
  case "$rc" in
    0) say "== settle == ✅ rc=0 $(grep -o '判据=[a-z]*' "$OUT/settle.txt" | head -n 1)" ;;
    1) say "== settle == ⚠️ rc=1 超时未静止（非异常，按当前画面取证）: settle.txt" ;;
    *) say "== settle == ⚠️ rc=${rc}（见 settle.txt）"; FAILED=1; FAIL_ITEMS+=("settle") ;;
  esac
fi

# ---------------- 2. snapshot ------------
set +e
bash "$SCRIPT_DIR/snapshot.sh" --platform "$PLATFORM" --max 40 > "$OUT/snapshot.txt" 2>&1
SNAP_RC=$?
set -e
SNAP_ITEMS="$(grep -c . "$OUT/snapshot.txt" 2>/dev/null || true)"
case "$SNAP_RC" in
  0) say "== snapshot == ✅ rc=0（${SNAP_ITEMS} 行摘要）: snapshot.txt" ;;
  4) say "== snapshot == ⚠️ rc=4 语义树为空（正常观测，常见于 Flutter 未开语义/WebView）: snapshot.txt" ;;
  3)
    say "== snapshot == ⚠️ rc=3 语义不可用 ⇒ 按既有契约降级为截图+日志（截图/日志为本包主证据）"
    if [ -f "$SCRIPT_DIR/$PLAT_DIR/shot.sh" ]; then
      set +e
      if [ "$PLATFORM" = "ios-device" ]; then
        bash "$SCRIPT_DIR/$PLAT_DIR/shot.sh" --device > "$OUT/shot.txt" 2>&1
      else
        bash "$SCRIPT_DIR/$PLAT_DIR/shot.sh" > "$OUT/shot.txt" 2>&1
      fi
      rc=$?
      set -e
      if [ "$rc" -eq 0 ] && [ -f "$LOG_DIR/screen.png" ]; then
        cp "$LOG_DIR/screen.png" "$OUT/shot.png" 2>/dev/null || true
        say "   shot: ✅ rc=0（主证据: shot.png）"
      else
        say "   shot: ⚠️ rc=${rc}（见 shot.txt）；无截图时证据仅为日志"
      fi
    else
      say "   shot: ⚠️ ${PLAT_DIR} 无 shot.sh"
    fi
    ;;
  *) say "== snapshot == ⚠️ rc=${SNAP_RC}（快照失败，见 snapshot.txt）"; FAILED=1; FAIL_ITEMS+=("snapshot") ;;
esac

# ---------------- 3. logs（异常摘要） ----------------
if [ "$DO_LOGS" -eq 0 ]; then
  say "== logs == 跳过（--no-logs）"
else
  set +e
  if [ "$PLATFORM" = "ios-device" ]; then
    bash "$SCRIPT_DIR/$PLAT_DIR/logs.sh" --device "$LINES" > "$OUT/logs.txt" 2>&1
  else
    bash "$SCRIPT_DIR/$PLAT_DIR/logs.sh" "$LINES" > "$OUT/logs.txt" 2>&1
  fi
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    grep -iE 'error|exception|fatal|crash|anr|(#| E )' "$OUT/logs.txt" 2>/dev/null | head -n 30 > "$OUT/logs-errors.txt" || true
    ERRS="$(grep -c . "$OUT/logs-errors.txt" 2>/dev/null || true)"
    say "== logs == ✅ rc=0（${LINES} 行；异常候选 ${ERRS} 行 → logs-errors.txt）"
  else
    say "== logs == ⚠️ rc=${rc}（App 可能未运行/日志文件不存在，见 logs.txt）"
  fi
fi

# ---------------- 4. assert（可选） ----------------
AS_RC=""
if [ -n "$ASSERT_FILE" ] || [ "${#HAS_ARGS[@]}" -gt 0 ]; then
  AARGS=(--platform "$PLATFORM")
  if [ -n "$ASSERT_FILE" ]; then AARGS+=(--file "$ASSERT_FILE"); fi
  if [ "${#HAS_ARGS[@]}" -gt 0 ]; then AARGS+=("${HAS_ARGS[@]}"); fi
  if [ "$WAIT" -gt 0 ]; then AARGS+=(--wait "$WAIT"); fi
  set +e
  bash "$SCRIPT_DIR/assert_page.sh" "${AARGS[@]}" > "$OUT/assert.txt" 2>&1
  AS_RC=$?
  set -e
  case "$AS_RC" in
    0) say "== assert == ✅ PASS（$(grep -m1 -E 'PASS|通过' "$OUT/assert.txt" || true)）" ;;
    1) say "== assert == ❌ FAIL（见 assert.txt 末行与差异）"; FAILED=1; FAIL_ITEMS+=("assert") ;;
    3) say "== assert == ⚠️ rc=3 该平台语义断言不可用（iOS 模拟器既有契约）⇒ 结论只能基于截图+日志" ;;
    4) say "== assert == ⚠️ rc=4 语义树为空（属正常观测，不能当通过）" ;;
    *) say "== assert == ⚠️ rc=${AS_RC}（见 assert.txt）"; FAILED=1; FAIL_ITEMS+=("assert") ;;
  esac
fi

# ---------------- meta + 结论 ----------------
{
  echo "ts=${TS}"
  echo "platform=${PLATFORM}"
  echo "cwd=${PWD}"
  echo "log_dir=${LOG_DIR}"
  echo "android_serial=${ANDROID_SERIAL:-}"
  echo "ios_device_udid=${IOS_DEVICE_UDID:-}"
  echo "ios_target=${IOS_TARGET:-}"
  echo "note=${NOTE}"
} > "$OUT/meta.txt"

say ""
if [ "$FAILED" -eq 0 ]; then
  if [ -z "$AS_RC" ]; then
    say "结论: PASS（仅观测；未做断言，不能声称「功能验证通过」）"
  else
    say "结论: PASS"
  fi
else
  say "结论: FAIL（失败项: ${FAIL_ITEMS[*]}）"
fi
say "取证包: ${OUT}"

echo "📦 取证包: ${OUT}" >&2
sed -n '/^结论:/p' "$SUMMARY" >&2 || true
[ "$FAILED" -eq 0 ] || exit 1
exit 0
