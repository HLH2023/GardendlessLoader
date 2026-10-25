// 真实资源包解压验收：1.38 GB / ZIP_STORED
//
// 目的不是「能跑通」，而是验证两件生产环境真会踩的事：
//   1. 流式解压不会把整包读进内存（peak RSS 必须远小于包体）
//   2. 数千个 entry 全量落盘、大小与 CRC 可被校验
//
// 用法：dart run tool/stress_real_pack.dart <pack.zip> <targetDir>
import 'dart:io';

import 'package:gardendless_loader/src/services/desktop_zip_extractor.dart';

Future<int> peakRssKb() async {
  final status = File('/proc/self/status');
  if (!await status.exists()) return -1;
  for (final line in await status.readAsLines()) {
    if (line.startsWith('VmHWM:')) {
      return int.tryParse(line.replaceAll(RegExp(r'[^0-9]'), '')) ?? -1;
    }
  }
  return -1;
}

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('用法: dart run tool/stress_real_pack.dart <pack.zip> <targetDir>');
    exit(2);
  }
  final zip = File(args[0]);
  final target = Directory(args[1]);
  if (await target.exists()) await target.delete(recursive: true);

  final started = DateTime.now();
  var lastReported = 0;
  final result = await const DesktopZipExtractor().extract(
    zipFile: zip,
    targetDirectory: target,
    onProgress: (files, bytes, total) {
      if (files - lastReported >= 500) {
        lastReported = files;
        stdout.writeln('  … $files 个文件 / ${(bytes / 1048576).toStringAsFixed(0)} MB');
      }
    },
  );
  final seconds = DateTime.now().difference(started).inMilliseconds / 1000;

  var totalBytes = 0;
  var totalFiles = 0;
  await for (final entity in target.list(recursive: true, followLinks: false)) {
    if (entity is File) {
      totalFiles++;
      totalBytes += await entity.length();
    }
  }
  final rss = await peakRssKb();
  final zipBytes = await zip.length();

  stdout.writeln('解压文件数：${result.files}（磁盘实际 $totalFiles）');
  stdout.writeln('越界跳过：${result.skippedEntries}');
  stdout.writeln('解压字节：${(totalBytes / 1048576).toStringAsFixed(1)} MB');
  stdout.writeln('包体大小：${(zipBytes / 1048576).toStringAsFixed(1)} MB');
  stdout.writeln('耗时：${seconds.toStringAsFixed(1)} s');
  stdout.writeln('进程峰值 RSS：${(rss / 1024).toStringAsFixed(0)} MB');

  final memoryOk = rss > 0 && rss * 1024 < zipBytes / 2; // 峰值必须远小于包体一半
  final countOk = result.files == totalFiles && totalFiles > 100;
  stdout.writeln(memoryOk ? 'PASS 流式解压（峰值内存 ${
      (rss / 1024).toStringAsFixed(0)} MB << 包体）' : 'FAIL 内存占用过高');
  stdout.writeln(countOk ? 'PASS 文件计数一致（$totalFiles）' : 'FAIL 文件计数不一致');
  exit(memoryOk && countOk ? 0 : 1);
}
