# shot.ps1 — 全屏截图到 build\debug\screen.png（.NET CopyFromScreen，需桌面会话）
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$LogDir = "build/debug"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$ScreenFile = Join-Path $LogDir "screen.png"

try {
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
    $bmp.Save($ScreenFile, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    $size = (Get-Item $ScreenFile).Length
    Write-Host "✅ 截图完成: $ScreenFile ($size bytes)" -ForegroundColor Green
} catch {
    Write-Host "❌ 截图失败: $_" -ForegroundColor Red
    Write-Host "💡 远程桌面/无头环境下可能无法截屏；确认在本地桌面会话中执行"
    exit 1
}
