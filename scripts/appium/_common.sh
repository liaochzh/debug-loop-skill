#!/bin/bash
# _common.sh — Appium 脚本公共段（由各脚本 source，不直接执行）
#
# 约定：必须从 Flutter 项目根执行（脚本按 $PWD 查找 .debug.env，产物/日志写入 build/debug/）
#   ⚠️ .debug.env **不再 source**（source 等于执行项目内文本）⇒ 走 scripts/_env.sh 安全解析
# 支持: macOS（mac2 驱动）、iOS 真机（xcuitest 驱动）
# 依赖: appium 3.x CLI + mac2/xcuitest 驱动；python3 + requests（driver.py）

# 自取目录：调用方才有 SCRIPT_DIR，而本文件也可能被 `bash -c 'source …/appium/_common.sh'` 直接加载
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

APPIUM_PORT="${APPIUM_PORT:-4723}"
APPIUM_SERVER="${APPIUM_SERVER:-http://127.0.0.1:$APPIUM_PORT}"
APPIUM_LOG="$LOG_DIR/appium.log"
DRIVER_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/driver.py"

require_appium() {
  command -v appium >/dev/null 2>&1 || {
    echo "❌ 未安装 Appium CLI — 请执行: npm install -g appium@3 && appium driver install mac2 && appium driver install xcuitest"
    exit 1
  }
}

# Appium 服务是否在线
appium_online() {
  curl -s -m 3 "$APPIUM_SERVER/status" 2>/dev/null | grep -q '"ready"'
}

# 确保 Appium 服务在跑（不在则后台启动并等待就绪）
ensure_appium_server() {
  if appium_online; then
    return 0
  fi
  echo "🚀 启动 Appium 服务（:${APPIUM_PORT}，日志: ${APPIUM_LOG}）..."
  nohup appium --port "$APPIUM_PORT" > "$APPIUM_LOG" 2>&1 &
  disown 2>/dev/null || true
  local i
  for i in $(seq 1 40); do
    appium_online && { echo "✅ Appium 就绪"; return 0; }
    sleep 1
  done
  echo "❌ Appium 服务启动超时（详见 ${APPIUM_LOG}）"
  tail -15 "$APPIUM_LOG" 2>/dev/null || true
  return 1
}

# macOS .app 的 BundleID（显式覆盖 > 默认构建产物 Info.plist）
resolve_macos_bundle_id() {
  local app="${MACOS_APP_BUNDLE:-}" bid=""
  if [ -z "$app" ] || [ ! -d "$app" ]; then
    local d
    for d in build/macos/Build/Products/Debug build/macos/Build/Products/Release; do
      if [ -d "$d/${MACOS_APP_NAME:-}.app" ]; then app="$d/${MACOS_APP_NAME:-}.app"; break; fi
    done
  fi
  if [ -n "$app" ] && [ -f "$app/Contents/Info.plist" ]; then
    bid=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app/Contents/Info.plist" 2>/dev/null || true)
  fi
  echo "$bid"
}

# 已连接的 iOS 真机 UDID（排除模拟器）
# 守卫（内移）：无 iOS 真机 ⇒ grep 无匹配(1)；head 截断上游 ⇒ SIGPIPE(141) —— 均属「非 0 但正常语义」，
#   不得触发 errexit 使调用方静默死（`write_caps_ios_device` 的「❌ 未检测到 iOS 真机」友好提示须可达）
resolve_ios_device() {
  # 只取「真 iPhone」行：xctrace 的 Devices 段里 Mac 自己排在最前（且只有一层括号 `Name (UUID)`），
  # iPhone 行是 `Name (iOS版本) (硬件UDID)` ⇒ 用「两组括号」区分，避免把 Mac 的 UUID 当设备。
  xcrun xctrace list devices 2>/dev/null \
    | awk '/^== Devices ==/{f=1;next} /^== Simulators ==/{f=0} f' \
    | grep -E '\([0-9][^)]*\)[[:space:]]*\([0-9A-Fa-f-]{25,}\)' \
    | grep -Eo '\([0-9A-Fa-f-]{25,}\)' | tr -d '()' | head -1 || true
}

# 写 macOS mac2 caps 到 $1
write_caps_macos() {
  local out="$1" bid="${2:-}"
  [ -n "$bid" ] || bid=$(resolve_macos_bundle_id)
  if [ -z "$bid" ]; then
    echo "❌ 无法解析 macOS BundleID：请先 build.sh，或用 --app-id 指定"
    exit 1
  fi
  python3 - "$out" "$bid" <<'PY'
import json, sys
out, bid = sys.argv[1], sys.argv[2]
caps = {"platformName": "Mac", "appium:automationName": "Mac2",
        "appium:bundleId": bid, "appium:showServerLogs": False}
json.dump(caps, open(out, "w", encoding="utf-8"), ensure_ascii=False)
PY
  echo "🧩 caps(macOS/mac2): bundleId=$bid"
}

