#!/bin/bash
# test_interact.sh — 输入/点击回执/坑表 的离线回归（adb 桩模拟设备，不需真机）
#
# 用法:
#   bash <S>/scripts/test_interact.sh [-v] [-f <关键字>]
#
# 退出码: 0=全部通过 / 1=有用例失败 / 2=用法错误
#
# 覆盖点:
#   _field_target 纯函数（清空次数/掩码下限/读回比对）
#   android/input.sh 退出码 0/1/2/3/4/5/6/7/8 与 --dry-run/--append/--clear-only/--mask/--text-from
#   tap_verify.sh rc=0/1/2/3 与「页面已变不再点」「危险词禁二击」「--allow-danger」
#   pitfall_append.sh 追加/去重/用法错/竖线转义
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"

VERBOSE=0; FILTER=""
while [ $# -gt 0 ]; do
  case "$1" in
    -v) VERBOSE=1; shift ;;
    -f) [ $# -ge 2 ] || { echo "❌ -f 需带关键字" >&2; exit 2; }; FILTER="$2"; shift 2 ;;
    -h|--help) awk 'NR < 3 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; exit 0 ;;
    *) echo "❌ 未知参数: $1" >&2; exit 2 ;;
  esac
done

PASS=0; FAIL=0; FAILED_CASES=()
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/dbginteract.XXXXXX")"
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

expect_rc() {
  local name="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then PASS=$((PASS+1)); printf '  ✅ %s\n' "$name"
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$name"); printf '  ❌ %s（期望 rc=%s，实际 rc=%s）\n' "$name" "$want" "$got"; fi
}
expect_contains() {
  local name="$1" needle="$2" out="$3"
  case "$out" in *"$needle"*) PASS=$((PASS+1)); printf '  ✅ %s\n' "$name" ;;
    *) FAIL=$((FAIL+1)); FAILED_CASES+=("$name"); printf '  ❌ %s（输出未含「%s」）\n' "$name" "$needle" ;; esac
}
expect_not_contains() {
  local name="$1" needle="$2" out="$3"
  case "$out" in *"$needle"*) FAIL=$((FAIL+1)); FAILED_CASES+=("$name"); printf '  ❌ %s（输出不该含「%s」）\n' "$name" "$needle" ;;
    *) PASS=$((PASS+1)); printf '  ✅ %s\n' "$name" ;; esac
}
expect_eq() {
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then PASS=$((PASS+1)); printf '  ✅ %s\n' "$name"
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$name"); printf '  ❌ %s（期望「%s」，实际「%s」）\n' "$name" "$want" "$got"; fi
}
run_case() { case "$1" in *"$FILTER"*) return 0 ;; *) return 1 ;; esac; }

# ---------- adb 桩（会改写 ui.xml，模拟「输入真的落到控件里」） ----------
mkdir -p "$TMPROOT/bin"
cat > "$TMPROOT/bin/adb" <<'STUB'
#!/bin/bash
STATE="${AB_STATE:-}"
if [ "${1:-}" = "devices" ]; then
  if [ "${AB_NO_DEVICE:-0}" = "1" ]; then printf 'List of devices attached\n\n'
  else printf 'List of devices attached\nemulator-5554\tdevice\n'; fi
  exit 0
fi
if [ "${1:-}" = "-s" ]; then shift 2; fi
cmd="${1:-}"; shift || true

_edit_node() {  # <clear|append:…|set:…>
  python3 - "$STATE/ui.xml" "$1" <<'PY'
import re, sys
p, mode = sys.argv[1], sys.argv[2]
s = open(p, encoding="utf-8").read()


def repl(m):
    tag = m.group(0)
    cur = re.search(r'text="([^"]*)"', tag)
    cur = cur.group(1) if cur else ""
    if mode == "clear":
        new = ""
    elif mode.startswith("append:"):
        new = cur + mode[len("append:"):]
    elif mode.startswith("set:"):
        new = mode[len("set:"):]
    else:
        new = cur
    if 'text="' in tag:
        tag = re.sub(r'text="[^"]*"', 'text="%s"' % new, tag, count=1)
    else:
        tag = tag.replace("<node", '<node text="%s"' % new, 1)
    return tag


s = re.sub(r'<node[^>]*resource-id="account"[^>]*>', repl, s)
open(p, "w", encoding="utf-8").write(s)
PY
}

