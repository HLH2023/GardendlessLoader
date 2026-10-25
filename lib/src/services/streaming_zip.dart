import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// 极简流式 ZIP 读取器。
///
/// 为什么不用 `package:archive`：它的 `ZipDecoder().decodeStream()` 虽然返回
/// `Archive`，但会把每个 entry 的解压内容都留在 `ArchiveFile.content` 里 ——
/// 实测解我们 1.31 GB 的资源包时进程峰值 RSS 达到 **1600 MB**，等于把整包读进
/// 内存。桌面客户端不能这么干（用户机器可能只有 8 GB）。
///
/// 这里只做解压需要的最小集合：
///   - 读中央目录（EOCD + ZIP64 EOCD）
///   - 逐条目定位本地头 → 获取数据起点 → 按压缩大小流式读到磁盘
///   - stored(0) 直接搬运；deflate(8) 用 `ZLibDecoder(raw: true)` 分块转换
///   - 越界条目（`../`、绝对路径）跳过并计数，绝不写穿目标目录
class StreamingZip {
  const StreamingZip();

  /// 解压 [zip] 到 [target]，返回写入文件数与跳过的越界条目数。
  Future<ZipExtractSummary> extract({
    required File zip,
    required Directory target,
    void Function(int files, int bytes, int totalBytes)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final totalBytes = await zip.length();
    await target.create(recursive: true);
    final canonicalTarget = p.canonicalize(target.path);
    final entries = await readCentralDirectory(zip);

    final reader = await zip.open();
    var files = 0;
    var skipped = 0;
    var written = 0;
    try {
      for (final entry in entries) {
        if (isCancelled?.call() ?? false) {
          throw const ZipFailure('解压已取消', code: 'cancelled');
        }
        final name = entry.name.replaceAll('\\', '/');
        if (name.endsWith('/')) continue; // 目录条目：落文件时自动创建
        final destination = _safeDestination(canonicalTarget, name);
        if (destination == null) {
          skipped += 1;
          continue;
        }
        final dataStart = await _dataOffset(reader, entry);
        if (dataStart == null) {
          skipped += 1; // 本地头损坏：宁可少导一个文件，也不猜
          continue;
        }
        final file = File(destination);
        await file.parent.create(recursive: true);
        final sink = file.openWrite();
        try {
          await _copyEntry(
            reader: reader,
            entry: entry,
            dataStart: dataStart,
            sink: sink,
          );
        } finally {
          await sink.close();
        }
        files += 1;
        written += entry.uncompressedSize;
        onProgress?.call(files, written.clamp(0, totalBytes), totalBytes);
      }
    } finally {
      await reader.close();
    }
    return ZipExtractSummary(files: files, skippedEntries: skipped);
  }

  /// 解析中央目录。ZIP64（条目数/偏移溢出 32 位）也支持。
  Future<List<ZipEntry>> readCentralDirectory(File zip) async {
    final length = await zip.length();
    if (length < 22) {
      throw const ZipFailure('文件太小，不是有效的 ZIP', code: 'zip_invalid');
    }
    final reader = await zip.open();
    try {
      // EOCD 在文件末尾，最多带 64 KB 注释
      final tailLength = length < 65557 ? length : 65557;
      await reader.setPosition(length - tailLength);
      final tail = await reader.read(tailLength);
      var eocd = -1;
      for (var i = tail.length - 22; i >= 0; i--) {
        if (tail[i] == 0x50 &&
            tail[i + 1] == 0x4b &&
            tail[i + 2] == 0x05 &&
            tail[i + 3] == 0x06) {
          eocd = i;
          break;
        }
      }
      if (eocd < 0) {
        throw const ZipFailure('找不到 ZIP 目录末尾记录', code: 'zip_invalid');
      }
      final view = ByteData.sublistView(tail);
      var entryCount = view.getUint16(eocd + 10, Endian.little);
      var directoryOffset = view.getUint32(eocd + 16, Endian.little);
      var directorySize = view.getUint32(eocd + 12, Endian.little);

      if (entryCount == 0xFFFF ||
          directoryOffset == 0xFFFFFFFF ||
          directorySize == 0xFFFFFFFF) {
        final zip64 = await _readZip64End(tail, view, eocd, length, reader);
        if (zip64 == null) {
          throw const ZipFailure('ZIP64 目录结构不完整', code: 'zip64_unsupported');
        }
        entryCount = zip64.count;
        directoryOffset = zip64.offset;
      }

      await reader.setPosition(directoryOffset);
      final directory = await reader.read(directorySize);
      return _parseEntries(directory, entryCount);
    } finally {
      await reader.close();
    }
  }

  Future<({int count, int offset})?> _readZip64End(
    Uint8List tail,
    ByteData view,
    int eocd,
    int fileLength,
    RandomAccessFile reader,
  ) async {
    // ZIP64 locator 紧挨在 EOCD 之前（20 字节）
    final locatorStart = eocd - 20;
    if (locatorStart < 0) return null;
    if (!(tail[locatorStart] == 0x50 &&
        tail[locatorStart + 1] == 0x4b &&
        tail[locatorStart + 2] == 0x06 &&
        tail[locatorStart + 3] == 0x07)) {
      return null;
    }
    final lv = ByteData.sublistView(tail);
    final zip64Offset = lv.getUint64(locatorStart + 8, Endian.little);
    if (zip64Offset <= 0 || zip64Offset + 56 > fileLength) return null;
    await reader.setPosition(zip64Offset);
    final record = await reader.read(56);
    if (record.length < 56) return null;
    if (!(record[0] == 0x50 &&
        record[1] == 0x4b &&
        record[2] == 0x06 &&
        record[3] == 0x06)) {
      return null;
    }
    final rv = ByteData.sublistView(record);
    return (
      count: rv.getUint64(32, Endian.little),
      offset: rv.getUint64(48, Endian.little),
    );
  }

  List<ZipEntry> _parseEntries(Uint8List directory, int expectedCount) {
    final entries = <ZipEntry>[];
    var offset = 0;
    while (offset + 46 <= directory.length) {
      final view = ByteData.sublistView(directory, offset);
      if (view.getUint32(0, Endian.little) != 0x02014b50) break;
      final flags = view.getUint16(8, Endian.little);
      final method = view.getUint16(10, Endian.little);
      final compressed = view.getUint32(20, Endian.little);
      final uncompressed = view.getUint32(24, Endian.little);
      final nameLength = view.getUint16(28, Endian.little);
      final extraLength = view.getUint16(30, Endian.little);
      final commentLength = view.getUint16(32, Endian.little);
      var localOffset = view.getUint32(42, Endian.little);
      final nameStart = offset + 46;
      if (nameStart + nameLength > directory.length) break;
      final name = _decodeName(
        directory.sublist(nameStart, nameStart + nameLength),
        flags,
      );
      var comp = compressed;
      var uncomp = uncompressed;
      if (comp == 0xFFFFFFFF || uncomp == 0xFFFFFFFF || localOffset == 0xFFFFFFFF) {
        final extraStart = nameStart + nameLength;
        final extraEnd = extraStart + extraLength;
        if (extraEnd <= directory.length) {
          final zip64 = _parseZip64Extra(
            directory.sublist(extraStart, extraEnd),
            needUncompressed: uncompressed == 0xFFFFFFFF,
            needCompressed: compressed == 0xFFFFFFFF,
            needOffset: localOffset == 0xFFFFFFFF,
          );
          comp = zip64.compressed ?? comp;
          uncomp = zip64.uncompressed ?? uncomp;
          localOffset = zip64.offset ?? localOffset;
        }
      }
      entries.add(ZipEntry(
        name: name,
        method: method,
        flags: flags,
        compressedSize: comp,
        uncompressedSize: uncomp,
        localHeaderOffset: localOffset,
      ));
      offset = nameStart + nameLength + extraLength + commentLength;
      if (entries.length >= expectedCount) break;
    }
    return entries;
  }

  ({int? uncompressed, int? compressed, int? offset}) _parseZip64Extra(
    Uint8List extra, {
    required bool needUncompressed,
    required bool needCompressed,
    required bool needOffset,
  }) {
    var index = 0;
    while (index + 4 <= extra.length) {
      final view = ByteData.sublistView(extra, index);
      final id = view.getUint16(0, Endian.little);
      final size = view.getUint16(2, Endian.little);
      final bodyStart = index + 4;
      if (bodyStart + size > extra.length) break;
      if (id == 0x0001) {
        final body = ByteData.sublistView(extra.sublist(bodyStart, bodyStart + size));
        var cursor = 0;
        int? uncompressed;
        int? compressed;
        int? offset;
        if (needUncompressed && cursor + 8 <= size) {
          uncompressed = body.getUint64(cursor, Endian.little);
          cursor += 8;
        }
        if (needCompressed && cursor + 8 <= size) {
          compressed = body.getUint64(cursor, Endian.little);
          cursor += 8;
        }
        if (needOffset && cursor + 8 <= size) {
          offset = body.getUint64(cursor, Endian.little);
        }
        return (uncompressed: uncompressed, compressed: compressed, offset: offset);
      }
      index = bodyStart + size;
    }
    return (uncompressed: null, compressed: null, offset: null);
  }

  String _decodeName(List<int> bytes, int flags) {
    // bit 11 = UTF-8；否则按 latin1 兜底（中文文件名的包基本都是 UTF-8）
    if (flags & 0x800 != 0) {
      return _utf8(bytes);
    }
    try {
      return _utf8(bytes);
    } catch (_) {
      return String.fromCharCodes(bytes);
    }
  }

  String _utf8(List<int> bytes) {
    // 用 dart:convert 的 utf8 解码（这里避免额外 import 冲突）
    return const Utf8Codec(allowMalformed: true).decode(bytes);
  }

  /// 数据起点：本地头长度可能与中央目录不同（extra 字段），必须按本地头算。
  Future<int?> _dataOffset(RandomAccessFile reader, ZipEntry entry) async {
    await reader.setPosition(entry.localHeaderOffset);
    final header = await reader.read(30);
    if (header.length < 30) return null;
    final view = ByteData.sublistView(header);
    if (view.getUint32(0, Endian.little) != 0x04034b50) return null;
    final nameLength = view.getUint16(26, Endian.little);
    final extraLength = view.getUint16(28, Endian.little);
    return entry.localHeaderOffset + 30 + nameLength + extraLength;
  }

  Future<void> _copyEntry({
    required RandomAccessFile reader,
    required ZipEntry entry,
    required int dataStart,
    required IOSink sink,
  }) async {
    await reader.setPosition(dataStart);
    if (entry.compressedSize <= 0) return;

    const chunkSize = 1 << 20; // 1 MB/块：内存占用恒定
    if (entry.method == 0) {
      var remaining = entry.compressedSize;
      while (remaining > 0) {
        final want = remaining < chunkSize ? remaining : chunkSize;
        final chunk = await reader.read(want);
        if (chunk.isEmpty) break;
        sink.add(chunk);
        remaining -= chunk.length;
      }
      return;
    }
    if (entry.method != 8) {
      throw ZipFailure(
        '不支持的压缩方式 ${entry.method}（${entry.name}）',
        code: 'zip_unsupported_method',
      );
    }
    final inflater = ZLibDecoder(raw: true).startChunkedConversion(_SinkAdapter(sink));
    var remaining = entry.compressedSize;
    try {
      while (remaining > 0) {
        final want = remaining < chunkSize ? remaining : chunkSize;
        final chunk = await reader.read(want);
        if (chunk.isEmpty) break;
        inflater.add(chunk);
        remaining -= chunk.length;
      }
    } finally {
      inflater.close();
    }
  }

  static String? _safeDestination(String canonicalTarget, String entryName) {
    final normalized = p.normalize(entryName);
    if (normalized.isEmpty ||
        normalized.startsWith('..') ||
        p.isAbsolute(normalized)) {
      return null;
    }
    final destination = p.canonicalize(p.join(canonicalTarget, normalized));
    if (destination == canonicalTarget) return null;
    if (!destination.startsWith('$canonicalTarget${p.separator}')) return null;
    return destination;
  }
}

/// 把 `ByteConversionSink` 的 `add` 接到 IOSink 上（IOSink 自己有缓冲）。
class _SinkAdapter implements Sink<List<int>> {
  _SinkAdapter(this._sink);
  final IOSink _sink;

  @override
  void add(List<int> data) => _sink.add(data);

  @override
  void close() {}
}

class ZipEntry {
  const ZipEntry({
    required this.name,
    required this.method,
    required this.flags,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.localHeaderOffset,
  });

  final String name;
  final int method;
  final int flags;
  final int compressedSize;
  final int uncompressedSize;
  final int localHeaderOffset;
}

class ZipExtractSummary {
  const ZipExtractSummary({required this.files, required this.skippedEntries});
  final int files;
  final int skippedEntries;
}

class ZipFailure implements Exception {
  const ZipFailure(this.message, {required this.code});
  final String message;
  final String code;

  @override
  String toString() => message;
}
