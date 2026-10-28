import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:webview_cef/webview_cef.dart';

import '../../l10n/app_strings.dart';
import '../../services/desktop_fullscreen_script.dart';
import '../../services/desktop_keyboard_script.dart';
import '../../services/local_resource_server.dart';
import '../../services/window_service.dart';
import '../theme/garden_theme.dart';

/// 桌面端游戏窗口：进程内 WebView(CEF) 加载本地服务器地址。
///
/// 为什么走本地服务器而不是直接开浏览器：游戏需要 document-start 注入存档桥，
/// 而桥需要同一 origin 才能避免 CORS；本地服务器同时承担 HTML 注入与资源
/// 流式返回，Android 的原生宿主则各自实现同一份契约。
///
/// 仅桌面端使用；Android 走原生 GameActivity。
class DesktopGamePage extends StatefulWidget {
  const DesktopGamePage({
    super.key,
    required this.launch,
    required this.onClosed,
  });

  final DesktopGameLaunch launch;
  final Future<void> Function() onClosed;

  @override
  State<DesktopGamePage> createState() => _DesktopGamePageState();
}

class _DesktopGamePageState extends State<DesktopGamePage> {
  /// 注入脚本转发的通道名，必须与 [desktopFullscreenScript] 里的一致。
  static const String _desktopChannelName = 'gardendlessDesktop';

