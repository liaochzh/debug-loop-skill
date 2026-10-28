#!/bin/bash
# build.sh — 构建 iOS 包（模拟器免签名 / 真机需签名）
#
# 目标选择：IOS_TARGET=device|simulator（默认 simulator）；IOS_DEVICE_UDID 非空 ⇒ device。
#   参数显式带 --simulator ⇒ 强制模拟器（覆盖上面的选择）。
#   透传参数缺 --debug 时自动补 --debug（`flutter build ios` 内置缺省是 release）。
# 用法: build.sh [--device] [--simulator] [--flavor <名>] [-t <target>] [--release]
# 成功后锁定产物：模拟器 ⇒ $LOG_DIR/.last_ios_app；真机 ⇒ $LOG_DIR/.last_ios_app_device
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_common.sh"

# 首参 --device ⇒ 真机目标（等价 IOS_TARGET=device）；--device 只允许出现在首参
[ "${1:-}" = "--device" ] && { IOS_TARGET=device; shift; }
case " $* " in
  *" --device "*) echo "❌ --device 必须是第一个参数（当前: $*）" >&2; exit 2 ;;
esac

TARGET=$(resolve_ios_target)
case " $* " in
  *" --simulator "*) TARGET=simulator ;;
esac
echo "🎯 目标: $TARGET"

if [ "$TARGET" = "simulator" ]; then
  if [ $# -eq 0 ]; then
    if [ -n "${IOS_SCHEME:-}" ]; then
      echo "🔨 构建 iOS 模拟器包（默认 flavor: ${IOS_SCHEME}）..."
      flutter build ios --debug --simulator --flavor "$IOS_SCHEME"
    else
      echo "🔨 构建 iOS 模拟器包（默认 --debug --simulator）..."
      flutter build ios --debug --simulator
    fi
  else
    # 目标已定为模拟器 ⇒ 透传参数补 --simulator（不改变用户其它参数）
    case " $* " in
      *" --simulator "*) ;;
      *) set -- "$@" --simulator ;;
    esac
    MODE_ARGS=""
    case " $* " in
      *" --release "*|*" --profile "*|*" --debug "*) ;;
      *) MODE_ARGS="--debug" ;;
    esac
    echo "🔨 构建 iOS 模拟器包（透传: $*；模式: ${MODE_ARGS:-(显式指定)}）..."
    # shellcheck disable=SC2068
    flutter build ios $MODE_ARGS "$@"
  fi
else
  if [ $# -eq 0 ] && [ -n "${IOS_SCHEME:-}" ]; then
    set -- --flavor "$IOS_SCHEME"
  fi
  # 真机默认 --profile：iOS 14+ 的 debug(JIT) 包**只能由 Flutter/Xcode 启动**，
  # 用 devicectl launch 会停在「debug mode Flutter apps can only be launched from Flutter tooling」提示页。
  MODE_ARGS=""
  case " $* " in
    *" --release "*|*" --profile "*|*" --debug "*) ;;
    *) MODE_ARGS="--profile" ;;
  esac
  case " $* " in
    *" --debug "*)
      echo "⚠️  真机 --debug 包无法用 devicectl 直接启动（iOS 14+ JIT 限制）——需改 --profile/--release，或用 flutter run 启动" ;;
  esac
  echo "⚠️  真机构建需签名（DEVELOPMENT_TEAM / provisioning）；失败时检查 Xcode 签名配置"
  echo "🔨 构建 iOS 真机包（透传: ${*:-无}；模式: ${MODE_ARGS:-(显式指定)}）..."
  # shellcheck disable=SC2068
  flutter build ios $MODE_ARGS "$@"
fi

APP_PATH=$(resolve_ios_app "$TARGET")
LOCK_FILE="$LOG_DIR/.last_ios_app"
[ "$TARGET" = "device" ] && LOCK_FILE="$LOG_DIR/.last_ios_app_device"
if [ -n "$APP_PATH" ] && [ -d "$APP_PATH" ]; then
  atomic_write_lock "$LOCK_FILE" "$APP_PATH"
  echo "✅ 构建成功: ${APP_PATH}（已锁定 → ${LOCK_FILE}）"
else
  echo "❌ 构建失败，未找到 .app"
  exit 1
fi
