#!/bin/bash
# wda_prepare.sh — 离线准备 iOS 真机 WDA（无签名构建 → 描述文件签名 → 产出 xctestrun）
#
# 用途：Xcode 账号凭据失效 / 不想让 appium 会话期跑 xcodebuild 时，一次性准备好 WDA 产物，
#      之后用 `IOS_XCTESTRUN=<产出的 .xctestrun>` 走 appium 的 test-without-building 路线。
#
# 用法:
#   ./wda_prepare.sh --team-id <TeamID> --profile <profile.mobileprovision>
#                    [--wda-bundle-id <id>] [--identity "Apple Development: ..."] [--out-dir <dir>]
#
# 说明:
#   - `--wda-bundle-id` 默认 `com.<team>.wda` 形式由调用方给；必须能被 profile 的 AppID 覆盖
#     （通配符 profile 形如 TEAM.* 时可任意）。
#   - 产物目录结构固定为 <out-dir>/Build/Products/Debug-iphoneos/，因为 appium 按
#     `<IOS_XCTESTRUN 同级目录>/__TESTROOT__` 解析 xctestrun 里的相对路径。
#   - 首次全量构建约 1–2 分钟；重复执行是增量，可放心重跑。
set -euo pipefail

TEAM_ID=""; PROFILE=""; WDA_BID=""; IDENT="Apple Development"
OUT_DIR="$(pwd)/build/debug/wda-prebuilt"

while [ $# -gt 0 ]; do
  case "$1" in
    --team-id)       [ $# -ge 2 ] || { echo "❌ --team-id 缺参数值"; exit 2; };       TEAM_ID="$2"; shift 2 ;;
    --profile)       [ $# -ge 2 ] || { echo "❌ --profile 缺参数值"; exit 2; };       PROFILE="$2"; shift 2 ;;
    --wda-bundle-id) [ $# -ge 2 ] || { echo "❌ --wda-bundle-id 缺参数值"; exit 2; }; WDA_BID="$2"; shift 2 ;;
    --identity)      [ $# -ge 2 ] || { echo "❌ --identity 缺参数值"; exit 2; };      IDENT="$2"; shift 2 ;;
    --out-dir)       [ $# -ge 2 ] || { echo "❌ --out-dir 缺参数值"; exit 2; };       OUT_DIR="$2"; shift 2 ;;
    -*) echo "❌ 未知参数: $1"; exit 2 ;;
    *)  echo "❌ 未知参数: $1"; exit 2 ;;
  esac
done

[ -n "$TEAM_ID" ] || { echo "❌ 缺 --team-id"; exit 2; }
[ -f "$PROFILE" ] || { echo "❌ 描述文件不存在: $PROFILE"; exit 2; }
[ -n "$WDA_BID" ] || { echo "❌ 缺 --wda-bundle-id（如 com.example.app.wda）"; exit 2; }

WDA_PKG="${APPIUM_HOME:-$HOME/.appium}/node_modules/appium-xcuitest-driver/node_modules/appium-webdriveragent"
[ -d "$WDA_PKG" ] || { echo "❌ 找不到 WDA 工程: ${WDA_PKG}（先 appium driver install xcuitest）"; exit 1; }

mkdir -p "$(dirname "$OUT_DIR")"
echo "📦 WDA 工程: $WDA_PKG"
echo "🔨 无签名构建 → $OUT_DIR"
cd "$WDA_PKG"
xcodebuild build-for-testing \
  -project WebDriverAgent.xcodeproj -scheme WebDriverAgentRunner \
  -destination "generic/platform=iOS" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  DEVELOPMENT_TEAM="$TEAM_ID" PRODUCT_BUNDLE_IDENTIFIER="$WDA_BID" \
  -derivedDataPath "$OUT_DIR" > "$OUT_DIR.build.log" 2>&1 \
  || { echo "❌ 构建失败，日志: $OUT_DIR.build.log"; tail -20 "$OUT_DIR.build.log"; exit 1; }

PRODUCTS="$OUT_DIR/Build/Products/Debug-iphoneos"
APP="$PRODUCTS/WebDriverAgentRunner-Runner.app"
# glob 无匹配时 ls 退 2，set -e 会静默杀脚本 ⇒ 必须兜底；多份时取最新（SDK 升级会残留旧文件）
XCTESTRUN="$(ls -t "$OUT_DIR"/Build/Products/*.xctestrun 2>/dev/null | head -1 || true)"
[ -d "$APP" ] || { echo "❌ 构建完成但没找到 $APP"; exit 1; }
[ -n "$XCTESTRUN" ] || { echo "❌ 构建完成但没找到 .xctestrun"; exit 1; }

echo "🔏 用描述文件签名（${PROFILE}）"
bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wda_sign.sh" "$APP" "$PROFILE" "$IDENT"

cat <<EOF

✅ 准备完成
   xctestrun: $XCTESTRUN

   下一步（把 xctestrun 交给 appium 的 test-without-building 路线）：
     export IOS_XCTESTRUN="$XCTESTRUN"
     export IOS_WDA_BUNDLE_ID="$WDA_BID"
     appium/source.sh --platform ios-device --udid <UDID> --team-id $TEAM_ID --app-id <AppBundleId>
EOF
