# 2026-11 · debug-loop 遗留项收敛 + iOS 沙箱回退（已归档）

> 原件：`plan/20261027-debugloop-next.md`（193 行）+ `.review.md`（206）、`review/debugloop-next.md`（98）+ `.r2.md`（62）、`review/20261104-ios-sandbox-fallback-appium-pointer.md`（75）+ `.r2.md`（44）。baton 现记「未完成：无」「下一步：无必做项」。

## 一、2026-10-27 四项遗留收敛（第 3 版）

**范围**：判据 + 状态机 → `settle` → `findtap` → 桩用例 → 模板 → 文档下沉；改 4 个脚本（3 业务 + 1 测试）。

**关键裁定**：
- `--mode` 默认 `auto`；`(采样状态 × mode) → rc` 逐位定义，与 `bg.sh` 的 rc=3（LOST）区分。
- 降级分支加**剩余预算感知**：剩余 < 单帧成本（10 s）即降级并注明「预算耗尽，未达连续 2 次」；`--timeout` 默认 25。
- `ui_has_semantics` 输出非负整数、**永不非零返回**（`grep -a` + `tr -dc '0-9'`，调用方 `${N:-0}`）。
- `findtap` 失败 = **rc=1**（不改调用方分支）。
- 桩用例 G12 落 `test_bg.sh` 末尾、case-local PATH 前置（防污染 G1–G11）。

**验收**：`test_bg.sh` **215 项全通过**；真机 settle（auto/screen/ui）均 rc=0；findtap 两屏命中（`Display`→(248,1960)、`About phone`→(308,1875)）；auto 降级链路真机走通（语义树 0 节点 → 像素比对 → rc=0）。

**审查链**：R1 **需修改**（1 条 P1 假阳性回归 + 3 P2 + 4 P3）→ R2 **有条件通过**（1 P2 + 3 P3）；重审次数用尽，改用 G12 用例 + 真机冒烟兜底。

## 二、2026-11-04 iOS 沙箱回退 Appium 指针

- R1 **有条件通过**（无 P1 阻断，P2×5 建议随轮修，P3 可选）→ R2 **通过（LGTM）**：5 条 P2 均已真实修复，无功能性回归。

## 三、现状与遗留

- 全部落地并提交（`~/Projects/debug-loop-skill`）；baton 无必做项。
- 仍开放（均非本线欠账）：`bundle.sh` 证据包 / MCP 化（须先确认需求）；`screen` 模式在 FLAG_SECURE/息屏下可能假「静止」（设计边界，靠 `判据=screen` 缓解）。
