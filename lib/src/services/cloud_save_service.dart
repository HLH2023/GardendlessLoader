/// 云端存档的只读视图模型。
///
/// 这里只做「解析 + 展示所需的派生值」，不碰网络：请求由
/// [RemoteResourceService] 发出（它已经有令牌、超时、体积上限这套底座），
/// 页面只消费这里的结果。存档内容本体（`data[key]`）刻意不保留 ——
/// App 端不该也没能力直接改写游戏 localStorage，回滚走服务端历史。
library;

/// 一份云端存档当前版本的元信息。
class CloudSaveEntry {
  const CloudSaveEntry({
    required this.key,
    required this.bytes,
    required this.mtime,
    required this.summary,
  });

  final String key;
  final int bytes;

  /// 服务端文件 mtime（秒），0 表示未知。
  final int mtime;

  /// 服务端对可摘要键返回的统计（玩家名、金币、宝石…），其余键为空。
  final Map<String, Object?> summary;

  DateTime? get lastWrite =>
      mtime > 0 ? DateTime.fromMillisecondsSinceEpoch(mtime * 1000) : null;

  String? get playerName {
    final name = summary['name'];
    return name is String && name.trim().isNotEmpty ? name.trim() : null;
  }

  int? get coin => _intOf(summary['coin']);

  int? get gem => _intOf(summary['gem']);

  int? get world => _intOf(summary['world']);

  static int? _intOf(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }
}

/// `GET /_save/app/load` 的解析结果。
class CloudSaveSnapshot {
  const CloudSaveSnapshot({
    required this.user,
    required this.entries,
    required this.serverTime,
  });

  factory CloudSaveSnapshot.fromJson(Map<String, Object?> json) {
    final user = json['user'];
    if (user is! String || user.trim().isEmpty) {
      throw const FormatException('save snapshot has no user');
    }
    final mtime = _mapOf(json['mtime']);
    final summary = _mapOf(json['summary']);
    final entries = <CloudSaveEntry>[];
    for (final entry in mtime.entries) {
      final key = entry.key;
      final stamp = _asInt(entry.value) ?? 0;
      if (key.isEmpty) continue;
      entries.add(
        CloudSaveEntry(
          key: key,
          // /load 不返回字节数，用摘要里的 bytes（服务端会带）兜底为 0。
          bytes: _bytesOf(summary[key]),
          mtime: stamp,
          summary: _mapOf(summary[key], allowNull: true),
        ),
      );
    }
    entries.sort((a, b) {
      // 玩家进度置顶，其余按时间倒序
      final byKey = _rank(a.key).compareTo(_rank(b.key));
      return byKey != 0 ? byKey : b.mtime.compareTo(a.mtime);
    });
    return CloudSaveSnapshot(
      user: user.trim(),
      entries: entries,
      serverTime: _asInt(json['server_ts']) ?? 0,
    );
  }

  final String user;
  final List<CloudSaveEntry> entries;
  final int serverTime;

  int get totalBytes => entries.fold(0, (sum, entry) => sum + entry.bytes);

  int get lastWrite => entries.fold(0, (latest, entry) {
        return entry.mtime > latest ? entry.mtime : latest;
      });

  static int _rank(String key) {
    const order = [
      'PvZ2_PlayerProperties',
      'PvZ2_Settings',
      'PvZ2_GitHubLevels',
      'PvZ2_GitHubLevels_Sha',
    ];
    final index = order.indexOf(key);
    return index < 0 ? order.length : index;
  }

  static Map<String, Object?> _mapOf(Object? value, {bool allowNull = false}) {
    if (value is Map) {
      return value.map((key, item) => MapEntry(key.toString(), item));
    }
    return <String, Object?>{};
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  static int _bytesOf(Object? summary) {
    if (summary is Map) {
      final raw = summary['bytes'];
      if (raw is int) return raw;
      if (raw is num) return raw.toInt();
      if (raw is String) return int.tryParse(raw.trim()) ?? 0;
    }
    return 0;
  }
}

/// 一个历史版本。
class CloudSaveVersion {
  const CloudSaveVersion({
    required this.ts,
    required this.bytes,
    required this.device,
    required this.summary,
  });

  factory CloudSaveVersion.fromJson(Map<String, Object?> json) {
    final ts = CloudSaveSnapshot._asInt(json['ts']) ?? 0;
    if (ts <= 0) {
      throw const FormatException('history item has no timestamp');
    }
    final device = json['device'];
    return CloudSaveVersion(
      ts: ts,
      bytes: CloudSaveSnapshot._asInt(json['bytes']) ?? 0,
      device: device is String ? device : '',
      summary: CloudSaveSnapshot._mapOf(json['summary']),
    );
  }

  final int ts;
  final int bytes;

  /// 服务端记录的最后写入设备标签，例如 `PLG110 · Chrome 155`。
  final String device;
  final Map<String, Object?> summary;

  DateTime get writtenAt => DateTime.fromMillisecondsSinceEpoch(ts * 1000);

  String? get playerName {
    final name = summary['name'];
    return name is String && name.trim().isNotEmpty ? name.trim() : null;
  }
}
