import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_controller.dart';
import '../../l10n/app_strings.dart';
import '../../services/storage_migration.dart';
import '../theme/garden_theme.dart';
import '../widgets/garden_widgets.dart';

/// 资源存储位置卡片：展示当前路径与占用，支持迁移到任意目录。
///
/// Android 与桌面端共用同一份实现——迁移逻辑在 [ResourceMigration] 里，
/// 与 UI 无关，因此两端行为一致。
class StorageLocationCard extends StatefulWidget {
  const StorageLocationCard({super.key, required this.controller});

  final AppController controller;

  @override
  State<StorageLocationCard> createState() => _StorageLocationCardState();
}

class _StorageLocationCardState extends State<StorageLocationCard> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.controller.refreshStorageUsage();
    });
  }

  Future<void> _showChangeDialog() async {
    final path = await showDialog<String>(
      context: context,
      builder: (_) => _StoragePickerDialog(controller: widget.controller),
    );
    if (path == null || !mounted) return;
    final error = await widget.controller.changeStorageRoot(path);
    if (!mounted) return;
    final strings = context.strings;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(error ?? '${strings.storageSwitched}：$path'),
      ),
    );
  }

  Future<void> _restoreDefault() async {
    final defaultPath = await widget.controller.storageDefaultPath();
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(dialogContext.strings.storageRestoreDefault),
        content: Text(defaultPath),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(dialogContext.strings.storageCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(dialogContext.strings.storageConfirmMigrate),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final error = await widget.controller.changeStorageRoot(defaultPath);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error ?? context.strings.storageSwitched)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.garden;
    final strings = context.strings;
    final controller = widget.controller;
    final usage = controller.storageUsage;
    final busy = controller.storageBusy || controller.busy;
    final path = controller.storageRootPath;

    final captionStyle = TextStyle(color: palette.inkMuted, fontSize: 13, height: 1.5);
    final pathStyle = TextStyle(
      color: palette.ink,
      fontSize: 13,
      height: 1.5,
      fontFamily: 'monospace',
      fontFamilyFallback: const ['Consolas', 'Menlo', 'DejaVu Sans Mono'],
    );

    final usageText = usage == null
        ? strings.storageUsageUnknown
        : strings.storageUsageSummary(usage.bytesLabel, usage.files);
    final freeText = usage?.freeLabel;

    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.folder_open_outlined, size: 18, color: palette.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  strings.storageTitle,
                  style: TextStyle(
                    color: palette.ink,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: palette.surface,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: palette.border),
                ),
                child: Text(
                  controller.storageFromConfigured
                      ? strings.storageFromCustom
                      : strings.storageFromDefault,
                  style: TextStyle(color: palette.inkMuted, fontSize: 11),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (busy)
            Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Text(strings.storageMigrating, style: captionStyle),
              ],
            )
          else
            SelectableText(
              path ?? strings.storageNotConfigured,
              style: pathStyle,
              maxLines: 3,
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 14,
            runSpacing: 4,
            children: [
              Text(usageText, style: captionStyle),
              if (freeText != null) Text(strings.storageFreeLabel(freeText), style: captionStyle),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: busy ? null : _showChangeDialog,
                icon: const Icon(Icons.swap_horiz, size: 18),
                label: Text(strings.storageChange),
              ),
              OutlinedButton.icon(
                onPressed: busy ? null : _restoreDefault,
                icon: const Icon(Icons.settings_backup_restore, size: 18),
                label: Text(strings.storageRestoreDefault),
              ),
              TextButton.icon(
                onPressed: busy ? null : controller.refreshStorageUsage,
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(strings.storageRefresh),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 目录选择 + 校验 + 迁移确认。
class _StoragePickerDialog extends StatefulWidget {
  const _StoragePickerDialog({required this.controller});

  final AppController controller;

  @override
  State<_StoragePickerDialog> createState() => _StoragePickerDialogState();
}

class _StoragePickerDialogState extends State<_StoragePickerDialog> {
  late final TextEditingController _path = TextEditingController(
    text: widget.controller.storageRootPath ?? '',
  );
  StorageCheck? _check;
  bool _checking = false;
  int _checkSeq = 0;

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  Future<void> _pickFolder() async {
    try {
      final picked = await FilePicker.getDirectoryPath(
        dialogTitle: context.strings.storageDialogTitle,
      );
      if (picked == null || !mounted) return;
      setState(() => _path.text = picked);
      await _validate();
    } catch (e) {
      if (!mounted) return;
      setState(() => _check = StorageCheck(ok: false, message: '无法打开目录选择器：$e'));
    }
  }

  Future<void> _validate() async {
    final target = _path.text.trim();
    if (target.isEmpty) {
      setState(() => _check = const StorageCheck(ok: false, message: '路径不能为空'));
      return;
    }
    final seq = ++_checkSeq;
    setState(() {
      _checking = true;
      _check = null;
    });
    final result = await widget.controller.checkStorageTarget(target);
    if (!mounted || seq != _checkSeq) return; // 过期结果直接丢弃
    setState(() {
      _checking = false;
      _check = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.garden;
    final strings = context.strings;
    final check = _check;
    final canConfirm = !_checking && check != null && check.ok;
    return AlertDialog(
      title: Text(strings.storageDialogTitle),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              strings.storageDialogBody,
              style: TextStyle(color: palette.inkMuted, fontSize: 13, height: 1.5),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _path,
              autofocus: true,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r'[\n\r]'))],
              decoration: InputDecoration(
                labelText: strings.storagePathHint,
                hintText: Platform.isWindows ? r'D:\Gardendless\res' : '/storage/emulated/0/res',
                suffixIcon: IconButton(
                  tooltip: strings.storagePickFolder,
                  onPressed: _pickFolder,
                  icon: const Icon(Icons.folder_open),
                ),
              ),
              onChanged: (_) {
                if (_check != null) setState(() => _check = null);
              },
              onSubmitted: (_) => _validate(),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                OutlinedButton(
                  onPressed: _checking ? null : _validate,
                  child: Text(strings.storageValidating),
                ),
                const SizedBox(width: 10),
                if (_checking)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                if (!_checking && check != null)
                  Expanded(
                    child: Text(
                      check.message ?? '',
                      style: TextStyle(
                        color: check.ok ? palette.accent : palette.danger,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.storageCancel),
        ),
        FilledButton(
          onPressed: canConfirm ? () => Navigator.of(context).pop(_path.text.trim()) : null,
          child: Text(strings.storageConfirmMigrate),
        ),
      ],
    );
  }
}
