# 审查报告（第 1 轮）：iOS 沙箱降级 + 真机枚举回退 + Appium 坐标/退后台

- 日期：2026-11-04
- 范围：`/Users/lcr/Projects/debug-loop-skill` 工作区**未暂存**的 10 个文件（上一轮会话遗留、本轮补提交前审查）
- 方式：静态阅读 `git diff -- scripts references` + 定向 grep 核验调用方（未跑测试，调用方已跑全套绿测）
- 结论：**有条件通过**（无 P1 阻断，P2×5 建议随本轮修，P3 可选）

> 说明：审查由 review 子代理执行，其会话对 `docs/review/` 无写权限，报告由调用方代存。

## 正面事实

`git show HEAD:scripts/ios/run.sh` 已调用仅在未暂存 `ios/_common.sh` 中定义的 `resolve_ios_app_name` /
`ios_syslog_line_re`（run.sh:34-35）⇒ 公开仓当前 `run.sh --device` 处于**悬空引用**状态，本轮应尽快补提交。

## rc 契约核验（均通过）

- `_ios_device.sh` 无设备 rc=1：调用方 `doctor.sh:170`、`appium/doctor.sh:49`、`appium/_common.sh:147`、
  `resolve_ios_device`（管道 + `|| true` 保持「空输出 rc=0」对外语义，`test_bg.sh:530-533` 钉死）⇒ 无回归，
  且新实现首次与文件头注释一致（旧实现实返 0，注释失真）。
- `assert_batch.sh` rc=3 与既有 1/2 分支互斥无冲突；`[ -s "$ERR" ] && cat` 在 `set -e` 下不触发退出。
- `ios_syslog_line_re`：ERE 转义完备（`]` 置类首为字面量、`-` 不在类内），`printf` 产出 `NAME(\(|\[)` 合法；
  锚定 `^日期 时间` 正确排除 `kernel(Sandbox)…deny` 噪声。
- `.app` 缺失时 `resolve_ios_app_name` 回退链（env → plist → basename → Runner）符合注释。

## P2（应修，非阻断）

| # | 位置 | 问题 | 修复建议 |
|---|---|---|---|
| P2-1 | `scripts/appium/driver.py:237-247` | 坐标步骤 `step["x"]` 硬取键 ⇒ KeyError 冒泡到 `main()` 兜底 `exit 3`（驱动错误），与既有 `shot` 缺 `out` ⇒ rc=1 的约定相悖 | 缺字段/非数字改为显式 `RuntimeError`；`activate` 缺 `bundleId` 同样显式报错 |
| P2-2 | `scripts/ios/_common.sh:236-242` | TERM 后立即 `kill -0`，信号投递有延迟 ⇒ 误报「无法停止」并写已死 pid 到 `syslog.orphan.txt` | 加宽限轮询（≤1 s，0.2 s 步进），仅 EPERM 或宽限后仍存活才报警 |
| P2-3 | `scripts/snapshot.sh:345-389` | 宿主机新增 120 s 上限，超时不分环境一律 rc=3 +「沙箱内已知限制」文案 ⇒ 可重试问题被归为「环境不支持」死路 | 124 分支分环境：沙箱 rc=3 + 现文案；宿主机 rc=1 + 中性可重试文案 |
| P2-4 | `scripts/_ios_device.sh:31-33` + `scripts/test_common.sh:501-510` | 表格解析依赖 `(UDID)`/`physical` 字面 token，G13 桩按正则手写 ⇒ 自证式测试，Xcode 漂移时静默失配 | 改用 `devicectl list devices --json-output` 解析 `hardwareProperties.{udid,reality}` + `deviceProperties.name`，表格仅作老版本兜底；桩改用真实采集结构 |
| P2-5 | `scripts/maestro/_common.sh:46-52` | `guard_sandbox_ios` 的 rc=3 只在 `assert_batch.sh` 文档化；`assert.sh` 头注「非 0 = 断言失败」⇒ 环境不可用被读成断言失败；`flow.sh`/`tap.sh` 头注无 rc=3 | 三处头注补 rc=3 语义；`assert.sh` 显式区分 3 与 1 |

