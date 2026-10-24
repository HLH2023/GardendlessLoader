import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
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
import 'services/app_paths_service.dart';
import 'services/app_settings_store.dart';
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
  late final ImportService _importService;
  RemoteDownloadStatus _remoteDownload = RemoteDownloadStatus.idle;
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
  bool get serverResourceDownloadSupported => Platform.isAndroid;

  /// Page a user opens in a browser to issue a device token.
  String get deviceTokenUrl {
    final base = _appSettings.effectiveServerBaseUrl;
    return base.isEmpty ? '' : '$base/_save/app.html';
  }

  RemoteDownloadStatus get remoteDownload => _remoteDownload;
  RemoteResourceManifest? get remoteManifest => _remoteManifest;
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
  bool get canStartGame => hasCurrentResource;

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
        _paths = await _pathsService.ensureInitialized();
        _emitInitializationStage('game_session_recovery');
        _gameSessionStore = GameSessionStore(_paths!.root);
        final exitResult = await _gameSessionStore!.consumeExitResult();
        _emitInitializationStage('settings');
        _appSettingsStore = AppSettingsStore(_paths!.appSettingsFile);
        _appSettings = await _appSettingsStore!.read();
        _applyLanguage(_appSettings.languagePreference);
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

  Future<void> startGame() async {
    final paths = _requirePaths();
    _message = null;
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

  Future<void> setDeviceToken(String value) {
    return _updateAppSettings(_appSettings.copyWith(deviceToken: value.trim()));
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
    final base = _appSettings.effectiveServerBaseUrl;
    final token = _appSettings.deviceToken.trim();
    if (base.isEmpty || token.isEmpty) {
      await _deleteFileQuietly(file);
      return;
    }
    try {
      final script = await _remoteResourceService.fetchAppSyncScript(
        token: token,
        baseUrl: base,
      );
      final buffer = StringBuffer()
        ..write('window.__PVZGE_APP__={base:')
        ..write(_jsStringLiteral(base))
        ..write(',token:')
        ..write(_jsStringLiteral(token))
        ..write('};\n')
        ..write(escapeDocumentStartScript(script));
      final content = buffer.toString();
      await file.writeAsString(content, flush: true);
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
    } catch (error, stackTrace) {
      await _deleteFileQuietly(file);
      _appLogger.emit(
        level: LogLevel.warn,
        category: 'game.host',
        event: 'save_server_bridge_failed',
        outcome: LogOutcome.failed,
        code: 'save_bridge_unavailable',
        error: error,
        stackTrace: stackTrace,
      );
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
