#!/bin/bash
# test_common.sh — .debug.env 安全解析 + Android 脚本「非 Flutter 项目可用」回归
#
# 用法:
#   bash <S>/scripts/test_common.sh          # 全量
#   bash <S>/scripts/test_common.sh -v       # 显示每个用例的输出明细
#   bash <S>/scripts/test_common.sh -f <关键字>  # 只跑名称含该关键字的用例
#
# 退出码: 0=全部通过 / 1=有用例失败 / 2=用法错误或未执行任何用例
#
# 覆盖点: 解析宽容/严格边界 / 键缺失语义 / 路径越界 / 注入负控（断言副作用不存在）/
#         非 Flutter 工程可用性 / build.sh 早退 / resolve_apk 降级 / bg.sh 负控。
# 所有用例在临时目录构造夹具 + adb 桩，不触碰真实工程、不需要真机。
set -uo pipefail   # 故意不加 -e：单例失败要继续跑完其余用例

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"

VERBOSE=0; FILTER=""
while [ $# -gt 0 ]; do
  case "$1" in
    -v) VERBOSE=1; shift ;;
    -f) [ $# -ge 2 ] || { echo "❌ -f 需带关键字" >&2; exit 2; }; FILTER="$2"; shift 2 ;;
    -h|--help) echo "用法: bash test_common.sh [-v] [-f <关键字>]"; exit 0 ;;
    *) echo "❌ 未知参数: $1" >&2; exit 2 ;;
  esac
done

PASS=0; FAIL=0; FAILED_CASES=()
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/dbgcommon.XXXXXX")"
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

# ---------- adb 桩 ----------
mkdir -p "$TMPROOT/bin"
cat > "$TMPROOT/bin/adb" <<'STUB'
#!/bin/bash
if [ "${1:-}" = "devices" ]; then
  printf 'List of devices attached\nemulator-5554\tdevice\n'
  exit 0
fi
if [ "${1:-}" = "-s" ]; then shift 2; fi
cmd="${1:-}"
case "$cmd" in
  shell)
    shift; sub="${1:-}"
    case "$sub" in
      getprop) echo "arm64-v8a" ;;
      pidof)   echo "4242" ;;
      am)      echo "Starting: Intent { }" ;;
      *)       : ;;
    esac
    ;;
  exec-out) printf '\211PNG\r\n\032\nFAKEPNGBYTES' ;;
  install)  echo "Success" ;;
  pull)
    for a in "$@"; do dst="$a"; done
    printf 'FAKEPULLED' > "$dst"
    ;;
  logcat)   : ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$TMPROOT/bin/adb"
export PATH="$TMPROOT/bin:$PATH"

# ---------- 断言 ----------
expect_rc() {   # <用例名> <期望rc> <实际rc>
  local name="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then
    PASS=$((PASS+1)); printf '  ✅ %s\n' "$name"
  else
    FAIL=$((FAIL+1)); FAILED_CASES+=("$name"); printf '  ❌ %s（期望 rc=%s，实际 rc=%s）\n' "$name" "$want" "$got"
  fi
}
expect_contains() {  # <用例名> <文本> <实际输出>
  local name="$1" needle="$2" out="$3"
  case "$out" in
    *"$needle"*) PASS=$((PASS+1)); printf '  ✅ %s\n' "$name" ;;
    *) FAIL=$((FAIL+1)); FAILED_CASES+=("$name"); printf '  ❌ %s（输出未含「%s」）\n' "$name" "$needle" ;;
  esac
}
expect_not_contains() {
  local name="$1" needle="$2" out="$3"
  case "$out" in
    *"$needle"*) FAIL=$((FAIL+1)); FAILED_CASES+=("$name"); printf '  ❌ %s（输出不该含「%s」）\n' "$name" "$needle" ;;
    *) PASS=$((PASS+1)); printf '  ✅ %s\n' "$name" ;;
  esac
}
expect_file() {      # <用例名> <路径> 期望存在
  local name="$1" p="$2"
  if [ -e "$p" ]; then PASS=$((PASS+1)); printf '  ✅ %s\n' "$name"
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$name"); printf '  ❌ %s（文件不存在: %s）\n' "$name" "$p"
  fi
}
expect_no_file() {
  local name="$1" p="$2"
  if [ -e "$p" ]; then FAIL=$((FAIL+1)); FAILED_CASES+=("$name"); printf '  ❌ %s（不该存在: %s）\n' "$name" "$p"
  else PASS=$((PASS+1)); printf '  ✅ %s\n' "$name"
  fi
}
run_case() {  # 名称含关键字才跑
  case "$1" in *"$FILTER"*) return 0 ;; *) SKIP_ALL=1; return 1 ;; esac
}
SKIP_ALL=0

