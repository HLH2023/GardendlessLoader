import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

import '../models.dart';
import 'desktop_zip_extractor.dart';

class ResourcePickerService {
  ResourcePickerService() {
    _mobileZipImporterChannel.setMethodCallHandler(_handleNativeCall);
  }

  final String _platformName = Platform.operatingSystem;

  static const MethodChannel _mobileZipImporterChannel = MethodChannel(
    'io.github.dey410.gardendlessloader/resource_zip_importer',
  );

  ImportProgressCallback? _onProgress;

  /// Called with the file name when another app opens or shares a ZIP with
  /// the loader while the launcher is running.
  void Function(String name)? onIncomingZip;

  Future<void> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'progress':
        final progress = _decodeProgress(call.arguments);
        if (progress != null) _onProgress?.call(progress);
      case 'incomingZipReceived':
        final name = call.arguments;
        if (name is String) onIncomingZip?.call(name);
    }
  }

  /// File name of a ZIP another app handed to the loader and that is still
  /// waiting for the user's decision.
  ///
  /// 桌面端没有这个原生通道（Windows/Linux/macOS），直接调用会抛
  /// `MissingPluginException`；它以前在初始化末尾被直接 await，于是整个
  /// 启动流程失败（2026-10-27 Windows 实测：应用初始化失败）。
  /// 通道缺失等价于「没有待处理的 ZIP」，返回 null 就好。
  Future<String?> incomingZipName() async {
    if (!_isSupportedPlatform) return null;
    try {
      return await _mobileZipImporterChannel
          .invokeMethod<String>('incomingZip');
    } on MissingPluginException {
      return null;
    }
  }

  Future<void> discardIncomingZip() async {
    if (!_isSupportedPlatform) return;
    try {
      await _mobileZipImporterChannel.invokeMethod<void>('discardIncomingZip');
    } on MissingPluginException {
      // 没有原生实现 = 没有待处理的 ZIP，无需丢弃。
    }
  }

  /// Extracts from the system picker when [incoming] is false, otherwise
  /// from the ZIP another app handed to the loader.
  Future<Directory?> extractDocsZip({
    required bool incoming,
    Directory? targetDirectory,
    ImportProgressCallback? onProgress,
  }) async {
    if (targetDirectory == null) {
      throw ResourcePickerFailure(
        'ZIP import requires an app-private target directory',
        code: 'invalid_target_directory',
      );
    }

    // 桌面端：用系统文件对话框挑 ZIP，再用 Dart 解压（原生通道不存在）
    if (_isDesktopPlatform) {
      final picked = await FilePicker.pickFiles(
        dialogTitle: '选择资源包 ZIP',
        type: FileType.custom,
        allowedExtensions: const ['zip'],
      );
      // file_picker 13 的 pickFiles 直接返回 List<PlatformFile>（旧版是 FilePickerResult）
      final path = picked.isEmpty ? null : picked.first.path;
      if (path == null) return null;
      await const DesktopZipExtractor().extract(
        zipFile: File(path),
        targetDirectory: targetDirectory,
        onProgress: (files, bytes, total) {
          onProgress?.call(ImportProgress(
            phase: ImportPhase.extracting,
            copiedFiles: files,
            copiedBytes: bytes,
            totalBytes: total,
          ));
        },
      );
      return targetDirectory;
    }

    if (!_isSupportedPlatform) {
      throw ResourcePickerFailure(
        '当前平台不支持 ZIP 导入：$_platformName',
        code: 'platform_unsupported',
      );
    }

    _onProgress = onProgress;
    try {
      final extractedPath =
          await _mobileZipImporterChannel.invokeMethod<String>(
        incoming ? 'extractIncomingDocsZip' : 'pickAndExtractDocsZip',
        <String, Object?>{'targetDirectory': targetDirectory.path},
      );
      return extractedPath == null ? null : Directory(extractedPath);
    } on PlatformException catch (error) {
      throw ResourcePickerFailure(
        error.message ?? '无法导入选择的 ZIP',
        code: error.code,
      );
    } finally {
      _onProgress = null;
    }
  }

  /// Extracts a ZIP the launcher already downloaded to [zipPath]; the native
  /// side reads the same file the picker would have handed it.
  Future<Directory?> extractLocalZip({
    required String zipPath,
    required Directory targetDirectory,
    ImportProgressCallback? onProgress,
  }) async {
    // 桌面端没有原生解压通道：用 Dart 流式解压（带 zip-slip 防护）
    if (_isDesktopPlatform) {
      await const DesktopZipExtractor().extract(
        zipFile: File(zipPath),
        targetDirectory: targetDirectory,
        onProgress: (files, bytes, total) {
          onProgress?.call(ImportProgress(
            phase: ImportPhase.extracting,
            copiedFiles: files,
            copiedBytes: bytes,
            totalBytes: total,
          ));
        },
      );
      return targetDirectory;
    }
    if (!_isSupportedPlatform) {
      throw ResourcePickerFailure(
        '当前平台不支持从服务器下载资源：$_platformName',
        code: 'platform_unsupported',
      );
    }

    _onProgress = onProgress;
    try {
      final extractedPath =
          await _mobileZipImporterChannel.invokeMethod<String>(
        'extractLocalZip',
        <String, Object?>{
          'zipPath': zipPath,
          'targetDirectory': targetDirectory.path,
        },
      );
      return extractedPath == null ? null : Directory(extractedPath);
    } on MissingPluginException {
      throw ResourcePickerFailure(
        '当前平台不支持从服务器下载资源：$_platformName',
        code: 'platform_unsupported',
      );
    } on PlatformException catch (error) {
      if (error.code == 'notImplemented') {
        throw ResourcePickerFailure(
          '当前平台不支持从服务器下载资源：$_platformName',
          code: 'platform_unsupported',
        );
      }
      throw ResourcePickerFailure(
        error.message ?? '无法解压下载的资源包',
        code: error.code,
      );
    } finally {
      _onProgress = null;
    }
  }

  bool get _isSupportedPlatform =>
      _platformName == 'android' ||
      _platformName == 'ios' ||
      _platformName == 'ohos';

  /// 桌面端：有 Dart 解压路径，但没有原生目录选择通道。
  bool get _isDesktopPlatform =>
      _platformName == 'windows' ||
      _platformName == 'linux' ||
      _platformName == 'macos';

  static ImportProgress? _decodeProgress(Object? arguments) {
    if (arguments is! Map) {
      return null;
    }
    final phase = switch (arguments['phase']) {
      'receiving' => ImportPhase.receiving,
      'extracting' => ImportPhase.extracting,
      _ => null,
    };
    if (phase == null) {
      return null;
    }
    int readInt(String key) => (arguments[key] as num?)?.toInt() ?? 0;

    return ImportProgress(
      phase: phase,
      copiedBytes: readInt('processedBytes'),
      totalBytes: readInt('totalBytes'),
      copiedFiles: readInt('processedFiles'),
      totalFiles: readInt('totalFiles'),
      message: arguments['message'] as String?,
    );
  }
}

class ResourcePickerFailure implements Exception {
  ResourcePickerFailure(this.message, {this.code = 'import_extract_failed'});

  final String message;
  final String code;

  @override
  String toString() => message;
}
