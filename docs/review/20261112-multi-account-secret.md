# 代码审查 r1：debug-loop 多测试账号（方案 C）

- 审查对象：`scripts/_secret.py`（新增）、`scripts/android/input.sh`、`scripts/appium/driver.py`、`init.sh`、`scripts/test_interact.sh`、`SKILL.md`、`references/{autoDebug-task-template,troubleshooting,maestro-flow-snippets,platform-extra}.md`、`docs/baton/debug-loop.md`
- 依据：`docs/plan/20261112-multi-account-secret.md`、`docs/plan/20261112-multi-account-secret.review.md`
- 审查方式：review 子代理（只读，静态 diff 取证；子会话 shell 只放行只读 git 命令，未复跑脚本）
- 结论：**需修改**（P1×1 阻塞、P2×4）

## r1 发现

| 级别 | 位置 | 问题 | 判定 |
|---|---|---|---|
| P1 | `scripts/appium/driver.py:419-428` | stdin 分支提前 return，`--key` 被静默丢弃：`find-type --text-from - --key PASSWORD` 从「按行取值」退化为「取第一行」，属身份错配 | 真实缺陷 |
| P2 | `scripts/_secret.py:69-72` | 组内无 `=` 的行漏进扁平档（判断顺序在 `current` 之前），畸形文件会取到组内原文而非 fail-closed | 真实缺陷 |
| P2 | `scripts/test_interact.sh:757` | 「`--account` 配 stdin」用例是**原因错误的假绿**：`input.sh:83` 把 `-` 当未知参数（`--text-from -` 从未生效），rc 恰为 2 | 真实缺陷（既有缺陷暴露） |
| P2 | `scripts/appium/driver.py:517-520` | driver 侧 `--account` 互斥无测试；非 find-type 子命令传 `--account` 被静默忽略 | 真实缺陷（缺测试 + 静默忽略） |
| P2 | `scripts/_secret.py:78` | 组内重复键「后者胜」，与扁平「首条命中」相反 | 真实缺陷 |

## 核销

首轮方案审查的 4 条 P1 均确认落地：单行无 `=` 回退（`_secret.py` + I6 断言）、driver `--account` 互斥、I6 段名、`SECRET=true` 脱敏。

## 分诊与处置（全部按真实缺陷处理）

1. **driver stdin 丢 `--key`** → `_secret.py` 拆出 `parse_lines()` 并新增 `load_text(raw, key=…)`；driver stdin 分支委托它。新增 I6 断言：命中 `PASSWORD` 得 `stdin-p`、缺该键 rc=2（可证伪「取第一行」）。
2. **组内畸形行/重复键** → `parse_lines()` 在组内先判 `=`，缺失或重复键一律 `SecretError`（rc=2），错误文案不带行内容（防值泄露）。
3. **`--text-from -` 假绿** → 修 `input.sh:83` 显式接受 `-`（文档本来就写「等价 stdin」）；I6 改为断言「值真正写进 ui.xml」+「配 `--account` rc=2」。
4. **driver 参数校验** → 校验前移到 `start_session` 之前（`caps={}` 可离线测）；非 find-type 传 `--account` ⇒ rc=2；I6 补 3 条离线断言。
5. **组内重复键** → 改为 rc=2（见 2）。

## 复审要求

- 重点复核 stdin 命中/未命中两条路径、`parse_lines` 重构对扁平语义（CRLF、值含 `=`、单行原文）的影响、`--text-from -` 对参数解析与 `SOURCES` 计数的副作用、rc 语义是否变化、新增用例是否可证伪。