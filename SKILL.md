---
name: debug-loop
description: 多平台自动化调试闭环（Android 真机/模拟器、iOS 模拟器+真机、macOS/Windows；Android 支持 Flutter 与原生工程）。构建→安装→启动→抓日志→截图→UI操作复现→验证修复。当需要真机/模拟器调试应用、采集 logcat/应用日志、复现 Bug、验证修复效果、操作 Android UI（点击/滑动/截图）时使用。仅用于「真机/模拟器上的运行调试与复现」；不用于编译期报错修复（code-error-fixer）、不用于纯代码审查（review）。
license: MIT
metadata:
  scope: multi-platform（Android 含 Flutter 与原生工程）
  requires: adb / Xcode(simctl + devicectl) / libimobiledevice(idevicesyslog) / macOS(screencapture) / PowerShell(windows)
---

# Debug Loop — Flutter 多平台自动化调试

**脚本为全局单一来源**（本 skill 的 `scripts/` 目录），项目内仅有 `.debug.env` 常量文件。
下文 `<S>` 指本 skill 的 base directory（加载时由系统给出绝对路径）。

## 前置检查（必做）

1. 在**项目根**确认存在 `.debug.env`（**Flutter 工程与原生 Android 工程均可**）。若不存在，运行：
   ```bash
   bash <S>/init.sh
   ```
   > `.debug.env` 由**主 agent / 人工**准备：subagent 档无写权限，**不能自举** ⇒ 缺失时立即登记阻塞并返回，不要重试。
2. `.debug.env` 含各平台常量（包名/BundleID/AppName + 可选 flavor/scheme/显式产物路径），推断错误可手工修正后重试。
   > `.debug.env` 是 **KEY=VALUE 常量文件**，由 `scripts/_env.sh` **安全解析**（不 `source`、不 `eval`、不展开变量）。
   > 允许 `export ` 前缀 / 行尾 ` #` 注释 / CRLF；**变量引用（`$HOME/…`）不展开**；值里含 `;`、反引号、`$(` 会被**拒绝**（防注入）。
3. **一次自检代替逐项探测**：`bash <S>/scripts/doctor.sh [--platform android|ios|macos|windows]`
   一条命令报告「配置 / 工具链 / 设备 / 产物 / 可选密钥」五类事实（✅ 可用 / ⚠️ 可选缺失 / ❌ 阻塞），
   rc=0 才继续；rc=1 说明有阻塞项，按提示修复，**不要**再用 `adb devices`、`which xxx` 逐条试探。
   > 判据纪律（借 agent-device / MobileBuildMCP 的 doctor 模式）：**「命令被拒」≠「环境不可用」**。
   > 先看 doctor 的 ❌ 分级，再决定是补配置还是改路径；不要凭单条命令失败就宣布环境不可用。

## 执行约定

- 所有脚本必须从**项目根**执行（按 `$PWD` 查找 `.debug.env`，产物写入项目 `build/debug/`）
- 调用形式：`bash <S>/scripts/<platform>/<script>.sh [args]`
- **启动经济**：一次定位设备、一次 dump 页面、一次读日志。禁止用 `--help`、`adb devices`、`ui.sh` 反复探路来「确认状态」——
  目标脚本自身会给出事实与失败原因；重复探测既慢，又容易把「页面确实是空的」误判成「权限或环境坏了」。
  需要新一轮事实时，先问「上一条证据缺什么」，而不是把同样的命令再跑一次。
- **脚本的 `💡` 提示优先于自行重规划**：失败输出里的处置建议（降级路径、候选清单、`ui.sh rc=N`）就是下一手依据；
  先按提示做一次，再考虑换思路。
- 解析优先级（由强到弱，**不得跳级**）：**语义/文本定位**（Maestro → `ui.sh`/`findtap.sh`）＞ **Vision 视觉定位** ＞ **坐标**。
  坐标是兜底，用前必须 `shot.sh` 看过当前页；用了坐标就要在回报里写明「坐标兜底 + 已截图确认」。
- **工程类型差异**（`pubspec.yaml` 存在与否自动探测）：

  | 能力 | Flutter 工程 | 原生 Android 工程 |
  |---|---|---|
  | `shot/tap/swipe/ui/settle/findtap/logs/logclear/logwatch/pull` | ✅ | ✅ |
  | `run.sh`（启动） | ✅ | ✅（无 APK 时跳过安装，用设备上已装版本） |
  | `install.sh` | ✅（需 APK） | 需在 `.debug.env` 设 `ANDROID_APK_PATH`（**不自动发现 APK**） |
  | `build.sh` | ✅ | ❌（封装的是 `flutter build apk` ⇒ 交回主 agent 用 gradle） |
  | `maestro/`、`appium/` | ✅ | ❌（这两处 `_common.sh` 仍有 Flutter 门 ⇒ 直接用 `ui.sh`/`tap.sh`/`findtap.sh`） |

