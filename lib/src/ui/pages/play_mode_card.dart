import 'package:flutter/material.dart';

import '../../app_controller.dart';
import '../../l10n/app_strings.dart';
import '../../services/app_settings_store.dart';
import '../launcher_actions.dart';
import '../theme/garden_theme.dart';
import '../widgets/token_login_dialog.dart';
import '../widgets/garden_widgets.dart';

/// 游玩形态 + 全局登录卡片。
///
/// 两种形态共用同一个本地服务器与同一份存档桥，所以这里只切换「资源从哪来」；
/// 登录态是启动器级别的（云存档 / 资源下载 / 在线游玩 / 存档管理共用一份令牌）。
class PlayModeCard extends StatelessWidget {
  const PlayModeCard({super.key, required this.controller, required this.actions});

  final AppController controller;
  final LauncherActions actions;

  @override
  Widget build(BuildContext context) {
    final palette = context.garden;
    final strings = context.strings;
    final mode = controller.playMode;
    final busy = controller.busy ||
        controller.storageBusy ||
        controller.desktopGameActive ||
        controller.gameLaunchInFlight;

    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            strings.playModeTitle,
            style: TextStyle(
              color: palette.ink,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          SegmentedButton<PlayMode>(
            segments: [
              ButtonSegment(value: PlayMode.local, label: Text(strings.playModeLocal)),
              ButtonSegment(value: PlayMode.online, label: Text(strings.playModeOnline)),
            ],
            selected: {mode},
            onSelectionChanged: busy
                ? null
                : (selection) => controller.setPlayMode(selection.first),
          ),
          const SizedBox(height: 10),
          Text(
            mode == PlayMode.local ? strings.playModeLocalHint : strings.playModeOnlineHint,
            style: TextStyle(color: palette.inkMuted, fontSize: 12.5, height: 1.5),
          ),
          if (mode == PlayMode.local && !controller.hasCurrentResource)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                strings.playModeLocalNeedsResource,
                style: TextStyle(color: palette.danger, fontSize: 12.5),
              ),
            ),
          if (mode == PlayMode.online && !controller.onlinePlaySupported)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                controller.isDesktopPlatform
                    ? strings.playModeOnlineNeedsServer
                    : strings.playModeDesktopOnly,
                style: TextStyle(color: palette.danger, fontSize: 12.5),
              ),
            ),
          const SizedBox(height: 18),
          Divider(color: palette.border, height: 1),
          const SizedBox(height: 14),
          _AccountRow(controller: controller, actions: actions),
        ],
      ),
    );
  }
}

class _AccountRow extends StatelessWidget {
  const _AccountRow({required this.controller, required this.actions});

  final AppController controller;
  final LauncherActions actions;

  @override
  Widget build(BuildContext context) {
    final palette = context.garden;
    final strings = context.strings;
    final signedIn = controller.accountSignedIn;
    final account = controller.accountDisplayName;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              signedIn ? Icons.verified_user_outlined : Icons.person_outline,
              size: 18,
              color: signedIn ? palette.accent : palette.inkMuted,
            ),
            const SizedBox(width: 8),
            Text(
              strings.accountTitle,
              style: TextStyle(color: palette.ink, fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                signedIn ? '${strings.accountSignedInAs} $account' : strings.accountSignedOut,
                style: TextStyle(color: palette.inkMuted, fontSize: 12.5),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          strings.accountHint,
          style: TextStyle(color: palette.inkMuted, fontSize: 12, height: 1.5),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: controller.loginInProgress
                  ? null
                  : () async {
                      if (controller.cloudLoginSupported) {
                        // Android：原生 LoginActivity 闭环
                        await actions.loginWithAuthentik();
                        return;
                      }
                      // 桌面端：先在浏览器打开令牌签发页，再粘贴回来
                      await controller.openTokenIssuePage();
                      if (!context.mounted) return;
                      await showTokenLoginDialog(context, controller);
                    },
              icon: controller.loginInProgress
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.login, size: 18),
              label: Text(signedIn ? strings.accountReSignIn : strings.accountSignIn),
            ),
            if (signedIn)
              OutlinedButton.icon(
                onPressed: () async {
                  await controller.signOutAccount();
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(context.strings.accountSignedOutDone)),
                  );
                },
                icon: const Icon(Icons.logout, size: 18),
                label: Text(strings.accountSignOut),
              ),
          ],
        ),
      ],
    );
  }
}
