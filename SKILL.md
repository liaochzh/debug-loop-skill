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

1. 在**项目根**确认存在 `.debug.env`（Flutter 与原生 Android 工程均可）；不存在则运行 `bash <S>/init.sh`。它由**主 agent / 人工**准备：subagent 无写权限、**不能自举** ⇒ 缺失时登记阻塞并返回，不要重试。
2. `.debug.env` 是 **KEY=VALUE 常量文件**（包名/BundleID/AppName + 可选 flavor/scheme/显式产物路径），由 `scripts/_env.sh` **安全解析**（不 `source`、不 `eval`、不展开变量；允许 `export ` 前缀、行尾 ` #` 注释、CRLF；值里含 `;`、反引号、`$(` 会被**拒绝**，防注入）。推断错误可手工修正后重试。
3. **一次自检代替逐项探测**：`bash <S>/scripts/doctor.sh [--platform android|ios|ios-device|macos|windows|all]`
   （`ios` = 模拟器 + 真机都报告；`ios-device` = 只认真机，与 `snapshot.sh --platform ios-device` 同一取值）
   一条命令报告「配置 / 工具链 / 设备 / 产物 / 可选密钥」五类事实（✅ 可用 / ⚠️ 可选缺失 / ❌ 阻塞），
   rc=0 才继续；rc=1 说明有阻塞项，按提示修复，**不要**再用 `adb devices`、`which xxx` 逐条试探。
   > 判据纪律（借 agent-device / MobileBuildMCP 的 doctor 模式）：**「命令被拒」≠「环境不可用」**。
   > 先看 doctor 的 ❌ 分级，再决定是补配置还是改路径；不要凭单条命令失败就宣布环境不可用。
4. **先读项目台账**（存在则必读）：`docs/test/debug-loop/pitfalls.md` 是**按项目累积**的逐坑表
   （症状 / 判据 / 处置 / 证据），命中同类症状直接照「处置」做，不要再自行摸索一遍。
   收尾时用 `bash <S>/scripts/pitfall_append.sh --symptom … --judge … --action …` 把新坑写回（自带落点，子代理可调用）。

## 执行约定

- 所有脚本必须从**项目根**执行（按 `$PWD` 查找 `.debug.env`，产物写入项目 `build/debug/`）
- **多设备（模拟器 + 真机同时在线）**：脚本默认取 `adb devices` 首台；要指定就带环境变量
  `ANDROID_SERIAL=<设备id>`（`android/*`、`snapshot.sh`、`tap_verify.sh`、`maestro/flow.sh` 同口径；无需拔线/关模拟器）。
  指定的设备不在线 ⇒ **直接失败**，不会静默换机。
  > 只认 **shell 环境变量**：写进 `.debug.env` 无效（那是项目常量档，未知键会被忽略并告警）。
- 调用形式：`bash <S>/scripts/safe_run.sh [--profile P] -- bash <S>/scripts/<platform>/<script>.sh [args]`
  （沙箱入口为唯一形态；`<S>` 软链与 realpath 两形态都在白名单，见「权限纪律」）
  > 下文各平台命令表里的 `bash <S>/scripts/…` 示例均为**裸形态**；实际执行时**一律**前置入口：`bash <S>/scripts/safe_run.sh [--profile P] -- <该命令>`（profile 放行清单见 `references/permission-discipline.md`）。
- **启动经济**：一次定位设备、一次 dump、一次读日志。禁止用 `--help`、`adb devices`、`ui.sh` 反复探路「确认状态」——脚本自身会给出事实与失败原因；重复探测既慢，又容易把「页面确实是空的」误判成「权限或环境坏了」。需要新事实时先问「上一条证据缺什么」。
- **脚本的 `💡` 提示优先于自行重规划**：失败输出里的处置建议（降级路径、候选清单、`ui.sh rc=N`）就是下一手依据，先按提示做一次再换思路。
- 解析优先级（由强到弱，**不得跳级**）：**语义/文本定位**（Maestro → `tap_snapshot.sh` → `ui.sh`/`findtap.sh`）＞ **Vision 视觉定位** ＞ **坐标**。
  坐标是兜底，用前必须 `shot.sh` 看过当前页；用了坐标就要在回报里写明「坐标兜底 + 已截图确认」。

### 输入与点击纪律（强制）

> 这两条是**真实故障复盘**得来的（2026-11-12）：账号密码「输错一两个字 / 反复粘贴 / 点了没反应」都不是模型手笨，
> 而是缺工具与缺回执 —— 前者迫使 agent 临场拼 `adb shell input text`（不清空、漏特殊字符、掉字），
> 后者让「点没点中」无人判定，最后把「点不中」误报成功能 Bug。

**输入**（登录/搜索/表单一律走脚本，不要拼 `adb shell input text`）：
- `bash <S>/scripts/android/input.sh --field <关键词> (--text <值>|--text-from <凭据文件>) [--mask]`
  一次调用完成「定位 → **焦点自检** → **清空** → 分段输入 → 读回校验 → 不符重试 1 次」，rc 见命令表。
- **必须先清空再输入**：`input text` 是追加语义，旧内容留着就会变成 `alicealice`（本项目踩过）。
- **必须读回校验**：密码框语义值常为空或圆点 ⇒ `--mask`（只比长度），并在回报里写「内容未验证」。
- **删除/输入前必须确认焦点已进目标框**（`input.sh` 内建 `dumpsys input_method` 自检）。焦点没进去就发
  `KEYCODE_DEL`/文本，会作用在**上一个聚焦元素**上（删掉别人的内容），这类事故比「输错值」更难发现。
- **敏感值走 `--text-from`**（`init.sh` 生成的 `.debug-login.secret`，权限 600、已在 `.gitignore`），
  不要写进任务书/命令行；`--text` 只用于非敏感串。校验用快照含明文，脚本只在临时文件里用它、退出即删；
  `build/debug/interact/*.json` 只记字段/长度，不含值。
