# debug-loop 遗留项收敛方案（2026-10-27，第 3 版）

**结论**：四项遗留按「判据+状态机 → settle → findtap → 桩用例 → 模板 → 文档下沉」落地。第 2 版审查（有条件通过，P0/P1/P2/P3=0/3/6/7）新增的 3 条 P1 已在本版闭合：**降级分支的时间预算**、**（采样状态 × mode）→ rc 状态机**、**fail 路径的可验收性**。改 4 个脚本（3 业务 + 1 测试）+ 4 个 references（3 新 1 改）+ SKILL.md。

> 重审次数已达上限（第 1 轮 + 第 2 轮）⇒ 本版不再送审，改为「G12 用例 + 真机冒烟」兜底。

## 0. 第 2 轮问题核销

| 条目 | 处置 |
|---|---|
| N-1 降级分支不可达 | 加**剩余预算感知**：每帧前算剩余预算，`剩余 < 单帧成本(10s)` ⇒ 立即降级/返回并注明「预算耗尽，未达连续 2 次」；`--mode auto` 默认 `--timeout 25`（命令表同步写明）；G12 加用例 8/9 |
| N-2 状态机未闭合 | §3 增组合表 + `--mode` 默认 `auto` + rc 逐位定义（含「settle 的 3 ≠ `bg.sh` 的 3=LOST」） |
| N-3 无 fail 用例 | G12 增用例 8/9/10 |
| N-4 `wda_prepare` 静默消失 | 摘要**写死必备名单**；§7 拆两条独立 grep |
| N-5 返回契约未定义 | `ui_has_semantics` 输出非负整数、**永不非零返回**、`grep -a` + `tr -dc '0-9'`、调用方 `${N:-0}` |
| N-6 桩 PATH 污染 G1–G11 | case-local 前置（仿 `test_bg.sh:653`）、G12 落文件**末尾**、6 动词清单、`pull` 按 remote→local 映射 |
| N-7 文案与断言不一致 | §3 给 4 条固定文案，G12 只匹配稳定短子串 |
| N-8/N-9/N-11 | 脚本数改 4；设备侧固定 `/sdcard/ui_settle.xml`；1099 B 标注为 iOS pageSource；Android 空树体积未实测 |
| N-10 rc 取值 | **裁定 findtap 失败 = rc=1**（不改调用方分支），删除「待裁决」 |
| N-12 同源断言空转 | 断言改为「grep 模式串与 `ui.sh` awk 正则字面一致」；§6 登记「返回值为属性出现次数，非节点数」 |
| N-13 项数推导 | §7 写「基线 52 + G12 ≥12」；循环串保留「修复后重走同一序列」 |
| screencap 漏 `-p` | 写死 `screencap -p`（对齐 `shot.sh:13`），否则得到 8 MB 原始 RGBA、帧不可 `Read` |

## 1. 目标

**做**：① `settle.sh` 消除 Flutter 空树假阳性（三态 + 像素降级）；② `findtap.sh` 语义树为空快速失败（rc=1）；③ SKILL.md 的 macOS/Appium 细节下沉；④ 两者接入复现循环与 Maestro 片段。
**不做**：MCP 化、`bundle.sh`、改 maestro/appium 脚本、改 `bg.sh`/`test_bg.sh` 契约、Windows 补测。

## 2. 现状与依赖

`settle.sh` 只比 dump 的 md5（空树两次相同 ⇒ 秒判静止，单帧上限 10s）；`findtap.sh` 在 `ui.sh` 恒空时滑满 `--max` 才报错；`ui.sh` 失败**不清理旧 `ui.xml`**；`flow.sh` 透传任意 YAML。依赖：`_common.sh` 判据 → settle → findtap → G12 → 模板 → 文档。

## 3. 状态机与固定文案

采样三态：`ok_has_semantics` / `ok_empty` / `fail`（由 `uiautomator dump` 退出码区分，不靠字节猜）。

