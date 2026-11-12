# 复审报告 · 多设备选择（`ANDROID_SERIAL`）+ 探测阶段 rc=4 透传（第 2 轮）

> 落档说明：同上，`review` 子代理无 `docs/` 写权限，本文件由主会话按其返回正文整理。

## 核销结果

| 上一轮 | 结论 | 依据 |
|---|---|---|
| P1#1 测试假绿 | **已核销** | 阈值 5 + 「探测阶段」+ 「不得出现清空后无法读回」双向钉死出口；回退透传或回退外层块都会红 |
| P1#2 ambient `ANDROID_SERIAL` | **已核销**（遗留 P3，已在 r3 修） | 4 个套件顶部 unset；`test_safe_run`/`test_build_metrics`/`test_ios_common` 不涉 adb，无遗漏 |
| P1#3 文档超出实现 | **已核销** | `resolve_device(android)` 采纳同一优先级；快照/点击脚本经 `require_device` 自然生效 |
| P2#4 `.debug.env` 不生效 | **已核销** | SKILL.md 引用块 + troubleshooting 行内 + `_common.sh` 注释三处齐 |
| P2#5 rc=4 文案反事实 | **已核销** | 改为「上一次读回仍有内容，重取后仍空」+ 哨兵残留提示（`rb=4` 时 DEL 不执行，提示真实） |
| P2#6 glob 展开 | **已核销** | 改为 `case` 整词匹配（后续 r3 再收紧为逐行逐字比对） |
| P3 echo 出口 | **部分核销** | 当时只改了 `ANDROID_SERIAL` 分支（见阻断 1） |
| P3 口径统一 | **部分核销** | `maestro/_common.sh` 注释谎称复用（见阻断 2） |
| P3 `adb devices >&2 \|\| true` | **已核销** | 两处均加 |
| P3 rc=4 未 `log_interact` | **未核销（可接受）** | 与既有 rc=5 / rc=7 口径一致，不阻断 |

口径回归核查：`awk 'NR>1 && $2=="device"'` 与旧 `grep -w "device$"` 对 `unauthorized`/`offline`/CRLF 语义一致，
唯一消费者 `require_device` 无回归。

## 本轮新发现（均为必修/可选，无 P0/P1）

- **[P2 阻断] `_common.sh` 首台回落路径仍 `echo "$device"`**：主张说「成功出口改 printf」只改了 `ANDROID_SERIAL` 分支。
  → 已改 `printf '%s\n'`。
- **[P2 阻断] `_common.sh` 注释对 maestro 的契约不实**（「都按它」，实际 maestro 独立解析且不校验在线）。
  → 注释改为「本文件内只此一处；改口径需同步 maestro/_common.sh」，并在 maestro 侧写明「不校验在线，由 Maestro 报错」。
- **[P3] `case` 模式右侧变量可能被当通配符**（`ANDROID_SERIAL='*'` 有误判风险）。
  → 改为 `while IFS= read -r` + `[ "$d" = "$ANDROID_SERIAL" ]`（here-string，无子 shell、无 glob）。
  实测：`ANDROID_SERIAL='*'` ⇒ rc=1「不在线」，不再误匹配。
- **[P3] `test_all.sh` 未兜底 unset** → 已加（防御纵深）。
- **[P3] `maestro` 新分支无测试、指定不在线号时失败延后** → 注释写明，接受（Maestro 自报错，非静默换机）。
- **[P3] probe 内 `rb=4` 时先打「无法判定…」再让上层给确定诊断，stderr 自相矛盾** → 已把 rc=4 判断提到警告之前。

## 结论

**有条件通过**（必修 2 项）→ 两项均已按上述修复，门禁与真机复测由主会话补跑：
`test_common.sh` 120/120、`test_interact.sh` 137 项、`test_all.sh` 全绿；
`ANDROID_SERIAL` 三态实测（默认=真机 / 指定模拟器 / 指定不存在或 `*` ⇒ rc=1）全部符合预期。