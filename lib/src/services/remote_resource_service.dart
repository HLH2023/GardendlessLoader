import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../constants.dart';
import 'cloud_save_service.dart';

/// A resource ZIP published by the save server's manifest.
class RemoteResourceZip {
  const RemoteResourceZip({
    required this.name,
    required this.version,
    required this.size,
    required this.sha256,
    required this.urlApp,
    required this.createdAt,
    this.latest = false,
  });

  factory RemoteResourceZip.fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    final urlApp = json['url_app'];
    final sha = json['sha256'];
    if (name is! String || name.isEmpty) {
      throw const FormatException('resource zip has no name');
    }
    if (urlApp is! String || urlApp.isEmpty) {
      throw const FormatException('resource zip has no url_app');
    }
    if (sha is! String || sha.length != 64) {
      throw const FormatException('resource zip has no sha256 digest');
    }
    return RemoteResourceZip(
      name: name,
      version: json['version'] as String? ?? '',
      size: (json['size'] as num?)?.toInt() ?? 0,
      sha256: sha.toLowerCase(),
      urlApp: urlApp,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        ((json['created'] as num?)?.toInt() ?? 0) * 1000,
        isUtc: true,
      ),
      latest: json['latest'] as bool? ?? false,
    );
  }

  final String name;
  final String version;
  final int size;

  /// Lowercase hex SHA-256 of the ZIP, checked after the download finishes.
  final String sha256;

  /// Path of the ZIP under the server base URL.
  final String urlApp;
  final DateTime createdAt;
  final bool latest;
}

/// `GET {base}/_save/app/res/manifest.json` as the launcher needs it.
class RemoteResourceManifest {
  const RemoteResourceManifest({
    required this.schema,
    required this.gameVersion,
    required this.imageDigest,
    required this.zips,
  });

  factory RemoteResourceManifest.fromJson(Map<String, dynamic> json) {
    final zips = json['zips'];
    if (zips is! List) {
      throw const FormatException('resource manifest has no zips list');
    }
    final game = json['game'];
    return RemoteResourceManifest(
      schema: (json['schema'] as num?)?.toInt() ?? 0,
      gameVersion: game is Map ? game['version'] as String? : null,
      imageDigest: game is Map ? game['image_digest'] as String? : null,
      zips: zips
          .whereType<Map<String, dynamic>>()
          .map(RemoteResourceZip.fromJson)
          .toList(growable: false),
    );
  }

  final int schema;
  final String? gameVersion;
  final String? imageDigest;
  final List<RemoteResourceZip> zips;

  /// The ZIP flagged `latest`, else the last published one.
  RemoteResourceZip? get latestZip {
    if (zips.isEmpty) {
      return null;
    }
    for (final zip in zips) {
      if (zip.latest) return zip;
    }
    return zips.last;
  }
}

/// `GET {base}/_save/app/whoami`: the identity a device token belongs to.
class CloudIdentity {
  const CloudIdentity({required this.user});

  factory CloudIdentity.fromJson(Map<String, dynamic> json) {
    final user = json['user'];
    if (user is! String || user.trim().isEmpty) {
      throw const FormatException('whoami has no user');
    }
    return CloudIdentity(user: user.trim());
  }

  /// Account name the server reports; shown in Settings after a sign-in.
  final String user;
}

/// Bytes of one download attempt, for the progress bar.
class RemoteDownloadProgress {
  const RemoteDownloadProgress({
    required this.receivedBytes,
    required this.totalBytes,
    this.resumedBytes = 0,
  });

  final int receivedBytes;
  final int totalBytes;

  /// Bytes that were already on disk when this attempt resumed a ZIP.
  final int resumedBytes;

  double? get value =>
      totalBytes > 0 ? (receivedBytes / totalBytes).clamp(0.0, 1.0) : null;
}

/// Cancels the download that was started with it: the next chunk check
/// throws [RemoteResourceCancelled] and the partial file stays for a resume.
class RemoteDownloadCancellation {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;

  void throwIfCancelled() {
    if (_cancelled) {
      throw const RemoteResourceCancelled();
    }
  }
}

