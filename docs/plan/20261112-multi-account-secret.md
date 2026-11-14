# debug-loop 多测试账号支持（方案 C：账号组一等支持）

日期：2026-11-12
目标仓库：`<home>/.config/opencode/skills/debug-loop`（独立 git 仓库，remote `liaochzh/debug-loop-skill`）
落档说明：规划档对目标仓库的写权限在本机被拒（`edit` denied under `~/.config/opencode/**`），本文落在当前项目根 `<home>/docs/plan/`；实施时以本文为准。
审查状态：已过 plan-review 首轮（`20261112-multi-account-secret.review.md`，结论「有条件通过」，4 条 P1 + 5 条 P2 已在本文核销）。

## 结论

在现有凭据文件上增加「账号组」语法 `[acct:<名字>]`，两个入口（`android/input.sh`、`appium/driver.py find-type`）新增 `--account <名字>`，解析统一收敛到新文件 `scripts/_secret.py`。**不新增退出码**（新失败一律 `rc=2` + 确定文案），旧文件与旧调用零改动。

不做：`.debug.env` 多环境建模（flavor→账号映射）、`flow` step 走凭据文件、加密存储/钥匙串、自动登录等业务代码改动。

## 现状与依赖

- `scripts/android/input.sh`：`read_secret()`(153-168) 扁平 `KEY=VALUE` 逐行取，`--key` 精确匹配，缺省第一条；`load_text()`(170-194) 先验 0600（`secret_perm()` 149-151）再取值；`--text-from` 可给任意路径，缺省 `.debug-login.secret`(79-83)；空文本 rc=2(476)；脚本内已用 `python3`(215)。
- `scripts/appium/driver.py`：`_load_text_source()`(411-445) 是上述语义的 Python 副本（含 0600 校验）；`find-type` 取值 523-527；`flow` 的 `type` step 只认内联 `text`(314-320)，不涉及凭据。
- `init.sh`：221-232 仅在文件不存在时生成模板（`ACCOUNT=`/`PASSWORD=`）；234-237 把**字面量** `.debug-login.secret` 写入项目 `.gitignore`。
- 文档触点：`SKILL.md` 57 / 61 / 248 行、`references/autoDebug-task-template.md` 35-44、`references/troubleshooting.md` 57、`references/maestro-flow-snippets.md` 113-114（建议 `source` 导出变量）、`docs/baton/debug-loop.md`。
- 测试：`scripts/test_interact.sh` I2 段用 adb 桩验 `--text-from`(395-406)，`acct_text()` 可读回框内值。

## 流程（改造后）

`input.sh` 解析参数 → 互斥/前置校验（`--account` 仅配 `--text-from <文件>`）→ `load_text()` 调 `python3 scripts/_secret.py get --file F [--account A] [--key ROLE]` → stdout 单值 → 既有「非 ASCII / 空值」检查 → 定位/清空/输入/读回，输出仍恒 `****`。`driver.py find-type` 在 `_load_text_source()` 内导入 `_secret.load()`，其余不变。`_secret.py` 为唯一解析实现，不再两处各写一套。

## 实现

### 1. 新增 `scripts/_secret.py`

CLI：`get --file PATH [--account NAME] [--key ROLE]`（stdout 单值、不加换行；错误 stderr `❌ …`，rc=2）；`list --file PATH`（每行 `<组名>\t<角色,...>`，**不含值**）。

`parse(path)` 返回 `(flat, groups)`：

- 容忍 CRLF（剥行尾 `\r`）；跳过空行与 `#` 开头行（值内 `#` 保留）。
- 组头正则 `^\[acct:([^\]]+)\]\s*$`；组名 trim 后须匹配 `^[A-Za-z0-9_.-]+$`；**重名报错**（fail-closed）；组内行须含 `=`；角色名精确匹配（模板用大写）。
- `account=None`（扁平模式）：只看组外行；键名**删除全部空白**（沿 `input.sh:160`）；首个 `KEY=` 匹配或第一行值；首个 `=` 切分，值可含 `=`；**单行且无 `=` ⇒ 整行作值返回**（保留 `driver.py:443-445` 既有用法，不破坏旧调用）。
- `account=NAME`：缺省角色 `ACCOUNT`；组不存在 → `❌ 账号组 'NAME' 不存在；可用组: a, b`；角色不存在 → `❌ 账号组 'NAME' 里没有 KEY=ROLE；可用角色: ACCOUNT, PASSWORD`。
- 存在性/权限集中在此：不存在 → `❌ 凭据文件不存在: F（先由人工创建，勿入库）`；`mode & 0o077` → `❌ 凭据文件权限为 %o，要求 600：chmod 600 F`（与现有文案逐字一致）。**规则拍板：只拒 group/other 位**（644/640 拒；0400/0700 放行）——与 `driver.py:425` 现行为一致，`input.sh:184` 由「逐字 600」放宽到同一档。
- 未预期异常（含 `python3` 缺失、文件半写入）统一折算 `rc=2` 并打 `❌ 凭据读取失败: …`，不落成其他码。
- 空值不在此拒绝，由调用方既有空值检查报错（保持两条入口语义）。
- 文件头注释写明「本文件是唯一解析实现，后续 maestro/flow 若接凭据也只许复用」，防第三套解析。

