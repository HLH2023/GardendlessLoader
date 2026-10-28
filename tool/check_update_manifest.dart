// Windows 更新清单与版本判定验收（纯 Dart，本机可跑）
//
// 为什么单独测：清单来自服务端，字段错了会**静默**表现为「没有更新」或
// 「下载到错误的文件」。文件名还要防目录穿越（清单不能指定写到别处）。
//
// 覆盖：清单解析、版本比较（versionCode 优先 / 版本名回退）、
//       文件名净化、坏字段必须报错。
//
// 用法: dart run tool/check_update_manifest.dart
import 'dart:io';

import 'package:gardendless_loader/src/services/app_update_service.dart';
import 'package:gardendless_loader/src/services/windows_update_service.dart';
import 'package:gardendless_loader/src/services/windows_updater.dart';

int passed = 0;
int failed = 0;

void check(String name, bool ok, [Object? extra]) {
  if (ok) {
    passed++;
    stdout.writeln('  ok   $name${extra != null ? ' -> $extra' : ''}');
  } else {
    failed++;
    stdout.writeln('  FAIL $name${extra != null ? ' -> $extra' : ''}');
  }
}

Map<String, Object?> releaseJson({
  Object? version = '0.9.0-hlh.18',
  Object? versionCode = 90018,
  Object? file = 'gardendless-loader-0.9.0-hlh.18-90018-windows-x64.zip',
  Object? sha =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  Object? url = '/_save/app/res/win/x.zip',
  Object? size = 123,
}) =>
    <String, Object?>{
      'version': version,
      'versionCode': versionCode,
      'file': file,
      'sha256': sha,
      'url': url,
      'size': size,
      'notes': 'notes',
      'created': 1792900000,
    };

