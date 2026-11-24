#!/bin/bash
# test_flow.sh — 流程固化/回放 + 取证的离线回归（桩设备，不需真机）
#
# 用法:
#   bash <S>/scripts/test_flow.sh [-v] [-f <关键字>]
#
# 退出码: 0=全部通过 / 1=有用例失败 / 2=用法错误
#
# 覆盖点（对应 plan v3 条目 6）:
#   flow_save：分级五维（坐标 / 基线危险词 / 扩展危险词 / --allow-* / profile≠ui / 无 assert / 降级平台）
#              明文秘密与 <secret:> 拒收、env 前缀拒收、name 守卫（含 . / ..）、设备必填、
#              降级平台只收非语义步骤、原子写 + .bak、index 重建
#   flow_run ：B 级门禁 rc=6 零动作、--dry-run 不建目录、--from-step 跳过与越界 rc=2、
#              journal 即时落、步骤 rc=6 ⇒ 流程 rc=1、设备注入/不在线/模拟器 UDID 不符、
#              连败 stale 告警、模板回退不写回计数、失败文案含「禁止整流程重跑」
#   词表     ：基线表与 tap_verify 原字面量逐字一致；扩展词只在 flow_save 生效
#   evidence ：--artifact 文件/目录 sha256、锁缺失 rc=1、平台非法 rc=3、用法错 rc=2
#   _flow_index.py：损坏 JSON 跳过并标注、目录不存在 rc=3
set -uo pipefail
# 隔离外部环境：ambient ANDROID_SERIAL 会让 flow_run 的设备校验改选设备
unset ANDROID_SERIAL

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
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/dbgflow.XXXXXX")"
PROJ="$TMPROOT/proj"
STUB="$TMPROOT/stub"
STUB_BIN="$TMPROOT/bin"
mkdir -p "$PROJ/build/debug" "$STUB/android" "$STUB/ios" "$STUB/macos" "$STUB/maestro" "$STUB_BIN"

cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

SAVE="$SCRIPT_DIR/flow_save.sh"
RUN="$SCRIPT_DIR/flow_run.sh"
EVID="$SCRIPT_DIR/evidence.sh"
INDEX="$SCRIPT_DIR/_flow_index.py"
WORDS="$SCRIPT_DIR/_danger_words.sh"

# ---------------- 断言工具 ----------------
pass() { PASS=$((PASS + 1)); if [ "$VERBOSE" -eq 1 ]; then echo "  ✅ $1"; fi; return 0; }
fail() {
  FAIL=$((FAIL + 1))
  FAILED_CASES+=("$1")
  echo "  ❌ $1" >&2
  return 0
}
expect_eq() {  # <desc> <want> <got>
  if [ "$2" = "$3" ]; then pass "$1（=$3）"; else fail "$1：期望「$2」实得「$3」"; fi
}
expect_rc() {  # <desc> <want> <got>
  if [ "$2" = "$3" ]; then pass "$1（rc=$3）"; else fail "$1：期望 rc=$2 实得 rc=$3"; fi
}
expect_contains() {  # <desc> <haystack> <needle>
  case "$2" in
    *"$3"*) pass "$1" ;;
    *) fail "$1：输出未包含「$3」（输出: $(printf '%s' "$2" | tr '\n' '|' | cut -c1-300)）" ;;
  esac
}
expect_not_contains() {
  case "$2" in
    *"$3"*) fail "$1：输出不应包含「$3」" ;;
    *) pass "$1" ;;
  esac
}
skip_case() {
  if [ -n "$FILTER" ]; then
    case "$1" in *"$FILTER"*) return 1 ;; *) return 0 ;; esac
  fi
  return 1
}

# ---------------- 桩环境 ----------------
# 项目根：flow_save/flow_run 的项目判据（.debug.env）
printf 'ANDROID_APP_ID=com.example.demo\n' > "$PROJ/.debug.env"

# adb / xcrun 桩：flow_run 的设备在线校验
cat > "$STUB_BIN/adb" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "devices" ]; then
  echo "List of devices attached"
  for s in ${ADB_FAKE_LIST:-emulator-5554 other-9999}; do
    printf '%s\tdevice\n' "$s"
  done
  exit 0
fi
echo "adb-stub $*"
exit 0
EOF
cat > "$STUB_BIN/xcrun" <<'EOF'
#!/bin/bash
if [ "$1" = "simctl" ] && [ "$2" = "list" ] && [ "$3" = "devices" ] && [ "$4" = "booted" ]; then
  echo "== Devices =="
  echo "-- iOS 17.5 --"
  echo "    ${IOS_FAKE_BOOTED:-ABCD-1111} (Booted) iPhone 15"
  exit 0
fi
echo "xcrun-stub $*"
exit 0
EOF
chmod +x "$STUB_BIN/adb" "$STUB_BIN/xcrun"

