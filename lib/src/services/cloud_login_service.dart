import 'dart:io';

import 'package:flutter/services.dart';

/// Credentials the embedded sign-in page handed back after authentik accepted
/// the user. The token is a secret: it is written to the app-private settings
/// file and never logged.
class CloudLoginCredentials {
  const CloudLoginCredentials({
    required this.token,
    required this.accountId,
    required this.baseUrl,
  });

  factory CloudLoginCredentials.fromChannel(Object? value) {
    if (value is! Map) {
      throw const CloudLoginFailure('login_failed', '登录返回的数据无效');
    }
    final token = value['token'];
    if (token is! String || token.trim().isEmpty) {
      throw const CloudLoginFailure('login_failed', '登录没有返回设备令牌');
    }
    final id = value['id'];
    final base = value['base'];
    return CloudLoginCredentials(
      token: token.trim(),
      accountId: id is String ? id.trim() : '',
      baseUrl: base is String ? base.trim() : '',
    );
  }

  final String token;

  /// Account identifier the page published; informational only.
  final String accountId;

  /// Origin the server says it issued the token for; may be empty.
  final String baseUrl;
}

/// A sign-in that did not produce a token.
class CloudLoginFailure implements Exception {
  const CloudLoginFailure(this.code, this.message);

  /// Error-catalog code, e.g. `login_invalid_base`.
  final String code;
  final String message;

  @override
  String toString() => 'CloudLoginFailure($code): $message';
}

/// Opens the save server's authentik-protected token page in a native WebView
/// and receives the token through `window.GardendlessBridge.onToken`.
///
/// Android host contract (`android/.../login/LoginActivity.kt` and
/// `MainActivity.kt`):
///
/// * channel `io.github.dey410.gardendlessloader/cloud_login`
/// * method `authentikLogin`, arguments
///   `{baseUrl: String, loginUrl: String, title: String, allowedHosts: List<String>}`
/// * result `null` when the user backed out, else
///   `{token: String, id: String, base: String}`
///
/// The native side only accepts a token while the page is still on the host it
/// opened, and only accepts a base URL on that same host. `allowedHosts` carries
/// the extra hosts the sign-in flow must be allowed to visit in-app — typically
/// the identity provider, which lives on its own host. Without it every hop is
/// handed to the system browser and the token bridge never fires.
class CloudLoginService {
  const CloudLoginService();

  static const channelName = 'io.github.dey410.gardendlessloader/cloud_login';
  static const methodAuthentikLogin = 'authentikLogin';
  static const MethodChannel _channel = MethodChannel(channelName);

  /// Maximum redirect hops followed while discovering the sign-in hosts.
  static const _maxDiscoveryHops = 6;
  static const _discoveryTimeout = Duration(seconds: 6);

  /// Returns null when the user closed the sign-in screen without signing in.
  Future<CloudLoginCredentials?> loginWithAuthentik({
    required String baseUrl,
    required String loginUrl,
    required String title,
  }) async {
    if (!Platform.isAndroid) {
      throw const CloudLoginFailure(
        'login_unsupported',
        '当前平台不支持应用内登录，请在设置中手动填写令牌',
      );
    }
    final allowedHosts = await discoverLoginHosts(baseUrl, loginUrl);
    try {
      final raw = await _channel.invokeMethod<Object?>(
        methodAuthentikLogin,
        <String, Object?>{
          'baseUrl': baseUrl,
          'loginUrl': loginUrl,
          'title': title,
          'allowedHosts': allowedHosts,
        },
      );
      if (raw == null) return null;
      return CloudLoginCredentials.fromChannel(raw);
    } on PlatformException catch (error) {
      if (error.code == 'login_cancelled') return null;
      throw CloudLoginFailure(error.code, error.message ?? error.code);
    } on MissingPluginException {
      throw const CloudLoginFailure(
        'login_unsupported',
        '当前安装包没有内置登录页面，请在设置中手动填写令牌',
      );
    }
  }

  /// Walks the sign-in redirect chain without following it in a browser and
  /// returns every host the flow touches (the save server plus its identity
  /// provider).
  ///
  /// Only `Location` headers are read; page bodies are discarded. Any failure
  /// degrades to "only the save server host", which keeps the login usable when
  /// the flow stays on one host and never leaks extra hosts to the native side.
  Future<List<String>> discoverLoginHosts(String baseUrl, String loginUrl) async {
    final hosts = <String>{};
    final baseHost = Uri.tryParse(baseUrl)?.host.toLowerCase();
    if (baseHost != null && baseHost.isNotEmpty) hosts.add(baseHost);

    var url = Uri.tryParse(loginUrl);
    if (url == null || !url.isScheme('http') && !url.isScheme('https')) {
      return hosts.toList();
    }

    final client = HttpClient()..connectionTimeout = _discoveryTimeout;
    try {
      for (var hop = 0; hop < _maxDiscoveryHops; hop++) {
        final host = url!.host.toLowerCase();
        if (host.isEmpty) break;
        hosts.add(host);
        final request = await client.getUrl(url);
        request.followRedirects = false;
        final response = await request.close().timeout(_discoveryTimeout);
        await response.drain<void>();
        if (response.statusCode < 300 || response.statusCode >= 400) break;
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location == null || location.trim().isEmpty) break;
        final next = url.resolve(location.trim());
        if (!next.isScheme('http') && !next.isScheme('https')) break;
        url = next;
      }
    } catch (_) {
      // 探测失败不影响登录：至少允许存档服务器自身的 host
    } finally {
      client.close(force: true);
    }
    return hosts.toList();
  }
}
