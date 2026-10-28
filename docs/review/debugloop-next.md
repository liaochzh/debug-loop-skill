# debug-loop 遗留项收敛 — 代码审查（第 1 轮）

- 审查对象：`~/.config/opencode/skills/debug-loop/` 本轮 10 个文件的改动（对比基线 `~/debug-loop-snap-20261027/`）
- 审查方式：`review` 子代理，只读；已加载 clean-code 规范必检
- 执行模型：Name: Qwen3.8 Flash / Provider ID: alibaba-token-plan-cn / Model ID: qwen3.8-flash
- 依据：`docs/plan/20261027-debugloop-next.md`（第 3 版）+ 两轮方案审查报告
- 结论档：**需修改**（1 条 P1 假阳性回归 + 3 条 P2 + 4 条 P3）

---

## 一、报告原文

### 审查范围
10 文件，逐一与 `~/debug-loop-snap-20261027/` 快照对比：
`scripts/android/_common.sh`、`scripts/android/settle.sh`、`scripts/android/findtap.sh`、`scripts/test_common.sh`、`SKILL.md`、`references/troubleshooting.md`、`references/autoDebug-task-template.md`、`references/macos-smart.md`、`references/appium-ios-device.md`、`references/maestro-flow-snippets.md`

### 阻断交付的问题

**1. [High/P1] settle.sh:119-138 + 109-110 — dump 单次失败后 `PREV` 未清空 × SLOT 奇偶错位 ⇒ `cmp` 同文件自比、单帧即判「静止」**

- 触发条件：两次成功采样之间恰好夹**一次** `_ui_sample` 失败（FAILS=1 < 2 且 REMAIN≥10 ⇒ 走 sleep+continue，**不清 PREV**）。`SLOT` 按 `SAMPLES%2` 每轮翻转，失败的迭代同样递增 SAMPLES，于是下一个成功采样的 `CUR` 落回 `PREV` 指向的同一个文件；`pull` 覆写后 `cmp -s "$PREV" "$CUR"` 变成同路径自比 ⇒ 恒真 ⇒ `_done "ui"` rc=0。
- 影响：动画页 `uiautomator dump` 偶发单次 `could not get idle state`（本脚本立身场景）⇒ 输出「✅ UI 已静止（判据=ui，两帧 N B）」但实际只采到了**一帧新内容**——旧实现因 `PREV=CUR`（含空串）总被重置而天然免疫，此为**新引入回归**；autoDebug 会把动画中间帧当静止取证，即 B-2 类假阳性换路径复活。G12 六个 settle 用例全是「全成功」或「全失败」序列，**混合序列零覆盖**，故 81/81 与真机冒烟均测不出。
- 建议：fail 分支在 `sleep` 前加 `PREV=""`（与 161-163 dump 不完整分支、183 screen 分支对齐）；G12 补一条「成功→失败一次→成功且两帧不同 ⇒ 不得 rc=0」用例。

### 应修（不阻断交付）

**2. [Medium/P2] settle.sh:142-164 — 判据顺序：内容判定先于完整性判定，0 字节/截断 dump 被误称「语义树无内容」**

- `dump+pull` 返回 0 但文件 <256 B（截断拉取）时，先跑 `ui_has_semantics`=0 ⇒ 走「语义树无内容（0 个 text/desc 节点）」文案，永远到不了「dump 不完整」分支。这正是 §3 三态设计要区分的「采样失败 ≠ 页面为空」，`--mode ui` 下 rc=3 虽对、原因文案错 ⇒ 按 troubleshooting 模板指引去查 Maestro/Vision，而真问题是设备侧 dump。G12 用例⑧的 TINY_XML 带 `text="OK"` 只覆盖了「不完整但有语义」半边。建议把 BYTES 完整性检查前移到 NODES 检查之前，G12 ⑧补一个「<256 B 且无语义」夹具。

**3. [Medium/P2] test_common.sh（G12 组缺失项）— 方案 §4.7 末句与 N-12 核销承诺的「源码级同源断言」未实现**

- 计划明文「另加源码级断言：`_common.sh` 的 grep 模式串与 `ui.sh` awk 正则字面一致」，G12 十二例中没有这条。且两者本就不是字面全等（`[^"]` vs `[^"]*"`，语义等价、形态不同），按原句无法逐字落地——这更说明需要一个钉住共同锚点（`[[:space:]]text="` / `[[:space:]]content-desc="`）在两个文件中同时存在的断言，否则日后改 `ui.sh` 正则不会触发任何测试报警，判据口径静默漂移。属实施对已核销方案的偏离，应补或显式登记否决理由。

**4. [Medium/P2→实为覆盖核对说明] 验证覆盖判断**：已实跑的 81/81 与真机冒烟**确实覆盖不了**条目 1、2（前者需混合采样序列，后者需截断且无语义夹具）；其余 §4.7 列出的 12 例逐条核点均已实现且非恒真（`env` case-local PATH、桩落 `$TMPROOT/g12bin`、trap 清理、G12 置文件末尾，不污染 G1–G11；`STUB_DUMP_FAIL`、`STUB_PNG_BYTES`、remote→local `pull` 映射、6 动词兜底均符合 N-6/N-7 裁定）。

### 可选改进（P3）

**5.** `test_common.sh` — `expect_contains "G12 缺文件输出 0" "0" "$N2"` 为弱断言（输出 `10`/`20` 也过）。建议等值断言。