Future<void> main() async {
  final release = WindowsRelease.fromJson(releaseJson());
  check('清单解析版本号', release.version == '0.9.0-hlh.18', release.version);
  check('清单解析 versionCode', release.versionCode == 90018, release.versionCode);
  check(
      '清单解析 sha256',
      release.sha256 ==
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      release.sha256);
  check('清单解析字节数', release.size == 123, release.size);

  final manifest = WindowsUpdateManifest.fromJson(<String, Object?>{
    'schema': 1,
    'latest': releaseJson(),
    'history': [releaseJson(versionCode: 90017, version: '0.9.0-hlh.17')],
    'hint': 'hint',
  });
  check('清单 latest 可解析', manifest.latest?.versionCode == 90018);
  check(
      '清单 history 可解析', manifest.history.length == 1, manifest.history.length);

  check(
      'versionCode 更大 → 有更新',
      isWindowsUpgrade(
        release: release,
        installedVersionCode: 90017,
        installedVersionName: '0.9.0-hlh.17',
      ));
  check(
      'versionCode 相同 → 无更新',
      !isWindowsUpgrade(
        release: release,
        installedVersionCode: 90018,
        installedVersionName: '0.9.0-hlh.18',
      ));
  check(
      'versionCode 更小 → 无更新',
      !isWindowsUpgrade(
        release: release,
        installedVersionCode: 90019,
        installedVersionName: '0.9.0-hlh.19',
      ));
  check(
      '没有 versionCode 时回退版本名比较',
      isWindowsUpgrade(
        release: release,
        installedVersionCode: null,
        installedVersionName: '0.9.0-hlh.17',
      ));
  check(
      '版本名回退也要能判「不更新」',
      !isWindowsUpgrade(
        release: release,
        installedVersionCode: null,
        installedVersionName: '0.9.0-hlh.18',
      ));
  check('hlh 序号按数字比较（.9 < .10）',
      compareVersionNames('0.9.0-hlh.10', '0.9.0-hlh.9') > 0);

  check(
      '缺少 .zip 后缀时补上',
      safeWindowsFileName(
              WindowsRelease.fromJson(releaseJson(file: 'build'))) ==
          'build.zip');
  // safeWindowsFileName 是第二道防线：即使对象是直接构造的，也只取 basename。
  check(
      '落盘文件名只取最后一段',
      safeWindowsFileName(const WindowsRelease(
            version: 'x',
            versionCode: 1,
            fileName: '../evil.zip',
            size: 0,
            sha256: '',
            notes: '',
            url: '/x',
          )) ==
          'evil.zip');

  var traversalThrew = false;
  try {
    WindowsRelease.fromJson(releaseJson(file: '../evil.zip'));
  } on FormatException {
    traversalThrew = true;
  }
  check('清单里的路径型文件名必须拒绝', traversalThrew);

  var shaThrew = false;
  try {
    WindowsRelease.fromJson(releaseJson(sha: 'not-a-sha'));
  } on FormatException {
    shaThrew = true;
  }
  check('非法 sha256 必须拒绝', shaThrew);

  var codeThrew = false;
  try {
    WindowsRelease.fromJson(releaseJson(versionCode: 0));
  } on FormatException {
    codeThrew = true;
  }
  check('versionCode 缺失/为 0 必须拒绝', codeThrew);

  var relativeUrlThrew = false;
  try {
    WindowsRelease.fromJson(releaseJson(url: 'http://example.com/x.zip'));
  } on FormatException {
    relativeUrlThrew = true;
  }
  check('清单 url 必须是站内绝对路径', relativeUrlThrew);

  // 更新脚本本身：必须带备份/回滚，且写成 PowerShell 5.1 能读的 BOM+CRLF。
  check(
      '更新脚本包含备份与回滚',
      WindowsUpdaterScript.script.contains('robocopy') &&
          WindowsUpdaterScript.script.contains('.backup') &&
          WindowsUpdaterScript.script.contains('rollback'),
      null);
  check(
      '更新脚本等待应用退出',
      WindowsUpdaterScript.script.contains('WaitPid') &&
          WindowsUpdaterScript.script.contains('Get-Process -Id'),
      null);
  check(
      '更新脚本给 robocopy 路径加引号',
      WindowsUpdaterScript.script.contains(r'''$arg = '"' + $Source''') &&
          WindowsUpdaterScript.script.contains(r'''+ '" "' + $Destination'''),
      null);
  check('更新脚本拒绝盘符根目录', WindowsUpdaterScript.script.contains(r'^[A-Za-z]:$'),
      null);
  check('回滚用 /MIR 恢复精确状态',
      WindowsUpdaterScript.script.contains(r"$backup $Target ('/MIR"), null);
  check(
    '备份与回滚排除下载目录',
    // downloads 现在默认在安装目录里，/MIR 不排除会把上 GB 的资源包复制一份，
    // 回滚时还会被当成「新版本多出来的文件」删掉。
    WindowsUpdaterScript.script
            .contains(r"$downloadsDir = Join-Path $Target 'downloads'") &&
        '\$excludeDownloads'.allMatches(WindowsUpdaterScript.script).length >=
            3,
    null,
  );
  final updaterScript = WindowsUpdaterScript.script;
  check(
    '更新脚本写结果回执（-Result）',
    updaterScript.contains(r'[string]$Result') &&
        updaterScript.contains('function Write-Result'),
    null,
  );
  check(
    '每条失败路径都写回执',
    updaterScript.contains(r"Write-Result 'failed' 'unsafe-target'") &&
        updaterScript.contains(r"Write-Result 'failed' 'app-still-running'") &&
        updaterScript.contains(r"Write-Result 'failed' 'expand-failed'") &&
        updaterScript.contains(r"Write-Result 'failed' 'stage-missing-exe'") &&
        updaterScript.contains(r"Write-Result 'failed' 'backup-failed'") &&
        updaterScript.contains(r"Write-Result 'rolled-back' 'copy-failed'") &&
        updaterScript.contains(r"Write-Result 'failed' 'rollback-failed'"),
    null,
  );
  check(
    '成功路径写回执',
    updaterScript.contains(r"Write-Result 'applied' 'ok'"),
    null,
  );
  check(
    '失败后重新拉起加载器（否则只剩空桌面）',
    'Relaunch'.allMatches(updaterScript).length >= 5,
    null,
  );
  // 应用侧：退出前落 pending、把版本/回执路径传给脚本、重启后消费回执。
  final controllerSource =
      File('lib/src/app_controller.dart').readAsStringSync();
  check(
    '退出前写 pending 回执',
    controllerSource.contains("'status': 'pending'") &&
        controllerSource.contains('windowsUpdateResultFile'),
    null,
  );
  // 参数拼装 2026-10-27 起在 WindowsUpdaterScript.start()（应用与
  // tools/windows_update_spawn_check.dart 共用同一份，测的就是跑的那份）。
  final updaterSource =
      File('lib/src/services/windows_updater.dart').readAsStringSync();
  check(
    '启动脚本收到版本与回执路径',
    updaterSource.contains("'-FromVersion'") &&
        updaterSource.contains("'-ToVersion'") &&
        updaterSource.contains("'-Result'"),
    null,
  );
  check(
    '启动脚本用普通模式（detached 在 Windows 上不执行子进程）',
    updaterSource.contains('mode: ProcessStartMode.normal') &&
        !controllerSource.contains('ProcessStartMode.detached'),
    null,
  );
  check(
    '退出前留时间刷新「正在安装」状态',
    controllerSource.contains('Duration(milliseconds: 900)'),
    null,
  );
  check(
    '启动时消费更新回执',
    controllerSource.contains('_consumeWindowsUpdateResult') &&
        controllerSource.contains('WindowsUpdateOutcomeStatus.rolledBack') &&
        controllerSource.contains('WindowsUpdateOutcomeStatus.pending') &&
        controllerSource.contains('WindowsUpdateOutcomeStatus.unknown'),
    null,
  );
  check(
    '脚本有兜底 catch（未预料的异常也要写回执并重启）',
    updaterScript.contains(r'''} catch {
    Say ("unexpected failure: "''') &&
        updaterScript.contains(r"Write-Result 'failed' 'unexpected'") &&
        'exit 6'.allMatches(updaterScript).isNotEmpty,
    null,
  );
  check(
    '杀残留进程时降级错误（受保护进程读 .Path 会抛 Access denied）',
    updaterScript.contains(r"$ErrorActionPreference = 'SilentlyContinue'") &&
        updaterScript.contains(r"$ErrorActionPreference = 'Stop'"),
    null,
  );
  check(
    '回滚成功时删掉冗余备份（几百 MB）',
    RegExp(r"Write-Result 'rolled-back'[\s\S]{0,200}?Remove-Item \$backup")
            .hasMatch(updaterScript) ||
        RegExp(r"Remove-Item \$backup[\s\S]{0,200}?Write-Result 'rolled-back'")
            .hasMatch(updaterScript),
    null,
  );
  check(
    '回滚失败时保留备份并在提示里给出路径',
    RegExp(r"Write-Result 'failed' 'rollback-failed' \([^\n]*\+ \$backup")
        .hasMatch(updaterScript),
    null,
  );
  check(
    '备份失败时清理半成品备份目录（不然留下几百 MB 垃圾）',
    RegExp(r"Write-Result 'failed' 'backup-failed'[\s\S]{0,300}?Remove-Item \$backup")
        .hasMatch(updaterScript),
    null,
  );
  check(
    'robocopy 限定重试次数（默认 100 万次×30 秒会挂死更新）',
    updaterScript.contains("' /R:2 /W:1'") &&
        updaterScript.contains('robocopy') &&
        !updaterScript.contains('/R:1000000'),
    null,
  );
  check(
    'robocopy 不可用按失败处理',
    updaterScript.contains(r'robocopy unavailable') &&
        updaterScript.contains('return 16'),
    null,
  );
  check(
    '写日志失败不打断更新',
    updaterScript.contains('function Say') &&
        updaterScript.contains(r'} catch { }'),
    null,
  );
  check(
    '重启带重试（刚复制完 exe 可能还被占用）',
    updaterScript.contains(r'for ($i = 0; $i -lt 5; $i++)'),
    null,
  );
  check(
    '脚本失败启动时撤掉 pending 回执',
    controllerSource.contains('windows_update_apply_failed') &&
        controllerSource.contains(
            'await _deleteFileQuietly(_requirePaths().windowsUpdateResultFile);'),
    null,
  );
  check(
    '下载目录默认落在加载器目录并可回退',
    File('lib/src/services/app_paths_service.dart')
            .readAsStringSync()
            .contains('Platform.resolvedExecutable') &&
        File('lib/src/services/app_paths_service.dart')
            .readAsStringSync()
            .contains("'downloads'"),
    null,
  );
  check(
    '解压用 .NET ZipFile（Expand-Archive 对 400 MB 包太慢且无输出）',
    updaterScript.contains('System.IO.Compression.ZipFile') &&
        updaterScript.contains('ExtractToDirectory') &&
        !updaterScript.contains('Expand-Archive -LiteralPath'),
    null,
  );
  check(
      '解压失败会清理临时目录',
      WindowsUpdaterScript.script.contains(
          'Remove-Item \$stage -Recurse -Force -ErrorAction SilentlyContinue'),
      null);
  check(
      '杀残留进程按目录边界匹配',
      WindowsUpdaterScript.script.contains(r"$targetPrefix = $Target + '\'"),
      null);
  final temp = await Directory.systemTemp.createTemp('gl-updater-script');
  try {
    final file = await WindowsUpdaterScript.write(
      File('${temp.path}/apply-windows-update.ps1'),
    );
    final bytes = await file.readAsBytes();
    check(
        '脚本是 UTF-8 BOM',
        bytes.length > 3 &&
            bytes[0] == 0xEF &&
            bytes[1] == 0xBB &&
            bytes[2] == 0xBF,
        bytes.take(3).toList());
    final text = await file.readAsString();
    check(
        '脚本是 CRLF 行尾',
        text.contains('\r\n') && !text.replaceAll('\r\n', '').contains('\n'),
        null);
  } finally {
    await temp.delete(recursive: true);
  }

  // CEF 会把 debug.log 写到 exe 目录且没有上限；界面起不来时后台循环
  // 能把它写到 250 GB（2026-10-25 实机事故）。这里守住「有上限 + 运行期裁剪」
  // 这两个关键点，避免下次重构 Windows runner 时无声丢掉。
  final runnerMain = File('windows/runner/main.cpp');
  final cefLimit = File('windows/runner/cef_log_limit.cc');
  check(
      'Windows runner 启动 CEF 日志看门狗',
      runnerMain.existsSync() &&
          runnerMain.readAsStringSync().contains('StartCefLogLimit()'),
      null);
  check('CEF 日志上限实现存在', cefLimit.existsSync(), null);
  if (cefLimit.existsSync()) {
    final source = cefLimit.readAsStringSync();
    check(
        'CEF 日志上限为 32 MB', source.contains('32ull * 1024ull * 1024ull'), null);
    check('CEF 日志运行期定期裁剪', source.contains('kTrimInterval'), null);
    // 必须允许共享写，否则 CEF 正持有 debug.log 时打不开，上限形同虚设。
    check(
        '裁剪能打开 CEF 正持有的文件',
        source.contains('FILE_SHARE_WRITE') && source.contains('SetEndOfFile'),
        null);
  }

  stdout.writeln('\n结果：$passed 通过 / $failed 失败');
  exit(failed == 0 ? 0 : 1);
}
