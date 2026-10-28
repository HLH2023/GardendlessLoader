import 'package:flutter/material.dart';

import '../../app_controller.dart';
import '../../l10n/app_strings.dart';
import '../launcher_actions.dart';
import '../theme/garden_theme.dart';
import '../widgets/token_login_dialog.dart';
import '../widgets/garden_widgets.dart';

/// 全局登录卡片。
///
/// 游玩形态固定为本地资源包，所以这张卡只负责启动器级别的账号：
/// 云存档 / 资源下载 / 存档管理共用一份令牌。
class AccountCard extends StatelessWidget {
  const AccountCard({
    super.key,
    required this.controller,
    required this.actions,
    this.compact = false,
  });

  final AppController controller;
  final LauncherActions actions;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return SurfaceCard(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 16 : 20,
        vertical: compact ? 12 : 20,
      ),
      child: _AccountRow(
        controller: controller,
        actions: actions,
        compact: compact,
      ),
    );
  }
}

class _AccountRow extends StatelessWidget {
  const _AccountRow({
    required this.controller,
    required this.actions,
    this.compact = false,
  });

  final AppController controller;
  final LauncherActions actions;
  final bool compact;

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
              size: compact ? 16 : 18,
              color: signedIn ? palette.accent : palette.inkMuted,
            ),
            const SizedBox(width: 8),
            Text(
              strings.accountTitle,
              style: TextStyle(
                color: palette.ink,
                fontSize: compact ? 13.5 : 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                signedIn
                    ? '${strings.accountSignedInAs} $account'
                    : strings.accountSignedOut,
                style: TextStyle(
                  color: palette.inkMuted,
                  fontSize: compact ? 12 : 12.5,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        SizedBox(height: compact ? 6 : 8),
        Text(
          strings.accountHint,
          style: TextStyle(
            color: palette.inkMuted,
            fontSize: compact ? 11.5 : 12,
            height: 1.45,
          ),
        ),
        SizedBox(height: compact ? 8 : 12),
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
              label: Text(
                  signedIn ? strings.accountReSignIn : strings.accountSignIn),
            ),
            if (signedIn)
              OutlinedButton.icon(
                onPressed: () async {
                  await controller.signOutAccount();
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                        content: Text(context.strings.accountSignedOutDone)),
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
