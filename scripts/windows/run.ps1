# run.ps1 — 启动 Windows 应用（stdout/stderr → build\debug\app.log）
# 约定：必须从 Flutter 项目根执行（脚本按 $PWD 查找 .debug.env）
param(
    [int]$WaitSeconds = 3
)
$ErrorActionPreference = "Stop"

$EnvFile = Join-Path (Get-Location) ".debug.env"
if (-not (Test-Path $EnvFile)) {
    Write-Host "❌ 缺少 $EnvFile — 请在项目根执行 debug-loop skill 的 init.sh" -ForegroundColor Red
    exit 1
}

# 从 .debug.env 解析 WINDOWS_APP_NAME="xxx"
$line = Get-Content $EnvFile | Where-Object { $_ -match '^\s*WINDOWS_APP_NAME=' } | Select-Object -First 1
if ($null -eq $line) {
    Write-Host "❌ .debug.env 缺少 WINDOWS_APP_NAME — 请补填或重新运行 init.sh" -ForegroundColor Red
    exit 1
}
$WindowsAppName = ($line -split '=', 2)[1].Trim().Trim('"')

$LogDir = "build/debug"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$AppLog = Join-Path $LogDir "app.log"
$LockFile = Join-Path $LogDir ".last_windows_exe"

# 三级回退：显式覆盖（WINDOWS_EXE_PATH）> 锁文件 > 目录最新发现（x64/arm64 × Debug/Release）
$ExePath = $null
$envLine2 = Get-Content $EnvFile | Where-Object { $_ -match '^\s*WINDOWS_EXE_PATH=' } | Select-Object -First 1
if ($null -ne $envLine2) {
    $explicit = ($envLine2 -split '=', 2)[1].Trim().Trim('"')
    if ($explicit -ne "" -and (Test-Path $explicit)) { $ExePath = $explicit }
    elseif ($explicit -ne "") { Write-Host "⚠️ WINDOWS_EXE_PATH 指向不存在: $explicit，回退自动发现" -ForegroundColor Yellow }
}
if ($null -eq $ExePath -and (Test-Path $LockFile)) {
    $locked = (Get-Content $LockFile | Select-Object -First 1).Trim()
    if ($locked -ne "" -and (Test-Path $locked)) { $ExePath = $locked }
    elseif ($locked -ne "") { Write-Host "🔓 锁文件过期，回退目录发现" -ForegroundColor Yellow }
}
if ($null -eq $ExePath) {
    $candidates = @()
    foreach ($arch in @("x64", "arm64")) {
        foreach ($cfg in @("Debug", "Release")) {
            $dir = "build/windows/$arch/runner/$cfg"
            if (Test-Path $dir) {
                if ($WindowsAppName -ne "" -and (Test-Path (Join-Path $dir "$WindowsAppName.exe"))) {
                    $candidates += Get-Item (Join-Path $dir "$WindowsAppName.exe")
                } else {
                    $candidates += Get-ChildItem -Path $dir -Filter "*.exe" -File -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -notmatch '^(flutter_|url_launcher|test)' }
                }
            }
        }
    }
    if ($candidates.Count -eq 0) {
        Write-Host "❌ 未找到可执行文件 — 请先运行 build.ps1" -ForegroundColor Red
        exit 1
    }
    $exe = $candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($candidates.Count -gt 1) {
        Write-Host "⚠️ 检测到 $($candidates.Count) 个 .exe 候选，自动选最新: $($exe.FullName)" -ForegroundColor Yellow
        Write-Host "   如需精确指定，在 .debug.env 设置 WINDOWS_EXE_PATH" -ForegroundColor Yellow
    }
    $ExePath = $exe.FullName
}

if (-not (Test-Path $ExePath)) {
    Write-Host "❌ 未找到可执行文件: $ExePath — 请先运行 build.ps1" -ForegroundColor Red
    exit 1
}

# 停止已运行实例（进程名取自实际 exe，兼容 BINARY_NAME 变化）
$ProcName = [System.IO.Path]::GetFileNameWithoutExtension($ExePath)
Get-Process -Name $ProcName -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 1

Write-Host "🚀 启动: $ProcName（日志 → $AppLog）"
if (Test-Path $AppLog) { Clear-Content $AppLog }
$proc = Start-Process -FilePath $ExePath -RedirectStandardOutput $AppLog -RedirectStandardError "$LogDir\app.err.log" -PassThru
Start-Sleep -Seconds $WaitSeconds

if ($proc.HasExited) {
    Write-Host "⚠️ 进程已退出 (ExitCode: $($proc.ExitCode))，用 logs.ps1 查看日志排查" -ForegroundColor Yellow
} else {
    Write-Host "✅ App 已启动，PID: $($proc.Id)" -ForegroundColor Green
}
