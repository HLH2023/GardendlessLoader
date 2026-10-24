import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../constants.dart';
import 'remote_resource_service.dart';

/// One APK the save server publishes under `_save/app/res/apk/`.
///
/// The manifest's `latest` entry is an [AppRelease]; the same shape appears in
/// `history`. Only [urlApp] is downloaded: the server also publishes
/// `url_web`, which a browser would use, and the app must not guess it.
class AppRelease {
  const AppRelease({
    required this.version,
    required this.versionCode,
    required this.fileName,
    required this.size,
    required this.sha256,
    required this.packageName,
    required this.minSdk,
    required this.notes,
    required this.urlApp,
    this.publishedAt,
  });

  factory AppRelease.fromJson(Map<String, dynamic> json) {
    final version = json['version'];
    final fileName = json['file'];
    final urlApp = json['url_app'];
    final packageName = json['package'];
    final sha = json['sha256'];
    final versionCode = (json['versionCode'] as num?)?.toInt();
    if (version is! String || version.trim().isEmpty) {
      throw const FormatException('apk release has no version');
    }
    if (versionCode == null || versionCode <= 0) {
      throw const FormatException('apk release has no versionCode');
    }
    if (fileName is! String || fileName.trim().isEmpty) {
      throw const FormatException('apk release has no file');
    }
    if (urlApp is! String || !urlApp.startsWith('/')) {
      throw const FormatException('apk release has no url_app path');
    }
    if (packageName is! String || packageName.trim().isEmpty) {
      throw const FormatException('apk release has no package');
    }
    if (sha is! String || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(sha)) {
      throw const FormatException('apk release has no sha256 digest');
    }
    final created = (json['created'] as num?)?.toInt();
    return AppRelease(
      version: version.trim(),
      versionCode: versionCode,
      fileName: fileName.trim(),
      size: (json['size'] as num?)?.toInt() ?? 0,
      sha256: sha.toLowerCase(),
      packageName: packageName.trim(),
      minSdk: (json['minSdk'] as num?)?.toInt() ?? 0,
      notes: (json['notes'] as String? ?? '').trim(),
      urlApp: urlApp,
      publishedAt: created == null || created <= 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(created * 1000, isUtc: true),
    );
  }

  /// `versionName`, e.g. `0.9.0-hlh.2`.
  final String version;

  /// Android `versionCode`; the number Android itself uses to decide whether an
  /// APK is an upgrade.
  final int versionCode;

  /// Manifest filename; only its last path segment is ever used on disk.
  final String fileName;
  final int size;

  /// Lowercase hex SHA-256 of the APK, checked after the download finishes and
  /// again before the installer is opened.
  final String sha256;

  /// The `applicationId` the APK was built with.
  final String packageName;

  /// Minimum Android API the APK supports; informational, the installer
  /// enforces it.
  final int minSdk;

  /// Release notes the Settings page shows before downloading.
  final String notes;

  /// Path of the APK under the server base URL.
  final String urlApp;
  final DateTime? publishedAt;
}

/// `GET {base}/_save/app/res/apk/manifest.json` as the launcher needs it.
class AppUpdateManifest {
  const AppUpdateManifest({
    required this.schema,
    required this.latest,
    required this.history,
    required this.hint,
  });

  factory AppUpdateManifest.fromJson(Map<String, dynamic> json) {
    final latest = json['latest'];
    if (latest != null && latest is! Map) {
      throw const FormatException('apk manifest latest is not an object');
    }
    final history = json['history'];
    return AppUpdateManifest(
      schema: (json['schema'] as num?)?.toInt() ?? 0,
      latest: latest is Map
          ? AppRelease.fromJson(Map<String, dynamic>.from(latest))
          : null,
      history: history is List
          ? history
              .whereType<Map>()
              .map(
                (entry) =>
                    AppRelease.fromJson(Map<String, dynamic>.from(entry)),
              )
              .toList(growable: false)
          : const <AppRelease>[],
      hint: (json['hint'] as String? ?? '').trim(),
    );
  }

  final int schema;

  /// The release the server currently serves; null before the first upload.
  final AppRelease? latest;
  final List<AppRelease> history;

