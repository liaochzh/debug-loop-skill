#!/bin/bash
# test_ios_common.sh — ios/_common.sh 纯函数回归（离线，不需真机/模拟器/Flutter）
#
# 用法:
#   bash <S>/scripts/test_ios_common.sh      # 全量
#   bash <S>/scripts/test_ios_common.sh -v   # 显示每个用例的输出明细
#
# 退出码: 0=全部通过 / 1=有用例失败 / 2=用法错误
#
# 为什么要有这一组：这两个函数已被 `ios/run.sh`（进程名过滤）与 `ios/logs.sh --app-only`
# 依赖，且历史上出现过「run.sh 调用未定义函数」的悬空引用事故（2026-11-04）——
# 它们此前零测试覆盖，而硬编码 `Runner` 会让真机日志恒为空。
#
# 覆盖点：
#   - `ios_syslog_line_re`：ERE 转义（`.` `+` `[` `]` 等）与 syslog 头部锚定语义
#     （App 行命中 / kernel(Sandbox) deny 行不命中 / 前缀相似的别的进程不命中）
#   - `resolve_ios_app_name`：IOS_APP_NAME > Info.plist CFBundleExecutable > .app 文件名 > Runner
set -uo pipefail   # 故意不加 -e：单例失败要继续跑完其余用例

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
COMMON="$SCRIPT_DIR/ios/_common.sh"

VERBOSE=0
while [ $# -gt 0 ]; do
  case "$1" in
    -v) VERBOSE=1; shift ;;
    -h|--help) awk 'NR<3 {next} /^[^#[:space:]]/ {exit} {sub(/^# ?/, ""); print}' "$0"; exit 0 ;;
    *) echo "❌ 未知参数: $1" >&2; exit 2 ;;
  esac
done

[ -f "$COMMON" ] || { echo "❌ 找不到 $COMMON" >&2; exit 2; }

PASS=0; FAIL=0; FAILED_CASES=()

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/iostest.XXXXXX")"
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

# 断言：$1 用例名  $2 期望  $3 实际
expect_eq() {
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    PASS=$((PASS+1)); printf '  ✅ %s\n' "$name"
  else
    FAIL=$((FAIL+1)); FAILED_CASES+=("$name")
    printf '  ❌ %s\n     期望: %s\n     实际: %s\n' "$name" "$want" "$got"
  fi
}

# 断言：$1 用例名  $2 期望rc  $3 实际rc
expect_rc() {
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    PASS=$((PASS+1)); printf '  ✅ %s\n' "$name"
  else
    FAIL=$((FAIL+1)); FAILED_CASES+=("$name")
    printf '  ❌ %s（期望 rc=%s，实际 rc=%s）\n' "$name" "$want" "$got"
  fi
}

# 构造假 Flutter 项目（ios/_common.sh 的加载前置：pubspec.yaml + .debug.env + IOS_BUNDLE_ID）
new_project() {
  local p="$TMPROOT/$1"
  mkdir -p "$p/build/debug"
  printf 'name: fake\n' > "$p/pubspec.yaml"
  printf 'LOG_DIR=build/debug\nIOS_BUNDLE_ID=com.test.ios\n' > "$p/.debug.env"
  echo "$p"
}

# 在假项目里 source 公共段并求值一段 bash 片段：in_proj <项目目录> <表达式>
in_proj() {
  local p="$1" expr="$2"
  ( cd "$p" && bash -c 'source "$1"; shift; eval "$*"' _ "$COMMON" "$expr" 2>&1 )
}

P1="$(new_project p1)"

echo "== A. ios_syslog_line_re（ERE 转义 + 头部锚定） =="

OUT="$(in_proj "$P1" 'ios_syslog_line_re TinoSec')"; RC=$?
expect_rc       "A1 正常名求值 rc=0" 0 "$RC"
expect_eq       "A2 普通名 → NAME(\\(|\\[)" 'TinoSec(\(|\[)' "$OUT"

