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
  Object? sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
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
  check('清单解析 versionCode', release.versionCode == 90018,
      release.versionCode);
  check('清单解析 sha256', release.sha256 == 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', release.sha256);
  check('清单解析字节数', release.size == 123, release.size);

  final manifest = WindowsUpdateManifest.fromJson(<String, Object?>{
    'schema': 1,
    'latest': releaseJson(),
    'history': [releaseJson(versionCode: 90017, version: '0.9.0-hlh.17')],
    'hint': 'hint',
  });
  check('清单 latest 可解析', manifest.latest?.versionCode == 90018);
  check('清单 history 可解析', manifest.history.length == 1,
      manifest.history.length);

  check('versionCode 更大 → 有更新',
      isWindowsUpgrade(
        release: release,
        installedVersionCode: 90017,
        installedVersionName: '0.9.0-hlh.17',
      ));
  check('versionCode 相同 → 无更新',
      !isWindowsUpgrade(
        release: release,
        installedVersionCode: 90018,
        installedVersionName: '0.9.0-hlh.18',
      ));
  check('versionCode 更小 → 无更新',
      !isWindowsUpgrade(
        release: release,
        installedVersionCode: 90019,
        installedVersionName: '0.9.0-hlh.19',
      ));
  check('没有 versionCode 时回退版本名比较',
      isWindowsUpgrade(
        release: release,
        installedVersionCode: null,
        installedVersionName: '0.9.0-hlh.17',
      ));
  check('版本名回退也要能判「不更新」',
      !isWindowsUpgrade(
        release: release,
        installedVersionCode: null,
        installedVersionName: '0.9.0-hlh.18',
      ));
  check('hlh 序号按数字比较（.9 < .10）',
      compareVersionNames('0.9.0-hlh.10', '0.9.0-hlh.9') > 0);

  check('缺少 .zip 后缀时补上',
      safeWindowsFileName(WindowsRelease.fromJson(
              releaseJson(file: 'build'))) ==
          'build.zip');
  // safeWindowsFileName 是第二道防线：即使对象是直接构造的，也只取 basename。
  check('落盘文件名只取最后一段',
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
  check('更新脚本包含备份与回滚',
      WindowsUpdaterScript.script.contains('robocopy') &&
          WindowsUpdaterScript.script.contains('.backup') &&
          WindowsUpdaterScript.script.contains('rollback'),
      null);
  check('更新脚本等待应用退出',
      WindowsUpdaterScript.script.contains('WaitPid') &&
          WindowsUpdaterScript.script.contains('Get-Process -Id'),
      null);
  check('更新脚本给 robocopy 路径加引号',
      WindowsUpdaterScript.script.contains(r'''$arg = '"' + $Source''') &&
          WindowsUpdaterScript.script.contains(r'''+ '" "' + $Destination'''),
      null);
  check('更新脚本拒绝盘符根目录',
      WindowsUpdaterScript.script.contains(r'^[A-Za-z]:$'), null);
  check('回滚用 /MIR 恢复精确状态',
      WindowsUpdaterScript.script.contains("\$backup \$Target '/MIR"), null);
  check('解压失败会清理临时目录',
      WindowsUpdaterScript.script.contains(
          'Remove-Item \$stage -Recurse -Force -ErrorAction SilentlyContinue'),
      null);
  check('杀残留进程按目录边界匹配',
      WindowsUpdaterScript.script.contains(r"$targetPrefix = $Target + '\'"), null);
  final temp = await Directory.systemTemp.createTemp('gl-updater-script');
  try {
    final file = await WindowsUpdaterScript.write(
      File('${temp.path}/apply-windows-update.ps1'),
    );
    final bytes = await file.readAsBytes();
    check('脚本是 UTF-8 BOM',
        bytes.length > 3 &&
            bytes[0] == 0xEF &&
            bytes[1] == 0xBB &&
            bytes[2] == 0xBF,
        bytes.take(3).toList());
    final text = await file.readAsString();
    check('脚本是 CRLF 行尾',
        text.contains('\r\n') && !text.replaceAll('\r\n', '').contains('\n'),
        null);
  } finally {
    await temp.delete(recursive: true);
  }

  stdout.writeln('\n结果：$passed 通过 / $failed 失败');
  exit(failed == 0 ? 0 : 1);
}
