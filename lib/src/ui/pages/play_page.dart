import 'package:flutter/material.dart';

import '../../app_controller.dart';
import '../../l10n/app_strings.dart';
import '../launcher_actions.dart';
import '../theme/garden_theme.dart';
import '../widgets/garden_widgets.dart';
import 'account_card.dart';

class PlayPage extends StatefulWidget {
  const PlayPage({
    super.key,
    required this.controller,
    required this.actions,
    required this.compact,
  });

  final AppController controller;
  final LauncherActions actions;
  final bool compact;

  @override
  State<PlayPage> createState() => _PlayPageState();
}

class _PlayPageState extends State<PlayPage> {
  bool _launching = false;

  Future<void> _launch() async {
    if (_launching) return;
    setState(() => _launching = true);
    try {
      await widget.actions.startGame();
    } finally {
      if (mounted) setState(() => _launching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final gap = widget.compact ? 12.0 : 32.0;
    final ready = controller.canStartGame;
    final hero = _Hero(controller: controller, compact: widget.compact);
    final actionBar = _ActionBar(
      ready: ready,
      launching: _launching,
      onLaunch: _launch,
      onImport: () => widget.actions.navigate(LauncherDestination.resources),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final accountCard = AccountCard(
          controller: controller,
          actions: widget.actions,
          compact: widget.compact,
        );
        if (constraints.maxWidth < 560) {
          return ListView(
            children: [
              hero,
              SizedBox(height: gap),
              actionBar,
              SizedBox(height: gap),
              accountCard,
            ],
          );
        }
        // Launcher composition: the key art owns the open area, the title
        // sits bottom-left on the same row as the primary action. On short
        // displays (e.g. 21:9 phones) this scrolls rather than clipping.
        return SingleChildScrollView(
          physics: const ClampingScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: IntrinsicHeight(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Spacer(),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(child: hero),
                      const SizedBox(width: 16),
                      actionBar,
                    ],
                  ),
                  SizedBox(height: gap),
                  // 全局账号：本地资源包启动路径固定，登录只影响云端能力
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: accountCard,
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.controller, required this.compact});

  final AppController controller;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final palette = context.garden;
    final strings = context.strings;
    final ready = controller.canStartGame;
    final journal = controller.journal;
    final lastPlayedAt = journal.lastPlayedAt;
    final details = <String>[
      if (ready) strings.gameVersionLabel(controller.currentGameVersion),
      if (ready)
        !controller.hasGpNext
            ? strings.standardWeb
            : controller.gpNextCompatible
                ? 'GP-Next ${controller.gpNextVersion ?? ''}'.trim()
                : strings.gpNextIncompatibleShort,
      controller.gameHostPlatform.nativeHostName,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        StatusLabel(
          key: const ValueKey('game-readiness-chip'),
          label: ready ? strings.resourcesReady : strings.resourcesNeeded,
          color: ready ? palette.accent : palette.warning,
        ),
        SizedBox(height: compact ? 6 : 16),
        Text(
          ready
              ? displayGameTitle(controller.detectedTitle)
              : 'PvZ2 Gardendless',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: GardenType.title(compact ? 28 : 46, color: palette.ink),
        ),
        SizedBox(height: compact ? 6 : 10),
        Text(
          ready ? details.join('  ·  ') : strings.importToPlayHint,
          style: TextStyle(
            color: palette.inkMuted,
            fontSize: compact ? 13 : 14,
            height: 1.4,
          ),
        ),
        if (ready && lastPlayedAt != null)
          Text(
            '${strings.lastPlayed(lastPlayedAt, Duration(milliseconds: journal.lastPlayMs))}'
            '  ·  ${strings.totalPlayed(Duration(milliseconds: journal.totalPlayMs))}',
            key: const ValueKey('last-played'),
            style: TextStyle(
              color: palette.inkFaint,
              fontSize: compact ? 12 : 13,
              height: 1.4,
            ),
          ),
      ],
    );
  }
}

/// The page's one primary action, anchored bottom-right where the thumb
/// rests in landscape.
class _ActionBar extends StatelessWidget {
  const _ActionBar({
    required this.ready,
    required this.launching,
    required this.onLaunch,
    required this.onImport,
  });

  final bool ready;
  final bool launching;
  final VoidCallback onLaunch;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    final strings = context.strings;
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if (ready)
          GardenButton(
            key: const ValueKey('start-game-button'),
            label: launching ? strings.starting : strings.startGame,
            icon: Icons.play_arrow_rounded,
            tone: GardenButtonTone.primary,
            busy: launching,
            onPressed: onLaunch,
          )
        else
          GardenButton(
            key: const ValueKey('go-import-button'),
            label: strings.goToImport,
            icon: Icons.arrow_forward_rounded,
            tone: GardenButtonTone.primary,
            onPressed: onImport,
          ),
      ],
    );
  }
}