| 状态 × mode | 行为 | rc |
|---|---|---|
| ui · `ok_has_semantics` · 两帧同且 ≥256 B | 成功 | **0** |
| ui · `ok_empty` · `auto` | 打印切换 → 转 screen | 续跑 |
| ui · `ok_empty` · `ui` | 判定不可信 | **3** |
| ui · `fail` · `auto` | 重试；连续 2 次或预算不足 ⇒ 降级 screen（打印降级文案） | 续跑 |
| ui · `fail` · `ui` | 连续 2 次或预算耗尽 | **3** |
| screen · 两帧同且 ≥1024 B | 成功 | **0** |
| screen · 两帧异/0 字节，直至超时 | 未静止 | **1** |

rc 定义：`0` 静止（输出必带判据）／`1` 超时未静止或降级后仍不静止（⚠️ 文案，非 ❌）／`2` 用法错／`3` 判定不可信（仅 `--mode ui`）。`--mode` 默认 `auto`。

固定文案（G12 逐字引用短子串）：
- 切换：`ℹ️ 语义树无内容（0 个 text/desc 节点），改用整屏像素比对（每帧约 1s，必要时 --timeout ≥ 15）`
- 降级：`ℹ️ uiautomator dump 连续失败/预算耗尽，降级整屏像素（这是 dump 失败，不是页面为空）`
- 成功：`✅ UI 已静止（判据=ui|screen，两帧 N B，耗时 Xs，采样 K 次）`
- 超时：`⚠️ UI 在 Ns 内未静止（判据=…）` + 三分支提示（曾 auto→screen ⇒ `assert.sh` 轮询/`shot.sh` 双帧/`logwatch.sh`，**不建议** `--mode ui`；纯 screen ⇒ `--timeout ≥ 15`；纯 ui ⇒ 检查设备）

## 4. 实现

### 4.1 `scripts/android/_common.sh`
新增 `MIN_DUMP_BYTES=256`、`SETTLE_MIN_PNG_BYTES=1024`、`ui_has_semantics() <file>`：`grep -a -o '[[:space:]]text="[^"]'|content-desc` 计数相加，`|| true` + `tr -dc '0-9'`，**永不非零返回**；文件缺失/空/含 NUL ⇒ 输出 `0`（调用方按 `fail` 或 `ok_empty` 自行归类）。不用 `readonly`（G9 式重复 source）。

### 4.2 `scripts/android/settle.sh`
`--mode auto|ui|screen`、`--timeout 25`（auto 默认）、`--interval 0.4`、`--keep`。`_sample_ui()` 输出 `ok|fail <字节数>`，设备侧固定 `/sdcard/ui_settle.xml`（不得回用 `/sdcard/ui.xml`，与 `ui.sh` 互踩）；`_sample_screen()` 用 `exec-out screencap -p` 写 `.settle_$i.png`。判定按 §3；`rc≠0` 保留两帧并打印路径+字节数，`--keep` 时 rc=0 亦保留。

### 4.3 `scripts/android/findtap.sh`
首轮 `ui.sh` **rc=0** 后 `ui_has_semantics "$LOG_DIR/ui.xml"` = 0 ⇒ `❌ 语义树无内容` + 三级降级（`maestro/tap.sh` → Vision → `shot.sh`+坐标），**rc=1**；`ui.sh` rc≠0 仍走原重试分支。

### 4.4 `references/troubleshooting.md`（改）
第 34 行**判定列**（「两次空 dump 哈希相同」已不适用）与处置列同改：新实现已内置像素降级；仍误判时用 `--mode screen` 并核对两帧字节数。补 `--mode`/rc=3 语义。

### 4.5 `references/macos-smart.md`、`references/appium-ios-device.md`（新）
承接 `SKILL.md:246-263` / `265-304` 全文，各加「何时必读」。

