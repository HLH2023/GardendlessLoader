// 原生宿主 ⇄ Dart 的退出原因契约验收（纯 Dart，本机可跑）
//
// 为什么单独盯这份契约：Android 侧写 `game_exit_result.json`，Dart 侧
// 只按字符串认原因。两边枚举一旦漂移，`consumeExitResult()` 会安静地
// 返回 null（异常被吞掉），表现为「退出原因丢失」而不是报错。
// 令牌失效（tokenRejected）尤其致命：丢失就等于登录态永远不会被清。
//
// 覆盖：Kotlin/Dart 枚举名双向一致、每个 Kotlin 原因都能被 Dart 解析、
//       导出结果的解析与校验、未知原因必须报错。
//
// 用法: dart run tool/check_game_host_contract.dart
import 'dart:io';

import 'package:gardendless_loader/src/game_host/game_exit_result.dart';
import 'package:gardendless_loader/src/services/remote_resource_service.dart';

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

/// 从 Kotlin 源码里抠出 `NAME("wireName")` 形式的枚举项。
Map<String, String> kotlinExitReasons(String source) {
  final result = <String, String>{};
  final pattern = RegExp(r'^\s*([A-Z][A-Z0-9_]*)\("([^"]+)"\)', multiLine: true);
  final enumBody = RegExp(r'enum class GameExitReason\(val wireName: String\)\s*\{([\s\S]*?)\n\}')
      .firstMatch(source);
  if (enumBody == null) return result;
  for (final match in pattern.allMatches(enumBody.group(1)!)) {
    result[match.group(1)!] = match.group(2)!;
  }
  return result;
}

