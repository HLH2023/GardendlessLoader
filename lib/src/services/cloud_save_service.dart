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
    this.deviceLabel = '',
    this.sourceVersion = '',
    this.sourceKind = '',
    this.sourceKnown = false,
  });

  final String key;
  final int bytes;

  /// 服务端文件 mtime（秒），0 表示未知。
  final int mtime;

  /// 服务端对可摘要键返回的统计（玩家名、金币、宝石…），其余键为空。
  final Map<String, Object?> summary;

  /// 最后写这份存档的设备标签，例如 `PLG110 · Chrome 155`；空表示未知。
  final String deviceLabel;

  /// 这个键实际存放在哪个游戏版本分区（空串 = legacy）。
  /// 不能拿快照的全局分区代替：一个账号的 Settings 可能来自 1.7.0，
  /// 而玩家进度来自继承的 0.16.1，历史目录各在各自的分区里。
  final String sourceVersion;

  /// `exact` / `migrated`；空表示老服务端没给。
  final String sourceKind;

  /// `keySources` 是否明确给出了这个键的来源。
  ///
  /// 必须区分「明确是 legacy（空串）」和「老服务端没给」：前者历史要去遗留
  /// 分区，后者只能回退到整份快照的分区。只看空串会把 legacy 键查错目录。
  final bool sourceKnown;

  /// 这份数据是从旧版本继承来的（不是当前版本自己写的）。
  bool get inherited => sourceKind == 'migrated';

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

/// 一份云端玩家数据（服务端 `profiles/<id>.json` 的元信息）。
///
/// 游戏把全部玩家放在 `PvZ2_PlayerProperties` 数组里，但云端已经拆成独立
/// 文档。`id` 是服务端分配的稳定 UUID（玩家改名、数组换序都不变），
/// `name` 只是展示名，允许重名。
class CloudPlayerProfile {
  const CloudPlayerProfile({
    required this.id,
    required this.name,
    required this.index,
    required this.bytes,
    required this.revision,
    required this.updatedAt,
    this.ownerUid = '',
    this.ownerUsername = '',
    this.summary = const <String, Object?>{},
    this.sourceVersion = '',
    this.sourceKind = '',
    this.sourceKnown = false,
  });

  factory CloudPlayerProfile.fromJson(
    Map<String, Object?> json, {
    String sourceVersion = '',
    String sourceKind = '',
    bool sourceKnown = false,
  }) {
    final id = (json['id'] as String? ?? '').trim();
    if (id.isEmpty) {
      throw const FormatException('profile has no id');
    }
    return CloudPlayerProfile(
      id: id,
      name: (json['name'] as String? ?? '').trim(),
      index: CloudSaveSnapshot._asInt(json['index']) ?? 0,
      bytes: CloudSaveSnapshot._asInt(json['bytes']) ?? 0,
      revision: (json['revision'] as String? ?? '').trim(),
      updatedAt: CloudSaveSnapshot._asInt(json['updatedAt']) ?? 0,
      ownerUid: (json['ownerUid'] as String? ?? '').trim(),
      ownerUsername: (json['ownerUsername'] as String? ?? '').trim(),
      summary: CloudSaveSnapshot._mapOf(json['summary']),
      sourceVersion: sourceVersion,
      sourceKind: sourceKind,
      sourceKnown: sourceKnown,
    );
  }

  final String id;
  final String name;
  final int index;
  final int bytes;

  /// 服务端的不透明 revision（UUID 字符串），用于逐玩家乐观并发。
  final String revision;

  /// 最近写入时间（秒）。
  final int updatedAt;

  /// 归属的 authentik uid。用户名可能重名/改名，uid 才是所有权主键。
  final String ownerUid;
  final String ownerUsername;
  final Map<String, Object?> summary;

  /// 这份玩家数据实际来自哪个游戏版本（exact 时等于请求版本，
  /// migrated 时是旧版本标签），空串表示 legacy。
  final String sourceVersion;
  final String sourceKind;

  /// 服务端是否明确给了 `profileSource`（与 [CloudSaveEntry.sourceKnown] 同理）。
  final bool sourceKnown;