/// A save-server request failed; [code] is the log/error-catalog code.
class RemoteResourceFailure implements Exception {
  const RemoteResourceFailure(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

class RemoteResourceCancelled implements Exception {
  const RemoteResourceCancelled();

  @override
  String toString() => 'remote download cancelled';
}

/// Talks to the save server: the resource manifest, the document-start
/// injection script, and resumable ZIP downloads.
///
/// Every request carries the user's device token as a bearer credential;
/// nothing here retries or hides a failure — the caller decides what a
/// failed request means.
class RemoteResourceService {
  HttpClient? _activeClient;

  /// Breaks a download that is blocked on a socket read.
  void abortActiveRequests() {
    _activeClient?.close(force: true);
    _activeClient = null;
  }

  Future<RemoteResourceManifest> fetchManifest({
    required String token,
    required String baseUrl,
    Duration timeout = saveServerRequestTimeout,
  }) async {
    final body = await _getText(
      _resolve(baseUrl, '/_save/app/res/manifest.json'),
      token: token,
      timeout: timeout,
      maxBytes: saveServerManifestMaxBytes,
      code: 'resource_manifest_unavailable',
    );
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException catch (error) {
      throw RemoteResourceFailure('resource_manifest_invalid', error.message);
    }
    if (decoded is! Map<String, dynamic>) {
      throw const RemoteResourceFailure(
        'resource_manifest_invalid',
        'Manifest is not a JSON object',
      );
    }
    try {
      return RemoteResourceManifest.fromJson(decoded);
    } on FormatException catch (error) {
      throw RemoteResourceFailure('resource_manifest_invalid', error.message);
    }
  }

  /// Verifies a device token and returns the identity it belongs to.
  ///
  /// `GET {base}/_save/app/whoami` answers `{"user": "..."}` for a live token
  /// and 401/403 once it has been revoked, which is what the sign-in screen
  /// shows the user before saving anything.
  Future<CloudIdentity> fetchWhoami({
    required String token,
    required String baseUrl,
    Duration timeout = saveServerRequestTimeout,
  }) async {
    final body = await _getText(
      _resolve(baseUrl, saveWhoamiPath),
      token: token,
      timeout: timeout,
      maxBytes: saveServerManifestMaxBytes,
      code: 'save_login_unverified',
    );
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException catch (error) {
      throw RemoteResourceFailure('save_login_unverified', error.message);
    }
    if (decoded is! Map<String, dynamic>) {
      throw const RemoteResourceFailure(
        'save_login_unverified',
        '身份校验响应不是 JSON 对象',
      );
    }
    try {
      return CloudIdentity.fromJson(decoded);
    } on FormatException catch (error) {
      throw RemoteResourceFailure('save_login_unverified', error.message);
    }
  }

  /// The shim the native host injects at document-start; it rewrites the
  /// browser save-sync calls onto `{base}/_save/app` with our token.
  Future<String> fetchAppSyncScript({
    required String token,
    required String baseUrl,
    Duration timeout = saveServerRequestTimeout,
  }) {
    return _getText(
      _resolve(baseUrl, '/_save/app-sync.js'),
      token: token,
      timeout: timeout,
      maxBytes: saveServerScriptMaxBytes,
      code: 'save_bridge_unavailable',
      accept: 'text/javascript, */*',
    );
  }

  /// 云端存档的当前状态（键、大小、写入时间、可摘要键的统计）。
  ///
  /// `/load` 是任何有效令牌都能读的接口（`/list` 只有管理员能读），所以
  /// 存档页用它来展示「我自己的云存档」，非管理员也不会 403。
  Future<CloudSaveSnapshot> fetchCloudSaves({
    required String token,
    required String baseUrl,
    Duration timeout = saveServerRequestTimeout,
  }) async {
    final body = await _getText(
      _resolve(baseUrl, saveLoadPath),
      token: token,
      timeout: timeout,
      maxBytes: saveServerSavesMaxBytes,
      code: 'cloud_saves_unavailable',
    );
    return _parseJson<CloudSaveSnapshot>(
      body,
      code: 'cloud_saves_invalid',
      parse: (json) => CloudSaveSnapshot.fromJson(json),
    );
  }

  /// 某个存档键的历史版本（服务端要求管理员组）。
  Future<List<CloudSaveVersion>> fetchSaveHistory({
    required String token,
    required String baseUrl,
    required String user,
    required String key,
    int limit = saveServerHistoryLimit,
    Duration timeout = saveServerRequestTimeout,
  }) async {
    final uri = _resolve(baseUrl, saveHistoryPath).replace(
      queryParameters: <String, String>{
        'user': user,
        'key': key,
        'limit': '$limit',
      },
    );
    final body = await _getText(
      uri,
      token: token,
      timeout: timeout,
      maxBytes: saveServerSavesMaxBytes,
      code: 'save_history_unavailable',
    );
    return _parseJson<List<CloudSaveVersion>>(
      body,
      code: 'save_history_invalid',
      parse: (json) {
        final raw = json['versions'];
        if (raw is! List) {
          throw const FormatException('history has no versions array');
        }
        return raw
            .whereType<Map>()
            .map((item) => CloudSaveVersion.fromJson(
                  item.map((key, value) => MapEntry(key.toString(), value)),
                ))
            .toList(growable: false);
      },
    );
  }

  /// 把云端某个存档键回滚到指定历史版本；服务端会先给当前版本留快照。
  Future<void> restoreSaveVersion({
    required String token,
    required String baseUrl,
    required String user,
    required String key,
    required int ts,
    String name = '',
    Duration timeout = saveServerRequestTimeout,
  }) async {
    final body = <String, Object?>{'user': user, 'key': key, 'ts': ts};
    if (name.isNotEmpty) {
      // 精确到具体历史文件：同一秒内可能有多个版本
      body['name'] = name;
    }
    await _postJson(
      _resolve(baseUrl, saveRestorePath),
      token: token,
      timeout: timeout,
      maxBytes: saveServerSavesMaxBytes,
      code: 'save_restore_failed',
      body: body,
    );
  }

  /// The in-game save panel (floating button) served over the same Bearer
  /// channel as the sync bridge; it opens the must-authenticated save manager
  /// page inside the game view.
  Future<String> fetchAppUiScript({
    required String token,
    required String baseUrl,
    Duration timeout = saveServerRequestTimeout,
  }) {
    return _getText(
      _resolve(baseUrl, '/_save/app-ui.js'),
      token: token,
      timeout: timeout,
      maxBytes: saveServerScriptMaxBytes,
      code: 'save_panel_unavailable',
      accept: 'text/javascript, */*',
    );
  }

  /// `GET {base}{path}` with the device token attached, as text.
  ///
  /// A caller that publishes its own document format (the APK manifest) uses
  /// this instead of duplicating authentication, timeout, size cap and
  /// address redaction.
  Future<String> fetchAuthorizedText({
    required String path,
    required String token,
    required String baseUrl,
    required String code,
    int maxBytes = saveServerManifestMaxBytes,
    Duration timeout = saveServerRequestTimeout,
    String accept = 'application/json, */*',
  }) {
    return _getText(
      _resolve(baseUrl, path),
      token: token,
      timeout: timeout,
      maxBytes: maxBytes,
      code: code,
      accept: accept,
    );
  }

  /// Joins a server-published relative path onto [baseUrl], keeping any path
  /// prefix the server is mounted under. A caller that hands the result to
  /// [downloadFile] resolves it the same way every other request is resolved.
  Uri resolveServerUri(String baseUrl, String path) => _resolve(baseUrl, path);

  /// Downloads the manifest's latest ZIP into [targetFile], resuming from the
  /// bytes already on disk when the server honours `Range`.
  ///
  /// The file is deleted when its size or SHA-256 does not match the
  /// manifest, so a resumed download can never be mistaken for a good one.
  Future<File> downloadZip({
    required RemoteResourceManifest manifest,
    required String token,
    required String baseUrl,
    required File targetFile,
    RemoteDownloadCancellation? cancellation,
    void Function(RemoteDownloadProgress progress)? onProgress,
  }) async {
    final zip = manifest.latestZip;
    if (zip == null) {
      throw const RemoteResourceFailure(
        'resource_manifest_empty',
        '服务器没有可用资源包',
      );
    }
    return downloadFile(
      uri: _resolve(baseUrl, zip.urlApp),
      token: token,
      targetFile: targetFile,
      expectedSize: zip.size,
      expectedSha256: zip.sha256,
      cancellation: cancellation,
      onProgress: onProgress,
    );
  }

  /// Downloads any file the save server publishes, resuming from the bytes
  /// already on [targetFile] when the server honours `Range`.
  ///
  /// This is the one resumable-transfer implementation: the resource ZIP and
  /// the in-app APK update both go through it. The bytes on disk are appended
  /// to only after the server confirms the range, and the finished file must
  /// match [expectedSize] and [expectedSha256]; either mismatch deletes it, so
  /// a resumed transfer can never be mistaken for a good one. [detailLabel]
  /// only names the file in those two error details.
  Future<File> downloadFile({
    required Uri uri,
    required String token,
    required File targetFile,
    required int expectedSize,
    required String expectedSha256,
    String failureCode = 'resource_download_failed',
    String sizeMismatchCode = 'resource_size_mismatch',
    String checksumMismatchCode = 'resource_checksum_mismatch',
    String detailLabel = '资源',
    RemoteDownloadCancellation? cancellation,
    void Function(RemoteDownloadProgress progress)? onProgress,
  }) async {
    final etagFile = File('${targetFile.path}.etag');
    await targetFile.parent.create(recursive: true);

    var attempt = 0;
    while (true) {
      final resumeFrom = attempt == 0 ? await _fileLength(targetFile) : 0;
      try {
        await _downloadAttempt(
          uri: uri,
          token: token,
          targetFile: targetFile,
          etagFile: etagFile,
          resumeFrom: resumeFrom,
          expectedSize: expectedSize,
          failureCode: failureCode,
          cancellation: cancellation,
          onProgress: onProgress,
        );
        break;
      } on _RangeRejected {
        // The server no longer has the bytes we hold: start over once.
        await _deleteQuietly(targetFile);
        await _deleteQuietly(etagFile);
        if (attempt >= 1) {
          throw RemoteResourceFailure(
            failureCode,
            '服务器拒绝断点续传，重新下载仍失败',
          );
        }
        attempt++;
      }
    }

    final length = await targetFile.length();
    if (expectedSize > 0 && length != expectedSize) {
      await _deleteQuietly(targetFile);
      await _deleteQuietly(etagFile);
      throw RemoteResourceFailure(
        sizeMismatchCode,
        '$detailLabel大小不符：$length / $expectedSize',
      );
    }

    final digest = await sha256.bind(targetFile.openRead()).first;
    if (digest.toString() != expectedSha256.toLowerCase()) {
      await _deleteQuietly(targetFile);
      await _deleteQuietly(etagFile);
      throw RemoteResourceFailure(
        checksumMismatchCode,
        '$detailLabel校验失败（SHA-256 不一致）',
      );
    }
    await _deleteQuietly(etagFile);
    return targetFile;
  }

  /// Removes a partial or rejected download and the ETag beside it, so the
  /// next attempt starts from byte zero.
  Future<void> discardDownload(File targetFile) async {
    await _deleteQuietly(targetFile);
    await _deleteQuietly(File('${targetFile.path}.etag'));
  }

  Future<void> _downloadAttempt({
    required Uri uri,
    required String token,
    required File targetFile,
    required File etagFile,
    required int resumeFrom,
    required int expectedSize,
    required String failureCode,
    RemoteDownloadCancellation? cancellation,
    void Function(RemoteDownloadProgress progress)? onProgress,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = saveServerDownloadConnectTimeout;
    _activeClient = client;
    IOSink? sink;
    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.headers.set(HttpHeaders.userAgentHeader, appDisplayName);
      request.headers.set(HttpHeaders.acceptHeader, '*/*');
      if (resumeFrom > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$resumeFrom-');
        final etag = await _readEtag(etagFile);
        if (etag != null) {
          request.headers.set('If-Range', etag);
        }
      }
      final response = await request.close();
      cancellation?.throwIfCancelled();

      final status = response.statusCode;
      final bool append;
      final int total;
      if (status == HttpStatus.partialContent && resumeFrom > 0) {
        final range = _parseContentRange(
          response.headers.value(HttpHeaders.contentRangeHeader),
        );
        if (range == null || range.start != resumeFrom) {
          await response.drain<void>();
          throw const _RangeRejected();
        }
        append = true;
        total =
            range.total > 0 ? range.total : resumeFrom + response.contentLength;
      } else if (status == HttpStatus.ok) {
        append = false;
        total =
            response.contentLength > 0 ? response.contentLength : expectedSize;
      } else if (status == HttpStatus.requestedRangeNotSatisfiable) {
        await response.drain<void>();
        throw const _RangeRejected();
      } else {
        await response.drain<void>();
        throw _statusFailure(status, failureCode);
      }

      final etag = response.headers.value(HttpHeaders.etagHeader);
      // Stored before the body: an interrupted transfer still knows which
      // version its bytes belong to, so If-Range can validate the resume.
      if (etag != null && etag.isNotEmpty) {
        await etagFile.writeAsString(etag, flush: true);
      }
      var received = append ? resumeFrom : 0;
      sink = targetFile.openWrite(
        mode: append ? FileMode.append : FileMode.write,
      );
      onProgress?.call(
        RemoteDownloadProgress(
          receivedBytes: received,
          totalBytes: total,
          resumedBytes: append ? resumeFrom : 0,
        ),
      );
      await for (final chunk in response) {
        if (cancellation?.isCancelled ?? false) {
          throw const RemoteResourceCancelled();
        }
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(
          RemoteDownloadProgress(receivedBytes: received, totalBytes: total),
        );
      }
      await sink.flush();
      await sink.close();
      sink = null;
    } on SocketException catch (error) {
      if (cancellation?.isCancelled ?? false) {
        throw const RemoteResourceCancelled();
      }
      throw RemoteResourceFailure(
        failureCode,
        _redact(error.message, uri),
      );
    } on HttpException catch (error) {
      if (cancellation?.isCancelled ?? false) {
        throw const RemoteResourceCancelled();
      }
      throw RemoteResourceFailure(
        failureCode,
        _redact(error.message, uri),
      );
    } finally {
      try {
        await sink?.flush();
        await sink?.close();
      } catch (_) {
        // A cancelled download may already have lost its handle.
      }
      if (identical(_activeClient, client)) {
        _activeClient = null;
      }
      client.close(force: true);
    }
  }

  Future<String> _getText(
    Uri uri, {
    required String token,
    required Duration timeout,
    required int maxBytes,
    required String code,
    String accept = 'application/json, */*',
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    _activeClient = client;
    try {
      return await (() async {
        final request = await client.getUrl(uri);
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        request.headers.set(HttpHeaders.userAgentHeader, appDisplayName);
        request.headers.set(HttpHeaders.acceptHeader, accept);
        final response = await request.close();
        if (response.statusCode != HttpStatus.ok) {
          await response.drain<void>();
          throw _statusFailure(response.statusCode, code);
        }
        if (response.contentLength > maxBytes) {
          await response.drain<void>();
          throw RemoteResourceFailure(code, '服务器响应过大');
        }
        final bytes = await response.fold<List<int>>(<int>[], (buffer, chunk) {
          if (buffer.length + chunk.length > maxBytes) {
            throw RemoteResourceFailure(code, '服务器响应过大');
          }
          buffer.addAll(chunk);
          return buffer;
        });
        return utf8.decode(bytes, allowMalformed: true);
      })()
          .timeout(timeout);
    } on RemoteResourceFailure {
      rethrow;
    } on TimeoutException {
      throw RemoteResourceFailure(code, '请求超时');
    } on SocketException catch (error) {
      throw RemoteResourceFailure(code, _redact(error.message, uri));
    } on HttpException catch (error) {
      throw RemoteResourceFailure(code, _redact(error.message, uri));
    } on FormatException catch (error) {
      throw RemoteResourceFailure(code, error.message);
    } finally {
      if (identical(_activeClient, client)) {
        _activeClient = null;
      }
      client.close(force: true);
    }
  }

  Future<String> _postJson(
    Uri uri, {
    required String token,
    required Duration timeout,
    required int maxBytes,
    required String code,
    required Map<String, Object?> body,
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    _activeClient = client;
    try {
      return await (() async {
        final request = await client.postUrl(uri);
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        request.headers.set(HttpHeaders.userAgentHeader, appDisplayName);
        request.headers.contentType = ContentType.json;
        final payload = utf8.encode(jsonEncode(body));
        request.contentLength = payload.length;
        request.add(payload);
        final response = await request.close();
        final text = await response
            .transform(utf8.decoder)
            .join()
            .timeout(timeout);
        if (response.statusCode != HttpStatus.ok) {
          throw _statusFailure(response.statusCode, code);
        }
        if (text.length > maxBytes) {
          throw RemoteResourceFailure(code, '服务器响应过大');
        }
        return text;
      })()
          .timeout(timeout);
    } on RemoteResourceFailure {
      rethrow;
    } on TimeoutException {
      throw RemoteResourceFailure(code, '请求超时');
    } on SocketException catch (error) {
      throw RemoteResourceFailure(code, _redact(error.message, uri));
    } on HttpException catch (error) {
      throw RemoteResourceFailure(code, _redact(error.message, uri));
    } finally {
      if (identical(_activeClient, client)) {
        _activeClient = null;
      }
      client.close(force: true);
    }
  }

  T _parseJson<T>(
    String body, {
    required String code,
    required T Function(Map<String, Object?> json) parse,
  }) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException catch (error) {
      throw RemoteResourceFailure(code, error.message);
    }
    if (decoded is! Map) {
      throw RemoteResourceFailure(code, '响应不是 JSON 对象');
    }
    final json = decoded.map(
      (key, value) => MapEntry(key.toString(), value),
    );
    try {
      return parse(json);
    } on FormatException catch (error) {
      throw RemoteResourceFailure(code, error.message);
    }
  }

  RemoteResourceFailure _statusFailure(int statusCode, String code) {
    if (statusCode == HttpStatus.unauthorized ||
        statusCode == HttpStatus.forbidden) {
      return const RemoteResourceFailure(
        'save_token_rejected',
        '服务器拒绝了设备令牌（HTTP 401/403）',
      );
    }
    if (statusCode == HttpStatus.notFound) {
      return RemoteResourceFailure(code, '服务器没有这个资源（HTTP 404）');
    }
    return RemoteResourceFailure(code, 'HTTP $statusCode');
  }

  /// Joins [path] onto [baseUrl], keeping any path prefix the server is
  /// mounted under.
  Uri _resolve(String baseUrl, String path) {
    final base = Uri.tryParse(baseUrl.trim());
    if (base == null || base.host.isEmpty) {
      throw const RemoteResourceFailure('save_server_invalid', '服务器地址无效');
    }
    if (base.scheme != 'https' && base.scheme != 'http') {
      throw const RemoteResourceFailure('save_server_invalid', '服务器地址无效');
    }
    final prefix = base.path.replaceFirst(RegExp(r'/+$'), '');
    return base.replace(path: '$prefix$path', query: '', fragment: '');
  }

  /// Connection errors quote the host they could not reach; the launcher
  /// must never write the save server's address into a log or a message.
  String _redact(String message, Uri uri) {
    var redacted = message;
    if (uri.authority.isNotEmpty) {
      redacted = redacted.replaceAll(uri.authority, '***');
    }
    if (uri.host.isNotEmpty) {
      redacted = redacted.replaceAll(uri.host, '***');
    }
    return redacted;
  }

  Future<int> _fileLength(File file) async {
    try {
      return await file.exists() ? await file.length() : 0;
    } catch (_) {
      return 0;
    }
  }

  Future<String?> _readEtag(File etagFile) async {
    try {
      if (!await etagFile.exists()) return null;
      final value = (await etagFile.readAsString()).trim();
      return value.isEmpty ? null : value;
    } catch (_) {
      return null;
    }
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // A file that cannot be removed is reported by the next verification.
    }
  }

  ({int start, int end, int total})? _parseContentRange(String? header) {
    if (header == null) return null;
    final match = RegExp(r'bytes\s+(\d+)-(\d+)/(\d+|\*)').firstMatch(header);
    if (match == null) return null;
    return (
      start: int.tryParse(match.group(1) ?? '') ?? -1,
      end: int.tryParse(match.group(2) ?? '') ?? -1,
      total: int.tryParse(match.group(3) ?? '') ?? 0,
    );
  }
}

/// The server answered a resumed request with a range we cannot append to.
class _RangeRejected implements Exception {
  const _RangeRejected();
}