### 2. `scripts/android/input.sh`

- 头注释补 `--account` 与示例（`--account buyer --key PASSWORD --mask`）；`usage()` 自动跟随。
- 变量 `ACCOUNT=""`；case 分支 `--account)` 取值，缺参 rc=2。
- SOURCES 校验后追加：`--account` 非空且（`TEXT_SET` 或 `STDIN_SET` 或 `FROM_SET=false`）⇒ `❌ --account 只能与 --text-from <文件> 同用`，rc=2。
- `load_text()`：删 `secret_perm`/`read_secret`，改为
  `local args=("$SCRIPTS/_secret.py" get --file "$TEXT_FROM"); [ -n "$ACCOUNT" ] && args+=(--account "$ACCOUNT"); [ -n "$KEY_NAME" ] && args+=(--key "$KEY_NAME")`，
  `TEXT=$(python3 "${args[@]}")`，失败 `return 2`（文案由 `_secret.py` 输出）。**不得用 `${ACCOUNT:+…}` 裸展开**（含空格/通配的组名会拆词或 glob）。
- 取值成功后**保留 `SECRET=true`**（删 read_secret 时不可连带删除；它是 `input.sh:530` 的脱敏开关）。
- 476 行空值文案改为 `检查凭据文件 / --key / --account`。

### 3. `scripts/appium/driver.py`

- 顶部 `sys.path.insert(0, str(Path(__file__).resolve().parent.parent))`（或函数内惰性 import，二选一并加注释说明单一来源）。
- `_load_text_source(path, key="", account="")`：`-`（stdin）分支保持原文；其余委托 `_secret.load(path, account or None, key or None)`，捕获 `SecretError` → stderr + `sys.exit(2)`。
- 新增 `--account` 参数（help 注明仅 `--text-from` 文件有效）；调用处传入；527 行空值文案加 `--account`。
- **前置校验（与 input.sh 同文案，rc=2）**：`args.account` 非空且（`args.text` 非空 或 `args.text_from == "-"` 或 `args.text_from` 为空）⇒ `❌ --account 只能与 --text-from <文件> 同用`。不校验就会出现「以为切了组、实际用默认值/扁平值」的静默身份错配。
- 值来源改为委托后，扁平单行无 `=` 的旧用法由 `_secret.load` 的 fallback 保留（见 §1），并在验证节加一条 `python3 -c` 离线断言锁住该行为。

### 4. `init.sh`

- 凭据模板追加注释块（不启用，保持单账号默认）：`# 多账号：[acct:<名字>] 一组，组内 ACCOUNT= / PASSWORD=` + `# [acct:buyer]` 示例三行。
- 226 行用法提示**保留扁平口径**（`--key ACCOUNT`），`--account` 示例只写进新增注释块——否则新项目首条命令就打「账号组 'buyer' 不存在」rc=2。
- `.gitignore` 写入 `.debug-login*.secret`（`grep -qxF` 判重；旧字面量行保留，不删）。

### 5. 文档（同批）

