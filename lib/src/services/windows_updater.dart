import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 生成并投递 Windows 更新脚本。
///
/// 为什么必须用外部进程：安装目录里的 exe/dll 正在被当前进程与 CEF 子进程
/// 占用，Windows 不允许覆盖运行中的文件。应用先启动脚本、再退出；脚本等到
/// 进程消失后解压覆盖，最后重新拉起。
///
/// 「结果回执」为什么是这个脚本的一部分：应用点完「立即更新」立刻 exit(0)，
/// 覆盖发生在退出之后，用户在当前进程里看不到任何进度，也无法知道成功与否。
/// 因此每条退出路径都要写一份 JSON 回执（`-Result`），下一次启动由 Dart 读出来
/// 变成提示；失败路径还要把加载器重新拉起来，否则用户面前只剩一个空桌面。
///
/// 安全边界：
///  - 只接受调用方已用清单 sha256 校验过的 zip；
///  - 解压后必须存在目标 exe，否则不动安装目录；
///  - 替换前整目录镜像备份，robocopy 失败（退出码 ≥8）自动回滚；
///  - 拒绝盘符根目录，避免把整个磁盘当安装目录备份/覆盖。
class WindowsUpdaterScript {
  const WindowsUpdaterScript._();

  /// 脚本用 UTF-8 BOM + CRLF 写盘：PowerShell 5.1 读无 BOM 的中文/特殊字符
  /// 会按 ANSI 解码，直接语法错误（与 tools/build-windows.ps1 同一个坑）。
  static const script = r'''param(
    [Parameter(Mandatory = $true)][int]$WaitPid,
    [Parameter(Mandatory = $true)][string]$Zip,
    [Parameter(Mandatory = $true)][string]$Target,
    [Parameter(Mandatory = $true)][string]$Exe,
    [string]$FromVersion = '',
    [string]$ToVersion = '',
    [string]$Result = '',
    [switch]$NoLaunch,
    # 测试用：不弹进度窗口（默认弹，见 Initialize-ProgressUi）。
    [switch]$NoUi
)
$ErrorActionPreference = 'Stop'
$log = Join-Path $env:TEMP ("gardendless-update-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".log")
function Say([string]$m) {
    # 写日志失败（临时目录被清理/权限）不能反过来打断更新。
    try {
        Add-Content -LiteralPath $log -Value ((Get-Date -Format 'HH:mm:ss') + ' ' + $m) -Encoding UTF8
    } catch { }
}

# 结果回执：应用重启后据此告诉用户「更新成功 / 已回滚 / 失败原因」。
# 每一条退出路径都必须写，否则用户只会看到窗口消失，不知道发生了什么。
function Write-Result([string]$status, [string]$code, [string]$message) {
    if ([string]::IsNullOrWhiteSpace($Result)) { return }
    try {
        $dir = Split-Path -Parent $Result
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
        $payload = [ordered]@{
            status      = $status
            code        = $code
            message     = $message
            fromVersion = $FromVersion
            toVersion   = $ToVersion
            target      = $Target
            logFile     = $log
            at          = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        }
        $json = $payload | ConvertTo-Json -Depth 4
        # 不写 BOM：Dart 侧直接 jsonDecode。
        [System.IO.File]::WriteAllText(
            $Result, $json, [System.Text.UTF8Encoding]::new($false))
        Say ("result: " + $status + " / " + $code)
    } catch {
        Say ("result write failed: " + $_.Exception.Message)
    }
}

# 进度窗口：应用已经退出，如果这里什么都不显示，用户面对的就是一个空桌面，
# 完全不知道机器在干什么（2026-10-27 用户反馈「点完就消失了，也不知道有没有
# 更新完」）。所以脚本自己弹一个「正在更新」的无主窗口。
#
# 整个 UI 都是尽力而为：Add-Type/窗体在任何一步失败（无交互桌面、Session 0、
# 精简版系统）都只是没有窗口，绝不能让更新本身中断——这条路径以前已经因为
# 「为了提示而多做一步」踩过坑。
$script:uiForm = $null
$script:uiLabel = $null

function Initialize-ProgressUi {
    if ($NoUi) { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $form = New-Object System.Windows.Forms.Form
        $form.Text = 'Gardendless 更新'
        $form.ClientSize = New-Object System.Drawing.Size(420, 132)
        $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        $form.MaximizeBox = $false
        $form.MinimizeBox = $false
        $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $form.TopMost = $true
        $form.ShowInTaskbar = $true
        $label = New-Object System.Windows.Forms.Label
        $label.SetBounds(18, 18, 384, 44)
        $label.Text = '正在准备更新…'
        $bar = New-Object System.Windows.Forms.ProgressBar
        $bar.SetBounds(18, 72, 384, 16)
        $bar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
        $bar.MarqueeAnimationSpeed = 30
        $hint = New-Object System.Windows.Forms.Label
        $hint.SetBounds(18, 96, 384, 24)
        $hint.Text = '更新完成后会自动重新打开加载器，请不要手动启动它。'
        $hint.ForeColor = [System.Drawing.Color]::DimGray
        $form.Controls.Add($label)
        $form.Controls.Add($bar)
        $form.Controls.Add($hint)
        $form.Show()
        [System.Windows.Forms.Application]::DoEvents()
        $script:uiForm = $form
        $script:uiLabel = $label
    } catch {
        Say ("progress ui unavailable: " + $_.Exception.Message)
        $script:uiForm = $null
        $script:uiLabel = $null
    }
}

function Update-Ui([string]$text) {
    if (-not $script:uiForm) { return }
    try {
        $script:uiLabel.Text = $text
        [System.Windows.Forms.Application]::DoEvents()
    } catch {
        # 窗口被用户关掉/句柄失效：只丢掉 UI，不影响更新
        $script:uiForm = $null
        $script:uiLabel = $null
    }
}

function Close-Ui {
    if (-not $script:uiForm) { return }
    try {
        $script:uiForm.Close()
        $script:uiForm.Dispose()
    } catch { }
    $script:uiForm = $null
    $script:uiLabel = $null
}

# 泵一次窗口消息。等待期间必须反复调用它，否则进度窗口在 robocopy 的
# 十几秒里完全没有响应，看起来跟卡死一样。
function Pump-Ui {
    if (-not $script:uiForm) { return }
    try { [System.Windows.Forms.Application]::DoEvents() } catch { $script:uiForm = $null }
}

# 失败也把加载器拉起来：否则用户面前没有窗口，只能自己去目录里找 exe。
# 刚复制完/回滚完时 exe 可能还被上一个进程句柄占着，重试几次。
function Relaunch {
    if ($NoLaunch) { return }
    $exePath = Join-Path $Target $Exe
    for ($i = 0; $i -lt 5; $i++) {
        try {
            Start-Process $exePath
            return
        } catch {
            Say ("relaunch attempt " + ($i + 1) + " failed: " + $_.Exception.Message)
            Start-Sleep -Seconds 1
        }
    }
}

# 安装目录来自 Dart 的 dirname(exe)；盘符根目录会拿整块磁盘做备份/覆盖。
$Target = $Target.TrimEnd('\')
if ($Target -eq '' -or $Target -match '^[A-Za-z]:$') {
    Say "refusing unsafe target: $Target"
    Write-Result 'failed' 'unsafe-target' '安装目录不安全（盘符根目录或空路径），未做任何替换'
    exit 5
}
Say "start pid=$WaitPid zip=$Zip target=$Target to=$ToVersion"

# robocopy 的路径必须显式加引号：-ArgumentList 传数组会被 PowerShell
# 用空格拼成一个字符串，Program Files 这类带空格的路径会被拆成两个参数。
function Invoke-Robocopy([string]$Source, [string]$Destination, [string]$Flags) {
    try {
        # /R:2 /W:1 是硬约束，不能省：robocopy 默认「重试 100 万次 × 等 30 秒」，
        # 只要有一个文件被占用（杀软扫描、CEF 还没退干净），整个更新就会静默挂住，
        # 用户看到的是「应用没重启、也没任何提示」（2026-10-27 Windows 实测复现）。
        # 重试两次仍失败就交给回滚，宁可回滚也不要卡死。
        $arg = '"' + $Source + '" "' + $Destination + '" ' + $Flags + ' /R:2 /W:1'
        # 为什么要用 .NET 的 Process 而不是 `Start-Process -PassThru`：PS 5.1 上
        # 不带 -Wait 的 Start-Process 不保留进程句柄，`HasExited` 会变 true 但
        # `ExitCode` 恒为 $null。于是「robocopy 失败」被当成成功——脚本写出
        # applied 却一个文件都没覆盖，`$rc -ge 8` 的回滚分支永远不触发
        # （2026-10-27 自查：测试用例 4/5 的回滚断言整段失效）。
        $info = New-Object System.Diagnostics.ProcessStartInfo
        $info.FileName = 'robocopy.exe'
        $info.Arguments = $arg
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $info
        [void]$process.Start()
        while (-not $process.HasExited) {
            Pump-Ui
            Start-Sleep -Milliseconds 100
        }
        $process.WaitForExit()
        $rc = $process.ExitCode
        $process.Dispose()
        return $rc
    } catch {
        # robocopy 不存在/被杀软拦下：按「失败不可用」处理，交给调用方回滚判断。
        Say ("robocopy unavailable: " + $_.Exception.Message)
        return 16
    }
}

# 兜底：任何未预料到的异常（杀软拦截、句柄占用、属性访问被拒）都必须留下
# 回执并把加载器拉回来，绝不能让用户面对一个空桌面（2026-10-27 复核）。
try {
    # 1. 等应用自己退出（最多 120 秒）
    Initialize-ProgressUi
    Update-Ui '正在等待加载器退出…'
    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Process -Id $WaitPid -ErrorAction SilentlyContinue) -and ((Get-Date) -lt $deadline)) {
        Pump-Ui
        Start-Sleep -Milliseconds 300
    }
    if (Get-Process -Id $WaitPid -ErrorAction SilentlyContinue) {
        Say 'app did not exit in time'
        Write-Result 'failed' 'app-still-running' '加载器 120 秒内没有退出，本次更新已取消'
        Close-Ui
        # 旧进程还在，不能重启（会变成两个实例）
        exit 1
    }
    # CEF 的辅助进程可能还在退出过程中；只按目标目录边界匹配，
    # 避免把 Gardendless2 之类前缀相同的其它程序一起杀掉。
    # 受保护进程读 .Path 会抛 Access denied：这段整体降级，不能让它中断更新。
    Start-Sleep -Seconds 2
    $targetPrefix = $Target + '\'
    $ErrorActionPreference = 'SilentlyContinue'
    Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Path -and $_.Path.StartsWith($targetPrefix, [System.StringComparison]::OrdinalIgnoreCase)
    } | ForEach-Object {
        Say ("stopping leftover " + $_.ProcessName)
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    }
    $ErrorActionPreference = 'Stop'
    Start-Sleep -Milliseconds 500

    # 2. 解压到临时目录并做最低限度校验
    # 不用 Expand-Archive：PS 5.1 上它对 400 MB+（解压后）的包要跑好几分钟，
    # 期间没有任何输出，用户以为卡死。.NET 的 ZipFile 快一个数量级。
    # ExtractToDirectory 要求目标目录不存在，所以这里故意不预创建。
    $stage = Join-Path $env:TEMP ("gl-update-" + [guid]::NewGuid().ToString('N'))
    Update-Ui '正在解压更新包…'
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($Zip, $stage)
    } catch {
        Say ("expand failed: " + $_.Exception.Message)
        Write-Result 'failed' 'expand-failed' ("解压更新包失败：" + $_.Exception.Message)
        Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
        Close-Ui
        Relaunch
        exit 2
    }
    $newExe = Join-Path $stage $Exe
    if (-not (Test-Path $newExe)) {
        Say ("staged exe missing: " + $newExe)
        Write-Result 'failed' 'stage-missing-exe' '更新包里没有目标 exe，已放弃本次更新'
        Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
        Close-Ui
        Relaunch
        exit 2
    }

    # 3. 备份 + 覆盖；失败则回滚
    $backup = $Target + '.backup'
    # downloads 现在默认就在安装目录里，里面可能有 1 GB+ 的资源包与更新 zip：
    # 备份时不排除它会把整份下载再复制一遍；回滚用 /MIR 更会把这些文件当成
    # 「新版本多出来的文件」删掉。两处都必须 /XD。
    $downloadsDir = Join-Path $Target 'downloads'
    $excludeDownloads = '/XD "' + $downloadsDir + '"'
    if (Test-Path $backup) { Remove-Item $backup -Recurse -Force }
    Update-Ui '正在备份当前版本…'
    $rc = Invoke-Robocopy $Target $backup ('/MIR /NFL /NDL /NJH /NJS /NP ' + $excludeDownloads)
    if ($rc -ge 8) {
        Say ("backup failed: " + $rc)
        Write-Result 'failed' 'backup-failed' ("备份安装目录失败（robocopy 退出码 " + $rc + "），未做任何替换")
        # 备份是 /MIR 的半成品，可能已经几百 MB；安装目录没动过，留着只会占空间。
        Remove-Item $backup -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
        Close-Ui
        Relaunch
        exit 3
    }
    Update-Ui '正在覆盖安装目录…'
    $rc = Invoke-Robocopy $stage $Target '/E /NFL /NDL /NJH /NJS /NP'
    if ($rc -ge 8) {
        Say ("copy failed: " + $rc + " -> rollback")
        # /MIR：把新版本多出来的文件也删掉，回到备份时的精确状态；
        # 只用 /E 回滚会留下「旧版本 + 新版本多余文件」的混合目录。
        $rc2 = Invoke-Robocopy $backup $Target ('/MIR /NFL /NDL /NJH /NJS /NP ' + $excludeDownloads)
        Say ("rollback rc=" + $rc2)
        Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
        if ($rc2 -ge 8) {
            # 回滚也失败：安装目录可能新旧混杂，这份备份是用户唯一完整的旧版本，
            # 必须留着并在提示里给出路径，让用户能手动拷回去。
            Write-Result 'failed' 'rollback-failed' ("覆盖失败（robocopy " + $rc + "）且回滚也失败（robocopy " + $rc2 + "），安装目录可能不完整。旧版本备份保留在 " + $backup + "，可手动复制回安装目录，或重新解压更新包")
        } else {
            # 回滚成功 = 安装目录已经是旧版本，备份冗余，删掉省几百 MB。
            Remove-Item $backup -Recurse -Force -ErrorAction SilentlyContinue
            Write-Result 'rolled-back' 'copy-failed' ("覆盖安装目录失败（robocopy " + $rc + "），已回滚到原版本")
        }
        Close-Ui
        Relaunch
        exit 4
    }

    # 4. 清理并重启
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $backup -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $Zip -Force -ErrorAction SilentlyContinue
    Say 'update applied'
    # 先把终态写给用户看，再关窗口：立刻关掉会让人以为又崩了。
    Update-Ui ("更新完成，正在启动 " + $ToVersion + "…")
    Start-Sleep -Milliseconds 900
    Close-Ui
    Write-Result 'applied' 'ok' ("已更新到 " + $ToVersion)
    Relaunch
    exit 0
} catch {
    Say ("unexpected failure: " + $_.Exception.Message)
    Write-Result 'failed' 'unexpected' ("更新脚本意外失败：" + $_.Exception.Message)
    Close-Ui
    Relaunch
    exit 6
}
''';

