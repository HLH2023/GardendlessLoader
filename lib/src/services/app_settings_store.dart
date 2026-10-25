import 'dart:convert';
import 'dart:io';

import '../constants.dart';
import '../game_host/game_host.dart';

/// 两种游玩形态，存档通路完全一致（同一个本地服务器 + 同一份存档桥）。
enum PlayMode {
  /// 本地资源包：资源已下载并解包到磁盘，完全离线可玩。
  local,

  /// 在线：启动器反代服务器上的游戏页，不占本地磁盘。
  online;

  static PlayMode fromName(Object? value) {
    return PlayMode.values.firstWhere(
      (mode) => mode.name == value,
      orElse: () => PlayMode.local,
    );
  }
}

enum ThemePreference {
  system,
  light,
  dark;

  static ThemePreference fromName(Object? value) {
    return ThemePreference.values.firstWhere(
      (preference) => preference.name == value,
      orElse: () => ThemePreference.system,
    );
  }
}

enum LanguagePreference {
  system,
  chinese,
  english;

  static LanguagePreference fromName(Object? value) {
    return LanguagePreference.values.firstWhere(
      (preference) => preference.name == value,
      orElse: () => LanguagePreference.system,
    );
  }
}

/// Renders the game at a share of the device's native resolution; a lower
/// share shrinks the game canvas and its GPU memory at the cost of sharpness.
enum RenderResolution {
  full(null),
  medium(0.75),
  low(0.5);

  const RenderResolution(this.scale);

  /// Share of the device pixel ratio the game renders at; null is native.
  final double? scale;

  static RenderResolution fromName(Object? value) {
    return RenderResolution.values.firstWhere(
      (resolution) => resolution.name == value,
      orElse: () => RenderResolution.full,
    );
  }
}

class AppSettings {
  const AppSettings({
    this.watermarkEnabled = true,
    this.quickLaunchEnabled = false,
    this.renderResolution = RenderResolution.full,
    this.screenFit = ScreenFit.balanced,
    this.detailedAudioDiagnosticsEnabled = false,
    this.themePreference = ThemePreference.system,
    this.reduceMotion = false,
    this.languagePreference = LanguagePreference.system,
    this.seenAnnouncementId,
    this.toolShedUnlocked = false,
    this.touchDiagnosticsEnabled = false,
    this.gestureHintShown = false,
    this.serverBaseUrl = kDefaultServerBase,
    this.deviceToken = '',
    this.deviceAccount = '',
    this.playMode = PlayMode.local,
  });

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    return AppSettings(
      watermarkEnabled: json['watermarkEnabled'] as bool? ?? true,
      quickLaunchEnabled: json['quickLaunchEnabled'] as bool? ?? false,
      renderResolution: RenderResolution.fromName(json['renderResolution']),
      screenFit: ScreenFit.fromName(json['screenFit']),
      detailedAudioDiagnosticsEnabled:
          json['detailedAudioDiagnosticsEnabled'] as bool? ?? false,
      themePreference: ThemePreference.fromName(json['themePreference']),
      reduceMotion: json['reduceMotion'] as bool? ?? false,
      languagePreference:
          LanguagePreference.fromName(json['languagePreference']),
      seenAnnouncementId: json['seenAnnouncementId'] as String?,
      toolShedUnlocked: json['toolShedUnlocked'] as bool? ?? false,
      touchDiagnosticsEnabled:
          json['touchDiagnosticsEnabled'] as bool? ?? false,
      gestureHintShown: json['gestureHintShown'] as bool? ?? false,
      serverBaseUrl: _readBaseUrl(json['serverBaseUrl']),
      playMode: PlayMode.fromName(json['playMode']),
      deviceToken: (json['deviceToken'] as String? ?? '').trim(),
      deviceAccount: (json['deviceAccount'] as String? ?? '').trim(),
    );
  }

  final bool watermarkEnabled;

  /// Opens the game directly on a cold start instead of the launcher.
  final bool quickLaunchEnabled;
  final RenderResolution renderResolution;
  final ScreenFit screenFit;
  final bool detailedAudioDiagnosticsEnabled;
  final ThemePreference themePreference;
  final bool reduceMotion;
  final LanguagePreference languagePreference;

  /// Id of the last announcement shown to the user, so a new one pops up
  /// once and an old one never again.
  final String? seenAnnouncementId;

  /// The tool shed found by tapping the launcher icon seven times.
  final bool toolShedUnlocked;

  /// Records the touch trace on the next launch; only while the tool shed is
  /// unlocked.
  final bool touchDiagnosticsEnabled;

  /// The gesture hint shows over the game once, on the first launch.
  final bool gestureHintShown;

  /// Where the save server lives: device tokens, cloud saves and the
  /// resource manifest are all served from here. Only ever set at runtime by
  /// the user or by `--dart-define=PVZGE_SERVER=…`; never in the repository.
  final String serverBaseUrl;

  /// The device token the user issued at `{server}/_save/app.html`; empty
  /// means cloud features stay off. Only ever stored at runtime.
  final String deviceToken;

  /// Name the server reported for [deviceToken] at sign-in (`whoami`); empty
  /// until the identity has been verified. Never a secret.
  final String deviceAccount;

  /// 游玩形态：本地资源包（离线）或在线（由启动器反代服务器游戏页）。
  /// 两种形态走同一个本地服务器与同一份存档桥，存档语义保持一致。
  final PlayMode playMode;

  /// The server this app talks to: the value saved in settings, else the one
  /// compiled in. Empty when neither is a usable https URL.
  String get effectiveServerBaseUrl {
    final raw = serverBaseUrl.trim();
    if (raw.isEmpty) {
      return normalizeServerBaseUrl(kDefaultServerBase) ?? '';
    }
    return normalizeServerBaseUrl(raw) ?? '';
  }

  bool get hasDeviceToken => deviceToken.trim().isNotEmpty;

  AppSettings copyWith({
    bool? watermarkEnabled,
    bool? quickLaunchEnabled,
    RenderResolution? renderResolution,
    ScreenFit? screenFit,
    bool? detailedAudioDiagnosticsEnabled,
    ThemePreference? themePreference,
    bool? reduceMotion,
    LanguagePreference? languagePreference,
    String? seenAnnouncementId,
    bool? toolShedUnlocked,
    bool? touchDiagnosticsEnabled,
    bool? gestureHintShown,
    String? serverBaseUrl,
    String? deviceToken,
    String? deviceAccount,
    PlayMode? playMode,
  }) {
    return AppSettings(
      watermarkEnabled: watermarkEnabled ?? this.watermarkEnabled,
      quickLaunchEnabled: quickLaunchEnabled ?? this.quickLaunchEnabled,
      renderResolution: renderResolution ?? this.renderResolution,
      screenFit: screenFit ?? this.screenFit,
      detailedAudioDiagnosticsEnabled: detailedAudioDiagnosticsEnabled ??
          this.detailedAudioDiagnosticsEnabled,
      themePreference: themePreference ?? this.themePreference,
      reduceMotion: reduceMotion ?? this.reduceMotion,
      languagePreference: languagePreference ?? this.languagePreference,
      seenAnnouncementId: seenAnnouncementId ?? this.seenAnnouncementId,
      toolShedUnlocked: toolShedUnlocked ?? this.toolShedUnlocked,
      touchDiagnosticsEnabled:
          touchDiagnosticsEnabled ?? this.touchDiagnosticsEnabled,
      gestureHintShown: gestureHintShown ?? this.gestureHintShown,
      serverBaseUrl: serverBaseUrl ?? this.serverBaseUrl,
      deviceToken: deviceToken ?? this.deviceToken,
      deviceAccount: deviceAccount ?? this.deviceAccount,
      playMode: playMode ?? this.playMode,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'watermarkEnabled': watermarkEnabled,
        'quickLaunchEnabled': quickLaunchEnabled,
        'renderResolution': renderResolution.name,
        'screenFit': screenFit.name,
        'detailedAudioDiagnosticsEnabled': detailedAudioDiagnosticsEnabled,
        'themePreference': themePreference.name,
        'reduceMotion': reduceMotion,
        'languagePreference': languagePreference.name,
        'seenAnnouncementId': seenAnnouncementId,
        'toolShedUnlocked': toolShedUnlocked,
        'touchDiagnosticsEnabled': touchDiagnosticsEnabled,
        'gestureHintShown': gestureHintShown,
        'serverBaseUrl': serverBaseUrl,
        'deviceToken': deviceToken,
        'deviceAccount': deviceAccount,
        'playMode': playMode.name,
      };
}

