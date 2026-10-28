# Appium 命令（`scripts/appium/` — iOS 真机 / macOS 实验）

> **何时必读**：首次接 iOS 真机做 UI 操作前（**必读**）；`doctor.sh` 报缺 TeamID/驱动、`source.sh` 拿到空树、WDA 签名失败、mac2 定位不到 Flutter 控件时。
> 摘要与命令名见 `SKILL.md`「Appium 命令」节；本文件是完整前置、路线 A/B 与已知限制。

**无障碍语义定位**（同 Maestro 思路），基于 Appium 3 + W3C WebDriver；`driver.py` 为极简客户端（requests）。

| 命令 | 说明 |
|---|---|
| `doctor.sh [--platform macos\|ios-device]` | 环境自检（appium/驱动/Xcode/权限/TeamID） |
| `source.sh --platform macos\|ios-device [--wait N]` | 导出当前页面 page source（排查元素可否寻址）；`--wait` 等 App 首帧 |
| `tap.sh "<selector>" --platform macos\|ios-device [--using "accessibility id"] [--app-id] [--udid] [--team-id] [--wait N]` | 语义点击 |
| `assert.sh "<selector>" --platform macos\|ios-device [...] [--not-visible]` | 语义断言（退出码 0=成立，1=失败，3=驱动/会话错误） |
| `flow.sh <steps.json> --platform macos\|ios-device [...]` | 单会话多步（真机每次新建会话会重启 App，多步必须走 flow） |
| `wda_prepare.sh --team-id <T> --profile <描述文件> --wda-bundle-id <id.wda>` | 离线准备真机 WDA（无签名构建→描述文件签名→产出 xctestrun） |
| `wda_sign.sh <Runner.app> <描述文件> ["身份"]` | 用描述文件逐层 codesign（框架→xctest→App） |

**前置**：`npm install -g appium@3 && appium driver install mac2 && appium driver install xcuitest`；`driver.py` 依赖 `python3 + requests`；脚本会自动拉起 Appium 服务（`:4723`，日志 `build/debug/appium.log`）。

**iOS 真机前置（xcuitest）**：
- `IOS_TEAM_ID`（Development Team）必填；`IOS_WDA_BUNDLE_ID` 填本团队名下的 App ID（如 `<AppBundleId>.wda`）；
- **路线 A（Xcode 账号可用）**：登录 Xcode → Accounts 后，appium 会在会话期自动构建并签名 WDA（首次 2–5 分钟）。凭据失效时报 `No Accounts` / code 65，转路线 B；
- **路线 B（离线，推荐在凭据不可用时）**：
  1. `wda_prepare.sh --team-id <T> --profile ~/Library/MobileDevice/Provisioning\ Profiles/<uuid>.mobileprovision --wda-bundle-id <AppBundleId>.wda`（无签名构建 + 描述文件手签，通配 profile 即可覆盖 runner 的 `.xctrunner`）；
  2. `export IOS_XCTESTRUN=<产出>/Build/Products/WebDriverAgentRunner_iphoneos<SDK>-arm64.xctestrun` + `export IOS_WDA_BUNDLE_ID=<AppBundleId>.wda`；
  3. 之后 `source.sh` / `tap.sh` / `flow.sh` 走 `xcodebuild test-without-building`（XCTest 托管 WDA，能正确切后台），不再需要 Xcode 账号；
  4. 约束：xctestrun 必须与 `Build/Products/Debug-iphoneos/` 同级（appium 按 `__TESTROOT__` 相对解析），脚本会自动补 appium 认的固定文件名；
- **不要**在会话期全局传 `PROVISIONING_PROFILE_SPECIFIER`（会被套到 framework target：`WebDriverAgentLib does not support provisioning profiles`）；
- `IOS_PREBUILT_WDA`（`prebuiltWDAPath` + `usePreinstalledWDA`）仅作备选：它依赖 RemoteXPC 后台启动；Xcode 27 栈上 RemoteXPC 不可用时会回退 devicectl **前台**启动，runner 无法自切后台导致 8100 不通；
- 元素查找默认最长等 10s（`driver.py` 内置轮询；封装脚本不暴露 `--element-wait`）；首帧慢时用 `--wait N`。
- 首次安装后的首启偶发空树（1099 B，Flutter semantics 激活延迟），重跑一次 `source.sh` 即恢复。
- ⚠️ 设备上的 App 必须是 **profile/release** 包：Flutter **debug** 包被 WDA/桌面冷启动只会显示「In iOS 14+, debug mode Flutter apps can only be launched from Flutter tooling…」，page source 里没有业务元素。用 `ios/build.sh --device`（默认 `--profile`）+ `run.sh --device` 重装。
- ⚠️ 自动签名会在设备未注册时**自动注册设备**（占用团队年度设备额度），并自动创建/更新描述文件；不触碰 App 自身签名（路线 B 不涉及）。

**macOS（mac2）**：
- 需为 **Xcode Helper** 开启「辅助功能」权限（`open /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/`，拖入系统设置）
- macOS 12+ 需一次性授权：`sudo automationmodetool enable-automationmode-without-authentication`
- ⚠️ **已知限制**：upstream（appium-mac2-driver #186/#306）报告 **Flutter 桌面端 AX 元素不可单独寻址**，mac2 可能无法定位 Flutter 控件；**实测为准**（用 `source.sh` 看 page source），失败则回退「macOS 智能命令（Vision）」

**iOS 真机（xcuitest）**：
- 需 `export IOS_TEAM_ID=<Apple TeamID>` + 设备连接 + Developer Mode + Xcode 账号（免签可跑模拟器）
- 可选 `IOS_DEVICE_APP=<path.ipa/.app>` 指定安装包
- Flutter 3.19+ 的 `Semantics.identifier` → `accessibilityIdentifier`，按 `--using "accessibility id"` 定位
