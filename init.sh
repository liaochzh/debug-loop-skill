#!/bin/bash
# init.sh — 在 Flutter 项目根执行，生成 .debug.env（调试常量）
# 脚本本体在 skill 内单一来源，项目内不再复制任何脚本
# 用法: bash init.sh [--force]
set -euo pipefail

FORCE=false
[ "${1:-}" = "--force" ] && FORCE=true

# ---- 工程类型探测：Flutter（pubspec.yaml）或原生 Android（app/build.gradle[.kts] / settings.gradle[.kts]）----
FLUTTER_PROJECT=0
NATIVE_ANDROID=0
if [ -f "pubspec.yaml" ]; then
  FLUTTER_PROJECT=1
  ANDROID_APP_DIR="android/app"
elif [ -f "app/build.gradle" ] || [ -f "app/build.gradle.kts" ] || [ -f "settings.gradle" ] || [ -f "settings.gradle.kts" ]; then
  NATIVE_ANDROID=1
  ANDROID_APP_DIR="app"
  # 默认 app/；若不存在，从 settings.gradle 的 include 推导第一个模块
  if [ ! -f "app/build.gradle" ] && [ ! -f "app/build.gradle.kts" ]; then
    first_mod=""
    for sf in settings.gradle settings.gradle.kts; do
      [ -f "$sf" ] || continue
      first_mod=$(grep -oE "include[[:space:]]*[^)]*" "$sf" 2>/dev/null | head -1 | grep -oE "'[^']+'" | head -1 | tr -d "'")
      [ -n "$first_mod" ] && break
    done
    first_mod="${first_mod#:}"          # 去掉前导 :
    first_mod="${first_mod//:/\/}"     # : → /
    if [ -n "$first_mod" ] && { [ -f "$first_mod/build.gradle" ] || [ -f "$first_mod/build.gradle.kts" ]; }; then
      ANDROID_APP_DIR="$first_mod"
    fi
  fi
else
  echo "❌ 当前目录既不是 Flutter 项目（无 pubspec.yaml），也不是原生 Android 工程（无 app/build.gradle[.kts] / settings.gradle[.kts]）"
  echo "   请在项目根执行；或先用 flutter create / Android Studio 生成工程骨架"
  exit 1
fi

TARGET="$(pwd)/.debug.env"
if [ -f "$TARGET" ] && [ "$FORCE" != true ]; then
  echo "❌ $TARGET 已存在。确认覆盖请加 --force"
  exit 1
fi

# ---------- 工具函数 ----------
ask_or() { # ask_or <提示> <推断值> [allow_empty] —— 推断为空时交互询问
  # allow_empty=true 时：允许为空的可选字段，在非 TTY 下返回空而非报错
  local prompt="$1" inferred="$2" allow_empty="${3:-false}" v=""
  if [ -n "$inferred" ]; then echo "$inferred"; return; fi
  if [ ! -t 0 ]; then
    if [ "$allow_empty" = true ]; then echo ""; return 0; fi
    echo "❌ 无法自动推断「${prompt}」，且当前为非交互环境。" >&2
    echo "   请先在 .debug.env 手工填入对应值后重试。" >&2
    exit 1
  fi
  read -r -p "❓ ${prompt}: " v
  echo "$v"
}

# 从 AndroidManifest.xml 提取首个 *Activity 的 android:name（bash3.2 兼容：逻辑放函数，勿在 $() 内写多行 while+case）
# 注意：activity 属性可能跨多行，先 tr 压成单行再按块提取
extract_activity() {
  local manifest="$1" n=""
  [ -f "$manifest" ] || return 0
  tr '\n' ' ' < "$manifest" \
    | grep -oE '<activity[^>]*>' \
    | grep -oE 'android:name="[^"]*"' \
    | sed -E 's/.*"([^"]*)".*/\1/' \
    | while IFS= read -r n; do
        case "$n" in *Activity*) echo "$n"; break ;; esac
      done \
    | head -1
}

PUBSPEC_NAME=""
if [ "$FLUTTER_PROJECT" -eq 1 ]; then
  PUBSPEC_NAME=$(grep -m1 '^name:' pubspec.yaml | sed 's/name:[[:space:]]*//' | tr -d '[:space:]' || true)
fi

# 列出 gradle 中定义的 productFlavors 名（仅提示用，best-effort；bash3.2 兼容）
list_flavors() {
  local g="$1"
  [ -f "$g" ] || return 0
  { grep -oE "create\(\"[a-zA-Z0-9_]+\"\)" "$g" 2>/dev/null | sed -E 's/.*"([a-zA-Z0-9_]+)".*/\1/'; } || true
  { sed -n "/productFlavors/,/^ *}/p" "$g" 2>/dev/null | grep -oE "^[[:space:]]+[a-z][a-zA-Z0-9_]*[[:space:]]*{" | grep -oE "[a-z][a-zA-Z0-9_]*" | grep -v "^productFlavors$" | sort -u; } || true
}

