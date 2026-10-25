import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../constants.dart';
import '../models.dart';
import 'app_update_service.dart';
import 'remote_resource_service.dart';

/// 服务端 `win/manifest.json` 里的一条 Windows 构建。
///
/// 与 APK 清单分开的理由：Windows 包没有 aapt badging 可读，版本号只能
/// 由发布脚本写入；字段也更少（没有 package/minSdk）。
class WindowsRelease {
  const WindowsRelease({
    required this.version,
    required this.versionCode,
    required this.fileName,
    required this.size,
    required this.sha256,
    required this.notes,
    required this.url,
    this.publishedAt,
  });

  factory WindowsRelease.fromJson(Map<String, dynamic> json) {
    final version = json['version'];
    final fileName = json['file'];
    final url = json['url'];
    final sha = json['sha256'];
    final versionCode = (json['versionCode'] as num?)?.toInt();
    if (version is! String || version.trim().isEmpty) {
      throw const FormatException('windows release has no version');
    }
    if (versionCode == null || versionCode <= 0) {
      throw const FormatException('windows release has no versionCode');
    }
    if (fileName is! String ||
        fileName.trim().isEmpty ||
        p.basename(fileName.replaceAll('\\', '/')) != fileName) {
      // 只接受纯文件名：清单不能把下载写到目录外
      throw const FormatException('windows release file must be a bare name');
    }
    if (url is! String || !url.startsWith('/')) {
      throw const FormatException('windows release has no url path');
    }
    if (sha is! String || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(sha)) {
      throw const FormatException('windows release has no sha256 digest');
    }
    final created = (json['created'] as num?)?.toInt();
    return WindowsRelease(
      version: version.trim(),
      versionCode: versionCode,
      fileName: fileName.trim(),
      size: (json['size'] as num?)?.toInt() ?? 0,
      sha256: sha.toLowerCase(),
      notes: (json['notes'] as String? ?? '').trim(),
      url: url,
      publishedAt: created == null || created <= 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(created * 1000, isUtc: true),
    );
  }

  final String version;
  final int versionCode;
  final String fileName;
  final int size;
  final String sha256;
  final String notes;
  final String url;
  final DateTime? publishedAt;
}

class WindowsUpdateManifest {
  const WindowsUpdateManifest({
    required this.latest,
    required this.history,
    required this.hint,
  });

  factory WindowsUpdateManifest.fromJson(Map<String, dynamic> json) {
    final latest = json['latest'];
    if (latest != null && latest is! Map) {
      throw const FormatException('windows manifest latest is not an object');
    }
    final history = json['history'];
    return WindowsUpdateManifest(
      latest: latest is Map
          ? WindowsRelease.fromJson(Map<String, dynamic>.from(latest))
          : null,
      history: history is List
          ? history
              .whereType<Map>()
              .map((e) => WindowsRelease.fromJson(Map<String, dynamic>.from(e)))
              .toList(growable: false)
          : const <WindowsRelease>[],
      hint: (json['hint'] as String? ?? '').trim(),
    );
  }

  final WindowsRelease? latest;
  final List<WindowsRelease> history;
  final String hint;
}

/// Windows 更新：检查清单、下载 zip、校验 sha256。
///
/// 不自动替换安装目录：替换运行中的 CEF 应用需要外部进程，复制到一半失败
/// 会把安装弄坏。这里做到「下载 + 完整性校验 + 打开所在文件夹」，替换仍由
/// 用户执行（见 07-backlog B-08 的决策记录）。
class WindowsUpdateService {
  WindowsUpdateService(this._remote);

  final RemoteResourceService _remote;

  Future<WindowsUpdateManifest> fetchManifest({
    required String token,
    required String baseUrl,
    Duration timeout = saveServerRequestTimeout,
  }) async {
    final body = await _remote.fetchAuthorizedText(
      path: saveWindowsManifestPath,
      token: token,
      baseUrl: baseUrl,
      code: 'windows_update_manifest_unavailable',
      maxBytes: saveWindowsManifestMaxBytes,
      timeout: timeout,
    );
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException catch (error) {
      throw RemoteResourceFailure(
          'windows_update_manifest_invalid', error.message);
    }
    if (decoded is! Map<String, dynamic>) {
      throw const RemoteResourceFailure(
        'windows_update_manifest_invalid',
        'Windows manifest is not a JSON object',
      );
    }
    try {
      return WindowsUpdateManifest.fromJson(decoded);
    } on FormatException catch (error) {
      throw RemoteResourceFailure(
          'windows_update_manifest_invalid', error.message);
    }
  }

