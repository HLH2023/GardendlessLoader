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
  Future<({AppPaths paths, bool fromConfigured})>
      ensureInitializedWithSource() async {
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
      downloads: _downloadsDirectory(root),
    );
  }

  /// 下载目录：桌面端默认放到加载器自己的文件夹里（`<exe目录>/downloads`）。
  ///
  /// 为什么不跟着资源根走：资源根是用户可选的（很多人直接指向一个
  /// 「downloads」目录），再拼一层 `downloads` 会出现 `...\downloads\downloads`；
  /// 而且下载包（资源包 1 GB+、更新 zip）本来就属于安装目录，放在一起
  /// 用户能找到。安装目录不可写时（Program Files 未提权、只读介质）必须
  /// 退回资源根，否则下载和更新都会失败。
  Directory _downloadsDirectory(Directory root) {
    final fallback = Directory(p.join(root.path, 'downloads'));
    final desktop = _platformName == 'windows' ||
        _platformName == 'macos' ||
        _platformName == 'linux';
    if (!desktop) return fallback;
    try {
      final exeDir = File(Platform.resolvedExecutable).parent;
      final candidate = Directory(p.join(exeDir.path, 'downloads'));
      candidate.createSync(recursive: true);
      // 真正写一次才算数：Program Files 下 create 可能成功但写入被拒。
      final probe = File(p.join(candidate.path, '.gl-write-test'));
      probe.writeAsStringSync('x', flush: true);
      probe.deleteSync();
      return candidate;
    } catch (_) {
      return fallback;
    }
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