# 列出所有 AndroidManifest.xml 中的 Activity（main 优先，其次各 flavor）
list_manifest_activities() {
  local m a
  for m in "$ANDROID_APP_DIR/src/main/AndroidManifest.xml" $(find "$ANDROID_APP_DIR/src" -mindepth 2 -maxdepth 2 -name AndroidManifest.xml 2>/dev/null | grep -v '/main/' | sort); do
    [ -f "$m" ] || continue
    a=$(extract_activity "$m" || true)
    [ -n "$a" ] && echo "$m :: $a"
  done
}

# 列出 pbxproj 中所有 PRODUCT_BUNDLE_IDENTIFIER（含 Target/Configuration 上下文）
list_bundle_ids() {
  local pbx="$1"
  [ -f "$pbx" ] || return 0
  { grep -oE 'PRODUCT_BUNDLE_IDENTIFIER = [^;]+' "$pbx" 2>/dev/null | sort -u; } || true
}

# ---------- 平台检测与常量推断 ----------
ANDROID_APP_ID=""; ANDROID_ACTIVITY=".MainActivity"; ANDROID_FLAVOR=""
IOS_BUNDLE_ID=""; IOS_SCHEME=""
MACOS_APP_NAME=""; WINDOWS_APP_NAME=""
PLATFORMS=()

echo "🔍 检测平台与常量..."
echo ""

# ---- Android ----
if [ -d android ] || [ "$NATIVE_ANDROID" -eq 1 ]; then
  PLATFORMS+=("android")
  GRADLE=""
  [ -f "$ANDROID_APP_DIR/build.gradle.kts" ] && GRADLE="$ANDROID_APP_DIR/build.gradle.kts"
  [ -z "$GRADLE" ] && [ -f "$ANDROID_APP_DIR/build.gradle" ] && GRADLE="$ANDROID_APP_DIR/build.gradle"
  if [ -z "$GRADLE" ] && [ "$NATIVE_ANDROID" -eq 1 ]; then
    echo "❌ 原生 Android 工程缺少 $ANDROID_APP_DIR/build.gradle[.kts]（先跑一次 gradle 同步/构建生成）"
    exit 1
  fi
  if [ -n "$GRADLE" ]; then
    # 兼容 kts (applicationId = "x") 与 groovy (applicationId "x")
    ANDROID_APP_ID=$(grep -oE 'applicationId[[:space:]]*(=|:)?[[:space:]]*"[^"]+"' "$GRADLE" | head -1 | sed -E 's/.*"([^"]+)".*/\1/' || true)
    FLAVORS=$(list_flavors "$GRADLE")
    if [ -n "$FLAVORS" ]; then
      echo "   📋 检测到 productFlavors:"
      echo "$FLAVORS" | sed 's/^/      - /'
    fi
    SUFFIX=$(grep -oE 'applicationIdSuffix[[:space:]]*(=|:)?[[:space:]]*"[^"]+"' "$GRADLE" | head -1 | sed -E 's/.*"([^"]+)".*/\1/' || true)
    [ -n "$SUFFIX" ] && echo "   ⚠️  检测到 applicationIdSuffix: ${SUFFIX}（运行时 ID = 基值+后缀，脚本会自动从 APK 提取）"
  fi
  ANDROID_APP_ID=$(ask_or "Android applicationId（基值；flavor suffix 运行时自动从 APK 提取，无需手工补）" "$ANDROID_APP_ID")
  if [ -n "${FLAVORS:-}" ]; then
    ANDROID_FLAVOR=$(ask_or "Android flavor（dev/stg/prod 等；为空则不传 --flavor，使用默认 flavor）" "" true)
  fi

  echo "   📋 各 Manifest 的 Activity:"
  { list_manifest_activities | sed 's/^/      /'; } || true
  A=$(extract_activity "$ANDROID_APP_DIR/src/main/AndroidManifest.xml" || true)
  [ -n "$A" ] && ANDROID_ACTIVITY="$A"
  echo "   ✅ Android: $ANDROID_APP_ID / $ANDROID_ACTIVITY${ANDROID_FLAVOR:+ / flavor=$ANDROID_FLAVOR}"
fi

