# 复审报告 · 空框 hint 哨兵探测 + `--editable-index`（第 2 轮）

> 落档说明：同上，`review` 子代理无 `docs/` 写权限，本文件由主会话按其返回正文整理。
> 复审对象：修完第 1 轮 P1/P2 后的未提交工作区 diff（同一 7 文件）。

## 限制声明

本子代理无命令执行权限，未能实跑 `test_interact.sh`；「可红性 / 存量断言未回归」类结论为静态推演。
主会话随后实跑补齐：`test_interact.sh` 132 项 rc=0，`test_all.sh` 七项 rc=0。

## 逐条核销

| 上一轮问题 | 结论 | 依据 |
|---|---|---|
| [P1] editable 分支零身份校验 | **已核销（带可接受残留）** | `input.sh` 读回新增数量门；三条读回路径共用（`--clear-only` / `--text` / 重试重定位）均传 `EDIT_IDX`+`EDIT_TOTAL`；与关键词分支 `total==1` 兜底同口径 |
| [P2] `--editable-index <1` 守卫 | **已核销** | shell 数字校验 rc=2 + python 守卫 + 越界 rc=1 附候选 |
| [P2] `hint_verdict` 大小写 | **已核销**，但引入新窄缝（见 N-1） | `casefold()` 双处比较；纯函数断言补大写哨兵 |
| [P2] 测试缺口（哨兵循环 / hint×editable） | **已核销** | `AB_REJECT_ALPHA` 驱动 a→1 兜底；hint×editable 组合用例 |
| [P2] probe 发键前焦点复检 | **半核销**（见 N-2） | 字面已加，但 `focus_ok` 只测 IME 显示，测不出「焦点跳到别的框」 |
| [P3] probe 内 rc=4 折叠成 5 | **未核销**（本轮未主张修复） | probe 内读回失败统一 `return 1`，主流程再映射成 5 |
| [P3] `--actual` 前导 `-` | **已核销（probe 路径）**；同类残留见 N-3 | 改用 `--actual=` / `--probe=` / `--sentinel=` |
| [P3] `--bounds` × `--editable-index` 互斥 | **已核销** | python 层拒绝 |
| [P3] 头部退出码注释 | **已核销** | 补 `--hint-verdict` 的 0/1/3 |
| [P3] `probe_hint_only` 第 5 参未命名 | **已核销** | 改为 `want_edit` / `want_etotal` |

## 本轮新发现问题

### [P2] N-1 `hint_verdict` 判定顺序 —— 「哨兵没进去」必须优先于「读回等于哨兵」

`casefold()` 之后新增的窄缝：若框内原本残留的**恰好就是哨兵字符**（单字符 `a` / `1`），而哨兵因只读或
输入类型不匹配没进去，则 `probe == after == sentinel`，先比 `sentinel` 会判 0（空）⇒ 假绿。
⇒ 必须让 `probe == after → 3（无法判定）` 优先。

### [P2] N-2 焦点复检的判据强度

`focus_ok` 依据 `dumpsys input_method` 的 `mInputShown`，只能证明「有 IME 在显示」，不能证明目标是同一个框。
属可接受弱判据（比没有强），但结论里不得把「probe 成功」说成「确认焦点在目标框」。

### [P3] N-3 其余位置参数仍用空格形式

`--verify --expect "$TEXT" --actual "$ACTUAL"`、`--plan-clear "$REDO_PLAN"` 仍可能被以 `-` 开头的值骗过；
另 `--index` 与 `--editable-index` 同用会静默失效（应显式拒绝）。

## 结论

**有条件通过** —— 必修 N-1（`hint_verdict` 判定顺序）；N-3 建议同轮处理。

## 处置

- N-1 已修：`probe == after` 判定提到 `probe == sentinel` 之前，并补纯函数用例
  （`hint_verdict("1", "1", "1") == 3`）。
- N-3 已修：`--verify`/`--expect`/`--actual`、`--plan-clear` 改等号形式；
  `--editable-index` 与 `--index>1` 直接 rc=2 互斥。
- N-2 保留为已知弱判据，写进 `input.sh` 注释与坑表，不当作强证据。
- P3「probe 内 rc=4 折叠成 5」列为已知遗留（对外仍稳定 rc=5，诊断信息在 stderr）。