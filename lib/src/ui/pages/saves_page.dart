import 'package:flutter/material.dart';

import '../../app_controller.dart';
import '../../l10n/app_strings.dart';
import '../../services/cloud_save_service.dart';
import '../launcher_actions.dart';
import '../theme/garden_theme.dart';
import '../widgets/garden_widgets.dart';

/// 独立的一页「云端存档」。
///
/// 为什么不复用网页那套面板：App 的 WebView 是跨站环境，iframe 里拿不到
/// authentik 会话；而这个页面走 Bearer 设备令牌直连存档服务，令牌不经过
/// 任何 URL，也不依赖 WebView。网页端的管理页仍然保留（历史/设备/令牌管理
/// 更全），设置页里有入口。
class SavesPage extends StatefulWidget {
  const SavesPage({
    super.key,
    required this.controller,
    required this.actions,
    required this.compact,
  });

  final AppController controller;
  final LauncherActions actions;
  final bool compact;

  @override
  State<SavesPage> createState() => _SavesPageState();
}

class _SavesPageState extends State<SavesPage> {
  final Set<String> _expanded = <String>{};

  @override
  void initState() {
    super.initState();
    // 页面首次出现就拉一次；失败只是显示错误，不影响其它流程。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.controller.refreshCloudSaves();
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final palette = context.garden;
        final strings = context.strings;
        final snapshot = controller.cloudSaves;
        final configured = controller.cloudServerConfigured;
        return SingleChildScrollView(
          padding: EdgeInsets.symmetric(
            horizontal: widget.compact ? 16 : 28,
            vertical: widget.compact ? 16 : 24,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                strings.savesTitle,
                style: GardenType.title(22, color: palette.ink),
              ),
              const SizedBox(height: 6),
              Text(
                strings.savesSubtitle,
                style: TextStyle(
                  color: palette.inkMuted,
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 18),
              if (!configured)
                _Notice(
                  text: strings.savesNotConfigured,
                  color: palette.warning,
                  action: GardenButton(
                    label: strings.navSettings,
                    icon: Icons.settings_outlined,
                    compact: true,
                    onPressed: () =>
                        widget.actions.navigate(LauncherDestination.settings),
                  ),
                )
              else ...[
                _SummaryCard(controller: controller),
                const SizedBox(height: 14),
                _Notice(
                  text: strings.savesUploadHint,
                  color: palette.inkMuted,
                ),
                const SizedBox(height: 14),
                if (controller.cloudSavesError != null)
                  _Notice(
                    text: _errorText(strings, controller.cloudSavesError!),
                    color: palette.danger,
                    action: GardenButton(
                      label: strings.savesRefresh,
                      icon: Icons.refresh,
                      compact: true,
                      onPressed: controller.refreshCloudSaves,
                    ),
                  )
                else if (snapshot == null)
                  _Notice(
                    text: controller.cloudSavesLoading
                        ? strings.checking
                        : strings.savesLoadFailed,
                    color: palette.inkMuted,
                  )
                else if (snapshot.entries.isEmpty)
                  _Notice(
                    text: strings.savesEmpty,
                    color: palette.inkMuted,
                    action: GardenButton(
                      label: strings.savesRefresh,
                      icon: Icons.refresh,
                      compact: true,
                      onPressed: controller.refreshCloudSaves,
                    ),
                  )
                else
                  for (final entry in snapshot.entries) ...[
                    _SaveEntryCard(
                      controller: controller,
                      entry: entry,
                      // 页面只展示当前账号；服务端已允许本人查看历史与回滚，
                      // 不再要求 authentik Admins 组。
                      canManage: true,
                      expanded: _expanded.contains(entry.key),
                      onToggleHistory: () {
                        setState(() {
                          if (_expanded.remove(entry.key)) return;
                          _expanded.add(entry.key);
                        });
                        if (_expanded.contains(entry.key)) {
                          controller.loadSaveHistory(entry.key);
                        }
                      },
                    ),
                    const SizedBox(height: 10),
                  ],
                if (controller.saveRestoreMessage != null) ...[
                  const SizedBox(height: 4),
                  _Notice(
                    text: controller.saveRestoreMessage == 'save_restore_done'
                        ? strings.savesRestoreDone
                        : strings.savesRestoreFailed,
                    color: controller.saveRestoreMessage == 'save_restore_done'
                        ? palette.accent
                        : palette.danger,
                  ),
                ],
              ],
            ],
          ),
        );
      },
    );
  }

  String _errorText(AppStrings strings, String code) => switch (code) {
        'save_server_not_configured' => strings.savesNotConfigured,
        'save_token_rejected' => strings.savesLoadFailed,
        _ => strings.savesLoadFailed,
      };
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final palette = context.garden;
    final strings = context.strings;
    final snapshot = controller.cloudSaves;
    final account = snapshot?.user.isNotEmpty == true
        ? snapshot!.user
        : controller.cloudAccount;
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PanelHeader(
            title: strings.savesTitle,
            icon: Icons.cloud_outlined,
            trailing: GardenButton(
              label: strings.savesRefresh,
              icon: Icons.refresh,
              tone: GardenButtonTone.ghost,
              compact: true,
              busy: controller.cloudSavesLoading,
              onPressed:
                  controller.cloudSavesLoading ? null : controller.refreshCloudSaves,
            ),
          ),
          const SizedBox(height: 14),
          MetricRow(
            metrics: [
              Metric(
                label: strings.savesAccount,
                value: account.isEmpty ? '--' : account,
              ),
              Metric(
                label: strings.savesLastSync,
                value: snapshot == null || snapshot.lastWrite == 0
                    ? '--'
                    : _formatTime(snapshot.lastWrite),
              ),
            ],
          ),
          const SizedBox(height: 10),
          InfoRow(
            label: strings.savesTotalSize,
            value: snapshot == null
                ? '--'
                : '${_formatBytes(snapshot.totalBytes)} · '
                    '${snapshot.entries.length} ${strings.savesEntryCount}',
          ),
          const SizedBox(height: 8),
          Text(
            strings.savesSubtitle,
            style: TextStyle(color: palette.inkFaint, fontSize: 11.5, height: 1.5),
          ),
        ],
      ),
    );
  }
}

