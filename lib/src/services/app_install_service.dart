import 'dart:io';

import 'package:flutter/services.dart';

/// An install request the Android host refused or could not start.
class AppInstallFailure implements Exception {
  const AppInstallFailure(this.code, this.message);

  /// Error-catalog code the Settings page turns into a readable sentence,
  /// e.g. `install_permission_required`.
  final String code;

  /// Detail from the host; never contains a URL or a token.
  final String message;

  @override
  String toString() => 'AppInstallFailure($code): $message';
}

/// Hands a downloaded APK to the system package installer.
///
/// Android host contract (`android/.../appupdate/ApkInstaller.kt` and
/// `MainActivity.kt`):
///
/// * channel `io.github.dey410.gardendlessloader/app_update`
/// * `installApk` arguments `{path: String}`, result `null` once the installer
///   activity started
/// * `installPermissionGranted`, result `bool`: whether this package may
///   install unknown apps
/// * `openInstallPermissionSettings`, result `bool`: whether the system
///   settings screen was opened
///
/// The host only accepts a file inside the app's own `downloads` folder and
/// serves it through `FileProvider` (`<package>.fileprovider`), so no storage
/// permission is involved. On Android 8+ it opens the unknown-sources screen
/// and answers `install_permission_required` when the grant is still missing.
class AppInstallService {
  const AppInstallService();

  static const channelName = 'io.github.dey410.gardendlessloader/app_update';
  static const methodInstallApk = 'installApk';
  static const methodPermissionGranted = 'installPermissionGranted';
  static const methodOpenPermissionSettings = 'openInstallPermissionSettings';
  static const MethodChannel _channel = MethodChannel(channelName);

  static const permissionRequiredCode = 'install_permission_required';

  /// Only the Android host can open a package installer.
  bool get supported => Platform.isAndroid;

  Future<void> installApk(String path) async {
    if (!Platform.isAndroid) {
      throw const AppInstallFailure(
        'install_unsupported',
        'In-app installation is only implemented on Android',
      );
    }
    try {
      await _channel.invokeMethod<Object?>(methodInstallApk, <String, Object?>{
        'path': path,
      });
    } on PlatformException catch (error) {
      throw AppInstallFailure(error.code, error.message ?? error.code);
    } on MissingPluginException {
      throw const AppInstallFailure(
        'install_unsupported',
        'This build has no APK installer',
      );
    }
  }

  /// False when the grant is missing, the host is absent or the platform is
  /// not Android.
  Future<bool> permissionGranted() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>(methodPermissionGranted) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Opens `Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES` for this package.
  Future<bool> openPermissionSettings() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>(methodOpenPermissionSettings) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
