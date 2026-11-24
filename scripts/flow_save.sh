#!/bin/bash
# flow_save.sh — 把「已跑通的步骤序列」固化成可回放流程（分级 + 校验 + 项目内落点）
#
# 为什么需要本脚本（2026-11-17 立项）：
#   autoDebug 每次任务都要「逐步探索 + 每步一轮推理」，同一序列反复重跑也每次重想。
#   本脚本把成功序列存成 docs/test/debug-loop/flows/<name>.json，配合 flow_run.sh
#   一条命令回放。落点固定在项目 docs/test/（沙箱 ui profile 可写，子代理 edit 面已放行）——
#   与 pitfall_append.sh 同模式：**脚本自带落点**，不依赖 agent 自己写文档。
#
# 分级（grade）：
#   A 级 = 可免确认直跑：纯语义定位 + 断言，ui profile，android；
#   B 级 = 回放前需用户确认：命中以下任一
#     · 坐标点击（tap.sh <x> <y>）
#     · 点击关键词命中基线危险词（删除/解绑/支付…，与 tap_verify 同一来源）
#     · 步骤命令串命中扩展危险词（clean/uninstall/pm clear…）
#     · 含 --allow-danger / --allow-weak
#     · profile ≠ ui（写面/出网被放宽）
#     · 无 assert 类步骤（观察型，不能声称「验证通过」）
#     · platform = ios / ios-device / macos（降级平台，证据为截图+日志）
#
# 步骤规范形态（唯一口径，flow_run/test_flow 共用）：
#   · 相对 scripts/ 的完整路径，如 `android/run.sh`、`assert_page.sh`、`maestro/flow.sh`
#   · 跨平台流程写 `<platform>/<script>.sh`，回放时按元数据 platform 展开（ios-device→ios）
#   · 禁 env 前缀 / cd / && / ; / 管道 / 重定向 / 命令替换；一步 = 一条脚本调用
#
# 用法:
#   flow_save.sh --name 登录冒烟 --platform android --profile ui --device <serial> \
#                --precond "已装 App，允许清数据" \
#                --step "android/run.sh" \
#                --step "tap_verify.sh 登录 --expect has:首页" \
#                --step "assert_page.sh --has 首页"
#   flow_save.sh --name <名> ... --steps <步骤文件>     # 一行一步，# 开头为注释
#
# 选项:
#   --name <名>      流程名（[A-Za-z0-9._-]+，拒 . / ..；同名覆盖并留 .bak 时间戳）
#   --platform <P>   android | ios | ios-device | macos
#   --profile <P>    ui | build | ios | macos（回放时 safe_run 用哪个 profile 由调用方传）
#   --device <D>     设备标识：Android serial / iOS UDID / macOS 写 local（必填）
#   --precond <文本> 起始状态前提（登录页/已登录/是否允许清数据）；缺省「未声明」
#   --step <cmd>     步骤（可重复）或 --steps <文件>（一行一步）
#   --note <文本>    备注（可选）
#   --root <目录>    落点根，缺省 docs/test/debug-loop
#
# 退出码: 0 已固化 / 2 用法或校验失败 / 3 无法写入或项目根不对
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_danger_words.sh"

NAME=""; PLATFORM=""; PROFILE="ui"; DEVICE=""; PRECOND=""; NOTE=""
STEPS_FILE=""; ROOT="docs/test/debug-loop"
STEPS=()

usage() {
  awk 'NR < 3 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"
}

