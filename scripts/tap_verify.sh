#!/bin/bash
# tap_verify.sh — 点击 + 回执校验（跨平台）：点完必须拿到「页面确实变了/到了目标页」的证据
#
# 为什么需要本脚本（2026-11-12 立项）：`android/tap.sh` / `tap_snapshot.sh` / `findtap.sh`
#   全部只投递不回执（rc=0 = 指令已送达），「点没点中」无人判定 ⇒ 页面没变也继续往下走，
#   最后把「点不中」误报成功能 Bug。本脚本把「定位 → 点击 → 断言/变化判定 → 必要时重试一次」
#   收敛成一次调用。
#
# 用法:
#   ./tap_verify.sh 登录 --expect has:首页
#   ./tap_verify.sh 提交 --expect none --wait 8          # 无稳定文案时：判页面是否变化
#   ./tap_verify.sh 账号输入框 --id --dry-run
#
# 选项:
#   --expect has:<文本>   可多次；用 assert_page --wait 轮询（默认判据）
#   --expect none         改判「点击前后页面是否变化」（目标节点消失 / 节点数 / 文本集变化）
#   --wait N              轮询秒数（默认 10）
#   --retry N             未生效且页面没变化时的重点次数（默认 1）
#   --index N             多处命中取第 N 个（1-based）
#   --id                  只在 id 字段匹配
#   --exact               精确匹配且大小写敏感
#   --allow-danger        允许对「删除/解绑/支付…」类目标做第二次点击（默认禁止，防双击副作用）
#   --allow-weak          允许把「仅文本集变化」（弱证据）当通过（默认按未通过算）
#   --platform P          android（默认自动判定）| ios-device
#   --dry-run             只定位，不点击
#   --json                定位后额外打印一行以 `{` 开头的定位 JSON（机器可 grep）
#
# 退出码:
#   0 点击且校验通过 / 1 点击后未达预期或**无法判定**（附 diff 与降级建议）/ 2 用法错
#   3 平台/环境不支持（ios 模拟器、macos、windows：改用 maestro / smart_tap） / 4 语义树为空
#   5 快照失败 / 7 点击派发失败
#
# 重试纪律（防「二次触发」）:
#   第一次点击后若页面**已经变化**（目标节点消失 / 节点数变化）或**无法判定**（快照失败/不可解析），
#   即使 `--expect` 没通过也**不再点第二次**（事务可能已提交），直接 rc=1 + diff；
#   仅「文本集变化」是弱证据（自动刷新页会自行漂移），默认按未通过算（`--allow-weak` 才放行）；
#   危险词目标默认同样不重试。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAP="$SCRIPT_DIR/snapshot.sh"
ASSERT="$SCRIPT_DIR/assert_page.sh"
TAP_TARGET="$SCRIPT_DIR/_tap_target.py"
DIFF_PY="$SCRIPT_DIR/_snapshot_diff.py"
LOG_DIR="${LOG_DIR:-build/debug}"
INTERACT_DIR="$LOG_DIR/interact"

NEEDLE=""; ID_ONLY=false; EXACT=false; INDEX=1
EXPECTS=(); EXPECT_NONE=false
WAIT=10; RETRY=1; ALLOW_DANGER=false; ALLOW_WEAK=false; PLATFORM=""; DRY_RUN=false; AS_JSON=false

