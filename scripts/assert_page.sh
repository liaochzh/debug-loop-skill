#!/bin/bash
# assert_page.sh — 声明式页面断言（一行结论；失败时自动附「与上一份快照的差异」）
#
# 用法:
#   ./assert_page.sh --file <断言文件> [--platform P] [--with-logs N] [--no-diff]
#   ./assert_page.sh --has "订单列表" --has-not "加载中" --count "订单" 3 --platform android
#   ./assert_page.sh --file <断言文件> --wait 10 [--interval 0.5] [--single-dump] [--no-diff]
#
# 断言文件语法见 _assert_page.py 头部注释。
#
# --wait N（默认 0 = 一次性）:
#   轮询「快照 → 断言」直到通过或超时。轮询期间一律 --no-cache + 自动 --single-dump（Android）；
#   通过后把通过时那份 payload 经 `snapshot.sh --cache-payload` 落盘（供随后 tap_snapshot.sh 复用）。
#   空树（rc=4）在等待期内重试并重置连败；快照连续 2 次失败即放弃（rc=5）；rc=3/2 立即透传；
#   断言引擎自身报错（rc=2/5）也立即透传，不当作「页面没到」重试。
#
# 失败附 diff（默认开，--no-diff 关闭）:
#   仅 rc=1（断言 FAIL / --wait 超时）时，用「产生该断言结果的 payload」与基线比对，变化清单写
#   **stderr**（stdout 契约不变）。基线：一次性路径取 prev（本次快照刚把旧 last 轮转过去）；
#   轮询路径优先 last（轮询期不写缓存，last 即「轮询开始前那一页」），缺失才退 prev。
#   基线缺失/不可解析/方言平台不符 ⇒ 静默跳过。
#
# 测试钩子（正常使用不要设）: SNAPSHOT_BIN（只替换取快照命令；--cache-payload 落盘仍走真实脚本）
#
# 退出码:
#   0 全过 / 1 断言失败或 --wait 超时 / 2 用法错 / 3 平台不可用 / 4 语义树为空 / 5 快照失败
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAP_BIN="${SNAPSHOT_BIN:-$SCRIPT_DIR/snapshot.sh}"
REAL_SNAP="$SCRIPT_DIR/snapshot.sh"
DIFF_PY="$SCRIPT_DIR/_snapshot_diff.py"
LOG_DIR="${LOG_DIR:-build/debug}"

PLATFORM=""; FILE=""; WITH_LOGS=""; ASSERTS=()
DIALECT=""; RESOLVED=""
WAIT=0; INTERVAL="0.5"; SINGLE_DUMP=false; NO_DIFF=false
while [ $# -gt 0 ]; do
  case "$1" in
    --platform) [ $# -ge 2 ] || { echo "❌ --platform 缺参数值"; exit 2; }; PLATFORM="$2"; shift 2 ;;
    --file)     [ $# -ge 2 ] || { echo "❌ --file 缺参数值"; exit 2; };     FILE="$2"; shift 2 ;;
    --with-logs) [ $# -ge 2 ] || { echo "❌ --with-logs 缺参数值"; exit 2; }; WITH_LOGS="$2"; shift 2 ;;
    --wait)     [ $# -ge 2 ] || { echo "❌ --wait 缺参数值"; exit 2; };     WAIT="$2"; shift 2 ;;
    --interval) [ $# -ge 2 ] || { echo "❌ --interval 缺参数值"; exit 2; }; INTERVAL="$2"; shift 2 ;;
    --single-dump) SINGLE_DUMP=true; shift ;;
    --no-diff)  NO_DIFF=true; shift ;;
    --has)      [ $# -ge 2 ] || { echo "❌ --has 缺参数值"; exit 2; };      ASSERTS+=("has $2"); shift 2 ;;
    --has-not)  [ $# -ge 2 ] || { echo "❌ --has-not 缺参数值"; exit 2; };  ASSERTS+=("has-not $2"); shift 2 ;;
    --match)    [ $# -ge 2 ] || { echo "❌ --match 缺参数值"; exit 2; };    ASSERTS+=("match $2"); shift 2 ;;
    --count)    [ $# -ge 3 ] || { echo "❌ --count 需要 <正则> <N>"; exit 2; }; ASSERTS+=("count $2 $3"); shift 3 ;;
    -*) echo "❌ 未知参数: $1"; exit 2 ;;
    *)  echo "❌ 未知参数: $1"; exit 2 ;;
  esac
