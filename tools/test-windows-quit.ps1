# Windows 退出路径实机验收（只能在 Windows 上跑）
#
# 为什么需要：2026-10-27 用户点「退出并自动更新」后加载器消失，事件日志里却留下
# 一条 `gardendless_loader.exe` 的 0xc0000409（ucrtbase.dll）崩溃——Dart 侧
# `exit(0)` 硬终止进程时 CEF 的线程还在跑，CRT teardown fail-fast。
# 现在改成走窗口通道 `quit`（PostMessage WM_CLOSE），让 runner 自己结束消息
# 循环。这个脚本验证的是同一条原生路径：给主窗口发 WM_CLOSE，进程必须
# 干净退出（退出码 0、没有崩溃事件、没有残留进程）。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\test-windows-quit.ps1 `
#       -Exe 'build\windows\x64\runner\Release\gardendless_loader.exe'
#   ... -Zip dist\gardendless-loader-0.9.0-hlh.29-90029-windows-x64.zip   # 直接测发布包
param(
    [string]$Exe = '',
    [string]$Zip = '',
    [int]$SettleMs = 1500
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$sandbox = ''
if (-not [string]::IsNullOrWhiteSpace($Zip)) {
    if (-not (Test-Path -LiteralPath $Zip)) { Write-Host "找不到 zip：$Zip"; exit 2 }
    $sandbox = Join-Path $env:TEMP ('gl-quit-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
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
using System.Text;
public static class QuitProbe {
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc callback, IntPtr lParam);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder name, int max);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
  public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
}
'@

$WM_CLOSE = 0x0010
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

# ssh 会话里起的 GUI 进程窗口永远「不可见」（MainWindowHandle 恒为 0，已发布版
# 也一样），所以按 PID + 窗口类名枚举。WM_CLOSE 对隐藏窗口同样有效。
function Find-AppWindow([int]$processId) {
    $script:foundWindow = [IntPtr]::Zero
    $callback = [QuitProbe+EnumProc]{
        param($hWnd, $lParam)
        $owner = 0
        [void][QuitProbe]::GetWindowThreadProcessId($hWnd, [ref]$owner)
        if ($owner -eq $processId) {
            $name = New-Object System.Text.StringBuilder 256
            [void][QuitProbe]::GetClassName($hWnd, $name, 256)
            $class = $name.ToString()
            if ($class -like 'FLUTTER*' -or $class -like '*Gardendless*') {
                $script:foundWindow = $hWnd
                return $false
            }
        }
        return $true
    }
    [void][QuitProbe]::EnumWindows($callback, [IntPtr]::Zero)
    return $script:foundWindow
}

Write-Host "启动 $Exe"
$startedAt = Get-Date
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
    Assert '启动后找到加载器窗口' ($hwnd -ne [IntPtr]::Zero) $hwnd
    if ($hwnd -eq [IntPtr]::Zero) { throw '没有窗口，后续无从验证' }

    Start-Sleep -Milliseconds $SettleMs   # 等首帧，避免刚起来就被关掉

    Write-Host '== 发 WM_CLOSE（窗口通道 quit 走的就是这条路径）=='
    [void][QuitProbe]::PostMessage($hwnd, $WM_CLOSE, [IntPtr]0, [IntPtr]0)
    $exited = $proc.WaitForExit(15000)
    Assert '15 秒内退出（没有卡在 CEF 清理上）' $exited
    if ($exited) {
        Assert '退出码 0' ($proc.ExitCode -eq 0) $proc.ExitCode
    }

    # 崩溃事件是这次要修掉的症状：0xc0000409 只会在硬终止/teardown 出错时出现。
    Start-Sleep -Milliseconds 800
    $crashEvents = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $startedAt; Id = 1000 } -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -like '*gardendless_loader.exe*' })
    Assert '没有留下应用崩溃事件（0xc0000409）' ($crashEvents.Count -eq 0) ("count=" + $crashEvents.Count)
    if ($crashEvents.Count -gt 0) {
        Write-Host ('    ' + (($crashEvents[0].Message -split "`n")[0]))
    }
    # webview_cef 的 CEF 辅助进程与主进程同名（`gardendless_loader.exe
    # --type=gpu-process`），所以按进程名断言就能覆盖「主进程没了、helper 还活着」
    # 这种孤儿——它们会占住安装目录里的 libcef.dll，让下一次覆盖失败。
    Assert '没有残留加载器进程（含 CEF 辅助进程）' (@(Get-Process gardendless_loader -ErrorAction SilentlyContinue).Count -eq 0)
} finally {
    Start-Sleep -Milliseconds 300
    Get-Process gardendless_loader -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    if ($sandbox -ne '') {
        Start-Sleep -Milliseconds 500
        Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
Write-Host ("结果：$pass 通过 / $fail 失败")
if ($fail -gt 0) { exit 1 }