- **中文/emoji 不可用 `input text`**（rc=8）⇒ 改走 Maestro `eraseText` + `inputText`（见 `references/maestro-flow-snippets.md`）。
- iOS 真机同理：`driver.py find-type --clear`（默认开）+ 读回校验；`flow` 的 `type` 步骤 `"clear"` 缺省 `true`；
  文本为空一律 rc=2（模板里 `ACCOUNT=` 是空值，别把「什么也没输」当成功）。

**点击**（每次点击都要有回执）：
- 首选 `bash <S>/scripts/tap_verify.sh <关键词> --expect has:<目标页文本>`：一次调用完成
  「settle → 快照 → 语义定位 → 点击 → 断言轮询 → 必要时重试一次」。
- **页面切换后的第一次点击必须用 fresh 快照**（`tap_verify.sh` 内建；`tap_snapshot.sh` 默认复用 ≤60 s 缓存坐标，
  页面已换仍按旧坐标点 ⇒ 典型的「点不中」）。
- `rc=0` 只代表**事件已送达**（`tap.sh`/`tap_snapshot.sh`/`findtap.sh` 都是这个语义）；判「有没有点中」必须靠
  `assert_page.sh --wait` 或 `tap_verify.sh`，**不得**把 rc=0 写成「点击成功」。
- `tap_verify.sh` 重试前置判据：点击后页面**已变化**（目标节点消失 / 节点数变化）即不再点第二次；
  其中**仅文本集变化是弱证据**（自动刷新页会自行漂移），默认按未通过算（`--allow-weak` 才放行）。
  点后快照失败 ⇒ 判「无法判定」，同样**不重点**（fail-closed）；断言路径也不例外。危险词
  （删除/解绑/支付/提交/确认…）默认禁二击，确认可再点时显式
  `--allow-danger`；危险词表只是启发式，**不能当唯一防线**（危险操作前仍要按 L0/L2 确认页面）。

### 页面观测阶梯（强制）

判定页面状态按 L0 → L1 → L2 逐级取证据，**不得跳级，也不得用截图代替可断言的证据**：

| 层 | 手段 | 成本 | 能支撑的主张 |
|---|---|---|---|
| L0 断言 | `assert_page.sh`（Android / iOS / macOS）；点击后用 `--wait N` 轮询 | 1 行输出 | 「界面呈现符合预期」 |
| L1 摘要 | `snapshot.sh`（≤40 行 + 指纹） | ~600 token | 「当前页面有哪些元素」 |
| L1 变化 | `snapshot.sh --diff`（≤20 行变化清单） | ~150 token | 「刚才那一下，页面变了什么」 |
| L2 截图 | `shot.sh` + `Read` | 视觉信息 | 仅「视觉呈现」 |

- 先用 L0：把期望写成断言（`has` / `has-not` / `count` / `match`），拿 rc 与一行结论。
- 断言失败或需看全貌时用 L1：摘要带 `fingerprint`，可判断「页面是否切换」。
- **仅以下 5 类允许 L2**：① `snapshot.sh` exit 4（语义树为空）；② 视觉类问题（遮挡/错位/颜色）与瞬态提示（toast/snackbar/红色报错）；③ 需给人看的取证；④ 坐标兜底前确认；⑤ 危险操作（解绑/删除/付款）点击前确认。
  > ④ 的例外：**与点击同源于同一时刻语义快照**的坐标（`tap_snapshot.sh`、`snapshot.sh --center` + `tap.sh x y`）**不属于坐标兜底**，免 `shot.sh` 前置；危险操作（⑤）仍需确认。
- 截图默认**只报路径、不 `Read`**；确需 Read 须在回报写明理由。
- ⚠️ `snapshot.sh` exit 4 ≠ 页面空白：表示页面无文本/可点击节点（需 App 侧 `Semantics`），不要判成 Bug。
- ⚠️ 指纹只用于「页面稳定时」判切换：自动刷新页（实时预览/时间戳/缩略图）fp 会自行漂移（实测同页 3 秒内 3 个不同 fp）⇒ 这类页面判「点击/跳转是否生效」必须用 `assert_page.sh` 的目标文本，不能只看 fp。
- **判「变了什么」用 `snapshot.sh --diff`**（不要只看 fp）：输出 `+`/`-`/`~text`/`~pos`/`~clickable` 与 header 计数；`~ text` 只代表文本刷新（时间戳），`+` 多 `-` 少通常是跳转后节点更多。它**不省 dump**（仍是一次新快照），省的是 token 与判据。点击后先 `settle.sh` 再 `--diff`，否则满屏 `~pos` 是动画中间帧。
- **点击后判「是否到了目标页」用 `assert_page.sh --wait 10`**（取代「`settle.sh` + 一次断言 + 自行重试」）：轮询到断言通过或超时，Android 单 dump 一轮约 2.5–3 s（`--single-dump` 由 `--wait` 自动带）。**断言失败（rc=1）会自动附「与上一份快照的差异」到 stderr**（基线 = 断言自身轮转出的 `prev`，零额外 dump；`--no-diff` 关）。iOS 模拟器每次 poll 15 s ⇒ 只跑 1 次，优先 `maestro/assert_batch.sh`。
- 通道选择：Android 用 `snapshot + assert_page`（秒级）；iOS 模拟器 ≥3 条 `has/has-not` 用 `maestro/assert_batch.sh`（单次 flow），含 `count/match` 或需摘要用 `snapshot + assert_page`。
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

### 权限纪律（执行前必读，作为 subagent 时**强制**）