## P3（可选）

- `snapshot.sh:355-379`：`_pid/_ticks/_max/_cp` 未 `local`；超时只杀 wrapper 直接子进程，XCTest 孙进程可能残留；
  清理提示只写 `maestro.cli.AppKt`，可补 `xcodebuild`；轮询 sleep 开销使实际超略大于上限。
- `ios/_common.sh:248`：`syslog.orphan.txt` 只追加不清理/去重。
- 沙箱停止分支：`old_pid` ESRCH 但同沙箱孙进程仍活时静默（可把 UDID 写进 orphan 记录）。
- 放行开关不一致：`MAESTRO_ALLOW_SANDBOX`（maestro）vs `SNAPSHOT_MAESTRO_TRY`（snapshot），文档应互相点名。
- `snapshot.sh:347` 注释「180 s 口径」与实际值 120 不一致（过时注释）。
- `driver.py:141-148`：`t.join` 超时后线程迟到的异常不检查 ⇒ 理论假 ✅。
- DRY：「降级：shot+logs、真机走 appium」文案 4 处近逐字重复。

## 测试覆盖（G13 评估）

覆盖三条回退（devicectl / idevice_id / 全失败 rc=1）与模拟器行剔除，**合格**；xctrace 主路径由
`test_bg.sh:414` 桩覆盖。值得补（不要求穷举）：① `ios_syslog_line_re` 转义纯字符串断言；
② `resolve_ios_app_name` 四级回退链；③ `guard_sandbox_ios` 的 rc=3 与放行开关；④ `assert_batch` rc=3 透传。

## 脱敏核验（公开仓）

- `grep '/Users/|liaoch|lcr@'`：仅 `safe_run.sh:75` 的 `${HOME:-/Users/$(id -un)}` 代码模板命中（非泄露、不在本轮 diff）。
- G13 全为合成值：占位 UDID `00008101-0011A2B3C4D5E6F7`、`Demo iPhone`、随机 UUID。
- `TinoSec`/`Tuya` 出现于本轮 references 新增行与 `logs.sh` 注释，与既有接受口径一致。
- **脱敏通过**（调用方已把原真实 UDID/设备名替换为占位值）。

## 待核实项

1. 本机 Xcode 的 devicectl 表格是否实含 `(UDID)`/`physical` token（决定 P2-4 紧迫度）——
   本轮已改写为 JSON 主路径，仅作老版本兜底。
2. 宿主机 iOS 模拟器 hierarchy dump 的 P99 耗时是否远低于 120 s（决定 P2-3 紧迫度）。
3. 沙箱停止采集在现安全层里走 EPERM 还是同空间真投递信号（决定 P2-2 触发频率）。

## 处置记录（调用方，2026-11-04）

- P2-1 已修：新增 `_step_xy()` / `_step_num()`，缺字段与非数字均转 `RuntimeError`（rc=1）；`activate` 缺 `bundleId` 显式报错。
- P2-2 已修：TERM 后宽限轮询 5×0.2 s，再判定存活（EPERM 视为存活）。
- P2-3 已修：124 分支分环境，宿主机 rc=1 + 可重试文案；顺带修 180→120 过时注释。
- P2-4 已修：新增 `_devicectl_json_list()`（python3 解析 `--json-output`），表格降为老版本兜底；G13 扩为 4 段（JSON / 表格兜底 / idevice_id / 全失败），`test_common.sh` 100→112 项。
- P2-5 已修：`assert.sh` / `tap.sh` / `flow.sh` 头注补 rc=3 语义（`assert.sh` 仍按 flow 的 rc 原样退出）。
- P3 部分采纳：`maestro_dump_bounded` 内变量改 `local`、超时提示补 `xcodebuild`。
- 复验：`bash -n` 全部通过、`python3 -m py_compile` 通过、`test_common.sh` 112/112、`test_all.sh` 全绿、真机枚举实测走 JSON 路径 rc=0。
- 未采纳（留作后续）：P3 的 orphan 表清理、DRY 文案收敛、`ios/_common.sh` 新增函数的专项单测（需构造临时 Flutter 工程）。
