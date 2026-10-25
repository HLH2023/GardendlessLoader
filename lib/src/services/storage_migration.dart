import 'dart:io';

import 'package:path/path.dart' as p;

/// 资源目录的搬迁、校验与统计。
///
/// 这一层刻意不依赖 Flutter（只用 dart:io），因为它是最容易出错、最需要
/// 在测试机上反复验证的部分：`dart run tool/check_storage_migration.dart`
/// 能直接跑，不需要真机、不需要 Flutter binding。
///
/// 迁移是两阶段的：先逐个条目搬到新位置（源目录保持可用），全部成功才写指针；
/// 中途失败就把已搬过去的条目搬回来，回滚后应用仍从老位置正常启动。
class ResourceMigration {
  /// 允许迁移的条目（下载缓存也一起搬，避免用户以为空间没释放）。
  static const movableEntries = [
    'manifest.json',
    'settings.json',
    'slot-a',
    'slot-b',
    'gp-next',
    'downloads',
  ];

  /// 校验候选目录是否可用作资源根（不改变任何状态）。
  Future<StorageCheck> validate(Directory candidate, {Directory? currentRoot}) async {
    final path = candidate.path.trim();
    if (path.isEmpty) {
      return const StorageCheck(ok: false, message: '路径不能为空');
    }
    if (!p.isAbsolute(path)) {
      return const StorageCheck(ok: false, message: '请使用绝对路径');
    }
    if (currentRoot != null) {
      final rootPath = p.canonicalize(currentRoot.path);
      final normalized = p.canonicalize(path);
      if (normalized == rootPath) {
        return const StorageCheck(ok: false, message: '这就是当前存储位置');
      }
      if (normalized.startsWith('$rootPath${p.separator}')) {
        return const StorageCheck(ok: false, message: '不能放在当前资源目录里面');
      }
    }
    final dir = Directory(path);
    try {
      if (await File(path).exists()) {
        return const StorageCheck(ok: false, message: '这是一个文件，不是目录');
      }
      final existed = await dir.exists();
      await dir.create(recursive: true);
      // 能建目录不等于能写：外接盘只读、权限不足都要在这里暴露
      final probe = File(p.join(dir.path, '.pvz_write_probe'));
      await probe.writeAsString('ok', flush: true);
      await probe.delete();
      return StorageCheck(ok: true, message: existed ? '目录可用' : '目录已创建');
    } on FileSystemException catch (e) {
      return StorageCheck(ok: false, message: '不可写：${e.osError?.message ?? e.message}');
    } catch (e) {
      return StorageCheck(ok: false, message: '不可用：$e');
    }
  }

