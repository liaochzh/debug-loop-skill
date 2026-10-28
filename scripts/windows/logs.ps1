# logs.ps1 — 查看 Windows 应用日志（build\debug\app.log）
param(
    [int]$Tail = 200,
    [string]$Filter = ""
)
$ErrorActionPreference = "Stop"

$LogDir = "build/debug"
$AppLog = Join-Path $LogDir "app.log"

if (-not (Test-Path $AppLog)) {
    Write-Host "❌ 日志文件不存在: $AppLog — 请先运行 run.ps1" -ForegroundColor Red
    exit 1
}

if ($Filter -ne "") {
    $matches = Get-Content $AppLog | Select-String -Pattern $Filter -SimpleMatch | Select-Object -Last $Tail
    if ($matches) { $matches.Line } else { Write-Host "📭 无匹配 '$Filter' 的日志" }
} else {
    Get-Content $AppLog -Tail $Tail
}

Write-Host ""
Write-Host "=== 异常摘要 ==="
$errors = Get-Content $AppLog | Select-String -Pattern "exception|error|fatal" | Select-Object -First 20
if ($errors) { $errors.Line } else { Write-Host "无异常" }
Write-Host ""
Write-Host "📁 完整日志: $AppLog"