usage() {
  awk 'NR < 3 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --expect)
      [ $# -ge 2 ] || { echo "❌ --expect 缺参数值"; exit 2; }
      case "$2" in
        none) EXPECT_NONE=true ;;
        has:*) EXPECTS+=("${2#has:}") ;;
        *) echo "❌ --expect 只支持 has:<文本> 或 none: $2"; exit 2 ;;
      esac
      shift 2 ;;
    --wait)     [ $# -ge 2 ] || { echo "❌ --wait 缺参数值"; exit 2; }; WAIT="$2"; shift 2 ;;
    --retry)    [ $# -ge 2 ] || { echo "❌ --retry 缺参数值"; exit 2; }; RETRY="$2"; shift 2 ;;
    --index)    [ $# -ge 2 ] || { echo "❌ --index 缺参数值"; exit 2; }; INDEX="$2"; shift 2 ;;
    --id)       ID_ONLY=true; shift ;;
    --exact)    EXACT=true; shift ;;
    --allow-danger) ALLOW_DANGER=true; shift ;;
    --allow-weak)   ALLOW_WEAK=true; shift ;;
    --platform) [ $# -ge 2 ] || { echo "❌ --platform 缺参数值"; exit 2; }; PLATFORM="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=true; shift ;;
    --json)     AS_JSON=true; shift ;;
    -h|--help)  usage; exit 0 ;;
    -*) echo "❌ 未知参数: $1"; exit 2 ;;
    *)  [ -z "$NEEDLE" ] || { echo "❌ 只能给一个目标关键词: $1"; exit 2; }; NEEDLE="$1"; shift ;;
  esac
done

[ -n "$NEEDLE" ] || { echo "❌ 用法: ./tap_verify.sh <关键词> [--expect has:<文本>|none]"; exit 2; }
case "$WAIT" in ''|*[!0-9]*) echo "❌ --wait 需为非负整数（秒）: $WAIT"; exit 2 ;; esac
case "$RETRY" in ''|*[!0-9]*) echo "❌ --retry 需为非负整数: $RETRY"; exit 2 ;; esac
case "$INDEX" in ''|*[!0-9]*) echo "❌ --index 需为正整数: $INDEX"; exit 2 ;; esac
[ "$INDEX" -ge 1 ] || { echo "❌ --index 必须 ≥1"; exit 2; }
if [ "${#EXPECTS[@]}" -gt 0 ] && [ "$EXPECT_NONE" = true ]; then
  echo "❌ --expect none 不能与 --expect has:… 同用"; exit 2
fi

# ⚠️ 启发式表：只用于「页面无变化时是否允许再点一次」，**不是唯一防线**（漏判方向才是风险，
#    误判方向只是少点一次）。确认类弹窗的「确定/确认」也算危险（删除确认最常点它）。
DANGER_WORDS=" 删除 移除 解绑 注销 退出 支付 付款 提交 下单 购买 卸载 清空 重置 确认 确定 发送 绑定 开通 转账 退款 挂失 delete remove logout unbind pay submit confirm send"

is_danger() {
  local t lower w
  t=" $(printf '%s' "$1" | tr '\n' ' ') "
  lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  for w in $DANGER_WORDS; do
    case "$t" in *"$w"*) return 0 ;; esac
    case " $lower " in *"$w"*) return 0 ;; esac
  done
  return 1
}

# ---------- 平台 ----------
if [ -z "$PLATFORM" ]; then
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/_platform_detect.sh"
  PLATFORM=$(detect_platform || true)
