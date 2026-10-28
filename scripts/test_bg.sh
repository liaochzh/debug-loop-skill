#!/bin/bash
# test_bg.sh — bg.sh 回归测试（自包含，无外部依赖，不需真机/模拟器）
#
# 用法:
#   bash <S>/scripts/test_bg.sh          # 全量（默认）
#   bash <S>/scripts/test_bg.sh -v       # 显示每个用例的输出明细
#   bash <S>/scripts/test_bg.sh -f <名字> # 只跑名称含该关键字的用例
#
# 退出码：0=全部通过 / 1=有用例失败 / 2=用法错误或未执行任何用例
#
# 覆盖点：退出码契约 / 参数守卫 / detach 行为 / clamp / usage 边界 / F2 空值路径 /
#         多字节隐患 / 常用子命令。所有用例在临时目录构造假项目，不触碰真实工程。
set -uo pipefail   # 故意不加 -e：单例失败要继续跑完其余用例

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"   # -P：解析软链，确保 ../../ 能回到仓库根
BG="$SCRIPT_DIR/bg.sh"

VERBOSE=0; FILTER=""
while [ $# -gt 0 ]; do
  case "$1" in
    -v) VERBOSE=1; shift ;;
    -f) [ $# -ge 2 ] || { echo "❌ -f 需带分组名" >&2; exit 2; }
        FILTER="$2"; shift 2 ;;
    -h|--help) awk 'NR<3 {next} /^[^#[:space:]]/ {exit} {sub(/^# ?/, ""); print}' "$0"; exit 0 ;;
    *) echo "❌ 未知参数: $1" >&2; exit 2 ;;
  esac
done