  String? get displayName => name.isEmpty ? null : name;

  int? get coin => CloudSaveEntry._intOf(summary['coin']);

  int? get gem => CloudSaveEntry._intOf(summary['gem']);

  bool get inherited => sourceKind == 'migrated';

  DateTime? get lastWrite => updatedAt > 0
      ? DateTime.fromMillisecondsSinceEpoch(updatedAt * 1000)
      : null;

  /// revision 很短的一段，用于界面确认「这是不是同一份数据」。
  String get shortId => id.length <= 8 ? id : id.substring(0, 8);
}

/// `GET /_save/app/load` 的解析结果。
class CloudSaveSnapshot {
  const CloudSaveSnapshot({
    required this.user,
    required this.entries,
    required this.serverTime,
    this.isAdmin = false,
    this.gameVersion = '',
    this.requestedGameVersion = '',
    this.loadKind = '',
    this.ownerUid = '',
    this.profiles = const <CloudPlayerProfile>[],
    this.profileSource = '',
  });

  factory CloudSaveSnapshot.fromJson(Map<String, Object?> json) {
    final user = json['user'];
    if (user is! String || user.trim().isEmpty) {
      throw const FormatException('save snapshot has no user');
    }
    final mtime = _mapOf(json['mtime']);
    final summary = _mapOf(json['summary']);
    final device = _mapOf(json['device']);
    final entries = <CloudSaveEntry>[];
    for (final entry in mtime.entries) {
      final key = entry.key;
      final stamp = _asInt(entry.value) ?? 0;
      if (key.isEmpty) continue;
      final deviceInfo = _mapOf(device[key], allowNull: true);
      final label = deviceInfo['label'];
      final source = _keySource(json['keySources'], key);
      entries.add(
        CloudSaveEntry(
          key: key,
          // /load 不返回字节数，用摘要里的 bytes（服务端会带）兜底为 0。
          bytes: _bytesOf(summary[key]),
          mtime: stamp,
          summary: _mapOf(summary[key], allowNull: true),
          deviceLabel: label is String ? label : '',
          sourceVersion: source.version,
          sourceKind: source.kind,
          sourceKnown: source.present,
        ),
      );
    }
    entries.sort((a, b) {
      // 玩家进度置顶，其余按时间倒序
      final byKey = _rank(a.key).compareTo(_rank(b.key));
      return byKey != 0 ? byKey : b.mtime.compareTo(a.mtime);
    });

    final profileSource = (json['profileSource'] as String? ?? '').trim();
    final profileSourceKnown = json.containsKey('profileSource');
    final playerKind =
        _keySourceKind(json['keySources'], 'PvZ2_PlayerProperties');
    final profiles = <CloudPlayerProfile>[];
    final rawProfiles = json['profiles'];
    if (rawProfiles is List) {
      for (final raw in rawProfiles) {
        if (raw is! Map) continue;
        try {
          profiles.add(CloudPlayerProfile.fromJson(
            raw.map((key, value) => MapEntry(key.toString(), value)),
            sourceVersion: profileSource,
            sourceKind: playerKind,
            sourceKnown: profileSourceKnown,
          ));
        } on FormatException {
          // 单份玩家元信息损坏不能拖垮整页
        }
      }
    }
    profiles.sort((a, b) => a.index.compareTo(b.index));

    return CloudSaveSnapshot(
      user: user.trim(),
      entries: entries,
      serverTime: _asInt(json['server_ts']) ?? 0,
      isAdmin: json['is_admin'] == true,
      gameVersion: (json['gameVersion'] as String? ?? '').trim(),
      requestedGameVersion:
          (json['requestedGameVersion'] as String? ?? '').trim(),
      loadKind: (json['load_kind'] as String? ?? '').trim(),
      ownerUid: (json['owner_uid'] as String? ?? '').trim(),
      profiles: profiles,
      profileSource: profileSource,
    );
  }

  final String user;
  final List<CloudSaveEntry> entries;
  final int serverTime;

  /// 令牌是否属于 authentik Admins 组。跨用户管理才需要管理员；
  /// 自己的历史版本与回滚对所有登录用户开放。
  final bool isAdmin;