OUT="$(in_proj "$P1" 'ios_syslog_line_re "" ')"
expect_eq       "A3 空名 → 默认 Runner" 'Runner(\(|\[)' "$OUT"

OUT="$(in_proj "$P1" 'ios_syslog_line_re "A.B+C[D]"')"
expect_eq       "A4 元字符转义（. + [ ]）" 'A\.B\+C\[D\](\(|\[)' "$OUT"

# 行为级：把同一段正则按 logs.sh 的拼法用在样例日志上
LOG_SAMPLE="$TMPROOT/sample.log"
{
  printf 'Nov  4 11:28:20 TinoSec(Flutter)[123] <Notice>: app line one\n'
  printf 'Nov  4 11:28:21 TinoSec[456] <Notice>: app line two\n'
  printf 'Nov  4 11:28:23 kernel(Sandbox)[0] <Error>: Sandbox: TinoSec(31624) deny(1) iokit-get-properties\n'
  printf 'Nov  4 11:28:24 TinoSecHelper[789] <Notice>: other process\n'
} > "$LOG_SAMPLE"

RE="$(in_proj "$P1" 'ios_syslog_line_re TinoSec')"
MATCHES="$(grep -E "^[A-Z][a-z]{2} [ 0-9][0-9] [0-9:.]+ ${RE}" "$LOG_SAMPLE" | sed -e 's/.*<[A-Za-z]*>: //' | tr '\n' '|')"
expect_eq "A5 命中两条 App 行（TinoSec(…) 与 TinoSec[…]）" 'app line one|app line two|' "$MATCHES"

DENY_HIT="$(grep -cE "^[A-Z][a-z]{2} [ 0-9][0-9] [0-9:.]+ ${RE}" "$LOG_SAMPLE" || true)"
expect_eq "A6 只命中 App 行（deny / 近似进程名均被排除）" '2' "$DENY_HIT"

echo ""
echo "== B. resolve_ios_app_name（四级回退） =="

# B1 显式 env 覆盖
OUT="$(in_proj "$P1" 'IOS_APP_NAME=EnvApp; resolve_ios_app_name')"
expect_eq "B1 IOS_APP_NAME 覆盖优先" 'EnvApp' "$OUT"

# B2 Info.plist 的 CFBundleExecutable（含子目录 .app，验证不是取 basename）
APP_PLIST="$TMPROOT/app1/Any.app"
mkdir -p "$APP_PLIST"
cat > "$APP_PLIST/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>PlistName</string>
</dict></plist>
PLIST
OUT="$(in_proj "$P1" "resolve_ios_app_name '$APP_PLIST' device")"
expect_eq "B2 读 Info.plist 的 CFBundleExecutable（非 basename）" 'PlistName' "$OUT"

# B3 无 Info.plist ⇒ .app 文件名
APP_BARE="$TMPROOT/app2/BareApp.app"
mkdir -p "$APP_BARE"
OUT="$(in_proj "$P1" "resolve_ios_app_name '$APP_BARE' device")"
expect_eq "B3 无 plist ⇒ .app 文件名" 'BareApp' "$OUT"

# B4 全无 ⇒ Runner（假项目里没有 build/ios 产物）
OUT="$(in_proj "$P1" 'unset IOS_APP_NAME; resolve_ios_app_name "" device')"
expect_eq "B4 无从推断 ⇒ 兜底 Runner" 'Runner' "$OUT"

# B5 只给 simulator 目标时同样走回退链（不该崩）
OUT="$(in_proj "$P1" 'unset IOS_APP_NAME; resolve_ios_app_name "" simulator')"; RC=$?
expect_rc "B5 simulator 目标 rc=0" 0 "$RC"
expect_eq "B6 simulator 目标回退 Runner" 'Runner' "$OUT"

echo "────────────────────────────────"
TOTAL=$((PASS + FAIL))
echo "通过: ${PASS} / ${TOTAL}"
if [ "$FAIL" -gt 0 ]; then
  echo "失败用例:"
  printf '  - %s\n' "${FAILED_CASES[@]}"
  exit 1
fi
exit 0
