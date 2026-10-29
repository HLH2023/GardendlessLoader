// Windows 显卡偏好的静态/模型验收（纯 Dart，本机可跑）。
//
// 为什么单独盯这一条：真正决定游戏用哪块显卡的是「进程启动前写进
// HKCU\...\DirectX\UserGpuPreferences 的值」，而 Windows 只在进程创建
// DXGI 设备时读一次。写早了/写晚了都会造成 Flutter 和 CEF 不在同一块卡上，
// 表现是游戏画面黑掉而不是报错。这些约束没法在 Linux 上跑起来验证，只能
// 把关键顺序和映射固化成断言，Windows 构建后再靠真机确认。
//
// 用法: dart run tool/check_gpu_preference.dart
import 'dart:convert';
import 'dart:io';

import 'package:gardendless_loader/src/services/app_settings_store.dart';
import 'package:gardendless_loader/src/services/gpu_adapter.dart';

int passed = 0;
int failed = 0;

void check(String name, bool ok, [Object? extra]) {
  if (ok) {
    passed++;
    stdout.writeln('  ok   $name${extra != null ? ' -> $extra' : ''}');
  } else {
    failed++;
    stdout.writeln('  FAIL $name${extra != null ? ' -> $extra' : ''}');
  }
}

String read(String path) => File(path).readAsStringSync();

/// 取一段源码里的函数体，用于验证某个函数没有做某件事。
String functionBody(String source, String signature, String nextSignature) {
  final start = source.indexOf(signature);
  if (start < 0) return '';
  final end = source.indexOf(nextSignature, start + signature.length);
  return source.substring(start, end < 0 ? source.length : end);
}

