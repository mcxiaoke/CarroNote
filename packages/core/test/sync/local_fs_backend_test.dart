/*
 * LocalFsBackend 单元测试
 *
 * 验证点：
 *   - init 创建目录结构
 *   - getManifest 首次返回空
 *   - putManifest 首次上传成功
 *   - getManifest 读取上传的内容
 *   - putManifest 乐观锁冲突检测
 *   - putBlob / getBlob 幂等性
 *   - getBlob 不存在返回 null
 *   - ETag 一致性（同内容同 etag）
 *   - 隔离区：deleteBlobSoft → blobs-orphan、purgeOrphans 超期才删（I9 依赖的链路）
 *
 * 运行：flutter test test/sync/local_fs_backend_test.dart
 */

// Dart 原生导入
import 'dart:io';
import 'dart:typed_data';

// Package 导入
import 'package:test/test.dart';
import 'package:path/path.dart' as p;

// Project 导入
import 'package:core/core.dart';

void main() {
  late Directory tempDir;
  late LocalFsBackend backend;

  setUp(() async {
    // 每个测试用例创建独立临时目录，避免相互干扰
    tempDir = await Directory.systemTemp.createTemp('safenotes_backend_test_');
    backend = LocalFsBackend(rootPath: tempDir.path);
    await backend.init();
  });

  tearDown(() async {
    await backend.close();
    // 测试完成后清理临时目录
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('LocalFsBackend - 初始化', () {
    test('init 创建 keyring 根目录和 blobs 子目录', () async {
      // 重新创建一个 backend 验证 init 行为
      final freshDir = await Directory.systemTemp.createTemp(
        'safenotes_fresh_',
      );
      final freshBackend = LocalFsBackend(rootPath: freshDir.path);

      // 初始状态：目录不存在
      expect(await Directory(freshDir.path).exists(), isTrue); // createTemp 已创建
      expect(await Directory(p.join(freshDir.path, 'blobs')).exists(), isFalse);

      await freshBackend.init();

      // init 后：blobs 子目录应存在
      expect(await Directory(p.join(freshDir.path, 'blobs')).exists(), isTrue);
      // manifest.json 文件还不应存在
      expect(
        await File(p.join(freshDir.path, 'manifest.json')).exists(),
        isFalse,
      );

      await freshBackend.close();
      await freshDir.delete(recursive: true);
    });

    test('init 幂等：重复调用不报错', () async {
      // 已在 setUp 中 init 一次，再调一次应正常
      await backend.init();
      await backend.init();
    });

    test('未初始化时调用方法抛 BackendNotInitializedException', () async {
      final freshBackend = LocalFsBackend(rootPath: tempDir.path);
      // 不调用 init()，直接使用
      expect(
        () => freshBackend.getManifest(),
        throwsA(isA<BackendNotInitializedException>()),
      );
      expect(
        () => freshBackend.getBlob('anyhash'),
        throwsA(isA<BackendNotInitializedException>()),
      );
    });
  });

  group('LocalFsBackend - manifest 操作', () {
    test('首次 getManifest 返回空密文和空 etag', () async {
      final result = await backend.getManifest();
      expect(result.ciphertext.length, 0);
      expect(result.etag, '');
    });

    test('putManifest 首次上传成功（expectedEtag 为空）', () async {
      final data = Uint8List.fromList([1, 2, 3, 4, 5]);
      final newEtag = await backend.putManifest(data, '');
      expect(newEtag, isNotEmpty);
      expect(newEtag, isNot(''));
    });

    test('putManifest 首次上传后内容可读回', () async {
      final data = Uint8List.fromList([10, 20, 30, 40, 50]);
      final newEtag = await backend.putManifest(data, '');

      final result = await backend.getManifest();
      expect(result.ciphertext, data);
      expect(result.etag, newEtag);
    });

    test('putManifest 带正确 etag 可覆盖写入', () async {
      // 首次上传
      final data1 = Uint8List.fromList([1, 1, 1]);
      final etag1 = await backend.putManifest(data1, '');

      // 第二次上传，带正确的 etag1
      final data2 = Uint8List.fromList([2, 2, 2]);
      final etag2 = await backend.putManifest(data2, etag1);

      expect(etag2, isNot(etag1)); // 新内容应有新 etag

      // 读取验证
      final result = await backend.getManifest();
      expect(result.ciphertext, data2);
      expect(result.etag, etag2);
    });

    test('putManifest 带错误 etag 抛 ConflictException', () async {
      // 首次上传
      await backend.putManifest(Uint8List.fromList([1]), '');

      // 用错误的 etag 再上传
      expect(
        () => backend.putManifest(
          Uint8List.fromList([2]),
          'fake-wrong-etag-12345',
        ),
        throwsA(isA<ConflictException>()),
      );
    });

    test('putManifest 首次上传但远端已存在时抛 ConflictException', () async {
      // 先正常上传一次
      await backend.putManifest(Uint8List.fromList([1]), '');

      // 再用空 etag 尝试"首次上传"，应失败
      expect(
        () => backend.putManifest(Uint8List.fromList([2]), ''),
        throwsA(isA<ConflictException>()),
      );
    });

    test('ETag 一致性：相同内容产生相同 etag', () async {
      final data = Uint8List.fromList([100, 101, 102]);

      // 上传内容
      final etag1 = await backend.putManifest(data, '');

      // 读取后 etag 应一致
      final getResult = await backend.getManifest();
      expect(getResult.etag, etag1);

      // 重新上传相同内容，新 etag 应与之前相同
      // 注意：需要先 getManifest 拿到当前 etag，才能用 If-Match 覆盖
      final etag2 = await backend.putManifest(data, getResult.etag);
      expect(etag2, etag1);
    });
  });

  group('LocalFsBackend - blob 操作', () {
    test('getBlob 不存在时返回 null', () async {
      final result = await backend.getBlob('nonexistent-hash-12345');
      expect(result, isNull);
    });

    test('putBlob + getBlob 往返', () async {
      final hash = 'abc123def456';
      final data = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);

      await backend.putBlob(hash, data);

      final result = await backend.getBlob(hash);
      expect(result, isNotNull);
      expect(result!, data);
    });

    test('putBlob 幂等：相同 hash 多次上传结果一致', () async {
      final hash = 'idempotent-hash';
      final data1 = Uint8List.fromList([10, 20, 30]);
      final data2 = Uint8List.fromList([10, 20, 30]); // 相同内容

      await backend.putBlob(hash, data1);
      await backend.putBlob(hash, data2); // 再次上传相同内容

      final result = await backend.getBlob(hash);
      expect(result, data1);
    });

    test('putBlob 覆盖写：相同 hash 不同内容以后写为准', () async {
      final hash = 'overwrite-hash';
      final data1 = Uint8List.fromList([1, 2, 3]);
      final data2 = Uint8List.fromList([4, 5, 6]);

      await backend.putBlob(hash, data1);
      await backend.putBlob(hash, data2); // 覆盖

      final result = await backend.getBlob(hash);
      expect(result, data2);
    });

    test('多个 blob 并存：不同 hash 互不干扰', () async {
      final hash1 = 'hash-aaa';
      final hash2 = 'hash-bbb';
      final hash3 = 'hash-ccc';

      final data1 = Uint8List.fromList([1]);
      final data2 = Uint8List.fromList([2]);
      final data3 = Uint8List.fromList([3]);

      await backend.putBlob(hash1, data1);
      await backend.putBlob(hash2, data2);
      await backend.putBlob(hash3, data3);

      expect(await backend.getBlob(hash1), data1);
      expect(await backend.getBlob(hash2), data2);
      expect(await backend.getBlob(hash3), data3);
    });
  });

  group('LocalFsBackend - 隔离区（blobs-orphan）', () {
    // 隔离区语义是 P1-2 数据安全的核心承诺：
    //   孤儿 blob 软删除进 blobs-orphan（文件名 `hash.<epochMs>`），
    //   保留期（默认 30 天）内可恢复，超期才由 purgeOrphans 彻底删除。
    // 这里锁定「隔离 → 列出 → 超期 purge → 未超期保留」的完整行为，
    // 防止未来改动破坏 purge 路径（longrun I9 依赖同一链路，但此处定向更快）。
    test('deleteBlobSoft 把 blob 移入隔离区，listOrphanBlobs 列出', () async {
      final hash = 'soft-delete-hash';
      await backend.putBlob(hash, Uint8List.fromList([1, 2, 3]));

      await backend.deleteBlobSoft(hash);

      // 原位置应已移走（blobs/ 不再有，隔离区有）
      expect(await backend.getBlob(hash), isNull);
      expect(await backend.listOrphanBlobs(), [hash]);
      // 磁盘文件名应为 hash.<epochMs>（purge 依赖该时间戳）
      final orphanDir = Directory(p.join(tempDir.path, 'blobs-orphan'));
      final names = orphanDir
          .listSync()
          .whereType<File>()
          .map((f) => f.path)
          .toList();
      expect(names.length, 1);
      final base = p.basename(names.first);
      expect(base, startsWith('$hash.'));
    });

    test('deleteBlobSoft 幂等：hash 不存在时不报错', () async {
      await backend.deleteBlobSoft('no-such-hash');
      expect(await backend.listOrphanBlobs(), isEmpty);
    });

    test('purgeOrphans 保留期内不删（今天隔离的 30 天保留期仍在期内）', () async {
      final hash = 'young-hash';
      await backend.putBlob(hash, Uint8List.fromList([9]));
      await backend.deleteBlobSoft(hash);

      await backend.purgeOrphans(const Duration(days: 30));

      // 刚隔离（时间戳为现在）未超过 30 天 → 保留
      expect(await backend.listOrphanBlobs(), [hash]);
    });

    test('purgeOrphans 超期隔离项被删除（零保留期即隔离即清）', () async {
      final hash = 'expired-hash';
      await backend.putBlob(hash, Uint8List.fromList([7]));
      await backend.deleteBlobSoft(hash);

      // 零保留期：cutoff = now，隔离时间戳 < now → 立即清空
      await backend.purgeOrphans(Duration.zero);

      expect(await backend.listOrphanBlobs(), isEmpty);
      final orphanDir = Directory(p.join(tempDir.path, 'blobs-orphan'));
      expect(orphanDir.listSync().whereType<File>(), isEmpty);
    });

    test('purgeOrphans 混合：只删超期的，保留期内留下', () async {
      // 手工构造两个隔离文件：一个 40 天前（超期），一个现在（期内）
      final orphanDir = Directory(p.join(tempDir.path, 'blobs-orphan'));
      await orphanDir.create(recursive: true);
      final now = DateTime.now().millisecondsSinceEpoch;
      final oldTs = now - 40 * 24 * 60 * 60 * 1000;
      await File(p.join(orphanDir.path, 'old-hash.$oldTs')).writeAsString('x');
      await File(p.join(orphanDir.path, 'fresh-hash.$now')).writeAsString('y');

      await backend.purgeOrphans(const Duration(days: 30));

      expect(await backend.listOrphanBlobs(), ['fresh-hash']);
    });
  });

  group('LocalFsBackend - 模拟同步流程', () {
    test('完整同步流程模拟：init → 首次上传 → 读取 → 更新 → 冲突重试', () async {
      // Step 1: 首次 getManifest（远端为空）
      var remote = await backend.getManifest();
      expect(remote.ciphertext.length, 0);
      expect(remote.etag, '');

      // Step 2: 首次上传 manifest
      final manifestV1 = Uint8List.fromList([1, 2, 3, 4, 5]);
      var etag = await backend.putManifest(manifestV1, remote.etag);
      expect(etag, isNotEmpty);

      // Step 3: 上传一些 blob
      final blobHash1 = 'blob-hash-1';
      final blobData1 = Uint8List.fromList([10, 20, 30]);
      await backend.putBlob(blobHash1, blobData1);

      final blobHash2 = 'blob-hash-2';
      final blobData2 = Uint8List.fromList([40, 50, 60]);
      await backend.putBlob(blobHash2, blobData2);

      // Step 4: 模拟其他设备修改了 manifest（用错误 etag 应失败）
      expect(
        () => backend.putManifest(Uint8List.fromList([9, 9, 9]), 'stale-etag'),
        throwsA(isA<ConflictException>()),
      );

      // Step 5: 重新 getManifest 拿到最新 etag
      remote = await backend.getManifest();
      expect(remote.ciphertext, manifestV1);
      expect(remote.etag, etag);

      // Step 6: 用最新 etag 上传新版本
      final manifestV2 = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7]);
      final newEtag = await backend.putManifest(manifestV2, remote.etag);
      expect(newEtag, isNot(etag));

      // Step 7: 读取 blob 验证未受影响
      expect(await backend.getBlob(blobHash1), blobData1);
      expect(await backend.getBlob(blobHash2), blobData2);
    });
  });
}
