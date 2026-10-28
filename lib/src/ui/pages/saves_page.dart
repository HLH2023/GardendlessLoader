import 'package:flutter/material.dart';

import '../../app_controller.dart';
import '../../l10n/app_strings.dart';
import '../../services/cloud_save_service.dart';
import '../launcher_actions.dart';
import '../theme/garden_theme.dart';
import '../widgets/garden_widgets.dart';

/// 独立的一页「云端存档」。
///
/// 支持多玩家独立快照与整键共享数据查看；
/// 支持按「本地资源版本」与「在线版本」分区查看并手动切换。
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
  final Set<String> _expandedProfiles = <String>{};
  final Set<String> _expandedEntries = <String>{};

  @override
  void initState() {
    super.initState();
    // 页面首次出现就拉一次；失败只是显示错误，不影响其它流程。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.controller.refreshCloudSaves();
    });
  }

  void _onSwitchView(bool online) {
    if (widget.controller.cloudSavesLoading) return;
    if (widget.controller.cloudSavesViewOnline == online) return;
    setState(() {
      _expandedProfiles.clear();
      _expandedEntries.clear();
    });
    widget.controller.setCloudSavesView(online: online);
  }

  void _toggleProfileHistory(String profileId) {
    setState(() {
      if (_expandedProfiles.remove(profileId)) return;
      _expandedProfiles.add(profileId);
    });
    if (_expandedProfiles.contains(profileId)) {
      widget.controller.loadProfileHistory(profileId);
    }
  }

  void _toggleEntryHistory(String key) {
    setState(() {
      if (_expandedEntries.remove(key)) return;
      _expandedEntries.add(key);
    });
    if (_expandedEntries.contains(key)) {
      widget.controller.loadSaveHistory(key);
    }
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

        if (!configured) {
          return ListView(
            children: [
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
                compact: widget.compact,
              ),
            ],
          );
        }

        return TwoColumn(
          gap: widget.compact ? 14 : 20,
          breakpoint: 560,
          left: [
            _SummaryCard(
              controller: controller,
              compact: widget.compact,
              onSwitchView: _onSwitchView,
            ),
            SizedBox(height: widget.compact ? 10 : 14),
            _Notice(
              text: strings.savesUploadHint,
              color: palette.inkMuted,
              compact: widget.compact,
            ),
            if (controller.saveRestoreMessage != null) ...[
              SizedBox(height: widget.compact ? 8 : 12),
              _Notice(
                text: controller.saveRestoreMessage == 'save_restore_done'
                    ? strings.savesRestoreDone
                    : strings.savesRestoreFailed,
                color: controller.saveRestoreMessage == 'save_restore_done'
                    ? palette.accent
                    : palette.danger,
                action: GardenIconButton(
                  icon: Icons.close,
                  tooltip: strings.cancel,
                  size: 32,
                  onPressed: controller.clearSaveRestoreMessage,
                ),
                compact: widget.compact,
              ),
            ],
          ],
          right: [
            if (controller.cloudSavesError != null)
              _buildErrorNotice(
                context,
                controller,
                controller.cloudSavesError!,
                palette,
                strings,
              )
            else if (snapshot == null)
              _Notice(
                text: controller.cloudSavesLoading
                    ? strings.checking
                    : strings.savesLoadFailed,
                color: palette.inkMuted,
                action: controller.cloudSavesLoading
                    ? null
                    : GardenButton(
                        label: strings.savesRefresh,
                        icon: Icons.refresh,
                        compact: true,
                        tone: GardenButtonTone.secondary,
                        onPressed: () => controller.refreshCloudSaves(),
                      ),
                compact: widget.compact,
              )
            else if (snapshot.profiles.isEmpty &&
                snapshot.sharedEntries.isEmpty &&
                snapshot.entries.isEmpty)
              _Notice(
                text: strings.savesEmpty,
                color: palette.inkMuted,
                action: GardenButton(
                  label: strings.savesRefresh,
                  icon: Icons.refresh,
                  compact: true,
                  tone: GardenButtonTone.secondary,
                  busy: controller.cloudSavesLoading,
                  onPressed: controller.cloudSavesLoading
                      ? null
                      : () => controller.refreshCloudSaves(),
                ),
                compact: widget.compact,
              )
            else ...[
              if (snapshot.profiles.isNotEmpty) ...[
                _SectionHeader(
                  title: strings.savesPlayers,
                  badge: '${snapshot.profiles.length}',
                  icon: Icons.group_outlined,
                  compact: widget.compact,
                ),
                for (final profile in snapshot.profiles) ...[
                  _PlayerProfileCard(
                    key: ValueKey('profile-${profile.id}'),
                    controller: controller,
                    profile: profile,
                    expanded: _expandedProfiles.contains(profile.id),
                    compact: widget.compact,
                    onToggleHistory: () => _toggleProfileHistory(profile.id),
                  ),
                  SizedBox(height: widget.compact ? 8 : 12),
                ],
                if (snapshot.sharedEntries.isNotEmpty) ...[
                  SizedBox(height: widget.compact ? 4 : 8),
                  _SectionHeader(
                    title: strings.savesSharedData,
                    badge: '${snapshot.sharedEntries.length}',
                    icon: Icons.tune_outlined,
                    compact: widget.compact,
                  ),
                  for (final entry in snapshot.sharedEntries) ...[
                    _SaveEntryCard(
                      key: ValueKey('entry-${entry.key}'),
                      controller: controller,
                      entry: entry,
                      canManage: true,
                      expanded: _expandedEntries.contains(entry.key),
                      compact: widget.compact,
                      onToggleHistory: () => _toggleEntryHistory(entry.key),
                    ),
                    SizedBox(height: widget.compact ? 8 : 12),
                  ],
                ],
              ] else ...[
                // 旧服务端不拆 profiles：玩家数据仍在 entries 里。只渲染
                // sharedEntries 会把 PvZ2_PlayerProperties 藏起来，所以这里
                // 直接渲染全部条目。
                for (final entry in snapshot.entries) ...[
                  _SaveEntryCard(
                    key: ValueKey('entry-${entry.key}'),
                    controller: controller,
                    entry: entry,
                    canManage: true,
                    expanded: _expandedEntries.contains(entry.key),
                    compact: widget.compact,
                    onToggleHistory: () => _toggleEntryHistory(entry.key),
                  ),
                  SizedBox(height: widget.compact ? 8 : 12),
                ],
              ],
            ],
          ],
        );
      },
    );
  }

  Widget _buildErrorNotice(
    BuildContext context,
    AppController controller,
    String errorCode,
    GardenPalette palette,
    AppStrings strings,
  ) {
    return switch (errorCode) {
      'local_resource_missing' => _Notice(
          text: strings.savesLocalResourceMissing,
          color: palette.warning,
          action: GardenButton(
            label: strings.savesViewOnline,
            icon: Icons.cloud_outlined,
            compact: true,
            tone: GardenButtonTone.secondary,
            busy: controller.cloudSavesLoading,
            onPressed:
                controller.cloudSavesLoading ? null : () => _onSwitchView(true),
          ),
          compact: widget.compact,
        ),
      'online_version_unavailable' => _Notice(
          text: strings.savesOnlineVersionUnavailable,
          color: palette.warning,
          action: GardenButton(
            label: strings.savesRefresh,
            icon: Icons.refresh,
            compact: true,
            tone: GardenButtonTone.secondary,
            busy: controller.cloudSavesLoading,
            onPressed: controller.cloudSavesLoading
                ? null
                : () => controller.refreshCloudSaves(),
          ),
          compact: widget.compact,
        ),
      'save_server_not_configured' => _Notice(
          text: strings.savesNotConfigured,
          color: palette.warning,
          action: GardenButton(
            label: strings.navSettings,
            icon: Icons.settings_outlined,
            compact: true,
            tone: GardenButtonTone.secondary,
            onPressed: () =>
                widget.actions.navigate(LauncherDestination.settings),
          ),
          compact: widget.compact,
        ),
      'save_token_rejected' => _Notice(
          text: strings.savesLoadFailed,
          color: palette.danger,
          action: GardenButton(
            label: strings.savesRefresh,
            icon: Icons.refresh,
            compact: true,
            tone: GardenButtonTone.secondary,
            busy: controller.cloudSavesLoading,
            onPressed: controller.cloudSavesLoading
                ? null
                : () => controller.refreshCloudSaves(),
          ),
          compact: widget.compact,
        ),
      _ => _Notice(
          text: strings.savesLoadFailed,
          color: palette.danger,
          action: GardenButton(
            label: strings.savesRefresh,
            icon: Icons.refresh,
            compact: true,
            tone: GardenButtonTone.secondary,
            busy: controller.cloudSavesLoading,
            onPressed: controller.cloudSavesLoading
                ? null
                : () => controller.refreshCloudSaves(),
          ),
          compact: widget.compact,
        ),
    };
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    this.badge,
    this.icon,
    this.compact = false,
  });

  final String title;
  final String? badge;
  final IconData? icon;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final palette = context.garden;
    return Padding(
      padding: EdgeInsets.only(
        top: compact ? 4 : 6,
        bottom: compact ? 8 : 10,
      ),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: palette.inkMuted),
            const SizedBox(width: 8),
          ],
          Text(
            title,
            style: GardenType.title(14, color: palette.ink),
          ),
          if (badge != null) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1.5),
              decoration: BoxDecoration(
                color: palette.surfaceMuted,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: palette.border),
              ),
              child: Text(
                badge!,
                style: GardenType.mono(
                  11,
                  color: palette.inkMuted,
                  weight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.controller,
    required this.onSwitchView,
    this.compact = false,
  });

  final AppController controller;
  final ValueChanged<bool> onSwitchView;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final palette = context.garden;
    final strings = context.strings;
    final snapshot = controller.cloudSaves;
    final account = snapshot?.user.isNotEmpty == true
        ? snapshot!.user
        : controller.cloudAccount;
    final rawUid = snapshot?.ownerUid ?? '';
    final shortUid = rawUid.isNotEmpty
        ? (rawUid.length <= 8 ? rawUid : rawUid.substring(0, 8))
        : '';

    return SurfaceCard(
      padding: EdgeInsets.all(compact ? 14 : 20),
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
              onPressed: controller.cloudSavesLoading
                  ? null
                  : controller.refreshCloudSaves,
            ),
          ),
          SizedBox(height: compact ? 12 : 16),
          IgnorePointer(
            ignoring: controller.cloudSavesLoading,
            child: AnimatedOpacity(
              duration: GardenMotion.quick,
              opacity: controller.cloudSavesLoading ? 0.6 : 1.0,
              child: GardenSegmented<bool>(
                values: const [false, true],
                selected: controller.cloudSavesViewOnline,
                labelOf: (online) =>
                    online ? strings.savesViewOnline : strings.savesViewLocal,
                onChanged: onSwitchView,
              ),
            ),
          ),
          SizedBox(height: compact ? 8 : 10),
          _PartitionVersionBadge(
            version: controller.cloudSavesViewVersion,
            actualVersion: snapshot?.gameVersion,
            isOnline: controller.cloudSavesViewOnline,
            compact: compact,
          ),
          SizedBox(height: compact ? 6 : 8),
          Text(
            strings.savesViewHint,
            style: TextStyle(
              color: palette.inkFaint,
              fontSize: compact ? 11 : 11.5,
              height: 1.45,
            ),
          ),
          SizedBox(height: compact ? 10 : 14),
          Divider(color: palette.border),
          SizedBox(height: compact ? 10 : 14),
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
          if (shortUid.isNotEmpty) ...[
            SizedBox(height: compact ? 8 : 10),
            Row(
              children: [
                Text(
                  '${strings.savesUid}  ',
                  style: TextStyle(
                    color: palette.inkMuted,
                    fontSize: compact ? 11.5 : 12,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1.5,
                  ),
                  decoration: BoxDecoration(
                    color: palette.surfaceMuted,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: palette.border),
                  ),
                  child: Text(
                    shortUid,
                    style: GardenType.mono(
                      11,
                      color: palette.ink,
                      weight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ],
          SizedBox(height: compact ? 8 : 10),
          InfoRow(
            label: strings.savesTotalSize,
            value: snapshot == null
                ? '--'
                : '${_formatBytes(snapshot.totalBytes)} · '
                    '${snapshot.profiles.isNotEmpty ? strings.savesPlayerCount(snapshot.profiles.length) : '${snapshot.entries.length} ${strings.savesEntryCount}'}',
          ),
          SizedBox(height: compact ? 6 : 8),
          Text(
            strings.savesSubtitle,
            style: TextStyle(
              color: palette.inkFaint,
              fontSize: 11.5,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}

class _PartitionVersionBadge extends StatelessWidget {
  const _PartitionVersionBadge({
    required this.version,
    this.actualVersion,
    required this.isOnline,
    this.compact = false,
  });

  final String version;
  final String? actualVersion;
  final bool isOnline;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final palette = context.garden;
    final strings = context.strings;
    final displayVersion = strings.savesViewVersion(version);
    final hasResolvedDifference = actualVersion != null &&
        actualVersion!.isNotEmpty &&
        actualVersion != version;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 10,
        vertical: compact ? 5 : 6,
      ),
      decoration: BoxDecoration(
        color: palette.surfaceMuted,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            isOnline ? Icons.cloud_outlined : Icons.inventory_2_outlined,
            size: 13,
            color: palette.inkMuted,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              displayVersion,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GardenType.mono(
                compact ? 11.5 : 12,
                color: palette.ink,
                weight: FontWeight.w500,
              ),
            ),
          ),
          if (hasResolvedDifference) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
              decoration: BoxDecoration(
                color: palette.surface,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: palette.border),
              ),
              child: Text(
                '↳ ${strings.savesViewVersion(actualVersion!)}',
                style: GardenType.mono(10.5, color: palette.inkMuted),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PlayerProfileCard extends StatelessWidget {
  const _PlayerProfileCard({
    super.key,
    required this.controller,
    required this.profile,
    required this.expanded,
    required this.onToggleHistory,
    this.compact = false,
  });

  final AppController controller;
  final CloudPlayerProfile profile;
  final bool expanded;
  final VoidCallback onToggleHistory;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final palette = context.garden;
    final strings = context.strings;

    final displayName = profile.name.trim().isNotEmpty
        ? profile.name.trim()
        : (profile.shortId.isNotEmpty
            ? profile.shortId
            : strings.savesNothingYet);

    final shortRev = profile.revision.isNotEmpty
        ? (profile.revision.length <= 8
            ? profile.revision
            : profile.revision.substring(0, 8))
        : '';

    final versions = controller.profileHistory[profile.id];
    final loading = controller.profileHistoryLoading.contains(profile.id);
    final historyError = controller.profileHistoryError;
    final isRestoring = controller.profileRestoreInProgress == profile.id;

    return SurfaceCard(
      padding: EdgeInsets.all(compact ? 14 : 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PanelHeader(
            title: displayName,
            icon: Icons.person_outline,
            trailing: GardenButton(
              label: expanded ? strings.savesHistoryHide : strings.savesHistory,
              icon: expanded ? Icons.expand_less : Icons.history,
              tone: GardenButtonTone.ghost,
              compact: true,
              onPressed: onToggleHistory,
            ),
          ),
          if (profile.inherited) ...[
            SizedBox(height: compact ? 6 : 8),
            _InheritedBadge(
              sourceVersion: profile.sourceVersion,
              compact: compact,
            ),
          ],
          SizedBox(height: compact ? 8 : 12),
          MetricRow(
            metrics: [
              Metric(
                label: strings.savesTotalSize,
                value: _formatBytes(profile.bytes),
              ),
              Metric(
                label: strings.savesLastSync,
                value: profile.updatedAt == 0
                    ? '--'
                    : _formatTime(profile.updatedAt),
              ),
            ],
          ),
          if (profile.coin != null || profile.gem != null) ...[
            SizedBox(height: compact ? 8 : 10),
            Row(
              children: [
                if (profile.coin != null) ...[
                  _CurrencyBadge(
                    icon: Icons.monetization_on_outlined,
                    label: strings.savesCoin,
                    value: '${profile.coin}',
                    accentColor: palette.warning,
                    compact: compact,
                  ),
                  const SizedBox(width: 8),
                ],
                if (profile.gem != null) ...[
                  _CurrencyBadge(
                    icon: Icons.diamond_outlined,
                    label: strings.savesGem,
                    value: '${profile.gem}',
                    accentColor: const Color(0xff38bdf8),
                    compact: compact,
                  ),
                ],
              ],
            ),
          ],
          SizedBox(height: compact ? 8 : 10),
          Row(
            children: [
              Text(
                'ID: ',
                style: TextStyle(
                  color: palette.inkFaint,
                  fontSize: compact ? 11 : 11.5,
                ),
              ),
              Text(
                profile.shortId,
                style: GardenType.mono(
                  compact ? 11 : 11.5,
                  color: palette.inkMuted,
                  weight: FontWeight.w500,
                ),
              ),
              if (shortRev.isNotEmpty) ...[
                Text(
                  '  ·  rev: ',
                  style: TextStyle(
                    color: palette.inkFaint,
                    fontSize: compact ? 11 : 11.5,
                  ),
                ),
                Text(
                  shortRev,
                  style: GardenType.mono(
                    compact ? 11 : 11.5,
                    color: palette.inkMuted,
                    weight: FontWeight.w500,
                  ),
                ),
              ],
              if (profile.index >= 0) ...[
                Text(
                  '  ·  #${profile.index + 1}',
                  style: GardenType.mono(
                    compact ? 11 : 11.5,
                    color: palette.inkFaint,
                  ),
                ),
              ],
            ],
          ),
          if (expanded) ...[
            SizedBox(height: compact ? 8 : 12),
            Divider(color: palette.border),
            SizedBox(height: compact ? 6 : 8),
            if (loading)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: palette.accent,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      strings.checking,
                      style: TextStyle(color: palette.inkMuted, fontSize: 12.5),
                    ),
                  ],
                ),
              )
            else if (historyError != null &&
                (versions == null || versions.isEmpty))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        historyError == 'save_token_rejected'
                            ? strings.savesHistoryForbidden
                            : strings.savesLoadFailed,
                        style: TextStyle(
                          color: historyError == 'save_token_rejected'
                              ? palette.warning
                              : palette.danger,
                          fontSize: 12.5,
                          height: 1.5,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GardenButton(
                      label: strings.savesRefresh,
                      icon: Icons.refresh,
                      tone: GardenButtonTone.ghost,
                      compact: true,
                      onPressed: () =>
                          controller.loadProfileHistory(profile.id),
                    ),
                  ],
                ),
              )
            else if (versions == null || versions.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  strings.savesProfileHistoryEmpty,
                  style: TextStyle(color: palette.inkMuted, fontSize: 12.5),
                ),
              )
            else
              for (final version in versions)
                _VersionRow(
                  key: ValueKey('${profile.id}-${version.name}-${version.ts}'),
                  version: version,
                  busy: isRestoring,
                  onRestore: () => _confirmRestoreProfile(
                    context,
                    controller,
                    profile,
                    version,
                  ),
                  compact: compact,
                ),
          ],
        ],
      ),
    );
  }

  Future<void> _confirmRestoreProfile(
    BuildContext context,
    AppController controller,
    CloudPlayerProfile profile,
    CloudSaveVersion version,
  ) async {
    final strings = context.strings;
    final palette = context.garden;
    final profileName = profile.name.trim().isNotEmpty
        ? profile.name.trim()
        : (profile.shortId.isNotEmpty
            ? profile.shortId
            : strings.savesNothingYet);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: palette.surface,
        title: Text(strings.savesRestoreConfirmTitle),
        content: Text(
          strings.savesRestoreProfileConfirmBody(profileName),
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
    await controller.restoreProfileVersion(
      profileId: profile.id,
      ts: version.ts,
      name: version.name,
    );
  }
}

