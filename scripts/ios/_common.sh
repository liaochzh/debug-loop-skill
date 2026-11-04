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

# App 进程名（syslog 行过滤用）。优先级：
#   IOS_APP_NAME（.debug.env 显式覆盖） > 产物 Info.plist 的 CFBundleExecutable > .app 文件名 > Runner
# 为什么需要：App 可执行名不一定等于 Runner（本项目为 TinoSec），硬编码会让 app_device.log 恒为空。
# 用法：resolve_ios_app_name [app路径] [simulator|device]（路径空 ⇒ 按 target 自动发现）
resolve_ios_app_name() {
  local app="${1:-}" target="${2:-device}" name=""
  if [ -n "${IOS_APP_NAME:-}" ]; then
    printf '%s' "$IOS_APP_NAME"
    return 0
  fi
  if [ -z "$app" ]; then
    app=$(resolve_ios_app "$target" 2>/dev/null || true)
  fi
  if [ -n "$app" ] && [ -f "$app/Info.plist" ] && command -v /usr/libexec/PlistBuddy >/dev/null 2>&1; then
    name=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$app/Info.plist" 2>/dev/null || true)
  fi
  if [ -z "$name" ] && [ -n "$app" ]; then
    name=$(basename "$app" .app)
  fi
  printf '%s' "${name:-Runner}"
}

# syslog 中「本 App 进程行」的正则片段：`TinoSec(Flutter)[123]` / `TinoSec[123]` 均命中。
# 进程名先做 ERE 元字符转义，避免自定义名（含 . + 等）污染正则。
ios_syslog_line_re() {
  local name="${1:-Runner}"
  name=$(printf '%s' "$name" | sed 's/[][\\.^$*+?(){}|]/\\&/g')
  printf '%s(\\(|\\[)' "$name"
}

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
  # 沙箱内：pgrep/pkill 被拒（process-info），跨沙箱 kill 也会 EPERM ⇒ 只能尽力。
  #   ⚠️ 判活不能写成 `kill -0 … | grep -q`：调用方多带 pipefail（管道状态取 kill 的非 0）会被吞；
  #   且 bash 内建 kill 的文案是小写 `operation not permitted` ⇒ 统一取输出再大小写不敏感匹配。
  if [ -n "${SAFE_RUN_PROFILE:-}" ]; then
    local alive=0 kout="" _i=0
    if [ -n "${old_pid:-}" ]; then
      kill "$old_pid" 2>/dev/null || true
      # 信号投递有毫秒级延迟：紧跟 `kill -0` 会大概率命中「还没死」⇒ 先宽限轮询（最多 1s），
      #   否则会误报「杀不掉」并往 orphan 表写已死的 pid，把人骗去宿主机 pkill。
      while [ "$_i" -lt 5 ] && kill -0 "$old_pid" 2>/dev/null; do
        sleep 0.2
        _i=$((_i + 1))
      done
      if kill -0 "$old_pid" 2>/dev/null; then
        alive=1
      else
        # `kill -0` 失败也可能是 EPERM（跨沙箱存在但无权限发信号）⇒ 只有 EPERM 才算存活
        kout=$(kill -0 "$old_pid" 2>&1 || true)
        case "$kout" in *[Nn]ot\ [Pp]ermitted*) alive=1 ;; esac
      fi
    fi
    if [ "$alive" -eq 1 ]; then
      echo "⚠️  沙箱内无法停止上一次日志采集（PID ${old_pid}）：日志可能出现重复行" >&2
      echo "   彻底重置请在宿主机执行: pkill -f 'idevicesyslog --syslog-relay'" >&2
      # 记下孤儿，便于宿主机侧清理（主 pid 文件由本次启动覆盖，故不在这里保留）
      printf '%s\t%s\n' "$old_pid" "${old_udid:-${fallback_udid:-?}}" \
        >> "${LOG_DIR}/syslog.orphan.txt" 2>/dev/null || true
    fi
    rm -f "$pid_file"
    return 0
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
  # 沙箱内 `pgrep`/`ps` 被拒（process-info）⇒ 改用 pid 文件的 `kill -0` 判活；
  #   EPERM 说明进程存在（跨沙箱实例）⇒ 同样视为存活，避免误报「采集未运行」。
  if [ -n "${SAFE_RUN_PROFILE:-}" ]; then
    local pf="$LOG_DIR/syslog.pid" sp="" kout=""
    [ -f "$pf" ] || return 1
    sp=$(sed -n '1p' "$pf" 2>/dev/null || true)
    case "$sp" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$sp" 2>/dev/null && return 0
    # EPERM 说明进程存在（跨沙箱实例，信号被拒）⇒ 视为存活；必须避开管道 pipefail 吞状态。
    kout=$(kill -0 "$sp" 2>&1 || true)
    case "$kout" in *[Nn]ot\ [Pp]ermitted*) return 0 ;; esac
    return 1
  fi
  if [ -n "$udid" ]; then
    pgrep -f "idevicesyslog --syslog-relay -u $udid" >/dev/null 2>&1
  else
    pgrep -f "idevicesyslog --syslog-relay" >/dev/null 2>&1
  fi
}
