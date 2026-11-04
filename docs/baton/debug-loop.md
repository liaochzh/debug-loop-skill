# debug-loop skill：settle/findtap 判据 + 文档下沉（baton）

> 最后更新：2026-11-04
> 本文件 owner：`~/.config/opencode/skills/debug-loop` 这条线（**目录级软链** → `~/Projects/debug-loop-skill`，GitHub `liaochzh/debug-loop-skill`，private）。方案见 `docs/plan/20261027-debugloop-next.md`，审查见 `docs/review/debugloop-next.md` / `.r2.md`。

## 模块结构
- skill 根：`~/.config/opencode/skills/debug-loop` → 软链到 `~/Projects/debug-loop-skill`（**2026-10-28 起是 git 仓库**，局部 `user.email=liaochzh@gmail.com`；文档已从 `~/docs/` 迁回本仓 `docs/`）
- 历史回滚点：`~/debug-loop-snap-20261027/`（入库前的快照；现可直接 `git revert`/`git checkout`）
- 判据公共段：`scripts/android/_common.sh`（`MIN_DUMP_BYTES` / `SETTLE_MIN_PNG_BYTES` / `SETTLE_FRAME_ALARM` / `ui_has_semantics()`）
- 被测对象：`scripts/android/settle.sh`、`scripts/android/findtap.sh`
- 回归：`scripts/test_common.sh`（G1–G12，100 项）、`scripts/test_bg.sh`（215 项，约 33s）、`scripts/test_safe_run.sh`（43 项）、`scripts/test_build_metrics.sh`（27 项）；`scripts/test_all.sh` 串联五项
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

## 沙箱 / 真机链路（2026-11-04）

方案：`docs/plan/20261104-debug-sandbox-followups.md`；审查：`docs/review/20261104-debug-sandbox-followups.md`（结论「通过」，7 条问题全部处置）；提交：`c2cf081`（**未 push**，发布走 `publish.sh`）。

### 已完成
- **A `safe_run.sh` 软链 SDK 推导**：`--profile build` 的 Flutter SDK 缓存改为「先解析软链链再校验」；`resolve_symlink_chain()` 拒相对路径、逐跳 `cd` + `pwd -P`、10 跳上限；解析失败一律不放行且走 stderr 可观测。原 6 道校验保留。回归新增独立分组 `N13-flutter软链`（不引用 `N12_SKIP`、PATH 收窄），`test_safe_run.sh` 共 **43 项**。
- **B `ios/run.sh --device` 顺序**：stop 旧采集 → install → 起采集 → launch（原实现先起采集再 install，`set -e` 下安装失败会留孤儿采集）。install 失败：沙箱内 `rc=3` + 宿主机指引，宿主机 `rc=1`；产物路径绝对化并显式校验。
- **C 埋点内测包脚本化**：新增 `scripts/ios/build_metrics.sh`（`INTERNAL_METRICS` 状态机：备份 + sha256 守卫 → 注入 → 构建 → `strings` 双判据 → 还原 → 重编 → 判据归零；`--restore` / `--clear-pending` / `--keep` / `--force`；`--mode` 只接受 `profile|release`，拒绝 debug；沙箱内 `rc=3`）与 `scripts/test_build_metrics.sh`（**27 项**离线 stub 回归），接入 `test_all.sh`（五项）。
- **D runbook**：`SKILL.md` 新增「埋点内测包（INTERNAL_METRICS）」小节；`logwatch.sh` 头注补 `startLog done` 只在导出涂鸦日志时输出、已登录态需先退出登录。
- **真机验证（2026-11-04，profile 双轮）**：注入 → `P2PCameraOverlap = 1` / 对照 `ThingLogSDK.startLog done = 1` → 自动还原重编 → `= 0` / 对照 `= 1`；xcconfig 最终 sha `f991dfab…` == 审计 `sha_before`（逐字节还原）；`grep -c INTERNAL_METRICS` = 0；`build/debug/metrics/` 只剩 `build_metrics.log` + `ipc_business.strings.txt`（无 `pending_restore`/`.bak`/`.state`）；耗时 11:17:01 → 11:22:33（两轮构建各 ~93 s）。
- **宿主机 `run.sh --device` 成功路径（2026-11-04 实测）**：`bash scripts/ios/run.sh --device`（cwd=项目根）rc=0 —— 停旧采集 → `devicectl install` 成功（返回 installationURL）→ 起 `idevicesyslog` 采集 → `process launch` 返回 PID 31624 且 `device info processes` 确认存活；`app_device.log` 从 0 涨到 3122 → 3796 行（5 s），`syslog.pid` 第 1/2 行为 PID + UDID。⚠️ 说明：安装失败只在**沙箱 profile 内**复现，宿主机直跑不受 `file-issue-extension` 限制。
- 门禁：`test_safe_run.sh` 43 ✅ / `test_build_metrics.sh` 27 ✅ / `test_common.sh` 109 ✅（含新增 G13）/ `test_all.sh` 全绿 / `verify-env-guard.py --gate --quiet` rc=0。

