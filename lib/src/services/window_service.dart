import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 桌面窗口能力（目前只有全屏）。
///
/// 为什么需要它：游戏在 CEF 的离屏渲染（贴图）里跑，HTML5 的
/// `requestFullscreen()` 在离屏模式下不会改变任何窗口状态，`webview_cef` 也没有
/// 全屏回调。因此游戏设置里的「全屏」以前点了没有任何效果——必须在宿主的 Win32
/// 窗口上真的做一次边框全屏。
///
/// 两个方向都要通：
///  - 游戏 → 宿主：注入脚本把 `requestFullscreen`/`exitFullscreen` 转成
///    `window.gardendlessDesktop` 通道消息，最终落到这里的 [setFullscreen]。
///  - 宿主 → 游戏：原生窗口还处理 F11，状态变化通过 `onFullscreenChanged`
///    推回来，再回灌给页面，界面按钮与游戏内状态才一致。
class WindowService {
  WindowService._();

  static final WindowService instance = WindowService._();

  static const MethodChannel _channel =
      MethodChannel('io.github.dey410.gardendlessloader/window');

  /// 当前是否处于边框全屏。原生侧是唯一事实源，这里只缓存最后已知值。
  final ValueNotifier<bool> fullscreen = ValueNotifier<bool>(false);

  /// 只有 Windows 有原生实现；其它平台静默降级（不抛 MissingPluginException）。
  bool get available => Platform.isWindows;

  bool _registered = false;

  /// 原生按键事件。
  ///
  /// 为什么需要这条通路：`webview_cef` 把 Win32 键盘消息转给 CEF 的
  /// `SendKeyEvent`，但在这套离屏渲染里 CEF 只把它发给
  /// `current_focused_browser_`，实测即使该值非空、`SetFocus(true)`、
  /// `document.hasFocus() === true`，页面依然收不到任何 keydown
  /// （2026-10-28 实机，B-74）。所以游戏页在前台时，由 runner 把按键
  /// 通过这个方法通道转给 Dart，再由 [DesktopGamePage] 注入的 JS 分发器
  /// 派发真实的 KeyboardEvent（见 `desktop_keyboard_script.dart`）。
  final StreamController<Map<String, Object?>> _keyEvents =
      StreamController<Map<String, Object?>>.broadcast();

  Stream<Map<String, Object?>> get keyEvents => _keyEvents.stream;

  /// 注册原生回调。必须在调用 [setFullscreen] 之前完成，否则 F11 推回来的
  /// 状态会没人接。
  void ensureRegistered() {
    if (!available || _registered) return;
    _registered = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onFullscreenChanged') {
        fullscreen.value = call.arguments == true;
      } else if (call.method == 'keyEvent') {
        final arguments = call.arguments;
        if (arguments is Map) {
          _keyEvents.add(
            arguments.map<String, Object?>(
              (key, value) => MapEntry('$key', value),
            ),
          );
        }
      }
      return null;
    });
  }

  Future<bool> isFullscreen() async {
    if (!available) return false;
    ensureRegistered();
    try {
      return await _channel.invokeMethod<bool>('isFullscreen') ??
          fullscreen.value;
    } on MissingPluginException {
      return fullscreen.value;
    } on PlatformException {
      return fullscreen.value;
    }
  }

  /// 请求切换全屏，返回**实际**生效的状态（窗口可能拒绝，例如显示器异常）。
  Future<bool> setFullscreen(bool value) async {
    if (!available) return false;
    ensureRegistered();
    try {
      final applied = await _channel.invokeMethod<bool>('setFullscreen', value);
      fullscreen.value = applied ?? value;
    } on MissingPluginException {
      // 旧版 runner 没注册这个通道：当作不支持，不要打断游戏。
      return false;
    } on PlatformException {
      return fullscreen.value;
    }
    return fullscreen.value;
  }

  Future<bool> toggle() => setFullscreen(!fullscreen.value);

  /// 打开/关闭原生按键转发。只有游戏页在前台时才该打开：加载器自己的界面
  /// 不需要它，关掉可以少一次跨平台调用。
  Future<void> setKeyForwarding(bool enabled) async {
    if (!available) return;
    ensureRegistered();
    try {
      await _channel.invokeMethod<void>('setKeyForwarding', enabled);
    } on MissingPluginException {
      // 旧版 runner 没有这个能力：游戏页的键盘就维持原样，不抛异常。
    } on PlatformException {
      // 同上，转发是增强能力，失败不该影响游戏启动。
    }
  }

  /// 请求正常退出（关闭主窗口，让 runner 自己走完消息循环）。
  ///
  /// 为什么不让调用方直接 `exit(0)`：硬终止时 CEF 的线程还在跑，CRT teardown
  /// 会 fail-fast（`0xc0000409` / ucrtbase.dll，2026-10-27 用户实测），
  /// 事件日志里就是一条「加载器崩溃」。
  ///
  /// 返回原生是否接受了请求；false 表示这个通道不存在（旧版 runner）。
  Future<bool> quit() async {
    if (!available) return false;
    try {
      await _channel.invokeMethod<void>('quit');
      return true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