_handle_text() {  # <原始命令串里的文本部分>
  local raw="$1" val
  raw="${raw# }"
  raw="${raw#\'}"; raw="${raw%\'}"
  val="${raw//%s/ }"
  if [ "${AB_MASK_HIDE:-0}" = "1" ]; then
    val="$(python3 -c 'import sys;print("\u2022" * len(sys.argv[1]))' "$val")"
  fi
  [ "${AB_DROP_LAST:-0}" = "1" ] && val="${val%?}"
  if [ "${AB_EMPTY_ON_TEXT:-0}" = "1" ]; then
    # 输入后语义树变空（导航中间态）⇒ 校验阶段应 rc=4，不能混成「读回不符 rc=6」
    cat > "$STATE/ui.xml" <<'XML'
<?xml version='1.0' encoding='UTF-8' standalone='yes' ?>
<hierarchy rotation="0">
  <node index="0" text="" resource-id="" class="android.view.View" package="com.example.demo" clickable="false" bounds="[0,0][1080,1920]" />
</hierarchy>
XML
    return 0
  fi
  _edit_node "append:${val}"
}

case "$cmd" in
  shell)
    sub="${1:-}"; shift || true
    # `adb shell "input text '…'"` 是**整串一条命令**（与分开传参的其余调用不同）
    case "$sub" in
      "input text"*) _handle_text "${sub#input text}"; exit 0 ;;
    esac
    case "$sub" in
      getprop) echo "arm64-v8a" ;;
      pidof)   echo "4242" ;;
      uiautomator)
        # AB_BREAK_DUMP=1 且已点过 ⇒ 之后 dump 一律失败，用于验证「无法判定 ⇒ 不重点」
        [ -f "$STATE/broken" ] && exit 1
        echo "UI hierarchy dumped to: /sdcard/ui_snapshot.xml" ;;
      rm) : ;;
      input)
        act="${1:-}"; shift || true
        case "$act" in
          tap)
            [ "${AB_FAIL_TAP:-0}" = "1" ] && exit 1
            printf '%s\n' "$*" >> "$STATE/taps"
            [ "${AB_BREAK_DUMP:-0}" = "1" ] && : > "$STATE/broken"
            case "${AB_TAP_EFFECT:-0}" in
              1)
                # 目标页出现（节点数 +1，目标仍在）⇒ 强判据通过
                python3 - "$STATE/ui.xml" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
if "首页" not in s:
    s = s.replace("</hierarchy>", '<node index="9" text="首页" class="android.widget.TextView" package="com.example.demo" clickable="false" bounds="[0,0][100,100]" /></hierarchy>')
open(p, "w", encoding="utf-8").write(s)
PY
                ;;
              2)
                # 整页换成只剩「首页」⇒ 目标节点消失（强判据：target_gone）
                python3 - "$STATE/ui.xml" <<'PY'
import sys
p = sys.argv[1]
open(p, "w", encoding="utf-8").write(
    "<?xml version='1.0' encoding='UTF-8' standalone='yes' ?>\n"
    '<hierarchy rotation="0">\n'
    '  <node index="0" text="首页" resource-id="" class="android.widget.TextView"'
    ' package="com.example.demo" content-desc="" clickable="false" bounds="[0,0][1080,1920]" />\n'
    '</hierarchy>\n'
)
PY
                ;;
              3)
                # 只改一个非目标节点的文本（节点数与目标都不变）⇒ **仅弱证据**（text_changed）
                python3 - "$STATE/ui.xml" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
s = re.sub(r'(text=")提交(")', r'\1提交x\2', s, count=1)
open(p, "w", encoding="utf-8").write(s)
PY
                ;;
            esac
            exit 0 ;;
          keyevent)
            # 真机语义：不带键码的 `input keyevent` 会报错。桩必须同样失败，
            # 否则 do_clear 的 n=0 缺陷在测试里永远看不到（2026-11-12 复审 P1#6）
            [ $# -gt 0 ] || exit 255
            printf '%s\n' "$*" >> "$STATE/keys"
            if printf '%s' "$*" | grep -q 67; then
              [ "${AB_CLEAR_FAIL:-0}" = "1" ] || _edit_node clear
            fi
            exit 0 ;;
        esac
        ;;
      dumpsys)
        if [ "${AB_NO_FOCUS:-0}" = "1" ]; then echo "mInputShown=false"
        elif [ "${AB_NO_FOCUS:-0}" = "2" ]; then echo "InputMethodService state: mCurMethodId=com.example.ime/.Svc"
        else echo "mInputShown=true"; fi ;;
    esac
    exit 0 ;;
  pull)
    dst="${2:-}"
    cp "$STATE/ui.xml" "$dst" 2>/dev/null || exit 1
    exit 0 ;;
  exec-out) printf '\211PNG\r\n\032\nFAKEPNG' ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$TMPROOT/bin/adb"

