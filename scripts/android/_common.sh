#!/bin/bash
# _common.sh — Android 脚本公共段：加载项目 env + 设备检测（由各脚本 source，不直接执行）
#
# 约定：必须从**项目根**执行（脚本按 $PWD 查找 .debug.env，日志/产物写入项目 build/debug/）
#   工程类型：Flutter（pubspec.yaml 存在）或原生 Android —— 差异由 IS_FLUTTER 标记探测得出
#   ⚠️ .debug.env **不再 source**（source 等于执行项目内文本）⇒ 走 scripts/_env.sh 安全解析

# 自取目录：调用方才有 SCRIPT_DIR，而本文件也可能被 `bash -c 'source …/android/_common.sh'` 直接加载
_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$_SELF_DIR/../_env.sh" ]; then
  # shellcheck source=/dev/null
  source "$_SELF_DIR/../_env.sh"
else
  # 解析器缺失 ⇒ 无法安全加载 .debug.env ⇒ 失败关闭（绝不退回 source）
  echo "❌ 缺少 scripts/_env.sh（.debug.env 安全解析器）—— 无法安全加载 .debug.env" >&2
  exit 1
fi

# 工程类型：Flutter vs 原生 Android（用 if 而非 && 链 —— 链末项是赋值时 errexit 会穿透）
if [ -f "pubspec.yaml" ]; then
  IS_FLUTTER=1
else
  IS_FLUTTER=0
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

# 必填字段校验（env 字段演进时旧项目缺字段在此报错）
if [ -z "${ANDROID_APP_ID:-}" ]; then
  echo "❌ .debug.env 缺少 ANDROID_APP_ID — 请补填或重新运行 init.sh"
  exit 1
fi

# 检测在线设备并回显设备 ID，无设备时非零退出
require_device() {
  local device
  device=$(adb devices | grep -w "device$" | head -1 | awk '{print $1}' || true)
  if [ -z "$device" ]; then
    echo "❌ 没有检测到 Android 设备" >&2
    adb devices >&2
    exit 1
  fi
  echo "$device"
}

# 原子写锁文件（避免并发截断）：atomic_write_lock <lock文件> <内容>
atomic_write_lock() {
  printf '%s\n' "$2" > "$1.tmp" && mv "$1.tmp" "$1"
}

# 读锁文件（不存在/为空时输出空串，不报错）
read_lock() {
  [ -f "$1" ] && [ -s "$1" ] && head -1 "$1" || true
}

# 设备 ABI（无设备时输出空串，不报错；build-only 机器跳过 ABI 过滤）
device_abi() {
  adb -s "$1" shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r[:space:]' || true
}