### 4.6 `SKILL.md`
两段各替换为 4 行摘要：定位句 + **必备命令名**（macOS：`smart_tap/smart_assert/click`；Appium：`doctor/source/tap/assert/flow/wda_prepare/wda_sign`）+ 指针 + 「首次使用必读」。Appium 摘要固定保留 ⚠️「会触发设备自动注册/占年度额度；需 `IOS_TEAM_ID`；debug 包 JIT 受限」，并补进「先分类再改码」签名行。「Android UI 复现循环」改为 `run.sh → settle.sh → (maestro/tap.sh | findtap.sh) → settle.sh → assert/shot.sh → logclear.sh → 操作 → logs.sh`，**保留**「修复后：build.sh → run.sh → 重走同一序列 → logs.sh 验证」。命令表更新 settle（`--mode`、rc=3、默认 timeout 25）与 findtap（快速失败 rc=1）。行数：417−18+4−40+4+循环/命令表 ≈6 ⇒ ≈373，阈值 ≤378，验收用实测 `wc -l` 回填。

### 4.7 `scripts/test_common.sh`（G12，落文件末尾）
case-local 前置 `STUB_DUMP_FAIL=… STUB_PNG_BYTES=… PATH="$TMPROOT/g12bin:$PATH" bash <脚本>`（**不**全局 export）；桩动词：`devices`、`shell uiautomator dump`、`shell wm size`、`shell input tap|swipe`、`pull`（remote→local 映射）、`exec-out screencap -p`，未识别动词 `exit 0` 兜底。用例 12 条：①ui+`ok_empty`+≥1024 ⇒ rc=3；②auto+`ok_empty` ⇒ 含「改用整屏像素」且 rc=0；③screen+`STUB_PNG_BYTES=0` ⇒ rc=1（不得静止）；④ui+有语义两帧同 ⇒ rc=0；⑤`--interval 0` ⇒ rc=2；⑥findtap+空语义 ⇒ rc=1 含「语义树」；⑦findtap+有语义 ⇒ rc=0；⑧`STUB_DUMP_FAIL=1`+`--mode ui` ⇒ rc=3 且含「dump 失败」、**不含**「语义树无内容」；⑨`STUB_DUMP_FAIL=1`+auto+`--timeout 3` ⇒ 含「降级整屏像素」；⑩findtap+`ui.sh` rc≠0 ⇒ 走重试、输出不含「语义树」；⑪dump <256 B ⇒ 不判静止 rc=1；⑫含 NUL 的畸形 dump ⇒ `ui_has_semantics` 输出整数不崩。另加源码级断言：`_common.sh` 的 grep 模式串与 `ui.sh` awk 正则字面一致。

### 4.8 `references/maestro-flow-snippets.md`（新）
片段①（整流程冒烟/冷启动）`launchApp` + `waitForAnimationToEnd: {timeout: 5000}` + `tapOn` + `assertVisible`；片段②（**复现既有状态**，无 `launchApp`）shell 序列 `run.sh → settle.sh → tap.sh → settle.sh → shot.sh`。注明：首行不写 `appId:`（`flow.sh` 注入）、不以 `---` 开头；`waitForAnimationToEnd` 超时**仍算成功**（截至 2026-10 官方文档，以 `maestro --version` 为准），要断言动画结束用 `assertVisible` 轮询或 `settle.sh`。

## 5. 实施顺序

1. 快照 `cp -r <skill 绝对路径> ~/debug-loop-snap-20261027/` + `shasum -a 256` 记录；恢复用**逐文件 cp 回**。
2. `_common.sh`（常量 + 函数 + 契约）
3. `settle.sh`（状态机 + 预算感知）→ 真机三模式
4. `findtap.sh`（rc=1 快速失败）→ 真机 Settings 回归
5. G12（先桩后断言）→ `test_common.sh` 全绿
6. 模板 + 循环图 + 命令表
7. 下沉 + 摘要 + troubleshooting 同批改
8. 全量：`test_bg.sh`(215) + `test_common.sh` + `wc -l SKILL.md`

