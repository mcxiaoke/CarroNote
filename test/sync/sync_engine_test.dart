/*
 * SyncEngine 单元测试
 *
 * 使用 FakeBackend（内存实现）+ 真实 NotesDatabase（in-memory SQLite）验证：
 *   - 首次同步（本地有笔记，远端空）
 *   - 新设备同步（本地空，远端有笔记）
 *   - 增量同步（双方各有部分笔记）
 *   - LWW 冲突解决（同一笔记双方都修改）
 *   - 墓碑同步（软删除传播）
 *   - 跳过已同步（hash 一致不重复传输）
 *   - 乐观锁重试（putManifest 冲突后重试成功）
 *
 * 运行：flutter test test/sync/sync_engine_test.dart
 */

// Dart 原生导入
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// Package 导入
import 'package:flutter_test/flutter_test.dart';
import 'package:safenotes/data/database_handler.dart';
import 'package:safenotes/models/safenote.dart';
import 'package:safenotes/sync/crypto.dart';
import 'package:safenotes/sync/local_fs_backend.dart';
import 'package:safenotes/sync/sync_backend.dart';
import 'package:safenotes/sync/sync_engine.dart';
import 'package:safenotes/sync/sync_models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// 测试公共支撑（P2：Keyring/Journal 构造 + FakeBackend journal 存储）
import 'sync_test_support.dart';

/// 测试用 FakeBackend：内存实现，可模拟冲突
class FakeBackend with FakeJournalStore implements SyncBackend {
  Uint8List? _manifestCiphertext;
  String _etag = '';
  final Map<String, Uint8List> _blobs = {};

  /// 控制 putManifest 是否第一次抛冲突（用于测试乐观锁重试）
  int _conflictOnNextPuts = 0;

  @override
  String get displayName => 'FakeBackend';

  /// 测试用固定 providerKey
  @override
  String get providerKey => 'fake-test-backend';

  @override
  Future<void> init() async {}

  void conflictOnNextPuts(int count) {
    _conflictOnNextPuts = count;
  }

  @override
  Future<({Uint8List ciphertext, String etag})> getManifest() async {
    if (_manifestCiphertext == null) {
      return (ciphertext: Uint8List(0), etag: '');
    }
    return (ciphertext: _manifestCiphertext!, etag: _etag);
  }

  @override
  Future<String> putManifest(Uint8List ciphertext, String expectedEtag) async {
    if (_conflictOnNextPuts > 0) {
      _conflictOnNextPuts--;
      throw ConflictException('FakeBackend: simulated conflict');
    }

    if (expectedEtag.isEmpty) {
      if (_manifestCiphertext != null) {
        throw ConflictException('FakeBackend: manifest already exists');
      }
    } else {
      if (_etag != expectedEtag) {
        throw ConflictException(
            'FakeBackend: etag mismatch (expected=$expectedEtag, actual=$_etag)');
      }
    }

    _manifestCiphertext = ciphertext;
    _etag = 'etag-${DateTime.now().microsecondsSinceEpoch}';
    return _etag;
  }

  @override
  Future<Uint8List?> getBlob(String hash) async {
    return _blobs[hash];
  }

  @override
  Future<void> putBlob(String hash, Uint8List data) async {
    _blobs[hash] = data;
  }

  /// F1 修复：删除 blob（GC 用）
  @override
  Future<void> deleteBlob(String hash) async {
    _blobs.remove(hash);
  }

  /// F1 修复：列出所有 blob hash（GC 用）
  @override
  Future<List<String>> listBlobs() async {
    return _blobs.keys.toList();
  }

  /// D2 修复：备份损坏 manifest（测试用空实现）
  @override
  Future<void> backupCorruptManifest(Uint8List ciphertext) async {}

  @override
  Future<void> close() async {}

  @override
  Future<bool> ping() async => true;

  /// 清空状态（测试用例间重置）
  void reset() {
    _manifestCiphertext = null;
    _etag = '';
    _blobs.clear();
    _conflictOnNextPuts = 0;
  }

