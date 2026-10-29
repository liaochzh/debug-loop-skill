#!/bin/bash
# snapshot.sh — 页面结构化快照（跨平台）+ 页面变化判定（--diff）
#
# 用法:
#   ./snapshot.sh [--platform android|ios|ios-device|macos] [--max 40] [--json] [--center]
#                 [--wait-stable] [--no-cache]
#   ./snapshot.sh --diff [--against <snapshot.json>] [--max-diff 20] [--platform P] [--no-cache]
#
# 输出:
#   默认 人读摘要（≤--max 行，text 截断 40 字符）；--center 追加第 7 列 cx,cy
#   --json 断言/点击专用全量数据（供 assert_page.sh / tap_snapshot.sh 使用）
#   --diff 变化清单（TAB 分隔，取代摘要输出，≤--max-diff 行 + header 计数）
#
# 缓存:
#   任一**观测成功**（rc=0，含摘要/--diff 模式）写 $LOG_DIR/last_snapshot.json（含 _meta.platform/ts），
#   供 tap_snapshot.sh 在 TTL 内复用、供 --diff 当基线。写前把旧 last 轮转为 prev_snapshot.json。
#   last = 当前页快照（坐标可信）；prev = 最近一次页面变化之前的快照（**只作 diff 基线，不作坐标来源**）。
#   --no-cache 关闭写入（仍可读基线）；观测失败（rc≠0）不写不清。
#
# 测试钩子（正常使用不要设）: SNAPSHOT_INPUT=<xml|csv> 跳过设备 dump、直接用该文件走完整解析路径。
#
# 退出码:
#   0 成功（--diff 时无论有无变化；变化数看 header）/ 1 观测失败 或 无可用基线（可重试）
#   2 用法错 / 3 平台不支持 / 4 语义树为空
#   ⚠️ exit 4 判据由解析器钉死为「raw_nodes > 0 且过滤后 nodes == 0」；观测失败一律 exit 1。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSE="$SCRIPT_DIR/_snapshot_parse.py"
DIFF_PY="$SCRIPT_DIR/_snapshot_diff.py"
LOG_DIR="${LOG_DIR:-build/debug}"

PLATFORM=""; MAX=40; JSON=false; CENTER=false; WAIT_STABLE=false; NO_CACHE=false
DIFF=false; AGAINST=""; MAX_DIFF=20; MAX_DIFF_SET=false
while [ $# -gt 0 ]; do
  case "$1" in
    --platform) [ $# -ge 2 ] || { echo "❌ --platform 缺参数值"; exit 2; }; PLATFORM="$2"; shift 2 ;;
    --max)      [ $# -ge 2 ] || { echo "❌ --max 缺参数值"; exit 2; };      MAX="$2"; shift 2 ;;
    --json)     JSON=true; shift ;;
    --center)   CENTER=true; shift ;;
    --wait-stable) WAIT_STABLE=true; shift ;;
    --no-cache) NO_CACHE=true; shift ;;
    --diff)     DIFF=true; shift ;;
    --against)  [ $# -ge 2 ] || { echo "❌ --against 缺参数值"; exit 2; }; AGAINST="$2"; shift 2 ;;
    --max-diff) [ $# -ge 2 ] || { echo "❌ --max-diff 缺参数值"; exit 2; }; MAX_DIFF="$2"; MAX_DIFF_SET=true; shift 2 ;;
    -*) echo "❌ 未知参数: $1"; exit 2 ;;
    *)  echo "❌ 未知参数: $1"; exit 2 ;;
  esac
done

case "$MAX" in
  ''|*[!0-9]*) echo "❌ --max 必须为正整数: $MAX"; exit 2 ;;
esac
case "$MAX_DIFF" in
  ''|*[!0-9]*) echo "❌ --max-diff 必须为正整数: $MAX_DIFF"; exit 2 ;;
esac
[ "$MAX_DIFF" -ge 1 ] || { echo "❌ --max-diff 必须 ≥1: $MAX_DIFF"; exit 2; }
if [ "$DIFF" = true ] && [ "$JSON" = true ]; then
  echo "❌ --diff 与 --json 互斥（两者都是给调用方消费的主输出）"; exit 2
fi
if [ "$DIFF" = false ] && [ -n "$AGAINST" ]; then
  echo "❌ --against 需配合 --diff 使用"; exit 2
fi
if [ "$DIFF" = false ] && [ "$MAX_DIFF_SET" = true ]; then
  echo "❌ --max-diff 需配合 --diff 使用"; exit 2
fi

if [ -z "$PLATFORM" ]; then
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/_platform_detect.sh"
  PLATFORM=$(detect_platform || true)
  if [ -z "$PLATFORM" ]; then
    echo "❌ 无法自动判定平台（无 Android 设备 / 无已启动 iOS 模拟器），请用 --platform 指定" >&2
    exit 3
  fi
fi

OUT=""
RC=0
LOCAL_XML=""

