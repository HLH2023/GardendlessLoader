import 'dart:io';

import 'package:path/path.dart' as p;

import '../models.dart';
import 'storage_root_service.dart';

const _androidMediaIgnoreFileName = '.nomedia';

class AppPathsService {
  AppPathsService({StorageRootService? storageRoot})
      : _storageRoot = storageRoot ?? StorageRootService();

  final String _platformName = Platform.operatingSystem;
  final StorageRootService _storageRoot;

  StorageRootService get storage => _storageRoot;

  /// 解析资源根目录：用户配置的位置优先，不可用时退回平台默认。
  Future<({AppPaths paths, bool fromConfigured})> ensureInitializedWithSource() async {
    final resolved = await _storageRoot.resolveRoot();
    final paths = _buildPaths(resolved.root);
    await _createPaths(paths);
    return (paths: paths, fromConfigured: resolved.fromConfigured);
  }

  Future<AppPaths> ensureInitialized() async {
    final resolved = await ensureInitializedWithSource();
    return resolved.paths;
  }

  /// 切换存储位置后重新定位（迁移完成的收尾动作）。
  Future<AppPaths> relocateTo(Directory root) async {
    final paths = _buildPaths(root);
    await _createPaths(paths);
    return paths;
  }

  AppPaths _buildPaths(Directory root) {
    return AppPaths(
      root: root,
      manifestFile: File(p.join(root.path, 'manifest.json')),
    );
  }

  Future<void> _createPaths(AppPaths paths) async {
    await paths.root.create(recursive: true);
    if (_platformName == 'android' || _platformName == 'ohos') {
      await File(p.join(paths.root.path, _androidMediaIgnoreFileName)).create();
    }
    await paths.slotADir.create(recursive: true);
    await paths.slotBDir.create(recursive: true);
    // gp-next stays absent until GP-Next creates it: its fresh-install check
    // treats an existing gp-next directory as a legacy installation.
  }

  /// 平台默认位置（供 UI 展示「恢复默认」）。
  Future<Directory> defaultRoot() => _storageRoot.defaultRoot();
}
