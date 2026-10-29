import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../app_controller.dart';
import '../../constants.dart';
import '../../game_host/game_host.dart';
import '../../l10n/app_strings.dart';
import '../../models.dart';
import '../../services/app_settings_store.dart';
import '../../services/gpu_adapter.dart';
import '../../services/gpu_preference_service.dart';
import '../launcher_actions.dart';
import '../theme/garden_theme.dart';
import '../widgets/garden_widgets.dart';
import '../widgets/gpu_choice_dialog.dart';
import '../widgets/token_login_dialog.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.controller,
    required this.actions,
    required this.compact,
  });

  final AppController controller;
  final LauncherActions actions;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return TwoColumn(
      gap: compact ? 16 : 24,
      left: [
        _LoaderPanel(controller: controller, actions: actions),
        const SizedBox(height: 16),
        if (Platform.isWindows)
          _WindowsUpdatePanel(controller: controller)
        else
          _AppUpdatePanel(controller: controller),
        const SizedBox(height: 16),
        _LaunchPreferences(controller: controller),
        const SizedBox(height: 16),
        _SaveServerPanel(controller: controller),
        const SizedBox(height: 16),
        _AppearancePanel(controller: controller),
      ],
      right: [
        _AboutPanel(controller: controller, actions: actions),
        const SizedBox(height: 16),
        const _GuidePanel(),
      ],
    );
  }
}

class _LoaderPanel extends StatelessWidget {
  const _LoaderPanel({required this.controller, required this.actions});

  final AppController controller;
  final LauncherActions actions;