- **唯一执行入口**：所有命令经 `bash <S>/scripts/safe_run.sh [--profile ui|build|ios|macos] [--project-root <proj>] -- <命令>`；白名单外裸跑 `bash <S>/scripts/*.sh` 秒拒（结构护栏，不是缺权限）。
- **写面**：项目 `build/`、`docs/test/`、`$TMPDIR`、`/private/tmp`；`--profile build` 才放开整个项目根。`~/.ssh`、`~/.aws`、`~/.gnupg`、`~/.netrc`、Keychains 全拒；`.env*` 读不到，仅 `.debug.env` 可读。
- **`<S>` 必须绝对路径**：`~` / `$HOME` / 相对路径不匹配白名单 ⇒ 秒拒。
- **`117` = 沙箱不可用（fail-closed）**：停下并回报，不得裸跑绕过；其余退出码是脚本自己的（`snapshot.sh` 的 `4` = 语义树为空，属正常观测）。
- **必须交回主 agent**：`flutter build ios`（嵌套沙箱被系统拒，换 profile 也无效）与 `devicectl install`（沙箱内能力缺失）。回报写「需主 agent 在宿主机执行」。
- **沙箱内 iOS 模拟器语义能力不可用**：`snapshot.sh` / `assert_page.sh --platform ios` 与 `maestro/*` 的 iOS 路径 rc=3 快失败 ⇒ 降级 `shot.sh` + `logs.sh`，不重试。
- **禁止**：`>` / `>>` 重定向；`&&` / `;` 串联裸命令（都会绕过沙箱入口）。
- 完整判据（`Operation not permitted` 读法、profile 放行清单、Flutter SDK 缓存软链、内联脚本形态）→ `references/permission-discipline.md`。

## 页面快照与断言（`<S>/scripts/` — 跨平台）

| 命令 | 耗时（实测中位） | 说明 |
|---|---|---|
| `snapshot.sh [--platform android\|ios\|ios-device\|macos] [--max 40] [--json] [--center] [--wait-stable] [--single-dump] [--no-cache]`<br>`snapshot.sh --diff [--against <json>] [--max-diff 20]`<br>`snapshot.sh --cache-payload <json> [--platform P]` | Android **5.7 s**（双 dump）；iOS 模拟器 **15.3 s**（`maestro hierarchy`）；iOS 真机 **待实测**；`--diff` 不额外加时（复用本次 dump） | 页面结构化摘要：`i\|type\|text\|id\|bounds\|clickable` + 指纹（`--center` 追加第 7 列 `cx,cy`，无中心为 `-`）。Android 走 `uiautomator dump`（默认双 dump，覆盖语义树懒激活；设备侧 `/sdcard/ui_snapshot.xml`）；**iOS 模拟器走 `maestro hierarchy --compact`**（实测 Appium pageSource 对 Flutter 恒为空树）；iOS 真机/macOS 走 Appium page source。`--json` 为断言/点击专用全量（不截断，每条含 `center`），默认摘要 text 截断 40 字符、最多 `--max` 行。**`--diff`**：输出变化清单（TAB 分隔，取代摘要）——header `# diff baseline=… fp=旧→新 nodes=M: +a -b ~c (text/pos/clickable)` + `+`/`-`/`~text`/`~pos`/`~clickable` 行（≤`--max-diff`，截断补「另有 N 项」；计数恒为截断前全量）。基线优先级 `--against` > `last_snapshot.json` > `prev_snapshot.json`；**隐式基线强制校验 `dialect`+`_meta.platform`**（不符 ⇒ 跳过且不降级读 `prev`，rc=1），显式 `--against` 跨平台只 ⚠️ 仍输出；`--diff`+`--json` 互斥（rc=2）；`--diff` 无基线时 rc=1 但**本次观测仍落缓存**（再跑一次即可看变化）。**缓存**：任一**观测成功**快照（含摘要/`--diff` 模式）落盘 `build/debug/last_snapshot.json`（含 `_meta.platform/ts`）供 `tap_snapshot.sh` 复用与 `--diff` 当基线，写前把旧 `last` 轮转为 `prev_snapshot.json`（**只作 diff 基线，不作坐标来源**）；`--no-cache` 关闭写入。**`--single-dump`**（仅 Android：只 dump 一次，省约一半时间，`assert_page --wait` 轮询自动带上；与 `--wait-stable` 互斥 rc=2；单次观测别默认开——语义树懒激活时可能空树）。**`--cache-payload <json>`**（不 dump，只把已有 `--json` 产物落盘，供 `assert_page --wait` 通过后写缓存；只允许与 `--platform` 同用，其余参数 rc=2；平台无法判定 rc=3，不猜）。退出码：`0` 成功（`--diff` 时无论有无变化）/ `1` 可重试或无可用基线 / `2` 用法错 / `3` 平台不支持（**沙箱内 iOS 模拟器即此情形**，见「权限纪律」）/ `4` 语义树为空 |
| `assert_page.sh --file <断言文件> [--platform P] [--with-logs N] [--no-diff] [--wait N] [--interval S] [--single-dump]` | Android 一次性 **5.7–6.1 s**；`--wait` 每轮单 dump **实测 3.8–4.7 s**（中位 3.84 s vs 双 dump 6.08 s）；iOS 模拟器一次 poll **15–40 s**（实测 39.6 s） | 声明式断言：`has` / `has-not` / `match` / `not-match` / `count <正则> <N>`。输出一行 `✅ 3/3 PASS` 或 `❌ 1/3 FAIL` + ≤5 条差异。**失败自动附 diff**（默认开，`--no-diff` 关）：仅 rc=1 时用**产生该断言结果那轮**的 payload 与基线比对（一次性路径取 `prev`——本次快照刚把旧 `last` 轮转过去；`--wait` 路径优先 `last`，轮询期不写缓存故它就是「轮询开始前那一页」，缺失才退 `prev`），变化清单写 **stderr**（stdout 契约不变），基线缺失/不可解析/方言平台不符则静默跳过。**`--wait N`**（默认 0 = 一次性）：轮询到断言通过或超时——轮询期一律 `--no-cache` + 自动 `--single-dump`（Android），通过后经 `snapshot.sh --cache-payload` 落盘；空树（rc=4）重置连败计数继续等，快照连续 2 次失败放弃（rc=5），rc=3/2 立即透传；断言引擎自身报错（rc=2 用法错 / 5 数据不可解析）也立即透传、不重试；超时报**最后一次成功断言**结果 + `已轮询 N 次 / X.Xs`。⚠️ `--wait 0` 失败仍写 `last` 并轮转 `prev`，`--wait N` 失败/超时**不写**（两条路径下 `prev` 含义不同）。退出码：`0` 全过 / `1` 有失败或 `--wait` 超时 / `2` 用法错 / `3` 平台不可用 / `4` 语义树为空 / `5` 快照失败 |
| `maestro/assert_batch.sh <断言文件>` | iOS 模拟器 **15.6 s**（3 条，单次 flow）；Android 未单独计时 | 多条 `has`/`has-not` 合并为**单个** YAML 单次 `flow.sh`（避免 N 次 JVM 冷启动）；`count`/`match` 无 Maestro 对应物，会明确拒绝。⚠️ 语义为**精确文本、大小写敏感**（同 `assertVisible`）；子串/忽略大小写/数量请用 `assert_page.sh` |
| `tap_verify.sh <关键词> [--expect has:<文本>…] [--expect none] [--wait 10] [--retry 1] [--index N] [--id] [--allow-danger] [--allow-weak] [--platform android\|ios-device] [--dry-run] [--json]` | 待实测（≈ settle + 1 次快照 + `assert_page --wait` 若干轮；替代手工 3–4 轮） | **点击 + 回执**：`settle → fresh 快照 → 语义定位 → 点击 → assert 轮询`；未过时先判「页面是否已变化」，已变化**不再点第二次**（防登录/提交/删除被重复触发），危险词（删除/解绑/支付/提交/确认…）默认禁二击、`--allow-danger` 放开（**启发式，非唯一防线**）。`--expect none` 主判「目标节点消失 / 节点数变化」；**仅文本集变化属弱证据**（自动刷新页倒计时/轮播会自行漂移）⇒ 打 `❌ 弱判据` 并按未通过算，`--allow-weak` 才放行。点后快照失败/不可解析（含断言路径）⇒ 判「无法判定」，**fail-closed 不重点**。android 走 `adb input tap`；ios-device 转 `appium/tap.sh` + `appium/assert.sh`（语义点击，rc 分流：1=未找到/7=驱动失败）；`ios`/`macos`/`windows` ⇒ rc=3 指引 Maestro / smart_tap。现场落 `build/debug/interact/<ts>-tap.json`（不含明文值）。退出码：`0` 通过 / `1` 未达预期或无法判定（附 diff 与降级建议）/ `2` 用法错 / `3` 平台或环境不支持 / `4` 语义树为空 / `5` 快照失败 / `7` 派发失败 |
| `tap_snapshot.sh "<文本>" [--id] [--index N] [--exact] [--dry-run] [--fresh] [--max-age 60] [--keep-cache] [--json] [--platform android\|macos] [--input <snapshot.json>]` | 命中缓存 **<1 s**；无缓存 ≈ 一次 `snapshot.sh` + 点击（Android 合计 ~6 s） | 用快照 `bounds` 的中心点做**坐标点击**（一次快照 → 点击）。匹配语义 = `assert_page` 的 `has`（text∪id、字面包含、忽略大小写；`--exact` 精确且大小写敏感），**是 `tap.sh --text` 的超集**（能点 `clickable=false` 的文本节点，此时打 ⚠️）。**缓存**：复用 `snapshot.sh` 落盘的 `last_snapshot.json`（TTL 默认 60 s、按 `_meta.platform` 校验；点击成功后 `last` 轮转为 `prev_snapshot.json`（只作 `snapshot.sh --diff` 的基线，**绝不**作坐标来源），`--keep-cache` 保留，`--dry-run` 不轮转，`--max-age 0` ≡ `--fresh`）。平台：`android`（`adb input tap`）/ `macos`（`click.sh`，**实验**：`AXFrame` 形态未真机实测）；`ios` ⇒ rc=3 指引 `maestro/tap.sh`，`ios-device` ⇒ rc=3 指引 `appium/driver.py find-click`，`windows` ⇒ rc=3。疑似离屏（负坐标/越界）也打 ⚠️。退出码：`0` 点击完成 / `1` 未命中或 `--index` 越界 / `2` 用法错 / `3` 平台不支持 / `4` 语义树为空 / `5` 快照失败 / `6` 无可用坐标 / `7` 点击派发失败。⚠️ **rc=0 仅表示指令已送达**（`adb input tap` 无回执），是否响应必须另用 `assert_page.sh` 判 |

