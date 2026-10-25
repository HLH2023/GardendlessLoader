import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// 本地资源服务器：把已解包的游戏资源目录以 HTTP 方式提供给内嵌浏览器。
///
/// 为什么需要：桌面端（Windows）没有 Android 的 `WebViewAssetLoader`，
/// 而游戏是纯前端应用（index.html + wasm + 资源），需要一个 origin 才能跑。
/// 顺带这层还承担了两件 Android 由原生/网关做的事：
///   1. 往 HTML 里注入存档脚本（等价于 nginx 的 sub_filter；
///      WebView 的 document-start 注入各家实现不一致，改 HTML 更可控）
///   2. 注入 `window.__PVZGE_APP__`（服务器地址 + 设备令牌），
///      让 app-sync.js 的 shim 能把 /_save/api 改写到 Bearer 通道
///
/// 安全约束：
///   - 只绑 127.0.0.1，端口随机，外部不可达
///   - 路径必须落在资源根目录内（防 ../ 穿越）
///   - 每次启动生成一次性前缀，注入脚本路径带随机串，避免被页面里的
///     其他脚本猜中并读取令牌
/// 桌面端游玩形态（纯 Dart 版，避免把 Flutter 设置模型拖进这个文件）。
enum DesktopPlayMode { local, online }

/// 桌面端一次游戏会话所需的全部信息。
class DesktopGameLaunch {
  const DesktopGameLaunch({
    required this.uri,
    required this.server,
    required this.mode,
    required this.hasCloudSaves,
  });

  /// 游戏窗口要加载的地址（永远是 127.0.0.1）
  final Uri uri;

  /// 会话结束后必须 stop，否则端口与线程会泄漏
  final LocalResourceServer server;

  /// 本地资源 or 在线反代
  final DesktopPlayMode mode;

  /// 存档桥是否注入成功（未登录时为 false）
  final bool hasCloudSaves;
}

class LocalResourceServer {
  LocalResourceServer._(
    this._server,
    this._root,
    this._bridgeScript,
    this._uiScript, {
    Uri? upstream,
  }) : _upstream = upstream;

  final HttpServer _server;
  final Directory _root;
  final String _bridgeScript;
  final String _uiScript;

  /// 在线形态的上游地址；为空表示纯本地资源模式。
  final Uri? _upstream;

  /// 供外部判断当前是哪种形态。
  bool get isOnline => _upstream != null;