done

case "$WAIT" in
  ''|*[!0-9]*) echo "❌ --wait 必须为非负整数（秒）: $WAIT"; exit 2 ;;
esac
if ! awk -v v="$INTERVAL" 'BEGIN{exit !(v+0 > 0)}'; then
  echo "❌ --interval 必须为正数（秒）: $INTERVAL"; exit 2
fi

TMP_ASSERT=""; TMP_ERR=""; TMP_CUR=""; TMP_AERR=""
cleanup() {
  [ -n "$TMP_ASSERT" ] && rm -f "$TMP_ASSERT"
  [ -n "$TMP_ERR" ] && rm -f "$TMP_ERR"
  [ -n "$TMP_CUR" ] && rm -f "$TMP_CUR"
  [ -n "$TMP_AERR" ] && rm -f "$TMP_AERR"
  return 0
}
trap cleanup EXIT

if [ -n "$FILE" ] && [ "${#ASSERTS[@]}" -gt 0 ]; then
  echo "❌ --file 与内联断言不能同时使用（避免断言被静默丢弃）"
  exit 2
fi

if [ -z "$FILE" ]; then
  [ "${#ASSERTS[@]}" -gt 0 ] || { echo "❌ 需要 --file 或至少一条断言（--has/--has-not/--match/--count）"; exit 2; }
  TMP_ASSERT=$(mktemp)
  printf '%s\n' "${ASSERTS[@]}" > "$TMP_ASSERT"
  FILE="$TMP_ASSERT"
fi

# 平台一次性解析定（与 snapshot.sh 同一函数 ⇒ 结果必然一致），供 --platform 透传、
# --strict 的基线校验与 --cache-payload 的 _meta.platform 共用；失败则留给 snapshot.sh 报 rc=3。
if [ -z "$PLATFORM" ]; then
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/_platform_detect.sh"
  PLATFORM=$(detect_platform || true)
fi

SNAP_ARGS=(--json)
[ -n "$PLATFORM" ] && SNAP_ARGS+=(--platform "$PLATFORM")
[ "$SINGLE_DUMP" = true ] && SNAP_ARGS+=(--single-dump)

TMP_ERR=$(mktemp)
TMP_CUR=$(mktemp)
TMP_AERR=$(mktemp)

# 断言失败时附「与上一份快照的差异」到 stderr（仅 rc=1 调用）。
# $1 = 基线文件，$2 = 基线类型（last|prev）。调用前必须把「产生该断言结果的那份 payload」写入 TMP_CUR，
# 否则末轮空树/失败会把 payload 覆盖成空树，diff 就变成误导性的「全删」。
emit_diff() {
  [ "$NO_DIFF" = true ] && return 0
  local base="$1" kind="$2"
  [ -n "$base" ] && [ -f "$base" ] || return 0
  [ -s "$TMP_CUR" ] || return 0
  local dargs=(--baseline "$base" --current "$TMP_CUR" --baseline-kind "$kind" --strict --max-diff 10)
  # 权威平台是 PLATFORM（写 _meta.platform 用的就是它）；RESOLVED 只是方言反推，ios-device 会被推成 ios
  local plat="${PLATFORM:-$RESOLVED}"
  [ -n "$plat" ] && dargs+=(--platform "$plat")
  local out rc=0
  set +e
  out=$(python3 "$DIFF_PY" "${dargs[@]}" 2>/dev/null)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || return 0
  printf '%s\n' "$out" | sed '1s/^# diff /# 与上一份快照的差异 /' >&2 || true
  return 0
}

# 失败日志（--with-logs）；平台用 dialect 映射，maestro 归 ios。
dump_logs() {
  [ -n "$WITH_LOGS" ] || return 0
  # 平台以 PLATFORM 为准（ios-device 要走 --device，不能落到模拟器日志）；全程无成功轮时退回 RESOLVED
  local plat="${PLATFORM:-$RESOLVED}"
  case "$plat" in
    android)    bash "$SCRIPT_DIR/android/logs.sh" "$WITH_LOGS" 2>/dev/null | tail -n 20 || true ;;
    ios)        bash "$SCRIPT_DIR/ios/logs.sh" "$WITH_LOGS" 2>/dev/null | tail -n 20 || true ;;
    ios-device) bash "$SCRIPT_DIR/ios/logs.sh" --device "$WITH_LOGS" 2>/dev/null | tail -n 20 || true ;;
    macos)      bash "$SCRIPT_DIR/macos/logs.sh" "$WITH_LOGS" 2>/dev/null | tail -n 20 || true ;;
    *)          : ;;
  esac
  return 0
}