void main() {
  stdout.writeln('== 设置模型 ==');
  const defaults = AppSettings();
  check('默认不指定显卡', defaults.gpuPreference == GpuPreference.automatic);
  check('默认未完成首次询问', !defaults.gpuChoicePrompted);
  check(
    '未知枚举值回落 automatic',
    GpuPreference.fromName('something-else') == GpuPreference.automatic,
  );

  final configured = defaults.copyWith(
    gpuPreference: GpuPreference.highPerformance,
    gpuChoicePrompted: true,
  );
  final decoded = AppSettings.fromJson(
    jsonDecode(jsonEncode(configured.toJson())) as Map<String, dynamic>,
  );
  check(
    '显卡偏好写入并读回 JSON',
    decoded.gpuPreference == GpuPreference.highPerformance,
  );
  check('记住选择标记写入并读回 JSON', decoded.gpuChoicePrompted);

  stdout.writeln('== 适配器信息 ==');
  final high = GpuAdapterInfo.fromMap(<Object?, Object?>{
    'name': 'NVIDIA GeForce RTX 4060',
    'vendorId': 0x10de,
    'deviceId': 0x2882,
    'subSysId': 1,
    'revision': 2,
    'dedicatedVideoMemory': 8 * 1024 * 1024 * 1024,
    'luidHigh': 0,
    'luidLow': 1234,
    'software': false,
    'highPerformance': true,
    'minimumPower': false,
  });
  check('解析显卡名', high.name.contains('RTX 4060'));
  check('显存按 GB 展示', high.memoryLabel == '8.0 GB', high.memoryLabel);
  check('厂商名映射', high.vendorName == 'NVIDIA', high.vendorName);
  check('高性能标记', high.highPerformance && !high.minimumPower);

  final integrated = GpuAdapterInfo.fromMap(<Object?, Object?>{
    'name': 'AMD Radeon Graphics',
    'vendorId': 0x1002,
    'deviceId': 0x164e,
    'subSysId': 1,
    'revision': 1,
    'dedicatedVideoMemory': 512 * 1024 * 1024,
    'luidHigh': 0,
    'luidLow': 99,
    'software': false,
    'highPerformance': false,
    'minimumPower': true,
  });
  final adapters = <GpuAdapterInfo>[high, integrated];
  check(
    '默认选系统认定的高性能显卡',
    highPerformanceAdapter(adapters) == high,
  );
  check(
    '节能档选系统认定的核显',
    powerSavingAdapter(adapters) == integrated,
  );
  check('单卡没有节能档可问', powerSavingAdapter([high]) == null);
  check(
    '高性能目标就是系统认定的独显',
    targetAdapterFor(GpuPreference.highPerformance, adapters) == high,
  );
  check('automatic 没有明确目标卡',
      targetAdapterFor(GpuPreference.automatic, adapters) == null);
  check(
    '已在实际使用目标卡时不需要重启',
    activeMatchesPreference(
      preference: GpuPreference.highPerformance,
      adapters: adapters,
      active: high,
      currentPreference: GpuPreference.automatic,
    ),
  );
  check(
    '实际仍在核显时必须重启',
    !activeMatchesPreference(
      preference: GpuPreference.highPerformance,
      adapters: adapters,
      active: integrated,
      currentPreference: GpuPreference.highPerformance,
    ),
  );
  check(
    '查询不到实际卡时退回注册表值',
    activeMatchesPreference(
      preference: GpuPreference.powerSaving,
      adapters: adapters,
      active: null,
      currentPreference: GpuPreference.powerSaving,
    ),
  );

  stdout.writeln('== 原生写入时机 ==');
  final native = read('windows/runner/gpu_preference.cc');
  check(
    '高性能映射到 GpuPreference=2',
    RegExp(
      r'kHighPerformance:\s*return 2;',
      multiLine: true,
    ).hasMatch(native),
  );
  check(
    '节能映射到 GpuPreference=1',
    RegExp(
      r'kPowerSaving:\s*return 1;',
      multiLine: true,
    ).hasMatch(native),
  );
  final setBody = functionBody(
    native,
    'bool SetPreference(Preference preference, bool remember)',
    'void ApplyStartupPreference()',
  );
  check('选择时不直接改系统偏好（否则 CEF 会单独换卡）',
      setBody.isNotEmpty && !setBody.contains('ApplyUserGpuPreference('));
  check('一次性选择保存原值以便下次还原',
      setBody.contains('kPreviousValue') && setBody.contains('kRestoreValue'));
  final startupBody = functionBody(
    native,
    'void ApplyStartupPreference()',
    '}  // namespace gpu',
  );
  check(
    '启动钩子先消费 pending 再应用 remember',
    startupBody.contains('kPendingValue') &&
        startupBody.contains('kDesiredValue') &&
        startupBody.contains('kRestoreValue'),
  );

  final mainSource = read('windows/runner/main.cpp');
  final applyIndex = mainSource.indexOf('gpu::ApplyStartupPreference()');
  final windowIndex = mainSource.indexOf('FlutterWindow window(project);');
  check(
    '启动钩子在 Flutter 窗口创建之前',
    applyIndex >= 0 && windowIndex > applyIndex,
    '$applyIndex < $windowIndex',
  );

  stdout.writeln('== 通道与重启 ==');
  final windowSource = read('windows/runner/flutter_window.cpp');
  for (final method in <String>[
    '"listGpus"',
    '"getGpuPreference"',
    '"getActiveGpu"',
    '"setGpuPreference"',
    '"restart"',
  ]) {
    check('窗口通道处理 $method', windowSource.contains(method));
  }
  check(
    '设置页展示本进程实际使用的显卡',
    read('lib/src/ui/pages/settings_page.dart')
        .contains('gpuPreferenceActive(_active!.label)'),
  );
  check(
    '重启参数让新进程跳过选择框',
    windowSource.contains('--gpu-choice-done'),
  );
  check(
    'runner 把 --gpu-choice-done 传给 Dart',
    read('lib/main.dart').contains("widget.args.contains('--gpu-choice-done')"),
  );

  stdout.writeln('== UI 接线 ==');
  final home = read('lib/src/ui/home_page.dart');
  check('首次进游戏弹显卡选择', home.contains('showGpuChoiceDialog('));
  check('改卡后提示重启', home.contains('showGpuRestartDialog('));
  check(
    '选择框在 prepareDesktopGame 之前',
    home.indexOf('_ensureGpuChoiceBeforeLaunch()') <
        home.indexOf('prepareDesktopGame()'),
  );
  final settings = read('lib/src/ui/pages/settings_page.dart');
  check(
      '设置页提供显卡入口',
      settings.contains('_GpuPreferenceRow') &&
          settings.contains('showGpuChoiceDialog('));
  check(
    '设置页写入后不直接假设当前进程已换卡',
    settings.contains('showGpuRestartDialog('),
  );

  stdout.writeln('');
  stdout.writeln('结果：$passed 通过 / $failed 失败');
  if (failed > 0) exitCode = 1;
}