# ---------- 夹具 ----------
mk_proj() {   # <名字> <是否Flutter 0/1>  → 输出目录路径
  local p="$TMPROOT/$1"
  mkdir -p "$p"
  if [ "$2" = "1" ]; then printf 'name: fake\n' > "$p/pubspec.yaml"; fi
  echo "$p"
}

echo "🧪 .debug.env 解析 + Android 非 Flutter 支持 回归"
echo ""

# ---------- G7 解析宽容（行形态归一化） ----------
if run_case "G7-解析宽容"; then
  P="$(mk_proj g7 0)"
  printf '# 注释行\r\nexport ANDROID_APP_ID=com.test.app   # 行尾注释\r\nANDROID_ACTIVITY=".MainActivity"\r\nLOG_DIR="build/debug"\r\nUNKNOWN_KEY=whatever\r\ntouch %s/pwn_unknown_form' "$TMPROOT" > "$P/.debug.env"
  OUT="$(cd "$P" && bash "$SKILL_DIR/scripts/android/shot.sh" 2>&1)"; RC=$?
  [ "$VERBOSE" = "1" ] && echo "$OUT"
  expect_rc "G7 非 Flutter 工程不被 pubspec 门拦住" 0 "$RC"
  expect_not_contains "G7 输出不含 Flutter 项目根提示" "请在 Flutter 项目根" "$OUT"
  expect_contains "G7 export 前缀+行尾注释正确解析" "截图完成" "$OUT"
  expect_file "G7 截图落 build/debug/screen.png" "$P/build/debug/screen.png"
  expect_no_file "G7 未知形态行未被执行" "$TMPROOT/pwn_unknown_form"
  echo ""
fi

# ---------- G1 非 Flutter 可用（shot / tap / run 无 APK） ----------
if run_case "G1-非Flutter可用"; then
  P="$(mk_proj g1 0)"
  printf 'ANDROID_APP_ID=com.test.app\n' > "$P/.debug.env"
  OUT="$(cd "$P" && bash "$SKILL_DIR/scripts/android/shot.sh" 2>&1)"; RC=$?
  expect_rc "G1 shot.sh 在非 Flutter 工程可用" 0 "$RC"
  expect_file "G1 截图已落盘" "$P/build/debug/screen.png"

  OUT="$(cd "$P" && bash "$SKILL_DIR/scripts/android/tap.sh" 100 200 2>&1)"; RC=$?
  expect_rc "G1 tap.sh 坐标点击可用" 0 "$RC"
  expect_contains "G1 tap.sh 有完成提示" "点击完成" "$OUT"

  OUT="$(cd "$P" && bash "$SKILL_DIR/scripts/android/run.sh" 2>&1)"; RC=$?
  expect_rc "G1 run.sh 无 APK 时不静默终止" 0 "$RC"
  expect_contains "G1 run.sh 明确提示跳过安装" "跳过安装" "$OUT"
  expect_contains "G1 run.sh 仍完成启动" "App 已启动" "$OUT"
  echo ""
fi

# ---------- G2 Flutter 回归 ----------
if run_case "G2-Flutter回归"; then
  P="$(mk_proj g2 1)"
  printf 'ANDROID_APP_ID=com.test.app\n' > "$P/.debug.env"
  OUT="$(cd "$P" && bash "$SKILL_DIR/scripts/android/shot.sh" 2>&1)"; RC=$?
  expect_rc "G2 Flutter 工程 shot.sh 仍可用" 0 "$RC"
  expect_file "G2 产物仍落 build/debug（路径未变）" "$P/build/debug/screen.png"
  echo ""
fi

# ---------- G3 build.sh 早退 ----------
if run_case "G3-build早退"; then
  P="$(mk_proj g3 0)"
  printf 'ANDROID_APP_ID=com.test.app\n' > "$P/.debug.env"
  OUT="$(cd "$P" && bash "$SKILL_DIR/scripts/android/build.sh" 2>&1)"; RC=$?
  expect_rc "G3 build.sh 非 Flutter 早退 rc=1" 1 "$RC"
  expect_contains "G3 提示非 Flutter" "非 Flutter" "$OUT"
  expect_contains "G3 提示交回主 agent" "主 agent" "$OUT"
  echo ""
fi

