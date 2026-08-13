/*
 * P0-1 / P0-3 / P0-4 / P1-1 / P1-2 回归测试 + 自愈/混沌场景
 *
 * 覆盖本轮改动：
 *   - P0-1 重建路径跳过 GC（远端 manifest 为空/损坏时，绝不误删其他设备 blob）
 *   - P0-3 repairRemote：远端 blob 缺失 → 本机持有明文则重传自愈
 *   - P0-4 普通下载：远端 blob 缺失 → 本机持有明文/孪生则自愈重传
 *   - P1-1 manifest 代际备份（环形 N 份，可恢复）
 *   - P1-2 GC 软删除隔离区（blobs-orphan/，超期才真删）
 *   - 混沌：运行中随机删掉/翻转一个远端 blob，断言最终要么被 heal 补回、
 *           要么出现在 failedNoteUuids（绝不静默丢失）
 *
 * 运行：flutter test test/sync/p0p1_self_heal_test.dart
 */

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:core/core.dart';

// 测试公共支撑（P2：Keyring/Journal 构造 + FakeBackend journal 存储）
import 'sync_test_support.dart';

// ──────────────────────────────────────────────
// 测试用 FakeBackend（内存实现，支持 P1-2 隔离区与 P1-1 备份记录）
// ──────────────────────────────────────────────
class FakeBackend with FakeJournalStore implements SyncBackend {
  Uint8List? _manifestCiphertext;
  String _etag = '';
  final Map<String, Uint8List> _blobs = {};
  final Map<String, ({Uint8List data, int ts})> _orphans = {};
  final List<Uint8List> _backups = [];
  int _conflictOnNextPuts = 0;

  @override
  String get displayName => 'FakeBackend';

  @override
  String get providerKey => 'fake-test-backend';

  @override
  Future<void> init() async {}

  void conflictOnNextPuts(int count) => _conflictOnNextPuts = count;

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
    } else if (_etag != expectedEtag) {
      throw ConflictException('FakeBackend: etag mismatch');
    }
    _manifestCiphertext = ciphertext;
    _etag = 'etag-${DateTime.now().microsecondsSinceEpoch}';
    return _etag;
  }

  @override
  Future<Uint8List?> getBlob(String hash) async => _blobs[hash];

  @override
  Future<void> putBlob(String hash, Uint8List data) async =>
      _blobs[hash] = data;

  @override
  Future<void> deleteBlob(String hash) async => _blobs.remove(hash);

  @override
  Future<List<String>> listBlobs() async => _blobs.keys.toList();

  /// P1-2：软删除到隔离区（内存实现）
  @override
  Future<void> deleteBlobSoft(String hash) async {
    final d = _blobs.remove(hash);
    if (d != null) {
      _orphans[hash] = (data: d, ts: DateTime.now().millisecondsSinceEpoch);
    }
  }

  @override
  Future<List<String>> listOrphanBlobs() async => _orphans.keys.toList();

  /// P1-2：清理超期隔离项（retention 之前写入的视为超期）
  @override
  Future<void> purgeOrphans(Duration retention) async {
    final cutoff = DateTime.now().subtract(retention).millisecondsSinceEpoch;
    _orphans.removeWhere((h, v) => v.ts < cutoff);
  }

  /// P1-1：记录每次备份的 manifest 密文
  @override
  Future<void> backupManifest([Uint8List? currentManifestBytes]) async {
    if (currentManifestBytes != null && currentManifestBytes.isNotEmpty) {
      _backups.add(currentManifestBytes);
    }
  }

  /// D2 修复：备份损坏 manifest（模拟真实后端：移除损坏文件以便空 etag 重建）
  @override
  Future<void> backupCorruptManifest(Uint8List ciphertext) async {
    _manifestCiphertext = null;
    _etag = '';
  }

  /// P1-1 读侧：从新到旧返回所有备份名（对应 _backups 逆序）
  @override
  Future<List<String>> listManifestBackups() async => [
    for (var i = _backups.length - 1; i >= 0; i--) 'backup-$i',
  ];

  @override
  Future<Uint8List?> readManifestBackup(String name) async {
    final m = RegExp(r'^backup-(\d+)$').firstMatch(name);
    if (m == null) return null;
    final idx = int.parse(m.group(1)!);
    if (idx < 0 || idx >= _backups.length) return null;
    return _backups[idx];
  }

  @override
  Future<void> close() async {}

  @override
  Future<bool> ping() async => true;

  void reset() {
    _manifestCiphertext = null;
    _etag = '';
    _blobs.clear();
    _orphans.clear();
    _backups.clear();
    _conflictOnNextPuts = 0;
  }
}

