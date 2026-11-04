#!/bin/bash
# test_safe_run.sh — safe_run.sh（Seatbelt 沙箱入口）的负控制回归
#
# 用法:
#   bash <S>/scripts/test_safe_run.sh          # 全量
#   bash <S>/scripts/test_safe_run.sh -v       # 显示每条用例输出
#   bash <S>/scripts/test_safe_run.sh -f <关键字>  # 只跑名称含该关键字的用例
#
# 退出码: 0=全部通过 / 1=有用例失败 / 2=用法错误或未执行任何用例
#
# 覆盖点（均为**负控制**：证明边界真的在，而不是「跑通就行」）:
#   N1 用法边界：缺命令 / 未知 profile / 选项缺值 / 值以 `-` 开头 ⇒ rc=2 且不执行命令
#     （「选项缺值」是回归点：`shift 2` 在参数不足时不会移动 ⇒ 曾出现死循环挂死）
#   N2 凭证面：`~/.ssh` 读、写都拒
#   N3 写面越界：项目外路径写拒
#   N4 写面正向：**项目根**（在允许清单内、且不在 ${TMPDIR}）的 `build/debug/` 写成功；
#      同一路径**不传** `--project-root` 时必须被拒（证明写面来自 ROOT 而非 TMPDIR 兜底）
#   N5 出网面：`--no-net` 下外网连接失败（且不经本机代理）
#   N6 入口存活：`safe_run.sh -- pwd` 正常返回
#   N7 fail-closed：把 `sandbox-exec` 路径改成不存在的副本 ⇒ rc=117 且命令**未执行**
#   N8 读面：`.env` / `.env.local` / `.ENV` 读拒，`.debug.env` 读成功
#   N9 信号面：沙箱内可给自己起的子进程发信号（脚本内超时/清理依赖），但**不能**给沙箱外进程发信号
#   N10 环境透出：`SAFE_RUN_PROFILE` / `SAFE_RUN_NET` 传给孩子进程（供脚本做能力降级判断）
#   N11 真机通道：usbmuxd unix socket 已放行（`idevice_id -l` 不再报 Unable to retrieve device list）
#   N12 Flutter SDK 缓存：`--profile build` 放行 `<SDK>/bin/cache`（SDK 常在白名单外），默认 profile 不放行
#   N13 Flutter SDK 缓存（软链）：`command -v flutter` 是软链时按**真实路径**放行；
#       相对路径 / 超过 10 跳 ⇒ **不放行 + stderr 说明原因**。
#       断链 / 成环会被 `command -v` 直接跳过（静默，等同未安装）⇒ 只验「不放行 + 不挂死」。
#       分组独立：不依赖本机是否装了 flutter，也不受 N12 跳过逻辑管辖
# 非 macOS（无 Seatbelt）跳过 N2–N5/N7/N8，退出码仍为 0 并打印原因。
set -uo pipefail   # 故意不加 -e：单例失败要继续跑完其余用例

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TARGET="$SCRIPT_DIR/safe_run.sh"
PROJ_TEST="$HOME/Projects/.dbg-safe-run-test.$$"

VERBOSE=0; FILTER=""
while [ $# -gt 0 ]; do
  case "$1" in
    -v) VERBOSE=1; shift ;;
    -f) [ $# -ge 2 ] || { echo "❌ -f 需带关键字" >&2; exit 2; }; FILTER="$2"; shift 2 ;;
    -h|--help) awk 'NR<3 {next} /^[^#[:space:]]/ {exit} {sub(/^# ?/, ""); print}' "$0"; exit 0 ;;
    *) echo "❌ 未知参数: $1" >&2; exit 2 ;;
  esac
done

PASS=0; FAIL=0; FAILED_CASES=()
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/dbgsafe.XXXXXX")"
cleanup() { rm -rf "$TMPROOT" "$PROJ_TEST"; }
trap cleanup EXIT

ok()   { PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILED_CASES+=("$1"); printf '  ❌ %s（%s）\n' "$1" "$2"; }
expect_rc() {
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then ok "$name"; else bad "$name" "rc=${got}，期望 ${want}"; fi
}
expect_file() {
  if [ -e "$2" ]; then ok "$1"; else bad "$1" "文件不存在: $2"; fi
}
expect_no_file() {
  if [ -e "$2" ]; then bad "$1" "不该存在: $2"; else ok "$1"; fi
}
run_case() {  # 名称含关键字才跑
  case "$1" in *"$FILTER"*) return 0 ;; *) return 1 ;; esac
}

