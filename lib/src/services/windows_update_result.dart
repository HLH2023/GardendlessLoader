import 'dart:convert';

/// Windows 更新脚本写回的终态。
///
/// 更新发生在应用退出之后：脚本覆盖安装目录，最后写一份 JSON 到
/// `<资源根>/windows_update_result.json`，下一次启动由 AppController 读出来
/// 变成提示。这里只做「JSON → 结构化结果」的纯映射，方便本机测试——
/// 否则这条路径只能靠 Windows 实机跑一次才知道解析对不对。
enum WindowsUpdateOutcomeStatus {
  /// 覆盖成功。
  applied,

  /// 覆盖失败但已回滚到原版本。
  rolledBack,

  /// 失败且没有回滚（安装目录可能不完整）。
  failed,

  /// Dart 写了 pending 但脚本没写出终态（没起来/被杀软拦下/机器重启）。
  pending,

  /// 脚本写了不认识的 status（版本不匹配/手改过）。
  unknown;

  bool get isSuccess => this == WindowsUpdateOutcomeStatus.applied;

  bool get isFailure => this == WindowsUpdateOutcomeStatus.failed;

  bool get isRollback => this == WindowsUpdateOutcomeStatus.rolledBack;

  bool get isInterrupted => this == WindowsUpdateOutcomeStatus.pending;

  /// 日志与用户提示共用的稳定 code（不要用 `name`：`rolledBack` 和
  /// `windows_update_rolled_back` 对不上，userErrorCatalog 里的下一步动作
  /// 会查不到 —— 2026-10-27 自查发现）。
  String get logCode => switch (this) {
        WindowsUpdateOutcomeStatus.applied => 'windows_update_applied',
        WindowsUpdateOutcomeStatus.rolledBack => 'windows_update_rolled_back',
        WindowsUpdateOutcomeStatus.failed =>
          'windows_update_failed_after_restart',
        WindowsUpdateOutcomeStatus.pending => 'windows_update_interrupted',
        WindowsUpdateOutcomeStatus.unknown => 'windows_update_unknown',
      };
}

class WindowsUpdateOutcome {
  const WindowsUpdateOutcome({
    required this.status,
    this.code = '',
    this.message = '',
    this.fromVersion = '',
    this.toVersion = '',
    this.logFile = '',
    this.at,
  });

  final WindowsUpdateOutcomeStatus status;

  /// 脚本侧的细分原因（`ok` / `expand-failed` / `copy-failed` / ...）。
  final String code;
  final String message;
  final String fromVersion;
  final String toVersion;

  /// 脚本自己的日志路径（`%TEMP%\gardendless-update-*.log`），写进诊断用。
  final String logFile;

  /// Unix 秒；仅用于排查，不参与判定。
  final int? at;

  /// 解析回执。空串、坏 JSON、非对象、缺/空 `status` 一律返回 null：
  /// 宁可当作「没有回执」，也不要弹一条吓人的假失败。
  ///
  /// 注意 BOM：脚本用无 BOM 的 UTF-8 写，但用户/杀软/编辑器可能补上；
  /// `jsonDecode` 遇到 `\uFEFF` 会直接抛，这里先剥掉。
  static WindowsUpdateOutcome? parse(String raw) {
    if (raw.isEmpty) return null;
    var text = raw;
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    text = text.trim();
    if (text.isEmpty) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final status = _text(decoded['status']).toLowerCase();
    if (status.isEmpty) return null;
    return WindowsUpdateOutcome(
      status: switch (status) {
        'applied' => WindowsUpdateOutcomeStatus.applied,
        'rolled-back' => WindowsUpdateOutcomeStatus.rolledBack,
        'failed' => WindowsUpdateOutcomeStatus.failed,
        'pending' => WindowsUpdateOutcomeStatus.pending,
        _ => WindowsUpdateOutcomeStatus.unknown,
      },
      code: _text(decoded['code']),
      message: _text(decoded['message']),
      fromVersion: _text(decoded['fromVersion']),
      toVersion: _text(decoded['toVersion']),
      logFile: _text(decoded['logFile']),
      at: _int(decoded['at']),
    );
  }

  static String _text(Object? value) =>
      value is String ? value.trim() : (value == null ? '' : '$value'.trim());

  static int? _int(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }
}
