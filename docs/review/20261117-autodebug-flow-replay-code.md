# 代码审查 r1：autoDebug 流程固化 + 分级回放 + 取证包

> 日期：2026-11-17 · 审查对象：`debug-loop-skill` 本轮全部新增/改动脚本与文档
> 方案：`~/docs/plan/20261117-autodebug-flow-replay.md`（v3 定稿；设计侧审查见同目录 `.review.md` / `.review.r2.md`）
> 结论：**不通过（需修复后复审）** —— P0×1、P1×5、P2×7

## 审查范围

`scripts/flow_save.sh`、`scripts/flow_run.sh`、`scripts/evidence.sh`、`scripts/_danger_words.sh`、
`scripts/_flow_index.py`、`scripts/test_flow.sh`、`scripts/tap_verify.sh`（词表抽取）、
`scripts/test_all.sh`（第 9 项）、`templates/flows/*.json`、`SKILL.md`、`references/autoDebug-task-template.md`。

## 已核对通过

- **tap_verify 行为保持重构**：删除的 `DANGER_WORDS` 字面量与 `_danger_words.sh` 的 `DANGER_WORDS_BASE` 逐字一致（含前导空格）；`is_danger` 未改；扩展词表未泄漏进 tap_verify。
- **rc 契约主干自洽**：门禁先于设备校验/bundle 创建/任何步骤 ⇒ rc=6 零设备动作；步骤脚本 rc=6 ⇒ 流程 rc=1，不与门禁混淆。
- **设备语义**：Android 在线校验 + `ANDROID_SERIAL` 注入、不在线不静默换机；iOS 模拟器只校验不注入；ios-device 注入 UDID + `IOS_TARGET=device`；macOS 仅记录。
- **原子写/落盘**：mkstemp + `os.replace`；索引全量重建；同名 `.bak`；journal 每步即时落。
- **evidence `--artifact` 无设备路径**：只读 `.last_*` 锁，路径全程引号传参，无 eval 面。
- **凭据面**：journal/JSON 经 argv→json 序列化，`<secret:>` 拒收、`--mask` 无 `--text-from` 拒收、login 模板用 `--text-from`。

## P0（阻断）

**P0-1 `flow_run.sh` META 解析可被多行值注入，伪造 `grade=A` 绕过 B 级门禁**
- 触发：`flow_save --precond $'…\ngrade=A'`（多行字符串合法）→ 回放时 python 原样输出多行值，bash 侧 `while IFS='=' read` 逐行覆盖变量 ⇒ `GRADE=A`。
- 影响：直接击穿「B 级未获用户同意不可回放」这一核心承诺。
- 处置：flow_save 拒收标量字段换行 + flow_run 单行化（defense in depth）+ 钉桩用例（手写 JSON 也须 rc=6）。

## P1（应修）

- **P1-1 命令串黑名单漏单 `&` / `$` / glob**：`android/run.sh & <cmd>` 可通过固化并被 `bash -c` 当控制符执行；`$HOME`/`*` 会被展开。处置：两侧拒 `&`/`$`，执行侧 `set -f`。
- **P1-2 无 `--mask` 时明文秘密可入库**：`--field 密码 --text hunter2` 不触发任何检查 ⇒ 明文进流程 JSON / journal.cmd / argv。处置：敏感字段（密码/验证码/otp/secret/token…）+ `--text` 一律 rc=2。
- **P1-3 GRADE 坏值 fail-open**：`"grade": "a"` 等非 `"B"` 串被当作可直跑。处置：只有恰好 `A` 才免门禁，其余 fail-closed。
- **P1-4 flow_run 缺 `..` 校验**（与 flow_save 不对称）：手改 JSON 可指向 scripts/ 之外的 `.sh`。处置：回放侧同样拒 `..`。
- **P1-5 `test_flow.sh -f 原子写` 状态依赖**：单独跑时 `.bak` 断言必红。处置：改为自足（自建首次固化 + 增量断言）。

## P2（可选）

1. 首 token 带引号时前缀剥离错位（改为按首个空白分词剥离）。
2. bundle/取证目录 check-then-mkdir 竞态（改 `until mkdir`）。
3. 显式 `--platform any` 未配 `--artifact` 时未拦截。
4. rc=3 兼作「非项目根（缺 `.debug.env`）」未入表。
5. SKILL.md 非语义步骤清单窄于实现（漏 `install` / appium 三件套）。
6. `_flow_index.py` 未转义单元格 `|`。
7. `.bak` 秒级时间戳同秒冲突；`cp || true` 静默。

## 处置台账

| 编号 | 状态 | 落点 |
|---|---|---|
| P0-1 | 已修 | flow_save 换行拒收 + flow_run `one_line()` + test「元数据注入」组 |
| P1-1 | 已修 | 两侧守卫拒 `&`/`$` + `set -f` + 用例 |
| P1-2 | 已修 | 敏感字段明文 `--text` 拒收 + 正/负用例 |
| P1-3 | 已修 | `grade != A` 即需授权 + 坏值用例 |
| P1-4 | 已修 | 回放侧 `..` 拒收 + 用例 |
| P1-5 | 已修 | 原子写组自足 |
| P2-1..7 | 已修 | 见 r2 报告「逐条核实」节 |

修复后门禁：`test_flow.sh` 139 ✅ / `test_all.sh` 九项全绿 / `verify-env-guard.py --gate` rc=0 /
真机（Android 占位设备）A 级回放 rc=0、B 级未授权 rc=6 零动作。复审见 `20261117-autodebug-flow-replay-code.r2.md`。