die_usage() { echo "❌ $1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --name)     [ $# -ge 2 ] || die_usage "--name 缺参数值";     NAME="$2"; shift 2 ;;
    --platform) [ $# -ge 2 ] || die_usage "--platform 缺参数值"; PLATFORM="$2"; shift 2 ;;
    --profile)  [ $# -ge 2 ] || die_usage "--profile 缺参数值";  PROFILE="$2"; shift 2 ;;
    --device)   [ $# -ge 2 ] || die_usage "--device 缺参数值";   DEVICE="$2"; shift 2 ;;
    --precond)  [ $# -ge 2 ] || die_usage "--precond 缺参数值";  PRECOND="$2"; shift 2 ;;
    --note)     [ $# -ge 2 ] || die_usage "--note 缺参数值";     NOTE="$2"; shift 2 ;;
    --step)     [ $# -ge 2 ] || die_usage "--step 缺参数值";     STEPS+=("$2"); shift 2 ;;
    --steps)    [ $# -ge 2 ] || die_usage "--steps 缺参数值";    STEPS_FILE="$2"; shift 2 ;;
    --root)     [ $# -ge 2 ] || die_usage "--root 缺参数值";     ROOT="$2"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    -*) echo "❌ 未知参数: $1" >&2; exit 2 ;;
    *)  die_usage "未知参数: $1" ;;
  esac
done

# ---------- 基础校验 ----------
# 标量字段必须是单行：flow_run 按 `键=值` 逐行解析元数据，多行值可伪造额外键（如 precond 里写 grade=A）
for _v in "$PLATFORM" "$PROFILE" "$DEVICE" "$PRECOND" "$NOTE" "$ROOT"; do
  case "$_v" in
    *$'\n'*|*$'\r'*) die_usage "参数值不得含换行/回车（会把元数据解析成额外键）" ;;
  esac
done
[ -n "$NAME" ] || die_usage "需要 --name <流程名>"
[ -n "$PLATFORM" ] || die_usage "需要 --platform <android|ios|ios-device|macos>"
[ -n "$DEVICE" ] || die_usage "需要 --device <设备标识>（macOS 写 local）"
case "$NAME" in
  .|..) die_usage "流程名不能是 '.' 或 '..'" ;;
  *[!A-Za-z0-9._-]*) die_usage "流程名只允许 字母/数字/点/下划线/连字符（收到: ${NAME}）" ;;
esac
case "$PLATFORM" in
  android|ios|ios-device|macos) ;;
  *) die_usage "--platform 只支持 android|ios|ios-device|macos（收到: ${PLATFORM}）" ;;
esac
case "$PROFILE" in
  ui|build|ios|macos) ;;
  *) die_usage "--profile 只支持 ui|build|ios|macos（收到: ${PROFILE}）" ;;
