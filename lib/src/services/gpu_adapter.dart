/// Windows 图形性能首选项的三档取值。
///
/// 注意：系统只允许按「高性能 / 节能」分类，不能直接指定第三块显卡。
/// 这与 `HKCU\Software\Microsoft\DirectX\UserGpuPreferences` 的
/// `GpuPreference=2/1` 一一对应；枚举名会原样写进设置 JSON 和注册表。
enum GpuPreference {
  automatic('automatic'),
  highPerformance('highPerformance'),
  powerSaving('powerSaving');

  const GpuPreference(this.wireName);

  final String wireName;

  static GpuPreference fromName(Object? value) {
    return GpuPreference.values.firstWhere(
      (preference) => preference.wireName == value,
      orElse: () => GpuPreference.automatic,
    );
  }
}

/// 一块由 DXGI 枚举出来的显卡。只用于设置页/首次选择弹窗的展示。
class GpuAdapterInfo {
  const GpuAdapterInfo({
    required this.name,
    required this.vendorId,
    required this.deviceId,
    required this.subSysId,
    required this.revision,
    required this.dedicatedVideoMemory,
    required this.luidHigh,
    required this.luidLow,
    required this.software,
    required this.highPerformance,
    required this.minimumPower,
  });

  factory GpuAdapterInfo.fromMap(Map<Object?, Object?> map) {
    int readInt(String key) {
      final value = map[key];
      return value is num ? value.toInt() : 0;
    }

    bool readBool(String key) => map[key] == true;

    return GpuAdapterInfo(
      name: map['name'] is String ? map['name']! as String : 'Unknown GPU',
      vendorId: readInt('vendorId'),
      deviceId: readInt('deviceId'),
      subSysId: readInt('subSysId'),
      revision: readInt('revision'),
      dedicatedVideoMemory: readInt('dedicatedVideoMemory'),
      luidHigh: readInt('luidHigh'),
      luidLow: readInt('luidLow'),
      software: readBool('software'),
      highPerformance: readBool('highPerformance'),
      minimumPower: readBool('minimumPower'),
    );
  }

  final String name;
  final int vendorId;
  final int deviceId;
  final int subSysId;
  final int revision;
  final int dedicatedVideoMemory;
  final int luidHigh;
  final int luidLow;
  final bool software;
  final bool highPerformance;
  final bool minimumPower;

  /// 显存只用于展示；小于 1 GB 时按 MB 显示，避免出现 0.1 GB。
  String get memoryLabel {
    if (dedicatedVideoMemory <= 0) return '';
    const gigabyte = 1024 * 1024 * 1024;
    if (dedicatedVideoMemory >= gigabyte) {
      return '${(dedicatedVideoMemory / gigabyte).toStringAsFixed(1)} GB';
    }
    return '${(dedicatedVideoMemory / (1024 * 1024)).round()} MB';
  }

  String get vendorName => switch (vendorId) {
        0x10de => 'NVIDIA',
        0x1002 => 'AMD',
        0x8086 => 'Intel',
        0x1414 => 'Microsoft',
        _ => 'GPU',
      };

  /// 设置页显示用：`NVIDIA GeForce ... · 8.0 GB`。
  String get label => memoryLabel.isEmpty ? name : '$name · $memoryLabel';

  @override
  bool operator ==(Object other) =>
      other is GpuAdapterInfo &&
      other.vendorId == vendorId &&
      other.deviceId == deviceId &&
      other.subSysId == subSysId &&
      other.revision == revision &&
      other.name == name;

  @override
  int get hashCode => Object.hash(vendorId, deviceId, subSysId, revision, name);
}

/// 系统认定的高性能显卡；没有标记时退回枚举列表第一项。
GpuAdapterInfo? highPerformanceAdapter(List<GpuAdapterInfo> adapters) {
  for (final adapter in adapters) {
    if (adapter.highPerformance) return adapter;
  }
  return adapters.isEmpty ? null : adapters.first;
}

/// 系统认定的节能显卡；单卡机器返回 null（没有可选的第二档）。
GpuAdapterInfo? powerSavingAdapter(List<GpuAdapterInfo> adapters) {
  for (final adapter in adapters) {
    if (adapter.minimumPower) return adapter;
  }
  return adapters.length > 1 ? adapters.last : null;
}

/// 某个偏好对应的目标显卡；automatic 没有明确目标（由 Windows 决定）。
GpuAdapterInfo? targetAdapterFor(
  GpuPreference preference,
  List<GpuAdapterInfo> adapters,
) {
  return switch (preference) {
    GpuPreference.automatic => null,
    GpuPreference.highPerformance => highPerformanceAdapter(adapters),
    GpuPreference.powerSaving => powerSavingAdapter(adapters),
  };
}

/// 当前进程实际拿到的显卡是否已经是所选偏好对应的卡。
///
/// `active == null`（查询失败）时退回注册表值的比较；`automatic` 没有
/// 目标卡，只能看注册表里是否已经是 automatic。
bool activeMatchesPreference({
  required GpuPreference preference,
  required List<GpuAdapterInfo> adapters,
  required GpuAdapterInfo? active,
  required GpuPreference currentPreference,
}) {
  final target = targetAdapterFor(preference, adapters);
  if (target == null || active == null) return currentPreference == preference;
  return active.name == target.name &&
      active.vendorId == target.vendorId &&
      active.deviceId == target.deviceId;
}
