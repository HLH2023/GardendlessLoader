// 本地资源服务器验收（纯 Dart，本机可跑）
//
// 覆盖：HTML 注入、虚拟脚本路径、MIME、Range/206、HEAD、路径穿越防护、
//       大文件流式返回、请求异常不影响服务器、固定端口（origin 稳定）与端口冲突。
//
// 用法：dart run tool/check_local_server.dart
import 'dart:convert';
import 'dart:io';

import 'package:gardendless_loader/src/services/local_resource_server.dart';

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

Future<HttpClientResponse> req(
  HttpClient client,
  Uri uri, {
  String method = 'GET',
  Map<String, String> headers = const {},
}) async {
  final request = await client.openUrl(method, uri);
  headers.forEach(request.headers.set);
  return request.close();
}

/// 取一个当前空闲的端口：绑 0 让系统分配后立刻释放。
///
/// 释放与再次绑定之间存在竞态，但这是本机验收脚本：被别人抢走只会让断言
/// 失败（看得见），不会误判通过。
Future<int> freePort() async {
  final probe = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final port = probe.port;
  await probe.close(force: true);
  return port;
}

Future<void> main() async {
  final temp = await Directory.systemTemp.createTemp('pvz-local-server');
  final root = Directory('${temp.path}/res');
  await root.create(recursive: true);
  await Directory('${root.path}/assets').create(recursive: true);

  final html = '''<!DOCTYPE html>
<html><head><title>Game</title></head>
<body><script src="main.js"></script></body></html>''';
  await File('${root.path}/index.html').writeAsString(html);
  await File('${root.path}/main.js').writeAsString('console.log(1);');
  final wasmBytes = List<int>.generate(4096, (i) => i % 256);
  await File('${root.path}/assets/game.wasm').writeAsBytes(wasmBytes);
  // Cocos 打包产物带内容哈希：文件名里的哈希不变则内容不变，可以 immutable。
  await File('${root.path}/assets/_virtual_cc-937a2166.js')
      .writeAsString('export const v = 1;');
  // 目录下放一个「秘密」文件，用来验证穿越防护
  await File('${temp.path}/secret.txt').writeAsString('TOP-SECRET');

  const bridgeMarker =
      'window.__PVZGE_APP__={base:"https://x",token:"pvz_TEST"};';
  final server = await LocalResourceServer.start(
    root: root,
    bridgeScript: '$bridgeMarker\n/*shim*/',
    uiScript: '/*panel*/',
  );
  stdout.writeln('[server] ${server.baseUri}');

  final client = HttpClient();
  try {
    // 1) index.html 注入
    final indexResp = await req(client, server.baseUri);
    final indexBody = await indexResp.transform(utf8.decoder).join();
    check(
        'index.html 返回 200', indexResp.statusCode == 200, indexResp.statusCode);
    check('注入脚本标签存在',
        indexBody.contains('/__pvz_') && indexBody.contains('/bridge.js'));
    check('面板脚本也被注入', indexBody.contains('/ui.js'));
    check('注入位于 </head> 之前',
        indexBody.indexOf('/bridge.js') < indexBody.indexOf('</head>'));
    check('原内容保留', indexBody.contains('main.js'));
    check('HTML 不缓存', indexResp.headers.value('cache-control') == 'no-store');

    // 2) 虚拟桥脚本
    final bridgePath = RegExp(r'src="(/__pvz_[^"]+/bridge\.js)"')
        .firstMatch(indexBody)!
        .group(1)!;
    final bridgeResp = await req(client, server.baseUri.resolve(bridgePath));
    final bridgeBody = await bridgeResp.transform(utf8.decoder).join();
    check('桥脚本 200', bridgeResp.statusCode == 200, bridgeResp.statusCode);
    check('桥脚本内容正确', bridgeBody.contains('pvz_TEST'));
    check(
      '桥脚本 MIME 为 javascript',
      (bridgeResp.headers.contentType?.mimeType ?? '') ==
          'application/javascript',
      bridgeResp.headers.contentType,
    );

    // 3) wasm MIME + 长度
    final wasmResp =
        await req(client, server.baseUri.resolve('assets/game.wasm'));
    final wasmBody =
        await wasmResp.fold<List<int>>(<int>[], (b, c) => b..addAll(c));
    check('wasm 200', wasmResp.statusCode == 200, wasmResp.statusCode);
    check(
        'wasm MIME 正确',
        wasmResp.headers.contentType?.mimeType == 'application/wasm',
        wasmResp.headers.contentType);
    check('wasm 内容完整', wasmBody.length == wasmBytes.length, wasmBody.length);

    // 4) Range
    final rangeResp = await req(
      client,
      server.baseUri.resolve('assets/game.wasm'),
      headers: {'range': 'bytes=10-19'},
    );
    final rangeBody =
        await rangeResp.fold<List<int>>(<int>[], (b, c) => b..addAll(c));
    check('Range 返回 206', rangeResp.statusCode == 206, rangeResp.statusCode);
    check(
        'Content-Range 正确',
        rangeResp.headers.value('content-range') == 'bytes 10-19/4096',
        rangeResp.headers.value('content-range'));
    check('Range 长度 10', rangeBody.length == 10, rangeBody.length);
    check('Range 字节正确',
        rangeBody.first == wasmBytes[10] && rangeBody.last == wasmBytes[19]);

    // 5) 后缀 Range
    final suffixResp = await req(
      client,
      server.baseUri.resolve('assets/game.wasm'),
      headers: {'range': 'bytes=-8'},
    );
    check('后缀 Range 206', suffixResp.statusCode == 206, suffixResp.statusCode);
    await suffixResp.drain<void>();
    check(
        '后缀 Content-Range 正确',
        suffixResp.headers.value('content-range') == 'bytes 4088-4095/4096',
        suffixResp.headers.value('content-range'));

    // 6) HEAD
    final headResp =
        await req(client, server.baseUri.resolve('main.js'), method: 'HEAD');
    final headBody =
        await headResp.fold<List<int>>(<int>[], (b, c) => b..addAll(c));
    check('HEAD 200 且无 body', headResp.statusCode == 200 && headBody.isEmpty,
        '${headResp.statusCode}/${headBody.length}');

    // 7) 缓存策略：HTML 不能缓存（每次注入 nonce），带内容哈希的资源长期
    //    缓存，其余 no-cache + ETag 重新验证。资源包 2 GB，重进游戏不必
    //    每次都从磁盘重读。
    final hashedResp = await req(
        client, server.baseUri.resolve('assets/_virtual_cc-937a2166.js'));
    await hashedResp.drain<void>();
    check(
      '带哈希的资源 immutable 长期缓存',
      hashedResp.headers.value('cache-control') ==
          'public, max-age=31536000, immutable',
      hashedResp.headers.value('cache-control'),
    );
    final plainResp =
        await req(client, server.baseUri.resolve('assets/game.wasm'));
    await plainResp.drain<void>();
    final plainEtag = plainResp.headers.value('etag');
    check(
      '普通资源 no-cache + ETag（可重新验证）',
      plainResp.headers.value('cache-control') == 'no-cache' &&
          plainEtag != null &&
          plainEtag.isNotEmpty,
      '${plainResp.headers.value('cache-control')} / $plainEtag',
    );
    final revalidated = await req(
      client,
      server.baseUri.resolve('assets/game.wasm'),
      headers: {'if-none-match': plainEtag ?? ''},
    );
    final revalidatedBody =
        await revalidated.fold<List<int>>(<int>[], (b, c) => b..addAll(c));
    check(
      'ETag 命中返回 304 且无 body',
      revalidated.statusCode == 304 && revalidatedBody.isEmpty,
      '${revalidated.statusCode}/${revalidatedBody.length}',
    );
    check(
      '304 保留 ETag 与缓存策略',
      revalidated.headers.value('etag') == plainEtag &&
          revalidated.headers.value('cache-control') == 'no-cache',
      revalidated.headers.value('etag'),
    );

    // 8) 路径穿越
    for (final evil in [
      '../secret.txt',
      '..%2Fsecret.txt',
      'assets/../../secret.txt'
    ]) {
      final evilResp =
          await req(client, server.baseUri.resolve('/').resolve(evil));
      final body = await evilResp.transform(utf8.decoder).join();
      check('拒绝穿越 $evil', !body.contains('TOP-SECRET'),
          'HTTP ${evilResp.statusCode}');
    }

    // 9) 不存在的文件
    final missing = await req(client, server.baseUri.resolve('nope.js'));
    await missing.drain<void>();
    check('404 正常返回', missing.statusCode == 404, missing.statusCode);

    // 10) 服务器在异常请求后仍可用
    final after = await req(client, server.baseUri.resolve('main.js'));
    await after.drain<void>();
    check('异常后服务器仍正常', after.statusCode == 200, after.statusCode);

    // ── 11) 对抗性：符号链接逃逸（资源目录里放一个指向 /etc/passwd 的链接）
    final linkPath = '${root.path}/escape.txt';
    try {
      await Link(linkPath).create('/etc/passwd');
    } catch (_) {}
    final linkResp = await req(client, server.baseUri.resolve('escape.txt'));
    final linkBody = await linkResp.transform(utf8.decoder).join();
    check('符号链接不能逃出资源根', !linkBody.contains('root:x:'),
        'HTTP ${linkResp.statusCode}');

    // ── 12) 畸形 Range 不能崩，也不能返回错内容
    for (final bad in [
      'bytes=abc-def',
      'bytes=99999-',
      'bytes=-0',
      'items=0-1'
    ]) {
      final r = await req(
        client,
        server.baseUri.resolve('assets/game.wasm'),
        headers: {'range': bad},
      );
      final body = await r.fold<List<int>>(<int>[], (b, c) => b..addAll(c));
      final okStatus = r.statusCode == 200 || r.statusCode == 206;
      check('畸形 Range "$bad" 优雅处理', okStatus && body.isNotEmpty,
          'HTTP ${r.statusCode} ${body.length}B');
    }

    // ── 13) 并发请求：不能串内容、不能崩
    final results = await Future.wait(
      List.generate(24, (i) async {
        final r = await req(
          client,
          server.baseUri.resolve('assets/game.wasm'),
          headers: {'range': 'bytes=$i-${i + 31}'},
        );
        final body = await r.fold<List<int>>(<int>[], (b, c) => b..addAll(c));
        return (r.statusCode, body.length, body.isEmpty ? -1 : body.first);
      }),
    );
    final allPartial = results.every((r) => r.$1 == 206 && r.$2 == 32);
    final correctFirst = List.generate(24, (i) => i).every(
      (i) => results[i].$3 == (i % 256),
    );
    check('24 个并发 Range 全部 206 且长度正确', allPartial, results.first);
    check('并发下每个响应对应自己的区间', correctFirst);

    // ── 14) 没有 </head> 的 HTML 也要注入到最前面
    await File('${root.path}/bare.html')
        .writeAsString('<html><body>bare</body></html>');
    final bareResp = await req(client, server.baseUri.resolve('bare.html'));
    final bareBody = await bareResp.transform(utf8.decoder).join();
    check('无 head 的 HTML 也注入', bareBody.contains('/__pvz_'),
        bareBody.substring(0, 20));

    // ── 15) 虚拟桥脚本不支持 HEAD 时不能挂掉
    final headBridge =
        await req(client, server.baseUri.resolve(bridgePath), method: 'HEAD');
    await headBridge.drain<void>();
    check(
        '桥脚本 HEAD 正常返回',
        headBridge.statusCode == 200 || headBridge.statusCode == 404,
        headBridge.statusCode);

    // ── 16) 固定端口：origin 不随重启变化（localStorage 存档依赖它）
    final pinnedPort = await freePort();
    final pinned = await LocalResourceServer.start(
      root: root,
      bridgeScript: '$bridgeMarker\n/*shim*/',
      uiScript: '/*panel*/',
      port: pinnedPort,
    );
    try {
      check(
          '指定端口生效', pinned.port == pinnedPort, '${pinned.port} vs $pinnedPort');
      check(
          'baseUri 指向固定端口',
          pinned.baseUri.host == '127.0.0.1' &&
              pinned.baseUri.port == pinnedPort,
          pinned.baseUri);
      final pinnedResp = await req(client, pinned.baseUri);
      final pinnedBody = await pinnedResp.transform(utf8.decoder).join();
      check('固定端口页面 200', pinnedResp.statusCode == 200, pinnedResp.statusCode);
      check(
          '固定端口仍注入桥脚本', pinnedBody.contains('/__pvz_'), pinnedResp.statusCode);
      final pinnedAsset =
          await req(client, pinned.baseUri.resolve('assets/game.wasm'));
      final pinnedBytes =
          await pinnedAsset.fold<List<int>>(<int>[], (b, c) => b..addAll(c));
      check(
          '固定端口资源请求可用',
          pinnedAsset.statusCode == 200 &&
              pinnedBytes.length == wasmBytes.length,
          '${pinnedAsset.statusCode}/${pinnedBytes.length}');

      // 同一端口再启一次：必须抛明确类型，绝不能静默改用随机端口
      Object? secondError;
      try {
        final duplicate = await LocalResourceServer.start(
          root: root,
          bridgeScript: bridgeMarker,
          port: pinnedPort,
        );
        // 万一真的绑上了，先收掉再让断言失败（否则端口泄漏到后面的用例）
        await duplicate.stop();
      } catch (error) {
        secondError = error;
      }
      check('端口被占用抛 LocalPortUnavailableException',
          secondError is LocalPortUnavailableException, secondError ?? '没有抛异常');
      check(
          '异常带正确的 port',
          secondError is LocalPortUnavailableException &&
              secondError.port == pinnedPort,
          secondError is LocalPortUnavailableException
              ? secondError.port
              : null);
      check(
          '异常消息可读',
          secondError is LocalPortUnavailableException &&
              secondError.toString().contains('$pinnedPort'),
          secondError);
    } finally {
      await pinned.stop();
    }

    // port=0 保留系统分配行为（测试与旧调用点的兼容路径）
    final ephemeral = await LocalResourceServer.start(
      root: root,
      bridgeScript: bridgeMarker,
      port: 0,
    );
    check('port=0 仍能启动并拿到非 0 端口', ephemeral.port != 0, ephemeral.port);
    await ephemeral.stop();
  } finally {
    client.close(force: true);
    await server.stop();
    await temp.delete(recursive: true);
  }

  stdout.writeln('\n结果：$passed 通过 / $failed 失败');
  exit(failed == 0 ? 0 : 1);
}
