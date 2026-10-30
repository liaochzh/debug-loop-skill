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

# iOS 真机枚举的**单一来源**（与 doctor.sh 共用）：`scripts/_ios_device.sh`
#   （识别规则「xctrace Devices 段里 Mac 排最前 / iPhone 行有两组括号」写两份必然漂移）
# shellcheck source=/dev/null
[ -f "$_SELF_DIR/../_ios_device.sh" ] && source "$_SELF_DIR/../_ios_device.sh"

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
# 实现在 `scripts/_ios_device.sh`（本文件顶部已 source）—— 与 doctor.sh 共用同一识别规则：
#   只取「真 iPhone」行（xctrace 的 Devices 段里 Mac 自己排最前，且只有一层括号 `Name (UUID)`；
#   iPhone 行是 `Name (iOS版本) (硬件UDID)` ⇒ 用「两组括号」区分）。
# 守卫（在 helper 内）：无 iOS 真机 ⇒ 空输出；调用方按「空串」判「未检测到」。

# 已启动的 iOS 模拟器 UDID（优先 IOS_SIM_UDID，否则取 booted 第一个）
resolve_ios_sim() {
  if [ -n "${IOS_SIM_UDID:-}" ]; then
    echo "$IOS_SIM_UDID"
    return 0
  fi
  xcrun simctl list devices booted 2>/dev/null \
    | grep -E '^[[:space:]]*(iPhone|iPad)' \
    | grep -Eo '\([0-9A-Fa-f-]{36}\)' | tr -d '()' | head -1 || true
}

