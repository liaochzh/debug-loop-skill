# 其他平台命令与排障（Appium / macOS / Windows）

> 由 `SKILL.md` 抽出，内容原样保留。

## macOS 智能命令（<S>/scripts/macos/ + vision/smart_lib.sh）

一体化「截图 → Vision 定位 → Retina 换算 → 点击」，含安全护栏（置信度 <0.7、危险词、页面 loading/白屏/遮挡时拒绝点击）。命令：`smart_tap.sh`（`--dry-run` / `--stable` / `--allow-danger`）、`smart_assert.sh`（`--not-visible`）、`click.sh <x> <y>` 与 `click.sh --activate <AppName>`。
退出码：0=成功，1=未定位/页面不稳定，2=危险词拒绝，3=Vision/截图失败。**前置权限**：终端需「屏幕录制」（截图）+「辅助功能」（点击）。
**首次使用、报 Vision 失败或坐标偏移时必读** `references/macos-smart.md`（完整命令表、护栏阈值 `SMART_MIN_CONF`、排障）。

## Appium 命令（<S>/scripts/appium/ — iOS 真机 / macOS 实验）

无障碍语义定位（同 Maestro 思路），Appium 3 + W3C WebDriver。命令：`doctor.sh`、`source.sh`（导出 page source 排查元素可否寻址）、`tap.sh`、`assert.sh`（0=成立，1=失败，3=驱动/会话错误）、`flow.sh`（真机多步**必须**走单会话 flow）、`wda_prepare.sh` / `wda_sign.sh`（离线准备真机 WDA）。
⚠️ **不可逆副作用**：路线 A 自动签名会在设备未注册时**自动注册设备**（占用团队年度设备额度）并创建/更新描述文件。iOS 真机需 `IOS_TEAM_ID`；设备上必须是 **profile/release** 包（Flutter debug 包 JIT 受限，page source 无业务元素）。
**首次接 iOS 真机必读** `references/appium-ios-device.md`（前置、路线 A/B、xctestrun 约束、mac2 与 Flutter 桌面已知限制）。

**输入纪律（2026-11-12 起）**：`driver.py find-type` 与 flow 的 `{"type":"type"}` 步骤**默认先清空再输入**，
输入后读 `attribute/value` 校验（不符重试一次，仍不符 rc=1）。全量替换是默认语义 —— 需要追加时显式写
`--no-clear`（CLI）或 `{"clear": false}`（步骤）；**追加语义不自动重试**（重试会变成「旧值+文本+文本」）。
密码框加 `--mask`（只比长度）。平台会转换输入时用 `--expect "<期望读回值>"` 额外断言一次（掩码只比长度）。
敏感值用
`--text-from <文件>`（0600）而不是 `--text`，避免密码进会话记录。⚠️ `POST /element/{eid}/clear` 对
Flutter 输入框的可靠性仍是**未验证假设**：不可用时自动回退「按当前长度发退格键」。

## macOS（<S>/scripts/macos/）

| 命令 | 说明 |
|---|---|
| `build.sh [flutter build 参数]` | `flutter build macos`（透传；**未指定模式则补 `--debug`**；无参默认 `--debug`） |
| `run.sh` | 直接执行二进制，stdout → build/debug/app.log |
| `logs.sh [行数] [关键词]` | tail app.log |
| `shot.sh` | `screencapture -x -D 1` 主屏全屏（终端需「屏幕录制」权限，否则黑图） |
| `click.sh <x> <y>` | 屏幕 point 坐标点击（需「辅助功能」权限 + cliclick 推荐） |
| `smart_tap.sh "<关键词>"` | 智能点击（截图→Vision→换算→点击，含安全护栏） |
| `smart_assert.sh "<关键词>"` | 智能断言可见性 |

UI 自动化：优先 `smart_tap.sh`（Vision 定位 + Retina 换算 + 安全护栏）；仅简单场景才用 AppleScript；代码级测试用 integration_test。

## Windows（<S>/scripts/windows/*.ps1）

仅在 Windows 机器上执行（Flutter Windows 产物无法跨平台构建）。PowerShell 用法：

```powershell
powershell -ExecutionPolicy Bypass -File <S>\scripts\windows\build.ps1
powershell -ExecutionPolicy Bypass -File <S>\scripts\windows\run.ps1     # stdout → build\debug\app.log
powershell -ExecutionPolicy Bypass -File <S>\scripts\windows\logs.ps1 [-Tail 200] [-Filter 关键词]
powershell -ExecutionPolicy Bypass -File <S>\scripts\windows\shot.ps1
```

首次在 Windows 机使用前，按 `references/windows-setup.md` 验证环境。


## iOS 真机（devicectl，2026-10-23 起支持）

- 前置：USB 连接 + 已配对 + iPhone 开启「开发者模式」；签名来自 Xcode 工程 `DEVELOPMENT_TEAM`。
- **真机默认构建 profile**（`--profile`）：iOS 14+ 的 debug(JIT) 包只能由 Flutter/Xcode 启动，`devicectl launch` 会停在 Flutter 限制提示页；`--debug` 仍可构建但需用 `flutter run` 启动。
- `build.sh --device` → `build/ios/iphoneos/*.app`（锁 `.last_ios_app_device`）
- `run.sh --device` → `devicectl device install app` + `process launch`（输出 PID）
- `shot.sh --device` → `devicectl device capture screenshot`（失败回退 `idevicescreenshot`）
- `logs.sh --device [--app-only] [行数] [关键词]` → 读 `build/debug/app_device.log`（后台 `idevicesyslog --syslog-relay | grep "<App 进程名>("` 采集；进程名由产物 `CFBundleExecutable` 推导，`.debug.env` 的 `IOS_APP_NAME` 可覆盖，缺省回退 `Runner`；模拟器日志仍为 `app.log`，两者分文件不交叉）
