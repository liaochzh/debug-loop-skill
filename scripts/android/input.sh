#!/bin/bash
# input.sh — 输入框闭环：定位 → 清空 → 分段输入 → 读回校验（一次调用，替代临场拼 adb input text）
#
# 为什么需要本脚本（2026-11-12 立项）：此前 skill 全线没有输入能力，agent 只能临场
#   `adb shell input text` ⇒ ① 不清空旧内容（追加而非替换）② 特殊字符/空格被设备 shell 吃掉
#   ③ 长串输入掉字 ④ 输入完没人回读校验，错一两个字直到登录失败才发现 ⑤ 反复重试/粘贴。
#
# 用法:
#   ./input.sh --field 账号 --text 'alice@example.com'
#   ./input.sh --field 密码 --text-from .debug-login.secret --key PASSWORD --mask
#   ./input.sh --field 账号 --clear-only
#   ./input.sh --field 账号 --text 'alice' --dry-run      # 只看定位/清空方案，不点不输
#
# 取值来源（三选一，互斥）:
#   --text <字符串>          直接给值（会出现在命令行/会话记录里，敏感值不要用）
#   --text-from [文件]       从 KEY=VALUE 文件读（缺省 .debug-login.secret，必须 0600）
#   --text-stdin             从 stdin 读（`--text-from -` 等价）
#   --key <名字>             配合 --text-from：取哪一行；缺省取第一条
#
# 选项:
#   --field <关键词>         输入框的 text 或 id 子串（忽略大小写、非正则；= tap_snapshot 语义）
#   --exact                  精确匹配且大小写敏感
#   --index N                多处命中取第 N 个（1-based，默认 1）
#   --append                 append 模式（不清空；默认 replace = 先清空再输入）
#                            ⚠️ append 语义下**不自动重试**（重试会先清空，等于把追加变替换），
#                            且 --max-retry 对它无效；追加不符直接 rc=6
#   --mask                   掩码字段：读回只比长度、输出恒 ****
#   --max-retry N            校验不符时的重试次数（默认 1）
#   --slow                   每段间隔 0.6s（默认 0.15s），用于 IME 掉字的机器
#   --one-key                逐发 KEYCODE_DEL（老 ROM 不支持一次多键码时用）
#   --dry-run                只输出定位/清空方案
#
# 退出码:
#   0 输入并校验通过 / 1 未找到输入框（附候选）/ 2 用法错或凭据文件权限不合规
#   3 环境不可用（无设备 / 缺 .debug.env / 快照无法获取）/ 4 语义树为空（无 Semantics）
#   5 清空失败（--clear-only 或重试后仍非空）/ 6 输入后读回校验不符
#   7 事件派发失败（adb input 报错）**或点击后未获得焦点**（此时一律未做任何删除/输入）/ 8 含非 ASCII 字符（adb input text 不支持，改走 Maestro）
#
# 已知边界:
#   - `adb shell input text` **只支持 ASCII 可打印字符**；中文/emoji 直接 rc=8，
#     改用 `maestro/flow.sh`（`eraseText` + `inputText`，Android 可用）。
#   - 文本里含字面 `%s` 会被 Android 当作空格（框架层限制，无法转义）；`%s` 请改走 Maestro。
#   - 密码框语义值可能恒为空或全为圆点 ⇒ `--mask` 只比长度；长度也不可见时输出
#     `⚠️ 内容未验证`，只保证「点击聚焦 + 已发送按键」，不要当成通过。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # → scripts/android
SCRIPTS="$(cd "$SCRIPT_DIR/.." && pwd)"                       # → scripts（跨平台脚本都在这一层）
FIELD_PY="$SCRIPTS/_field_target.py"
LOG_DIR="${LOG_DIR:-build/debug}"
INTERACT_DIR="$LOG_DIR/interact"

FIELD=""; TEXT=""; TEXT_SET=false; FROM_SET=false; STDIN_SET=false; KEY_NAME=""
TEXT_FROM=""   # 必须预置：`set -u` 下 --clear-only 路径不会赋值，直接引用会 unbound
MASK=false; EXACT=false; INDEX=1; MODE="replace"; CLEAR_ONLY=false
MAX_RETRY=1; SLOW=false; ONE_KEY=false; DRY_RUN=false
# 凭据来源（--text-from / --text-stdin）一律按敏感处理：输出恒打 ****，不回显原值
SECRET=false