- ⚠️ `gradlew clean` 会清空 `build/debug` ⇒ 证据要及时外带（`pull.sh` 拉出设备文件）。
- `scripts/test.sh`（单元测试）**仅 Flutter 工程**可用（封装 `flutter test`）；原生 Android 工程的测试交回主 agent 用 gradle。
- **依赖安装与升级属于用户动作**：`brew install maestro`、`npm i -g appium`、`sudo automationmodetool …` 等**不自动执行**。
  缺工具时由本 skill 报「缺 X，需用户安装」（doctor.sh 已分级标出），不要 `npx -y xxx@latest` 之类可变版本自举。

### 权限纪律（作为 subagent 执行时**必须**遵守）

- **单命令纪律**：一条 `shell` 只跑**单条命令**；多步串联 / 条件 / 循环一律**写进脚本**再 `bash <S>/scripts/…` 调用。
  原因：本 skill 在 subagent 档是「**白名单 + 兜底 `deny`**」，白名单之外的复合行会落兜底 `deny`（**秒拒**，不再挂 1 h）。
  ⚠️ 白名单按**逐段判权**（引擎实测）：复合命令中**任一段**不可达 `allow` ⇒ **整条拒**（故 `&&` / `;` 串联基本不可用）。
- **白名单命令形态**（B6-1 后；2026-10-23 起仅留实存拼写）：`bash <home>/.config/opencode/skills/debug-loop/scripts/*`
  —— **唯一放行的绝对拼写**（`<home>` 指本机家目录；镜像路径 `<home>/code/opencode-skills/…` 已随死规则清理移除，该目录从未实存）；
  `~` 形式**不放行**（`shell` 的 pattern 侧**不展开** `~`）。
- **单命令放行集**（2026-10-23 实测，均为**单条**命令）：`adb *`、`ls *`、`pwd`、`head *`、`tail *`、`wc *`、`grep *`、`which *`、
  `flutter build *` / `flutter test*` / `flutter analyze*`、`maestro *`、`appium *`、`xcrun *`、`screencapture *`、`echo *`、
  `printenv *`、`git status *` / `git diff *`。
  ⚠️ **被拒 ≠ 整档无 shell**：单条命令落兜底 `deny`（如 `cat`、`sed`、`sort`、`mkdir`、重定向）时，按本表单命令换形态或改用脚本，
  **不得**据此判定「权限被拒」中止条件（2026-10-23 事故：`pwd` 被拒后误判全禁并中止，同期 `adb devices` 实为 allow）。
  ⚠️ `.debug.env` **不可 `cat`**（read 面 env 家族 deny）—— 由 `scripts/_env.sh` 解析，需要键名交回主 agent 转述。
- **subagent 档没有 `mkdir` / 写重定向** ⇒ 产物落点**一律交给脚本**：
  - 截图 → `shot.sh`（自带 `mkdir -p "$LOG_DIR"`）
  - 拉设备文件 → `pull.sh <设备侧路径> [本地名]`（自带 `mkdir -p` + `adb pull`）
  - 读行区间 → **用 `read` 工具的 `offset`/`limit`**（不是 `sed -n 'a,bp'`）
  - 抽字段 → **`grep -oE` / `grep -E -B/-A`**（不是 `sed 's///'`）
  - 去重/排序 → 本档面**无** `sort`/`uniq` ⇒ 用 `scripts/sort.sh [-u] [-r] [-n] [-k <列>] [-o <文件>] [输入文件]`（stdin 亦可）；去重加 `-u`，数值排序 `-n`，按列 `-k N`，落盘 `-o`（写入 LOG_DIR）
  > 需要一次性多步逻辑时：写进 skill 内脚本再 `bash <S>/scripts/…` 调用（`bash …/scripts/*` 在白名单内）。
  > `$TMPDIR` 临时脚本配方（`mkdir -p "$T"; cat > …`）在 **build/debug 档**可用，在 **autoDebug 档不可用**（无 `mkdir`、写重定向被 deny）。

## 产物解析（多 flavor/ABI/mode 通用）

