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
/// 顺带这层还承担了两件事：
///   1. 往 HTML 里注入存档脚本（等价于 nginx 的 sub_filter；
///      WebView 的 document-start 注入各家实现不一致，改 HTML 更可控）
///   2. 注入 `window.__PVZGE_APP__`（服务器地址 + 设备令牌 + 游戏版本），
///      让 app-sync.js 的 shim 能把 /_save/api 改写到 Bearer 通道
///
/// 安全约束：
///   - 只绑 127.0.0.1，外部不可达
///   - 路径必须落在资源根目录内（防 ../ 穿越）
///   - 每次启动生成一次性前缀，注入脚本路径带随机串，避免被页面里的
///     其他脚本猜中并读取令牌
///
/// 端口语义（决定 localStorage 的 origin 是否稳定）：
///   - `start(port: 0)` 由系统分配随机端口，仅用于测试/兼容；
///   - `start(port: n)` 绑定固定端口，绑定失败抛 [LocalPortUnavailableException]。
///     端口从哪来（配置、上次退出时的记录、冲突后重选）由调用方决定，
///     本文件不做分配与持久化。

/// 桌面端一次游戏会话所需的全部信息。
class DesktopGameLaunch {
  const DesktopGameLaunch({
    required this.uri,
    required this.server,
    required this.hasCloudSaves,
  });

  /// 游戏窗口要加载的地址（永远是 127.0.0.1）
  final Uri uri;

  /// 会话结束后必须 stop，否则端口与线程会泄漏
  final LocalResourceServer server;

  /// 存档桥是否注入成功（未登录时为 false）
  final bool hasCloudSaves;
}

/// 固定端口无法绑定（被占用、无权限等）。
///
/// 单独成类型的原因：调用方需要区分「端口要换一个」与「资源目录坏了」这类
/// 错误，前者可以换端口重试，后者重试多少次都没用。绝不能在服务器内部改成
/// 随机端口继续跑 —— 那样 origin 又变了，调用方以为稳妥的存档位置会静默失效。
class LocalPortUnavailableException implements Exception {
  const LocalPortUnavailableException(this.port, this.reason);

  /// 希望绑定但失败了的端口。
  final int port;

  /// 底层失败原因（通常是 `SocketException` 的 message）。
  final String reason;

  @override
  String toString() => 'LocalPortUnavailableException: 无法绑定 127.0.0.1:$port'
      '${reason.isEmpty ? '' : '（$reason）'}';
}

class LocalResourceServer {
  LocalResourceServer._(
    this._server,
    this._root,
    this._bridgeScript,
    this._uiScript,
  );

  final HttpServer _server;
  final Directory _root;
  final String _bridgeScript;
  final String _uiScript;

  /// 资源根解析软链后的真实路径（懒加载缓存）。
  String? _canonicalRoot;

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
  /// [port] 固定端口。0（默认）表示由系统分配随机端口；>0 时绑定该端口，
  /// 失败抛 [LocalPortUnavailableException]，不会静默退回随机端口 —— 见
  /// [LocalPortUnavailableException] 的说明。
  static Future<LocalResourceServer> start({
    required Directory root,
    required String bridgeScript,
    String uiScript = '',
    int port = 0,
  }) async {
    if (!await root.exists()) {
      throw StateError('资源目录不存在: ${root.path}');
    }
    final indexFile = File(p.join(root.path, 'index.html'));
    if (!await indexFile.exists()) {
      throw StateError('资源目录里没有 index.html: ${root.path}');
    }
    // 只监听回环地址：这个服务器不该被局域网访问
    final server = await _bind(port);
    final instance = LocalResourceServer._(
      server,
      root,
      bridgeScript,
      uiScript,
    );
    server.listen(instance._handle, onError: (Object _) {});
    return instance;
  }