# 解析当前 XML；rc 透传（4=语义树为空，1=解析失败）
parse_now() {
  set +e
  OUT=$(python3 "$PARSE" --input "$LOCAL_XML" --json 2>/dev/null)
  RC=$?
  set -e
}

# 本次 payload 的方言（--diff 的基线校验要用；解析失败则为空，由 diff 侧退化为只比 platform）
payload_dialect() {
  printf '%s' "$OUT" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("dialect",""))' 2>/dev/null || true
}

# --diff：选基线 → 算变化。只输出 diff（取代摘要）；rc 由本函数返回（0/1/2）
run_diff() {
  local tmp_cur="${LOG_DIR}/.snapshot_current.$$.json"
  local pick_out="${LOG_DIR}/.snapshot_pick.$$.txt"
  local err="${LOG_DIR}/.snapshot_err.$$.txt"
  local dialect pick_rc diff_rc
  local base_path="" base_kind="last" base_age="-" base_stale="0"
  dialect=$(payload_dialect)

  if ! printf '%s' "$OUT" > "$tmp_cur" 2>/dev/null; then
    echo "❌ 无法写临时快照: $tmp_cur" >&2
    return 1
  fi

  local pargs=(--pick-baseline --log-dir "$LOG_DIR" --platform "$PLATFORM" --dialect "$dialect")
  [ -n "$AGAINST" ] && pargs+=(--against "$AGAINST")
  set +e
  python3 "$DIFF_PY" "${pargs[@]}" > "$pick_out" 2> "$err"
  pick_rc=$?
  set -e
  [ -s "$err" ] && cat "$err" >&2
  rm -f "$err"
  if [ "$pick_rc" -ne 0 ]; then
    rm -f "$tmp_cur" "$pick_out"
    return "$pick_rc"
  fi
  IFS=$'\t' read -r base_path base_kind base_age base_stale < "$pick_out" || true
  rm -f "$pick_out"
  if [ "$base_stale" = "1" ]; then
    echo "💡 基线较旧（age=${base_age}s），如需精确对比用 --against <file>" >&2
  fi

  set +e
  python3 "$DIFF_PY" --baseline "$base_path" --current "$tmp_cur" --max-diff "$MAX_DIFF" \
    --baseline-kind "$base_kind" --baseline-age "$base_age" 2> "$err"
  diff_rc=$?
  set -e
  [ -s "$err" ] && cat "$err" >&2
  rm -f "$err" "$tmp_cur"
  return "$diff_rc"
}

emit() {
  local final_rc="$RC"
  if [ "$DIFF" = true ]; then
    run_diff || final_rc=$?
  elif [ "$JSON" = true ]; then
    [ -n "$OUT" ] && printf '%s\n' "$OUT"
  else
    local sargs=(--max "$MAX")
    [ "$CENTER" = true ] && sargs+=(--center)
    python3 "$PARSE" --input "$LOCAL_XML" "${sargs[@]}" || RC=$?
    final_rc="$RC"
  fi
  # 缓存落盘点（唯一）：**观测** rc=0 即写 —— diff 是元步骤，失败不折损观测
  # （否则冷启第一次 --diff 会白烧 1–2 次 dump 才能自愈）。--no-cache 不写；观测失败不写不清。
  if [ "$RC" -eq 0 ] && [ "$NO_CACHE" = false ] && [ -n "$OUT" ]; then
    write_cache
  fi
  if [ "$DIFF" = true ] && [ "$final_rc" -eq 1 ] && [ -z "$AGAINST" ] \
     && [ "$RC" -eq 0 ] && [ "$NO_CACHE" = false ]; then
    echo "💡 基线已建立（本次快照已落盘），再跑一次 --diff 即可看变化" >&2
  fi
  exit "$final_rc"
}

# 把本次 payload 加 _meta 后原子写入 $LOG_DIR/last_snapshot.json；写前把旧 last 轮转为 prev
# （失败静默：缓存是加速项，不是功能项；无旧 last 时不得因 mv 失败被 set -e 杀掉）
write_cache() {
  local cache="${LOG_DIR}/last_snapshot.json"
  local prev="${LOG_DIR}/prev_snapshot.json"
  local tmp="${cache}.tmp.$$"
  if printf '%s' "$OUT" | python3 -c '
import json, sys, time
payload = json.load(sys.stdin)
payload["_meta"] = {"platform": sys.argv[1], "ts": int(time.time())}
json.dump(payload, open(sys.argv[2], "w", encoding="utf-8"), ensure_ascii=False)
' "$PLATFORM" "$tmp" 2>/dev/null; then
    local rotated=false
    if [ -f "$cache" ]; then mv -f "$cache" "$prev" 2>/dev/null && rotated=true || true; fi
    if ! mv -f "$tmp" "$cache" 2>/dev/null; then
      rm -f "$tmp"
      # 回滚：仅回滚「本轮刚轮转走的那份」，不得把历史遗留的 prev 提升为 last（陈旧坐标）
      if [ "$rotated" = true ] && [ -f "$prev" ]; then mv -f "$prev" "$cache" 2>/dev/null || true; fi
    fi
  else
    rm -f "$tmp"
  fi
}

