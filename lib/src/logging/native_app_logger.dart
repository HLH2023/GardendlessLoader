import 'dart:async';

import 'package:flutter/services.dart';

import 'app_logger.dart';

/// 原生日志通道。
///
/// Android / iOS / OHOS 有原生实现；Windows 桌面端没有。日志是诊断设施，
/// 绝不能成为启动的前置条件——hlh.18 的 Windows 包就因为这里抛
/// `MissingPluginException`，`runApp` 从未执行，表现为双击后只有空白窗口。
/// 因此通道不可用时退回 [InMemoryAppLogger]：本次会话仍能看日志，只是不落盘。
class NativeAppLogger implements AppLogger {
  NativeAppLogger._({
    required this.appSessionId,
    required String? appRoot,
    required Map<String, LogEventSchema> eventSchemas,
  }) : _sanitizer = LogSanitizer(appRoot: appRoot, eventSchemas: eventSchemas);

  static const channelName = 'io.github.dey410.gardendlessloader/app_logger';
  static const MethodChannel _channel = MethodChannel(channelName);

  static Future<AppLogger> initialize({
    String? appRoot,
    Map<String, LogEventSchema> eventSchemas = const <String, LogEventSchema>{},
  }) async {
    try {
      final response =
          await _channel.invokeMapMethod<Object?, Object?>('initialize');
      final sessionId = response?['appSessionId'];
      if (sessionId is String && sessionId.isNotEmpty) {
        return NativeAppLogger._(
          appSessionId: sessionId,
          appRoot: appRoot,
          eventSchemas: eventSchemas,
        );
      }
    } on MissingPluginException {
      // 桌面端没有原生日志实现，走降级路径。
    } on PlatformException {
      // 原生实现存在但初始化失败：同样不能拖垮启动。
    } on FormatException {
      // 返回结构不对，按不可用处理。
    }
    final fallback = InMemoryAppLogger(
      appSessionId: 'local-'
          '${DateTime.now().toUtc().microsecondsSinceEpoch.toRadixString(16)}',
      appRoot: appRoot,
      eventSchemas: eventSchemas,
    );
    fallback.emit(
      level: LogLevel.warn,
      category: 'app.logging',
      event: 'native_logger_unavailable',
      outcome: LogOutcome.degraded,
      code: 'logger_channel_missing',
      message: '当前平台没有原生日志实现，日志只保留在本次会话内存中',
    );
    return fallback;
  }

  final LogSanitizer _sanitizer;
  @override
  final String appSessionId;

  @override
  void emit({
    required LogLevel level,
    required String category,
    required String event,
    required LogOutcome outcome,
    String? code,
    String? message,
    String? gameSessionId,
    String? operationId,
    int? durationMs,
    Map<String, Object?>? context,
    Object? error,
    StackTrace? stackTrace,
  }) {
    final payload = logEventPayload(
      appSessionId: appSessionId,
      sanitizer: _sanitizer,
      level: level,
      category: category,
      event: event,
      outcome: outcome,
      code: code,
      message: message,
      gameSessionId: gameSessionId,
      operationId: operationId,
      durationMs: durationMs,
      context: context,
      error: error,
      stackTrace: stackTrace,
    );
    // Logging must not replace an application failure. Native owns all retained
    // events and its snapshot reports persistence health.
    unawaited(
        _channel.invokeMethod<void>('emit', payload).catchError((Object _) {}));
  }

  @override
  LogOperation startOperation({
    required String operationId,
    required String category,
    required String startedEvent,
    required String finishedEvent,
    String? failureCode,
    String? gameSessionId,
  }) =>
      startLogOperation(
        logger: this,
        operationId: operationId,
        category: category,
        startedEvent: startedEvent,
        finishedEvent: finishedEvent,
        failureCode: failureCode,
        gameSessionId: gameSessionId,
      );

  @override
  Future<AppLogSnapshot> loadSnapshot({int limit = 500}) async {
    final response = await _channel.invokeMapMethod<Object?, Object?>(
      'snapshot',
      <String, Object?>{'limit': limit},
    );
    if (response == null) {
      throw const FormatException('Native logger returned no snapshot');
    }
    return AppLogSnapshot.fromMap(response);
  }

  @override
  Future<void> flush({Duration timeout = const Duration(milliseconds: 500)}) =>
      _channel.invokeMethod<void>('flush').timeout(timeout);