  /// 是否有比当前版本更新的构建。versionCode 优先，缺失时退回版本名比较。
  bool isUpgrade({
    required WindowsRelease release,
    required int? installedVersionCode,
    required String installedVersionName,
  }) {
    return isWindowsUpgrade(
      release: release,
      installedVersionCode: installedVersionCode,
      installedVersionName: installedVersionName,
    );
  }

  File targetFile(Directory downloadsDir, WindowsRelease release) {
    final name = safeWindowsFileName(release);
    return File(p.join(downloadsDir.path, name));
  }

  Future<File> download({
    required WindowsRelease release,
    required String token,
    required String baseUrl,
    required File targetFile,
    RemoteDownloadCancellation? cancellation,
    void Function(RemoteDownloadProgress progress)? onProgress,
  }) {
    return _remote.downloadFile(
      uri: _remote.resolveServerUri(baseUrl, release.url),
      token: token,
      targetFile: targetFile,
      expectedSize: release.size,
      expectedSha256: release.sha256,
      failureCode: 'windows_update_download_failed',
      sizeMismatchCode: 'windows_update_size_mismatch',
      checksumMismatchCode: 'windows_update_checksum_mismatch',
      detailLabel: 'Windows zip',
      cancellation: cancellation,
      onProgress: onProgress,
    );
  }

  /// 删除同目录里更早下载的 Windows zip，避免每次更新留一份 ~190 MB。
  Future<void> removeStaleZips(File keep) async {
    try {
      await for (final entity in keep.parent.list()) {
        if (entity is! File) continue;
        final name = p.basename(entity.path).toLowerCase();
        if (!name.endsWith('.zip') || !name.contains('windows-x64')) continue;
        if (entity.path == keep.path) continue;
        try {
          await entity.delete();
        } catch (_) {}
      }
    } catch (_) {
      // 清理失败只占空间，不影响已校验的更新包
    }
  }

  Future<bool> verifyFile(File file, WindowsRelease release) async {
    try {
      if (!await file.exists()) return false;
      if (release.size > 0 && await file.length() != release.size) return false;
      final digest = await sha256.bind(file.openRead()).first;
      return digest.toString() == release.sha256;
    } catch (_) {
      return false;
    }
  }
}

/// 桌面端更新状态。与 Android 的 [AppUpdateStatus] 分开：
/// 两者共享阶段枚举，但 release 类型不同，混用会让 UI 拿到错的对象。
class WindowsUpdateStatus {
  const WindowsUpdateStatus({
    required this.phase,
    this.release,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.errorCode,
    this.message,
  });

  final AppUpdatePhase phase;
  final WindowsRelease? release;
  final int receivedBytes;
  final int totalBytes;
  final String? errorCode;
  final String? message;

  bool get active =>
      phase == AppUpdatePhase.checking ||
      phase == AppUpdatePhase.downloading ||
      phase == AppUpdatePhase.verifying;
}

bool isWindowsUpgrade({
  required WindowsRelease release,
  required int? installedVersionCode,
  required String installedVersionName,
}) {
  if (installedVersionCode != null) {
    return release.versionCode > installedVersionCode;
  }
  return compareVersionNames(release.version, installedVersionName) > 0;
}

/// 清单里的文件名只取最后一段，且强制 `.zip` 后缀。
String safeWindowsFileName(WindowsRelease release) {
  final name = p.basename(release.fileName.replaceAll('\\', '/'));
  if (name.isEmpty || name == '.' || name == '..') {
    return 'gardendless-loader-${_sanitize(release.version)}-windows-x64.zip';
  }
  return name.toLowerCase().endsWith('.zip') ? name : '$name.zip';
}

String _sanitize(String value) {
  final cleaned = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '-');
  return cleaned.isEmpty ? 'unknown' : cleaned;
}
