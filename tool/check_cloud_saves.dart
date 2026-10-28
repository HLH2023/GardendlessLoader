// 用真实服务器返回体校验存档数据解析（不进入 App，纯 Dart）。
//
// 用法：
//   PVZGE_TOKEN=pvz_xxx dart run tool/check_cloud_saves.dart
//
// 存在的意义：`/load`、`/history` 的字段形状是服务端 Python 定的，解析写错
// 只会在真机上表现为「页面空白」。这个脚本把同一份 JSON 拿下来直接过一遍
// 解析器，字段对不上立刻可见。
import 'dart:convert';
import 'dart:io';

import 'package:gardendless_loader/src/services/cloud_save_service.dart';

// 服务器地址不进源码：必须显式传入
//   dart run --define=PVZGE_SERVER=https://<your-server> tool/check_cloud_saves.dart
const base = String.fromEnvironment('PVZGE_SERVER');

Future<Map<String, Object?>> getJson(
    HttpClient client, String path, String token) async {
  final request = await client.getUrl(Uri.parse('$base$path'));
  request.headers.set('Authorization', 'Bearer $token');
  final response = await request.close();
  final text = await response.transform(utf8.decoder).join();
  if (response.statusCode != 200) {
    throw StateError('$path -> HTTP ${response.statusCode}: $text');
  }
  final decoded = jsonDecode(text);
  if (decoded is! Map) throw StateError('$path -> not a JSON object');
  return decoded.map((key, value) => MapEntry(key.toString(), value));
}