- `build.sh` 参数透传给 `flutter build`（如 `build.sh --flavor dev --split-per-abi`）；**未显式指定 `--release`/`--profile` 时一律补 `--debug`**（`flutter build apk` 的内置缺省是 release，不补会静默变 release 构建）；无参时用默认 `--debug`，若 `.debug.env` 配了 `ANDROID_FLAVOR`/`IOS_SCHEME` 则自动加 `--flavor`。
- 构建成功后解析实际产物（兼容 `app-<flavor>-<mode>.apk` / `app-<abi>-<flavor>-<mode>.apk` / `<Scheme>.app`），写入 `build/debug/.last_<platform>_*` 锁文件。
- `install.sh`/`run.sh` 按「显式覆盖（`ANDROID_APK_PATH`/`IOS_APP_PATH`/`MACOS_APP_BUNDLE`/`WINDOWS_EXE_PATH`）> 锁文件 > 输出目录最新发现」三级解析；多候选时按设备 ABI 优先（Android）+ mtime 取最新并警告；`flutter clean` 后锁失效自动回退目录发现。
- 运行时 ID 以产物为准：Android 从 APK 提取 package（覆盖 `applicationIdSuffix`），iOS 从 `.app/Info.plist` 读 BundleID；提取失败回退 `.debug.env` 并告警。

## 平台路由

| 目标平台 | 脚本目录 | 能力 |
|---|---|---|
| Android 真机/模拟器 | `<S>/scripts/android/` | ★完整：构建/启动/日志/截图/UI 点击滑动（**Flutter 与原生工程均可用**；原生工程无 `build.sh`，见「执行约定」能力表） |
| Android/iOS 模拟器 语义 UI | `<S>/scripts/maestro/` | ★无障碍语义定位点击/断言（跨端同 YAML，无需坐标）——**限 Flutter 工程**（原生工程走 `ui.sh`/`tap.sh`） |
| iOS 模拟器 | `<S>/scripts/ios/` | 构建/启动/日志/截图（UI 操作走 Maestro，见下） |
| iOS 真机 | `<S>/scripts/ios/`（命令加 `--device`） | 构建（`build.sh --device`）/安装启动（`devicectl`）/日志（`idevicesyslog --syslog-relay`）/截图（`devicectl capture`）；等价设 `IOS_TARGET=device` |
| iOS 真机 语义 UI | `<S>/scripts/appium/` | 语义 UI（xcuitest；需 Apple 签名/TeamID，见下）——**限 Flutter 工程** |
| macOS desktop | `<S>/scripts/macos/` | 构建/启动/日志/截图/智能点击（Vision）+ Appium mac2（实验） |
| Windows desktop | `<S>/scripts/windows/` | 构建/启动/日志/截图（需在 Windows 机执行） |

单元测试与平台无关：`bash <S>/scripts/test.sh [路径]`。
脚本层回归（不需真机）：`bash <S>/scripts/test_common.sh`（.debug.env 解析 + Android 非 Flutter 支持）、`bash <S>/scripts/test_bg.sh`（bg.sh）。

## 长任务后台模式（bg.sh）

`flutter build`（Android 常 >120s / iOS 常 >300s）与 Maestro 冷启动（60~180s）会超过 shell 工具 **120s 前台默认超时**被强杀。凡预估 >60s 的命令一律用 `bg.sh` 包装，**不要直接前台调用**：

```bash
bash <S>/scripts/bg.sh start android/build.sh --debug   # 立即返回 job_id（<1s）
bash <S>/scripts/bg.sh wait <job_id> --timeout 100      # 短轮询，尾附 60 行日志
bash <S>/scripts/bg.sh status <job_id>                   # RUNNING / DONE / FAILED / LOST
bash <S>/scripts/bg.sh logs <job_id> -n 50               # 观察进度
bash <S>/scripts/bg.sh list                              # 最近 10 个 job
```

**退出码契约**：`0`=成功 / `1`=任务失败 / `2`=用法错误(参数非法/job 不存在) / `3`=被强杀(LOST) / `10`=仍在执行。

### ⚠️ 轮询规范（两条，务必遵守）

1. **`wait` 必须短轮询（`--timeout ≤ 100`），循环调用直到拿到 0/1/3。**
   `wait` 自身跑在 shell 的 120s 前台超时下——`--timeout 600` 实际会在 120s 被外层强杀（返回 10 但并非任务结束）。
   job 本身不受影响（已脱离会话），但**单次长 wait 会让调用方拿到误导性的返回**。正确写法：`wait --timeout 100` → 返回 10 → 再 `wait --timeout 100` → ……直到 0/1/3。
2. **日志长时间无新增 ≠ 卡死。**
   `flutter build` 全程可能只有一行 `Running Gradle task 'assembleDevDebug'...` 持续 8 分钟以上（实测 Android debug 构建 473s），期间 CPU 极低、无文件写入——这是 Gradle 依赖解析/下载的正常表现。
   **判定卡死的唯一依据是 `status` 返回 `LOST` 或进程消失**，不是「日志没动」。不要因日志静止而提前终止或降级。

