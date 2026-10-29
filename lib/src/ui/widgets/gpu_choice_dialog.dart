import 'package:flutter/material.dart';

import '../../l10n/app_strings.dart';
import '../../services/gpu_adapter.dart';
import '../theme/garden_theme.dart';
import 'garden_widgets.dart';

/// 首次进游戏（或设置页手动点「选择显卡」）的结果。
class GpuChoiceResult {
  const GpuChoiceResult({required this.preference, required this.remember});

  final GpuPreference preference;
  final bool remember;
}

/// 让用户在三档里选一个。Windows 不支持直接指定第三块显卡，所以这里
/// 展示的是系统认定的「高性能 / 节能」两块，而不是把枚举结果全列出来。
Future<GpuChoiceResult?> showGpuChoiceDialog(
  BuildContext context, {
  required List<GpuAdapterInfo> adapters,
  required GpuPreference initial,
  bool allowCancel = true,
}) {
  return showDialog<GpuChoiceResult>(
    context: context,
    barrierDismissible: allowCancel,
    builder: (context) => _GpuChoiceDialog(
      adapters: adapters,
      initial: initial,
      allowCancel: allowCancel,
    ),
  );
}

/// 更改显卡后必须重启：Flutter 引擎和 CEF 都只在进程创建时选一次显卡。
Future<bool> showGpuRestartDialog(BuildContext context) async {
  final strings = context.strings;
  final palette = context.garden;
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      key: const ValueKey('gpu-restart-dialog'),
      title: Text(strings.gpuRestartTitle),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Text(
          strings.gpuRestartBody,
          style: TextStyle(color: palette.inkMuted, height: 1.55),
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      actions: [
        GardenButton(
          label: strings.gpuRestartLater,
          compact: true,
          tone: GardenButtonTone.ghost,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        GardenButton(
          label: strings.gpuRestartNow,
          compact: true,
          tone: GardenButtonTone.primary,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    ),
  );
  return result ?? false;
}

class _GpuChoiceDialog extends StatefulWidget {
  const _GpuChoiceDialog({
    required this.adapters,
    required this.initial,
    required this.allowCancel,
  });

  final List<GpuAdapterInfo> adapters;
  final GpuPreference initial;
  final bool allowCancel;

  @override
  State<_GpuChoiceDialog> createState() => _GpuChoiceDialogState();
}

class _GpuChoiceDialogState extends State<_GpuChoiceDialog> {
  late GpuPreference _selected =
      _available(widget.initial) ? widget.initial : GpuPreference.automatic;
  bool _remember = true;

  bool _available(GpuPreference preference) {
    if (preference == GpuPreference.highPerformance) {
      return highPerformanceAdapter(widget.adapters) != null;
    }
    if (preference == GpuPreference.powerSaving) {
      return powerSavingAdapter(widget.adapters) != null;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final strings = context.strings;
    final palette = context.garden;
    final high = highPerformanceAdapter(widget.adapters);
    final power = powerSavingAdapter(widget.adapters);

    return AlertDialog(
      key: const ValueKey('gpu-choice-dialog'),
      title: Text(strings.gpuDialogTitle),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                strings.gpuDialogSubtitle,
                style: TextStyle(color: palette.inkMuted, height: 1.55),
              ),
              const SizedBox(height: 12),
              RadioGroup<GpuPreference>(
                groupValue: _selected,
                onChanged: (value) {
                  if (value != null) setState(() => _selected = value);
                },
                child: Column(
                  children: [
                    RadioListTile<GpuPreference>(
                      key: const ValueKey('gpu-choice-automatic'),
                      value: GpuPreference.automatic,
                      contentPadding: EdgeInsets.zero,
                      title: Text(strings.gpuPreferenceAutomatic),
                    ),
                    if (high != null)
                      RadioListTile<GpuPreference>(
                        key: const ValueKey('gpu-choice-high'),
                        value: GpuPreference.highPerformance,
                        contentPadding: EdgeInsets.zero,
                        title: Text(strings.gpuPreferenceHigh),
                        subtitle: _AdapterLine(
                          adapter: high,
                          recommended: true,
                        ),
                      ),
                    if (power != null &&
                        (high == null ||
                            power.name != high.name ||
                            power.vendorId != high.vendorId))
                      RadioListTile<GpuPreference>(
                        key: const ValueKey('gpu-choice-power'),
                        value: GpuPreference.powerSaving,
                        contentPadding: EdgeInsets.zero,
                        title: Text(strings.gpuPreferencePower),
                        subtitle: _AdapterLine(adapter: power),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              CheckboxListTile(
                key: const ValueKey('gpu-choice-remember'),
                value: _remember,
                onChanged: (value) =>
                    setState(() => _remember = value ?? false),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(strings.gpuDialogRemember),
              ),
            ],
          ),
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      actions: [
        if (widget.allowCancel)
          GardenButton(
            label: strings.gpuDialogCancel,
            compact: true,
            tone: GardenButtonTone.ghost,
            onPressed: () => Navigator.of(context).pop(),
          ),
        GardenButton(
          label: strings.gpuDialogSave,
          compact: true,
          tone: GardenButtonTone.primary,
          onPressed: () => Navigator.of(context).pop(
            GpuChoiceResult(preference: _selected, remember: _remember),
          ),
        ),
      ],
    );
  }
}

class _AdapterLine extends StatelessWidget {
  const _AdapterLine({required this.adapter, this.recommended = false});

  final GpuAdapterInfo adapter;
  final bool recommended;

  @override
  Widget build(BuildContext context) {
    final strings = context.strings;
    final palette = context.garden;
    return Text(
      recommended
          ? '${adapter.label} · ${strings.gpuRecommended}'
          : adapter.label,
      style: TextStyle(color: palette.inkMuted, fontSize: 12.5),
    );
  }
}
