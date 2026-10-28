/// 原生宿主写回、Dart 侧消费的「游戏退出结果」契约。
///
/// 单独立成不依赖 Flutter 的文件：`tool/check_game_host_contract.dart`
/// 要用纯 `dart run` 读它，而 `game_host.dart` 依赖 `package:flutter/services.dart`。
library;

enum GameExitReason {
  normal,
  userReturned,
  rendererGone,
  launchFailed,
  systemTerminated,

  /// 旧版在线宿主在设备令牌被服务端拒绝（401/403）时写回的原因。在线
  /// 游玩已删除，但升级前留下的退出结果仍靠它清理登录态。
  tokenRejected;

  static GameExitReason fromWireName(Object? value) {
    return GameExitReason.values.firstWhere(
      (reason) => reason.name == value,
      orElse: () => throw FormatException('Unknown game exit reason: $value'),
    );
  }
}

class GameExitResult {
  const GameExitResult({
    required this.sessionId,
    required this.reason,
    required this.finishedAt,
    this.message,
    this.code,
    this.playedMs = 0,
  });

  factory GameExitResult.fromJson(Map<String, Object?> json) {
    if (json['schemaVersion'] != 1) {
      throw const FormatException('Unsupported game exit result schema');
    }
    final sessionId = json['sessionId'];
    final finishedAt = DateTime.tryParse(json['finishedAt'] as String? ?? '');
    if (sessionId is! String || sessionId.isEmpty || finishedAt == null) {
      throw const FormatException('Invalid game exit result');
    }
    return GameExitResult(
      sessionId: sessionId,
      reason: GameExitReason.fromWireName(json['reason']),
      finishedAt: finishedAt.toUtc(),
      message: json['message'] as String?,
      code: json['code'] as String?,
      playedMs: (json['playedMs'] as num?)?.toInt() ?? 0,
    );
  }

  final String sessionId;
  final GameExitReason reason;
  final DateTime finishedAt;
  final String? message;

  /// Error code naming a known launch failure cause; absent for other exits.
  final String? code;

  /// Time the game spent in the foreground; time in the background is not
  /// play time.
  final int playedMs;
}

/// 退出结果是否要求启动器清登录态。
///
/// 只有原生在线宿主发现令牌被拒（401/403）才写 `tokenRejected`；没有令牌
/// 时不用重复清（幂等），其他退出原因一律不动登录态。
bool exitResultRequiresSignOut(GameExitResult? result,
    {required bool hasToken}) {
  return hasToken && result?.reason == GameExitReason.tokenRejected;
}
