#!/bin/bash
# tap_snapshot.sh — 用页面快照的 bounds 做坐标点击（一次快照 → 点击；命中缓存时 ~0.2s）
#
# 用法:
#   ./tap_snapshot.sh "<文本>" [--id] [--index N] [--exact] [--dry-run] [--fresh]
#                              [--max-age 60] [--keep-cache] [--json]
#                              [--platform android|ios|ios-device|macos|windows]
#                              [--input <snapshot.json>]
#
# 与既有命令的分工:
#   - maestro/tap.sh   语义定位点击（iOS 模拟器首选；Android 亦可）
#   - tap.sh --text    只能点 clickable=true 的节点（本命令覆盖「非 clickable 文本节点」这一盲区）
#   - findtap.sh       目标不在当前屏时用（自动滚动查找+点击）
#   - 本命令           已有一份快照（≤--max-age）时最快；也支持 --dry-run 只算坐标
#
# 匹配语义: text∪id、字面包含、忽略大小写（= assert_page 的 has）；--exact 精确且大小写敏感。
# 缓存: 复用 $LOG_DIR/last_snapshot.json（snapshot.sh 落盘）；点击成功后默认把 last 轮转为
#       $LOG_DIR/prev_snapshot.json（只作 snapshot.sh --diff 的基线，**绝不**作坐标来源），
#       --keep-cache 保留；--dry-run 不轮转；--max-age 0 等价 --fresh（禁用缓存读取）。
# 输出: 人读 = 命中行 + ⚠️（非 clickable / 疑似离屏）+ 结果；--json = stdout 单行 JSON
#       （text/id/center/bounds/clickable/offscreen/total/index），提示与结果一律走 stderr。
# 测试钩子（正常使用不要设）: SNAPSHOT_BIN（替换取快照命令）、TAP_SNAPSHOT_DISPATCH（替换点击执行）。
#
# 退出码:
#   0 点击完成 / 1 未命中或 --index 越界 / 2 用法错 / 3 平台不支持坐标点击
#   4 语义树为空 / 5 快照或载荷失败 / 6 无可用坐标 / 7 点击派发失败
#   ⚠️ rc=0 仅表示点击指令已送达（adb input tap 无回执），不代表 UI 已响应。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_PY="$SCRIPT_DIR/_tap_target.py"
SNAPSHOT_BIN="${SNAPSHOT_BIN:-$SCRIPT_DIR/snapshot.sh}"
LOG_DIR="${LOG_DIR:-build/debug}"
CACHE="$LOG_DIR/last_snapshot.json"
PREV="$LOG_DIR/prev_snapshot.json"

# 临时文件兜底清理（含异常退出路径；显式 rm 仍保留，幂等）
cleanup_tmp() {
  [ -n "${SNAP_ERR_FILE:-}" ] && rm -f "${SNAP_ERR_FILE:-}"
  [ -n "${MATCH_ERR_FILE:-}" ] && rm -f "${MATCH_ERR_FILE:-}"
  return 0
}
trap cleanup_tmp EXIT

TEXT=""; ID_ONLY=false; INDEX=1; EXACT=false; DRY_RUN=false; FRESH=false
MAX_AGE=60; KEEP_CACHE=false; JSON_OUT=false
PLATFORM=""; INPUT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --id)       ID_ONLY=true; shift ;;
    --exact)    EXACT=true; shift ;;
    --dry-run)  DRY_RUN=true; shift ;;
    --fresh)    FRESH=true; shift ;;
    --keep-cache) KEEP_CACHE=true; shift ;;
    --json)     JSON_OUT=true; shift ;;
    --index)    [ $# -ge 2 ] || { echo "❌ --index 缺参数值"; exit 2; };    INDEX="$2"; shift 2 ;;
    --max-age)  [ $# -ge 2 ] || { echo "❌ --max-age 缺参数值"; exit 2; };  MAX_AGE="$2"; shift 2 ;;
    --platform) [ $# -ge 2 ] || { echo "❌ --platform 缺参数值"; exit 2; }; PLATFORM="$2"; shift 2 ;;
    --input)    [ $# -ge 2 ] || { echo "❌ --input 缺参数值"; exit 2; };    INPUT="$2"; shift 2 ;;
    -*) echo "❌ 未知参数: $1"; exit 2 ;;
    *)  [ -z "$TEXT" ] || { echo "❌ 只能指定一个目标文本（已有: ${TEXT}）"; exit 2; }; TEXT="$1"; shift ;;
  esac