fi
case "$PLATFORM" in
  android) : ;;
  ios-device)
    echo "🍎 ios-device：改用 appium 语义路径（坐标点击在真机上无回执，语义点击可断言）" >&2
    TAP_ARGS=("$NEEDLE" --platform ios-device)
    [ "$ID_ONLY" = true ] && TAP_ARGS+=(--using "id")
    if [ "$DRY_RUN" = true ]; then
      echo "🧪 --dry-run：只做断言前检查（不点击）"
      exit 0
    fi
    [ "$INDEX" -eq 1 ] || echo "⚠️ ios-device 路径不支持 --index（按 selector 唯一命中），已忽略" >&2
    [ "$EXPECT_NONE" = true ] && echo "⚠️ ios-device 路径需 --expect has:…；--expect none 无语义变化判定，已忽略" >&2
    TAP_RC=0
    set +e
    bash "$SCRIPT_DIR/appium/tap.sh" ${TAP_ARGS[@]+"${TAP_ARGS[@]}"}
    TAP_RC=$?
    set -e
    case "$TAP_RC" in
      0) : ;;
      1) echo "❌ 未找到目标元素（appium/tap.sh rc=1）" >&2; exit 1 ;;
      *) echo "❌ appium 点击失败（rc=${TAP_RC}）" >&2; exit 7 ;;
    esac
    if [ "${#EXPECTS[@]}" -gt 0 ]; then
      for e in "${EXPECTS[@]}"; do
        bash "$SCRIPT_DIR/appium/assert.sh" "$e" --platform ios-device || { echo "❌ 点击后断言失败: $e" >&2; exit 1; }
      done
    else
      echo "⚠️ ios-device 无 --expect has:… ⇒ 未做变化判定（建议补断言）" >&2
    fi
    log_json tap_verify "needle=$NEEDLE" "attempts=1" "ok=true" "platform=ios-device" || true
    echo "✅ 点击并校验通过（ios-device）"
    exit 0 ;;
  ios|macos|windows)
    echo "❌ 平台 ${PLATFORM} 不支持 tap_verify（坐标无回执）" >&2
    case "$PLATFORM" in
      ios)   echo "💡 iOS 模拟器：bash $SCRIPT_DIR/maestro/tap.sh \"<文本>\" + maestro/assert.sh" >&2 ;;
      macos) echo "💡 macOS：bash $SCRIPT_DIR/macos/smart_tap.sh \"<关键词>\"（自带 Vision 校验）" >&2 ;;
      *)     echo "💡 Windows：shot.sh + Vision，无结构化回执" >&2 ;;
    esac
    exit 3 ;;
  "") echo "❌ 无法判定平台（无 Android 设备 / 未启动 iOS 模拟器），请用 --platform 指定" >&2; exit 3 ;;
  *) echo "❌ 不支持的平台: $PLATFORM" >&2; exit 3 ;;
esac

# ---------- 环境（android） ----------
DEVICE=""
DEV_OUT=$(mktemp); DEV_ERR=$(mktemp)
set +e
( source "$SCRIPT_DIR/android/_common.sh"; require_device > "$DEV_OUT" ) 2> "$DEV_ERR"
ENV_RC=$?
set -e
if [ "$ENV_RC" -ne 0 ]; then
  echo "❌ 环境不可用（rc=${ENV_RC}）" >&2
  [ -s "$DEV_ERR" ] && cat "$DEV_ERR" >&2
  rm -f "$DEV_OUT" "$DEV_ERR"
  exit 3
fi
DEVICE=$(head -1 "$DEV_OUT")
rm -f "$DEV_OUT" "$DEV_ERR"
mkdir -p "$LOG_DIR" "$INTERACT_DIR"

# ---------- 快照/定位/变化判定 ----------
# 快照含页面明文（账号/搜索词）⇒ 落临时文件、退出即删，不写进 build/debug 留档。
SNAP_OLD="$(mktemp "${TMPDIR:-/tmp}/tv_old.XXXXXX")"
SNAP_NEW="$(mktemp "${TMPDIR:-/tmp}/tv_new.XXXXXX")"
cleanup_tv() { rm -f "$SNAP_OLD" "$SNAP_NEW"; }
trap cleanup_tv EXIT

snap_take() {  # <out> → 透传 snapshot.sh rc
  local out="$1" rc=0
  set +e
  bash "$SNAP" --platform android --json > "$out" 2>"$LOG_DIR/.tv_snap.err"
  rc=$?
  set -e
  return "$rc"
}

locate() {  # <snapshot> → stdout JSON（_tap_target 语义）；rc 透传
  local snap="$1" rc=0
  local args=(--text "$NEEDLE" --index "$INDEX" --json)
  [ "$ID_ONLY" = true ] && args+=(--id)
  [ "$EXACT" = true ] && args+=(--exact)
  set +e
  python3 "$TAP_TARGET" ${args[@]+"${args[@]}"} < "$snap"
  rc=$?
  set -e
  return "$rc"
}