可包装任意脚本（`ios/build.sh`、`maestro/flow.sh <flow.yaml>`、`macos/smart_tap.sh "<kw>"` 等），job 元数据落 `build/debug/jobs/`。

## 修改脚本前必读

**改动 `scripts/bg.sh` 或 `scripts/test_bg.sh` 后，必须先跑完整回归**（215 项，实测约 33s）：

```bash
bash <S>/scripts/test_bg.sh          # 全量
bash <S>/scripts/test_bg.sh -f 静态  # 仅语法+编码（<1s）
bash <S>/scripts/test_bg.sh -f clamp # 只跑某组
```

**若**本 skill 位于 git 仓库内且仓库有 `hooks/pre-commit`（新 clone/换机后需一次性 `git config core.hooksPath hooks` + `chmod +x hooks/pre-commit`），则提交时自动跑**静态组**（快）。⚠️ 当前机器上 `~/.config/opencode` **不是 git 仓库、也没有 `hooks/` 目录** ⇒ 只能手动跑全量（见上）。即便钩子存在，它也**只覆盖静态组**：退出码契约、参数守卫、clamp、detach 等行为回归**必须手动跑**；另外 `git merge`/`rebase`/`cherry-pick`/`am` **不经过**钩子（`git commit --amend` 会经过），这些场景需自行跑全量。

> 新增脚本**无需手工登记**：钩子按 `scripts/*.sh` 后缀匹配、静态组按目录递归收集，均自动覆盖（改脚本即触发静态校验）。

写脚本时的两条硬约束（均有回归守卫）：
- 变量后紧跟中文/全角标点时必须写 `${VAR}` —— macOS bash 3.2 在 UTF-8 locale 下会把全角字符并入变量名（`$VAR（` 被解析成变量 `VAR（…`）
- `usage()` 按内容边界（首个非注释行）截取头部，**禁止硬编码行号**（头部增删注释会泄漏代码行）

> 设计来源与取舍（哪些做法借鉴自 agent-device / MobileBuildMCP / ship-mobile-app，哪些明确不采纳）见
> `references/upstream-references.md` —— 再次调研前先读它，避免重复评估同一来源。

## 模拟器 vs 真机

| 维度 | 模拟器 | 真机 |
|---|---|---|
| 速度 | **快**（启动快，CPU/GPU 模拟开销小） | 慢（设备性能、安装延迟） |
| Agent 操作稳定性 | **稳定**：分辨率固定（如 Pixel 5 / iPhone 15），无物理按键干扰 | 受分辨率、刷新率、权限弹窗影响 |
| UI 元素定位 | **predictable**：Flutter 语义标签在模拟器上识别率高 | 可能因渲染差异或 Native 权限弹窗失败 |
| 日志/截图 | **纯净**：无额外弹窗，`logcat`/`screencapture` 直接 | 可能需权限确认、弹窗遮挡 |

**建议**：日常调试 + agent 自动化优先模拟器；真机仅用于最终回归验证、性能/功能实测。

**启动模拟器**：
- Android：`flutter emulators --launch <avd_name>`（或 `$ANDROID_HOME/emulator/emulator -avd <name>`）
- iOS：`open -a Simulator` + `xcrun simctl boot <device_udid>`

**iOS 真机（2026-10-23 起支持）**：
- 前置：USB 连接 + 已配对 + iPhone 开启「开发者模式」；签名来自 Xcode 工程 `DEVELOPMENT_TEAM`。
- **真机默认构建 profile**（`--profile`）：iOS 14+ 的 debug(JIT) 包只能由 Flutter/Xcode 启动，`devicectl launch` 会停在 Flutter 限制提示页；`--debug` 仍可构建但需用 `flutter run` 启动。
- `build.sh --device` → `build/ios/iphoneos/*.app`（锁 `.last_ios_app_device`）
- `run.sh --device` → `devicectl device install app` + `process launch`（输出 PID）
- `shot.sh --device` → `devicectl device capture screenshot`（失败回退 `idevicescreenshot`）
- `logs.sh --device [--app-only] [行数] [关键词]` → 读 `build/debug/app_device.log`（后台 `idevicesyslog --syslog-relay | grep "Runner[(\[]"` 采集；模拟器日志仍为 `app.log`，两者分文件不交叉）
- 等价开关：`IOS_TARGET=device`；显式 UDID：`IOS_DEVICE_UDID`。**默认仍是模拟器**，`--device` 不会污染模拟器目标。

**固定设备**：团队统一一个型号（如 Pixel 5 / iPhone 15），永久使用该 UDID/avd，避免每次换设备重新定位坐标。

## Android 命令表（<S>/scripts/android/）