PASS=0; FAIL=0; FAILED_CASES=()

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/bgtest.XXXXXX")"
cleanup() {
  # 结束仍在跑的 job 孤儿进程（按 .pid 精确 kill，避免 sleep 300 残留）
  for pf in "$TMPROOT"/*/build/debug/jobs/*.pid; do
    [ -f "$pf" ] || continue
    kp="$(cat "$pf" 2>/dev/null)"
    [ -n "$kp" ] && kill "$kp" 2>/dev/null
  done
  rm -rf "$TMPROOT"
}
trap cleanup EXIT

# 构造假 Flutter 项目：pubspec.yaml + .debug.env + 可包装脚本
new_project() {
  local p="$TMPROOT/$1"
  mkdir -p "$p/build/debug" "$p/tools"
  printf 'name: fake\n' > "$p/pubspec.yaml"
  printf 'LOG_DIR=build/debug\nANDROID_APP_ID=com.test.app\n' > "$p/.debug.env"
  printf '#!/bin/bash\necho "ok $*"\nsleep 1\nexit 0\n'      > "$p/tools/ok.sh"
  printf '#!/bin/bash\necho "boom" >&2\nexit 7\n'                > "$p/tools/fail.sh"
  printf '#!/bin/bash\nsleep 300\n'                               > "$p/tools/slow.sh"
  echo "$p"
}

# 断言：$1 用例名  $2 期望rc  $3 实际rc  [$4 rc输出描述]
expect_rc() {
  local name="$1" want="$2" got="$3" label="${4:-}"
  if [ "$got" = "$want" ]; then
    PASS=$((PASS+1)); printf '  ✅ %s\n' "$name"
  else
    FAIL=$((FAIL+1)); FAILED_CASES+=("$name")
    printf '  ❌ %s（期望 rc=%s，实际 rc=%s %s）\n' "$name" "$want" "$got" "$label"
  fi
}

# 断言输出包含子串
expect_contains() {
  local name="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) PASS=$((PASS+1)); printf '  ✅ %s\n' "$name" ;;
    *) FAIL=$((FAIL+1)); FAILED_CASES+=("$name"); printf '  ❌ %s（输出缺少 "%s"）\n' "$name" "$needle" ;;
  esac
}

# 断言输出不包含子串
expect_not_contains() {
  local name="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) FAIL=$((FAIL+1)); FAILED_CASES+=("$name"); printf '  ❌ %s（输出不应含 "%s"）\n' "$name" "$needle" ;;
    *) PASS=$((PASS+1)); printf '  ✅ %s\n' "$name" ;;
  esac
}

# 断言两值相等（用于非 rc 的数值/字符串核对，如「行数须为 0」）
expect_eq() {
  local name="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then
    PASS=$((PASS+1)); printf '  ✅ %s\n' "$name"
  else
    FAIL=$((FAIL+1)); FAILED_CASES+=("$name")
    printf '  ❌ %s（期望 %s，实际 %s）\n' "$name" "$want" "$got"
  fi
}

# 启动 job 并回显 job_id
start_job() {
  local proj="$1"; shift
  ( cd "$proj" && bash "$BG" start "$@" 2>/dev/null | head -1 | sed 's/.*job_id=//' )
}

should_run() { [ -z "$FILTER" ] || case "$1" in *"$FILTER"*) return 0;; *) return 1;; esac; }

echo "=== bg.sh 回归测试 ==="
echo "脚本: $BG"
[ "$VERBOSE" = 1 ] && echo "（verbose 模式）"
echo ""

# ---------- 1. 静态检查 ----------
if should_run "静态"; then
  echo "[1] 静态检查"
  # 定位版本化钩子：从 scripts 向上找 hooks/pre-commit（兼容 debug-loop 位于仓库任意层级）
  HOOK=""; d="$SCRIPT_DIR"
  for _ in 1 2 3; do d="$(dirname "$d")"; [ -f "$d/hooks/pre-commit" ] && { HOOK="$d/hooks/pre-commit"; break; }; done

  # 收集全部 shell 脚本：scripts/ 下递归 + debug-loop 根（init.sh/dbg.sh）+ 版本化钩子
  sh_files=()
  while IFS= read -r sf; do sh_files+=("$sf"); done < <(find "$SCRIPT_DIR" -type f -name '*.sh' 2>/dev/null | sort)
  DL_ROOT="$(dirname "$SCRIPT_DIR")"
  while IFS= read -r sf; do sh_files+=("$sf"); done < <(find "$DL_ROOT" -maxdepth 1 -type f -name '*.sh' 2>/dev/null | sort)
  [ -f "$HOOK" ] && sh_files+=("$HOOK")

  syn_err=""; syn_ok=1
  for sf in "${sh_files[@]}"; do
    if ! e="$(bash -n "$sf" 2>&1)"; then syn_ok=0; syn_err="${syn_err}${e}"$'\n'; fi
  done
  if [ "$syn_ok" = 1 ]; then PASS=$((PASS+1)); echo "  ✅ 语法检查（${#sh_files[@]} 个脚本）"
  else FAIL=$((FAIL+1)); FAILED_CASES+=("语法检查"); echo "  ❌ 语法检查"; printf '%s\n' "$syn_err" | sed 's/^/       /'; fi

  # macOS bash 3.2 在 UTF-8 locale 下把全角字符并入变量名（反例写法见下，勿原样复制）
  # 扫描全部脚本 + 钩子（任一处「变量名后紧跟非 ASCII」都会在此被拦）
  command -v perl >/dev/null 2>&1 || { echo "❌ 缺少 perl，无法执行多字节扫描" >&2; exit 2; }
  if ! mb=$(perl -ne 'while (/\$([A-Za-z_][A-Za-z0-9_]*)([^\x00-\x7F])/g){print}' "${sh_files[@]}"); then
    echo "❌ 多字节扫描执行失败（perl 非零退出）" >&2; exit 2
  fi
  if [ -z "$mb" ]; then PASS=$((PASS+1)); echo "  ✅ 多字节隐患无命中（全部脚本 + 钩子）"
  else FAIL=$((FAIL+1)); FAILED_CASES+=("多字节隐患")
       echo "  ❌ 多字节隐患命中（变量名后紧跟非 ASCII）："
       printf '%s\n' "$mb" | sed 's/^/       /'; fi
  echo ""
fi

# ---------- 2. usage 边界 ----------
if should_run "usage"; then
  echo "[2] usage 帮助文本"
  u=$(bash "$BG" --help 2>&1)
  expect_not_contains "usage 不泄漏 set -euo pipefail" "$u" "set -euo pipefail"
  expect_not_contains "usage 不泄漏 PROJ_ROOT 赋值"    "$u" 'PROJ_ROOT='
  expect_contains     "usage 含 start 子命令"          "$u" "bg.sh start"
  expect_contains     "usage 含 wait 子命令"           "$u" "bg.sh wait"
  expect_contains     "usage 含退出码契约说明"          "$u" "退出码契约"

  # 动态守卫（关键）：usage 必须按「内容边界」而非行号提取。
  # 做法：删掉头部前 3 行注释，把 set -euo pipefail 拉进硬编码行号区间
  #      （如 sed -n '3,22p'）；若 usage 依赖行号，此时必然泄漏 set 行。
  #      反向（插入注释）只会把 set 推远、不会泄漏，故不能作为守卫方向。
  bgc="$TMPROOT/bg_shift.sh"; u2=""
  awk 'NR>=4 && NR<=6 {next} {print}' "$BG" > "$bgc"
  chmod +x "$bgc"
  u2=$(bash "$bgc" --help 2>&1)
  expect_not_contains "头部注释删减后 usage 仍不泄漏 set 行" "$u2" "set -euo pipefail"
  expect_contains     "删减后 usage 仍保留核心说明"        "$u2" "bg.sh start"
  rm -f "$bgc"
  echo ""
fi

# ---------- 3. 退出码契约 ----------
if should_run "退出码"; then
  echo "[3] 退出码契约"
  P=$(new_project contract)

  J=$(start_job "$P" tools/ok.sh)
  expect_contains "start 返回 job_id" "$J" "20"
  ( cd "$P" && bash "$BG" wait "$J" --timeout 20 >/dev/null 2>&1 ); expect_rc "成功任务 → 0" 0 $?
  ( cd "$P" && bash "$BG" status "$J" >/dev/null 2>&1 );               expect_rc "已完成 status → 0" 0 $?

  JF=$(start_job "$P" tools/fail.sh)
  ( cd "$P" && bash "$BG" wait "$JF" --timeout 20 >/dev/null 2>&1 ); expect_rc "失败任务 → 1" 1 $?

  ( cd "$P" && bash "$BG" status "$JF" >/dev/null 2>&1 );              expect_rc "失败 status → 1" 1 $?

  JS=$(start_job "$P" tools/slow.sh)
  ( cd "$P" && bash "$BG" status "$JS" >/dev/null 2>&1 );              expect_rc "运行中 status → 10" 10 $?
  ( cd "$P" && bash "$BG" wait "$JS" --timeout 1 >/dev/null 2>&1 );    expect_rc "wait 超时未结束 → 10" 10 $?

  ( cd "$P" && bash "$BG" status nonexistent >/dev/null 2>&1 );        expect_rc "job 不存在 → 2" 2 $?
  ( cd "$P" && bash "$BG" wait nonexistent >/dev/null 2>&1 );          expect_rc "wait job 不存在 → 2" 2 $?
  ( cd "$P" && bash "$BG" start tools/nope.sh >/dev/null 2>&1 );       expect_rc "找不到脚本 → 2" 2 $?
  ( cd "$P" && bash "$BG" start /abs/nope.sh >/dev/null 2>&1 );        expect_rc "绝对路径找不到 → 2" 2 $?
  ( cd "$P" && bash "$BG" bogus >/dev/null 2>&1 );                     expect_rc "未知子命令 → 2" 2 $?
  echo ""
fi

# ---------- 4. 参数守卫 ----------
if should_run "参数"; then
  echo "[4] 参数守卫"
  P=$(new_project params)
  J=$(start_job "$P" tools/ok.sh)

  ( cd "$P" && bash "$BG" wait "$J" --interval 0  >/dev/null 2>&1 ); expect_rc "--interval 0 → 2（防死循环）" 2 $?
  ( cd "$P" && bash "$BG" wait "$J" --interval -1 >/dev/null 2>&1 ); expect_rc "--interval 负数 → 2" 2 $?
  ( cd "$P" && bash "$BG" wait "$J" --interval x  >/dev/null 2>&1 ); expect_rc "--interval 非数字 → 2" 2 $?
  ( cd "$P" && bash "$BG" wait "$J" --timeout abc  >/dev/null 2>&1 ); expect_rc "--timeout 非数字 → 2" 2 $?
  ( cd "$P" && bash "$BG" logs "$J" -n abc          >/dev/null 2>&1 ); expect_rc "logs -n 非数字 → 2" 2 $?
  ( cd "$P" && bash "$BG" wait "$J" --timeout      >/dev/null 2>&1 ); expect_rc "--timeout 缺值 → 2" 2 $?
  ( cd "$P" && bash "$BG" start                     >/dev/null 2>&1 ); expect_rc "start 无参数 → 2" 2 $?
  ( cd "$P" && bash "$BG" wait                      >/dev/null 2>&1 ); expect_rc "wait 无参数 → 2" 2 $?
  echo ""
fi

# ---------- 5. clamp 与墙钟 ----------
if should_run "clamp"; then
  echo "[5] 超时截断与墙钟计时"
  P=$(new_project clamp)
  JS=$(start_job "$P" tools/slow.sh)

  # BG_MAX_WAIT 覆盖后可在 3s 内验证截断逻辑，无需真等 110s
  out=$( cd "$P" && BG_MAX_WAIT=3 bash "$BG" wait "$JS" --timeout 600 2>&1 )
  expect_rc        "timeout 超上限 → 截断后返回 10" 10 $?
  expect_contains  "截断时给出警告"        "$out" "已截为 3"
  expect_contains  "提示短轮询累积等待"    "$out" "短轮询"

  # 墙钟语义：timeout=3 的实际耗时应约等于 3s，而非 sleep 累加的偏差值
  t0=$(date +%s)
  ( cd "$P" && BG_MAX_WAIT=3 bash "$BG" wait "$JS" --timeout 3 >/dev/null 2>&1 )
  t1=$(date +%s); el=$(( t1 - t0 ))
  if [ "$el" -ge 3 ] && [ "$el" -le 8 ]; then
    PASS=$((PASS+1)); echo "  ✅ 墙钟计时合理（实测 ${el}s，期望 3~8s）"
  else
    FAIL=$((FAIL+1)); FAILED_CASES+=("墙钟计时"); echo "  ❌ 墙钟计时异常（实测 ${el}s，期望 3~8s）"
  fi

  ( cd "$P" && bash "$BG" wait "$JS" --timeout 0 >/dev/null 2>&1 ); expect_rc "--timeout 0 → 等价一次查询 10" 10 $?
  echo ""
fi

# ---------- 6. detach 与 F2 空值路径 ----------
if should_run "detach"; then
  echo "[6] detach 与错误路径"
  P=$(new_project detach)

  # start 必须在 3s 内返回（detach 生效），而非同步等待任务结束
  t0=$(date +%s)
  ( cd "$P" && bash "$BG" start tools/slow.sh >/dev/null 2>&1 ); src=$?
  t1=$(date +%s); el=$(( t1 - t0 ))
  expect_rc "start 退出码 0" 0 $src
  if [ "$el" -le 3 ]; then PASS=$((PASS+1)); echo "  ✅ start 立即返回（${el}s，任务需 300s）"
  else FAIL=$((FAIL+1)); FAILED_CASES+=("start 立即返回"); echo "  ❌ start 未立即返回（${el}s）"; fi

  # 无 PID 时不得谎报成功：把 JOB_DIR 指向不可写位置模拟启动失败
    badp="$TMPROOT/nowrite"
  mkdir -p "$badp/build/debug/jobs" "$badp/tools"
  printf 'name: f\n' > "$badp/pubspec.yaml"
  printf 'LOG_DIR=build/debug\n' > "$badp/.debug.env"
  printf '#!/bin/bash\nexit 0\n' > "$badp/tools/ok.sh"
  chmod 555 "$badp/build/debug/jobs"
  ( cd "$badp" && bash "$BG" start tools/ok.sh >/dev/null 2>&1 ); wrc=$?
  chmod 755 "$badp/build/debug/jobs"
  expect_rc "JOB_DIR 不可写 → 非 0（不谎报成功）" 1 $wrc

  # 错误提示应落到 stderr（find_script 的中文提示）
  err=$( cd "$P" && bash "$BG" start tools/nope.sh 2>&1 >/dev/null )
  expect_contains "找不到脚本时 stderr 有中文提示" "$err" "找不到脚本"
  echo ""
fi

# ---------- 7. 常用子命令 ----------
if should_run "子命令"; then
  echo "[7] logs / list / 参数透传"
  P=$(new_project cmds)

  J=$(start_job "$P" tools/ok.sh --flavor dev --dart-define=K=V)
  ( cd "$P" && bash "$BG" wait "$J" --timeout 20 >/dev/null 2>&1 )
  lg=$( cd "$P" && bash "$BG" logs "$J" -n 20 2>&1 )
  expect_contains "logs 能读到脚本输出"     "$lg" "ok --flavor dev --dart-define=K=V"
  expect_contains "logs 显示 DONE 状态"     "$lg" "DONE"

  ls=$( cd "$P" && bash "$BG" list 2>&1 )
  expect_contains "list 列出 job"           "$ls" "$J"
  expect_contains "list 显示 DONE"          "$ls" "DONE"

  # 含空格/中文参数必须完整透传
  J=$(start_job "$P" tools/ok.sh "带 空格" "中文参数")
  ( cd "$P" && bash "$BG" wait "$J" --timeout 20 >/dev/null 2>&1 )
  lg=$( cd "$P" && bash "$BG" logs "$J" -n 10 2>&1 )
  expect_contains "空格/中文参数完整透传"   "$lg" "带 空格 中文参数"

  # job_id 含随机后缀仍可查（防同秒覆盖）
  a=$(start_job "$P" tools/ok.sh); b=$(start_job "$P" tools/ok.sh)
  if [ "$a" != "$b" ]; then PASS=$((PASS+1)); echo "  ✅ 连续 start 生成不同 job_id"
  else FAIL=$((FAIL+1)); FAILED_CASES+=("job_id 唯一性"); echo "  ❌ job_id 重复: $a"; fi
  echo ""
fi

# ---------- 8. logwatch 契约（无需真机，只验参数/环境守卫与退出码路径）----------
if should_run "logwatch"; then
  echo "[8] logwatch 契约（rc=2 参数 / rc=3 环境）"
  LW="$SCRIPT_DIR/android/logwatch.sh"
  if [ -f "$LW" ]; then
    # 无参：SIG 为空 → rc=2（参数校验在 source 之前，故任何目录都成立）
    ( cd "$TMPROOT" && bash "$LW" )          >/dev/null 2>&1; expect_rc "logwatch 无参 → rc=2"       2 $?
    ( cd "$TMPROOT" && bash "$LW" sig abc 2 ) >/dev/null 2>&1; expect_rc "logwatch 非数字超时 → rc=2" 2 $?
    ( cd "$TMPROOT" && bash "$LW" sig 60 0 )  >/dev/null 2>&1; expect_rc "logwatch 间隔 0 → rc=2"     2 $?
    # 合法参数但非项目根（TMPROOT 无 pubspec/.debug.env）→ 环境守卫 rc=3，不得伪装成「未命中」rc=1
    ( cd "$TMPROOT" && bash "$LW" sig 1 2 )   >/dev/null 2>&1; expect_rc "logwatch 非项目根 → rc=3"   3 $?
  else
    echo "  (跳过：未找到 $LW)"
  fi
  echo ""
fi

# ---------- 9. android 脚本契约（无需真机：app_pid 退出码 / build.sh 模式缺省）----------
if should_run "android契约"; then
  echo "[9] android 契约（桩 adb / 桩 flutter，无需真机）"
  AP="$(new_project android_contract)"
  # 桩 adb：`shell pidof` 返回 rc=1（模拟「进程不存在」），其余子命令成功空输出
  printf '#!/bin/bash\ncase "$*" in *"shell pidof"*) exit 1;; *) exit 0;; esac\n' > "$AP/tools/adb"
  # 桩 flutter：只回显收到的参数
  printf '#!/bin/bash\necho "FLUTTER_ARGS: $*"\nexit 0\n'                            > "$AP/tools/flutter"
  chmod +x "$AP/tools/adb" "$AP/tools/flutter"

  # 9.1 app_pid 契约（硬门禁：防 `|| true` 被误删 ⇒ 调用方静默终止回归）
  OUT="$( cd "$AP" && PATH="$AP/tools:$PATH" bash -c 'set -euo pipefail; source "'"$SCRIPT_DIR"'/android/_common.sh"; PID=$(app_pid FAKE); printf "PID=[%s]\n" "$PID"; echo "REACHED_AFTER_APP_PID"' 2>&1 )"
  expect_contains "app_pid 未运行 → 流程未被静默终止" "$OUT" "REACHED_AFTER_APP_PID"
  expect_contains "app_pid 未运行 → 输出空串"          "$OUT" "PID=[]"
  ( cd "$AP" && PATH="$AP/tools:$PATH" bash -c 'set -euo pipefail; source "'"$SCRIPT_DIR"'/android/_common.sh"; PID=$(app_pid FAKE)' ) >/dev/null 2>&1
  expect_rc "app_pid 未运行 → rc=0" 0 $?

  # 9.2 build.sh 模式缺省（透传参数但未显式指定模式 ⇒ 必须补 --debug）
  OUT="$( cd "$AP" && PATH="$AP/tools:$PATH" bash "$SCRIPT_DIR/android/build.sh" --flavor dev 2>&1 || true )"
  expect_contains     "build.sh --flavor dev → 补 --debug"   "$OUT" "apk --debug --flavor dev"
  OUT="$( cd "$AP" && PATH="$AP/tools:$PATH" bash "$SCRIPT_DIR/android/build.sh" --release 2>&1 || true )"
  expect_contains     "build.sh --release → 参数确实透传（正向锚）" "$OUT" "FLUTTER_ARGS: build apk --release"
  expect_not_contains "build.sh --release → 不补 --debug"          "$OUT" "--debug"
  OUT="$( cd "$AP" && PATH="$AP/tools:$PATH" bash "$SCRIPT_DIR/android/build.sh" --split-per-abi --profile 2>&1 || true )"
  expect_contains     "build.sh --profile → 参数确实透传（正向锚）" "$OUT" "FLUTTER_ARGS: build apk --split-per-abi --profile"
  expect_not_contains "build.sh --profile → 不补 --debug"          "$OUT" "--debug"
  echo ""
fi

# ---------- 10. 跨平台同类契约（ios/macos：logs.sh 无匹配 / build.sh 模式缺省）----------
if should_run "跨平台契约"; then
  echo "[10] 跨平台同类契约（桩 flutter，无需真机）"
  XP="$(new_project xplat_contract)"
  printf 'IOS_BUNDLE_ID=com.test.ios\nMACOS_APP_NAME=fake\n' >> "$XP/.debug.env"
  printf 'hello line\nsecond line\n' > "$XP/build/debug/app.log"
  # 注：本组只走 ios/macos 路径，下面的桩 adb 实际不被调用（继承自组 9 的无害冗余）
  printf '#!/bin/bash\ncase "$*" in *"shell pidof"*) exit 1;; *) exit 0;; esac\n' > "$XP/tools/adb"
  printf '#!/bin/bash\necho "FLUTTER_ARGS: $*"\nexit 0\n'                             > "$XP/tools/flutter"
  chmod +x "$XP/tools/adb" "$XP/tools/flutter"

  # 10.1 ios/macos logs.sh 关键词无匹配 ⇒ 📭 必须可达且 rc=0（修复前：set -e 静默终止）
  for plat in ios macos; do
    OUT="$( cd "$XP" && bash "$SCRIPT_DIR/$plat/logs.sh" 200 ZZZ_NOMATCH 2>&1 )"; rc=$?
    expect_rc       "$plat/logs.sh 关键词无匹配 → rc=0" 0 $rc
    expect_contains "$plat/logs.sh 无匹配 → 📭 可达"      "$OUT" "📭 无匹配 'ZZZ_NOMATCH' 的日志"
  done

  # 10.2 ios/macos build.sh 透传参数时同样补 --debug（修复前：静默变 release）
  OUT="$( cd "$XP" && PATH="$XP/tools:$PATH" bash "$SCRIPT_DIR/ios/build.sh" --flavor dev 2>&1 || true )"
  expect_contains     "ios/build.sh --flavor dev → 补 --debug"     "$OUT" "FLUTTER_ARGS: build ios --debug --flavor dev"
  expect_contains     "ios/build.sh 默认模拟器 → 自动补 --simulator" "$OUT" "--simulator"
  OUT="$( cd "$XP" && PATH="$XP/tools:$PATH" bash "$SCRIPT_DIR/ios/build.sh" --release --simulator 2>&1 || true )"
  expect_contains     "ios/build.sh --release → 透传（正向锚）"     "$OUT" "FLUTTER_ARGS: build ios --release --simulator"
  expect_not_contains "ios/build.sh --release → 不补 --debug"       "$OUT" "--debug"
  OUT="$( cd "$XP" && PATH="$XP/tools:$PATH" bash "$SCRIPT_DIR/ios/build.sh" --device 2>&1 || true )"
  expect_contains     "ios/build.sh --device → 默认 --profile（iOS 14+ JIT 限制）" "$OUT" "FLUTTER_ARGS: build ios --profile"
  expect_not_contains "ios/build.sh --device → 不带 --simulator"    "$OUT" "FLUTTER_ARGS: build ios --profile --simulator"

  # 10.3 ios 真机采集停止：pid 文件记 UDID、先停后清、清后存活复核
  LOGCLEAR_SRC="$(cat "$SCRIPT_DIR/ios/logclear.sh")"
  COMMON_SRC="$(cat "$SCRIPT_DIR/ios/_common.sh")"
  RUN_SRC="$(cat "$SCRIPT_DIR/ios/run.sh")"
  expect_contains "ios/logclear.sh 支持 --device"          "$LOGCLEAR_SRC" "--device"
  expect_contains "ios/logclear.sh 清 app_device.log"      "$LOGCLEAR_SRC" "app_device.log"
  expect_contains "ios/logclear.sh 调用停止助手"           "$LOGCLEAR_SRC" "stop_ios_syslog_capture"
  expect_contains "ios/logclear.sh 清空后存活复核"         "$LOGCLEAR_SRC" "ios_syslog_capture_running"
  expect_contains "syslog.pid 第2行记 UDID"                "$COMMON_SRC" "sed -n '2p'"
  expect_contains "停止助手按 UDID 定向 pkill"             "$COMMON_SRC" 'pkill -f "idevicesyslog --syslog-relay -u $udid"'
  expect_contains "run.sh 写 pid+UDID 两行"                "$RUN_SRC" '"$!" "$UDID"'
  # 顺序守卫：停采集必须早于清空（挪位后仍应红）
  STOP_LINE=$(grep -n 'stop_ios_syslog_capture' "$SCRIPT_DIR/ios/logclear.sh" | head -1 | cut -d: -f1 || true)
  TRUNC_LINE=$(grep -n ': > "$APP_LOG"' "$SCRIPT_DIR/ios/logclear.sh" | head -1 | cut -d: -f1 || true)
  if [ -n "${STOP_LINE:-}" ] && [ -n "${TRUNC_LINE:-}" ] && [ "$STOP_LINE" -lt "$TRUNC_LINE" ]; then
    PASS=$((PASS+1)); printf '  ✅ %s\n' "ios/logclear.sh 先停采集后清空（行号序）"
  else
    FAIL=$((FAIL+1)); FAILED_CASES+=("ios/logclear.sh 先停采集后清空（行号序）")
    printf '  ❌ %s（stop=%s trunc=%s）\n' "ios/logclear.sh 先停采集后清空（行号序）" "${STOP_LINE:-?}" "${TRUNC_LINE:-?}"
  fi
  OUT="$( cd "$XP" && PATH="$XP/tools:$PATH" bash "$SCRIPT_DIR/macos/build.sh" --flavor dev 2>&1 || true )"
  expect_contains     "macos/build.sh --flavor dev → 补 --debug"   "$OUT" "FLUTTER_ARGS: build macos --debug --flavor dev"
  OUT="$( cd "$XP" && PATH="$XP/tools:$PATH" bash "$SCRIPT_DIR/macos/build.sh" --release 2>&1 || true )"
  expect_contains     "macos/build.sh --release → 透传（正向锚）"   "$OUT" "FLUTTER_ARGS: build macos --release"
  expect_not_contains "macos/build.sh --release → 不补 --debug"     "$OUT" "--debug"

  # 10.4 ios/logs.sh --app-only 过滤 Sandbox/kernel 噪声（行为级：同一份日志两种视图）
  printf '%s\n' \
    'Oct 23 19:17:18 Runner(Flutter)[123] <Notice>: app started' \
    'Oct 23 19:17:18 kernel(Sandbox)[0] <Error>: Sandbox: Runner(123) deny(1) foo' \
    'Oct 23 19:17:19 Runner(libsystem)[123] <Error>: boom' > "$XP/build/debug/app.log"
  OUT="$( cd "$XP" && bash "$SCRIPT_DIR/ios/logs.sh" --app-only 200 2>&1 )"; rc=$?
  expect_rc           "ios/logs.sh --app-only → rc=0" 0 $rc
  expect_contains     "ios/logs.sh --app-only 保留 App 行"         "$OUT" "app started"
  expect_contains     "ios/logs.sh --app-only 摘要保留 App 错误"   "$OUT" "boom"
  expect_not_contains "ios/logs.sh --app-only 过滤 Sandbox 行"     "$OUT" "deny(1)"
  OUT="$( cd "$XP" && bash "$SCRIPT_DIR/ios/logs.sh" 200 2>&1 )"
  expect_contains     "ios/logs.sh 无 --app-only → 仍含全量噪声"   "$OUT" "deny(1)"

  # 10.5 appium 真机：探测必须跳过 Mac 自身；caps 必须带 WDA 签名相关项
  cat > "$XP/tools/xcrun" <<'XEOF'
#!/bin/bash
if [ "$1" = "xctrace" ]; then
cat <<'OUT'
== Devices ==
Testers MacBook Pro (D482C0C0-AF64-534A-ADCC-775D39CF7019)
Test iPhone (26.6.1) (00008101-000000000000001E)
== Simulators ==
iPhone 17e Simulator (27.0) (564710EF-5626-4DF2-B995-8DC225B369F2)
OUT
exit 0
fi
exit 0
XEOF
  chmod +x "$XP/tools/xcrun"
  OUT="$( cd "$XP" && PATH="$XP/tools:$PATH" bash -c "source '$SCRIPT_DIR/appium/_common.sh'; resolve_ios_device" 2>&1 )"
  expect_contains "appium 真机探测跳过 Mac/Xcode 自身" "$OUT" "00008101-000000000000001E"
  OUT="$( cd "$XP" && PATH="$XP/tools:$PATH" IOS_TEAM_ID=TEAM123456 IOS_WDA_BUNDLE_ID=com.test.ios.wda \
        bash -c "source '$SCRIPT_DIR/appium/_common.sh'; write_caps_ios_device '$XP/build/debug/caps.json'; cat '$XP/build/debug/caps.json'" 2>&1 )"
  expect_contains "appium caps 带 updatedWDABundleId"      "$OUT" '"appium:updatedWDABundleId": "com.test.ios.wda"'
  expect_contains "appium caps 允许自动申请描述文件"      "$OUT" '"appium:allowProvisioningDeviceRegistration": true'

  # 10.5b 离线签名路线的 caps：预构建 WDA（usePreinstalledWDA）与 xctestrun（useXctestrunFile）
  OUT="$( cd "$XP" && PATH="$XP/tools:$PATH" IOS_TEAM_ID=TEAM123456 IOS_PREBUILT_WDA=/tmp/fake.app \
        bash -c "source '$SCRIPT_DIR/appium/_common.sh'; write_caps_ios_device '$XP/build/debug/caps2.json'; cat '$XP/build/debug/caps2.json'" 2>&1 )"
  expect_contains "appium caps 预构建 WDA → prebuiltWDAPath"        "$OUT" '"appium:prebuiltWDAPath": "/tmp/fake.app"'
  expect_contains "appium caps 预构建 WDA → usePreinstalledWDA"     "$OUT" '"appium:usePreinstalledWDA": true'
  expect_not_contains "appium caps 预构建 WDA → 不再请求自动描述文件" "$OUT" 'allowProvisioningDeviceRegistration'

  mkdir -p "$XP/build/debug/wda"
  printf '{}\n' > "$XP/build/debug/wda/WebDriverAgentRunner_iphoneos27.1-arm64.xctestrun"
  OUT="$( cd "$XP" && PATH="$XP/tools:$PATH" IOS_TEAM_ID=TEAM123456 \
        IOS_XCTESTRUN="$XP/build/debug/wda/WebDriverAgentRunner_iphoneos27.1-arm64.xctestrun" \
        bash -c "source '$SCRIPT_DIR/appium/_common.sh'; write_caps_ios_device '$XP/build/debug/caps3.json'; cat '$XP/build/debug/caps3.json'" 2>&1 )"
  expect_contains "appium caps xctestrun → useXctestrunFile"        "$OUT" '"appium:useXctestrunFile": true'
  expect_contains "appium caps xctestrun → bootstrapPath 指向产物目录" "$OUT" '"appium:bootstrapPath": "'"$(cd "$XP/build/debug/wda" && pwd)"'"' 
  expect_not_contains "appium caps xctestrun → 不再请求自动描述文件" "$OUT" 'allowProvisioningDeviceRegistration'
  expect_contains "appium caps xctestrun → 备好 appium 认的固定文件名" "$(ls "$XP/build/debug/wda" 2>/dev/null)" "WebDriverAgentRunner_iphoneos-arm64.xctestrun"

  OUT="$( cd "$XP" && PATH="$XP/tools:$PATH" IOS_TEAM_ID=TEAM123456 IOS_PREBUILT_WDA=/tmp/fake.app \
        IOS_XCTESTRUN="$XP/build/debug/wda/WebDriverAgentRunner_iphoneos27.1-arm64.xctestrun" \
        bash -c "source '$SCRIPT_DIR/appium/_common.sh'; write_caps_ios_device '$XP/build/debug/caps5.json'; cat '$XP/build/debug/caps5.json'" 2>&1 )"
  expect_contains     "prebuilt+xctestrun → 提示按 xctestrun 执行"   "$OUT" "按 xctestrun 路线执行"
  expect_not_contains "prebuilt+xctestrun → 不启用 usePreinstalledWDA" "$OUT" "usePreinstalledWDA"
  expect_contains     "prebuilt+xctestrun → 仍走 useXctestrunFile"    "$OUT" '"appium:useXctestrunFile": true'

  OUT="$( cd "$XP" && PATH="$XP/tools:$PATH" IOS_TEAM_ID=TEAM123456 IOS_XCTESTRUN=/nope/x.xctestrun \
        bash -c "source '$SCRIPT_DIR/appium/_common.sh'; write_caps_ios_device '$XP/build/debug/caps4.json'" 2>&1 )"; rc=$?
  expect_rc       "appium caps xctestrun 文件不存在 → rc=1" 1 $rc
  expect_contains "appium caps xctestrun 文件不存在 → 显式报错" "$OUT" "IOS_XCTESTRUN 不存在"

  OUT="$( cd "$XP" && bash "$SCRIPT_DIR/appium/source.sh" --platform ios-device --wait 2>&1 )"; rc=$?
  expect_rc       "source.sh --wait 缺值 → rc=2" 2 $rc
  expect_contains "source.sh --wait 缺值 → 显式报错" "$OUT" "--wait 缺参数值"
  OUT="$( cd "$XP" && bash "$SCRIPT_DIR/appium/source.sh" --platform ios-device --wait abc 2>&1 )"; rc=$?
  expect_rc       "source.sh --wait 非数字 → rc=2" 2 $rc
  expect_contains "source.sh --wait 非数字 → 显式报错" "$OUT" "需为非负数字"

  # 10.5c WDA 离线准备/签名脚本：参数校验不通过时不能静默
  OUT="$( bash "$SCRIPT_DIR/appium/wda_prepare.sh" --profile /tmp/p.mobileprovision 2>&1 )"; rc=$?
  expect_rc       "wda_prepare.sh 缺 team → rc=2" 2 $rc
  expect_contains "wda_prepare.sh 缺 team → 显式报错" "$OUT" "缺 --team-id"
  OUT="$( bash "$SCRIPT_DIR/appium/wda_prepare.sh" --team-id T --profile /nope.p 2>&1 )"; rc=$?
  expect_rc       "wda_prepare.sh 描述文件不存在 → rc=2" 2 $rc
  OUT="$( bash "$SCRIPT_DIR/appium/wda_sign.sh" /nope.app /nope.p 2>&1 )"; rc=$?
  expect_rc       "wda_sign.sh app 不存在 → rc=1" 1 $rc
  expect_contains "wda_sign.sh app 不存在 → 显式报错" "$OUT" "没有 app"

  # 10.6 ios/logs.sh 空视图双文案 / 未知选项 / --app-only+关键词
  : > "$XP/build/debug/app.log"
  OUT="$( cd "$XP" && bash "$SCRIPT_DIR/ios/logs.sh" 5 2>&1 )"
  expect_contains "ios/logs.sh 空日志 → 📭 无日志"              "$OUT" "📭 无日志"
  OUT="$( cd "$XP" && bash "$SCRIPT_DIR/ios/logs.sh" --app-only 5 2>&1 )"
  expect_contains "ios/logs.sh 空日志 --app-only → 专门文案"    "$OUT" "📭 无 App 日志"
  OUT="$( cd "$XP" && bash "$SCRIPT_DIR/ios/logs.sh" --bogus 2>&1 )"; rc=$?
  expect_rc       "ios/logs.sh 未知选项 → rc=2" 2 $rc
  expect_contains "ios/logs.sh 未知选项 → 显式报错"             "$OUT" "未知参数"
  printf '%s\n' \
    'Oct 24 01:00:00 Runner(Flutter)[9] <Notice>: boot ok' \
    'Oct 24 01:00:01 kernel(Sandbox)[0] <Error>: Sandbox: Runner(9) deny(1)' > "$XP/build/debug/app.log"
  OUT="$( cd "$XP" && bash "$SCRIPT_DIR/ios/logs.sh" --app-only 10 boot 2>&1 )"
  expect_contains "ios/logs.sh --app-only + 关键词 → 命中 App 行" "$OUT" "boot ok"
  OUT="$( cd "$XP" && bash "$SCRIPT_DIR/ios/logs.sh" --app-only 10 deny 2>&1 )"
  expect_contains "ios/logs.sh --app-only + 关键词 → 噪声不命中" "$OUT" "📭 无匹配"
  echo ""
fi

# ---------- 11. macOS newest_of 守卫（三平台对称：pipefail 下「非 0 但正常语义」不得触发 errexit）----------
if should_run "newest_of"; then
  echo "[11] macOS newest_of 守卫（无需真机）"
  MP="$(new_project newest_of)"
  printf 'MACOS_APP_NAME=fake\n' >> "$MP/.debug.env"     # macos/_common.sh 加载时要求该变量
  mkdir -p "$MP/pool/old.app" "$MP/pool/new.app"
  touch -t 202001010000 "$MP/pool/old.app"

  # 11.1 候选路径全不存在（模拟 ls→stat 之间被删 / 含空格被 xargs 拆词）⇒ xargs stat 退出 123
  #      修复前：newest_of 内裸管道 + pipefail ⇒ errexit，调用方（resolve_macos_app → build.sh/run.sh）静默死，
  #              「⚠️ 检测到 N 个 .app 候选，自动选最新」友好输出不可达
  POOL_BAD=$'/tmp/__dl_no_such_a.app\n/tmp/__dl_no_such_b.app'
  OUT="$( cd "$MP" && bash -c 'set -euo pipefail; source "$1/macos/_common.sh"; v=$(newest_of "$2"); echo "REACHED newest=[$v]"' _ "$SCRIPT_DIR" "$POOL_BAD" 2>&1 )"; rc=$?
  expect_rc       "macos newest_of 候选全失效 → rc=0（不 errexit）" 0 $rc
  expect_contains "macos newest_of 候选全失效 → 后续语句可达"       "$OUT" "REACHED"
  expect_contains "macos newest_of 候选全失效 → 输出空串"           "$OUT" "newest=[]"

  # 11.2 正向锚：守卫不得把「真选出最新」也一并吞掉
  POOL_OK="$MP/pool/old.app"$'\n'"$MP/pool/new.app"
  OUT="$( cd "$MP" && bash -c 'set -euo pipefail; source "$1/macos/_common.sh"; newest_of "$2"' _ "$SCRIPT_DIR" "$POOL_OK" 2>&1 )"
  expect_contains "macos newest_of 正常候选 → 仍选最新（正向锚）"   "$OUT" "$MP/pool/new.app"
  echo ""
fi

# ---------- 12. 守卫内移（appium / maestro / vision：函数体裸管道 ⇒ 异常不得致调用方 errexit）----------
if should_run "守卫内移"; then
  echo "[12] 守卫内移（桩 xcrun/adb/osascript，无需真机）"
  GP="$(new_project guard_inner)"
  printf 'IOS_BUNDLE_ID=com.test.ios\nMACOS_APP_NAME=fake\n' >> "$GP/.debug.env"
  # 桩：三条外部命令一律失败 ⇒ 模拟「无 iOS 真机 / 无设备 / osascript 不可用」
  for t in xcrun adb osascript; do printf '#!/bin/bash\nexit 1\n' > "$GP/tools/$t"; done
  chmod +x "$GP/tools/xcrun" "$GP/tools/adb" "$GP/tools/osascript"

  # 12.1-12.3 异常路径（修复前：rc=1、输出空 —— errexit 静默终止）
  OUT="$( cd "$GP" && PATH="$GP/tools:$PATH" bash -c 'set -euo pipefail; source "$1/appium/_common.sh"; d=$(resolve_ios_device); printf "D=[%s]\n" "$d"; echo "REACHED"' _ "$SCRIPT_DIR" 2>&1 )"; rc=$?
  expect_rc       "appium resolve_ios_device 无真机 → rc=0（不 errexit）" 0 $rc
  expect_contains "appium resolve_ios_device 无真机 → 后续可达"           "$OUT" "REACHED"
  expect_contains "appium resolve_ios_device 无真机 → 输出空串"           "$OUT" "D=[]"

  OUT="$( cd "$GP" && PATH="$GP/tools:$PATH" bash -c 'set -euo pipefail; source "$1/maestro/_common.sh"; d=$(resolve_device android); printf "D=[%s]\n" "$d"; echo "REACHED"' _ "$SCRIPT_DIR" 2>&1 )"; rc=$?
  expect_rc       "maestro resolve_device(android) 无设备 → rc=0（不 errexit）" 0 $rc
  expect_contains "maestro resolve_device(android) 无设备 → 后续可达"           "$OUT" "REACHED"
  expect_contains "maestro resolve_device(android) 无设备 → 输出空串"           "$OUT" "D=[]"

  OUT="$( cd "$GP" && PATH="$GP/tools:$PATH" bash -c 'set -euo pipefail; source "$1/vision/smart_lib.sh"; p=$(sl_screen_points); printf "P=[%s]\n" "$p"; echo "REACHED"' _ "$SCRIPT_DIR" 2>&1 )"; rc=$?
  expect_rc       "vision sl_screen_points osascript 不可用 → rc=0（不 errexit）" 0 $rc
  expect_contains "vision sl_screen_points osascript 不可用 → 后续可达"           "$OUT" "REACHED"
  expect_contains "vision sl_screen_points osascript 不可用 → 输出空串"           "$OUT" "P=[]"

  # 12.4-12.7 正向锚：正常输出不得被守卫吞掉
  printf '#!/bin/bash\ncase "$*" in *"xctrace list devices"*) printf "== Devices ==\\nmyiPhone (17.0) (00008110-001A2B3C4D5E801E)\\n== Simulators ==\\n";; *devices*booted*) echo "    ABCDEF01-2345-6789-ABCD-EF0123456789 (Booted)";; *) exit 0;; esac\n' > "$GP/tools/xcrun"
  printf '#!/bin/bash\n[ "$*" = "devices" ] && printf "List of devices attached\\nR58M00TEST1 device\\n" || exit 1\n' > "$GP/tools/adb"
  printf '#!/bin/bash\necho "0, 0, 1440, 900"\n' > "$GP/tools/osascript"
  chmod +x "$GP/tools/xcrun" "$GP/tools/adb" "$GP/tools/osascript"

  OUT="$( cd "$GP" && PATH="$GP/tools:$PATH" bash -c 'set -euo pipefail; source "$1/appium/_common.sh"; resolve_ios_device' _ "$SCRIPT_DIR" 2>&1 )"
  expect_contains "appium 有 iOS 真机 → 仍解析 UDID（正向锚）"      "$OUT" "00008110-001A2B3C4D5E801E"
  OUT="$( cd "$GP" && PATH="$GP/tools:$PATH" bash -c 'set -euo pipefail; source "$1/maestro/_common.sh"; resolve_device android' _ "$SCRIPT_DIR" 2>&1 )"
  expect_contains "maestro 有 Android 设备 → 仍解析设备号（正向锚）" "$OUT" "R58M00TEST1"
  OUT="$( cd "$GP" && PATH="$GP/tools:$PATH" bash -c 'set -euo pipefail; source "$1/maestro/_common.sh"; resolve_device ios' _ "$SCRIPT_DIR" 2>&1 )"
  expect_contains "maestro 有 iOS 模拟器 → 仍解析 UDID（正向锚）"    "$OUT" "ABCDEF01-2345-6789-ABCD-EF0123456789"
  OUT="$( cd "$GP" && PATH="$GP/tools:$PATH" bash -c 'set -euo pipefail; source "$1/vision/smart_lib.sh"; sl_screen_points' _ "$SCRIPT_DIR" 2>&1 )"
  expect_contains "vision osascript 正常 → 仍解析尺寸（正向锚）"     "$OUT" "1440 900"
  echo ""
fi

# ---------- 13. 形态清单清扫 v3（adb 瞬时失败 / 空 glob / SIGPIPE ⇒ 异常不得致调用方 errexit）----------
# 形态清单（两轴：位置 × 命令）与逐形态判据见 docs/plan/20261017-debugloop-guard-inventory.md
if should_run "形态清单"; then
  echo "[13] 形态清单清扫 v3（桩 adb，无需真机）"
  GP="$(new_project forms_sweep)"

  # 桩 1：`shell getprop` 退 1 = 模拟 adb 瞬时失败（offline 竞态）；其余子命令正常 ⇒ 模拟「设备在但 getprop 那次调用失败」
  printf '#!/bin/bash\ncase "$*" in\n  *"shell getprop"*) exit 1 ;;\n  *"shell pidof"*) echo 1234 ;;\n  *"--pid="*) echo LOGCAT_WITH_PID ;;\n  *logcat*) echo LOGCAT_FULL ;;\n  *devices*) printf "List of devices attached\\nR58M00TEST1 device\\n" ;;\n  *) exit 0 ;;\nesac\n' > "$GP/tools/adb"
  chmod +x "$GP/tools/adb"

  # 13.1-13.4 异常路径（修复前：rc=1，输出止于「📦 App: …」—— 第 33 行 errexit 静默终止）
  OUT="$( cd "$GP" && PATH="$GP/tools:$PATH" bash "$SCRIPT_DIR/android/logs.sh" 2>&1 )"; rc=$?
  expect_rc       "13.1 logs.sh getprop 失败 → rc=0（不 errexit）" 0 $rc
  expect_contains "13.1 logs.sh getprop 失败 → 降级提示可达"        "$OUT" "Android < 7.0"
  expect_contains "13.1 logs.sh getprop 失败 → 全量 logcat 已抓"     "$OUT" "LOGCAT_FULL"
  expect_contains "13.1 logs.sh getprop 失败 → 完整日志路径可达"     "$OUT" "📁 完整日志"

  # 13.5-13.7 正向锚：getprop 正常时必须仍走 --pid 过滤（守卫不得吞掉正常语义）
  printf '#!/bin/bash\ncase "$*" in\n  *"shell getprop"*) echo 24 ;;\n  *"shell pidof"*) echo 1234 ;;\n  *"--pid="*) echo LOGCAT_WITH_PID ;;\n  *logcat*) echo LOGCAT_FULL ;;\n  *devices*) printf "List of devices attached\\nR58M00TEST1 device\\n" ;;\n  *) exit 0 ;;\nesac\n' > "$GP/tools/adb"
  chmod +x "$GP/tools/adb"
  OUT="$( cd "$GP" && PATH="$GP/tools:$PATH" bash "$SCRIPT_DIR/android/logs.sh" 2>&1 )"; rc=$?
  expect_rc            "13.5 logs.sh getprop=24 → rc=0"                    0 $rc
  expect_contains      "13.5 logs.sh getprop=24 → 走 --pid 路径（正向锚）"  "$OUT" "LOGCAT_WITH_PID"
  expect_not_contains  "13.5 logs.sh getprop=24 → 不误入降级（正向锚）"     "$OUT" "Android < 7.0"

  # 13.8-13.9 源码级防误删断言（行为级不可确定性触发：13.8 需上游候选 >20 **且**输出超管道缓冲（64KB）；
  #          13.9 需 count→ls 之间候选被删光的竞态。故此处只拦「守卫被误删」这一主回归风险，不代表行为已验。）
  SRC_TAP="$(cat "$SCRIPT_DIR/android/tap.sh")"
  SRC_IOS="$(cat "$SCRIPT_DIR/ios/_common.sh")"
  expect_contains "13.8 tap.sh 候选清单管道守卫在（源码级防误删）" "$SRC_TAP" "head -20 || true"
  expect_contains "13.9 ios/_common.sh 候选清单守卫在（源码级防误删）" "$SRC_IOS" "ls -d \"\$sim_dir\"/*.app | sed 's/^/     - /' >&2 || true"

  # 13.10 sl_shot 失败可见性（P2-A：`shot.sh` 的 ❌ **打 stdout**，裸 `>/dev/null` 会连它一起吞
  #   ⇒ 调用方 `IMG=$(sl_shot)` **rc=0 静默「成功」**、沿用**陈旧 screen.png**（详见落档 §3.7）；
  #   对照 `sl_vision` 打 stderr 故不受影响）
  printf 'MACOS_APP_NAME=fake\n' >> "$GP/.debug.env"
  printf '#!/bin/bash\nexit 1\n' > "$GP/tools/screencapture"   # 桩：模拟「无屏幕录制权限」⇒ shot.sh 走 else 分支
  chmod +x "$GP/tools/screencapture"
  OUT="$( cd "$GP" && PATH="$GP/tools:$PATH" bash -c 'set -euo pipefail; source "$1/macos/_common.sh"; source "$1/vision/smart_lib.sh"; p=$(sl_shot); printf "P=[%s]\n" "$p"' _ "$SCRIPT_DIR" 2>&1 )"; rc=$?
  expect_rc       "13.10 sl_shot 截图失败 → rc=3（与 sl_vision 同约定）"            3 $rc
  expect_contains "13.10 sl_shot 截图失败 → shot.sh 的 ❌ 可达（原被 >/dev/null 吞）" "$OUT" "❌ 截图失败"
  expect_contains "13.10 sl_shot 截图失败 → 屏幕录制权限引导可达"                    "$OUT" "屏幕录制"

  # 13.13 logs.sh logcat 失败可见性（P2-B：裸 `adb logcat … 2>/dev/null` 静默死、零提示）
  #   桩令 logcat **退 7**（非 1）：改前 rc 会随 adb 漂移成 7，改后由 `|| { … exit 1; }` 钉死 1 ⇒ 该断言具判别力
  #   （2026-10-17 第 2 轮复审 P3-7 命中：原桩退 1，改前后同值 ⇒ 断言无判别力）
  printf '#!/bin/bash\ncase "$*" in\n  *"shell getprop"*) exit 1 ;;\n  *"shell pidof"*) echo 1234 ;;\n  *logcat*) exit 7 ;;\n  *devices*) printf "List of devices attached\\nR58M00TEST1 device\\n" ;;\n  *) exit 0 ;;\nesac\n' > "$GP/tools/adb"
  chmod +x "$GP/tools/adb"
  OUT="$( cd "$GP" && PATH="$GP/tools:$PATH" bash "$SCRIPT_DIR/android/logs.sh" 2>&1 )"; rc=$?
  expect_rc       "13.13 logs.sh logcat 失败（降级分支）→ rc=1（桩退 7 ⇒ 守卫钉 1，判别力在 rc 本身）" 1 $rc
  expect_contains "13.13 logs.sh logcat 失败 → ❌ 提示可达（原为静默死）"              "$OUT" "logcat 抓取失败"

  # 13.14×2 **正向档覆盖**（第 2 轮复审 P2-1 命中：13.13 令 getprop 退 1 ⇒ SDK 空 ⇒ **恒走 else 降级分支**，
  #   使 `--pid` 分支新增的 `|| { … }` 零行为级覆盖 —— 单独删它全量仍全绿）
  printf '#!/bin/bash\ncase "$*" in\n  *"shell getprop"*) echo 24 ;;\n  *"shell pidof"*) echo 1234 ;;\n  *"--pid="*) exit 1 ;;\n  *logcat*) echo LOGCAT_FULL ;;\n  *devices*) printf "List of devices attached\\nR58M00TEST1 device\\n" ;;\n  *) exit 0 ;;\nesac\n' > "$GP/tools/adb"
  chmod +x "$GP/tools/adb"
  OUT="$( cd "$GP" && PATH="$GP/tools:$PATH" bash "$SCRIPT_DIR/android/logs.sh" 2>&1 )"; rc=$?
  expect_rc       "13.14 logs.sh logcat 失败（Android 7+ / --pid 分支）→ rc=1（原为 adb 的 rc 漂移）" 1 $rc
  expect_contains "13.14 logs.sh logcat 失败（--pid 分支）→ ❌ 提示可达"                          "$OUT" "logcat 抓取失败"

  # 13.15 resolve_apk 的「`&&` 末项」守卫（P2-C：目录被并发清理的竞态，行为级不可确定性触发 ⇒ 源码级防误删）
  SRC_ANDROID_COMMON="$(cat "$SCRIPT_DIR/android/_common.sh")"
  expect_contains "13.15 android/_common.sh \`&&\` 末项赋值守卫在（源码级防误删）" "$SRC_ANDROID_COMMON" 'ls "$apk_dir"/*.apk || true)'
  echo ""
fi

# ---------- 组 14：android/ui.sh 解析 + tap.sh 文本路径 ----------
if should_run "ui 解析"; then
  echo "--- 组 14：ui.sh 解析（TSV）与 tap.sh 文本路径 ---"
  GP="$(new_project ui_parse)"
  printf 'MACOS_APP_NAME=fake\n' >> "$GP/.debug.env"

  # 形态 A：每行一节点 ｜ 形态 B：**单行压缩** —— 内容等价。修法取「字段级」⇒ **两种行形态都必须产出 2 行**
  # （2026-10-17 plan-review Q-1 命中：记录级实现只在形态 A 成立，形态 B 下漏报 —— 真机行形态此前未知）
  cat > "$GP/uiA.xml" <<'XML'
<?xml version='1.0' encoding='UTF-8'?>
<hierarchy rotation="0">
  <node index="0" text="登录" resource-id="com.x:id/btn" class="android.widget.Button" package="com.x" content-desc="" checkable="false" checked="false" clickable="true" enabled="true" focusable="true" bounds="[100,200][300,280]" />
  <node index="1" text="" resource-id="" class="android.view.View" package="com.x" content-desc="设置" checkable="false" checked="false" clickable="true" enabled="true" bounds="[0,0][50,50]" />
  <node index="2" text="标题" resource-id="" class="android.widget.TextView" package="com.x" content-desc="" clickable="false" bounds="[10,10][90,40]" />
</hierarchy>
XML
  printf '<hierarchy rotation="0"><node index="0" text="登录" resource-id="com.x:id/btn" class="android.widget.Button" package="com.x" content-desc="" clickable="true" enabled="true" bounds="[100,200][300,280]" /><node index="1" text="" resource-id="" class="android.view.View" package="com.x" content-desc="设置" clickable="true" enabled="true" bounds="[0,0][50,50]" /><node index="2" text="标题" class="android.widget.TextView" package="com.x" content-desc="" clickable="false" bounds="[10,10][90,40]" /></hierarchy>\n' > "$GP/uiB.xml"

  # 桩 adb：dump 成功、`pull` 把夹具（经 $AB3_UI_XML 注入）落到目标路径、设备在线、input tap 成功
  printf '#!/bin/bash\ncase "$*" in\n  *"uiautomator dump"*) echo "UI hierchary dumped to: /sdcard/ui.xml" ;;\n  *"pull"*) last=""; for a in "$@"; do last="$a"; done; cp "$AB3_UI_XML" "$last" ;;\n  *devices*) printf "List of devices attached\\nR58M00TEST1 device\\n" ;;\n  *"shell input tap"*) echo "TAP $*" ;;\n  *) exit 1 ;;\nesac\n' > "$GP/tools/adb"
  chmod +x "$GP/tools/adb"

  # 14.1-14.8 双形态红/绿
  for form in A B; do
    [ "$form" = A ] && base=0 || base=4
    OUT="$( cd "$GP" && AB3_UI_XML="$GP/ui$form.xml" PATH="$GP/tools:$PATH" bash "$SCRIPT_DIR/android/ui.sh" 2>&1 )"; rc=$?
    case "$form" in A) OUTA="$OUT" ;; B) OUTB="$OUT" ;; esac
    expect_rc       "14.$((base+1)) ui.sh 形态$form → rc=0" 0 $rc
    expect_contains "14.$((base+2)) ui.sh 形态$form → TSV 第 1 行（text 节点，含真中心坐标）"    "$OUT" '登录 | [100,200][300,280] | 200 240'
    expect_contains "14.$((base+3)) ui.sh 形态$form → TSV 第 2 行（仅 desc 节点，含真中心坐标）" "$OUT" '设置 | [0,0][50,50] | 25 25'
    expect_contains "14.$((base+4)) ui.sh 形态$form → count 与实际一致（2 个，非计行塌成 1）" "$OUT" '共 2 个可点击节点'
  done

  # 14.9 count 不得把 `long-clickable="true"` 计入（改前 `grep -c` 会误计）
  printf '<hierarchy rotation="0"><node index="0" text="假" class="android.view.View" clickable="false" long-clickable="true" bounds="[0,0][10,10]" /></hierarchy>\n' > "$GP/uiC.xml"
  OUT="$( cd "$GP" && AB3_UI_XML="$GP/uiC.xml" PATH="$GP/tools:$PATH" bash "$SCRIPT_DIR/android/ui.sh" 2>&1 )"; rc=$?
  expect_contains "14.9 count 不误计 long-clickable（须 0 个）" "$OUT" '共 0 个可点击节点'

  # 14.10 **夹具判别力自查**：改前实现（`gsub` 就地截断）在同一夹具上必须得 0 行 —— 否则本组是空转
  OLDROWS="$(awk -F'[<>]' '
    /<node/ {
      text=""; desc=""; bounds=""; clickable="false"
      for (i=1; i<=NF; i++) {
        if ($i ~ /text=/)         { gsub(/.*text="/, "", $i);         gsub(/".*/, "", $i); text=$i }
        if ($i ~ /content-desc=/) { gsub(/.*content-desc="/, "", $i); gsub(/".*/, "", $i); desc=$i }
        if ($i ~ /bounds=/)       { gsub(/.*bounds="/, "", $i);       gsub(/".*/, "", $i); bounds=$i }
        if ($i ~ /clickable=/)    { gsub(/.*clickable="/, "", $i);    gsub(/".*/, "", $i); clickable=$i }
      }
      if ((text != "" || desc != "") && bounds != "" && clickable == "true") { print }
    }
  ' "$GP/uiA.xml" | wc -l | tr -d ' ')"
  expect_eq "14.10 改前实现同夹具得 0 行（证明本组具判别力，非空转）" 0 "$OLDROWS"

  # 14.11-14.13 `--text` 未命中：rc 钉 1 + ❌ + **候选清单可达且非空**（autoDebug 降级决策依赖它；改前恒空）
  OUT="$( cd "$GP" && AB3_UI_XML="$GP/uiA.xml" PATH="$GP/tools:$PATH" bash "$SCRIPT_DIR/android/tap.sh" --text 决不存在的词 2>&1 )"; rc=$?
  expect_rc       "14.11 tap.sh --text 未命中 → rc=1（不随上游漂移）" 1 $rc
  expect_contains "14.12 tap.sh --text 未命中 → ❌ 未找到 可达" "$OUT" "❌ 未找到"
  expect_contains "14.13 tap.sh --text 未命中 → 候选清单可达且非空（改前恒空）" "$OUT" '登录 | [100,200][300,280] | 200 240'

  # 14.14-14.16 `--text` 命中 → 成功分支（主路径恢复）
  OUT="$( cd "$GP" && AB3_UI_XML="$GP/uiA.xml" PATH="$GP/tools:$PATH" bash "$SCRIPT_DIR/android/tap.sh" --text 登录 2>&1 )"; rc=$?
  expect_rc       "14.14 tap.sh --text 命中 → rc=0" 0 $rc
  expect_contains "14.15 tap.sh --text 命中 → 坐标可达（真中心）" "$OUT" "坐标 (200, 240)"
  expect_contains "14.16 tap.sh --text 命中 → 点击完成" "$OUT" "✅ 点击完成"

  # 14.17-14.19 P3-9 的 **141 路径**（>64KB 候选 ⇒ 上游 `grep` 收 SIGPIPE；夹具**用例内生成**，不依赖 /tmp 资产）
  BIG="$GP/uiBig.xml"
  {
    printf '<hierarchy rotation="0">\n'
    i=0
    while [ $i -lt 2000 ]; do
      printf '<node index="%s" text="按钮%s" class="android.widget.Button" package="com.x" clickable="true" bounds="[0,%s][100,%s]" />\n' "$i" "$i" "$i" "$((i+60))"
      i=$((i+1))
    done
    printf '</hierarchy>\n'
  } > "$BIG"
  BIGSZ=$(wc -c < "$BIG" | tr -d ' ')
  expect_eq "14.17 大 dump 夹具 >64KB（SIGPIPE 触发前提，实测 ${BIGSZ}B）" 1 "$([ "$BIGSZ" -gt 65536 ] && echo 1 || echo 0)"
  OUT="$( cd "$GP" && AB3_UI_XML="$BIG" PATH="$GP/tools:$PATH" bash "$SCRIPT_DIR/android/tap.sh" --text 决不存在的词 2>&1 )"; rc=$?
  expect_rc       "14.18 tap.sh 未命中（>64KB 候选）→ rc=1（非 141；管道守卫钉死）" 1 $rc
  expect_contains "14.19 tap.sh 未命中（>64KB 候选）→ 候选清单仍可达（head -20 后上游未被 SIGPIPE 跳过 exit）" "$OUT" "按钮0"

  # 14.20 **真中心锚**（用**不对称** bounds 防巧合）：改前既有缺陷 —— `split(b,c,"[, ]+")` 的正则 FS 在串首
  #   命中分隔符产生空首字段 ⇒ 索引错位 ⇒ 打印 `(y1/2, 真中心X)`。本断言在旧算式下必红（2026-10-17 复审 P1-1）
  printf '<hierarchy rotation="0"><node index="0" text="不对称" class="android.widget.Button" package="com.x" clickable="true" bounds="[100,200][300,400]" /></hierarchy>\n' > "$GP/uiD.xml"
  OUT="$( cd "$GP" && AB3_UI_XML="$GP/uiD.xml" PATH="$GP/tools:$PATH" bash "$SCRIPT_DIR/android/ui.sh" 2>&1 )"; rc=$?
  expect_contains "14.20 中心坐标=真中心 ((100+300)/2,(200+400)/2) = 200 300" "$OUT" '不对称 | [100,200][300,400] | 200 300'

  # 14.21-14.22 §4.3「两类边界」落为用例（Q-8：夹具在用例内生成，不依赖 /tmp）
  printf '<hierarchy rotation="0"><node text="首属性" class="android.widget.Button" clickable="true" bounds="[0,0][9,9]" /><node index="0" resource-id="app:id/text=widget" text="真值" class="android.widget.Button" clickable="true" bounds="[10,20][30,60]" /></hierarchy>\n' > "$GP/uiE.xml"
  OUT="$( cd "$GP" && AB3_UI_XML="$GP/uiE.xml" PATH="$GP/tools:$PATH" bash "$SCRIPT_DIR/android/ui.sh" 2>&1 )"; rc=$?
  # 注：`<node text=…>`（无 index）覆盖「属性顺序变异」；但 `l=" " $i` 前缀在本实现的字段过滤下**不可达**
    #（`^node[[:space:]]` 保证字段以 `node␣` 起头 ⇒ 属性恒有内部空格锚）⇒ 该前缀属**防御性冗余**，
    #  删掉它本用例仍绿（2026-10-17 第 2 轮复审 P3-4 指出，此处如实标注）。
    expect_contains "14.21 属性顺序变异（<node text=… 无 index）不漏取" "$OUT" '首属性 | [0,0][9,9] | 4 4'
  expect_contains "14.22 属性值内含 text= 不误取（resource-id 场景）" "$OUT" '真值 | [10,20][30,60] | 20 40'

  # 14.23 **行数上界**（P3-2：仅「包含」断言拦不住多报 —— clickable=false 的「标题」若被吐出仍会绿）
  ROWS="$(printf '%s\n' "$OUTA" | grep -cE '^.+ \| \[[0-9,-]+\]\[[0-9,-]+\] \| [0-9]+ [0-9]+$')"
  expect_eq "14.23 形态A 恰输出 2 行 TSV（clickable=false 节点不得混入）" 2 "$ROWS"

  # 14.24 **源码级静态断言**：`ui.sh` 的 awk 程序体内不得出现裸单引号 —— 它会提前终止 bash 的单引号
  #   字符串（运行时才报 `No such file or directory`），而 `bash -n` 与 shellcheck **都查不出**（引号成对即
  #   语法合法）。本批实际踩过此坑一次（见 triage §9.6「连带②」）；此处用 `\047` 表示单引号以避开同类陷阱。
  SQN="$(awk '
    /^awk -F/ { inprog=1; next }
    inprog && substr($0,1,1) == "\047" { inprog=0; next }
    inprog { if (index($0, "\047") > 0) n++ }
    END { print n+0 }' "$SCRIPT_DIR/android/ui.sh")"
  expect_eq "14.24 ui.sh 的 awk 程序体裸单引号 = 0（防提前终止 bash 字符串）" 0 "$SQN"

  # 14.25 **特征用例（钉死当前行为，非「正确性」断言）**：属性值**字面以 ` text=` 收尾**的已知反例
  #   （`content-desc="see text="`）会使空格锚误命中 ⇒ label 取脏值。本批**登记不修**（概率极低），此用例
  #   只钉死「坐标与行存在性」，使将来的重构**不能静默改变**该行为（第 2 轮复审 P3-5 建议）。
  printf '<hierarchy rotation="0"><node index="0" content-desc="see text=" text="真值" class="android.widget.Button" clickable="true" bounds="[10,20][30,60]" /></hierarchy>\n' > "$GP/uiF.xml"
  OUT="$( cd "$GP" && AB3_UI_XML="$GP/uiF.xml" PATH="$GP/tools:$PATH" bash "$SCRIPT_DIR/android/ui.sh" 2>&1 )"; rc=$?
  expect_contains "14.25 已知反例（未修）仍产出行且坐标正确；label 取脏值属登记局限" "$OUT" ' | [10,20][30,60] | 20 40'

  # 14.26 形态 **B** 的行数上界（P3-6：14.23 只约束了形态 A）
  ROWSB="$(printf '%s\n' "$OUTB" | grep -cE '^.+ \| \[[0-9,-]+\]\[[0-9,-]+\] \| [0-9]+ [0-9]+$')"
  expect_eq "14.26 形态B 恰输出 2 行 TSV（单行压缩下同样不得多报）" 2 "$ROWSB"
  echo ""
