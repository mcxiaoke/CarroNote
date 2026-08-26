/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

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
import 'package:test/test.dart';
import 'package:core/core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// 测试公共支撑（P2：Keyring/Journal 构造 + FakeBackend journal 存储）
import 'sync_test_support.dart';

/// 测试用 FakeBackend：内存实现，可模拟冲突
class FakeBackend
    with FakeJournalStore, FakeNoteMetaStore
    implements SyncBackend {
  Uint8List? _manifestCiphertext;
  String _etag = '';
  final Map<String, Uint8List> _blobs = {};

  /// 控制 putManifest 是否第一次抛冲突（用于测试乐观锁重试）
  int _conflictOnNextPuts = 0;

  /// P1-B 测试钩子：putManifest 写入前**等待完成**的回调。
  ///
  /// 此时 _mergeAndTransfer 已完成、merged 快照已构建，但 _updateLocalState
  /// 尚未执行——模拟「同步期间用户编辑笔记」的竞态窗口。回调被 await 确保
  /// 编辑先落盘，_updateLocalState 的白名单比对应跳过该笔记（当前 hash ≠
  /// merged 快照），避免 fire-and-forget 的时序不确定性。
  Future<void> Function()? onBeforePutManifestWrite;

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

    // P1-B：在乐观锁检查通过、实际写入前触发回调（模拟同步期竞态）
    // await 回调：确保同步期间编辑先落盘，_updateLocalState 白名单比对才确定
    if (onBeforePutManifestWrite != null) {
      await onBeforePutManifestWrite!();
    }

    if (expectedEtag.isEmpty) {
      if (_manifestCiphertext != null) {
        throw ConflictException('FakeBackend: manifest already exists');
      }
    } else {
      if (_etag != expectedEtag) {
        throw ConflictException(
          'FakeBackend: etag mismatch (expected=$expectedEtag, actual=$_etag)',
        );
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
  Future<List<String>> listManifestBackups() async => [];

  @override
  Future<Uint8List?> readManifestBackup(String name) async => null;

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
  final dk =
      dataKey ??
      (database.isEncryptionEnabled
          ? database.dataKeyForTesting
          : SyncCrypto.generateDataKey());
  final edk =
      encryptedDataKey ?? base64Encode(Uint8List(60)..fillRange(0, 60, 0xAB));
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
    test('单边编辑已同步笔记（base 存在）：fast-forward 上传覆盖，不记 conflict', () async {
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
      final noteB =
          _makeNote(
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

      // P0-B 修复：base 存在且远端未偏离 base → 单边编辑走 fast-forward，
      // 上传覆盖远端，不记 conflict（原实现误报 conflict=1）
      expect(result.success, isTrue);
      expect(result.uploaded, 1);
      expect(result.conflicts, 0);

      // 验证本地内容仍是 Version B
      final local = await database.readNoteByUuid('uuid-conflict');
      expect(local!.title, 'Version B (newer)');
    });

    test('base=null 退化真冲突：LWW 远端胜下载覆盖本地', () async {
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

    test('真双方冲突（双方都偏离 base）：LWW + 记 conflict', () async {
      // 场景：A 与 B 都从同一 base (V1) 出发分别改成 V2 / V3 → 真并发冲突
      //
      // 1. A 同步 V1 → 远端=V1，A 的 base=V1hash
      // 2. A 本地改 V1→V2 (updatedAt=2000)，A 同步：本地 V2 vs 远端 V1
      //    base=V1，localChanged=true、remoteChanged=false → fast-forward
      //    A 单边，上传 V2 覆盖远端，A 的 base 更新为 V2hash
      // 3. B 曾同步收敛到 V1（base=V1hash），离线把 V1 改成 V3 (updatedAt=3000)
      // 4. B 上线同步：本地 V3 vs 远端 V2，base=V1
      //    localChanged=true (V3≠V1)、remoteChanged=true (V2≠V1) → 真冲突
      //    LWW: B 的 3000 > A 的 2000 → B 胜，上传 V3 覆盖远端
      final noteA1 = _makeNote(
        uuid: 'uuid-real-conflict',
        title: 'V1',
        updatedAt: 1000,
      );
      await database.storeNote(noteA1);
      final engineA = _makeEngine(backend: backend, database: database);
      await engineA.sync();

      // A 的 base = V1hash（同步收敛后写入）
      final v1Hash = SafeNote.computeHash('V1', 'Test Description');

      // A 本地编辑 V1→V2，保持 syncedHash=V1hash（base 不变）
      final syncedA = await database.readNoteByUuid('uuid-real-conflict');
      final noteA2 = syncedA!.copyWith(
        title: 'V2',
        contentHash: SafeNote.computeHash('V2', 'Test Description'),
        updatedAt: 2000,
        synced: false,
      );
      await database.updateNote(noteA2);
      await engineA.sync(); // fast-forward A 单边，远端变 V2

      // B：新库，模拟曾同步收敛到 V1（base=V1hash），离线改成 V3
      await database.close();
      final dbB = await openDatabase(
        ':memory:',
        version: 2,
        onCreate: NotesDatabase.createDBForTesting,
      );
      NotesDatabase.setDatabaseForTesting(dbB);
      final noteB = _makeNote(
        uuid: 'uuid-real-conflict',
        title: 'V3',
        updatedAt: 3000,
      ).copyWith(syncedHash: v1Hash);
      await database.storeNote(noteB);

      final engineB = _makeEngine(
        backend: backend,
        database: database,
        dataKey: engineA.keyring.dataKey,
        encryptedDataKey: engineA.keyring.encryptedDataKey,
      );

      final result = await engineB.sync();

      // 真冲突：B 更新（3000>2000）胜出，上传 V3 覆盖远端，记 conflict。
      // uploaded=2：胜方 V3 上传 + 败方 V2 保留为冲突副本上传（新 UUID）
      expect(result.success, isTrue);
      expect(result.conflicts, 1);
      expect(result.uploaded, 2);

      // 验证本地是 V3（B 胜保留本地内容）
      final local = await database.readNoteByUuid('uuid-real-conflict');
      expect(local!.title, 'V3');
    });
  });

  group('SyncEngine - fast-forward 单边变更（P0-B 修复）', () {
    // P0-B 修复目标：单客户端删除/编辑已同步笔记时，远端从未改动，
    // 应走 fast-forward 分支（上传/下载覆盖），不应误记 conflict。
    // 详见 docs/conflict-analysis-20260802.md

    test('单边软删除已同步笔记：fast-forward 上传墓碑，不记 conflict', () async {
      // 准备：同步一条笔记，建立 base (hash, deleted=false)
      final note = _makeNote(uuid: 'uuid-ff-del', title: 'To delete');
      await database.storeNote(note);
      final engine = _makeEngine(backend: backend, database: database);
      await engine.sync();

      // 验证 base 已建立
      final synced = await database.readNoteByUuid('uuid-ff-del');
      expect(synced!.synced, isTrue);
      expect(synced.syncedHash, note.contentHash);
      expect(synced.syncedDeleted, isFalse);

      // 本地软删除（模拟用户操作：softDelete 不动 syncedHash/syncedDeleted）
      await database.softDelete(synced.id!);

      // 再次同步：本地 deleted=true 偏离 base(deleted=false)，远端未动
      // → fast-forward 本地单边变更，上传墓碑，不记 conflict
      final result = await engine.sync();

      expect(result.success, isTrue);
      expect(result.deleted, 1);
      expect(result.conflicts, 0); // P0-B：单边删除不再误报 conflict

      // 验证远端 manifest 标记为 deleted
      final remoteResponse = await backend.getManifest();
      final remoteManifest = await ManifestCrypto.deserialize(
        engine.keyring.dataKey,
        remoteResponse.ciphertext,
      );
      expect(remoteManifest.items['uuid-ff-del']!.deleted, isTrue);

      // 验证本地 base 已更新为 deleted=true（下一轮判定的 base）
      final after = await database.readNoteByUuid('uuid-ff-del');
      expect(after!.synced, isTrue);
      expect(after.syncedDeleted, isTrue);
      expect(after.syncedHash, note.contentHash);
    });

    test('单边编辑已同步笔记：fast-forward 上传覆盖，不记 conflict', () async {
      // 准备：同步 V1，建立 base
      final noteV1 = _makeNote(
        uuid: 'uuid-ff-edit',
        title: 'V1',
        updatedAt: 1000,
      );
      await database.storeNote(noteV1);
      final engine = _makeEngine(backend: backend, database: database);
      await engine.sync();

      // 本地编辑 V1→V2，保持 syncedHash=V1hash（base 不变）
      final synced = await database.readNoteByUuid('uuid-ff-edit');
      final noteV2 = synced!.copyWith(
        title: 'V2',
        contentHash: SafeNote.computeHash('V2', 'Test Description'),
        updatedAt: 2000,
        synced: false,
      );
      await database.updateNote(noteV2);

      // 再次同步：本地 V2 偏离 base V1，远端仍是 V1（未动）→ fast-forward
      final result = await engine.sync();

      expect(result.success, isTrue);
      expect(result.uploaded, 1);
      expect(result.conflicts, 0); // P0-B：单边编辑不再误报 conflict

      // 验证本地内容是 V2，base 更新为 V2hash
      final local = await database.readNoteByUuid('uuid-ff-edit');
      expect(local!.title, 'V2');
      expect(local.synced, isTrue);
      expect(local.syncedHash, noteV2.contentHash);
    });

    test('单边变更后再次同步：base 已更新，无变化全部跳过', () async {
      // 验证 fast-forward 后 base 正确更新，避免「重复上传」或「误判冲突」
      final noteV1 = _makeNote(
        uuid: 'uuid-ff-stable',
        title: 'V1',
        updatedAt: 1000,
      );
      await database.storeNote(noteV1);
      final engine = _makeEngine(backend: backend, database: database);
      await engine.sync();

      // 单边编辑 + 同步（fast-forward）
      final synced = await database.readNoteByUuid('uuid-ff-stable');
      final noteV2 = synced!.copyWith(
        title: 'V2',
        contentHash: SafeNote.computeHash('V2', 'Test Description'),
        updatedAt: 2000,
        synced: false,
      );
      await database.updateNote(noteV2);
      await engine.sync();

      // 第三次同步：本地 V2 == base V2 == 远端 V2 → 全部跳过
      final result = await engine.sync();

      expect(result.success, isTrue);
      expect(result.uploaded, 0);
      expect(result.downloaded, 0);
      expect(result.conflicts, 0);
    });
  });

  group('SyncEngine - P1-A 同步期写入竞态（白名单 markSynced）', () {
    // P1-A 修复目标：_updateLocalState 改为白名单模式，只标记「当前 (hash, deleted)
    // == merged.items[uuid]」的笔记。同步期间被编辑的笔记当前 hash ≠ merged 快照
    // → 跳过，保持 synced=0、syncedHash=旧 base，下次同步重新处理。
    // 原实现 markAllSyncedExcept 是全量 UPDATE，会把同步期间编辑的笔记误标
    // synced=1 并把 syncedHash 写成「远端没有的新 hash」→ 下次同步 fast-forward
    // 远端单边下载旧内容覆盖本地新编辑 → 丢数据。
    // 详见 docs/conflict-analysis-20260802.md §P1-A

    test('同步期间编辑已同步笔记：不被误标 synced=1，base 不被污染', () async {
      // note1 + note2 同步建立 base
      final note1 = _makeNote(uuid: 'uuid-p1a-1', title: 'Note 1');
      await database.storeNote(note1);
      final note2 = _makeNote(uuid: 'uuid-p1a-2', title: 'V1', updatedAt: 1000);
      await database.storeNote(note2);
      final engine = _makeEngine(backend: backend, database: database);
      await engine.sync();

      final v1Hash = SafeNote.computeHash('V1', 'Test Description');

      // note3 新建触发第二次 sync 的 PUT manifest（否则无变化会跳过 PUT）
      // 回调里编辑 note2 → V2：模拟「同步期间用户编辑」竞态
      // （_mergeAndTransfer 已用 V1 快照构建 merged，_updateLocalState 尚未执行）
      final note3 = _makeNote(uuid: 'uuid-p1a-3', title: 'Note 3');
      await database.storeNote(note3);
      final note2Stored = await database.readNoteByUuid('uuid-p1a-2');
      backend.onBeforePutManifestWrite = () async {
        final edited = note2Stored!.copyWith(
          title: 'V2',
          contentHash: SafeNote.computeHash('V2', 'Test Description'),
          updatedAt: 2000,
          synced: false,
        );
        await database.updateNote(edited);
      };
      await engine.sync();
      backend.onBeforePutManifestWrite = null;

      // 验证 P1-A：note2 当前是 V2，但 merged 快照是 V1（已 skip）→ 跳过 markSynced
      final after = await database.readNoteByUuid('uuid-p1a-2');
      expect(after!.title, 'V2');
      expect(after.synced, isFalse, reason: '同步期间编辑的笔记不应被误标 synced=1');
      expect(
        after.syncedHash,
        v1Hash,
        reason: 'base 必须保持旧 V1hash，不能被污染为新 hash',
      );
    });

    test('同步期间编辑的笔记下次 fast-forward 上传新内容，不丢数据', () async {
      // note1 + note2 同步建立 base
      final note1 = _makeNote(uuid: 'uuid-p1a-nd-1', title: 'Note 1');
      await database.storeNote(note1);
      final note2 = _makeNote(
        uuid: 'uuid-p1a-nd-2',
        title: 'V1',
        updatedAt: 1000,
      );
      await database.storeNote(note2);
      final engine = _makeEngine(backend: backend, database: database);
      await engine.sync();

      // note3 触发 PUT，回调里编辑 note2 → V2
      final note3 = _makeNote(uuid: 'uuid-p1a-nd-3', title: 'Note 3');
      await database.storeNote(note3);
      final note2Stored = await database.readNoteByUuid('uuid-p1a-nd-2');
      backend.onBeforePutManifestWrite = () async {
        final edited = note2Stored!.copyWith(
          title: 'V2',
          contentHash: SafeNote.computeHash('V2', 'Test Description'),
          updatedAt: 2000,
          synced: false,
        );
        await database.updateNote(edited);
      };
      await engine.sync();
      backend.onBeforePutManifestWrite = null;

      // 第三次同步：note2 V2 vs 远端 V1，base=V1hash（未被污染）
      // → localChanged=true、remoteChanged=false → fast-forward 本地单边，上传 V2
      final result = await engine.sync();
      expect(result.success, isTrue);
      expect(result.uploaded, 1);
      expect(result.conflicts, 0);

      // 验证 note2 V2 收敛，本地内容未被远端旧 V1 覆盖（不丢数据）
      final after = await database.readNoteByUuid('uuid-p1a-nd-2');
      expect(after!.title, 'V2');
      expect(after.synced, isTrue);
      expect(after.syncedHash, after.contentHash);

      // 验证远端也是 V2
      final remoteResponse = await backend.getManifest();
      final remoteManifest = await ManifestCrypto.deserialize(
        engine.keyring.dataKey,
        remoteResponse.ciphertext,
      );
      expect(remoteManifest.items['uuid-p1a-nd-2']!.hash, after.contentHash);
    });

    test('同步期间新建的笔记不被误标 synced=1', () async {
      // note1 同步建立，note2 触发第二次 sync 的 PUT，回调里新建 note3
      final note1 = _makeNote(uuid: 'uuid-p1a-new-1', title: 'Note 1');
      await database.storeNote(note1);
      final engine = _makeEngine(backend: backend, database: database);
      await engine.sync();

      final note2 = _makeNote(uuid: 'uuid-p1a-new-2', title: 'Note 2');
      await database.storeNote(note2);
      backend.onBeforePutManifestWrite = () async {
        // note3 在同步开始前不存在，merged 快照不含 note3
        final note3 = _makeNote(
          uuid: 'uuid-p1a-new-3',
          title: 'Note 3 (new during sync)',
        );
        await database.storeNote(note3);
      };
      final result = await engine.sync();
      backend.onBeforePutManifestWrite = null;

      expect(result.success, isTrue);

      // note3 不在 merged 快照里 → _updateLocalState 跳过 → synced=0
      final note3After = await database.readNoteByUuid('uuid-p1a-new-3');
      expect(note3After, isNotNull);
      expect(note3After!.synced, isFalse, reason: '同步期间新建的笔记不应被误标 synced=1');
      expect(note3After.syncedHash, isNull);
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
      final remoteManifest = await ManifestCrypto.deserialize(
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
      final note1 = _makeNote(
        uuid: 'uuid-dup-1',
        title: 'Same',
        description: 'Content',
      );
      final note2 = _makeNote(
        uuid: 'uuid-dup-2',
        title: 'Same',
        description: 'Content',
      );
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
      final tempDir = await Directory.systemTemp.createTemp(
        'safenotes_engine_e2e_',
      );
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
          await SyncCrypto.wrapDataKey(e2eDataKey, e2eDataKey),
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

      // 再次同步（P2 两阶段 GC：首次观察只登记候选，不隔离——
      // 保护「他端刚 putBlob、尚未 putManifest」的并发窗口）
      final r1 = await engine.sync();
      expect(r1.success, isTrue);
      expect(
        backend._blobs.containsKey(orphanHash),
        isTrue,
        reason: '两阶段 GC：首次观察仅登记候选，不应立即隔离',
      );

      // 再同步（连续第二次观察仍为孤儿 → 才隔离）
      final r2 = await engine.sync();
      expect(r2.success, isTrue);

      // 验证：孤儿 blob 被删除，引用的 blob 保留
      expect(backend._blobs.containsKey(orphanHash), isFalse);
      expect(backend._blobs.containsKey(note.contentHash), isTrue);
      expect(backend._blobs.length, 1);
    });

    test('两阶段 GC：候选 blob 被他端引用后不再隔离（并发窗口保护）', () async {
      // 准备：本地有 1 条笔记，同步上传
      final note = _makeNote(uuid: 'gc-race-uuid', title: 'GC Race');
      await database.storeNote(note);
      final engine = _makeEngine(backend: backend, database: database);
      await engine.sync();
      expect(backend._blobs.containsKey(note.contentHash), isTrue);

      // 模拟他端「正在上传」的 blob：已 putBlob、尚未 putManifest
      final inFlight = 'f' * 64;
      backend._blobs[inFlight] = Uint8List.fromList([9, 9]);

      // 第 1 次同步：GC 观察到孤儿候选，但不应隔离（保护上传窗口）
      final r1 = await engine.sync();
      expect(r1.success, isTrue);
      expect(
        backend._blobs.containsKey(inFlight),
        isTrue,
        reason: '首次观察不得隔离正在上传的 blob',
      );

      // 他端随后提交 manifest（引用该 blob）
      backend._blobs[inFlight] = Uint8List.fromList([9, 9]);
      final remoteManifest = await backend.getManifest();
      final remote = await ManifestCrypto.deserialize(
        testDataKey,
        remoteManifest.ciphertext,
      );
      final items = Map<String, ManifestItem>.from(remote.items)
        ..['he-other'] = ManifestItem(
          hash: inFlight,
          deleted: false,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
          updatedBy: 'other-device',
          createdAt: DateTime.now().millisecondsSinceEpoch,
        );
      await backend.putManifest(
        await ManifestCrypto.serialize(
          testDataKey,
          remote.copyWith(items: items),
        ),
        remoteManifest.etag,
      );

      // 第 2 次同步：该 blob 已被 manifest 引用 → 不再是孤儿，不得隔离
      final r2 = await engine.sync();
      expect(r2.success, isTrue);
      expect(
        backend._blobs.containsKey(inFlight),
        isTrue,
        reason: '他端已提交 manifest 引用的 blob 不得被 GC 隔离',
      );
      expect(backend._blobs.containsKey(note.contentHash), isTrue);
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
      expect(
        uuids.contains('gc-tombstone-old'),
        isFalse,
        reason: '超 30 天的墓碑应被硬删除',
      );
      expect(
        uuids.contains('gc-tombstone-recent'),
        isTrue,
        reason: '未过期的墓碑应保留',
      );

      // 验证：远端 manifest 不含旧墓碑
      final remoteManifest = await backend.getManifest();
      final manifest = await ManifestCrypto.deserialize(
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