  /// 一次性的虚拟路径前缀（内含随机串），挂载注入脚本。
  static String _newNonce() {
    final rand = Random.secure();
    final bytes = List<int>.generate(12, (_) => rand.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  late final String _nonce = _newNonce();

  Uri get baseUri => Uri.parse('http://127.0.0.1:${_server.port}/');

  int get port => _server.port;

  /// 启动服务器。
  ///
  /// [root] 资源根目录（解包后的游戏目录，包含 index.html）。
  /// [bridgeScript] 存档桥脚本内容（已含 `window.__PVZGE_APP__` 前缀 + shim + sync）。
  /// [uiScript] 面板脚本内容（可选）；为空时只注入存档桥。
  static Future<LocalResourceServer> start({
    required Directory? root,
    required String bridgeScript,
    String uiScript = '',
    Uri? upstream,
  }) async {
    // 两种形态共用这一个服务器，只是「文件从哪来」不同：
    //   root 非空 → 本地资源包（离线）
    //   upstream 非空 → 反代服务器上的游戏页（在线）
    // 页面 origin 都是 127.0.0.1，因此存档桥、存档语义完全一致。
    if (root == null && upstream == null) {
      throw StateError('必须提供资源目录或上游地址');
    }
    if (root != null) {
      if (!await root.exists()) {
        throw StateError('资源目录不存在: ${root.path}');
      }
      final indexFile = File(p.join(root.path, 'index.html'));
      if (!await indexFile.exists()) {
        throw StateError('资源目录里没有 index.html: ${root.path}');
      }
    }
    // 只监听回环地址：这个服务器不该被局域网访问
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final instance = LocalResourceServer._(
      server,
      root ?? Directory(''),
      bridgeScript,
      uiScript,
      upstream: upstream,
    );
    server.listen(instance._handle, onError: (Object _) {});
    return instance;
  }

  Future<void> stop() async {
    await _server.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      await _serve(request);
    } catch (_) {
      // 任何异常都只影响这一个请求，绝不让服务器整体挂掉
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    final segments = request.uri.pathSegments.where((s) => s.isNotEmpty).toList();

    // 注入脚本（虚拟路径，不属于资源目录）
    if (segments.length == 2 && segments[0] == '__pvz_$_nonce') {
      final body = segments[1] == 'bridge.js' ? _bridgeScript : _uiScript;
      if (body.isEmpty) {
        response.statusCode = HttpStatus.notFound;
        return response.close();
      }
      final bytes = utf8.encode(body);
      response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType('application', 'javascript', charset: 'utf-8')
        ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
        ..headers.contentLength = bytes.length;
      response.add(bytes);
      return response.close();
    }

    final upstream = _upstream;
    if (upstream != null) {
      return _serveUpstream(request, upstream, segments);
    }

    final relative = segments.isEmpty ? 'index.html' : segments.join('/');
    final file = _resolveInside(relative);
    if (file == null) {
      response.statusCode = HttpStatus.forbidden;
      return response.close();
    }
    if (!await file.exists()) {
      response.statusCode = HttpStatus.notFound;
      return response.close();
    }

    final length = await file.length();
    final contentType = _contentTypeFor(file.path);
    final isHtml = contentType.mimeType == 'text/html';

    // HTML 要改写（注入脚本），不能直接流式发送，也不能带 Range
    if (isHtml) {
      final bytes = await _htmlWithInjection(file);
      response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = contentType
        ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
        ..headers.contentLength = bytes.length;
      response.add(bytes);
      return response.close();
    }

    // 非 HTML 支持 Range：游戏里有大体积音视频，断点/拖动都靠它
    final range = _parseRange(request.headers.value(HttpHeaders.rangeHeader), length);
    if (range != null) {
      final (start, end) = range;
      response
        ..statusCode = HttpStatus.partialContent
        ..headers.contentType = contentType
        ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/$length',
        )
        ..headers.contentLength = end - start + 1;
      if (request.method == 'HEAD') return response.close();
      await response.addStream(file.openRead(start, end + 1));
      return response.close();
    }

    response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = contentType
      ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..headers.contentLength = length;
    if (request.method == 'HEAD') return response.close();
    await response.addStream(file.openRead());
    return response.close();
  }

  /// 在线形态：把请求转发到上游，HTML 去掉服务端自己注入的存档脚本，
  /// 再注入本地这份（带设备令牌的）桥，保证两种形态存档行为一致。
  Future<void> _serveUpstream(
    HttpRequest request,
    Uri upstream,
    List<String> segments,
  ) async {
    final response = request.response;
    final target = upstream.replace(
      path: segments.isEmpty ? upstream.path : p.posix.join(upstream.path, segments.join('/')),
      query: request.uri.hasQuery ? request.uri.query : null,
    );
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final upstreamRequest = await client.openUrl(request.method, target);
      // 透传对游戏有用的头；Cookie 不透传（在线形态用设备令牌，不用 IdP 会话）
      for (final name in const [
        HttpHeaders.rangeHeader,
        HttpHeaders.ifRangeHeader,
        HttpHeaders.ifNoneMatchHeader,
        HttpHeaders.ifModifiedSinceHeader,
        HttpHeaders.acceptHeader,
        HttpHeaders.acceptEncodingHeader,
      ]) {
        final value = request.headers.value(name);
        if (value != null) upstreamRequest.headers.set(name, value);
      }
      upstreamRequest.headers.set(HttpHeaders.userAgentHeader, 'GardendlessLauncher/1.0');
      final upstreamResponse = await upstreamRequest.close();
      final contentType = upstreamResponse.headers.contentType ??
          ContentType('application', 'octet-stream');
      final isHtml = (contentType.mimeType) == 'text/html';

      if (isHtml) {
        final body = await upstreamResponse.transform(utf8.decoder).join();
        final cleaned = _stripServerInjected(body);
        final bytes = await _injectInto(cleaned);
        response
          ..statusCode = upstreamResponse.statusCode == 200 ? 200 : upstreamResponse.statusCode
          ..headers.contentType = ContentType('text', 'html', charset: 'utf-8')
          ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
          ..headers.contentLength = bytes.length;
        response.add(bytes);
        return response.close();
      }

      // 非 HTML：原样流式透传（含 206 与 Content-Range）
      response.statusCode = upstreamResponse.statusCode;
      for (final name in const [
        HttpHeaders.contentTypeHeader,
        HttpHeaders.contentRangeHeader,
        HttpHeaders.acceptRangesHeader,
        HttpHeaders.etagHeader,
        HttpHeaders.lastModifiedHeader,
        HttpHeaders.cacheControlHeader,
      ]) {
        final value = upstreamResponse.headers.value(name);
        if (value != null) response.headers.set(name, value);
      }
      final length = upstreamResponse.contentLength;
      if (length >= 0) response.headers.contentLength = length;
      if (request.method == 'HEAD') {
        return response.close();
      }
      await response.addStream(upstreamResponse);
      return response.close();
    } on SocketException {
      response.statusCode = HttpStatus.badGateway;
      return response.close();
    } finally {
      client.close();
    }
  }