# ---------- G4 resolve_apk 降级 ----------
if run_case "G4-resolve_apk降级"; then
  P="$(mk_proj g4 0)"
  printf 'ANDROID_APP_ID=com.test.app\n' > "$P/.debug.env"
  OUT="$(cd "$P" && bash "$SKILL_DIR/scripts/android/install.sh" 2>&1)"; RC=$?
  expect_rc "G4 install.sh 无 APK 时 rc=1" 1 "$RC"
  expect_contains "G4 提示设置 ANDROID_APK_PATH" "ANDROID_APK_PATH" "$OUT"
  expect_not_contains "G4 不再猜 Flutter APK 目录" "flutter-apk" "$OUT"
  echo ""
fi

# ---------- G5 注入负控（宿主侧） ----------
if run_case "G5-注入负控"; then
  P="$(mk_proj g5 0)"
  MARK="$TMPROOT/pwn_appid"
  printf 'ANDROID_APP_ID="x; touch %s"\n' "$MARK" > "$P/.debug.env"
  OUT="$(cd "$P" && bash "$SKILL_DIR/scripts/android/shot.sh" 2>&1)"; RC=$?
  expect_rc "G5 分号注入被拒 rc=1" 1 "$RC"
  expect_contains "G5 报错含键名" "ANDROID_APP_ID" "$OUT"
  expect_no_file "G5 注入副作用未发生" "$MARK"

  MARK2="$TMPROOT/pwn_subst"
  printf 'ANDROID_APP_ID="$(touch %s)"\n' "$MARK2" > "$P/.debug.env"
  OUT="$(cd "$P" && bash "$SKILL_DIR/scripts/android/shot.sh" 2>&1)"; RC=$?
  expect_rc "G5 命令替换被拒 rc=1" 1 "$RC"
  expect_no_file "G5 命令替换副作用未发生" "$MARK2"

  MARK3="$TMPROOT/pwn_act"
  printf 'ANDROID_APP_ID=com.test.app\nANDROID_ACTIVITY=".Main; touch %s"\n' "$MARK3" > "$P/.debug.env"
  OUT="$(cd "$P" && bash "$SKILL_DIR/scripts/android/shot.sh" 2>&1)"; RC=$?
  expect_rc "G5 ACTIVITY 注入被拒 rc=1" 1 "$RC"
  expect_contains "G5 ACTIVITY 报错含键名" "ANDROID_ACTIVITY" "$OUT"
  expect_no_file "G5 ACTIVITY 注入副作用未发生" "$MARK3"
  echo ""
fi

# ---------- G6 LOG_DIR 越界 ----------
if run_case "G6-LOG_DIR越界"; then
  P="$(mk_proj g6 0)"
  EVIL="$TMPROOT/evil"
  printf 'ANDROID_APP_ID=com.test.app\nLOG_DIR="%s"\n' "$EVIL" > "$P/.debug.env"
  OUT="$(cd "$P" && bash "$SKILL_DIR/scripts/android/shot.sh" 2>&1)"; RC=$?
  expect_rc "G6 绝对 LOG_DIR 被拒 rc=1" 1 "$RC"
  expect_contains "G6 报错含 LOG_DIR" "LOG_DIR" "$OUT"
  expect_no_file "G6 越界目录未被创建" "$EVIL"

  printf 'ANDROID_APP_ID=com.test.app\nLOG_DIR="build/../.."\n' > "$P/.debug.env"
  OUT="$(cd "$P" && bash "$SKILL_DIR/scripts/android/shot.sh" 2>&1)"; RC=$?
  expect_rc "G6 含 .. 的 LOG_DIR 被拒 rc=1" 1 "$RC"
  expect_no_file "G6 .. 逃逸目录未被创建" "$TMPROOT/evil2"
  echo ""
fi

# ---------- G8 键缺失语义 ----------
if run_case "G8-键缺失"; then
  P="$(mk_proj g8 0)"
  printf 'ANDROID_APP_ID=com.test.app\n' > "$P/.debug.env"
  OUT="$(cd "$P" && bash "$SKILL_DIR/scripts/android/run.sh" 2>&1)"; RC=$?
  expect_rc "G8 最小 env 不崩 rc=0" 0 "$RC"
  expect_contains "G8 ANDROID_ACTIVITY 缺省为 .MainActivity" "com.test.app/.MainActivity" "$OUT"
  echo ""
fi

# ---------- G9 调用方式兼容（source _common.sh） ----------
if run_case "G9-source兼容"; then
  P="$(mk_proj g9 1)"
  printf 'ANDROID_APP_ID=com.test.app\n' > "$P/.debug.env"
  OUT="$(cd "$P" && bash -c "set -euo pipefail; source '$SKILL_DIR/scripts/android/_common.sh'; echo OK-\$IS_FLUTTER" 2>&1)"; RC=$?
  expect_rc "G9 bash -c source _common.sh 可用" 0 "$RC"
  expect_contains "G9 IS_FLUTTER 探测正确" "OK-1" "$OUT"
  echo ""