> 耗时口径：`see_pro` + Android 真机 R38N405KJYB + iOS 模拟器 iPhone 17e，每项 3 次取中位，已热机（不含首次 JVM/驱动冷启动）。明细见 `docs/test/20261029-assert-timing.md`。
> ⚠️ iOS 模拟器路径**明显慢于 Android**（Maestro 为 JVM 进程，单次固定开销十几秒）：≥3 条断言优先 `maestro/assert_batch.sh`（一次 flow 摊薄），只 1–2 条且需子串/数量断言时用 `assert_page.sh`。

> 断言文件示例（`docs/test/` 下随任务生成）：
> ```
> has 我的设备
> has-not 加载中
> count 在线 3
> ```

## 产物解析（多 flavor/ABI/mode 通用）

- `build.sh` 参数透传给 `flutter build`（如 `build.sh --flavor dev --split-per-abi`）；**未显式指定 `--release`/`--profile` 时一律补 `--debug`**（`flutter build apk` 的内置缺省是 release，不补会静默变 release 构建）；无参时用默认 `--debug`，若 `.debug.env` 配了 `ANDROID_FLAVOR`/`IOS_SCHEME` 则自动加 `--flavor`。
- 构建成功后解析实际产物（兼容 `app-<flavor>-<mode>.apk` / `app-<abi>-<flavor>-<mode>.apk` / `<Scheme>.app`），写入 `build/debug/.last_<platform>_*` 锁文件。
- `install.sh`/`run.sh` 按「显式覆盖（`ANDROID_APK_PATH`/`IOS_APP_PATH`/`MACOS_APP_BUNDLE`/`WINDOWS_EXE_PATH`）> 锁文件 > 输出目录最新发现」三级解析；多候选时按设备 ABI 优先（Android）+ mtime 取最新并警告；`flutter clean` 后锁失效自动回退目录发现。
- 运行时 ID 以产物为准：Android 从 APK 提取 package（覆盖 `applicationIdSuffix`），iOS 从 `.app/Info.plist` 读 BundleID；提取失败回退 `.debug.env` 并告警。

