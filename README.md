# debug-loop

一个用于 **真机/模拟器自动化调试** 的 agent skill：把「构建 → 安装 → 启动 → 抓日志 → 截图 → UI 操作复现 → 验证修复」这条最容易靠印象走的链路，变成一组**有退出码契约的脚本**。

> 面向 opencode / Claude 一类支持 `SKILL.md` 的 agent 运行时。提示词 + bash 脚本；Android / iOS / macOS / Windows 四端。

## 它解决什么问题

| 常见失败 | 本 skill 的做法 |
|---|---|
| 每轮调试先 `adb devices`、`which xxx`、`--help` 探一圈，把预算烧在「确认状态」上 | `scripts/doctor.sh` 一条命令出五类事实（配置 / 工具链 / 设备 / 产物 / 可选密钥），rc=0 才继续 |
| 「点了没反应」分不清是慢、是崩、还是放错了位置 | 固定优先级：语义/文本定位（Maestro → `ui.sh` / `findtap.sh`）＞ Vision ＞ 坐标；用坐标必须附截图确认 |
| 截图/点击时页面还在转场，取到中间态就下结论 | `settle.sh` 双帧比对等静止，**rc=0 必带 `判据=ui|screen`**，超时是 rc=1 而不是异常 |
| Flutter 未开 semantics，UI 树为空却按「已静止」放行 | 判据是**语义节点数**不是字节数（真机实测空树 dump 仍有 3418 B）；`auto` 自动降级整屏像素，`--mode ui` 明确返回 rc=3「判定不可信」 |
| 目标不在当前屏，白滑 6 屏才失败 | `findtap.sh` 语义树为空**首屏即 rc=1**，并给出三级降级路径 |
| 长构建/长日志把会话卡死，或靠 `sleep 30` 猜 | `bg.sh` 后台任务 + pid/exit/log 三件套，轮询有规范、卡死有判定 |

## 何时触发

需要**在真机/模拟器上跑起来看**：复现 Bug、抓 logcat/应用日志、截图取证、点按滑动操作 UI、验证修复是否生效。

**不适用于**：编译期报错修复（用 `code-error-fixer`）、纯代码审查（用 `review`）、目标位置未知的多轮搜索（用 `progressive-find`）。skill 的 `description` 已写明这些排除关系。

## 安装

```bash
# 方式一：软链（推荐，跟随仓库更新）
ln -s ~/Projects/debug-loop-skill ~/.config/opencode/skills/debug-loop

# 方式二：整目录复制
cp -R debug-loop-skill ~/.config/opencode/skills/debug-loop
```

## 使用

在**项目根**准备 `.debug.env`（常量文件，`bash <S>/init.sh` 可生成），然后：

```bash
bash <S>/scripts/doctor.sh --platform android        # 一次自检
bash <S>/scripts/android/build.sh                    # 构建
bash <S>/scripts/android/run.sh                      # 安装 + 启动
bash <S>/scripts/android/settle.sh                   # 等静止（rc=0 必带判据）
bash <S>/scripts/android/shot.sh                     # 截图
bash <S>/scripts/android/findtap.sh "Playback"       # 语义定位 + 点击
bash <S>/scripts/android/logs.sh                     # 抓日志
```

`<S>` 指本 skill 的 base directory。所有脚本都是**单条命令**、可判 rc，便于 agent 在权限受限的子会话里按白名单调用。

## 结构

```
SKILL.md                    主流程：前置检查 → 平台路由 → 命令表 → 证据口径
references/                 按需下钻（macOS 智能命令 / iOS 真机 Appium / Windows / Maestro 片段 / 故障速查 / 上游取舍）
scripts/doctor.sh           五类事实自检
scripts/bg.sh               长任务后台模式（pid / exit / log）
scripts/android/            build install run logs shot ui settle findtap tap swipe pull
scripts/ios/                build run logs shot（模拟器）
scripts/appium/             iOS 真机 / macOS 实验（WDA 签名、caps、source、tap、assert）
scripts/maestro/            Maestro 流程封装（语义定位首选路径）
scripts/macos/              build run logs shot click + smart_tap / smart_assert
scripts/vision/             Vision 视觉定位（可选，需 VISION_API_KEY）
scripts/windows/            build logs run shot（PowerShell）
scripts/test_common.sh      解析/注入/降级回归（无需设备）
scripts/test_bg.sh          bg.sh 回归（无需设备）
docs/plan/ docs/review/ docs/baton/   本 skill 的方案、审查与接力棒
```

## 自检

```bash
bash scripts/test_common.sh    # 100 条断言，桩 adb，无设备
bash scripts/test_bg.sh        # 215 项，临时目录构造假项目
```

两者都**不连真机**；真机行为（判据、降级、findtap 命中）另见 `docs/plan/20261027-debugloop-next.md` §7 的实测记录。

## 依赖

| 能力 | 需要 |
|---|---|
| Android | `adb`（+ 一台在线设备/模拟器） |
| iOS 模拟器 | Xcode（`simctl`） |
| iOS 真机 | Xcode + Appium + WDA（见 `references/appium-ios-device.md`） |
| 语义定位首选 | `maestro`（缺则自动降级到 `ui.sh` / 坐标） |
| Vision 兜底 | `python3` + `VISION_API_KEY`（可选） |
| Windows | 只能在 Windows 上构建（见 `references/windows-setup.md`） |

缺工具时 `doctor.sh` 会分级标出，**不会自动安装**（`brew` / `npm -g` 属用户动作）。

## License

MIT（见 `LICENSE`）。
