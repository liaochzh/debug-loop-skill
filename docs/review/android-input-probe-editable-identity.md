# 审查报告 · 空框 hint 哨兵探测 + `--editable-index`（第 1 轮）

> 落档说明：审查由 `review` 子代理执行，子代理无 `docs/` 写权限，本文件由主会话按子代理返回的
> 报告正文整理（问题条目、证据引用与结论原样保留，仅省略客套段）。
> 范围：未提交工作区 diff（7 文件）。评审时点：2026-11-12。

## 审查范围

| 文件 | 改动量 |
|---|---|
| `scripts/_field_target.py` | +65 |
| `scripts/android/input.sh` | +109 |
| `scripts/test_interact.sh` | +138 |
| `SKILL.md` / `references/troubleshooting.md` / `references/autoDebug-task-template.md` / `docs/baton/debug-loop.md` | 文档同步 |

背景（评审所需事实）：真机验证暴露两个判据缺陷 ——
① 空的可编辑框 `text` 会回填 hint（实测 `text="Search settings"`），`--clear-only` 假失败 rc=5；
② Flutter 登录页输入框既无 `text` 也无 `resource-id`，无法定位与读回。
本 diff 分别用 `hint_verdict()` + 哨兵探测、`editable_order()` + `--editable-index` 修复。

## 契约核对通过项

- rc 0–8 契约未动；探测失败一律 fail-closed 到 rc=5。
- 无新增 `printf | grep -q`（SIGPIPE 误判）；`set -u` 下 `${4:-0}` 有默认值；AND-list 受 `set -e` 豁免。
- 日志不落读回值/凭据。
- 哨兵 DEL 在读回之后、判定之前无条件发出。
- `total==1` 兜底不受 editable 分支影响（该分支 `want_field=""`，不进关键词回退）。
- 文档（`SKILL.md` 命令表、rc=5 说明、坑表、baton 的 rc=5 语义纠正）与实现一致。

## 问题清单

### [P1] `scripts/android/input.sh:340-347` — `read_back` 的 editable 分支零身份校验（假绿通道）

- **证据**：同函数关键词分支（:356-368）复定位后有「同 id / 无 id 时 `total==1`」双保险并注明
  「读到别的框必须按失败处理」；新增 editable 分支在 `bounds` miss 后直接取 `plan_field editable`
  的 `current`（:370-371），无任何同节点确认。
- **触发链**：选中时为第 k 个可编辑节点；读回帧同时满足 (a) `bounds` 精确匹配失效（IME 位移 —— 正是
  本次修复的场景）、(b) 可编辑节点数变化或序号漂移（弹层搜索栏激活、Flutter 输入框收起）⇒ 第 k 个
  落到别的空框。`--clear-only` 下读回为空即 `:550` 直接判「✅ 已清空」（假绿）；`--text` 路径则按
  错误长度盲删。
- **建议**：与关键词分支同口径 —— 读回后校验「可编辑节点总数未变」，不一致即 `return 1`。

### [P2] `_field_target.py` — `--editable-index` 缺 `<1` 守卫

负数会静默取倒数节点；`hits≤1` 时触发 `IndexError`。建议 python 层与 shell 层都拒。

### [P2] `_field_target.py` — `hint_verdict` 的 `probe == sentinel` 大小写敏感

`textCap` 域名会把 `a` 渲染成 `A` ⇒ 误判「有残留」，并短路后续的数字哨兵。

### [P2] `test_interact.sh` — 测试缺口

哨兵循环的「字母被拒 ⇒ 换数字哨兵」分支、以及 hint×editable 组合零覆盖。

### [P2] `input.sh` — `probe_hint_only` 发键前无焦点复检

OTP / 输入即跳转场景下，哨兵与清理 DEL 会落到别的框。

### [P3] 若干细节

- probe 内 `read_back` 的 rc=4 被折叠成 5（与主流程合同不一致）。
- `--actual "$after"` 遇以 `-` 开头的值会被 argparse 当成选项。
- `--bounds` 与 `--editable-index` 在 python 层未拦互斥。
- 头部退出码注释未含 `--hint-verdict` 的 3。
- `probe_hint_only` 第 5 参未命名（可读性）。

## 结论

**有条件通过** —— 必须修 P1（editable 读回零身份校验）；P2 强烈建议同轮修掉。

## 处置

P1 与 P2 全部当轮修复（`editable_total` 同节点校验、`<1`/`--bounds` 守卫、`casefold()`、
`AB_REJECT_ALPHA`/`AB_ADD_EDITABLE` 桩用例、probe 入口 `focus_ok` 复检），P3 一并处理，
然后进入第 2 轮复审（见 `android-input-probe-editable-identity.r2.md`）。