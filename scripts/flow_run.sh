#!/bin/bash
# flow_run.sh — 回放已固化的流程（分级门禁 + 续跑 + 设备注入 + 逐步 journal + 失败取证）
#
# 为什么需要本脚本（2026-11-17 立项）：
#   回归任务每次「逐步探索 + 每步一轮推理」是 autoDebug 慢的根因。流程固化后，
#   回放 = 一条命令跑完整个序列，agent 只读步骤表与证据 ⇒ 几十轮推理压到 1~3 轮。
#
# 分级门禁（与 flow_save 分级同一口径）：
#   A 级：可直接回放；
#   B 级：必须显式 --allow-confirm（**未获用户同意不得授权**，见任务模板硬条款）；
#         未授权 ⇒ rc=6，**零设备动作**（不建目录、不跑任何步骤）。
#   rc=6 只属于本脚本的「需授权」；步骤脚本自己的 rc（如 input.sh 读回不符 rc=6）
#   只记进步骤表 ⇒ 流程最终 rc=1，不会与门禁混淆。
#
# 幂等/中断纪律：
#   回放失败后**禁止整流程重跑**（登录/提交类步骤会重复触发事务）。
#   续跑用 --from-step N（N∈[1,步数]），续跑仍受 B 级门禁约束；
#   每步结束立即写 journal（build/debug/flows/<名>-<ts>/journal.jsonl），被强杀也留有现场。
#
# 设备语义（与既有脚本家族一致）：
#   android   注入 ANDROID_SERIAL；指定不在线 ⇒ rc=1，不静默换机
#   ios       模拟器**校验不注入**（booted 与元数据 UDID 不符 ⇒ rc=1）
#   ios-device 注入 IOS_DEVICE_UDID + IOS_TARGET=device
#   macos     设备字段仅记录（写 local）
#
# 用法:
#   flow_run.sh --name <名> [--allow-confirm] [--from-step N] [--dry-run] [--root <目录>]
#
# 退出码: 0 全过 / 1 步骤失败或设备不符 / 2 用法错或流程文件非法 /
#         3 流程不存在 / 4 平台不受支持 / 6 需授权（B 级未加 --allow-confirm）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${LOG_DIR:-build/debug}"
# 危险词（命令串扩展表）：仅用于失败后提醒「续跑前先确认页面状态」
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_danger_words.sh"
# 测试钩子（正常使用不要设）：把步骤脚本解析到桩目录，供离线回归注入 rc/输出
STEP_BASE="${FLOW_STEP_DIR:-$SCRIPT_DIR}"

NAME=""; ALLOW=false; FROM=1; DRY=false; ROOT="docs/test/debug-loop"

usage() {
  awk 'NR < 3 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"
}
die_usage() { echo "❌ $1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --name)          [ $# -ge 2 ] || die_usage "--name 缺参数值";   NAME="$2"; shift 2 ;;
    --allow-confirm) ALLOW=true; shift ;;
    --from-step)     [ $# -ge 2 ] || die_usage "--from-step 缺参数值"; FROM="$2"; shift 2 ;;
    --dry-run)       DRY=true; shift ;;
    --root)          [ $# -ge 2 ] || die_usage "--root 缺参数值";   ROOT="$2"; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "❌ 未知参数: $1" >&2; exit 2 ;;
  esac
done

[ -n "$NAME" ] || die_usage "需要 --name <流程名>"
case "$NAME" in
  .|..) die_usage "流程名不能是 '.' 或 '..'" ;;
  *[!A-Za-z0-9._-]*) die_usage "流程名只允许 字母/数字/点/下划线/连字符（收到: ${NAME}）" ;;
