import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../constants.dart';
import 'storage_migration.dart';
import 'storage_root_locator.dart';

export 'storage_migration.dart';
export 'storage_root_locator.dart';

/// 存储位置的 Flutter 适配层：只负责「平台默认目录」与「支持目录」从哪来，
/// 真正的定位/搬家/校验逻辑在 [StorageRootLocator] 与 [ResourceMigration]。
class StorageRootService {
  StorageRootService({StorageRootLocator? locator, ResourceMigration? migration})
      : migration = migration ?? ResourceMigration(),
        locator = locator ??
            StorageRootLocator(
              supportDirectory: getApplicationSupportDirectory,
              defaultRoot: _platformDefaultRoot,
            );

  final StorageRootLocator locator;
  final ResourceMigration migration;

  /// 平台默认资源根目录。
  static Future<Directory> _platformDefaultRoot() async {
    final platform = Platform.operatingSystem;
    if (platform == 'windows' || platform == 'linux' || platform == 'macos') {
      // 桌面端放在应用支持目录：不污染用户文档目录
      final support = await getApplicationSupportDirectory();
      return Directory(p.join(support.path, resourceFolderName));
    }
    if (platform == 'ios' || platform == 'ohos') {
      final documents = await getApplicationDocumentsDirectory();
      return Directory(p.join(documents.path, resourceFolderName));
    }
    if (platform == 'android') {
      final external = await getExternalStorageDirectory();
      if (external != null) {
        return Directory(p.join(external.path, resourceFolderName));
      }
      final documents = await getApplicationDocumentsDirectory();
      return Directory(p.join(documents.path, resourceFolderName));
    }
    throw UnsupportedError('当前平台不受支持：$platform');
  }

  Future<Directory> defaultRoot() => locator.defaultRoot();

  Future<Directory?> readConfiguredRoot() => locator.readConfiguredRoot();

  Future<({Directory root, bool fromConfigured})> resolveRoot() => locator.resolveRoot();

  Future<void> writePointer(String path) => locator.writePointer(path);

  Future<void> clearPointer() => locator.clearPointer();

  Future<StorageCheck> validate(Directory candidate, {Directory? currentRoot}) =>
      migration.validate(candidate, currentRoot: currentRoot);

  Future<StorageUsage> usage(Directory root) => migration.usage(root);

  /// 迁移资源根，并在成功后写入指针。
  ///
  /// 写指针失败 → 调用方拿到 `ok=false`，此时条目已搬回源目录，
  /// 应用下次启动仍从老位置正常工作。
  Future<StorageMigrationResult> migrate({
    required Directory sourceRoot,
    required Directory target,
    void Function(String entry, int done, int total)? onProgress,
  }) async {
    final result = await migration.migrate(
      sourceRoot: sourceRoot,
      target: target,
      onProgress: onProgress,
    );
    if (!result.ok) return result;
    try {
      await writePointer(target.path);
    } catch (e) {
      final errors = await migration.rollback(
        target: target,
        sourceRoot: sourceRoot,
        moved: result.movedEntries,
      );
      return StorageMigrationResult.failure(
        '写入存储位置指针失败：$e',
        rolledBack: result.movedEntries.length - errors.length,
        rollbackErrors: errors,
      );
    }
    return result;
  }
}
