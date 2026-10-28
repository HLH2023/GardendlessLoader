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
import 'package:gardendless_loader/src/game_host/game_host_platform.dart';
import 'package:gardendless_loader/src/services/app_settings_store.dart';
import 'package:gardendless_loader/src/services/cloud_save_service.dart';
import 'package:gardendless_loader/src/services/local_save_guard.dart';
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
  final pattern =
      RegExp(r'^\s*([A-Z][A-Z0-9_]*)\("([^"]+)"\)', multiLine: true);
  final enumBody = RegExp(
          r'enum class GameExitReason\(val wireName: String\)\s*\{([\s\S]*?)\n\}')
      .firstMatch(source);
  if (enumBody == null) return result;
  for (final match in pattern.allMatches(enumBody.group(1)!)) {
    result[match.group(1)!] = match.group(2)!;
  }
  return result;
}

/// 取源码里从 [startNeedle] 到下一个 [endNeedle] 之间的一段，找不到返回空串。
/// 用空串参与断言是为了让「函数被删/改名」直接变成失败，而不是空断言恒真。
String memberBody(String source, String startNeedle, String endNeedle) {
  final start = source.indexOf(startNeedle);
  if (start < 0) return '';
  final end = source.indexOf(endNeedle, start + startNeedle.length);
  return source.substring(start, end < 0 ? source.length : end);
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

  check(
      '能从 Kotlin 源码解析出退出原因枚举', kotlinReasons.isNotEmpty, kotlinReasons.length);
  check(
      'Kotlin 有 tokenRejected 原因',
      kotlinReasons['TOKEN_REJECTED'] == 'tokenRejected',
      kotlinReasons['TOKEN_REJECTED']);

  final dartWireNames = GameExitReason.values.map((e) => e.name).toSet();
  final kotlinWireNames = kotlinReasons.values.toSet();
  check(
      'Kotlin 与 Dart 的退出原因条数一致',
      kotlinWireNames.length == dartWireNames.length,
      '${kotlinWireNames.length}/${dartWireNames.length}');
  check(
      'Kotlin 写出的每个原因 Dart 都认识',
      kotlinWireNames.every(dartWireNames.contains),
      kotlinWireNames.difference(dartWireNames).toString());
  check(
      'Dart 支持的每个原因 Kotlin 都会写',
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

  // 令牌失效的退出原因仍保留在契约里（旧版原生在线宿主写过它，升级恢复
  // 路径还要能解析），但本地资源包的宿主不会因为资源 401 退出。

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
  check(
      'tokenRejected 能解析出原因',
      tokenRejected.reason == GameExitReason.tokenRejected,
      tokenRejected.reason);
  check('tokenRejected 保留错误码', tokenRejected.code == 'save_token_rejected',
      tokenRejected.code);
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
  check('正常退出不动登录态', !exitResultRequiresSignOut(noPlayedMs, hasToken: true));
  check('没有退出结果不动登录态', !exitResultRequiresSignOut(null, hasToken: true));

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

  // 启动契约：日志是诊断设施，Windows 没有原生日志通道。初始化失败若
  // 继续向上抛，main 会在 runApp 之前退出，表现为「双击没反应」。
  final loggerSource =
      File('lib/src/logging/native_app_logger.dart').readAsStringSync();
  check(
      '原生日志通道不可用时降级而不是抛错',
      loggerSource.contains('on MissingPluginException') &&
          loggerSource.contains('InMemoryAppLogger'),
      null);
  check(
      '日志降级快照标记为未持久化',
      loggerSource.contains('persisting: false') &&
          loggerSource.contains('degraded: true'),
      null);
  final mainSource = File('lib/main.dart').readAsStringSync();
  check(
      'main 在日志初始化失败时仍继续启动',
      mainSource.contains('try {') &&
          mainSource.contains('InMemoryAppLogger') &&
          mainSource.contains('runApp('),
      null);
  // B-04：换不到会话令牌时必须失败关闭，不能把设备令牌塞回页面。
  final controllerSource =
      File('lib/src/app_controller.dart').readAsStringSync();
  // B-19（已修订）：存档页默认跟随游玩形态，但版本来源必须分开：
  //   本地资源 → 已校验资源包的 gameVersion + manifest 版本
  //   在线     → 服务器资源清单版本，取不到就失败，绝不借用本地版本
  // 页面允许手动切换查看分区，这只影响查看，不改变运行中的游戏会话。
  final savesRefresh =
      controllerSource.indexOf('Future<void> refreshCloudSaves(');
  final refreshEnd = savesRefresh < 0
      ? -1
      : controllerSource.indexOf('Future<void> loadSaveHistory(', savesRefresh);
  final refreshBody = savesRefresh >= 0 && refreshEnd > savesRefresh
      ? controllerSource.substring(savesRefresh, refreshEnd)
      : '';
  check(
      '存档页按查看分区取版本（不直接用游玩版本）',
      refreshBody.isNotEmpty &&
          refreshBody.contains('final version = cloudSavesViewVersion;') &&
          !refreshBody.contains('gameVersion: _playGameVersion()'),
      null);
  check('本地资源缺失时明确失败而不是查 legacy',
      refreshBody.contains("'local_resource_missing'"), null);
  check('在线版本取不到时明确失败而不是借用本地版本',
      refreshBody.contains("'online_version_unavailable'"), null);
  // 在线版本分区仍需要服务器清单的版本，不能被本地游玩状态挡掉。
  check('本地游玩时也能取在线存档分区版本', refreshBody.contains('_ensureRemoteGameVersion()'),
      null);
  // 先 ++ 代际再因「正在加载」返回，会把在途请求作废又没人接手 → 页面永久加载。
  final inFlightIndex =
      refreshBody.indexOf('if (_cloudSavesInFlight > 0 && !force) return;');
  final bumpIndex = refreshBody.indexOf('++_savesViewGeneration');
  check('没有新请求时不推进视图代际', inFlightIndex >= 0 && bumpIndex > inFlightIndex,
      'guard@$inFlightIndex bump@$bumpIndex');
  // P1-4：在线版本请求在途期间可能重新登录/换服务器。旧请求的 401 若直接
  // 走 _handleTokenRejected，会把刚登录的新令牌清掉。写入缓存与登出前都必须
  // 重新比对发起时的令牌/服务器（以及登录上下文代际）。
  final ensureRemoteBody = memberBody(
    controllerSource,
    'Future<void> _ensureRemoteGameVersion() async {',
    '/// 桌面端准备游戏',
  );
  final authCheck = 'if (!isCurrentAuthContext()) return;';
  final authCheckCount =
      RegExp(RegExp.escape(authCheck)).allMatches(ensureRemoteBody).length;
  final firstAuthCheck = ensureRemoteBody.indexOf(authCheck);
  final manifestAssign =
      ensureRemoteBody.indexOf('_remoteManifest = manifest;');
  final tokenRejectedIndex =
      ensureRemoteBody.indexOf('_handleTokenRejected(error)');
  final secondAuthCheck = tokenRejectedIndex < 0
      ? -1
      : ensureRemoteBody.indexOf(authCheck, firstAuthCheck + 1);
  check(
      '在线版本：写缓存前比对令牌/服务器上下文',
      ensureRemoteBody.isNotEmpty &&
          ensureRemoteBody
              .contains('final authGeneration = _authContextGeneration;') &&
          ensureRemoteBody
              .contains('token == _appSettings.deviceToken.trim()') &&
          ensureRemoteBody
              .contains('base == _appSettings.effectiveServerBaseUrl') &&
          firstAuthCheck >= 0 &&
          manifestAssign > firstAuthCheck,
      'check@$firstAuthCheck assign@$manifestAssign');
  check(
      '在线版本：迟到 401 不会登出新账号',
      authCheckCount >= 2 &&
          secondAuthCheck >= 0 &&
          tokenRejectedIndex > secondAuthCheck,
      'checks@$authCheckCount rejected@$tokenRejectedIndex');
  final updateSettingsBody = memberBody(
    controllerSource,
    'Future<void> _updateAppSettings(AppSettings settings) async {',
    'Future<void> setAutoCollectSunEnabled',
  );
  check(
      '登录上下文代际在令牌/服务器变化时推进',
      updateSettingsBody.contains('_authContextGeneration++') &&
          updateSettingsBody.contains('_remoteManifest = null') &&
          updateSettingsBody
              .contains('settings.deviceToken != _appSettings.deviceToken') &&
          updateSettingsBody.contains('settings.effectiveServerBaseUrl !='),
      null);
  final viewStart =
      controllerSource.indexOf('String get cloudSavesViewVersion {');
  final viewEnd = viewStart < 0 ? -1 : controllerSource.indexOf('}', viewStart);
  final viewBody = viewStart >= 0 && viewEnd > viewStart
      ? controllerSource.substring(viewStart, viewEnd)
      : '';
  check(
      '本地查看使用本地资源版本',
      viewBody.contains('currentGameVersion') &&
          viewBody.contains('cloudSavesViewOnline'),
      null);
  check(
      '切换查看分区会作废在途响应', controllerSource.contains('_savesViewGeneration'), null);
  check(
      '会话令牌失败时不回退到设备令牌',
      !controllerSource.contains('var pageToken = deviceToken') &&
          controllerSource.contains("return '';"),
      null);
  check(
      'Windows 更新入口拒绝盘符根目录',
      File('lib/src/services/windows_updater.dart')
          .readAsStringSync()
          .contains('p.rootPrefix(target.path)'),
      null);

  // 存档面板显示的是 /load 实际返回的分区（可能是 legacy）。历史/回滚
  // 必须沿用这个分区，否则页面有数据、历史却查空。
  final legacySnapshot = CloudSaveSnapshot.fromJson(<String, Object?>{
    'user': 'u',
    'gameVersion': '',
    'is_admin': false,
    'mtime': <String, Object?>{'PvZ2_PlayerProperties': 1},
    'summary': <String, Object?>{},
    'device': <String, Object?>{},
    'server_ts': 1,
  });
  check('快照保留服务端实际分区（legacy）', legacySnapshot.gameVersion.isEmpty,
      legacySnapshot.gameVersion);
  final versionedSnapshot = CloudSaveSnapshot.fromJson(<String, Object?>{
    'user': 'u',
    'gameVersion': '0.16.1',
    'is_admin': false,
    'mtime': <String, Object?>{'PvZ2_PlayerProperties': 1},
    'summary': <String, Object?>{},
    'device': <String, Object?>{},
    'server_ts': 1,
  });
  check('快照保留服务端实际分区（版本号）', versionedSnapshot.gameVersion == '0.16.1',
      versionedSnapshot.gameVersion);
  check(
      '历史与回滚用每个键自己的来源分区',
      controllerSource.contains('_saveHistorySourceVersion(key)') &&
          controllerSource
              .contains('_profileHistorySourceVersion(profileId)') &&
          controllerSource.contains('gameVersion: version'),
      null);
  check(
      '存档页不再按管理员隐藏历史/回滚',
      !File('lib/src/ui/pages/saves_page.dart')
          .readAsStringSync()
          .contains('canManage: snapshot.isAdmin'),
      null);

  // Windows 没有原生 GameHost：界面/诊断必须回退到 Dart 桌面宿主，
  // 否则 play_page 构建时直接抛 UnsupportedError（hlh.20 实测）。
  check(
      'Windows 映射到 Dart 桌面宿主',
      GameHostPlatform.forOperatingSystem('windows') ==
          GameHostPlatform.desktop,
      null);
  // 桌面端 localStorage 按 origin 隔离；origin 含端口，必须持久化固定端口，
  // 否则随机端口会让重启后进度「消失」。在线游玩的第二个端口已删除。
  final settingsSource =
      File('lib/src/services/app_settings_store.dart').readAsStringSync();
  check(
      '设置只持久化本地固定端口',
      settingsSource.contains('final int desktopLocalPort') &&
          settingsSource.contains("'desktopLocalPort': desktopLocalPort") &&
          !settingsSource.contains('final int desktopOnlinePort') &&
          !settingsSource.contains("'desktopOnlinePort':"),
      null);
  final legacySettings = AppSettings.fromJson(<String, dynamic>{
    'playMode': 'online',
    'desktopOnlinePort': 45123,
    'desktopLocalPort': 44001,
    'deviceToken': 'pvz_legacy',
    'deviceAccount': 'alice',
    'serverBaseUrl': 'https://saves.example',
    'themePreference': 'dark',
    'languagePreference': 'chinese',
  });
  check(
      '旧设置迁移：playMode/desktopOnlinePort 被忽略且保留账号、服务器、令牌、主题、语言与本地端口',
      !legacySettings.toJson().containsKey('playMode') &&
          !legacySettings.toJson().containsKey('desktopOnlinePort') &&
          legacySettings.hasDeviceToken &&
          legacySettings.deviceAccount == 'alice' &&
          legacySettings.serverBaseUrl == 'https://saves.example' &&
          legacySettings.themePreference == ThemePreference.dark &&
          legacySettings.languagePreference == LanguagePreference.chinese &&
          legacySettings.desktopLocalPort == 44001,
      legacySettings.toJson().keys.join(','));
  check('存档页默认查看本地资源版本',
      controllerSource.contains('_savesViewOnlineOverride ?? false'), null);
  check(
      '桌面端启动使用固定端口',
      controllerSource.contains('_startDesktopServer(') &&
          controllerSource.contains('port: saved') &&
          controllerSource.contains('port: candidate'),
      null);
  // 首次分配必须在绑定成功之后才持久化，否则竞态会留下永远不可用的端口。
  final bindIndex = controllerSource
      .indexOf('final server = await LocalResourceServer.start(');
  final persistIndex = controllerSource.indexOf(
      'desktopLocalPort: candidate', bindIndex > 0 ? bindIndex : 0);
  check('首次分配端口在绑定成功后才持久化', bindIndex > 0 && persistIndex > bindIndex, null);
  check(
      '桌面端端口被占用时明确失败而不是换 origin',
      controllerSource.contains("'desktop_port_unavailable'") &&
          !controllerSource.contains('port: 0,'),
      null);
  check(
      '桌面宿主的展示名不是原生',
      GameHostPlatform.desktop.nativeHostName == 'dart-desktop',
      GameHostPlatform.desktop.nativeHostName);
  check(
      'Android/iOS/OHOS 仍映射到原生宿主',
      GameHostPlatform.forOperatingSystem('android') ==
              GameHostPlatform.android &&
          GameHostPlatform.forOperatingSystem('ios') == GameHostPlatform.ios &&
          GameHostPlatform.forOperatingSystem('ohos') == GameHostPlatform.ohos,
      null);
  var unknownPlatformThrew = false;
  try {
    GameHostPlatform.forOperatingSystem('plan9');
  } on UnsupportedError {
    unknownPlatformThrew = true;
  }
  check('未知平台明确报错而不是静默降级', unknownPlatformThrew, null);

  // 多玩家 / 存档页分区：服务端字段形状一旦变更，启动器页面会空白。
  // 这里用真实形状的 JSON 直接过一遍解析器，不依赖网络与令牌。
  final snapshot = CloudSaveSnapshot.fromJson(<String, Object?>{
    'user': 'alice',
    'owner_uid': 'uid-1234567890',
    'is_admin': false,
    'gameVersion': '0.16.1',
    'requestedGameVersion': '0.16.2',
    'load_kind': 'migrated',
    'profileSource': '0.16.1',
    'keySources': <String, Object?>{
      'PvZ2_PlayerProperties': <String, Object?>{
        'gameVersion': '0.16.1',
        'kind': 'migrated',
      },
    },
    'mtime': <String, Object?>{
      'PvZ2_PlayerProperties': 1700000000,
      'PvZ2_Settings': 1700000001,
    },
    'summary': <String, Object?>{
      'PvZ2_PlayerProperties': <String, Object?>{'bytes': 900, 'name': 'nb'},
      'PvZ2_Settings': <String, Object?>{'bytes': 12},
    },
    'profiles': <Object?>[
      <String, Object?>{
        'id': 'pppppppp1111',
        'name': 'nb',
        'index': 0,
        'bytes': 450,
        'revision': 'rev-a',
        'updatedAt': 1700000000,
        'summary': <String, Object?>{'name': 'nb', 'coin': 7, 'gem': 2},
      },
      <String, Object?>{
        'id': 'qqqqqqqq2222',
        'name': 'cool',
        'index': 1,
        'bytes': 450,
        'revision': 'rev-b',
        'updatedAt': 1700000002,
        'summary': <String, Object?>{'name': 'cool', 'coin': 9, 'gem': 1},
      },
    ],
    'profileVer': <String, Object?>{
      'pppppppp1111': 'rev-a',
      'qqqqqqqq2222': 'rev-b'
    },
    'server_ts': 1700000100,
  });
  check('多玩家快照解析出两份玩家', snapshot.profiles.length == 2,
      snapshot.profiles.map((p) => p.name).join(','));
  check(
      '玩家按 index 排序',
      snapshot.profiles.first.name == 'nb' &&
          snapshot.profiles.last.name == 'cool',
      null);
  check(
      '玩家 profileId/revision 可读',
      snapshot.profiles.first.id == 'pppppppp1111' &&
          snapshot.profiles.first.shortId == 'pppppppp' &&
          snapshot.profiles.first.revision == 'rev-a',
      null);
  check('玩家来源标记为迁移', snapshot.profiles.first.inherited, null);
  check('账号 uid 可展示', snapshot.ownerUid == 'uid-1234567890', null);
  check(
      '共享数据不含玩家键',
      snapshot.sharedEntries.length == 1 &&
          snapshot.sharedEntries.first.key == 'PvZ2_Settings',
      snapshot.sharedEntries.map((e) => e.key).join(','));
  check(
      '玩家金币/宝石可读',
      snapshot.profiles.first.coin == 7 && snapshot.profiles.first.gem == 2,
      null);
  // 本机存档版本保护：换资源版本不换 origin，降级必须挡住高版本 localStorage。
  final guard = buildLocalSaveGuardScript('0.16.2');
  check(
      '版本保护脚本包含上下文键',
      guard.contains('__pvzSaveContext') &&
          guard.contains('__pvzVersionBlocked'),
      null);
  check(
      '版本保护脚本会备份并按版本恢复存档',
      guard.contains('__pvzBlocked_') &&
          guard.contains('clearGame()') &&
          guard.contains('restoreGame(CUR)'),
      null);
  check(
      '降级后把上下文推进到当前版本（防止重复备份/清空）',
      guard.contains('prev.gameVersion!==CUR') &&
          guard.contains('gameVersion:CUR,from:before') &&
          guard.contains('prev.at=Date.now()'),
      null);
  check(
      '同步队列/云端基准也按版本归档',
      guard.contains('__pvzPending') &&
          guard.contains('__pvzCloudProfiles') &&
          guard.contains('stateKey(ver,'),
      null);
  check('空版本不注入保护脚本（无法比较）', buildLocalSaveGuardScript('').isEmpty, null);
  final activitySource = File(
          'android/app/src/main/kotlin/io/github/dey410/gardendlessloader/game/GameActivity.kt')
      .readAsStringSync();
  check(
      'Android 在游戏脚本前执行版本保护',
      activitySource.contains('appendLocalSaveGuard()') &&
          activitySource.indexOf('appendLocalSaveGuard()') <
              activitySource.indexOf('appendSaveBridge()') &&
          activitySource.contains('LOCAL_SAVE_GUARD_FILE_NAME'),
      null);
  check(
      'Android 读取 Dart 生成的保护脚本，不再维护第二份实现',
      activitySource
              .contains('File(session.appRoot, LOCAL_SAVE_GUARD_FILE_NAME)') &&
          !activitySource.contains("var KEY='__pvzSaveContext'"),
      null);
  // P1-5：Dart 写 guard 必须原子（临时文件 → 读回 → 替换 → 再读回），
  // 任何一步失败都要抛出阻止启动；只 log 后继续等于无保护启动。
  final writeGuardBody = memberBody(
    controllerSource,
    'Future<void> _writeSaveGuardAtomically(',
    'Future<Never> _abortForUnusableGuard',
  );
  final prepareBridgeBody = memberBody(
    controllerSource,
    'Future<void> _prepareSaveBridge(Directory appRoot) async {',
    '/// 原子写入版本保护脚本',
  );
  final abortGuardBody = memberBody(
    controllerSource,
    'Future<Never> _abortForUnusableGuard(',
    '/// 生成存档桥脚本',
  );
  final tempWrite = writeGuardBody.indexOf('temp.writeAsString(');
  final tempRead = writeGuardBody.indexOf('await temp.readAsString()');
  final rename = writeGuardBody.indexOf('temp.rename(target.path)');
  final targetRead = writeGuardBody.indexOf('await target.readAsString()');
  check(
      'guard 原子写：临时文件 → 读回 → 替换 → 再读回',
      writeGuardBody.isNotEmpty &&
          tempWrite >= 0 &&
          tempRead > tempWrite &&
          rename > tempRead &&
          targetRead > rename,
      'write@$tempWrite read@$tempRead rename@$rename reread@$targetRead');
  check(
      'guard 写入失败抛出而不是只记日志',
      prepareBridgeBody.isNotEmpty &&
          prepareBridgeBody
              .contains('_writeSaveGuardAtomically(guardFile, guard)') &&
          !prepareBridgeBody.contains('guardFile.writeAsString') &&
          writeGuardBody.contains('throw StateError') &&
          writeGuardBody.contains('_abortForUnusableGuard(') &&
          abortGuardBody.contains("event: 'local_save_guard_write_failed'") &&
          abortGuardBody.contains('throw StateError'),
      null);
  check(
      '无版本时仍不写 guard，但会清掉旧文件并确认删除',
      prepareBridgeBody.contains('if (guard.isEmpty)') &&
          prepareBridgeBody.contains('_deleteFileQuietly(guardFile)') &&
          prepareBridgeBody.contains('await guardFile.exists()'),
      null);
  check(
      '桌面端注入同一份版本保护（非空时不会被过滤丢弃）',
      controllerSource.contains(
              'final guard = buildLocalSaveGuardScript(_playGameVersion());') &&
          controllerSource.contains('if (guard.isNotEmpty) guard') &&
          controllerSource.contains('localSaveGuardFileName') &&
          !controllerSource.contains('guardFile.writeAsString'),
      null);
  // P1-5：required 表示本次启动必须有 guard。Dart 与 Kotlin 的字段名/default
  // 必须一致，否则旧 JSON 会被误判成「必须」而拒绝启动。
  // GameSession 所在文件依赖 package:flutter/services.dart，而本仓库的验收
  // 脚本是纯 Dart（没有 dart:ui），无法直接构造实例做 round-trip。这里改为
  // 断言四处链路（构造默认值 / fromJson / toJson / Dart 传值）都存在，
  // 断链（字段名或默认值漂移）会立刻失败。
  final sessionSource =
      File('lib/src/game_host/game_host.dart').readAsStringSync();
  final sessionConstructor = memberBody(
    sessionSource,
    'const GameSession({',
    'factory GameSession.fromJson',
  );
  final sessionFromJson = memberBody(
    sessionSource,
    'factory GameSession.fromJson(',
    'static const schemaVersion',
  );
  final sessionToJson = memberBody(
    sessionSource,
    'Map<String, Object?> toJson() {',
    'class MethodChannelGameHost',
  );
  check(
      'Dart GameSession 携带 localSaveGuardRequired（默认 false 兼容旧构造）',
      sessionConstructor.contains('this.localSaveGuardRequired = false') &&
          sessionFromJson
              .contains("json['localSaveGuardRequired'] as bool? ?? false") &&
          sessionToJson
              .contains("'localSaveGuardRequired': localSaveGuardRequired"),
      null);
  check(
      '启动会话按游戏版本决定是否要求 guard',
      controllerSource
          .contains('localSaveGuardRequired: _playGameVersion().isNotEmpty'),
      null);
  final sessionCodecSource = File(
          'android/app/src/main/kotlin/io/github/dey410/gardendlessloader/game/GameSessionCodec.kt')
      .readAsStringSync();
  check(
      'Kotlin 解析 localSaveGuardRequired 且缺省 false（向后兼容）',
      sessionCodecSource.contains('localSaveGuardRequired: Boolean = false') &&
          sessionCodecSource.contains(
              'localSaveGuardRequired = json.optBoolean("localSaveGuardRequired", false)'),
      null);
  // required 且文件缺失/空白/读取失败必须 fail closed；非 required 仍允许
  // 缺失（旧式未索引资源包）——两条语义都不能丢。
  final guardFnBody = memberBody(
    activitySource,
    'private fun StringBuilder.appendLocalSaveGuard() {',
    'private fun StringBuilder.appendSaveBridge()',
  );
  final missingBranch = guardFnBody.indexOf('failUnusableGuard("missing")');
  final emptyBranch =
      guardFnBody.indexOf('failUnusableGuard("empty_or_unreadable")');
  check(
      'Android required 时 guard 缺失/空白/读取失败都失败关闭',
      guardFnBody.isNotEmpty &&
          guardFnBody.contains('if (!guard.isFile) {') &&
          guardFnBody.contains('if (script.isNullOrBlank()) {') &&
          guardFnBody.contains('session.localSaveGuardRequired') &&
          missingBranch >= 0 &&
          emptyBranch >= 0 &&
          guardFnBody.contains('throw LocalSaveGuardUnusableException') &&
          activitySource.contains('event = "local_save_guard_unusable"') &&
          activitySource.contains(
              'is LocalSaveGuardUnusableException -> "local_save_guard_unusable"'),
      null);
  // B-65：iOS/OHOS 原生宿主也必须加载 Dart 生成的 guard。仅 Android 注入
  // 等于换资源版本时 iOS/OHOS 的旧游戏仍能读到高版本 localStorage。
  final iosSessionSource =
      File('ios/GardendlessKit/Sources/GardendlessCore/GameSession.swift')
          .readAsStringSync();
  final iosSessionInit = memberBody(
    iosSessionSource,
    'public init(',
    'self.exportTemporaryRoot = exportTemporaryRoot',
  );
  final iosSessionDecoder = memberBody(
    iosSessionSource,
    'public static func decode(_ value: Any?) throws -> GameSession {',
    'public static func isValidRemoteHost',
  );
  check(
      'iOS GameSession 携带 localSaveGuardRequired（默认 false 兼容旧构造）',
      iosSessionSource.contains('public let localSaveGuardRequired: Bool') &&
          iosSessionInit.contains('localSaveGuardRequired: Bool = false') &&
          iosSessionInit
              .contains('self.localSaveGuardRequired = localSaveGuardRequired'),
      null);
  check(
      'iOS 解析 localSaveGuardRequired 且缺省 false（向后兼容）',
      iosSessionDecoder.isNotEmpty &&
          iosSessionDecoder.contains(
              'localSaveGuardRequired: json["localSaveGuardRequired"] as? Bool ?? false'),
      null);

  final iosHostSource =
      File('ios/Runner/GameHostController.swift').readAsStringSync();
  final iosLoadView = memberBody(
    iosHostSource,
    'override func loadView() {',
    'override func viewDidLoad()',
  );
  final iosGuardBody = memberBody(
    iosHostSource,
    'private func loadLocalSaveGuard() throws -> String {',
    '/// guard 由 Dart 生成',
  );
  final iosBuildBody = memberBody(
    iosHostSource,
    'private func buildDocumentStartScript() throws -> String {',
    'private static func loadFlutterAsset(',
  );
  check(
      'iOS document-start 在 game bridge 之后追加 guard',
      iosBuildBody.isNotEmpty &&
          iosBuildBody.contains('for name in names') &&
          iosBuildBody.contains('let guardScript = try loadLocalSaveGuard()') &&
          iosBuildBody.indexOf('for name in names') <
              iosBuildBody.indexOf('try loadLocalSaveGuard()'),
      null);
  check(
      'iOS required 时 guard 缺失/空白/读取失败都失败关闭',
      iosGuardBody.isNotEmpty &&
          iosGuardBody.contains('__local_save_guard.js') &&
          iosGuardBody.contains('session.appRoot') &&
          iosGuardBody.contains('session.localSaveGuardRequired') &&
          iosGuardBody.contains('"missing_or_unreadable"') &&
          iosGuardBody.contains('"empty"') &&
          iosGuardBody.contains('throw GameError.failed') &&
          iosGuardBody.contains('local_save_guard_unusable'),
      null);
  check(
      'iOS guard 不可用时走现有启动失败收尾（不创建无保护的 WebView）',
      iosLoadView.isNotEmpty &&
          iosLoadView.contains('try buildDocumentStartScript()') &&
          iosLoadView.contains('exit(reason: "launchFailed"'),
      null);
  final iosViewDidLoad = memberBody(
    iosHostSource,
    'override func viewDidLoad() {',
    'override var prefersStatusBarHidden',
  );
  check(
      'iOS 启动失败后 viewDidLoad 不再访问未创建的 WebView',
      iosHostSource.contains('private var launchFailed = false') &&
          iosLoadView.contains('launchFailed = true') &&
          iosViewDidLoad.isNotEmpty &&
          iosViewDidLoad.contains('guard !launchFailed else { return }'),
      null);

  final ohosSessionSource =
      File('ohos/entry/src/main/ets/game/GameSession.ets').readAsStringSync();
  check(
      'OHOS GameSession 携带 localSaveGuardRequired（缺省 false 兼容旧 JSON）',
      ohosSessionSource.contains('localSaveGuardRequired?: boolean;') &&
          ohosSessionSource
              .contains('readonly localSaveGuardRequired: boolean;') &&
          ohosSessionSource.contains(
              'this.localSaveGuardRequired = value.localSaveGuardRequired === true;'),
      null);

  final ohosPageSource =
      File('ohos/entry/src/main/ets/pages/GamePage.ets').readAsStringSync();
  final ohosGuardBody = memberBody(
    ohosPageSource,
    'private loadLocalSaveGuard(session: GameSession): string {',
    'private buildDocumentStartScript(session: GameSession): string {',
  );
  final ohosBuildBody = memberBody(
    ohosPageSource,
    'private buildDocumentStartScript(session: GameSession): string {',
    'private gpNextBaseDirectory(',
  );
  check(
      'OHOS document-start 在 game bridge 之后追加 guard',
      ohosBuildBody.isNotEmpty &&
          ohosBuildBody.contains('for (const name of names)') &&
          ohosBuildBody.contains('this.loadLocalSaveGuard(session)') &&
          ohosBuildBody.indexOf('for (const name of names)') <
              ohosBuildBody.indexOf('this.loadLocalSaveGuard(session)'),
      null);
  check(
      'OHOS required 时 guard 缺失/空白/读取失败都失败关闭',
      ohosGuardBody.isNotEmpty &&
          ohosGuardBody.contains('__local_save_guard.js') &&
          ohosGuardBody.contains('session.appRoot') &&
          ohosGuardBody.contains('fs.readTextSync(guardPath)') &&
          ohosGuardBody.contains('session.localSaveGuardRequired') &&
          ohosGuardBody.contains("'missing_or_unreadable'") &&
          ohosGuardBody.contains("'empty'") &&
          ohosGuardBody.contains('throw new LocalSaveGuardUnusableError') &&
          ohosGuardBody.contains('local_save_guard_unusable'),
      null);
  check(
      'OHOS guard 不可用时走初始化失败收尾并记录明确 code',
      ohosPageSource.contains(
              'const guardUnusable = error instanceof LocalSaveGuardUnusableError;') &&
          ohosPageSource.contains('code: guardUnusable') &&
          ohosPageSource
              .contains('this.writeLaunchFailure(launchError.message)'),
      null);
  check(
      'OHOS 初始化失败后不再加载游戏（Web 组件仍会被创建）',
      ohosPageSource.contains('private launchFailed: boolean') &&
          ohosPageSource.contains('this.launchFailed = true;') &&
          ohosPageSource.indexOf('if (this.launchFailed)') <
              ohosPageSource
                  .indexOf('this.controller.loadUrl(session.entryUrl)'),
      null);

  // 日志落盘必须有跨平台总量上限，而且要在换段时清理。只在进程启动时清一次
  // 的实现，遇到界面异常反复报错会无限增长（Windows CEF 曾写出 250 GB）。
  final androidLogStore = File(
          'android/app/src/main/kotlin/io/github/dey410/gardendlessloader/logging/AppLogStore.kt')
      .readAsStringSync();
  check(
      'Android 日志换段时按总量清理',
      RegExp(r'private fun ensureWriter[\s\S]*?cleanupLocked\(\)')
          .hasMatch(androidLogStore),
      null);
  final ohosLogStore = File('ohos/entry/src/main/ets/logging/AppLogStore.ets')
      .readAsStringSync();
  check(
      'OHOS 日志换段时按总量清理',
      RegExp(r'private segmentPath[\s\S]*?this\.cleanup\(\)')
          .hasMatch(ohosLogStore),
      null);
  final iosLogStore =
      File('ios/GardendlessKit/Sources/GardendlessLogging/LogStore.swift')
          .readAsStringSync();
  check(
      'iOS 日志换段时按总量清理',
      RegExp(r'private func ensureHandle[\s\S]*?if rotating \{ cleanup\(\) \}')
          .hasMatch(iosLogStore),
      null);

  // 安卓切后台：WebView.onPause() 只停计时器，不碰不挂 DOM 的 HTMLAudio 池；
  // 游戏的自动暂停又只认 window blur。两条都必须由宿主显式触发，顺序也不能反。
  final activity = File(
          'android/app/src/main/kotlin/io/github/dey410/gardendlessloader/game/GameActivity.kt')
      .readAsStringSync();
  check('GameActivity 注入 media_lifecycle.js',
      activity.contains('add("media_lifecycle.js")'), null);
  final pauseHook = activity.indexOf('__gardendlessHostPause');
  final webPause = activity.indexOf('webView.onPause()');
  final resumeHook = activity.indexOf('__gardendlessHostResume');
  final webResume = activity.indexOf('webView.onResume()');
  check('onPause 先暂停页面再暂停 WebView', pauseHook >= 0 && webPause > pauseHook,
      '$pauseHook < $webPause');
  check(
      'onResume 先恢复 WebView 再恢复媒体',
      resumeHook >= 0 && webResume >= 0 && webResume < resumeHook,
      '$webResume < $resumeHook');

  stdout.writeln('\n结果：$passed 通过 / $failed 失败');
  exit(failed == 0 ? 0 : 1);
}
