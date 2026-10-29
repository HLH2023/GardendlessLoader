import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'gpu_adapter.dart';

/// Windows 显卡偏好与 GPU 枚举。
///
/// 为什么不在 Dart 里直接读注册表/跑 PowerShell：
///  * 需要 DXGI 枚举出真实的适配器名、显存和 Windows 认定的高性能/节能档；
///  * 写 `UserGpuPreferences` 要保留同一字符串里的其它字段（例如驱动的
///    `SwapEffectUpgradeEnable`），用 `reg.exe` 做拼接容易把别人的设置覆盖掉。
///
/// 原生实现见 `windows/runner/gpu_preference.cc`，通道复用窗口通道。
class GpuPreferenceService {
  GpuPreferenceService._();

  static final GpuPreferenceService instance = GpuPreferenceService._();

  static const MethodChannel _channel =
      MethodChannel('io.github.dey410.gardendlessloader/window');

  bool get available => Platform.isWindows;

  Future<List<GpuAdapterInfo>> listAdapters() async {
    if (!available) return const [];
    try {
      final result = await _channel.invokeMethod<Object?>('listGpus');
      if (result is! List) return const [];
      return result
          .whereType<Map>()
          .map((map) => GpuAdapterInfo.fromMap(map.cast<Object?, Object?>()))
          .toList(growable: false);
    } on MissingPluginException {
      return const [];
    } on PlatformException catch (error) {
      debugPrint('[gpu] listGpus failed: ${error.message}');
      return const [];
    }
  }

  /// 当前进程按默认适配器创建 D3D11 设备时实际拿到的那块显卡。
  /// 只用于设置页展示/排查「重启后有没有换过去」；失败返回 null。
  Future<GpuAdapterInfo?> activeAdapter() async {
    if (!available) return null;
    try {
      final result = await _channel.invokeMethod<Object?>('getActiveGpu');
      if (result is Map) {
        final adapter = GpuAdapterInfo.fromMap(result.cast<Object?, Object?>());
        return adapter.name.isEmpty ? null : adapter;
      }
      return null;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// 当前 exe 在 Windows 里**实际生效**的偏好；没有设置时是 automatic。
  Future<GpuPreference> currentPreference() async {
    if (!available) return GpuPreference.automatic;
    try {
      final name = await _channel.invokeMethod<String>('getGpuPreference');
      return GpuPreference.fromName(name);
    } on MissingPluginException {
      return GpuPreference.automatic;
    } on PlatformException {
      return GpuPreference.automatic;
    }
  }

  /// 写入系统偏好。`remember=false` 时只对下一次启动生效，再下次启动
  /// 会还原成选择前的值（由原生启动钩子处理）。
  Future<bool> setPreference(
    GpuPreference preference, {
    required bool remember,
  }) async {
    if (!available) return false;
    try {
      final applied = await _channel.invokeMethod<bool>(
        'setGpuPreference',
        <String, Object?>{
          'preference': preference.wireName,
          'remember': remember,
        },
      );
      return applied ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (error) {
      debugPrint('[gpu] setGpuPreference failed: ${error.message}');
      return false;
    }
  }

  /// 重启加载器。显卡偏好要等新进程创建 DXGI 设备时才生效，换个进程是
  /// 唯一不改 CEF 源码的办法；新进程带 `--gpu-choice-done`，不会重复提问。
  Future<bool> restart() async {
    if (!available) return false;
    try {
      await _channel.invokeMethod<void>('restart');
      return true;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (error) {
      debugPrint('[gpu] restart failed: ${error.message}');
      return false;
    }
  }

  /// 启动后补写一遍浏览器进程记住的偏好：安装目录变化后，旧 exe 路径的
  /// 注册表项不会自动迁移；这里只是为**下一次**启动修复。
  Future<void> syncRemembered(GpuPreference preference) async {
    if (!available) return;
    await setPreference(preference, remember: true);
  }
}
