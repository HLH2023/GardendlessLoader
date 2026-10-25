import 'dart:io';

enum GameHostPlatform {
  android('android', 'https://appassets.androidplatform.net'),
  ios('ios', 'gardendless-game://localhost'),
  ohos('ohos', 'https://gardendless.invalid'),

  /// 桌面端没有原生 GameHost：游戏由 Dart 的本地 HTTP 服务器 +
  /// webview_cef 承载。这个值只用于界面/诊断展示，不参与原生活会话。
  desktop('desktop', 'http://127.0.0.1');

  const GameHostPlatform(this.wireName, this.origin);

  final String wireName;
  final String origin;

  String get nativeHostName =>
      this == desktop ? 'dart-desktop' : '$wireName-native';

  static GameHostPlatform forOperatingSystem(String value) {
    if (value == 'windows' || value == 'linux' || value == 'macos') {
      return desktop;
    }
    return GameHostPlatform.values.firstWhere(
      (platform) => platform.wireName == value,
      orElse: () => throw UnsupportedError(
        'Gardendless game host does not support $value',
      ),
    );
  }

  static GameHostPlatform current() => forOperatingSystem(Platform.operatingSystem);

  static GameHostPlatform fromWireName(Object? value) {
    return GameHostPlatform.values.firstWhere(
      (platform) => platform.wireName == value,
      orElse: () => throw FormatException(
        'Unsupported native GameHost platform: $value',
      ),
    );
  }
}

/// How the game viewport fits the screen. The game shows 16:10 to 17:9 without
/// distortion and its whole picture at 17:9. The names are the native session
/// wire values.
enum ScreenFit {
  /// Follows the window exactly (native): a 21:9 phone gets a 21:9 viewport,
  /// so nothing is cropped and no 16:9 bars are added.
  balanced,

  /// Keeps the viewport at 17:9 so the whole picture shows, with larger
  /// black bars.
  showAll,

  /// Stretches the balanced viewport over the whole screen.
  stretch;

  static ScreenFit fromName(Object? value) {
    return ScreenFit.values.firstWhere(
      (fit) => fit.name == value,
      orElse: () => ScreenFit.balanced,
    );
  }
}