# ---------- 夹具 ----------
mk_proj() {  # <名字> → 目录
  local p="$TMPROOT/$1"
  mkdir -p "$p"
  printf 'name: fake\n' > "$p/pubspec.yaml"
  printf 'ANDROID_APP_ID=com.example.demo\n' > "$p/.debug.env"
  echo "$p"
}

fresh_state() {  # [account_text] → 状态目录（内含 ui.xml/taps/keys）
  local state
  state="$TMPROOT/state.$RANDOM$RANDOM"
  mkdir -p "$state"
  : > "$state/taps"; : > "$state/keys"
  cat > "$state/ui.xml" <<XML
<?xml version='1.0' encoding='UTF-8' standalone='yes' ?>
<hierarchy rotation="0">
  <node index="0" text="" resource-id="" class="android.widget.FrameLayout" package="com.example.demo" content-desc="" clickable="false" bounds="[0,0][1080,1920]">
    <node index="0" text="${1:-}" resource-id="account" class="android.widget.EditText" package="com.example.demo" content-desc="" clickable="true" bounds="[100,400][980,500]" />
    <node index="1" text="登录" resource-id="btn_login" class="android.widget.Button" package="com.example.demo" content-desc="" clickable="true" bounds="[100,600][980,700]" />
    <node index="2" text="提交" resource-id="btn_submit" class="android.widget.Button" package="com.example.demo" content-desc="" clickable="true" bounds="[100,800][980,900]" />
  </node>
</hierarchy>
XML
  echo "$state"
}

empty_tree_xml() {
  local f="$TMPROOT/empty.$RANDOM.xml"
  cat > "$f" <<'XML'
<?xml version='1.0' encoding='UTF-8' standalone='yes' ?>
<hierarchy rotation="0">
  <node index="0" text="" resource-id="" class="android.view.View" package="com.example.demo" clickable="false" bounds="[0,0][1080,1920]" />
</hierarchy>
XML
  echo "$f"
}

acct_text() {  # <ui.xml> → account 节点的 text
  python3 - "$1" <<'PY'
import re, sys
s = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'<node[^>]*resource-id="account"[^>]*>', s)
if not m:
    print("<no-node>")
else:
    t = re.search(r'text="([^"]*)"', m.group(0))
    print(t.group(1) if t else "")
PY
}

run_in() {  # <项目目录> <状态目录> <额外env...> -- <命令...>
  local proj="$1" state="$2"; shift 2
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  ( cd "$proj" && env AB_STATE="$state" PATH="$TMPROOT/bin:$PATH" ${envs[@]+"${envs[@]}"} "$@" )
}

echo "🧪 输入/点击回执/坑表 回归（离线 adb 桩）"
echo ""

# ---------- I1 纯函数 ----------
if run_case "I1-pure"; then
  echo "--- I1 _field_target 纯函数 ---"
  OUT=$(python3 - "$SCRIPT_DIR" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import _field_target as f
print(f.plan_clear(""))
print(f.plan_clear("abc"))
print(f.plan_clear("x" * 100))
print(f.plan_clear("", mask=True))
print(f.verify("a", "a"), f.verify("a", "b"), f.verify("ab", "cd", mask=True))
print("append:", f.verify("abc", "oldabc", append=True), f.verify("abc", "oldab", append=True))
print("append+mask:", f.verify("abc", "oldabcd", mask=True, append=True),
      f.verify("abc", "ol", mask=True, append=True))
PY
)
  expect_contains "I1 空值不清空" "(0, 0)" "$OUT"
  expect_contains "I1 3 字符删 6 次" "(6, 3)" "$OUT"
  expect_contains "I1 超长截断到 64" "(64, 100)" "$OUT"
  expect_contains "I1 掩码空值保底 12" "(12, 0)" "$OUT"
  expect_contains "I1 verify 三种情形" "True False True" "$OUT"
  expect_contains "I1 append 只判后缀" "append: True False" "$OUT"
  expect_contains "I1 append+mask 只判不短于" "append+mask: True False" "$OUT"
fi

