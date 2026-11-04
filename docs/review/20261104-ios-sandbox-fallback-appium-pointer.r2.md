# 审查报告（第 2 轮，复审）：iOS 沙箱降级 + 真机枚举回退 + Appium 坐标/退后台

- 日期：2026-11-04
- 对象：同批未暂存改动（`git diff -- scripts references`）
- 前序：`docs/review/20261104-ios-sandbox-fallback-appium-pointer.md`（第 1 轮「有条件通过」+ 处置记录）
- 结论：**通过（LGTM）** —— 5 条 P2 均已真实修复，未发现功能性回归

## 逐条核验

**P2-1 `appium/driver.py` ✅**
- `_step_xy()`：`KeyError` 与 `TypeError/ValueError` 分别转 `RuntimeError`，消息含缺失键与 x/y 原值 repr；`_step_num()` 同口径（`None`/字符串/列表经 `float()` 抛 TypeError 均被捕获）。
- 覆盖确认：`tap_xy`（:258）、`long_press`（:261）、`hold_and_background`（:264，hold/at/seconds 全走 `_step_num`）、`background`（:272）；`activate` 缺 `bundleId`（含空串）显式 `RuntimeError`（:275-277）。
- rc 落点：`run_steps` 的 `except RuntimeError → return False → sys.exit(1)`（:298-300、:353）；步骤内异常不会冒泡到 `main()` 的 `except → exit(3)`。

**P2-2 `ios/_common.sh` ✅**
- 宽限轮询 `while [ "$_i" -lt 5 ] && kill -0 …`：条件上下文失败不触发 errexit；上界 5×0.2 s=1 s，进程死亡即退出，不死循环。
- 宽限后 `kill -0` 成功 → alive；失败再判 EPERM（大小写兼容），ESRCH 不匹配 → 不写 orphan；非数字 pid 报 "invalid kill argument" 不含 "not permitted" → 不误报。
- `kout=$(kill -0 … 2>&1 || true)` 有 `|| true` 保护且避开 pipefail 吞状态；沙箱分支末尾 `rm -f pid_file; return 0`，宿主机分支原逻辑未变。`ios_syslog_capture_running` 同口径。

**P2-3 `snapshot.sh` ✅**
- 文件头注释（:34-37）与 124 分支实现（:390-402）逐项一致：沙箱 rc=3 / 宿主机超时 rc=1 可重试 / 0=不限。
- `MAESTRO_RC=$?` 位于 `if … then :; else` 的 else 首条语句，`$?` 保留条件命令退出码 ✅。
- 超时路径先 TERM 子进程再 KILL、`wait || true`，变量已 `local`；正常退出时 `wait "$_pid"` 透传真实 rc。

**P2-4 `_ios_device.sh` + `test_common.sh` G13 ✅**
- `_devicectl_json_list()` 各分支闭环：python3 缺失、mktemp 失败、devicectl 失败、JSON 解析异常、`result`/`devices`/`hardwareProperties` 缺失（`or {}`/`or []` 防御）、`reality≠physical`、udid 缺失、空结果 ⇒ 全部返回 1；**所有路径均 `rm -f "$tmp"`**（`out=$(… || true)` 处于 `||` 列表非末位，errexit 在函数体内被抑制）。
- 表格兜底可达：老版本拒绝 `--json-output` ⇒ 返回 1 ⇒ 走表格 ⇒ 再走 idevice_id；xctrace 非空即 return，不会重复输出。
- G13 四段桩为分支级、非自证：① JSON 段由真实解析代码读 Apple schema，断言验证 `reality` 过滤（模拟器条目未混入）；② 表格段显式拒绝 `--json-output`（exit 2）强制走兜底；③ xcrun 全失败 + idevice_id/ideviceinfo；④ 全灭断言 rc=1 且空输出。

**P2-5 maestro 三脚本头注 ✅**
- `assert.sh:9-11`、`flow.sh:11-12`、`tap.sh:12-13` 补齐 rc=3 语义与降级指引。
- 透传链路：`guard_sandbox_ios` exit 3（`_common.sh:52`）在 `detect_platform` 显式/自动两路触发（:62、:73）；`flow.sh:36` 命令替换赋值以 3 退出；`assert.sh` 末条命令即 `bash flow.sh`，rc=3 原样透传；`assert_batch.sh` rc=3 分支与 1/2 互斥。

## 可选打磨项（复审提出，本轮一并处理）

1. [Medium] 新头注声明「2 = 用法错」，但「未知参数」「缺 TARGET/FLOW」仍 `exit 1` ⇒ 已统一改为 `exit 2`（`assert.sh` / `tap.sh` / `flow.sh`）。
2. [Low] `_devicectl_json_list` 内嵌 python 顶层非 dict 时 `data.get` 抛 AttributeError 打印 traceback ⇒ 已加 `isinstance(data, dict)` 防御。

## 复验（调用方）

- `bash -n` 全部改动脚本通过；`python3 -m py_compile scripts/appium/driver.py` 通过。
- `scripts/test_common.sh` **112/112**；`scripts/test_all.sh` 全绿（test_common / test_bg / test_snapshot / test_safe_run / test_build_metrics）。
- 真机枚举实测：`source scripts/_ios_device.sh; list_ios_devices` 走 JSON 路径返回 1 台真机、rc=0。
- 脱敏：G13 全为合成值（占位 UDID / `Demo iPhone` / 随机 UUID），无真实设备号、用户名、家目录。
