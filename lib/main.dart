import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'src/app_controller.dart';
import 'src/l10n/app_strings.dart';
import 'src/logging/app_logger.dart';
import 'src/logging/log_event_catalog.dart';
import 'src/logging/native_app_logger.dart';
import 'src/services/app_settings_store.dart';
import 'src/ui/home_page.dart';
import 'src/ui/theme/garden_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 日志是诊断设施，不是启动前置条件。任何初始化失败都必须降级继续：
  // Windows 没有原生日志实现，直接抛异常会让 runApp 永远不执行。
  AppLogger logger;
  try {
    logger = await NativeAppLogger.initialize(
      eventSchemas: defaultLogEventSchemas,
    );
  } catch (error, stackTrace) {
    logger = InMemoryAppLogger(
      appSessionId: 'local-'
          '${DateTime.now().toUtc().microsecondsSinceEpoch.toRadixString(16)}',
    );
    logger.emit(
      level: LogLevel.fatal,
      category: 'app.logging',
      event: 'native_logger_unavailable',
      outcome: LogOutcome.degraded,
      code: 'logger_init_failed',
      error: error,
      stackTrace: stackTrace,
    );
  }
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    logger.emit(
      level: LogLevel.error,
      category: 'app.flutter',
      event: 'flutter_framework_error',
      outcome: LogOutcome.failed,
      code: 'flutter_framework_error',
      error: details.exception,
      stackTrace: details.stack,
    );
  };
  PlatformDispatcher.instance.onError = (error, stackTrace) {
    logger.emit(
      level: LogLevel.fatal,
      category: 'app.dart',
      event: 'dart_unhandled_error',
      outcome: LogOutcome.failed,
      code: 'dart_unhandled_error',
      error: error,
      stackTrace: stackTrace,
    );
    return true;
  };
  unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));
  unawaited(SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]));
  runZonedGuarded(
    () => runApp(GardendlessLoaderApp(logger: logger)),
    (error, stackTrace) => logger.emit(
      level: LogLevel.fatal,
      category: 'app.dart',
      event: 'dart_unhandled_error',
      outcome: LogOutcome.failed,
      code: 'dart_unhandled_error',
      error: error,
      stackTrace: stackTrace,
    ),
  );
}

class GardendlessLoaderApp extends StatefulWidget {
  const GardendlessLoaderApp({required this.logger, super.key});

  final AppLogger logger;

  @override
  State<GardendlessLoaderApp> createState() => _GardendlessLoaderAppState();
}

class _GardendlessLoaderAppState extends State<GardendlessLoaderApp>
    with WidgetsBindingObserver {
  late final AppController _controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = AppController(appLogger: widget.logger);
    unawaited(_controller.initialize().then((_) {
      if (mounted && _controller.initialized) {
        unawaited(_controller.refreshAboutContent());
        unawaited(_controller.refreshAnnouncement());
      }
    }));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeLocales(List<Locale>? locales) {
    _controller.systemLocalesChanged();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    widget.logger.emit(
      level: LogLevel.info,
      category: 'app.lifecycle',
      event: 'app_lifecycle_changed',
      outcome: LogOutcome.observed,
      context: <String, Object?>{'state': state.name},
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, home) => MaterialApp(
        title: 'GardendlessLoader',
        debugShowCheckedModeBanner: false,
        theme: buildGardenTheme(
          Brightness.light,
          accent: switch (_controller.seasonalTheme) {
            final theme? => Color(theme.accent),
            null => null,
          },
        ),
        darkTheme: buildGardenTheme(
          Brightness.dark,
          accent: switch (_controller.seasonalTheme) {
            final theme? => Color(theme.accentDark ?? theme.accent),
            null => null,
          },
        ),
        themeMode: switch (_controller.themePreference) {
          ThemePreference.system => ThemeMode.system,
          ThemePreference.light => ThemeMode.light,
          ThemePreference.dark => ThemeMode.dark,
        },
        locale: AppStrings.current.locale,
        supportedLocales: AppStrings.supportedLocales,
        localizationsDelegates: const [
          AppStrings.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: home,
      ),
      child: HomePage(controller: _controller),
    );
  }
}