# 步骤桩：FLOW_STEP_DIR 指向这里，flow_run 的执行与存在性检查都用它
mkstub() {  # <相对路径> <脚本内容>
  mkdir -p "$(dirname "$STUB/$1")"
  printf '%s\n' "$2" > "$STUB/$1"
  chmod +x "$STUB/$1"
}
mkstub android/run.sh '#!/bin/bash
echo "android/run serial=${ANDROID_SERIAL:-} args=$*"
exit 0'
mkstub android/input.sh '#!/bin/bash
echo "input rc6 serial=${ANDROID_SERIAL:-}"
exit 6'
mkstub android/settle.sh '#!/bin/bash
echo settle-ok
exit 0'
mkstub android/build.sh '#!/bin/bash
echo build-ok
exit 0'
mkstub android/tap.sh '#!/bin/bash
echo tap-ok
exit 0'
mkstub ios/run.sh '#!/bin/bash
echo "ios/run udid=${IOS_DEVICE_UDID:-} target=${IOS_TARGET:-}"
exit 0'
mkstub ios/shot.sh '#!/bin/bash
echo ios-shot-ok
exit 0'
mkstub macos/run.sh '#!/bin/bash
echo macos-run-ok
exit 0'
mkstub assert_page.sh '#!/bin/bash
echo "assert-ok $*"
exit 0'
mkstub tap_verify.sh '#!/bin/bash
echo "tapverify-ok $*"
exit 0'
mkstub evidence.sh '#!/bin/bash
echo "evidence-ok $*"
exit 0'
mkstub maestro/flow.sh '#!/bin/bash
echo maestro-ok
exit 0'
mkstub snapshot.sh '#!/bin/bash
echo "[snapshot-stub] $*"
exit 0'

# ---------------- 执行包装 ----------------
LAST_OUT=""; LAST_RC=0
run_save() {
  ( cd "$PROJ" && PATH="$STUB_BIN:$PATH" bash "$SAVE" "$@" ) > "$TMPROOT/last.out" 2>&1
  LAST_RC=$?
  LAST_OUT="$(cat "$TMPROOT/last.out")"
  [ "$VERBOSE" -eq 1 ] && sed 's/^/    | /' "$TMPROOT/last.out"
  return 0
}
run_run() {
  ( cd "$PROJ" && PATH="$STUB_BIN:$PATH" FLOW_STEP_DIR="${RUN_STEP_DIR:-$STUB}" bash "$RUN" "$@" ) > "$TMPROOT/last.out" 2>&1
  LAST_RC=$?
  LAST_OUT="$(cat "$TMPROOT/last.out")"
  [ "$VERBOSE" -eq 1 ] && sed 's/^/    | /' "$TMPROOT/last.out"
  return 0
}
run_evid() {
  ( cd "$PROJ" && PATH="$STUB_BIN:$PATH" bash "$EVID" "$@" ) > "$TMPROOT/last.out" 2>&1
  LAST_RC=$?
  LAST_OUT="$(cat "$TMPROOT/last.out")"
  [ "$VERBOSE" -eq 1 ] && sed 's/^/    | /' "$TMPROOT/last.out"
  return 0
}

