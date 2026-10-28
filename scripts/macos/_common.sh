#!/bin/bash
# _common.sh — macOS desktop 脚本公共段（由各脚本 source，不直接执行）
#
# 约定：必须从 Flutter 项目根执行（脚本按 $PWD 查找 .debug.env）
#   ⚠️ .debug.env **不再 source**（source 等于执行项目内文本）⇒ 走 scripts/_env.sh 安全解析

# 自取目录：调用方才有 SCRIPT_DIR，而本文件也可能被 `bash -c 'source …/macos/_common.sh'` 直接加载
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

if [ -z "${MACOS_APP_NAME:-}" ]; then
  echo "❌ .debug.env 缺少 MACOS_APP_NAME — 请补填或重新运行 init.sh"
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

# 按 mtime 取最新的辅助函数：输入为换行分隔的路径列表
# 守卫：候选在 ls→stat 之间被删 / 路径含空格致 xargs 拆词等属「非 0 但正常语义」，
#       不得触发 errexit 使调用方（resolve_macos_app → build.sh/run.sh）静默死
#       —— 对齐 ios/_common.sh:73,75 与 android/_common.sh:114,116 内联版的 `|| true`
newest_of() {
  if stat -f '%m %N' /dev/null >/dev/null 2>&1; then
    printf '%s\n' "$1" | xargs stat -f '%m %N' 2>/dev/null | sort -rn | head -1 | sed 's/^[0-9]* //' || true
  else
    printf '%s\n' "$1" | xargs stat -c '%Y %n' 2>/dev/null | sort -rn | head -1 | sed 's/^[0-9]* //' || true
  fi
}

# 解析 macOS .app（Debug/Release 双目录 + PRODUCT_NAME 变化兼容）
# 依赖：MACOS_APP_BUNDLE（显式覆盖，可空）、$LOG_DIR/.last_macos_app（锁文件）
resolve_macos_app() {
  # 1. 显式覆盖
  if [ -n "${MACOS_APP_BUNDLE:-}" ]; then
    if [ -d "$MACOS_APP_BUNDLE" ]; then
      echo "$MACOS_APP_BUNDLE"
      return 0
    else
      echo "⚠️  MACOS_APP_BUNDLE 指向不存在: ${MACOS_APP_BUNDLE}，回退自动发现" >&2
    fi
  fi

  # 2. 锁文件
  local locked
  locked=$(read_lock "$LOG_DIR/.last_macos_app")
  if [ -n "$locked" ] && [ -d "$locked" ]; then
    echo "$locked"
    return 0
  fi
  [ -n "$locked" ] && echo "🔓 锁文件过期（$locked 不存在），回退目录发现" >&2

  # 3. 目录发现：Debug/Release 双目录合并
  local pool=""
  for d in build/macos/Build/Products/Debug build/macos/Build/Products/Release; do
    [ -d "$d" ] || continue
    # 优先按 MACOS_APP_NAME 精确匹配
    if [ -n "${MACOS_APP_NAME:-}" ] && [ -d "$d/$MACOS_APP_NAME.app" ]; then
      pool="${pool:+$pool
}$d/$MACOS_APP_NAME.app"
    else
      local found
      found=$(ls -d "$d"/*.app 2>/dev/null || true)
      [ -n "$found" ] && pool="${pool:+$pool
}$found"
    fi
  done
  [ -z "$pool" ] && { echo "❌ 未找到 macOS .app，请先运行 build.sh" >&2; return 1; }

  local n
  n=$(echo "$pool" | wc -l)
  if [ "$n" -eq 1 ]; then
    echo "$pool"
    return 0
  fi
  local newest
  newest=$(newest_of "$pool")
  echo "⚠️  检测到 $n 个 .app 候选，自动选最新: $newest" >&2
  echo "$pool" | sed 's/^/     - /' >&2
  echo "$newest"
}

APP_BUNDLE="build/macos/Build/Products/Debug/$MACOS_APP_NAME.app"
BIN_PATH="$APP_BUNDLE/Contents/MacOS/$MACOS_APP_NAME"