> 内测埋点包（`INTERNAL_METRICS` 注入 → 构建 → `strings` 判据 → 还原）的状态机、`--mode` 约束、pending 与 runbook 见
> `references/ios-metrics.md`（须宿主机执行，沙箱内 rc=3）。

## 平台路由

| 目标平台 | 脚本目录 | 结构化快照 | 能力 |
|---|---|---|---|
| Android 真机/模拟器 | `<S>/scripts/android/` | ✅ `snapshot.sh` | ★完整：构建/启动/日志/截图/UI 点击滑动（**Flutter 与原生工程均可用**；原生工程无 `build.sh`，见「执行约定」能力表） |
| Android/iOS 模拟器 语义 UI | `<S>/scripts/maestro/` | —（`assert_batch.sh` 批量断言） | ★无障碍语义定位点击/断言（跨端同 YAML，无需坐标）——**限 Flutter 工程**（原生工程走 `ui.sh`/`tap.sh`）；⚠️ **iOS 模拟器在沙箱内不可用**（rc=3，见「权限纪律」） |
| iOS 模拟器 | `<S>/scripts/ios/` | ⚠️ 仅沙箱外（`maestro hierarchy`；沙箱内 rc=3 降级为 `shot.sh`+`logs.sh`） | 启动/安装/日志/截图（UI 操作走 Maestro，见下）；构建 `build.sh` **仅沙箱外**（嵌套 `sandbox-exec` 被拒） |
| iOS 真机 | `<S>/scripts/ios/`（命令加 `--device`） | ✅（需 profile/release 包） | 安装启动（`devicectl`：**安装沙箱内不可用** ⇒ `run.sh --device` rc=3 并交宿主机；`process launch` 可用）/日志（`idevicesyslog --syslog-relay`）/截图（`devicectl capture`）；**构建 `build.sh --device` 只能在宿主机**（嵌套 `sandbox-exec` 被拒）；等价设 `IOS_TARGET=device` |
| iOS 真机 语义 UI | `<S>/scripts/appium/` | ✅（Appium page source） | 语义 UI（xcuitest；需 Apple 签名/TeamID，见下）——**限 Flutter 工程** |
| macOS desktop | `<S>/scripts/macos/` | ⚠️ 实验（Appium mac2） | 构建/启动/日志/截图/智能点击（Vision）+ Appium mac2（实验）；坐标点击可用 `tap_snapshot.sh --platform macos`（**实验**：`AXFrame` 形态未真机实测） |
| Windows desktop | `<S>/scripts/windows/` | ❌ 退回截图 | 构建/启动/日志/截图（需在 Windows 机执行） |

单元测试与平台无关：`bash <S>/scripts/test.sh [路径]`。
脚本层回归**统一入口**（不需真机）：`bash <S>/scripts/test_all.sh`（rc `0` 全过 / `1` 有失败 / `2` 用法错）。
默认串联七项：`test_common.sh`（.debug.env 解析 + Android 非 Flutter 支持）、`test_bg.sh -f 静态`（语法 + 多字节隐患）、`test_snapshot.sh`（快照解析 + 断言 + 点击选点/缓存 + `--diff` 变化判定 + 断言失败附 diff + `--wait` 轮询 + `--single-dump`/`--cache-payload`，296 项离线用例）、`test_safe_run.sh`（沙箱入口负控制：凭证面/写面/出网面/fail-closed/真机通道/build profile 的 SDK 缓存（含软链解析）与 trustd，**43 项**；非 macOS 自动跳过）、`test_build_metrics.sh`（`INTERNAL_METRICS` 内测包状态机：注入/还原/pending/sha 守卫/模式沿用，**27 项**，stub 构建、非 macOS 与沙箱内跳过）、`test_ios_common.sh`（`ios/_common.sh` 纯函数：syslog 行正则转义与头部锚定、App 可执行名四级回退，**12 项**）、`test_interact.sh`（输入/点击回执/坑表：`input.sh` 逐 rc + 清空/掩码/`--append`/`--text-from`/`--editable-index`/占位符哨兵探测、`tap_verify.sh` 的「已变不重点」「危险词禁二击」、`pitfall_append.sh` 去重，**137 项**，adb 桩会在 `ui.xml` 上真改内容）；加 `--full` 额外跑 `test_bg.sh` 全量行为用例（较慢）。
离线用例的测试钩子（正常使用不要设）：`SNAPSHOT_INPUT=<xml|csv>`（`snapshot.sh` 跳过 dump 走完整解析/写缓存路径）、`SNAPSHOT_BIN=<script>`（`assert_page.sh` / `tap_snapshot.sh` 替换取快照；`assert_page --wait` 通过后的 `--cache-payload` 落盘仍走真实脚本）。

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

1. **`wait` 必须短轮询**：`--timeout ≤ 100`，返回 10 就再 `wait`，循环到 0/1/3。`wait` 自身受 shell 120s 前台超时约束（`--timeout 600` 会在 120s 被外层强杀，job 本身不受影响），单次长 wait 只会拿到误导性返回。
2. **日志长时间无新增 ≠ 卡死**：`flutter build` 可能只有一行 `Running Gradle task …` 持续 8 分钟以上（实测 Android debug 473s，CPU 极低、无文件写入属 Gradle 依赖解析的正常表现）。判定卡死的唯一依据是 `status` 返回 `LOST` 或进程消失，不要因日志静止提前终止或降级。

可包装任意脚本（`android/build.sh`、`maestro/flow.sh <flow.yaml>`、`macos/smart_tap.sh "<kw>"` 等），job 元数据落 `build/debug/jobs/`。
⚠️ `ios/build.sh` **除外**：iOS 构建须在宿主机跑（沙箱内 SwiftPM 嵌套 `sandbox-exec` 被拒），见「权限纪律」。

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