void main() {
  final kotlinFile = File(
    'android/app/src/main/kotlin/io/github/dey410/gardendlessloader/game/GameBridge.kt',
  );
  final activityFile = File(
    'android/app/src/main/kotlin/io/github/dey410/gardendlessloader/game/GameActivity.kt',
  );
  for (final file in [kotlinFile, activityFile]) {
    if (!file.existsSync()) {
      stderr.writeln('找不到 ${file.path}：请在仓库根目录运行 '
          '`dart run tool/check_game_host_contract.dart`');
      exit(2);
    }
  }
  final kotlinSource = kotlinFile.readAsStringSync();
  final kotlinReasons = kotlinExitReasons(kotlinSource);

  check('能从 Kotlin 源码解析出退出原因枚举', kotlinReasons.isNotEmpty,
      kotlinReasons.length);
  check('Kotlin 有 tokenRejected 原因',
      kotlinReasons['TOKEN_REJECTED'] == 'tokenRejected',
      kotlinReasons['TOKEN_REJECTED']);

  final dartWireNames = GameExitReason.values.map((e) => e.name).toSet();
  final kotlinWireNames = kotlinReasons.values.toSet();
  check('Kotlin 与 Dart 的退出原因条数一致',
      kotlinWireNames.length == dartWireNames.length,
      '${kotlinWireNames.length}/${dartWireNames.length}');
  check('Kotlin 写出的每个原因 Dart 都认识',
      kotlinWireNames.every(dartWireNames.contains),
      kotlinWireNames.difference(dartWireNames).toString());
  check('Dart 支持的每个原因 Kotlin 都会写',
      dartWireNames.every(kotlinWireNames.contains),
      dartWireNames.difference(kotlinWireNames).toString());

  for (final entry in kotlinReasons.entries) {
    var parsed = true;
    try {
      GameExitReason.fromWireName(entry.value);
    } catch (_) {
      parsed = false;
    }
    check('原因 ${entry.key} 可被 Dart 解析', parsed, entry.value);
  }

  // 原生宿主必须真的在 401 路径上退出，否则枚举加了也没人用。
  final activity = activityFile.readAsStringSync();
  final exitUses = RegExp(r'GameExitReason\.TOKEN_REJECTED').allMatches(activity).length;
  check('GameActivity 在线令牌失效时使用 TOKEN_REJECTED', exitUses >= 1, exitUses);
  check('GameActivity 心跳回调里上报令牌失效',
      activity.contains('online_token_rejected') &&
          activity.contains('handleOnlineTokenRejected'),
      null);

  // 导出结果解析：tokenRejected 必须能带上 code / playedMs 一起读回来。
  final tokenRejected = GameExitResult.fromJson(<String, Object?>{
    'schemaVersion': 1,
    'sessionId': 'session-test',
    'reason': 'tokenRejected',
    'finishedAt': '2026-10-25T06:00:00.000Z',
    'message': '登录状态已失效',
    'code': 'save_token_rejected',
    'playedMs': 1234,
  });
  check('tokenRejected 能解析出原因',
      tokenRejected.reason == GameExitReason.tokenRejected,
      tokenRejected.reason);
  check('tokenRejected 保留错误码',
      tokenRejected.code == 'save_token_rejected', tokenRejected.code);
  check('tokenRejected 保留游玩时长', tokenRejected.playedMs == 1234,
      tokenRejected.playedMs);
  check('时间统一转成 UTC', tokenRejected.finishedAt.isUtc,
      tokenRejected.finishedAt.toIso8601String());

  final noPlayedMs = GameExitResult.fromJson(<String, Object?>{
    'schemaVersion': 1,
    'sessionId': 'session-test',
    'reason': 'normal',
    'finishedAt': '2026-10-25T06:00:00.000Z',
  });
  check('缺少 playedMs 时按 0 处理', noPlayedMs.playedMs == 0, noPlayedMs.playedMs);

  var unknownThrew = false;
  try {
    GameExitReason.fromWireName('somethingNewer');
  } on FormatException {
    unknownThrew = true;
  }
  check('未知原因必须报错（不静默降级）', unknownThrew);

  var schemaThrew = false;
  try {
    GameExitResult.fromJson(<String, Object?>{
      'schemaVersion': 2,
      'sessionId': 's',
      'reason': 'normal',
      'finishedAt': '2026-10-25T06:00:00.000Z',
    });
  } on FormatException {
    schemaThrew = true;
  }
  check('不支持的 schemaVersion 必须报错', schemaThrew);

  var badReasonThrew = false;
  try {
    GameExitResult.fromJson(<String, Object?>{
      'schemaVersion': 1,
      'sessionId': 's',
      'reason': 'notAReason',
      'finishedAt': '2026-10-25T06:00:00.000Z',
    });
  } on FormatException {
    badReasonThrew = true;
  }
  check('未知原因在结果解析阶段报错', badReasonThrew);

  // 「要不要清登录态」的判定：只认 tokenRejected 且本地确实有令牌。
  check('tokenRejected + 有令牌 → 清登录态',
      exitResultRequiresSignOut(tokenRejected, hasToken: true));
  check('tokenRejected + 已无令牌 → 不重复清',
      !exitResultRequiresSignOut(tokenRejected, hasToken: false));
  check('正常退出不动登录态',
      !exitResultRequiresSignOut(noPlayedMs, hasToken: true));
  check('没有退出结果不动登录态',
      !exitResultRequiresSignOut(null, hasToken: true));

  // 游戏页只应拿短时存档会话令牌；响应解析错了会静默退回设备令牌，
  // 等于安全修复失效，所以这里把解析契约钉死。
  final session = parseSaveSessionTokenResponse(
      '{"token":"pvz_abc","expiresAt":1792920299}');
  check('会话令牌响应可解析', session.token == 'pvz_abc', session.token);
  check(
      '会话令牌过期时间是 UTC',
      session.expiresAt != null &&
          session.expiresAt!.isUtc &&
          session.expiresAt!.millisecondsSinceEpoch == 1792920299000,
      session.expiresAt?.toIso8601String());

  var missingTokenThrew = false;
  try {
    parseSaveSessionTokenResponse('{"expiresAt":1}');
  } on RemoteResourceFailure {
    missingTokenThrew = true;
  }
  check('缺少 token 的响应必须报错', missingTokenThrew);

  var badPrefixThrew = false;
  try {
    parseSaveSessionTokenResponse('{"token":"not-a-token"}');
  } on RemoteResourceFailure {
    badPrefixThrew = true;
  }
  check('非 pvz_ 前缀必须报错', badPrefixThrew);

  var notJsonThrew = false;
  try {
    parseSaveSessionTokenResponse('<html>401</html>');
  } on RemoteResourceFailure {
    notJsonThrew = true;
  }
  check('非 JSON 响应必须报错', notJsonThrew);

  check('没有 expiresAt 时按未知处理',
      parseSaveSessionTokenResponse('{"token":"pvz_x"}').expiresAt == null);

  // 原生凭据文件名是跨语言契约：Dart 写、Kotlin 读，拼错时心跳会静默
  // 退化到短时会话令牌（3 小时后 401），从日志很难看出来。
  final constants = File('lib/src/constants.dart').readAsStringSync();
  final nativeName = RegExp(
          r"nativeTokenFileName\s*=\s*'([^']+)'")
      .firstMatch(constants)
      ?.group(1);
  final kotlinNativeName = RegExp(
          r'NATIVE_TOKEN_FILE_NAME\s*=\s*"([^"]+)"')
      .firstMatch(activity)
      ?.group(1);
  check('Dart 与 Kotlin 的原生凭据文件名一致',
      nativeName != null && nativeName == kotlinNativeName,
      '$nativeName / $kotlinNativeName');
  check('控制器会写原生凭据文件',
      File('lib/src/app_controller.dart')
          .readAsStringSync()
          .contains('nativeTokenFileName'),
      null);
  check('原生优先读宿主凭据再回退桥脚本',
      File(
        'android/app/src/main/kotlin/io/github/dey410/gardendlessloader/game/OnlineGameResourceClient.kt',
      ).readAsStringSync().contains('readHostCredentials'),
      null);

  // 启动契约：日志是诊断设施，Windows 没有原生日志通道。初始化失败若
  // 继续向上抛，main 会在 runApp 之前退出，表现为「双击没反应」。
  final loggerSource =
      File('lib/src/logging/native_app_logger.dart').readAsStringSync();
  check('原生日志通道不可用时降级而不是抛错',
      loggerSource.contains('on MissingPluginException') &&
          loggerSource.contains('InMemoryAppLogger'),
      null);
  check('日志降级快照标记为未持久化',
      loggerSource.contains('persisting: false') &&
          loggerSource.contains('degraded: true'),
      null);
  final mainSource = File('lib/main.dart').readAsStringSync();
  check('main 在日志初始化失败时仍继续启动',
      mainSource.contains('try {') &&
          mainSource.contains('InMemoryAppLogger') &&
          mainSource.contains('runApp('),
      null);
  // B-04：换不到会话令牌时必须失败关闭，不能把设备令牌塞回页面。
  final controllerSource =
      File('lib/src/app_controller.dart').readAsStringSync();
  check('会话令牌失败时不回退到设备令牌',
      !controllerSource.contains('var pageToken = deviceToken') &&
          controllerSource.contains("return '';"),
      null);
  check('Windows 更新入口拒绝盘符根目录',
      File('lib/src/services/windows_updater.dart')
          .readAsStringSync()
          .contains('p.rootPrefix(target.path)'),
      null);

  stdout.writeln('\n结果：$passed 通过 / $failed 失败');
  exit(failed == 0 ? 0 : 1);
}
