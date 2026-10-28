// 把 `buildLocalSaveGuardScript()` 的输出打到 stdout，供 Node 验收脚本执行。
//
// 用法: dart run tool/dump_local_save_guard.dart 0.16.2
// 为什么单独一个入口：版本保护逻辑在 Dart 常量里生成、在 WebView/CEF 里执行，
// 只有真正跑一遍 JS 才能验证「连续降级不覆盖备份」这类状态机行为。
import 'dart:io';

import 'package:gardendless_loader/src/services/local_save_guard.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    throw StateError('usage: dump_local_save_guard.dart <gameVersion>');
  }
  // dart run 可能先打印构建钩子；调用方按 `;(function` 截断。
  stdout.writeln(buildLocalSaveGuardScript(args.first));
}
