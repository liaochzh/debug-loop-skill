# macOS 智能命令（`scripts/macos/` + `vision/smart_lib.sh`）

> **何时必读**：首次在 macOS 上用智能命令；`smart_tap`/`smart_assert` 报 Vision 失败、坐标偏移、权限弹窗时。
> 摘要与命令名见 `SKILL.md`「macOS 智能命令」节；本文件是完整用法与护栏口径。

**自动完成「截图 → Vision 定位 → 坐标换算 → 点击」**，替代人工读图估算坐标。

| 命令 | 说明 |
|---|---|
| `smart_tap.sh "<关键词>"` | 智能定位并点击（自动 Retina 换算） |
| `smart_tap.sh "<关键词>" --dry-run` | 只报告将点击的坐标/置信度，不点击 |
| `smart_tap.sh "<关键词>" --stable` | 双采样稳定后再点击（动画页） |
| `smart_tap.sh "<关键词>" --allow-danger` | 允许点击危险词按钮（默认拒绝） |
| `smart_assert.sh "<关键词>"` | 智能断言可见（退出码 0=成立，1=失败，3=Vision/截图失败/页面非 normal） |
| `smart_assert.sh "<关键词>" --not-visible` | 智能断言不可见 |
| `click.sh <x> <y>` | 屏幕 point 坐标点击（底层原语） |
| `click.sh --activate <AppName>` | 将应用切到前台 |

**安全护栏**（`smart_tap.sh` 内建）：`confidence < 0.7` 拒绝点击；危险词（中英双语：解绑/删除/付款/delete/logout…）拒绝；`state=loading/white_screen/obscured` 拒绝。阈值可用 `SMART_MIN_CONF` 覆盖。**退出码**：0=成功，1=未定位/页面不稳定，2=危险词拒绝，3=Vision/截图失败。

**前置权限**：终端需「屏幕录制」（截图）+「辅助功能」（点击）；建议 `brew install cliclick` 提升点击稳定性。

**排障要点**：
- 截图全黑 ⇒ 缺「屏幕录制」权限（不是 Vision 失效），先 `shot.sh` 自查。
- 点击无反应 ⇒ 缺「辅助功能」权限；仍无效再 `--dry-run` 核对坐标是否落在目标上。
- 坐标系统性偏移 ⇒ Retina 缩放换算异常，用 `--dry-run` 输出与 `shot.sh` 图对比像素位置。