usage() {
  awk 'NR < 3 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --field)     [ $# -ge 2 ] || { echo "❌ --field 缺参数值"; exit 2; }; FIELD="$2"; shift 2 ;;
    --text)      [ $# -ge 2 ] || { echo "❌ --text 缺参数值"; exit 2; }; TEXT="$2"; TEXT_SET=true; shift 2 ;;
    --text-from)
      FROM_SET=true
      if [ $# -ge 2 ] && [ "${2#-}" = "$2" ]; then TEXT_FROM="$2"; shift 2; else TEXT_FROM=".debug-login.secret"; shift; fi
      [ "$TEXT_FROM" = "-" ] && { STDIN_SET=true; FROM_SET=false; }
      ;;
    --text-stdin) STDIN_SET=true; shift ;;
    --key)       [ $# -ge 2 ] || { echo "❌ --key 缺参数值"; exit 2; }; KEY_NAME="$2"; shift 2 ;;
    --exact)     EXACT=true; shift ;;
    --index)     [ $# -ge 2 ] || { echo "❌ --index 缺参数值"; exit 2; }; INDEX="$2"; shift 2 ;;
    --append)    MODE="append"; shift ;;
    --clear-only) CLEAR_ONLY=true; shift ;;
    --mask)      MASK=true; shift ;;
    --max-retry) [ $# -ge 2 ] || { echo "❌ --max-retry 缺参数值"; exit 2; }; MAX_RETRY="$2"; shift 2 ;;
    --slow)      SLOW=true; shift ;;
    --one-key)   ONE_KEY=true; shift ;;
    --dry-run)   DRY_RUN=true; shift ;;
    -h|--help)   usage; exit 0 ;;
    -*) echo "❌ 未知参数: $1"; exit 2 ;;
    *)  echo "❌ 未知参数: $1"; exit 2 ;;
  esac
done

[ -n "$FIELD" ] || { echo "❌ 需要 --field <关键词>"; exit 2; }
case "$INDEX" in ''|*[!0-9]*) echo "❌ --index 必须为整数: $INDEX"; exit 2 ;; esac
[ "$INDEX" -ge 1 ] || { echo "❌ --index 必须 ≥1"; exit 2; }
case "$MAX_RETRY" in ''|*[!0-9]*) echo "❌ --max-retry 必须为非负整数: $MAX_RETRY"; exit 2 ;; esac

SOURCES=0
[ "$TEXT_SET" = true ] && SOURCES=$((SOURCES + 1))
[ "$FROM_SET" = true ] && SOURCES=$((SOURCES + 1))
[ "$STDIN_SET" = true ] && SOURCES=$((SOURCES + 1))
if [ "$CLEAR_ONLY" = false ]; then
  [ "$SOURCES" -eq 1 ] || { echo "❌ --text / --text-from / --text-stdin 必须且只能给一个（当前 ${SOURCES} 个）"; exit 2; }
else
  [ "$SOURCES" -eq 0 ] || { echo "❌ --clear-only 不能与取值参数同用"; exit 2; }
fi

SLEEP_CHUNK="0.15"
[ "$SLOW" = true ] && SLEEP_CHUNK="0.6"

# ---------- 环境：把 _common.sh 的 exit 1 收敛成 rc=3（否则会撞上「1=未找到」） ----------
DEVICE=""
env_guard() {
  local out err rc
  out=$(mktemp); err=$(mktemp)
  set +e
  ( source "$SCRIPT_DIR/_common.sh"; require_device > "$out" ) 2> "$err"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "❌ 环境不可用（rc=${rc}），未执行任何输入动作" >&2
    [ -s "$err" ] && cat "$err" >&2
    rm -f "$out" "$err"
    return 3
  fi
  DEVICE=$(head -1 "$out")
  rm -f "$out" "$err"
  [ -n "$DEVICE" ] || { echo "❌ 未能解析设备 ID" >&2; return 3; }
  return 0
}

# ---------- 取值 ----------
secret_perm() {  # <file> → 八进制权限
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then stat -f '%Lp' "$1"; else stat -c '%a' "$1"; fi
}