  /// 去掉上游页面里由服务端 sub_filter 注入的存档脚本（改由本地注入）。
  String _stripServerInjected(String html) {
    var result = html;
    for (final name in const ['sync.js', 'ui.js', 'touch.js', 'version-check.js', 'app-sync.js', 'app-ui.js']) {
      result = result.replaceAll(
        RegExp(r'<script[^>]*src="[^"]*' + RegExp.escape(name) + r'"[^>]*>\s*</script>'),
        '',
      );
    }
    return result;
  }

  /// 把相对路径解析到资源根目录内；越界返回 null。
  File? _resolveInside(String relative) {
    final normalized = p.normalize(relative);
    if (normalized.startsWith('..') || p.isAbsolute(normalized)) return null;
    final full = p.join(_root.path, normalized);
    final rootPath = p.canonicalize(_root.path);
    final fullPath = p.canonicalize(full);
    if (fullPath != rootPath && !fullPath.startsWith('$rootPath${p.separator}')) {
      return null;
    }
    return File(fullPath);
  }

  Future<Uint8List> _htmlWithInjection(File file) async {
    final html = await file.readAsString();
    return _injectInto(html);
  }

  /// HTML 注入（本地与在线两条路径共用）。
  Future<Uint8List> _injectInto(String html) async {
    final bridge = '<script src="/__pvz_$_nonce/bridge.js"></script>';
    final ui = _uiScript.isEmpty
        ? ''
        : '<script src="/__pvz_$_nonce/ui.js" defer></script>';
    final snippet = '$bridge$ui';
    // 优先插进 <head>，保证在游戏脚本之前执行；没有 head 就插到最前面
    final lower = html.toLowerCase();
    final headIndex = lower.indexOf('</head>');
    final String patched;
    if (headIndex >= 0) {
      patched = html.substring(0, headIndex) + snippet + html.substring(headIndex);
    } else {
      patched = snippet + html;
    }
    return Uint8List.fromList(utf8.encode(patched));
  }

  static ContentType _contentTypeFor(String path) {
    final ext = p.extension(path).toLowerCase();
    return switch (ext) {
      '.html' || '.htm' => ContentType('text', 'html', charset: 'utf-8'),
      '.js' || '.mjs' => ContentType('application', 'javascript', charset: 'utf-8'),
      '.json' => ContentType('application', 'json', charset: 'utf-8'),
      '.css' => ContentType('text', 'css', charset: 'utf-8'),
      '.wasm' => ContentType('application', 'wasm'),
      '.png' => ContentType('image', 'png'),
      '.jpg' || '.jpeg' => ContentType('image', 'jpeg'),
      '.webp' => ContentType('image', 'webp'),
      '.svg' => ContentType('image', 'svg+xml'),
      '.ico' => ContentType('image', 'x-icon'),
      '.mp3' => ContentType('audio', 'mpeg'),
      '.ogg' => ContentType('audio', 'ogg'),
      '.wav' => ContentType('audio', 'wav'),
      '.m4a' => ContentType('audio', 'mp4'),
      '.mp4' => ContentType('video', 'mp4'),
      '.webm' => ContentType('video', 'webm'),
      '.ttf' => ContentType('font', 'ttf'),
      '.otf' => ContentType('font', 'otf'),
      '.woff' => ContentType('font', 'woff'),
      '.woff2' => ContentType('font', 'woff2'),
      '.txt' || '.md' => ContentType('text', 'plain', charset: 'utf-8'),
      _ => ContentType('application', 'octet-stream'),
    };
  }

  /// 解析 `Range: bytes=start-end`；不支持的形式一律按整份返回。
  static (int, int)? _parseRange(String? header, int length) {
    if (header == null || !header.startsWith('bytes=') || length <= 0) return null;
    final spec = header.substring('bytes='.length).split(',').first.trim();
    final dash = spec.indexOf('-');
    if (dash < 0) return null;
    final startText = spec.substring(0, dash).trim();
    final endText = spec.substring(dash + 1).trim();
    int start;
    int end;
    if (startText.isEmpty) {
      // bytes=-N：最后 N 字节
      final suffix = int.tryParse(endText);
      if (suffix == null || suffix <= 0) return null;
      start = length - suffix;
      if (start < 0) start = 0;
      end = length - 1;
    } else {
      start = int.tryParse(startText) ?? -1;
      if (start < 0) return null;
      end = endText.isEmpty ? length - 1 : (int.tryParse(endText) ?? length - 1);
      if (end >= length) end = length - 1;
    }
    if (start > end || start >= length) return null;
    return (start, end);
  }
}
