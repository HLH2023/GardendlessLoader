// Windows 更新回执的解析契约（纯 Dart，本机可跑）
//
// 为什么单独盯这份数据：更新发生在应用退出之后，用户看到的「已更新 / 已回滚 /
// 更新失败」全部来自脚本写的那份 JSON。解析写错的表现是「更新成功了却提示失败」
// 或「失败却静默」——这类错误在 Windows 实机上只会在下一次启动时出现一次，
// 很难复现，所以把映射抽成纯函数并在这里覆盖。
//
// 用法: dart run tool/check_windows_update_result.dart
import 'dart:convert';
import 'dart:io';

import 'package:gardendless_loader/src/services/windows_update_result.dart';

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

String jsonOf(Map<String, Object?> value) => jsonEncode(value);

void main() {
  stdout.writeln('== 正常回执 ==');
  final applied = WindowsUpdateOutcome.parse(jsonOf(<String, Object?>{
    'status': 'applied',
    'code': 'ok',
    'message': '已更新到 0.9.0-hlh.27',
    'fromVersion': '0.9.0-hlh.26',
    'toVersion': '0.9.0-hlh.27',
    'target': r'D:\Program Files\gardendless-loader',
    'logFile': r'C:\Users\me\AppData\Local\Temp\gardendless-update-1.log',
    'at': 1761561234,
  }));
  check('applied 解析成功', applied != null);
  check('applied 状态', applied?.status == WindowsUpdateOutcomeStatus.applied);
  check('applied 视为成功', applied?.status.isSuccess == true);
  check('applied 不带出失败标志', applied?.status.isFailure == false);
  check(
      'applied 版本号', applied?.toVersion == '0.9.0-hlh.27', applied?.toVersion);
  check('applied 来源版本', applied?.fromVersion == '0.9.0-hlh.26');
  check(
      'applied 保留 Windows 日志路径',
      applied?.logFile ==
          r'C:\Users\me\AppData\Local\Temp\gardendless-update-1.log');
  check('applied 解析时间戳', applied?.at == 1761561234, applied?.at);

  final rolled = WindowsUpdateOutcome.parse(jsonOf(<String, Object?>{
    'status': 'rolled-back',
    'code': 'copy-failed',
    'toVersion': '0.9.0-hlh.27',
  }));
  check('rolled-back 状态',
      rolled?.status == WindowsUpdateOutcomeStatus.rolledBack);
  check('rolled-back 不是成功', rolled?.status.isSuccess == false);
  check('rolled-back 保留原因码', rolled?.code == 'copy-failed');

  final failedOutcome = WindowsUpdateOutcome.parse(jsonOf(<String, Object?>{
    'status': 'failed',
    'code': 'rollback-failed',
  }));
  check(
      'failed 状态', failedOutcome?.status == WindowsUpdateOutcomeStatus.failed);
  check('failed 视为失败', failedOutcome?.status.isFailure == true);

  final pending = WindowsUpdateOutcome.parse(jsonOf(<String, Object?>{
    'status': 'pending',
    'toVersion': '0.9.0-hlh.27',
  }));
  check('pending 状态', pending?.status == WindowsUpdateOutcomeStatus.pending);
  check('pending 视为被中断', pending?.status.isInterrupted == true);

  stdout.writeln('== 容错 ==');
  check('空串 → null', WindowsUpdateOutcome.parse('') == null);
  check('纯空白 → null', WindowsUpdateOutcome.parse('   \n ') == null);
  check('坏 JSON → null', WindowsUpdateOutcome.parse('{"status":') == null);
  check('数组 → null', WindowsUpdateOutcome.parse('[]') == null);
  check('字符串字面量 → null', WindowsUpdateOutcome.parse('"applied"') == null);
  check('缺 status → null', WindowsUpdateOutcome.parse('{"code":"ok"}') == null);
  check('status 空串 → null',
      WindowsUpdateOutcome.parse('{"status":"  "}') == null);
  check(
      '带 BOM 仍能解析',
      WindowsUpdateOutcome.parse('\uFEFF{"status":"applied"}')?.status ==
          WindowsUpdateOutcomeStatus.applied);
  final unknown = WindowsUpdateOutcome.parse('{"status":"half-applied"}');
  check('未知 status → unknown（不当作失败弹窗）',
      unknown?.status == WindowsUpdateOutcomeStatus.unknown);
  check('未知 status 不在成功集合里', unknown?.status.isSuccess == false);
  final upper = WindowsUpdateOutcome.parse('{"status":"APPLIED"}');
  check('status 大小写不敏感', upper?.status == WindowsUpdateOutcomeStatus.applied);
  final messy = WindowsUpdateOutcome.parse(jsonOf(<String, Object?>{
    'status': 'applied',
    'code': 7,
    'toVersion': 27,
    'logFile': null,
    'at': '1761561234',
  }));
  check('非字符串字段被转成文本', messy?.code == '7', messy?.code);
  check('数字版本号也被接受', messy?.toVersion == '27', messy?.toVersion);
  check('null 字段降级为空串', messy?.logFile == '');
  check('字符串时间戳被解析', messy?.at == 1761561234, messy?.at);
  final extra = WindowsUpdateOutcome.parse(jsonOf(<String, Object?>{
    'status': 'applied',
    'futureField': <String, Object?>{'a': 1},
  }));
  check('多余字段不影响解析', extra?.status == WindowsUpdateOutcomeStatus.applied);

  stdout.writeln('== 状态语义 ==');
  check(
      '只有 applied 算成功',
      WindowsUpdateOutcomeStatus.values
              .where((s) => s.isSuccess)
              .toList()
              .length ==
          1);
  check(
      'rolled-back / failed 都不算成功',
      !WindowsUpdateOutcomeStatus.rolledBack.isSuccess &&
          !WindowsUpdateOutcomeStatus.failed.isSuccess);
  check(
      'pending 与 unknown 都不算成功',
      !WindowsUpdateOutcomeStatus.pending.isSuccess &&
          !WindowsUpdateOutcomeStatus.unknown.isSuccess);

  stdout.writeln('== code 契约 ==');
  // 曾经用 status.name 写日志（rolledBack），而 userErrorCatalog 里是
  // windows_update_rolled_back：查不到动作，提示里就没有「下一步怎么做」。
  const expectedCodes = <WindowsUpdateOutcomeStatus, String>{
    WindowsUpdateOutcomeStatus.applied: 'windows_update_applied',
    WindowsUpdateOutcomeStatus.rolledBack: 'windows_update_rolled_back',
    WindowsUpdateOutcomeStatus.failed: 'windows_update_failed_after_restart',
    WindowsUpdateOutcomeStatus.pending: 'windows_update_interrupted',
    WindowsUpdateOutcomeStatus.unknown: 'windows_update_unknown',
  };
  var codesOk = true;
  for (final entry in expectedCodes.entries) {
    if (entry.key.logCode != entry.value) {
      codesOk = false;
      stdout.writeln('       ${entry.key.name} -> ${entry.key.logCode} '
          '(期望 ${entry.value})');
    }
  }
  check('每个状态都有稳定的 logCode', codesOk);
  check(
      'logCode 互不重复',
      WindowsUpdateOutcomeStatus.values.map((s) => s.logCode).toSet().length ==
          WindowsUpdateOutcomeStatus.values.length);
  final catalog =
      File('lib/src/logging/log_event_catalog.dart').readAsStringSync();
  check(
    '失败状态在 userErrorCatalog 里都有「下一步」',
    catalog.contains("'windows_update_rolled_back': UserLogError(") &&
        catalog
            .contains("'windows_update_failed_after_restart': UserLogError(") &&
        catalog.contains("'windows_update_interrupted': UserLogError("),
    null,
  );
  final controller = File('lib/src/app_controller.dart').readAsStringSync();
  check(
      '控制器只用 logCode 写日志/提示，不再拼 status.name',
      controller.contains('outcome.status.logCode') &&
          !controller.contains(r"'windows_update_${outcome.status.name}'"),
      null);

  stdout.writeln('');
  stdout.writeln('结果：$passed 通过 / $failed 失败');
  if (failed > 0) exitCode = 1;
}
