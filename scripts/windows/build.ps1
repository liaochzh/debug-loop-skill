# build.ps1 — 构建 Windows 应用（仅能在 Windows 机执行；参数透传给 flutter build，无参默认 --debug）
# 用法: build.ps1 [--flavor <名>] [--release] ...
# 成功后解析实际 .exe（兼容 x64/arm64 × Debug/Release × BINARY_NAME 变化）并写入 build/debug/.last_windows_exe 锁文件
$ErrorActionPreference = "Stop"

if ($args.Count -eq 0) {
    Write-Host "🔨 构建 Windows debug（默认 --debug）..."
    flutter build windows --debug
} else {
    Write-Host "🔨 构建 Windows（透传参数: $($args -join ' ')）..."
    flutter build windows @args
}
if ($LASTEXITCODE -ne 0) { Write-Host "❌ 构建失败" -ForegroundColor Red; exit 1 }

$LogDir = "build/debug"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LockFile = Join-Path $LogDir ".last_windows_exe"

$candidates = @()
foreach ($arch in @("x64", "arm64")) {
    foreach ($cfg in @("Debug", "Release")) {
        $dir = "build/windows/$arch/runner/$cfg"
        if (Test-Path $dir) {
            $candidates += Get-ChildItem -Path $dir -Filter "*.exe" -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notmatch '^(flutter_|url_launcher|test)' }
        }
    }
}
if ($candidates.Count -eq 0) { Write-Host "❌ 构建失败，未找到 .exe" -ForegroundColor Red; exit 1 }
$exe = $candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$exe.FullName | Out-File -FilePath $LockFile -Encoding utf8 -NoNewline
Write-Host "✅ 构建成功: $($exe.FullName)（已锁定）" -ForegroundColor Green