# 解析 APK（三级回退：显式覆盖 > 锁文件 > 目录最新发现）
# 输入：$1 = 可选设备 ID（用于 ABI 优先匹配，无设备可空）
# 输出：stdout 打印 APK 路径；日志打到 stderr
# 依赖：ANDROID_APK_PATH（显式覆盖，可空）、LOG_DIR/.last_android_apk（锁文件）
resolve_apk() {
  local device="${1:-}" abi="" apk_dir="build/app/outputs/flutter-apk"

  # 1. 显式覆盖
  if [ -n "${ANDROID_APK_PATH:-}" ]; then
    if [ -f "$ANDROID_APK_PATH" ]; then
      echo "$ANDROID_APK_PATH"
      return 0
    else
      echo "⚠️  ANDROID_APK_PATH 指向不存在: ${ANDROID_APK_PATH}，回退自动发现" >&2
    fi
  fi

  # 2. 锁文件（校验存在性，过期自动失效）
  local locked
  locked=$(read_lock "$LOG_DIR/.last_android_apk")
  if [ -n "$locked" ] && [ -f "$locked" ]; then
    echo "$locked"
    return 0
  fi
  if [ -n "$locked" ] && [ ! -f "$locked" ]; then
    if [ "${IS_FLUTTER:-1}" -eq 1 ]; then
      echo "🔓 锁文件过期（$locked 不存在），回退目录发现" >&2
    else
      echo "🔓 锁文件过期（$locked 不存在），非 Flutter 项目请用 ANDROID_APK_PATH 指定" >&2
    fi
  fi

  # 2.5 非 Flutter：不猜 APK 目录（Flutter 产物路径不适用；全树 find 慢且不可预期）
  if [ "${IS_FLUTTER:-1}" -eq 0 ]; then
    echo "❌ 非 Flutter 项目不自动发现 APK" >&2
    echo "   请在 .debug.env 设置 ANDROID_APK_PATH，或手工：echo <apk路径> > $LOG_DIR/.last_android_apk" >&2
    return 1
  fi

  # 3. 目录发现
  [ -d "$apk_dir" ] || { echo "❌ 无 APK 输出目录: ${apk_dir}，请先运行 build.sh" >&2; return 1; }
  # shellcheck disable=SC2012
  local count
  count=$(ls "$apk_dir"/*.apk 2>/dev/null | wc -l || true)
  [ "$count" -eq 0 ] && { echo "❌ $apk_dir 下无 APK，请先运行 build.sh" >&2; return 1; }

  # 单候选直接返回
  if [ "$count" -eq 1 ]; then
    ls "$apk_dir"/*.apk
    return 0
  fi

  # 多候选：设备 ABI 优先过滤（无设备时跳过）
  local pool=""
  if [ -n "$device" ]; then
    abi=$(device_abi "$device")
    if [ -n "$abi" ]; then
      pool=$(ls "$apk_dir"/*.apk | grep -i "$abi" || true)
    fi
  fi
  # ⚠️ 末尾 `|| true`：`&&` 链的**末项**（赋值）不受 errexit 豁免 —— 目录被并发清理/glob 不匹配时
  #    `ls` 退 1，会让 `APK_PATH=$(resolve_apk …)`（`run/install/build.sh` 三处**无守卫**调用）静默终止。
  #    （2026-10-17 复审发现 —— 位置轴「`&&` 末项」形态；与 §ios/_common.sh 的空 glob 展示管道同形同竞态。）
  [ -z "$pool" ] && pool=$(ls "$apk_dir"/*.apk || true)

  local n
  n=$(echo "$pool" | wc -l)
  if [ "$n" -eq 1 ]; then
    echo "$pool"
    return 0
  fi

  # 仍多候选：按 mtime 取最新并警告（跨平台 stat 兼容）
  local newest=""
  if stat -f '%m %N' /dev/null >/dev/null 2>&1; then
    newest=$(printf '%s\n' "$pool" | xargs stat -f '%m %N' 2>/dev/null | sort -rn | head -1 | sed 's/^[0-9]* //' || true)
  else
    newest=$(printf '%s\n' "$pool" | xargs stat -c '%Y %n' 2>/dev/null | sort -rn | head -1 | sed 's/^[0-9]* //' || true)
  fi
  echo "⚠️  检测到 $n 个 APK 候选，自动选最新: $newest" >&2
  echo "   候选列表：" >&2
  echo "$pool" | sed 's/^/     - /' >&2
  echo "   如需精确指定，在 .debug.env 设置 ANDROID_APK_PATH" >&2
  echo "$newest"
}

# 解析运行时 applicationId：优先从 APK 提取（覆盖 flavor 的 applicationIdSuffix），
# aapt 不可用时回退 ANDROID_APP_ID 并告警
# 输入：$1 = APK 路径；输出：stdout 打印 appId
resolve_app_id() {
  local apk="$1" id=""
  if command -v aapt >/dev/null 2>&1 && [ -n "$apk" ] && [ -f "$apk" ]; then
    id=$(aapt dump badging "$apk" 2>/dev/null | grep -m1 -oE "package: name='[^']+'" | sed "s/.*'//;s/'//" || true)
  fi
  if [ -n "$id" ]; then
    echo "$id"
  else
    [ -n "${ANDROID_APK_PATH:-}" ] || echo "⚠️  未能从 APK 提取 package（缺 aapt？），使用 .debug.env ANDROID_APP_ID" >&2
    echo "$ANDROID_APP_ID"
  fi
}

# 生效的 App ID（resolve_app_id 结果缓存；未解析时回退 ANDROID_APP_ID）
EFFECTIVE_APP_ID="${ANDROID_APP_ID:-}"

# 拼接完整 activity 名：支持 ".MainActivity" / "com.x.y/.MainActivity" / 全限定名
full_activity() {
  local app_id="${EFFECTIVE_APP_ID:-$ANDROID_APP_ID}"
  # ANDROID_ACTIVITY 可缺省（最小 .debug.env 只含 ANDROID_APP_ID）⇒ 给默认 .MainActivity
  local act="${ANDROID_ACTIVITY:-.MainActivity}"
  case "$act" in
    /*) echo "${app_id}${act}" ;;
    */*) echo "$act" ;;
    *) echo "${app_id}/${act}" ;;
  esac
}