- `SKILL.md` 57 行：多账号用 `--account`；**读回只保证值一致，不保证登的是哪个号** ⇒ 登录后用 `assert_page` 断言账号标识。
- `SKILL.md` 248 行命令表与 61 行：补 `--account`，注明仅配 `--text-from <文件>`。
- `references/autoDebug-task-template.md` 35-44：多账号写 `<secret:<组名>/ACCOUNT>`；示例 `input.sh … --account <组名> --key ACCOUNT|PASSWORD`。
- `references/troubleshooting.md`：新增「登成别的账号 / 切号残留」→ 显式 `--account`；切号先登出并断言旧标识消失。
- `references/maestro-flow-snippets.md` 114：**禁止 `source .debug-login.secret`**（组头行会报错），改用 `ACCOUNT=$(python3 <S>/scripts/_secret.py get --file .debug-login.secret --account buyer --key ACCOUNT)`。
- 同批补注：`SKILL.md` 51/337 行签名补 `--account`；`SKILL.md` 168 行测试计数与段名改成 I6；`references/autoDebug-task-template.md` 109 行检查项；`references/platform-extra.md` 22 行。
- `docs/baton/debug-loop.md`：追加改动条目与验证结论。

## 实施顺序与依赖

1. `_secret.py`（无依赖）→ 2. `input.sh` → 3. `driver.py` → 4. `init.sh` → 5. `test_interact.sh` 新增 **I6 段**（追加在既有 I5 之后；`I4`/`I5` 已被占用，不得复用段名）→ 6. 文档。步骤 1 必须先落地，2/3 依赖其 CLI 与错误文案。

## 边界

- 兼容：旧扁平文件不受影响；`--account` 与 `--text`/`--text-stdin` 显式互斥（两入口同文案）；文件改成全分组后旧调用（扁平 `--key ACCOUNT`）报 rc=2（fail-closed，不会误取别的账号值）；`--text-from` 单行无 `=` 的旧用法保留整行取值。
- 权限：`_secret.py` 统一按「只拒 group/other 位」判定 ⇒ 644/640 仍拒，`input.sh` 原先拒的 0400/0700 转为可读（无安全损失，需在 `input.sh:16` 注释与 baton 里写明）。
- 明文：错误信息只列组名/角色名（非密）；值只走 stdout；不改「快照落临时文件、退出即删」纪律。
- 状态/并发：纯只读解析、无锁；文件半写入（编辑器保存中）→ rc=2 明确失败。
- 生命周期：不动 `.debug.env` 结构；不做自动登出/登录；不改 `flow` step 语义；`_secret.py` 不落任何临时文件。

## 验证

- `bash scripts/test_interact.sh`（新 **I6**）：组内取 ACCOUNT/PASSWORD、缺省角色、组不存在（含「可用组」）、角色不存在、扁平模式不被组头影响、单行无 `=` 仍整行取值、重名组/非法组名 rc=2、0644 rc=2 含 `chmod 600`。fixture 用**两两不同的哨兵值**（如 `acctA1`/`pwA1`/`acctB1`/`pwB1`），断言取 A 组时**等于 A 值且不等于 B 值**，证「不串组」；集成：`--account a --key ACCOUNT` 输入后 `acct_text` 等于组值、`--mask` 输出 `****` 且不含明文、`--account`+`--text` 与 `--account`+`--text-from -` 均 rc=2。
- `python3 -c` 离线断言 driver 取值路径：单行无 `=` 文件 → 整行；分组文件按 `account/key` 取值；`--account`+`--text` 组合走前置校验（不连 Appium 也能测的部分直接 import `_load_text_source`）。
- `bash scripts/test_bg.sh -f 静态` + `python3 -m py_compile scripts/_secret.py scripts/appium/driver.py`。
- 手工：`python3 scripts/_secret.py list --file <fixture>`、`bash scripts/android/input.sh --help`、`python3 scripts/appium/driver.py --help`。
- 真机最小闭环（1 台 Android）：两组凭据各登录一次，`assert_page has:<登录后账号标识>` 证明确实切到目标账号（读回不覆盖身份）。

## 实施结果（2026-11-12）

- 已按本方案落地；代码审查 r1「需修改」→ r2「通过」：`docs/review/20261112-multi-account-secret{,.r2}.md`。
- 偏差（均已在 r2 核销）：
  1. 顺带修复 `input.sh` 的 `--text-from -` 被当成未知参数（文档早已声明等价 stdin）；stdin 配 `--key` 由「静默忽略」改为 rc=2。
  2. `_secret.py` 拆出 `parse_lines()` + `load_text()`，driver 的 stdin 分支复用，避免出现第二套解析。
  3. 测试最终 **184 项**（I6 共 47 项）。
- 未执行：真机登录闭环——本机无带登录页的目标工程（无 `.debug.env`），已登记在 baton 未完成项。
