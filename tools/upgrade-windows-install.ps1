# 用发布 zip 原位替换 Windows 安装目录（无需点界面，失败自动回滚）
#
# 为什么需要它：内置更新要「应用退出 → 外部脚本覆盖」，一旦脚本出问题（旧版本
# 没有回执、robocopy 卡在占用文件上），用户面前只剩空桌面、也不知道坏在哪。
# 这个脚本把同样的动作放在前台做，每一步都有断言，失败立刻从备份回滚。
#
# 保留 <安装目录>\downloads：资源包、更新 zip 都在里面，替换不应碰它。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\upgrade-windows-install.ps1 `
#       -Zip C:\path\to\gardendless-loader-x.y.z-nnnnn-windows-x64.zip `
#       -Target 'D:\Program Files\gardendless-loader'
#
# 成功后 <Target>.backup 会保留一份旧版本（不含 downloads），确认新版本正常后可删。
param(
    [Parameter(Mandatory = $true)][string]$Zip,
    [Parameter(Mandatory = $true)][string]$Target,
    [string]$ExpectVersion = '',
    [switch]$KeepBackup,
    [int]$SmokeSeconds = 12
)

$ErrorActionPreference = 'Stop'
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

$Target = $Target.TrimEnd('\')
$backup = $Target + '.backup'
$stage = Join-Path $env:TEMP ('gl-upgrade-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$downloads = Join-Path $Target 'downloads'
$versionBefore = (Get-Item (Join-Path $Target 'gardendless_loader.exe')).VersionInfo.ProductVersion
# 只有「备份完整 + 已经开始覆盖」才允许回滚：拿半成品备份去 /MIR 会把安装目录删残。
$backupOk = $false
$copyStarted = $false

if (-not (Test-Path -LiteralPath $Zip)) { Write-Host "找不到 zip：$Zip"; exit 2 }
if (-not (Test-Path (Join-Path $Target 'gardendless_loader.exe'))) {
    Write-Host "目标目录不像安装目录（没有 gardendless_loader.exe）：$Target"
    exit 2
}

# 替换前记录 downloads 的大小与文件数，结束后必须一模一样。
$dlBefore = @(Get-ChildItem $downloads -Recurse -File -ErrorAction SilentlyContinue)
$dlBytesBefore = ($dlBefore | Measure-Object Length -Sum).Sum
$dlCountBefore = $dlBefore.Count
Write-Host "安装目录：$Target（当前 $versionBefore）"
Write-Host "downloads：$dlCountBefore 个文件 / $([math]::Round($dlBytesBefore/1MB,1)) MB（必须保持不变）"

# 1. 停掉正在运行的加载器（含 CEF 子进程）
$running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.Path -and $_.Path.StartsWith($Target + '\', [System.StringComparison]::OrdinalIgnoreCase)
})
if ($running.Count -gt 0) {
    Write-Host "结束正在运行的进程：$(($running | ForEach-Object { $_.ProcessName }) -join ', ')"
    $running | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 3
}
Assert '替换前没有残留进程' (@(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.Path -and $_.Path.StartsWith($Target + '\', [System.StringComparison]::OrdinalIgnoreCase)
}).Count -eq 0)

function Invoke-Robocopy([string]$Source, [string]$Destination, [string]$Flags) {
    $arg = '"' + $Source + '" "' + $Destination + '" ' + $Flags + ' /R:2 /W:1 /NFL /NDL /NJH /NJS /NP'
    $p = Start-Process robocopy -ArgumentList $arg -Wait -PassThru -NoNewWindow
    return $p.ExitCode
}

try {
    # 2. 解压到暂存目录并校验
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($Zip, $stage)
    Assert '包里有 gardendless_loader.exe' (Test-Path (Join-Path $stage 'gardendless_loader.exe'))
    Assert '包里有 Flutter 运行时（data\app.so）' (Test-Path (Join-Path $stage 'data\app.so'))
    if ($fail -gt 0) { throw '暂存包不完整，未动安装目录' }

    # 3. 备份（排除 downloads：资源包上 GB，替换不该复制它）
    if (Test-Path $backup) { Remove-Item $backup -Recurse -Force }
    $rc = Invoke-Robocopy $Target $backup ("/MIR /XD `"$downloads`"")
    Assert '备份成功（robocopy < 8）' ($rc -lt 8) $rc
    if ($rc -ge 8) {
        Remove-Item $backup -Recurse -Force -ErrorAction SilentlyContinue
        throw '备份失败，未动安装目录'
    }
    $backupOk = $true

    # 4. 覆盖：/E 只增不减，旧版本独有的文件保留
    $copyStarted = $true
    $rc = Invoke-Robocopy $stage $Target ("/E /XD `"$downloads`"")
    Assert '覆盖成功（robocopy < 8）' ($rc -lt 8) $rc
    if ($rc -ge 8) { throw '覆盖失败，开始回滚' }

    # 5. 校验
    $ver = (Get-Item (Join-Path $Target 'gardendless_loader.exe')).VersionInfo.ProductVersion
    if ([string]::IsNullOrWhiteSpace($ExpectVersion)) {
        Assert 'exe 版本已变化' ($ver -ne $versionBefore) "$versionBefore -> $ver"
    } else {
        Assert "exe 版本为 $ExpectVersion" ($ver -match [regex]::Escape($ExpectVersion)) $ver
    }
    $dlAfter = @(Get-ChildItem $downloads -Recurse -File -ErrorAction SilentlyContinue)
    $dlBytesAfter = ($dlAfter | Measure-Object Length -Sum).Sum
    Assert 'downloads 文件数未变' ($dlAfter.Count -eq $dlCountBefore) "$($dlAfter.Count) vs $dlCountBefore"
    Assert 'downloads 字节数未变' ($dlBytesAfter -eq $dlBytesBefore) "$([math]::Round($dlBytesAfter/1MB,1)) MB vs $([math]::Round($dlBytesBefore/1MB,1)) MB"

    # 6. 启动冒烟：能活过十几秒、事件日志没有崩溃记录
    $started = Get-Date
    $proc = Start-Process -FilePath (Join-Path $Target 'gardendless_loader.exe') -WorkingDirectory $Target -PassThru
    Start-Sleep -Seconds $SmokeSeconds
    $proc.Refresh()
    $alive = -not $proc.HasExited
    Assert "启动后 $SmokeSeconds 秒仍在运行" $alive $(if ($alive) { "pid=$($proc.Id)" } else { "exit=$($proc.ExitCode)" })
    $errors = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $started; Level = 1, 2 } -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match 'gardendless_loader|flutter_windows|libcef' }
    Assert '事件日志没有本次启动的崩溃记录' ($null -eq $errors) $(if ($errors) { $errors[0].ProviderName } else { $null })
    if ($alive) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }

    if ($fail -gt 0) { throw '校验未通过，开始回滚' }
    Write-Host ''
    Write-Host "升级成功。备份保留在：$backup（确认新版本正常后可删）"
} catch {
    Write-Host ''
    Write-Host ("!! " + $_.Exception.Message + " -> 回滚")
    if ($backupOk -and $copyStarted) {
        $rc = Invoke-Robocopy $backup $Target ("/MIR /XD `"$downloads`"")
        Assert '回滚执行（robocopy < 8）' ($rc -lt 8) $rc
        $ver = (Get-Item (Join-Path $Target 'gardendless_loader.exe')).VersionInfo.ProductVersion
        Assert '回滚后 exe 回到替换前版本' ($ver -eq $versionBefore) "$versionBefore -> $ver"
    } else {
        Write-Host '   还没开始覆盖，安装目录保持原样'
    }
} finally {
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    if (-not $KeepBackup -and $fail -gt 0 -and (Test-Path $backup)) {
        Write-Host "保留备份以便人工检查：$backup"
    }
}

Write-Host ''
Write-Host ("结果：$pass 通过 / $fail 失败")
if ($fail -gt 0) { exit 1 }