fi

# ---------- G10 bg.sh 负控 ----------
if run_case "G10-bg负控"; then
  P="$(mk_proj g10 0)"
  MARK="$TMPROOT/pwn_bg"
  printf 'ANDROID_APP_ID="x; touch %s"\n' "$MARK" > "$P/.debug.env"
  OUT="$(cd "$P" && bash "$SKILL_DIR/scripts/bg.sh" list 2>&1)"; RC=$?
  expect_rc "G10 bg.sh 拒绝非法 env 值" 1 "$RC"
  expect_contains "G10 bg.sh 报错含键名" "ANDROID_APP_ID" "$OUT"
  expect_no_file "G10 bg.sh 注入副作用未发生" "$MARK"

  MARK2="$TMPROOT/pwn_bg2"
  printf 'touch %s\n' "$MARK2" > "$P/.debug.env"
  OUT="$(cd "$P" && bash "$SKILL_DIR/scripts/bg.sh" list 2>&1)"; RC=$?
  expect_rc "G10 bg.sh 忽略未知形态行" 0 "$RC"
  expect_no_file "G10 未知形态行未被执行" "$MARK2"
  echo ""
fi

# ---------- G11 doctor.sh 自检 ----------
if run_case "G11-doctor"; then
  P="$(mktemp -d "$TMPROOT/g11.XXXXXX")"

  OUT="$(cd "$P" && bash "$SKILL_DIR/scripts/doctor.sh" 2>&1)"; RC=$?
  expect_rc "G11 缺 .debug.env → rc=1（诊断本身不崩）" 1 "$RC"
  expect_contains "G11 提示缺 .debug.env" "缺少 .debug.env" "$OUT"
  expect_contains "G11 给出 init.sh 指引" "init.sh" "$OUT"

  printf 'ANDROID_APP_ID=com.test.app\n' > "$P/.debug.env"
  OUT="$(cd "$P" && bash "$SKILL_DIR/scripts/doctor.sh" 2>&1)"; RC=$?
  expect_rc "G11 最小合法 env → rc=0" 0 "$RC"
  expect_contains "G11 汇总输出无阻塞" "无阻塞项" "$OUT"
  expect_contains "G11 识别 adb 桩" "adb:" "$OUT"

  MARK="$TMPROOT/pwn_doctor"
  printf 'ANDROID_APP_ID="x; touch %s"\n' "$MARK" > "$P/.debug.env"
  OUT="$(cd "$P" && bash "$SKILL_DIR/scripts/doctor.sh" 2>&1)"; RC=$?
  expect_rc "G11 非法 env 值 → rc=1" 1 "$RC"
  expect_contains "G11 报错含键名" "ANDROID_APP_ID" "$OUT"
  expect_no_file "G11 注入副作用未发生" "$MARK"

  OUT="$(cd "$P" && bash "$SKILL_DIR/scripts/doctor.sh" --platform bogus 2>&1)"; RC=$?
  expect_rc "G11 非法平台参数 → rc=2" 2 "$RC"
  echo ""
fi

# ---------- G12 settle / findtap 语义树判据（桩驱动） ----------
if run_case "G12-settle"; then
  P="$(mk_proj g12 0)"
  printf 'ANDROID_APP_ID=com.test.app\n' > "$P/.debug.env"
  LOGP="$P/build/debug"

  # 第二套 adb 桩：case-local PATH 前置，**不**污染文件级全局桩（后者对 G1–G11 生效）
  G12BIN="$TMPROOT/g12bin"; mkdir -p "$G12BIN"
  cat > "$G12BIN/adb" <<'STUB'
#!/bin/bash
# G12 桩：可注入 dump 内容（STUB_DUMP_FILE）、dump 失败（STUB_DUMP_FAIL）、截图字节数（STUB_PNG_BYTES）
st="${G12_STATE:-}"
if [ "${1:-}" = "devices" ]; then
  printf 'List of devices attached\nemulator-5554\tdevice\n'
  exit 0