# 页面变化判定：目标节点是否消失 / 节点数变化 / 文本集变化（三者分列，供主流程辨强弱）
#   为什么分列：文本集变化在自动刷新页（倒计时/相对时间/轮播）会自行发生 ⇒ 只能当**弱证据**，
#   单独变化不得判「点击生效」（2026-11-12 复审 P1#10）。
page_delta() {  # <old.json> <new.json> → changed target_gone nodes_changed text_changed old_nodes new_nodes unreadable
  python3 - "$1" "$2" "$NEEDLE" "$ID_ONLY" <<'PY'
import json, sys

old_p, new_p, needle, id_only = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "true"
needle_l = needle.lower()


def load(path):
    try:
        d = json.load(open(path, encoding="utf-8"))
    except Exception:
        return None
    # 顶层不是对象（数组/字符串/数字）同样按「不可解析」处理：否则下面的 .get 会抛异常，
    # 让 page_delta 非零退出、DELTA 为空 ⇒ 主循环可能误判成「没变化」并二次点击。
    return d if isinstance(d, dict) else None


def values(node):
    if id_only:
        return [node.get("id") or ""]
    out = [node.get("text") or ""]
    if node.get("id"):
        out.append(node.get("id"))
    return [v for v in out if v]


def hit(nodes):
    for n in nodes:
        if not isinstance(n, dict):
            continue
        if any(needle_l in v.lower() for v in values(n)):
            return True
    return False


def sig(nodes):
    bag = []
    for n in nodes:
        if not isinstance(n, dict):
            continue
        bag.append(((n.get("text") or "").strip(), (n.get("id") or "").strip()))
    return bag


o, n = load(old_p), load(new_p)
if not o or not n:
    print("changed=0 target_gone=0 nodes_changed=0 text_changed=0 old_nodes=0 new_nodes=0 unreadable=1")
    sys.exit(0)
on = [x for x in (o.get("nodes") or []) if isinstance(x, dict)]
nn = [x for x in (n.get("nodes") or []) if isinstance(x, dict)]
gone = 1 if (hit(on) and not hit(nn)) else 0
nodes_changed = 1 if len(on) != len(nn) else 0
text_changed = 1 if sorted(sig(on)) != sorted(sig(nn)) else 0
changed = 1 if (gone or nodes_changed or text_changed) else 0
print("changed=%d target_gone=%d nodes_changed=%d text_changed=%d old_nodes=%d new_nodes=%d unreadable=0"
      % (changed, gone, nodes_changed, text_changed, len(on), len(nn)))
PY
}

# page_delta 输出是**单行多对** `changed=1 target_gone=0 …`，按空白切词后逐词比对。
# ⚠️ 不能用于按行输出、且值可能含空格的 KV（如定位结果的 `text=我的 设备`）——
#    那样会把值截成第一个词（2026-11-12 复审 P2）；那类场景用 kv_line。
kv_of() {
  printf '%s\n' "$1" | awk -v k="$2=" '{
    n = split($0, parts, /[ \t]+/)
    for (i = 1; i <= n; i++) if (index(parts[i], k) == 1) { print substr(parts[i], length(k) + 1); exit }
  }'
}

# 按行锚定的 KV（每行一对，值允许含空格）：只认行首 key=，取到行尾。
kv_line() {
  printf '%s\n' "$1" | awk -v k="$2=" 'index($0, k) == 1 { print substr($0, length(k) + 1); exit }'
}

# 现场 JSON：用 python 构造（不手拼 JSON，避免 needle/text 含引号时产出非法 JSON）
#   用法：log_json <action> key=value …（action 单独一个位置参数，不再被当成 KV 字段）
log_json() {  # <action> key=value …
  python3 - "$INTERACT_DIR" "$@" <<'PY'
import json, os, sys, time

out_dir = sys.argv[1]
action = sys.argv[2]
data = {"action": action}
for kv in sys.argv[3:]:
    key, _, val = kv.partition("=")
    if val in ("true", "false"):
        data[key] = val == "true"
    else:
        try:
            data[key] = int(val)
        except ValueError:
            data[key] = val
ms = int(time.time() * 1000)
data["ts"] = ms // 1000
os.makedirs(out_dir, exist_ok=True)
# 毫秒 + pid：同一秒内多次调用不会互相覆盖（原先只按秒命名，重试时会覆盖首次现场）
path = os.path.join(out_dir, "%d-%d-tap.json" % (ms, os.getpid()))
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, ensure_ascii=False, indent=1)
print("📝 " + path)
PY
}