  /// Wording the server wants shown under the release, e.g. why an update
  /// cannot be installed from inside the app.
  final String hint;
}

/// What a check found: the server's release plus whether it is an upgrade for
/// the installed build.
class AppUpdateCheck {
  const AppUpdateCheck({
    required this.manifest,
    required this.release,
    required this.isUpgrade,
  });

  final AppUpdateManifest manifest;
  final AppRelease release;
  final bool isUpgrade;
}

/// Reads the APK manifest, decides whether it is newer than the installed
/// build, and downloads it through the shared resumable transfer in
/// [RemoteResourceService].
class AppUpdateService {
  AppUpdateService(this._remote);

  final RemoteResourceService _remote;

  Future<AppUpdateManifest> fetchManifest({
    required String token,
    required String baseUrl,
    Duration timeout = saveServerRequestTimeout,
  }) async {
    final body = await _remote.fetchAuthorizedText(
      path: saveApkManifestPath,
      token: token,
      baseUrl: baseUrl,
      code: 'app_update_manifest_unavailable',
      maxBytes: saveApkManifestMaxBytes,
      timeout: timeout,
    );
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException catch (error) {
      throw RemoteResourceFailure('app_update_manifest_invalid', error.message);
    }
    if (decoded is! Map<String, dynamic>) {
      throw const RemoteResourceFailure(
        'app_update_manifest_invalid',
        'APK manifest is not a JSON object',
      );
    }
    try {
      return AppUpdateManifest.fromJson(decoded);
    } on FormatException catch (error) {
      throw RemoteResourceFailure('app_update_manifest_invalid', error.message);
    }
  }

  /// Fetches the manifest and compares its release with the installed build.
  Future<AppUpdateCheck> check({
    required String token,
    required String baseUrl,
    required int? installedVersionCode,
    required String installedVersionName,
  }) async {
    final manifest = await fetchManifest(token: token, baseUrl: baseUrl);
    final release = manifest.latest;
    if (release == null) {
      throw const RemoteResourceFailure(
        'app_update_manifest_empty',
        'APK manifest has no latest release',
      );
    }
    return AppUpdateCheck(
      manifest: manifest,
      release: release,
      isUpgrade: isUpgrade(
        release: release,
        installedVersionCode: installedVersionCode,
        installedVersionName: installedVersionName,
      ),
    );
  }

  /// Where [release] is stored: the manifest filename reduced to its last path
  /// segment, so a hostile manifest cannot point outside the downloads folder.
  File targetFile(Directory downloadsDir, AppRelease release) {
    return File(p.join(downloadsDir.path, safeApkFileName(release)));
  }

  /// Bytes of a previous, interrupted attempt, capped at the announced size so
  /// a truncated or over-long file never inflates the progress display.
  Future<int> partialBytes(File targetFile, AppRelease release) async {
    try {
      if (!await targetFile.exists()) return 0;
      final length = await targetFile.length();
      return release.size > 0 && length > release.size ? release.size : length;
    } catch (_) {
      return 0;
    }
  }

  /// Downloads [release] into [targetFile], resuming the bytes already there.
  Future<File> downloadRelease({
    required AppRelease release,
    required String token,
    required String baseUrl,
    required File targetFile,
    RemoteDownloadCancellation? cancellation,
    void Function(RemoteDownloadProgress progress)? onProgress,
  }) {
    return _remote.downloadFile(
      uri: _remote.resolveServerUri(baseUrl, release.urlApp),
      token: token,
      targetFile: targetFile,
      expectedSize: release.size,
      expectedSha256: release.sha256,
      failureCode: 'app_update_download_failed',
      sizeMismatchCode: 'app_update_size_mismatch',
      checksumMismatchCode: 'app_update_checksum_mismatch',
      detailLabel: 'APK',
      cancellation: cancellation,
      onProgress: onProgress,
    );
  }

  /// True when [file] is on disk with the announced size and SHA-256. Called
  /// after a download and again right before the installer is opened.
  Future<bool> verifyFile(File file, AppRelease release) async {
    try {
      if (!await file.exists()) return false;
      if (release.size > 0 && await file.length() != release.size) return false;
      final digest = await sha256.bind(file.openRead()).first;
      return digest.toString() == release.sha256;
    } catch (_) {
      return false;
    }
  }