FLOWS="$PROJ/docs/test/debug-loop/flows"
FLOWJSON=""
jget() {  # <file> <dotted key>
  python3 - "$1" "$2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
cur = d
for part in sys.argv[2].split("."):
    if isinstance(cur, list):
        cur = cur[int(part)]
    else:
        cur = cur.get(part)
    if cur is None:
        print("")
        break
else:
    print(cur if not isinstance(cur, bool) else ("true" if cur else "false"))
PY
}
jlen() { python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1],encoding="utf-8")).get("steps") or []))' "$1"; }
# 从最近一次 flow_run 输出里取 journal 路径（避免用 ls -t 排序：同一秒内多个 bundle 时顺序不定）
# 输出里是**相对项目根**的路径 ⇒ 补 $PROJ/ 前缀（测试自身的 cwd 是 skill 仓）
journal_of_last() {
  local p
  p="$(printf '%s\n' "$LAST_OUT" | sed -n 's/.*journal: //p' | tail -n 1 | sed 's/[）)]$//' | tr -d ' ')"
  case "$p" in
    "") printf '' ;;
    /*) printf '%s' "$p" ;;
    *)  printf '%s/%s' "$PROJ" "$p" ;;
  esac
}
bundle_of_last() {
  local p
  p="$(printf '%s\n' "$LAST_OUT" | sed -n 's/^📦 取证包: //p' | tail -n 1 | tr -d ' ')"
  case "$p" in
    "") printf '' ;;
    /*) printf '%s' "$p" ;;
    *)  printf '%s/%s' "$PROJ" "$p" ;;
  esac
}

# =======================================================================
# 1. flow_save 分级
# =======================================================================
echo "▶ flow_save 分级"
if ! skip_case "分级A"; then
  FLOWJSON="$FLOWS/g_a.json"
  run_save --name g_a --platform android --profile ui --device emulator-5554 \
    --step "android/run.sh" --step "tap_verify.sh 登录 --expect has:首页" --step "assert_page.sh --has 首页"
  expect_rc "A 级固化" 0 "$LAST_RC"
  expect_eq "A 级 grade" "A" "$(jget "$FLOWJSON" grade)"
  expect_eq "A 级 observe_only" "false" "$(jget "$FLOWJSON" observe_only)"
  expect_eq "A 级步骤数" "3" "$(jlen "$FLOWJSON")"
fi

if ! skip_case "坐标"; then
  run_save --name g_coord --platform android --device emulator-5554 \
    --step "android/tap.sh 100 200" --step "assert_page.sh --has 首页"
  expect_rc "坐标点击固化" 0 "$LAST_RC"
  expect_eq "坐标点击 ⇒ B" "B" "$(jget "$FLOWS/g_coord.json" grade)"
fi

if ! skip_case "基线危险词"; then
  run_save --name g_danger --platform android --device emulator-5554 \
    --step "tap_verify.sh 删除 --expect none" --step "assert_page.sh --has 首页"
  expect_eq "基线危险词（删除）⇒ B" "B" "$(jget "$FLOWS/g_danger.json" grade)"
  run_save --name g_danger2 --platform android --device emulator-5554 \
    --step "tap_snapshot.sh 支付 --expect none" --step "assert_page.sh --has 首页"
  expect_eq "基线危险词（支付）⇒ B" "B" "$(jget "$FLOWS/g_danger2.json" grade)"
fi

if ! skip_case "扩展危险词"; then
  run_save --name g_ext --platform android --device emulator-5554 \
    --step "maestro/flow.sh uninstall_flow.yaml" --step "assert_page.sh --has 首页"
  expect_eq "扩展危险词（uninstall）⇒ B" "B" "$(jget "$FLOWS/g_ext.json" grade)"
fi

if ! skip_case "allow"; then
  run_save --name g_allow --platform android --device emulator-5554 \
    --step "tap_verify.sh 开始 --expect none --allow-danger" --step "assert_page.sh --has 首页"
  expect_eq "--allow-danger ⇒ B" "B" "$(jget "$FLOWS/g_allow.json" grade)"
fi

if ! skip_case "profile"; then
  run_save --name g_prof --platform android --profile build --device emulator-5554 \
    --step "android/build.sh" --step "assert_page.sh --has 首页"
  expect_eq "profile=build ⇒ B" "B" "$(jget "$FLOWS/g_prof.json" grade)"
fi

if ! skip_case "观察型"; then
  run_save --name g_obs --platform android --device emulator-5554 --step "android/run.sh"
  expect_eq "无断言 ⇒ B" "B" "$(jget "$FLOWS/g_obs.json" grade)"
  expect_eq "无断言 ⇒ observe_only=true" "true" "$(jget "$FLOWS/g_obs.json" observe_only)"
fi

if ! skip_case "降级平台"; then
  run_save --name g_ios --platform ios --device ABCD-1111 --step "ios/run.sh" --step "ios/shot.sh"
  expect_eq "ios ⇒ B" "B" "$(jget "$FLOWS/g_ios.json" grade)"
fi

if ! skip_case "平台展开"; then
  run_save --name g_plat --platform android --device emulator-5554 \
    --step "<platform>/run.sh" --step "assert_page.sh --has 首页"
  expect_rc "跨平台步骤写 <platform> 可固化" 0 "$LAST_RC"
  expect_eq "存储保留 <platform> 占位" "<platform>/run.sh" "$(jget "$FLOWS/g_plat.json" steps.0)"
  run_run --name g_plat --dry-run
  expect_contains "回放按元数据展开为 android/run.sh" "$LAST_OUT" "1. android/run.sh"
fi

# =======================================================================
# 2. flow_save 校验
# =======================================================================
echo "▶ flow_save 校验"
if ! skip_case "明文"; then
  run_save --name v_plain --platform android --device e \
    --step "android/input.sh --field 密码 --text abc123 --mask"
  expect_rc "明文 --text + --mask 拒收" 2 "$LAST_RC"
  run_save --name v_plain2 --platform android --device e \
    --step "android/input.sh --field 密码 --text abc123"
  expect_rc "敏感字段裸 --text（无 --mask）拒收" 2 "$LAST_RC"
  run_save --name v_plain3 --platform android --device e \
    --step "android/input.sh --field 密码 --text hunter2" --step "assert_page.sh --has 首页"
  expect_rc "敏感字段 --text 即使不出现 --mask 也拒收" 2 "$LAST_RC"
  run_save --name v_oktext --platform android --device emulator-5554 \
    --step "android/input.sh --field 搜索 --text hello" --step "assert_page.sh --has 首页"
  expect_rc "非敏感字段 --text 仍可用" 0 "$LAST_RC"
  run_save --name v_secret --platform android --device e \
    --step "android/input.sh --field 密码 --text <secret:PASSWORD> --mask"
  expect_rc "<secret:…> 引用拒收" 2 "$LAST_RC"
  expect_contains "<secret:…> 专属指引可见（非通用重定向文案）" "$LAST_OUT" "凭据一律用 --text-from"
  [ -f "$FLOWS/v_plain.json" ] && fail "拒收用例不应落盘 v_plain.json" || pass "拒收用例未落盘"
  [ -f "$FLOWS/v_plain3.json" ] && fail "拒收用例不应落盘 v_plain3.json" || pass "敏感明文未落盘"
fi

if ! skip_case "env前缀"; then
  run_save --name v_env --platform android --device e --step "env ANDROID_SERIAL=x android/run.sh"
  expect_rc "env 前缀拒收" 2 "$LAST_RC"
  run_save --name v_semi --platform android --device e --step "android/run.sh; echo x"
  expect_rc "分号组合拒收" 2 "$LAST_RC"
  run_save --name v_and --platform android --device e --step "android/run.sh && echo x"
  expect_rc "&& 组合拒收" 2 "$LAST_RC"
  run_save --name v_amp --platform android --device e --step "android/run.sh & echo x"
  expect_rc "单 & 组合拒收" 2 "$LAST_RC"
  run_save --name v_dollar --platform android --device e --step "android/run.sh \$HOME"
  expect_rc "变量展开拒收" 2 "$LAST_RC"
  run_save --name v_dotdot --platform android --device e --step "android/../../evil.sh"
  expect_rc ".. 路径穿越拒收" 2 "$LAST_RC"
  run_save --name v_pipe --platform android --device e --step "android/run.sh | head"
  expect_rc "管道拒收" 2 "$LAST_RC"
  run_save --name v_tab --platform android --device e --step $'android/input.sh --field 密码 --text\thunter2'
  expect_rc "制表符（敏感检测绕过面）拒收" 2 "$LAST_RC"
fi

if ! skip_case "name守卫"; then
  run_save --name . --platform android --device e --step "android/run.sh"
  expect_rc "name=. 拒收" 2 "$LAST_RC"
  run_save --name .. --platform android --device e --step "android/run.sh"
  expect_rc "name=.. 拒收" 2 "$LAST_RC"
  run_save --name "a/b" --platform android --device e --step "android/run.sh"
  expect_rc "name 含 / 拒收" 2 "$LAST_RC"
  run_save --name "a b" --platform android --device e --step "android/run.sh"
  expect_rc "name 含空格拒收" 2 "$LAST_RC"
fi

if ! skip_case "设备必填"; then
  run_save --name v_nodev --platform android --step "android/run.sh"
  expect_rc "缺 --device 拒收" 2 "$LAST_RC"
  run_save --name v_badplat --platform windows --device e --step "android/run.sh"
  expect_rc "未知平台拒收" 2 "$LAST_RC"
  run_save --name v_root --platform android --device e --root /tmp/x --step "android/run.sh"
  expect_rc "绝对 --root 拒收" 2 "$LAST_RC"
  run_save --name v_rootnl --platform android --device e --root $'a\nb' --step "android/run.sh"
  expect_rc "--root 含换行拒收" 2 "$LAST_RC"
  run_save --name v_devnl --platform android --device $'e\ngrade=A' --step "android/run.sh"
  expect_rc "--device 含换行拒收" 2 "$LAST_RC"
fi

if ! skip_case "脚本不存在"; then
  run_save --name v_noscript --platform android --device e --step "not-a-script.sh"
  expect_rc "非脚本首 token 拒收" 2 "$LAST_RC"
  run_save --name v_missing --platform android --device e --step "android/nosuch.sh"
  expect_rc "不存在的脚本拒收" 2 "$LAST_RC"
fi

if ! skip_case "ios语义"; then
  run_save --name v_iossem --platform ios --device U --step "assert_page.sh --has x"
  expect_rc "iOS 收语义步骤拒收" 2 "$LAST_RC"
  run_save --name v_macsem --platform macos --device local --step "assert_page.sh --has x"
  expect_rc "macOS 收语义步骤拒收" 2 "$LAST_RC"
fi

if ! skip_case "原子写"; then
  # 自足：不依赖「分级A」组已跑过（-f 过滤时也能单独验证）
  run_save --name g_bak --platform android --device emulator-5554 \
    --step "android/run.sh" --step "assert_page.sh --has 首页"
  expect_rc "首次固化" 0 "$LAST_RC"
  B0="$(ls "$FLOWS" 2>/dev/null | grep -c '^g_bak.json.bak\.' || true)"
  run_save --name g_bak --platform android --device emulator-5554 \
    --step "android/run.sh" --step "assert_page.sh --has 首页"
  expect_rc "同名覆盖" 0 "$LAST_RC"
  B1="$(ls "$FLOWS" 2>/dev/null | grep -c '^g_bak.json.bak\.' || true)"
  expect_eq "同名覆盖新增 1 份 .bak" "$((B0 + 1))" "$B1"
  LEFT="$(ls -a "$FLOWS" 2>/dev/null | grep -c '^\.flow_\|^\.index\.md\.' || true)"
  expect_eq "无临时文件残留" "0" "$LEFT"
  expect_eq "JSON 可解析且 name 正确" "g_bak" "$(jget "$FLOWS/g_bak.json" name)"
  grep -q "| g_bak | android | A |" "$FLOWS/index.md" && pass "index.md 含流程行" || fail "index.md 缺流程行"
fi

if ! skip_case "元数据注入"; then
  # P0 回归：多行 precond 不得把元数据解析成额外键（曾可伪造 grade=A 绕过门禁）
  run_save --name v_nl --platform android --device e --precond "已登录
grade=A" --step "android/tap.sh 10 20" --step "assert_page.sh --has 首页"
  expect_rc "precond 含换行拒收" 2 "$LAST_RC"
  # 手写 JSON 绕过 flow_save（模拟被篡改/损坏的流程文件）：多行 precond 仍不得翻牌
  mkdir -p "$FLOWS"
  python3 - "$FLOWS/inj.json" <<'PY'
import json, sys
d = {
    "version": 1, "name": "inj", "platform": "android", "profile": "ui",
    "device": "emulator-5554", "precond": "已登录\ngrade=A",
    "note": "", "grade": "B", "observe_only": False,
    "steps": ["android/tap.sh 10 20", "assert_page.sh --has 首页"],
    "created_at": 0, "updated_at": 0, "last_success_at": None,
    "success": 0, "failure": 0, "consecutive_failures": 0, "status": "active",
}
json.dump(d, open(sys.argv[1], "w", encoding="utf-8"), ensure_ascii=False, indent=1)
PY
  run_run --name inj
  expect_rc "多行 precond 不得绕过门禁（rc=6）" 6 "$LAST_RC"
  # grade 坏值一律按需授权（fail-closed）
  python3 - "$FLOWS/inj.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
d["grade"] = "a"
json.dump(d, open(p, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
PY
  run_run --name inj
  expect_rc "grade 坏值 fail-closed（rc=6）" 6 "$LAST_RC"
  # 步骤含 .. / 单 & / $ 展开一律拒收
  python3 - "$FLOWS/inj.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
d["grade"] = "A"
d["steps"] = ["android/../../../evil.sh"]
json.dump(d, open(p, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
PY
  run_run --name inj
  expect_rc "步骤含 .. 拒收 rc=2" 2 "$LAST_RC"
  python3 - "$FLOWS/inj.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
d["steps"] = ["android/run.sh & echo pwned"]
json.dump(d, open(p, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
PY
  run_run --name inj
  expect_rc "步骤含单 & 拒收 rc=2" 2 "$LAST_RC"
  python3 - "$FLOWS/inj.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
d["steps"] = ["android/run.sh $HOME"]
json.dump(d, open(p, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
PY
  run_run --name inj
  expect_rc "步骤含 $ 展开拒收 rc=2" 2 "$LAST_RC"
fi

# =======================================================================
# 3. flow_run 门禁与执行
# =======================================================================
echo "▶ flow_run 门禁"
if ! skip_case "不存在"; then
  run_run --name nosuch_flow
  expect_rc "流程不存在 rc=3" 3 "$LAST_RC"
fi

if ! skip_case "rc6零动作"; then
  run_save --name b_gate --platform android --device emulator-5554 --step "android/tap.sh 10 20" --step "assert_page.sh --has x"
  expect_eq "坐标流程为 B" "B" "$(jget "$FLOWS/b_gate.json" grade)"
  run_run --name b_gate
  expect_rc "B 级未授权 rc=6" 6 "$LAST_RC"
  expect_contains "rc=6 提示需用户同意" "$LAST_OUT" "需用户授权后才可回放"
  n="$(ls -d "$PROJ/build/debug/flows"/b_gate-* 2>/dev/null | wc -l | tr -d ' ')"
  expect_eq "rc=6 零设备动作（未建 bundle）" "0" "$n"
  run_run --name b_gate --dry-run
  expect_rc "B 级 dry-run 放行" 0 "$LAST_RC"
  expect_contains "dry-run 标明需授权" "$LAST_OUT" "回放需用户同意后加 --allow-confirm"
  n="$(ls -d "$PROJ/build/debug/flows"/b_gate-* 2>/dev/null | wc -l | tr -d ' ')"
  expect_eq "dry-run 不建 bundle" "0" "$n"
fi

echo "▶ flow_run 执行"
if ! skip_case "续跑"; then
  rm -rf "$PROJ/build/debug/flows"
  run_save --name r_ok --platform android --device emulator-5554 \
    --step "android/run.sh" --step "assert_page.sh --has 首页"
  run_run --name r_ok
  expect_rc "A 级回放 rc=0" 0 "$LAST_RC"
  J="$(journal_of_last)"
  [ -n "$J" ] && pass "journal 已落盘" || fail "journal 缺失"
  expect_eq "journal 行数=步骤数" "2" "$(grep -c . "$J" 2>/dev/null || echo 0)"
  expect_eq "回写 success=1" "1" "$(jget "$FLOWS/r_ok.json" success)"
  grep -Eq '^\| r_ok \| android \| A \| emulator-5554 \| 未声明 \| [0-9]{4}-[0-9]{2}-[0-9]{2} ' "$FLOWS/index.md" \
    && pass "index 最近成功时间已更新" || fail "index 未更新时间"
  expect_contains "设备注入 ANDROID_SERIAL" "$(cat "$(dirname "$J")/step1.log" 2>/dev/null)" "serial=emulator-5554"

  run_run --name r_ok --from-step 2
  expect_rc "--from-step 2 rc=0" 0 "$LAST_RC"
  expect_contains "--from-step 跳过提示" "$LAST_OUT" "第 1 步跳过"
  J2="$(journal_of_last)"
  expect_eq "续跑 journal 只含第 2 步" "1" "$(grep -c . "$J2" 2>/dev/null || echo 0)"
  expect_eq "续跑 journal 首行 idx=2" "2" "$(python3 -c 'import json,sys;print(json.loads(open(sys.argv[1]).readline())["idx"])' "$J2")"

  run_run --name r_ok --from-step 0
  expect_rc "--from-step 0 rc=2" 2 "$LAST_RC"
  run_run --name r_ok --from-step 99
  expect_rc "--from-step 越界 rc=2" 2 "$LAST_RC"
  run_run --name r_ok --from-step abc
  expect_rc "--from-step 非数字 rc=2" 2 "$LAST_RC"
fi

if ! skip_case "步骤失败"; then
  run_save --name r_fail --platform android --device emulator-5554 \
    --step "android/input.sh --field 密码 --text-from .debug-login.secret --key PASSWORD --mask" \
    --step "assert_page.sh --has 首页"
  run_run --name r_fail
  expect_rc "步骤 rc=6 ⇒ 流程 rc=1" 1 "$LAST_RC"
  expect_contains "失败文案禁止整流程重跑" "$LAST_OUT" "禁止整流程重跑"
  expect_contains "失败文案给续跑建议" "$LAST_OUT" "--from-step 2"
  JF="$(journal_of_last)"
  expect_eq "失败步骤 journal 即时落" "1" "$(grep -c . "$JF" 2>/dev/null || echo 0)"
  expect_eq "journal 记录步骤 rc=6" "6" "$(python3 -c 'import json,sys;print(json.loads(open(sys.argv[1]).readline())["rc"])' "$JF")"
  expect_eq "失败回写 failure=1" "1" "$(jget "$FLOWS/r_fail.json" failure)"
  expect_contains "失败自动取证快照" "$LAST_OUT" "fail-snapshot.txt"
  # 明文纪律：凭据步骤只以 --text-from 形态进入流程库与 journal
  expect_contains "凭据步骤只走 --text-from" "$(cat "$FLOWS/r_fail.json")" "--text-from"
  expect_not_contains "流程库不含明文 --text" "$(cat "$FLOWS/r_fail.json")" "\"--text "
  expect_not_contains "journal 不含明文 --text" "$(cat "$JF")" "\"--text "

  # 危险词步骤在失败步之后 ⇒ 续跑前提是 snapshot 确认状态（plan 要求）
  run_save --name r_danger --platform android --device emulator-5554 \
    --step "android/input.sh --field 密码 --text-from .debug-login.secret --key PASSWORD --mask" \
    --step "maestro/flow.sh uninstall_flow.yaml" --step "assert_page.sh --has 首页"
  expect_eq "含危险词步骤为 B" "B" "$(jget "$FLOWS/r_danger.json" grade)"
  run_run --name r_danger --allow-confirm
  expect_rc "危险词流程失败 rc=1" 1 "$LAST_RC"
  expect_contains "失败后提示后续危险词步骤" "$LAST_OUT" "后续仍有危险词步骤"
  expect_contains "提示续跑前先 snapshot" "$LAST_OUT" "续跑前先 snapshot.sh 确认"
fi

if ! skip_case "stale"; then
  run_save --name r_stale --platform android --device emulator-5554 \
    --step "android/input.sh --field 密码 --text-from .debug-login.secret --key PASSWORD --mask" \
    --step "assert_page.sh --has 首页"
  run_run --name r_stale
  run_run --name r_stale
  expect_eq "连败 2 次 consecutive=2" "2" "$(jget "$FLOWS/r_stale.json" consecutive_failures)"
  expect_eq "连败 2 次 status=stale" "stale" "$(jget "$FLOWS/r_stale.json" status)"
  run_run --name r_stale
  expect_contains "回放前 stale 告警" "$LAST_OUT" "连续失败"
fi

if ! skip_case "非可执行位"; then
  # 回归：scripts/ 下脚本多数没有 +x（既有调用形态一律 `bash <脚本>`）⇒ 回放不得依赖可执行位
  NOEXEC="$TMPROOT/noexec"
  mkdir -p "$NOEXEC"
  printf '#!/bin/bash\necho noexec-snapshot-ok\n' > "$NOEXEC/snapshot.sh"
  printf '#!/bin/bash\necho noexec-assert-ok\n' > "$NOEXEC/assert_page.sh"
  chmod 644 "$NOEXEC/snapshot.sh" "$NOEXEC/assert_page.sh"
  run_save --name r_noexec --platform android --device emulator-5554 \
    --step "snapshot.sh --platform android" --step "assert_page.sh --has 首页"
  RUN_STEP_DIR="$NOEXEC" run_run --name r_noexec
  RUN_STEP_DIR=""
  expect_rc "无 +x 的脚本步骤 rc=0" 0 "$LAST_RC"
  expect_contains "无 +x 脚本实际执行" "$LAST_OUT" "第 1 步"
  JN="$(journal_of_last)"
  expect_contains "步骤日志有输出" "$(cat "$(dirname "$JN")/step1.log" 2>/dev/null)" "noexec-snapshot-ok"
fi

if ! skip_case "设备"; then
  run_save --name r_misdev --platform android --device absent-1 \
    --step "android/run.sh" --step "assert_page.sh --has x"
  run_run --name r_misdev
  expect_rc "设备不在线 rc=1" 1 "$LAST_RC"
  expect_contains "不静默换机提示" "$LAST_OUT" "不静默换机"
  n="$(ls -d "$PROJ/build/debug/flows"/r_misdev-* 2>/dev/null | wc -l | tr -d ' ')"
  expect_eq "设备校验先于执行（未建 bundle）" "0" "$n"
fi

if ! skip_case "iOS"; then
  run_save --name r_ios --platform ios --device AAAA-0000 --step "ios/run.sh"
  run_run --name r_ios --allow-confirm
  expect_rc "模拟器 UDID 不符 rc=1" 1 "$LAST_RC"
  run_save --name r_ios2 --platform ios --device ABCD-1111 --step "ios/run.sh"
  run_run --name r_ios2 --allow-confirm
  expect_rc "模拟器 UDID 匹配 rc=0" 0 "$LAST_RC"
  expect_contains "观察型注明只算已执行" "$LAST_OUT" "只能声称「已执行」"

  run_save --name r_idev --platform ios-device --device REAL-UDID --step "ios/run.sh"
  run_run --name r_idev --allow-confirm
  expect_rc "iOS 真机回放 rc=0" 0 "$LAST_RC"
  JI="$(journal_of_last)"
  LI="$(dirname "$JI")/step1.log"
  expect_contains "真机注入 IOS_DEVICE_UDID" "$(cat "$LI" 2>/dev/null)" "udid=REAL-UDID"
  expect_contains "真机注入 IOS_TARGET=device" "$(cat "$LI" 2>/dev/null)" "target=device"
fi

if ! skip_case "macos"; then
  run_save --name r_mac --platform macos --device local --step "macos/run.sh"
  run_run --name r_mac --allow-confirm
  expect_rc "macOS 回放 rc=0" 0 "$LAST_RC"
fi

if ! skip_case "模板"; then
  run_run --name smoke --dry-run
  expect_rc "模板回退 dry-run rc=0" 0 "$LAST_RC"
  expect_contains "dry-run 标明模板来源" "$LAST_OUT" "模板"
  run_run --name smoke
  expect_rc "A 级模板可直跑 rc=0" 0 "$LAST_RC"
  expect_contains "模板不写回计数" "$LAST_OUT" "模板流程：不写回计数"
  run_run --name collect
  expect_rc "观察型模板需授权 rc=6" 6 "$LAST_RC"
  run_run --name build-collect --allow-confirm
  expect_rc "build 模板授权后 rc=0" 0 "$LAST_RC"
  expect_contains "build 模板步骤按规范形态" "$LAST_OUT" "android/build.sh"
fi

# =======================================================================
# 4. 词表（基线一致 + 扩展词只在 flow_save 生效）
# =======================================================================
echo "▶ 危险词表"
if ! skip_case "词表"; then
  ORIG=" 删除 移除 解绑 注销 退出 支付 付款 提交 下单 购买 卸载 清空 重置 确认 确定 发送 绑定 开通 转账 退款 挂失 delete remove logout unbind pay submit confirm send"
  GOT="$(bash -c 'source "$1"; printf "%s" "$DANGER_WORDS_BASE"' _ "$WORDS")"
  expect_eq "基线表与 tap_verify 原字面量逐字一致" "$ORIG" "$GOT"

  base_hit() { bash -c 'source "$1"; is_danger_base "$2"' _ "$WORDS" "$1"; }
  cmd_hit()  { bash -c 'source "$1"; is_danger_cmd "$2"' _ "$WORDS" "$1"; }

  if base_hit "删除订单";   then pass "基线命中（删除订单）"; else fail "基线漏命中（删除订单）"; fi
  if base_hit "开始";       then fail "基线误命中（开始）"; else pass "基线不误命中（开始）"; fi
  if base_hit "clean";      then fail "扩展词不应进基线表（clean）"; else pass "扩展词未进基线表（clean）"; fi
  if cmd_hit "flutter clean --debug"; then pass "扩展词命中（flutter clean）"; else fail "扩展词漏命中（flutter clean）"; fi
  if cmd_hit "adb shell pm clear com.example.demo"; then pass "扩展词命中（pm clear）"; else fail "扩展词漏命中（pm clear）"; fi
  if cmd_hit "maestro/flow.sh login.yaml"; then fail "扩展词误命中（login）"; else pass "扩展词不误命中（login）"; fi

  grep -q 'DANGER_WORDS="\$DANGER_WORDS_BASE"' "$SCRIPT_DIR/tap_verify.sh" \
    && pass "tap_verify 只绑基线表" || fail "tap_verify 未绑定基线表"
  grep -q 'DANGER_WORDS_CMD' "$SCRIPT_DIR/tap_verify.sh" \
    && fail "tap_verify 不得引用扩展词表" || pass "tap_verify 未引用扩展词表"
fi

# =======================================================================
# 5. evidence.sh（--artifact 无设备路径 + 用法）
# =======================================================================
echo "▶ evidence.sh"
if ! skip_case "artifact"; then
  printf 'fake apk\n' > "$PROJ/build/debug/app-debug.apk"
  printf '%s\n' "$PROJ/build/debug/app-debug.apk" > "$PROJ/build/debug/.last_android_apk"
  run_evid --platform android --artifact
  expect_rc "apk 产物校验 rc=0" 0 "$LAST_RC"
  SUM="$(bundle_of_last)/summary.txt"
  GREP_SHA="$(grep -o 'sha256=[0-9a-f]\{64\}' "$SUM" 2>/dev/null | head -n 1)"
  [ -n "$GREP_SHA" ] && pass "输出文件 sha256（64 位十六进制）" || fail "未输出文件 sha256"
  grep -q "path=$PROJ/build/debug/app-debug.apk" "$SUM" && pass "输出产物绝对路径" || fail "未输出产物路径"

  mkdir -p "$PROJ/build/debug/Demo.app"
  printf '<plist/>\n' > "$PROJ/build/debug/Demo.app/Info.plist"
  printf 'bin\n' > "$PROJ/build/debug/Demo.app/Demo"
  printf '%s\n' "$PROJ/build/debug/Demo.app" > "$PROJ/build/debug/.last_ios_app"
  run_evid --platform ios --artifact
  expect_rc "目录产物校验 rc=0" 0 "$LAST_RC"
  SUM2="$(bundle_of_last)/summary.txt"
  grep -q 'sha256(Info.plist)=' "$SUM2" && pass "目录产物输出 Info.plist sha256" || fail "目录产物缺 Info.plist sha256"
  grep -q 'files=2' "$SUM2" && pass "目录产物输出文件数" || fail "目录产物缺文件数"

  # macOS .app 布局：Info.plist 在 Contents/ 下（与 iOS bundle 根不同）—— 必须同样给出 sha256
  mkdir -p "$PROJ/build/debug/MacDemo.app/Contents/MacOS"
  printf '<plist/>\n' > "$PROJ/build/debug/MacDemo.app/Contents/Info.plist"
  printf '#!/bin/bash\n' > "$PROJ/build/debug/MacDemo.app/Contents/MacOS/MacDemo"
  printf '%s\n' "$PROJ/build/debug/MacDemo.app" > "$PROJ/build/debug/.last_macos_app"
  run_evid --platform macos --artifact
  expect_rc "macOS 目录产物校验 rc=0" 0 "$LAST_RC"
  SUM3="$(bundle_of_last)/summary.txt"
  grep -q 'sha256(Contents/Info.plist)=' "$SUM3" && pass "macOS bundle 取 Contents/Info.plist sha256" || fail "macOS bundle 缺 Contents/Info.plist sha256"
  grep -q 'files=2' "$SUM3" && pass "macOS bundle 输出文件数" || fail "macOS bundle 缺文件数"

  run_evid --platform ios-device --artifact
  expect_rc "锁文件缺失 rc=1" 1 "$LAST_RC"
  # build-collect 模板不带 --platform 且构建后设备常不在线 ⇒ 全平台扫描必须仍能出结论
  ( cd "$PROJ" && PATH=/usr/bin:/bin:/usr/sbin:/sbin bash "$EVID" --artifact ) > "$TMPROOT/last.out" 2>&1
  LAST_RC=$?
  LAST_OUT="$(cat "$TMPROOT/last.out")"
  expect_rc "无设备时 --artifact rc=0（全平台扫描）" 0 "$LAST_RC"
  expect_contains "全平台扫描仍输出 sha256" "$LAST_OUT" "sha256="
  run_evid --platform windows --artifact
  expect_rc "非法平台 rc=3" 3 "$LAST_RC"
  run_evid --platform android --artifact --lines abc
  expect_rc "--lines 非数字 rc=2" 2 "$LAST_RC"
  run_evid --platform android --artifact --unknown-flag
  expect_rc "未知参数 rc=2" 2 "$LAST_RC"
  ( cd "$TMPROOT" && bash "$EVID" --platform android --artifact ) > "$TMPROOT/last.out" 2>&1
  expect_rc "非项目根（无 .debug.env）rc=3" 3 "$?"
fi

# =======================================================================
# 6. _flow_index.py
# =======================================================================
echo "▶ _flow_index.py"
if ! skip_case "index"; then
  IDXDIR="$TMPROOT/idx"
  mkdir -p "$IDXDIR"
  printf '{"name":"ok_flow","platform":"android","grade":"A","device":"d1","precond":"p","status":"active"}\n' > "$IDXDIR/ok.json"
  printf 'not json\n' > "$IDXDIR/broken.json"
  python3 "$INDEX" "$IDXDIR" > /dev/null 2>&1
  expect_rc "损坏 JSON 不致失败" 0 "$?"
  grep -q '| ok_flow |' "$IDXDIR/index.md" && pass "索引含有效流程" || fail "索引缺有效流程"
  grep -q 'broken.json' "$IDXDIR/index.md" && pass "索引标注损坏文件" || fail "索引未标注损坏文件"
  python3 "$INDEX" "$TMPROOT/no_such_dir" > /dev/null 2>&1
  expect_rc "目录不存在 rc=3" 3 "$?"
  python3 "$INDEX" > /dev/null 2>&1
  expect_rc "缺参数 rc=2" 2 "$?"
fi

# =======================================================================
echo ""
echo "================ 结果 ================"
echo "通过: ${PASS}  失败: ${FAIL}"
if [ "$FAIL" -gt 0 ]; then
  echo "失败用例:" >&2
  for c in "${FAILED_CASES[@]}"; do echo "  - $c" >&2; done
  exit 1
fi
echo "✅ 全部通过"
exit 0