  @override
  Widget build(BuildContext context) {
    final palette = context.garden;
    final strings = context.strings;
    final update = controller.availableUpdate;
    // 这张卡片只反映上游官方主线；个人构建的升级走下方「应用内更新」。
    final (String status, Color? statusColor) = update != null
        ? (strings.upstreamNewer, palette.accent)
        : controller.updateCheckInProgress
            ? (strings.checking, null)
            : controller.latestAppVersion == null
                ? (strings.noUpdate, null)
                : (strings.upstreamOnPar, null);
    return SurfaceCard(
      key: update == null ? null : const ValueKey('app-update-entry'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PanelHeader(
            title: '$appDisplayName · ${strings.personalBuildTag}',
            trailing: StatusLabel(label: status, color: statusColor),
          ),
          const SizedBox(height: 16),
          MetricRow(
            metrics: [
              Metric(
                label: strings.currentVersion,
                value: 'v${controller.installedVersionName}',
              ),
              Metric(
                label: strings.upstreamLatest,
                value: controller.latestAppVersion == null
                    ? '--'
                    : 'v${controller.latestAppVersion}',
              ),
            ],
          ),
          const SizedBox(height: 10),
          InfoRow(
            label: strings.buildNumber,
            value: controller.installedBuildNumber.isEmpty
                ? '--'
                : controller.installedBuildNumber,
            mono: true,
          ),
          const SizedBox(height: 12),
          Text(
            strings.personalBuildNotice,
            style:
                TextStyle(color: palette.inkMuted, fontSize: 12.5, height: 1.5),
          ),
          const SizedBox(height: 14),
          if (controller.cloudServerConfigured) ...[
            Text(
              strings.saveManagerHint,
              style: TextStyle(
                  color: palette.inkMuted, fontSize: 12.5, height: 1.5),
            ),
            const SizedBox(height: 8),
            GardenButton(
              label: strings.saveManager,
              icon: Icons.cloud_sync_outlined,
              tone: GardenButtonTone.ghost,
              compact: true,
              onPressed: () => actions.openUrl(controller.saveAdminUrl),
            ),
            const SizedBox(height: 14),
          ],
          if (update == null)
            Text(
              strings.autoCheckHint,
              style: TextStyle(
                color: palette.inkMuted,
                fontSize: 12.5,
                height: 1.5,
              ),
            )
          else ...[
            Text(
              '${update.currentVersion} → ${update.latestVersion}',
              style: TextStyle(color: palette.inkMuted, fontSize: 12.5),
            ),
            const SizedBox(height: 8),
            Text(
              strings.upstreamSignatureWarning,
              style:
                  TextStyle(color: palette.danger, fontSize: 12.5, height: 1.5),
            ),
            if (update.releaseName.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                update.releaseName,
                style: TextStyle(
                  color: palette.ink,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            if (update.releaseNotes.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                update.releaseNotes,
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: palette.inkMuted,
                  fontSize: 12.5,
                  height: 1.5,
                ),
              ),
            ],
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                GardenButton(
                  label: strings.cloudDriveUpdate,
                  icon: Icons.download_rounded,
                  tone: GardenButtonTone.primary,
                  compact: true,
                  onPressed: () =>
                      actions.openUrl(controller.links.loaderCloudDrive),
                ),
                GardenButton(
                  label: strings.viewGithubRelease,
                  compact: true,
                  onPressed: () => actions.openRelease(update),
                ),
                GardenButton(
                  label: strings.remindLater,
                  tone: GardenButtonTone.ghost,
                  compact: true,
                  onPressed: () => actions.deferUpdate(update),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// The in-app APK update: check the server's manifest, resume a download,
/// verify its SHA-256 and hand it to the system installer.
class _AppUpdatePanel extends StatelessWidget {
  const _AppUpdatePanel({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final palette = context.garden;
    final strings = context.strings;
    final status = controller.appUpdate;
    final release = status.release;
    final configured = controller.cloudServerConfigured;
    final supported = controller.appUpdateInstallSupported;
    final notes = release?.notes ?? '';
    final (String stateText, Color? stateColor) = switch (status.phase) {
      AppUpdatePhase.idle => (strings.appUpdateNotChecked, null),
      AppUpdatePhase.checking => (strings.appUpdateChecking, null),
      AppUpdatePhase.upToDate => (strings.upToDate, null),
      AppUpdatePhase.available => (strings.updateAvailable, palette.accent),
      AppUpdatePhase.downloading => (strings.appUpdateDownloading, null),
      AppUpdatePhase.verifying => (strings.appUpdateVerifying, null),
      AppUpdatePhase.ready => (strings.appUpdateReadyShort, palette.accent),
      AppUpdatePhase.installing => (strings.appUpdateInstalling, null),
      AppUpdatePhase.failed => (strings.appUpdateFailed, palette.danger),
    };
    final hintStyle = TextStyle(
      color: palette.inkMuted,
      fontSize: 12.5,
      height: 1.5,
    );
    final showProgress = status.totalBytes > 0 &&
        status.phase != AppUpdatePhase.idle &&
        status.phase != AppUpdatePhase.checking &&
        status.phase != AppUpdatePhase.upToDate;
    final canDownload = supported &&
        configured &&
        !status.active &&
        (status.phase == AppUpdatePhase.available ||
            status.phase == AppUpdatePhase.failed) &&
        release != null;
    final canInstall = supported &&
        !status.active &&
        release != null &&
        (status.phase == AppUpdatePhase.ready ||
            controller.appUpdateInstallReady);

    return SurfaceCard(
      key: const ValueKey('app-update'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PanelHeader(
            title: strings.appUpdateTitle,
            icon: Icons.system_update_alt_rounded,
            trailing: StatusLabel(label: stateText, color: stateColor),
          ),
          const SizedBox(height: 8),
          Text(strings.appUpdateSubtitle, style: hintStyle),
          const SizedBox(height: 14),
          MetricRow(
            metrics: [
              Metric(
                label: strings.currentVersion,
                value: 'v${controller.installedVersionName}',
              ),
              Metric(
                label: strings.buildNumber,
                value: controller.installedBuildNumber.isEmpty
                    ? '--'
                    : controller.installedBuildNumber,
              ),
            ],
          ),
          if (release != null) ...[
            const SizedBox(height: 10),
            InfoRow(
              label: strings.appUpdateServerBuild,
              value: '${release.version} · ${release.versionCode}',
              mono: true,
            ),
            if (release.size > 0)
              InfoRow(
                label: strings.appUpdatePackage,
                value: formatBytes(release.size),
              ),
          ],
          if (status.phase == AppUpdatePhase.upToDate && release != null) ...[
            const SizedBox(height: 10),
            Text(
              strings.appUpdateUpToDate(
                release.version,
                '${release.versionCode}',
              ),
              style: hintStyle.copyWith(color: palette.ink),
            ),
          ],
          if (status.phase == AppUpdatePhase.available && release != null) ...[
            const SizedBox(height: 10),
            Text(
              strings.appUpdateAvailable(
                release.version,
                '${release.versionCode}',
              ),
              style: hintStyle.copyWith(
                color: palette.ink,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          if (notes.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              notes,
              maxLines: 8,
              overflow: TextOverflow.ellipsis,
              style: hintStyle,
            ),
          ],
          if (controller.appUpdateHint.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              controller.appUpdateHint,
              style: hintStyle.copyWith(color: palette.warning),
            ),
          ],
          if (showProgress) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: status.phase == AppUpdatePhase.ready ? 1 : status.value,
                minHeight: 6,
                backgroundColor: palette.surfaceMuted,
                color: palette.accent,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              strings.downloadProgress(
                formatBytes(status.receivedBytes),
                formatBytes(status.totalBytes),
              ),
              style: hintStyle.copyWith(fontSize: 12.5),
            ),
            if (status.resumedBytes > 0 &&
                status.phase == AppUpdatePhase.downloading) ...[
              const SizedBox(height: 4),
              Text(
                strings.appUpdateResumed(formatBytes(status.resumedBytes)),
                style: hintStyle.copyWith(fontSize: 12),
              ),
            ],
          ],
          if (status.phase == AppUpdatePhase.ready) ...[
            const SizedBox(height: 8),
            Text(
              strings.appUpdateReady,
              style: hintStyle.copyWith(color: palette.accent),
            ),
          ],
          if (status.phase == AppUpdatePhase.failed) ...[
            const SizedBox(height: 10),
            Text(
              strings.appUpdateError(status.errorCode, status.message),
              style: hintStyle.copyWith(color: palette.danger, fontSize: 12.5),
            ),
            if (status.needsInstallPermission) ...[
              const SizedBox(height: 6),
              Text(
                strings.appUpdatePermissionHint,
                style: hintStyle.copyWith(color: palette.warning),
              ),
            ],
          ],
          if (!configured) ...[
            const SizedBox(height: 10),
            Text(
              strings.appUpdateSignInFirst,
              style: hintStyle.copyWith(color: palette.warning),
            ),
          ] else if (!supported) ...[
            const SizedBox(height: 10),
            Text(
              strings.appUpdatePlatformUnsupported,
              style: hintStyle.copyWith(color: palette.warning),
            ),
          ],
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              GardenButton(
                key: const ValueKey('app-update-check'),
                label: strings.appUpdateCheck,
                icon: Icons.refresh_rounded,
                tone: GardenButtonTone.ghost,
                compact: true,
                busy: status.phase == AppUpdatePhase.checking,
                onPressed:
                    status.active ? null : () => controller.checkAppUpdate(),
              ),
              if (status.downloading)
                GardenButton(
                  key: const ValueKey('app-update-cancel'),
                  label: strings.cancelDownload,
                  icon: Icons.close_rounded,
                  tone: GardenButtonTone.danger,
                  compact: true,
                  onPressed: controller.cancelAppUpdateDownload,
                )
              else if (canInstall)
                GardenButton(
                  key: const ValueKey('app-update-install'),
                  label: strings.appUpdateInstall,
                  icon: Icons.install_mobile_rounded,
                  tone: GardenButtonTone.primary,
                  compact: true,
                  onPressed: () => controller.installAppUpdate(),
                )
              else if (canDownload)
                GardenButton(
                  key: const ValueKey('app-update-download'),
                  label: status.resumedBytes > 0
                      ? strings.appUpdateResume
                      : strings.appUpdateDownload,
                  icon: Icons.download_rounded,
                  tone: GardenButtonTone.primary,
                  compact: true,
                  busy: status.active,
                  onPressed: () => controller.downloadAppUpdate(),
                ),
              if (status.needsInstallPermission)
                GardenButton(
                  key: const ValueKey('app-update-permission'),
                  label: strings.appUpdateOpenPermissionSettings,
                  icon: Icons.settings_outlined,
                  compact: true,
                  onPressed: () =>
                      controller.openAppInstallPermissionSettings(),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 桌面端更新：只做「检查 / 下载 / 校验 / 打开目录」。
///
/// 不自动替换安装目录：替换运行中的 CEF 应用需要外部进程，复制失败会留下
/// 半套文件。手动替换是刻意保留的边界，见 07-backlog B-08。
class _WindowsUpdatePanel extends StatelessWidget {
  const _WindowsUpdatePanel({required this.controller});

  final AppController controller;

  Future<void> _confirmApply(
    BuildContext context,
    AppController controller,
  ) async {
    final strings = context.strings;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(strings.windowsUpdateApplyTitle),
        content: Text(strings.windowsUpdateApplyMessage),
        actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        actions: [
          GardenButton(
            label: strings.cancel,
            compact: true,
            onPressed: () => Navigator.of(dialogContext).pop(false),
          ),
          GardenButton(
            label: strings.windowsUpdateApply,
            compact: true,
            tone: GardenButtonTone.danger,
            icon: Icons.restart_alt_rounded,
            onPressed: () => Navigator.of(dialogContext).pop(true),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await controller.applyWindowsUpdate();
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.garden;
    final strings = context.strings;
    final status = controller.windowsUpdate;
    final release = status.release;
    final notes = release?.notes ?? '';
    final (String stateText, Color? stateColor) = switch (status.phase) {
      AppUpdatePhase.idle => (strings.appUpdateNotChecked, null),
      AppUpdatePhase.checking => (strings.windowsUpdateChecking, null),
      AppUpdatePhase.upToDate => (strings.windowsUpdateUpToDate, null),
      AppUpdatePhase.available => (strings.updateAvailable, palette.accent),
      AppUpdatePhase.downloading => (strings.windowsUpdateDownloading, null),
      AppUpdatePhase.verifying => (strings.windowsUpdateVerifying, null),
      AppUpdatePhase.ready => (strings.windowsUpdateReadyShort, palette.accent),
      AppUpdatePhase.installing => (strings.windowsUpdateApplying, null),
      AppUpdatePhase.failed => (strings.appUpdateFailed, palette.danger),
    };
    final hintStyle = TextStyle(
      color: palette.inkMuted,
      fontSize: 12.5,
      height: 1.5,
    );
    final canDownload = !status.active &&
        release != null &&
        (status.phase == AppUpdatePhase.available ||
            status.phase == AppUpdatePhase.failed);
    final canOpen = controller.windowsUpdateFile != null;

    return SurfaceCard(
      key: const ValueKey('windows-update'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PanelHeader(
            title: strings.windowsUpdateTitle,
            icon: Icons.desktop_windows_rounded,
            trailing: StatusLabel(label: stateText, color: stateColor),
          ),
          const SizedBox(height: 8),
          Text(strings.windowsUpdateSubtitle, style: hintStyle),
          const SizedBox(height: 14),
          MetricRow(
            metrics: [
              Metric(
                label: strings.currentVersion,
                value: 'v${controller.installedVersionName}',
              ),
              Metric(
                label: strings.buildNumber,
                value: controller.installedBuildNumber.isEmpty
                    ? '--'
                    : controller.installedBuildNumber,
              ),
            ],
          ),
          if (release != null) ...[
            const SizedBox(height: 10),
            Text(
              strings.windowsUpdateAvailable(
                release.version,
                '${release.versionCode}',
              ),
              style: hintStyle.copyWith(
                color: palette.ink,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          if (notes.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              notes,
              maxLines: 8,
              overflow: TextOverflow.ellipsis,
              style: hintStyle,
            ),
          ],
          if (status.phase == AppUpdatePhase.downloading ||
              status.phase == AppUpdatePhase.verifying) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: status.totalBytes > 0
                    ? status.receivedBytes / status.totalBytes
                    : null,
                minHeight: 6,
                backgroundColor: palette.surfaceMuted,
                color: palette.accent,
              ),
            ),
          ],
          if (status.phase == AppUpdatePhase.ready) ...[
            const SizedBox(height: 8),
            Text(
              strings.windowsUpdateReady,
              style: hintStyle.copyWith(color: palette.accent),
            ),
          ],
          if (status.phase == AppUpdatePhase.failed) ...[
            const SizedBox(height: 8),
            Text(
              strings.windowsUpdateError(status.errorCode, status.message),
              style: hintStyle.copyWith(color: palette.danger, fontSize: 12.5),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              GardenButton(
                key: const ValueKey('windows-update-check'),
                label: strings.windowsUpdateCheck,
                icon: Icons.refresh_rounded,
                tone: GardenButtonTone.ghost,
                compact: true,
                busy: status.phase == AppUpdatePhase.checking,
                onPressed: status.active
                    ? null
                    : () => controller.checkWindowsUpdate(),
              ),
              if (status.phase == AppUpdatePhase.downloading)
                GardenButton(
                  key: const ValueKey('windows-update-cancel'),
                  label: strings.cancelDownload,
                  icon: Icons.close_rounded,
                  tone: GardenButtonTone.danger,
                  compact: true,
                  onPressed: controller.cancelWindowsUpdateDownload,
                )
              else if (canDownload)
                GardenButton(
                  key: const ValueKey('windows-update-download'),
                  label: strings.windowsUpdateDownload,
                  icon: Icons.download_rounded,
                  tone: GardenButtonTone.primary,
                  compact: true,
                  onPressed: () => controller.downloadWindowsUpdate(),
                ),
              if (canOpen)
                GardenButton(
                  key: const ValueKey('windows-update-apply'),
                  label: strings.windowsUpdateApply,
                  icon: Icons.restart_alt_rounded,
                  tone: GardenButtonTone.primary,
                  compact: true,
                  onPressed: () => _confirmApply(context, controller),
                ),
              if (canOpen)
                GardenButton(
                  key: const ValueKey('windows-update-folder'),
                  label: strings.windowsUpdateOpenFolder,
                  icon: Icons.folder_open_rounded,
                  compact: true,
                  onPressed: () => controller.openWindowsUpdateFolder(),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LaunchPreferences extends StatelessWidget {
  const _LaunchPreferences({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final palette = context.garden;
    final strings = context.strings;
    return SurfaceCard(
      key: const ValueKey('launch-preferences'),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PanelHeader(
            title: strings.launchPreferences,
            trailing: Text(
              strings.appliesNextLaunch,
              style: TextStyle(color: palette.inkFaint, fontSize: 12),
            ),
          ),
          const SizedBox(height: 4),
          SwitchRow(
            key: const ValueKey('home-quick-launch'),
            switchKey: const ValueKey('home-quick-launch-switch'),
            title: strings.quickLaunch,
            subtitle: strings.quickLaunchSubtitle,
            value: controller.quickLaunchEnabled,
            onChanged: controller.initialized
                ? controller.setQuickLaunchEnabled
                : null,
          ),
          Divider(color: palette.border),
          SwitchRow(
            key: const ValueKey('home-auto-collect-sun'),
            switchKey: const ValueKey('home-auto-collect-sun-switch'),
            title: strings.autoCollectSun,
            subtitle: controller.hasCurrentResource
                ? strings.autoCollectSunSubtitle
                : '${strings.autoCollectSunSubtitle}'
                    '（${strings.autoCollectSunNeedsResource}）',
            value: controller.autoCollectSunEnabled,
            onChanged: controller.initialized
                ? controller.setAutoCollectSunEnabled
                : null,
          ),
          Divider(color: palette.border),
          _SegmentedSettingRow<RenderResolution>(
            key: const ValueKey('render-resolution'),
            title: strings.renderResolution,
            subtitle: strings.renderResolutionSubtitle,
            values: RenderResolution.values,
            selected: controller.renderResolution,
            keyOf: (value) => ValueKey('render-resolution-${value.name}'),
            labelOf: strings.renderResolutionLabel,
            onChanged: controller.initialized
                ? controller.setRenderResolution
                : (_) {},
          ),
          Divider(color: palette.border),
          _SegmentedSettingRow<ScreenFit>(
            key: const ValueKey('screen-fit'),
            title: strings.screenFit,
            subtitle: strings.screenFitSubtitle,
            values: ScreenFit.values,
            selected: controller.screenFit,
            keyOf: (value) => ValueKey('screen-fit-${value.name}'),
            labelOf: strings.screenFitLabel,
            onChanged:
                controller.initialized ? controller.setScreenFit : (_) {},
          ),
          Divider(color: palette.border),
          SwitchRow(
            key: const ValueKey('home-watermark'),
            switchKey: const ValueKey('home-watermark-switch'),
            title: strings.watermark,
            subtitle: strings.watermarkSubtitle,
            value: controller.watermarkEnabled,
            onChanged:
                controller.initialized ? controller.setWatermarkEnabled : null,
          ),
          if (Platform.isWindows) ...[
            Divider(color: palette.border),
            _GpuPreferenceRow(controller: controller),
          ],
        ],
      ),
    );
  }
}

/// Windows 显卡偏好。只在设置页展示，不改动已有行；首次进游戏的询问
/// 走 HomePage 的同一个弹窗，避免两套文案/逻辑。
class _GpuPreferenceRow extends StatefulWidget {
  const _GpuPreferenceRow({required this.controller});

  final AppController controller;

  @override
  State<_GpuPreferenceRow> createState() => _GpuPreferenceRowState();
}

class _GpuPreferenceRowState extends State<_GpuPreferenceRow> {
  List<GpuAdapterInfo> _adapters = const [];
  GpuAdapterInfo? _active;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final service = GpuPreferenceService.instance;
    final adapters = await service.listAdapters();
    final active = await service.activeAdapter();
    if (!mounted) return;
    setState(() {
      _adapters = adapters;
      _active = active;
      _loading = false;
    });
  }

  GpuAdapterInfo? get _high => highPerformanceAdapter(_adapters);
  GpuAdapterInfo? get _power => powerSavingAdapter(_adapters);

  String _label(AppStrings strings, GpuPreference preference) {
    return switch (preference) {
      GpuPreference.automatic => strings.gpuPreferenceAutomatic,
      GpuPreference.highPerformance => _high == null
          ? strings.gpuPreferenceHigh
          : '${strings.gpuPreferenceHigh} · ${_high!.label}',
      GpuPreference.powerSaving => _power == null
          ? strings.gpuPreferencePower
          : '${strings.gpuPreferencePower} · ${_power!.label}',
    };
  }

  Future<void> _pick() async {
    if (_loading) return;
    final strings = context.strings;
    final service = GpuPreferenceService.instance;
    final current = await service.currentPreference();
    final active = await service.activeAdapter();
    if (!mounted) return;
    final result = await showGpuChoiceDialog(
      context,
      adapters: _adapters,
      initial: widget.controller.gpuPreference,
      allowCancel: true,
    );
    if (result == null || !mounted) return;
    final applied =
        await service.setPreference(result.preference, remember: true);
    if (!mounted) return;
    if (!applied) {
      _showMessage(strings.gpuPreferenceFailed);
      return;
    }
    await widget.controller.setGpuPreference(result.preference);
    if (!mounted) return;
    if (activeMatchesPreference(
      preference: result.preference,
      adapters: _adapters,
      active: active,
      currentPreference: current,
    )) {
      return;
    }
    final restart = await showGpuRestartDialog(context);
    if (!restart) return;
    if (!await service.restart() && mounted) {
      _showMessage(strings.gpuRestartFailed);
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final strings = context.strings;
    final palette = context.garden;
    return Padding(
      key: const ValueKey('gpu-preference'),
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  strings.gpuPreference,
                  style: TextStyle(
                    color: palette.ink,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _loading
                      ? strings.checking
                      : _adapters.isEmpty
                          ? strings.gpuPreferenceUnknown
                          : _label(strings, widget.controller.gpuPreference),
                  style: TextStyle(
                    color: palette.inkMuted,
                    fontSize: 12.5,
                    height: 1.45,
                  ),
                ),
                if (_active != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    strings.gpuPreferenceActive(_active!.label),
                    style: TextStyle(
                      color: palette.inkMuted,
                      fontSize: 12,
                      height: 1.45,
                    ),
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  strings.gpuPreferenceSubtitle,
                  style: TextStyle(
                    color: palette.inkFaint,
                    fontSize: 12,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          GardenButton(
            key: const ValueKey('gpu-preference-choose'),
            label: strings.chooseGpu,
            compact: true,
            onPressed: _loading || _adapters.isEmpty ? null : _pick,
          ),
        ],
      ),
    );
  }
}

/// The sign-in card: authentik first, with manual token entry tucked under
/// "Advanced" for the rare case the embedded page cannot be used.
class _SaveServerPanel extends StatefulWidget {
  const _SaveServerPanel({required this.controller});

  final AppController controller;

  @override
  State<_SaveServerPanel> createState() => _SaveServerPanelState();
}

class _SaveServerPanelState extends State<_SaveServerPanel> {
  late final TextEditingController _address =
      TextEditingController(text: widget.controller.serverBaseUrl);
  late final TextEditingController _token =
      TextEditingController(text: widget.controller.deviceToken);
  final FocusNode _addressFocus = FocusNode();
  final FocusNode _tokenFocus = FocusNode();
  bool _addressRejected = false;

  /// A field the user has edited but not saved yet; a rebuild must not
  /// overwrite that draft with the last persisted value.
  bool _addressDirty = false;
  bool _tokenDirty = false;

  /// Manual entry is a fallback, so it starts folded.
  bool _advancedOpen = false;

  @override
  void initState() {
    super.initState();
    _addressFocus.addListener(_onAddressFocus);
    _tokenFocus.addListener(_onTokenFocus);
  }

  @override
  void dispose() {
    _addressFocus.removeListener(_onAddressFocus);
    _tokenFocus.removeListener(_onTokenFocus);
    _address.dispose();
    _token.dispose();
    _addressFocus.dispose();
    _tokenFocus.dispose();
    super.dispose();
  }

  void _onAddressFocus() {
    if (!_addressFocus.hasFocus) {
      unawaited(_saveAddress());
    }
  }

  void _onTokenFocus() {
    if (!_tokenFocus.hasFocus) {
      unawaited(_saveToken());
    }
  }

  Future<void> _saveAddress() async {
    final accepted = await widget.controller.setServerBaseUrl(_address.text);
    if (accepted) _addressDirty = false;
    if (mounted) {
      setState(() => _addressRejected = !accepted);
    }
  }

  Future<void> _saveToken() async {
    await widget.controller.setDeviceToken(_token.text);
    _tokenDirty = false;
  }

  /// Signing in rewrites both fields; keep the folded editors in step once the
  /// frame that notified us is done.
  void _syncEditor(
    TextEditingController controller,
    FocusNode focus,
    String value,
    bool dirty,
  ) {
    if (focus.hasFocus || dirty || controller.text == value) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || focus.hasFocus || controller.text == value) return;
      controller.text = value;
      if (controller == _address) {
        setState(() => _addressRejected = false);
      }
    });
  }

  InputDecoration _decoration(
    String hint, {
    String? error,
    required GardenPalette palette,
  }) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: palette.border),
    );
    return InputDecoration(
      hintText: hint,
      errorText: error,
      isDense: true,
      filled: true,
      fillColor: palette.surfaceMuted,
      hintStyle: TextStyle(color: palette.inkFaint, fontSize: 13),
      errorStyle: TextStyle(color: palette.danger, fontSize: 12),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: border,
      enabledBorder: border,
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: palette.accent),
      ),
    );
  }

  /// Only the host is shown; the full address may carry a private path.
  String _serverLabel() {
    final base = widget.controller.serverBaseUrl.trim();
    if (base.isEmpty) return '—';
    final uri = Uri.tryParse(base);
    if (uri == null || uri.host.isEmpty) return base;
    return uri.host;
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.garden;
    final strings = context.strings;
    final controller = widget.controller;
    final status = controller.cloudLogin;
    final baseReady = controller.cloudServerAddressConfigured;
    final configured = controller.cloudServerConfigured;
    final labelStyle = TextStyle(
      color: palette.ink,
      fontSize: 13,
      fontWeight: FontWeight.w600,
    );
    _syncEditor(
      _address,
      _addressFocus,
      controller.serverBaseUrl,
      _addressDirty,
    );
    _syncEditor(_token, _tokenFocus, controller.deviceToken, _tokenDirty);

    final statusText = switch (status.phase) {
      CloudLoginPhase.opening => strings.cloudLoginOpening,
      CloudLoginPhase.verifying => strings.cloudLoginVerifying,
      CloudLoginPhase.succeeded => controller.cloudAccountKnown
          ? strings.cloudLoginSucceededAs(controller.cloudAccount)
          : strings.cloudLoginSucceeded,
      CloudLoginPhase.failed =>
        '${strings.cloudLoginFailed}：${status.message ?? ''}',
      CloudLoginPhase.idle => !configured
          ? null
          : controller.cloudAccountKnown
              ? strings.cloudLoginSucceededAs(controller.cloudAccount)
              : strings.cloudLoginStoredToken,
    };
    final statusColor = switch (status.phase) {
      CloudLoginPhase.failed => palette.danger,
      CloudLoginPhase.succeeded => palette.accent,
      CloudLoginPhase.opening || CloudLoginPhase.verifying => palette.inkMuted,
      CloudLoginPhase.idle => configured ? palette.accent : palette.inkMuted,
    };
    final issueUrl = controller.deviceTokenUrl;
    final manualHint = issueUrl.isEmpty
        ? strings.saveServerAddressRequired
        : strings.saveServerTokenIssue(issueUrl);

    return SurfaceCard(
      key: const ValueKey('save-server'),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PanelHeader(
            title: strings.saveServer,
            trailing: StatusLabel(
              label: configured
                  ? strings.cloudLoginSucceeded
                  : strings.cloudLoginSignedOut,
              color: configured ? palette.accent : palette.inkFaint,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            strings.saveServerSubtitle,
            style: TextStyle(
              color: palette.inkMuted,
              fontSize: 12.5,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 12),
          InfoRow(
            label: strings.saveServerAddress,
            value: _serverLabel(),
            mono: true,
          ),
          if (statusText != null) ...[
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (status.inProgress) ...[
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: palette.accent,
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    statusText,
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 12.5,
                      height: 1.45,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          GardenButton(
            key: const ValueKey('cloud-login-button'),
            label: configured
                ? strings.cloudLoginSignInAgain
                : strings.cloudLoginAction,
            icon: Icons.login_rounded,
            tone: GardenButtonTone.primary,
            busy: controller.cloudLoginInProgress,
            onPressed: !baseReady || controller.cloudLoginInProgress
                ? null
                : () async {
                    if (controller.cloudLoginSupported) {
                      // Android：原生登录闭环
                      unawaited(controller.loginWithAuthentik());
                      return;
                    }
                    // 桌面端：浏览器打开令牌签发页 → 粘贴回来
                    await controller.openTokenIssuePage();
                    if (!context.mounted) return;
                    await showTokenLoginDialog(context, controller);
                  },
          ),
          const SizedBox(height: 8),
          Text(
            baseReady
                ? strings.cloudLoginAutoSaveHint
                : strings.cloudLoginServerMissing,
            style: TextStyle(
              color: baseReady ? palette.inkMuted : palette.warning,
              fontSize: 12,
              height: 1.45,
            ),
          ),
          if (configured &&
              !controller.cloudAccountKnown &&
              !controller.cloudLoginInProgress) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: GardenButton(
                key: const ValueKey('cloud-login-verify'),
                label: strings.cloudLoginVerifyIdentity,
                icon: Icons.verified_outlined,
                tone: GardenButtonTone.ghost,
                compact: true,
                onPressed: () => unawaited(controller.verifyCloudIdentity()),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('cloud-login-advanced'),
              onPressed: () => setState(() => _advancedOpen = !_advancedOpen),
              icon: Icon(
                _advancedOpen
                    ? Icons.keyboard_arrow_up_rounded
                    : Icons.keyboard_arrow_down_rounded,
                size: 18,
              ),
              label: Text(strings.cloudLoginManualSection),
              style: TextButton.styleFrom(
                foregroundColor: palette.inkMuted,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                minimumSize: const Size(0, 36),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle: const TextStyle(fontSize: 12.5),
              ),
            ),
          ),
          AnimatedSize(
            duration: GardenMotion.quick,
            alignment: Alignment.topCenter,
            child: !_advancedOpen
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          strings.cloudLoginManualHint,
                          style: TextStyle(
                            color: palette.inkMuted,
                            fontSize: 12,
                            height: 1.45,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(strings.saveServerAddress, style: labelStyle),
                        const SizedBox(height: 6),
                        TextField(
                          key: const ValueKey('save-server-address'),
                          controller: _address,
                          focusNode: _addressFocus,
                          keyboardType: TextInputType.url,
                          autocorrect: false,
                          textInputAction: TextInputAction.next,
                          style: TextStyle(color: palette.ink, fontSize: 13.5),
                          onChanged: (_) => _addressDirty = true,
                          onSubmitted: (_) => unawaited(_saveAddress()),
                          decoration: _decoration(
                            strings.saveServerAddressHint,
                            palette: palette,
                            error: _addressRejected
                                ? strings.saveServerInvalid
                                : null,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Text(strings.deviceToken, style: labelStyle),
                        const SizedBox(height: 6),
                        TextField(
                          key: const ValueKey('save-server-token'),
                          controller: _token,
                          focusNode: _tokenFocus,
                          obscureText: true,
                          autocorrect: false,
                          enableSuggestions: false,
                          textInputAction: TextInputAction.done,
                          style: GardenType.mono(13, color: palette.ink),
                          onChanged: (_) => _tokenDirty = true,
                          onSubmitted: (_) => unawaited(_saveToken()),
                          decoration: _decoration(
                            strings.deviceTokenHint,
                            palette: palette,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          manualHint,
                          style: TextStyle(
                            color: palette.inkMuted,
                            fontSize: 12,
                            height: 1.45,
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _SegmentedSettingRow<T> extends StatelessWidget {
  const _SegmentedSettingRow({
    super.key,
    required this.title,
    required this.subtitle,
    required this.values,
    required this.selected,
    required this.keyOf,
    required this.labelOf,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final List<T> values;
  final T selected;
  final Key Function(T value) keyOf;
  final String Function(T value) labelOf;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.garden;
    // The control sits under the text: beside it, a phone's narrow column
    // left the text a few characters wide.
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: TextStyle(
              color: palette.ink,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            subtitle,
            style: TextStyle(
              color: palette.inkMuted,
              fontSize: 12.5,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 10),
          GardenSegmented<T>(
            values: values,
            selected: selected,
            keyOf: keyOf,
            labelOf: labelOf,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class _AppearancePanel extends StatelessWidget {
  const _AppearancePanel({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final palette = context.garden;
    final strings = context.strings;
    final groupLabel = TextStyle(
      color: palette.inkMuted,
      fontSize: 12,
      fontWeight: FontWeight.w700,
    );
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PanelHeader(title: strings.appearance),
          const SizedBox(height: 14),
          Text(strings.theme, style: groupLabel),
          const SizedBox(height: 8),
          GardenSegmented<ThemePreference>(
            values: ThemePreference.values,
            selected: controller.themePreference,
            keyOf: (value) => ValueKey('theme-preference-${value.name}'),
            labelOf: (value) => switch (value) {
              ThemePreference.system => strings.followSystem,
              ThemePreference.light => strings.lightTheme,
              ThemePreference.dark => strings.darkTheme,
            },
            onChanged:
                controller.initialized ? controller.setThemePreference : (_) {},
          ),
          const SizedBox(height: 14),
          Text(strings.language, style: groupLabel),
          const SizedBox(height: 8),
          GardenSegmented<LanguagePreference>(
            values: LanguagePreference.values,
            selected: controller.languagePreference,
            keyOf: (value) => ValueKey('language-preference-${value.name}'),
            // Language names stay in their own language.
            labelOf: (value) => switch (value) {
              LanguagePreference.system => strings.followSystem,
              LanguagePreference.chinese => '中文',
              LanguagePreference.english => 'English',
            },
            onChanged: controller.initialized
                ? controller.setLanguagePreference
                : (_) {},
          ),
          const SizedBox(height: 8),
          SwitchRow(
            key: const ValueKey('reduce-motion'),
            switchKey: const ValueKey('reduce-motion-switch'),
            title: strings.reduceMotion,
            subtitle: strings.reduceMotionSubtitle,
            value: controller.reduceMotion,
            onChanged:
                controller.initialized ? controller.setReduceMotion : null,
          ),
        ],
      ),
    );
  }
}

class _AboutPanel extends StatelessWidget {
  const _AboutPanel({required this.controller, required this.actions});

  final AppController controller;
  final LauncherActions actions;

  @override
  Widget build(BuildContext context) {
    final palette = context.garden;
    final strings = context.strings;
    final launcherLinks = controller.links;
    final links = <AnnouncementLink>[
      AnnouncementLink(
          label: strings.loaderGithub, url: launcherLinks.loaderGithub),
      AnnouncementLink(
          label: strings.upstreamGithub, url: launcherLinks.gameGithub),
      AnnouncementLink(
          label: strings.bilibiliHome, url: launcherLinks.bilibili),
    ];
    return SurfaceCard(
      key: const ValueKey('about-panel'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PanelHeader(title: strings.aboutTitle),
          const SizedBox(height: 12),
          SelectableText(
            strings.isChinese
                ? controller.aboutContent.content
                : controller.aboutContent.contentEn ??
                    controller.aboutContent.content,
            style: TextStyle(color: palette.ink, fontSize: 13.5, height: 1.6),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final link in links)
                GardenButton(
                  label: link.label,
                  compact: true,
                  onPressed: () => actions.openUrl(link.url),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _GuidePanel extends StatelessWidget {
  const _GuidePanel();

  @override
  Widget build(BuildContext context) {
    final palette = context.garden;
    final strings = context.strings;
    const icons = <IconData>[
      Icons.touch_app_rounded,
      Icons.ads_click_rounded,
      Icons.swipe_vertical_rounded,
      Icons.do_not_touch_rounded,
      Icons.keyboard_rounded,
    ];
    final gestures = [
      for (final (index, (gesture, mapping)) in strings.gestures.indexed)
        (icons[index], gesture, mapping),
    ];
    final tips = strings.guideTips;
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PanelHeader(title: strings.guide),
          const SizedBox(height: 10),
          for (final (icon, gesture, mapping) in gestures)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Icon(icon, size: 18, color: palette.inkMuted),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      gesture,
                      style: TextStyle(
                        color: palette.ink,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      mapping,
                      textAlign: TextAlign.right,
                      style: TextStyle(color: palette.inkMuted, fontSize: 12.5),
                    ),
                  ),
                ],
              ),
            ),
          Divider(color: palette.border, height: 20),
          for (final tip in tips)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      tip,
                      style: TextStyle(
                        color: palette.inkMuted,
                        fontSize: 12.5,
                        height: 1.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