class _CurrencyBadge extends StatelessWidget {
  const _CurrencyBadge({
    required this.icon,
    required this.label,
    required this.value,
    required this.accentColor,
    this.compact = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color accentColor;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final palette = context.garden;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 10,
        vertical: compact ? 3 : 4,
      ),
      decoration: BoxDecoration(
        color: palette.surfaceMuted,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: compact ? 13 : 14, color: accentColor),
          const SizedBox(width: 5),
          Text(
            '$label ',
            style: TextStyle(
              color: palette.inkMuted,
              fontSize: compact ? 11 : 11.5,
            ),
          ),
          Text(
            value,
            style: GardenType.mono(
              compact ? 11.5 : 12,
              color: palette.ink,
              weight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _InheritedBadge extends StatelessWidget {
  const _InheritedBadge({
    required this.sourceVersion,
    this.compact = false,
  });

  final String sourceVersion;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final palette = context.garden;
    final strings = context.strings;
    final label = sourceVersion.isNotEmpty
        ? '${strings.savesProfileInherited} ($sourceVersion)'
        : strings.savesProfileInherited;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 7 : 9,
        vertical: compact ? 2.5 : 3.5,
      ),
      decoration: BoxDecoration(
        color: palette.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: palette.warning.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.history_toggle_off,
            size: compact ? 12 : 13,
            color: palette.warning,
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: palette.warning,
              fontSize: compact ? 10.5 : 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _SaveEntryCard extends StatelessWidget {
  const _SaveEntryCard({
    super.key,
    required this.controller,
    required this.entry,
    required this.canManage,
    required this.expanded,
    required this.onToggleHistory,
    this.compact = false,
  });

  final AppController controller;
  final CloudSaveEntry entry;

  /// 历史版本与回滚是本人可用的能力。
  final bool canManage;
  final bool expanded;
  final VoidCallback onToggleHistory;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final palette = context.garden;
    final strings = context.strings;
    final summaryBits = <String>[
      if (entry.playerName != null)
        '${strings.savesPlayer} ${entry.playerName}',
      if (entry.coin != null) '${strings.savesCoin} ${entry.coin}',
      if (entry.gem != null) '${strings.savesGem} ${entry.gem}',
      if (entry.world != null) '${strings.savesWorld} ${entry.world}',
    ];
    final versions = controller.saveHistory[entry.key];
    final loading = controller.saveHistoryLoading.contains(entry.key);
    final historyError = controller.saveHistoryError;
    final isRestoring = controller.saveRestoreInProgress == entry.key;

    return SurfaceCard(
      padding: EdgeInsets.all(compact ? 14 : 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PanelHeader(
            title: strings.savesKeyLabel(entry.key),
            icon: Icons.save_outlined,
            trailing: canManage
                ? GardenButton(
                    label: expanded
                        ? strings.savesHistoryHide
                        : strings.savesHistory,
                    icon: expanded ? Icons.expand_less : Icons.history,
                    tone: GardenButtonTone.ghost,
                    compact: true,
                    onPressed: onToggleHistory,
                  )
                : null,
          ),
          SizedBox(height: compact ? 8 : 12),
          MetricRow(
            metrics: [
              Metric(
                label: strings.savesTotalSize,
                value: _formatBytes(entry.bytes),
              ),
              Metric(
                label: strings.savesLastSync,
                value: entry.mtime == 0 ? '--' : _formatTime(entry.mtime),
              ),
            ],
          ),
          if (entry.deviceLabel.isNotEmpty) ...[
            SizedBox(height: compact ? 6 : 8),
            Text(
              '${strings.savesWrittenBy} ${entry.deviceLabel}',
              style: TextStyle(
                color: palette.inkFaint,
                fontSize: compact ? 11.5 : 12,
              ),
            ),
          ],
          if (summaryBits.isNotEmpty) ...[
            SizedBox(height: compact ? 8 : 10),
            Text(
              summaryBits.join(' · '),
              style: TextStyle(
                color: palette.inkMuted,
                fontSize: compact ? 12 : 12.5,
              ),
            ),
          ] else ...[
            SizedBox(height: compact ? 8 : 10),
            Text(
              entry.key,
              style: GardenType.mono(
                11.5,
                color: palette.inkFaint,
              ),
            ),
          ],
          if (!canManage) ...[
            SizedBox(height: compact ? 6 : 8),
            Text(
              strings.savesHistoryForbidden,
              style: TextStyle(
                color: palette.inkFaint,
                fontSize: 11.5,
                height: 1.5,
              ),
            ),
          ],
          if (expanded && canManage) ...[
            SizedBox(height: compact ? 8 : 12),
            Divider(color: palette.border),
            SizedBox(height: compact ? 6 : 8),
            if (loading)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: palette.accent,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      strings.checking,
                      style: TextStyle(color: palette.inkMuted, fontSize: 12.5),
                    ),
                  ],
                ),
              )
            else if (historyError == 'save_token_rejected')
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  strings.savesHistoryForbidden,
                  style: TextStyle(
                    color: palette.warning,
                    fontSize: 12.5,
                    height: 1.5,
                  ),
                ),
              )
            else if (versions == null || versions.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  strings.savesHistoryEmpty,
                  style: TextStyle(color: palette.inkMuted, fontSize: 12.5),
                ),
              )
            else
              for (final version in versions)
                _VersionRow(
                  key: ValueKey('${entry.key}-${version.name}-${version.ts}'),
                  version: version,
                  busy: isRestoring,
                  onRestore: () => _confirmRestore(context, version),
                  compact: compact,
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
    this.compact = false,
  });

  final CloudSaveVersion version;
  final bool busy;
  final VoidCallback onRestore;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final palette = context.garden;
    final strings = context.strings;
    final parts = <String>[
      _formatTime(version.ts),
      _formatBytes(version.bytes),
      if (version.device.isNotEmpty) version.device,
      if (version.playerName != null) version.playerName!,
      if (version.summary['coin'] != null)
        '${strings.savesCoin} ${version.summary['coin']}',
      if (version.summary['gem'] != null)
        '${strings.savesGem} ${version.summary['gem']}',
    ];
    return Padding(
      padding: EdgeInsets.only(bottom: compact ? 6 : 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              parts.join(' · '),
              style: TextStyle(
                color: palette.inkMuted,
                fontSize: compact ? 11.5 : 12,
              ),
            ),
          ),
          const SizedBox(width: 8),
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
  const _Notice({
    required this.text,
    required this.color,
    this.action,
    this.compact = false,
  });

  final String text;
  final Color color;
  final Widget? action;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final palette = context.garden;
    return SurfaceCard(
      padding: EdgeInsets.all(compact ? 12 : 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: palette.inkMuted,
                fontSize: compact ? 12 : 12.5,
                height: 1.5,
              ),
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