# ---- iOS ----
if [ -d ios ]; then
  PLATFORMS+=("ios")
  PBXPROJ=$(find ios -name project.pbxproj 2>/dev/null | head -1 || true)
  if [ -n "$PBXPROJ" ]; then
    echo "   📋 检测到 BundleID（多 Target/Scheme 时列出全部，请选默认）:"
    list_bundle_ids "$PBXPROJ" | sed 's/^/      /'
    IOS_BUNDLE_ID=$(grep -m1 -oE 'PRODUCT_BUNDLE_IDENTIFIER = [^;]+' "$PBXPROJ" | sed 's/.*= //' || true)
  fi
  IOS_BUNDLE_ID=$(ask_or "iOS Bundle Identifier（默认；多 Target 运行时自动从 .app Info.plist 提取）" "$IOS_BUNDLE_ID")
  IOS_SCHEME=$(ask_or "iOS Scheme（Runner 之外的 Target 名；为空则自动发现 .app）" "" true)
  echo "   ✅ iOS: $IOS_BUNDLE_ID${IOS_SCHEME:+ / scheme=$IOS_SCHEME}"
fi

# ---- macOS ----
if [ -d macos ]; then
  PLATFORMS+=("macos")
  APPINFO=$(find macos -name AppInfo.xcconfig 2>/dev/null | head -1 || true)
  if [ -n "$APPINFO" ]; then
    MACOS_APP_NAME=$(grep -m1 '^PRODUCT_NAME' "$APPINFO" | sed 's/^[^=]*=[[:space:]]*//' | xargs || true)
  fi
  [ -z "$MACOS_APP_NAME" ] && MACOS_APP_NAME="$PUBSPEC_NAME"
  MACOS_APP_NAME=$(ask_or "macOS 应用名（AppInfo.xcconfig PRODUCT_NAME）" "$MACOS_APP_NAME")
  echo "   ✅ macOS: $MACOS_APP_NAME"
fi

# ---- Windows ----
if [ -d windows ]; then
  PLATFORMS+=("windows")
  CMAKELISTS="windows/CMakeLists.txt"
  if [ -f "$CMAKELISTS" ]; then
    WINDOWS_APP_NAME=$(grep -m1 -oE 'set\(BINARY_NAME "[^"]+"\)' "$CMAKELISTS" | sed -E 's/.*"([^"]+)".*/\1/' || true)
  fi
  [ -z "$WINDOWS_APP_NAME" ] && WINDOWS_APP_NAME="$PUBSPEC_NAME"
  WINDOWS_APP_NAME=$(ask_or "Windows 应用名（CMakeLists BINARY_NAME）" "$WINDOWS_APP_NAME")
  echo "   ✅ Windows: $WINDOWS_APP_NAME"
fi

if [ ${#PLATFORMS[@]} -eq 0 ]; then
  if [ "$NATIVE_ANDROID" -eq 1 ]; then
    echo "❌ 原生 Android 工程未检测到 app/src/main/AndroidManifest.xml（先跑一次构建生成）"
  else
    echo "❌ 未检测到任何平台目录（android/ios/macos/windows），先 flutter create 添加平台"
  fi
  exit 1
fi

# ---------- 生成 .debug.env ----------
cat > "$TARGET" <<EOF
# .debug.env — debug-loop 调试常量（init.sh 生成，可手工修正；建议随项目提交 git）
ANDROID_APP_ID="$ANDROID_APP_ID"
ANDROID_ACTIVITY="$ANDROID_ACTIVITY"
ANDROID_FLAVOR="$ANDROID_FLAVOR"
# 显式覆盖产物路径（多项目 exotic 命名时用；为空则自动发现最新产物）
ANDROID_APK_PATH=""
IOS_BUNDLE_ID="$IOS_BUNDLE_ID"
IOS_SCHEME="$IOS_SCHEME"
IOS_APP_PATH=""
# iOS 真机（Appium xcuitest）：Apple TeamID（Appium 需要）；可选真机安装包路径
IOS_TEAM_ID=""
IOS_DEVICE_APP=""
MACOS_APP_NAME="$MACOS_APP_NAME"
MACOS_APP_BUNDLE=""
WINDOWS_APP_NAME="$WINDOWS_APP_NAME"
WINDOWS_EXE_PATH=""
LOG_DIR="build/debug"
# Vision Tool（可选）：百炼 Token Plan Key；留空则从环境变量 VISION_API_KEY / OPENAI_API_KEY 读取
# ⚠️ 若填入真实 Key：本文件建议随项目提交 git，务必把含 Key 的 .debug.env 加入 .gitignore 或改走环境变量，避免密钥入库
VISION_API_KEY=""
EOF

echo ""
echo "✅ 生成完成: ${TARGET}（检测到平台: ${PLATFORMS[*]}）"
echo ""
echo "下一步（脚本为全局单一来源，无需复制到本项目）："
echo "  DBG=~/.config/opencode/skills/debug-loop/scripts"
echo "  Android:  bash \$DBG/android/run.sh && bash \$DBG/android/logs.sh"
[ -d ios ] && echo "  iOS:      bash \$DBG/ios/run.sh（需已启动模拟器或可用 runtime）"
[ -d macos ] && echo "  macOS:    bash \$DBG/macos/run.sh"
[ -d windows ] && echo "  Windows:  在 Windows 机按 references/windows-setup.md 验证"
exit 0