# 通过后把「通过时那份 payload」落盘（真实脚本，不走 SNAPSHOT_BIN 桩）
cache_payload() {
  local cargs=(--cache-payload "$TMP_CUR")
  [ -n "$PLATFORM" ] && cargs+=(--platform "$PLATFORM")
  [ -s "$TMP_CUR" ] || { echo "⚠️ 缓存落盘跳过（payload 未写入）" >&2; return 0; }
  bash "$REAL_SNAP" "${cargs[@]}" >/dev/null 2>&1 || echo "⚠️ 缓存落盘失败（不影响断言结论）" >&2
  return 0
}

resolve_platform() {
  DIALECT=$(printf '%s' "$JSON_OUT" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("dialect",""))' 2>/dev/null || true)
  case "$DIALECT" in
    uiautomator) RESOLVED=android ;;
    xcuitest)    RESOLVED=ios ;;
    mac2)        RESOLVED=macos ;;
    maestro)     RESOLVED=ios ;;
    *)           RESOLVED="${PLATFORM:-auto}" ;;
  esac
}

snap_exit() {
  # 快照非 0 的既有提示与 rc 映射（rc=2 用法错 / 3 平台 / 4 空树 / 其他=5 快照失败）
  local rc="$1" msg="$2"
  case "$rc" in
    4) echo "⚠️ 语义树为空（页面无文本/可点击节点，非页面空白）— 需 App 侧 Semantics 或改用 shot.sh"; return 4 ;;
    3) echo "❌ 平台不支持或未指定（见下方 snapshot 提示；可加 --platform 重试）"; [ -n "$msg" ] && echo "  ${msg}"; return 3 ;;
    2) echo "❌ 快照用法错（snapshot rc=2）"; [ -n "$msg" ] && echo "  ${msg}"; return 2 ;;
    1) echo "❌ 快照失败（设备/dump/解析，可重试）"; [ -n "$msg" ] && echo "  ${msg}"; return 5 ;;
    *) echo "❌ 快照失败（snapshot rc=${rc}）"; [ -n "$msg" ] && echo "  ${msg}"; return 5 ;;
  esac
}

now_float() { python3 -c 'import time;print("%.1f" % time.time())' 2>/dev/null || echo 0; }
elapsed_float() { python3 -c 'import sys,time;print("%.1f" % (time.time() - float(sys.argv[1])))' "$1" 2>/dev/null || echo 0; }

# ---------- 一次性路径（--wait 0）：与既有行为逐字节等价 ----------
if [ "$WAIT" -eq 0 ]; then
  set +e
  JSON_OUT=$(bash "$SNAP_BIN" "${SNAP_ARGS[@]}" 2>"$TMP_ERR")
  SNAP_RC=$?
  set -e
  SNAP_MSG=$(tail -n 3 "$TMP_ERR" 2>/dev/null | tr '\n' ' ' || true)

  if [ "$SNAP_RC" -ne 0 ]; then
    set +e
    snap_exit "$SNAP_RC" "$SNAP_MSG"
    RC=$?
    set -e
    exit "$RC"
  fi

  resolve_platform

  set +e
  printf '%s' "$JSON_OUT" | python3 "$SCRIPT_DIR/_assert_page.py" --file "$FILE" --platform "$RESOLVED"
  RC=$?
  set -e

  if [ "$RC" -eq 1 ]; then
    # 本次快照已把旧 last 轮转成 prev ⇒ prev 恰是「断言前那一页」
    printf '%s' "$JSON_OUT" > "$TMP_CUR" 2>/dev/null || true
    emit_diff "$LOG_DIR/prev_snapshot.json" prev
  fi
  [ "$RC" -ne 0 ] && dump_logs

  exit "$RC"
fi

# ---------- 轮询路径（--wait N≥1） ----------
POLL_ARGS=("${SNAP_ARGS[@]}" --no-cache)
# 轮询自动用单 dump（Android）：拿到空树只是这一轮重试，而每次省 ~2.5 s
[ "$PLATFORM" = android ] && POLL_ARGS+=(--single-dump)
START_TS=$(date +%s)
START_FLOAT=$(now_float)
ATTEMPTS=0; FAIL_STREAK=0; LAST_ASSERT_OUT=""; LAST_ASSERT_RC=0; LAST_SNAP_RC=0

