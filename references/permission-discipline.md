# 权限纪律完整判据（debug-loop，按需读）

> 由 `SKILL.md` §权限纪律 抽出，内容原样保留；执行前应先读 SKILL 内的硬规则摘要。

## 权限纪律（完整版）

- **唯一执行入口 = 沙箱**：本 skill 的所有命令（含 skill 自己的脚本）一律经 `safe_run.sh` 执行：

  ```bash
  bash <S>/scripts/safe_run.sh [--profile ui|build|ios|macos] [--project-root <proj>] -- <命令...>
  ```

  | profile | 用途 | 额外放行 |
  |---|---|---|
  | `ui`（默认） | 截图 / dump / 点击 / 日志等日常操作 | 写 `build/`、`docs/test/`、`$TMPDIR`、`/private/tmp` |
  | `build` | `flutter build` / `gradle` / `xcodebuild` | 写整个项目 + 缓存目录（含 `~/.pub-cache`、`~/.gradle`、`~/.dart-tool`、**Flutter SDK 的 `bin/cache`**），**且允许出网**（依赖下载；证书校验放行 trustd 通道） |
  | `ios` | `xcrun simctl` / `devicectl` / 模拟器截图 | 补 CoreSimulator / diskimaged 等 mach 通道 |
  | `macos` | `screencapture` / `cliclick` / 智能点击 | 补 WindowServer / CARenderServer / 服务发现通道 |

  - **沙箱是唯一执行边界**：写面只到项目 `build/`、`docs/test/`、`$TMPDIR`、`/private/tmp`（`--profile build` 才放开整个项目根），
    外加调试工具的缓存目录 `~/.maestro`、`~/.appium`、`~/Library/Logs/maestro`（maestro 解包依赖/写日志锁需要，所有 profile 都有）；
    `~/.ssh`、`~/.aws`、`~/.gnupg`、`~/.netrc`、`~/Library/Keychains` 读写全拒，`~/Library/LaunchAgents*`、登录脚本只拒写；
    `.env` / `.env.local` 等 env 家族在 shell 面也读不到（仅 `.debug.env` 放行）；
    iOS 真机链路已放行 **usbmuxd 本机 unix socket**（`libimobiledevice`：`idevice_id`/`ideviceinfo`/`idevicesyslog`；
    `xctrace list devices` 在沙箱内不可用，设备枚举自动回退 `devicectl` / `idevice_id`）；
    默认禁网（仅放行 adb `5037` / appium `4723` 的**本机**端口；另允许 `bind` 本机任意端口，仅 adb 起 daemon 需要）。
  - `--project-root` 缺省取 `$PWD`；**只接受白名单根**（`~/Projects`、`/Volumes`、`/private/tmp`、`$TMPDIR`），
    且拒绝 `$HOME` / `/` 本体。缺省且 `$PWD` 不在白名单时**写面自动收窄到 `$TMPDIR`**（stderr 会提示）；
    要写项目内产物必须显式传项目根。需要新根改 `safe_run.sh` 的 `ALLOW_ROOTS`。
  - **退出码**：`2` = 用法错；**`117` = 沙箱不可用**（fail-closed，命令根本没跑）。
    遇到 `117` 必须停下并回报「沙箱不可用」，**不得**绕过入口裸跑命令。
    ⚠️ 其余退出码是**命令自己的**、原样透传：例如 `snapshot.sh` 的 `rc=4` = 语义树为空（正常观测，见「页面观测阶梯」），
    **不要**把 `4` 当成沙箱故障。
  - 裸 `bash <S>/scripts/<x>.sh`（不经 `safe_run.sh`）在白名单外 ⇒ 秒拒；这是**结构护栏**，不是缺权限。
  - **`<S>` 必须写成绝对路径**（`/Users/<你>/.config/opencode/skills/debug-loop` 或 `.../Projects/debug-loop-skill` 两种都在白名单）；
    写成 `~/.config/...`、`$HOME/...` 或相对路径**不匹配**白名单 ⇒ 秒拒。这是踩过的坑，不是权限问题。
  - 沙箱内 `pgrep` / `ps` 不可用，`kill` 只能作用于**本沙箱内**进程：日志采集的存活判断已改用 pid 文件（见 `ios/logs.sh`）。
- **`Operation not permitted` 的读法**（沙箱拒绝）：
  - 写 `~/.ssh`、写项目外路径、连外网 ⇒ **边界正常**：换落点（`build/debug/`、`$TMPDIR`）或改用 skill 脚本，**不算权限被拒中止**。
  - 需要出网（下载依赖）⇒ 用 `--profile build`，不要 `--net` 硬开普通 profile。
  - 报 `sandbox-exec: sandbox_apply: Operation not permitted` ⇒ **嵌套沙箱被系统拒绝**（典型于 `flutter build ios`）：
    换 profile/加权限都无效，按下条交回主 agent，**不要**反复重试。
  - 只有「沙箱入口本身起不来（rc=117）」或「设备侧权限（USB 调试授权、屏幕录制、辅助功能）」才算中止条件 4。