### 未完成
- `--mode release` 未实测（只跑了 profile）。
- 仓库仍有 10 个早前会话的 `M` 文件未提交（与本轮无关，未暂存未改动）。

### 本轮新增的坑
- **`command -v flutter` 会静默跳过断链/成环**：想验证「软链解析失败是否可观测」时，用断链或成环构造根本进不了解析器；必须用 13 跳超长链（终点可执行但超上限）。
- **沙箱内 `devicectl install` 的根因是 `sandbox_extension_issue_file … Operation not permitted`**（`file-issue-extension` 权限面）⇒ `NSCocoaErrorDomain 257`「读不到 Info.plist」。把 bundle 先 `ditto` 到 `$TMPDIR` 同样失败（与路径/卷无关），所以**不放宽权限面**，契约固定为沙箱 `rc=3` 交宿主机。⚠️ 宿主机直跑同一条命令 rc=0 —— 别把「宿主机也装不上」当成结论。
- **基线 sha 的测量时序**：必须在启动任何会改该文件的任务（含后台任务）**之前**同步测量；后台启动后再测，测到的是注入后的状态（本轮曾把注入后 `d32a615e…` 误当基线，真实基线 `f991dfab…`）。
- **trap EXIT 做回滚/收尾必须先存 rc**：`rc=$?` → 收尾 → `exit "$rc"`，否则断言失败会被吞成成功；INT/TERM 用 `exit 130/143` 汇入 EXIT trap。

### 沙箱内已知不可用（会反复踩）
`pgrep` / `ps`、`xctrace list devices`、`flutter build ios`、`devicectl install`。白名单只放行两条 `safe_run.sh` 绝对路径；`bash -c '…'` 可执行多步，`cd X && …` 复合命令会被拒（用 shell 的 `workdir`）。`safe_run.sh` 尾部 `"$SBD" … ; exit $?` ⇒ 被包命令 rc 原样透传。

## 发布（推送到 GitHub）
- 本机权限层对所有 agent 硬性 deny `git push*`（build / autoDebug / commit 档），**不要反复重试**；agent 唯一发布入口是白名单脚本：
  ```bash
  bash ~/.config/opencode/scripts/publish.sh ~/Projects/debug-loop-skill          # 发布当前分支
  bash ~/.config/opencode/scripts/publish.sh ~/Projects/debug-loop-skill --dry-run # 只看计划
  ```
  白名单：`~/.config/opencode/publish-allowlist`（一行一个 `owner/repo`，精确匹配、不支持通配；**只能人工编辑**）。
- 脚本只做**快进**：远端有本地没有的提交 ⇒ rc=1 拒绝，**不提供 `--force`**；只碰远端，不改本地历史与工作区（SHA 保真）。
- 退出码：`0` 已推送/已同步 · `1` 策略或前置拒绝（非白名单/分叉/白名单缺失）· `2` 用法错误 · `3` 网络或传输失败。
- 方案与验收：`~/docs/plan/20261028-publish-channel.md`（v2，含 V1–V10 实测）。
- 远端：`liaochzh/debug-loop-skill`（**public**，2026-10-28 起）；skill 目录通过软链 `~/.config/opencode/skills/debug-loop` 指向本仓。
- ⚠️ **脱敏纪律**：本仓已公开，历史与工作树均不含真实设备/内部产品标识。写入新内容时沿用占位值——设备号 `R58M00TEST1`、包名 `com.example.demo`、示例工程 `sample_pro`、家目录路径 `<home>/…`（权限 pattern 需绝对拼写时用 `<home>` 指代，不要写真实用户名）。
- 旧历史（含真实设备号）保留在私有归档仓 `liaochzh/debug-loop-skill-private-archive`，**勿公开**；确认无需回溯后可整仓删除。
- ⚠️ 不得绕过 `publish.sh` 直推（如用 `gh api` 改 ref）：白名单只约束经本脚本的调用，旁路靠档位纪律兜底。

## 踩过的坑
- 用「字节数 ≥1024」判空树是错的：旧的「1099 B 空树」实例其实是 **iOS pageSource**；真机实测 Android Flutter 空树 dump = **3418 B（3.4 KB）** > 1024 ⇒ 字节阈值**必然漏判**，判据只能数语义节点。
- `settle.sh` 的 `SLOT` 按 `SAMPLES` 奇偶轮转，**失败的那轮也递增 SAMPLES** ⇒ 只要失败分支不清 `PREV`，下一次成功采样就会 `cmp` 同路径自比、单帧判静止（review 抓到的 P1）。
- 完整性检查前移到语义检查之前后会**丢掉降级出口**（auto 模式空烧 timeout）——顺序调整必须同时补计数上限与降级/退出。
- `test_common.sh` 的全局 adb 桩 `exec-out` 只有 ~20 B，G12 必须自建 `$TMPROOT/g12bin/adb`（case-local PATH，落文件末尾，不污染 G1–G11）。
