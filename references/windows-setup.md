# Windows 端首次使用验证清单

> Flutter Windows 产物只能在 Windows 机器上构建。以下步骤在 Windows 开发机执行一次即可。

## 1. 前置环境

- [ ] Flutter SDK（Windows 版）已安装且在 PATH：`flutter doctor`
- [ ] Visual Studio 2022 含「使用 C++ 的桌面开发」工作负载
- [ ] PowerShell 5.1+（Windows 10/11 自带）
- [ ] 本仓库已 clone 到 Windows 机（如 `C:\code\opencode-skills`），或至少 `debug-loop/scripts/` 可访问

## 2. 项目接入

项目根需有 `.debug.env`（macOS 上跑 init.sh 生成后随 git 同步，或手工创建）：

```
WINDOWS_APP_NAME="your_app_name"   # 来自 windows/CMakeLists.txt 的 BINARY_NAME
```

> run.ps1 运行时从 `$PWD\.debug.env` 解析该字段——**必须在项目根执行脚本**。

## 3. 逐项验证

```powershell
$S = "C:\code\opencode-skills\debug-loop\scripts\windows"

# 3.1 构建
powershell -ExecutionPolicy Bypass -File $S\build.ps1
# 预期：build/windows/x64/runner/Debug/<app>.exe 存在

# 3.2 启动 + 日志捕获
powershell -ExecutionPolicy Bypass -File $S\run.ps1
# 预期：App 窗口弹出；build\debug\app.log 生成

# 3.3 在 Flutter 代码里临时加一行后热重跑验证 print 可见：
#   debugPrint / print("HELLO_DEBUG_LOOP");
# 预期：logs.ps1 输出中包含该行（flutter: HELLO_DEBUG_LOOP）
powershell -ExecutionPolicy Bypass -File $S\logs.ps1 -Tail 50

# 3.4 关键词过滤与异常摘要
powershell -ExecutionPolicy Bypass -File $S\logs.ps1 -Filter "flutter"

# 3.5 截图
powershell -ExecutionPolicy Bypass -File $S\shot.ps1
# 预期：build\debug\screen.png 为有效图片（本地桌面会话；RDP 最小化时可能失败）

# 3.6 .debug.env 解析验证（run.ps1 内置）：故意把 WINDOWS_APP_NAME 置空再跑 run.ps1
# 预期：报「缺少 WINDOWS_APP_NAME」而非启动失败
```

## 4. 已知限制

- `Start-Process -RedirectStandardOutput` 每次启动覆盖日志（与 macOS/iOS 行为一致）
- 远程桌面断开/最小化时 CopyFromScreen 可能截出黑图或失败
- opencode 权限：在 Windows 机的 `opencode.jsonc` 中为 autoDebug 追加：
  `"powershell *": "allow"`、`"pwsh *": "allow"`