  /// 绑定回环地址上的 [port]；0 交给系统分配。
  ///
  /// 固定端口失败一律转成 [LocalPortUnavailableException]：`SocketException`
  /// 的错误文本在不同平台上不一致，调用方没法可靠判断「端口被占」，
  /// 也不该为此去解析平台字符串。
  static Future<HttpServer> _bind(int port) async {
    if (port < 0 || port > 65535) {
      throw ArgumentError.value(port, 'port', '端口必须在 0..65535 之间');
    }
    try {
      return await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    } on SocketException catch (error) {
      // port==0 时没有「换端口」这个语义，保持原来直接抛 SocketException 的行为
      if (port == 0) rethrow;
      // osError 才是「Address already in use」这类人话；message 只有
      // 「Failed to create server socket」，排查时几乎没有信息量。
      throw LocalPortUnavailableException(
        port,
        error.osError?.message ?? error.message,
      );
    }
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
    final segments =
        request.uri.pathSegments.where((s) => s.isNotEmpty).toList();

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
        ..headers.contentType =
            ContentType('application', 'javascript', charset: 'utf-8')
        ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
        ..headers.contentLength = bytes.length;
      response.add(bytes);
      return response.close();
    }

    final relative = segments.isEmpty ? 'index.html' : segments.join('/');
    final file = await _resolveInside(relative);
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
    final range =
        _parseRange(request.headers.value(HttpHeaders.rangeHeader), length);
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

  /// 把相对路径解析到资源根目录内；越界返回 null。
  ///
  /// 两道检查缺一不可：
  ///   1. 词法检查（`..` / 绝对路径）—— 挡住 `../../etc/passwd`
  ///   2. **符号链接解析** —— `p.canonicalize` 只做字符串归一化，不解析链接。
  ///      资源目录里放一个指向 /etc/passwd 的软链，词法检查完全看不出问题，
  ///      结果本地服务器会把根目录外的任意文件喂给页面（已用测试复现过）。
  Future<File?> _resolveInside(String relative) async {
    final normalized = p.normalize(relative);
    if (normalized.startsWith('..') || p.isAbsolute(normalized)) return null;
    final full = p.join(_root.path, normalized);
    final rootPath = p.canonicalize(_root.path);
    final fullPath = p.canonicalize(full);
    if (fullPath != rootPath &&
        !fullPath.startsWith('$rootPath${p.separator}')) {
      return null;
    }
    final file = File(fullPath);
    try {
      // 解析真实路径：软链指到根目录外就当作越权。
      // 文件不存在会抛异常 —— 那种情况交给后面的 exists() 走 404。
      final resolved = await file.resolveSymbolicLinks();
      final resolvedRootText = await _canonicalRootPath();
      if (resolved != resolvedRootText &&
          !resolved.startsWith('$resolvedRootText${p.separator}')) {
        return null;
      }
    } on FileSystemException {
      // 不存在/不可解析：沿用词法结果，由 exists() 决定 404
    }
    return file;
  }

  /// 资源根的真实路径（解析软链后），只算一次。
  Future<String> _canonicalRootPath() async {
    final cached = _canonicalRoot;
    if (cached != null) return cached;
    try {
      final resolved = await _root.resolveSymbolicLinks();
      _canonicalRoot = resolved;
      return resolved;
    } catch (_) {
      final fallback = p.canonicalize(_root.path);
      _canonicalRoot = fallback;
      return fallback;
    }
  }

  Future<Uint8List> _htmlWithInjection(File file) async {
    final html = await file.readAsString();
    return _injectInto(html);
  }

  /// HTML 注入：把存档桥/面板脚本插到页面最前面或 `</head>` 之前。
  Future<Uint8List> _injectInto(String html) async {
    // 未登录（桥脚本为空）时不注入标签：否则页面会去请求 bridge.js 拿到 404，
    // 控制台一片红，还会掩盖真正的错误。
    if (_bridgeScript.isEmpty) {
      return Uint8List.fromList(utf8.encode(html));
    }
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
      patched =
          html.substring(0, headIndex) + snippet + html.substring(headIndex);
    } else {
      patched = snippet + html;
    }
    return Uint8List.fromList(utf8.encode(patched));
  }

  static ContentType _contentTypeFor(String path) {
    final ext = p.extension(path).toLowerCase();
    return switch (ext) {
      '.html' || '.htm' => ContentType('text', 'html', charset: 'utf-8'),
      '.js' ||
      '.mjs' =>
        ContentType('application', 'javascript', charset: 'utf-8'),
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
    if (header == null || !header.startsWith('bytes=') || length <= 0) {
      return null;
    }
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
      end =
          endText.isEmpty ? length - 1 : (int.tryParse(endText) ?? length - 1);
      if (end >= length) end = length - 1;
    }
    if (start > end || start >= length) return null;
    return (start, end);
  }
}