  /// 统计目录占用。
  Future<StorageUsage> usage(Directory root) async {
    var bytes = 0;
    var files = 0;
    if (await root.exists()) {
      await for (final entity in root.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            bytes += await entity.length();
            files++;
          } catch (_) {}
        }
      }
    }
    int? freeBytes;
    try {
      freeBytes = await freeSpaceFor(root.path);
    } catch (_) {}
    return StorageUsage(bytes: bytes, files: files, freeBytes: freeBytes);
  }

  /// 目录所在卷的剩余空间。Windows 走 PowerShell，类 Unix 走 df。
  Future<int?> freeSpaceFor(String path) async {
    try {
      if (Platform.isWindows) {
        final drive = p.rootPrefix(path).replaceAll(RegExp(r'[\\/:]'), '');
        if (drive.isEmpty) return null;
        final result = await Process.run('powershell', [
          '-NoProfile',
          '-Command',
          '(Get-PSDrive -Name $drive).Free',
        ]);
        return int.tryParse((result.stdout as String).trim());
      }
      final result = await Process.run('df', ['-B1', '--output=avail', path]);
      final lines = (result.stdout as String).trim().split('\n');
      if (lines.length < 2) return null;
      return int.tryParse(lines.last.trim());
    } catch (_) {
      return null;
    }
  }

  /// 把 [sourceRoot] 下的资源条目搬到 [target]。
  ///
  /// 返回值中的 `ok=true` 只代表「文件已就位」，指针由调用方写；
  /// 调用方写指针失败时应当调用 [rollback] 把条目搬回去。
  Future<StorageMigrationResult> migrate({
    required Directory sourceRoot,
    required Directory target,
    void Function(String entry, int done, int total)? onProgress,
  }) async {
    final check = await validate(target, currentRoot: sourceRoot);
    if (!check.ok) {
      return StorageMigrationResult.failure(check.message ?? '目标不可用');
    }
    final entries = <FileSystemEntity>[];
    for (final name in movableEntries) {
      final path = p.join(sourceRoot.path, name);
      final type = FileSystemEntity.typeSync(path);
      if (type == FileSystemEntityType.notFound) continue;
      entries.add(type == FileSystemEntityType.directory
          ? Directory(path)
          : File(path));
    }

    final moved = <String>[];
    var index = 0;
    try {
      for (final entry in entries) {
        final name = p.basename(entry.path);
        await moveEntry(entry, p.join(target.path, name));
        moved.add(name);
        index++;
        onProgress?.call(name, index, entries.length);
      }
    } on FileSystemException catch (e) {
      final errors = await rollback(target: target, sourceRoot: sourceRoot, moved: moved);
      return StorageMigrationResult.failure(
        '迁移失败：${e.osError?.message ?? e.message}',
        rolledBack: moved.length - errors.length,
        rollbackErrors: errors,
      );
    }

    return StorageMigrationResult(
      ok: true,
      path: target.path,
      movedEntries: List.unmodifiable(moved),
    );
  }

  /// 把已搬走的条目搬回源目录（写指针失败或迁移中断时用）。
  Future<List<String>> rollback({
    required Directory target,
    required Directory sourceRoot,
    required List<String> moved,
  }) async {
    final errors = <String>[];
    for (final name in moved.reversed) {
      try {
        final path = p.join(target.path, name);
        final type = FileSystemEntity.typeSync(path);
        if (type == FileSystemEntityType.notFound) continue;
        final entity =
            type == FileSystemEntityType.directory ? Directory(path) : File(path);
        await moveEntry(entity, p.join(sourceRoot.path, name));
      } catch (e) {
        errors.add('$name: $e');
      }
    }
    return errors;
  }

  /// 单个条目搬迁：rename 优先（同盘瞬间完成），跨盘退化为复制 + 校验 + 删除。
  Future<void> moveEntry(FileSystemEntity source, String destination) async {
    if (FileSystemEntity.typeSync(destination) != FileSystemEntityType.notFound) {
      await deleteEntity(destination);
    }
    try {
      if (source is Directory) {
        await source.rename(destination);
      } else {
        await source.rename(destination);
      }
      return;
    } on FileSystemException {
      // 跨文件系统 rename 会失败（EXDEV），落到复制分支
    }
    if (source is Directory) {
      await copyDirectory(source, Directory(destination));
      final srcBytes = await directoryBytes(source);
      final dstBytes = await directoryBytes(Directory(destination));
      if (srcBytes != dstBytes) {
        throw FileSystemException(
          '复制后大小不一致（$srcBytes != $dstBytes），已保留源目录',
          destination,
        );
      }
      await source.delete(recursive: true);
    } else if (source is File) {
      await File(destination).parent.create(recursive: true);
      await source.copy(destination);
      final srcLen = await source.length();
      final dstLen = await File(destination).length();
      if (srcLen != dstLen) {
        throw FileSystemException(
          '复制后大小不一致（$srcLen != $dstLen），已保留源文件',
          destination,
        );
      }
      await source.delete();
    }
  }

  Future<void> copyDirectory(Directory source, Directory destination) async {
    await destination.create(recursive: true);
    await for (final entity in source.list(followLinks: false)) {
      final target = p.join(destination.path, p.basename(entity.path));
      if (entity is Directory) {
        await copyDirectory(entity, Directory(target));
      } else if (entity is File) {
        await entity.copy(target);
      } else if (entity is Link) {
        try {
          await Link(target).create(await entity.target());
        } catch (_) {}
      }
    }
  }

  Future<int> directoryBytes(Directory dir) async {
    var bytes = 0;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        try {
          bytes += await entity.length();
        } catch (_) {}
      }
    }
    return bytes;
  }

  Future<void> deleteEntity(String path) async {
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.directory) {
      await Directory(path).delete(recursive: true);
    } else if (type == FileSystemEntityType.file) {
      await File(path).delete();
    }
  }
}

class StorageCheck {
  const StorageCheck({required this.ok, this.message, this.mode});
  final bool ok;
  final String? message;
  final String? mode;
}

class StorageUsage {
  const StorageUsage({required this.bytes, required this.files, this.freeBytes});
  final int bytes;
  final int files;
  final int? freeBytes;

  String get bytesLabel => formatBytes(bytes);
  String? get freeLabel => freeBytes == null ? null : formatBytes(freeBytes!);

  static String formatBytes(int value) {
    if (value < 1024) return '$value B';
    const units = ['KB', 'MB', 'GB', 'TB'];
    var size = value / 1024;
    var unit = 0;
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit++;
    }
    return '${size.toStringAsFixed(size >= 100 ? 0 : 1)} ${units[unit]}';
  }
}

class StorageMigrationResult {
  const StorageMigrationResult({
    required this.ok,
    this.path,
    this.movedEntries = const [],
    this.error,
    this.rolledBack = 0,
    this.rollbackErrors = const [],
  });

  factory StorageMigrationResult.success(String path, List<String> moved) =>
      StorageMigrationResult(ok: true, path: path, movedEntries: moved);

  factory StorageMigrationResult.failure(
    String error, {
    int rolledBack = 0,
    List<String> rollbackErrors = const [],
  }) =>
      StorageMigrationResult(
        ok: false,
        error: error,
        rolledBack: rolledBack,
        rollbackErrors: rollbackErrors,
      );

  final bool ok;
  final String? path;
  final List<String> movedEntries;
  final String? error;
  final int rolledBack;
  final List<String> rollbackErrors;
}