if [ "$WAIT_STABLE" = true ] && [ "$PLATFORM" != android ]; then
  echo "⚠️ --wait-stable 仅 Android 生效，当前平台忽略（iOS/macOS 快照本身为单次全量导出）" >&2
fi

# 平台预检（SNAPSHOT_INPUT 测试钩子同样遵守：平台契约不因钩子放宽）
case "$PLATFORM" in
  android|ios|ios-device|macos) ;;
  windows)
    echo "❌ windows 无结构化快照能力，请退回 shot.sh + Vision" >&2
    exit 3 ;;
  *)
    echo "❌ 不支持的平台: $PLATFORM" >&2
    exit 3 ;;
esac

if [ -n "${SNAPSHOT_INPUT:-}" ]; then
  # 测试钩子：跳过设备 dump，其余（解析、写缓存、diff）完全走真实路径
  if [ ! -f "$SNAPSHOT_INPUT" ]; then
    echo "❌ SNAPSHOT_INPUT 指向的文件不存在: $SNAPSHOT_INPUT" >&2
    exit 2
  fi
  LOCAL_XML="$SNAPSHOT_INPUT"
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  echo "🧪 SNAPSHOT_INPUT 已生效（跳过设备 dump）: $SNAPSHOT_INPUT" >&2
else
case "$PLATFORM" in
  android)
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/android/_common.sh"
    DEVICE=$(require_device)
    LOCAL_XML="$LOG_DIR/snapshot_ui.xml"

    dump_once() {
      rm -f "$LOCAL_XML"
      adb -s "$DEVICE" shell rm -f /sdcard/ui_snapshot.xml >/dev/null 2>&1 || true
      perl -e 'alarm 10; exec @ARGV' adb -s "$DEVICE" shell uiautomator dump /sdcard/ui_snapshot.xml >/dev/null 2>&1 || return 1
      adb -s "$DEVICE" pull /sdcard/ui_snapshot.xml "$LOCAL_XML" >/dev/null 2>&1 || return 1
      [ -s "$LOCAL_XML" ]
    }

    dump_with_retry() {
      local attempt=0
      until dump_once; do
        attempt=$((attempt + 1))
        if [ "$attempt" -ge 3 ]; then
          echo "❌ uiautomator dump 连续 3 次失败（动画中或界面不可用，可重试）" >&2
          return 1
        fi
        sleep 0.5
      done
    }

    if [ "$WAIT_STABLE" = true ]; then
      prev=""; n=0
      while [ "$n" -lt 5 ]; do
        dump_with_retry || exit 1
        parse_now
        cur=$(printf '%s' "$OUT" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("fingerprint",""))' 2>/dev/null || true)
        if [ -n "$prev" ] && [ "$cur" = "$prev" ]; then break; fi
        prev="$cur"
        n=$((n + 1))
        [ "$n" -lt 5 ] && sleep 0.6
      done
    else
      # 默认双 dump：Flutter 语义树由无障碍客户端触发后懒构建，首次常空
      dump_with_retry || exit 1
      sleep 0.6
      dump_with_retry || exit 1
    fi
    ;;

  ios)
    # 实测（2026-10-28，see_pro / iPhone 17e）：Flutter 在 iOS 模拟器上 Appium pageSource 恒为空树
    # （全是 XCUIElementTypeOther，accessible=false），而 Maestro hierarchy 能读到 accessibilityText。
    # ⇒ iOS 模拟器快照走 Maestro，不再走 Appium。
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/appium/_common.sh"
    UDID=$(resolve_ios_sim)
    [ -n "$UDID" ] || { echo "❌ 未检测到已启动的 iOS 模拟器（xcrun simctl list devices booted）" >&2; exit 1; }
    LOCAL_XML="$LOG_DIR/maestro_hierarchy.csv"
    if ! maestro --device "$UDID" hierarchy --compact > "$LOCAL_XML" 2>/dev/null; then
      echo "❌ maestro hierarchy 失败（驱动/冷启动问题，可重试）" >&2
      exit 1
    fi
    [ -s "$LOCAL_XML" ] || { echo "❌ maestro hierarchy 输出为空" >&2; exit 1; }
    ;;

  ios-device|macos)
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/appium/_common.sh"
    LOCAL_XML="$LOG_DIR/page_source.xml"
    rm -f "$LOCAL_XML"
    if ! bash "$SCRIPT_DIR/appium/source.sh" --platform "$PLATFORM" --out "$LOCAL_XML" >/dev/null 2>&1; then
      echo "❌ page source 导出失败（Appium 会话/驱动问题，可重试）" >&2
      exit 1
    fi
    ;;
esac
fi

parse_now
emit
