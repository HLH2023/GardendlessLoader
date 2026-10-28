# Windows 更新脚本实机测试（只能在 Windows 上跑，Linux 没有 PowerShell/robocopy）
#
# 为什么需要它：更新发生在应用退出之后，本机（Linux）只能断言脚本文本里「有没有
# 写回执/有没有 /XD/有没有兜底 catch」，但没法证明脚本真的能把文件换掉、失败真的
# 会回滚、downloads 真的没被删。这些都只有真机跑一遍才知道。
#
# 覆盖的路径：
#   1. 正常覆盖            -> applied，exe 被替换，downloads 保留，备份与 zip 清掉
#   2. 坏 zip              -> failed/expand-failed，安装目录一字未动
#   3. 包里没有目标 exe    -> failed/stage-missing-exe，安装目录一字未动
#   4. 文件连读都读不了    -> failed/backup-failed，不留半成品备份
#   5. 只有写失败          -> rolled-back/copy-failed，回到旧版本（真实场景：CEF 占着 exe）
#   6. 盘符根目录          -> failed/unsafe-target，拒绝执行
#   7. 应用 120 秒没退出   -> failed/app-still-running（-IncludeSlow 才跑，要等 2 分钟）
#   8. 真实发布包          -> 用 dist 里的正式 zip 跑一遍（-RealZip <zip>，验证包结构、
#                             解压耗时与「exe 在根目录」；Compress-Archive 写的 zip 条目
#                             用反斜杠分隔，.NET 的 ExtractToDirectory 必须能吃下）
#
# 全程只用 %TEMP% 下的沙箱目录，路径故意带空格（等价于 Program Files），用来验证
# robocopy 参数引号。不会碰到真实安装目录。
#
# 用法（在 Windows 上）：
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\test-windows-updater.ps1
#   ... -Root C:\Users\s2681\GardendlessLoader-src -IncludeSlow
param(
    [string]$Root = '',
    [string]$Dart = 'dart',
    [switch]$NoClean,
    [switch]$IncludeSlow,
    [string]$RealZip = ''
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}
if (-not (Test-Path (Join-Path $Root 'lib\src\services\windows_updater.dart'))) {
    Write-Host "找不到仓库根：$Root"
    exit 2
}

# 1. 取脚本：每次都重新生成（与应用运行时同一份常量）。
#    不要缓存：改成「已存在就复用」后，改完脚本文本仍然会跑上一轮那份旧脚本，
#    测试全绿但测的不是当前代码（2026-10-27 自查发现）。
$scriptPath = Join-Path $Root 'build\windows-updater.ps1'
$dir = Split-Path -Parent $scriptPath
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
Push-Location $Root
try {
    & $Dart run tool\print_windows_updater.dart 'build\windows-updater.ps1'
    if ($LASTEXITCODE -ne 0) { throw "生成更新脚本失败（dart exit $LASTEXITCODE）" }
} finally { Pop-Location }

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

$sandboxRoot = Join-Path $env:TEMP 'gl updater test'
if (Test-Path $sandboxRoot) { Remove-Item $sandboxRoot -Recurse -Force }
New-Item -ItemType Directory -Force -Path $sandboxRoot | Out-Null
# 上一轮被中断的运行会留下 gl-update-* 解压目录，先清掉，否则「无残留」断言会误报。
Get-ChildItem $env:TEMP -Filter 'gl-update-*' -Directory -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

# 假安装目录：名字带空格（等价于 Program Files），含 downloads 与仅旧版本才有的文件。
function New-FakeInstall([string]$Name) {
    $parent = Join-Path $sandboxRoot $Name
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $target = Join-Path $parent 'gardendless loader'
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Set-Content -LiteralPath (Join-Path $target 'gardendless_loader.exe') -Value 'OLD-EXE' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $target 'flutter_windows.dll') -Value 'OLD-DLL' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $target 'only-in-old.txt') -Value 'user file' -Encoding ASCII
    $dl = Join-Path $target 'downloads'
    New-Item -ItemType Directory -Force -Path $dl | Out-Null
    # 模拟 1 GB 资源包：只关心它是否被保留，内容大小无所谓。
    Set-Content -LiteralPath (Join-Path $dl 'pvzge-res-0.16.1.zip') -Value ('RESOURCE' * 2000) -Encoding ASCII
    return $target
}