Future<void> main() async {
  var failures = 0;
  var passed = 0;
  void check(String name, bool ok, [String extra = '']) {
    if (ok) {
      passed++;
      stdout.writeln('  ok   $name${extra.isEmpty ? '' : ' → $extra'}');
    } else {
      failures++;
      stdout.writeln('  FAIL $name${extra.isEmpty ? '' : ' → $extra'}');
    }
  }

  // 离线部分：不需要服务器与令牌，先跑。这些断言盯的是「服务端字段形状 →
  // App 视图模型」的映射，以及旧服务端下存档页是否会藏掉玩家键。
  stdout.writeln('[0] keySources 逐键来源解析（离线 fixture）');
  final fixture = CloudSaveSnapshot.fromJson(<String, Object?>{
    'user': 'alice',
    'is_admin': false,
    'gameVersion': '1.7.0',
    'requestedGameVersion': '1.7.0',
    'load_kind': 'exact',
    'profileSource': '0.16.1',
    'keySources': <String, Object?>{
      'PvZ2_PlayerProperties': <String, Object?>{
        'gameVersion': '0.16.1',
        'kind': 'migrated',
      },
      'PvZ2_Settings': <String, Object?>{
        'gameVersion': '1.7.0',
        'kind': 'exact',
      },
      'PvZ2_GitHubLevels': <String, Object?>{
        'gameVersion': 'legacy',
        'kind': 'exact',
      },
    },
    'mtime': <String, Object?>{
      'PvZ2_PlayerProperties': 1700000000,
      'PvZ2_Settings': 1700000001,
      'PvZ2_GitHubLevels': 1700000002,
    },
    'summary': <String, Object?>{
      'PvZ2_PlayerProperties': <String, Object?>{'bytes': 900},
      'PvZ2_Settings': <String, Object?>{'bytes': 12},
      'PvZ2_GitHubLevels': <String, Object?>{'bytes': 34},
    },
    'device': <String, Object?>{},
    'profiles': <Object?>[
      <String, Object?>{
        'id': 'pppppppp1111',
        'name': 'nb',
        'index': 0,
        'bytes': 450,
        'revision': 'rev-a',
        'updatedAt': 1700000000,
        'summary': <String, Object?>{'name': 'nb'},
      },
    ],
    'server_ts': 1700000100,
  });
  final playerEntry = fixture.entryFor('PvZ2_PlayerProperties');
  final settingsEntry = fixture.entryFor('PvZ2_Settings');
  final levelsEntry = fixture.entryFor('PvZ2_GitHubLevels');
  check(
      '玩家键来源版本按 keySources 解析',
      playerEntry?.sourceVersion == '0.16.1' &&
          playerEntry?.sourceKind == 'migrated',
      '${playerEntry?.sourceVersion}/${playerEntry?.sourceKind}');
  check(
      '共享键用自己的来源版本（不被全局分区覆盖）',
      settingsEntry?.sourceVersion == '1.7.0' &&
          settingsEntry?.sourceKind == 'exact',
      '${settingsEntry?.sourceVersion}/${settingsEntry?.sourceKind}');
  check(
      'legacy 分区映射为空串且标记为已知',
      levelsEntry?.sourceVersion == '' && levelsEntry?.sourceKnown == true,
      '${levelsEntry?.sourceVersion}/${levelsEntry?.sourceKnown}');
  check(
      'player/settings 来源均标记为已知',
      playerEntry?.sourceKnown == true && settingsEntry?.sourceKnown == true,
      '${playerEntry?.sourceKnown}/${settingsEntry?.sourceKnown}');
  final noSources = CloudSaveSnapshot.fromJson(<String, Object?>{
    'user': 'alice',
    'gameVersion': '1.7.0',
    'keySources': null,
    'mtime': <String, Object?>{'PvZ2_Settings': 1700000001},
    'summary': <String, Object?>{
      'PvZ2_Settings': <String, Object?>{'bytes': 12}
    },
    'server_ts': 1700000100,
  });
  check(
      '老服务端没有 keySources → sourceKnown=false（允许回退）',
      noSources.entryFor('PvZ2_Settings')?.sourceKnown == false,
      '${noSources.entryFor('PvZ2_Settings')?.sourceKnown}');
  check('继承条目可识别', playerEntry?.inherited == true, '${playerEntry?.inherited}');
  check(
      'sharedEntries 仍不含玩家键',
      fixture.sharedEntries.length == 2 &&
          fixture.sharedEntries.every((e) => e.key != 'PvZ2_PlayerProperties'),
      fixture.sharedEntries.map((e) => e.key).join(','));
  check(
      'profiles 仍用全局 profileSource',
      fixture.profileSource == '0.16.1' &&
          fixture.profiles.first.sourceVersion == '0.16.1' &&
          fixture.profiles.first.sourceKnown == true,
      '${fixture.profiles.first.sourceVersion}/${fixture.profiles.first.sourceKnown}');

  stdout.writeln('[0b] 旧服务端存档页回退（源码检查）');
  final pageSource =
      File('lib/src/ui/pages/saves_page.dart').readAsStringSync();
  final profilesIndex =
      pageSource.indexOf('for (final profile in snapshot.profiles)');
  final sharedIndex = pageSource.indexOf(
      'if (snapshot.sharedEntries.isNotEmpty) ...[', profilesIndex);
  final allEntriesIndex = pageSource.indexOf(
      'for (final entry in snapshot.entries) ...[', sharedIndex);
  // 旧实现的 bug：`profiles.isEmpty && sharedEntries.isNotEmpty` 的 else if
  // 只渲染 Settings，把 entries 里的玩家键藏起来。
  final oldFallbackBranch = RegExp(
    r'snapshot\.profiles\.isEmpty\s*&&\s*snapshot\.entries\.isNotEmpty',
  ).hasMatch(pageSource);
  check(
      '没有 profiles 时渲染全部 entries（不再只渲染共享键）',
      profilesIndex > 0 &&
          sharedIndex > profilesIndex &&
          allEntriesIndex > sharedIndex &&
          !oldFallbackBranch,
      'profile@$profilesIndex shared@$sharedIndex entries@$allEntriesIndex');

  if (base.isEmpty) {
    stderr.writeln(
      '\n离线断言：$passed 通过 / $failures 失败\n'
      '缺少 PVZGE_SERVER，跳过在线部分。用法：\n'
      '  dart run --define=PVZGE_SERVER=https://<server> tool/check_cloud_saves.dart',
    );
    exit(2);
  }
  final token = Platform.environment['PVZGE_TOKEN'] ?? '';
  if (token.isEmpty) {
    stderr.writeln(
      '\n离线断言：$passed 通过 / $failures 失败\n缺少 PVZGE_TOKEN，跳过在线部分',
    );
    exit(2);
  }
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);

  stdout.writeln('[1] /load 解析');
  try {
    final json = await getJson(client, '/_save/app/load', token);
    final snapshot = CloudSaveSnapshot.fromJson(json);
    check('账号解析', snapshot.user.isNotEmpty, snapshot.user);
    check(
        '存档条目非空', snapshot.entries.isNotEmpty, '${snapshot.entries.length} 条');
    check(
        '最后写入时间有效',
        snapshot.lastWrite > 0,
        DateTime.fromMillisecondsSinceEpoch(snapshot.lastWrite * 1000)
            .toString());
    final player = snapshot.entries
        .where((e) => e.key == 'PvZ2_PlayerProperties')
        .toList();
    if (player.isNotEmpty) {
      final entry = player.first;
      check('玩家进度字节数 > 0', entry.bytes > 0, '${entry.bytes} B');
      check('玩家名/金币/宝石可读', entry.playerName != null && entry.coin != null,
          '${entry.playerName} / ${entry.coin} / ${entry.gem}');
    } else {
      check('玩家进度存在', false);
    }
    final withDevice = snapshot.entries.where((e) => e.deviceLabel.isNotEmpty);
    check('最后写入设备可读', withDevice.isNotEmpty,
        withDevice.map((e) => '${e.key}=${e.deviceLabel}').join(', '));

    // 多玩家：新服务端把玩家拆成独立文档，数组只是信封。
    // 旧服务端不返回 profiles 时跳过，保持向后兼容。
    if (snapshot.profiles.isNotEmpty) {
      check('玩家列表可解析', snapshot.profiles.isNotEmpty,
          '${snapshot.profiles.length} 份');
      final ids = snapshot.profiles.map((p) => p.id).toSet();
      check('玩家 profileId 唯一', ids.length == snapshot.profiles.length);
      check('玩家 revision 非空',
          snapshot.profiles.every((p) => p.revision.isNotEmpty));
      check('玩家按 index 排序',
          _sorted(snapshot.profiles.map((p) => p.index).toList()));
      final first = snapshot.profiles.first;
      check('玩家名称/摘要可读', first.name.isNotEmpty,
          '${first.name} / ${first.coin} / ${first.gem}');
      for (final profile in snapshot.profiles) {
        stdout.writeln('       · player ${profile.shortId} '
            '${profile.name}: ${profile.bytes}B, rev=${profile.revision}, '
            'source=${profile.sourceVersion.isEmpty ? 'legacy' : profile.sourceVersion}'
            '/${profile.sourceKind}');
      }
    }
    check('共享数据不含玩家键',
        snapshot.sharedEntries.every((e) => e.key != 'PvZ2_PlayerProperties'));
    if (snapshot.requestedGameVersion.isNotEmpty) {
      check('查看分区与请求版本一致', snapshot.requestedGameVersion.isNotEmpty,
          'requested=${snapshot.requestedGameVersion} served=${snapshot.gameVersion}');
    }
    for (final entry in snapshot.entries) {
      stdout.writeln('       · ${entry.key}: ${entry.bytes} B, '
          'mtime=${entry.mtime}, device=${entry.deviceLabel.isEmpty ? '-' : entry.deviceLabel}, '
          'source=${entry.sourceVersion.isEmpty ? 'legacy' : entry.sourceVersion}'
          '/${entry.sourceKind}, summary=${entry.summary}');
    }
    // 逐键来源版本必须与条目一致：历史/回滚按它选目录，错了会回滚到空目录。
    final rawKeySources = json['keySources'];
    if (rawKeySources is Map) {
      final mismatched = <String>[];
      rawKeySources.forEach((rawKey, rawSource) {
        if (rawSource is! Map) return;
        final declared = '${rawSource['gameVersion'] ?? ''}'.trim();
        final expected = declared == 'legacy' ? '' : declared;
        for (final entry in snapshot.entries.where((e) => e.key == '$rawKey')) {
          if (entry.sourceVersion != expected) {
            mismatched.add('${entry.key}: ${entry.sourceVersion} != $expected');
          }
        }
      });
      check('逐键来源版本与 keySources 一致', mismatched.isEmpty, mismatched.join('; '));
    }

    stdout.writeln('[2] /history 解析');
    try {
      final historyJson = await getHttp(
        client,
        '/_save/app/history?user=${Uri.encodeQueryComponent(snapshot.user)}'
        '&key=PvZ2_PlayerProperties&limit=5',
        token,
      );
      final raw = historyJson['versions'];
      final versions = (raw is List ? raw : const [])
          .whereType<Map>()
          .map((item) => CloudSaveVersion.fromJson(
                item.map((key, value) => MapEntry(key.toString(), value)),
              ))
          .toList();
      check('历史版本可解析', versions.isNotEmpty, '${versions.length} 个');
      if (versions.isNotEmpty) {
        final latest = versions.first;
        check('历史版本时间有效', latest.ts > 0, latest.writtenAt.toString());
        check('历史版本字节数 > 0', latest.bytes > 0, '${latest.bytes} B');
        stdout.writeln('       · 最新历史: ${latest.writtenAt} '
            '${latest.bytes}B ${latest.device}');
      }
    } catch (error) {
      check('历史版本接口', false, '$error');
    }
  } catch (error) {
    check('/load 接口', false, '$error');
  }

  client.close(force: true);
  stdout.writeln(
      failures == 0 ? '\n结果：$passed 项通过' : '\n结果：$passed 通过 / $failures 失败');
  exit(failures == 0 ? 0 : 1);
}

Future<Map<String, Object?>> getHttp(
    HttpClient client, String path, String token) async {
  final request = await client.getUrl(Uri.parse('$base$path'));
  request.headers.set('Authorization', 'Bearer $token');
  final response = await request.close();
  final text = await response.transform(utf8.decoder).join();
  if (response.statusCode != 200) {
    throw StateError('$path -> HTTP ${response.statusCode}');
  }
  final decoded = jsonDecode(text);
  return (decoded as Map).map((key, value) => MapEntry(key.toString(), value));
}

bool _sorted(List<int> values) {
  for (var i = 1; i < values.length; i++) {
    if (values[i] < values[i - 1]) return false;
  }
  return true;
}