// ──────────────────────────────────────────────
// 辅助构造
// ──────────────────────────────────────────────
SyncEngine _makeEngine({
  required SyncBackend backend,
  required NotesDatabase database,
  required Uint8List dataKey,
  String? encryptedDataKey,
  String vaultId = 'test-keyring',
  String deviceId = 'test-device',
}) {
  final edk =
      encryptedDataKey ?? base64Encode(Uint8List(60)..fillRange(0, 60, 0xAB));
  final keyring = makeTestKeyring(
    vaultId: vaultId,
    dataKey: dataKey,
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
    deviceId: deviceId,
    journal: makeTestJournal(),
  );
}

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
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late FakeBackend backend;
  late NotesDatabase database;
  late Uint8List testDataKey;

  setUp(() async {
    backend = FakeBackend();
    final db = await openDatabase(
      ':memory:',
      version: 2,
      onCreate: NotesDatabase.createDBForTesting,
    );
    NotesDatabase.setDatabaseForTesting(db);
    database = NotesDatabase.instance;
    testDataKey = SyncCrypto.generateDataKey();
    database.setDataKey(testDataKey);
  });

  tearDown(() async {
    await database.close();
    backend.reset();
  });

  // ────────────────────────────────────────────
  // P0-1：重建路径跳过 GC
  // ────────────────────────────────────────────
  group('P0-1 重建路径跳过 GC', () {
    test('远端 manifest 为空（首次同步）：不误删其他设备 blob', () async {
      // 模拟其他设备已在服务端留有 blob（不在本端 manifest 引用中）
      final otherHash = '0' * 64;
      backend._blobs[otherHash] = Uint8List.fromList([9, 9, 9]);

      final note = _makeNote(uuid: 'p01-note', title: 'P0-1');
      await database.storeNote(note);

      final engine = _makeEngine(
        backend: backend,
        database: database,
        dataKey: testDataKey,
      );
      final result = await engine.sync();

      expect(result.success, isTrue);
      // 其他设备的 blob 应被保留（skipGc 生效，未执行孤儿 GC）
      expect(
        backend._blobs.containsKey(otherHash),
        isTrue,
        reason: '远端空时不应误删其他设备 blob',
      );
      // 本端笔记 blob 已上传
      expect(backend._blobs.containsKey(note.contentHash), isTrue);
    });

    test('远端 manifest 损坏→重建：不误删其他设备 blob', () async {
      // 写入无法解析的"损坏" manifest（触发 FormatException → 重建分支 early-return）
      backend._manifestCiphertext = Uint8List.fromList([1, 2, 3, 4, 5]);
      backend._etag = 'garbage-etag';

      final otherHash = 'a' * 64;
      backend._blobs[otherHash] = Uint8List.fromList([8, 8, 8]);

      final note = _makeNote(uuid: 'p01-note2', title: 'P0-1b');
      await database.storeNote(note);

      final engine = _makeEngine(
        backend: backend,
        database: database,
        dataKey: testDataKey,
      );
      final result = await engine.sync();

      expect(result.success, isTrue);
      // 重建分支直接 early-return，根本不会执行 GC
      expect(
        backend._blobs.containsKey(otherHash),
        isTrue,
        reason: '损坏重建不应误删其他设备 blob',
      );
    });
  });

  // ────────────────────────────────────────────
  // P1-F: bak 循环恢复 + F-H01 空 etag PUT
  // ────────────────────────────────────────────
  group('P1-F manifest bak 循环恢复', () {
    test('损坏且 bak 可用：优先从 bak 恢复，不丢远端数据', () async {
      final note = _makeNote(uuid: 'p1f-note', title: 'P1-F');
      await database.storeNote(note);

      final engine = _makeEngine(
        backend: backend,
        database: database,
        dataKey: testDataKey,
      );

      // 第一次同步：远端为空 → 仅首次上传，不产生备份
      var r = await engine.sync();
      expect(r.success, isTrue);
      expect(backend._backups, isEmpty);

      // 第二次同步：PUT 前会备份旧 manifest（此时已存在）→ 得到一份可用的 bak
      final note2 = _makeNote(uuid: 'p1f-note2', title: 'P1-F2');
      await database.storeNote(note2);
      r = await engine.sync();
      expect(r.success, isTrue);
      expect(backend._backups, isNotEmpty, reason: '第二次同步应产生 manifest 备份');

      // 注入损坏远端（本地两次同步后 bak 中已是含 note 的旧 manifest）
      backend._manifestCiphertext = Uint8List.fromList([1, 2, 3, 4, 5]);
      backend._etag = 'garbage-etag';

      // re-GET 也损坏 → 走 bak 循环：应能从备份恢复远端数据
      r = await engine.sync();
      expect(r.success, isTrue, reason: 'bak 恢复不应导致同步失败');
      final recoverAction = r.actions.firstWhere(
        (a) => a.uuid == '' && a.type == SyncActionType.skip,
        orElse: () => throw StateError('缺少恢复动作'),
      );
      expect(
        recoverAction.message,
        contains('bak'),
        reason: '应从 bak 恢复而非本地空重建',
      );
      // 远端数据未丢：两次同步的笔记都还在本地
      expect(await database.readNoteByUuid('p1f-note'), isNotNull);
      expect(await database.readNoteByUuid('p1f-note2'), isNotNull);
      // 远端 manifest 已生成可解析的新版本（含 bak 恢复的旧数据 + 本地新数据）
      expect(backend._manifestCiphertext, isNotNull);
      final remote = await ManifestCrypto.deserialize(
        testDataKey,
        backend._manifestCiphertext!,
      );
      expect(remote.items.keys, contains('p1f-note'));
      expect(remote.items.keys, contains('p1f-note2'));
    });

    test('损坏且无 bak：本地重建后用空 etag 首传（F-H01）', () async {
      final note = _makeNote(uuid: 'p1f-empty', title: 'P1-F-Empty');
      await database.storeNote(note);

      final engine = _makeEngine(
        backend: backend,
        database: database,
        dataKey: testDataKey,
      );
      await engine.sync(); // 建立远端 manifest
      backend._backups.clear(); // 模拟 bak 全部丢失（此 fake 首传不产生备份）

      backend._manifestCiphertext = Uint8List.fromList([9, 9, 9, 9]);
      backend._etag = 'corrupt-etag';

      // 无 bak → 本地重建；backupCorruptManifest 把损坏文件移除（F-H01），
      // 因此重建上传必须用空 etag（首传语义），否则会因文件不存在而 412 失败
      final r = await engine.sync();
      expect(r.success, isTrue, reason: '本地重建 + 空 etag 首传必须成功（F-H01）');
      final recoverAction = r.actions.firstWhere(
        (a) => a.uuid == '' && a.type == SyncActionType.skip,
        orElse: () => throw StateError('缺少恢复动作'),
      );
      expect(recoverAction.message, contains('本地重建'));
      // 远端已是可解析的新 manifest，且只含本地笔记
      final remote = await ManifestCrypto.deserialize(
        testDataKey,
        backend._manifestCiphertext!,
      );
      expect(remote.items.keys, contains('p1f-empty'));
    });
  });

  // ────────────────────────────────────────────
  // P0-3：repairRemote blob 缺失 → 本机明文兜底
  // ────────────────────────────────────────────
  group('P0-3 repairRemote blob 缺失兜底', () {
    test('远端 blob 缺失，本机有明文则重传修复', () async {
      final note = _makeNote(
        uuid: 'p03-note',
        title: 'P0-3',
        description: 'hi',
      );
      await database.storeNote(note);

      final engine = _makeEngine(
        backend: backend,
        database: database,
        dataKey: testDataKey,
      );
      await engine.sync(); // 上传 blob + manifest
      expect(backend._blobs.containsKey(note.contentHash), isTrue);

      // 模拟远端 blob 被静默删除
      backend._blobs.remove(note.contentHash);
      expect(backend._blobs.containsKey(note.contentHash), isFalse);

      // 本机仍持有明文 → repairRemote 应自愈补回
      final result = await engine.repairRemote();
      expect(result.success, isTrue);
      expect(
        backend._blobs.containsKey(note.contentHash),
        isTrue,
        reason: '缺失 blob 应被本机明文重传补回',
      );
      expect(result.failedNoteUuids, isNot(contains('p03-note')));
      expect(
        result.actions.any(
          (a) => a.uuid == 'p03-note' && a.type == SyncActionType.heal,
        ),
        isTrue,
        reason: '应记录一次 heal 动作',
      );
    });

    test('远端 blob 缺失且无本机明文：标记失败（不静默丢失）', () async {
      final note = _makeNote(uuid: 'p03-note2', title: 'P0-3b');
      await database.storeNote(note);

      final engine = _makeEngine(
        backend: backend,
        database: database,
        dataKey: testDataKey,
      );
      await engine.sync();
      // 把远端 blob 改写为"存在但无法解密"的损坏内容（而非删除）：
      // 缺失 blob + 无明文是 skip（延期重试），只有"损坏且无法解密 + 无明文"
      // 才会进入 failedNoteUuids。这是"绝不静默丢失"的追踪分支。
      backend._blobs[note.contentHash] = Uint8List.fromList([9, 9, 9, 9, 9]);

      // 软删除本机明文，模拟"任何设备都没有这条笔记的可用明文"
      final stored = await database.readNoteByUuid('p03-note2');
      await database.softDelete(stored!.id!);

      final result = await engine.repairRemote();
      expect(result.success, isTrue);
      // 损坏 blob 且无明文 → 该 uuid 进入 failedNoteUuids（被追踪，而非静默丢弃）
      expect(result.failedNoteUuids, contains('p03-note2'));
    });
  });

  // ────────────────────────────────────────────
  // P0-4：普通下载路径 blob 缺失 → 本机兜底
  // ────────────────────────────────────────────
  group('P0-4 普通下载 blob 缺失兜底', () {
    test('远端 blob 缺失，本机有同内容孪生则自愈重传', () async {
      // 设备 A 上传 note1（blob 在远端）
      final note1 = _makeNote(
        uuid: 'p04-note',
        title: 'P0-4',
        description: 'shared',
      );
      await database.storeNote(note1);
      final engineA = _makeEngine(
        backend: backend,
        database: database,
        dataKey: testDataKey,
      );
      await engineA.sync();
      expect(backend._blobs.containsKey(note1.contentHash), isTrue);

      // 远端 blob 丢失
      backend._blobs.remove(note1.contentHash);

      // 设备 B：本地只有一条"同内容孪生"（不同 uuid），尚未同步
      await database.close();
      final dbB = await openDatabase(
        ':memory:',
        version: 2,
        onCreate: NotesDatabase.createDBForTesting,
      );
      NotesDatabase.setDatabaseForTesting(dbB);
      database.setDataKey(testDataKey);

      final twin = _makeNote(
        uuid: 'p04-twin',
        title: 'P0-4',
        description: 'shared',
      );
      await database.storeNote(twin);

      final engineB = _makeEngine(
        backend: backend,
        database: database,
        dataKey: engineA.keyring.dataKey,
      );
      final result = await engineB.sync();

      expect(result.success, isTrue);
      // 下载 p04-note 时 blob 缺失 → 用孪生明文自愈重传，blob 补回
      expect(
        backend._blobs.containsKey(note1.contentHash),
        isTrue,
        reason: '缺失 blob 应被孪生明文自愈补回',
      );
      expect(result.failedNoteUuids, isNot(contains('p04-note')));
    });
  });

  // ────────────────────────────────────────────
  // P1-1 / P1-2：用真实 LocalFsBackend（落地磁盘）
  // ────────────────────────────────────────────
  group('P1-1 / P1-2 LocalFsBackend 集成', () {
    late Directory dir;
    late LocalFsBackend fsBackend;
    late Uint8List fsKey;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('p1x_');
      fsBackend = LocalFsBackend(rootPath: dir.path);
      await fsBackend.init();
      fsKey = SyncCrypto.generateDataKey();
    });

    tearDown(() async {
      await fsBackend.close();
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    SyncEngine fsEngine(String id) => _makeEngine(
      backend: fsBackend,
      database: database,
      dataKey: fsKey,
      vaultId: 'p1x-keyring',
      deviceId: id,
    );

    test('P1-1 覆盖远端 manifest 前生成可恢复环形备份', () async {
      final engine = fsEngine('p11');
      final note = _makeNote(uuid: 'p11-note', title: 'P1-1');
      await database.storeNote(note);

      // 第一次同步：远端原为空，不备份
      final r1 = await engine.sync();
      expect(r1.success, isTrue);

      // 修改内容再同步 → 覆盖旧 manifest，应触发备份
      final updated = note.copyWith(
        title: 'P1-1 v2',
        contentHash: SafeNote.computeHash('P1-1 v2', 'Test Description'),
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        synced: false,
      );
      await database.updateNoteByUuid(updated);
      final r2 = await engine.sync();
      expect(r2.success, isTrue);

      // 应存在环形备份文件 manifest.bak-*（位于 keyring 的 manifest-backup/ 子目录）
      final backupDir = Directory(p.join(dir.path, 'manifest-backup'));
      expect(
        backupDir.existsSync(),
        isTrue,
        reason: '应创建 manifest-backup/ 子目录',
      );
      final bakFiles = backupDir
          .listSync()
          .whereType<File>()
          .where((f) => p.basename(f.path).startsWith('manifest.bak-'))
          .toList();
      expect(bakFiles.isNotEmpty, isTrue, reason: '应生成 manifest 代际备份');

      // 备份不应污染 keyring 根目录（与 webdav/safeServer 子目录布局一致）
      final rootBak = Directory(dir.path)
          .listSync()
          .whereType<File>()
          .where((f) => p.basename(f.path).startsWith('manifest.bak-'))
          .toList();
      expect(rootBak, isEmpty, reason: '备份文件应只在 manifest-backup/ 子目录');

      final bakBytes = await bakFiles.first.readAsBytes();
      expect(bakBytes.length, greaterThan(0));

      // 备份内容应是"上一代"（含 p11-note 且版本较旧）的有效 manifest，可反序列化
      final oldManifest = await ManifestCrypto.deserialize(fsKey, bakBytes);
      expect(oldManifest.items.containsKey('p11-note'), isTrue);
    });

    test('P1-2 孤儿 blob 软删除到隔离区而非物理删除', () async {
      final engine = fsEngine('p12');
      final note = _makeNote(uuid: 'p12-note', title: 'P1-2');
      await database.storeNote(note);
      await engine.sync(); // 上传 blob + manifest
      expect(
        await File('${dir.path}/blobs/${note.contentHash}').exists(),
        isTrue,
      );

      // 注入一个孤儿 blob（历史遗留，不在 manifest 引用中）
      final orphanHash = 'b' * 64;
      await File('${dir.path}/blobs/$orphanHash').writeAsBytes([7, 7, 7]);

      // 首次同步：P2 两阶段 GC 只登记候选、不隔离（保护「他端正在上传」的窗口）
      final r1 = await engine.sync();
      expect(r1.success, isTrue);
      expect(
        await File('${dir.path}/blobs/$orphanHash').exists(),
        isTrue,
        reason: '两阶段 GC：首次观察只登记候选，不应立即隔离',
      );

      // 再次同步：连续第二次观察仍为孤儿 → 软删除到隔离区
      final r2 = await engine.sync();
      expect(r2.success, isTrue);

      // 孤儿 blob 不应再留在 blobs/，而应进入 blobs-orphan/
      expect(
        await File('${dir.path}/blobs/$orphanHash').exists(),
        isFalse,
        reason: '孤儿 blob 不应被物理删除，应进隔离区',
      );
      final orphans = await fsBackend.listOrphanBlobs();
      expect(orphans, contains(orphanHash), reason: '孤儿 blob 应出现在隔离区');

      // 本端笔记 blob 仍保留
      expect(
        await File('${dir.path}/blobs/${note.contentHash}').exists(),
        isTrue,
      );
    });

    test('P1-2 purgeOrphans 仅清理超期隔离项', () async {
      final orphanDir = Directory('${dir.path}/blobs-orphan');
      await orphanDir.create(recursive: true);
      final oldHash = 'c' * 64;
      final recentHash = 'd' * 64;
      final oldTs = DateTime.now()
          .subtract(const Duration(days: 40))
          .millisecondsSinceEpoch;
      final recentTs = DateTime.now().millisecondsSinceEpoch;
      await File('${orphanDir.path}/$oldHash.$oldTs').writeAsBytes([1]);
      await File('${orphanDir.path}/$recentHash.$recentTs').writeAsBytes([2]);

      await fsBackend.purgeOrphans(const Duration(days: 30));

      expect(
        await File('${orphanDir.path}/$oldHash.$oldTs').exists(),
        isFalse,
        reason: '超期隔离项应被彻底删除',
      );
      expect(
        await File('${orphanDir.path}/$recentHash.$recentTs').exists(),
        isTrue,
        reason: '未超期隔离项应保留',
      );
    });

    // ──────────────────────────────────────────
    // 混沌：随机破坏远端 blob → 自愈或 failedNoteUuids
    // ──────────────────────────────────────────
    test('混沌：随机删掉/翻转远端 blob，repairRemote 自愈补回（绝不静默丢失）', () async {
      for (final seed in const [1, 2, 3, 7, 99]) {
        final rng = Random(seed);
        final engine = fsEngine('chaos-$seed');
        final notes = <SafeNote>[];
        for (var i = 0; i < 3; i++) {
          final n = _makeNote(
            uuid: 'chaos-$seed-n$i',
            title: 'T$i',
            description: 'D$i',
          );
          await database.storeNote(n);
          notes.add(n);
        }
        final r0 = await engine.sync();
        expect(r0.success, isTrue);

        // 随机选一个受害者，删除或翻转其远端 blob
        final victim = notes[rng.nextInt(notes.length)];
        final blobPath = File('${dir.path}/blobs/${victim.contentHash}');
        expect(await blobPath.exists(), isTrue);
        if (rng.nextBool()) {
          await blobPath.delete(); // 删除
        } else {
          final bytes = await blobPath.readAsBytes();
          final flipped = Uint8List.fromList(bytes);
          for (var i = 0; i < flipped.length; i += 7) {
            flipped[i] ^= 0xFF; // 翻转若干字节（损坏 GCM tag）
          }
          await blobPath.writeAsBytes(flipped);
        }

        // 本机持有明文 → repairRemote 应自愈补回
        final r1 = await engine.repairRemote();
        expect(r1.success, isTrue);
        expect(
          await File('${dir.path}/blobs/${victim.contentHash}').exists(),
          isTrue,
          reason: 'seed=$seed 受害者 blob 应被自愈补回',
        );
        expect(
          r1.failedNoteUuids,
          isNot(contains(victim.uuid)),
          reason: 'seed=$seed 有明文应 heal 而非失败',
        );

        // 其余笔记的 blob 未被误伤
        for (final n in notes) {
          expect(
            await File('${dir.path}/blobs/${n.contentHash}').exists(),
            isTrue,
            reason: 'seed=$seed 其余 blob 不应被误伤',
          );
        }
      }
    });

    test('混沌：blob 缺失且无任何设备持有明文 → 进入 failedNoteUuids', () async {
      // 客户端 A 上传一条笔记
      final engineA = fsEngine('chaos-fail-A');
      final note = _makeNote(
        uuid: 'chaos-fail-note',
        title: 'X',
        description: 'Y',
      );
      await database.storeNote(note);
      await engineA.sync();
      expect(
        await File('${dir.path}/blobs/${note.contentHash}').exists(),
        isTrue,
      );

      // 把远端 blob 改写为"存在但无法解密"的损坏内容，并软删除本机明文，
      // 模拟"任何设备都持有不了这条笔记的可用明文"（同一 database，避免切库导致
      // 解密密钥缺失）。
      await File(
        '${dir.path}/blobs/${note.contentHash}',
      ).writeAsBytes([9, 9, 9, 9, 9]);
      final stored = await database.readNoteByUuid('chaos-fail-note');
      await database.softDelete(stored!.id!);

      final r = await engineA.repairRemote();
      expect(r.success, isTrue);
      // 没有任何设备持有明文 → 该 uuid 被追踪（绝不静默丢失）
      expect(r.failedNoteUuids, contains('chaos-fail-note'));
    });
  });
}