class _SaveEntryCard extends StatelessWidget {
  const _SaveEntryCard({
    required this.controller,
    required this.entry,
    required this.canManage,
    required this.expanded,
    required this.onToggleHistory,
  });

  final AppController controller;
  final CloudSaveEntry entry;

  /// 历史版本与回滚是管理员接口；非管理员点进去只会 403。
  final bool canManage;
  final bool expanded;
  final VoidCallback onToggleHistory;

  @override
  Widget build(BuildContext context) {
    final palette = context.garden;
    final strings = context.strings;
    final summaryBits = <String>[
      if (entry.playerName != null) '${strings.savesPlayer} ${entry.playerName}',
      if (entry.coin != null) '${strings.savesCoin} ${entry.coin}',
      if (entry.gem != null) '${strings.savesGem} ${entry.gem}',
      if (entry.world != null) '${strings.savesWorld} ${entry.world}',
    ];
    final versions = controller.saveHistory[entry.key];
    final loading = controller.saveHistoryLoading.contains(entry.key);
    final historyError = controller.saveHistoryError;
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PanelHeader(
            title: strings.savesKeyLabel(entry.key),
            icon: Icons.save_outlined,
            trailing: canManage
                ? GardenButton(
                    label:
                        expanded ? strings.savesHistoryHide : strings.savesHistory,
                    icon: expanded ? Icons.expand_less : Icons.history,
                    tone: GardenButtonTone.ghost,
                    compact: true,
                    onPressed: onToggleHistory,
                  )
                : null,
          ),
          const SizedBox(height: 12),
          MetricRow(
            metrics: [
              Metric(label: strings.savesTotalSize, value: _formatBytes(entry.bytes)),
              Metric(
                label: strings.savesLastSync,
                value: entry.mtime == 0 ? '--' : _formatTime(entry.mtime),
              ),
            ],
          ),
          if (entry.deviceLabel.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              '${strings.savesWrittenBy} ${entry.deviceLabel}',
              style: TextStyle(color: palette.inkFaint, fontSize: 12),
            ),
          ],
          if (summaryBits.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              summaryBits.join(' · '),
              style: TextStyle(color: palette.inkMuted, fontSize: 12.5),
            ),
          ] else ...[
            const SizedBox(height: 10),
            Text(
              entry.key,
              style: TextStyle(
                color: palette.inkFaint,
                fontSize: 11.5,
                fontFamily: 'monospace',
              ),
            ),
          ],
          if (!canManage) ...[
            const SizedBox(height: 8),
            Text(
              strings.savesHistoryForbidden,
              style: TextStyle(color: palette.inkFaint, fontSize: 11.5, height: 1.5),
            ),
          ],
          if (expanded && canManage) ...[
            const SizedBox(height: 12),
            Divider(color: palette.border),
            const SizedBox(height: 8),
            if (loading)
              Text(
                strings.checking,
                style: TextStyle(color: palette.inkMuted, fontSize: 12.5),
              )
            else if (historyError == 'save_token_rejected')
              Text(
                strings.savesHistoryForbidden,
                style: TextStyle(color: palette.warning, fontSize: 12.5, height: 1.5),
              )
            else if (versions == null || versions.isEmpty)
              Text(
                strings.savesHistoryEmpty,
                style: TextStyle(color: palette.inkMuted, fontSize: 12.5),
              )
            else
              for (final version in versions)
                _VersionRow(
                  key: ValueKey('${entry.key}-${version.ts}'),
                  version: version,
                  busy: controller.saveRestoreInProgress == entry.key,
                  onRestore: () => _confirmRestore(context, version),
                ),
          ],
        ],
      ),
    );
  }

  Future<void> _confirmRestore(
    BuildContext context,
    CloudSaveVersion version,
  ) async {
    final strings = context.strings;
    final palette = context.garden;
    final label = strings.savesKeyLabel(entry.key);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: palette.surface,
        title: Text(strings.savesRestoreConfirmTitle),
        content: Text(
          strings.savesRestoreConfirmBody(label),
          style: TextStyle(color: palette.inkMuted, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(
              strings.savesRestore,
              style: TextStyle(color: palette.danger),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await controller.restoreSaveVersion(
      key: entry.key,
      ts: version.ts,
      name: version.name,
    );
  }
}

class _VersionRow extends StatelessWidget {
  const _VersionRow({
    super.key,
    required this.version,
    required this.busy,
    required this.onRestore,
  });

  final CloudSaveVersion version;
  final bool busy;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final palette = context.garden;
    final strings = context.strings;
    final parts = <String>[
      _formatTime(version.ts),
      _formatBytes(version.bytes),
      if (version.device.isNotEmpty) version.device,
      if (version.playerName != null) version.playerName!,
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              parts.join(' · '),
              style: TextStyle(color: palette.inkMuted, fontSize: 12),
            ),
          ),
          GardenButton(
            label: strings.savesRestore,
            tone: GardenButtonTone.ghost,
            compact: true,
            busy: busy,
            onPressed: busy ? null : onRestore,
          ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text, required this.color, this.action});

  final String text;
  final Color color;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final palette = context.garden;
    return SurfaceCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: palette.inkMuted, fontSize: 12.5, height: 1.6),
            ),
          ),
          if (action != null) ...[const SizedBox(width: 10), action!],
        ],
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes <= 0) return '--';
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
  return '${(kb / 1024).toStringAsFixed(1)} MB';
}

String _formatTime(int epochSeconds) {
  if (epochSeconds <= 0) return '--';
  final time = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000);
  final now = DateTime.now();
  String two(int value) => value.toString().padLeft(2, '0');
  final stamp = '${time.year}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}';
  final delta = now.difference(time);
  if (delta.inMinutes < 1) return '$stamp（刚刚）';
  if (delta.inMinutes < 60) return '$stamp（${delta.inMinutes} 分钟前）';
  if (delta.inHours < 24) return '$stamp（${delta.inHours} 小时前）';
  return '$stamp（${delta.inDays} 天前）';
}
