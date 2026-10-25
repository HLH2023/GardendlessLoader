import 'dart:io';

import 'package:path/path.dart' as p;

/// 资源根目录的定位器：指针优先，失效则退回默认位置。
///
/// 为什么需要「指针文件」：资源根目录里放着 manifest.json / settings.json，
/// 用户一旦改了位置，下次启动就找不到这些文件。所以指针必须存在
/// **资源根目录之外**的固定位置——先读指针，再定位资源根。
///
/// 这一层不依赖 Flutter：目录来源由外部注入（App 里注入 path_provider 的结果，
/// 验收脚本注入临时目录），因此指针逻辑可以被完整测试。
class StorageRootLocator {
  StorageRootLocator({
    required Future<Directory> Function() supportDirectory,
    required Future<Directory> Function() defaultRoot,
  })  : _supportDirectory = supportDirectory,
        _defaultRoot = defaultRoot;

  static const pointerFileName = 'storage_root_pointer.txt';
  static const _pointerDirName = 'GardendlessLoader';

  final Future<Directory> Function() _supportDirectory;
  final Future<Directory> Function() _defaultRoot;

  Future<File> pointerFile() async {
    final dir = await _supportDirectory();
    return File(p.join(dir.path, _pointerDirName, pointerFileName));
  }

  /// 读取用户配置的位置；未配置或内容为空返回 null。
  Future<Directory?> readConfiguredRoot() async {
    try {
      final file = await pointerFile();
      if (!await file.exists()) return null;
      final text = (await file.readAsString()).trim();
      if (text.isEmpty) return null;
      return Directory(text);
    } catch (_) {
      return null;
    }
  }

  /// 解析实际使用的资源根。
  ///
  /// 指针指向的目录或它的父目录存在 → 认为有效（目录本身会被重建）；
  /// 否则退回默认位置，避免一个坏指针让应用完全起不来。
  Future<({Directory root, bool fromConfigured})> resolveRoot() async {
    final configured = await readConfiguredRoot();
    if (configured != null) {
      try {
        if (await configured.exists()) {
          return (root: configured, fromConfigured: true);
        }
        final parent = Directory(p.dirname(configured.path));
        if (await parent.exists()) {
          return (root: configured, fromConfigured: true);
        }
      } catch (_) {}
      return (root: await _defaultRoot(), fromConfigured: false);
    }
    return (root: await _defaultRoot(), fromConfigured: false);
  }

  Future<void> writePointer(String path) async {
    final file = await pointerFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(path, flush: true);
  }

  Future<void> clearPointer() async {
    final file = await pointerFile();
    if (await file.exists()) await file.delete();
  }

  Future<Directory> defaultRoot() => _defaultRoot();
}
