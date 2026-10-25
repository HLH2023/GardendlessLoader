import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;


/// 生成并投递 Windows 更新脚本。
///
/// 为什么必须用外部进程：安装目录里的 exe/dll 正在被当前进程与 CEF 子进程
/// 占用，Windows 不允许覆盖运行中的文件。应用先启动脚本、再退出；脚本等到
/// 进程消失后解压覆盖，最后重新拉起。
///
/// 安全边界：
///  - 只接受调用方已用清单 sha256 校验过的 zip；
///  - 解压后必须存在目标 exe，否则不动安装目录；
///  - 替换前整目录备份，robocopy 失败（退出码 ≥8）自动回滚。
class WindowsUpdaterScript {
  const WindowsUpdaterScript._();

  /// 脚本用 UTF-8 BOM + CRLF 写盘：PowerShell 5.1 读无 BOM 的中文/特殊字符
  /// 会按 ANSI 解码，直接语法错误（与 tools/build-windows.ps1 同一个坑）。
  static const script = r'''param(
    [Parameter(Mandatory = $true)][int]$WaitPid,
    [Parameter(Mandatory = $true)][string]$Zip,
    [Parameter(Mandatory = $true)][string]$Target,
    [Parameter(Mandatory = $true)][string]$Exe,
    [switch]$NoLaunch
)
$ErrorActionPreference = 'Stop'
$log = Join-Path $env:TEMP ("gardendless-update-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".log")
function Say([string]$m) {
    $line = (Get-Date -Format 'HH:mm:ss') + ' ' + $m
    Add-Content -LiteralPath $log -Value $line -Encoding UTF8
}
Say "start pid=$WaitPid zip=$Zip target=$Target"

# 1. 等应用自己退出（最多 120 秒）
$deadline = (Get-Date).AddSeconds(120)
while ((Get-Process -Id $WaitPid -ErrorAction SilentlyContinue) -and ((Get-Date) -lt $deadline)) {
    Start-Sleep -Milliseconds 500
}
if (Get-Process -Id $WaitPid -ErrorAction SilentlyContinue) {
    Say 'app did not exit in time'
    exit 1
}
# CEF 的辅助进程可能还在退出过程中
Start-Sleep -Seconds 2
Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.Path -and $_.Path.StartsWith($Target, [System.StringComparison]::OrdinalIgnoreCase)
} | ForEach-Object {
    Say ("stopping leftover " + $_.ProcessName)
    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Milliseconds 500

# 2. 解压到临时目录并做最低限度校验
$stage = Join-Path $env:TEMP ("gl-update-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $stage | Out-Null
try {
    Expand-Archive -LiteralPath $Zip -DestinationPath $stage -Force
} catch {
    Say ("expand failed: " + $_.Exception.Message)
    exit 2
}
$newExe = Join-Path $stage $Exe
if (-not (Test-Path $newExe)) {
    Say "staged exe missing: $newExe"
    exit 2
}

# 3. 备份 + 覆盖；失败则回滚
$backup = $Target + '.backup'
if (Test-Path $backup) { Remove-Item $backup -Recurse -Force }
$rc = Start-Process robocopy -ArgumentList @($Target, $backup, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP') -Wait -PassThru
if ($rc.ExitCode -ge 8) {
    Say ("backup failed: " + $rc.ExitCode)
    exit 3
}
$rc = Start-Process robocopy -ArgumentList @($stage, $Target, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP') -Wait -PassThru
if ($rc.ExitCode -ge 8) {
    Say ("copy failed: " + $rc.ExitCode + " -> rollback")
    Start-Process robocopy -ArgumentList @($backup, $Target, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP') -Wait | Out-Null
    if (-not $NoLaunch) { Start-Process (Join-Path $Target $Exe) }
    exit 4
}

# 4. 清理并重启
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $backup -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $Zip -Force -ErrorAction SilentlyContinue
Say 'update applied'
if (-not $NoLaunch) { Start-Process (Join-Path $Target $Exe) }
exit 0
''';

  /// 写出脚本（BOM + CRLF），返回文件路径。
  static Future<File> write(File file) async {
    final normalized = script.replaceAll('\r\n', '\n').replaceAll('\n', '\r\n');
    await file.writeAsBytes(<int>[0xEF, 0xBB, 0xBF, ...utf8.encode(normalized)],
        flush: true);
    return file;
  }
}

/// 校验安装目录可写，并返回 (安装目录, exe 名)。
Future<({Directory target, String exe})?> windowsInstallTarget() async {
  if (!Platform.isWindows) return null;
  final exePath = Platform.resolvedExecutable;
  final target = Directory(p.dirname(exePath));
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
