import 'package:flutter/services.dart';

export 'game_host_platform.dart';
import 'game_host_platform.dart';

/// 游戏会话：本地资源包。
///
/// 在线游玩形态已删除；会话只描述一个本地资源槽、入口与宿主参数。
class GameSession {
  const GameSession({
    required this.sessionId,
    this.packageId,
    required this.resourceRoot,
    required this.platform,
    required this.entryPath,
    this.appRoot,
    required this.activationGeneration,
    required this.hasGpNext,
    required this.gpNextCompatible,
    required this.gpNextVersion,
    required this.watermarkEnabled,
    this.autoCollectSunEnabled = false,
    this.detailedAudioDiagnosticsEnabled = false,
    this.localSaveGuardRequired = false,
    this.renderScale,
    this.screenFit = ScreenFit.balanced,
    this.touchDiagnosticsEnabled = false,
    this.gestureHint,
    required this.allowedRemoteHosts,
    required this.gpNextRoot,
    required this.exportTemporaryRoot,
  });

  factory GameSession.fromJson(Map<String, Object?> json) {
    final entryPath = _requiredString(json, 'entryPath');
    _validateEntryPath(entryPath);
    final allowedRemoteHosts = json['allowedRemoteHosts'];
    if (allowedRemoteHosts is! List ||
        allowedRemoteHosts.any((host) => host is! String)) {
      throw const FormatException('allowedRemoteHosts must be a string list');
    }
    final normalizedRemoteHosts = allowedRemoteHosts
        .cast<String>()
        .map(_normalizeRemoteHost)
        .toList(growable: false);
    final generation = json['activationGeneration'];
    if (generation is! int || generation < 0) {
      throw const FormatException('activationGeneration must be non-negative');
    }
    final renderScale = json['renderScale'];
    if (renderScale != null && (renderScale is! num || renderScale <= 0)) {
      throw const FormatException('renderScale must be positive');
    }
    final gestureHint = json['gestureHint'];
    if (gestureHint != null &&
        (gestureHint is! List || gestureHint.any((line) => line is! String))) {
      throw const FormatException('gestureHint must be a string list');
    }
    return GameSession(
      sessionId: _requiredString(json, 'sessionId'),
      packageId: json['packageId'] as String?,
      appRoot: json['appRoot'] as String?,
      resourceRoot: _requiredString(json, 'resourceRoot'),
      platform: GameHostPlatform.fromWireName(json['platform']),
      entryPath: entryPath,
      activationGeneration: generation,
      hasGpNext: _requiredBool(json, 'hasGpNext'),
      gpNextCompatible: _requiredBool(json, 'gpNextCompatible'),
      gpNextVersion: json['gpNextVersion'] as String?,
      watermarkEnabled: _requiredBool(json, 'watermarkEnabled'),
      autoCollectSunEnabled: json['autoCollectSunEnabled'] as bool? ?? false,
      detailedAudioDiagnosticsEnabled:
          json['detailedAudioDiagnosticsEnabled'] as bool? ?? false,
      // 旧 session JSON 没有该字段：默认 false，原生宿主保持原行为。
      localSaveGuardRequired: json['localSaveGuardRequired'] as bool? ?? false,
      renderScale: (renderScale as num?)?.toDouble(),
      screenFit: ScreenFit.fromName(json['screenFit']),
      touchDiagnosticsEnabled:
          json['touchDiagnosticsEnabled'] as bool? ?? false,
      gestureHint: (gestureHint as List?)?.cast<String>(),
      allowedRemoteHosts: normalizedRemoteHosts,
      gpNextRoot: _requiredString(json, 'gpNextRoot'),
      exportTemporaryRoot: _requiredString(json, 'exportTemporaryRoot'),
    );
  }

  static const schemaVersion = 1;

  final String sessionId;
  final String? packageId;
  final String resourceRoot;
  final GameHostPlatform platform;
  final String entryPath;
  final int activationGeneration;
  final bool hasGpNext;
  final bool gpNextCompatible;
  final String? gpNextVersion;
  final bool watermarkEnabled;
  final bool autoCollectSunEnabled;
  final bool detailedAudioDiagnosticsEnabled;

