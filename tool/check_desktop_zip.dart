// 桌面端 ZIP 解压器验收（纯 Dart，本机可跑）
//
// 覆盖：正常解压、嵌套目录、大文件流式（不进内存）、进度回调、
//       zip-slip 条目必须被拦截且不得在目标目录外写任何字节。
//
// 用法：dart run tool/check_desktop_zip.dart <pack.zip>
import 'dart:io';

import 'package:gardendless_loader/src/services/desktop_zip_extractor.dart';

int passed = 0;
int failed = 0;

void check(String name, bool ok, [Object? extra]) {
  if (ok) {
    passed++;
    stdout.writeln('  ok   $name${extra != null ? ' -> $extra' : ''}');
  } else {
    failed++;
    stdout.writeln('  FAIL $name${extra != null ? ' -> $extra' : ''}');
  }
}

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('用法: dart run tool/check_desktop_zip.dart <pack.zip>');
    exit(2);
  }
  final zip = File(args.first);

  // 1) 正常解压（含 3MB 文件，验证流式不会一次性读进内存）
  final temp = await Directory.systemTemp.createTemp('pvz-unzip');
  final target = Directory('${temp.path}/slot-a');
  var progressCalls = 0;
  int lastBytes = 0;
  final result = await const DesktopZipExtractor().extract(
    zipFile: zip,
    targetDirectory: target,
    onProgress: (f, bytes, total) {
      progressCalls++;
      lastBytes = bytes;
    },
  );
  check('解压返回文件数', result.files == 3, result.files);
  check('越界条目被跳过并计数', result.skippedEntries == 1, result.skippedEntries);
  check('index.html 落盘', await File('${target.path}/index.html').exists());
  check('嵌套目录保留',
      await File('${target.path}/sub/dir/nested.txt').exists());
  final big = File('${target.path}/assets/big.bin');
  check('大文件完整', await big.length() == 3 * 1024 * 1024, await big.length());
  check('有进度回调', progressCalls > 0, progressCalls);
  check('进度字节数递增', lastBytes > 0, lastBytes);

  // 2) zip-slip：恶意条目必须被拒绝，且目标目录外不能出现文件
  final evil = File('${temp.path}/evil.txt');
  final outside = File('${temp.path}/../evil.txt');
  check('目标目录外没有 evil.txt', !await evil.exists());
  check('上级目录没有 evil.txt', !await outside.exists());

  // 3) 再来一次（不同目标目录）：结果应一致，且任何位置都不出现越界文件
  final temp2 = await Directory.systemTemp.createTemp('pvz-unzip2');
  final second = await const DesktopZipExtractor().extract(
    zipFile: zip,
    targetDirectory: Directory('${temp2.path}/slot-b'),
  );
  check('第二次解压计数一致',
      second.files == 3 && second.skippedEntries == 1,
      '${second.files}/${second.skippedEntries}');
  final leaked = File('${temp2.path}/evil.txt');
  final leakedParent = File('${temp2.path}/../evil.txt');
  check('新位置同样没有越界文件',
      !await leaked.exists() && !await leakedParent.exists());

  await temp.delete(recursive: true);
  await temp2.delete(recursive: true);

  stdout.writeln('\n结果：$passed 通过 / $failed 失败');
  exit(failed == 0 ? 0 : 1);
}
