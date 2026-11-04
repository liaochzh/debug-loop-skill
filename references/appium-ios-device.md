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
| `flow.sh <steps.json> --platform macos\|ios-device [...]` | 单会话多步（**坐标/长按/退后台都走这个**；步骤类型见下） |
| `wda_prepare.sh --team-id <T> --profile <描述文件> --wda-bundle-id <id.wda>` | 离线准备真机 WDA（无签名构建→描述文件签名→产出 xctestrun） |
| `wda_sign.sh <Runner.app> <描述文件> ["身份"]` | 用描述文件逐层 codesign（框架→xctest→App） |

**前置**：`npm install -g appium@3 && appium driver install mac2 && appium driver install xcuitest`；`driver.py` 依赖 `python3 + requests`；脚本会自动拉起 Appium 服务（`:4723`，日志 `build/debug/appium.log`）。

**iOS 真机前置（xcuitest）**：
- `IOS_TEAM_ID`（Development Team）必填；`IOS_WDA_BUNDLE_ID` 填本团队名下的 App ID（如 `<AppBundleId>.wda`）；
- **路线 A（Xcode 账号可用）**：登录 Xcode → Accounts 后，appium 会在会话期自动构建并签名 WDA（首次 2–5 分钟）。凭据失效时报 `No Accounts` / code 65，转路线 B；
- **路线 B（离线，推荐在凭据不可用时）**：
  1. `wda_prepare.sh --team-id <T> --profile ~/Library/MobileDevice/Provisioning\ Profiles/<uuid>.mobileprovision --wda-bundle-id <AppBundleId>.wda`（无签名构建 + 描述文件手签，通配 profile 即可覆盖 runner 的 `.xctrunner`）；
  2. `export IOS_XCTESTRUN=<产出>/Build/Products/WebDriverAgentRunner_iphoneos<SDK>-arm64.xctestrun` + `export IOS_WDA_BUNDLE_ID=<AppBundleId>.wda`；
     **可省略**：`wda_prepare.sh` 默认产物目录 `build/debug/wda-prebuilt/Build/Products/` 下若有 `<udid>_<系统版本>.xctestrun`，`_common.sh` 会自动发现并走 xctestrun 路线（免得把含设备 UDID 的绝对路径写进随项目提交的 `.debug.env`）；`IOS_XCTESTRUN` 也可给**相对项目根**的路径，脚本内部绝对化后再下发给 appium；
  3. 之后 `source.sh` / `tap.sh` / `flow.sh` 走 `xcodebuild test-without-building`（XCTest 托管 WDA，能正确切后台），不再需要 Xcode 账号；
     该路线下**不下发** `appium:updatedWDABundleId`（WDA 的 bundle id 由 xctestrun 的 `TestHostBundleIdentifier` 决定，与 `.debug.env` 的 `IOS_WDA_BUNDLE_ID` 未必同名）；
  4. 约束：xctestrun 必须与 `Build/Products/Debug-iphoneos/` 同级（appium 按 `__TESTROOT__` 相对解析），脚本会自动补 appium 认的固定文件名；
- **不要**在会话期全局传 `PROVISIONING_PROFILE_SPECIFIER`（会被套到 framework target：`WebDriverAgentLib does not support provisioning profiles`）；
- `IOS_PREBUILT_WDA`（`prebuiltWDAPath` + `usePreinstalledWDA`）仅作备选：它依赖 RemoteXPC 后台启动；Xcode 27 栈上 RemoteXPC 不可用时会回退 devicectl **前台**启动，runner 无法自切后台导致 8100 不通；
- 元素查找默认最长等 10s（`driver.py` 内置轮询；封装脚本不暴露 `--element-wait`）；首帧慢时用 `--wait N`。
- 首次安装后的首启偶发空树（1099 B，Flutter semantics 激活延迟），重跑一次 `source.sh` 即恢复。
- ⚠️ Flutter **debug** 包**可以**驱动，但必须满足两条，否则 page source 里只有「In iOS 14+, debug mode Flutter apps can only be launched from Flutter tooling…」限制页：
  1. 先用 `flutter run -d <udid>` 把它启动起来（唯一可用的 debug 启动方式，见 `.ai/commands.md`；`devicectl process launch` / `run.sh --device` 冷启动必然踩限制页）；
  2. `.debug.env` 设 `IOS_ATTACH_ONLY="1"` ⇒ caps 带 **`autoLaunch=false`** + `forceAppLaunch=false` + `shouldTerminateApp=false` + `noReset=true`，Appium **只 attach 不重启**（否则会话创建即重启 App，直接掉进限制页）。
     **`autoLaunch=false` 是唯一真正生效的那个**：`appium-xcuitest-driver/commands/wda/startup.js` 里写的是
     `bundleId: driver.opts.autoLaunch === false ? undefined : bundleId` —— 只给另外两个，WDA 仍会拿 `bundleId` 去
     terminate+launch；表现为「会话建完 App 的 PID 变了」，且**注入的进程环境变量（`Malloc*`）随之丢失**（压测证据作废）。
  另：`ios/run.sh --device` 的 `devicectl` 启动路径同理不可用于 debug 包，只适合 profile/release 包。