read_secret() {  # <file> [key] → stdout 值
  local file="$1" key="${2:-}" line k v
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) : ;; *) continue ;; esac
    k="${line%%=*}"
    v="${line#*=}"
    k="$(printf '%s' "$k" | tr -d '[:space:]')"
    if [ -n "$key" ]; then
      [ "$k" = "$key" ] && { printf '%s' "$v"; return 0; }
    else
      printf '%s' "$v"; return 0
    fi
  done < "$file"
  return 1
}

load_text() {
  if [ "$TEXT_SET" = true ]; then
    return 0
  fi
  if [ "$STDIN_SET" = true ]; then
    TEXT="$(cat)"
    SECRET=true
    return 0
  fi
  # ⚠️ 变量后紧跟中文全角标点必须写成 ${VAR}：`$VAR` 直接接全角括号时，部分 locale 下
  #    多字节字符首字节会被吞进变量名 ⇒ `set -u` 报「TEXT_FROM<乱码>: unbound variable」（2026-11-12 实测）
  [ -f "$TEXT_FROM" ] || { echo "❌ 凭据文件不存在: ${TEXT_FROM}（先由人工创建，勿入库）" >&2; return 2; }
  local perm
  perm=$(secret_perm "$TEXT_FROM")
  if [ "$perm" != "600" ]; then
    echo "❌ 凭据文件权限为 ${perm}，要求 600：chmod 600 $TEXT_FROM" >&2
    return 2
  fi
  TEXT=$(read_secret "$TEXT_FROM" "$KEY_NAME") || {
    echo "❌ 凭据文件里没有可用的 KEY=VALUE（--key '${KEY_NAME}'）" >&2
    return 2
  }
  SECRET=true
  return 0
}

# ---------- 快照 / 定位 ----------
# 快照含完整语义树（非掩码字段会带**刚输进去的明文**）⇒ 落在临时文件、退出即删，
# 不写进 build/debug 长期留档（2026-11-12 复审 P1#8）。
SNAP="$(mktemp "${TMPDIR:-/tmp}/dbginput.snap.XXXXXX")"
SNAP_ERR="$(mktemp "${TMPDIR:-/tmp}/dbginput.err.XXXXXX")"
READBACK_SNAP="$(mktemp "${TMPDIR:-/tmp}/dbginput.rb.XXXXXX")"
cleanup() { rm -f "$SNAP" "$SNAP_ERR" "$READBACK_SNAP"; }
trap cleanup EXIT

take_snapshot() {  # <out> → 透传 snapshot.sh rc
  local out="$1" rc=0
  set +e
  bash "$SCRIPTS/snapshot.sh" --platform android --json > "$out" 2>"$SNAP_ERR"
  rc=$?
  set -e
  return "$rc"
}

show_candidates() {  # <json>
  printf '%s\n' "$1" | python3 -c '
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
print("💡 " + (d.get("reason") or "未命中"))
c = d.get("candidates") or []
if c:
    print("💡 候选: " + " / ".join(c))
print("💡 语义树可用时也确认页面确实是目标页：bash scripts/snapshot.sh --platform android --max 20")
' || true
}

plan_field() {  # <snapshot> <mode: field|field-edit|bounds> <value> [mask:on|off] → stdout KV；rc 透传
  # mask=off 用于**读回**：--mask 会让 _field_target 不回显 current（防明文外泄），
  #   但读回就是要那个值 ⇒ 定位与掩码必须解耦，否则 --mask --clear-only 会把空串当「已清空」（假绿）。
  local snap="$1" mode="$2" value="$3" mask_mode="${4:-on}" rc=0
  set +e
  if [ "$mode" = "bounds" ]; then
    python3 "$FIELD_PY" --snapshot "$snap" --bounds "$value" --kv
  else
    local extra=()
    [ "$mask_mode" = "on" ] && [ "$MASK" = true ] && extra+=("--mask")
    [ "$EXACT" = true ] && extra+=("--exact")
    [ "$mode" = "field-edit" ] && extra+=("--editable-only")
    python3 "$FIELD_PY" --snapshot "$snap" --field "$value" --index "$INDEX" ${extra[@]+"${extra[@]}"} --kv
  fi
  rc=$?
  set -e
  return "$rc"
}

