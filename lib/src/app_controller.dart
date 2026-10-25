import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:wakelock_plus/wakelock_plus.dart';

import 'constants.dart';
import 'game_host/game_host.dart';
import 'game_host/game_session_store.dart';
import 'l10n/app_strings.dart';
import 'logging/app_logger.dart';
import 'logging/log_event_catalog.dart';
import 'models.dart';
import 'services/about_content_service.dart';
import 'services/announcement_service.dart';
import 'services/app_install_service.dart';
import 'services/app_paths_service.dart';
import 'services/local_resource_server.dart';
import 'services/storage_root_service.dart';
import 'services/app_settings_store.dart';
import 'services/app_update_service.dart';
import 'services/cloud_login_service.dart';
import 'services/cloud_save_service.dart';
import 'services/diagnostics_service.dart';
import 'services/garden_journal.dart';
import 'services/game_update_check_service.dart';
import 'services/import_service.dart';
import 'services/import_progress_meter.dart';
import 'services/manifest_store.dart';
import 'services/remote_resource_service.dart';
import 'services/resource_validator.dart';
import 'services/resource_picker_service.dart';
import 'services/shortcut_service.dart';
import 'services/update_check_service.dart';
import 'services/windows_update_service.dart';
import 'services/windows_updater.dart';

//AppController 是整个应用的核心控制器，负责管理应用的状态、处理业务逻辑，并与 UI 进行交互。它使用 ChangeNotifier 来通知 UI 更新。
class AppController extends ChangeNotifier {
  AppController({required AppLogger appLogger}) : _appLogger = appLogger {
    _importService = ImportService(validator: _validator);
    _resourcePickerService.onIncomingZip = (name) {
      _incomingZipName = name;
      notifyListeners();
    };
    _shortcutService.onShortcut = (shortcut) {
      _pendingShortcut = shortcut;
      notifyListeners();
    };
  }

  final AppPathsService _pathsService = AppPathsService();
  final ResourceValidator _validator = ResourceValidator();
  final MethodChannelGameHost _gameHost = const MethodChannelGameHost();
  final AppLogger _appLogger;
  final AnnouncementService _announcementService = AnnouncementService();
  final AboutContentService _aboutContentService = AboutContentService();
  final UpdateCheckService _updateCheckService = UpdateCheckService();
  final GameUpdateCheckService _gameUpdateCheckService =
      GameUpdateCheckService();
  final ResourcePickerService _resourcePickerService = ResourcePickerService();
  final ShortcutService _shortcutService = ShortcutService();
  final RemoteResourceService _remoteResourceService = RemoteResourceService();
  final AppInstallService _appInstallService = const AppInstallService();
  late final AppUpdateService _appUpdateService = AppUpdateService(
    _remoteResourceService,
  );
  final CloudLoginService _cloudLoginService = const CloudLoginService();
  late final ImportService _importService;
  RemoteDownloadStatus _remoteDownload = RemoteDownloadStatus.idle;
  late final WindowsUpdateService _windowsUpdateService = WindowsUpdateService(
    _remoteResourceService,
  );
  WindowsUpdateStatus _windowsUpdate = const WindowsUpdateStatus(
    phase: AppUpdatePhase.idle,
  );
  File? _windowsUpdateFile;
  RemoteDownloadCancellation? _windowsUpdateCancellation;
  AppUpdateStatus _appUpdate = AppUpdateStatus.idle;
  AppUpdateManifest? _appUpdateManifest;
  File? _appUpdateFile;
  RemoteDownloadCancellation? _appUpdateCancellation;
  CloudLoginStatus _cloudLogin = CloudLoginStatus.idle;

  // 云端存档页（独立页面）的状态。刷新失败不阻塞任何游戏流程。
  CloudSaveSnapshot? _cloudSaves;
  bool _cloudSavesLoading = false;
  String? _cloudSavesError;
  Map<String, List<CloudSaveVersion>> _saveHistory =
      <String, List<CloudSaveVersion>>{};
  final Set<String> _saveHistoryLoading = <String>{};
  String? _saveHistoryError;
  String? _saveRestoreInProgress;
  String? _saveRestoreMessage;
  RemoteResourceManifest? _remoteManifest;
  ({String? code, String message})? _remoteManifestFailure;
  bool _remoteManifestLoading = false;
  RemoteDownloadCancellation? _remoteCancellation;
  ImportProgressMeter? _importProgressMeter;
  Timer? _importCompletionTimer;
  Timer? _importProgressTickTimer;
  String? _activeImportOperationId;
  DateTime? _lastImportProgressLogAt;
  Future<void> _appSettingsWrite = Future<void>.value();
  Future<void> _manifestPreferenceWrite = Future<void>.value();

  AppPaths? _paths;
  AppSettingsStore? _appSettingsStore;
  GardenJournalStore? _journalStore;
  GardenJournal _journal = const GardenJournal();
  ManifestStore? _manifestStore;
  GameSessionStore? _gameSessionStore;
  ResourceManifest _manifest = ResourceManifest.initial();
  ResourceValidationResult _currentValidation =
      ResourceValidationResult.missing('尚未检查激活槽');
  ResourceValidationResult _importValidation = ResourceValidationResult.missing(
    '尚未选择 ZIP',
  );
  ImportProgress _importProgress = ImportProgress.idle;
  Announcement? _announcement;
  SeasonalTheme? _seasonalTheme;
  LauncherLinks _links = const LauncherLinks();
  ({String from, String to})? _versionUpgrade;
  int _importTipIndex = 0;
  AboutContent _aboutContent = localFallbackAboutContent;
  UpdateInfo? _availableUpdate;
  GameUpdateInfo? _availableGameUpdate;
  String? _deferredUpdateTagName;
  String? _deferredGameUpdateTagName;
  String _currentAppVersion = appVersion;
  String _installedVersionName = appVersion;
  String _installedBuildNumber = '';
  String? _currentGameVersion;
  String? _latestAppVersion;
  String? _latestGameVersion;
  bool _currentGameVersionIsAhead = false;
  bool _appUpdateDetected = false;
  bool _gameUpdateDetected = false;
  bool _updateCheckInProgress = false;
  AppSettings _appSettings = const AppSettings();
  bool _initialized = false;
  bool _busy = false;
  LauncherMessage? _message;
  String? _incomingZipName;
  LauncherShortcut? _pendingShortcut;
  AppLogSnapshot? _logSnapshot;
  bool _logSnapshotLoading = false;

  bool get initialized => _initialized;
  bool get busy => _busy;
  LauncherMessage? get message => _message;

  /// Name of a ZIP another app opened or shared with the loader, waiting for
  /// the user to import or dismiss it.
  String? get incomingZipName => _incomingZipName;

  /// A home-screen shortcut waiting for the launcher to act on it.
  LauncherShortcut? get pendingShortcut => _pendingShortcut;

  LauncherShortcut? takeShortcut() {
    final shortcut = _pendingShortcut;
    _pendingShortcut = null;
    return shortcut;
  }

  AppLogSnapshot? get logSnapshot => _logSnapshot;
  bool get logSnapshotLoading => _logSnapshotLoading;
  ResourceManifest get manifest => _manifest;
  ImportProgress get importProgress => _importProgress;
  Announcement? get announcement => _announcement;
  LauncherLinks get links => _links;

  /// The remote seasonal theme, while today is within its dates.
  SeasonalTheme? get seasonalTheme =>
      _seasonalTheme?.isActiveOn(DateTime.now()) == true
          ? _seasonalTheme
          : null;

  /// Play time and the version rings, kept on this device only.
  GardenJournal get journal => _journal;

  /// The game versions of the last import, while its completion shows and
  /// only when it moved the game to a newer version.
  ({String from, String to})? get versionUpgrade => _versionUpgrade;

  /// One tip shown while the current import runs.
  String get importTip => AppStrings.current.importTips[_importTipIndex];
  AboutContent get aboutContent => _aboutContent;
  UpdateInfo? get availableUpdate => _availableUpdate;
  GameUpdateInfo? get availableGameUpdate => _availableGameUpdate;
  String get currentAppVersion => _currentAppVersion;

  /// Installed versionName exactly as packaged (`0.9.0-hlh.1`), for the
  /// Settings page so the user can tell which personal build is installed.
  String get installedVersionName => _installedVersionName;
  String get installedBuildNumber => _installedBuildNumber;
  String? get latestAppVersion => _latestAppVersion;
  String? get currentGameVersion => _currentGameVersion;
  String? get latestGameVersion => _latestGameVersion;
  bool get updateCheckInProgress => _updateCheckInProgress;
  bool get watermarkEnabled => _appSettings.watermarkEnabled;
  bool get quickLaunchEnabled => _appSettings.quickLaunchEnabled;
  RenderResolution get renderResolution => _appSettings.renderResolution;
  ScreenFit get screenFit => _appSettings.screenFit;
  bool get detailedAudioDiagnosticsEnabled =>
      _appSettings.detailedAudioDiagnosticsEnabled;
  ThemePreference get themePreference => _appSettings.themePreference;
  LanguagePreference get languagePreference => _appSettings.languagePreference;
  bool get reduceMotion => _appSettings.reduceMotion;
  bool get toolShedUnlocked => _appSettings.toolShedUnlocked;
  bool get touchDiagnosticsEnabled => _appSettings.touchDiagnosticsEnabled;
  bool get autoCollectSunEnabled => _manifest.autoCollectSunEnabled;
  GameHostPlatform get gameHostPlatform => GameHostPlatform.current();

  /// Where the user signed in to issue the device token, and the server the
  /// app asks for saves and resources.
  String get serverBaseUrl => _appSettings.serverBaseUrl;
  String get deviceToken => _appSettings.deviceToken;
  bool get cloudServerConfigured =>
      _appSettings.hasDeviceToken &&
      _appSettings.effectiveServerBaseUrl.isNotEmpty;

  /// Only the Android host implements extracting a downloaded ZIP; elsewhere
  /// the launcher must not start a multi-gigabyte download it cannot import.
  /// 下载/导入资源包：Android 与桌面端都支持（桌面端跑本地资源同样需要）。
  /// iOS 等还没有本地游戏宿主的平台仍然关闭。
  bool get serverResourceDownloadSupported =>
      Platform.isAndroid || isDesktopPlatform;

  /// Page a user opens in a browser to issue a device token.
  String get deviceTokenUrl {
    final base = _appSettings.effectiveServerBaseUrl;
    return base.isEmpty ? '' : '$base$saveLoginPagePath';
  }

  /// The authentik-protected page the in-app sign-in screen loads; it hands the
  /// token to the native bridge instead of asking the user to copy it.
  String get saveLoginUrl {
    final base = _appSettings.effectiveServerBaseUrl;
    return base.isEmpty ? '' : '$base$saveLoginPagePath?$saveLoginBridgeQuery';
  }

  /// The full save manager (history, rollback, devices, tokens) that already
  /// exists on the server; it needs the browser's authentik session, so the
  /// app hands it to the system browser instead of embedding a second UI.
  String get saveAdminUrl {
    final base = _appSettings.effectiveServerBaseUrl;
    return base.isEmpty ? '' : '$base$saveAdminPagePath';
  }

  /// 云端存档页的状态：快照、错误、历史缓存与进行中的操作。
  CloudSaveSnapshot? get cloudSaves => _cloudSaves;
  bool get cloudSavesLoading => _cloudSavesLoading;
  bool get cloudSavesRefreshing => _cloudSavesLoading && _cloudSaves != null;
  String? get cloudSavesError => _cloudSavesError;
  Map<String, List<CloudSaveVersion>> get saveHistory => _saveHistory;
  String? get saveHistoryError => _saveHistoryError;
  Set<String> get saveHistoryLoading => _saveHistoryLoading;
  String? get saveRestoreInProgress => _saveRestoreInProgress;
  String? get saveRestoreMessage => _saveRestoreMessage;