# ---------- I2 input.sh 用法与取值 ----------
if run_case "I2-usage"; then
  echo "--- I2 input.sh 用法/取值（rc=2/8） ---"
  P=$(mk_proj i2); S=$(fresh_state)
  OUT=$(run_in "$P" "$S" -- bash "$SCRIPT_DIR/android/input.sh" 2>&1); RC=$?
  expect_rc "I2 缺 --field → rc=2" 2 "$RC"
  OUT=$(run_in "$P" "$S" -- bash "$SCRIPT_DIR/android/input.sh" --field account --text a --text-stdin 2>&1); RC=$?
  expect_rc "I2 两种取值来源 → rc=2" 2 "$RC"
  OUT=$(run_in "$P" "$S" -- bash "$SCRIPT_DIR/android/input.sh" --field account --clear-only --text a 2>&1); RC=$?
  expect_rc "I2 --clear-only 与 --text 冲突 → rc=2" 2 "$RC"
  OUT=$(run_in "$P" "$S" -- bash "$SCRIPT_DIR/android/input.sh" --field account --text '密码123' 2>&1); RC=$?
  expect_rc "I2 非 ASCII → rc=8" 8 "$RC"
  expect_contains "I2 提示改走 Maestro" "Maestro" "$OUT"

  printf 'PASSWORD=abc123\n' > "$P/secret600"; chmod 600 "$P/secret600"
  S=$(fresh_state)
  OUT=$(run_in "$P" "$S" -- bash "$SCRIPT_DIR/android/input.sh" --field account --text-from "$P/secret600" --key PASSWORD 2>&1); RC=$?
  expect_rc "I2 0600 凭据文件可用 → rc=0" 0 "$RC"
  expect_contains "I2 输出不回显明文" "****" "$OUT"
  expect_not_contains "I2 stdout 不含明文密码" "abc123" "$OUT"

  printf 'PASSWORD=abc123\n' > "$P/secret644"; chmod 644 "$P/secret644"
  S=$(fresh_state)
  OUT=$(run_in "$P" "$S" -- bash "$SCRIPT_DIR/android/input.sh" --field account --text-from "$P/secret644" 2>&1); RC=$?
  expect_rc "I2 权限非 600 → rc=2" 2 "$RC"
  expect_contains "I2 给出 chmod 指引" "chmod 600" "$OUT"
fi