- ⚠️ **产物可能悄悄是 debug 包**：Flutter 的 debug 与 release 都可能落在 `build/ios/iphoneos/`。判据只看一条：
  `build/ios/iphoneos/TinoSec.app/Frameworks/App.framework/flutter_assets/kernel_blob.bin` **存在 ⇒ debug**（JIT）；
  不存在才是 AOT（profile/release）。本机实测：`build/ios/iphoneos/` 是 debug（含 kernel_blob），
  AOT 在 `build/ios/Release-iphoneos/`。**踩坑**：devicectl 冷启动 debug 包会永远停在**启动 logo 页**
  （console 打 `Cannot create a FlutterEngine instance in debug mode without Flutter tooling or Xcode.`），
  此时 Appium 的 `tap` 步骤**照样返回 ok**（点在空页上）、三张截图字节完全相同 ⇒ 完全静默的空跑，
  压测「未命中」毫无意义。压测前务必先 `shot.sh --device` 看一眼是不是真 UI。
- ⚠️ 自动签名会在设备未注册时**自动注册设备**（占用团队年度设备额度），并自动创建/更新描述文件；不触碰 App 自身签名（路线 B 不涉及）。

**flow 步骤类型**（`driver.py`；坐标/长按/退后台缺一不可）：
| 步骤 | 说明 |
|---|---|
| `tap` / `type` / `assert` | 语义定位（default `--using "accessibility id"`）；`assert` 失败即整轮失败 |
| `tap_xy {x,y}` / `long_press {x,y,seconds}` | 坐标点击/长按。**图标按钮（如「按住说话」麦克风）在 Flutter 语义树里被合并进父节点，没有独立 id ⇒ 只能坐标** |
| `hold_and_background {x,y,hold,at,seconds}` | 按住 `hold` 秒，同时在 `at` 秒时退后台 `seconds` 秒（复现「按住 → 立即退后台」竞态） |
| `background {seconds}` / `activate {bundleId}` | 退后台 / 唤回前台（`activateApp` 不冷启动） |
| `shot {out}` / `source` / `exec {script,args}` / `wait {seconds}` | 取证与原子动作（`exec` 可跑任意 `mobile:` 命令） |

**三个实测坑（都踩过）**：
- ❌ `mobile: pressButton {name:"home"}` 在真机上**返回成功但空操作**（截图仍在 App 内）⇒ 退后台必须用 `background`（`mobile: backgroundApp`）。
- ❌ W3C actions 的指针状态**不跨调用保持**：单独发 `pointerUp` 会 500 `unknown error` ⇒ 「先 down 再另发命令再 up」这条路不通，只能把「按住+退后台」原子化为 `hold_and_background`。
- ⚠️ `pressKey`/`launchApp`/`clearState` 在 debug 包上一律禁止（会冷启动）。

**判据提示（Flutter + Tuya）**：`print()` 走 stdout**不进 syslog**，`idevicesyslog` 抓不到；debug 包经 `flutter run` 启动时 stdout 会进 flutter 工具日志，可 `tail -F` 镜像到 `build/debug/app_device.log` 供 `logs.sh` 读取。App 内的 `Caches/ipc_diag/ipc_diag.log` 需代码显式 `enableDiag`（本项目 `IpcDiag.enableIfCompiled()` 未被调用 ⇒ 该通道为空），不要拿它当默认证据源。

**macOS（mac2）**：
- 需为 **Xcode Helper** 开启「辅助功能」权限（`open /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/`，拖入系统设置）
- macOS 12+ 需一次性授权：`sudo automationmodetool enable-automationmode-without-authentication`
- ⚠️ **已知限制**：upstream（appium-mac2-driver #186/#306）报告 **Flutter 桌面端 AX 元素不可单独寻址**，mac2 可能无法定位 Flutter 控件；**实测为准**（用 `source.sh` 看 page source），失败则回退「macOS 智能命令（Vision）」

**iOS 真机（xcuitest）**：
- 需 `export IOS_TEAM_ID=<Apple TeamID>` + 设备连接 + Developer Mode + Xcode 账号（免签可跑模拟器）
- 可选 `IOS_DEVICE_APP=<path.ipa/.app>` 指定安装包
- Flutter 3.19+ 的 `Semantics.identifier` → `accessibilityIdentifier`，按 `--using "accessibility id"` 定位