  /// 拉取云端存档元信息。离线/未登录都不抛：页面只需要一个可读的错误码。
  Future<void> refreshCloudSaves() async {
    final base = _appSettings.effectiveServerBaseUrl;
    final token = _appSettings.deviceToken.trim();
    if (base.isEmpty || token.isEmpty) {
      _cloudSaves = null;
      _cloudSavesError = 'save_server_not_configured';
      notifyListeners();
      return;
    }
    if (_cloudSavesLoading) return;
    _cloudSavesLoading = true;
    _cloudSavesError = null;
    notifyListeners();
    try {
      final snapshot = await _remoteResourceService.fetchCloudSaves(
        gameVersion: _playGameVersion(),
        token: token,
        baseUrl: base,
      );
      if (token != _appSettings.deviceToken.trim()) return;
      _cloudSaves = snapshot;
    } on RemoteResourceFailure catch (failure) {
      await _handleTokenRejected(failure);
      _cloudSavesError = failure.code;
      _appLogger.emit(
        level: LogLevel.warn,
        category: 'cloud.saves',
        event: 'cloud_saves_refresh',
        outcome: LogOutcome.failed,
        code: failure.code,
        context: <String, Object?>{'message': failure.message},
      );
    } catch (error, stackTrace) {
      _cloudSavesError = 'cloud_saves_unavailable';
      _appLogger.emit(
        level: LogLevel.warn,
        category: 'cloud.saves',
        event: 'cloud_saves_refresh',
        outcome: LogOutcome.failed,
        code: 'cloud_saves_unavailable',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _cloudSavesLoading = false;
      notifyListeners();
    }
  }

  /// 拉取某个存档键的历史版本（管理员）。403 时给出明确错误码而不是空列表。
  Future<void> loadSaveHistory(String key) async {
    final base = _appSettings.effectiveServerBaseUrl;
    final token = _appSettings.deviceToken.trim();
    final user = _cloudSaves?.user ?? _appSettings.deviceAccount;
    if (base.isEmpty || token.isEmpty || user.isEmpty) {
      _saveHistoryError = 'save_server_not_configured';
      notifyListeners();
      return;
    }
    if (!_saveHistoryLoading.add(key)) return;
    _saveHistoryError = null;
    notifyListeners();
    try {
      final versions = await _remoteResourceService.fetchSaveHistory(
        // 用 /load 实际返回的分区（可能是 legacy），而不是请求的版本。
        gameVersion: _cloudSaves?.gameVersion ?? _playGameVersion(),
        token: token,
        baseUrl: base,
        user: user,
        key: key,
      );
      _saveHistory = <String, List<CloudSaveVersion>>{
        ..._saveHistory,
        key: versions,
      };
    } on RemoteResourceFailure catch (failure) {
      _saveHistoryError = failure.code;
      _saveHistory = <String, List<CloudSaveVersion>>{
        ..._saveHistory,
        key: const <CloudSaveVersion>[],
      };
    } finally {
      _saveHistoryLoading.remove(key);
      notifyListeners();
    }
  }

  /// 回滚云端存档到某个历史版本；成功后刷新快照。
  Future<bool> restoreSaveVersion({
    required String key,
    required int ts,
    String name = '',
  }) async {
    final base = _appSettings.effectiveServerBaseUrl;
    final token = _appSettings.deviceToken.trim();
    final user = _cloudSaves?.user ?? _appSettings.deviceAccount;
    if (base.isEmpty || token.isEmpty || user.isEmpty) {
      _saveRestoreMessage = 'save_server_not_configured';
      notifyListeners();
      return false;
    }
    if (_saveRestoreInProgress != null) return false;
    _saveRestoreInProgress = key;
    _saveRestoreMessage = null;
    notifyListeners();
    try {
      await _remoteResourceService.restoreSaveVersion(
        token: token,
        baseUrl: base,
        user: user,
        key: key,
        ts: ts,
        name: name,
        gameVersion: _cloudSaves?.gameVersion ?? _playGameVersion(),
      );
      _saveRestoreMessage = 'save_restore_done';
      _appLogger.emit(
        level: LogLevel.info,
        category: 'cloud.saves',
        event: 'cloud_save_restored',
        outcome: LogOutcome.succeeded,
        context: <String, Object?>{'key': key, 'ts': ts},
      );
      _saveRestoreInProgress = null;
      notifyListeners();
      await refreshCloudSaves();
      return true;
    } on RemoteResourceFailure catch (failure) {
      _saveRestoreMessage = failure.code;
      _appLogger.emit(
        level: LogLevel.warn,
        category: 'cloud.saves',
        event: 'cloud_save_restore',
        outcome: LogOutcome.failed,
        code: failure.code,
        context: <String, Object?>{'key': key, 'ts': ts},
      );
      return false;
    } finally {
      _saveRestoreInProgress = null;
      notifyListeners();
    }
  }

  void clearSaveRestoreMessage() {
    if (_saveRestoreMessage == null) return;
    _saveRestoreMessage = null;
    notifyListeners();
  }

  CloudLoginStatus get cloudLogin => _cloudLogin;
  bool get cloudLoginInProgress => _cloudLogin.inProgress;

  /// Only the Android host embeds the sign-in screen.
  /// 应用内 authentik 登录：Android 走原生 LoginActivity；
  /// 桌面端目前通过「在浏览器打开令牌签发页」完成同一件事（见 deviceTokenUrl）。
  bool get cloudLoginSupported => Platform.isAndroid;

  /// Account name the server reported for the stored token, when verified.
  String get cloudAccount => _appSettings.deviceAccount;
  bool get cloudAccountKnown => _appSettings.deviceAccount.isNotEmpty;

  /// 全局登录态：启动器级别的一份身份，云存档/资源下载/在线游玩共用。
  bool get accountSignedIn => _appSettings.hasDeviceToken;
  String get accountDisplayName => _appSettings.deviceAccount.isNotEmpty
      ? _appSettings.deviceAccount
      : AppStrings.current.accountSignedInFallback;

  /// Whether a server address is known, with or without a token yet.
  bool get cloudServerAddressConfigured =>
      _appSettings.effectiveServerBaseUrl.isNotEmpty;

  RemoteDownloadStatus get remoteDownload => _remoteDownload;
  RemoteResourceManifest? get remoteManifest => _remoteManifest;

  /// Where the in-app APK update is: the server's release, the download and
  /// the install request.
  AppUpdateStatus get appUpdate => _appUpdate;

  /// Server wording shown under the release, e.g. why an update cannot be
  /// installed from inside the app.
  String get appUpdateHint => _appUpdateManifest?.hint ?? '';

  /// Only Android can hand a downloaded APK to the system installer.
  bool get appUpdateInstallSupported => _appInstallService.supported;

  /// A verified installer is on disk and can be handed to the system again,
  /// e.g. after the user granted the unknown-sources permission.
  bool get appUpdateInstallReady => _appUpdateFile != null;

  /// Windows 端的更新（清单 + zip 下载 + 校验）。与 APK 更新完全独立，
  /// 避免一个平台的失败状态污染另一个平台。
  WindowsUpdateStatus get windowsUpdate => _windowsUpdate;
  File? get windowsUpdateFile => _windowsUpdateFile;
  bool get windowsUpdateSupported => Platform.isWindows;
  ({String? code, String message})? get remoteManifestFailure =>
      _remoteManifestFailure;
  bool get remoteManifestLoading => _remoteManifestLoading;

  bool get isImporting =>
      _importProgress.phase != ImportPhase.idle &&
      _importProgress.phase != ImportPhase.completed &&
      _importProgress.phase != ImportPhase.failed;
  bool get hasCurrentResource => _currentValidation.isValid;
  bool get hasGpNext => hasCurrentResource && _currentValidation.hasGpNext;
  bool get gpNextCompatible => hasGpNext && _currentValidation.gpNextCompatible;
  String? get gpNextVersion =>
      _currentValidation.gpNextVersion ?? _manifest.gpNextVersion;
  String? get gpNextCompatibilityError =>
      _currentValidation.gpNextCompatibilityError ??
      _manifest.gpNextCompatibilityError;
  /// 是否桌面平台（Windows/Linux/macOS）：游戏跑在进程内 WebView + 本地服务器。
  bool get isDesktopPlatform =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  /// 当前游玩形态。
  PlayMode get playMode => _appSettings.playMode;

  /// 在线形态是否可用。
  ///
  /// 桌面端：配置了服务器即可（未登录也能玩，只是没有云存档）。
  /// Android：还必须已登录 —— 在线资源走服务器 `/_save/online/`，该路由要
  /// Bearer 设备令牌，未登录会 401，宁可提前拦住也不要让玩家看到白屏。
  bool get onlinePlaySupported {
    if (_appSettings.effectiveServerBaseUrl.isEmpty) return false;
    if (isDesktopPlatform) return true;
    if (Platform.isAndroid) return _appSettings.hasDeviceToken;
    return false;
  }

  /// 启动是否正在进行（防重复进入：快捷键与按钮点击可能同时触发）。
  bool _gameLaunchInFlight = false;
  bool get gameLaunchInFlight => _gameLaunchInFlight;

  /// 桌面端游戏窗口是否正在运行（迁移/切形态时必须让路）。
  bool _desktopGameActive = false;
  bool get desktopGameActive => _desktopGameActive;

  /// 是否具备开始游戏的条件（按形态判定）。
  bool get canStartGame => playMode == PlayMode.online
      ? onlinePlaySupported
      : hasCurrentResource;

  /// 用系统默认浏览器打开设备令牌签发页（桌面端登录第一步）。
  ///
  /// Android 有内嵌登录闭环，不需要这个；桌面端没有内嵌页，只能借浏览器拿令牌。
  Future<void> openTokenIssuePage() async {
    final url = deviceTokenUrl;
    if (url.isEmpty) return;
    try {
      if (Platform.isWindows) {
        await Process.run('cmd', ['/c', 'start', '', url], runInShell: false);
      } else if (Platform.isMacOS) {
        await Process.run('open', [url]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [url]);
      } else {
        await const MethodChannel('io.github.dey410.gardendlessloader/external_browser')
            .invokeMethod<void>('open', <String, Object?>{'url': url});
      }
    } catch (error) {
      _appLogger.emit(
        level: LogLevel.warn,
        category: 'cloud.login',
        event: 'open_token_page_failed',
        outcome: LogOutcome.failed,
        error: error,
      );
    }
  }

  /// 云端明确拒绝了这个令牌（401/403）时的统一处理。
  ///
  /// 令牌被服务器吊销/过期后，继续留着它只会让所有云功能持续静默失败：
  /// 界面显示「加载失败」，用户不知道要重新登录。这里清掉令牌 + 给明确提示。
  /// 返回 true 表示已经按「登录失效」处理过。
  Future<bool> _handleTokenRejected(Object error) async {
    final code = error is RemoteResourceFailure ? error.code : '';
    if (code != 'save_token_rejected') return false;
    if (_appSettings.deviceToken.trim().isEmpty) return true; // 已经清过
    // 复用登出流程：清令牌、清存档快照、删掉资源根里那份明文令牌桥文件
    try {
      await signOutAccount();
    } catch (_) {}
    _cloudSavesError = 'save_token_rejected';
    _message = const LauncherMessage(
      '登录状态已失效，请重新登录后再使用云端功能',
      'save_token_rejected',
    );
    _appLogger.emit(
      level: LogLevel.warn,
      category: 'cloud.auth',
      event: 'device_token_rejected',
      outcome: LogOutcome.failed,
      code: 'save_token_rejected',
    );
    notifyListeners();
    return true;
  }

  /// 退出登录：清掉设备令牌（服务器端令牌仍有效，需要时可在存档页吊销）。
  Future<void> signOutAccount() async {
    await _updateAppSettings(_appSettings.copyWith(deviceToken: '', deviceAccount: ''));
    // 存档页展示的是上一份快照：不清空就会把「别人的/已登出的」数据继续显示
    _cloudSaves = null;
    _saveHistory = <String, List<CloudSaveVersion>>{};
    // 退出登录必须把这个明文令牌文件也抹掉：它躺在资源根目录里，
    // 用户能改到任意位置，留着等于登出没登出。
    final root = _paths?.root;
    if (root != null) {
      await _deleteFileQuietly(File(p.join(root.path, syncBridgeFileName)));
      await _deleteFileQuietly(File(p.join(root.path, nativeTokenFileName)));
    }
    _appLogger.emit(
      level: LogLevel.info,
      category: 'cloud',
      event: 'account_signed_out',
      outcome: LogOutcome.succeeded,
    );
    notifyListeners();
  }

  /// 桌面端登录：用浏览器在签发页拿到设备令牌后粘贴进来。
  ///
  /// Android 有原生 LoginActivity 闭环（`cloudLoginSupported=true`）；桌面端没有
  /// 内嵌登录页，所以走「浏览器签发 + 粘贴」这条路，校验 whoami 通过才落库，
  /// 避免把一个错令牌存进去让所有云功能静默 401。
  Future<String?> signInWithToken(String rawToken) async {
    final token = rawToken.trim();
    if (token.isEmpty) return '令牌不能为空';
    if (!token.startsWith('pvz_')) return '令牌格式不对（应以 pvz_ 开头）';
    final base = _appSettings.effectiveServerBaseUrl;
    if (base.isEmpty) return '还没有配置服务器地址';
    if (_loginInProgress) return '正在登录中，请稍候';
    _loginInProgress = true;
    _cloudLogin = const CloudLoginStatus(phase: CloudLoginPhase.verifying);
    notifyListeners();
    try {
      final identity = await _remoteResourceService.fetchWhoami(
        token: token,
        baseUrl: base,
      );
      await _updateAppSettings(_appSettings.copyWith(
        deviceToken: token,
        deviceAccount: identity.user,
      ));
      // 换了身份，之前缓存的清单与存档快照都失效
      _remoteManifest = null;
      _remoteManifestFailure = null;
      _cloudSaves = null;
      _saveHistory = <String, List<CloudSaveVersion>>{};
      _cloudLogin = const CloudLoginStatus(phase: CloudLoginPhase.succeeded);
      _appLogger.emit(
        level: LogLevel.info,
        category: 'cloud.login',
        event: 'cloud_login_finished',
        outcome: LogOutcome.succeeded,
        context: <String, Object?>{
          'stage': 'token_paste',
          'server': maskedServerBase(base),
          'accountKnown': identity.user.isNotEmpty,
        },
      );
      notifyListeners();
      return null;
    } on RemoteResourceFailure catch (failure) {
      _cloudLogin = CloudLoginStatus(
        phase: CloudLoginPhase.failed,
        errorCode: failure.code,
        message: failure.message,
      );
      notifyListeners();
      return failure.message;
    } catch (error) {
      _cloudLogin = CloudLoginStatus(
        phase: CloudLoginPhase.failed,
        errorCode: 'cloud_login_failed',
        message: '$error',
      );
      notifyListeners();
      return '$error';
    } finally {
      _loginInProgress = false;
      notifyListeners();
    }
  }

  /// 切换游玩形态（立即持久化）。
  Future<void> setPlayMode(PlayMode mode) async {
    if (_appSettings.playMode == mode) return;
    if (_storageBusy ||
        isImporting ||
        _desktopGameActive ||
        _gameLaunchInFlight ||
        resourceTransactionBusy(_manifest.transactionState)) {
      // 形态决定「资源从哪来」，跑到一半切换会让当前会话的来源与设置不一致；
      // 上个事务没恢复完（崩溃窗口）同样不能切。
      return;
    }
    await _updateAppSettings(_appSettings.copyWith(playMode: mode));
    _appLogger.emit(
      level: LogLevel.info,
      category: 'game.host',
      event: 'play_mode_changed',
      outcome: LogOutcome.succeeded,
      context: <String, Object?>{'mode': mode.name},
    );
    notifyListeners();
  }

  // ===== 存储位置（资源包根目录）=====
  bool _storageBusy = false;
  bool _storageFromConfigured = false;
  StorageUsage? _storageUsage;

  /// 正在迁移存储位置
  bool get storageBusy => _storageBusy;

  /// 当前资源根是否来自用户配置（而不是平台默认）
  bool get storageFromConfigured => _storageFromConfigured;

  /// 资源目录占用（字节/文件数/剩余空间）
  StorageUsage? get storageUsage => _storageUsage;

  /// 资源根绝对路径
  String? get storageRootPath => _paths?.root.path;

  /// 平台默认位置（供「恢复默认」展示）
  Future<String> storageDefaultPath() async =>
      (await _pathsService.defaultRoot()).path;

  /// 校验候选目录是否可用作存储位置（不改状态）
  Future<StorageCheck> checkStorageTarget(String path) {
    final current = _paths?.root;
    return _pathsService.storage.validate(Directory(path.trim()), currentRoot: current);
  }

  /// 刷新占用统计
  Future<void> refreshStorageUsage() async {
    final root = _paths?.root;
    if (root == null) return;
    try {
      _storageUsage = await _pathsService.storage.usage(root);
      notifyListeners();
    } catch (_) {}
  }

  /// 切换资源存储位置：搬数据 → 写指针 → 重新加载。
  ///
  /// 返回 null 表示成功；否则返回给用户看的错误文案。
  /// 迁移失败时数据已自动回滚，仍从老位置正常工作。
  Future<String?> changeStorageRoot(String path) async {
    final current = _paths;
    if (current == null) return '应用尚未初始化';
    if (_storageBusy) return '正在迁移中，请稍候';
    // 迁移会把资源槽整体搬走：游戏正在跑或正在导入时动手，会把正在读的
    // 文件抽走（桌面端本地服务器、安卓原生 asset loader 都在读）。
    if (_desktopGameActive || _gameLaunchInFlight) {
      return '游戏正在运行，请先退出游戏再迁移';
    }
    if (isImporting) {
      return '正在导入资源，请等导入完成再迁移';
    }
    if (resourceTransactionBusy(_manifest.transactionState)) {
      // 上次导入/迁移没走完（断电、进程被杀）。先让启动恢复把槽收尾，
      // 否则会把半成品目录整体搬到新位置。
      return '上次资源导入未完成，请重启应用完成恢复后再迁移';
    }
    final target = Directory(path.trim());
    _storageBusy = true;
    notifyListeners();
    // 搬迁要几分钟，进程被系统杀掉/断电都可能：先落迁移日志，
    // 下次启动才能把「搬走一半」的条目搬回来（见 recoverIfInterrupted）。
    try {
      await _pathsService.storage.migration.beginJournal(
        sourceRoot: current.root,
        target: target,
        entries: List<String>.from(ResourceMigration.movableEntries),
      );
    } catch (e) {
      _storageBusy = false;
      notifyListeners();
      return '切换存储位置失败：无法写入迁移日志（$e）';
    }
    try {
      final result = await _pathsService.storage.migrate(
        sourceRoot: current.root,
        target: target,
      );
      if (!result.ok) {
        await _pathsService.storage.migration.clearJournal(current.root);
        final detail = result.rollbackErrors.isEmpty
            ? ''
            : '（回滚异常：${result.rollbackErrors.join('；')}）';
        return '${result.error ?? '切换存储位置失败'}$detail';
      }
      // 指针写入成功后才算迁移完成：这一步失败就必须保持日志，
      // 让下次启动把条目搬回老根。
      _paths = await _pathsService.relocateTo(target);
      _storageFromConfigured = true;
      await _pathsService.storage.migration.clearJournal(current.root);
      // 等价于从新位置重启：重新读取 manifest / 设置 / 日志
      await initialize();
      await refreshStorageUsage();
      return null;
    } catch (e) {
      return '切换存储位置失败：$e';
    } finally {
      _storageBusy = false;
      notifyListeners();
    }
  }

  String get detectedTitle =>
      _currentValidation.detectedTitle ??
      _manifest.detectedTitle ??
      AppStrings.current.noTitleDetected;
  //返回一个适合在 UI 中显示的资源根目录名称。如果路径信息不可用，则返回一个默认的资源文件夹名称。
  String get userVisibleRoot {
    final root = _paths?.root;
    if (root == null) {
      return resourceFolderName;
    }
    return '${root.parent.path}${Platform.pathSeparator}${p.basename(root.path)}';
  }

  //initialize 方法负责初始化应用的核心状态，包括加载路径信息、读取资源清单、恢复未完成的导入事务，并刷新公告信息。它会在整个过程中更新 busy 状态和 message，以便 UI 可以显示加载状态和错误信息。
  Future<void> initialize() async {
    _busy = true;
    notifyListeners();
    var quickLaunch = false;
    try {
      Future<void> initializeCore() async {
        _emitInitializationStage('paths');
        final resolvedPaths = await _pathsService.ensureInitializedWithSource();
        _paths = resolvedPaths.paths;
        _storageFromConfigured = resolvedPaths.fromConfigured;
        // 上次迁移若被打断，先把条目搬回当前根再继续（否则会出现
        // 「一半在新位置、指针还在老位置」的半残状态）
        final recovery = await _pathsService.storage.migration
            .recoverIfInterrupted(_paths!.root);
        if (recovery != null && recovery.restoredEntries.isNotEmpty) {
          _message = LauncherMessage(
            '上次更换存储位置未完成，已恢复 ${recovery.restoredEntries.length} 项资源',
            'storage_migration_recovered',
          );
        }
        _emitInitializationStage('game_session_recovery');
        _gameSessionStore = GameSessionStore(_paths!.root);
        final exitResult = await _gameSessionStore!.consumeExitResult();
        _emitInitializationStage('settings');
        _appSettingsStore = AppSettingsStore(_paths!.appSettingsFile);
        _appSettings = await _appSettingsStore!.read();
        _applyLanguage(_appSettings.languagePreference);
        // 原生在线宿主发现令牌被拒（401）时会带 tokenRejected 原因退出。
        // 引擎已销毁，这一步只能在下次启动做：清掉本地令牌并明确提示，
        // 否则用户会一直看到「已登录但所有云功能静默失败」。
        if (exitResultRequiresSignOut(
            exitResult, hasToken: _appSettings.deviceToken.trim().isNotEmpty)) {
          await signOutAccount();
          _message = const LauncherMessage(
            '登录状态已失效，请重新登录后再使用在线功能',
            'save_token_rejected',
          );
          _appLogger.emit(
            level: LogLevel.warn,
            category: 'cloud.auth',
            event: 'device_token_rejected',
            outcome: LogOutcome.failed,
            code: 'save_token_rejected',
            context: <String, Object?>{'source': 'native_online_host'},
          );
        }
        _journalStore = GardenJournalStore(_paths!.journalFile);
        _journal = await _journalStore!.read();
        if (exitResult != null &&
            exitResult.reason != GameExitReason.launchFailed &&
            exitResult.playedMs > 0) {
          await _saveJournal(_journal.recordPlay(
            finishedAt: exitResult.finishedAt,
            playedMs: exitResult.playedMs,
          ));
        }
        _emitInitializationStage('manifest');
        _manifestStore = ManifestStore(_paths!.manifestFile);
        _manifest = await _manifestStore!.read();
        final interruptedTransaction =
            _manifest.transactionState != TransactionState.idle;
        final recoveryOperationId =
            interruptedTransaction ? _newOperationId('import-recovery') : null;
        if (interruptedTransaction) {
          _appLogger.emit(
            level: LogLevel.warn,
            category: 'resource.import',
            event: 'import_transaction_recovery_started',
            outcome: LogOutcome.started,
            operationId: recoveryOperationId,
            context: <String, Object?>{
              'transactionState': _manifest.transactionState.name,
              'targetSlot': _manifest.transactionSlot?.name ?? 'none',
            },
          );
        }
        try {
          _manifest = await _importService.recoverStartupTransaction(
            paths: _paths!,
            manifestStore: _manifestStore!,
          );
          if (interruptedTransaction) {
            _appLogger.emit(
              level: LogLevel.info,
              category: 'resource.import',
              event: 'import_transaction_recovery_finished',
              outcome: LogOutcome.succeeded,
              operationId: recoveryOperationId,
              context: <String, Object?>{
                'recoveryAction': _manifest.transactionState ==
                        TransactionState.cleaningOldSlot
                    ? 'cleanup_deferred'
                    : 'transaction_reconciled',
                'activeSlot': _manifest.activeSlot?.name ?? 'none',
                'currentResourceUsable': _manifest.activeSlot != null,
              },
            );
          }
        } catch (error, stackTrace) {
          _appLogger.emit(
            level: LogLevel.error,
            category: 'resource.import',
            event: 'import_transaction_recovery_finished',
            outcome: LogOutcome.failed,
            code: 'import_transaction_recovery_failed',
            operationId: recoveryOperationId,
            error: error,
            stackTrace: stackTrace,
          );
          rethrow;
        }
        _emitInitializationStage('diagnostics');
        await _loadCurrentAppVersion();
        _emitInitializationStage('resource_validation');
        await refresh();
        // The rings begin with the resource imported before they existed.
        if (_journal.imports.isEmpty &&
            hasCurrentResource &&
            _manifest.lastImportAt != null) {
          await _saveJournal(_journal.recordImport(_importRecord()));
        }
        _incomingZipName = await _resourcePickerService.incomingZipName();
        _pendingShortcut = await _shortcutService.take();
        await _shortcutService.publish(AppStrings.current);
        if (_manifest.transactionState == TransactionState.cleaningOldSlot) {
          _message = _failureMessage('old_slot_cleanup_failed', null);
        } else if (interruptedTransaction) {
          _message = _failureMessage('import_interrupted', null);
        } else if (exitResult?.reason == GameExitReason.rendererGone) {
          _message = _failureMessage(
            exitResult?.code ?? 'webview_render_process_gone',
            exitResult?.message,
          );
        } else if (exitResult?.reason == GameExitReason.launchFailed) {
          _message = _failureMessage(
            exitResult?.code ?? 'game_host_launch_failed',
            exitResult?.message,
          );
        }
        _initialized = true;
        // Every game exit leaves an exit result, so only a cold start skips
        // the launcher; returning from the game always shows it.
        quickLaunch = exitResult == null &&
            _incomingZipName == null &&
            _pendingShortcut == null &&
            _appSettings.quickLaunchEnabled &&
            canStartGame;
      }

      final operation = _appLogger.startOperation(
        operationId: 'app-initialize',
        category: 'app.lifecycle',
        startedEvent: 'app_initialization_started',
        finishedEvent: 'app_initialization_finished',
        failureCode: 'app_initialization_failed',
      );
      await operation.run(initializeCore);
      if (quickLaunch) {
        await startGame();
      }
    } catch (error) {
      _message = _failureMessage('app_initialization_failed', '$error');
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  // 统一从 manifest 指向的激活槽刷新资源状态和游戏版本。
  Future<void> refresh() async {
    _manifest = await _requireManifestStore().read();
    _currentValidation =
        _importService.activeDirectory(_requirePaths(), _manifest) == null
            ? ResourceValidationResult.missing('尚未导入游戏资源')
            : _manifestValidation();
    _currentGameVersion = _currentValidation.gameVersion;
    if (_currentGameVersion == null) {
      _availableGameUpdate = null;
      _currentGameVersionIsAhead = false;
      _gameUpdateDetected = false;
    }
    notifyListeners();
  }

  // 导入时已完整校验激活槽并写入 manifest，之后直接沿用该结果。
  ResourceValidationResult _manifestValidation() =>
      ResourceValidationResult.valid(
        stats: ResourceStats(
            fileCount: _manifest.fileCount, totalBytes: _manifest.totalBytes),
        detectedTitle: _manifest.detectedTitle,
        packageId: _manifest.packageId,
        gameVersion: _manifest.gameVersion,
        buildProfile: _manifest.buildProfile,
        gpNextVersion: _manifest.gpNextVersion,
        gpNextCompatibilityError: _manifest.gpNextCompatibilityError,
      ).asReady();

  /// Applies the saved feed at once, then the remote one if it arrives.
  /// Fetched links replace the built-in ones and are saved with the feed, so
  /// they stay in use offline and when a later file leaves them out.
  Future<void> refreshAnnouncement() async {
    final cacheFile =
        File(p.join(_requirePaths().root.path, 'announcements.json'));
    final cached = await _announcementService.loadCached(cacheFile);
    if (cached != null) _applyFeed(cached);
    final feed = await _announcementService.fetch();
    if (feed == null) return;
    _applyFeed(feed);
    await _announcementService.save(cacheFile, feed, _links);
  }

  void _applyFeed(AnnouncementFeed feed) {
    _announcement = feed.announcement;
    _seasonalTheme = feed.theme;
    _links = _links.merge(feed.urls);
    notifyListeners();
  }

  /// True while the current announcement has not been shown to the user.
  bool get hasUnseenAnnouncement {
    final announcement = _announcement;
    return announcement != null &&
        announcement.id != _appSettings.seenAnnouncementId;
  }

  Future<void> markAnnouncementSeen() async {
    final announcement = _announcement;
    if (announcement == null || _appSettingsStore == null) return;
    await _updateAppSettings(
      _appSettings.copyWith(seenAnnouncementId: announcement.id),
    );
  }

  Future<void> refreshAboutContent() async {
    final paths = _requirePaths();
    _aboutContent = await _aboutContentService.refreshContent(
      cacheFile: File(p.join(paths.root.path, 'about_content.json')),
    );
    notifyListeners();
  }

  Future<void> checkForUpdates({bool silent = false}) async {
    _updateCheckInProgress = true;
    if (!silent) {
      _message = null;
    }
    notifyListeners();

    try {
      await _loadCurrentAppVersion();
      notifyListeners();
      final results = await Future.wait([
        _checkAppForUpdate(),
        _checkGameForUpdate(),
      ]);
      if (!silent) {
        final appSucceeded = results[0];
        final gameSucceeded = results[1];
        final strings = AppStrings.current;
        if (!appSucceeded && !gameSucceeded) {
          _message = LauncherMessage(
            strings.updateCheckFailedBoth,
            'update_check_failed',
          );
        } else if (!appSucceeded) {
          _message = LauncherMessage(
            strings.updateCheckFailedLoader,
            'update_check_failed',
          );
        } else if (!gameSucceeded) {
          _message = LauncherMessage(
            strings.updateCheckFailedGame,
            'update_check_failed',
          );
        } else if (!_appUpdateDetected && !_gameUpdateDetected) {
          final currentGameVersion = _currentGameVersion;
          if (currentGameVersion == null) {
            _message = LauncherMessage(strings.loaderLatestGameUnknown(
              _currentAppVersion,
              hasCurrentResource,
              _latestGameVersion,
            ));
          } else if (_currentGameVersionIsAhead) {
            _message = LauncherMessage(strings.loaderLatestGameAhead(
              _currentAppVersion,
              currentGameVersion,
              _latestGameVersion,
            ));
          } else {
            _message = LauncherMessage(
              strings.bothUpToDate(_currentAppVersion, currentGameVersion),
            );
          }
        }
      }
    } finally {
      _updateCheckInProgress = false;
      notifyListeners();
    }
  }

  Future<bool> _checkAppForUpdate() async {
    try {
      final result = await _updateCheckService.checkForUpdate();
      final update = result.update;
      _latestAppVersion = result.latestVersion;
      if (update != null) {
        _currentAppVersion = update.currentVersion;
      }
      _appUpdateDetected = update != null;
      _availableUpdate =
          update?.tagName == _deferredUpdateTagName ? null : update;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _checkGameForUpdate({bool reuseLatestVersion = false}) async {
    final currentGameVersion = _currentGameVersion;
    if (currentGameVersion == null) {
      try {
        _latestGameVersion = await _gameUpdateCheckService.loadLatestVersion();
        _availableGameUpdate = null;
        _gameUpdateDetected = false;
        return true;
      } catch (_) {
        return false;
      }
    }
    try {
      final result = await _gameUpdateCheckService.check(
        currentVersion: currentGameVersion,
        latestVersion: reuseLatestVersion ? _latestGameVersion : null,
      );
      final update = result.update;
      _latestGameVersion = result.latestVersion;
      _currentGameVersionIsAhead = result.currentIsAhead;
      _gameUpdateDetected = update != null;
      _availableGameUpdate =
          update?.tagName == _deferredGameUpdateTagName ? null : update;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _loadCurrentAppVersion() async {
    final build = await _updateCheckService.loadInstalledBuild();
    _installedVersionName = build.versionName;
    _installedBuildNumber = build.buildNumber;
    _currentAppVersion = await _updateCheckService.loadCurrentVersion();
  }

  void deferUpdate(UpdateInfo update) {
    _deferredUpdateTagName = update.tagName;
    if (_availableUpdate?.tagName == update.tagName) {
      _availableUpdate = null;
    }
    notifyListeners();
  }

  void deferGameUpdate(GameUpdateInfo update) {
    _deferredGameUpdateTagName = update.tagName;
    if (_availableGameUpdate?.tagName == update.tagName) {
      _availableGameUpdate = null;
    }
    notifyListeners();
  }

  Future<void> importIncomingZip({
    required Future<bool> Function(String current, String incoming)
        confirmDowngrade,
  }) {
    _incomingZipName = null;
    return importResources(incoming: true, confirmDowngrade: confirmDowngrade);
  }

  Future<void> discardIncomingZip() async {
    _incomingZipName = null;
    notifyListeners();
    await _resourcePickerService.discardIncomingZip();
  }

  /// Imports a ZIP from the system picker, or with [incoming] the ZIP
  /// another app handed to the loader. A ZIP with an older game version than
  /// the active one replaces it only after [confirmDowngrade].
  Future<void> importResources({
    bool incoming = false,
    required Future<bool> Function(String current, String incoming)
        confirmDowngrade,
  }) {
    return _runImport(
      source: incoming ? 'incoming' : 'picker',
      showPickerNotice: !incoming,
      confirmDowngrade: confirmDowngrade,
      extract: (target) => _resourcePickerService.extractDocsZip(
        incoming: incoming,
        targetDirectory: target.directory,
        onProgress: _updateImportProgress,
      ),
    );
  }

  /// Imports a ZIP the launcher downloaded from the save server into the same
  /// import transaction the picker uses, so activation, validation and
  /// rollback behave identically.
  Future<void> importDownloadedZip({
    required File zipFile,
    required Future<bool> Function(String current, String incoming)
        confirmDowngrade,
  }) {
    return _runImport(
      source: 'server',
      showPickerNotice: false,
      confirmDowngrade: confirmDowngrade,
      extract: (target) => _resourcePickerService.extractLocalZip(
        zipPath: zipFile.path,
        targetDirectory: target.directory,
        onProgress: _updateImportProgress,
      ),
    );
  }

  /// The shared import transaction: prepare a target slot, hand it to
  /// [extract], then activate what it extracted.
  Future<void> _runImport({
    required String source,
    required bool showPickerNotice,
    required Future<bool> Function(String current, String incoming)
        confirmDowngrade,
    required Future<Directory?> Function(ImportTarget target) extract,
  }) async {
    final paths = _requirePaths();
    final manifestStore = _requireManifestStore();
    // 导入会重置并切换资源槽：游戏正在跑（桌面端本地服务器/安卓原生 loader
    // 正在读文件）或正在迁移存储位置时动手，会把正在读的目录抽走。
    if (_desktopGameActive ||
        _gameLaunchInFlight ||
        _storageBusy ||
        resourceTransactionBusy(_manifest.transactionState)) {
      const failure = '游戏正在运行或正在迁移资源，请先退出游戏再导入';
      _message = const LauncherMessage(failure, 'import_blocked_busy');
      notifyListeners();
      throw StateError(failure);
    }
    final previousVersion = hasCurrentResource ? _currentGameVersion : null;
    _message = null;
    _busy = true;
    _importCompletionTimer?.cancel();
    _versionUpgrade = null;
    _importTipIndex = Random().nextInt(AppStrings.current.importTips.length);
    _importProgress = ImportProgress.idle;
    _importProgressMeter = ImportProgressMeter();
    _startImportProgressTicker();
    notifyListeners();

    final operationId = _newOperationId('resource-import');
    _activeImportOperationId = operationId;
    _lastImportProgressLogAt = null;
    final importStopwatch = Stopwatch()..start();
    _appLogger.emit(
      level: LogLevel.info,
      category: 'resource.import',
      event: 'resource_import_started',
      outcome: LogOutcome.started,
      operationId: operationId,
      context: <String, Object?>{'source': source},
    );

    var restoreAwakeModeAfterImport = false;
    ImportTarget? importTarget;
    try {
      restoreAwakeModeAfterImport = await _keepScreenAwakeForImport();
      importTarget = await _importService.beginImport(
        paths: paths,
        manifestStore: manifestStore,
      );
      _appLogger.emit(
        level: LogLevel.info,
        category: 'resource.import',
        event: 'resource_import_target_prepared',
        outcome: LogOutcome.succeeded,
        operationId: operationId,
        context: <String, Object?>{'targetSlot': importTarget.slot.name},
      );
      if (showPickerNotice) {
        _message = LauncherMessage(AppStrings.current.openingFilePicker);
        notifyListeners();
      }
      _appLogger.emit(
        level: LogLevel.info,
        category: 'resource.import',
        event: 'resource_import_picker_started',
        outcome: LogOutcome.started,
        operationId: operationId,
      );
      final selectedSource = await extract(importTarget);
      if (selectedSource == null) {
        _appLogger.emit(
          level: LogLevel.info,
          category: 'resource.import',
          event: 'resource_import_picker_finished',
          outcome: LogOutcome.cancelled,
          operationId: operationId,
          context: const <String, Object?>{'stage': 'cancelled'},
        );
        _manifest = await _importService.abortImport(
          paths: paths,
          manifestStore: manifestStore,
        );
        importTarget = null;
        _message = LauncherMessage(AppStrings.current.zipSelectionCancelled);
        _appLogger.emit(
          level: LogLevel.info,
          category: 'resource.import',
          event: 'resource_import_finished',
          outcome: LogOutcome.cancelled,
          operationId: operationId,
          durationMs: importStopwatch.elapsedMilliseconds,
          context: const <String, Object?>{'stage': 'picking'},
        );
        return;
      }

      _appLogger.emit(
        level: LogLevel.info,
        category: 'resource.import',
        event: 'resource_import_picker_finished',
        outcome: LogOutcome.succeeded,
        operationId: operationId,
        context: const <String, Object?>{'stage': 'extracted'},
      );

      _importValidation = ResourceValidationResult.missing('正在校验 docs');
      _updateImportProgress(
        const ImportProgress(phase: ImportPhase.validating, message: '正在校验资源'),
      );
      _appLogger.emit(
        level: LogLevel.info,
        category: 'resource.validation',
        event: 'resource_validation_started',
        outcome: LogOutcome.started,
        operationId: operationId,
      );

      final activated = await _importService.completeImport(
        paths: paths,
        manifestStore: manifestStore,
        target: importTarget,
        confirmActivation: (candidate) async {
          final incomingVersion = candidate.gameVersion;
          final order = _versionOrder(incomingVersion, previousVersion);
          return order == null ||
              order >= 0 ||
              await confirmDowngrade(previousVersion!, incomingVersion!);
        },
        onProgress: _updateImportProgress,
      );
      importTarget = null;
      if (activated == null) {
        _manifest = await manifestStore.read();
        _importProgress = ImportProgress.idle;
        _message = LauncherMessage(AppStrings.current.downgradeDeclined);
        _appLogger.emit(
          level: LogLevel.info,
          category: 'resource.import',
          event: 'resource_import_finished',
          outcome: LogOutcome.cancelled,
          operationId: operationId,
          durationMs: importStopwatch.elapsedMilliseconds,
          context: const <String, Object?>{'stage': 'downgrade_declined'},
        );
        return;
      }
      _manifest = activated;
      _appLogger.emit(
        level: LogLevel.info,
        category: 'resource.validation',
        event: 'resource_validation_finished',
        outcome: LogOutcome.succeeded,
        operationId: operationId,
        context: <String, Object?>{
          'fileCount': _manifest.fileCount,
          'totalBytes': _manifest.totalBytes,
          'buildProfile': _manifest.buildProfile.name,
          'gpNextVersion': _manifest.gpNextVersion ?? 'none',
        },
      );
      _appLogger.emit(
        level: LogLevel.info,
        category: 'resource.import',
        event: 'resource_slot_activated',
        outcome: LogOutcome.succeeded,
        operationId: operationId,
        context: <String, Object?>{
          'activeSlot': _manifest.activeSlot?.name ?? 'none',
          'cleanupDeferred':
              _manifest.transactionState == TransactionState.cleaningOldSlot,
        },
      );
      _message = LauncherMessage(
        _manifest.transactionState == TransactionState.cleaningOldSlot
            ? AppStrings.current.importSucceededCleanupDeferred
            : AppStrings.current.importSucceeded,
      );
      _importProgressTickTimer?.cancel();
      if (restoreAwakeModeAfterImport) {
        await _setImportAwakeMode(false);
        restoreAwakeModeAfterImport = false;
      }
      _currentValidation = _importValidation = _manifestValidation();
      _currentGameVersion = _manifest.gameVersion;
      if (_currentGameVersion == null) {
        _availableGameUpdate = null;
        _currentGameVersionIsAhead = false;
        _gameUpdateDetected = false;
      }
      await _checkGameForUpdate(reuseLatestVersion: true);
      final newVersion = _manifest.gameVersion;
      if ((_versionOrder(newVersion, previousVersion) ?? 0) > 0) {
        // The upgrade stays on screen until the player dismisses it.
        _versionUpgrade = (from: previousVersion!, to: newVersion!);
      } else {
        _scheduleCompletedProgressReset();
      }
      await _saveJournal(_journal.recordImport(_importRecord()));
      _appLogger.emit(
        level: LogLevel.info,
        category: 'resource.import',
        event: 'resource_import_finished',
        outcome: LogOutcome.succeeded,
        operationId: operationId,
        durationMs: importStopwatch.elapsedMilliseconds,
        context: <String, Object?>{
          'stage': 'completed',
          'activeSlot': _manifest.activeSlot?.name ?? 'none',
          'fileCount': _manifest.fileCount,
          'totalBytes': _manifest.totalBytes,
        },
      );
    } on ResourcePickerFailure catch (failure) {
      _appLogger.emit(
        level: LogLevel.error,
        category: 'resource.import',
        event: 'resource_import_picker_finished',
        outcome: LogOutcome.failed,
        code: failure.code,
        operationId: operationId,
        error: failure,
        stackTrace: StackTrace.current,
      );
      if (importTarget != null) {
        _manifest = await _importService.abortImport(
          paths: paths,
          manifestStore: manifestStore,
        );
        importTarget = null;
      }
      _message = _failureMessage(failure.code, failure.message);
      _updateImportProgress(
        ImportProgress(
          phase: ImportPhase.failed,
          message: _message!.text,
          errorCode: failure.code,
        ),
      );
      _appLogger.emit(
        level: LogLevel.error,
        category: 'resource.import',
        event: 'resource_import_finished',
        outcome: LogOutcome.failed,
        code: failure.code,
        operationId: operationId,
        durationMs: importStopwatch.elapsedMilliseconds,
        error: failure,
        stackTrace: StackTrace.current,
      );
    } on ImportFailure catch (failure) {
      _message = _failureMessage(failure.code, failure.message);
      await refresh();
      _appLogger.emit(
        level: LogLevel.error,
        category: 'resource.validation',
        event: 'resource_validation_finished',
        outcome: LogOutcome.failed,
        code: failure.code,
        operationId: operationId,
        context: <String, Object?>{'stage': _importProgress.phase.name},
        error: failure,
        stackTrace: StackTrace.current,
      );
      _appLogger.emit(
        level: LogLevel.error,
        category: 'resource.import',
        event: 'resource_import_finished',
        outcome: LogOutcome.failed,
        code: failure.code,
        operationId: operationId,
        durationMs: importStopwatch.elapsedMilliseconds,
        error: failure,
        stackTrace: StackTrace.current,
      );
    } catch (error) {
      if (importTarget != null) {
        _manifest = await _importService.abortImport(
          paths: paths,
          manifestStore: manifestStore,
        );
        importTarget = null;
      }
      _message = _failureMessage('import_extract_failed', '$error');
      _updateImportProgress(
        ImportProgress(
          phase: ImportPhase.failed,
          message: _message!.text,
          errorCode: 'import_extract_failed',
        ),
      );
      await refresh();
      _appLogger.emit(
        level: LogLevel.error,
        category: 'resource.import',
        event: 'resource_import_finished',
        outcome: LogOutcome.failed,
        code: 'import_extract_failed',
        operationId: operationId,
        durationMs: importStopwatch.elapsedMilliseconds,
        error: error,
        stackTrace: StackTrace.current,
      );
    } finally {
      _importProgressTickTimer?.cancel();
      if (restoreAwakeModeAfterImport) {
        await _setImportAwakeMode(false);
      }
      _busy = false;
      _activeImportOperationId = null;
      notifyListeners();
    }
  }

  void _updateImportProgress(ImportProgress progress) {
    final meter = _importProgressMeter ??= ImportProgressMeter();
    _importProgress = meter.measure(progress);
    final now = DateTime.now();
    final lastLogAt = _lastImportProgressLogAt;
    if (lastLogAt == null ||
        now.difference(lastLogAt) >= const Duration(seconds: 1)) {
      _lastImportProgressLogAt = now;
      _appLogger.emit(
        level: LogLevel.debug,
        category: 'resource.import',
        event: 'resource_import_progress',
        outcome: LogOutcome.observed,
        operationId: _activeImportOperationId,
        context: <String, Object?>{
          'stage': progress.phase.name,
          'processedBytes': progress.copiedBytes,
          'totalBytes': progress.totalBytes,
          'processedFiles': progress.copiedFiles,
          'totalFiles': progress.totalFiles,
        },
      );
    }
    notifyListeners();
  }

  void _startImportProgressTicker() {
    _importProgressTickTimer?.cancel();
    _importProgressTickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (isImporting) {
        _updateImportProgress(_importProgress);
      }
    });
  }

  void dismissImportProgress() {
    if (isImporting || _importProgress.phase == ImportPhase.idle) {
      return;
    }
    _importCompletionTimer?.cancel();
    _versionUpgrade = null;
    _importProgress = ImportProgress.idle;
    notifyListeners();
  }

  Future<void> _setImportAwakeMode(bool enabled) async {
    try {
      await (enabled ? WakelockPlus.enable() : WakelockPlus.disable());
    } catch (_) {
      // Import progress remains functional when a platform cannot toggle wakelock.
    }
  }

  Future<bool> _keepScreenAwakeForImport() async {
    var alreadyEnabled = false;
    try {
      alreadyEnabled = await WakelockPlus.enabled;
    } catch (_) {
      // Query failures fall back to the normal enable/disable import lifecycle.
    }
    if (alreadyEnabled) {
      return false;
    }
    await _setImportAwakeMode(true);
    return true;
  }

  void _scheduleCompletedProgressReset() {
    _importCompletionTimer?.cancel();
    _importCompletionTimer = Timer(
      const Duration(seconds: 2),
      () {
        if (_importProgress.phase != ImportPhase.completed) {
          return;
        }
        _importProgress = ImportProgress.idle;
        notifyListeners();
      },
    );
  }

  @override
  void dispose() {
    _remoteCancellation?.cancel();
    _remoteResourceService.abortActiveRequests();
    _importCompletionTimer?.cancel();
    _importProgressTickTimer?.cancel();
    super.dispose();
  }

  /// 当前游玩所用的游戏版本（存档按版本隔离用）。
  ///
  /// 本地形态用资源包版本；在线形态用**服务器当前那套资源**的版本，
  /// 否则会用本地残留的旧版本号给存档分区，导致存档写错版本目录。
  String _playGameVersion() {
    if (playMode == PlayMode.online) {
      final remote = _remoteManifest?.gameVersion?.trim() ?? '';
      if (remote.isNotEmpty) return remote;
    }
    return (currentGameVersion ?? '').trim();
  }

  /// 在线形态进入游戏前，尽力把服务器的资源清单拉下来。
  ///
  /// 存档按游戏版本分区：在线形态必须用**服务器当前那套资源**的版本号。
  /// 如果只用户本地残留的版本（在线模式本来就不需要本地资源，常常是空的或过期的），
  /// 存档会被记到错误的版本目录下 —— 表现为「在线玩了一晚上，本地进游戏看不到存档」。
  /// 拉取失败不阻断启动：退化成当前已知版本，仅记录日志。
  Future<void> _ensureOnlineGameVersion() async {
    if (playMode != PlayMode.online) return;
    if ((_remoteManifest?.gameVersion ?? '').trim().isNotEmpty) return;
    final base = _appSettings.effectiveServerBaseUrl;
    final token = _appSettings.deviceToken.trim();
    if (base.isEmpty || token.isEmpty) return;
    try {
      final manifest = await _remoteResourceService.fetchManifest(
        token: token,
        baseUrl: base,
      );
      _remoteManifest = manifest;
      _appLogger.emit(
        level: LogLevel.info,
        category: 'game.host',
        event: 'online_manifest_loaded',
        outcome: LogOutcome.succeeded,
        context: <String, Object?>{'gameVersion': manifest.gameVersion ?? ''},
      );
    } catch (error) {
      // 服务器拒绝令牌时一并清理登录态，否则在线形态会一直白屏式失败
      await _handleTokenRejected(error);
      _appLogger.emit(
        level: LogLevel.warn,
        category: 'game.host',
        event: 'online_manifest_failed',
        outcome: LogOutcome.failed,
        code: 'online_manifest_unavailable',
        error: error,
      );
    }
  }

  /// 安卓在线形态启动。
  ///
  /// 在线形态必须已登录：`/_save/online/` 走 Bearer 鉴权（不用 authentik cookie，
  /// 因为 App 的 WebView 是跨站环境带不上 cookie）。
  Future<void> _startAndroidOnlineGame(AppPaths paths) async {
    final base = _appSettings.effectiveServerBaseUrl;
    if (base.isEmpty) {
      const failure = '还没有配置服务器地址，无法在线游玩';
      _message = const LauncherMessage(failure, 'online_play_no_server');
      notifyListeners();
      throw StateError(failure);
    }
    if (!_appSettings.hasDeviceToken) {
      const failure = '在线游玩需要先登录账号';
      _message = const LauncherMessage(failure, 'online_play_needs_signin');
      notifyListeners();
      throw StateError(failure);
    }
    // 必须**先**确认服务器当前的游戏版本，再构造 session：
    // session.gameVersion 会传给原生心跳（/_save/app/online/enter）和会话编解码，
    // 用旧版本号上报会让在线登记挂到错的游戏版本上。
    await _ensureOnlineGameVersion();
    final session = GameSession(
      sessionId: _newGameSessionId(),
      packageId: null,
      resourceRoot: paths.root.path,
      appRoot: paths.root.path,
      mode: GameSessionMode.online,
      originOverride: base,
      // 原生侧用它们做在线会话心跳（Dart 定时器随引擎销毁活不下来）
      gameVersion: _playGameVersion(),
      deviceId: _appSettings.deviceAccount.trim().isEmpty
          ? 'launcher'
          : _appSettings.deviceAccount.trim(),
      platform: gameHostPlatform,
      // 服务端 /_save/online/ 是「游戏本体 + Bearer 鉴权 + 不注入脚本」的路由
      entryPath: '_save/online/index.html',
      activationGeneration: _manifest.generation,
      hasGpNext: hasGpNext,
      gpNextCompatible: gpNextCompatible,
      gpNextVersion: gpNextVersion,
      watermarkEnabled: watermarkEnabled,
      autoCollectSunEnabled: _manifest.autoCollectSunEnabled,
      detailedAudioDiagnosticsEnabled: detailedAudioDiagnosticsEnabled,
      renderScale: renderResolution.scale,
      screenFit: screenFit,
      touchDiagnosticsEnabled: toolShedUnlocked && touchDiagnosticsEnabled,
      gestureHint: _appSettings.gestureHintShown
          ? null
          : AppStrings.current.gestureHintLines(gameHostPlatform),
      allowedRemoteHosts: _allowedRemoteHosts(),
      gpNextRoot: paths.gpNextDir.path,
      exportTemporaryRoot: Directory(p.join(paths.gpNextDir.path, '.exports')).path,
    );
    final store = _gameSessionStore ??= GameSessionStore(paths.root);
    // 存档桥必须先落盘：原生侧从 appRoot 读它拿设备令牌
    await _prepareSaveBridge(paths.root);
    if (_appSettings.gestureHintShown == false && session.gestureHint != null) {
      await _updateAppSettings(_appSettings.copyWith(gestureHintShown: true));
    }
    await store.prepare(session);
    // 心跳不在这里起：MainActivity 拉起 GameActivity 后会 finish，Flutter 引擎
    // 随之销毁，Dart 定时器活不过一个 tick。在线会话的心跳与注销由原生
    // GameActivity 负责（见 OnlineGameResourceClient + GameActivity.startOnlineHeartbeat）。
    final operation = _appLogger.startOperation(
      operationId: _newOperationId('game-launch-online'),
      category: 'game.host',
      startedEvent: 'game_host_launch_started',
      finishedEvent: 'game_host_launch_finished',
      failureCode: 'game_host_launch_failed',
      gameSessionId: session.sessionId,
    );
    await operation.run(() => _gameHost.launch(session));
  }

  /// 桌面端准备游戏：起本地服务器（本地资源 / 反代上游），返回要加载的地址。
  ///
  /// 两种形态都经过 [LocalResourceServer]，页面 origin 固定是 127.0.0.1，
  /// 存档桥（设备令牌）注入方式相同 —— 这就是「存档行为一致」的实现基础。
  Future<DesktopGameLaunch> prepareDesktopGame() async {
    // 桌面端的启动互斥：prepareDesktopGame 会起本地资源服务器 + CEF 窗口，
    // 而 _desktopGameActive 要等服务器起来之后才置位，中间这段 await 里
    // 连点两次「开始游戏」就会起两个服务器、两个窗口（端口与句柄都翻倍）。
    if (_gameLaunchInFlight) {
      throw StateError('正在启动游戏，请稍候');
    }
    if (_desktopGameActive) {
      throw StateError('游戏已经在运行');
    }
    _gameLaunchInFlight = true;
    try {
      return await _prepareDesktopGameInternal();
    } finally {
      _gameLaunchInFlight = false;
    }
  }

  Future<DesktopGameLaunch> _prepareDesktopGameInternal() async {
    final paths = _requirePaths();
    _message = null;
    final mode = playMode;
    final base = _appSettings.effectiveServerBaseUrl;

    if (mode == PlayMode.online && base.isEmpty) {
      const failure = '还没有配置服务器地址，无法在线游玩';
      _message = const LauncherMessage(failure, 'online_play_no_server');
      notifyListeners();
      throw StateError(failure);
    }
    Directory? resourceDirectory;
    if (mode == PlayMode.local) {
      if (!_currentValidation.isValid) {
        _message = _failureMessage(
          _currentValidation.errorCode,
          _currentValidation.errorMessage,
        );
        notifyListeners();
        throw StateError(_message!.text);
      }
      resourceDirectory = _importService.activeDirectory(paths, _manifest);
      if (resourceDirectory == null) {
        const failure = '没有可用的资源包';
        _message = const LauncherMessage(failure, 'local_play_no_resource');
        notifyListeners();
        throw StateError(failure);
      }
    }

    await _ensureOnlineGameVersion();
    final bridge = await buildSaveBridgeScript();
    final server = await LocalResourceServer.start(
      root: resourceDirectory,
      bridgeScript: bridge,
      upstream: mode == PlayMode.online ? Uri.parse('$base/') : null,
    );
    // 服务器已经占住端口和句柄：从这里往后的任何失败都必须停掉它
    try {
      return await _finishDesktopPrepare(server, bridge, mode, base);
    } catch (_) {
      await _stopOnlineHeartbeat();
      await server.stop();
      rethrow;
    }
  }

  Future<DesktopGameLaunch> _finishDesktopPrepare(
    LocalResourceServer server,
    String bridge,
    PlayMode mode,
    String base,
  ) async {
    if (mode == PlayMode.online) {
      _startOnlineHeartbeat();
    }
    _desktopGameActive = true;
    notifyListeners();
    _appLogger.emit(
      level: LogLevel.info,
      category: 'game.host',
      event: 'desktop_host_started',
      outcome: LogOutcome.succeeded,
      context: <String, Object?>{
        'mode': mode.name,
        'port': server.port,
        'cloud_saves': bridge.isNotEmpty,
        if (mode == PlayMode.online) 'server': maskedServerBase(base),
      },
    );
    return DesktopGameLaunch(
      uri: server.baseUri,
      server: server,
      mode: mode == PlayMode.online ? DesktopPlayMode.online : DesktopPlayMode.local,
      hasCloudSaves: bridge.isNotEmpty,
    );
  }

  Timer? _onlineHeartbeatTimer;

  /// 在线游玩心跳：服务器据此判断「能否安全地切换资源版本」。
  ///
  /// 失败一律静默 —— 心跳只是给服务端做更新的让路判断，
  /// 不能因为网络抖动让玩家进不去游戏。
  Future<void> _onlineHeartbeat() async {
    final base = _appSettings.effectiveServerBaseUrl;
    final token = _appSettings.deviceToken.trim();
    if (base.isEmpty || token.isEmpty) return;
    final deviceId = _appSettings.deviceAccount.trim().isEmpty
        ? 'launcher'
        : _appSettings.deviceAccount.trim();
    final body = jsonEncode(<String, Object?>{
      'gameVersion': _playGameVersion(),
      'device': {'id': deviceId, 'label': Platform.operatingSystem},
    });
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client.postUrl(Uri.parse('$base/_save/app/online/enter'));
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.add(utf8.encode(body));
      final response = await request.close();
      await response.drain<void>();
    } catch (_) {
      // 静默：心跳失败不影响游玩
    } finally {
      client.close(force: true);
    }
  }

  void _startOnlineHeartbeat() {
    _onlineHeartbeatTimer?.cancel();
    unawaited(_onlineHeartbeat());
    _onlineHeartbeatTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => unawaited(_onlineHeartbeat()),
    );
  }

  Future<void> _stopOnlineHeartbeat() async {
    _onlineHeartbeatTimer?.cancel();
    _onlineHeartbeatTimer = null;
    final base = _appSettings.effectiveServerBaseUrl;
    final token = _appSettings.deviceToken.trim();
    if (base.isEmpty || token.isEmpty) return;
    final deviceId = _appSettings.deviceAccount.trim().isEmpty
        ? 'launcher'
        : _appSettings.deviceAccount.trim();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client.postUrl(Uri.parse('$base/_save/app/online/leave'));
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.add(utf8.encode(jsonEncode(<String, Object?>{
        'device': {'id': deviceId},
      })));
      final response = await request.close();
      await response.drain<void>();
    } catch (_) {
    } finally {
      client.close(force: true);
    }
  }

  /// 桌面端游戏窗口关闭后收尾。
  Future<void> finishDesktopGame(DesktopGameLaunch launch) async {
    _desktopGameActive = false;
    notifyListeners();
    await _stopOnlineHeartbeat();
    await launch.server.stop();
    _appLogger.emit(
      level: LogLevel.info,
      category: 'game.host',
      event: 'desktop_host_stopped',
      outcome: LogOutcome.succeeded,
      context: <String, Object?>{'mode': launch.mode.name},
    );
  }

  Future<void> startGame() async {
    final paths = _requirePaths();
    if (_gameLaunchInFlight) {
      // 快捷键与按钮可能同时触发；重复进入会起两个资源服务器/两个窗口
      return;
    }
    if (_storageBusy || isImporting) {
      const failure = '正在迁移资源或导入资源，请稍候再开始游戏';
      _message = const LauncherMessage(failure, 'launch_blocked_busy');
      notifyListeners();
      throw StateError(failure);
    }
    _gameLaunchInFlight = true;
    try {
      await _startGameInternal(paths);
    } finally {
      _gameLaunchInFlight = false;
      notifyListeners();
    }
  }

  Future<void> _startGameInternal(AppPaths paths) async {
    _message = null;

    // ── 安卓在线形态 ──
    // 不读本地资源，会话 origin 直接指向服务器的 /_save/online/（Bearer 鉴权、
    // 服务端不做脚本注入），原生侧带令牌取资源并注入同一份存档桥。
    if (playMode == PlayMode.online && Platform.isAndroid) {
      return _startAndroidOnlineGame(paths);
    }

    final activeDirectory = _importService.activeDirectory(paths, _manifest);
    if (!_currentValidation.isValid) {
      _message = _failureMessage(
        _currentValidation.errorCode,
        _currentValidation.errorMessage,
      );
      notifyListeners();
      _appLogger.emit(
        level: LogLevel.error,
        category: 'game.host',
        event: 'game_host_launch_finished',
        outcome: LogOutcome.failed,
        code: 'resource_validation_failed',
        message: _currentValidation.errorMessage,
      );
      throw StateError(_message!.text);
    }
    // The native host creates it on the first export, after GP-Next startup.
    final exportRoot = Directory(p.join(paths.gpNextDir.path, '.exports'));
    final session = GameSession(
      sessionId: _newGameSessionId(),
      packageId: _currentValidation.packageId,
      resourceRoot: activeDirectory!.path,
      platform: gameHostPlatform,
      entryPath: 'index.html',
      activationGeneration: _manifest.generation,
      hasGpNext: hasGpNext,
      gpNextCompatible: gpNextCompatible,
      gpNextVersion: gpNextVersion,
      watermarkEnabled: watermarkEnabled,
      autoCollectSunEnabled: _manifest.autoCollectSunEnabled,
      detailedAudioDiagnosticsEnabled: detailedAudioDiagnosticsEnabled,
      renderScale: renderResolution.scale,
      screenFit: screenFit,
      touchDiagnosticsEnabled: toolShedUnlocked && touchDiagnosticsEnabled,
      gestureHint: _appSettings.gestureHintShown
          ? null
          : AppStrings.current.gestureHintLines(gameHostPlatform),
      allowedRemoteHosts: _allowedRemoteHosts(),
      gpNextRoot: paths.gpNextDir.path,
      exportTemporaryRoot: exportRoot.path,
    );
    final store = _gameSessionStore ??= GameSessionStore(paths.root);
    Future<void> launch() async {
      // Written before the session starts: the native host inlines it.
      await _prepareSaveBridge(paths.root);
      await store.prepare(session);
      _importCompletionTimer?.cancel();
      _importProgressTickTimer?.cancel();
      // Saved first: the launcher engine is torn down once the game opens.
      if (session.gestureHint != null) {
        await _updateAppSettings(_appSettings.copyWith(gestureHintShown: true));
      }
      await _gameHost.launch(session);
    }

    final operation = _appLogger.startOperation(
      operationId: _newOperationId('game-launch'),
      category: 'game.host',
      startedEvent: 'game_host_launch_started',
      finishedEvent: 'game_host_launch_finished',
      failureCode: 'game_host_launch_failed',
      gameSessionId: session.sessionId,
    );
    await operation.run(launch);
  }

  static String _newOperationId(String prefix) =>
      '$prefix-${DateTime.now().toUtc().microsecondsSinceEpoch}';

  void _emitInitializationStage(String stage) {
    _appLogger.emit(
      level: LogLevel.debug,
      category: 'app.lifecycle',
      event: 'app_initialization_stage_changed',
      outcome: LogOutcome.observed,
      operationId: 'app-initialize',
      context: <String, Object?>{'stage': stage},
    );
  }

  DiagnosticSnapshot diagnostics({String? webViewEngineVersion}) {
    return buildDiagnosticSnapshot(
      appVersion: _currentAppVersion,
      paths: _requirePaths(),
      currentValidation: _currentValidation,
      importValidation: _importValidation,
      manifest: _manifest,
      gameHostPlatform: gameHostPlatform,
      webViewEngineVersion: webViewEngineVersion,
    );
  }

  Future<void> refreshLogs() async {
    if (_logSnapshotLoading) {
      return;
    }
    _logSnapshotLoading = true;
    notifyListeners();
    try {
      _logSnapshot = await _appLogger.loadSnapshot();
    } finally {
      _logSnapshotLoading = false;
      notifyListeners();
    }
  }

  Future<void> deleteLogHistory() async {
    await _appLogger.deleteHistory();
    await refreshLogs();
  }

  String buildLogText({String minimumLevel = 'INFO', bool errorsOnly = false}) {
    final snapshot = _logSnapshot;
    final buffer = StringBuffer(diagnostics().toLogText());
    if (snapshot == null) {
      buffer.writeln('\nstructuredLogs: unavailable');
      return buffer.toString();
    }
    buffer
      ..writeln('\nappSessionId: ${snapshot.appSessionId}')
      ..writeln('logPersisting: ${snapshot.persisting}')
      ..writeln('logDegraded: ${snapshot.degraded}')
      ..writeln('logDirectory: ${snapshot.logDirectory ?? 'unavailable'}')
      ..writeln('logBytes: ${snapshot.totalBytes}')
      ..writeln('logWriteFailures: ${snapshot.writeFailureCount}')
      ..writeln('logDropped: ${jsonEncode(snapshot.droppedByLevel)}')
      ..writeln('\nrecent events:');
    const ranks = <String, int>{
      'DEBUG': 0,
      'INFO': 1,
      'WARN': 2,
      'ERROR': 3,
      'FATAL': 4,
    };
    final minimumRank = ranks[minimumLevel] ?? 1;
    for (final event in snapshot.events) {
      final level = event['level']?.toString().toUpperCase() ?? 'INFO';
      if ((ranks[level] ?? 1) < minimumRank) {
        continue;
      }
      if (errorsOnly && level != 'ERROR' && level != 'FATAL') {
        continue;
      }
      buffer.writeln(jsonEncode(event));
    }
    return buffer.toString();
  }

  String buildDiagnosticSummary() {
    final buffer = StringBuffer(diagnostics().toCopyText());
    final snapshot = _logSnapshot;
    if (snapshot == null) {
      return buffer.toString();
    }
    buffer
      ..writeln()
      ..writeln('Structured logs:')
      ..writeln('appSessionId: ${snapshot.appSessionId}')
      ..writeln('persisting: ${snapshot.persisting}')
      ..writeln('degraded: ${snapshot.degraded}')
      ..writeln('writeFailures: ${snapshot.writeFailureCount}');
    for (final event in snapshot.events) {
      buffer.writeln(jsonEncode(event));
    }
    return buffer.toString();
  }

  Future<void> setWatermarkEnabled(bool enabled) {
    return _updateAppSettings(
      _appSettings.copyWith(watermarkEnabled: enabled),
    );
  }

  Future<void> setQuickLaunchEnabled(bool enabled) {
    return _updateAppSettings(
      _appSettings.copyWith(quickLaunchEnabled: enabled),
    );
  }

  Future<void> setRenderResolution(RenderResolution resolution) {
    return _updateAppSettings(
      _appSettings.copyWith(renderResolution: resolution),
    );
  }

  Future<void> setScreenFit(ScreenFit fit) {
    return _updateAppSettings(_appSettings.copyWith(screenFit: fit));
  }

  Future<void> setDetailedAudioDiagnosticsEnabled(bool enabled) {
    return _updateAppSettings(
      _appSettings.copyWith(detailedAudioDiagnosticsEnabled: enabled),
    );
  }

  Future<void> setThemePreference(ThemePreference preference) {
    return _updateAppSettings(
      _appSettings.copyWith(themePreference: preference),
    );
  }

  Future<void> setToolShedUnlocked(bool unlocked) {
    return _updateAppSettings(
      _appSettings.copyWith(toolShedUnlocked: unlocked),
    );
  }

  Future<void> setTouchDiagnosticsEnabled(bool enabled) {
    return _updateAppSettings(
      _appSettings.copyWith(touchDiagnosticsEnabled: enabled),
    );
  }

  /// Saves the address the user typed. Only an https origin is accepted (a
  /// loopback http address is allowed for a local server); a blank value
  /// clears it, which falls back to the address compiled in at build time.
  Future<bool> setServerBaseUrl(String value) async {
    final trimmed = value.trim();
    if (trimmed.isNotEmpty && normalizeServerBaseUrl(trimmed) == null) {
      return false;
    }
    await _updateAppSettings(_appSettings.copyWith(serverBaseUrl: trimmed));
    return true;
  }

  /// Saves a token the user pasted by hand. The account name is dropped
  /// because only the server can say whom a token belongs to.
  Future<void> setDeviceToken(String value) {
    final token = value.trim();
    return _updateAppSettings(
      _appSettings.copyWith(
        deviceToken: token,
        deviceAccount:
            token == _appSettings.deviceToken ? _appSettings.deviceAccount : '',
      ),
    );
  }

  /// Signs in on the save server's own authentik page inside a native WebView.
  ///
  /// The page posts `{token, id, base}` to `window.GardendlessBridge`; this
  /// method then proves the token with `/_save/app/whoami` before persisting
  /// it, so a half-finished authentik flow never looks like a working login.
  bool _loginInProgress = false;

  /// 登录流程进行中（按钮转圈用）。
  bool get loginInProgress => _loginInProgress;

  Future<void> loginWithAuthentik() async {
    if (_loginInProgress) return;
    _loginInProgress = true;
    notifyListeners();
    try {
      await _loginWithAuthentikImpl();
    } finally {
      _loginInProgress = false;
      notifyListeners();
    }
  }

  Future<void> _loginWithAuthentikImpl() async {
    if (_cloudLogin.inProgress) return;
    final base = _appSettings.effectiveServerBaseUrl;
    if (base.isEmpty) {
      _cloudLogin = CloudLoginStatus(
        phase: CloudLoginPhase.failed,
        errorCode: 'save_server_invalid',
        message: AppStrings.current.saveServerAddressRequired,
      );
      notifyListeners();
      return;
    }
    final operationId = _newOperationId('cloud-login');
    _cloudLogin = const CloudLoginStatus(phase: CloudLoginPhase.opening);
    notifyListeners();
    _appLogger.emit(
      level: LogLevel.info,
      category: 'cloud.login',
      event: 'cloud_login_started',
      outcome: LogOutcome.started,
      operationId: operationId,
      context: <String, Object?>{'server': maskedServerBase(base)},
    );
    try {
      final credentials = await _cloudLoginService.loginWithAuthentik(
        baseUrl: base,
        loginUrl: saveLoginUrl,
        title: AppStrings.current.cloudLoginTitle,
      );
      if (credentials == null) {
        _cloudLogin = CloudLoginStatus.idle;
        notifyListeners();
        _appLogger.emit(
          level: LogLevel.info,
          category: 'cloud.login',
          event: 'cloud_login_finished',
          outcome: LogOutcome.cancelled,
          operationId: operationId,
          context: <String, Object?>{'stage': 'sign_in_page'},
        );
        return;
      }
      final confirmedBase = normalizeServerBaseUrl(
            credentials.baseUrl.isEmpty ? base : credentials.baseUrl,
          ) ??
          base;
      _cloudLogin = const CloudLoginStatus(phase: CloudLoginPhase.verifying);
      notifyListeners();
      final identity = await _remoteResourceService.fetchWhoami(
        token: credentials.token,
        baseUrl: confirmedBase,
      );
      await _updateAppSettings(
        _appSettings.copyWith(
          serverBaseUrl: confirmedBase,
          deviceToken: credentials.token,
          deviceAccount: identity.user,
        ),
      );
      // The resource list is served with the new token; refresh it in place.
      _remoteManifest = null;
      _remoteManifestFailure = null;
      _cloudLogin = const CloudLoginStatus(phase: CloudLoginPhase.succeeded);
      notifyListeners();
      _appLogger.emit(
        level: LogLevel.info,
        category: 'cloud.login',
        event: 'cloud_login_finished',
        outcome: LogOutcome.succeeded,
        operationId: operationId,
        context: <String, Object?>{
          'stage': 'verified',
          'server': maskedServerBase(confirmedBase),
          'accountKnown': identity.user.isNotEmpty,
        },
      );
    } on CloudLoginFailure catch (failure) {
      _failCloudLogin(failure.code, failure.message);
      _appLogger.emit(
        level: LogLevel.warn,
        category: 'cloud.login',
        event: 'cloud_login_finished',
        outcome: LogOutcome.failed,
        code: failure.code,
        message: failure.message,
        operationId: operationId,
        context: <String, Object?>{'stage': 'sign_in_page'},
      );
    } on RemoteResourceFailure catch (failure) {
      _failCloudLogin(failure.code, failure.message);
      _appLogger.emit(
        level: LogLevel.warn,
        category: 'cloud.login',
        event: 'cloud_login_finished',
        outcome: LogOutcome.failed,
        code: failure.code,
        message: failure.message,
        operationId: operationId,
        context: <String, Object?>{'stage': 'verification'},
      );
    } catch (error, stackTrace) {
      _failCloudLogin('login_failed', '$error');
      _appLogger.emit(
        level: LogLevel.error,
        category: 'cloud.login',
        event: 'cloud_login_finished',
        outcome: LogOutcome.failed,
        code: 'login_failed',
        error: error,
        stackTrace: stackTrace,
        operationId: operationId,
        context: <String, Object?>{'stage': 'sign_in_page'},
      );
    }
  }

  /// Re-checks an already stored token with `whoami`, e.g. after switching
  /// servers or when the account name was never shown.
  Future<void> verifyCloudIdentity() async {
    final base = _appSettings.effectiveServerBaseUrl;
    final token = _appSettings.deviceToken.trim();
    if (base.isEmpty || token.isEmpty || _cloudLogin.inProgress) return;
    _cloudLogin = const CloudLoginStatus(phase: CloudLoginPhase.verifying);
    notifyListeners();
    try {
      final identity = await _remoteResourceService.fetchWhoami(
        token: token,
        baseUrl: base,
      );
      if (token != _appSettings.deviceToken.trim()) return;
      await _updateAppSettings(
        _appSettings.copyWith(deviceAccount: identity.user),
      );
      _cloudLogin = const CloudLoginStatus(phase: CloudLoginPhase.succeeded);
    } on RemoteResourceFailure catch (failure) {
      _cloudLogin = CloudLoginStatus(
        phase: CloudLoginPhase.failed,
        errorCode: failure.code,
        message: failure.message,
      );
    } catch (error, stackTrace) {
      _cloudLogin = const CloudLoginStatus(
        phase: CloudLoginPhase.failed,
        errorCode: 'login_failed',
        message: '身份校验失败',
      );
      _appLogger.emit(
        level: LogLevel.error,
        category: 'cloud.login',
        event: 'cloud_login_finished',
        outcome: LogOutcome.failed,
        code: 'login_failed',
        error: error,
        stackTrace: stackTrace,
        context: <String, Object?>{'stage': 'verification'},
      );
    } finally {
      if (_cloudLogin.inProgress) {
        _cloudLogin = CloudLoginStatus.idle;
      }
      notifyListeners();
    }
  }

  void _failCloudLogin(String code, String message) {
    _cloudLogin = CloudLoginStatus(
      phase: CloudLoginPhase.failed,
      errorCode: code,
      message: message,
    );
    notifyListeners();
  }

  /// Reads `{base}/_save/app/res/manifest.json` so the page can show which
  /// resource version the server offers before downloading it.
  Future<void> refreshRemoteManifest() async {
    final base = _appSettings.effectiveServerBaseUrl;
    final token = _appSettings.deviceToken.trim();
    if (base.isEmpty || token.isEmpty) {
      _remoteManifestFailure = (
        code: base.isEmpty ? 'save_server_invalid' : 'save_token_missing',
        message: AppStrings.current.saveServerNotConfigured,
      );
      _remoteManifest = null;
      notifyListeners();
      return;
    }
    if (_remoteManifestLoading) {
      return;
    }
    _remoteManifestLoading = true;
    _remoteManifestFailure = null;
    notifyListeners();
    try {
      _remoteManifest = await _remoteResourceService.fetchManifest(
        token: token,
        baseUrl: base,
      );
      final latest = _remoteManifest?.latestZip;
      _appLogger.emit(
        level: LogLevel.info,
        category: 'resource.remote',
        event: 'remote_resource_manifest_fetched',
        outcome: LogOutcome.succeeded,
        context: <String, Object?>{
          'gameVersion': _remoteManifest?.gameVersion ?? 'unknown',
          'zipName': latest?.name ?? 'none',
          'zipSize': latest?.size ?? 0,
        },
      );
    } on RemoteResourceFailure catch (failure) {
      _remoteManifest = null;
      _remoteManifestFailure = (code: failure.code, message: failure.message);
      _appLogger.emit(
        level: LogLevel.warn,
        category: 'resource.remote',
        event: 'remote_resource_manifest_fetched',
        outcome: LogOutcome.failed,
        code: failure.code,
        message: failure.message,
      );
    } catch (error, stackTrace) {
      _remoteManifest = null;
      _remoteManifestFailure = (
        code: 'resource_manifest_unavailable',
        message: '$error',
      );
      _appLogger.emit(
        level: LogLevel.warn,
        category: 'resource.remote',
        event: 'remote_resource_manifest_fetched',
        outcome: LogOutcome.failed,
        code: 'resource_manifest_unavailable',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _remoteManifestLoading = false;
      notifyListeners();
    }
  }

  /// Downloads the manifest's latest ZIP (resuming a partial one) and imports
  /// it through the same transaction the ZIP picker uses.
  Future<void> downloadLatestResources({
    required Future<bool> Function(String current, String incoming)
        confirmDowngrade,
  }) async {
    if (_busy || isImporting || _remoteDownload.active) {
      return;
    }
    final base = _appSettings.effectiveServerBaseUrl;
    final token = _appSettings.deviceToken.trim();
    if (base.isEmpty || token.isEmpty) {
      _remoteDownload = RemoteDownloadStatus(
        phase: RemoteDownloadPhase.failed,
        errorCode: base.isEmpty ? 'save_server_invalid' : 'save_token_missing',
        message: AppStrings.current.saveServerNotConfigured,
      );
      notifyListeners();
      return;
    }

    final paths = _requirePaths();
    final cancellation = RemoteDownloadCancellation();
    _remoteCancellation = cancellation;
    _remoteDownload = const RemoteDownloadStatus(
      phase: RemoteDownloadPhase.downloading,
    );
    notifyListeners();
    final stopwatch = Stopwatch()..start();
    var lastProgressNotify = DateTime.fromMillisecondsSinceEpoch(0);

    try {
      final manifest = _remoteManifest ??
          await _remoteResourceService.fetchManifest(
            token: token,
            baseUrl: base,
          );
      _remoteManifest = manifest;
      final zip = manifest.latestZip;
      if (zip == null) {
        throw const RemoteResourceFailure(
          'resource_manifest_empty',
          '服务器没有可用资源包',
        );
      }
      final directory = paths.downloadsDir;
      await directory.create(recursive: true);
      // The manifest name comes from the server: keep only its last segment so
      // it can never point outside the download directory.
      final safeName = p.basename(zip.name);
      final target = File(
        p.join(directory.path, safeName.isEmpty ? 'resources.zip' : safeName),
      );
      _remoteDownload = RemoteDownloadStatus(
        phase: RemoteDownloadPhase.downloading,
        version: zip.version,
        totalBytes: zip.size,
      );
      notifyListeners();

      final downloaded = await _remoteResourceService.downloadZip(
        manifest: manifest,
        token: token,
        baseUrl: base,
        targetFile: target,
        cancellation: cancellation,
        onProgress: (progress) {
          final now = DateTime.now();
          if (now.difference(lastProgressNotify) <
              const Duration(milliseconds: 200)) {
            return;
          }
          lastProgressNotify = now;
          _remoteDownload = RemoteDownloadStatus(
            phase: RemoteDownloadPhase.downloading,
            version: zip.version,
            receivedBytes: progress.receivedBytes,
            totalBytes:
                progress.totalBytes > 0 ? progress.totalBytes : zip.size,
          );
          notifyListeners();
        },
      );
      _appLogger.emit(
        level: LogLevel.info,
        category: 'resource.remote',
        event: 'remote_resource_download_finished',
        outcome: LogOutcome.succeeded,
        durationMs: stopwatch.elapsedMilliseconds,
        context: <String, Object?>{
          'zipName': zip.name,
          'zipSize': zip.size,
          'gameVersion': zip.version,
        },
      );

      _remoteDownload = RemoteDownloadStatus(
        phase: RemoteDownloadPhase.importing,
        version: zip.version,
        receivedBytes: zip.size,
        totalBytes: zip.size,
      );
      notifyListeners();

      await importDownloadedZip(
        zipFile: downloaded,
        confirmDowngrade: confirmDowngrade,
      );
      if (_importProgress.phase == ImportPhase.completed) {
        try {
          if (await downloaded.exists()) {
            await downloaded.delete();
          }
        } catch (_) {
          // A kept ZIP only costs space; the import already succeeded.
        }
        _remoteDownload = RemoteDownloadStatus(
          phase: RemoteDownloadPhase.completed,
          version: _manifest.gameVersion ?? zip.version,
          receivedBytes: zip.size,
          totalBytes: zip.size,
        );
        // 导入完成后占用会变（旧槽被清、新槽写入）：刷新一次，
        // 否则存储卡片上的数字会停留在导入前
        await refreshStorageUsage();
      } else {
        // The import progress region explains a declined or failed import.
        _remoteDownload = RemoteDownloadStatus.idle;
      }
    } on RemoteResourceCancelled {
      _remoteDownload = RemoteDownloadStatus.idle;
      _message = LauncherMessage(AppStrings.current.remoteDownloadCancelled);
      _appLogger.emit(
        level: LogLevel.info,
        category: 'resource.remote',
        event: 'remote_resource_download_finished',
        outcome: LogOutcome.cancelled,
        durationMs: stopwatch.elapsedMilliseconds,
      );
    } on RemoteResourceFailure catch (failure) {
      _remoteDownload = RemoteDownloadStatus(
        phase: RemoteDownloadPhase.failed,
        errorCode: failure.code,
        message: failure.message,
      );
      _appLogger.emit(
        level: LogLevel.error,
        category: 'resource.remote',
        event: 'remote_resource_download_finished',
        outcome: LogOutcome.failed,
        code: failure.code,
        message: failure.message,
        durationMs: stopwatch.elapsedMilliseconds,
      );
    } catch (error, stackTrace) {
      _remoteDownload = RemoteDownloadStatus(
        phase: RemoteDownloadPhase.failed,
        errorCode: 'resource_download_failed',
        message: '$error',
      );
      _appLogger.emit(
        level: LogLevel.error,
        category: 'resource.remote',
        event: 'remote_resource_download_finished',
        outcome: LogOutcome.failed,
        code: 'resource_download_failed',
        error: error,
        stackTrace: stackTrace,
        durationMs: stopwatch.elapsedMilliseconds,
      );
    } finally {
      _remoteCancellation = null;
      notifyListeners();
    }
  }

  /// Stops a running download; the bytes already on disk stay for a resume.
  void cancelRemoteDownload() {
    _remoteCancellation?.cancel();
    _remoteResourceService.abortActiveRequests();
  }

  /// Fetches the APK manifest with the device token and compares its
  /// versionCode with the installed build.
  Future<void> checkAppUpdate() async {
    if (_appUpdate.phase == AppUpdatePhase.checking || _appUpdate.active) {
      return;
    }
    final strings = AppStrings.current;
    final base = _appSettings.effectiveServerBaseUrl;
    final token = _appSettings.deviceToken.trim();
    if (base.isEmpty || token.isEmpty) {
      _appUpdate = AppUpdateStatus(
        phase: AppUpdatePhase.failed,
        release: _appUpdate.release,
        errorCode:
            base.isEmpty ? 'save_server_invalid' : 'app_update_not_signed_in',
        message: strings.saveServerNotConfigured,
      );
      notifyListeners();
      return;
    }

    _appUpdate = AppUpdateStatus(
      phase: AppUpdatePhase.checking,
      release: _appUpdate.release,
    );
    notifyListeners();
    final stopwatch = Stopwatch()..start();
    try {
      await _loadCurrentAppVersion();
      final installed = InstalledAppBuild(
        versionName: _installedVersionName,
        buildNumber: _installedBuildNumber,
      );
      final result = await _appUpdateService.check(
        token: token,
        baseUrl: base,
        installedVersionCode: parseVersionCode(installed.buildNumber),
        installedVersionName: installed.versionName,
      );
      _appUpdateManifest = result.manifest;
      final release = result.release;
      _appUpdateFile = null;
      if (!result.isUpgrade) {
        _appUpdate = AppUpdateStatus(
          phase: AppUpdatePhase.upToDate,
          release: release,
          totalBytes: release.size,
        );
      } else {
        // A previous run may have finished (or half finished) the bytes.
        final target = _appUpdateService.targetFile(
          _requirePaths().downloadsDir,
          release,
        );
        final onDisk = await _appUpdateService.partialBytes(target, release);
        final complete = release.size > 0 &&
            onDisk == release.size &&
            await _appUpdateService.verifyFile(target, release);
        if (complete) {
          _appUpdateFile = target;
        }
        _appUpdate = AppUpdateStatus(
          phase: complete ? AppUpdatePhase.ready : AppUpdatePhase.available,
          release: release,
          receivedBytes: onDisk,
          totalBytes: release.size,
          resumedBytes: onDisk,
        );
      }
      _appLogger.emit(
        level: LogLevel.info,
        category: 'app.update',
        event: 'app_update_checked',
        outcome: LogOutcome.succeeded,
        durationMs: stopwatch.elapsedMilliseconds,
        context: <String, Object?>{
          'installedVersion': installed.versionName,
          'installedCode': parseVersionCode(installed.buildNumber),
          'latestVersion': release.version,
          'latestCode': release.versionCode,
          'updateAvailable': result.isUpgrade,
        },
      );
    } on RemoteResourceFailure catch (failure) {
      _appUpdate = AppUpdateStatus(
        phase: AppUpdatePhase.failed,
        release: _appUpdate.release,
        errorCode: failure.code,
        message: failure.message,
      );
      _appLogger.emit(
        level: LogLevel.warn,
        category: 'app.update',
        event: 'app_update_checked',
        outcome: LogOutcome.failed,
        code: failure.code,
        message: failure.message,
        durationMs: stopwatch.elapsedMilliseconds,
      );
    } catch (error, stackTrace) {
      _appUpdate = AppUpdateStatus(
        phase: AppUpdatePhase.failed,
        release: _appUpdate.release,
        errorCode: 'app_update_check_failed',
        message: '$error',
      );
      _appLogger.emit(
        level: LogLevel.error,
        category: 'app.update',
        event: 'app_update_checked',
        outcome: LogOutcome.failed,
        code: 'app_update_check_failed',
        error: error,
        stackTrace: stackTrace,
        durationMs: stopwatch.elapsedMilliseconds,
      );
    } finally {
      notifyListeners();
    }
  }

  /// Downloads the release the last check found, resuming whatever an earlier
  /// attempt left in the downloads folder, and verifies its SHA-256.
  Future<void> downloadAppUpdate() async {
    final release = _appUpdate.release;
    if (release == null || _appUpdate.active) return;
    if (_appUpdate.phase == AppUpdatePhase.upToDate) {
      // Nothing to download: the server's build is not newer than this one.
      return;
    }
    final strings = AppStrings.current;
    final base = _appSettings.effectiveServerBaseUrl;
    final token = _appSettings.deviceToken.trim();
    if (base.isEmpty || token.isEmpty) {
      _appUpdate = _appUpdate.copyWith(
        phase: AppUpdatePhase.failed,
        errorCode: 'app_update_not_signed_in',
        message: strings.saveServerNotConfigured,
      );
      notifyListeners();
      return;
    }
    if (!_appInstallService.supported) {
      _appUpdate = _appUpdate.copyWith(
        phase: AppUpdatePhase.failed,
        errorCode: 'install_unsupported',
        message: 'In-app installation is only implemented on Android',
      );
      notifyListeners();
      return;
    }

    final File target;
    final Directory downloadsDir;
    final int onDisk;
    try {
      downloadsDir = _requirePaths().downloadsDir;
      await downloadsDir.create(recursive: true);
      target = _appUpdateService.targetFile(downloadsDir, release);
      onDisk = await _appUpdateService.partialBytes(target, release);
    } catch (error, stackTrace) {
      _appUpdate = _appUpdate.copyWith(
        phase: AppUpdatePhase.failed,
        errorCode: 'app_update_download_failed',
        message: '$error',
      );
      _appLogger.emit(
        level: LogLevel.error,
        category: 'app.update',
        event: 'app_update_download_finished',
        outcome: LogOutcome.failed,
        code: 'app_update_download_failed',
        error: error,
        stackTrace: stackTrace,
      );
      notifyListeners();
      return;
    }

    final cancellation = RemoteDownloadCancellation();
    _appUpdateCancellation = cancellation;
    _appUpdate = AppUpdateStatus(
      phase: AppUpdatePhase.downloading,
      release: release,
      receivedBytes: onDisk,
      totalBytes: release.size,
      resumedBytes: onDisk,
    );
    notifyListeners();
    final stopwatch = Stopwatch()..start();
    var lastProgressNotify = DateTime.fromMillisecondsSinceEpoch(0);

    try {
      if (release.size > 0 &&
          onDisk == release.size &&
          await _appUpdateService.verifyFile(target, release)) {
        // A previous attempt already finished and verified these bytes.
        _appUpdateFile = target;
      } else {
        // A file longer than announced cannot be a prefix of the APK.
        if (onDisk >= release.size) {
          await _appUpdateService.discard(target);
        }
        final file = await _appUpdateService.downloadRelease(
          release: release,
          token: token,
          baseUrl: base,
          targetFile: target,
          cancellation: cancellation,
          onProgress: (progress) {
            final now = DateTime.now();
            if (now.difference(lastProgressNotify) <
                const Duration(milliseconds: 200)) {
              return;
            }
            lastProgressNotify = now;
            final total =
                progress.totalBytes > 0 ? progress.totalBytes : release.size;
            _appUpdate = AppUpdateStatus(
              phase: progress.receivedBytes >= total && total > 0
                  ? AppUpdatePhase.verifying
                  : AppUpdatePhase.downloading,
              release: release,
              receivedBytes: progress.receivedBytes,
              totalBytes: total,
              resumedBytes: onDisk,
            );
            notifyListeners();
          },
        );
        _appUpdateFile = file;
      }
      _appUpdate = AppUpdateStatus(
        phase: AppUpdatePhase.ready,
        release: release,
        receivedBytes: release.size,
        totalBytes: release.size,
        resumedBytes: onDisk,
      );
      await _appUpdateService.removeStaleApks(downloadsDir, target);
      _appLogger.emit(
        level: LogLevel.info,
        category: 'app.update',
        event: 'app_update_download_finished',
        outcome: LogOutcome.succeeded,
        durationMs: stopwatch.elapsedMilliseconds,
        context: <String, Object?>{
          'version': release.version,
          'versionCode': release.versionCode,
          'sizeBytes': release.size,
          'resumedBytes': onDisk,
        },
      );
    } on RemoteResourceCancelled {
      final kept = await _appUpdateService.partialBytes(target, release);
      _appUpdate = AppUpdateStatus(
        phase: AppUpdatePhase.available,
        release: release,
        receivedBytes: kept,
        totalBytes: release.size,
        resumedBytes: kept,
        message: strings.remoteDownloadCancelled,
      );
      _appLogger.emit(
        level: LogLevel.info,
        category: 'app.update',
        event: 'app_update_download_finished',
        outcome: LogOutcome.cancelled,
        durationMs: stopwatch.elapsedMilliseconds,
        context: <String, Object?>{
          'version': release.version,
          'versionCode': release.versionCode,
          'resumedBytes': kept,
        },
      );
    } on RemoteResourceFailure catch (failure) {
      final kept = await _appUpdateService.partialBytes(target, release);
      _appUpdate = AppUpdateStatus(
        phase: AppUpdatePhase.failed,
        release: release,
        receivedBytes: kept,
        totalBytes: release.size,
        resumedBytes: kept,
        errorCode: failure.code,
        message: failure.message,
      );
      _appLogger.emit(
        level: LogLevel.error,
        category: 'app.update',
        event: 'app_update_download_finished',
        outcome: LogOutcome.failed,
        code: failure.code,
        message: failure.message,
        durationMs: stopwatch.elapsedMilliseconds,
      );
    } catch (error, stackTrace) {
      _appUpdate = _appUpdate.copyWith(
        phase: AppUpdatePhase.failed,
        errorCode: 'app_update_download_failed',
        message: '$error',
      );
      _appLogger.emit(
        level: LogLevel.error,
        category: 'app.update',
        event: 'app_update_download_finished',
        outcome: LogOutcome.failed,
        code: 'app_update_download_failed',
        error: error,
        stackTrace: stackTrace,
        durationMs: stopwatch.elapsedMilliseconds,
      );
    } finally {
      _appUpdateCancellation = null;
      notifyListeners();
    }
  }

  /// Stops a running APK download; the bytes on disk stay for a resume.
  void cancelAppUpdateDownload() {
    _appUpdateCancellation?.cancel();
    _remoteResourceService.abortActiveRequests();
  }

  // ===== Windows 更新（清单 + zip 下载 + 校验）=====

  /// 检查服务端是否发布了更新的 Windows 构建。
  Future<void> checkWindowsUpdate() async {
    if (!Platform.isWindows || _windowsUpdate.active) return;
    final strings = AppStrings.current;
    final base = _appSettings.effectiveServerBaseUrl;
    final token = _appSettings.deviceToken.trim();
    if (base.isEmpty || token.isEmpty) {
      _windowsUpdate = WindowsUpdateStatus(
        phase: AppUpdatePhase.failed,
        errorCode:
            base.isEmpty ? 'save_server_invalid' : 'windows_update_not_signed_in',
        message: strings.saveServerNotConfigured,
      );
      notifyListeners();
      return;
    }
    _windowsUpdate = WindowsUpdateStatus(
      phase: AppUpdatePhase.checking,
      release: _windowsUpdate.release,
    );
    notifyListeners();
    final stopwatch = Stopwatch()..start();
    try {
      await _loadCurrentAppVersion();
      final installed = InstalledAppBuild(
        versionName: _installedVersionName,
        buildNumber: _installedBuildNumber,
      );
      final manifest = await _windowsUpdateService.fetchManifest(
        token: token,
        baseUrl: base,
      );
      final release = manifest.latest;
      if (release == null) {
        throw const RemoteResourceFailure(
          'windows_update_manifest_empty',
          'Windows manifest has no latest release',
        );
      }
      final upgrade = isWindowsUpgrade(
        release: release,
        installedVersionCode: parseVersionCode(installed.buildNumber),
        installedVersionName: installed.versionName,
      );
      _windowsUpdateFile = null;
      if (!upgrade) {
        _windowsUpdate = WindowsUpdateStatus(
          phase: AppUpdatePhase.upToDate,
          release: release,
          totalBytes: release.size,
        );
      } else {
        final target = _windowsUpdateService.targetFile(
          _requirePaths().downloadsDir,
          release,
        );
        final complete = release.size > 0 &&
            await target.exists() &&
            await target.length() == release.size &&
            await _windowsUpdateService.verifyFile(target, release);
        if (complete) _windowsUpdateFile = target;
        _windowsUpdate = WindowsUpdateStatus(
          phase: complete ? AppUpdatePhase.ready : AppUpdatePhase.available,
          release: release,
          totalBytes: release.size,
        );
      }
      _appLogger.emit(
        level: LogLevel.info,
        category: 'app.update',
        event: 'windows_update_checked',
        outcome: LogOutcome.succeeded,
        durationMs: stopwatch.elapsedMilliseconds,
        context: <String, Object?>{
          'installedVersion': installed.versionName,
          'latestVersion': release.version,
          'latestCode': release.versionCode,
          'updateAvailable': upgrade,
        },
      );
    } on RemoteResourceFailure catch (failure) {
      _windowsUpdate = WindowsUpdateStatus(
        phase: AppUpdatePhase.failed,
        release: _windowsUpdate.release,
        errorCode: failure.code,
        message: failure.message,
      );
      _appLogger.emit(
        level: LogLevel.warn,
        category: 'app.update',
        event: 'windows_update_checked',
        outcome: LogOutcome.failed,
        code: failure.code,
        message: failure.message,
      );
    } catch (error, stackTrace) {
      _windowsUpdate = WindowsUpdateStatus(
        phase: AppUpdatePhase.failed,
        release: _windowsUpdate.release,
        errorCode: 'windows_update_check_failed',
        message: '$error',
      );
      _appLogger.emit(
        level: LogLevel.error,
        category: 'app.update',
        event: 'windows_update_checked',
        outcome: LogOutcome.failed,
        code: 'windows_update_check_failed',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      notifyListeners();
    }
  }

  /// 下载并校验 Windows zip。校验通过后才允许打开所在文件夹。
  Future<void> downloadWindowsUpdate() async {
    if (!Platform.isWindows) return;
    final release = _windowsUpdate.release;
    if (release == null || _windowsUpdate.active) return;
    if (_windowsUpdate.phase == AppUpdatePhase.upToDate) return;
    final strings = AppStrings.current;
    final base = _appSettings.effectiveServerBaseUrl;
    final token = _appSettings.deviceToken.trim();
    if (base.isEmpty || token.isEmpty) {
      _windowsUpdate = WindowsUpdateStatus(
        phase: AppUpdatePhase.failed,
        release: release,
        errorCode: 'windows_update_not_signed_in',
        message: strings.saveServerNotConfigured,
      );
      notifyListeners();
      return;
    }
    final Directory downloadsDir;
    final File target;
    try {
      downloadsDir = _requirePaths().downloadsDir;
      await downloadsDir.create(recursive: true);
      target = _windowsUpdateService.targetFile(downloadsDir, release);
    } catch (error, stackTrace) {
      _windowsUpdate = WindowsUpdateStatus(
        phase: AppUpdatePhase.failed,
        release: release,
        errorCode: 'windows_update_download_failed',
        message: '$error',
      );
      _appLogger.emit(
        level: LogLevel.error,
        category: 'app.update',
        event: 'windows_update_download_finished',
        outcome: LogOutcome.failed,
        code: 'windows_update_download_failed',
        error: error,
        stackTrace: stackTrace,
      );
      notifyListeners();
      return;
    }
    final cancellation = RemoteDownloadCancellation();
    _windowsUpdateCancellation = cancellation;
    _windowsUpdate = WindowsUpdateStatus(
      phase: AppUpdatePhase.downloading,
      release: release,
      totalBytes: release.size,
    );
    notifyListeners();
    final stopwatch = Stopwatch()..start();
    var lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      final file = await _windowsUpdateService.download(
        release: release,
        token: token,
        baseUrl: base,
        targetFile: target,
        cancellation: cancellation,
        onProgress: (progress) {
          final now = DateTime.now();
          if (now.difference(lastNotify) < const Duration(milliseconds: 200)) {
            return;
          }
          lastNotify = now;
          _windowsUpdate = WindowsUpdateStatus(
            phase: AppUpdatePhase.downloading,
            release: release,
            receivedBytes: progress.receivedBytes,
            totalBytes: progress.totalBytes,
          );
          notifyListeners();
        },
      );
      _windowsUpdate = WindowsUpdateStatus(
        phase: AppUpdatePhase.verifying,
        release: release,
        receivedBytes: release.size,
        totalBytes: release.size,
      );
      notifyListeners();
      if (!await _windowsUpdateService.verifyFile(file, release)) {
        throw const RemoteResourceFailure(
          'windows_update_checksum_mismatch',
          '下载的文件与清单 sha256 不一致',
        );
      }
      _windowsUpdateFile = file;
      await _windowsUpdateService.removeStaleZips(file);
      _windowsUpdate = WindowsUpdateStatus(
        phase: AppUpdatePhase.ready,
        release: release,
        receivedBytes: release.size,
        totalBytes: release.size,
      );
      _appLogger.emit(
        level: LogLevel.info,
        category: 'app.update',
        event: 'windows_update_download_finished',
        outcome: LogOutcome.succeeded,
        durationMs: stopwatch.elapsedMilliseconds,
        context: <String, Object?>{
          'version': release.version,
          'bytes': release.size,
        },
      );
    } on RemoteResourceFailure catch (failure) {
      _windowsUpdate = WindowsUpdateStatus(
        phase: AppUpdatePhase.failed,
        release: release,
        errorCode: failure.code,
        message: failure.message,
      );
      _appLogger.emit(
        level: LogLevel.warn,
        category: 'app.update',
        event: 'windows_update_download_finished',
        outcome: LogOutcome.failed,
        code: failure.code,
        message: failure.message,
      );
    } catch (error, stackTrace) {
      _windowsUpdate = WindowsUpdateStatus(
        phase: AppUpdatePhase.failed,
        release: release,
        errorCode: 'windows_update_download_failed',
        message: '$error',
      );
      _appLogger.emit(
        level: LogLevel.error,
        category: 'app.update',
        event: 'windows_update_download_finished',
        outcome: LogOutcome.failed,
        code: 'windows_update_download_failed',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _windowsUpdateCancellation = null;
      notifyListeners();
    }
  }

  void cancelWindowsUpdateDownload() {
    _windowsUpdateCancellation?.cancel();
    _remoteResourceService.abortActiveRequests();
  }

  /// 退出应用并让外部脚本替换安装目录。
  ///
  /// 这是唯一会终止进程的更新路径：调用前已经校验过 zip 的 sha256，
  /// 并且安装目录必须可写（Program Files 下需要管理员权限，直接拒绝）。
  Future<void> applyWindowsUpdate() async {
    if (!Platform.isWindows) return;
    final release = _windowsUpdate.release;
    final file = _windowsUpdateFile;
    if (release == null || file == null || _windowsUpdate.active) return;
    final target = await windowsInstallTarget();
    if (target == null) {
      _windowsUpdate = WindowsUpdateStatus(
        phase: AppUpdatePhase.failed,
        release: release,
        errorCode: 'windows_update_not_writable',
        message: '安装目录不可写，请用管理员权限运行或手动解压',
      );
      notifyListeners();
      return;
    }
    // 启动脚本前再校验一次：下载完成后文件仍可能被改坏
    if (!await _windowsUpdateService.verifyFile(file, release)) {
      _windowsUpdate = WindowsUpdateStatus(
        phase: AppUpdatePhase.failed,
        release: release,
        errorCode: 'windows_update_checksum_mismatch',
        message: '更新包校验失败，请重新下载',
      );
      notifyListeners();
      return;
    }
    try {
      final script = await WindowsUpdaterScript.write(
        File(p.join(file.parent.path, 'apply-windows-update.ps1')),
      );
      _windowsUpdate = WindowsUpdateStatus(
        phase: AppUpdatePhase.installing,
        release: release,
      );
      notifyListeners();
      _appLogger.emit(
        level: LogLevel.info,
        category: 'app.update',
        event: 'windows_update_apply_started',
        outcome: LogOutcome.started,
        context: <String, Object?>{
          'version': release.version,
          'target': target.target.path,
        },
      );
      await Process.start(
        'powershell.exe',
        <String>[
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          script.path,
          '-WaitPid',
          pid.toString(),
          '-Zip',
          file.path,
          '-Target',
          target.target.path,
          '-Exe',
          target.exe,
        ],
        mode: ProcessStartMode.detached,
      );
      exit(0);
    } catch (error, stackTrace) {
      _windowsUpdate = WindowsUpdateStatus(
        phase: AppUpdatePhase.failed,
        release: release,
        errorCode: 'windows_update_apply_failed',
        message: '$error',
      );
      _appLogger.emit(
        level: LogLevel.error,
        category: 'app.update',
        event: 'windows_update_apply_failed',
        outcome: LogOutcome.failed,
        code: 'windows_update_apply_failed',
        error: error,
        stackTrace: stackTrace,
      );
      notifyListeners();
    }
  }

  /// 打开已校验 zip 所在目录，方便用户退出后解压覆盖。
  Future<void> openWindowsUpdateFolder() async {
    final file = _windowsUpdateFile;
    if (!Platform.isWindows || file == null) return;
    try {
      await Process.start(
        'explorer.exe',
        <String>[file.parent.path],
        mode: ProcessStartMode.detached,
      );
    } catch (error, stackTrace) {
      _appLogger.emit(
        level: LogLevel.warn,
        category: 'app.update',
        event: 'windows_update_open_folder_failed',
        outcome: LogOutcome.failed,
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Re-checks everything the server promised before opening the installer:
  /// the manifest's package is this app, its versionCode is newer than the
  /// installed one, and the file still hashes to the published SHA-256.
  Future<void> installAppUpdate() async {
    final release = _appUpdate.release;
    final file = _appUpdateFile;
    if (release == null || file == null) {
      _appUpdate = _appUpdate.copyWith(
        phase: AppUpdatePhase.failed,
        errorCode: 'app_update_not_downloaded',
      );
      notifyListeners();
      return;
    }
    if (!_appInstallService.supported) {
      _appUpdate = _appUpdate.copyWith(
        phase: AppUpdatePhase.failed,
        errorCode: 'install_unsupported',
        message: 'In-app installation is only implemented on Android',
      );
      notifyListeners();
      return;
    }

    final installed = await _updateCheckService.loadInstalledBuild();
    final installedPackage =
        await _updateCheckService.loadInstalledPackageName();
    if (release.packageName != installedPackage) {
      _appUpdate = _appUpdate.copyWith(
        phase: AppUpdatePhase.failed,
        errorCode: 'app_update_package_mismatch',
        message: '${release.packageName} != $installedPackage',
      );
      notifyListeners();
      return;
    }
    final installedCode = parseVersionCode(installed.buildNumber);
    final newer = installedCode != null
        ? release.versionCode > installedCode
        : compareVersionNames(release.version, installed.versionName) > 0;
    if (!newer) {
      _appUpdate = _appUpdate.copyWith(
        phase: AppUpdatePhase.failed,
        errorCode: 'app_update_not_newer',
        message: '${release.version} / ${release.versionCode} '
            'vs ${installed.versionName} / ${installed.buildNumber}',
      );
      notifyListeners();
      return;
    }
    if (!await _appUpdateService.verifyFile(file, release)) {
      await _appUpdateService.discard(file);
      _appUpdateFile = null;
      _appUpdate = _appUpdate.copyWith(
        phase: AppUpdatePhase.failed,
        errorCode: 'app_update_checksum_mismatch',
      );
      notifyListeners();
      return;
    }

    _appUpdate = _appUpdate.copyWith(
      phase: AppUpdatePhase.installing,
      receivedBytes: release.size,
      totalBytes: release.size,
    );
    notifyListeners();
    final stopwatch = Stopwatch()..start();
    try {
      await _appInstallService.installApk(file.path);
      _appUpdate = _appUpdate.copyWith(phase: AppUpdatePhase.ready);
      _appLogger.emit(
        level: LogLevel.info,
        category: 'app.update',
        event: 'app_update_install_requested',
        outcome: LogOutcome.succeeded,
        durationMs: stopwatch.elapsedMilliseconds,
        context: <String, Object?>{
          'version': release.version,
          'versionCode': release.versionCode,
        },
      );
    } on AppInstallFailure catch (failure) {
      _appUpdate = _appUpdate.copyWith(
        phase: AppUpdatePhase.failed,
        errorCode: failure.code,
        message: failure.message,
        needsInstallPermission:
            failure.code == AppInstallService.permissionRequiredCode,
      );
      _appLogger.emit(
        level: LogLevel.warn,
        category: 'app.update',
        event: 'app_update_install_requested',
        outcome: LogOutcome.failed,
        code: failure.code,
        message: failure.message,
        durationMs: stopwatch.elapsedMilliseconds,
      );
    } finally {
      notifyListeners();
    }
  }

  /// Opens the system screen that grants this package the right to install
  /// APKs (Android 8+).
  Future<void> openAppInstallPermissionSettings() async {
    final opened = await _appInstallService.openPermissionSettings();
    if (!opened) {
      _message = LauncherMessage(
        AppStrings.current.appUpdatePermissionSettingsUnavailable,
      );
      notifyListeners();
    }
  }

  /// Hosts the game may open outside the WebView. The save server joins them
  /// once a device token is set, so an export can reach it.
  List<String> _allowedRemoteHosts() {
    final hosts = hasGpNext
        ? <String>['pvzge.com', 'github.com', 'discord.gg']
        : <String>[];
    final serverHost = Uri.tryParse(_appSettings.effectiveServerBaseUrl)?.host;
    if (_appSettings.hasDeviceToken &&
        serverHost != null &&
        serverHost.isNotEmpty &&
        !hosts.contains(serverHost)) {
      hosts.add(serverHost);
    }
    return hosts;
  }

  /// Writes the save server's document-start shim where the native host reads
  /// it. It sits beside the slots, never inside one: an indexed resource pack
  /// rejects any file its index does not list. A failed fetch must never block
  /// the launch: the game opens without cloud saves and the log records why.
  Future<void> _prepareSaveBridge(Directory appRoot) async {
    final file = File(p.join(appRoot.path, syncBridgeFileName));
    final nativeFile = File(p.join(appRoot.path, nativeTokenFileName));
    final content = await buildSaveBridgeScript();
    if (content.isEmpty) {
      await _deleteFileQuietly(file);
      await _deleteFileQuietly(nativeFile);
      return;
    }
    try {
      // 原生心跳/在线代理要用长期设备令牌；页面脚本里只有短时会话令牌。
      // 分开两个文件，避免「页面过期」把在线会话登记一起弄断。
      await nativeFile.writeAsString(
        jsonEncode(<String, Object?>{
          'token': _appSettings.deviceToken.trim(),
        }),
        flush: true,
      );
      if (!Platform.isWindows) {
        await Process.run('chmod', ['600', nativeFile.path]);
      }
      await file.writeAsString(content, flush: true);
      // 桥文件里有 `token:"pvz_..."` 明文：资源根可能位于用户自选目录，
      // 落地即收紧到 0600（Windows 上 chmod 是空操作）。
      if (!Platform.isWindows) {
        await Process.run('chmod', ['600', file.path]);
      }
    } catch (error, stackTrace) {
      _appLogger.emit(
        level: LogLevel.warn,
        category: 'game.host',
        event: 'save_bridge_write_failed',
        outcome: LogOutcome.failed,
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// 生成存档桥脚本（`window.__PVZGE_APP__` + shim/sync + 面板）。
  ///
  /// Android 把它交给原生在 document-start 内联；桌面端直接把它交给本地服务器
  /// 注入页面（在线形态注入反代后的页面）。两条路径同一份脚本，因此
  /// 「本地/在线」两种形态的存档语义完全一致。
  /// 未登录或未配置服务器时返回空字符串：游戏照常启动，只是没有云存档。
  Future<String> buildSaveBridgeScript() async {
    final base = _appSettings.effectiveServerBaseUrl;
    final deviceToken = _appSettings.deviceToken.trim();
    if (base.isEmpty || deviceToken.isEmpty) return '';
    try {
      // 页面只拿短时会话令牌：设备令牌留在启动器/原生侧，不进 JS。
      // 换不到会话令牌时必须失败关闭：绝不能把设备令牌塞进页面，
      // 否则一次接口抖动就等于撤销了 B-04 的隔离（页面重新持有长期凭据）。
      final String pageToken;
      String? sessionExpiresAt;
      try {
        final session = await _remoteResourceService.issueSaveSessionToken(
          token: deviceToken,
          baseUrl: base,
        );
        pageToken = session.token;
        sessionExpiresAt = session.expiresAt?.toIso8601String();
        _appLogger.emit(
          level: LogLevel.info,
          category: 'cloud.auth',
          event: 'save_session_token_issued',
          outcome: LogOutcome.succeeded,
          context: <String, Object?>{'expiresAt': sessionExpiresAt},
        );
      } catch (error, stackTrace) {
        _appLogger.emit(
          level: LogLevel.warn,
          category: 'cloud.auth',
          event: 'save_session_token_unavailable',
          outcome: LogOutcome.failed,
          code: 'save_session_unavailable',
          error: error,
          stackTrace: stackTrace,
        );
        // 本次启动不注入存档桥：游戏照常离线玩，只是没有云存档。
        return '';
      }
      final script = await _remoteResourceService.fetchAppSyncScript(
        token: deviceToken,
        baseUrl: base,
      );
      // 存档面板（右下角悬浮按钮）与同步桥共用同一个 document-start 文件：
      // 面板要读同一份 __PVZGE_APP__ 配置，分成两个文件反而要额外注入点。
      // 面板拉不到不是致命错误 —— 游戏照常启动，只是没有入口。
      var panel = '';
      try {
        panel = await _remoteResourceService.fetchAppUiScript(
          token: deviceToken,
          baseUrl: base,
        );
      } catch (error, stackTrace) {
        _appLogger.emit(
          level: LogLevel.warn,
          category: 'game.host',
          event: 'save_panel_unavailable',
          outcome: LogOutcome.failed,
          code: 'save_panel_unavailable',
          error: error,
          stackTrace: stackTrace,
        );
      }
      final buffer = StringBuffer()
        ..write('window.__PVZGE_APP__={base:')
        ..write(_jsStringLiteral(base))
        // 这里注入的是短时会话令牌，不是设备令牌。设备令牌只留在
        // 启动器与原生宿主侧；页面即使被恶意资源包读取，拿到的也只是
        // 一次会话、3 小时后失效的存档读写凭据。
        ..write(',token:')
        ..write(_jsStringLiteral(pageToken))
        // 存档按游戏版本隔离：注入当前资源包版本，注入脚本据此分区
        ..write(',gameVersion:')
        ..write(_jsStringLiteral(_playGameVersion()))
        ..write('};\n')
        ..write(escapeDocumentStartScript(script));
      if (panel.isNotEmpty) {
        buffer
          ..write('\n;\n')
          ..write(escapeDocumentStartScript(panel));
      }
      final content = buffer.toString();
      _appLogger.emit(
        level: LogLevel.info,
        category: 'game.host',
        event: 'save_server_bridge_ready',
        outcome: LogOutcome.succeeded,
        context: <String, Object?>{
          'server': maskedServerBase(base),
          'bytes': content.length,
        },
      );
      return content;
    } catch (error, stackTrace) {
      _appLogger.emit(
        level: LogLevel.warn,
        category: 'game.host',
        event: 'save_server_bridge_failed',
        outcome: LogOutcome.failed,
        code: 'save_bridge_unavailable',
        error: error,
        stackTrace: stackTrace,
      );
      return '';
    }
  }

  Future<void> _deleteFileQuietly(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // An unreadable leftover cannot be inlined after the next launch anyway.
    }
  }

  /// The launcher's own state files as they are on disk, for the tool shed.
  String toolShedSnapshot() {
    const encoder = JsonEncoder.withIndent('  ');
    return [
      ('manifest.json', _manifest.toJson()),
      ('app_settings.json', _appSettings.toJson()),
      ('journal.json', _journal.toJson()),
    ].map((file) => '# ${file.$1}\n${encoder.convert(file.$2)}').join('\n\n');
  }

  ImportRecord _importRecord() => ImportRecord(
        importedAt: _manifest.lastImportAt ?? DateTime.now(),
        totalBytes: _manifest.totalBytes,
        gameVersion: _manifest.gameVersion,
        gpNextVersion: _manifest.gpNextVersion,
      );

  /// The journal is a keepsake: failing to save it never fails the import or
  /// launch that recorded it.
  Future<void> _saveJournal(GardenJournal journal) async {
    _journal = journal;
    try {
      await _journalStore?.write(journal);
    } catch (error, stackTrace) {
      _appLogger.emit(
        level: LogLevel.warn,
        category: 'app.journal',
        event: 'journal_write_failed',
        outcome: LogOutcome.failed,
        code: 'journal_write_failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> setReduceMotion(bool enabled) {
    return _updateAppSettings(_appSettings.copyWith(reduceMotion: enabled));
  }

  Future<void> setLanguagePreference(LanguagePreference preference) async {
    _applyLanguage(preference);
    await _updateAppSettings(
      _appSettings.copyWith(languagePreference: preference),
    );
    await _shortcutService.publish(AppStrings.current);
  }

  /// Follows a system language change while the language setting is System.
  void systemLocalesChanged() {
    _applyLanguage(_appSettings.languagePreference);
    notifyListeners();
    unawaited(_shortcutService.publish(AppStrings.current));
  }

  void _applyLanguage(LanguagePreference preference) {
    AppStrings.current = AppStrings.resolve(
      preference,
      PlatformDispatcher.instance.locales,
    );
  }

  /// A failure notice worded by the error catalog; [detail] is shown only
  /// for a code the catalog does not know.
  LauncherMessage _failureMessage(String? code, String? detail) =>
      LauncherMessage(
        userErrorTitle(code, detail ?? code ?? 'unknown_error'),
        code,
      );

  Future<void> _updateAppSettings(AppSettings settings) async {
    if (settings.toJson().toString() == _appSettings.toJson().toString()) {
      return;
    }
    final appSettingsStore = _appSettingsStore;
    if (appSettingsStore == null) {
      throw StateError('AppSettingsStore 尚未初始化');
    }

    _appSettings = settings;
    notifyListeners();
    final previousWrite = _appSettingsWrite;
    final currentWrite = () async {
      try {
        await previousWrite;
      } catch (_) {
        // A later choice must still be persisted after an earlier write fails.
      }
      await appSettingsStore.write(settings);
    }();
    _appSettingsWrite = currentWrite;
    await currentWrite;
  }

  Future<void> setAutoCollectSunEnabled(bool enabled) async {
    if (_manifest.autoCollectSunEnabled == enabled) {
      return;
    }
    final manifestStore = _requireManifestStore();
    _manifest = _manifest.copyWith(autoCollectSunEnabled: enabled);
    final manifest = _manifest;
    notifyListeners();
    final previousWrite = _manifestPreferenceWrite;
    final currentWrite = () async {
      try {
        await previousWrite;
      } catch (_) {
        // A later choice must still be persisted after an earlier write fails.
      }
      await manifestStore.write(manifest);
    }();
    _manifestPreferenceWrite = currentWrite;
    await currentWrite;
  }

  AppPaths _requirePaths() {
    final paths = _paths;
    if (paths == null) {
      throw StateError('AppPaths 尚未初始化');
    }
    return paths;
  }

  ManifestStore _requireManifestStore() {
    final manifestStore = _manifestStore;
    if (manifestStore == null) {
      throw StateError('ManifestStore 尚未初始化');
    }
    return manifestStore;
  }
}

/// How [incoming] orders against [current]; null when either is missing or
/// not a version [compareGameVersions] understands.
int? _versionOrder(String? incoming, String? current) => incoming != null &&
        current != null &&
        gameVersionPattern.hasMatch(incoming) &&
        gameVersionPattern.hasMatch(current)
    ? compareGameVersions(incoming, current)
    : null;

String _newGameSessionId() {
  return '${DateTime.now().toUtc().microsecondsSinceEpoch}-${pid.toRadixString(16)}';
}

/// A JavaScript single-quoted string literal, safe to paste into the shim
/// prefix the server script expects.
String _jsStringLiteral(String value) {
  final escaped = value
      .replaceAll('\\', r'\\')
      .replaceAll("'", r"\'")
      .replaceAll('\r', '')
      .replaceAll('\n', r'\n')
      .replaceAll('\u2028', r'\u2028')
      .replaceAll('\u2029', r'\u2029');
  return "'$escaped'";
}

/// The native host inlines the document-start script into `index.html`, which
/// forbids `</script` and `<!--` in it. Escaping the slash (and the comment
/// opener) keeps the script's meaning while satisfying that rule.
String escapeDocumentStartScript(String script) {
  return script
      .replaceAll(RegExp('</script', caseSensitive: false), r'<\/script')
      .replaceAll('<!--', r'<\!--');
}