if [ ! -f "$TARGET" ]; then
  echo "❌ 缺少被测脚本: $TARGET" >&2
  exit 1
fi

echo "🧪 safe_run.sh 沙箱入口 负控制回归"
echo ""

# ---------- N1 用法边界（含「选项缺值不挂死」回归） ----------
if run_case "N1-参数"; then
  OUT="$(timeout 10 bash "$TARGET" 2>&1)"; RC=$?
  [ "$VERBOSE" = "1" ] && echo "$OUT"
  expect_rc "N1 缺命令 ⇒ rc=2" 2 "$RC"

  OUT="$(timeout 10 bash "$TARGET" --profile nosuch -- pwd 2>&1)"; RC=$?
  [ "$VERBOSE" = "1" ] && echo "$OUT"
  expect_rc "N1 未知 profile ⇒ rc=2" 2 "$RC"

  # 回归：`--profile` 作为末位参数。修复前 `shift 2` 不动 ⇒ while 恒真 ⇒ 挂死（timeout 会返回 124）
  OUT="$(timeout 10 bash "$TARGET" --profile 2>&1)"; RC=$?
  [ "$VERBOSE" = "1" ] && echo "$OUT"
  expect_rc "N1 --profile 缺值 ⇒ rc=2（不挂死）" 2 "$RC"

  OUT="$(timeout 10 bash "$TARGET" --project-root 2>&1)"; RC=$?
  [ "$VERBOSE" = "1" ] && echo "$OUT"
  expect_rc "N1 --project-root 缺值 ⇒ rc=2（不挂死）" 2 "$RC"

  OUT="$(timeout 10 bash "$TARGET" --project-root -- ls 2>&1)"; RC=$?
  [ "$VERBOSE" = "1" ] && echo "$OUT"
  expect_rc "N1 --project-root 吞到 '--' ⇒ rc=2" 2 "$RC"

  bash "$TARGET" --profile nosuch -- touch "$TMPROOT/n1_marker" >/dev/null 2>&1
  expect_no_file "N1 未知 profile 的副作用不存在" "$TMPROOT/n1_marker"
  echo ""
fi

# ---------- N6 入口存活 ----------
if run_case "N6-入口"; then
  OUT="$(timeout 30 bash "$TARGET" -- pwd 2>&1)"; RC=$?
  [ "$VERBOSE" = "1" ] && echo "$OUT"
  if [ "$RC" = "117" ]; then
    ok "N6 沙箱不可用 ⇒ fail-closed rc=117（未执行命令）"
  else
    expect_rc "N6 safe_run.sh -- pwd 正常返回" 0 "$RC"
  fi
  echo ""
fi

if [ "$(uname -s)" != "Darwin" ]; then
  echo "⏭  非 macOS：跳过 N2–N5/N7/N8（Seatbelt 专属）"
  echo ""
else

# ---------- N7 fail-closed（行为级：断掉 sandbox-exec） ----------
if run_case "N7-fail-closed"; then
  BROKEN="$TMPROOT/safe_run_broken.sh"
  sed 's|^SBD="/usr/bin/sandbox-exec"$|SBD="/nonexistent/sandbox-exec"|' "$TARGET" > "$BROKEN"
  if grep -q '^SBD="/nonexistent/sandbox-exec"$' "$BROKEN"; then
    ok "N7 造出「sandbox-exec 缺失」副本"
  else
    bad "N7 造出「sandbox-exec 缺失」副本" "sed 未命中 SBD 行（脚本结构变了？）"
  fi
  OUT="$(timeout 10 bash "$BROKEN" -- touch "$TMPROOT/n7_marker" 2>&1)"; RC=$?
  [ "$VERBOSE" = "1" ] && echo "$OUT"
  expect_rc "N7 缺 sandbox-exec ⇒ rc=117" 117 "$RC"
  expect_no_file "N7 缺 sandbox-exec 时命令未执行" "$TMPROOT/n7_marker"
  echo ""
fi