done

[ -n "$TEXT" ] || {
  echo "❌ 用法: ./tap_snapshot.sh \"<文本>\" [--id] [--index N] [--exact] [--dry-run] [--fresh] [--platform P] [--input <json>]"
  exit 2
}
case "$INDEX" in ''|*[!0-9]*) echo "❌ --index 必须为正整数: $INDEX"; exit 2 ;; esac
case "$MAX_AGE" in ''|*[!0-9]*) echo "❌ --max-age 必须为非负整数: $MAX_AGE"; exit 2 ;; esac
[ "$INDEX" -ge 1 ] || { echo "❌ --index 必须 ≥1（1-based）"; exit 2; }

if [ -n "$INPUT" ] && [ "$FRESH" = true ]; then
  echo "❌ --input 与 --fresh 互斥"; exit 2
fi
if [ -n "$INPUT" ] && [ ! -f "$INPUT" ]; then
  echo "❌ 快照文件不存在: $INPUT"; exit 2
fi
if [ -n "$INPUT" ] && [ -z "$PLATFORM" ] && [ "$DRY_RUN" = false ]; then
  # 按 dialect 反推只服务展示/日志路由；点设备必须显式指定，否则可能点到另一台设备
  echo "❌ 使用 --input 时必须同时给 --platform（--dry-run 除外）"; exit 2
fi

# ---------- 目标平台解析：--platform → 缓存 _meta.platform → 自动判定（同 snapshot.sh） ----------
cache_platform() {
  [ -f "$CACHE" ] || return 1
  python3 - "$CACHE" <<'PY' 2>/dev/null
import json, sys
try:
    meta = json.load(open(sys.argv[1], encoding="utf-8")).get("_meta") or {}
except Exception:
    sys.exit(1)
platform = meta.get("platform") or ""
if not platform:
    sys.exit(1)
print(platform)
PY
}

# 平台自动判定与 snapshot.sh 共用同一实现（避免两份逻辑漂移）
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_platform_detect.sh"

if [ -z "$PLATFORM" ] && [ -z "$INPUT" ]; then
  PLATFORM=$(cache_platform || true)
fi
if [ -z "$PLATFORM" ] && [ -z "$INPUT" ]; then
  PLATFORM=$(detect_platform || true)
fi
if [ -z "$PLATFORM" ]; then
  if [ -z "$INPUT" ]; then
    echo "❌ 无法自动判定平台（无 Android 设备 / 无已启动 iOS 模拟器），请用 --platform 指定" >&2
    exit 3
  fi
  # --input + --dry-run 无平台：只算坐标、不派发 ⇒ 无需平台
  [ "$DRY_RUN" = true ] || { echo "❌ 无法判定目标平台：请用 --platform 指定"; exit 2; }
fi

# ---------- 预检：不支持坐标点击的平台，立即拒绝（不读缓存、不取快照） ----------
case "${PLATFORM:-none}" in
  none) ;;  # --dry-run + --input：不派发，跳过平台预检
  ios)
    echo "❌ iOS 模拟器不支持本命令的坐标点击（需先快照再起 Maestro，≈30s 无净收益）" >&2
    echo "💡 改用 bash ${SCRIPT_DIR}/maestro/tap.sh \"<文本>\"（语义定位，≈15s）" >&2
    exit 3 ;;
  ios-device)
    echo "❌ iOS 真机无坐标点击通道；语义点击亦不可用（Maestro 不支持 iOS 真机）" >&2
    echo "💡 改用 python3 ${SCRIPT_DIR}/appium/driver.py find-click（需 --server/--caps）或 scripts/vision/" >&2
    exit 3 ;;
  windows)
    echo "❌ Windows 无结构化快照能力，无法从 bounds 取坐标" >&2
    echo "💡 退回 shot.sh + 截图坐标" >&2
    exit 3 ;;
  android|macos) ;;
  *) echo "❌ 不支持的平台: ${PLATFORM}" >&2; exit 3 ;;