/// Settings kept before the save server was configurable have no base URL;
/// a blank value stays blank so the compiled-in default can apply.
String _readBaseUrl(Object? value) {
  return value is String ? value.trim() : '';
}

/// Accepts only an https origin (plain http is allowed solely for a loopback
/// development server). Returns it without a trailing slash, or null when the
/// value is not a usable base URL.
String? normalizeServerBaseUrl(String? value) {
  final raw = value?.trim() ?? '';
  if (raw.isEmpty) {
    return null;
  }
  final uri = Uri.tryParse(raw);
  if (uri == null ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  final isLoopback = uri.host == 'localhost' || uri.host == '127.0.0.1';
  final schemeAccepted =
      uri.scheme == 'https' || (uri.scheme == 'http' && isLoopback);
  if (!schemeAccepted) {
    return null;
  }
  final path = uri.path.replaceFirst(RegExp(r'/+$'), '');
  final port = uri.hasPort ? ':${uri.port}' : '';
  return '${uri.scheme}://${uri.host}$port$path';
}

/// What may appear in a log line: the scheme and a mask, never the host.
String maskedServerBase(String baseUrl) {
  final uri = Uri.tryParse(baseUrl.trim());
  if (uri == null || uri.scheme.isEmpty) {
    return '***';
  }
  return '${uri.scheme}://***';
}

class AppSettingsStore {
  AppSettingsStore(this._file);

  final File _file;

  File get _temporaryFile => File('${_file.path}.tmp');

  Future<AppSettings> read() async {
    if (!await _file.exists()) {
      return const AppSettings();
    }

    try {
      final json = jsonDecode(await _file.readAsString());
      if (json is Map<String, dynamic>) {
        return AppSettings.fromJson(json);
      }
    } catch (_) {
      // Invalid or outdated settings fall back to the safe default.
    }
    return const AppSettings();
  }

  Future<void> write(AppSettings settings) async {
    await _file.parent.create(recursive: true);
    const encoder = JsonEncoder.withIndent('  ');
    await _temporaryFile.writeAsString(
      '${encoder.convert(settings.toJson())}\n',
      flush: true,
    );
    // settings.json 里存着设备令牌。资源根目录现在可以由用户改到任意位置
    // （包括网盘同步目录/共享盘），所以落地即收紧到 0600。
    // Windows 上 chmod 是空操作，不会因此失败。
    await _restrictPermissions(_temporaryFile);
    await _temporaryFile.rename(_file.path);
    await _restrictPermissions(_file);
  }

  Future<void> _restrictPermissions(File file) async {
    if (Platform.isWindows) return;
    try {
      await Process.run('chmod', ['600', file.path]);
    } catch (_) {
      // 权限收紧失败不该让设置保存整体失败
    }
  }
}
