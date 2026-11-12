# 审查报告 · 多设备选择（`ANDROID_SERIAL`）+ 探测阶段 rc=4 透传（第 1 轮）

> 落档说明：审查由 `review` 子代理执行，子代理无 `docs/` 写权限，本文件由主会话按其返回正文整理。
> 范围：未提交工作区 diff（6 代码/测试 + 2 文档）。评审时点：2026-11-12。

## 背景（改动动因，实测事实）

1. 本机同时在线 `ZY22GT4HNG`（真机，`adb devices` 首台）与 `emulator-5554`（模拟器）。`require_device`
   取首台，而 skill 全线用 `adb -s $DEVICE` ⇒ adb 自身的 `ANDROID_SERIAL` 约定不生效，整套脚本打到真机。
2. `--clear-only` 的哨兵探测阶段若语义树为空，`read_back` 的 rc=4 被折成「清空失败 rc=5」，
   把排障引向 IME 掉字。

## 结论

**有条件通过**（原报告未给 LGTM，必修项见下）。

## 必修（阻断）

### [P1#1] `test_interact.sh` 的 I3 用例打不到新增分支（假绿）

`snapshot.sh` 每次 dump = 2 次 `adb pull`；`input.sh` 不传 `--single-dump`。因此
`AB_EMPTY_FROM_PULL=3` 让**外层** `read_back` 就拿到空树 ⇒ 命中既有 `exit 4`，永远进不到 probe。
把 probe 的 rc=4 透传整段删掉，用例照样绿。
→ 修：阈值改 5，断言加「探测阶段」与「不得出现『清空后无法读回』」。

### [P1#2] 套件对 ambient `ANDROID_SERIAL` 不设防

`_common.sh` 读继承环境；开发机 export 过该变量（正是本次动因场景）⇒ 所有 adb 桩用例集体变异，
`AB_NO_DEVICE=1` 的断言文案也错配。
→ 修：四个涉 adb 桩的套件顶部 `unset ANDROID_SERIAL`。

### [P1#3] 文档「全脚本生效」超出实现

`maestro/_common.sh` 的 `resolve_device()` 不读 `ANDROID_SERIAL` ⇒ 多设备下 `input.sh` 与 `maestro/flow.sh`
会打不同设备，断言与输入分裂（静默假绿）。
→ 修：`resolve_device(android)` 采纳同一优先级。

## 应修

- **[P2#4]** `ANDROID_SERIAL` 写进 `.debug.env` 不生效（`_env.sh` 未知键 warn+忽略），文档未提示。
- **[P2#5]** rc=4 文案「重取后仍空」与事实不符（上一次读回明明有内容）；且 `rb=4` 时哨兵 DEL 不执行，
  框内可能残留 1 个字符，输出未提示。
- **[P2#6]** `for d in $online` 除分词外还做 pathname expansion（`ANDROID_SERIAL` 与展开后的文件名同名会假通过）。

## 可选（P3）

成功出口用 `echo`（`-n`/`-e` 设备号被吞）；两套 `adb devices` 解析口径；`adb devices >&2` 未 `|| true`；
rc=4 出口未 `log_interact`（与既有 rc=5/rc=7 口径一致，可接受）。

## 待核实（报告标注，不据以定性）

- `input.sh` 内 `[ "$rb" -eq 0 ] && [ "$probe_after" != "$after" ]` 在函数体 `set -e` 之后的 errexit 豁免是否成立
  （本次主会话已在调用点实测踩到同形问题并修，函数体内该式为 if 体内命令，实测用例通过）。
- 每条结论基于「每次 `snapshot.sh` = 2 次 pull」的静态推断（主会话随后实测确认：阈值 3/4 命中校验阶段出口，
  阈值 5 命中探测阶段出口）。

## 处置

必修 3 项 + 应修 3 项全部当轮修复，P3 修 3 项（printf 出口、口径统一、`|| true`），随后进入第 2 轮复审
（见 `.r2.md`）。