# ---------- N2 凭证面 ----------
if run_case "N2-凭证"; then
  OUT="$(timeout 10 bash "$TARGET" -- ls "$HOME/.ssh" 2>&1)"; RC=$?
  [ "$VERBOSE" = "1" ] && echo "$OUT"
  if printf '%s' "$OUT" | grep -q 'Operation not permitted'; then
    ok "N2 读 ~/.ssh 被沙箱拒"
  else
    bad "N2 读 ~/.ssh 被沙箱拒" "输出=${OUT}"
  fi
  bash "$TARGET" -- touch "$HOME/.ssh/dbg_safe_run_probe" >/dev/null 2>&1
  expect_no_file "N2 写 ~/.ssh 的副作用不存在" "$HOME/.ssh/dbg_safe_run_probe"
  echo ""
fi

# ---------- N3 写面越界 ----------
if run_case "N3-写面越界"; then
  # 探针落在「父进程可写、但不在 --project-root 的 build/docs 下」的位置 ⇒ 只有沙箱能拦住，
  #   不会因为父进程缺 TCC/权限而假绿。
  mkdir -p "$PROJ_TEST"
  OUT="$(timeout 10 bash "$TARGET" --project-root "$PROJ_TEST" -- mkdir -p "$PROJ_TEST/dbg_outside_probe" 2>&1)"; RC=$?
  [ "$VERBOSE" = "1" ] && echo "$OUT"
  if [ "$RC" -ne 0 ]; then ok "N3 项目内但非 build/docs 的写被拒（rc=${RC}）"; else bad "N3 项目内但非 build/docs 的写被拒" "rc=0"; fi
  expect_no_file "N3 越界目录未创建" "$PROJ_TEST/dbg_outside_probe"
  echo ""
fi

# ---------- N4 写面正向（必须来自 --project-root，不能靠 TMPDIR 兜底） ----------
if run_case "N4-写面正向"; then
  mkdir -p "$PROJ_TEST/build/debug"
  OUT="$(timeout 10 bash "$TARGET" --project-root "$PROJ_TEST" -- touch "$PROJ_TEST/build/debug/ok.txt" 2>&1)"; RC=$?
  [ "$VERBOSE" = "1" ] && echo "$OUT"
  expect_rc "N4 项目 build/ 写成功" 0 "$RC"
  expect_file "N4 文件已落盘" "$PROJ_TEST/build/debug/ok.txt"

  # 负控：同一路径不传 --project-root ⇒ 当前 cwd 不在允许清单 ⇒ 写面收窄 ⇒ 必须被拒
  rm -f "$PROJ_TEST/build/debug/no_root.txt"
  # 从 `/` 起跑，确保「不传 --project-root」时 cwd 一定不在白名单（不依赖运行者当前目录）
  OUT="$( cd / && timeout 10 bash "$TARGET" -- touch "$PROJ_TEST/build/debug/no_root.txt" 2>&1 )"; RC=$?
  [ "$VERBOSE" = "1" ] && echo "$OUT"
  expect_no_file "N4 未指定项目根时该路径不可写（写面不是全局兜底）" "$PROJ_TEST/build/debug/no_root.txt"
  echo ""
fi

# ---------- N5 出网面 ----------
if run_case "N5-出网"; then
  OUT="$(timeout 20 bash "$TARGET" --no-net -- curl -sS --max-time 5 -o /dev/null -w '%{http_code}' https://example.com 2>&1)"; RC=$?
  [ "$VERBOSE" = "1" ] && echo "$OUT"
  if [ "$RC" -ne 0 ] && ! printf '%s' "$OUT" | grep -q '^200$'; then
    ok "N5 --no-net 下外网不可达（rc=${RC}）"
  else
    bad "N5 --no-net 下外网不可达" "rc=${RC} 输出=${OUT}"
  fi
  echo ""
fi