# ---------- I3 input.sh 主路径 ----------
if run_case "I3-flow"; then
  echo "--- I3 input.sh 主路径（rc=0/1/5/6/7 + append/mask/dry-run） ---"
  P=$(mk_proj i3)

  S=$(fresh_state)
  OUT=$(run_in "$P" "$S" -- bash "$SCRIPT_DIR/android/input.sh" --field account --text abc 2>&1); RC=$?
  expect_rc "I3 空字段输入 abc → rc=0" 0 "$RC"
  expect_eq   "I3 设备侧 text 变成 abc" "abc" "$(acct_text "$S/ui.xml")"
  expect_eq   "I3 未发生删除（无需清空）" "" "$(cat "$S/keys")"
  expect_eq   "I3 只点了一次输入框" "1" "$(wc -l < "$S/taps" | tr -d ' ')"

  S=$(fresh_state "old")
  OUT=$(run_in "$P" "$S" -- bash "$SCRIPT_DIR/android/input.sh" --field account --text abc 2>&1); RC=$?
  expect_rc "I3 脏内容 → 清空后输入 rc=0" 0 "$RC"
  expect_contains "I3 发过删除键" "67" "$(cat "$S/keys")"
  expect_eq   "I3 设备侧是 abc（不是 oldabc）" "abc" "$(acct_text "$S/ui.xml")"

  S=$(fresh_state "old")
  OUT=$(run_in "$P" "$S" -- bash "$SCRIPT_DIR/android/input.sh" --field account --text abc --append 2>&1); RC=$?
  expect_rc "I3 --append → rc=0" 0 "$RC"
  expect_eq   "I3 --append 保留旧内容" "oldabc" "$(acct_text "$S/ui.xml")"

  S=$(fresh_state)
  OUT=$(run_in "$P" "$S" -- bash "$SCRIPT_DIR/android/input.sh" --field nosuchfield --text abc 2>&1); RC=$?
  expect_rc "I3 未找到输入框 → rc=1" 1 "$RC"
  expect_contains "I3 附候选清单" "候选" "$OUT"

  # --id 只匹配 id：命中 resource-id 才成功；用文本去匹配 id 必须失败
  S=$(fresh_state)
  OUT=$(run_in "$P" "$S" -- bash "$SCRIPT_DIR/android/input.sh" --id account --text abc 2>&1); RC=$?
  expect_rc "I3 --id account → rc=0" 0 "$RC"
  expect_eq   "I3 --id 命中同一输入框" "abc" "$(acct_text "$S/ui.xml")"
  S=$(fresh_state)
  OUT=$(run_in "$P" "$S" -- bash "$SCRIPT_DIR/android/input.sh" --id 登录 --text abc 2>&1); RC=$?
  expect_rc "I3 --id 不看 text（用文案匹配 → rc=1）" 1 "$RC"

  # 校验阶段语义树为空（重取后仍空）⇒ rc=4，不是 rc=6
  S=$(fresh_state)
  OUT=$(run_in "$P" "$S" AB_EMPTY_ON_TEXT=1 -- bash "$SCRIPT_DIR/android/input.sh" --field account --text abc 2>&1); RC=$?
  expect_rc "I3 校验阶段空树 → rc=4" 4 "$RC"
  expect_contains "I3 空树提示 Semantics" "Semantics" "$OUT"

  S=$(fresh_state)
  OUT=$(run_in "$P" "$S" -- bash "$SCRIPT_DIR/android/input.sh" --field account --text abc --dry-run 2>&1); RC=$?
  expect_rc "I3 --dry-run → rc=0" 0 "$RC"
  expect_eq   "I3 --dry-run 不产生点击" "" "$(cat "$S/taps")"

  S=$(fresh_state)
  OUT=$(run_in "$P" "$S" -- bash "$SCRIPT_DIR/android/input.sh" --field account --clear-only 2>&1); RC=$?
  expect_rc "I3 --clear-only（本来就空）→ rc=0" 0 "$RC"

  S=$(fresh_state "old")
  OUT=$(run_in "$P" "$S" AB_CLEAR_FAIL=1 -- bash "$SCRIPT_DIR/android/input.sh" --field account --clear-only 2>&1); RC=$?
  expect_rc "I3 清空失败 → rc=5" 5 "$RC"

  # --mask 不能污染读回：掩码字段清空失败时，若读回也按掩码置空就会假报「已清空」（假绿）
  S=$(fresh_state "old")
  OUT=$(run_in "$P" "$S" AB_CLEAR_FAIL=1 -- bash "$SCRIPT_DIR/android/input.sh" --field account --clear-only --mask 2>&1); RC=$?
  expect_rc "I3 --mask --clear-only 清空失败仍 → rc=5" 5 "$RC"

  # 焦点状态拿不到 mInputShown 字段（部分 ROM）⇒ 只告警，不阻断正常输入
  S=$(fresh_state)
  OUT=$(run_in "$P" "$S" AB_NO_FOCUS=2 -- bash "$SCRIPT_DIR/android/input.sh" --field account --text abc 2>&1); RC=$?
  expect_rc "I3 无 mInputShown 字段 → 继续执行 rc=0" 0 "$RC"
  expect_eq   "I3 无字段时仍完成输入" "abc" "$(acct_text "$S/ui.xml")"

  # --append 不符 → rc=6 且只派发一次文本（重试会先清空，等于变替换）
  S=$(fresh_state "old")
  OUT=$(run_in "$P" "$S" AB_DROP_LAST=1 -- bash "$SCRIPT_DIR/android/input.sh" --field account --text abc --append 2>&1); RC=$?
  expect_rc "I3 --append 不符 → rc=6" 6 "$RC"
  expect_contains "I3 说明 append 不重试" "不自动重试" "$OUT"
  expect_eq   "I3 append 不符时未清空旧内容" "oldab" "$(acct_text "$S/ui.xml")"

  S=$(fresh_state)
  OUT=$(run_in "$P" "$S" AB_DROP_LAST=1 -- bash "$SCRIPT_DIR/android/input.sh" --field account --text abc 2>&1); RC=$?
  expect_rc "I3 IME 掉字 + 重试仍不符 → rc=6" 6 "$RC"
  expect_contains "I3 给出 --slow 提示" "--slow" "$OUT"

  S=$(fresh_state)
  OUT=$(run_in "$P" "$S" AB_FAIL_TAP=1 -- bash "$SCRIPT_DIR/android/input.sh" --field account --text abc 2>&1); RC=$?
  expect_rc "I3 adb input tap 失败 → rc=7" 7 "$RC"

  # 焦点没进去 ⇒ 必须在发任何 DEL/文本前停下（否则会删掉别的框的内容）
  S=$(fresh_state "old")
  OUT=$(run_in "$P" "$S" AB_NO_FOCUS=1 -- bash "$SCRIPT_DIR/android/input.sh" --field account --text abc 2>&1); RC=$?
  expect_rc "I3 点击未获焦点 → rc=7" 7 "$RC"
  expect_eq   "I3 未获焦点时不发删除键" "" "$(cat "$S/keys")"
  expect_eq   "I3 未获焦点时旧内容不变" "old" "$(acct_text "$S/ui.xml")"
  expect_contains "I3 说明未删除任何内容" "未删除" "$OUT"

  # 空格必须转成 %s（adb input text 的框架限制）；漏转会把两个词粘在一起
  S=$(fresh_state)
  OUT=$(run_in "$P" "$S" -- bash "$SCRIPT_DIR/android/input.sh" --field account --text 'a b' 2>&1); RC=$?
  expect_rc "I3 空格文本 → rc=0" 0 "$RC"
  expect_eq   "I3 空格按 %s 送达设备" "a b" "$(acct_text "$S/ui.xml")"

  # --index 越界：命中 1 处却要第 2 个
  S=$(fresh_state)
  OUT=$(run_in "$P" "$S" -- bash "$SCRIPT_DIR/android/input.sh" --field account --index 2 --text abc 2>&1); RC=$?
  expect_rc "I3 --index 越界 → rc=1" 1 "$RC"
  expect_contains "I3 越界说明命中数" "越界" "$OUT"

  # --one-key：逐发键码 ⇒ keys 文件应有多行（批量时只有 1 行）
  S=$(fresh_state "old")
  OUT=$(run_in "$P" "$S" -- bash "$SCRIPT_DIR/android/input.sh" --field account --text abc --one-key 2>&1); RC=$?
  expect_rc "I3 --one-key → rc=0" 0 "$RC"
  expect_eq   "I3 --one-key 逐发 6 条删除键" "6" "$(grep -c 67 "$S/keys")"

  S=$(fresh_state "old")
  OUT=$(run_in "$P" "$S" -- bash "$SCRIPT_DIR/android/input.sh" --field account --text abc 2>&1); RC=$?
  expect_eq   "I3 批量删除只发 1 条删除键命令" "1" "$(grep -c 67 "$S/keys")"

  S=$(fresh_state)
  OUT=$(run_in "$P" "$S" -- bash "$SCRIPT_DIR/android/input.sh" --field account --text secret --mask 2>&1); RC=$?
  expect_rc "I3 --mask 按长度校验（stub 明文）→ rc=0" 0 "$RC"

  S=$(fresh_state "••")
  OUT=$(run_in "$P" "$S" AB_MASK_HIDE=1 -- bash "$SCRIPT_DIR/android/input.sh" --field account --text secret --mask 2>&1); RC=$?
  expect_rc "I3 密码框掩码只比长度 → rc=0" 0 "$RC"

  S=$(fresh_state "••")
  OUT=$(run_in "$P" "$S" AB_MASK_HIDE=1 -- bash "$SCRIPT_DIR/android/input.sh" --field account --text secret 2>&1); RC=$?
  expect_rc "I3 掩码字段不回退明文比对 → rc=6" 6 "$RC"
