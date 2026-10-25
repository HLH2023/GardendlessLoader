// 本地资源服务器验收（纯 Dart，本机可跑）
//
// 覆盖：HTML 注入、虚拟脚本路径、MIME、Range/206、HEAD、路径穿越防护、
//       大文件流式返回、请求异常不影响服务器。
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
  // 目录下放一个「秘密」文件，用来验证穿越防护
  await File('${temp.path}/secret.txt').writeAsString('TOP-SECRET');

  const bridgeMarker = 'window.__PVZGE_APP__={base:"https://x",token:"pvz_TEST"};';
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
    check('index.html 返回 200', indexResp.statusCode == 200, indexResp.statusCode);
    check('注入脚本标签存在', indexBody.contains('/__pvz_') && indexBody.contains('/bridge.js'));
    check('面板脚本也被注入', indexBody.contains('/ui.js'));
    check('注入位于 </head> 之前', indexBody.indexOf('/bridge.js') < indexBody.indexOf('</head>'));
    check('原内容保留', indexBody.contains('main.js'));
    check('HTML 不缓存', indexResp.headers.value('cache-control') == 'no-store');

    // 2) 虚拟桥脚本
    final bridgePath = RegExp(r'src="(/__pvz_[^"]+/bridge\.js)"').firstMatch(indexBody)!.group(1)!;
    final bridgeResp = await req(client, server.baseUri.resolve(bridgePath));
    final bridgeBody = await bridgeResp.transform(utf8.decoder).join();
    check('桥脚本 200', bridgeResp.statusCode == 200, bridgeResp.statusCode);
    check('桥脚本内容正确', bridgeBody.contains('pvz_TEST'));
    check(
      '桥脚本 MIME 为 javascript',
      (bridgeResp.headers.contentType?.mimeType ?? '') == 'application/javascript',
      bridgeResp.headers.contentType,
    );

    // 3) wasm MIME + 长度
    final wasmResp = await req(client, server.baseUri.resolve('assets/game.wasm'));
    final wasmBody = await wasmResp.fold<List<int>>(<int>[], (b, c) => b..addAll(c));
    check('wasm 200', wasmResp.statusCode == 200, wasmResp.statusCode);
    check('wasm MIME 正确', wasmResp.headers.contentType?.mimeType == 'application/wasm',
        wasmResp.headers.contentType);
    check('wasm 内容完整', wasmBody.length == wasmBytes.length, wasmBody.length);

    // 4) Range
    final rangeResp = await req(
      client,
      server.baseUri.resolve('assets/game.wasm'),
      headers: {'range': 'bytes=10-19'},
    );
    final rangeBody = await rangeResp.fold<List<int>>(<int>[], (b, c) => b..addAll(c));
    check('Range 返回 206', rangeResp.statusCode == 206, rangeResp.statusCode);
    check('Content-Range 正确',
        rangeResp.headers.value('content-range') == 'bytes 10-19/4096',
        rangeResp.headers.value('content-range'));
    check('Range 长度 10', rangeBody.length == 10, rangeBody.length);
    check('Range 字节正确', rangeBody.first == wasmBytes[10] && rangeBody.last == wasmBytes[19]);

    // 5) 后缀 Range
    final suffixResp = await req(
      client,
      server.baseUri.resolve('assets/game.wasm'),
      headers: {'range': 'bytes=-8'},
    );
    check('后缀 Range 206', suffixResp.statusCode == 206, suffixResp.statusCode);
    await suffixResp.drain<void>();
    check('后缀 Content-Range 正确',
        suffixResp.headers.value('content-range') == 'bytes 4088-4095/4096',
        suffixResp.headers.value('content-range'));

    // 6) HEAD
    final headResp = await req(client, server.baseUri.resolve('main.js'), method: 'HEAD');
    final headBody = await headResp.fold<List<int>>(<int>[], (b, c) => b..addAll(c));
    check('HEAD 200 且无 body', headResp.statusCode == 200 && headBody.isEmpty,
        '${headResp.statusCode}/${headBody.length}');

    // 7) 路径穿越
    for (final evil in ['../secret.txt', '..%2Fsecret.txt', 'assets/../../secret.txt']) {
      final evilResp =
          await req(client, server.baseUri.resolve('/').resolve(evil));
      final body = await evilResp.transform(utf8.decoder).join();
      check('拒绝穿越 $evil', !body.contains('TOP-SECRET'),
          'HTTP ${evilResp.statusCode}');
    }

    // 8) 不存在的文件
    final missing = await req(client, server.baseUri.resolve('nope.js'));
    await missing.drain<void>();
    check('404 正常返回', missing.statusCode == 404, missing.statusCode);

    // 9) 服务器在异常请求后仍可用
    final after = await req(client, server.baseUri.resolve('main.js'));
    await after.drain<void>();
    check('异常后服务器仍正常', after.statusCode == 200, after.statusCode);
    // 10) 在线形态：反代上游 + 去掉服务端注入 + 注入本地桥
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstream.listen((req) async {
      final path = req.uri.path;
      if (path == '/' || path == '/index.html') {
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType('text', 'html', charset: 'utf-8')
          ..write('<html><head><title>Online</title>'
              '<script src="/_save/sync.js"></script>'
              '<script src="/_save/touch.js" defer></script>'
              '</head><body>online-game</body></html>');
        await req.response.close();
        return;
      }
      if (path == '/big.bin') {
        // 真实上游（nginx）会处理 Range，这里同样实现，才能验证透传是否忠实
        final payload = List<int>.generate(1024, (i) => i % 256);
        final rangeHeader = req.headers.value('range');
        if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
          final spec = rangeHeader.substring(6);
          final dash = spec.indexOf('-');
          final start = int.parse(spec.substring(0, dash));
          final end = int.parse(spec.substring(dash + 1));
          final slice = payload.sublist(start, end + 1);
          req.response
            ..statusCode = 206
            ..headers.contentType = ContentType('application', 'octet-stream')
            ..headers.set('accept-ranges', 'bytes')
            ..headers.set('content-range', 'bytes $start-$end/${payload.length}')
            ..headers.contentLength = slice.length
            ..add(slice);
          await req.response.close();
          return;
        }
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType('application', 'octet-stream')
          ..headers.set('accept-ranges', 'bytes')
          ..headers.contentLength = payload.length
          ..add(payload);
        await req.response.close();
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    });
    final onlineServer = await LocalResourceServer.start(
      root: null,
      bridgeScript: bridgeMarker,
      uiScript: '/*panel*/',
      upstream: Uri.parse('http://127.0.0.1:${upstream.port}/'),
    );
    check('在线形态标记正确', onlineServer.isOnline);
    final onlineIndex = await req(client, onlineServer.baseUri);
    final onlineBody = await onlineIndex.transform(utf8.decoder).join();
    check('在线页面 200', onlineIndex.statusCode == 200, onlineIndex.statusCode);
    check('保留上游内容', onlineBody.contains('online-game'));
    check('去掉服务端 sync.js', !onlineBody.contains('src="/_save/sync.js"'));
    check('去掉服务端 touch.js', !onlineBody.contains('src="/_save/touch.js"'));
    check('注入本地桥', onlineBody.contains('/__pvz_'));
    final onlineBridgePath =
        RegExp(r'src="(/__pvz_[^"]+/bridge\.js)"').firstMatch(onlineBody)!.group(1)!;
    final onlineBridge = await req(client, onlineServer.baseUri.resolve(onlineBridgePath));
    final onlineBridgeBody = await onlineBridge.transform(utf8.decoder).join();
    check('在线形态桥内容正确', onlineBridgeBody.contains('pvz_TEST'));
    final onlineBinary = await req(client, onlineServer.baseUri.resolve('big.bin'));
    final onlineBytes = await onlineBinary.fold<List<int>>(<int>[], (b, c) => b..addAll(c));
    check('在线二进制透传', onlineBinary.statusCode == 200 && onlineBytes.length == 1024,
        '${onlineBinary.statusCode}/${onlineBytes.length}');
    final onlineRange = await req(
      client,
      onlineServer.baseUri.resolve('big.bin'),
      headers: {'range': 'bytes=0-15'},
    );
    final onlineRangeBody = await onlineRange.fold<List<int>>(<int>[], (b, c) => b..addAll(c));
    check('在线 Range 透传 206', onlineRange.statusCode == 206, onlineRange.statusCode);
    check('在线 Range 长度', onlineRangeBody.length == 16, onlineRangeBody.length);
    await onlineServer.stop();
    await upstream.close(force: true);

  } finally {
    client.close(force: true);
    await server.stop();
    await temp.delete(recursive: true);
  }

  stdout.writeln('\n结果：$passed 通过 / $failed 失败');
  exit(failed == 0 ? 0 : 1);
}