kv_get() {  # <text> <key>
  printf '%s\n' "$1" | awk -v k="$2=" 'index($0, k) == 1 { print substr($0, length(k) + 1); exit }'
}

# ---------- 动作 ----------
escape_for_adb() {  # <原串> → 设备 shell 单引号安全形态；空格 → %s
  python3 - "$1" <<'PY'
import sys
s = sys.argv[1]
s = s.replace("'", "'\\''")
s = s.replace(" ", "%s")
sys.stdout.write(s)
PY
}

do_tap() {  # <x> <y>
  adb -s "$DEVICE" shell input tap "$1" "$2" >/dev/null 2>&1
}

do_clear() {  # <dels>
  local n="$1" i=0 keys=""
  # n=0 时必须直接返回：否则会发出**不带键码**的 `input keyevent`（真机返回非零 ⇒ 误报 rc=7）
  [ "$n" -gt 0 ] || return 0
  adb -s "$DEVICE" shell input keyevent 123 >/dev/null 2>&1 || return 1   # MOVE_END
  if [ "$ONE_KEY" = true ]; then
    while [ "$i" -lt "$n" ]; do
      adb -s "$DEVICE" shell input keyevent 67 >/dev/null 2>&1 || return 1
      i=$((i + 1))
    done
  else
    while [ "$i" -lt "$n" ]; do keys="$keys 67"; i=$((i + 1)); done
    adb -s "$DEVICE" shell input keyevent $keys >/dev/null 2>&1 || return 1
  fi
  return 0
}

# 焦点自检：删除/输入都作用在「当前聚焦元素」上，焦点没进去就发 DEL 会删掉**别的框**。
#   取不到判定信息（老 ROM 无 dumpsys output）时只告警，不当失败（避免假阻塞）。
focus_ok() {
  local out
  out=$(adb -s "$DEVICE" shell dumpsys input_method 2>/dev/null || true)
  [ -n "$out" ] || { echo "⚠️ 取不到输入法焦点状态（dumpsys 无输出），继续但请留意读回校验" >&2; return 0; }
  # ⚠️ 用 case 而非 `printf | grep -q`：本脚本开了 pipefail，grep -q 命中即退出会让 printf
  #    吃到 SIGPIPE（输出 > 管道缓冲时），管线整体非零 ⇒ 被误判成「字段不存在」⇒ 告警后继续，
  #    等于在「真没焦点」时照样盲删（2026-11-12 收尾复核 P1）。case 无管道、纯内建。
  case "$out" in
    *mInputShown=true*) return 0 ;;   # 有焦点
    *mInputShown*)      return 1 ;;   # 有该字段且不为 true ⇒ 焦点没进去（必须停，别盲删）
  esac
  # 字段不存在（部分 ROM 精简了 dumpsys）⇒ 无法判定，不能当「没焦点」阻断（否则正常流程被迫中断）
  echo "⚠️ 该 ROM 的 dumpsys input_method 无 mInputShown 字段，焦点无法判定，继续但请留意读回校验" >&2
  return 0
}