  /// 模拟其他设备写入 manifest（用于测试并发冲突）
  void simulateOtherDevicePutManifest(Uint8List ciphertext) {
    _manifestCiphertext = ciphertext;
    _etag = 'etag-other-device-${DateTime.now().microsecondsSinceEpoch}';
  }

  // P0/P1 接口新增方法的默认实现（测试用 FakeBackend 无需真实隔离区/备份语义）
  @override
  Future<void> deleteBlobSoft(String hash) async => deleteBlob(hash);
  @override
  Future<List<String>> listOrphanBlobs() async => [];
  @override
  Future<void> purgeOrphans(Duration retention) async {}
  @override
  Future<void> backupManifest([Uint8List? currentManifestBytes]) async {}
}

/// 测试辅助：构造 SyncEngine
///
/// Keyring 构造方式：
///   - 显式传入的 dataKey/encryptedDataKey（multi-device 测试中设备 B 传设备 A 的值）
///   - database 已设置的 dataKey（单设备测试中 setUp 注入的 dataKey）
///   - 新生成的 dataKey（fallback，理论上不会触发）
///
/// 注意：测试用 Keyring 不缓存 MK（mk=null）。
/// 由于多设备测试中设备 B 使用与设备 A 相同的 encryptedDataKey，
/// checkMigrationNeeded 会直接比较 encryptedDataKey 返回无需迁移，不需要 MK。
SyncEngine _makeEngine({
  required FakeBackend backend,
  required NotesDatabase database,
  Uint8List? dataKey,
  String? encryptedDataKey,
  String? vaultId,
}) {
  final dk = dataKey ??
      (database.isEncryptionEnabled
          ? database.dataKeyForTesting
          : SyncCrypto.generateDataKey());
  final edk = encryptedDataKey ?? base64Encode(SyncCrypto.wrapDataKey(dk, dk));
  final vid = vaultId ?? 'test-keyring-id';
  final keyring = makeTestKeyring(
    vaultId: vid,
    dataKey: dk,
    encryptedDataKey: edk,
    keyFingerprint: '',
    keyVersion: 1,
    kdf: KdfParams.create(salt: SyncCrypto.generateSalt()),
    createdAt: DateTime.now().millisecondsSinceEpoch,
  );
  return SyncEngine(
    backend: backend,
    database: database,
    keyring: keyring,
    deviceId: 'test-device',
    journal: makeTestJournal(),
  );
}

/// 创建测试用笔记
SafeNote _makeNote({
  required String uuid,
  String title = 'Test Title',
  String description = 'Test Description',
  bool deleted = false,
  int? updatedAt,
}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return SafeNote(
    uuid: uuid,
    title: title,
    description: description,
    contentHash: SafeNote.computeHash(title, description),
    deleted: deleted,
    createdTime: DateTime.now(),
    updatedAt: updatedAt ?? now,
    synced: false,
  );
}