esac
case "$ROOT" in
  /*) die_usage "--root 必须相对项目根（收到绝对路径: ${ROOT}）" ;;
  *..*) die_usage "--root 不得含 ..（收到: ${ROOT}）" ;;
esac
case "$FROM" in ''|*[!0-9]*) die_usage "--from-step 需为正整数（收到: ${FROM}）" ;; esac

if [ ! -f ".debug.env" ]; then
  echo "❌ 请在项目根执行（当前目录无 .debug.env）" >&2
  exit 3
fi

FILE="$ROOT/flows/$NAME.json"
FROM_TEMPLATE=0
if [ ! -f "$FILE" ]; then
  FILE="$SCRIPT_DIR/../templates/flows/$NAME.json"
  FROM_TEMPLATE=1
fi
if [ ! -f "$FILE" ]; then
  echo "❌ 流程不存在: ${ROOT}/flows/${NAME}.json（也查过 templates/flows/）" >&2
  echo "   💡 先固化：bash <S>/scripts/flow_save.sh --name ${NAME} …" >&2
  exit 3
fi

# ---------- 读取流程（元数据走 KV，步骤单独落临时文件避免空格/引号问题） ----------
TMP_STEPS="$(mktemp "${TMPDIR:-/tmp}/flowsteps.XXXXXX")"
cleanup() { rm -f "$TMP_STEPS"; }
trap cleanup EXIT

META="$(python3 - "$FILE" "$TMP_STEPS" <<'PY'
import json, sys

src, out = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(src, encoding="utf-8"))
except Exception as exc:
    print("ERR=解析失败: %s" % exc)
    raise SystemExit(0)
if not isinstance(d, dict):
    print("ERR=顶层不是对象")
    raise SystemExit(0)
steps = d.get("steps") or []
if not isinstance(steps, list):
    print("ERR=steps 不是数组")
    raise SystemExit(0)
with open(out, "w", encoding="utf-8") as fh:
    for s in steps:
        fh.write(str(s).replace("\n", " ").replace("\r", " ") + "\n")
# 值必须是单行：多行值会被 bash 侧逐行解析成**额外键**（如 precond="x\ngrade=A" 可伪造 grade）
def one_line(v):
    return str(v if v is not None else "").replace("\r", " ").replace("\n", " ").strip()

for k in ("name", "platform", "profile", "device", "grade", "precond", "status"):
    print("%s=%s" % (k, one_line(d.get(k))))
print("observe=%s" % ("1" if d.get("observe_only") else "0"))
print("consecutive=%s" % one_line(d.get("consecutive_failures") or 0))
PY
)"
ERR=""
while IFS='=' read -r k v; do
  case "$k" in
    ERR) ERR="$v" ;;
    platform) PLATFORM="$v" ;;
    profile) PROFILE="$v" ;;
    device) DEVICE="$v" ;;
    grade) GRADE="$v" ;;
    precond) PRECOND="$v" ;;
    status) STATUS="$v" ;;
    observe) OBSERVE="$v" ;;
    consecutive) CONSEC="$v" ;;
  esac
done <<< "$META"
[ -z "$ERR" ] || die_usage "流程文件非法（${FILE}）：${ERR}"

PLATFORM="${PLATFORM:-}"; PROFILE="${PROFILE:-ui}"; DEVICE="${DEVICE:-}"; GRADE="${GRADE:-B}"
STATUS="${STATUS:-active}"; OBSERVE="${OBSERVE:-0}"; CONSEC="${CONSEC:-0}"

STEPS=()
while IFS= read -r line; do STEPS+=("$line"); done < "$TMP_STEPS"
COUNT="${#STEPS[@]}"
[ "$COUNT" -gt 0 ] || die_usage "流程没有步骤（${FILE}）"

case "$PLATFORM" in
  android|ios|ios-device|macos) ;;
  *) echo "❌ 流程平台不受支持: ${PLATFORM:-<空>}（${FILE}）" >&2; exit 4 ;;
esac
case "$PLATFORM" in
  android)   PLAT_DIR="android" ;;
  ios)       PLAT_DIR="ios" ;;
  ios-device) PLAT_DIR="ios" ;;
  *)         PLAT_DIR="macos" ;;
esac

if [ "$FROM" -lt 1 ] || [ "$FROM" -gt "$COUNT" ]; then
  die_usage "--from-step 越界：需在 1..${COUNT}（收到: ${FROM}）"
fi
[ "$FROM" -gt 1 ] || FROM=1

expand_platform() { printf '%s' "$1" | sed "s#<platform>#${PLAT_DIR}#g"; }

first_token() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  case "$s" in
    \"*) s="${s#\"}"; printf '%s' "${s%%\"*}" ;;
    \'*) s="${s#\'}"; printf '%s' "${s%%\'*}" ;;
    *)   printf '%s' "${s%%[[:space:]]*}" ;;
  esac
}

# ---------- dry-run：只列计划，不建目录不跑步骤 ----------
if [ "$DRY" = true ]; then
  echo "🧪 ${NAME}（平台=${PLATFORM} profile=${PROFILE} 级=${GRADE}${FROM_TEMPLATE:+$( [ "$FROM_TEMPLATE" = 1 ] && echo "，模板" )}）"
  echo "   设备=${DEVICE:-<未指定，脚本按默认选台>} | 前提=${PRECOND:-未声明} | 步骤=${COUNT} | 起始=第 ${FROM} 步"
  [ "$GRADE" != "A" ] && echo "   ⚠️ 非 A 级：回放需用户同意后加 --allow-confirm（dry-run 不执行）"
  i=0
  for s in "${STEPS[@]}"; do
    i=$((i + 1))
    mark="  "
    [ "$i" -lt "$FROM" ] && mark="⏭ "
    echo "   ${mark}${i}. $(expand_platform "$s")"
  done
  exit 0
fi

# ---------- 分级门禁（未授权 ⇒ 零设备动作） ----------
# fail-closed：**只有显式 grade=A 才免门禁**；缺值、坏值（"a"/"active"/未知）一律按需授权处理
if [ "$GRADE" != "A" ] && [ "$ALLOW" != true ]; then
  echo "🔒 流程 ${NAME} 非 A 级（级=${GRADE:-未知}；B 级含坐标/危险词/放宽 profile/降级平台/无断言之一），需用户授权后才可回放。" >&2
  echo "   已获用户同意后：加 --allow-confirm 重跑；未获同意请先问用户，不要自行加。" >&2
  echo "   💡 只看计划：--dry-run（不执行）" >&2
  exit 6
fi

# 设备语义：先校验再执行（指定设备不可用 ⇒ 直接失败，不静默换台）
if [ "$PLATFORM" = "android" ]; then
  if [ -z "$DEVICE" ]; then
    echo "⚠️  流程未记录设备（模板）⇒ 按 adb 默认首台执行；建议固化到具体流程时写 --device" >&2
  else
    ONLINE="$(adb devices 2>/dev/null | awk 'NR>1 && $2=="device"{print $1}' || true)"
    FOUND=0
    while IFS= read -r d; do
      [ "$d" = "$DEVICE" ] && FOUND=1 && break
    done <<< "$ONLINE"
    if [ "$FOUND" -ne 1 ]; then
      echo "❌ 流程记录的设备不在线: ${DEVICE}" >&2
      echo "   在线设备: $(printf '%s' "$ONLINE" | tr '\n' ' ')" >&2
      echo "   （不静默换机：请接回该设备，或用 flow_save 重新固化到当前设备）" >&2
      exit 1
    fi
    export ANDROID_SERIAL="$DEVICE"
  fi
elif [ "$PLATFORM" = "ios" ]; then
  if [ -z "$DEVICE" ]; then
    echo "⚠️  流程未记录模拟器 UDID（模板）⇒ 按 booted 首台执行" >&2
  else
    BOOTED="$(xcrun simctl list devices booted 2>/dev/null || true)"
    case "$BOOTED" in
      *"$DEVICE"*) ;;
      *) echo "❌ 元数据 UDID 未 booted: ${DEVICE}" >&2
         echo "   （iOS 模拟器路径只校验不注入；请 boot 该模拟器或重新固化）" >&2
         exit 1 ;;
    esac
  fi
elif [ "$PLATFORM" = "ios-device" ]; then
  [ -n "$DEVICE" ] || { echo "❌ ios-device 流程必须记录设备 UDID" >&2; exit 1; }
  export IOS_DEVICE_UDID="$DEVICE"
  export IOS_TARGET=device
fi

# 连续失败 ≥2 ⇒ stale：回放前告警（仍允许，但回报必须注明）
if [ "${CONSEC:-0}" -ge 2 ] || [ "$STATUS" = "stale" ]; then
  echo "⚠️  该流程已连续失败 ${CONSEC} 次（状态=${STATUS}）⇒ UI 可能已漂移；失败后请回退探索并更新流程。" >&2
fi

# ---------- 执行 ----------
TS="$(date +%Y%m%d%H%M%S)"
mkdir -p "$LOG_DIR/flows" 2>/dev/null || true
BUNDLE="$LOG_DIR/flows/${NAME}-${TS}"
# 同秒并发：用 mkdir 的返回码判定是否抢到目录（check-then-mkdir 有竞态）
_n=1
until mkdir "$BUNDLE" 2>/dev/null; do
  _n=$((_n + 1))
  BUNDLE="$LOG_DIR/flows/${NAME}-${TS}-${_n}"
  if [ "$_n" -gt 50 ]; then
    echo "❌ 无法创建回放目录: ${LOG_DIR}/flows/${NAME}-${TS}*" >&2
    exit 3
  fi
done
JOURNAL="$BUNDLE/journal.jsonl"

now_ms() { python3 -c 'import time;print(int(time.time()*1000))'; }

append_journal() {  # <idx> <cmd> <rc> <ms> <logfile>
  python3 - "$JOURNAL" "$1" "$2" "$3" "$4" "$5" <<'PY'
import json, sys
path, idx, cmd, rc, ms, log = sys.argv[1:7]
entry = {"idx": int(idx), "cmd": cmd, "rc": int(rc), "ms": int(ms), "log": log}
with open(path, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(entry, ensure_ascii=False) + "\n")
PY
}

update_flow() {  # <ok|fail>
  python3 - "$FILE" "$1" <<'PY'
import json, os, sys, tempfile, time

path, mode = sys.argv[1], sys.argv[2]
d = json.load(open(path, encoding="utf-8"))
now = int(time.time())
if mode == "ok":
    d["success"] = int(d.get("success") or 0) + 1
    d["consecutive_failures"] = 0
    d["last_success_at"] = now
    d["status"] = "active"
else:
    d["failure"] = int(d.get("failure") or 0) + 1
    d["consecutive_failures"] = int(d.get("consecutive_failures") or 0) + 1
    if d["consecutive_failures"] >= 2:
        d["status"] = "stale"
d["updated_at"] = now
fd, tmp = tempfile.mkstemp(prefix=".flow_", suffix=".json", dir=os.path.dirname(path) or ".")
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    json.dump(d, fh, ensure_ascii=False, indent=1)
    fh.write("\n")
os.replace(tmp, path)
PY
}

echo "▶️  回放 ${NAME}（平台=${PLATFORM} profile=${PROFILE} 级=${GRADE} 设备=${DEVICE:-默认} 步骤=${COUNT} 起始=第 ${FROM} 步）"
[ "$OBSERVE" = "1" ] && echo "   ℹ️ 观察型流程（无断言步骤）：结论只能写「已执行」，不能声称「验证通过」"

i=0
for raw in "${STEPS[@]}"; do
  i=$((i + 1))
  if [ "$i" -lt "$FROM" ]; then
    echo "⏭  第 ${i} 步跳过（--from-step ${FROM}）"
    continue
  fi
  cmd="$(expand_platform "$raw")"
  # 一步 = 一条脚本调用：禁 shell 组合（`&` 单符号也是控制符）、重定向、命令替换、变量与路径穿越
  case "$cmd" in
    *'&'*|*'$'*|*';'*|*'|'*|*'>'*|*'<'*|*'`'*)
      echo "❌ 第 ${i} 步含 shell 组合/重定向/命令替换/变量展开（流程文件非法）: ${raw}" >&2
      exit 2 ;;
    *'..'*)
      echo "❌ 第 ${i} 步含 .. 路径穿越（流程文件非法）: ${raw}" >&2
      exit 2 ;;
  esac
  tok="$(first_token "$cmd")"
  case "$tok" in
    android/*.sh|ios/*.sh|macos/*.sh|windows/*.sh|appium/*.sh|maestro/*.sh|vision/*.py|*.sh) ;;
    *) echo "❌ 第 ${i} 步首 token 不是脚本（流程文件非法）: ${tok}" >&2; exit 2 ;;
  esac
  [ -f "$STEP_BASE/$tok" ] || { echo "❌ 第 ${i} 步脚本不存在: scripts/${tok}" >&2; exit 2; }

  # 步骤脚本按 skill scripts 目录解析（不依赖项目内同名文件）；参数原样保留。
  # 余下部分按「首个空白分词」剥离（不按 token 字面剥离：首 token 带引号时前缀匹配会错位）。
  TRIMMED="$(printf '%s' "$cmd" | sed 's/^[[:space:]]*//')"
  REST="$(printf '%s' "$TRIMMED" | sed 's/^[^[:space:]][^[:space:]]*[[:space:]]*//')"
  if [ -n "$REST" ]; then
    CMD_ABS="$STEP_BASE/$tok $REST"
  else
    CMD_ABS="$STEP_BASE/$tok"
  fi
  # 解释器显式前置：scripts/ 下多数脚本没有可执行位（既有调用形态一律 `bash <脚本>`），
  # 直接 `bash -c "<脚本> …"` 会因缺 +x 报 Permission denied（rc=126）。按扩展名选解释器。
  # `set -f`：关闭通配展开（步骤里的 `*`/`?` 原样传给脚本，不被当前目录文件替换）。
  case "$tok" in
    *.py) RUNCMD="set -f; python3 $CMD_ABS" ;;
    *)    RUNCMD="set -f; bash $CMD_ABS" ;;
  esac

  LOGF="$BUNDLE/step${i}.log"
  START=$(now_ms)
  set +e
  bash -c "$RUNCMD" > "$LOGF" 2>&1
  RC=$?
  set -e
  END=$(now_ms)
  MS=$((END - START))
  append_journal "$i" "$cmd" "$RC" "$MS" "$LOGF"

  if [ "$RC" -eq 0 ]; then
    echo "✅ 第 ${i} 步（${MS}ms）: ${cmd}"
  else
    echo "❌ 第 ${i} 步失败（rc=${RC}，${MS}ms）: ${cmd}" >&2
    echo "   日志: ${LOGF}" >&2
    echo "   ---- 日志末 15 行 ----" >&2
    tail -n 15 "$LOGF" >&2 || true
    # 自动取证：snapshot 摘要（失败也写文件，rc 记在旁边）
    SNAP="$BUNDLE/fail-snapshot.txt"
    SNAP_SH="$SCRIPT_DIR/snapshot.sh"
    if [ -n "${FLOW_STEP_DIR:-}" ] && [ -f "$FLOW_STEP_DIR/snapshot.sh" ]; then
      SNAP_SH="$FLOW_STEP_DIR/snapshot.sh"
    fi
    set +e
    bash "$SNAP_SH" --platform "$PLATFORM" --max 40 > "$SNAP" 2>&1
    SNAP_RC=$?
    set -e
    echo "   页面快照: ${SNAP}（snapshot rc=${SNAP_RC}$( [ "$SNAP_RC" -eq 3 ] && echo "，沙箱内 iOS 模拟器语义不可用 ⇒ 改用 evidence.sh / shot.sh" )）" >&2
    if [ "$FROM_TEMPLATE" = 1 ]; then
      echo "   ℹ️ 模板流程不写回计数（项目内固化后才统计）" >&2
    else
      update_flow fail || true
      python3 "$SCRIPT_DIR/_flow_index.py" "$ROOT/flows" >/dev/null 2>&1 || true
    fi
    echo "❌ 回放中断：禁止整流程重跑（防重复触发登录/提交）；已生效的步骤不要重放。" >&2
    # plan：危险词步骤续跑前须 snapshot 确认状态（不自动跑，只提示）
    _j=0; REMAIN_DANGER=0
    for _s in "${STEPS[@]}"; do
      _j=$((_j + 1))
      if [ "$_j" -le "$i" ]; then continue; fi
      if is_danger_cmd "$(expand_platform "$_s")"; then REMAIN_DANGER=1; break; fi
    done
    if [ "$REMAIN_DANGER" -eq 1 ]; then
      echo "   ⚠️ 后续仍有危险词步骤（clean/uninstall/pm clear…）⇒ 续跑前先 snapshot.sh 确认页面与产物状态。" >&2
    fi
    echo "   续跑：--from-step $((i + 1))（跳过错步）或先回退逐步探索；成功后用 flow_save 更新流程。" >&2
    echo "   journal: ${JOURNAL}" >&2
    exit 1
  fi
done

if [ "$FROM_TEMPLATE" = 1 ]; then
  echo "ℹ️ 模板流程：不写回计数（固化到项目流程库后才统计）"
else
  update_flow ok || true
  python3 "$SCRIPT_DIR/_flow_index.py" "$ROOT/flows" >/dev/null 2>&1 || true
fi
echo "✅ 回放完成：${NAME}（${COUNT} 步，自第 ${FROM} 步起；journal: ${JOURNAL}）"
[ "$OBSERVE" = "1" ] && echo "   ℹ️ 观察型流程：无断言步骤 ⇒ 只能声称「已执行」"
exit 0
