import 'dart:async';
import 'dart:io';

import 'streaming_zip.dart';

/// 桌面端的 ZIP 解压器。
///
/// 为什么需要它：上游的导入链路全走原生 MethodChannel（Kotlin/ObjC 的
/// ZipInputStream），只支持 Android/iOS/鸿蒙。桌面端要能"下载/导入资源包"，
/// 就必须有一条 Dart 侧的路径，否则 Windows 客户端的本地游玩根本用不了。
///
/// 两个硬要求：
///   1. **流式解压**：资源包 1.3 GB，整包读进内存必 OOM，所以用 InputFileStream +
///      decodeStream，每个 entry 边解边写盘。
///   2. **zip-slip 防护**：ZIP 里的条目名可以是 `../../..`，也可以带软链。
///      逐条解析真实落点，越界/软链一律拒绝，绝不在目标目录外写任何字节。
class DesktopZipExtractor {
  const DesktopZipExtractor();

  /// 解压 [zipFile] 到 [targetDirectory]。
  ///
  /// 实测：`package:archive` 的 decodeStream 会把整包解压内容留在内存
  /// （1.31 GB 的资源包 → 峰值 RSS 1600 MB），所以这里走自写的流式读取。
  Future<DesktopZipResult> extract({
    required File zipFile,
    required Directory targetDirectory,
    void Function(int files, int bytes, int totalBytes)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (!await zipFile.exists()) {
      throw const ZipExtractionFailure('资源包不存在', code: 'zip_missing');
    }
    try {
      final summary = await const StreamingZip().extract(
        zip: zipFile,
        target: targetDirectory,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );
      return DesktopZipResult(
        files: summary.files,
        skippedEntries: summary.skippedEntries,
      );
    } on ZipFailure catch (failure) {
      throw ZipExtractionFailure(failure.message, code: failure.code);
    }
  }

}

/// 解压结果：写入的文件数与被跳过的越界条目数。
class DesktopZipResult {
  const DesktopZipResult({required this.files, required this.skippedEntries});
  final int files;
  final int skippedEntries;
}

class ZipExtractionFailure implements Exception {
  const ZipExtractionFailure(this.message, {required this.code});
  final String message;
  final String code;

  @override
  String toString() => message;
}