esac
case "$ROOT" in
  /*) die_usage "--root 必须相对项目根（收到绝对路径: ${ROOT}）" ;;
  *..*) die_usage "--root 不得含 ..（收到: ${ROOT}）" ;;
esac

# 项目根判据：与既有脚本家族一致（按 $PWD 找 .debug.env）
if [ ! -f ".debug.env" ]; then
  echo "❌ 请在项目根执行（当前目录无 .debug.env）" >&2
  echo "   autoDebug 档不能自举：缺 .debug.env 时由主 agent / 人工运行 init.sh" >&2
  exit 3
fi

# ---------- 步骤收集 ----------
if [ -n "$STEPS_FILE" ]; then
  [ -f "$STEPS_FILE" ] || die_usage "--steps 文件不存在: ${STEPS_FILE}"
  _ln=0
  while IFS= read -r line || [ -n "$line" ]; do
    _ln=$((_ln + 1))
    line="${line%$'\r'}"
    line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    case "$line" in \#*) continue ;; esac
    STEPS+=("$line")
  done < "$STEPS_FILE"
fi
[ "${#STEPS[@]}" -gt 0 ] || die_usage "至少给一个 --step 或 --steps <文件>"

# ---------- 步骤校验 ----------
# 平台目录映射：ios-device 的设备侧脚本仍在 ios/ 下
case "$PLATFORM" in
  android)   PLAT_DIR="android" ;;
  ios)       PLAT_DIR="ios" ;;
  ios-device) PLAT_DIR="ios" ;;
  macos)     PLAT_DIR="macos" ;;
  *)         PLAT_DIR="" ;;
esac

expand_platform() {
  printf '%s' "$1" | sed "s#<platform>#${PLAT_DIR}#g"
}

# 取首 token（脚本相对路径）
first_token() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  case "$s" in
    \"*) s="${s#\"}"; printf '%s' "${s%%\"*}" ;;
    \'*) s="${s#\'}"; printf '%s' "${s%%\'*}" ;;
    *)   printf '%s' "${s%%[[:space:]]*}" ;;
  esac
}

# 脚本白名单：scripts/ 下真实存在的 .sh（允许子目录）
check_script_token() {
  local tok="$1"
  case "$tok" in
    *'..'*) echo "❌ 步骤不得含 .. 路径：${tok}" >&2; exit 2 ;;
    */)     echo "❌ 步骤首 token 不是脚本：${tok}" >&2; exit 2 ;;
  esac
  case "$tok" in
    android/*.sh|ios/*.sh|macos/*.sh|windows/*.sh|appium/*.sh|maestro/*.sh|vision/*.py|*.sh) ;;
    *) echo "❌ 步骤首 token 必须是 scripts/ 下的脚本（收到: ${tok}）" >&2
       echo "   规范形态：android/run.sh、tap_verify.sh、assert_page.sh、maestro/flow.sh …" >&2
       echo "   禁止 env 前缀 / cd / bash -c / 裸命令" >&2
       exit 2 ;;
  esac
  [ -f "$SCRIPT_DIR/$tok" ] || { echo "❌ 脚本不存在: scripts/${tok}" >&2; exit 2; }
}

# 非语义步骤白名单（ios / ios-device / macos 降级平台只收这些）
is_nonsemantic() {
  case "$1" in
    ios/run.sh|ios/shot.sh|ios/logs.sh|ios/logclear.sh|ios/install.sh) return 0 ;;
    macos/run.sh|macos/shot.sh|macos/logs.sh) return 0 ;;
    appium/tap.sh|appium/assert.sh|appium/flow.sh) return 0 ;;
  esac
  return 1
}

# 坐标点击判定：`tap.sh <整数> <整数>`（tap.sh 的坐标形态；--text 形态不算）
has_coord_tap() {
  local s="$1" rest
  case "$s" in
    *"tap.sh "*) rest="${s#*"tap.sh "}" ;;
    *) return 1 ;;
  esac
  set -f
  set -- $rest
  set +f
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  case "${2:-}" in ''|*[!0-9]*) return 1 ;; esac
  return 0
}
# 第一个空白分隔词（本地关闭 glob，防关键词里的 [ ] * 被展开）
first_word() {
  local s="$1"
  set -f
  set -- $s
  set +f
  printf '%s' "${1:-}"
}

# 点击关键词提取（用于基线危险词判定）
click_keyword() {
  local s="$1" rest=""
  # 顺序敏感：--text 形态先判，避免被 `tap.sh ` 前缀吞掉
  if [ -z "$rest" ]; then case "$s" in *"tap.sh --text "*) rest="${s#*"tap.sh --text "}" ;; esac; fi
  if [ -z "$rest" ]; then case "$s" in *"tap_verify.sh "*) rest="${s#*"tap_verify.sh "}" ;; esac; fi
  if [ -z "$rest" ]; then case "$s" in *"tap_snapshot.sh "*) rest="${s#*"tap_snapshot.sh "}" ;; esac; fi
  if [ -z "$rest" ]; then case "$s" in *"findtap.sh "*) rest="${s#*"findtap.sh "}" ;; esac; fi
  if [ -z "$rest" ]; then case "$s" in *"maestro/tap.sh "*) rest="${s#*"maestro/tap.sh "}" ;; esac; fi
  [ -n "$rest" ] || { printf ''; return 0; }
  local kw
  kw="$(first_word "$rest")"
  kw="${kw#\"}"; kw="${kw%\"}"; kw="${kw#\'}"; kw="${kw%\'}"
  printf '%s' "$kw"
}

GRADE_A=1; OBSERVE_ONLY=0; ASSERT_SEEN=0; HAS_COORD=0; HAS_DANGER=0; HAS_ALLOW=0
i=0
for raw in "${STEPS[@]}"; do
  i=$((i + 1))
  step="$(expand_platform "$raw")"
  # 秘密纪律：<secret:KEY> 只是任务书约定，可执行步骤里必须是 --text-from
  # （必须排在形态守卫之前：`<secret:` 自带 `<`，否则会被通用重定向守卫抢先拒收、专属指引永不显示）
  case "$step" in
    *'<secret:'*)
      echo "❌ 第 ${i} 步含 <secret:…> 引用（无解析实现）—— 凭据一律用 --text-from .debug-login.secret --key …" >&2; exit 2 ;;
  esac
  # 形态守卫：一步一条脚本调用，禁 shell 组合（含单 `&`）、重定向、命令替换、变量展开、路径穿越、控制字符
  case "$step" in
    *'&'*|*'$'*|*';'*|*'|'*|*'>'*|*'<'*|*'`'*)
      echo "❌ 第 ${i} 步含 shell 组合/重定向/命令替换/变量展开（禁止）：${raw}" >&2; exit 2 ;;
    *$'\t'*|*$'\n'*|*$'\r'*)
      echo "❌ 第 ${i} 步含制表符/换行等控制字符（禁止；一步=一条单行脚本调用）：${raw}" >&2; exit 2 ;;
    *'..'*)
      echo "❌ 第 ${i} 步含 .. 路径穿越（禁止）：${raw}" >&2; exit 2 ;;
  esac
  # 明文秘密：`--mask` 只是掩码开关，不带它同样会把明文写进流程库 ⇒ 敏感字段一律要求 --text-from
  case "$step" in
    *' --text '*)
      _lower="$(printf '%s' "$step" | tr '[:upper:]' '[:lower:]')"
      case "$_lower" in
        *密码*|*passcode*|*password*|*验证码*|*otp*|*secret*|*token*)
          echo "❌ 第 ${i} 步对敏感字段用了明文 --text（流程库/argv/journal 会留痕）：改用 --text-from .debug-login.secret --key <角色> [--mask]" >&2
          exit 2 ;;
      esac ;;
  esac
  case "$step" in
    *'--mask'*)
      case "$step" in
        *'--text-from'*) ;;
        *) echo "❌ 第 ${i} 步用了 --mask 但没有 --text-from（密码必须走凭据文件，禁止 --text 明文）" >&2; exit 2 ;;
      esac ;;
  esac
  tok="$(first_token "$step")"
  check_script_token "$tok"
  if [ "$PLATFORM" != "android" ]; then
    if ! is_nonsemantic "$tok"; then
      echo "❌ ${PLATFORM} 流程只收非语义步骤（run/shot/logs/logclear/install）；拒绝: ${tok}" >&2
      echo "   语义断言在沙箱内不可用（iOS 模拟器 rc=3；macOS 属实验路径）⇒ 取证走 evidence.sh 单命令" >&2
      exit 2
    fi
    GRADE_A=0
  fi
  # 坐标点击
  if has_coord_tap "$step"; then HAS_COORD=1; GRADE_A=0; fi
  # 危险词（基线=点击关键词；扩展=整条命令串）
  kw="$(click_keyword "$step")"
  if [ -n "$kw" ] && is_danger_base "$kw"; then HAS_DANGER=1; GRADE_A=0; fi
  if is_danger_cmd "$step"; then HAS_DANGER=1; GRADE_A=0; fi
  case "$step" in
    *'--allow-danger'*|*'--allow-weak'*) HAS_ALLOW=1; GRADE_A=0 ;;
  esac
  # 断言步骤（决定观察型）
  case "$tok" in
    assert_page.sh|maestro/assert.sh|maestro/assert_batch.sh|appium/assert.sh|macos/smart_assert.sh)
      ASSERT_SEEN=1 ;;
  esac
  case "$step" in
    *'--expect has:'*) ASSERT_SEEN=1 ;;
  esac
done

[ "$PROFILE" = "ui" ] || GRADE_A=0
if [ "$ASSERT_SEEN" -eq 0 ]; then GRADE_A=0; OBSERVE_ONLY=1; fi
if [ "$GRADE_A" -eq 1 ]; then GRADE="A"; else GRADE="B"; fi

# ---------- 落盘 ----------
mkdir -p "$ROOT/flows" 2>/dev/null || { echo "❌ 无法创建目录: ${ROOT}/flows" >&2; exit 3; }
FILE="$ROOT/flows/$NAME.json"
BAK=""
if [ -f "$FILE" ]; then
  _bts="$(date +%Y%m%d%H%M%S)"
  BAK="$FILE.bak.$_bts"
  _bn=1
  while [ -e "$BAK" ]; do
    _bn=$((_bn + 1))
    BAK="$FILE.bak.${_bts}-${_bn}"
  done
  cp "$FILE" "$BAK" 2>/dev/null || { echo "⚠️  旧版本备份失败（继续写入）: ${BAK}" >&2; BAK=""; }
fi

STEPS_JSON="$(python3 - "${STEPS[@]}" <<'PY'
import json, sys
print(json.dumps(sys.argv[1:], ensure_ascii=False))
PY
)" || { echo "❌ 步骤序列化失败" >&2; exit 3; }

# 保留旧计数（同名覆盖不清零证据），其余字段以本次为准
OLD_JSON=""
[ -f "$FILE" ] && OLD_JSON="$FILE"

python3 - "$FILE" "$NAME" "$PLATFORM" "$PROFILE" "$DEVICE" "$PRECOND" "$NOTE" \
  "$GRADE" "$OBSERVE_ONLY" "$STEPS_JSON" "$OLD_JSON" <<'PY'
import json, os, sys, tempfile, time

(path, name, platform, profile, device, precond, note,
 grade, observe, steps_json, old_path) = sys.argv[1:12]

steps = json.loads(steps_json)
now = int(time.time())
success = failure = consecutive = 0
created = now
last_success = None
if old_path and os.path.exists(old_path):
    try:
        old = json.load(open(old_path, encoding="utf-8"))
        if isinstance(old, dict):
            success = int(old.get("success") or 0)
            failure = int(old.get("failure") or 0)
            consecutive = int(old.get("consecutive_failures") or 0)
            created = int(old.get("created_at") or now)
            last_success = old.get("last_success_at")
    except Exception:
        pass

data = {
    "version": 1,
    "name": name,
    "platform": platform,
    "profile": profile,
    "device": device,
    "precond": precond or "未声明",
    "note": note or "",
    "grade": grade,
    "observe_only": observe == "1",
    "steps": steps,
    "created_at": created,
    "updated_at": now,
    "last_success_at": last_success,
    "success": success,
    "failure": failure,
    "consecutive_failures": consecutive,
    "status": "active",
}
# 原子写：同目录临时文件 + mv（并发固化不产生半截 JSON）
fd, tmp = tempfile.mkstemp(prefix=".flow_", suffix=".json", dir=os.path.dirname(path) or ".")
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    json.dump(data, fh, ensure_ascii=False, indent=1)
    fh.write("\n")
os.replace(tmp, path)
PY

# 索引重建（与 flow_run 共用 _flow_index.py，格式单一来源）
python3 "$SCRIPT_DIR/_flow_index.py" "$ROOT/flows" >/dev/null || { echo "❌ 索引重建失败" >&2; exit 3; }

if [ ! -f "$FILE" ]; then
  echo "❌ 写入失败: ${FILE}" >&2
  exit 3
fi
# 回读校验（防静默落到别的目录：cwd 不是项目根时 .debug.env 判据已挡，但仍复核文件可解析）
python3 - "$FILE" <<'PY' || { echo "❌ 写入后回读校验失败: $FILE" >&2; exit 3; }
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert isinstance(d, dict) and d.get("name")
PY

echo "✅ 已固化: ${FILE}（级=${GRADE}$( [ "$OBSERVE_ONLY" = "1" ] && echo "，观察型：无断言步骤" )）"
echo "   平台=${PLATFORM} profile=${PROFILE} 设备=${DEVICE} 步骤=${#STEPS[@]}"
echo "   回放: bash <S>/scripts/flow_run.sh --name ${NAME}$( [ "$GRADE" = "B" ] && echo "（B 级需先获用户同意，再加 --allow-confirm）" )"
[ -n "$BAK" ] && echo "   旧版本备份: ${BAK}"
exit 0
