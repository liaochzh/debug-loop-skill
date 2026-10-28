# debug-loop 遗留项收敛 — 代码审查（第 2 轮复审）

- 审查对象：第 1 轮 P1/P2/P3 的修复（`scripts/android/settle.sh`、`scripts/android/_common.sh`、`scripts/test_common.sh`）
- 审查方式：`review` 子代理，只读
- 执行模型：Name: Qwen3.8 Flash / Provider ID: alibaba-token-plan-cn / Model ID: qwen3.8-flash
- 结论档：**有条件通过**（1 条 P2 行为回归 + 3 条 P3）

---

## 一、报告原文

### 核销表

| # | 上轮条目 | 状态 | 证据 |
|---|---|---|---|
| 1 | [P1] fail 分支清 PREV | ✅ 闭合 | `settle.sh:126` `PREV=""`（含原因注释:123-125）；降级分支、不完整分支、screen fail 同步清理。槽位轮转下自比路径已断 |
| 2 | [P2] 完整性先于语义 | ⚠️ 部分闭合 | 顺序已前移，⑮ 夹具已补；但前移后产生新行为回归，见 N-1 |
| 3 | [P2] 同源断言 | ✅ 闭合 | `test_common.sh:441-447`；`[[:space:]]text="` / `[[:space:]]content-desc="` 在 `ui.sh:51-52` 与 `_common.sh:219-220` 均字面存在，断言不会假绿 |
| 4 | [P3] 弱断言改等值 | ✅ 闭合 | `case "$N2" in 0)` 等值匹配 |
| 5 | [P3] `1.2.3` 校验 | ✅ 主案闭合 | `*.*.*` 拒绝；残余边缘见 N-2 |
| 6 | [P3] 10s 双写 | ✅ 闭合 | `_common.sh:206` 单点定义；`settle.sh:53`（alarm）与 `:128`（预算）同引用。`"alarm ${SETTLE_FRAME_ALARM}; exec @ARGV"` 中 `@ARGV` 不被 bash 展开，bash 3.2 下安全；alarm 随 exec 存续并杀死 adb 本体 |
| 7/8 | P3 未改 | ✅ 声明不处理 | 与改动说明一致 |

用例⑭ 非恒真复核：`c` 计数经 `rm -f cnt` 钉定 sample2 命中失败；sample2 时 elapsed≈0-1s，REMAIN≥10，不触发预算/降级分支；即便抢占，mode ui 下会得 rc=3 使期望 rc=1 **响亮失败**而非静默恒真。

### 新增条目

**[P2] N-1 settle.sh:149-154 — 完整性前移后，「dump 成功但持续 <256B」丧失降级/不可信出口（行为回归）**

- 触发条件：`uiautomator dump` 命令退出 0 但产出 0 字节/截断文件（桩路径 `STUB_DUMP_FILE` 为空即复现；真机部分 Flutter 场景可复现）。
- 影响：上一版语义检查在前，此类 dump ⇒ NODES=0 ⇒ **auto 立即降级整屏像素**（可 rc=0）、**ui 即时 rc=3 判定不可信**。前移后此分支只 `PREV=""; sleep; continue`，无计数、无降级、无 rc=3：auto 模式空烧整个 timeout 永不调用像素判据（功能性倒退）；终报走 `判据=ui` + 「页面可能仍在动画/加载：先 shot.sh」——恰是把排查引向错误方向的文案。
- 建议：不完整分支复用 fail 分支同款判定——连续 ≥2 轮不完整或 `REMAIN < SETTLE_FRAME_ALARM` 时，auto ⇒ 降级 screen（文案「dump 持续不完整」）、ui ⇒ exit 3。

**P3**
- **N-2** `settle.sh:43-45` `--interval` 校验仍放行 `"0."` / `".0"`（绕过「防忙等」）及 `"."`（sleep 用法错误，set -e 下以非 2 的 rc 崩溃）。
- **N-3** 用例⑭未断言「失败确实发生」：未来桩计数错位时，靠 `STUB_DUMP_UNIQUE` 依然 rc=1 绿——回归网静默失效。建议补 `expect_contains "dump 失败（第 1 次）"`。
- **N-4** `settle.sh:128-132` mode ui 下单次瞬时失败 + 预算 <10s 即报「dump **持续**失败」exit 3——未重试就宣称"持续"，短 timeout 下文案误导。

### 结论
修复 N-1（含⑮期望同步）后即可转「通过」；上轮 P1 的假阳性路径已确认关闭，无复发。

---

## 二、按反馈的修复（本会话执行）

| 条目 | 状态 | 处置 |
|---|---|---|
| N-1（P2） | **已修** | 不完整分支改为复用 fail 分支语义：`FAILS++`，连续 ≥2 次或 `REMAIN < SETTLE_FRAME_ALARM` 时 auto ⇒ 降级 screen（文案「持续不完整/预算耗尽」）、ui ⇒ rc=3；`FAILS` 归零点下移到「拿到完整且有语义的帧」之后（首次实现时归零位置错误，导致计数恒为 1、被 G12 ⑧ 抓到并修正） |
| N-2（P3） | **已修** | 新增 `case "$INTERVAL" in *[1-9]*) ;; *) 拒绝` ⇒ `0`/`0.`/`.0`/`.` 全部 rc=2 |
| N-3（P3） | **已修** | 用例⑭补 `expect_contains "G12 混合序列确实发生 dump 失败" "dump 失败（第 1 次）"` |
| N-4（P3） | **已修** | 预算不足但未重试时报「dump 失败且剩余预算不足，未能重试（可加大 --timeout）」，不再宣称「持续」 |
| 9（上轮 P3，screen 文案不对称） | **已修（收尾轮）** | screen 阶段拆三态 + 「判据不可用」终报；见 `docs/plan/…-next.md` §7.3 |

### 修复后新增/调整的 G12 用例

- ⑥ `dump 持续失败：--mode ui` 的 `--timeout` 3→12（让「连续 2 次失败」先于「预算不足」触发，验证的是「持续」分支）
- ⑧ 改为 `--timeout 12`，期望 `rc=3` + 同时含「dump 不完整」「持续不完整」，且**不含**「语义树无内容」
- ⑮ 改为 `--mode auto` + `STUB_PNG_BYTES=4096`，期望降级后 `rc=0` 且 `判据=screen`（覆盖 N-1 打回的功能路径）

### 复审结论的落地状态

N-1 已按报告建议修完；N-2/N-3/N-4 一并修完。因 review 轮次已达上限（2 轮），修复后未再送第 3 轮，改由 `test_common.sh` 92/92、`test_bg.sh` 215 项、真机冒烟与「删 `PREV=""` 复现 rc=0」对照实验兜底。