## 6. 边界

- **期限与预算**：单帧 dump 上限 10s（`settle.sh:34` 既有）；auto 默认 25s，仍可能不足 ⇒ 输出「预算耗尽」，不谎报静止。
- **FLAG_SECURE/息屏**：截图全黑但达标 ⇒ 可能假静止（已知边界）；rc=0 必带「判据=screen」。
- **`ui_has_semantics` 口径**：返回**属性出现次数**（同节点 text+desc 计 2），非 `ui.sh` 的「可点击节点数」；两者不可互相当基准。
- **单帧成本上升**：`dump+pull` 与 `screencap -p` 各约 1 帧/0.5–10s；auto 仅在 ui 不可用时启用，默认路径不变。
- **被否决备选**：默认 screen（黑屏假阳性 + 每帧 0.5–1s）／复用 `ui.sh` 单次采样（抢设备侧 `/sdcard/ui.xml`）／语义阈值 >1（极简原生页误降级）。
- **findtap 失败码 = rc=1**（已裁定）；若改 3 需同批改 `tap.sh` 注释、命令表、G12、troubleshooting 四处。
- subagent 可达性不变（`scripts/*` 白名单内；脚本内部重定向不受限）。

## 7. 验证

| 项 | 命令 | 通过标准 |
|---|---|---|
| 语法/多字节 | `test_bg.sh -f 静态` | 全绿（`${VAR}` 紧跟中文标点；`$(wc -c < f \| xargs)` 裁剪） |
| 单元回归 | `test_common.sh` | **基线 52 + G12 ≥12 ⇒ ≥64**，全绿 |
| 全量回归 | `test_bg.sh` | 215 项全绿（G12 落 test_common，语法组按 1 项计） |
| 空树反例 | G12 用例①② | `--mode ui` rc=3；auto 打印切换且不以 ui 判静止 |
| fail 反例 | G12 用例③⑧⑨⑩ | 0 字节不静止；dump 失败不称「语义树无内容」 |
| 真机 | `settle.sh` / `--mode screen` / `--mode ui` | Settings 页 rc=0 / rc=0 / rc=0 |
| 真机 findtap | `"Display"` / `"About phone"` | rc=0 且输出含命中屏号与坐标 |
| 文档完整性 | `grep -c 'smart_tap' SKILL.md`；`grep -c 'wda_prepare' SKILL.md`；`grep -c '该判定\*\*不可信' troubleshooting.md` | 前两条各 ≥1 且指向新 reference；第三条 = 0 |
| 体积 | `wc -l SKILL.md` | ≤378（实测回填） |

### 7.1 实测结果（2026-10-27 执行）

| 项 | 实跑结果 |
|---|---|
| `test_bg.sh`（全量） | `✅ 全部通过：215 项`（多次，修复前后各一次） |
| `test_common.sh` | `通过: 92 / 92`（基线 52 + G12 40 条；最终版比计划的 ≥64 多出 28 条，因两轮 review 追加了 ⑬⑭⑮） |
| 真机 `settle.sh`（auto） | `✅ UI 已静止（判据=ui，两帧 24212 B，耗时 6s，采样 2 次）` rc=0 |
| 真机 `settle.sh --mode screen` | `✅ UI 已静止（判据=screen，两帧 142467 B，耗时 2s，采样 2 次）` rc=0 |
| 真机 `settle.sh --mode ui` | `✅ UI 已静止（判据=ui，两帧 24212 B，耗时 5s，采样 2 次）` rc=0 |
| 真机 `findtap.sh "Display"` | `✅ 第 1 屏命中: Display -> 坐标 (248, 1960)（文本节点非 clickable，按坐标兜底）` rc=0 |
| 真机 `findtap.sh "About phone"` | `✅ 第 3 屏命中: About phone -> 坐标 (308, 1875)` rc=0 |
| 参数守卫 | `--interval 0.` / `--interval 1.2.3` 均 `rc=2` |
| `grep -c 'smart_tap' SKILL.md` | 5 |
| `grep -c 'wda_prepare' SKILL.md` | 1 |
| `grep -c '该判定\*\*不可信' troubleshooting.md` | 0 |
| `wc -l SKILL.md` | **371**（≤378 ✓；方案预估 373） |