fi
if [ "${1:-}" = "-s" ]; then shift 2; fi
cmd="${1:-}"
case "$cmd" in
  shell)
    shift; sub="${1:-}"
    case "$sub" in
      uiautomator)
        c=1
        if [ -n "$st" ]; then
          c=$(cat "$st/cnt" 2>/dev/null || printf '0'); c=$((c + 1)); printf '%s' "$c" > "$st/cnt"
        fi
        [ "${STUB_DUMP_FAIL:-0}" = "1" ] && exit 1
        # STUB_FAIL_SEQ="2,5" ⇒ 第 2、5 次 dump 失败（用于「成功→失败→成功」混合序列回归）
        if [ -n "${STUB_FAIL_SEQ:-}" ]; then
          case ",${STUB_FAIL_SEQ}," in *",${c},"*) exit 1 ;; esac
        fi
        if [ -n "$st" ]; then
          cp "${STUB_DUMP_FILE:-/dev/null}" "$st/device.xml" 2>/dev/null || true
          # STUB_DUMP_UNIQUE=1 ⇒ 每帧内容都不同（保证「永不静止」，用于负控）
          if [ "${STUB_DUMP_UNIQUE:-0}" = "1" ]; then printf '<!-- sample %s -->\n' "$c" >> "$st/device.xml"; fi
        fi
        echo "UI hierchary dumped to: /sdcard/x.xml"
        ;;
      wm)    echo "Physical size: 1080x1920" ;;
      input) : ;;
      *)     : ;;
    esac
    ;;
  pull)
    last=""
    for a in "$@"; do last="$a"; done
    if [ -n "$last" ]; then
      if [ -n "$st" ] && [ -f "$st/device.xml" ]; then cp "$st/device.xml" "$last" 2>/dev/null || true
      else : > "$last"; fi
    fi
    ;;
  exec-out)
    [ "${STUB_SCREEN_FAIL:-0}" = "1" ] && exit 1
    n="${STUB_PNG_BYTES:-4096}"
    if [ "${STUB_PNG_UNIQUE:-0}" = "1" ] && [ -n "$st" ]; then
      pc=$(cat "$st/pngcnt" 2>/dev/null || printf '0'); pc=$((pc + 1)); printf '%s' "$pc" > "$st/pngcnt"
      n=$((n + pc))
    fi
    dd if=/dev/zero bs=1 count="$n" 2>/dev/null || true
    ;;
  *) : ;;