  /// Deletes APKs from earlier versions once a newer one is verified, so the
  /// downloads folder does not keep one ~57 MB installer per update. [keep] is
  /// the file just verified; non-APK files (a resource ZIP) are left alone.
  Future<void> removeStaleApks(Directory downloadsDir, File keep) async {
    try {
      await for (final entity in downloadsDir.list()) {
        if (entity is! File) continue;
        if (!entity.path.toLowerCase().endsWith('.apk')) continue;
        if (entity.path == keep.path) continue;
        try {
          await entity.delete();
        } catch (_) {
          // A file that cannot be removed only costs space.
        }
      }
    } catch (_) {
      // Cleanup is best effort; the verified installer is what matters.
    }
  }

  /// Deletes a rejected APK and its resume ETag so the next attempt starts at
  /// byte zero.
  Future<void> discard(File file) => _remote.discardDownload(file);

  /// Whether [release] is an upgrade for the installed build.
  ///
  /// Android compares `versionCode`, so that is the primary check. Only when
  /// the platform cannot report one does the personal-build versionName
  /// decide.
  bool isUpgrade({
    required AppRelease release,
    required int? installedVersionCode,
    required String installedVersionName,
  }) {
    if (installedVersionCode != null) {
      return release.versionCode > installedVersionCode;
    }
    return compareVersionNames(release.version, installedVersionName) > 0;
  }
}

/// The APK's file name on disk: the manifest's last path segment.
String safeApkFileName(AppRelease release) {
  final name = p.basename(release.fileName.replaceAll('\\', '/'));
  if (name.isEmpty || name == '.' || name == '..') {
    return 'gardendless-loader-${_sanitizeSegment(release.version)}.apk';
  }
  if (name.toLowerCase().endsWith('.apk')) return name;
  return '$name.apk';
}

/// `versionCode` as Android reads it, or null when the platform gave nothing.
int? parseVersionCode(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  return int.tryParse(trimmed);
}

/// Compares two personal-build version names, e.g. `0.9.0-hlh.2` against
/// `0.9.0-hlh.1`.
///
/// The numeric triple comes first; within the same triple a larger `-hlh.N` is
/// newer, and a name without `-hlh.N` counts as N = 0 because the fork stamps
/// personal builds on top of the upstream release they were cut from.
int compareVersionNames(String left, String right) {
  final leftParts = _versionNumbers(left);
  final rightParts = _versionNumbers(right);
  for (var i = 0; i < 3; i++) {
    if (leftParts[i] != rightParts[i]) {
      return leftParts[i].compareTo(rightParts[i]);
    }
  }
  final leftPersonal = _personalBuild(left);
  final rightPersonal = _personalBuild(right);
  if (leftPersonal != rightPersonal) {
    return leftPersonal.compareTo(rightPersonal);
  }
  // Two tags the scheme does not describe: fall back to the raw suffix so the
  // comparison still has an order.
  return _tag(left).compareTo(_tag(right));
}

List<int> _versionNumbers(String version) {
  final name = _versionName(version);
  final numbers = name.split('-').first.split('.');
  return List<int>.generate(
    3,
    (index) => index < numbers.length ? int.tryParse(numbers[index]) ?? 0 : 0,
    growable: false,
  );
}

String _versionName(String version) {
  var name = version.trim();
  if (name.startsWith('v') || name.startsWith('V')) {
    name = name.substring(1);
  }
  final plus = name.indexOf('+');
  return plus < 0 ? name : name.substring(0, plus);
}

String _tag(String version) {
  final name = _versionName(version);
  final dash = name.indexOf('-');
  return dash < 0 ? '' : name.substring(dash + 1);
}

int _personalBuild(String version) {
  final match = RegExp(r'^hlh\.(\d+)$').firstMatch(_tag(version));
  return match == null ? 0 : int.tryParse(match.group(1) ?? '') ?? 0;
}

String _sanitizeSegment(String value) {
  return value.replaceAll(RegExp(r'[^0-9A-Za-z._-]'), '_');
}
