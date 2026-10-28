#!/bin/bash
# doctor.sh — 环境自检（只读：不构建 / 不启动 / 不安装 / 不改项目）
#
# 用法: bash <S>/scripts/doctor.sh [--platform android|ios|macos|windows|all]
#   在**项目根**执行（按 $PWD 找 .debug.env）。缺 .debug.env 时本脚本仍能跑完并报告，
#   不像 android/_common.sh 那样直接 exit ⇒ 便于「先诊断、再 init」。
# 退出码: 0 = 无阻塞项 / 1 = 有阻塞项（缺 .debug.env、env 值非法、目标平台零可用设备或关键工具缺失）
#         2 = 用法错误
# 设计要点（借 agent-device / MobileBuildMCP 的 doctor 思路）：
#   - 一次输出「配置 / 工具链 / 设备 / 产物 / 密钥」五类事实，避免子代理逐条探测后误判「权限被拒」
#   - ⚠️ 与 ❌ 分级：可选组件缺失只告警；被配置平台的关键工具缺失才算阻塞
set -uo pipefail   # 故意不加 -e：单项失败要继续把报告跑完（诊断脚本的退出码由汇总决定）

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_env.sh"

PLATFORM="all"
while [ $# -gt 0 ]; do
  case "$1" in
    --platform) [ $# -ge 2 ] || { echo "❌ --platform 需要取值" >&2; exit 2; }; PLATFORM="$2"; shift 2 ;;
    -h|--help)
      # 用法文本按「内容」输出，不按行号截取（头部增删注释不应泄漏代码行）
      echo "用法: bash doctor.sh [--platform android|ios|macos|windows|all]"
      echo "  只读自检：配置 / 工具链 / 设备 / 产物 / 可选密钥；在项目根执行"
      echo "退出码: 0=无阻塞 / 1=有阻塞 / 2=用法错误"
      exit 0 ;;
    *) echo "❌ 未知参数: $1" >&2; exit 2 ;;
  esac
done
case "$PLATFORM" in
  android|ios|macos|windows|all) ;;
  *) echo "❌ --platform 只支持 android|ios|macos|windows|all（收到: ${PLATFORM}）" >&2; exit 2 ;;
esac

BLOCKERS=0
WARNS=0
ok()   { echo "  ✅ $*"; }
warn() { WARNS=$((WARNS+1)); echo "  ⚠️  $*"; }
bad()  { BLOCKERS=$((BLOCKERS+1)); echo "  ❌ $*"; }
have() { command -v "$1" >/dev/null 2>&1; }

echo "🩺 debug-loop 环境自检（${PWD}）"
echo ""
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------- 1. 项目与配置 ----------
echo "[1] 项目与配置"
if [ ! -f .debug.env ]; then
  bad "缺少 .debug.env — 运行 bash ${SKILL_ROOT}/init.sh 生成后再执行本脚本"
else
  ok ".debug.env 存在"
  # validate_debug_env 违规时调 env_fail ⇒ exit 1；用**子 shell** 捕获，避免把诊断脚本本身终止
  if parse_debug_env .debug.env; then
    ENV_ERR=$( (validate_debug_env) 2>&1 >/dev/null )
    if [ $? -eq 0 ]; then
      ok ".debug.env 解析与值校验通过"
    else
      bad "取值被拒：$(printf '%s' "$ENV_ERR" | tr '\n' ' ' | cut -c1-200)"
    fi
  else
    bad ".debug.env 解析失败（见上方 ⚠️ 行）"
  fi
fi

if [ -f pubspec.yaml ]; then
  ok "工程类型: Flutter（可构建 APK / iOS / macOS）"
else
  ok "工程类型: 原生 Android（build.sh 不可用，APK 需 ANDROID_APK_PATH）"
fi

# 已配置平台字段（只报键名，不回声值 —— 避免密钥/包名进日志）
cfg=""
for k in ANDROID_APP_ID IOS_BUNDLE_ID MACOS_APP_NAME WINDOWS_APP_NAME; do
  case "$k" in
    ANDROID_APP_ID)   v="${ANDROID_APP_ID:-}" ;;
    IOS_BUNDLE_ID)    v="${IOS_BUNDLE_ID:-}" ;;
    MACOS_APP_NAME)   v="${MACOS_APP_NAME:-}" ;;
    WINDOWS_APP_NAME) v="${WINDOWS_APP_NAME:-}" ;;
    *) v="" ;;
  esac
  [ -n "$v" ] && cfg="${cfg} ${k}"
done
if [ -n "$cfg" ]; then
  ok "已配置平台字段:${cfg}"
else
  warn "未配置任何平台字段（ANDROID_APP_ID / IOS_BUNDLE_ID / MACOS_APP_NAME / WINDOWS_APP_NAME）"
fi

LOG_DIR="${LOG_DIR:-build/debug}"
# 保持「只读」承诺：这里**不主动创建**产物目录，只判断「可写 / 将可创建」
if [ -d "$LOG_DIR" ]; then
  if [ -w "$LOG_DIR" ]; then ok "产物目录可写: ${LOG_DIR}"; else bad "产物目录不可写: ${LOG_DIR}"; fi
else
  LOG_PARENT="$(dirname "$LOG_DIR")"
  if { [ -d "$LOG_PARENT" ] && [ -w "$LOG_PARENT" ]; } || { [ ! -e "$LOG_PARENT" ] && [ -w . ]; }; then
    ok "产物目录 ${LOG_DIR} 尚不存在（首次 build/取证时创建）"
  else
    bad "无法创建产物目录 ${LOG_DIR}（父目录不可写）"
  fi
