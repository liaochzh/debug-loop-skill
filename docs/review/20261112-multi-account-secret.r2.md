# 代码审查 r2：debug-loop 多测试账号（方案 C）

- 复审对象：r1 修复后的同一批文件（`git diff` 11 文件 + `scripts/_secret.py`）
- 结论：**通过（无阻断项）**；r1 的 1×P1 + 4×P2 修复全部成立，未引入阻断性回归
- 审查方式：review 子代理（只读静态取证；子会话 shell 无法执行测试脚本）

## r1 修复核实

| r1 项 | 核实结果 |
|---|---|
| P1 driver stdin 丢 `--key` | 已消除。stdin 走 `_secret.load_text(raw, key=…)`，命中/未命中与文件模式同语义；I6 用 `stdin-a`/`stdin-p` 两个不同值分别锁住命中与 rc=2，非同一重复 |
| P2 组内畸形行漏进扁平 | 已修。组内无 `=` / 重复键均 rc=2，错误不含行内容；组外行、注释、空行路径不变 |
| P2 `--text-from -` 假绿 | 已修。`input.sh` 接受 `-` 真走 stdin，I6 断言值写进 `ui.xml` |
| P2 driver 校验无测试/静默忽略 | 成立。三个互斥分支前移到建会话前，`caps={}` 即可离线测；rc 语义不变（原就是 2） |
| P2 组内重复键后者胜 | 已改 fail-closed（rc=2） |
| 测试计数 | 静态计数 181（I6 44）与当时声称一致 |

## 复审结论要点

- 扁平回归：单行无 `=`、CRLF、值含 `=` 与旧 driver 行为一致。
- `input.sh --text-from -`：无值/后随选项不误吞参数；`SOURCES` 计数与 `--clear-only` 互斥正确；`set -e` 下写法安全。
- driver rc：`--value` 必填仍在 find-* 分支（建会话后），flow 校验未动，仅 find-type 的 text/account 校验前移，rc 值不变。
- 安全：无新增注入面（argv 数组、无 eval）；错误信息不回显值；`list` 只出组名/角色；0644 仍 rc=2。

## 残余项（不阻塞）

| 级别 | 位置 | 问题 | 分诊 |
|---|---|---|---|
| P2 | `input.sh` stdin + `--key` | stdin 取整段原文、`--key` 静默忽略（与 driver 语义分叉，键名会被当值输入） | 真实缺陷（安全侧：把 `PASSWORD=` 前缀输进框）⇒ **已修复**：`STDIN_SET && --key` 直接 rc=2，I6 加两条断言（`--text-from -` 与 `--text-stdin` 两个形态） |
| P2 | `_secret.load("-")` 文案 | 防御分支措辞误导（不可达） | 已改为中性文案「文件路径不能是 -（stdin 请走 load_text）」 |
| 观察 | 扁平「首个有效行」 | 裸 `=`-less 行位于多行文件前部时会取代旧 bash「首个 KEY=VALUE 行」；属向 driver 旧语义收拢 | 接受为既定语义（畸形文件才触发），不改 |
| 观察 | 测试计数前提 | I6 有 9 条 driver 断言依赖 `requests`；缺依赖时打印 ⏭️ 跳过（总数 175） | 已在 baton 注明，不假绿 |

## 最终验证（主 agent 实跑）

- `bash scripts/test_interact.sh` → **184 项全过**
- `bash scripts/test_bg.sh -f 静态` → 2 项通过（67 个脚本语法 + 多字节隐患）
- `python3 -m py_compile scripts/_secret.py scripts/appium/driver.py` → 通过
- `bash scripts/android/input.sh --help` / `python3 scripts/appium/driver.py --help` → 新参数可见
- 真机闭环：**未执行**——本机无带登录页的目标工程（`secondhand-book-app` 只有 prototype，无 `.debug.env`），用系统 Settings 搜索框无法验证「账号身份」语义；已写入 baton 未完成项。