**6.** `settle.sh:43-44` — `--interval` 校验 `[!0-9.]` 放行 `1.2.3` 类畸形串 ⇒ `sleep 1.2.3` 失败被 `set -e` 静默截停，退出码 1 与「超时未静止」不可区分。

**7.** `settle.sh` CleanCode/G25-魔法数字 — 单帧成本 10s 双写（`alarm 10` 与 `-lt 10` 隐含同源）。改 alarm 会静默改变预算语义，建议提为 `_common.sh` 常量。

**8.** `_common.sh` CleanCode/N7-命名 — `ui_has_semantics` 名字是谓词、返回计数；改名 `ui_semantic_attr_count` 更贴切（不强求）。

**9.** `settle.sh:181-182` — screen 阶段 `STATUS=fail` 与「0 字节/截断」共用「截图无效」文案；ui 侧刻意三态分文案、screen 侧未分，诊断粒度不对称。

### 已核对无问题项

- **findtap.sh**：快速失败严格限定 `i==1` 且 `ui.sh` rc=0 分支；ui.sh rc≠0 仍走原重试（注释钉住 A-2 残留文件陷阱）；`--max`/滑动/兜底逻辑逐行比对与快照一致，无回归；rc=1 与 §8 终裁、头注、命令表、troubleshooting、G12⑨⑪ 五处口径一致。
- **`ui_has_semantics` 契约**：缺文件/空文件/NUL/无匹配路径全部 `printf 0 + return 0`；`|| true` 覆盖 `set -e`/pipefail；`tr -dc '0-9'` 净化前导空白；调用方均有兜底。G12⑫验证通过。
- **`_keep_frames`/清理**：只 glob `.settle_*.{xml,png}`，不触碰 `ui.xml`、`ui_findtap.txt`；设备侧固定 `/sdcard/ui_settle.xml` 与 `ui.sh` 的 `/sdcard/ui.xml` 隔离；`--keep`/失败保留逻辑与 §3 一致。
- **`set -euo pipefail`/多字节**：新代码所有变量紧跟全角标点处均 `${VAR}` 花括号；`$(wc -c < f | tr -dc '0-9' || true)` 形态正确。
- **文档**：SKILL.md 371 行 ≤378；必备命令名全部保留；不可逆副作用 ⚠️ 同时进了边界表（N-4/C-3 闭合）；三个新 reference 与快照 246-304 行逐行比对**无信息丢失**；片段① `launchApp` 冲突已由适用边界 + 片段②消解；troubleshooting 负向 grep `该判定` = 0；复现循环/命令表行与脚本实现一致。
- **快照回归面**：`_common.sh` 1-196 行与基线逐段一致，改动纯尾部追加；两常量未用 `readonly`（G9 重复 source 场景安全）。
- **范围外观察**（非本轮改动）：SKILL.md:129 「152 项」与实跑 215 项的旧口径漂移，建议下轮顺手回填。

### 结论
**需修改**：条目 1 是本轮目标缺陷（假阳性静止）的复发路径且属对旧行为的新增回归，修复成本一行 + 一条 G12 用例；修复后可升为「有条件通过」（条目 2、3 同批处理为最佳）。

---

## 二、按反馈的修复（本会话执行）

| 条目 | 状态 | 处置 |
|---|---|---|
| 1（P1） | **已修** | `settle.sh` fail 分支加 `PREV=""`（含原因注释，说明 SLOT 轮转导致同路径自比）；G12 新增用例⑭（`STUB_FAIL_SEQ=2` + `STUB_DUMP_UNIQUE=1`，`--timeout 12`） |
| 2（P2） | **已修** | 完整性检查前移到语义检查之前；G12 用例⑮补「<256 B 且无语义」夹具 |
| 3（P2） | **已修** | G12 新增用例⑬：`[[:space:]]text="` / `[[:space:]]content-desc="` 两个锚在 `_common.sh` 与 `ui.sh` 同时存在（2 条断言） |
| 4 | 已处理 | 由 ⑭/⑮ 补齐被点名缺失的覆盖 |
| 5（P3） | **已修** | 改等值断言 `case "$N2" in 0)` |
| 6（P3） | **已修** | 新增 `*.*.*` 拒绝；后续复审又补「无 1-9 数字 ⇒ 拒绝」覆盖 `0.`/`.0`/`.` |
| 7（P3） | **已修** | `_common.sh` 新增 `SETTLE_FRAME_ALARM=10`，`alarm` 与预算比较同源 |
| 8（P3） | 未改（PR 记录为「可接受」，口径已在注释钉死） | — |
| 9（P3） | **已修（后续收尾轮）** | screen 阶段拆三态：`screencap` 命令失败 ≠ 截到但无效；新增 `PNG_OK`/`PNG_BAD`，一帧有效帧都没取到时终报「整屏截图始终不可用」而非「未静止」；G12 ⑯⑰ 覆盖 |

### 用例⑭ 非空转验证（实测）

把 `settle.sh` 的 `PREV=""` 一行删掉后，用同一夹具跑：

```
rc=0
已静止出现次数: 1
⚠️  uiautomator dump 失败（第 1 次）
✅ UI 已静止（判据=ui，两帧 3428 B，耗时 1s，采样 3 次）
```

带修复的真实脚本：

```
rc=1
已静止出现次数: 0
⚠️  uiautomator dump 失败（第 1 次）
⚠️  UI 在 12s 内未静止（判据=ui，已采样 38 次，耗时 12s）
```

⇒ 断言具备区分力，不是恒真。