  /// 本次启动是否必须成功加载本机存档版本保护脚本。
  ///
  /// 有游戏版本时 Dart 会生成并原子写入 guard，原生宿主必须把「文件缺失/
  /// 空白/读取失败」当成启动失败；无版本（旧式未索引资源包）为 false，
  /// 允许没有 guard 启动，保持旧包可用。
  final bool localSaveGuardRequired;

  /// Share of the device pixel ratio the game canvas renders at; null renders
  /// at the device's own ratio.
  final double? renderScale;
  final ScreenFit screenFit;

  /// Records the touch adapter's trace into the logs (tool shed).
  final bool touchDiagnosticsEnabled;

  /// Lines of the one-time gesture hint shown over the game; null shows none.
  final List<String>? gestureHint;
  final List<String> allowedRemoteHosts;
  final String gpNextRoot;
  final String exportTemporaryRoot;

  /// 启动器数据目录（存档桥文件所在的目录）。为空时由原生按资源槽的父目录推导。
  final String? appRoot;

  String get origin => platform.origin;

  Uri get entryUri {
    final base = Uri.parse('$origin/$entryPath');
    return base.replace(
      queryParameters: {'generation': activationGeneration.toString()},
    );
  }

  Map<String, Object?> toJson() {
    final normalizedRemoteHosts =
        allowedRemoteHosts.map(_normalizeRemoteHost).toList(growable: false);
    return {
      'schemaVersion': schemaVersion,
      'sessionId': sessionId,
      'packageId': packageId,
      'state': 'prepared',
      'resourceRoot': resourceRoot,
      'platform': platform.wireName,
      if (appRoot != null) 'appRoot': appRoot,
      'origin': origin,
      'entryPath': entryPath,
      'entryUrl': entryUri.toString(),
      'activationGeneration': activationGeneration,
      'hasGpNext': hasGpNext,
      'gpNextCompatible': gpNextCompatible,
      'gpNextVersion': gpNextVersion,
      'watermarkEnabled': watermarkEnabled,
      'autoCollectSunEnabled': autoCollectSunEnabled,
      'detailedAudioDiagnosticsEnabled': detailedAudioDiagnosticsEnabled,
      'localSaveGuardRequired': localSaveGuardRequired,
      'renderScale': renderScale,
      'screenFit': screenFit.name,
      'touchDiagnosticsEnabled': touchDiagnosticsEnabled,
      'gestureHint': gestureHint,
      'allowedRemoteHosts': normalizedRemoteHosts,
      'gpNextRoot': gpNextRoot,
      'exportTemporaryRoot': exportTemporaryRoot,
    };
  }
}

class MethodChannelGameHost {
  const MethodChannelGameHost();

  static const MethodChannel _channel = MethodChannel(
    'io.github.dey410.gardendlessloader/game_host',
  );

  Future<void> launch(GameSession session) async {
    await _channel.invokeMethod<void>('launch', session.toJson());
  }
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$key must be a non-empty string');
  }
  return value;
}

bool _requiredBool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! bool) {
    throw FormatException('$key must be a bool');
  }
  return value;
}

String _normalizeRemoteHost(String value) {
  final host = value.trim().toLowerCase();
  final labels = host.split('.');
  final valid = host.isNotEmpty &&
      host.length <= 253 &&
      labels.every(
        (label) =>
            label.isNotEmpty &&
            label.length <= 63 &&
            RegExp(r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$').hasMatch(label),
      );
  if (!valid) {
    throw FormatException('Invalid allowed remote host: $value');
  }
  return host;
}

void _validateEntryPath(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.hasScheme ||
      value.startsWith('/') ||
      value.contains('\\') ||
      uri.pathSegments.any((segment) => segment == '.' || segment == '..')) {
    throw const FormatException('entryPath must stay inside the resource root');
  }
}