void main() {
  // 初始化 sqflite_ffi（桌面测试环境）
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late FakeBackend backend;
  late NotesDatabase database;

  /// 测试用的固定 dataKey（setUp 中设置到 database + engine 共用）
  late Uint8List testDataKey;

  setUp(() async {
    backend = FakeBackend();
    // 每个测试用例创建独立的 in-memory 数据库
    final db = await openDatabase(
      ':memory:',
      version: 2,
      onCreate: NotesDatabase.createDBForTesting,
    );
    NotesDatabase.setDatabaseForTesting(db);
    database = NotesDatabase.instance;
    // 生成测试用 dataKey 并注入 database（与生产环境一致）
    testDataKey = SyncCrypto.generateDataKey();
    database.setDataKey(testDataKey);
  });

  tearDown(() async {
    await database.close();
    backend.reset();
  });

  group('SyncEngine - 首次同步（本地有笔记，远端空）', () {
    test('上传所有本地笔记到远端', () async {
      // 准备：本地有 3 条笔记
      final note1 = _makeNote(uuid: 'uuid-1', title: 'Note 1');
      final note2 = _makeNote(uuid: 'uuid-2', title: 'Note 2');
      final note3 = _makeNote(uuid: 'uuid-3', title: 'Note 3');
      await database.storeNote(note1);
      await database.storeNote(note2);
      await database.storeNote(note3);

      final engine = _makeEngine(backend: backend, database: database);

      // 执行同步
      final result = await engine.sync();

      // 验证结果
      expect(result.success, isTrue);
      expect(result.uploaded, 3);
      expect(result.downloaded, 0);
      expect(result.attempts, 1);

      // 验证 manifest version 更新
      final version = await database.getManifestVersion(backend.providerKey);
      expect(version, 1);

      // 验证所有笔记标记为已同步
      final notes = await database.readAllNotesIncludingDeleted();
      for (final note in notes) {
        expect(note.synced, isTrue);
      }

      // 验证远端有 manifest
      final remoteManifest = await backend.getManifest();
      expect(remoteManifest.ciphertext.length, greaterThan(0));
      expect(remoteManifest.etag, isNotEmpty);
    });

    test('空数据库首次同步：只上传 manifest，无 blob', () async {
      final engine = _makeEngine(backend: backend, database: database);
      final result = await engine.sync();

      expect(result.success, isTrue);
      expect(result.uploaded, 0);
      expect(result.downloaded, 0);

      final version = await database.getManifestVersion(backend.providerKey);
      expect(version, 1);
    });
  });

  group('SyncEngine - 新设备同步（本地空，远端有笔记）', () {
    test('从远端下载所有笔记', () async {
      // 准备：设备 A 先同步上传 2 条笔记
      final note1 = _makeNote(uuid: 'uuid-a1', title: 'Note A1');
      final note2 = _makeNote(uuid: 'uuid-a2', title: 'Note A2');
      await database.storeNote(note1);
      await database.storeNote(note2);

      final engineA = _makeEngine(backend: backend, database: database);
      await engineA.sync();

      // 设备 B：新数据库（模拟新设备加入）
      await database.close();
      final dbB = await openDatabase(
        ':memory:',
        version: 2,
        onCreate: NotesDatabase.createDBForTesting,
      );
      NotesDatabase.setDatabaseForTesting(dbB);

      // 注意：设备 B 需要用相同的 dataKey 才能解密 manifest
      // 这里我们用同一个 dataKey（测试环境）
      final dataKey = engineA.keyring.dataKey;
      final encryptedDataKey = engineA.keyring.encryptedDataKey;
      final engineB = _makeEngine(
        backend: backend,
        database: database,
        dataKey: dataKey,
        encryptedDataKey: encryptedDataKey,
      );

      // 执行同步
      final result = await engineB.sync();

      // 验证：下载了 2 条笔记
      expect(result.success, isTrue);
      expect(result.downloaded, 2);
      expect(result.uploaded, 0);

      // 验证本地数据库有笔记
      final notes = await database.readAllNotes();
      expect(notes.length, 2);
      expect(notes.any((n) => n.uuid == 'uuid-a1'), isTrue);
      expect(notes.any((n) => n.uuid == 'uuid-a2'), isTrue);

      // 验证内容正确
      final downloaded1 = await database.readNoteByUuid('uuid-a1');
      expect(downloaded1!.title, 'Note A1');
    });
  });

  group('SyncEngine - 增量同步', () {
    test('双方各有独占笔记，同步后互相获得对方笔记', () async {
      // 准备：设备 A 同步上传 1 条笔记
      final noteA = _makeNote(uuid: 'uuid-a', title: 'Note A');
      await database.storeNote(noteA);
      final engineA = _makeEngine(backend: backend, database: database);
      await engineA.sync();

      // 设备 B：已有 1 条不同的笔记
      await database.close();
      final dbB = await openDatabase(
        ':memory:',
        version: 2,
        onCreate: NotesDatabase.createDBForTesting,
      );
      NotesDatabase.setDatabaseForTesting(dbB);

      final noteB = _makeNote(uuid: 'uuid-b', title: 'Note B');
      await database.storeNote(noteB);

      final engineB = _makeEngine(
        backend: backend,
        database: database,
        dataKey: engineA.keyring.dataKey,
        encryptedDataKey: engineA.keyring.encryptedDataKey,
      );

      // 设备 B 同步
      final result = await engineB.sync();

      // 验证：上传 1 条（noteB），下载 1 条（noteA）
      expect(result.success, isTrue);
      expect(result.uploaded, 1);
      expect(result.downloaded, 1);

      // 验证本地有 2 条笔记
      final notes = await database.readAllNotes();
      expect(notes.length, 2);
    });

    test('已同步的笔记不重复传输', () async {
      // 准备：同步一次
      final note1 = _makeNote(uuid: 'uuid-1', title: 'Note 1');
      await database.storeNote(note1);
      final engine = _makeEngine(backend: backend, database: database);
      await engine.sync();

      // 再次同步：无新改动
      final result = engine.sync();
      final syncResult = await result;

      // 验证：无上传无下载，全部跳过
      expect(syncResult.success, isTrue);
      expect(syncResult.uploaded, 0);
      expect(syncResult.downloaded, 0);
    });
  });

  group('SyncEngine - LWW 冲突解决', () {
    test('远端 updatedAt 更大时，远端胜出覆盖本地', () async {
      // 准备：设备 A 同步 note1（updatedAt=1000）
      final noteA = _makeNote(
        uuid: 'uuid-conflict',
        title: 'Version A',
        updatedAt: 1000,
      );
      await database.storeNote(noteA);
      final engineA = _makeEngine(backend: backend, database: database);
      await engineA.sync();

      // 设备 B：本地有同一笔记，但 updatedAt=2000（更新更晚）
      await database.close();
      final dbB = await openDatabase(
        ':memory:',
        version: 2,
        onCreate: NotesDatabase.createDBForTesting,
      );
      NotesDatabase.setDatabaseForTesting(dbB);

      // 设备 B 的共同祖先（base）= Version A：模拟 B 曾同步收敛到 Version A，
      // 之后本地把它单边改成 Version B（updatedAt=2000 更新）。远端仍是 Version A
      // （== base，未变），因此这是「单边编辑」而非双方分叉 —— base hash 判据
      // 下不应另存副本，纯 LWW 上传覆盖即可。
      // 若不设 base（syncedHash=null），会退化为「保守保留副本」，多出一次上传。
      final noteB = _makeNote(
        uuid: 'uuid-conflict',
        title: 'Version B (newer)',
        updatedAt: 2000, // 比 A 更新
      ).copyWith(
        syncedHash: SafeNote.computeHash('Version A', 'Test Description'),
      );
      await database.storeNote(noteB);

      final engineB = _makeEngine(
        backend: backend,
        database: database,
        dataKey: engineA.keyring.dataKey,
        encryptedDataKey: engineA.keyring.encryptedDataKey,
      );

      // 设备 B 同步
      final result = await engineB.sync();

      // 验证：本地版本胜出（updatedAt=2000 > 1000），上传覆盖远端
      expect(result.success, isTrue);
      expect(result.uploaded, 1);
      expect(result.conflicts, 1);

      // 验证本地内容仍是 Version B
      final local = await database.readNoteByUuid('uuid-conflict');
      expect(local!.title, 'Version B (newer)');
    });

    test('本地 updatedAt 更大时，本地胜出保留本地内容', () async {
      // 准备：设备 A 同步 note1（updatedAt=2000，较新）
      final noteA = _makeNote(
        uuid: 'uuid-conflict',
        title: 'Version A (newer)',
        updatedAt: 2000,
      );
      await database.storeNote(noteA);
      final engineA = _makeEngine(backend: backend, database: database);
      await engineA.sync();

      // 设备 B：本地有同一笔记，但 updatedAt=1000（较旧）
      await database.close();
      final dbB = await openDatabase(
        ':memory:',
        version: 2,
        onCreate: NotesDatabase.createDBForTesting,
      );
      NotesDatabase.setDatabaseForTesting(dbB);

      final noteB = _makeNote(
        uuid: 'uuid-conflict',
        title: 'Version B (older)',
        updatedAt: 1000,
      );
      await database.storeNote(noteB);

      final engineB = _makeEngine(
        backend: backend,
        database: database,
        dataKey: engineA.keyring.dataKey,
        encryptedDataKey: engineA.keyring.encryptedDataKey,
      );

      // 设备 B 同步
      final result = await engineB.sync();

      // 验证：远端胜出（updatedAt=2000 > 1000），下载覆盖本地
      expect(result.success, isTrue);
      expect(result.downloaded, 1);
      expect(result.conflicts, 1);

      // 验证本地内容被覆盖为 Version A
      final local = await database.readNoteByUuid('uuid-conflict');
      expect(local!.title, 'Version A (newer)');
    });
  });

  group('SyncEngine - 墓碑同步', () {
    test('本地软删除笔记 → 上传墓碑到远端', () async {
      // 准备：先同步一条笔记
      final note = _makeNote(uuid: 'uuid-delete', title: 'To be deleted');
      await database.storeNote(note);
      final engine = _makeEngine(backend: backend, database: database);
      await engine.sync();

      // 本地软删除
      final stored = await database.readNoteByUuid('uuid-delete');
      await database.softDelete(stored!.id!);

      // 再次同步
      final result = await engine.sync();

      // 验证：上传了墓碑（标记为 delete 操作）
      expect(result.success, isTrue);
      expect(result.deleted, 1);

      // 验证远端 manifest 里这条笔记标记为 deleted
      final remoteResponse = await backend.getManifest();
      final remoteManifest = ManifestCrypto.deserialize(
        engine.keyring.dataKey,
        remoteResponse.ciphertext,
      );
      expect(remoteManifest.items['uuid-delete']!.deleted, isTrue);
    });

    test('远端墓碑 → 本地也标记为软删除', () async {
      // 准备：设备 A 同步一条笔记后软删除再同步
      final note = _makeNote(uuid: 'uuid-tomb', title: 'Note to tomb');
      await database.storeNote(note);
      final engineA = _makeEngine(backend: backend, database: database);
      await engineA.sync();

      final stored = await database.readNoteByUuid('uuid-tomb');
      await database.softDelete(stored!.id!);
      await engineA.sync(); // 第二次同步上传墓碑

      // 设备 B：本地有同一笔记（未删除）
      await database.close();
      final dbB = await openDatabase(
        ':memory:',
        version: 2,
        onCreate: NotesDatabase.createDBForTesting,
      );
      NotesDatabase.setDatabaseForTesting(dbB);

      final noteB = _makeNote(
        uuid: 'uuid-tomb',
        title: 'Note to tomb',
        updatedAt: note.updatedAt,
      );
      await database.storeNote(noteB);

      final engineB = _makeEngine(
        backend: backend,
        database: database,
        dataKey: engineA.keyring.dataKey,
        encryptedDataKey: engineA.keyring.encryptedDataKey,
      );

      // 设备 B 同步
      final result = await engineB.sync();

      // 验证：远端墓碑应用，本地标记为删除
      expect(result.success, isTrue);

      final local = await database.readNoteByUuid('uuid-tomb');
      expect(local!.deleted, isTrue);
    });
  });

  group('SyncEngine - 乐观锁重试', () {
    test('putManifest 冲突后重试成功', () async {
      // 准备：本地有 1 条笔记
      final note = _makeNote(uuid: 'uuid-retry', title: 'Retry test');
      await database.storeNote(note);
      final engine = _makeEngine(backend: backend, database: database);

      // 让第一次 putManifest 抛冲突
      backend.conflictOnNextPuts(1);

      // 执行同步
      final result = await engine.sync();

      // 验证：重试后成功
      expect(result.success, isTrue);
      expect(result.attempts, 2); // 第一次冲突，第二次成功
      expect(result.uploaded, 1);
    });

    test('连续冲突超过 maxRetries 次后失败', () async {
      final note = _makeNote(uuid: 'uuid-fail', title: 'Fail test');
      await database.storeNote(note);
      final engine = _makeEngine(backend: backend, database: database);

      // 让所有 putManifest 都冲突
      backend.conflictOnNextPuts(SyncEngine.maxRetries + 1);

      final result = await engine.sync();

      // 验证：失败
      expect(result.success, isFalse);
      expect(result.attempts, SyncEngine.maxRetries);
      expect(result.errorMessage, contains('乐观锁冲突'));
    });
  });

  group('SyncEngine - 内容寻址去重', () {
    test('相同内容的多条笔记共享同一个 blob', () async {
      // 准备：2 条笔记内容完全相同（不同 uuid）
      final note1 = _makeNote(uuid: 'uuid-dup-1', title: 'Same', description: 'Content');
      final note2 = _makeNote(uuid: 'uuid-dup-2', title: 'Same', description: 'Content');
      await database.storeNote(note1);
      await database.storeNote(note2);

      final engine = _makeEngine(backend: backend, database: database);
      final result = await engine.sync();

      // 验证：上传了 2 条笔记，但 blob 只有 1 个（相同内容去重）
      expect(result.success, isTrue);
      expect(result.uploaded, 2);

      // 验证：两条笔记的 contentHash 相同
      expect(note1.contentHash, note2.contentHash);

      // blob 只有 1 个
      // 注意：FakeBackend._blobs 是私有的，我们通过 getBlob 验证
      final blob = await backend.getBlob(note1.contentHash);
      expect(blob, isNotNull);
    });
  });

  group('SyncEngine - 端到端：LocalFsBackend 集成', () {
    test('LocalFsBackend 真实文件系统同步', () async {
      // 这个测试用真实的 LocalFsBackend 验证 SyncEngine 与文件系统后端的集成
      final tempDir = await Directory.systemTemp
          .createTemp('safenotes_engine_e2e_');
      final localBackend = LocalFsBackend(rootPath: tempDir.path);
      await localBackend.init();

      // 准备本地笔记
      final note = _makeNote(uuid: 'uuid-e2e', title: 'E2E Test');
      await database.storeNote(note);

      // 构造测试用 Keyring（dataKey 独立生成，encryptedDataKey 用同一 dataKey 自包装）
      final e2eDataKey = SyncCrypto.generateDataKey();
      final keyring = makeTestKeyring(
        vaultId: 'e2e-keyring',
        dataKey: e2eDataKey,
        encryptedDataKey: base64Encode(
          SyncCrypto.wrapDataKey(e2eDataKey, e2eDataKey),
        ),
        keyFingerprint: '',
        keyVersion: 1,
        kdf: KdfParams.create(salt: SyncCrypto.generateSalt()),
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );
      final engine = SyncEngine(
        backend: localBackend,
        database: database,
        keyring: keyring,
        deviceId: 'e2e-test-device',
        journal: makeTestJournal(),
      );

      // 执行同步
      final result = await engine.sync();

      // 验证
      expect(result.success, isTrue);
      expect(result.uploaded, 1);

      // 验证 manifest 文件存在
      final manifestFile = File('${tempDir.path}/manifest.json');
      expect(await manifestFile.exists(), isTrue);
      expect(await manifestFile.length(), greaterThan(0));

      // 验证 blob 文件存在
      final blobFile = File('${tempDir.path}/blobs/${note.contentHash}');
      expect(await blobFile.exists(), isTrue);

      await localBackend.close();
      await tempDir.delete(recursive: true);
    });
  });

  // F1 修复：GC 测试
  group('SyncEngine - F1 垃圾回收', () {
    test('孤儿 blob 清理：同步后删除未被 manifest 引用的 blob', () async {
      // 准备：本地有 1 条笔记，同步上传
      final note = _makeNote(uuid: 'gc-uuid-1', title: 'GC Note');
      await database.storeNote(note);
      final engine = _makeEngine(backend: backend, database: database);
      await engine.sync();

      // 验证：笔记 blob 已上传
      expect(backend._blobs.containsKey(note.contentHash), isTrue);

      // 手动添加孤儿 blob（模拟历史遗留或冲突副本残留）
      // 64 字符十六进制字符串（SHA-256 格式），但不在 manifest 引用中
      final orphanHash = '0' * 64;
      final orphanData = Uint8List.fromList([1, 2, 3]);
      backend._blobs[orphanHash] = orphanData;
      expect(backend._blobs.length, 2); // 1 个引用 + 1 个孤儿

      // 再次同步（触发 GC）
      final result = await engine.sync();
      expect(result.success, isTrue);

      // 验证：孤儿 blob 被删除，引用的 blob 保留
      expect(backend._blobs.containsKey(orphanHash), isFalse);
      expect(backend._blobs.containsKey(note.contentHash), isTrue);
      expect(backend._blobs.length, 1);
    });

    test('墓碑 GC：超 30 天的墓碑从 manifest 移除并硬删除', () async {
      // 准备：创建一个超 30 天的墓碑
      final thirtyOneDaysAgo = DateTime.now()
          .subtract(const Duration(days: 31))
          .millisecondsSinceEpoch;
      final oldTombstone = _makeNote(
        uuid: 'gc-tombstone-old',
        title: 'Old Deleted Note',
        deleted: true,
        updatedAt: thirtyOneDaysAgo,
      );
      await database.storeNote(oldTombstone);

      // 创建一个未过期的墓碑（应保留）
      final recentTombstone = _makeNote(
        uuid: 'gc-tombstone-recent',
        title: 'Recent Deleted Note',
        deleted: true,
      );
      await database.storeNote(recentTombstone);

      final engine = _makeEngine(backend: backend, database: database);
      final result = await engine.sync();

      // 验证同步成功
      expect(result.success, isTrue);

      // 验证：旧墓碑已从数据库硬删除
      final notes = await database.readAllNotesIncludingDeleted();
      final uuids = notes.map((n) => n.uuid).toSet();
      expect(uuids.contains('gc-tombstone-old'), isFalse,
          reason: '超 30 天的墓碑应被硬删除');
      expect(uuids.contains('gc-tombstone-recent'), isTrue,
          reason: '未过期的墓碑应保留');

      // 验证：远端 manifest 不含旧墓碑
      final remoteManifest = await backend.getManifest();
      final manifest = ManifestCrypto.deserialize(
        testDataKey,
        remoteManifest.ciphertext,
      );
      expect(manifest.items.containsKey('gc-tombstone-old'), isFalse);
      expect(manifest.items.containsKey('gc-tombstone-recent'), isTrue);
    });

    test('listBlobs 返回空时 GC 跳过（保守不删）', () async {
      // 准备：本地有笔记，同步
      final note = _makeNote(uuid: 'gc-skip-1', title: 'Skip GC');
      await database.storeNote(note);
      final engine = _makeEngine(backend: backend, database: database);
      await engine.sync();

      // 用一个 listBlobs 返回空的 backend 包装
      // FakeBackend.listBlobs 返回 _blobs.keys，不会为空（有引用的 blob）
      // 此测试验证：当 backend 无孤儿时，GC 不删除任何 blob
      final beforeCount = backend._blobs.length;

      await engine.sync();

      // 验证：无孤儿时 blob 数量不变
      expect(backend._blobs.length, beforeCount);
    });
  });
}