function New-FakeZip([string]$Path, [string]$ExeContent, [switch]$WithExe) {
    $stage = Join-Path $sandboxRoot ('stage-' + [guid]::NewGuid().ToString('N'))
    $dataDir = Join-Path $stage 'data'
    New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
    Set-Content -LiteralPath (Join-Path $dataDir 'icudtl.dat') -Value 'NEW-DATA' -Encoding ASCII
    if ($WithExe) {
        Set-Content -LiteralPath (Join-Path $stage 'gardendless_loader.exe') -Value $ExeContent -Encoding ASCII
    }
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $Path -Force
    Remove-Item $stage -Recurse -Force
}

# 用 & 直接调子进程（数组 splat）：Start-Process -ArgumentList 会把数组用空格拼成
# 一个字符串，沙箱路径里的空格（等价于 Program Files）就会被拆断。
function Invoke-Updater([string]$Zip, [string]$Target, [string]$Result, [string]$WaitPid = '999999') {
    $psArgs = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath,
        '-WaitPid', $WaitPid,
        '-Zip', $Zip,
        '-Target', $Target,
        '-Exe', 'gardendless_loader.exe',
        '-FromVersion', '0.9.0-hlh.26',
        '-ToVersion', '0.9.0-hlh.27',
        '-Result', $Result,
        '-NoLaunch',                     # 测试里不真的启动应用
        '-NoUi'                          # 进度窗口只在 case 9 里验证
    )
    & powershell @psArgs | Out-Null
    return $LASTEXITCODE
}

function Read-Result([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    $raw = [System.IO.File]::ReadAllText($Path)
    try { return ($raw | ConvertFrom-Json) } catch { return $null }
}

function Wait-ForResult([string]$Path, [int]$TimeoutSeconds = 120) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (Test-Path $Path) {
            $r = Read-Result $Path
            if ($null -ne $r -and $r.status -ne 'pending') { return $r }
        }
        Start-Sleep -Milliseconds 250
    }
    return $null
}

function Read-File([string]$Path) {
    if (-not (Test-Path $Path)) { return '<missing>' }
    return (Get-Content -LiteralPath $Path -Raw).Trim()
}

function Assert-NoLeftovers([string]$Target) {
    Assert '备份目录已清理' (-not (Test-Path ($Target + '.backup')))
    Assert '临时解压目录未残留' (
        @(Get-ChildItem $env:TEMP -Filter 'gl-update-*' -Directory -ErrorAction SilentlyContinue).Count -eq 0)
}

Write-Host "更新脚本：$scriptPath"

# --- 1. 正常覆盖 -------------------------------------------------------------
Write-Host ''
Write-Host '== 1. 正常覆盖（applied）=='
$target = New-FakeInstall 'applied'
$zip = Join-Path (Split-Path -Parent $target) 'update.zip'
$result = Join-Path (Split-Path -Parent $target) 'windows_update_result.json'
New-FakeZip -Path $zip -ExeContent 'NEW-EXE' -WithExe
$code = Invoke-Updater -Zip $zip -Target $target -Result $result
$r = Read-Result $result
Assert '退出码 0' ($code -eq 0) $code
Assert '回执可解析' ($null -ne $r)
Assert '回执 status=applied' ($r.status -eq 'applied') $r.status
Assert '回执 code=ok' ($r.code -eq 'ok') $r.code
Assert '回执带 toVersion' ($r.toVersion -eq '0.9.0-hlh.27') $r.toVersion
Assert '回执带脚本日志路径' (-not [string]::IsNullOrWhiteSpace($r.logFile)) $r.logFile
Assert 'exe 被替换成新版本' ((Read-File (Join-Path $target 'gardendless_loader.exe')) -eq 'NEW-EXE')
Assert '新增文件已就位' (Test-Path (Join-Path $target 'data\icudtl.dat'))
Assert 'downloads 资源包被保留' (Test-Path (Join-Path $target 'downloads\pvzge-res-0.16.1.zip'))
Assert 'downloads 内容未被改动' ((Read-File (Join-Path $target 'downloads\pvzge-res-0.16.1.zip')).Length -gt 1000)
Assert '旧目录里用户自有文件未被删除' (Test-Path (Join-Path $target 'only-in-old.txt'))
Assert '更新包已删除' (-not (Test-Path $zip))
Assert-NoLeftovers $target
$raw = [System.IO.File]::ReadAllBytes($result)
Assert '回执无 BOM' (-not ($raw.Length -ge 3 -and $raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF))

