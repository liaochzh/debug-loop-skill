#!/bin/bash
# wda_sign.sh — 用开发描述文件离线签名 WebDriverAgentRunner-Runner.app
#
# 背景：Xcode 账号凭据失效时 `xcodebuild` 自动签名会报 `No Accounts` / code 65；
#      而 `PROVISIONING_PROFILE_SPECIFIER` 全局传给 xcodebuild 又会被套到 framework target 上
#      （WebDriverAgentLib does not support provisioning profiles）。
#      故走「CODE_SIGNING_ALLOWED=NO 构建 → 本脚本用 profile 里的 entitlements 逐层 codesign」。
#
# 用法:
#   ./wda_sign.sh <WebDriverAgentRunner-Runner.app> <profile.mobileprovision> [codesign 身份]
#
# 说明:
#   - 身份默认取本机 `Apple Development` 中团队与 profile 一致的那张证书（需自行确认）；
#     多证书机器建议显式传第三个参数，如 "Apple Development: xxx (XXXXXXXXXX)"。
#   - 通配符 profile（AppID 形如 TEAM.*）可直接覆盖任意 runner bundle id；
#     签名时会把 application-identifier 具体化为 `TEAM.<bundleId>`，keychain group 同步。
set -euo pipefail

APP="${1:?用法: wda_sign.sh <WebDriverAgentRunner-Runner.app> <profile.mobileprovision> [身份]}"
PROFILE="${2:?用法: wda_sign.sh <app> <profile.mobileprovision> [身份]}"
IDENT="${3:-Apple Development}"

[ -d "$APP" ] || { echo "❌ 没有 app: $APP" >&2; exit 1; }
[ -f "$PROFILE" ] || { echo "❌ 没有 profile: $PROFILE" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ENT="$WORK/ent.plist"

if ! security cms -D -i "$PROFILE" > "$WORK/profile.plist" 2>"$WORK/cms.err"; then
  echo "❌ 描述文件解析失败（security cms -D）: $(head -1 "$WORK/cms.err" 2>/dev/null)" >&2
  exit 1
fi

# 默认身份含义模糊（多团队证书机器上会签错）⇒ 按 profile 里的证书指纹反查本机身份
if [ "$IDENT" = "Apple Development" ]; then
  SHA="$(python3 - "$WORK/profile.plist" <<'PY'
import hashlib, plistlib, sys
d = plistlib.load(open(sys.argv[1], 'rb'))
certs = d.get('DeveloperCertificates') or []
print(hashlib.sha1(certs[0]).hexdigest().upper() if certs else '')
PY
)"
  if [ -n "$SHA" ]; then
    # grep 无命中会退 1；在 set -euo pipefail 下必须兜住，否则「保留默认身份」的回退分支不可达
    MATCH="$(security find-identity -v -p codesigning 2>/dev/null | grep -i "$SHA" | head -1 | sed -E 's/.*"(.*)"/\1/' || true)"
    [ -n "$MATCH" ] && IDENT="$MATCH"
  fi
fi

# profile 的 TeamIdentifier 必须与 app 期望一致；application-identifier 通配符要具体化
python3 - "$WORK/profile.plist" "$ENT" "$APP" <<'PY'
import plistlib, sys, os
prof, out, app = sys.argv[1:4]
d = plistlib.load(open(prof, 'rb'))
ents = dict(d.get('Entitlements') or {})
team = (d.get('TeamIdentifier') or [''])[0]
if not team:
    sys.exit('❌ 描述文件缺少 TeamIdentifier')
bid = plistlib.load(open(os.path.join(app, 'Info.plist'), 'rb'))['CFBundleIdentifier']
ents['application-identifier'] = f'{team}.{bid}'
ents['com.apple.developer.team-identifier'] = team
if 'keychain-access-groups' in ents:
    ents['keychain-access-groups'] = [f'{team}.{bid}']
plistlib.dump(ents, open(out, 'wb'))
print(f'🔏 签名目标: {bid} (team {team})')
PY

# embedded.mobileprovision 会被主 App 签名封存 ⇒ 必须先放好再签
cp "$PROFILE" "$APP/embedded.mobileprovision"

# 顺序：嵌套 framework → xctest → 主 App（带 entitlements）
while IFS= read -r fw; do
  codesign -f -s "$IDENT" "$fw"
  echo "  signed framework: ${fw#"$APP"/}"
done < <(find "$APP" -name "*.framework" -type d)

while IFS= read -r xt; do
  codesign -f -s "$IDENT" "$xt"
  echo "  signed xctest: ${xt#"$APP"/}"
done < <(find "$APP" -name "*.xctest" -type d)

codesign -f -s "$IDENT" --entitlements "$ENT" "$APP"
codesign --verify --deep --strict "$APP"
echo "✅ 签名校验通过"
codesign -d --entitlements :- "$APP" 2>/dev/null | plutil -p - | head -8