# 输出 App 当前 PID，未运行则输出空串（**契约：未运行 ≠ 报错，必须 exit 0**）
app_pid() {
  # ⚠️ 末尾 `|| true` 是**功能必需**，勿删（2026-10-17 由 A-1 真机实测暴露）：
  # `pidof` 在进程不存在时返回 **1**，经 `| tr | head` 后命令替换退出码非 0，
  # 在调用方的 `set -euo pipefail` 下会把 `PID=$(app_pid …)` **静默终止** ——
  # logs.sh 实测「App 未运行时 rc=1 且**零输出**」，永远走不到第 22 行的友好提示。
  adb -s "$1" shell pidof "${EFFECTIVE_APP_ID:-$ANDROID_APP_ID}" 2>/dev/null | tr -d '\r' | head -1 || true
}

# ---------- 语义树判据（settle.sh / findtap.sh 共用；2026-10-27 新增） ----------
# MIN_DUMP_BYTES      : dump 文件**完整性**下限（只判「dump 像不像样」，**不判内容**）
# SETTLE_MIN_PNG_BYTES: 整屏截图**有效性**下限（0 字节/截断帧不得判「静止」）
# 为什么不用「字节数判空树」：Flutter 未开 semantics 时骨架 dump 仍可达 1–3 KB，
#   字节阈值会**双向失准**（空树判不空 / 极简原生页误判空）。判据改用语义节点数。
MIN_DUMP_BYTES=256
SETTLE_MIN_PNG_BYTES=1024
# 单帧 UI dump 的硬上限（秒）：`uiautomator dump` 在动画/大树上可能挂住，必须带 alarm；
# settle.sh 的「剩余预算是否够采一帧」也用它，两处**必须同源**（改一处即同时生效）。
SETTLE_FRAME_ALARM=10

# ui_has_semantics <file> → stdout 打印「非空 text/content-desc 属性出现次数」
#   契约（必须遵守，否则 `set -euo pipefail` 下会静默终止调用方）：
#     - **永不非零返回**；缺文件 / 空文件 / 含 NUL 等异常输入一律输出 0
#     - 输出非负整数；调用方用 ${N:-0} 兜底
#   口径差异（**不可与 ui.sh 的「共 N 个可点击节点」互相当基准**）：
#     本函数计**属性出现次数**（同一节点 text+desc 计 2）；
#     ui.sh 计「带 bounds 且 clickable=true 的节点数」。
ui_has_semantics() {
  local f="${1:-}" a b
  [ -f "$f" ] || { printf '0\n'; return 0; }
  # `-a` 防二进制/含 NUL 的畸形 XML 被 grep 当二进制而只打印 "Binary file … matches"
  a=$(grep -a -o '[[:space:]]text="[^"]' "$f" 2>/dev/null | wc -l | tr -dc '0-9' || true)
  b=$(grep -a -o '[[:space:]]content-desc="[^"]' "$f" 2>/dev/null | wc -l | tr -dc '0-9' || true)
  printf '%s\n' "$(( ${a:-0} + ${b:-0} ))"
  return 0
}