esac

# ---------- 取快照：--input → 缓存（TTL + 平台一致）→ 重新快照 ----------
PAYLOAD=""; AGE=""

if [ -n "$INPUT" ]; then
  PAYLOAD=$(cat "$INPUT")
  [ -n "$PAYLOAD" ] || { echo "❌ 快照文件为空: $INPUT"; exit 2; }
elif [ "$FRESH" = false ] && [ "$MAX_AGE" -gt 0 ] && [ -f "$CACHE" ]; then
  AGE=$(python3 - "$CACHE" "$PLATFORM" "$MAX_AGE" <<'PY' 2>/dev/null || true
import json, sys, time
path, platform, max_age = sys.argv[1], sys.argv[2], int(sys.argv[3])
try:
    payload = json.load(open(path, encoding="utf-8"))
except Exception:
    sys.exit(1)
meta = payload.get("_meta") or {}
if meta.get("platform") != platform:
    sys.exit(1)
age = int(time.time()) - int(meta.get("ts") or 0)
if age < 0 or age > max_age:
    sys.exit(1)
print(age)
PY
)
  if [ -n "$AGE" ]; then
    PAYLOAD=$(cat "$CACHE")
    echo "♻️ 复用快照 (age=${AGE}s)" >&2
  fi
fi

if [ -z "$PAYLOAD" ]; then
  SNAP_ERR_FILE="$(mktemp "${TMPDIR:-/tmp}/tap_snapshot_err.XXXXXX")"
  set +e
  PAYLOAD=$(bash "$SNAPSHOT_BIN" --json --platform "$PLATFORM" 2>"$SNAP_ERR_FILE")
  SNAP_RC=$?
  set -e
  case "$SNAP_RC" in
    0) rm -f "$SNAP_ERR_FILE" ;;
    4) rm -f "$SNAP_ERR_FILE"; echo "⚠️ 语义树为空（页面无文本/可点击节点，非页面空白）— 需 App 侧 Semantics 或改用 shot.sh" >&2; exit 4 ;;
    3) rm -f "$SNAP_ERR_FILE"; echo "❌ 平台不支持结构化快照（退回 shot.sh + Vision）" >&2; exit 3 ;;
    1) echo "❌ 快照失败（设备/dump/解析，可重试）snapshot rc=1" >&2
       tail -n 3 "$SNAP_ERR_FILE" 2>/dev/null | sed 's/^/   /' >&2 || true
       rm -f "$SNAP_ERR_FILE"; exit 5 ;;
    *) echo "❌ 快照失败（snapshot rc=${SNAP_RC}）" >&2
       tail -n 3 "$SNAP_ERR_FILE" 2>/dev/null | sed 's/^/   /' >&2 || true
       rm -f "$SNAP_ERR_FILE"; exit 5 ;;
  esac
  [ -n "$PAYLOAD" ] || { echo "❌ 快照输出为空（snapshot rc=0 但无 payload）" >&2; exit 5; }
fi

# ---------- 匹配与选点 ----------
TARGS=(--text "$TEXT" --index "$INDEX")
[ "$ID_ONLY" = true ] && TARGS+=(--id)
[ "$EXACT" = true ] && TARGS+=(--exact)

if [ "$JSON_OUT" = true ]; then
  # stderr 单独收：stdout 必须只有一行可解析 JSON（⚠️ 提示与诊断一律转 stderr）
  MATCH_ERR_FILE="$(mktemp "${TMPDIR:-/tmp}/tap_target_err.XXXXXX")"
  set +e
  MATCH_OUT=$(printf '%s' "$PAYLOAD" | python3 "$TARGET_PY" "${TARGS[@]}" --json 2>"$MATCH_ERR_FILE")
  MATCH_RC=$?
  set -e
  if [ -s "$MATCH_ERR_FILE" ]; then cat "$MATCH_ERR_FILE" >&2; fi
  rm -f "$MATCH_ERR_FILE"
  if [ "$MATCH_RC" -ne 0 ]; then
    case "$MATCH_RC" in
      5) exit 5 ;;
      6) exit 6 ;;
      *) exit 1 ;;
    esac
  fi
  set +e
  XY=$(printf '%s' "$MATCH_OUT" | python3 -c 'import json,sys; c=json.load(sys.stdin)["center"]; print("%d %d" % (c[0], c[1]))' 2>/dev/null)
  XY_RC=$?
  set -e
  [ "$XY_RC" -eq 0 ] || XY=""