esac
exit 0
STUB
  chmod +x "$G12BIN/adb"
  G12STATE="$TMPROOT/g12state"; mkdir -p "$G12STATE"

  # 夹具：40 个空属性节点 ≈4 KB（**体积 ≥1024 但语义为空** —— 专门用来证明「不再拿字节数判空树」）
  pad_nodes() {  # <输出文件> <额外节点串|"">
    local out="$1" extra="$2" i
    {
      echo '<hierarchy>'
      [ -n "$extra" ] && printf '%s\n' "$extra"
      i=0
      while [ "$i" -lt 40 ]; do
        printf '%s\n' '<node index="'"$i"'" text="" content-desc="" bounds="[0,0][10,10]" clickable="false"/>'
        i=$((i + 1))
      done
      echo '</hierarchy>'
    } > "$out"
  }
  EMPTY_XML="$TMPROOT/g12_empty.xml"; pad_nodes "$EMPTY_XML" ""
  HAS_XML="$TMPROOT/g12_has.xml";     pad_nodes "$HAS_XML" '<node text="OK" content-desc="" bounds="[0,0][100,100]" clickable="true"/>'
  TINY_XML="$TMPROOT/g12_tiny.xml";   printf '%s\n' '<hierarchy><node text="OK" bounds="[0,0][100,100]" clickable="true"/></hierarchy>' > "$TINY_XML"
  NUL_XML="$TMPROOT/g12_nul.xml";     printf '<hierarchy><node text="OK" bounds="[0,0][100,100]" clickable="true"/>\0</hierarchy>\n' > "$NUL_XML"

  # ① 语义为空但 4 KB：--mode ui 必须判「不可信」而不是「静止」
  OUT="$(cd "$P" && env "G12_STATE=$G12STATE" "STUB_DUMP_FILE=$EMPTY_XML" "STUB_PNG_BYTES=4096" "PATH=$G12BIN:$PATH" bash "$SKILL_DIR/scripts/android/settle.sh" --mode ui --timeout 3 2>&1)"; RC=$?
  [ "$VERBOSE" = "1" ] && echo "$OUT"
  expect_rc       "G12 语义为空+体积4KB：--mode ui rc=3" 3 "$RC"
  expect_contains "G12 报「语义树无内容」" "语义树无内容" "$OUT"
  expect_not_contains "G12 不再拿字节数当判据（未走整屏）" "改用整屏像素" "$OUT"

  # ② --mode auto：自动降级整屏并判定静止
  OUT="$(cd "$P" && env "G12_STATE=$G12STATE" "STUB_DUMP_FILE=$EMPTY_XML" "STUB_PNG_BYTES=4096" "PATH=$G12BIN:$PATH" bash "$SKILL_DIR/scripts/android/settle.sh" --mode auto --timeout 3 2>&1)"; RC=$?
  [ "$VERBOSE" = "1" ] && echo "$OUT"
  expect_rc       "G12 auto：语义为空 ⇒ 降级后 rc=0" 0 "$RC"
  expect_contains "G12 auto 打印切换说明" "改用整屏像素" "$OUT"
  expect_contains "G12 成功输出带判据" "判据=screen" "$OUT"

  # ③ 负控：0 字节截图不得判「静止」
  OUT="$(cd "$P" && env "G12_STATE=$G12STATE" "STUB_DUMP_FILE=$EMPTY_XML" "STUB_PNG_BYTES=0" "PATH=$G12BIN:$PATH" bash "$SKILL_DIR/scripts/android/settle.sh" --mode screen --timeout 1 2>&1)"; RC=$?
  expect_rc       "G12 0 字节截图 ⇒ 不判静止 rc=1" 1 "$RC"
  expect_contains "G12 报「截图无效」" "截图无效" "$OUT"

  # ④ 有语义两帧相同 ⇒ 正常静止
  OUT="$(cd "$P" && env "G12_STATE=$G12STATE" "STUB_DUMP_FILE=$HAS_XML" "STUB_PNG_BYTES=4096" "PATH=$G12BIN:$PATH" bash "$SKILL_DIR/scripts/android/settle.sh" --mode ui --timeout 5 2>&1)"; RC=$?
  expect_rc       "G12 有语义两帧相同 ⇒ rc=0" 0 "$RC"
  expect_contains "G12 判据=ui" "判据=ui" "$OUT"

  # ⑤ 参数守卫
  ( cd "$P" && env "G12_STATE=$G12STATE" "STUB_DUMP_FILE=$HAS_XML" "PATH=$G12BIN:$PATH" bash "$SKILL_DIR/scripts/android/settle.sh" --interval 0 >/dev/null 2>&1 ); expect_rc "G12 --interval 0 ⇒ rc=2" 2 $?

  # ⑥ dump 持续失败：--mode ui ⇒ rc=3，且**不得**误报「语义树无内容」
  #    timeout 用 12 是为了让「连续 2 次失败」先于「预算不足」触发（后者文案不同，见 ⑧ 的姊妹分支）
  OUT="$(cd "$P" && env "G12_STATE=$G12STATE" "STUB_DUMP_FAIL=1" "PATH=$G12BIN:$PATH" bash "$SKILL_DIR/scripts/android/settle.sh" --mode ui --timeout 12 2>&1)"; RC=$?
  expect_rc       "G12 dump 持续失败：--mode ui rc=3" 3 "$RC"
  expect_contains "G12 标注「dump 持续失败」" "dump 持续失败" "$OUT"
  expect_not_contains "G12 不把 dump 失败误报为语义为空" "语义树无内容" "$OUT"

  # ⑦ dump 持续失败 + auto ⇒ 降级整屏（且说明「这是 dump 失败，不是页面为空」）
  OUT="$(cd "$P" && env "G12_STATE=$G12STATE" "STUB_DUMP_FAIL=1" "STUB_PNG_BYTES=4096" "PATH=$G12BIN:$PATH" bash "$SKILL_DIR/scripts/android/settle.sh" --mode auto --timeout 3 2>&1)"; RC=$?
  expect_rc       "G12 dump 失败 + auto ⇒ 降级后 rc=0" 0 "$RC"
  expect_contains "G12 降级文案区分「dump 失败」" "这是 dump 失败，不是页面为空" "$OUT"

  # ⑧ dump 不完整（<256 B）：--mode ui ⇒ 连续 2 次后 rc=3「持续不完整」，
  #    **不得**把「dump 不可用」说成「语义树无内容」（会把排查引向 Maestro/Vision）
  OUT="$(cd "$P" && env "G12_STATE=$G12STATE" "STUB_DUMP_FILE=$TINY_XML" "PATH=$G12BIN:$PATH" bash "$SKILL_DIR/scripts/android/settle.sh" --mode ui --timeout 12 2>&1)"; RC=$?
  expect_rc       "G12 dump <256B ⇒ 不判静止 rc=3" 3 "$RC"
  [ "$VERBOSE" = "1" ] && echo "$OUT"
  expect_contains "G12 报「dump 不完整」" "dump 不完整" "$OUT"
  expect_contains "G12 标注「持续不完整」" "持续不完整" "$OUT"
  expect_not_contains "G12 不把「不完整」误报为语义为空" "语义树无内容" "$OUT"

  # ⑨ findtap：语义树为空 ⇒ 立即失败（不滑动）且给降级路径
  OUT="$(cd "$P" && env "G12_STATE=$G12STATE" "STUB_DUMP_FILE=$EMPTY_XML" "PATH=$G12BIN:$PATH" bash "$SKILL_DIR/scripts/android/findtap.sh" "OK" --max 3 2>&1)"; RC=$?
  expect_rc       "G12 findtap 语义为空 ⇒ rc=1" 1 "$RC"
  expect_contains "G12 findtap 报「语义树无内容」" "语义树无内容" "$OUT"
  expect_contains "G12 findtap 给 Maestro 降级路径" "maestro/tap.sh" "$OUT"

  # ⑩ findtap：有语义 ⇒ 命中并点击
  OUT="$(cd "$P" && env "G12_STATE=$G12STATE" "STUB_DUMP_FILE=$HAS_XML" "PATH=$G12BIN:$PATH" bash "$SKILL_DIR/scripts/android/findtap.sh" "OK" --max 2 2>&1)"; RC=$?
  expect_rc       "G12 findtap 有语义 ⇒ rc=0" 0 "$RC"
  expect_contains "G12 findtap 完成点击" "点击完成" "$OUT"

  # ⑪ findtap：ui.sh 失败 ⇒ 走重试，不得误报「语义树无内容」
  OUT="$(cd "$P" && env "G12_STATE=$G12STATE" "STUB_DUMP_FAIL=1" "PATH=$G12BIN:$PATH" bash "$SKILL_DIR/scripts/android/findtap.sh" "OK" --max 1 2>&1)"; RC=$?
  expect_rc       "G12 findtap ui.sh 失败 ⇒ rc=1" 1 "$RC"
  expect_not_contains "G12 findtap 不把 dump 失败误报为语义为空" "语义树无内容" "$OUT"

  # ⑫ ui_has_semantics 契约：畸形（含 NUL）/缺失文件均输出整数、不崩
  N1="$(cd "$P" && env "PATH=$G12BIN:$PATH" bash -c "set -euo pipefail; source '$SKILL_DIR/scripts/android/_common.sh'; ui_has_semantics '$NUL_XML'" 2>&1)"; RC=$?
  expect_rc "G12 ui_has_semantics 含 NUL 不崩" 0 "$RC"
  case "$N1" in ''|*[!0-9]*) FAIL=$((FAIL+1)); FAILED_CASES+=("G12 ui_has_semantics 输出非整数"); printf '  ❌ G12 ui_has_semantics 输出非整数（%s）\n' "$N1" ;; *) PASS=$((PASS+1)); printf '  ✅ G12 ui_has_semantics 输出整数（%s）\n' "$N1" ;; esac
  N2="$(cd "$P" && env "PATH=$G12BIN:$PATH" bash -c "set -euo pipefail; source '$SKILL_DIR/scripts/android/_common.sh'; ui_has_semantics '$TMPROOT/no_such.xml'" 2>&1)"; RC=$?
  expect_rc "G12 ui_has_semantics 缺文件不崩" 0 "$RC"
  case "$N2" in 0) PASS=$((PASS+1)); printf '  ✅ G12 缺文件输出 0\n' ;; *) FAIL=$((FAIL+1)); FAILED_CASES+=("G12 缺文件应输出 0（实为 ${N2}）"); printf '  ❌ G12 缺文件应输出 0（实为 %s）\n' "$N2" ;; esac

  # ⑬ 源码级同源断言：语义判据的属性锚必须同时存在于 _common.sh 与 ui.sh，
  #    防「改了一处正则、另一处静默漂移」（两处形态不同但锚必须一致）。
  for PAT in '[[:space:]]text="' '[[:space:]]content-desc="'; do
    if grep -qF -- "$PAT" "$SKILL_DIR/scripts/android/_common.sh" && grep -qF -- "$PAT" "$SKILL_DIR/scripts/android/ui.sh"; then
      PASS=$((PASS+1)); printf '  ✅ G12 判据锚同源: %s\n' "$PAT"
    else
      FAIL=$((FAIL+1)); FAILED_CASES+=("G12 判据锚不同源: ${PAT}"); printf '  ❌ G12 判据锚不同源: %s\n' "$PAT"
    fi
  done

  # ⑭ 回归：成功 → 失败一次 → 成功，且每帧内容都不同 ⇒ **不得**因「同槽位自比」误判静止。
  #    失败那轮必须清 PREV，否则下一次成功采样轮回到同一 .settle_N.xml 时 cmp 变成自比、恒等。
  #    timeout 12 是为了让第 2 次采样时剩余预算仍 ≥ 单帧上限（否则会先走「预算耗尽」降级分支）。
  rm -f "$G12STATE/cnt"
  OUT="$(cd "$P" && env "G12_STATE=$G12STATE" "STUB_DUMP_FILE=$HAS_XML" "STUB_DUMP_UNIQUE=1" "STUB_FAIL_SEQ=2" "PATH=$G12BIN:$PATH" bash "$SKILL_DIR/scripts/android/settle.sh" --mode ui --timeout 12 --interval 0.1 2>&1)"; RC=$?
  expect_rc       "G12 成功→失败→成功且帧不同 ⇒ 不判静止 rc=1" 1 "$RC"
  expect_contains "G12 混合序列确实发生 dump 失败" "dump 失败（第 1 次）" "$OUT"
  expect_not_contains "G12 混合序列未误报「已静止」" "已静止" "$OUT"

  # ⑮ 截断且无语义（<256 B、0 个 text/desc 节点）+ auto ⇒ 必须降级整屏像素并判静止，
  #    不得误报「语义树无内容」（后者会把排查引向 Maestro/Vision，而真问题是 dump）
  TINY_EMPTY_XML="$TMPROOT/g12_tiny_empty.xml"; printf '%s\n' '<hierarchy/>' > "$TINY_EMPTY_XML"
  OUT="$(cd "$P" && env "G12_STATE=$G12STATE" "STUB_DUMP_FILE=$TINY_EMPTY_XML" "STUB_PNG_BYTES=4096" "PATH=$G12BIN:$PATH" bash "$SKILL_DIR/scripts/android/settle.sh" --mode auto --timeout 12 --interval 0.1 2>&1)"; RC=$?
  expect_rc           "G12 截断+无语义 + auto ⇒ 降级后 rc=0" 0 "$RC"
  expect_contains     "G12 报「持续不完整」并降级" "降级整屏像素" "$OUT"
  expect_contains     "G12 降级后判据=screen" "判据=screen" "$OUT"
  expect_not_contains "G12 不把截断误报为语义为空" "语义树无内容" "$OUT"

  # ⑯ screen 阶段「命令失败」≠「截到但无效」：前者文案指名 screencap，且终报必须说「判据不可用」
  #    而不是「页面在动」（后者会把排查引向 --timeout，真问题却是设备/权限）
  OUT="$(cd "$P" && env "G12_STATE=$G12STATE" "STUB_SCREEN_FAIL=1" "PATH=$G12BIN:$PATH" bash "$SKILL_DIR/scripts/android/settle.sh" --mode screen --timeout 1 2>&1)"; RC=$?
  expect_rc           "G12 screencap 失败 ⇒ rc=1" 1 "$RC"
  expect_contains     "G12 报「screencap 命令失败」" "screencap 命令失败" "$OUT"
  expect_contains     "G12 终报「整屏截图始终不可用」" "整屏截图始终不可用" "$OUT"
  expect_not_contains "G12 不把截图失败说成「截图无效」" "截图无效" "$OUT"

  # ⑰ 对照：截图有效但每帧都在变 ⇒ 走「未静止」正常路径（不得误报「判据不可用」）
  rm -f "$G12STATE/pngcnt"
  OUT="$(cd "$P" && env "G12_STATE=$G12STATE" "STUB_SCREEN_FAIL=0" "STUB_PNG_BYTES=4096" "STUB_PNG_UNIQUE=1" "PATH=$G12BIN:$PATH" bash "$SKILL_DIR/scripts/android/settle.sh" --mode screen --timeout 1 --interval 0.1 2>&1)"; RC=$?
  expect_rc           "G12 截图有效但持续变化 ⇒ 未静止 rc=1" 1 "$RC"
  expect_contains     "G12 报「未静止」" "未静止" "$OUT"
  expect_contains     "G12 判据=screen" "判据=screen" "$OUT"
  expect_not_contains "G12 不误报「整屏截图始终不可用」" "整屏截图始终不可用" "$OUT"
  echo ""
fi

# ---------- 汇总 ----------
TOTAL=$((PASS + FAIL))
echo "────────────────────────────────"
echo "通过: $PASS / $TOTAL"
if [ "$FAIL" -gt 0 ]; then
  echo "失败用例:"
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
[ "$TOTAL" -eq 0 ] && { echo "❌ 未执行任何用例"; exit 2; }
exit 0
