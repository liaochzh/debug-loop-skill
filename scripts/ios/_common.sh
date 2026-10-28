#!/bin/bash
# _common.sh — iOS 模拟器脚本公共段（由各脚本 source，不直接执行）
#
# 约定：必须从 Flutter 项目根执行（脚本按 $PWD 查找 .debug.env）
#   ⚠️ .debug.env **不再 source**（source 等于执行项目内文本）⇒ 走 scripts/_env.sh 安全解析

# 自取目录：调用方才有 SCRIPT_DIR，而本文件也可能被 `bash -c 'source …/ios/_common.sh'` 直接加载
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
APP_LOG="$LOG_DIR/app.log"

if [ -z "${IOS_BUNDLE_ID:-}" ]; then
  echo "❌ .debug.env 缺少 IOS_BUNDLE_ID — 请补填或重新运行 init.sh"
  exit 1
fi

# 原子写锁文件：atomic_write_lock <lock文件> <内容>
atomic_write_lock() {
  printf '%s\n' "$2" > "$1.tmp" && mv "$1.tmp" "$1"
}

# 读锁文件（不存在/为空时输出空串）
read_lock() {
  [ -f "$1" ] && [ -s "$1" ] && head -1 "$1" || true
}

# 解析 .app（三级回退：显式覆盖 > 锁文件 > 目录最新发现）
# 覆盖 Runner.app 写死，兼容多 Scheme/Target 的 <Scheme>.app
# 用法：resolve_ios_app [simulator|device]（默认 simulator）
# 依赖：IOS_APP_PATH（显式覆盖，可空）、$LOG_DIR/.last_ios_app[_device]（锁文件）
resolve_ios_app() {
  local target="${1:-simulator}"
  local sim_dir="build/ios/iphonesimulator"
  local lock_file="$LOG_DIR/.last_ios_app"
  if [ "$target" = "device" ]; then
    sim_dir="build/ios/iphoneos"
    lock_file="$LOG_DIR/.last_ios_app_device"
  fi

  # 1. 显式覆盖
  if [ -n "${IOS_APP_PATH:-}" ]; then
    if [ -d "$IOS_APP_PATH" ]; then
      echo "$IOS_APP_PATH"
      return 0
    else
      echo "⚠️  IOS_APP_PATH 指向不存在: ${IOS_APP_PATH}，回退自动发现" >&2
    fi
  fi

  # 2. 锁文件
  local locked
  locked=$(read_lock "$lock_file")
  if [ -n "$locked" ] && [ -d "$locked" ]; then
    echo "$locked"
    return 0
  fi
  [ -n "$locked" ] && echo "🔓 锁文件过期（$locked 不存在），回退目录发现" >&2

  # 3. 目录发现（按 mtime 取最新）
  [ -d "$sim_dir" ] || { echo "❌ 无产物目录: ${sim_dir}，请先运行 build.sh" >&2; return 1; }
  local count
  count=$(ls -d "$sim_dir"/*.app 2>/dev/null | wc -l || true)
  [ "$count" -eq 0 ] && { echo "❌ $sim_dir 下无 .app，请先运行 build.sh" >&2; return 1; }
  if [ "$count" -eq 1 ]; then
    ls -d "$sim_dir"/*.app
    return 0
  fi
  local newest=""
  if stat -f '%m %N' /dev/null >/dev/null 2>&1; then
    newest=$(printf '%s\n' "$sim_dir"/*.app | xargs stat -f '%m %N' 2>/dev/null | sort -rn | head -1 | sed 's/^[0-9]* //' || true)
  else
    newest=$(printf '%s\n' "$sim_dir"/*.app | xargs stat -c '%Y %n' 2>/dev/null | sort -rn | head -1 | sed 's/^[0-9]* //' || true)
  fi
  echo "⚠️  检测到 $count 个 .app 候选，自动选最新: $newest" >&2
  # ⚠️ 末尾 `|| true`：count 与此次 `ls` 之间候选被删光时，空 glob 使 `ls` 退 1，经 `pipefail` 会**静默终止**，
  #    使下面的 `echo "$newest"`（契约：newest 空为正常，调用方随后判断）不可达。
  #    （2026-10-17 形态清单清扫发现：三平台不对称 —— android/macos 同位置用 `echo "$pool" | sed`（恒 0），仅 iOS 用 `ls -d` glob。）
  ls -d "$sim_dir"/*.app | sed 's/^/     - /' >&2 || true
  echo "   如需精确指定，在 .debug.env 设置 IOS_APP_PATH" >&2
  echo "$newest"
}

# 解析 BundleID：优先从实际产物 Info.plist 读取（覆盖多 Target 场景），
# 回退 .debug.env IOS_BUNDLE_ID
# 输入：$1 = .app 路径；输出：stdout 打印 bundle id
resolve_bundle_id() {
  local app="$1" id=""
  if [ -n "$app" ] && [ -f "$app/Info.plist" ] && command -v /usr/libexec/PlistBuddy >/dev/null 2>&1; then
    id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app/Info.plist" 2>/dev/null || true)
  fi
  if [ -n "$id" ]; then
    echo "$id"
  else
    [ -n "${IOS_APP_PATH:-}" ] || echo "⚠️  未能从产物 Info.plist 读取 BundleID，使用 .debug.env IOS_BUNDLE_ID" >&2
    echo "$IOS_BUNDLE_ID"
  fi
}

# 生效的 BundleID 与 .app 路径（各脚本解析后赋值；未解析时回退 env 默认）
EFFECTIVE_BUNDLE_ID="${IOS_BUNDLE_ID:-}"
SIM_APP_PATH="build/ios/iphonesimulator/Runner.app"

# 输出已启动模拟器 UDID；无则尝试 boot 第一个可用 iPhone 并等待
require_simulator() {
  local udid
  udid=$(xcrun simctl list devices booted 2>/dev/null | grep -Eo '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1 || true)
  if [ -z "$udid" ]; then
    echo "⚠️  无已启动的模拟器，尝试启动第一个可用 iPhone..."
    udid=$(xcrun simctl list devices available | grep "iPhone" | grep -Eo '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1 || true)
    if [ -z "$udid" ]; then
      echo "❌ 找不到可用的 iPhone 模拟器，请用 Simulator.app 或 xcrun simctl boot <udid> 启动"
      exit 1
    fi
    xcrun simctl boot "$udid"
    # 等待 boot 完成
    for _ in $(seq 1 30); do
      xcrun simctl bootstatus "$udid" -b > /dev/null 2>&1 && break
      sleep 1
    done
  fi
  echo "$udid"
}

# ---- iOS 真机（physical device）支持（2026-10-23 新增）----
# 目标选择：IOS_DEVICE_UDID 非空 或 IOS_TARGET=device ⇒ device；否则 simulator（默认，保持旧行为）
resolve_ios_target() {
  if [ -n "${IOS_DEVICE_UDID:-}" ] || [ "${IOS_TARGET:-}" = "device" ]; then
    echo device
  else
    echo simulator
  fi
}

# 自动探测已连接真机 UDID（booted + 非模拟器）；无则输出空
detect_ios_device_udid() {
  xcrun devicectl list devices --json-output - 2>/dev/null \
    | python3 -c '
import json, sys
try:
    devs = json.load(sys.stdin)["result"]["devices"]
except Exception:
    sys.exit(0)
for d in devs:
    try:
        dp = d.get("deviceProperties") or {}
        hp = d.get("hardwareProperties") or {}
        props = d.get("properties") or {}
        vis = d.get("visibilityClass") or (props.get("state") or {}).get("visibilityClass")
        if hp.get("platform") == "iOS" and dp.get("bootState") == "booted" and vis != "simulators":
            print(hp.get("udid") or d.get("identifier", ""))
            break
    except Exception:
        continue
' | head -1 || true
}

# 输出真机 UDID（显式优先，其次自动探测）；找不到即失败
require_ios_device() {
  local udid="${IOS_DEVICE_UDID:-}"
  [ -z "$udid" ] && udid=$(detect_ios_device_udid)
  if [ -z "$udid" ]; then
    echo "❌ 未检测到已连接 iOS 真机（需 USB + 已配对 + 开发者模式；或在 .debug.env 设 IOS_DEVICE_UDID）" >&2
    exit 1
  fi
  echo "$udid"
}

# ---- 真机日志采集进程管理（pid 文件：第 1 行子 shell PID，第 2 行 UDID）----
# 停止 run.sh 启动的采集：$1 为兜底 UDID（pid 文件无第 2 行时用；空 ⇒ 宽匹配）
stop_ios_syslog_capture() {
  local fallback_udid="${1:-}"
  local pid_file="$LOG_DIR/syslog.pid"
  local old_pid="" old_udid=""
  if [ -f "$pid_file" ]; then
    old_pid=$(sed -n '1p' "$pid_file" 2>/dev/null || true)
    old_udid=$(sed -n '2p' "$pid_file" 2>/dev/null || true)
  fi
  [ -n "${old_pid:-}" ] && kill "$old_pid" 2>/dev/null || true
  # 子 shell PID 杀不到孙进程（idevicesyslog/grep）⇒ 按命令行定向清理；
  # UDID 优先取 pid 文件记录（多设备时只杀自己那台），其次兜底参数。
  local udid="${old_udid:-$fallback_udid}"
  if [ -n "$udid" ]; then
    pkill -f "idevicesyslog --syslog-relay -u $udid" 2>/dev/null || true
  else
    pkill -f "idevicesyslog --syslog-relay" 2>/dev/null || true
  fi
  rm -f "$pid_file"
  return 0
}

# 采集是否仍在运行：$1 为空 ⇒ 宽匹配
ios_syslog_capture_running() {
  local udid="${1:-}"
  if [ -n "$udid" ]; then
    pgrep -f "idevicesyslog --syslog-relay -u $udid" >/dev/null 2>&1
  else
    pgrep -f "idevicesyslog --syslog-relay" >/dev/null 2>&1
  fi
}
