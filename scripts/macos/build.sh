#!/bin/bash
# build.sh — 构建 macOS 应用（参数透传给 flutter build，无参默认 --debug）
#   ⚠️ 透传分支同样**补 --debug 缺省**（`flutter build macos` 内置缺省是 --release，不补会静默变 release）。
# 用法: build.sh [--flavor <名>] [--release] ...
# 成功后解析实际 .app 并写入 $LOG_DIR/.last_macos_app 锁文件
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_common.sh"

if [ $# -eq 0 ]; then
  echo "🔨 构建 macOS debug（默认 --debug）..."
  flutter build macos --debug
else
  MODE_ARGS=""
  case " $* " in
    *" --release "*|*" --profile "*|*" --debug "*) ;;
    *) MODE_ARGS="--debug" ;;
  esac
  echo "🔨 构建 macOS（透传参数: $*；模式参数: ${MODE_ARGS:-(显式指定)}）..."
  # shellcheck disable=SC2068
  flutter build macos $MODE_ARGS $@
fi

APP_BUNDLE=$(resolve_macos_app)
if [ -n "$APP_BUNDLE" ] && [ -d "$APP_BUNDLE" ]; then
  atomic_write_lock "$LOG_DIR/.last_macos_app" "$APP_BUNDLE"
  echo "✅ 构建成功: ${APP_BUNDLE}（已锁定）"
else
  echo "❌ 构建失败，未找到 .app"
  exit 1
fi