show_diff() {  # 点击前 vs 点击后（显式基线，避免 assert 轮询把 last/prev 顶掉）
  local base="$SNAP_OLD" cur="$SNAP_NEW"
  [ -f "$cur" ] || cur="$LOG_DIR/last_snapshot.json"
  [ -f "$base" ] && [ -f "$cur" ] || return 0
  python3 "$DIFF_PY" --baseline "$base" --current "$cur" --baseline-kind prev --max-diff 10 2>/dev/null \
    | sed '1s/^# diff /# 点击前后变化 /' >&2 || true
}

degrade_hint() {
  echo "💡 降级顺序：android/findtap.sh（滚动查找）→ maestro/tap.sh（语义点击）→ shot.sh + Vision 定位" >&2
  echo "💡 若目标在弹层/键盘下方：先 settle.sh + snapshot.sh 确认节点 bounds 与屏幕关系" >&2
}

# verify_once → 0 通过 / 1 未通过（真的没变化）/ 2 无法判定（快照失败或不可解析）/ 3 仅弱证据
#   2 单独一路是关键：**「不知道有没有生效」不能等同于「没生效」**，否则会在页面已跳走时再点一次
#   （登录/提交/删除被重复触发 —— 2026-11-12 复审 P0#1）。
#   3 表示「页面确实变了，但只有文本集变化」——自动刷新页（倒计时/轮播）会自行漂移，
#     属于弱证据，默认按未通过算（2026-11-12 复审 P1#10）。
verify_once() {
  local rc=0 i
  if [ "${#EXPECTS[@]}" -gt 0 ]; then
    local aargs=(--platform android --wait "$WAIT")
    for i in "${EXPECTS[@]}"; do aargs+=(--has "$i"); done
    set +e
    bash "$ASSERT" ${aargs[@]+"${aargs[@]}"}
    rc=$?
    set -e
    # assert rc：0 全过 / 1 断言失败或超时 / 2 用法错 / 3 平台不可用 / 4 语义树空 / 5 快照失败
    #   只有 1 能断言「页面确实没到目标」；≥3 是**判定不了**，不能当「没生效」
    case "$rc" in
      0) return 0 ;;
      1) return 1 ;;
      *) return 2 ;;
    esac
  fi
  # --expect none（或缺省）：判页面是否变化
  SNAP_RC=0
  snap_take "$SNAP_NEW" || SNAP_RC=$?
  [ "$SNAP_RC" -eq 0 ] || return 2
  DELTA=$(page_delta "$SNAP_OLD" "$SNAP_NEW")
  [ "$(kv_of "$DELTA" unreadable)" = "1" ] && return 2
  # 强判据：目标节点消失 / 节点数变化
  if [ "$(kv_of "$DELTA" target_gone)" = "1" ] || [ "$(kv_of "$DELTA" nodes_changed)" = "1" ]; then
    return 0
  fi
  [ "$(kv_of "$DELTA" text_changed)" = "1" ] && return 3
  return 1
}

# ---------- 主流程 ----------
SNAP_RC=0
snap_take "$SNAP_OLD" || SNAP_RC=$?
case "$SNAP_RC" in
  0) : ;;
  4) echo "❌ 语义树为空（无文本/可点击节点，非页面空白）— 需 App 侧 Semantics 或改用 shot.sh + 坐标" >&2; exit 4 ;;
  *) echo "❌ 无法获取页面快照（snapshot.sh rc=${SNAP_RC}）" >&2; exit 5 ;;
esac