  WebViewController? _controller;
  StreamSubscription<Map<String, Object?>>? _keySubscription;
  bool _ready = false;
  String? _error;
  bool _toolbarVisible = false;
  bool _fullscreen = false;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    WindowService.instance.ensureRegistered();
    WindowService.instance.fullscreen.addListener(_onFullscreenChanged);
    _fullscreen = WindowService.instance.fullscreen.value;
    // 原生按键：只收宿主自己的快捷键（F10 工具条）。游戏按键走 CEF 原生通路。
    _keySubscription = WindowService.instance.keyEvents.listen(_onNativeKey);
    unawaited(WindowService.instance.setKeyForwarding(true));
    _start();
  }

  Future<void> _start() async {
    _bridgeLog('start origin=${widget.launch.uri.origin}');
    try {
      // WebviewManager 全进程初始化一次即可
      await WebviewManager().initialize();
      if (!mounted) return;
      final controller = WebviewManager().createWebView(
        loading: const Center(child: CircularProgressIndicator()),
      );
      controller.setWebviewListener(
        WebviewEventsListener(
          onLoadEnd: (_, urlId) {
            _bridgeLog('loadEnd $urlId');
            if (!mounted) return;
            setState(() => _ready = true);
            // 全屏桥要在页面脚本之后、用户点「全屏」之前装好；重新加载会
            // 清掉 JS 通道，所以每次加载完成都重装一次。
            unawaited(_installFullscreenBridge(controller));
            unawaited(_reinstallKeyboardLater(controller));
          },
          onConsoleMessage: (level, message, source, line) {
            // 游戏侧报错只记日志，不弹 UI：控制台噪音太多
            debugPrint('[cef:$level] $message ($source:$line)');
            // CEF 日志级别 3 起是 error，只留这些，避免日志被游戏噪音淹没
            if (level >= 3) {
              _bridgeLog('console $level: $message ($source:$line)');
            }
          },
        ),
      );
      await controller.initialize(widget.launch.uri.toString());
      _bridgeLog('controller initialized');
      if (!mounted) {
        controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _ready = true;
      });
      await _installFullscreenBridge(controller);
      unawaited(_retryBridge(controller));
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    }
  }

  /// 装桌面桥：JS 通道 + DOM 全屏 API 改写 + 键盘焦点引导。
  ///
  /// 只有 Windows 有原生窗口实现；其它桌面平台跳过，保持原有行为，
  /// 不给自己造一个「点了没反应」的新假象。
  Future<void> _installFullscreenBridge(WebViewController controller) async {
    _bridgeLog('bridge enter available=${WindowService.instance.available}');
    if (!WindowService.instance.available) return;
    try {
      await controller.setJavaScriptChannels(<JavascriptChannel>{
        JavascriptChannel(
          name: _desktopChannelName,
          onMessageReceived: _onDesktopMessage,
        ),
      });
      _bridgeLog('channels ok');
      // Flutter 这边的 Focus 节点拿不到焦点（primaryFocus 为 null），
      // webview_cef 的 Focus.onFocusChange 因此不会调 setClientFocus；
      // 而 CEF 收键盘的前提是宿主告诉它「你有焦点」。必须先于下面的 DOM
      // 聚焦：浏览器还没拿到焦点时，渲染进程可能不上报 focusednode，
      // 探针就白聚焦了（hlh.31 复发的时序问题之一）。
      await controller.setClientFocus(true);
      _bridgeLog('clientFocus ok');
      await controller.executeJavaScript(desktopFullscreenScript);
      _bridgeLog('fullscreen script ok');
      // 单独注入：它只做一件事——让 CEF 上报一次焦点节点变化，否则插件的
      // sendKeyEvent 永远找不到「当前浏览器」。
      await controller.executeJavaScript(desktopKeyboardScript);
      _bridgeLog('keyboard script ok');
    } catch (error) {
      // 桥装不上只是没有全屏，不该影响游戏本身
      _bridgeLog('bridge failed: $error');
      debugPrint('[desktop] bridge install failed: $error');
    }
  }

  /// 注入重试：`initialize()` 可能比页面创建/导航更早返回，首轮的
  /// `executeJavaScript` 会落在旧文档或被插件静默丢掉（browser_map 里还
  /// 没有这个 id）。桌面端没有别的可观测入口，先按固定间隔补几次；
  /// 脚本本身是幂等的，已经引导过的页面不会重复抢焦点。
  Future<void> _retryBridge(WebViewController controller) async {
    for (final seconds in const [1, 3, 6]) {
      await Future<void>.delayed(Duration(seconds: seconds));
      if (!mounted) return;
      _bridgeLog('retry +${seconds}s');
      await _installFullscreenBridge(controller);
    }
  }

  /// 游戏引擎启动完成后还会自己动一次焦点（把焦点交给画布）。如果首轮
  /// 注入正好落在 HTML 解析中，探针的焦点会被覆盖，而 `SendKeyEvent` 又
  /// 依赖那次焦点上报。加载完成 1.2s 后再注入一次：脚本只在「从未聚焦
  /// 成功」时才补焦，已经引导过的页面不会被反复抢焦点。
  Future<void> _reinstallKeyboardLater(WebViewController controller) async {
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    if (!mounted) return;
    _bridgeLog('reinstall begin');
    try {
      await controller.executeJavaScript(desktopKeyboardScript);
      // 这一下强制 blur+focus 一次：如果首轮聚焦时浏览器还没拿到客户端
      // 焦点，渲染进程不会上报 focusednode；1.2s 后窗口已经就位，补一次
      // 一定能把「当前浏览器」建立起来（每次加载只做一次）。
      await controller.executeJavaScript(
        'window.__gardendlessKeyboardNudge&&window.__gardendlessKeyboardNudge()',
      );
    } catch (_) {
      // 页面已跳走/正在加载：下一次 loadEnd 会重新装
    }
  }

  /// 键盘引导的状态留痕。桌面端只能靠真实机器复现；出问题时先看
  /// `keyboard.log`（每次进游戏最多 6 行：安装状态 + 前 5 个 keydown）。
  Future<void> _logKeyboardState(Map<String, Object?> payload) async {
    _bridgeLog('keyboard state $payload');
    try {
      final directory = await getApplicationSupportDirectory();
      final file = File(p.join(directory.path, 'keyboard.log'));
      final line = '${DateTime.now().toIso8601String()} '
          'kind=${payload['kind']} installed=${payload['installed']} '
          'primed=${payload['primed']} active=${payload['active']} '
          'ready=${payload['readyState']} key=${payload['key']}\n';
      await file.writeAsString(line, mode: FileMode.append, flush: true);
      if (await file.length() > 64 * 1024) {
        final lines = await file.readAsLines();
        await file.writeAsString(
          '${lines.skip(lines.length - 100).join('\n')}\n',
        );
      }
    } catch (_) {
      // 诊断写盘失败不能影响游戏
    }
  }

  /// runner 只转发宿主自己的快捷键（目前只有 F10 的工具条显隐），
  /// 其余按键走 CEF 的原生键盘通路，不经过这里。
  void _onNativeKey(Map<String, Object?> event) {
    if (event['type'] != 'keydown') return;
    if (event['virtualKey'] != 0x79) return; // VK_F10
    if (!mounted) return;
    setState(() => _toolbarVisible = !_toolbarVisible);
  }

  /// 桌面桥诊断日志：出问题时先看这份文件，不用再猜注入跑没跑、通道通不通。
  /// 与 app_settings.json 同目录（%APPDATA%\io.github.dey410\gardendless_loader\
  /// GardendlessLoader），只在桌面游戏页写，一次进游戏几十行；超过 256 KB 清空。
  void _bridgeLog(String message) {
    try {
      final appData = Platform.environment['APPDATA'];
      final directory = appData == null || appData.isEmpty
          ? Directory.systemTemp
          : Directory(p.join(appData, 'io.github.dey410', 'gardendless_loader',
              'GardendlessLoader'));
      if (!directory.existsSync()) directory.createSync(recursive: true);
      final file = File(p.join(directory.path, 'desktop_bridge.log'));
      if (file.existsSync() && file.lengthSync() > 256 * 1024) {
        file.writeAsStringSync('', flush: true);
      }
      file.writeAsStringSync(
        '${DateTime.now().toIso8601String()} $message\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // 诊断写盘失败不能影响游戏
    }
  }

  void _onDesktopMessage(JavascriptMessage message) {
    _bridgeLog(
        'message ${message.message.length > 200 ? '${message.message.substring(0, 200)}…' : message.message}');
    Map<String, Object?> payload;
    try {
      final decoded = jsonDecode(message.message);
      if (decoded is! Map) return;
      payload = decoded.cast<String, Object?>();
    } catch (_) {
      return;
    }
    if (payload['command'] == 'keyboard:state') {
      unawaited(_logKeyboardState(payload));
      return;
    }
    if (payload['command'] == 'window:closeGame') {
      // 游戏内的退出：走和加载器「返回」按钮同一条收尾路径（停本地服务器、
      // 注销会话、回首页），不要让它去销毁 CEF 浏览器。
      unawaited(_exit());
      return;
    }
    if (payload['command'] != 'window:setFullscreen') return;
    final requested = payload['fullscreen'] == true;
    unawaited(_setFullscreen(requested));
  }

  Future<void> _setFullscreen(bool value) async {
    final applied = await WindowService.instance.setFullscreen(value);
    if (!mounted) return;
    setState(() => _fullscreen = applied);
    await _pushFullscreenState(applied);
  }

  /// 把真实状态回灌给页面：F11 是原生处理的，页面那边不会经过
  /// `requestFullscreen`，不推的话游戏会以为还在窗口模式。
  Future<void> _pushFullscreenState(bool value) async {
    final controller = _controller;
    if (controller == null) return;
    try {
      await controller.executeJavaScript(
        'window.__gardendlessFullscreen&&window.__gardendlessFullscreen.apply($value)',
      );
    } catch (_) {
      // 页面已跳走/正在加载：下一次注入会重新对齐
    }
  }

  void _onFullscreenChanged() {
    final value = WindowService.instance.fullscreen.value;
    if (!mounted) return;
    if (value != _fullscreen) setState(() => _fullscreen = value);
    unawaited(_pushFullscreenState(value));
  }

  @override
  void dispose() {
    unawaited(WindowService.instance.setKeyForwarding(false));
    _keySubscription?.cancel();
    _keySubscription = null;
    WindowService.instance.fullscreen.removeListener(_onFullscreenChanged);
    // 退出游戏时必须还原窗口：否则回到加载器还是一片无边框全屏，
    // 用户会以为界面坏了。
    if (_fullscreen) unawaited(WindowService.instance.setFullscreen(false));
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _exit() async {
    // 收尾（停服务器/注销会话）失败也必须能退出：卡在游戏页出不来更糟。
    // 页面可能重复触发（游戏退出 + 用户点返回），只跑一次。
    if (_closing) return;
    _closing = true;
    try {
      await widget.onClosed();
    } finally {
      if (mounted) Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.garden;
    final strings = context.strings;
    final controller = _controller;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _exit();
      },
      child: Scaffold(
        backgroundColor: palette.background,
        body: SafeArea(
          child: Stack(
            children: [
              Positioned.fill(child: _body(controller, strings)),
              // 工具条只在按 F10 时出现：以前做成顶部热区，鼠标一划过就弹出一条
              // 「像浏览器」的栏，还正好挡住游戏顶部的卡片，用户明确要求不要。
              // F10 是游戏自己忽略的键（KeyListener 里是空分支），拿来做显隐
              // 开关不会和游戏抢。
              if (_toolbarVisible)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: _toolbar(palette, strings, controller),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(WebViewController? controller, AppStrings strings) {
    final error = _error;
    if (error != null) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 40),
              const SizedBox(height: 12),
              Text(strings.cannotStartGame(error), textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                  onPressed: _exit, child: Text(strings.storageCancel)),
            ],
          ),
        ),
      );
    }
    if (controller == null || !_ready) {
      return const Center(child: CircularProgressIndicator());
    }
    return controller.webviewWidget;
  }

  Widget _toolbar(GardenPalette palette, AppStrings strings,
      WebViewController? controller) {
    final launch = widget.launch;
    final canFullscreen = WindowService.instance.available;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: palette.surface.withValues(alpha: 0.94),
      child: Row(
        children: [
          IconButton(
            tooltip: strings.storageCancel,
            onPressed: _exit,
            icon: const Icon(Icons.arrow_back),
          ),
          IconButton(
            tooltip: strings.storageRefresh,
            onPressed: () => controller?.reload(),
            icon: const Icon(Icons.refresh),
          ),
          if (canFullscreen)
            IconButton(
              tooltip: _fullscreen
                  ? strings.exitFullscreen
                  : strings.enterFullscreen,
              onPressed: () => unawaited(_setFullscreen(!_fullscreen)),
              icon:
                  Icon(_fullscreen ? Icons.fullscreen_exit : Icons.fullscreen),
            ),
          const SizedBox(width: 8),
          if (!launch.hasCloudSaves)
            Text(
              strings.cloudSavesOffHint,
              style: TextStyle(color: palette.inkMuted, fontSize: 11.5),
            ),
          const Spacer(),
          Text(
            launch.uri.toString(),
            style: TextStyle(color: palette.inkMuted, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

/// 桌面端是否受支持（Android 走原生宿主）。
bool get desktopGameHostAvailable =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;
