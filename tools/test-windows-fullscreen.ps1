# Windows 全屏实机验收（只能在 Windows 上跑）
#
# 为什么需要：全屏是窗口级动作，`dart run tool/*` 和 analyze 都证明不了
# 「按下去窗口真的变成无边框铺满整块屏幕、再按一次真的还原」。这里直接给
# 加载器窗口发 WM_KEYDOWN(VK_F11)（不需要人点、不需要窗口有焦点），再用
# GetWindowLongPtr / GetWindowRect 读真实窗口状态。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\test-windows-fullscreen.ps1 `
#       -Exe 'build\windows\x64\runner\Release\gardendless_loader.exe'
param(
    [string]$Exe = '',
    # 给 -Zip 时先解压到临时目录再测：验证的是「用户拿到的那个包」，
    # 而不是本机上一次构建的输出（两者可能不是同一次构建）。
    [string]$Zip = '',
    [int]$SettleMs = 700
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$sandbox = ''
if (-not [string]::IsNullOrWhiteSpace($Zip)) {
    if (-not (Test-Path -LiteralPath $Zip)) { Write-Host "找不到 zip：$Zip"; exit 2 }
    $sandbox = Join-Path $env:TEMP ('gl-fs-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $sandbox | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($Zip, $sandbox)
    $Exe = Join-Path $sandbox 'gardendless_loader.exe'
}
if ([string]::IsNullOrWhiteSpace($Exe)) {
    $Exe = Join-Path $repo 'build\windows\x64\runner\Release\gardendless_loader.exe'
}
if (-not (Test-Path -LiteralPath $Exe)) {
    Write-Host "找不到 exe：$Exe"
    exit 2
}

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class WinProbe {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct MONITORINFO {
    public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags;
  }
  [DllImport("user32.dll")] public static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int nIndex);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr hWnd, uint flags);
  [DllImport("user32.dll")] public static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc callback, IntPtr lParam);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder name, int max);
  public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
}
'@

$GWL_STYLE = -16
$WS_CAPTION = 0x00C00000
$WS_THICKFRAME = 0x00040000
$WS_POPUP = 0x80000000
$WM_KEYDOWN = 0x0100
$VK_F11 = 0x7A
$MONITOR_DEFAULTTONEAREST = 2

$pass = 0
$fail = 0
function Assert([string]$name, $cond, $extra) {
    if ($cond) {
        $script:pass++
        if ($null -ne $extra) { Write-Host ("  ok   $name -> $extra") } else { Write-Host "  ok   $name" }
    } else {
        $script:fail++
        if ($null -ne $extra) { Write-Host ("  FAIL $name -> $extra") } else { Write-Host "  FAIL $name" }
    }
}

function Get-Style([IntPtr]$hwnd) { [int64]([WinProbe]::GetWindowLongPtr($hwnd, $GWL_STYLE)) }

function Get-Rect([IntPtr]$hwnd) {
    $rect = New-Object WinProbe+RECT
    [void][WinProbe]::GetWindowRect($hwnd, [ref]$rect)
    return $rect
}

function Get-MonitorRect([IntPtr]$hwnd) {
    $monitor = [WinProbe]::MonitorFromWindow($hwnd, $MONITOR_DEFAULTTONEAREST)
    $info = New-Object WinProbe+MONITORINFO
    $info.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($info)
    [void][WinProbe]::GetMonitorInfo($monitor, [ref]$info)
    return $info.rcMonitor
}

function Send-F11([IntPtr]$hwnd) {
    [void][WinProbe]::PostMessage($hwnd, $WM_KEYDOWN, [IntPtr]$VK_F11, [IntPtr]0)
    Start-Sleep -Milliseconds $SettleMs
}

function Rect-Equals($a, $b) {
    return ($a.Left -eq $b.Left) -and ($a.Top -eq $b.Top) -and ($a.Right -eq $b.Right) -and ($a.Bottom -eq $b.Bottom)
}
function Format-Rect($r) { return "$($r.Left),$($r.Top) $($r.Right - $r.Left)x$($r.Bottom - $r.Top)" }

