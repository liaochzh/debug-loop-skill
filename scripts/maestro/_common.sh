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

# 沙箱内 iOS 模拟器：maestro 的 XCUITest 驱动起不来（JVM 无限轮询 127.0.0.1:22087）
#   ⇒ 快失败 rc=3 并提示降级，避免每轮白等 90 s+。需要试验时设 MAESTRO_ALLOW_SANDBOX=1。
guard_sandbox_ios() {
  [ -z "${SAFE_RUN_PROFILE:-}" ] && return 0
  [ "${MAESTRO_ALLOW_SANDBOX:-0}" = "1" ] && return 0
  echo "❌ 沙箱内不支持 iOS 模拟器 Maestro（XCUITest 驱动在嵌套沙箱内不可靠，会无限轮询 127.0.0.1:22087）" >&2
  echo "   ⇒ 降级：页面判定改用 shot.sh（截图）+ logs.sh（日志）；iOS **真机**走 appium/driver.py（--platform ios-device）" >&2
  echo "   需要试验时设 MAESTRO_ALLOW_SANDBOX=1（可能挂起，请自加超时）" >&2
  exit 3
}

# 探测目标平台：显式 $1 优先（须为 android|ios）；否则按在线设备自动判定
# 输出 android / ios；都无设备则报错退出
detect_platform() {
  local want="${1:-}"
  if [ -n "$want" ]; then
    case "$want" in
      android) echo "$want"; return 0 ;;
      ios)     guard_sandbox_ios; echo "ios"; return 0 ;;
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
    guard_sandbox_ios
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
      # 与 android/_common.sh 的 require_device 同优先级：显式 ANDROID_SERIAL 优先，否则取首台。
      #   否则多设备时 input.sh 打一台、maestro flow 打另一台，断言与输入落在不同设备上（静默假绿）。
      #   ⚠️ 本处**不校验在线**（这是独立脚本家族，不 source android/_common.sh）：指定了不在线的号
      #   会原样透传，由 Maestro 自己报错；要失败关闭的强校验请用 require_device。
      if [ -n "${ANDROID_SERIAL:-}" ]; then
        printf '%s\n' "$ANDROID_SERIAL"
        return 0
      fi
      # 与 android/_common.sh 的 online_serials 保持同一解析口径（改一处要同步另一处）
      adb devices 2>/dev/null | awk 'NR>1 && $2=="device"{print $1}' | head -1 || true
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