**未取到的实测数据（仍登记为边界）**：Flutter 未开 semantics 时 Android `uiautomator dump` 的真实体积与节点形态（本机无 Flutter 工程）；动画页 `dump` 单帧实测耗时。判据已改为语义节点计数，不依赖字节阈值，故不阻塞。

### 7.2 收尾清理（同一轮）

| 项 | 处置 |
|---|---|
| `SKILL.md:129`「152 项」旧口径 | 改 **215 项（实测 33s）**：实测 `bash scripts/test_bg.sh` 起止 33s |
| `SKILL.md:137` 声称「仓库已挂 `hooks/pre-commit`」 | 已核实 `~/.config/opencode` **不是 git 仓库**、也无 `hooks/` 目录 ⇒ 改为条件句（有钩子才自动跑静态组），并明确「钩子只覆盖静态组，行为回归必须手动跑」 |
| `SKILL.md` 命令表 settle 行 | 补「dump 持续**不完整**」这一降级/rc=3 触发条件（与 settle.sh 实际分支一致） |

### 7.3 screen 阶段诊断粒度（review 第 1 轮 P3-9 收尾）

- `settle.sh`：`_screen_sample` 的三态在调用侧真正分开 —— `screencap` 命令失败报「screencap 命令失败（第 N 次）」，截到但 <1024 B 仍报「截图无效」；新增 `PNG_OK`/`PNG_BAD` 计数，**screen 阶段一帧有效帧都没取到**时终报改为「⚠️ 整屏截图始终不可用（N 次全部失败/无效）⇒ 无法判定静止」+ 对应替代手段，**不再**报「UI 在 Ns 内未静止」（后者会把排查引向 `--timeout`）。
- `test_common.sh`：桩新增 `STUB_SCREEN_FAIL` 与 `STUB_PNG_UNIQUE`（每帧字节数递增）；G12 新增用例⑯（4 条：命令失败文案 + 终报「判据不可用」）、⑰（4 条：截图有效但持续变化 ⇒ 走「未静止」正常路径，不得误报「判据不可用」）。
- `troubleshooting.md` / `SKILL.md`：补该终报的判定与处置（别加大 `--timeout`，先 `shot.sh` 验证）。

**实测**：`test_common.sh` `rc=0` / `通过: 100 / 100`；`test_bg.sh` `rc=0` / `215 项`；真机 `settle.sh` `rc=0`（`判据=ui，两帧 31000 B`）与 `--mode screen` `rc=0`（`判据=screen，两帧 149789 B`）。

### 7.4 真机 Flutter 项目复跑（`~/Projects/sample_pro`，2026-10-27）

> 目的：补 §6 缺的「Flutter 页面单帧成本」实测，并验证裸 `settle.sh` 在真实 Flutter 工程上的行为（此前只有桩与 Settings 原生页）。

| 页面 | 命令 | 结果 | 判据 |
|---|---|---|---|
| My Devices（设备列表） | `settle.sh --keep` | `✅ 两帧 11382 B，耗时 5s，采样 2 次` | ui |
| Live（云台实时页，Retry 占位） | `settle.sh --keep` | `✅ 两帧 7364 B，耗时 5s，采样 2 次` | ui |
| Fullscreen（横屏全屏） | `settle.sh --mode screen --timeout 8 --keep` | `✅ 两帧 56726 B，耗时 1s，采样 2 次` | screen |
| Playback（回放列表） | `findtap.sh "Playback"` | `✅ 第 1 屏命中: Playback -> (898, 2110)` | — |