- **沙箱内**不能**跑 `flutter build ios`**（含 `--profile build`）：xcodebuild 解析 SwiftPM 依赖时会**再套一层
  `sandbox-exec`**，macOS 不允许嵌套沙箱 ⇒ 必失败（实测命令形态：
  `bash <S>/scripts/safe_run.sh --profile build --project-root <项目根> -- bash <S>/scripts/ios/build.sh --device`）：
  ```
  xcodebuild: error: Could not resolve package dependencies:
    sandbox-exec: sandbox_apply: Operation not permitted
  ```
  已实测**无效**的绕过：`env SWIFTPM_DISABLE_SANDBOX=1`（SwiftPM 环境变量）、
  `xcodebuild -resolvePackageDependencies -onlyUsePackageVersionsFromResolvedFile`（xcodebuild 参数）、
  以及换成 `--profile ios`。
  ⇒ **subagent 不得自行到宿主机裸跑构建**（那是绕过唯一执行边界）；应停止并在回报里写
  「iOS 构建需主 agent 在宿主机执行」，由主 agent 构建后你再继续安装/启动/取证。
- **`--profile build` 的 Flutter SDK 缓存按「真实路径」判定**：`command -v flutter` 常是软链
  （brew cask：`/opt/homebrew/bin/flutter` → `Caskroom/<ver>/flutter/bin/flutter`），入口会先解析
  软链链（每跳 `pwd -P`、上限 10 跳）再校验 `<SDK>/bin/cache`；相对路径 / 解析失败（超过 10 跳）
  **不放行且 stderr 说明原因**（此时 flutter 写 cache 报 `Operation not permitted`，属已知限制，不要改权限面）。
  断链 / 成环会被 `command -v` 直接跳过（等同「没装 flutter」，静默），这种情况本就不放行。
- **iOS 真机安装（`devicectl install`）在沙箱内不可用**（实测：`sandbox_extension_issue_file` 被拒，
  `.app` 的访问权限交不给沙箱外的 CoreDevice helper ⇒ 读 `Info.plist` 报 `NSCocoaErrorDomain 257`）。
  `ios/run.sh --device` 在沙箱内会带宿主机指引 **rc=3** 退出（**先停旧采集、安装失败即退出，不留孤儿采集**）；
  安装+启动交主 agent 在宿主机跑 `bash <S>/scripts/ios/run.sh --device`（cwd 为项目根）。
  ⚠️ 把 `.app` 暂存到 `${TMPDIR}` **无效**（已实测），不要重试这类绕过。
- **沙箱内已知能力限制（iOS 模拟器语义能力）**：XCUITest 驱动（maestro 的 iOS 侧）在嵌套沙箱内起不来
  （`maestro-driver` 数秒内退出，JVM 无限轮询 `127.0.0.1:22087`）⇒ 以下命令在沙箱内**直接 rc=3 快失败**，不重试：
  - `snapshot.sh --platform ios`、`assert_page.sh --platform ios`
  - `maestro/*`（iOS 模拟器路径：`assert.sh` / `tap.sh` / `assert_batch.sh` / `flow.sh`）
  - **降级做法**：UI 判定用 `shot.sh`（截图）+ `logs.sh`（日志）+ 人工/视觉判读；**不要**反复重试或用别的形态试探。
  - **iOS 真机不受限**：走 Appium（`snapshot.sh --platform ios-device` / `appium/driver.py`），沙箱内可用（`--profile ios`）。
  - 需强行试验时：`SNAPSHOT_MAESTRO_TRY=1`（snapshot，默认 45 s 有界等待）/ `MAESTRO_ALLOW_SANDBOX=1`（maestro 脚本，
    可能挂起，需自加超时）。
- **`.debug.env` 现在可读**（read 面对 build / autoDebug / debug 放行 `*.debug.env`）：
  需要键值时可直接 `bash <S>/scripts/safe_run.sh -- cat .debug.env`，或交给 `scripts/_env.sh` 解析。
  `.env` / `.env.*` **仍不可读**，不要尝试绕过。
- **产物落点**：沙箱内可写 `build/`、`docs/test/`、`$TMPDIR`、`/private/tmp`；因此：
  - 截图 → `shot.sh`（自带 `mkdir -p "$LOG_DIR"`）
  - 拉设备文件 → `pull.sh <设备侧路径> [本地名]`
  - 读行区间 → **用 `read` 工具的 `offset`/`limit`**（不是 `sed -n 'a,bp'`）
  - 抽字段 → **`grep -oE` / `grep -E -B/-A`**
  - 去重/排序 → `scripts/sort.sh [-u] [-r] [-n] [-k <列>] [-o <文件>]`；也可直接在 `$TMPDIR` 写临时脚本
- **多步逻辑**：优先写进 skill 内脚本；一次性编排可经入口内联：
  `bash <S>/scripts/safe_run.sh -- sh -c 'cd <项目根> && <命令1> && <命令2>'`。
  ⚠️ 内联脚本里**不要写 `>` / `>>` 重定向**：shell 面有硬化的 `* > *` / `* >> *` deny（防写面开洞），
  重定向会被整条拒掉。需要落盘就让脚本自己写（`shot.sh` / `pull.sh` / `snapshot.sh` 都自带落点），
  或用 `tee` 之外的方式（如 `grep -o … -f 文件` 不支持时改写进 `$TMPDIR` 的脚本再执行）。
  ⚠️ 不要拼「`&&` / `;` 串联的裸命令」——那会绕过沙箱入口，落白名单兜底 deny。