fi

# ---------- I4 环境与空树 ----------
if run_case "I4-env"; then
  echo "--- I4 环境/空树（rc=3/4） ---"
  P=$(mk_proj i4); S=$(fresh_state)
  EMPTY=$(empty_tree_xml)
  OUT=$(run_in "$P" "$S" SNAPSHOT_INPUT="$EMPTY" -- bash "$SCRIPT_DIR/android/input.sh" --field account --text abc 2>&1); RC=$?
  expect_rc "I4 语义树为空 → rc=4" 4 "$RC"
  expect_contains "I4 提示需 Semantics" "Semantics" "$OUT"

  S=$(fresh_state)
  OUT=$(run_in "$P" "$S" AB_NO_DEVICE=1 -- bash "$SCRIPT_DIR/android/input.sh" --field account --text abc 2>&1); RC=$?
  expect_rc "I4 无设备 → rc=3（不是 1）" 3 "$RC"
  expect_contains "I4 明确「环境不可用」" "环境不可用" "$OUT"
fi

# ---------- T1 tap_verify ----------
if run_case "T1-tapverify"; then
  echo "--- T1 tap_verify.sh（rc=0/1/2/3 + 重试纪律） ---"
  P=$(mk_proj t1)

  S=$(fresh_state)
  OUT=$(run_in "$P" "$S" -- bash "$SCRIPT_DIR/tap_verify.sh" 2>&1); RC=$?
  expect_rc "T1 缺关键词 → rc=2" 2 "$RC"
  S=$(fresh_state)
  OUT=$(run_in "$P" "$S" -- bash "$SCRIPT_DIR/tap_verify.sh" 登录 --expect nope 2>&1); RC=$?
  expect_rc "T1 非法 --expect → rc=2" 2 "$RC"
  S=$(fresh_state)
  OUT=$(run_in "$P" "$S" -- bash "$SCRIPT_DIR/tap_verify.sh" 登录 --platform ios 2>&1); RC=$?
  expect_rc "T1 iOS 模拟器 → rc=3" 3 "$RC"

  S=$(fresh_state)
  OUT=$(run_in "$P" "$S" -- bash "$SCRIPT_DIR/tap_verify.sh" 不存在的按钮 --expect none --wait 1 2>&1); RC=$?
  expect_rc "T1 未命中 → rc=1" 1 "$RC"
  expect_contains "T1 未命中提示 findtap" "findtap" "$OUT"

  # 断言必须断「目标页出现」，不能断「被点的按钮还在」（那样点击无效也必过 —— 自满足断言）
  S=$(fresh_state)
  OUT=$(run_in "$P" "$S" AB_TAP_EFFECT=1 -- bash "$SCRIPT_DIR/tap_verify.sh" 登录 --expect has:首页 --wait 1 2>&1); RC=$?
  expect_rc "T1 点击 + 断言目标页出现 → rc=0" 0 "$RC"
  expect_eq   "T1 只点一次" "1" "$(wc -l < "$S/taps" | tr -d ' ')"

  S=$(fresh_state)
  OUT=$(run_in "$P" "$S" -- bash "$SCRIPT_DIR/tap_verify.sh" 登录 --expect none --wait 1 --retry 0 2>&1); RC=$?
  expect_rc "T1 页面无变化 → rc=1" 1 "$RC"
  expect_contains "T1 报告无变化" "无变化" "$OUT"

  S=$(fresh_state)
  OUT=$(run_in "$P" "$S" AB_TAP_EFFECT=1 -- bash "$SCRIPT_DIR/tap_verify.sh" 登录 --expect none --wait 1 2>&1); RC=$?
  expect_rc "T1 点击后页面变化 → rc=0" 0 "$RC"

  # 整页换新（目标节点消失）⇒ 强判据，rc=0
  S=$(fresh_state)
  OUT=$(run_in "$P" "$S" AB_TAP_EFFECT=2 -- bash "$SCRIPT_DIR/tap_verify.sh" 登录 --expect none --wait 1 2>&1); RC=$?
  expect_rc "T1 目标节点消失 → rc=0" 0 "$RC"

  # 只有文本集变化（节点数与目标都不变）⇒ 弱证据：默认 rc=1、不再重点；--allow-weak 才放行
  S=$(fresh_state)
  OUT=$(run_in "$P" "$S" AB_TAP_EFFECT=3 -- bash "$SCRIPT_DIR/tap_verify.sh" 登录 --expect none --wait 1 --retry 1 2>&1); RC=$?
  expect_rc "T1 仅文本集变化 → rc=1（弱判据）" 1 "$RC"
  expect_contains "T1 说明弱判据" "弱判据" "$OUT"
  expect_eq   "T1 弱判据不重点（只点 1 次）" "1" "$(wc -l < "$S/taps" | tr -d ' ')"
  expect_contains "T1 提示 --allow-weak" "allow-weak" "$OUT"

  S=$(fresh_state)
  OUT=$(run_in "$P" "$S" AB_TAP_EFFECT=3 -- bash "$SCRIPT_DIR/tap_verify.sh" 登录 --expect none --wait 1 --allow-weak 2>&1); RC=$?
  expect_rc "T1 --allow-weak 放行弱判据 → rc=0" 0 "$RC"

  # 断言路径 + 点后 dump 失效 ⇒ 无法判定 ⇒ fail-closed（只点 1 次）
  S=$(fresh_state)
  OUT=$(run_in "$P" "$S" AB_BREAK_DUMP=1 -- bash "$SCRIPT_DIR/tap_verify.sh" 登录 --expect has:首页 --wait 1 --retry 1 2>&1); RC=$?
  expect_rc "T1 断言路径点后快照失败 → rc=1" 1 "$RC"
  expect_eq   "T1 断言路径快照失败只点 1 次" "1" "$(wc -l < "$S/taps" | tr -d ' ')"

  # 页面已变但没到期望页 ⇒ 事务可能已提交：**只点一次**、rc=1（不许再点第二次）
  S=$(fresh_state)
  OUT=$(run_in "$P" "$S" AB_TAP_EFFECT=1 -- bash "$SCRIPT_DIR/tap_verify.sh" 登录 --expect has:不存在的页 --wait 1 --retry 1 2>&1); RC=$?
  expect_rc "T1 已变化但未达断言 → rc=1" 1 "$RC"
  expect_eq   "T1 已变化不再重点（只点 1 次）" "1" "$(wc -l < "$S/taps" | tr -d ' ')"
  expect_contains "T1 说明事务可能已提交" "不再重点" "$OUT"

  # 点后 dump 失效 ⇒ 无法判定 ⇒ fail-closed：不重点、rc=1
  S=$(fresh_state)
  OUT=$(run_in "$P" "$S" AB_BREAK_DUMP=1 -- bash "$SCRIPT_DIR/tap_verify.sh" 登录 --expect none --wait 1 --retry 1 2>&1); RC=$?
  expect_rc "T1 点后快照不可用 → rc=1" 1 "$RC"
  expect_eq   "T1 快照不可用时只点 1 次" "1" "$(wc -l < "$S/taps" | tr -d ' ')"
  expect_contains "T1 快照不可用说明无法判定" "无法判定" "$OUT"

  S=$(fresh_state)
  OUT=$(run_in "$P" "$S" -- bash "$SCRIPT_DIR/tap_verify.sh" 登录 --expect none --wait 1 --retry 1 2>&1); RC=$?
  expect_rc "T1 无变化且允许重试 → rc=1" 1 "$RC"
  expect_eq   "T1 --retry 1 会点两次" "2" "$(wc -l < "$S/taps" | tr -d ' ')"

  S=$(fresh_state)
  OUT=$(run_in "$P" "$S" -- bash "$SCRIPT_DIR/tap_verify.sh" 提交 --expect none --wait 1 2>&1); RC=$?
  expect_rc "T1 危险词默认禁二击 → rc=1" 1 "$RC"
  expect_contains "T1 说明危险词" "危险操作" "$OUT"
  expect_eq   "T1 危险词只点一次" "1" "$(wc -l < "$S/taps" | tr -d ' ')"

  S=$(fresh_state)
  OUT=$(run_in "$P" "$S" -- bash "$SCRIPT_DIR/tap_verify.sh" 提交 --expect none --wait 1 --allow-danger 2>&1); RC=$?
  expect_rc "T1 --allow-danger 放行二击 → rc=1" 1 "$RC"
  expect_eq   "T1 --allow-danger 点两次" "2" "$(wc -l < "$S/taps" | tr -d ' ')"

  S=$(fresh_state)
  OUT=$(run_in "$P" "$S" -- bash "$SCRIPT_DIR/tap_verify.sh" 登录 --expect none --json --wait 1 2>&1); RC=$?
  expect_contains "T1 --json 输出定位载荷" '"needle": "登录"' "$OUT"