# 写 iOS 模拟器 xcuitest caps 到 $1
write_caps_ios_sim() {
  local out="$1" bid="${2:-}" udid="${3:-}"
  [ -n "$bid" ] || bid="${IOS_BUNDLE_ID:-}"
  [ -n "$udid" ] || udid=$(resolve_ios_sim || true)
  if [ -z "$bid" ]; then echo "❌ 缺 BundleID（.debug.env IOS_BUNDLE_ID 或 --app-id）"; exit 1; fi
  if [ -z "$udid" ]; then echo "❌ 未检测到已启动的 iOS 模拟器（xcrun simctl list devices booted）"; exit 1; fi
  python3 - "$out" "$bid" "$udid" <<'PY'
import json, sys
out, bid, udid = sys.argv[1], sys.argv[2], sys.argv[3]
caps = {"platformName": "iOS", "appium:automationName": "XCUITest",
        "appium:udid": udid, "appium:bundleId": bid,
        "appium:noReset": True, "appium:useNewWDA": False}
json.dump(caps, open(out, "w", encoding="utf-8"), ensure_ascii=False)
PY
  echo "🧩 caps(iOS 模拟器/xcuitest): bundleId=$bid udid=$udid"
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
  if [ -z "$xctestrun" ]; then
    # 自动发现：`wda_prepare.sh` 的默认产物目录（build/debug/wda-prebuilt/Build/Products/）
    # 里若有按本设备命名的 xctestrun，就直接走 xctestrun 路线，免得把**含设备 UDID 的绝对路径**
    # 写进随项目提交的 .debug.env。找不到 ⇒ 维持旧行为（会话期跑 xcodebuild）。
    local wdap="build/debug/wda-prebuilt/Build/Products" pver0
    pver0="$(ideviceinfo -u "$udid" -k ProductVersion 2>/dev/null || true)"
    if [ -n "$pver0" ] && [ -f "$wdap/${udid}_${pver0}.xctestrun" ]; then
      xctestrun="$wdap/${udid}_${pver0}.xctestrun"
    fi
  fi
  if [ -n "$xctestrun" ]; then
    if [ ! -f "$xctestrun" ]; then echo "❌ IOS_XCTESTRUN 不存在: $xctestrun" >&2; exit 1; fi
    # 绝对化：caps 里的 bootstrapPath 会交给 appium server 解析，相对路径依赖其 cwd
    xctestrun="$(cd "$(dirname "$xctestrun")" && pwd)/$(basename "$xctestrun")"
    bootstrap="$(cd "$(dirname "$xctestrun")" && pwd)"
    # appium 的查找顺序（appium-webdriveragent/utils/xctestrun.js:getXctestrunFilePath）：
    #   ① `<udid>_<iosSdkVersion>.xctestrun` → ② `<udid>_<platformVersion>.xctestrun`
    #   → ③ `WebDriverAgentRunner_iphoneos<version>-arm64.xctestrun`（复制成 ①② 形式）
    # ⚠️ iosSdkVersion 可能取不到（Xcode 27 下 `xcodebuild -showdestinations` 对 bootstrapPath 里
    #    不存在的 .xcodeproj 报 66/75 ⇒ 传进来是空串）⇒ 它会先找 `<udid>_.xctestrun`。
    #    若目录里残留这种空后缀文件，appium 会拿它当产物（版本/端口全错，WDA 起不来）。
    # ⚠️ platformVersion 报的是 `26.6`（不带补丁号），与 `ideviceinfo` 的 `26.6.1` 不同 ⇒ 两种都备。
    local sdk pver mm
    sdk="$(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || true)"
    pver="$(ideviceinfo -u "$udid" -k ProductVersion 2>/dev/null || true)"
    mm="$(printf '%s' "$pver" | cut -d. -f1,2)"
    # 每次覆盖：wda_prepare 重跑后，保留旧副本会让 appium 用陈旧产物。
    # ⚠️ 源文件本身可能就命中其中一个名字（自动发现取的就是 `<udid>_<pver>.xctestrun`）⇒
    #    macOS 的 cp 对「同一文件」会打印 "are identical (not copied)" 并返回 1，必须跳过。
    local dst
    for dst in "WebDriverAgentRunner_iphoneos-arm64.xctestrun" \
               ${sdk:+"${udid}_${sdk}.xctestrun"} \
               ${pver:+"${udid}_${pver}.xctestrun"} \
               ${mm:+"${udid}_${mm}.xctestrun"} \
               ${mm:+"WebDriverAgentRunner_iphoneos${mm}-arm64.xctestrun"}; do
      [ "$bootstrap/$dst" = "$xctestrun" ] && continue
      cp -f "$xctestrun" "$bootstrap/$dst" \
        || { echo "❌ 无法写入 $bootstrap/$dst" >&2; exit 1; }
    done
    # xctestrun 里的 TestHostPath 用 __TESTROOT__ 相对路径 ⇒ 必须与 Debug-iphoneos 同级
    if [ ! -d "$bootstrap/Debug-iphoneos" ]; then
      echo "⚠️ $bootstrap 下没有 Debug-iphoneos/，xctestrun 的 __TESTROOT__ 可能失效（应指向 Build/Products 目录）" >&2
    fi
    if [ -n "$prebuilt" ]; then
      echo "⚠️ 同时给了 IOS_PREBUILT_WDA 与 IOS_XCTESTRUN，按 xctestrun 路线执行" >&2
      prebuilt=""
    fi
  fi
  python3 - "$out" "$udid" "$bid" "$team" "$app" "$wda" "$prebuilt" "$bootstrap" "${IOS_ATTACH_ONLY:-0}" <<'PY'
import json, sys
out, udid, bid, team, app, wda, prebuilt, bootstrap, attach = sys.argv[1:10]
caps = {"platformName": "iOS", "appium:automationName": "XCUITest",
        "appium:udid": udid, "appium:bundleId": bid,
        "appium:xcodeOrgId": team, "appium:xcodeSigningId": "Apple Development"}
# 自动签名 + allowProvisioningUpdates 只在会话期真构建 WDA 时才需要；
# xctestrun 路线用已手签产物，带上会触发失效的 Xcode 账号校验（xcodebuild 65）。
if not bootstrap and not prebuilt:
    caps["appium:allowProvisioningDeviceRegistration"] = True
if app:
    caps["appium:app"] = app
if wda and not bootstrap:
    # xctestrun 路线下 WDA 的 bundle id 由 xctestrun 里的 TestHostBundleIdentifier 决定，
    # 传 updatedWDABundleId 只会引入「与实际产物不一致」的风险（.debug.env 的 IOS_WDA_BUNDLE_ID
    # 是给会话期构建路线用的，与离线手签产物未必同名）⇒ 该路线下不下发。
    caps["appium:updatedWDABundleId"] = wda
if prebuilt:
    # 二者必须成对：appium 只有 usePreinstalledWDA 时才走预构建分支（否则仍跑 xcodebuild）
    caps["appium:prebuiltWDAPath"] = prebuilt
    caps["appium:usePreinstalledWDA"] = True
if bootstrap:
    caps["appium:useXctestrunFile"] = True
    caps["appium:bootstrapPath"] = bootstrap
if attach == "1":
    # 只 attach 已运行实例：绝不重启目标 App。
    # （iOS 14+ debug 包被非 Flutter 工具冷启动会停在限制页，UI 完全不渲染 ⇒ 整轮回归作废）
    # ⚠️ 只有 `autoLaunch=false` 才真正阻止 WDA 启动 AUT：
    #    appium-xcuitest-driver/commands/wda/startup.js 里是
    #    `bundleId: driver.opts.autoLaunch === false ? undefined : bundleId`
    #    —— 只给 forceAppLaunch/shouldTerminateApp 不够，WDA 仍会拿 bundleId 去 terminate+launch，
    #    表现为「会话建完 App 的 PID 变了」，且注入的进程环境变量（Malloc*）随之丢失。
    caps["appium:autoLaunch"] = False
    caps["appium:forceAppLaunch"] = False
    caps["appium:shouldTerminateApp"] = False
    caps["appium:noReset"] = True
json.dump(caps, open(out, "w", encoding="utf-8"), ensure_ascii=False)
PY
  echo "🧩 caps(iOS/xcuitest): udid=$udid bundleId=$bid team=$team wda=${wda:-<默认/不可签名>} prebuilt=${prebuilt:-<无>} xctestrun=${xctestrun:-<无>} attach=${IOS_ATTACH_ONLY:-0}"
}