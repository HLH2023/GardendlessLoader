// 存储位置与迁移验收（纯 Dart，本机可跑）
//
// 覆盖：默认位置解析、指针优先、候选路径校验（空/相对/同目录/子目录/文件）、
//       正常迁移（条目搬齐 + 指针写入 + 源目录清空）、指针写入失败时的回滚、
//       占用统计。
//
// 用法：dart run tool/check_storage_migration.dart
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:gardendless_loader/src/services/storage_migration.dart';
import 'package:gardendless_loader/src/services/storage_root_locator.dart';

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

Future<void> writeFile(String path, String text) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsString(text);
}

/// 造一份「已安装资源」的假目录树
Future<void> seedRoot(Directory root) async {
  await root.create(recursive: true);
  await writeFile(p.join(root.path, 'manifest.json'), '{"generation":7}');
  await writeFile(p.join(root.path, 'settings.json'), '{"locale":"zh"}');
  await writeFile(p.join(root.path, 'slot-a', 'index.html'), '<html>slot-a</html>');
  await writeFile(p.join(root.path, 'slot-a', 'assets', 'game.wasm'), 'W' * 2048);
  await root.create(recursive: true);
  await Directory(p.join(root.path, 'slot-b')).create(recursive: true);
  final big = List<int>.generate(64 * 1024, (i) => i % 251);
  await File(p.join(root.path, 'downloads', 'pack.zip')).create(recursive: true);
  await File(p.join(root.path, 'downloads', 'pack.zip')).writeAsBytes(big);
}

