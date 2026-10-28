import 'dart:io';

import 'package:flutter/services.dart';

/// 统一的外部链接打开方式。
///
/// 移动端有原生 `external_browser` 通道；Windows/macOS/Linux 从未实现它，
/// 直接调通道会抛 `MissingPluginException`。桌面端因此走各平台的外壳命令。
///
/// 为什么单独抽出来：这个调用最初只出现在「登录」路径里，副作用是点链接
/// 没反应；后来公告/更新链接也走它。一旦有调用落在初始化路径上，异常会被
/// `initialize()` 的兜底 catch 接住，表现成整页「应用初始化失败」（2026-10-27
/// Windows 实测的同款故障）。集中到一处，桌面端就不可能再漏掉平台分支。
class ExternalUrlService {
  const ExternalUrlService();

  static const MethodChannel _channel = MethodChannel(
    'io.github.dey410.gardendlessloader/external_browser',
  );

  Future<void> open(String url) async {
    if (url.isEmpty) return;
    if (Platform.isWindows) {
      // 不能走 `cmd /c start`：URL 里（尤其是 OAuth 回调、带跟踪参数的公告）
      // 常有 `&`，cmd 会把它当命令分隔符。2026-10-27 在 Windows 上用本地 HTTP
      // 服务器实测：`http://127.0.0.1/port/game?uid=42&profile=slots-1&ver=hlh.26`
      // 只有 `/game?uid=42` 到达浏览器，剩下的部分被 cmd 当作独立命令执行。
      // 结果既打开了错误的地址，也留下命令注入面。
      //
      // rundll32 走 ShellExecute，参数按 argv 传递，不经过任何 shell 解析；
      // 同一次实测里它把完整 URL 送进了浏览器。
      final opened = await Process.run(
        'rundll32',
        <String>['url.dll,FileProtocolHandler', url],
      );
      if (opened.exitCode == 0) return;
      // rundll32 是常见的 LOLBin，杀软会拦。退回 PowerShell 的 ShellExecute：
      // URL 放在单引号里（内部单引号按 PS 规则双写），同样不经过 shell 分词。
      await Process.run('powershell', <String>[
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        "Start-Process -FilePath '${url.replaceAll("'", "''")}'",
      ]);
      return;
    }
    if (Platform.isMacOS) {
      await Process.run('open', [url]);
      return;
    }
    if (Platform.isLinux) {
      await Process.run('xdg-open', [url]);
      return;
    }
    await _channel.invokeMethod<void>('open', <String, Object?>{'url': url});
  }
}