fi

# ---------- 组 15：tap.sh 三态可分辨 + 字面匹配（B3，2026-10-18）----------
# 立项理由（B2 档 §5「B3-a/B3-b」）：
#   ① 改前 `--text` 的三失败态**坍缩成同一形态**（dump 级失败 / 页面无可点击节点 / 关键词未命中
#      都只表现为「❌ 未找到 + 空清单」），autoDebug 的降级决策拿不到区分证据；
#   ② 改前关键词走**正则**语义（`grep -i`）⇒ 含元字符时 rc=2 被 `|| true` 吞（误报「未找到」）、
#      且 `a.c` 会误命中 `abc` 之类的元素。
# 退出码契约：三失败态**统一 rc=1**（只分消息不分码；既有 P2-5 决策 + 组 14.11/14.18 钉死）。
if should_run "tap 三态"; then
  echo "--- 组 15：tap.sh 三态可分辨（dump 级失败 / 页面无节点 / 未命中）与字面匹配 ---"
  GP="$(new_project tap_states)"
  printf 'MACOS_APP_NAME=fake\n' >> "$GP/.debug.env"
  mkdir -p "$GP/tools" "$GP/tools_fail"

  # 成功桩（同组 14）：dump OK / pull 落夹具（经 $AB3_UI_XML 注入）/ 设备在线 / input tap OK
  printf '#!/bin/bash\ncase "$*" in\n  *"uiautomator dump"*) echo "UI hierchary dumped to: /sdcard/ui.xml" ;;\n  *"pull"*) last=""; for a in "$@"; do last="$a"; done; cp "$AB3_UI_XML" "$last" ;;\n  *devices*) printf "List of devices attached\\nR58M00TEST1 device\\n" ;;\n  *"shell input tap"*) echo "TAP $*" ;;\n  *) exit 1 ;;\nesac\n' > "$GP/tools/adb"
  # 失败桩：**仅** dump 分支非 0（失败点严格落在 dump 级，排除设备/拉取分支混入）
  printf '#!/bin/bash\ncase "$*" in\n  *"uiautomator dump"*) exit 1 ;;\n  *"pull"*) last=""; for a in "$@"; do last="$a"; done; cp "$AB3_UI_XML" "$last" ;;\n  *devices*) printf "List of devices attached\\nR58M00TEST1 device\\n" ;;\n  *"shell input tap"*) echo "TAP $*" ;;\n  *) exit 1 ;;\nesac\n' > "$GP/tools_fail/adb"
  chmod +x "$GP/tools/adb" "$GP/tools_fail/adb"

  # 夹具 1（4 个可点击节点）：登录 + **字面** abc + **字面** A|B + **字面** -x
  #   用途：abc ⇒ 15.13 的字面/正则判别；A|B ⇒ 含 `|` 的字面正向锚；-x ⇒ `--` 生效锚
  printf '<hierarchy rotation="0"><node index="0" text="登录" class="android.widget.Button" package="com.x" clickable="true" enabled="true" bounds="[100,200][300,280]" /><node index="1" text="abc" class="android.widget.Button" package="com.x" clickable="true" enabled="true" bounds="[0,0][20,20]" /><node index="2" text="A|B" class="android.widget.Button" package="com.x" clickable="true" enabled="true" bounds="[30,30][50,50]" /><node index="3" text="-x" class="android.widget.Button" package="com.x" clickable="true" enabled="true" bounds="[60,60][80,80]" /></hierarchy>\n' > "$GP/ui15ok.xml"
  # 夹具 2：只有 clickable=false 节点 ⇒ ui.sh rc=0 但 TSV 0 行（「页面无节点」态）
  printf '<hierarchy rotation="0"><node index="0" text="标题" class="android.widget.TextView" package="com.x" clickable="false" bounds="[10,10][90,40]" /></hierarchy>\n' > "$GP/ui15empty.xml"

  # 15.1-15.3 **dump 级失败**态：rc 仍 1，但文案可辨 + ui.sh 原文透传（证据不丢）
  OUT="$( cd "$GP" && AB3_UI_XML="$GP/ui15ok.xml" PATH="$GP/tools_fail:$PATH" bash "$SCRIPT_DIR/android/tap.sh" --text 登录 2>&1 )"; rc=$?
  expect_rc       "15.1 dump 级失败（ui.sh rc≠0）→ rc=1（三失败态统一 1，不分码）" 1 $rc
  expect_contains "15.2 dump 级失败 → 「无法获取 UI」文案可达（改前与未命中同形）" "$OUT" "❌ 无法获取 UI（ui.sh rc="
  expect_contains "15.3 dump 级失败 → ui.sh 原文透传（末 5 行哨兵，定位证据不丢）" "$OUT" "uiautomator dump 失败"

  # 15.4-15.6 **页面无节点**态（ui.sh rc=0 且 TSV 0 行）：须与「未命中」互斥
  OUT="$( cd "$GP" && AB3_UI_XML="$GP/ui15empty.xml" PATH="$GP/tools:$PATH" bash "$SCRIPT_DIR/android/tap.sh" --text 决不存在的词 2>&1 )"; rc=$?
  expect_rc       "15.4 页面无节点（rc=0 且 TSV 0 行）→ rc=1" 1 $rc
  expect_contains "15.5 页面无节点 → 「页面无可点击节点」文案可达" "$OUT" "❌ 页面无可点击节点"
  expect_eq       "15.6 页面无节点 ≠ 未命中（不得混报「未找到」，三态互斥）" 0 "$(printf '%s\n' "$OUT" | grep -c '❌ 未找到' || true)"

  # 15.7-15.12 **未命中 / 命中**（回归：主路径与候选清单证据不得被新分支改坏）
  OUT="$( cd "$GP" && AB3_UI_XML="$GP/ui15ok.xml" PATH="$GP/tools:$PATH" bash "$SCRIPT_DIR/android/tap.sh" --text 决不存在的词 2>&1 )"; rc=$?
  expect_rc       "15.7 未命中（有 TSV 行）→ rc=1（既有契约未变）" 1 $rc
  expect_contains "15.8 未命中 → ❌ 未找到 可达" "$OUT" "❌ 未找到"
  expect_contains "15.9 未命中 → 候选清单可达且含真中心坐标" "$OUT" '登录 | [100,200][300,280] | 200 240'
  OUT="$( cd "$GP" && AB3_UI_XML="$GP/ui15ok.xml" PATH="$GP/tools:$PATH" bash "$SCRIPT_DIR/android/tap.sh" --text 登录 2>&1 )"; rc=$?
  expect_rc       "15.10 命中 → rc=0（主路径回归）" 0 $rc
  expect_contains "15.11 命中 → 坐标 (200, 240) 可达" "$OUT" "坐标 (200, 240)"
  expect_contains "15.12 命中 → ✅ 点击完成 可达" "$OUT" "✅ 点击完成"

  # 15.13-15.14 **字面匹配锚**（B3-a）：夹具含 abc 但不含 a.c ⇒ 字面语义必须不命中
  OUT="$( cd "$GP" && AB3_UI_XML="$GP/ui15ok.xml" PATH="$GP/tools:$PATH" bash "$SCRIPT_DIR/android/tap.sh" --text 'a.c' 2>&1 )"; rc=$?
  expect_rc       "15.13 字面语义：a.c 不得命中 abc（正则语义会误命中）→ rc=1" 1 $rc
  GREP_RE=0; printf 'abc\n' | grep -i 'a.c' >/dev/null || GREP_RE=$?
  GREP_LIT=0; printf 'abc\n' | grep -iF 'a.c' >/dev/null || GREP_LIT=$?
  expect_eq       "15.14 判别力自查：同串下正则命中(0)/字面不命中(1) ⇒ 15.13 非空转" "0/1" "${GREP_RE}/${GREP_LIT}"

  # 15.15 含 `|` 的字面正向锚（证明 `-F` 未把匹配力砍掉）
  OUT="$( cd "$GP" && AB3_UI_XML="$GP/ui15ok.xml" PATH="$GP/tools:$PATH" bash "$SCRIPT_DIR/android/tap.sh" --text 'A|B' 2>&1 )"; rc=$?
  expect_rc       "15.15 字面正向锚：关键词含 | 仍命中（非正则语义的正向对照）→ rc=0" 0 $rc

  # 15.16-15.17 `--` 生效：关键词以 `-` 开头须按字面（改前 `grep -i -x` = 整行匹配 ⇒ 不命中）
  OUT="$( cd "$GP" && AB3_UI_XML="$GP/ui15ok.xml" PATH="$GP/tools:$PATH" bash "$SCRIPT_DIR/android/tap.sh" --text '-x' 2>&1 )"; rc=$?
  expect_rc       "15.16 「--」生效：-x 按字面命中（改前整行匹配语义下会「未找到」）→ rc=0" 0 $rc
  expect_eq       "15.17 无 grep 选项错误（输出不含 'grep:'）" 0 "$(printf '%s\n' "$OUT" | grep -c 'grep:' || true)"

  # 15.18-15.20 源码级防误删（含沿用 13.8 意图的候选清单守卫）
  SRC_TAP="$(cat "$SCRIPT_DIR/android/tap.sh")"
  expect_contains "15.18 源码级：关键词匹配用 grep -iF --（防误改回正则或丢 --）" "$SRC_TAP" 'grep -iF -- "$KEYWORD"'
  expect_eq       "15.19 源码级：三态文案齐全（两短语须**各** ≥1 次）" "1/1" \
    "$(printf '%s\n' "$SRC_TAP" | grep -qF '❌ 无法获取 UI' && echo 1 || echo 0)/$(printf '%s\n' "$SRC_TAP" | grep -qF '❌ 页面无可点击节点' && echo 1 || echo 0)"
  expect_contains "15.20 源码级：候选清单管道守卫在（head -20 || true；改前恒空）" "$SRC_TAP" "head -20 || true"

  # 15.21-15.22 **大 dump 回归**（>64KB 未命中）：新分支不得引入 141/2/3 穿透
  BIG="$GP/ui15Big.xml"
  {
    printf '<hierarchy rotation="0">\n'
    i=0
    while [ $i -lt 2000 ]; do
      printf '<node index="%s" text="按钮%s" class="android.widget.Button" package="com.x" clickable="true" bounds="[0,%s][100,%s]" />\n' "$i" "$i" "$i" "$((i+60))"
      i=$((i+1))
    done
    printf '</hierarchy>\n'
  } > "$BIG"
  OUT="$( cd "$GP" && AB3_UI_XML="$BIG" PATH="$GP/tools:$PATH" bash "$SCRIPT_DIR/android/tap.sh" --text 决不存在的词 2>&1 )"; rc=$?
  expect_rc       "15.21 大 dump（>64KB）未命中 → rc=1（新分支不得引入 141/其它码）" 1 $rc
  expect_contains "15.22 大 dump → 候选清单仍可达（head -20 后上游未被 SIGPIPE 跳过 exit）" "$OUT" "按钮0"

  # 15.23 **大小写不敏感行为锚**（review P2-2：原夹具文本与关键词同案 ⇒ `-i` 无行为测试）
  #   夹具含 `abc` ⇒ `--text ABC` 必须命中（若 `-i` 被删则此条必红）
  OUT="$( cd "$GP" && AB3_UI_XML="$GP/ui15ok.xml" PATH="$GP/tools:$PATH" bash "$SCRIPT_DIR/android/tap.sh" --text ABC 2>&1 )"; rc=$?
  expect_rc       "15.23 大小写不敏感：--text ABC 命中 abc（删 -i 必红）→ rc=0" 0 $rc

  # 15.24 态②**解析计数透传**（review P3-6）：无节点夹具下 ui.sh 报 `共 0 个可点击节点`
  #   ⇒ 该行进 tap.sh 输出（N>0 时即可区分「有节点但被 text/desc 过滤」与「确实无节点」）
  OUT="$( cd "$GP" && AB3_UI_XML="$GP/ui15empty.xml" PATH="$GP/tools:$PATH" bash "$SCRIPT_DIR/android/tap.sh" --text 决不存在的词 2>&1 )"; rc=$?
  expect_contains "15.24 态②透传 ui.sh 解析计数（共 0 个可点击节点 ⇒ 可与「被过滤」区分）" "$OUT" "共 0 个可点击节点"

  # 15.25-15.27 label **内含 `|`** 的切分特征用例（B3-d；**钉死当前行为、不改契约**）
  #   由来：显示用 `cut -d'|' -f1` ⇒ label 含 `|` 时显示被截断；而**坐标解析走 `awk` 末两列、不受影响**。
  #   夹具 1 的 `A|B` 节点（index 2，bounds [30,30][50,50] ⇒ 中心 40 40）即该形态 ⇒ 本条把
  #   「坐标仍正确 + 显示被截断」两个事实**特征化**，供将来真出现含 `|` 界面文本时对照（ui.sh:8 已登记该歧义）。
  #   ⚠ review R1 P2-4 修正：首版 15.25 仅断言 rc（`--text` 命中即 0），**测不出坐标解析被改坏**
  #     ⇒ 补 15.26 直断末两列结果（对照 15.11 的 `坐标 (200, 240)`）。
  OUT="$( cd "$GP" && AB3_UI_XML="$GP/ui15ok.xml" PATH="$GP/tools:$PATH" bash "$SCRIPT_DIR/android/tap.sh" --text 'A|B' 2>&1 )"; rc=$?
  expect_rc       "15.25 label 含 | ⇒ 命中 → rc=0" 0 $rc
  expect_contains "15.26 label 含 | ⇒ 坐标取**末尾两列**（40 40），切分不污染坐标（review R1 P2-4）" "$OUT" "坐标 (40, 40)"
  expect_contains "15.27 label 含 | ⇒ 显示标签按 cut -d'|' -f1 **截断为 A**（现状特征化，非契约承诺）" "$OUT" "✅ 匹配到: A ->"
  echo ""
