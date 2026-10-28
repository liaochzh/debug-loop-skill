#!/bin/bash
# _common.sh — Maestro 脚本公共段（由各脚本 source，不直接执行）
#
# 约定：必须从 Flutter 项目根执行（脚本按 $PWD 查找 .debug.env，产物写入项目 build/debug/）
#   ⚠️ .debug.env **不再 source**（source 等于执行项目内文本）⇒ 走 scripts/_env.sh 安全解析
# Maestro 跨平台同 YAML：Android 真机/模拟器 + iOS 模拟器共用同一流程；
# 不支持 Flutter Desktop（macOS/Windows）——桌面端走 vision 智能命令。

# 自取目录：调用方才有 SCRIPT_DIR，而本文件也可能被 `bash -c 'source …/maestro/_common.sh'` 直接加载
_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$_SELF_DIR/../_env.sh" ]; then
  # shellcheck source=/dev/null
  source "$_SELF_DIR/../_env.sh"
else
  echo "❌ 缺少 scripts/_env.sh（.debug.env 安全解析器）—— 无法安全加载 .debug.env" >&2
  exit 1
fi

if [ ! -f "pubspec.yaml" ]; then
  echo "❌ 请在 Flutter 项目根目录执行本脚本（当前: ${PWD}）"
  exit 1
fi

if [ ! -f ".debug.env" ]; then
  echo "❌ 缺少 .debug.env — 请在项目根执行 debug-loop skill 的 init.sh 生成"
  exit 1
fi
# 安全解析 .debug.env（不 source / 不 eval / 不展开变量）；值违规即 exit 1
parse_debug_env ".debug.env" || exit 1
validate_debug_env

LOG_DIR="${LOG_DIR:-build/debug}"
mkdir -p "$LOG_DIR"

# Maestro CLI 是否可用
require_maestro() {
  if ! command -v maestro >/dev/null 2>&1; then
    echo "❌ 未安装 Maestro CLI — 请执行: brew tap mobile-dev-inc/tap && brew install --formula mobile-dev-inc/tap/maestro"
    echo "   安装后执行 maestro doctor 验证"
    exit 1
  fi
}

# 探测目标平台：显式 $1 优先（须为 android|ios）；否则按在线设备自动判定
# 输出 android / ios；都无设备则报错退出
detect_platform() {
  local want="${1:-}"
  if [ -n "$want" ]; then
    case "$want" in
      android|ios) echo "$want"; return 0 ;;
      *) echo "❌ --platform 仅支持 android|ios（收到: ${want}）" >&2; exit 2 ;;
    esac
  fi
  # Android 在线设备优先
  if command -v adb >/dev/null 2>&1 && adb devices 2>/dev/null | grep -qw "device$"; then
    echo "android"
    return 0
  fi
  # iOS 已启动模拟器
  if command -v xcrun >/dev/null 2>&1 && xcrun simctl list devices booted 2>/dev/null | grep -qE '[0-9A-F]{8}-'; then
    echo "ios"
    return 0
  fi
  echo "❌ 未检测到在线设备（Android 真机/模拟器 或 iOS 已启动模拟器）" >&2
  echo "   Android: adb devices 确认；或 flutter emulators --launch <avd>" >&2
  echo "   iOS:     open -a Simulator && xcrun simctl boot <udid>" >&2
  exit 1
}

# 按平台解析 appId（Maestro YAML 的 appId 头）
# 依赖 .debug.env：ANDROID_APP_ID / IOS_BUNDLE_ID
resolve_app_id() {
  case "$1" in
    android) echo "${ANDROID_APP_ID:-}" ;;
    ios)     echo "${IOS_BUNDLE_ID:-}" ;;
    *)       echo "" ;;
  esac
}

# 按平台解析目标设备 ID（可空：Maestro 自行选设备）
# 守卫（内移）：无设备/无模拟器 ⇒ grep 无匹配(1) 或 SIGPIPE(141) 属「非 0 但正常语义」，
#   不得触发 errexit 使调用方静默死（Maestro 本就允许「自选设备」= 空输出）
resolve_device() {
  case "$1" in
    android)
      adb devices 2>/dev/null | grep -w "device$" | head -1 | awk '{print $1}' || true
      ;;
    ios)
      xcrun simctl list devices booted 2>/dev/null \
        | grep -Eo '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1 || true
      ;;
  esac
}

# 生成实际执行的 YAML：源文件已含 appId 则原样，否则注入 appId 头
# prepare_flow <src.yaml> <appId> <out.yaml>
prepare_flow() {
  local src="$1" app_id="$2" out="$3"
  if [ ! -f "$src" ]; then
    echo "❌ 流程文件不存在: $src"
    exit 1
  fi
  if head -30 "$src" | grep -qE '^[[:space:]]*appId:'; then
    cp "$src" "$out"
  else
    if [ -z "$app_id" ]; then
      echo "❌ 无法解析 appId（.debug.env 缺 ANDROID_APP_ID / IOS_BUNDLE_ID），且流程未自带 appId"
      echo "   可用 --app-id <id> 显式指定"
      exit 1
    fi
    printf 'appId: %s\n---\n' "$app_id" > "$out"
    cat "$src" >> "$out"
  fi
}

# 执行 Maestro 流程并落日志
# run_maestro <yaml> <device|"">
run_maestro() {
  local yaml="$1" device="${2:-}" out="$LOG_DIR/maestro_output.log"
  local args=(test "$yaml")
  [ -n "$device" ] && args=(--device "$device" "${args[@]}")
  echo "🎭 maestro ${args[*]}"
  echo "⏳ Maestro 为 JVM 进程：真机冷启动 + 设备驱动握手较慢，成功一次也可能花 60~180s；调用方超时请设 ≥180s"
  # 关闭 analytics，避免冷启动时网络等待拖慢/卡住
  export MAESTRO_CLI_NO_ANALYTICS=1
  export MAESTRO_CLI_ANALYSIS_NOTIFICATION_DISABLED=true
  # 直接重定向到日志文件（不用 tee 管道）：进程被外层超时杀掉时也能保留已落盘的部分输出，
  # 便于区分「流程失败」与「被超时中断」（后者日志常停在 "Selected device … port …" 之后）
  set +e
  maestro "${args[@]}" > "$out" 2>&1
  local code=$?
  set -e
  cat "$out"
  if [ "$code" -eq 0 ]; then
    echo "✅ Maestro 流程通过（日志: ${out}）"
  else
    echo "❌ Maestro 流程失败/中断（exit ${code}，日志: ${out}）"
  fi
  return "$code"
}