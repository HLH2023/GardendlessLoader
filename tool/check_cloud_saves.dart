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

const base = String.fromEnvironment(
  'PVZGE_SERVER',
  defaultValue: 'https://<server>',
);

Future<Map<String, Object?>> getJson(HttpClient client, String path, String token) async {
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
  final token = Platform.environment['PVZGE_TOKEN'] ?? '';
  if (token.isEmpty) {
    stderr.writeln('缺少 PVZGE_TOKEN');
    exit(2);
  }
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  var failures = 0;
  void check(String name, bool ok, [String extra = '']) {
    if (ok) {
      stdout.writeln('  ok   $name${extra.isEmpty ? '' : ' → $extra'}');
    } else {
      failures++;
      stdout.writeln('  FAIL $name${extra.isEmpty ? '' : ' → $extra'}');
    }
  }

  stdout.writeln('[1] /load 解析');
  try {
    final json = await getJson(client, '/_save/app/load', token);
    final snapshot = CloudSaveSnapshot.fromJson(json);
    check('账号解析', snapshot.user.isNotEmpty, snapshot.user);
    check('存档条目非空', snapshot.entries.isNotEmpty, '${snapshot.entries.length} 条');
    check('最后写入时间有效', snapshot.lastWrite > 0,
        DateTime.fromMillisecondsSinceEpoch(snapshot.lastWrite * 1000).toString());
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
    for (final entry in snapshot.entries) {
      stdout.writeln('       · ${entry.key}: ${entry.bytes} B, '
          'mtime=${entry.mtime}, summary=${entry.summary}');
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
  stdout.writeln(failures == 0 ? '\n结果：全部通过' : '\n结果：$failures 项失败');
  exit(failures == 0 ? 0 : 1);
}

Future<Map<String, Object?>> getHttp(HttpClient client, String path, String token) async {
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
