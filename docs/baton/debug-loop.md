# debug-loop skill：settle/findtap 判据 + 文档下沉（baton）

> 最后更新：2026-10-27
> 本文件 owner：`~/.config/opencode/skills/debug-loop` 这条线。方案见 `docs/plan/20261027-debugloop-next.md`，审查见 `docs/review/debugloop-next.md` / `.r2.md`。

## 模块结构
- skill 根：`~/.config/opencode/skills/debug-loop/`（**不是 git 仓库**，回滚只能靠 `~/debug-loop-snap-20261027/` 逐文件 `cp`）
- 判据公共段：`scripts/android/_common.sh`（`MIN_DUMP_BYTES` / `SETTLE_MIN_PNG_BYTES` / `SETTLE_FRAME_ALARM` / `ui_has_semantics()`）
- 被测对象：`scripts/android/settle.sh`、`scripts/android/findtap.sh`
- 回归：`scripts/test_common.sh`（G1–G12，100 项）、`scripts/test_bg.sh`（215 项，约 33s）
- 文档：`SKILL.md`（371 行）+ `references/{macos-smart,appium-ios-device,maestro-flow-snippets,troubleshooting,autoDebug-task-template}.md`

## 关键约束
- `settle` 判据是**语义节点数**（`ui_has_semantics`），**不是字节数**；字节只做完整性下限（256 B），整屏截图另有下限（1024 B）。
- 采样三态 `ok_has_semantics` / `ok_empty` / `fail`，**fail 与「无内容」不可混**；任何丢弃帧的分支必须清 `PREV`（否则槽位轮转 ⇒ 同路径自比 ⇒ 假「已静止」，这是本项目踩过的真坑）。
- rc 契约：`0` 静止（必带 `判据=ui|screen`）/ `1` 超时或判据不可用 / `2` 用法 / `3` 判定不可信（**仅 `--mode ui`**）。本 3 ≠ `bg.sh` 的 3=LOST。
- 设备侧固定 `/sdcard/ui_settle.xml`，**不得**复用 `ui.sh` 的 `/sdcard/ui.xml`。
- `findtap` 语义树为空 = **rc=1 立即失败**（不白滑 `--max` 屏），降级顺序 Maestro → Vision → 坐标。
- 静态组会拦两件事：`bash -n`；`$VAR` 紧跟非 ASCII（必须写 `${VAR}`）。

## 已完成
- 四项遗留全部落地：settle 三态+auto 降级+预算感知；findtap 快速失败；`SKILL.md` 417→371（macOS/Appium 下沉为摘要，必备命令名写死）；复现循环与 Maestro 片段接入。
- 两轮代码审查闭环（P1 假阳性回归 + N-1 降级出口丢失均已修）；G12 从 0 扩到 44 条断言。
- 收尾清理：`SKILL.md` 的「152 项」改 215（实测 33s）；「仓库已挂 hooks」改为条件句（本机 `~/.config/opencode` 不是 git 仓库、无 `hooks/`）。
- 真机冒烟（R58M00TEST1 / Samsung Settings）：settle 三模式 rc=0；findtap `Display` 第 1 屏、`About phone` 第 3 屏命中。
- 真机 Flutter 复跑（sample_pro）：列表/实时/全屏三页 settle 均 rc=0，`findtap "Playback"` 第 1 屏命中；取得单帧成本（dump 2.43s / screencap 0.42s）。
- **空树分支真机验证**（一次性 CustomPaint 工程）：auto 降级 → `判据=screen` rc=0；`--mode ui` rc=3；`findtap` 首屏 rc=1；空树 dump 实测 **3418 B**。

## 未完成
- 无（空树分支已于 2026-10-27 用一次性 Flutter 工程在真机验证并通过：auto 降级 rc=0 / `--mode ui` rc=3 / findtap rc=1）。
- `screen` 模式在 FLAG_SECURE/息屏下仍可能假「静止」（设计边界，靠 rc=0 必带 `判据=screen` 缓解）。

## 实测数据（2026-10-27，真机 R58M00TEST1）
- **空语义树 Flutter 页 dump = 3418 B（3.4 KB）** ⇒ 旧的「≥1024 B 视为有内容」判据必然漏判，必须用节点计数（这是本项目最关键的实测锚点）。
- 单帧 `ui.sh`（dump+pull+解析）**2.43s**；`exec-out screencap -p` **0.42s / 56 KB**。
- 带语义的 Flutter 页 dump **7–11 KB**（sample_pro：列表 11382 B、实时 7364 B）。
- auto 默认 `--timeout 25` 只够约 10 帧 ⇒ 剩余预算 <10s 的降级判据在真机上是必要的。

## 复现「空树」场景的方法（下次要重验时用）
1. `flutter create --platforms=android --org com.example --project-name sem_empty sem_empty`
2. `lib/main.dart` 只放一个 `CustomPaint`（**不写任何 `Text`/`Semantics`/按钮**）
3. 写 `.debug.env`（`ANDROID_APP_ID=com.example.sem_empty`）→ `build.sh` → `run.sh`
4. 期望：`ui.sh` 显示 `共 0 个可点击节点`、dump ≈3.4 KB；`settle.sh` 打印降级并以 `判据=screen` 判静止；`--mode ui` 返回 rc=3；`findtap.sh` 首屏 rc=1

## 下一步
- 无必做项。候选：`bundle.sh` 证据包 / MCP 化（方案 §1 明确本轮不做，须先确认需求）。
- 若重验空树分支：按上面「复现空树场景的方法」四步走即可（约 3 分钟，Gradle 首次构建 ~60s）。

## 踩过的坑
- 用「字节数 ≥1024」判空树是错的：旧的「1099 B 空树」实例其实是 **iOS pageSource**；真机实测 Android Flutter 空树 dump = **3418 B（3.4 KB）** > 1024 ⇒ 字节阈值**必然漏判**，判据只能数语义节点。
- `settle.sh` 的 `SLOT` 按 `SAMPLES` 奇偶轮转，**失败的那轮也递增 SAMPLES** ⇒ 只要失败分支不清 `PREV`，下一次成功采样就会 `cmp` 同路径自比、单帧判静止（review 抓到的 P1）。
- 完整性检查前移到语义检查之前后会**丢掉降级出口**（auto 模式空烧 timeout）——顺序调整必须同时补计数上限与降级/退出。
- `test_common.sh` 的全局 adb 桩 `exec-out` 只有 ~20 B，G12 必须自建 `$TMPROOT/g12bin/adb`（case-local PATH，落文件末尾，不污染 G1–G11）。