fi

# ---------- 16. 四平台注入面关闭（§11.1：.debug.env 不再 source） ----------
if should_run "注入面"; then
  echo "[16] 四平台 _common.sh 注入面关闭（无需真机）"
  for PLAT in ios macos maestro appium; do
    P="$(new_project inj_$PLAT)"
    case "$PLAT" in
      ios)    printf 'IOS_BUNDLE_ID=com.test.ios\n' > "$P/.debug.env" ;;
      macos)  printf 'MACOS_APP_NAME=fake\n' > "$P/.debug.env" ;;
      *)      printf 'LOG_DIR=build/debug\n' > "$P/.debug.env" ;;
    esac
    # 载荷 1：非 KEY=VALUE 形态 ⇒ 解析器 warn + 忽略，不得执行
    printf 'touch %s/.pwn1\n' "$P" >> "$P/.debug.env"
    # 载荷 2：引号分支 ⇒ 闭合引号后的部分视为行尾注释/丢弃，不得执行
    case "$PLAT" in
      ios)    printf 'IOS_BUNDLE_ID="com.x"; touch %s/.pwn2\n' "$P" >> "$P/.debug.env" ;;
      macos)  printf 'MACOS_APP_NAME="fake"; touch %s/.pwn2\n' "$P" >> "$P/.debug.env" ;;
      *)      printf 'LOG_DIR="build/debug"; touch %s/.pwn2\n' "$P" >> "$P/.debug.env" ;;
    esac

    OUT="$( cd "$P" && bash -c 'set -euo pipefail; source "$1/'"$PLAT"'/_common.sh"; echo "REACHED"' _ "$SCRIPT_DIR" 2>&1 )"; rc=$?
    expect_rc       "16.$PLAT 合法 env ⇒ 加载可达 rc=0" 0 $rc
    expect_contains "16.$PLAT 合法 env ⇒ REACHED" "$OUT" "REACHED"

    for n in 1 2; do
      if [ -e "$P/.pwn$n" ]; then
        FAIL=$((FAIL+1)); FAILED_CASES+=("16.$PLAT 载荷$n 被执行（.pwn$n 存在）")
        printf '  ❌ 16.%s 载荷%s 被执行（注入面未关闭）\n' "$PLAT" "$n"
      else
        PASS=$((PASS+1)); printf '  ✅ 16.%s 载荷%s 未执行（注入面已关闭）\n' "$PLAT" "$n"
      fi
    done
  done
  echo ""
fi

# ---------- 汇总 ----------
# 空跑守卫：filter 拼错 / 分组改名导致 0 用例执行时，绝不能算通过（否则门禁假绿）
if [ $((PASS+FAIL)) -eq 0 ]; then
  echo "❌ 未执行任何用例${FILTER:+（filter「${FILTER}」未匹配任何分组）}" >&2
  echo "   分组名见各 \"if should_run\" 处；不带 -f 则跑全量。" >&2
  exit 2
fi
echo "========================================"
if [ "$FAIL" -eq 0 ]; then
  echo "✅ 全部通过：$PASS 项"
  exit 0
else
  echo "❌ 失败 $FAIL / 通过 $PASS"
  printf '   失败用例：\n'
  for c in "${FAILED_CASES[@]}"; do printf '     - %s\n' "$c"; done
  exit 1
fi