**启动模拟器**：Android `flutter emulators --launch <avd_name>`（或 `$ANDROID_HOME/emulator/emulator -avd <name>`）；iOS `open -a Simulator` + `xcrun simctl boot <device_udid>`。

**iOS 真机**：前置（USB + 已配对 + 开发者模式）、`--profile` 默认构建、`build/run/shot/logs --device` 的命令与锁文件见 `references/platform-extra.md` §iOS 真机（devicectl）；等价开关 `IOS_TARGET=device` / `IOS_DEVICE_UDID`，**默认仍是模拟器**。

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
| `shot.sh` | 截图到 build/debug/screen.png（默认**只报路径**；确需 `Read` 须按「页面观测阶梯」L2 白名单写明理由） |
| `pull.sh <设备侧路径> [本地名]` | 把设备上的文件拉到 build/debug/（自带 `mkdir -p` ⇒ **subagent 档没有 `mkdir` 权限时的落点载体**） |
| `ui.sh` | uiautomator 元素清单（**Flutter 未暴露语义树**时为空，属正常；但空清单也可能是解析失败 ⇒ 拿 `共 N 个可点击节点` 与 `count` 交叉核对） |
| `tap.sh x y` 或 `--text 关键词` | 点击；危险按钮必须先 shot 确认页面。关键词为**字面包含（忽略大小写）、非正则**（故 `[`/`.`/`\|` 等按普通字符处理）。`--text` 三失败态**均为 `rc=1`**、靠消息区分：`❌ 无法获取 UI（ui.sh rc=N）`＋ui.sh 输出末 5 行（dump 级失败）／`❌ 页面无可点击节点（ui.sh rc=0 / TSV 0 行）`＋透传 `共 N 个可点击节点`（N>0 ⇒ 有节点但被 text/desc 过滤）／`❌ 未找到…`＋`💡 可用元素` 候选清单。另：label 本身含 `|` 时**显示**会被截断（`cut -d'|' -f1`；坐标仍取末两列、不受影响）—— 现状特征化，组 15.25–15.27 钉死（15.26 直断坐标仍取末两列） |
| `swipe.sh x1 y1 x2 y2 [ms]` | 滑动 |
| `settle.sh [--mode auto\|ui\|screen] [--timeout 25] [--interval 0.4] [--keep]` | **等 UI 静止**。默认 `--mode auto`：语义树可用则比两帧 `uiautomator dump`，**语义树无内容（0 个 text/desc 节点）或 dump 连续失败/持续不完整时自动降级整屏像素**（`screencap -p` 比对）。滑动/点击后**先 settle 再 `shot.sh`/`ui.sh`**，避免把动画中间帧当「页面错乱」。退出码：`0`=已静止（输出必带 `判据=ui\|screen`）/ `1`=超时未静止（⚠️ 文案 + 替代手段，不是异常）/ `2`=用法错 / `3`=**判定不可信**（仅 `--mode ui`：语义树无内容、dump 持续失败或不完整；本 3 ≠ `bg.sh` 的 3=LOST）。失败默认保留两帧在 `build/debug/.settle_*`，`--keep` 时成功也保留；screen 阶段一帧都取不到时终报「整屏截图始终不可用」（不谎报「未静止」） |
| `findtap.sh <关键词> [--max 6] [--dir down\|up] [--wait 0.4]` | **滑动查找并点击**（等价 `scroll --until`）：目标不在当前屏时自动滚动，省掉「滑一次、dump 一次」的手工循环。匹配语义与 `tap.sh --text` 一致（字面包含、忽略大小写、非正则）；命中的文本节点非 `clickable` 时按节点中心坐标兜底并**在输出中注明**。**语义树无内容时首轮立即失败**（不白滑 `--max` 屏）并给 Maestro → Vision → 坐标三级降级路径。退出码：`0`=命中并点击 / `1`=`--max` 次后仍未命中**或语义树无内容** / `2`=用法错 |
| `input.sh (--field <关键词> \| --id <元素id> \| --editable-index N) (--text <值>\|--text-from [文件]\|--text-stdin) [--key NAME] [--mask] [--append] [--clear-only] [--index N] [--max-retry 1] [--slow] [--one-key] [--no-probe] [--dry-run]` | **输入框闭环**：定位（`--field` 匹配 text/id 子串；`--id` 只匹配 id 字段；`--editable-index N` 按「页面上第 N 个可编辑框」定位——用于**既无 text 也无 id** 的输入框，Flutter/Compose 常见，2026-11-12 真机实测）→ **焦点自检**（`dumpsys input_method` 的 `mInputShown=false` ⇒ rc=7 且**未删未输**，防 DEL 落到别的框；该字段在部分 ROM 缺失时只告警）→ **清空**（`MOVE_END` + `KEYCODE_DEL`×(len+3)，`--one-key` 逐发兼容老 ROM）→ 分段输入（≤20 字符/段，`--slow` 段间隔 0.6 s）→ **读回校验**（按 `bounds` 精确定位；漂移时退「可编辑框序号 / 关键词 + 仅可编辑节点 + 同 id/total」复定位；拿不到唯一可编辑节点就按读回失败处理；校验阶段语义树重取一次仍空 ⇒ rc=4，不混成 rc=6）→ 不符重试一次（重试前重新定位并复检焦点；⚠️ `--append` 不自动重试——重试会清空旧内容，把追加变替换）。`--text-from` 缺省读项目根 `.debug-login.secret`（`init.sh` 生成、0600、已入 `.gitignore`），掩码/凭据来源输出恒 `****`；校验用快照写临时文件、退出即删。⚠️ `adb input text` **只支持 ASCII**（中文/emoji ⇒ rc=8 改走 Maestro `eraseText`+`inputText`）；字面 `%s` 会被当空格（框架限制）。退出码：`0` 通过 / `1` 未找到（附候选）/ `2` 用法或凭据权限错 / `3` 环境不可用 / `4` 语义树为空 / `5` 清空失败（`--clear-only` 读回非空时先做**占位符哨兵探测**：空框的 hint 会被语义树当成 text，2026-11-12 实测；探测会向框内输入 1 个字符再删掉，有副作用时用 `--no-probe` 关闭） / `6` 读回不符 / `7` 派发失败或**点击未获焦点（未做任何删除/输入）** / `8` 含非 ASCII |