do_type() {  # <text>
  # ⚠️ 不能在同一个 local 里写 `n=${#text}`：所有词先展开再赋值 ⇒ `set -u` 下报 unbound
  local text="$1" i=0 n chunk esc
  n=${#text}
  while [ "$i" -lt "$n" ]; do
    chunk="${text:$i:20}"
    i=$((i + 20))
    esc=$(escape_for_adb "$chunk")
    adb -s "$DEVICE" shell "input text '$esc'" >/dev/null 2>&1 || return 1
    sleep "$SLEEP_CHUNK"
  done
  return 0
}

read_back() {  # <bounds> <field> <id> → stdout 当前值；rc 0 找到 / 1 未找到或不是同一个框
  local snap="$READBACK_SNAP" kv rc=0 want_bounds="$1" want_field="$2" want_id="$3"
  set +e
  bash "$SCRIPTS/snapshot.sh" --platform android --json > "$snap" 2>/dev/null
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || return 1
  set +e
  kv=$(plan_field "$snap" bounds "$want_bounds" off)
  rc=$?
  set -e
  if [ "$rc" -ne 0 ] && [ -n "$want_field" ]; then
    # bounds 漂移（键盘收起/布局变化）⇒ 退一步按关键词 + **只认可编辑节点**再定位。
    # ⚠️ 必须校验「同一节点」：输入后原文/占位符会变，只按关键词可能命中同页另一个框，
    #    读到错的值会导致假 rc=6，并让重试按错误长度去删（2026-11-12 复审 P1#5）。
    set +e
    kv=$(plan_field "$snap" field-edit "$want_field" off)
    rc=$?
    set -e
    if [ "$rc" -eq 0 ] && [ -n "$want_id" ] && [ "$(kv_get "$kv" id)" != "$want_id" ]; then
      echo "⚠️ 读回命中的是另一个输入框（id=$(kv_get "$kv" id)，期望 ${want_id}）⇒ 按读回失败处理" >&2
      return 1
    fi
    # 节点没有 resource-id（Flutter/Compose 常见）⇒ 用「可编辑节点是否唯一」兜底：
    #   同页多个可编辑框且关键词命中 >1 时，无法确认读的是同一个框，宁可判读回失败（假 rc=6
    #   比「读到别人的值」安全：后者会让后续删除按错误长度执行）。
    if [ "$rc" -eq 0 ] && [ -z "$want_id" ] && [ "$(kv_get "$kv" total)" != "1" ]; then
      echo "⚠️ 关键词命中多个可编辑节点（total=$(kv_get "$kv" total)），无法确认读回的是同一输入框 ⇒ 按读回失败处理" >&2
      return 1
    fi
  fi
  [ "$rc" -eq 0 ] || return 1
  kv_get "$kv" current
  return 0
}

# 现场 JSON：python 构造（不手拼；字段名/值都按 key=value 传入，值含引号也不会产出坏 JSON）
log_interact() {  # <action> key=value …
  mkdir -p "$INTERACT_DIR"
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
# 毫秒 + pid：同一秒内多次写入不会互相覆盖
path = os.path.join(out_dir, "%d-%d-input.json" % (ms, os.getpid()))
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, ensure_ascii=False, indent=1)
print("📝 " + path)
PY
}

# ---------- 主流程 ----------
env_guard || exit 3

if [ "$CLEAR_ONLY" = false ]; then
  load_text || exit $?
  # ⚠️ 判据用 grep 而不是 case 模式：case 里写 `*[! -~]*` 会因模式词内空格触发语法错误
  #    （2026-11-12 实测）；`[!-~]` 又会被解析成「除 `-` 和 `~` 之外」⇒ 纯 ASCII 也误判。
  #    LC_ALL=C 保证按字节判，UTF-8 多字节字符才会命中。
  # ⚠️ 用 here-string 而非管道：脚本开了 pipefail，`printf | grep -q` 在超长文本下会因 grep
  #    提前退出让 printf 吃 SIGPIPE（管线非零 ⇒ 非 ASCII 漏检，本该 rc=8 变成派发失败）。
  if LC_ALL=C grep -q '[^ -~]' <<<"$TEXT"; then
    echo "❌ 含非 ASCII 字符（如中文/emoji），adb input text 无法输入" >&2
    echo "💡 改用 Maestro：写 flow 用 eraseText + inputText（Android 可用），见 references/maestro-flow-snippets.md" >&2
    exit 8
  fi
  [ -n "$TEXT" ] || { echo "❌ 取到的文本为空（检查凭据文件 / --key）"; exit 2; }
fi
[ -d "$LOG_DIR" ] || mkdir -p "$LOG_DIR"

SNAP_RC=0
take_snapshot "$SNAP" || SNAP_RC=$?
case "$SNAP_RC" in
  0) : ;;
  4) echo "❌ 语义树为空（页面无文本/可点击节点，非页面空白）— 需 App 侧 Semantics 或改用 shot.sh + 坐标" >&2; exit 4 ;;
  *) echo "❌ 无法获取页面快照（snapshot.sh rc=${SNAP_RC}）" >&2; exit 3 ;;
esac