fi

# ---------- P1 pitfall_append ----------
if run_case "P1-pitfall"; then
  echo "--- P1 pitfall_append.sh ---"
  ( cd "$TMPROOT" && bash "$SCRIPT_DIR/pitfall_append.sh" --symptom "账号输成旧值+新值" \
      --judge "读回不等" --action "input.sh --text-from" >/dev/null 2>&1 ); RC=$?
  expect_rc "P1 首次追加 → rc=0" 0 "$RC"
  LEDGER="$TMPROOT/docs/test/debug-loop/pitfalls.md"
  expect_contains "P1 台账含表头" "| 日期 | 症状 |" "$(cat "$LEDGER" 2>/dev/null || echo MISSING)"
  expect_contains "P1 台账含本条" "账号输成旧值+新值" "$(cat "$LEDGER" 2>/dev/null || echo MISSING)"
  OUT=$( cd "$TMPROOT" && bash "$SCRIPT_DIR/pitfall_append.sh" --symptom "账号输成旧值+新值" --judge x --action y 2>&1 ); RC=$?
  expect_rc "P1 重复症状 → rc=0" 0 "$RC"
  expect_contains "P1 重复不追加" "未重复追加" "$OUT"
  OUT=$( cd "$TMPROOT" && bash "$SCRIPT_DIR/pitfall_append.sh" 2>&1 ); RC=$?
  expect_rc "P1 缺 --symptom → rc=2" 2 "$RC"
  R="$TMPROOT/pf2"
  OUT=$(bash "$SCRIPT_DIR/pitfall_append.sh" --symptom "管道|字符" --judge "a|b" --action "c" --root "$R" 2>&1); RC=$?
  expect_rc "P1 自定义 --root → rc=0" 0 "$RC"
  expect_contains "P1 表格竖线被转义" '管道\|字符' "$(cat "$R/pitfalls.md")"
fi

echo ""
echo "================================"
if [ "$FAIL" -eq 0 ]; then
  echo "✅ 全部通过（${PASS} 项）"
  exit 0
fi
echo "❌ 失败 ${FAIL} 项（通过 ${PASS} 项）"
for c in "${FAILED_CASES[@]}"; do echo "   - $c"; done
exit 1