  /// 服务端实际返回的存档分区（空串 = 未分区的 legacy 存档）。
  /// 历史/回滚必须用这个值，不能再用「请求的版本」：否则页面显示的是
  /// 继承来的 legacy 存档，历史却去查一个不存在的 by-version 目录。
  final String gameVersion;

  /// 本次请求的分区键（页面当前查看的模式）。
  final String requestedGameVersion;

  /// exact / migrated / none。
  final String loadKind;

  /// 账号的 authentik uid；老服务端可能为空。
  final String ownerUid;

  /// 云端玩家列表。空表示旧服务端（还没拆多玩家）或云端没有玩家数据。
  final List<CloudPlayerProfile> profiles;

  /// 玩家数据实际来源版本（空串 = legacy）。
  final String profileSource;

  /// 除玩家数据外的共享键（Settings / GitHubLevels…）。
  List<CloudSaveEntry> get sharedEntries => entries
      .where((entry) => entry.key != 'PvZ2_PlayerProperties')
      .toList(growable: false);

  /// 按 key 找条目。历史/回滚要用这一条自己的分区，而不是整份快照的分区。
  CloudSaveEntry? entryFor(String key) {
    for (final entry in entries) {
      if (entry.key == key) return entry;
    }
    return null;
  }

  /// 按服务端 profileId 找玩家数据。
  CloudPlayerProfile? profileFor(String profileId) {
    for (final profile in profiles) {
      if (profile.id == profileId) return profile;
    }
    return null;
  }

  bool get hasPlayerProfiles => profiles.isNotEmpty;

  int get totalBytes => entries.fold(0, (sum, entry) => sum + entry.bytes);

  int get lastWrite => entries.fold(0, (latest, entry) {
        return entry.mtime > latest ? entry.mtime : latest;
      });

  static String _keySourceKind(Object? raw, String key) {
    if (raw is! Map) return '';
    final item = raw[key];
    if (item is! Map) return '';
    final kind = item['kind'];
    return kind is String ? kind : '';
  }

  /// 单个键自己的来源分区。服务端的 `keySources` 形状是
  /// `{key: {gameVersion, kind}}`；`gameVersion` 为 `"legacy"` 表示未分区。
  static ({String version, String kind, bool present}) _keySource(
      Object? raw, String key) {
    if (raw is! Map) return (version: '', kind: '', present: false);
    final item = raw[key];
    if (item is! Map) return (version: '', kind: '', present: false);
    final version = item['gameVersion'];
    final kind = item['kind'];
    final trimmedVersion = version is String ? version.trim() : '';
    return (
      version: trimmedVersion == 'legacy' ? '' : trimmedVersion,
      kind: kind is String ? kind.trim() : '',
      present: true,
    );
  }

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
    this.name = '',
  });

  factory CloudSaveVersion.fromJson(Map<String, Object?> json) {
    final ts = CloudSaveSnapshot._asInt(json['ts']) ?? 0;
    if (ts <= 0) {
      throw const FormatException('history item has no timestamp');
    }
    final device = json['device'];
    final name = json['name'];
    return CloudSaveVersion(
      ts: ts,
      bytes: CloudSaveSnapshot._asInt(json['bytes']) ?? 0,
      device: device is String ? device : '',
      summary: CloudSaveSnapshot._mapOf(json['summary']),
      // 服务端历史文件名，例如 1792892941-3.json；空表示老接口没给
      name: name is String ? name : '',
    );
  }

  final int ts;
  final int bytes;

  /// 服务端记录的最后写入设备标签，例如 `PLG110 · Chrome 155`。
  final String device;
  final Map<String, Object?> summary;

  /// 服务端历史文件名（`<ts>.json` 或 `<ts>-<n>.json`）。回滚时带上它，
  /// 同一秒内有多个版本时才能精确命中，而不是取该秒里的某一份。
  final String name;

  DateTime get writtenAt => DateTime.fromMillisecondsSinceEpoch(ts * 1000);

  String? get playerName {
    final name = summary['name'];
    return name is String && name.trim().isNotEmpty ? name.trim() : null;
  }
}
