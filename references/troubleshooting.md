# 故障速查（先查表再试，别重复同一条命令）

> 用法：按「现象」定位行 → 看「判定」确认不是误判 → 按「处置」执行。
> 前置：先跑 `bash <S>/scripts/doctor.sh`，它的 ❌/⚠️ 分级通常已指出一半问题。

## A. 命令层（先排除误判）

| 现象 | 判定 | 处置 |
|---|---|---|
| `shell` 单条命令被秒拒（`cat`/`sed`/`mkdir`/重定向） | **权限面**拒绝，不是环境坏了 | 换脚本或换形态：读区间用 `read --offset`、抽字段用 `grep -oE`、落盘交给 `shot.sh`/`pull.sh` |
| 复合命令（`&&` / `;`）整条被拒 | subagent 档逐段判权，任一段不可达即整条拒 | 多步逻辑写进脚本再 `bash <S>/scripts/…` 调用 |
| `doctor.sh` rc=1 但目标平台能跑 | 阻塞项来自**未配置平台** | `--platform <目标平台>` 过滤后再看 |
| 单条命令失败就宣布「无权限/环境不可用」 | 典型误判（曾有事故） | 先看 doctor 分级；只有 ❌ 才算阻塞 |

## B. 构建与产物

| 现象 | 判定 | 处置 |
|---|---|---|
| `flutter build` 日志长期只有 `Running Gradle task …` | **不是卡死**（实测 debug 构建可达 470s，CPU 极低） | `bg.sh status` 判存活；LOST 才算失败。用 `bg.sh wait --timeout 100` 短轮询 |
| 构建后找不到 APK | flavor/ABI 命名不同 | 看 `build/debug/.last_android_*` 锁文件；或 `.debug.env` 显式 `ANDROID_APK_PATH` |
| `gradlew clean` 后 `build/debug` 空了 | 证据已被清 | 之后每次取证都**先** `pull.sh` 外带；主张按「未验证」重报 |
| 非 Flutter 工程 `install.sh` 报无 APK | 原生工程不自动发现 APK | `.debug.env` 设 `ANDROID_APK_PATH`（或手工写锁文件） |

## C. UI 定位（Android）

| 现象 | 判定 | 处置 |
|---|---|---|
| `ui.sh` 清单为空但页面有内容 | ①Flutter 未暴露语义树 ②dump 在动画中 ③解析失败 | 先 `settle.sh` 重试；仍空看 `共 N 个可点击节点` 与 `count` 是否互相矛盾；确认后改 Maestro 或 Vision |
| `tap.sh --text` 报「页面无可点击节点」 | 页面确实无文本节点 / 全被过滤 | 用 `shot.sh` + 坐标；或 `maestro/tap.sh` |
| `tap.sh --text` 报「未找到」但有候选清单 | 关键词不匹配（字面包含，非正则） | 换更短的稳定子串；`|` 会被截断显示，坐标不受影响 |
| 文本在界面上看得见却点不到（`clickable="false"`） | Compose / RecyclerView 常见 | 用 `findtap.sh`（自动滚动 + 文本节点中心兜底点击，输出会注明兜底） |
| 目标项需要滚动才能看到 | — | `findtap.sh <关键词> --max 6 [--dir up]`，不要手工「滑一次 dump 一次」 |
| 截图抓到过渡态（白屏/半透明） | 动画未结束 | 先 `settle.sh` 再 `shot.sh` |
| `settle.sh` 秒回「已静止」但页面明显在动 | 旧实现（已修）：空 dump 两次哈希相同即判静止。现实现按「语义节点数」判空，空树自动降级整屏像素 | 看 rc=0 输出里的 `判据=`：为 `screen` 且画面仍在动 ⇒ 帧含时钟/视频，加大 `--timeout`（≥15）或改 Maestro `assert.sh` 轮询；`--mode ui` 返回 **rc=3** ⇒ 语义树不可用，改 Maestro / Vision |
| `settle.sh` 返回 rc=3 | **判定不可信**（仅 `--mode ui`）：语义树无内容或 dump 持续失败，**不是**「页面已静止」 | 去掉 `--mode ui` 用默认 `auto`（自动降级整屏像素），或显式 `--mode screen`；⚠️ rc=3 ≠ `bg.sh` 的 3（LOST） |
| `findtap.sh` 首屏就报「语义树无内容」rc=1 | Flutter 未暴露语义树 ⇒ 滑动查找**不可能**命中，故不白滑 `--max` 屏 | 按输出三级降级：`maestro/tap.sh` → Vision 定位 → `shot.sh` + 坐标 `tap.sh`（须先截图确认） |
| `settle.sh` 报「整屏截图始终不可用」rc=1 | screen 阶段 **screencap 一帧都没取到**（命令失败/0 字节），属「判据不可用」而非「页面在动」 | 先 `shot.sh` 验证能否截图；确认是 `screencap -p` 不被支持时改用 `maestro/assert.sh` 轮询或 `logwatch.sh <签名>`，别加大 `--timeout`（无效） |
| 多设备抢焦点 | 脚本默认取第一台 | 只留目标设备；或 `adb -s <id>` 前先 `adb devices` 核实 |

## D. Maestro

| 现象 | 判定 | 处置 |
|---|---|---|
| 日志停在 `Selected device … port …` 后无输出 | 冷启动被**外层超时杀掉**，不是流程失败 | 先 `adb forward --remove-all` 清残留，再 `bg.sh` 后台重试（或超时 ≥180s） |
| `Element not found` | 真·流程失败（语义树缺该控件） | 无文本控件需 App 侧 `Semantics(label:/identifier:)`；否则降级 `ui.sh`/Vision |
| 单次 60~180s 才成功 | JVM 进程 + 驱动握手 | 一律 `bg.sh` 包装 |

## E. Appium / iOS 真机

| 现象 | 判定 | 处置 |
|---|---|---|
| 首启 page source 只有 ~1KB | Flutter semantics 激活延迟 | 重跑一次 `source.sh` |
| 源里只有「In iOS 14+, debug mode Flutter apps …」 | 设备上是 **debug** 包（JIT 限制） | 用 `ios/build.sh --device`（默认 profile）+ `run.sh --device` 重装 |
| `No Accounts` / code 65 | Xcode 账号不可用 | 转 WDA 离线路线（`wda_prepare.sh` + 描述文件手签），**不要**自动注册设备 |
| mac2 找不到 Flutter 控件 | upstream 已知限制 | 回退 `macos/smart_tap.sh`（Vision） |

## F. 配置（`.debug.env`）

| 现象 | 原因 |
|---|---|
| `值含非法字符` | 值里出现 `;` / 反引号 / `$(`（防注入，必须改写） |
| `不能以 ~ 开头` / `不能以 - 开头` | 变量不展开、防被当选项；写绝对或相对路径 |
| `LOG_DIR 必须是项目内相对路径` | 禁止绝对路径与 `..` 逃逸 |
| `未知键（已忽略）` | 键名拼错（如 `ANDROID_PACKAGE`），改回 `ANDROID_APP_ID` |
| 引号未闭合 | `KEY="值` 缺右引号 |

## G. 记录新故障

本表只收「会导致误判或重复踩坑」的条目。新增一行要求：**现象可复现 + 判定依据明确 + 处置可执行**；
一次性的偶发日志不要写进来（会稀释检索价值）。
