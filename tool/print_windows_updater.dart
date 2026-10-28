// 把 Windows 更新脚本写到磁盘（BOM + CRLF），用于在 Windows 上实机验证。
//
// 应用运行时是 `WindowsUpdaterScript.write()` 写到临时目录再执行；这里复用
// 同一份常量与同一种编码，避免「测的脚本」和「跑的脚本」不是同一份。
//
// 用法:
//   dart run tool/print_windows_updater.dart                 # 打印到 stdout
//   dart run tool/print_windows_updater.dart build/upd.ps1    # 写到文件
import 'dart:io';

import 'package:gardendless_loader/src/services/windows_updater.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stdout.write(WindowsUpdaterScript.script);
    return;
  }
  final file = await WindowsUpdaterScript.write(File(args.first));
  final bytes = await file.length();
  stderr.writeln('wrote ${file.path} ($bytes bytes, UTF-8 BOM + CRLF)');
  // 快速自检：括号/引号必须配对，否则 PowerShell 会直接语法错误。
  final text = WindowsUpdaterScript.script;
  final problems = <String>[
    if ('{'.allMatches(text).length != '}'.allMatches(text).length)
      'braces unbalanced',
    if ('('.allMatches(text).length != ')'.allMatches(text).length)
      'parens unbalanced',
    if (text.codeUnits.where((c) => c == 0x27).length.isOdd)
      'odd number of single quotes',
  ];
  if (problems.isNotEmpty) {
    stderr.writeln('script self-check failed: ${problems.join(', ')}');
    exitCode = 1;
  }
}