PLAN=""
PLAN_RC=0
set +e
PLAN=$(plan_field "$SNAP" field "$FIELD")
PLAN_RC=$?
set -e
if [ "$PLAN_RC" -ne 0 ]; then
  echo "❌ 未找到输入框（--field '${FIELD}'，index=${INDEX}）"
  # ⚠️ 未命中时 _field_target 的 rc=1 是**预期**的：不能用 `|| echo '{}'` 兜（会把 JSON 和 `{}`
  #    拼在一条流里，下游 json.load 直接失败 ⇒ 候选清单静默丢失）；用 `|| true` 保留原输出
  CUES=""
  set +e
  CUES=$(python3 "$FIELD_PY" --snapshot "$SNAP" --field "$FIELD" --index "$INDEX" 2>/dev/null)
  set -e
  show_candidates "${CUES:-}"
  exit 1
fi

CX=$(kv_get "$PLAN" cx); CY=$(kv_get "$PLAN" cy)
DELS=$(kv_get "$PLAN" dels); NEEDS_CLEAR=$(kv_get "$PLAN" needs_clear)
BOUNDS=$(kv_get "$PLAN" bounds); CUR=$(kv_get "$PLAN" current)
NODE_ID=$(kv_get "$PLAN" id); CLICKABLE=$(kv_get "$PLAN" clickable)
DELS="${DELS:-0}"; NEEDS_CLEAR="${NEEDS_CLEAR:-0}"; CLICKABLE="${CLICKABLE:-0}"; NODE_ID="${NODE_ID:-}"

# 统一的「值能否外显」判据（掩码字段或凭据来源一律打码）：三处都走它，避免各自判漏
mask_out() {
  if [ "$MASK" = true ] || [ "$SECRET" = true ]; then printf '****'; else printf '%s' "$1"; fi
}

SHOWN=$(mask_out "$CUR")
echo "🎯 目标: bounds=${BOUNDS} id='${NODE_ID}' center=(${CX},${CY}) clickable=${CLICKABLE} 当前值='${SHOWN}' 清空删除=${DELS}"

if [ "$DRY_RUN" = true ]; then
  echo "🧪 --dry-run：不点击、不输入"
  exit 0
fi

[ "$CLICKABLE" = "1" ] || echo "⚠️ 该节点 clickable=false，仍按中心坐标点击（事件通常落到父容器）" >&2

if ! do_tap "$CX" "$CY"; then
  echo "❌ 点击聚焦失败（adb input tap 报错）" >&2; exit 7
fi
sleep 0.4

# 破坏性动作（DEL / 文本）之前必须确认焦点真的进了目标框：焦点没进去时这些键会落到
# 上一个聚焦元素上，等于删别人的内容（2026-11-12 复审 P1#7）。
if ! focus_ok; then
  echo "❌ 点击后输入法未显示（目标未获得焦点）⇒ 已停止，未删除/未输入任何内容" >&2
  echo "💡 目标可能在弹层/键盘下方，或 clickable=false；先 settle.sh + snapshot.sh 复核位置" >&2
  exit 7
fi

if [ "$CLEAR_ONLY" = true ] || { [ "$MODE" = "replace" ] && [ "$NEEDS_CLEAR" != "0" ]; }; then
  if ! do_clear "$DELS"; then
    echo "❌ 清空按键派发失败" >&2; exit 7
  fi
fi

if [ "$CLEAR_ONLY" = true ]; then
  LEFT=$(read_back "$BOUNDS" "$FIELD" "$NODE_ID") || { echo "❌ 清空后无法读回输入框" >&2; exit 5; }
  if [ -z "$LEFT" ]; then
    echo "✅ 已清空（读回为空）"
    log_interact clear-only "field=$FIELD" "bounds=$BOUNDS" "cleared=true" || true
    exit 0
  fi
  echo "❌ 清空失败：读回 '$(mask_out "$LEFT")'（可试 --one-key / 增大 --max-retry）" >&2
  exit 5
fi