**单帧成本实测**：`ui.sh`（dump + pull + 解析）**2.43s**；`exec-out screencap -p` **0.42s**（56726 B）。
⇒ 与 `SETTLE_FRAME_ALARM=10` 的关系：auto 默认 `--timeout 25` 只够约 10 帧；剩余 <10s 时降级/判不可信的判据在真机上是**保守且必要**的（2 帧就要 ~5s）。

**未复现项**：该工程所有可达页面（列表 / 实时 / 全屏 / 回放）**都暴露了完整语义树**（7–11 KB dump、8–29 个 clickable 节点），因此「Flutter 未暴露语义树 ⇒ 空树」场景**在该工程上不可复现**，auto→screen 与 `--mode ui` rc=3 仍只有桩覆盖。原始 dump 大小参考值可作对照：**带语义的 Flutter 页 ≈ 7–11 KB**，远高于 `MIN_DUMP_BYTES=256`，说明该阈值只拦截断、不会误伤正常页。

**现场**：设备 `R58M00TEST1` 上 `com.example.demo` 留在 Playback 页；`sample_pro/build/debug/` 下留有 `.settle_1.xml`/`.settle_2.{xml,png}`（`--keep` 产物）与 `screen.png` 证据。

### 7.5 「空树 → 降级 / rc=3」真机验证（临时 Flutter 工程，2026-10-27）

> sample_pro 的页面都带语义，故另建**一次性最小工程**（`flutter create --platforms=android`，首屏只有一个 `CustomPaint`、零 `Text`/`Semantics`），装到 `R58M00TEST1` 后验证，验完已 `adb uninstall`。

| 项 | 命令 | 实测结果 | 说明 |
|---|---|---|---|
| 空树 dump 体积 | `ui.sh` | `共 0 个可点击节点`，dump **3418 B** | **关键数据**：空树 dump 是 **3.4 KB > 1024 B** ⇒ 旧的「字节数 ≥1024 即视为有内容」判据**一定会漏判**，这正是原缺陷；节点计数判据正确识别 |
| auto 降级 | `settle.sh --keep` | `ℹ️ 语义树无内容（0 个 text/desc 节点），改用整屏像素比对…` → `✅ UI 已静止（判据=screen，两帧 29398 B，耗时 3s，采样 3 次）`，`rc=0` | 降级链路在真机完整走通，且降级后能正常判静止 |
| 判定不可信 | `settle.sh --mode ui --timeout 5` | `❌ 判定不可信：语义树无内容（0 个 text/desc 节点）`，`rc=3`，保留 `.settle_1.xml`(3418 B) 与两帧 png | rc=3 语义在真机成立，且证据帧自动留存 |
| findtap 快速失败 | `findtap.sh "Anything" --max 3` | `❌ 语义树无内容…⇒ findtap 不可用` + 三级降级提示，`rc=1`，**未滑动** | 与「白滑 6 屏」的旧行为对比成立 |

⇒ 至此 §1 的四项目标在**真机**上都有直接证据（此前空树相关分支只有桩覆盖）。






## 8. 执行授权与裁定（2026-10-27）

- 用户确认：**按本版全部执行**（§5 八步，不停在代码部分）。
- `findtap` 语义树为空的退出码：**终裁 rc=1**（不改调用方既有分支，与 `tap.sh` 三态统一口径同族）；命令表、脚本头注、G12 三处对齐。
- 执行者：**build 档**（本方案由 planner 档产出，planner 不写代码）。交接语：
  「按 `docs/plan/20261027-debugloop-next.md` §5 顺序执行，验收以 §7 为准」。
- 执行前必做：§5 第 1 步快照（`~/debug-loop-snap-20261027/` + `shasum -a 256`）；该目录非 git 仓库，无其他回滚手段。
- 执行中若 §3 状态机与真机实测冲突（如自动降级仍不可达），以**真机事实**为准修订 §3 并同步 G12，不得为过测放宽断言。