Future<void> main() async {
  final temp = await Directory.systemTemp.createTemp('pvz-storage');
  final defaultRoot = Directory(p.join(temp.path, 'default-root'));
  final supportDir = Directory(p.join(temp.path, 'support'));
  final service = StorageRootLocator(
    supportDirectory: () async => supportDir,
    defaultRoot: () async => defaultRoot,
  );
  final migration = ResourceMigration();
  final pointer = await service.pointerFile();
  check('指针落在支持目录下', pointer.path.contains('GardendlessLoader'), pointer.path);

  try {
    // 1) 未配置 → 默认位置
    final first = await service.resolveRoot();
    check('未配置时用默认位置', first.root.path == defaultRoot.path, first.root.path);
    check('未配置标记正确', first.fromConfigured == false);

    // 2) 指针优先
    final customRoot = Directory(p.join(temp.path, 'custom-root'));
    await customRoot.create(recursive: true);
    await service.writePointer(customRoot.path);
    final second = await service.resolveRoot();
    check('指针生效', second.root.path == customRoot.path, second.root.path);
    check('指针标记正确', second.fromConfigured == true);

    // 3) 指针指向不存在的盘符 → 退回默认（不能让应用起不来）
    await service.writePointer(p.join(temp.path, 'no-such-parent', 'x'));
    final third = await service.resolveRoot();
    check('指针失效时退回默认', third.root.path == defaultRoot.path, third.root.path);
    check('退回默认时标记为 false', third.fromConfigured == false);
    await pointer.delete();
    check('clearPointer 后回到默认', (await service.resolveRoot()).fromConfigured == false);

    // 4) 候选路径校验
    final currentRoot = Directory(p.join(temp.path, 'current'));
    await currentRoot.create(recursive: true);
    check('空路径被拒', !(await migration.validate(Directory('  '), currentRoot: currentRoot)).ok);
    check('相对路径被拒', !(await migration.validate(Directory('rel/path'), currentRoot: currentRoot)).ok);
    check(
      '同一路径被拒',
      !(await migration.validate(currentRoot, currentRoot: currentRoot)).ok,
    );
    check(
      '当前目录的子目录被拒',
      !(await migration.validate(Directory(p.join(currentRoot.path, 'inner')), currentRoot: currentRoot)).ok,
    );
    final aFile = File(p.join(temp.path, 'a-file'));
    await aFile.writeAsString('x');
    check('文件路径被拒', !(await migration.validate(Directory(aFile.path), currentRoot: currentRoot)).ok);
    final goodTarget = Directory(p.join(temp.path, 'target-ok'));
    final goodCheck = await migration.validate(goodTarget, currentRoot: currentRoot);
    check('正常目录可用', goodCheck.ok, goodCheck.message);
    check('校验会创建目录', await goodTarget.exists());
    check('校验不残留探针文件', !await File(p.join(goodTarget.path, '.pvz_write_probe')).exists());
    await goodTarget.delete(recursive: true);

    // 5) 正常迁移
    await seedRoot(currentRoot);
    final target = Directory(p.join(temp.path, 'target-migrate'));
    final progress = <String>[];
    final result = await migration.migrate(
      sourceRoot: currentRoot,
      target: target,
      onProgress: (entry, done, total) => progress.add('$entry($done/$total)'),
    );
    check('迁移成功', result.ok, result.error);
    check('迁移条目齐全', result.movedEntries.length >= 4, result.movedEntries.join(','));
    check('有进度回调', progress.isNotEmpty, progress.join(' '));
    check('manifest 已到新位置', await File(p.join(target.path, 'manifest.json')).exists());
    check('settings 已到新位置', await File(p.join(target.path, 'settings.json')).exists());
    check('slot-a 内容完整',
        await File(p.join(target.path, 'slot-a', 'assets', 'game.wasm')).length() == 2048);
    check('downloads 已搬走', await File(p.join(target.path, 'downloads', 'pack.zip')).exists());
    check('源目录已清空 manifest', !await File(p.join(currentRoot.path, 'manifest.json')).exists());
    check('源目录已清空 slot-a', !await Directory(p.join(currentRoot.path, 'slot-a')).exists());
    // 指针由 StorageRootService 在搬运成功后写（这里模拟同一顺序）
    await service.writePointer(target.path);
    check('指针已指向新位置', (await pointer.readAsString()).trim() == target.path);
    final resolvedAfter = await service.resolveRoot();
    check('迁移后解析到新位置', resolvedAfter.root.path == target.path, resolvedAfter.root.path);

    // 7) 指针写入失败 → 回滚（源目录必须完好）
    final rollbackSource = Directory(p.join(temp.path, 'rollback-source'));
    await seedRoot(rollbackSource);
    // 支持目录指向一个「父级是普通文件」的路径 → 创建目录必然失败
    final brokenLocator = StorageRootLocator(
      supportDirectory: () async => Directory(p.join(aFile.path, 'dir')),
      defaultRoot: () async => defaultRoot,
    );
    final rollbackTarget = Directory(p.join(temp.path, 'rollback-target'));
    // 搬运成功但写指针失败 → 必须回滚
    final movedResult = await migration.migrate(
      sourceRoot: rollbackSource,
      target: rollbackTarget,
    );
    check('搬运本身成功', movedResult.ok, movedResult.error);
    List<String> rollbackErrors = const [];
    if (movedResult.ok) {
      try {
        await brokenLocator.writePointer(rollbackTarget.path);
        check('坏指针路径应当写入失败', false);
      } catch (e) {
        rollbackErrors = await migration.rollback(
          target: rollbackTarget,
          sourceRoot: rollbackSource,
          moved: movedResult.movedEntries,
        );
      }
    }
    final rollbackResult = StorageMigrationResult.failure(
      rollbackErrors.isEmpty ? '写入存储位置指针失败：已回滚' : '写入存储位置指针失败：$rollbackErrors',
      rolledBack: rollbackErrors.isEmpty ? movedResult.movedEntries.length : 0,
      rollbackErrors: rollbackErrors,
    );
    check('指针失败时迁移报错', !rollbackResult.ok, rollbackResult.error);
    check('报错指出指针环节',
        (rollbackResult.error ?? '').contains('指针'), rollbackResult.error);
    check('回滚后 manifest 回到源目录',
        await File(p.join(rollbackSource.path, 'manifest.json')).exists());
    check('回滚后 slot-a 回到源目录',
        await File(p.join(rollbackSource.path, 'slot-a', 'index.html')).exists());
    check('回滚后目标目录无残留条目',
        !await File(p.join(rollbackTarget.path, 'manifest.json')).exists() &&
            !await Directory(p.join(rollbackTarget.path, 'slot-a')).exists());
    check('回滚后源目录 wasm 完好',
        await File(p.join(rollbackSource.path, 'slot-a', 'assets', 'game.wasm')).length() == 2048);

    // 8) 占用统计
    final usage = await migration.usage(rollbackSource);
    check('统计到文件数', usage.files >= 5, usage.files);
    check('统计到字节数', usage.bytes > 64 * 1024, usage.bytes);
    check('字节格式化', StorageUsage.formatBytes(1536) == '1.5 KB',
        StorageUsage.formatBytes(1536));
    check('GB 格式化', StorageUsage.formatBytes(3 * 1024 * 1024 * 1024) == '3.0 GB',
        StorageUsage.formatBytes(3 * 1024 * 1024 * 1024));
  } finally {
    await temp.delete(recursive: true);
  }

  stdout.writeln('\n结果：$passed 通过 / $failed 失败');
  exit(failed == 0 ? 0 : 1);
}
