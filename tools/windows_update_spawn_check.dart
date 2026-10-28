// 只在 Windows 上跑：验证「Dart → 外部更新脚本」这条链路真的启动了脚本。
//
// 为什么单独测这一段（2026-10-27 用户实测）：点「退出并自动更新」后加载器
// 消失了，之后什么都没发生，重启还是旧版本。根因是
// `ProcessStartMode.detached` 在 Windows 上会「成功」返回一个 pid，但子进程
// 根本没有执行——脚本连第一行日志都没写。Linux 上断言不了这件事，只能真机跑。
//
// 关键：这里调用的是生产代码的 `WindowsUpdaterScript.write/start`，不是复制
// 一份参数拼装，所以验证的就是应用实际走的那条路径。父进程在 900 ms 后
// 直接 exit(0)，脚本必须靠自己活下来并把更新做完（结果由 PowerShell 侧
// 读 resultJson 断言）。
//
// 用法（在仓库根）：
//   dart run tools\windows_update_spawn_check.dart <zip> <targetDir> <resultJson> [toVersion]
//
// 退出码：0 已交棒；3 子进程秒退（就是被修掉的那个 bug）；2 环境/参数不对。
import 'dart:io';

import 'package:gardendless_loader/src/services/windows_updater.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  if (!Platform.isWindows) {
    stderr.writeln('windows only');
    exit(2);
  }
  if (args.length < 3) {
    stderr.writeln('usage: <zip> <targetDir> <resultJson> [toVersion]');
    exit(2);
  }
  final zip = File(args[0]);
  final target = args[1];
  final result = File(args[2]);
  final toVersion = args.length > 3 ? args[3] : '0.0.0-test';

  final script = await WindowsUpdaterScript.write(
    File(p.join(p.dirname(result.path), 'apply-windows-update.ps1')),
  );
  final process = await WindowsUpdaterScript.start(
    script: script,
    waitPid: pid,
    zip: zip,
    target: target,
    exe: 'gardendless_loader.exe',
    fromVersion: '0.0.0-old',
    toVersion: toVersion,
    result: result,
  );

  // 应用侧的第一道护栏：脚本 700 ms 后还必须活着。
  var exited = false;
  process.exitCode.then((_) => exited = true).ignore();
  await Future<void>.delayed(const Duration(milliseconds: 900));
  if (exited) {
    stdout.writeln('child-exited-early');
    exit(3);
  }
  stdout.writeln('child-running pid=${process.pid}');
  // 父进程立刻消失：脚本必须自己在父进程退出后继续跑完。
  exit(0);
}