| 命令 | 说明 |
|---|---|
| `build.sh [flutter build 参数]` | 构建 APK（透传，如 `--flavor dev --split-per-abi`；**未指定模式则补 `--debug`**；耗时可能 >2 分钟，设长超时） |
| `install.sh` | 安装 APK 到设备 |
| `run.sh` | 冷启动（force-stop → install → am start） |
| `logs.sh [行数] [关键词]` | logcat 按 PID 抓取 + 异常摘要，默认 200 行 |
| `logwatch.sh <签名> [超时秒] [间隔秒]` | **等**指定日志签名出现（动态跟随 PID，App 重启不僵死）。超时秒 ≤100（更长等待用 `bg.sh` 包装本脚本）；退出码：命中 `0` / 超时未命中 `1` / 用法错 `2` / 环境问题 `3`（无设备、非项目根、App 全程未启动） |
| `logclear.sh` | 清空 logcat 缓冲（复现前用） |
| `shot.sh` | 截图到 build/debug/screen.png（用 Read 查看） |
| `pull.sh <设备侧路径> [本地名]` | 把设备上的文件拉到 build/debug/（自带 `mkdir -p` ⇒ **subagent 档没有 `mkdir` 权限时的落点载体**） |
| `ui.sh` | uiautomator 元素清单（**Flutter 未暴露语义树**时为空，属正常；但空清单也可能是解析失败 ⇒ 拿 `共 N 个可点击节点` 与 `count` 交叉核对） |
| `tap.sh x y` 或 `--text 关键词` | 点击；危险按钮必须先 shot 确认页面。关键词为**字面包含（忽略大小写）、非正则**（故 `[`/`.`/`\|` 等按普通字符处理）。`--text` 三失败态**均为 `rc=1`**、靠消息区分：`❌ 无法获取 UI（ui.sh rc=N）`＋ui.sh 输出末 5 行（dump 级失败）／`❌ 页面无可点击节点（ui.sh rc=0 / TSV 0 行）`＋透传 `共 N 个可点击节点`（N>0 ⇒ 有节点但被 text/desc 过滤）／`❌ 未找到…`＋`💡 可用元素` 候选清单。另：label 本身含 `|` 时**显示**会被截断（`cut -d'|' -f1`；坐标仍取末两列、不受影响）—— 现状特征化，组 15.25–15.27 钉死（15.26 直断坐标仍取末两列） |
| `swipe.sh x1 y1 x2 y2 [ms]` | 滑动 |
| `settle.sh [--mode auto\|ui\|screen] [--timeout 25] [--interval 0.4] [--keep]` | **等 UI 静止**。默认 `--mode auto`：语义树可用则比两帧 `uiautomator dump`，**语义树无内容（0 个 text/desc 节点）或 dump 连续失败/持续不完整时自动降级整屏像素**（`screencap -p` 比对）。滑动/点击后**先 settle 再 `shot.sh`/`ui.sh`**，避免把动画中间帧当「页面错乱」。退出码：`0`=已静止（输出必带 `判据=ui\|screen`）/ `1`=超时未静止（⚠️ 文案 + 替代手段，不是异常）/ `2`=用法错 / `3`=**判定不可信**（仅 `--mode ui`：语义树无内容、dump 持续失败或不完整；本 3 ≠ `bg.sh` 的 3=LOST）。失败默认保留两帧在 `build/debug/.settle_*`，`--keep` 时成功也保留；screen 阶段一帧都取不到时终报「整屏截图始终不可用」（不谎报「未静止」） |
| `findtap.sh <关键词> [--max 6] [--dir down\|up] [--wait 0.4]` | **滑动查找并点击**（等价 `scroll --until`）：目标不在当前屏时自动滚动，省掉「滑一次、dump 一次」的手工循环。匹配语义与 `tap.sh --text` 一致（字面包含、忽略大小写、非正则）；命中的文本节点非 `clickable` 时按节点中心坐标兜底并**在输出中注明**。**语义树无内容时首轮立即失败**（不白滑 `--max` 屏）并给 Maestro → Vision → 坐标三级降级路径。退出码：`0`=命中并点击 / `1`=`--max` 次后仍未命中**或语义树无内容** / `2`=用法错 |

## Maestro 命令（<S>/scripts/maestro/ — Android / iOS 模拟器）

**无障碍语义定位，无需坐标**；同一 YAML 跨 Android/iOS。前置：`brew tap mobile-dev-inc/tap && brew install --formula mobile-dev-inc/tap/maestro`。