ATTEMPT=0
TYPED=false
while : ; do
  if ! do_type "$TEXT"; then
    echo "❌ 文本派发失败（adb input text 报错）" >&2; exit 7
  fi
  TYPED=true
  sleep 0.3
  ACTUAL=""
  if ACTUAL=$(read_back "$BOUNDS" "$FIELD" "$NODE_ID"); then
    VRC=0
    VFY_ARGS=(--verify --expect "$TEXT" --actual "$ACTUAL")
    [ "$MASK" = true ] && VFY_ARGS+=(--mask)
    # append 模式读回是「旧值+新值」⇒ 只判后缀，否则会把成功误判成不符、再多删一遍
    [ "$MODE" = "append" ] && VFY_ARGS+=(--append)
    set +e
    python3 "$FIELD_PY" ${VFY_ARGS[@]+"${VFY_ARGS[@]}"} >/dev/null
    VRC=$?
    set -e
    if [ "$VRC" -eq 0 ]; then
      echo "✅ 输入并校验通过（$([ "$MASK" = true ] && echo '掩码字段，仅比长度' || echo "读回一致")）"
      log_interact input "field=$FIELD" "bounds=$BOUNDS" "mode=$MODE" \
        "mask=$([ "$MASK" = true ] && echo true || echo false)" "attempts=$((ATTEMPT + 1))" "ok=true" || true
      exit 0
    fi
  else
    echo "⚠️ 输入后读回失败（输入框不在当前页/被键盘遮挡），按未验证处理" >&2
    VRC=1
  fi

  # --append 不重试：重试要先把框清空，等于把「追加」变成「替换」（旧前缀被删），
  #   与调用方语义冲突；一次不符就直接回报（2026-11-12 复审 P2）。
  if [ "$MODE" = "append" ]; then
    echo "❌ 追加输入后读回不符（期望后缀长度 ${#TEXT}，实际 '$(mask_out "$ACTUAL")'）" >&2
    echo "💡 --append 语义下不自动重试（重试会清掉旧内容）；需要替换请去掉 --append" >&2
    log_interact input "field=$FIELD" "bounds=$BOUNDS" "mode=$MODE" \
      "mask=$([ "$MASK" = true ] && echo true || echo false)" "attempts=$((ATTEMPT + 1))" "ok=false" || true
    exit 6
  fi

  if [ "$ATTEMPT" -ge "$MAX_RETRY" ]; then
    echo "❌ 读回校验不符（期望长度 ${#TEXT}，实际 '$(mask_out "$ACTUAL")'）" >&2
    echo "💡 可试：--slow（IME 掉字）/ --one-key（老 ROM）/ 或改走 Maestro eraseText+inputText" >&2
    log_interact input "field=$FIELD" "bounds=$BOUNDS" "mode=$MODE" \
      "mask=$([ "$MASK" = true ] && echo true || echo false)" "attempts=$((ATTEMPT + 1))" "ok=false" || true
    exit 6
  fi

  ATTEMPT=$((ATTEMPT + 1))
  echo "↻ 第 ${ATTEMPT} 次重试：先按读回长度清空再重输" >&2
  # 重试前必须**重新定位**（旧坐标可能已不在目标框上；拿不到新坐标就按未验证退出）
  PLAN2=""
  PLAN2_RC=0
  set +e
  PLAN2=$(plan_field "$SNAP" field "$FIELD")
  PLAN2_RC=$?
  set -e
  if [ "$PLAN2_RC" -eq 0 ]; then
    CX2=$(kv_get "$PLAN2" cx); CY2=$(kv_get "$PLAN2" cy)
    [ -n "$CX2" ] && [ -n "$CY2" ] && { CX="$CX2"; CY="$CY2"; }
    BOUNDS2=$(kv_get "$PLAN2" bounds); [ -n "$BOUNDS2" ] && BOUNDS="$BOUNDS2"
  fi
  REDO_PLAN=""
  set +e
  REDO_PLAN=$(read_back "$BOUNDS" "$FIELD" "$NODE_ID")
  set -e
  # 清空次数与首次同源（_field_target.plan_clear），不再内联复制一份逻辑
  REDO_ARGS=(--plan-clear "${REDO_PLAN:-}")
  [ "$MASK" = true ] && REDO_ARGS+=(--mask)
  REDO_DELS=$(python3 "$FIELD_PY" ${REDO_ARGS[@]+"${REDO_ARGS[@]}"} 2>/dev/null || echo "$DELS")
  REDO_DELS="${REDO_DELS:-0}"
  do_tap "$CX" "$CY" || { echo "❌ 重新聚焦失败" >&2; exit 7; }
  sleep 0.3
  focus_ok || { echo "❌ 重试时点击未获得焦点 ⇒ 已停止，未删除任何内容" >&2; exit 7; }
  do_clear "$REDO_DELS" || { echo "❌ 重试清空失败" >&2; exit 7; }
  sleep 0.2
done