# 为什么不用 Process.MainWindowHandle：通过 ssh 启动的 GUI 进程跑在非交互
# 会话里，窗口永远「不可见」，MainWindowHandle 恒为 0（已发布版本也一样）。
# 但隐藏窗口的样式/矩形仍然是真实的，全屏逻辑照样能在它身上验证，所以按
# PID + 窗口类名枚举（EnumWindows 不要求窗口可见）。
function Find-AppWindow([int]$processId) {
    $found = [IntPtr]::Zero
    $callback = [WinProbe+EnumProc]{
        param($hWnd, $lParam)
        $owner = 0
        [void][WinProbe]::GetWindowThreadProcessId($hWnd, [ref]$owner)
        if ($owner -eq $processId) {
            $name = New-Object System.Text.StringBuilder 256
            [void][WinProbe]::GetClassName($hWnd, $name, 256)
            $class = $name.ToString()
            if ($class -like 'FLUTTER*' -or $class -like '*Gardendless*') {
                $script:foundWindow = $hWnd
                return $false
            }
        }
        return $true
    }
    $script:foundWindow = [IntPtr]::Zero
    [void][WinProbe]::EnumWindows($callback, [IntPtr]::Zero)
    return $script:foundWindow
}

Write-Host "启动 $Exe"
$proc = Start-Process -FilePath $Exe -WorkingDirectory (Split-Path -Parent $Exe) -PassThru
try {
    $hwnd = [IntPtr]::Zero
    for ($i = 0; $i -lt 120; $i++) {
        Start-Sleep -Milliseconds 250
        $proc.Refresh()
        if ($proc.HasExited) { break }
        $hwnd = Find-AppWindow $proc.Id
        if ($hwnd -ne [IntPtr]::Zero) { break }
    }
    Assert '启动后找到加载器窗口（按 PID 枚举，不要求可见）' ($hwnd -ne [IntPtr]::Zero) $hwnd
    if ($hwnd -eq [IntPtr]::Zero) { throw '没有窗口，后续无从验证' }

    Start-Sleep -Milliseconds 1500   # 等首帧
    $styleBefore = Get-Style $hwnd
    $rectBefore = Get-Rect $hwnd
    $monitorRect = Get-MonitorRect $hwnd
    Write-Host ("  窗口模式：style=0x{0:X} rect={1}" -f $styleBefore, (Format-Rect $rectBefore))
    Write-Host ("  显示器区域：{0}" -f (Format-Rect $monitorRect))
    Assert '起始状态是带标题栏的普通窗口' (($styleBefore -band $WS_CAPTION) -ne 0)
    Assert '起始状态不是铺满显示器' (-not (Rect-Equals $rectBefore $monitorRect))

    Write-Host ''
    Write-Host '== F11 进入全屏 =='
    Send-F11 $hwnd
    $styleFull = Get-Style $hwnd
    $rectFull = Get-Rect $hwnd
    Write-Host ("  全屏：style=0x{0:X} rect={1}" -f $styleFull, (Format-Rect $rectFull))
    Assert 'WS_POPUP 生效（无边框）' (($styleFull -band $WS_POPUP) -ne 0)
    Assert '标题栏/可调整边框被去掉' ((($styleFull -band $WS_CAPTION) -eq 0) -and (($styleFull -band $WS_THICKFRAME) -eq 0))
    Assert '窗口矩形等于显示器矩形' (Rect-Equals $rectFull $monitorRect) (Format-Rect $rectFull)
    Assert '进程仍在运行' (-not $proc.HasExited)

    Write-Host ''
    Write-Host '== F11 退出全屏 =='
    Send-F11 $hwnd
    $styleAfter = Get-Style $hwnd
    $rectAfter = Get-Rect $hwnd
    Write-Host ("  还原：style=0x{0:X} rect={1}" -f $styleAfter, (Format-Rect $rectAfter))
    Assert '样式回到带标题栏的窗口' (($styleAfter -band $WS_CAPTION) -ne 0)
    Assert '不再是 WS_POPUP' (($styleAfter -band $WS_POPUP) -eq 0)
    Assert '位置尺寸回到进入全屏前' (Rect-Equals $rectAfter $rectBefore) (Format-Rect $rectAfter)
    Assert '进程仍在运行' (-not $proc.HasExited)

    Write-Host ''
    Write-Host '== 连续切换不残留 =='
    Send-F11 $hwnd
    Send-F11 $hwnd
    Send-F11 $hwnd
    $styleOdd = Get-Style $hwnd
    $rectOdd = Get-Rect $hwnd
    Assert '奇数次后处于全屏' (($styleOdd -band $WS_POPUP) -ne 0) (Format-Rect $rectOdd)
    Send-F11 $hwnd
    $styleEven = Get-Style $hwnd
    $rectEven = Get-Rect $hwnd
    Assert '偶数次后回到原位置' ((($styleEven -band $WS_POPUP) -eq 0) -and (Rect-Equals $rectEven $rectBefore)) (Format-Rect $rectEven)
} finally {
    Start-Sleep -Milliseconds 300
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    if ($sandbox -ne '') {
        Start-Sleep -Milliseconds 500
        Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
Write-Host ("结果：$pass 通过 / $fail 失败")
if ($fail -gt 0) { exit 1 }