else
  set +e
  MATCH_OUT=$(printf '%s' "$PAYLOAD" | python3 "$TARGET_PY" "${TARGS[@]}" 2>&1)
  MATCH_RC=$?
  set -e
  if [ "$MATCH_RC" -ne 0 ]; then
    printf '%s\n' "$MATCH_OUT"
    case "$MATCH_RC" in
      5) exit 5 ;;
      6) exit 6 ;;
      *) exit 1 ;;
    esac
  fi
  XY=$(printf '%s\n' "$MATCH_OUT" | sed -n 's/.*center=(\(-\{0,1\}[0-9]*\),\(-\{0,1\}[0-9]*\)).*/\1 \2/p' | head -1)
fi

if [ -z "$XY" ]; then
  echo "❌ 无法从匹配结果解析坐标" >&2; exit 6
fi
X="${XY%% *}"
Y="${XY##* }"

# 目标信息：JSON 模式是单行机器载荷（后续提示走 stderr）；人读模式全部走 stdout
printf '%s\n' "$MATCH_OUT"

if [ "$DRY_RUN" = true ]; then
  if [ "$JSON_OUT" = true ]; then
    echo "（--dry-run：未点击，目标坐标 (${X},${Y})）" >&2
  else
    echo "（--dry-run：未点击，目标坐标 (${X},${Y})）"
  fi
  exit 0
fi

# ---------- 点击派发 ----------
dispatch() {
  if [ -n "${TAP_SNAPSHOT_DISPATCH:-}" ]; then
    # 测试钩子：只替换「命令执行」这一层；平台不支持已在预检阶段拦掉
    "$TAP_SNAPSHOT_DISPATCH" "$1" "$2"
    return $?
  fi
  case "$PLATFORM" in
    android)
      # 子 shell：_common.sh / require_device 的 exit 1 只让派发失败，不污染 1=未命中 的语义
      (
        # shellcheck source=/dev/null
        source "$SCRIPT_DIR/android/_common.sh"
        device=$(require_device)
        adb -s "$device" shell input tap "$1" "$2"
      )
      ;;
    macos)
      bash "$SCRIPT_DIR/macos/click.sh" "$1" "$2"
      ;;
    *)
      # 预检已拦掉不支持平台；这里兜底防「未来放宽平台后空转返回 0」⇒ 谎报点击成功
      echo "❌ 无该平台的点击派发实现: ${PLATFORM}" >&2
      return 1
      ;;
  esac
}

set +e
dispatch "$X" "$Y"
DISPATCH_RC=$?
set -e

if [ "$DISPATCH_RC" -ne 0 ]; then
  echo "❌ 点击派发失败（adb/click.sh rc=${DISPATCH_RC}，缓存已保留）" >&2
  exit 7
fi

# 点击后页面可能已变：默认把当前快照轮转为 diff 基线（prev），last 失效以免下一次点错位置。
# ⚠️ 读缓存只读 last，绝不读 prev（prev 是点击前的坐标，可能已失效）。
if [ "$KEEP_CACHE" = false ] && [ -f "$CACHE" ]; then
  mv -f "$CACHE" "$PREV" 2>/dev/null || true
fi

if [ "$JSON_OUT" = true ]; then
  echo "✅ 点击完成: (${X},${Y})（rc=0 仅表示指令已送达）" >&2
else
  echo "✅ 点击完成: (${X},${Y})（rc=0 仅表示点击指令已送达，不代表 UI 已响应）"
fi
exit 0