# --- 2. 坏 zip ---------------------------------------------------------------
Write-Host ''
Write-Host '== 2. 坏 zip（expand-failed）=='
$target = New-FakeInstall 'expand-failed'
$zip = Join-Path (Split-Path -Parent $target) 'broken.zip'
Set-Content -LiteralPath $zip -Value 'this is not a zip' -Encoding ASCII
$result = Join-Path (Split-Path -Parent $target) 'windows_update_result.json'
$code = Invoke-Updater -Zip $zip -Target $target -Result $result
$r = Read-Result $result
Assert '退出码 2' ($code -eq 2) $code
Assert '回执 status=failed' ($r.status -eq 'failed') $r.status
Assert '回执 code=expand-failed' ($r.code -eq 'expand-failed') $r.code
Assert '安装目录未被改动' ((Read-File (Join-Path $target 'gardendless_loader.exe')) -eq 'OLD-EXE')
Assert-NoLeftovers $target

# --- 3. 包里没有目标 exe -----------------------------------------------------
Write-Host ''
Write-Host '== 3. 包缺 exe（stage-missing-exe）=='
$target = New-FakeInstall 'stage-missing-exe'
$zip = Join-Path (Split-Path -Parent $target) 'no-exe.zip'
New-FakeZip -Path $zip -ExeContent 'NEW-EXE'      # 不给 WithExe
$result = Join-Path (Split-Path -Parent $target) 'windows_update_result.json'
$code = Invoke-Updater -Zip $zip -Target $target -Result $result
$r = Read-Result $result
Assert '退出码 2' ($code -eq 2) $code
Assert '回执 code=stage-missing-exe' ($r.code -eq 'stage-missing-exe') $r.code
Assert '安装目录未被改动' ((Read-File (Join-Path $target 'gardendless_loader.exe')) -eq 'OLD-EXE')
Assert-NoLeftovers $target