| 命令 | 说明 |
|---|---|
| `tap.sh "<文本>"` | 点击可见文本（首选；自动注入 appId） |
| `tap.sh "<id>" --id` | 按 Semantics identifier / 资源 ID 点击 |
| `tap.sh "<文本>" --index 2` | 多个匹配时取第 N 个（1-based） |
| `assert.sh "<文本>"` | 断言可见（退出码 0=通过，非 0=失败/错误） |
| `assert.sh "<文本>" --not-visible` | 断言不可见 |
| `flow.sh <flow.yaml>` | 执行任意 Maestro 流程（整流程一次调用，避免逐击开销） |

通用可选参数：`--platform android|ios`（缺省自动判定）、`--device <id>`、`--app-id <id>`。

**前提与边界**：
- Maestro 依赖 Flutter **Semantics Tree**：含文本控件（`Text`/`TextField`）隐式可定位；**无文本控件（Icon/图片按钮/纯 Container）须 App 侧包 `Semantics(label:/identifier:)`**（`identifier` 需 Flutter ≥ 3.19）
- 仅支持 **iOS 模拟器**（不支持 iOS 真机）；**不支持 Flutter Desktop**
- 不自动 `launchApp`（保持调用前页面状态）；冷启动请先跑平台 `run.sh`
- **真机/冷启动慢**：Maestro 为 JVM 进程，真机首次运行含驱动握手，单次成功也可能 60~180s。**首选用 `bg.sh` 后台模式包装执行**（见下节），可彻底绕开 120s 前台超时；确需前台直调时才把工具超时设 **≥180s**。若日志停在 `Selected device … port …` 之后无输出，多为被外层超时杀掉，而非流程失败

## Vision 命令（<S>/scripts/vision/）

| 命令 | 说明 |
|---|---|
| `python vision_read.py --image <path> --task <task> [--question "..."] [--region x1,y1,x2,y2] [--compare-image <path>] [--no-cache]` | 视觉分析：ui_analysis/ocr/find_element/compare/error_analysis，返回结构化 JSON（含 bbox/confidence） |

### Android UI 复现循环
```
run.sh → settle.sh → (maestro/tap.sh "目标按钮" | findtap.sh "目标")
→ settle.sh → maestro/assert.sh "成功页面" / shot.sh 确认
→ logclear.sh → 触发目标操作 → logs.sh 分析
→ 修复后：build.sh → run.sh → 重走同一序列 → logs.sh 验证
```
可复制 YAML 片段与 shell 等价序列见 `references/maestro-flow-snippets.md`（注意 `launchApp` 只用于冷启动冒烟，**复现既有页面状态时不要用**）。
**等日志出现时用 `logwatch.sh <签名> <超时>`，不要自己拼 `adb logcat --pid=$PID` 轮询**（写死 PID 在 App 重启后会僵死成孤儿进程）。判据签名必须先在源码 `grep` 确认真实存在，勿用方法名猜测。
**UI 操作优先级**（效率从高到低）：
1. **Maestro**（`maestro/tap.sh` / `assert.sh`）— 语义定位，无需坐标、无需截图，首选
2. `ui.sh` 命中 → `tap.sh --text 关键词` / `tap.sh x y`；**目标不在当前屏**时用 `findtap.sh 关键词`（自动滚动查找+点击，省掉手工「滑一次 dump 一次」）
3. **Vision 智能命令**（语义树缺失/视觉状态判断时，见下节）
4. 坐标点击前必须 `shot.sh` + `Read` 确认当前页（滑动/点击后先 `settle.sh`，避免抓到动画中间帧）

**回退**：Maestro 报错 → 先 `shot.sh` + `Read` 看真实页面，再降级到 ui.sh / Vision，不得盲点。但**必须先区分「流程失败」与「被超时中断」**：
- 看 `build/debug/maestro_output.log` 停在哪一步。停在 `Tap on …` / `Assert …` 等步骤（如 `Element not found`）→ **真·流程失败**，按上面正常回退。
- 停在启动信息 或 `Selected device … using port …` 之后无输出 → 是 Maestro 冷启动/驱动握手**被外层超时杀掉，不是流程失败**。应先 `adb -s <设备> forward --remove-all` 清理残留端口转发、改用 `bg.sh` 后台模式重试（或把超时提到 ≥180s），**不要据此降级**。

### Vision 调用路由（补充规则）
- `ui.sh` 命中元素 → 直接 `tap.sh`，不调 Vision
- 以下场景必须走 Vision：
  - `ui.sh` 为空/语义树未暴露（Flutter 页面常见；**非 Flutter 页面也空 ⇒ 先怀疑解析失败**，用 `shot.sh` 交叉看真实页面）
  - 判断：白屏 / 遮挡 / 错位 / 图片缺失 / loading / empty 状态 / error 文案定位
  - 需要 OCR 读取非控件文本（toast、dialog、snackbar、红色报错）
  - 视觉回归对比（`compare` task）
