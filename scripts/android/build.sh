#!/bin/bash
# build.sh — 构建 APK（参数透传给 flutter build；**未显式指定 --release/--profile 时一律补 --debug**）
# 用法: build.sh [--flavor <名>] [--split-per-abi] [--release] [--dart-define=K=V] ...
#   ⚠️ 为何必须补：`flutter build apk` 的**内置缺省是 --release** ⇒ 透传任意参数而不补，
#      会**静默变成 release 构建**（2026-10-17 实测：`build.sh --android-skip-build-dependency-validation`
#      跑的是 assembleRelease，并因 release 专有任务引入额外依赖而失败）。
# 构建成功后解析实际产物并写入 $LOG_DIR/.last_android_apk 锁文件
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_common.sh"

# 本脚本封装的是 `flutter build apk` ⇒ 原生 Android 工程不可用（早退，别让调用方空转）
if [ "${IS_FLUTTER:-1}" -eq 0 ]; then
  echo "❌ 非 Flutter 项目不支持本脚本（它封装的是 flutter build apk）" >&2
  echo "💡 构建交回主 agent / 人工执行（autoDebug 档无 gradle 执行面）；原生工程通常用 ./gradlew assembleDebug" >&2
  exit 1
fi

if [ $# -eq 0 ]; then
  if [ -n "${ANDROID_FLAVOR:-}" ]; then
    echo "🔨 构建 debug APK（默认 flavor: ${ANDROID_FLAVOR}）..."
    flutter build apk --debug --flavor "$ANDROID_FLAVOR"
  else
    echo "🔨 构建 debug APK（默认 --debug）..."
    flutter build apk --debug
  fi
else
  # ⚠️ 缺省补 --debug（2026-10-17 实测坑）：`flutter build apk` 的**内置缺省是 --release**，
  #    透传参数时不补 --debug 会**静默变 release**（实测：`build.sh --android-skip-build-dependency-validation`
  #    跑的是 assembleRelease，并因 release 专有任务引入额外依赖而失败）。
  MODE_ARGS=""
  case " $* " in
    *" --release "*|*" --profile "*|*" --debug "*) ;;
    *) MODE_ARGS="--debug" ;;
  esac
  echo "🔨 构建 APK（透传参数: $*；模式参数: ${MODE_ARGS:-(显式指定)}）..."
  # shellcheck disable=SC2068
  flutter build apk $MODE_ARGS $@
fi

APK_PATH=$(resolve_apk || true)   # ⚠️ 守卫：无守卫时 resolve_apk 失败会在 set -e 下静默终止（inventory §4.1）
if [ -n "$APK_PATH" ] && [ -f "$APK_PATH" ]; then
  atomic_write_lock "$LOG_DIR/.last_android_apk" "$APK_PATH"
  echo "✅ 构建成功: ${APK_PATH}（已锁定）"
else
  echo "❌ 构建失败，未找到 APK"
  exit 1
fi