  /// 写出脚本（BOM + CRLF），返回文件路径。
  static Future<File> write(File file) async {
    final normalized = script.replaceAll('\r\n', '\n').replaceAll('\n', '\r\n');
    await file.writeAsBytes(<int>[0xEF, 0xBB, 0xBF, ...utf8.encode(normalized)],
        flush: true);
    return file;
  }

  /// 启动更新脚本，返回子进程句柄。
  ///
  /// **不能用 `ProcessStartMode.detached`**（2026-10-27 Windows 实测）：
  /// 在 Windows 上 detached 模式会「成功」返回一个 pid，但子进程根本没有执行——
  /// 脚本连第一行日志都没写，用户看到的是加载器消失、之后什么都没有，只有
  /// 事件日志里那条我们 `exit(0)` 留下的 0xc0000409 崩溃。同样的参数换成普通
  /// 模式就正常执行，而且父进程退出后子进程会继续跑完（实测子进程在父进程
  /// 消失 6 秒后仍能写文件）。
  ///
  /// stdin 立刻关掉、stdout/stderr 必须读掉：我们马上就要退出，没人会再读
  /// 管道；PowerShell 往一个没人读的管道里写满 64 KB 就会卡住。
  static Future<Process> start({
    required File script,
    required int waitPid,
    required File zip,
    required String target,
    required String exe,
    required String fromVersion,
    required String toVersion,
    required File result,
  }) async {
    final process = await Process.start(
      'powershell.exe',
      <String>[
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        script.path,
        '-WaitPid',
        '$waitPid',
        '-Zip',
        zip.path,
        '-Target',
        target,
        '-Exe',
        exe,
        '-FromVersion',
        fromVersion,
        '-ToVersion',
        toVersion,
        '-Result',
        result.path,
      ],
      mode: ProcessStartMode.normal,
    );
    // close 失败（子进程已经死了）不该让整次更新失败：真正的判据是下面
    // 700 ms 后它还活着没有。
    try {
      await process.stdin.close();
    } catch (_) {}
    process.stdout.drain<void>().ignore();
    process.stderr.drain<void>().ignore();
    return process;
  }
}

/// 校验安装目录可写，并返回 (安装目录, exe 名)。
Future<({Directory target, String exe})?> windowsInstallTarget() async {
  if (!Platform.isWindows) return null;
  final exePath = Platform.resolvedExecutable;
  final target = Directory(p.dirname(exePath));
  // 盘符根目录（C:\）不能作为安装目录：更新脚本会备份/覆盖整块磁盘。
  if (p.equals(
      p.normalize(target.path), p.normalize(p.rootPrefix(target.path)))) {
    return null;
  }
  final exe = p.basename(exePath);
  final probe = File(p.join(target.path, '.gl-write-test'));
  try {
    await probe.writeAsString('x', flush: true);
    await probe.delete();
  } catch (_) {
    return null;
  }
  return (target: target, exe: exe);
}