# 点击前先等 UI 静止（滑动/动画中间帧的坐标会点偏）；失败只告警，不阻断
set +e
bash "$SCRIPT_DIR/android/settle.sh" --mode auto --timeout 8 >/dev/null 2>&1
set -e

LOC=""
LOC_RC=0
set +e
LOC=$(locate "$SNAP_OLD")
LOC_RC=$?
set -e
if [ "$LOC_RC" -ne 0 ]; then
  # _tap_target 的 rc 有语义：5=快照 JSON 不可解析、6=命中但无中心点。统一报成「未命中」
  # 会把排障引向「页面不对」，而实际是快照/布局问题（2026-11-12 收尾复核 P2）。
  case "$LOC_RC" in
    2) echo "❌ 定位参数错误（_tap_target rc=2），检查 --index / --id / --exact" >&2; exit 2 ;;
    5) echo "❌ 快照 JSON 不可解析（_tap_target rc=5）— 页面可能在切换中，重试或先 settle.sh" >&2; exit 5 ;;
    6) echo "❌ 命中目标但节点无中心坐标（bounds 不可解析；可能在屏外/被裁剪）" >&2
       echo "💡 先 bash $SNAP --platform android --max 20 核对 bounds" >&2
       exit 1 ;;
  esac
  echo "❌ 未命中目标（--text '${NEEDLE}' index=${INDEX}）"
  echo "💡 目标可能在屏外：bash $SCRIPT_DIR/android/findtap.sh \"$NEEDLE\"（自动滚动查找+点击，同样无回执）" >&2
  echo "💡 或先 bash $SNAP --platform android --max 20 核对当前页" >&2
  exit 1
fi