  @override
  Future<void> deleteHistory() => _channel
      .invokeMethod<void>('deleteHistory')
      .timeout(const Duration(seconds: 2));
}

/// 没有原生日志实现时的兜底：只保留本次进程内的最近事件。
///
/// 不写文件是刻意的：这里的目标是「应用能启动、界面能打开日志页」，
/// 持久化由各平台原生实现负责（Windows 目前没有）。
class InMemoryAppLogger implements AppLogger {
  InMemoryAppLogger({
    required this.appSessionId,
    String? appRoot,
    Map<String, LogEventSchema> eventSchemas = const <String, LogEventSchema>{},
  }) : _sanitizer = LogSanitizer(appRoot: appRoot, eventSchemas: eventSchemas);

  static const int maxEvents = 500;

  final LogSanitizer _sanitizer;
  final List<Map<String, Object?>> _events = <Map<String, Object?>>[];

  @override
  final String appSessionId;

  @override
  void emit({
    required LogLevel level,
    required String category,
    required String event,
    required LogOutcome outcome,
    String? code,
    String? message,
    String? gameSessionId,
    String? operationId,
    int? durationMs,
    Map<String, Object?>? context,
    Object? error,
    StackTrace? stackTrace,
  }) {
    _events.add(
      Map<String, Object?>.unmodifiable(
        logEventPayload(
          appSessionId: appSessionId,
          sanitizer: _sanitizer,
          level: level,
          category: category,
          event: event,
          outcome: outcome,
          code: code,
          message: message,
          gameSessionId: gameSessionId,
          operationId: operationId,
          durationMs: durationMs,
          context: context,
          error: error,
          stackTrace: stackTrace,
        ),
      ),
    );
    if (_events.length > maxEvents) {
      _events.removeRange(0, _events.length - maxEvents);
    }
  }

  @override
  LogOperation startOperation({
    required String operationId,
    required String category,
    required String startedEvent,
    required String finishedEvent,
    String? failureCode,
    String? gameSessionId,
  }) =>
      startLogOperation(
        logger: this,
        operationId: operationId,
        category: category,
        startedEvent: startedEvent,
        finishedEvent: finishedEvent,
        failureCode: failureCode,
        gameSessionId: gameSessionId,
      );

  @override
  Future<AppLogSnapshot> loadSnapshot({int limit = 500}) async {
    final count = limit.clamp(0, _events.length);
    return AppLogSnapshot(
      appSessionId: appSessionId,
      persisting: false,
      degraded: true,
      logDirectory: null,
      totalBytes: 0,
      writeFailureCount: 0,
      droppedByLevel: const <String, int>{},
      events: count == 0
          ? const <Map<String, Object?>>[]
          : List<Map<String, Object?>>.unmodifiable(
              _events.sublist(_events.length - count),
            ),
    );
  }

  @override
  Future<void> flush(
      {Duration timeout = const Duration(milliseconds: 500)}) async {}

  @override
  Future<void> deleteHistory() async => _events.clear();
}

/// 原生与内存两条路径共用的事件结构，避免字段漂移。
Map<String, Object?> logEventPayload({
  required String appSessionId,
  required LogSanitizer sanitizer,
  required LogLevel level,
  required String category,
  required String event,
  required LogOutcome outcome,
  String? code,
  String? message,
  String? gameSessionId,
  String? operationId,
  int? durationMs,
  Map<String, Object?>? context,
  Object? error,
  StackTrace? stackTrace,
}) =>
    <String, Object?>{
      'schemaVersion': 1,
      'source': LogSource.dart.name,
      'level': level.name.toUpperCase(),
      'category': category,
      'event': event,
      'outcome': outcome.name,
      'appSessionId': appSessionId,
      if (code != null) 'code': code,
      if (message != null) 'message': sanitizer.sanitizeText(message, 2048),
      if (gameSessionId != null) 'gameSessionId': gameSessionId,
      if (operationId != null) 'operationId': operationId,
      if (durationMs != null) 'durationMs': durationMs,
      if (context != null) 'context': sanitizer.sanitizeContext(event, context),
      if (error != null)
        'error': LogEventError(
          type: error.runtimeType.toString(),
          message: sanitizer.sanitizeText(error.toString(), 4096),
          stackTrace:
              sanitizer.sanitizeText(stackTrace?.toString() ?? '', 8192),
        ).toJson(),
    };