fi
echo ""

# ---------- 2. 目标平台及工具链 ----------
want() { [ "$PLATFORM" = "all" ] || [ "$PLATFORM" = "$1" ]; }
cfg_platform() {  # <平台> → 该平台是否在 .debug.env 里配了必要字段
  case "$1" in
    android) [ -n "${ANDROID_APP_ID:-}" ] ;;
    ios)     [ -n "${IOS_BUNDLE_ID:-}" ] ;;
    macos)   [ -n "${MACOS_APP_NAME:-}" ] ;;
    windows) [ -n "${WINDOWS_APP_NAME:-}" ] ;;
    *) return 1 ;;
  esac
}

echo "[2] 工具链"
# host 基线（任何平台都要能跑脚本）
for t in bash perl; do
  if have "$t"; then ok "$t 可用"; else bad "$t 缺失（脚本运行基线）"; fi
done

if want android; then
  if have adb; then ok "adb: $(command -v adb)"; else
    if cfg_platform android; then bad "adb 缺失（已配置 ANDROID_APP_ID，Android 通道不可用）"
    else warn "adb 缺失（本次未配置 Android，跳过）"; fi
  fi
fi
if want ios || want macos; then
  if have xcrun; then ok "xcrun 可用"; else
    if cfg_platform ios || cfg_platform macos; then bad "xcrun 缺失（Xcode 命令行工具）"
    else warn "xcrun 缺失（本次未配置 iOS/macOS）"; fi
  fi
fi
if [ -f pubspec.yaml ] && { want android || want ios || want macos; }; then
  if have flutter; then ok "flutter: $(flutter --version 2>/dev/null | head -1)"; else bad "flutter 缺失（Flutter 工程构建不可用）"; fi
fi
if want android || want ios; then
  if have maestro; then ok "maestro 可用（语义定位首选路径）"; else warn "maestro 缺失（降级 ui.sh / Vision；安装属用户动作）"; fi
fi
if want ios; then
  if have appium; then ok "appium 可用（iOS 真机语义路径）"; else warn "appium 缺失（iOS 真机语义路径不可用，可选）"; fi
fi
if want macos; then
  if have cliclick; then ok "cliclick 可用（点击稳定性）"; else warn "cliclick 缺失（坐标点击可用但稳定性差）"; fi
fi
if have python3; then ok "python3 可用（Vision 视觉分析）"; else warn "python3 缺失（Vision 视觉分析不可用）"; fi
echo ""

# ---------- 3. 设备 ----------
echo "[3] 设备"
if want android && have adb; then
  AND_N=$(adb devices 2>/dev/null | grep -w 'device$' | wc -l | tr -d ' ')
  if [ "${AND_N:-0}" -gt 0 ]; then
    ok "Android 在线设备 ${AND_N} 台: $(adb devices 2>/dev/null | grep -w 'device$' | awk '{print $1}' | tr '\n' ' ')"
    if [ "${AND_N:-0}" -gt 1 ]; then warn "多设备在线 — 脚本取第一台，建议只留目标设备"; fi
  elif cfg_platform android; then bad "无 Android 设备在线（adb devices 为空）"
  else warn "无 Android 设备在线（本次未配置 Android）"; fi
fi
if want ios && have xcrun; then
  BOOTED=$(xcrun simctl list devices booted 2>/dev/null | grep -c '(Booted)' || true)
  if [ "${BOOTED:-0}" -gt 0 ]; then ok "iOS 模拟器已启动 ${BOOTED} 台"; else
    if cfg_platform ios; then warn "无已启动的 iOS 模拟器（真机走 --device，需签名与开发者模式）"
    else warn "无已启动的 iOS 模拟器（本次未配置 iOS）"; fi
  fi
fi
if [ "$PLATFORM" = "windows" ] || { [ "$PLATFORM" = "all" ] && cfg_platform windows; }; then
  warn "Windows 产物只能在 Windows 机执行（本机为 $(uname -s)）"
fi
echo ""

# ---------- 4. 产物与证据 ----------
echo "[4] 产物与证据"
if [ -d build/debug ]; then
  ok "build/debug 存在（$(ls build/debug 2>/dev/null | wc -l | tr -d ' ') 个条目）"
else
  warn "build/debug 尚不存在（首次构建后生成）"
fi
LOCK=""
for f in build/debug/.last_android_apk build/debug/.last_ios_app build/debug/.last_ios_app_device; do
  [ -s "$f" ] && LOCK="${LOCK} ${f##*/}"
done
if [ -n "$LOCK" ]; then ok "产物锁文件:${LOCK}"; else warn "无产物锁文件（尚未 build，或已 flutter clean）"; fi
echo ""

# ---------- 5. 可选密钥 ----------
echo "[5] 可选能力"
if [ -n "${VISION_API_KEY:-}" ]; then ok "VISION_API_KEY 已配置（值不回显）"; else warn "VISION_API_KEY 未配置（Vision 视觉分析不可用，仅影响兜底路径）"; fi
echo ""

# ---------- 汇总 ----------
echo "────────────────────────────────"
if [ "$BLOCKERS" -gt 0 ]; then
  echo "❌ 阻塞项 ${BLOCKERS} 个，告警 ${WARNS} 个 — 先修阻塞项再跑调试闭环"
  exit 1
fi
echo "✅ 无阻塞项，告警 ${WARNS} 个 — 可以执行 build / run / shot / logs"
exit 0