# ---------- N8 读面（.env 家族） ----------
if run_case "N8-读面"; then
  D="$TMPROOT/env"
  mkdir -p "$D"
  printf 'A=1\n' > "$D/.env"
  printf 'C=3\n' > "$D/.env.local"
  printf 'D=4\n' > "$D/.ENV"
  printf 'B=2\n' > "$D/.debug.env"

  OUT="$(timeout 10 bash "$TARGET" -- cat "$D/.env" 2>&1)"; RC=$?
  [ "$VERBOSE" = "1" ] && echo "$OUT"
  if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'Operation not permitted'; then
    ok "N8 读 .env 被拒"
  else
    bad "N8 读 .env 被拒" "rc=${RC} 输出=${OUT}"
  fi

  OUT="$(timeout 10 bash "$TARGET" -- cat "$D/.env.local" 2>&1)"; RC=$?
  [ "$VERBOSE" = "1" ] && echo "$OUT"
  if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'Operation not permitted'; then
    ok "N8 读 .env.local 被拒"
  else
    bad "N8 读 .env.local 被拒" "rc=${RC} 输出=${OUT}"
  fi

  OUT="$(timeout 10 bash "$TARGET" -- cat "$D/.ENV" 2>&1)"; RC=$?
  [ "$VERBOSE" = "1" ] && echo "$OUT"
  if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'Operation not permitted'; then
    ok "N8 读 .ENV（大小写变体）被拒"
  else
    bad "N8 读 .ENV（大小写变体）被拒" "rc=${RC} 输出=${OUT}"
  fi

  OUT="$(timeout 10 bash "$TARGET" -- cat "$D/.debug.env" 2>&1)"; RC=$?
  [ "$VERBOSE" = "1" ] && echo "$OUT"
  if [ "$RC" = "0" ] && printf '%s' "$OUT" | grep -q '^B=2$'; then
    ok "N8 读 .debug.env 成功（放行子集）"
  else
    bad "N8 读 .debug.env 成功（放行子集）" "rc=${RC} 输出=${OUT}"
  fi
  echo ""
fi

# ---------- N9 子进程信号（bounded timeout 依赖：只能杀沙箱内的进程） ----------
if run_case "N9-信号"; then
  OUT="$(timeout 10 bash "$TARGET" -- sh -c 'sleep 5 & p=$!; sleep 0.2; kill -0 "$p"; echo "probe_rc=$?"; kill -TERM "$p" 2>/dev/null; echo "term_rc=$?"' 2>&1)"; RC=$?
  [ "$VERBOSE" = "1" ] && echo "$OUT"
  if printf '%s' "$OUT" | grep -q 'probe_rc=0' && printf '%s' "$OUT" | grep -q 'term_rc=0'; then
    ok "N9 沙箱内可对自己起的子进程发信号（脚本内超时清理可用）"
  else
    bad "N9 沙箱内可对自己起的子进程发信号" "输出=${OUT}"
  fi
  # 负控：不能杀沙箱外的进程（父 shell 的 pid 在沙箱内不可见/不可信号）
  OUT="$(timeout 10 bash "$TARGET" -- kill -0 "$$" 2>&1)"
  if printf '%s' "$OUT" | grep -q 'Operation not permitted'; then
    ok "N9 不可向沙箱外进程发信号（target same-sandbox 边界）"
  else
    bad "N9 不可向沙箱外进程发信号" "输出=${OUT}"
  fi
  echo ""
fi

# ---------- N10 环境变量透出（脚本可据此降级） ----------
if run_case "N10-环境透出"; then
  OUT="$(timeout 10 bash "$TARGET" --profile ios -- sh -c 'echo "P=${SAFE_RUN_PROFILE:-unset} N=${SAFE_RUN_NET:-unset}"' 2>&1)"; RC=$?
  [ "$VERBOSE" = "1" ] && echo "$OUT"
  if printf '%s' "$OUT" | grep -q 'P=ios N=off'; then
    ok "N10 SAFE_RUN_PROFILE=ios / SAFE_RUN_NET=off 透传给被调脚本"
  else
    bad "N10 SAFE_RUN_PROFILE / SAFE_RUN_NET 透传" "输出=${OUT}"
  fi
  OUT="$(timeout 10 bash "$TARGET" --profile build --project-root "$TMPROOT" -- sh -c 'echo "P=${SAFE_RUN_PROFILE:-unset} N=${SAFE_RUN_NET:-unset}"' 2>&1)"
  if printf '%s' "$OUT" | grep -q 'P=build N=on'; then
    ok "N10 build profile 默认开网（SAFE_RUN_NET=on）"
  else
    bad "N10 build profile 默认开网" "输出=${OUT}"
  fi
  echo ""
fi