# --- 4. 备份就失败（文件连读都拿不到）---------------------------------------
Write-Host ''
Write-Host '== 4. 备份失败（backup-failed）=='
$target = New-FakeInstall 'backup-failed'
$zip = Join-Path (Split-Path -Parent $target) 'backup-failed.zip'
New-FakeZip -Path $zip -ExeContent 'NEW-EXE' -WithExe
$result = Join-Path (Split-Path -Parent $target) 'windows_update_result.json'
# FileShare::None：别的进程连读都不行 -> robocopy 备份那一步就失败。
$handle = [System.IO.File]::Open((Join-Path $target 'gardendless_loader.exe'),
    [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
try {
    $code = Invoke-Updater -Zip $zip -Target $target -Result $result
} finally { $handle.Dispose() }
$r = Read-Result $result
Assert '退出码 3' ($code -eq 3) $code
Assert '回执 code=backup-failed' ($r.code -eq 'backup-failed') $r.code
Assert '安装目录未被改动' ((Read-File (Join-Path $target 'gardendless_loader.exe')) -eq 'OLD-EXE')
Assert-NoLeftovers $target

# --- 5. 复制失败 -> 回滚 -----------------------------------------------------
Write-Host ''
Write-Host '== 5. 复制失败（rolled-back）=='
$target = New-FakeInstall 'rollback'
$zip = Join-Path (Split-Path -Parent $target) 'rollback.zip'
New-FakeZip -Path $zip -ExeContent 'NEW-EXE' -WithExe
$result = Join-Path (Split-Path -Parent $target) 'windows_update_result.json'
$locked = Join-Path $target 'gardendless_loader.exe'
# FileShare::Read：可读不可写 —— 真实场景（应用/CEF 还占着 exe）。备份读得动，
# 覆盖写不进去，于是走回滚。用 FileShare::None 会连备份都失败，测不到回滚。
$handle = [System.IO.File]::Open($locked, [System.IO.FileMode]::Open,
    [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
try {
    $code = Invoke-Updater -Zip $zip -Target $target -Result $result
} finally { $handle.Dispose() }
$r = Read-Result $result
Assert '退出码 4' ($code -eq 4) $code
Assert '回执 status=rolled-back' ($r.status -eq 'rolled-back') $r.status
Assert '回执 code=copy-failed' ($r.code -eq 'copy-failed') $r.code
Assert 'exe 还是旧版本' ((Read-File $locked) -eq 'OLD-EXE') (Read-File $locked)
Assert '失败复制进来的新文件被回滚删除' (-not (Test-Path (Join-Path $target 'data\icudtl.dat')))
Assert '下载目录仍完整' (Test-Path (Join-Path $target 'downloads\pvzge-res-0.16.1.zip'))
Assert '旧版本独有的文件仍在' (Test-Path (Join-Path $target 'only-in-old.txt'))
Assert-NoLeftovers $target

# --- 6. 盘符根目录 -----------------------------------------------------------
Write-Host ''
Write-Host '== 6. 盘符根目录（unsafe-target）=='
$zip = Join-Path $sandboxRoot 'unsafe.zip'
New-FakeZip -Path $zip -ExeContent 'NEW-EXE' -WithExe
$result = Join-Path $sandboxRoot 'unsafe-result.json'
$code = Invoke-Updater -Zip $zip -Target 'C:\' -Result $result
$r = Read-Result $result
Assert '退出码 5' ($code -eq 5) $code
Assert '回执 code=unsafe-target' ($r.code -eq 'unsafe-target') $r.code
Assert '没有在盘符根目录留下备份' (-not (Test-Path 'C:\.backup'))

# --- 7. 应用没退出（可选，要等 120 秒）--------------------------------------
if ($IncludeSlow) {
    Write-Host ''
    Write-Host '== 7. 120 秒内未退出（app-still-running）=='
    $target = New-FakeInstall 'still-running'
    $zip = Join-Path (Split-Path -Parent $target) 'still-running.zip'
    New-FakeZip -Path $zip -ExeContent 'NEW-EXE' -WithExe
    $result = Join-Path (Split-Path -Parent $target) 'windows_update_result.json'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    # 用自己的 PID 冒充「还没退出的应用」。
    $code = Invoke-Updater -Zip $zip -Target $target -Result $result -WaitPid "$PID"
    $sw.Stop()
    $r = Read-Result $result
    Assert '退出码 1' ($code -eq 1) $code
    Assert '回执 code=app-still-running' ($r.code -eq 'app-still-running') $r.code
    Assert '确实等满 120 秒左右' ($sw.Elapsed.TotalSeconds -ge 115 -and $sw.Elapsed.TotalSeconds -le 150) ([math]::Round($sw.Elapsed.TotalSeconds, 1))
    Assert '安装目录未被改动' ((Read-File (Join-Path $target 'gardendless_loader.exe')) -eq 'OLD-EXE')
    Assert-NoLeftovers $target
}

# --- 8. 真实发布包（可选）---------------------------------------------------
if (-not [string]::IsNullOrWhiteSpace($RealZip)) {
    Write-Host ''
    Write-Host "== 8. 真实发布包（$RealZip）=="
    if (-not (Test-Path -LiteralPath $RealZip)) {
        Assert '真实包存在' $false $RealZip
    } else {
        $target = New-FakeInstall 'real-zip'
        $result = Join-Path (Split-Path -Parent $target) 'windows_update_result.json'
        # 真实包不能被删掉，所以先复制一份（脚本成功后会删除 zip）。
        $zip = Join-Path (Split-Path -Parent $target) 'real-package.zip'
        Copy-Item -LiteralPath $RealZip -Destination $zip
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $code = Invoke-Updater -Zip $zip -Target $target -Result $result
        $sw.Stop()
        $r = Read-Result $result
        Assert '退出码 0' ($code -eq 0) $code
        Assert '回执 status=applied' ($r.status -eq 'applied') $r.status
        Assert 'exe 被真实包里的版本替换' ((Read-File (Join-Path $target 'gardendless_loader.exe')) -ne 'OLD-EXE')
        Assert 'flutter 数据目录解压出来' ((Test-Path (Join-Path $target 'data\flutter_assets\AssetManifest.bin')) -or (Test-Path (Join-Path $target 'data\flutter_assets')))
        Assert 'CEF 运行时解压出来' (Test-Path (Join-Path $target 'libcef.dll')) (Test-Path (Join-Path $target 'libcef.dll'))
        Assert 'downloads 资源包被保留' (Test-Path (Join-Path $target 'downloads\pvzge-res-0.16.1.zip'))
        Assert '解压+覆盖耗时合理（<180 秒）' ($sw.Elapsed.TotalSeconds -lt 180) ([math]::Round($sw.Elapsed.TotalSeconds, 1))
        Assert-NoLeftovers $target
    }
}


# --- 9. 通过 Dart 生产代码启动脚本（回归：detached 黑洞）--------------------
# 2026-10-27 用户点「退出并自动更新」后加载器消失、什么都没发生。根因是
# ProcessStartMode.detached 在 Windows 上会返回 pid 但不执行子进程。
# 这一条用生产代码 WindowsUpdaterScript.start() 真跑一遍：Dart 进程 900 ms 后
# 就消失了，脚本必须自己活下来把更新做完（顺带验证进度窗口不会拖垮流程）。
Write-Host ''
Write-Host '== 9. Dart 生产代码启动脚本（父进程退出后仍要跑完）=='
$target = New-FakeInstall 'dart-spawn'
$parent = Split-Path -Parent $target
$result = Join-Path $parent 'windows_update_result.json'
$zip = Join-Path $parent 'dart-package.zip'
$stage = Join-Path $sandboxRoot ('stage-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'data') | Out-Null
Set-Content -LiteralPath (Join-Path $stage 'data\icudtl.dat') -Value 'NEW-DATA' -Encoding ASCII
# 包里放一个真 exe（改名成目标名）：脚本成功后 Relaunch 它；whoami 秒退，
# 这样「重启加载器」这一步也真被执行，又不会留下进程。
Copy-Item -LiteralPath (Join-Path $env:WINDIR 'System32\whoami.exe') -Destination (Join-Path $stage 'gardendless_loader.exe')
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force
Remove-Item $stage -Recurse -Force

$sw = [System.Diagnostics.Stopwatch]::StartNew()
Push-Location $Root
try {
    $out = & $Dart run tools\windows_update_spawn_check.dart $zip $target $result '0.9.0-hlh.29' 2>&1
    $code = $LASTEXITCODE
} finally {
    Pop-Location
}
$text = ($out | Out-String).Trim()
Assert 'Dart 侧确认子进程在运行' ($text -match 'child-running') ($text -replace '\s+', ' ')
Assert 'Dart 侧退出码 0' ($code -eq 0) $code
$r = Wait-ForResult $result 120
$sw.Stop()
Assert '脚本在父进程退出后写出了回执' ($null -ne $r) $(if ($null -ne $r) { $r.status } else { 'missing' })
Assert '回执 status=applied' ($null -ne $r -and $r.status -eq 'applied') $(if ($null -ne $r) { $r.status } else { 'missing' })
Assert '安装目录被真的覆盖（exe 换成了包里的）' (
    (Test-Path (Join-Path $target 'gardendless_loader.exe')) -and
    ((Get-Item (Join-Path $target 'gardendless_loader.exe')).Length -gt 1000))
Assert 'downloads 资源包被保留' (Test-Path (Join-Path $target 'downloads\pvzge-res-0.16.1.zip'))
Assert '更新包已删除' (-not (Test-Path $zip))
Assert '耗时合理（<120 秒，含 dart 编译）' ($sw.Elapsed.TotalSeconds -lt 120) ([math]::Round($sw.Elapsed.TotalSeconds, 1))
# 这一轮没有 -NoUi：用来证明「用户能看到的那个窗口」真的建起来了。
# 建不起来时脚本会降级（Say 'progress ui unavailable'），更新照样成功——
# 所以要单独断言，不然窗口挂了也测试全绿（用户看到的还是「点了就消失」）。
$logText = ''
if ($null -ne $r -and -not [string]::IsNullOrWhiteSpace($r.logFile) -and (Test-Path $r.logFile)) {
    $logText = Get-Content -LiteralPath $r.logFile -Raw
}
Assert '进度窗口创建成功（没有静默降级）' (
    $logText -ne '' -and $logText -notmatch 'progress ui unavailable'
) ($r.logFile)
Assert-NoLeftovers $target

# --- 汇总 -------------------------------------------------------------------
Write-Host ''
if (-not $NoClean) { Remove-Item $sandboxRoot -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host ("结果：$pass 通过 / $fail 失败")
if ($fail -gt 0) { exit 1 }
