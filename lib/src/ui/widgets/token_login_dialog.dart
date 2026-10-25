import 'package:flutter/material.dart';

import '../../app_controller.dart';
import '../../l10n/app_strings.dart';
import '../theme/garden_theme.dart';

/// 桌面端登录：浏览器签发页拿到 `pvz_...` 令牌后粘贴回来。
///
/// 为什么需要这条路径：Android 有原生 LoginActivity 闭环，而桌面端没有内嵌
/// 登录页。之前桌面端的登录按钮直接是 disabled（`cloudLoginSupported=false`），
/// 等于 Windows 客户端根本无法登录、也就没有云存档 —— 这里把它补齐。
/// 令牌先经 whoami 校验再落库，避免存进错令牌让所有云功能静默 401。
Future<void> showTokenLoginDialog(
  BuildContext context,
  AppController controller,
) async {
  final strings = context.strings;
  final input = TextEditingController();
  String? error;
  var busy = false;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setState) => AlertDialog(
        title: Text(strings.accountPasteTokenTitle),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                strings.accountPasteTokenHint(controller.deviceTokenUrl),
                style: TextStyle(
                  color: dialogContext.garden.inkMuted,
                  fontSize: 12.5,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: input,
                autofocus: true,
                obscureText: true,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                decoration: const InputDecoration(labelText: 'pvz_...'),
                onChanged: (_) {
                  if (error != null) setState(() => error = null);
                },
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    error!,
                    style: TextStyle(color: dialogContext.garden.danger, fontSize: 12.5),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: busy ? null : () => Navigator.of(dialogContext).pop(),
            child: Text(strings.storageCancel),
          ),
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    setState(() {
                      busy = true;
                      error = null;
                    });
                    final failure = await controller.signInWithToken(input.text);
                    if (!dialogContext.mounted) return;
                    if (failure == null) {
                      Navigator.of(dialogContext).pop();
                      ScaffoldMessenger.of(dialogContext).showSnackBar(
                        SnackBar(content: Text(strings.accountSignedInDone)),
                      );
                      return;
                    }
                    setState(() {
                      busy = false;
                      error = failure;
                    });
                  },
            child: Text(busy ? strings.storageValidating : strings.accountSignIn),
          ),
        ],
      ),
    ),
  );
  input.dispose();
}