# ---------- N11 真机通道（usbmuxd unix socket） ----------
if run_case "N11-usbmuxd"; then
  if ! command -v idevice_id >/dev/null 2>&1; then
    echo "  ⏭  N11 跳过（未安装 libimobiledevice）"
  else
    OUT="$(timeout 20 bash "$TARGET" -- idevice_id -l 2>&1)"; RC=$?
    [ "$VERBOSE" = "1" ] && echo "$OUT"
    if [ "$RC" -ne 0 ] || printf '%s' "$OUT" | grep -q 'Unable to retrieve device list'; then
      bad "N11 usbmuxd 通道可用（libimobiledevice 能枚举）" "rc=${RC} 输出=${OUT}"
    else
      ok "N11 usbmuxd 通道可用（idevice_id 未报 Unable to retrieve device list）"
    fi
  fi
  # 需要连接真机才有意义的行为已在真实设备上手工验证（ideviceinfo / idevicesyslog）
  echo ""
fi

# ---------- N12 Flutter SDK 缓存 / dart 状态目录 / trustd（仅 build profile 放行） ----------
if run_case "N12-flutter缓存"; then
  # 推导必须与 safe_run.sh 的校验链**同型**：实现正确地拒绝的路径，测试也要判为「不该放行」，
  #   否则会出现「实现没错、测试判红」的假红（如 SDK 装在 ~/.local/share 或 <root>/bin 是链接）。
  FB="$(command -v flutter 2>/dev/null || true)"
  FR=""; N12_SKIP=""
  case "$FB" in
    /*) [ -f "$FB" ] && [ -x "$FB" ] && FR="$(cd "$(dirname "$FB")/.." 2>/dev/null && pwd -P || true)" ;;
  esac
  case "$FR" in ""|/) N12_SKIP="推导不出 Flutter SDK 根（FB='${FB}'）"; FR="" ;; esac
  [ "$FR" = "$HOME" ] && { N12_SKIP="SDK 根就是 \$HOME"; FR=""; }
  case "$FR" in "$HOME"/.*) N12_SKIP="SDK 根在 \$HOME 的隐藏目录内"; FR="" ;; esac
  if [ -n "$FR" ]; then
    FC="$(cd "$FR/bin/cache" 2>/dev/null && pwd -P || true)"
    [ "$FC" = "$FR/bin/cache" ] || { N12_SKIP="<SDK>/bin/cache 不是真实目录（可能经符号链接）"; FR=""; }
  fi
  for _b in "$HOME/Projects" /Volumes /private/tmp "${TMPDIR:-/tmp}"; do
    [ "$FR" = "$_b" ] && N12_SKIP="SDK 根等于白名单根本体"
  done
  if [ -n "$N12_SKIP" ]; then
    # 推导不出受支持的 SDK 根时**必须跳过**（不能把「没测」记成「通过」）
    echo "  ⏭  N12 跳过（${N12_SKIP}）"
  else
    D_BUILD="$TMPROOT/n12_build.sbpl"; D_UI="$TMPROOT/n12_ui.sbpl"
    mkdir -p "$PROJ_TEST"
    SAFE_RUN_DUMP_PROFILE="$D_BUILD" timeout 15 bash "$TARGET" --profile build --project-root "$PROJ_TEST" -- /usr/bin/true >/dev/null 2>&1
    SAFE_RUN_DUMP_PROFILE="$D_UI" timeout 15 bash "$TARGET" --project-root "$PROJ_TEST" -- /usr/bin/true >/dev/null 2>&1
    # 先证明 dump 真的产出了：否则下面的「默认 profile 不含 X」会因文件不存在而恒过
    expect_file "N12 build profile dump 产出" "$D_BUILD"
    expect_file "N12 默认 profile dump 产出" "$D_UI"

    # 断言形态必须是 `(allow file-write* ... (subpath "<SDK>/bin/cache"))`（不是 deny、不是注释）
    if grep -F '(allow file-write*' "$D_BUILD" 2>/dev/null | grep -qF "(subpath \"${FR}/bin/cache\")"; then
      ok "N12 build profile 以 allow 形态放行 Flutter SDK 缓存（${FR}/bin/cache）"
    else
      bad "N12 build profile 放行 Flutter SDK 缓存" "profile 中未见 allow … (subpath \"${FR}/bin/cache\")"
    fi
    if grep -qF "$FR/bin/cache" "$D_UI" 2>/dev/null; then
      bad "N12 默认 profile 不得放行 Flutter SDK 缓存（最小权限）" "ui profile 含 ${FR}/bin/cache"
    else
      ok "N12 默认 profile 不放行 Flutter SDK 缓存（最小权限）"
    fi

    # dart 状态目录：build 放行（否则 flutter 以 setLastModified EPERM 崩），默认不放行
    if grep -F '(allow file-write*' "$D_BUILD" 2>/dev/null | grep -qF "(subpath \"${HOME}/.dart-tool\")"; then
      ok "N12 build profile 以 allow 形态放行 ~/.dart-tool（telemetry setLastModified）"
    else
      bad "N12 build profile 放行 ~/.dart-tool" "profile 中未见 allow … (subpath \"${HOME}/.dart-tool\")"
    fi
    if grep -qF '.dart-tool' "$D_UI" 2>/dev/null; then
      bad "N12 默认 profile 不得放行 ~/.dart-tool" "ui profile 含 .dart-tool"
    else
      ok "N12 默认 profile 不放行 ~/.dart-tool"
    fi

    # trustd（证书校验）只许出现在 build（禁网 profile 放它 = 间接外联通道）
    if grep -F '(allow mach-lookup' "$D_BUILD" 2>/dev/null | grep -qF 'com.apple.trustd'; then
      ok "N12 build profile 以 allow mach-lookup 形态放行 trustd 证书校验通道"
    else
      bad "N12 build profile 放行 trustd" "profile 中未见 allow mach-lookup … com.apple.trustd"
    fi
    if grep -qF 'com.apple.trustd' "$D_UI" 2>/dev/null; then
      bad "N12 默认 profile 不得放行 trustd（禁网 profile 会变成间接外联）" "ui profile 含 com.apple.trustd"
    else
      ok "N12 默认 profile 不放行 trustd（禁网 profile 无间接外联通道）"
    fi
  fi
  echo ""
fi

# ---------- N13 Flutter SDK 缓存（软链解析；独立分组） ----------
# ⚠️ 单独分组的原因：N12 在「本机 flutter 推导不出受支持 SDK 根」时整块跳过（N12_SKIP），
#   而 brew cask 的 flutter 恰恰就是软链 ⇒ 把软链用例塞进 N12 会在**最需要它的机器上静默不跑**。
#   这里只造 `$TMPROOT` 下的假 SDK 树，与本机安装无关。
if run_case "N13-flutter软链"; then
  FAKE_SDK="$TMPROOT/fakesdk"
  mkdir -p "$PROJ_TEST" "$FAKE_SDK/bin/cache" "$TMPROOT/fakebrew/bin" \
    "$TMPROOT/fakebrew_deep/bin" "$TMPROOT/fakebrew_loop/bin" "$TMPROOT/deep" "$TMPROOT/loop"
  printf '#!/bin/sh\nexit 0\n' > "$FAKE_SDK/bin/flutter"
  chmod +x "$FAKE_SDK/bin/flutter"
  # ① 相对目标软链（homebrew 的常态：`bin/flutter` 指向 Cellar/Caskroom 里的真实文件）
  ln -sf "../../fakesdk/bin/flutter" "$TMPROOT/fakebrew/bin/flutter"
  # ② 13 跳软链：`command -v` 能命中（终点可执行），但超过解析上限 10 跳 ⇒ 必须拒绝且可观测
  _i=1
  while [ "$_i" -le 11 ]; do
    ln -sf "c$(printf '%02d' $((_i+1)))" "$TMPROOT/deep/c$(printf '%02d' "$_i")"
    _i=$((_i+1))
  done
  ln -sf "$FAKE_SDK/bin/flutter" "$TMPROOT/deep/c12"
  ln -sf "$TMPROOT/deep/c01" "$TMPROOT/fakebrew_deep/bin/flutter"
  # ③ 成环：`command -v` 本身就会过滤掉（不算「找到但解析失败」），这里只验「不挂死、不放行」
  ln -sf "$TMPROOT/loop/b" "$TMPROOT/loop/a"
  ln -sf "$TMPROOT/loop/a" "$TMPROOT/loop/b"
  ln -sf "$TMPROOT/loop/a" "$TMPROOT/fakebrew_loop/bin/flutter"
  # 期望值必须按真实路径算（${TMPDIR} 常是 /var → /private/var 的软链）
  FAKE_CACHE_REAL="$(cd "$FAKE_SDK/bin/cache" 2>/dev/null && pwd -P || true)"

  D_SYM="$TMPROOT/n13_sym.sbpl"; D_DEEP="$TMPROOT/n13_deep.sbpl"; D_LOOP="$TMPROOT/n13_loop.sbpl"
  # ⚠️ PATH 必须收窄到「假 SDK + 系统目录」：否则 `command -v flutter` 会跳过坏链接，
  #   命中本机真实 flutter（如 /Volumes/<盘>/dev/flutter/bin）⇒ 负控制恒假绿。
  N13_SYS_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
  OUT_SYM="$(PATH="$TMPROOT/fakebrew/bin:$N13_SYS_PATH" SAFE_RUN_DUMP_PROFILE="$D_SYM" \
    timeout 15 bash "$TARGET" --profile build --project-root "$PROJ_TEST" -- /usr/bin/true 2>&1)"; RC_SYM=$?
  OUT_DEEP="$(PATH="$TMPROOT/fakebrew_deep/bin:$N13_SYS_PATH" SAFE_RUN_DUMP_PROFILE="$D_DEEP" \
    timeout 15 bash "$TARGET" --profile build --project-root "$PROJ_TEST" -- /usr/bin/true 2>&1)"; RC_DEEP=$?
  OUT_LOOP="$(PATH="$TMPROOT/fakebrew_loop/bin:$N13_SYS_PATH" SAFE_RUN_DUMP_PROFILE="$D_LOOP" \
    timeout 10 bash "$TARGET" --profile build --project-root "$PROJ_TEST" -- /usr/bin/true 2>&1)"; RC_LOOP=$?
  if [ "$VERBOSE" = "1" ]; then echo "$OUT_SYM"; echo "$OUT_DEEP"; echo "$OUT_LOOP"; fi

  if [ "$RC_SYM" -eq 0 ] && [ -n "$FAKE_CACHE_REAL" ] \
      && grep -F '(allow file-write*' "$D_SYM" 2>/dev/null | grep -qF "(subpath \"${FAKE_CACHE_REAL}\")"; then
    ok "N13 软链 flutter ⇒ 按真实 SDK 根放行缓存（${FAKE_CACHE_REAL}）"
  else
    bad "N13 软链 flutter 放行真实 SDK 缓存" "rc=${RC_SYM} 期望=${FAKE_CACHE_REAL} dump=$( [ -f "$D_SYM" ] && echo 有 || echo 无)"
  fi
  if printf '%s' "$OUT_SYM" | grep -q '未放行 Flutter SDK 缓存'; then
    bad "N13 解析成功时不得报「未放行」" "stderr=${OUT_SYM}"
  else
    ok "N13 解析成功时无「未放行」告警"
  fi
  if printf '%s' "$OUT_DEEP" | grep -q '软链解析失败'; then
    ok "N13 超过 10 跳 ⇒ stderr 说明「软链解析失败」"
  else
    bad "N13 超长软链必须 stderr 可观测" "输出=${OUT_DEEP}"
  fi
  # 负断言前先证 dump 真的产出（否则文件缺失时 grep 恒假 ⇒ 假绿）
  expect_file "N13 超长软链 dump 产出" "$D_DEEP"
  if grep -F '(allow file-write*' "$D_DEEP" 2>/dev/null | grep -qF '/bin/cache'; then
    bad "N13 超长软链不得放行 /bin/cache" "dump 中含 /bin/cache"
  else
    ok "N13 超长软链不放行 /bin/cache（fail-closed）"
  fi
  expect_file "N13 成环 dump 产出" "$D_LOOP"
  if grep -F '(allow file-write*' "$D_LOOP" 2>/dev/null | grep -qF '/bin/cache'; then
    bad "N13 软链成环不得放行 /bin/cache" "dump 中含 /bin/cache"
  else
    ok "N13 软链成环不放行 /bin/cache（fail-closed）"
  fi
  if [ "$RC_LOOP" -eq 124 ]; then
    bad "N13 软链成环不挂死" "10 s 超时（rc=124）"
  else
    ok "N13 软链成环不挂死（rc=${RC_LOOP}）"
  fi
  echo ""
fi

fi

echo "================================"
if [ "$PASS" -eq 0 ] && [ "$FAIL" -eq 0 ]; then
  echo "❌ 未执行任何用例（filter='${FILTER}' 未匹配任何分组）"
  exit 2
fi
if [ "$FAIL" -eq 0 ]; then
  echo "✅ 全部通过（${PASS} 项）"
  exit 0
fi
echo "❌ 失败 ${FAIL} 项（通过 ${PASS} 项）"
for f in "${FAILED_CASES[@]}"; do echo "   - ${f}"; done
exit 1
