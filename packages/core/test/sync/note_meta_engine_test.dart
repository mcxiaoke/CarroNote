/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*/

// note_meta 同步引擎级测试（items.meta + per-note LWW）
//
// 覆盖 docs/note-meta-sync-plan.md F 组引擎场景：
//   - 双设备改不同笔记的元数据 → 双向同步互不丢失（原设计 §11 验收场景）
//   - 标签跨设备传播
//   - 硬删墓碑经 items.meta 传播 + 上报端墓碑 GC
//   - 解密失败自愈（Q1a：本地全量覆盖上传，不影响 SyncResult）
//   - 后端不支持 meta 对象时整段跳过（脏标记不被误清）
//   - 无脏行不上传空文件（Q3a）

import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:core/core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// 测试公共支撑（Keyring/Journal 构造 + Fake 存储 mixin）
import 'sync_test_support.dart';

/// 内存 FakeBackend：manifest/blob 走最小实现，meta/journal 走真实内存存储
class _MetaTestBackend
    with FakeJournalStore, FakeNoteMetaStore
    implements SyncBackend {
  Uint8List? manifestCiphertext;
  String _etag = '';
  final Map<String, Uint8List> _blobs = {};

  @override
  String get displayName => 'MetaTestBackend';

  @override
  String get providerKey => 'meta-test-backend';

  @override
  Future<void> init() async {}

  @override
  Future<({Uint8List ciphertext, String etag})> getManifest() async {
    if (manifestCiphertext == null) {
      return (ciphertext: Uint8List(0), etag: '');
    }
    return (ciphertext: manifestCiphertext!, etag: _etag);
  }

  @override
  Future<String> putManifest(Uint8List ciphertext, String expectedEtag) async {
    if (expectedEtag.isNotEmpty && _etag != expectedEtag) {
      throw ConflictException('etag mismatch');
    }
    if (expectedEtag.isEmpty && manifestCiphertext != null) {
      throw ConflictException('manifest already exists');
    }
    manifestCiphertext = ciphertext;
    _etag = 'etag-${DateTime.now().microsecondsSinceEpoch}';
    return _etag;
  }

  @override
  Future<Uint8List?> getBlob(String hash) async => _blobs[hash];

  @override
  Future<void> putBlob(String hash, Uint8List data) async {
    _blobs[hash] = data;
  }

  @override
  Future<void> deleteBlob(String hash) async => _blobs.remove(hash);

  @override
  Future<List<String>> listBlobs() async => _blobs.keys.toList();

  @override
  Future<void> deleteBlobSoft(String hash) async => deleteBlob(hash);

  @override
  Future<List<String>> listOrphanBlobs() async => [];

  @override
  Future<void> purgeOrphans(Duration retention) async {}

  @override
  Future<void> backupManifest([Uint8List? currentManifestBytes]) async {}

  @override
  Future<void> backupCorruptManifest(Uint8List ciphertext) async {
    // 模拟 LocalFS rename 移走损坏文件：远端不再存在，
    // 后续本地重建的空 etag PUT 才能按首传语义成功
    manifestCiphertext = null;
  }

  @override
  Future<List<String>> listManifestBackups() async => [];

  @override
  Future<Uint8List?> readManifestBackup(String name) async => null;

  @override
  Future<void> close() async {}

  @override
  Future<bool> ping() async => true;
}

SafeNote _makeNote({required String uuid, int? updatedAt}) {
  final now = updatedAt ?? DateTime.now().millisecondsSinceEpoch;
  return SafeNote(
    uuid: uuid,
    title: 'Title $uuid',
    description: 'Desc $uuid',
    contentHash: SafeNote.computeHash('Title $uuid', 'Desc $uuid'),
    deleted: false,
    createdTime: DateTime.now(),
    updatedAt: now,
    synced: false,
  );
}

