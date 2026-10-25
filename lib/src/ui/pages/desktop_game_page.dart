import 'dart:io';

import 'package:flutter/material.dart';
import 'package:webview_cef/webview_cef.dart';

import '../../l10n/app_strings.dart';
import '../../services/local_resource_server.dart';
import '../theme/garden_theme.dart';

/// 桌面端游戏窗口：进程内 WebView(CEF) 加载本地服务器地址。
///
/// 为什么走本地服务器而不是直接开浏览器：游戏需要 document-start 注入存档桥，
/// 而桥需要同一 origin 才能避免 CORS；本地服务器同时服务「本地资源包」与
/// 「在线反代」，因此两种形态共用这一套窗口与存档通路。
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
  WebViewController? _controller;
  bool _ready = false;
  String? _error;
  bool _toolbarVisible = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      // WebviewManager 全进程初始化一次即可
      await WebviewManager().initialize();
      if (!mounted) return;
      final controller = WebviewManager().createWebView(
        loading: const Center(child: CircularProgressIndicator()),
      );
      controller.setWebviewListener(
        WebviewEventsListener(
          onLoadEnd: (_, __) {
            if (mounted) setState(() => _ready = true);
          },
          onConsoleMessage: (level, message, source, line) {
            // 游戏侧报错只记日志，不弹 UI：控制台噪音太多
            debugPrint('[cef:$level] $message ($source:$line)');
          },
        ),
      );
      await controller.initialize(widget.launch.uri.toString());
      if (!mounted) {
        controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _ready = true;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _exit() async {
    await widget.onClosed();
    if (mounted) Navigator.of(context).maybePop();
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
              // 顶部热区：鼠标移上来才显示工具条，避免遮住游戏画面
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: MouseRegion(
                  onEnter: (_) => setState(() => _toolbarVisible = true),
                  onExit: (_) => setState(() => _toolbarVisible = false),
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 150),
                    opacity: _toolbarVisible ? 1 : 0,
                    child: IgnorePointer(
                      ignoring: !_toolbarVisible,
                      child: _toolbar(palette, strings, controller),
                    ),
                  ),
                ),
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
              FilledButton(onPressed: _exit, child: Text(strings.storageCancel)),
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

  Widget _toolbar(GardenPalette palette, AppStrings strings, WebViewController? controller) {
    final launch = widget.launch;
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
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              border: Border.all(color: palette.border),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              launch.mode == DesktopPlayMode.online
                  ? strings.playModeOnline
                  : strings.playModeLocal,
              style: TextStyle(color: palette.inkMuted, fontSize: 11),
            ),
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