- Vision 失败（exit 3） → 回退 `ui.sh + logs.sh` 组合判断，不得臆断视觉信息
- **Vision API Key 配置**：`VISION_API_KEY` 可通过 CLI `--api-key`、环境变量、或 `.debug.env` 的 `VISION_API_KEY` 键三级读取。若在 `.debug.env` 中填入真实 Key，务必把该文件加入 `.gitignore`，避免密钥入库。

## macOS 智能命令（<S>/scripts/macos/ + vision/smart_lib.sh）

一体化「截图 → Vision 定位 → Retina 换算 → 点击」，含安全护栏（置信度 <0.7、危险词、页面 loading/白屏/遮挡时拒绝点击）。命令：`smart_tap.sh`（`--dry-run` / `--stable` / `--allow-danger`）、`smart_assert.sh`（`--not-visible`）、`click.sh <x> <y>` 与 `click.sh --activate <AppName>`。
退出码：0=成功，1=未定位/页面不稳定，2=危险词拒绝，3=Vision/截图失败。**前置权限**：终端需「屏幕录制」（截图）+「辅助功能」（点击）。
**首次使用、报 Vision 失败或坐标偏移时必读** `references/macos-smart.md`（完整命令表、护栏阈值 `SMART_MIN_CONF`、排障）。

## Appium 命令（<S>/scripts/appium/ — iOS 真机 / macOS 实验）

无障碍语义定位（同 Maestro 思路），Appium 3 + W3C WebDriver。命令：`doctor.sh`、`source.sh`（导出 page source 排查元素可否寻址）、`tap.sh`、`assert.sh`（0=成立，1=失败，3=驱动/会话错误）、`flow.sh`（真机多步**必须**走单会话 flow）、`wda_prepare.sh` / `wda_sign.sh`（离线准备真机 WDA）。
⚠️ **不可逆副作用**：路线 A 自动签名会在设备未注册时**自动注册设备**（占用团队年度设备额度）并创建/更新描述文件。iOS 真机需 `IOS_TEAM_ID`；设备上必须是 **profile/release** 包（Flutter debug 包 JIT 受限，page source 无业务元素）。
**首次接 iOS 真机必读** `references/appium-ios-device.md`（前置、路线 A/B、xctestrun 约束、mac2 与 Flutter 桌面已知限制）。

## iOS 模拟器（<S>/scripts/ios/）

前置：Xcode 已装、至少一个模拟器可用（无已启动的会尝试 boot 第一个可用项）。

| 命令 | 说明 |
|---|---|
| `build.sh [--device] [--simulator] [flutter build 参数]` | 默认模拟器（`--debug --simulator`）；`--device` ⇒ 真机（**默认 `--profile`**，debug 受 iOS 14+ JIT 限制）；模拟器透传参数自动补 `--debug`/`--simulator` |
| `run.sh [--device]` | 模拟器 simctl install+launch；真机 devicectl install+launch（输出 PID） |
| `logs.sh [--device] [--app-only] [行数] [关键词]` | tail 日志 + 异常摘要：模拟器读 `app.log`；真机读 `app_device.log`。`--app-only` 只留 App 进程行（滤掉 Sandbox/kernel 噪声，实测 1978→575 行） |
| `shot.sh [--device]` | 模拟器 simctl io screenshot；真机 devicectl capture（回退 idevicescreenshot） |
| `logclear.sh [--device]` | 清空日志；`--device` 会**先停常驻 idevicesyslog 采集进程**（按 `syslog.pid` 第 2 行的 UDID 定向，多设备不误杀）再清 `app_device.log`；停不掉时报错不假装成功（真机调试结束后必跑，否则文件持续增长） |
| （UI 操作）`<S>/scripts/maestro/tap.sh` | 语义点击（模拟器），见「Maestro 命令」节 |

**能力边界**：**iOS 真机** UI 操作走 Appium（`appium/tap.sh --platform ios-device`，需 `IOS_TEAM_ID` 与 XCUITest，属实验路径）；**iOS 模拟器**用 Maestro（`maestro/tap.sh` / `assert.sh`，语义定位无需坐标），复杂多步场景优先 `maestro/flow.sh`。需代码级 UI 测试时才写 integration_test：
```bash
flutter test integration_test/<file>.dart -d <simulator_udid>
```

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

## 测试分层策略

| 层级 | 命令 | 耗时 | 依赖 |
|---|---|---|---|
| 单元测试 | `flutter test test/<file>` | < 10s | 无 |
| Widget 测试 | `flutter test widget_test.dart` | 10s-1min | 无 |
| Integration 测试 | `flutter test integration_test/<file>.dart -d <device>` | 1-3min | 模拟器/真机 |

