# Windows 发布包启动冒烟（只能在 Windows 上跑）
#
# 为什么需要它：hlh.26 的回归不是编译错误，而是「装完一启动就报应用初始化失败」
# （MissingPluginException：桌面端没实现的平台通道）。`flutter analyze` 和单元断言
# 都发现不了，必须真的把 exe 跑起来看它能不能活过前十几秒。
#
# 做法：把发布 zip 解到干净的临时目录（模拟用户刚解压），启动 exe，等若干秒，
# 检查进程是否还活着、退出码是否异常、事件日志里有没有对应的崩溃记录。
# 全程不碰用户真实安装目录。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\smoke-windows-build.ps1 -Zip C:\path\to\dist.zip
#   ... -Seconds 20      # 观察更久（默认 12 秒）
param(
    [Parameter(Mandatory = $true)][string]$Zip,
    [int]$Seconds = 12
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Zip)) {
    Write-Host "找不到 zip：$Zip"
    exit 2
}

$sandbox = Join-Path $env:TEMP ('gl-smoke-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $sandbox | Out-Null
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

$started = Get-Date
try {
    Write-Host "解压到 $sandbox"
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($Zip, $sandbox)

    $exe = Join-Path $sandbox 'gardendless_loader.exe'
    Assert '包里根目录有 gardendless_loader.exe' (Test-Path $exe)
    Assert '带 Flutter 运行时（data\app.so）' (Test-Path (Join-Path $sandbox 'data\app.so'))
    Assert '带 CEF 运行时（libcef.dll）' (Test-Path (Join-Path $sandbox 'libcef.dll'))
    Assert '带 WebView2 加载器（webview_cef_plugin.dll）' (Test-Path (Join-Path $sandbox 'webview_cef_plugin.dll'))

    Write-Host "启动 exe，观察 $Seconds 秒..."
    $proc = Start-Process -FilePath $exe -WorkingDirectory $sandbox -PassThru
    Start-Sleep -Seconds $Seconds
    $proc.Refresh()
    $alive = -not $proc.HasExited
    Assert "启动后 $Seconds 秒仍在运行" $alive $(if ($alive) { "pid=$($proc.Id)" } else { "exit=$($proc.ExitCode)" })

    # 事件日志里出现 .NET/APPCRASH 记录通常意味着启动就崩（进程可能已经被 WER 拉起过）。
    $errors = Get-WinEvent -FilterHashtable @{
        LogName   = 'Application'
        StartTime = $started
        Level     = 1, 2
    } -ErrorAction SilentlyContinue | Where-Object {
        $_.Message -match 'gardendless_loader|flutter_windows|libcef'
    }
    Assert '事件日志里没有本次启动的崩溃记录' ($null -eq $errors) $(if ($errors) { $errors[0].ProviderName } else { $null })

    if ($alive) {
        # 应用自己的日志是内存态的，落盘证据只有设置文件；这里只确认进程能被正常结束。
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    }
} finally {
    Start-Sleep -Milliseconds 500
    Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("结果：$pass 通过 / $fail 失败")
if ($fail -gt 0) { exit 1 }
