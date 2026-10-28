import 'dart:io';

import 'package:flutter/services.dart';

import '../l10n/app_strings.dart';

enum LauncherShortcut {
  startGame,
  importResources;

  static LauncherShortcut? fromName(Object? value) {
    for (final shortcut in values) {
      if (shortcut.name == value) return shortcut;
    }
    return null;
  }
}

/// Home-screen shortcuts that open the launcher at a task.
class ShortcutService {
  ShortcutService() {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'perform') return;
      final shortcut = LauncherShortcut.fromName(call.arguments);
      if (shortcut != null) onShortcut?.call(shortcut);
    });
  }

  static const MethodChannel _channel = MethodChannel(
    'io.github.dey410.gardendlessloader/shortcuts',
  );

  /// Called when a shortcut is used while the launcher is running.
  void Function(LauncherShortcut shortcut)? onShortcut;

  /// The shortcut that started the launcher, if any; it is reported once.
  ///
  /// 桌面端没有 shortcuts 原生通道；以前这里会抛 MissingPluginException，
  /// 而调用点正好在初始化末尾，直接把启动判成失败（2026-10-27 Windows 实测）。
  Future<LauncherShortcut?> take() async {
    if (_isDesktop) return null;
    try {
      return LauncherShortcut.fromName(
        await _channel.invokeMethod<String>('take'),
      );
    } on MissingPluginException {
      return null;
    }
  }

  /// Titles the shortcuts in the launcher language. HarmonyOS has no dynamic
  /// shortcuts for apps; its shortcuts_config.json follows the system
  /// language instead.
  Future<void> publish(AppStrings strings) async {
    if (_isDesktop || Platform.operatingSystem == 'ohos') return;
    try {
      await _channel.invokeMethod<void>('setItems', <String, String>{
        LauncherShortcut.startGame.name: strings.startGame,
        LauncherShortcut.importResources.name: strings.importResources,
      });
    } on MissingPluginException {
      // 桌面端/未实现平台：没有桌面快捷方式可写，不影响启动。
    }
  }

  /// 桌面端（Windows/Linux/macOS）没有快捷方式原生实现。
  bool get _isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;
}