**优先级**：能 unit 不 widget，能 widget 不 integration。

**integration_test 注意**：
- timeout ≥ 180s（避免 agent 超时）
- 拆成多个独立 test 文件（如 `config_flow_test.dart`、`transfer_flow_test.dart`），避免单 test 超时
- 模拟器优先（更快、更稳）

## 角色协作

- **build** (主代理)：改代码、编排验证
- **debug** (子代理)：静态根因定位，不动设备、不动代码
- **autoDebug** (子代理)：本 skill 的真机执行层——构建/启动/UI操作/抓日志/截图/回归验证，**edit: deny**

build 通过 `task(subagent_type="autoDebug", prompt="...")` 把真机操作派给 autoDebug；autoDebug 返回证据（日志摘录/截图路径/结论），build 据此改码后再派回归验证任务。

## 核心规则

1. 修 Bug 必须先拿真实日志定位根因，禁止猜测
2. 禁止未运行验证就声称修复；修复后重走同一操作序列并附日志证据
3. 不通过吞异常/大范围 try-catch 屏蔽问题；最小修改不动无关代码
4. 同一设备同时仅运行一个 Debug Loop
5. 日志关注点：`[模块][类名]` 前缀日志 + exception/error/fatal
6. 危险操作（解绑/删除/付款类）点击前：Maestro 路径必须先 `shot.sh` 确认页面；macOS 路径 `smart_tap.sh` 默认已拒绝危险词（误判才加 `--allow-danger`）
7. `integration_test` 命令同样优先走 `bg.sh` 后台模式；确需前台直调时 timeout ≥ 180s
8. UI 操作优先级：Maestro（Android/iOS 模拟器）> ui.sh/tap.sh/findtap.sh > Vision 智能命令；任何路径失败都要 `shot.sh` 看真实页面，禁止盲点坐标
9. **每条结论都要绑证据**（见下节）；没有证据一律写「未验证」，不得写「已修复」

## 证据与主张（回报口径）

**证据分层**（由弱到强，只能声明到证据支撑的那一层）：

| 层 | 证据 | 能支撑的主张 |
|---|---|---|
| 源码推断 | 读代码/调用链 | 「按代码应当…」（不是「实际如此」） |
| 静态检查/单测 | `flutter analyze`、`flutter test` | 「逻辑层无回归」 |
| 构建产物 | `build/debug/.last_*` 锁文件、APK/.app 存在 | 「产物已产出」 |
| 运行日志 | `logs.sh` / `logwatch.sh` 命中签名 | 「该路径本次被执行」 |
| 界面观测 | `shot.sh` / `ui.sh` / Maestro 断言通过 | 「界面呈现符合预期」 |

**主张映射（强制）**：每条结论后跟证据坐标 `证据: build/debug/<文件>:<关键词/行号>`。
`gradlew clean` / `flutter clean` 会清掉证据 ⇒ 被清掉的主张**自动降级为「未验证」**，不要照抄上一轮结论。

**先分类再改码**：同一现象重试两次仍无新证据时，先判失败边界再决定动哪一层（避免「改 UI 修签名问题」）：

| 边界 | 典型证据 | 处置 |
|---|---|---|
| 应用逻辑 | 业务异常栈、`[模块][类]` 日志 | 交回 build 改码 |
| 构建链 | gradle / xcodebuild 报错 | 核工具链版本、clean 重建（**先外带证据**） |
| 签名/证书 | iOS `No Accounts`、entitlements 缺失 | 用户侧签名配置；**不要**自动注册设备/自动签名（占用团队年度设备额度，见 `references/appium-ios-device.md`） |
| 工程配置 | `.debug.env` 值被拒、manifest/Info.plist 权限缺失 | 修配置，不动业务代码 |
| 设备/账号状态 | 无设备、权限弹窗、账号切换残留 | 重置设备状态后**重走同一序列** |
| 传输/网络 | 超时、DNS、证书错误 | 以日志为准，不要归因到 UI |

平台常见故障（maestro 冷启动被超时杀掉、appium 首启空树、iOS debug 包 JIT 限制、多设备抢占等）见
`references/troubleshooting.md` —— **先查表再试**，不要凭直觉重试同一命令。

## opencode agent 配置

autoDebug 子代理的**命令细节一律以本文件为准**；其**身份与不可让渡边界**见 `~/.config/opencode/opencode.jsonc` 的 `agents.autoDebug.system`（全局一次性配置；权限 pattern 使用仓库绝对路径，换机器需同步）。`references/opencode-agent.jsonc` 仅作指针，不复制正文。