CX=""; CY=""; TEXT=""; TOTAL=""; CLICKABLE="false"; OFFSCREEN="false"
if [ -n "$LOC" ]; then
  LOC_KV=$(printf '%s' "$LOC" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
c = d.get("center") or [0, 0]
print("cx=%d" % c[0])
print("cy=%d" % c[1])
print("text=%s" % (d.get("text") or ""))
print("total=%s" % d.get("total"))
print("clickable=%s" % ("true" if d.get("clickable") else "false"))
print("offscreen=%s" % ("true" if d.get("offscreen") else "false"))
' 2>/dev/null || true)
  CX=$(kv_line "$LOC_KV" cx); CY=$(kv_line "$LOC_KV" cy)
  TEXT=$(kv_line "$LOC_KV" text); TOTAL=$(kv_line "$LOC_KV" total)
  CLICKABLE=$(kv_line "$LOC_KV" clickable); OFFSCREEN=$(kv_line "$LOC_KV" offscreen)
fi
if [ -z "$CX" ] || [ -z "$CY" ]; then
  echo "❌ 定位结果缺少中心坐标（bounds 不可解析）" >&2
  exit 1
fi

if [ "$AS_JSON" = true ]; then
  # 由 python 序列化：needle/text 含引号/反斜杠时 printf 拼串会产出非法 JSON
  python3 - "$NEEDLE" "$CX" "$CY" "$TEXT" "${TOTAL:-1}" "$CLICKABLE" "$OFFSCREEN" <<'PY'
import json, sys
needle, cx, cy, text, total, clickable, offscreen = sys.argv[1:8]
print(json.dumps({
    "needle": needle,
    "center": [int(cx), int(cy)],
    "text": text,
    "total": int(total),
    "clickable": clickable == "true",
    "offscreen": offscreen == "true",
}, ensure_ascii=False))
PY
fi
echo "🎯 命中 $( [ "$TOTAL" = "" ] && echo 1 || echo "$TOTAL" ) 处，取 center=(${CX},${CY}) text='${TEXT}' clickable=${CLICKABLE} offscreen=${OFFSCREEN}"
[ "$CLICKABLE" = "false" ] && echo "⚠️ 节点 clickable=false（事件可能落到父容器；点不中优先查这里）" >&2
[ "$OFFSCREEN" = "true" ] && echo "⚠️ bounds 疑似离屏（滚动/键盘遮挡），点击可能无效" >&2

DANGER=0
is_danger "$NEEDLE" && DANGER=1
[ "$DANGER" = "0" ] && is_danger "$TEXT" && DANGER=1

if [ "$DRY_RUN" = true ]; then
  echo "🧪 --dry-run：不点击"
  exit 0
fi

ATTEMPT=0
while : ; do
  if ! adb -s "$DEVICE" shell input tap "$CX" "$CY" >/dev/null 2>&1; then
    echo "❌ 点击派发失败（adb input tap 报错）" >&2; exit 7
  fi
  echo "👆 已点击（第 $((ATTEMPT + 1)) 次）"
  VRC=0
  verify_once || VRC=$?
  if [ "$VRC" -eq 0 ]; then
    echo "✅ 点击并校验通过"
    log_json tap_verify "needle=$NEEDLE" "center_x=$CX" "center_y=$CY" \
      "attempts=$((ATTEMPT + 1))" "ok=true" \
      "expect=$( [ "${#EXPECTS[@]}" -gt 0 ] && echo "${EXPECTS[0]}" || echo none )" || true
    exit 0
  fi
  if [ "$VRC" -eq 2 ]; then
    # 无法判定（快照失败 / JSON 不可解析）⇒ fail-closed：**不许重试**
    echo "❌ 点击后页面快照不可用，无法判定是否已生效 ⇒ 不再重点（防重复触发事务）" >&2
    degrade_hint
    log_json tap_verify "needle=$NEEDLE" "center_x=$CX" "center_y=$CY" \
      "attempts=$((ATTEMPT + 1))" "ok=false" "changed=unknown" || true
    exit 1
  fi
  if [ "$VRC" -eq 3 ]; then
    # 仅文本集变化：弱证据（自动刷新页会自行漂移）⇒ 默认按未通过算，且**不再点第二次**
    if [ "$ALLOW_WEAK" = true ]; then
      echo "⚠️ 仅文本集变化（弱判据），--allow-weak 已放行" >&2
      log_json tap_verify "needle=$NEEDLE" "center_x=$CX" "center_y=$CY" \
        "attempts=$((ATTEMPT + 1))" "ok=true" "weak=true" || true
      exit 0
    fi
    echo "❌ 弱判据：仅文本集变化（自动刷新页会自行漂移），不能证明点击生效 ⇒ 不再重点" >&2
    echo "💡 页面确有目标变化且可接受弱证据时加 --allow-weak" >&2
    show_diff
    log_json tap_verify "needle=$NEEDLE" "center_x=$CX" "center_y=$CY" \
      "attempts=$((ATTEMPT + 1))" "ok=false" "changed=weak-only" || true
    exit 1
  fi

  # 未通过：再取一次快照判「是不是其实已经生效了」——生效就不再点第二次（防双击副作用）
  SNAP_RC=0
  snap_take "$SNAP_NEW" || SNAP_RC=$?
  if [ "$SNAP_RC" -ne 0 ]; then
    # ⚠️ 断言路径的 verify_once 可能没取快照（纯 assert 轮询），这里失败同样属「无法判定」：
    #    不能因为 DELTA 为空就落到下面的重试分支再点一次（2026-11-12 复审 P1-N2）。
    echo "❌ 点击后页面快照不可用（snapshot.sh rc=${SNAP_RC}），无法判定是否已生效 ⇒ 不再重点" >&2
    degrade_hint
    log_json tap_verify "needle=$NEEDLE" "center_x=$CX" "center_y=$CY" \
      "attempts=$((ATTEMPT + 1))" "ok=false" "changed=unknown" || true
    exit 1
  fi
  DELTA=$(page_delta "$SNAP_OLD" "$SNAP_NEW")
  CHANGED=$(kv_of "$DELTA" changed); GONE=$(kv_of "$DELTA" target_gone)
  NODES_CH=$(kv_of "$DELTA" nodes_changed); TEXT_CH=$(kv_of "$DELTA" text_changed)
  UNREAD=$(kv_of "$DELTA" unreadable)

  if [ "${UNREAD:-0}" = "1" ]; then
    echo "❌ 页面快照不可解析，无法判定是否已生效 ⇒ 不再重点" >&2
    degrade_hint
    log_json tap_verify "needle=$NEEDLE" "center_x=$CX" "center_y=$CY" \
      "attempts=$((ATTEMPT + 1))" "ok=false" "changed=unknown" || true
    exit 1
  fi

  if [ "${CHANGED:-0}" = "1" ]; then
    WEAK=0
    [ "${GONE:-0}" = "1" ] || [ "${NODES_CH:-0}" = "1" ] || WEAK=1
    if [ "$WEAK" = "1" ]; then
      echo "⚠️ 弱判据：仅文本集变化（自动刷新页会自行漂移），未确认点击生效" >&2
    fi
    echo "❌ 未达期望断言，但页面已变化（target_gone=${GONE:-?} nodes_changed=${NODES_CH:-?}）⇒ 不再重点（事务可能已提交）" >&2
    show_diff
    degrade_hint
    log_json tap_verify "needle=$NEEDLE" "center_x=$CX" "center_y=$CY" \
      "attempts=$((ATTEMPT + 1))" "ok=false" "changed=true" "weak=$WEAK" || true
    exit 1
  fi

  if [ "$ATTEMPT" -ge "$RETRY" ]; then
    echo "❌ 点击后页面无变化（${WAIT}s 内未达断言，也未检测到节点/文本变化）" >&2
    show_diff
    degrade_hint
    log_json tap_verify "needle=$NEEDLE" "center_x=$CX" "center_y=$CY" \
      "attempts=$((ATTEMPT + 1))" "ok=false" "changed=false" || true
    exit 1
  fi

  if [ "$DANGER" = "1" ] && [ "$ALLOW_DANGER" != true ]; then
    echo "❌ 目标是危险操作（删除/解绑/支付/提交…），页面无变化但默认不重试（防误触）" >&2
    echo "💡 确认可以再点一次时加 --allow-danger" >&2
    log_json tap_verify "needle=$NEEDLE" "center_x=$CX" "center_y=$CY" \
      "attempts=$((ATTEMPT + 1))" "ok=false" "changed=false" "danger=true" || true
    exit 1
  fi

  ATTEMPT=$((ATTEMPT + 1))
  echo "↻ 第 ${ATTEMPT} 次重试：重新定位后再点" >&2
  SNAP_RC=0
  snap_take "$SNAP_OLD" || SNAP_RC=$?
  [ "$SNAP_RC" -eq 0 ] || { echo "❌ 重试前快照失败" >&2; exit 5; }
  LOC=""; LOC_RC=0
  set +e
  LOC=$(locate "$SNAP_OLD")
  LOC_RC=$?
  set -e
  if [ "$LOC_RC" -ne 0 ]; then
    case "$LOC_RC" in
      5) echo "❌ 重试前快照 JSON 不可解析（_tap_target rc=5）— 页面仍在切换" >&2; exit 5 ;;
      6) echo "❌ 重新定位命中但无中心坐标（bounds 不可解析）" >&2; exit 1 ;;
    esac
    echo "❌ 重试定位失败（页面仍无该目标）" >&2
    degrade_hint
    exit 1
  fi
  LOC_KV=$(printf '%s' "$LOC" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
c = d.get("center") or [0, 0]
print("cx=%d" % c[0]); print("cy=%d" % c[1]); print("text=%s" % (d.get("text") or ""))
' 2>/dev/null || true)
  CX=$(kv_line "$LOC_KV" cx); CY=$(kv_line "$LOC_KV" cy); TEXT=$(kv_line "$LOC_KV" text)
  [ -n "$CX" ] && [ -n "$CY" ] || { echo "❌ 重试定位结果缺少坐标" >&2; exit 1; }
  echo "🎯 重新定位 center=(${CX},${CY}) text='${TEXT}'"
done