while :; do
  ATTEMPTS=$((ATTEMPTS + 1))
  set +e
  JSON_OUT=$(bash "$SNAP_BIN" "${POLL_ARGS[@]}" 2>"$TMP_ERR")
  SNAP_RC=$?
  set -e
  LAST_SNAP_RC=$SNAP_RC
  SNAP_MSG=$(tail -n 3 "$TMP_ERR" 2>/dev/null | tr '\n' ' ' || true)

  case "$SNAP_RC" in
    0)
      FAIL_STREAK=0
      resolve_platform
      # 只有成功取到语义树才刷新「产生断言结果的那份 payload」
      printf '%s' "$JSON_OUT" > "$TMP_CUR" 2>/dev/null || true
      set +e
      LAST_ASSERT_OUT=$(printf '%s' "$JSON_OUT" | python3 "$SCRIPT_DIR/_assert_page.py" --file "$FILE" --platform "$RESOLVED" 2>"$TMP_AERR")
      LAST_ASSERT_RC=$?
      set -e
      LAST_ASSERT_ERR=$(cat "$TMP_AERR" 2>/dev/null || true)
      if [ "$LAST_ASSERT_RC" -gt 1 ]; then
        # 断言引擎自身错误（2 用法错 / 5 数据不可解析）：透传，不轮询（否则会被当成「页面没到」）
        [ -n "$LAST_ASSERT_OUT" ] && printf '%s\n' "$LAST_ASSERT_OUT"
        [ -n "$LAST_ASSERT_ERR" ] && printf '%s\n' "$LAST_ASSERT_ERR" >&2
        exit "$LAST_ASSERT_RC"
      fi
      if [ "$LAST_ASSERT_RC" -eq 0 ]; then
        cache_payload
        DUR=$(elapsed_float "$START_FLOAT")
        printf '%s（第 %d 次，%ss）\n' "$(printf '%s\n' "$LAST_ASSERT_OUT" | head -n 1)" "$ATTEMPTS" "$DUR"
        exit 0
      fi
      ;;
    4)
      # 空树：dump 成功只是树空（导航/懒激活期）⇒ 不计失败，且重置连败计数（管道是通的）
      FAIL_STREAK=0
      ;;
    3|2)
      # 平台不可用 / 用法错：重试无意义，立即透传
      set +e
      snap_exit "$SNAP_RC" "$SNAP_MSG"
      RC=$?
      set -e
      exit "$RC"
      ;;
    *)
      FAIL_STREAK=$((FAIL_STREAK + 1))
      if [ "$FAIL_STREAK" -ge 2 ]; then
        echo "❌ 快照连续 2 次失败，放弃轮询（已轮询 ${ATTEMPTS} 次）"
        [ -n "$SNAP_MSG" ] && echo "  ${SNAP_MSG}"
        dump_logs
        exit 5
      fi
      ;;
  esac

  ELAPSED=$(( $(date +%s) - START_TS ))
  [ "$ELAPSED" -ge "$WAIT" ] && break
  REMAIN=$(( WAIT - ELAPSED ))
  SLEEP_FOR=$(awk -v i="$INTERVAL" -v r="$REMAIN" 'BEGIN{v=(i+0<r+0)?i:r; print v}')
  sleep "$SLEEP_FOR"
done

# 超时：有成功断言结果就报它（含 diff）；全程无成功断言则按最后一次 poll 归因
DUR=$(elapsed_float "$START_FLOAT")
if [ -n "$LAST_ASSERT_OUT" ]; then
  printf '%s\n' "$LAST_ASSERT_OUT"
  # 轮询期一律 --no-cache ⇒ last 仍是「轮询开始前那一页」；只有被 tap_snapshot 轮转过才退 prev
  if [ -f "$LOG_DIR/last_snapshot.json" ]; then
    emit_diff "$LOG_DIR/last_snapshot.json" last
  else
    emit_diff "$LOG_DIR/prev_snapshot.json" prev
  fi
  echo "💡 已轮询 ${ATTEMPTS} 次 / ${DUR}s 仍未通过（--wait ${WAIT}）；可用 snapshot.sh --max 40 看当前页全貌"
  dump_logs
  exit 1
fi

set +e
snap_exit "$LAST_SNAP_RC" "$SNAP_MSG"
RC=$?
set -e
echo "💡 已轮询 ${ATTEMPTS} 次 / ${DUR}s：等待期内未取到可断言的语义树"
dump_logs
exit "$RC"