SyncEngine _makeEngine({
  required SyncBackend backend,
  required NotesDatabase database,
  required Uint8List dataKey,
  required String encryptedDataKey,
  required String deviceId,
}) {
  final keyring = makeTestKeyring(
    vaultId: 'test-keyring-id',
    dataKey: dataKey,
    encryptedDataKey: encryptedDataKey,
    keyFingerprint: '',
  );
  return SyncEngine(
    backend: backend,
    database: database,
    keyring: keyring,
    deviceId: deviceId,
    journal: makeTestJournal(),
  );
}

Future<NotesDatabase> _makeDatabase(Uint8List dataKey) async {
  try {
    await NotesDatabase.instance.close();
  } on Exception {
    // 首次调用无库可关
  }
  final db = await openDatabase(
    ':memory:',
    version: 2,
    onCreate: NotesDatabase.createDBForTesting,
  );
  NotesDatabase.setDatabaseForTesting(db);
  final database = NotesDatabase.instance;
  database.setDataKey(dataKey);
  return database;
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDown(() async {
    try {
      await NotesDatabase.instance.close();
    } on Exception {
      // 忽略
    }
  });

  group('双设备 note_meta 同步', () {
    test('A 星标笔记1、B 星标笔记2 → 双向同步后两者都保留（验收场景）', () async {
      final backend = _MetaTestBackend();
      final dataKey = SyncCrypto.generateDataKey();
      final edk = base64.encode(Uint8List(60)..fillRange(0, 60, 0xAB));

      // 设备 A：建两条笔记 + 首次同步建立基线
      var dbA = await _makeDatabase(dataKey);
      await dbA.storeNote(_makeNote(uuid: 'note-1'));
      await dbA.storeNote(_makeNote(uuid: 'note-2'));
      var engineA = _makeEngine(
        backend: backend,
        database: dbA,
        dataKey: dataKey,
        encryptedDataKey: edk,
        deviceId: 'device-A',
      );
      expect((await engineA.sync()).success, isTrue);
      // A 星标笔记1（产生 meta 脏行）
      await dbA.setNotePinned('note-1', true);
      expect((await engineA.sync()).success, isTrue);
      expect(backend.metaObject, isNotNull, reason: '有脏行必须上传 items.meta');

      // 设备 B：下载笔记 + A 的 meta，然后自己星标笔记2
      var dbB = await _makeDatabase(dataKey);
      final engineB = _makeEngine(
        backend: backend,
        database: dbB,
        dataKey: dataKey,
        encryptedDataKey: edk,
        deviceId: 'device-B',
      );
      expect((await engineB.sync()).success, isTrue);
      expect(
        await dbB.getNoteMeta('note-1'),
        isNotNull,
        reason: 'B 应先收到 A 的星标',
      );
      expect((await dbB.getNoteMeta('note-1'))!.pinned, isTrue);
      await dbB.setNotePinned('note-2', true);
      expect((await engineB.sync()).success, isTrue);

      // 设备 A 再同步：应收到 B 的星标且自己的星标不丢
      expect((await engineA.sync()).success, isTrue);
      expect(
        (await dbA.getNoteMeta('note-1'))!.pinned,
        isTrue,
        reason: 'A 自己的星标不得被覆盖',
      );
      expect(
        (await dbA.getNoteMeta('note-2'))!.pinned,
        isTrue,
        reason: 'B 的星标应到达 A',
      );
    });

    test('标签经 items.meta 跨设备传播', () async {
      final backend = _MetaTestBackend();
      final dataKey = SyncCrypto.generateDataKey();
      final edk = base64.encode(Uint8List(60)..fillRange(0, 60, 0xAB));

      final dbA = await _makeDatabase(dataKey);
      await dbA.storeNote(_makeNote(uuid: 'tag-note'));
      final engineA = _makeEngine(
        backend: backend,
        database: dbA,
        dataKey: dataKey,
        encryptedDataKey: edk,
        deviceId: 'device-A',
      );
      await engineA.sync();
      await dbA.setNoteTags('tag-note', ['工作', '就医记录']);
      await engineA.sync();

      final dbB = await _makeDatabase(dataKey);
      final engineB = _makeEngine(
        backend: backend,
        database: dbB,
        dataKey: dataKey,
        encryptedDataKey: edk,
        deviceId: 'device-B',
      );
      await engineB.sync();

      final tags = (await dbB.getNoteMeta('tag-note'))!.tags;
      expect(tags, ['工作', '就医记录']);
    });

    test('硬删墓碑传播到 B；上报端墓碑被 GC', () async {
      final backend = _MetaTestBackend();
      final dataKey = SyncCrypto.generateDataKey();
      final edk = base64.encode(Uint8List(60)..fillRange(0, 60, 0xAB));

      final dbA = await _makeDatabase(dataKey);
      await dbA.storeNote(_makeNote(uuid: 'doomed'));
      await dbA.setNoteTags('doomed', ['to-be-deleted']);
      final engineA = _makeEngine(
        backend: backend,
        database: dbA,
        dataKey: dataKey,
        encryptedDataKey: edk,
        deviceId: 'device-A',
      );
      await engineA.sync();

      // B 先拿到带标签的状态
      final dbB = await _makeDatabase(dataKey);
      final engineB = _makeEngine(
        backend: backend,
        database: dbB,
        dataKey: dataKey,
        encryptedDataKey: edk,
        deviceId: 'device-B',
      );
      await engineB.sync();
      expect((await dbB.getNoteMeta('doomed'))?.tags, ['to-be-deleted']);

      // A 硬删除（写墓碑 + purgedUuids）→ 同步上报
      await dbA.hardDeleteByUuid('doomed');
      await engineA.sync();
      // A 端墓碑已上报并被 GC
      final aAll = await dbA.readAllNoteMetaIncludingTombstones();
      expect(aAll.containsKey('doomed'), isFalse, reason: '已上报墓碑应被物理清理');

      // B 同步：收到墓碑 → payload 擦除、UI 视角不可见
      await engineB.sync();
      final bTomb = await dbB.readAllNoteMetaIncludingTombstones();
      expect(bTomb['doomed']?.deleted, isTrue);
      expect(bTomb['doomed']?.tags, isEmpty, reason: '墓碑应用须擦除标签明文');
      expect(await dbB.getNoteMeta('doomed'), isNull);
    });
  });

  group('note_meta 容错与降级', () {
    test('解密失败走自愈：本地全量覆盖上传，SyncResult 不受影响（Q1a）', () async {
      final backend = _MetaTestBackend();
      final dataKey = SyncCrypto.generateDataKey();
      final edk = base64.encode(Uint8List(60)..fillRange(0, 60, 0xAB));

      final db = await _makeDatabase(dataKey);
      await db.storeNote(_makeNote(uuid: 'heal-note'));
      final engine = _makeEngine(
        backend: backend,
        database: db,
        dataKey: dataKey,
        encryptedDataKey: edk,
        deviceId: 'device-A',
      );
      await engine.sync();

      // 远端塞入坏密文（非合法信封）+ 本地产生脏行
      backend.metaObject = Uint8List.fromList(List.filled(48, 0xEE));
      await db.setNotePinned('heal-note', true);

      final result = await engine.sync();
      expect(result.success, isTrue, reason: 'meta 失败绝不影响主同步结果');

      // 自愈后远端应是合法新信封且可解回本地状态
      final sealed = backend.metaObject!;
      final plain = await NoteMetaSyncCodec.open(dataKey, sealed);
      final parsed = NoteMetaSyncCodec.decode(plain)!;
      expect(parsed.metas['heal-note']?.pinned, isTrue);
    });

    test('后端不支持 meta 对象时整段跳过，脏行保持 synced=0', () async {
      final backend = _MetaTestBackend()..supportsMeta = false;
      final dataKey = SyncCrypto.generateDataKey();
      final edk = base64.encode(Uint8List(60)..fillRange(0, 60, 0xAB));

      final db = await _makeDatabase(dataKey);
      await db.storeNote(_makeNote(uuid: 'skip-note'));
      final engine = _makeEngine(
        backend: backend,
        database: db,
        dataKey: dataKey,
        encryptedDataKey: edk,
        deviceId: 'device-A',
      );

      await db.setNotePinned('skip-note', true);
      final result = await engine.sync();
      expect(result.success, isTrue);
      expect(backend.metaObject, isNull);
      expect(
        (await db.getNoteMeta('skip-note'))!.synced,
        isFalse,
        reason: '未上传成功绝不能误标已同步',
      );
    });

    test('远端无文件且本地无 meta → 不上传空文件（Q3a）', () async {
      final backend = _MetaTestBackend();
      final dataKey = SyncCrypto.generateDataKey();
      final edk = base64.encode(Uint8List(60)..fillRange(0, 60, 0xAB));

      final db = await _makeDatabase(dataKey);
      await db.storeNote(_makeNote(uuid: 'plain-note'));
      final engine = _makeEngine(
        backend: backend,
        database: db,
        dataKey: dataKey,
        encryptedDataKey: edk,
        deviceId: 'device-A',
      );

      final result = await engine.sync();
      expect(result.success, isTrue);
      expect(backend.metaObject, isNull, reason: '无脏行不应创建空 items.meta');
    });

    test('远端为未来 wire 版本 → 整段跳过，本端脏行保留待升级', () async {
      final backend = _MetaTestBackend();
      final dataKey = SyncCrypto.generateDataKey();
      final edk = base64.encode(Uint8List(60)..fillRange(0, 60, 0xAB));

      final db = await _makeDatabase(dataKey);
      await db.storeNote(_makeNote(uuid: 'fv-note'));
      final engine = _makeEngine(
        backend: backend,
        database: db,
        dataKey: dataKey,
        encryptedDataKey: edk,
        deviceId: 'device-A',
      );
      await engine.sync();

      // 他端用未来版本写入 items.meta
      backend.metaObject = await NoteMetaSyncCodec.seal(
        dataKey,
        Uint8List.fromList(utf8.encode('{"v":999,"notes":{}}')),
      );
      await db.setNotePinned('fv-note', true);

      final result = await engine.sync();
      expect(result.success, isTrue);
      // 未覆盖远端（仍是 v999 原文）
      final plain = await NoteMetaSyncCodec.open(dataKey, backend.metaObject!);
      expect(NoteMetaSyncCodec.decode(plain)!.version, 999);
      // 本地脏行保留，等客户端升级后再传
      expect((await db.getNoteMeta('fv-note'))!.synced, isFalse);
    });

    test('manifest 损坏重建轮同样执行 meta 段（L-2）', () async {
      final backend = _MetaTestBackend();
      final dataKey = SyncCrypto.generateDataKey();
      final edk = base64.encode(Uint8List(60)..fillRange(0, 60, 0xAB));

      final db = await _makeDatabase(dataKey);
      await db.storeNote(_makeNote(uuid: 'recover-note'));
      final engine = _makeEngine(
        backend: backend,
        database: db,
        dataKey: dataKey,
        encryptedDataKey: edk,
        deviceId: 'device-A',
      );
      // 建立基线后注入脏 meta + 坏 manifest（过短字节必抛 FormatException）
      await engine.sync();
      await db.setNotePinned('recover-note', true);
      backend.manifestCiphertext = Uint8List.fromList([1, 2, 3]);

      final result = await engine.sync();
      expect(result.success, isTrue, reason: '损坏应触发重建而非同步失败');
      expect(
        backend.metaObject,
        isNotNull,
        reason: '恢复轮必须执行 meta 段（否则 items.meta 残留到下轮才自愈）',
      );
      final plain = await NoteMetaSyncCodec.open(dataKey, backend.metaObject!);
      expect(
        NoteMetaSyncCodec.decode(plain)!.metas['recover-note']?.pinned,
        isTrue,
      );
    });
  });
}