## Maestro 命令（<S>/scripts/maestro/ — Android / iOS 模拟器）

> ⚠️ **沙箱内 iOS 模拟器不可用**：`safe_run.sh` 下这些脚本会直接 rc=3（XCUITest 驱动在嵌套沙箱内不可靠）。
> 降级用 `shot.sh` + `logs.sh`；iOS 真机走 `appium/`。详见「权限纪律」。

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
run.sh → settle.sh → (tap_verify.sh "目标按钮" --expect has:<目标页文本> | trace 无回执的旧路径)
→ 输入用 input.sh（清空+读回校验），不要再拼 adb input text
→ settle.sh → assert_page.sh （失败先 `snapshot.sh`，exit 4 才 `shot.sh`）
→ logclear.sh → 触发目标操作 → logs.sh 分析
→ 修复后：build.sh → run.sh → 重走同一序列 → logs.sh 验证
```
可复制 YAML 片段与 shell 等价序列见 `references/maestro-flow-snippets.md`（注意 `launchApp` 只用于冷启动冒烟，**复现既有页面状态时不要用**）。
**等日志出现时用 `logwatch.sh <签名> <超时>`，不要自己拼 `adb logcat --pid=$PID` 轮询**（写死 PID 在 App 重启后会僵死成孤儿进程）。判据签名必须先在源码 `grep` 确认真实存在，勿用方法名猜测。
**UI 操作优先级**（效率从高到低）：
1. **`tap_verify.sh 关键词 --expect has:<目标文本>`** — 一次调用拿到「点击 + 回执 + 必要时重试」，是现代替代首选（带断言恒强于任何无回执的旧路径）
2. **Maestro**（`maestro/tap.sh` / `assert.sh` / `flow.sh`）— 语义定位，无需坐标、无需截图；多步/输入用 `flow.sh`（`eraseText` + `inputText`），中文输入只能走这里
3. **`tap_snapshot.sh 关键词`** — 已有 ≤60 s 快照时最快（命中缓存 <1 s），且能点 `clickable=false` 的文本节点；无缓存时 ≈ 一次 `snapshot.sh` + 点击。⚠️ **页面切换后必须 `--fresh`**，否则按旧坐标点
4. `ui.sh` 命中 → `tap.sh --text 关键词` / `tap.sh x y`；**目标不在当前屏**时用 `findtap.sh 关键词`（自动滚动查找+点击，省掉手工「滑一次 dump 一次」）
5. **Vision 智能命令**（语义树缺失/视觉状态判断时；macOS 的 `smart_tap.sh` 见 `references/platform-extra.md`，图像分析见本节 Vision 命令）
6. 坐标点击前必须 `shot.sh` + `Read` 确认当前页（属 L2 白名单④；滑动/点击后先 `settle.sh`，避免抓到动画中间帧）
   > 例外：**与点击同源于同一时刻语义快照**的坐标（`tap_snapshot.sh`、`snapshot.sh --center` + `tap.sh x y`）不属坐标兜底，免 `shot.sh` 前置；危险操作仍需确认（白名单⑤）。
   > 2–4 与 6 的 rc=0 **都只表示事件已送达**：必须再用 `assert_page.sh --wait` 判「有没有点中」。

**回退**：Maestro 报错 → 先 `snapshot.sh` 取摘要（含指纹）定位失败层，摘要为空（exit 4）才 `shot.sh`，再降级到 ui.sh / Vision，不得盲点。但**必须先区分「流程失败」与「被超时中断」**：
- 看 `build/debug/maestro_output.log` 停在哪一步。停在 `Tap on …` / `Assert …` 等步骤（如 `Element not found`）→ **真·流程失败**，按上面正常回退。
- 停在启动信息 或 `Selected device … using port …` 之后无输出 → 是 Maestro 冷启动/驱动握手**被外层超时杀掉，不是流程失败**。应先 `adb -s <设备> forward --remove-all` 清理残留端口转发、改用 `bg.sh` 后台模式重试（或把超时提到 ≥180s），**不要据此降级**。

### Vision 调用路由（补充规则）
- `ui.sh` 命中元素 → 直接 `tap.sh`，不调 Vision
- 以下场景必须走 Vision：
  - `ui.sh` 为空/语义树未暴露（Flutter 页面常见；**非 Flutter 页面也空 ⇒ 先怀疑解析失败**，先用 `snapshot.sh` 交叉核对，仍为空再 `shot.sh`）
  - 判断：白屏 / 遮挡 / 错位 / 图片缺失 / loading / empty 状态 / error 文案定位
  - 需要 OCR 读取非控件文本（toast、dialog、snackbar、红色报错）
  - 视觉回归对比（`compare` task）
- Vision 失败（exit 3） → 回退 `ui.sh + logs.sh` 组合判断，不得臆断视觉信息
- **Vision API Key 配置**：`VISION_API_KEY` 可通过 CLI `--api-key`、环境变量、或 `.debug.env` 的 `VISION_API_KEY` 键三级读取。若在 `.debug.env` 中填入真实 Key，务必把该文件加入 `.gitignore`，避免密钥入库。

## iOS 模拟器（<S>/scripts/ios/）

前置：Xcode 已装、至少一个模拟器可用（无已启动的会尝试 boot 第一个可用项）。

| 命令 | 说明 |
|---|---|
| `build.sh [--device] [--simulator] [flutter build 参数]` | 默认模拟器（`--debug --simulator`）；`--device` ⇒ 真机（**默认 `--profile`**，debug 受 iOS 14+ JIT 限制）；模拟器透传参数自动补 `--debug`/`--simulator`。⚠️ **只能在宿主机跑**：沙箱内 xcodebuild 的 SwiftPM 解析会嵌套 `sandbox-exec` 被拒 |
| `run.sh [--device]` | 模拟器 simctl install+launch；真机 devicectl install+launch（输出 PID） |
| `logs.sh [--device] [--app-only] [行数] [关键词]` | tail 日志 + 异常摘要：模拟器读 `app.log`；真机读 `app_device.log`。`--app-only` 只留 App 进程行（滤掉 Sandbox/kernel 噪声，实测 1978→575 行） |
| `shot.sh [--device]` | 模拟器 simctl io screenshot；真机 devicectl capture（回退 idevicescreenshot） |
| `logclear.sh [--device]` | 清空日志；`--device` 会**先停常驻 idevicesyslog 采集进程**（按 `syslog.pid` 第 2 行的 UDID 定向，多设备不误杀）再清 `app_device.log`；停不掉时报错不假装成功（真机调试结束后必跑，否则文件持续增长） |
| （UI 操作）`<S>/scripts/maestro/tap.sh` | 语义点击（模拟器），见「Maestro 命令」节 |

**能力边界**：**iOS 真机** UI 操作走 Appium（`appium/tap.sh --platform ios-device`，需 `IOS_TEAM_ID` 与 XCUITest，属实验路径）；**iOS 模拟器**用 Maestro（`maestro/tap.sh` / `assert.sh`，语义定位无需坐标），复杂多步场景优先 `maestro/flow.sh`。需代码级 UI 测试时才写 integration_test：
```bash
flutter test integration_test/<file>.dart -d <simulator_udid>
```

## 其他平台（Appium / macOS / Windows）

命令表与排障见 `references/platform-extra.md`。执行前必记三条：

- **Appium 不可逆副作用**：路线 A 自动签名会在设备未注册时自动注册设备（占用团队年度额度）并创建/更新描述文件；iOS 真机需 `IOS_TEAM_ID`，且必须是 profile/release 包（debug 包 JIT 受限）。
- **Appium 输入纪律**：默认先清空再输入并读回校验；追加须显式 `--no-clear` / `{"clear": false}` 且不自动重试；密码用 `--mask`，敏感值用 `--text-from <文件>`。
- **macOS 智能点击**：`smart_tap.sh` / `smart_assert.sh` 含护栏（置信度 <0.7、危险词、loading/白屏时拒点）；需「屏幕录制」+「辅助功能」权限；排障读 `references/macos-smart.md`。

## 测试分层策略

| 层级 | 命令 | 耗时 | 依赖 |
|---|---|---|---|
| 单元测试 | `flutter test test/<file>` | < 10s | 无 |
| Widget 测试 | `flutter test widget_test.dart` | 10s-1min | 无 |
| Integration 测试 | `flutter test integration_test/<file>.dart -d <device>` | 1-3min | 模拟器/真机 |

**优先级**：能 unit 不 widget，能 widget 不 integration。integration_test 拆成多个独立 test 文件、模拟器优先，命令同样走 `bg.sh`（见核心规则 7）。

## 角色协作

- **build** (主代理)：改代码、编排验证
- **debug** (子代理)：静态根因定位，不动设备、不动代码
- **autoDebug** (子代理)：本 skill 的真机执行层——启动/UI操作/抓日志/截图/回归验证，**edit: deny**（构建：Android 可在沙箱内；**iOS 须主 agent 在宿主机跑**，见「权限纪律」）

build 通过 `task(subagent_type="autoDebug", prompt="...")` 把真机操作派给 autoDebug；autoDebug 返回证据（日志摘录/截图路径/结论），build 据此改码后再派回归验证任务。

## 核心规则

1. 修 Bug 必须先拿真实日志定位根因，禁止猜测
2. 禁止未运行验证就声称修复；修复后重走同一操作序列并附日志证据
3. 不通过吞异常/大范围 try-catch 屏蔽问题；最小修改不动无关代码
4. 同一设备同时仅运行一个 Debug Loop
5. 日志关注点：`[模块][类名]` 前缀日志 + exception/error/fatal
6. 危险操作（解绑/删除/付款类）点击前：优先 `snapshot.sh` + `assert_page.sh` 确认页面，语义树为空（exit 4）才 `shot.sh`；macOS 路径 `smart_tap.sh` 默认已拒绝危险词（误判才加 `--allow-danger`）
7. `integration_test` 命令同样优先走 `bg.sh` 后台模式；确需前台直调时 timeout ≥ 180s
8. UI 操作优先级：tap_verify.sh（带断言回执）> Maestro > tap_snapshot.sh（页面切换后必须 `--fresh`）> ui.sh/tap.sh/findtap.sh > Vision；任何路径失败先用 `snapshot.sh` 取摘要定位失败层，摘要为空再 `shot.sh`，禁止盲点坐标
9. **输入一律走脚本**（`android/input.sh` / `driver.py find-type`）：先清空再输入、读回校验；禁止临场拼 `adb shell input text`；`rc=0` 只代表事件送达，不代表点中/输入对
10. **每条结论都要绑证据**（见下节）；没有证据一律写「未验证」，不得写「已修复」

## 证据与主张（回报口径）

**证据分层**（由弱到强，只能声明到证据支撑的那一层）：

| 层 | 证据 | 能支撑的主张 |
|---|---|---|
| 源码推断 | 读代码/调用链 | 「按代码应当…」（不是「实际如此」） |
| 静态检查/单测 | `flutter analyze`、`flutter test` | 「逻辑层无回归」 |
| 构建产物 | `build/debug/.last_*` 锁文件、APK/.app 存在 | 「产物已产出」 |
| 运行日志 | `logs.sh` / `logwatch.sh` 命中签名 | 「该路径本次被执行」 |
| 语义摘要/断言 | `snapshot.sh` / `assert_page.sh` 通过 | 「界面呈现符合预期」 |
| 截图 | `shot.sh`（仅视觉类/取证，默认不 `Read`） | 仅「视觉呈现」 |

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