# 写 iOS 真机 xcuitest caps 到 $1
write_caps_ios_device() {
  local out="$1" bid="${2:-}" udid="${3:-}"
  [ -n "$bid" ] || bid="${IOS_BUNDLE_ID:-}"
  [ -n "$udid" ] || udid=$(resolve_ios_device || true)
  local team="${IOS_TEAM_ID:-}"
  if [ -z "$bid" ]; then echo "❌ 缺 BundleID（.debug.env IOS_BUNDLE_ID 或 --app-id）"; exit 1; fi
  if [ -z "$udid" ]; then echo "❌ 未检测到 iOS 真机（xcrun xctrace list devices）"; exit 1; fi
  if [ -z "$team" ]; then
    echo "❌ iOS 真机需 Apple Team ID：请 export IOS_TEAM_ID=<TeamID>（或用 --team-id 指定）"
    exit 1
  fi
  local app="${IOS_DEVICE_APP:-}"
  # WDA 默认 bundle id（com.facebook.WebDriverAgentRunner.xctrunner）不属于本团队 ⇒ 无法自动签名。
  # 真机必须给一个本团队名下的 bundle id（如 <AppBundleId>.wda），appium 会补 .xctrunner 后缀。
  local wda="${IOS_WDA_BUNDLE_ID:-}"
  # 预构建 WDA（离线签名后的 .app）：给了就不在会话期跑 xcodebuild，appium 直接安装并启动它。
  # 注意：Xcode 27 栈下该分支只能回退 devicectl 前台启动，runner 会因无法自切后台而退出，
  # 故真机首选下面的 xctestrun 路线。
  local prebuilt="${IOS_PREBUILT_WDA:-}"
  # xctestrun 路线：appium 直接跑 `xcodebuild test-without-building`，由 XCTest 托管 WDA
  # 生命周期（能正确切后台），产物用离线手签包，无需 Xcode 账号。
  # 约定：xctestrun 必须与 `Build/Products/Debug-iphoneos/` 同级，否则 __TESTROOT__ 失效。
  local xctestrun="${IOS_XCTESTRUN:-}" bootstrap=""
  if [ -n "$xctestrun" ]; then
    if [ ! -f "$xctestrun" ]; then echo "❌ IOS_XCTESTRUN 不存在: $xctestrun" >&2; exit 1; fi
    bootstrap="$(cd "$(dirname "$xctestrun")" && pwd)"
    # appium 只认 <bootstrapPath> 下的固定命名：优先 <udid>_<sdkVersion|platformVersion>.xctestrun，
    # 找不到再回退 WebDriverAgentRunner_iphoneos-arm64.xctestrun 复制成按设备名。两种都备上。
    local sdk pver
    sdk="$(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || true)"
    pver="$(ideviceinfo -u "$udid" -k ProductVersion 2>/dev/null || true)"
    # 每次覆盖：wda_prepare 重跑后，保留旧副本会让 appium 用陈旧产物
    cp -f "$xctestrun" "$bootstrap/WebDriverAgentRunner_iphoneos-arm64.xctestrun" \
      || { echo "❌ 无法写入 $bootstrap/WebDriverAgentRunner_iphoneos-arm64.xctestrun" >&2; exit 1; }
    if [ -n "$sdk" ]; then
      cp -f "$xctestrun" "$bootstrap/${udid}_${sdk}.xctestrun" \
        || { echo "❌ 无法写入 $bootstrap/${udid}_${sdk}.xctestrun" >&2; exit 1; }
    fi
    if [ -n "$pver" ]; then
      cp -f "$xctestrun" "$bootstrap/${udid}_${pver}.xctestrun" \
        || { echo "❌ 无法写入 $bootstrap/${udid}_${pver}.xctestrun" >&2; exit 1; }
    fi
    # xctestrun 里的 TestHostPath 用 __TESTROOT__ 相对路径 ⇒ 必须与 Debug-iphoneos 同级
    if [ ! -d "$bootstrap/Debug-iphoneos" ]; then
      echo "⚠️ $bootstrap 下没有 Debug-iphoneos/，xctestrun 的 __TESTROOT__ 可能失效（应指向 Build/Products 目录）" >&2
    fi
    if [ -n "$prebuilt" ]; then
      echo "⚠️ 同时给了 IOS_PREBUILT_WDA 与 IOS_XCTESTRUN，按 xctestrun 路线执行" >&2
      prebuilt=""
    fi
  fi
  python3 - "$out" "$udid" "$bid" "$team" "$app" "$wda" "$prebuilt" "$bootstrap" <<'PY'
import json, sys
out, udid, bid, team, app, wda, prebuilt, bootstrap = sys.argv[1:9]
caps = {"platformName": "iOS", "appium:automationName": "XCUITest",
        "appium:udid": udid, "appium:bundleId": bid,
        "appium:xcodeOrgId": team, "appium:xcodeSigningId": "Apple Development"}
# 自动签名 + allowProvisioningUpdates 只在会话期真构建 WDA 时才需要；
# xctestrun 路线用已手签产物，带上会触发失效的 Xcode 账号校验（xcodebuild 65）。
if not bootstrap and not prebuilt:
    caps["appium:allowProvisioningDeviceRegistration"] = True
if app:
    caps["appium:app"] = app
if wda:
    caps["appium:updatedWDABundleId"] = wda
if prebuilt:
    # 二者必须成对：appium 只有 usePreinstalledWDA 时才走预构建分支（否则仍跑 xcodebuild）
    caps["appium:prebuiltWDAPath"] = prebuilt
    caps["appium:usePreinstalledWDA"] = True
if bootstrap:
    caps["appium:useXctestrunFile"] = True
    caps["appium:bootstrapPath"] = bootstrap
json.dump(caps, open(out, "w", encoding="utf-8"), ensure_ascii=False)
PY
  echo "🧩 caps(iOS/xcuitest): udid=$udid bundleId=$bid team=$team wda=${wda:-<默认/不可签名>} prebuilt=${prebuilt:-<无>} xctestrun=${xctestrun:-<无>}"
}