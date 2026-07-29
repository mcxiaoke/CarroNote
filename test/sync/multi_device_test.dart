/*
 * 多设备交互场景测试
 *
 * 验证 P0/P1/P2 修复的核心场景：
 *   - 设备 A 改密码后推送新 encryptedDataKey，设备 B 同步后回写本地 meta（H1）
 *   - 硬删除后下次同步从远端 manifest 清理墓碑，不复活（M1）
 *   - blob hash 校验拒绝内容不一致的信封（M7）
 *   - 多设备并发同步最终一致性
 *
 * 数据库隔离说明：
 *   NotesDatabase 是单例，无法同时持有两个实例。
 *   多设备测试采用 "close → recreate" 模式：
 *     1. 设备 A 用 dbA 操作并同步（数据上传到 FakeBackend）
 *     2. 关闭 dbA
 *     3. 创建 dbB（模拟设备 B 的本地数据库）
 *     4. 设备 B 用 dbB 同步（从 FakeBackend 拉取数据）
 *   FakeBackend 在内存中持久化远端数据，跨设备切换不丢失。
 *
 * 运行：flutter test test/sync/multi_device_test.dart
 */

// Dart 原生导入
import 'dart:convert';
import 'dart:typed_data';

// Package 导入
import 'package:flutter_test/flutter_test.dart';
import 'package:safenotes/data/database_handler.dart';
import 'package:safenotes/models/safenote.dart';
import 'package:safenotes/sync/crypto.dart';
import 'package:safenotes/sync/sync_backend.dart';
import 'package:safenotes/sync/sync_engine.dart';
import 'package:safenotes/sync/sync_models.dart';
import 'package:safenotes/sync/vault.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 测试用 FakeBackend（内存实现，跨设备切换时持久化远端数据）
class FakeBackend implements SyncBackend {
  Uint8List? _manifestCiphertext;
  String _etag = '';
  final Map<String, Uint8List> _blobs = {};

  @override
  String get displayName => 'FakeBackend';

  @override
  String get providerKey => 'fake-multi-device';

  @override
  Future<void> init() async {}

  @override
  Future<({Uint8List ciphertext, String etag})> getManifest() async {
    if (_manifestCiphertext == null) {
      return (ciphertext: Uint8List(0), etag: '');
    }
    return (ciphertext: _manifestCiphertext!, etag: _etag);
  }

  @override
  Future<String> putManifest(Uint8List ciphertext, String expectedEtag) async {
    if (expectedEtag.isEmpty) {
      if (_manifestCiphertext != null) {
        throw ConflictException('manifest already exists');
      }
    } else {
      if (_etag != expectedEtag) {
        throw ConflictException('etag mismatch');
      }
    }
    _manifestCiphertext = ciphertext;
    _etag = 'etag-${DateTime.now().microsecondsSinceEpoch}';
    return _etag;
  }

  @override
  Future<Uint8List?> getBlob(String hash) async => _blobs[hash];

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

  /// 写入篡改过的 blob（用于 M7 测试）
  void putTamperedBlob(String hash, Uint8List data) {
    _blobs[hash] = data;
  }

  @override
  Future<void> close() async {}

  @override
  Future<bool> ping() async => true;

  void reset() {
    _manifestCiphertext = null;
    _etag = '';
    _blobs.clear();
  }
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

/// 构造 SyncEngine
SyncEngine _makeEngine({
  required FakeBackend backend,
  required NotesDatabase database,
  required Uint8List dataKey,
  required String encryptedDataKey,
  String vaultId = 'test-vault-id',
  String deviceId = 'test-device',
  Uint8List? mk,
}) {
  final vault = Vault(
    vaultId: vaultId,
    dataKey: dataKey,
    encryptedDataKey: encryptedDataKey,
    keyFingerprint: '',
    keyVersion: 1,
    kdf: KdfParams.create(salt: SyncCrypto.generateSalt()),
    createdAt: DateTime.now().millisecondsSinceEpoch,
    mk: mk,
  );
  return SyncEngine(
    backend: backend,
    database: database,
    vault: vault,
    deviceId: deviceId,
  );
}

/// 创建 in-memory 数据库并注入为单例
///
/// 每次调用前会先关闭旧数据库（如果存在），确保单例状态干净。
Future<NotesDatabase> _makeDatabase() async {
  // 关闭旧数据库（如果有）
  try {
    await NotesDatabase.instance.close();
  } on Exception {
    // 忽略：首次调用时无数据库
  }
  final db = await openDatabase(
    ':memory:',
    version: 2,
    onCreate: NotesDatabase.createDBForTesting,
  );
  NotesDatabase.setDatabaseForTesting(db);
  return NotesDatabase.instance;
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  // 每个测试后清理数据库单例状态
  tearDown(() async {
    try {
      await NotesDatabase.instance.close();
    } on Exception {
      // 忽略
    }
  });

  group('多设备交互 - H1: 改密码后他端同步回写 encryptedDataKey', () {
    test('设备 A 改密码 → 设备 B 同步后本地 meta 更新为新 encryptedDataKey',
        () async {
      // 场景：
      //   1. 设备 A 和设备 B 共享同一个 vault（相同 dataKey + encryptedDataKey_A）
      //   2. 设备 A 改密码 → 生成新 encryptedDataKey_B（dataKey 不变）
      //   3. 设备 A 同步上传新 manifest（含 encryptedDataKey_B）
      //   4. 设备 B 用新密码登录（派生新 MK），本地 meta 还是旧值 encryptedDataKey_A
      //   5. 设备 B 同步：MK 能解开远端 encryptedDataKey，dataKey 相同
      //      → 只更新本地 encryptedDataKey，不需要 reEncryptAllNotes
      //   6. 验证：设备 B 的本地 meta 中 encrypted_data_key 已更新

      final backend = FakeBackend();

      // 1. 共享 vault 初始化
      final dataKey = SyncCrypto.generateDataKey();
      final salt = SyncCrypto.generateSalt();
      final mkA = SyncCrypto.deriveMasterKey('password-A', salt: salt);
      final encryptedDataKeyA =
          base64.encode(SyncCrypto.wrapDataKey(mkA, dataKey));

      // 设备 A：创建笔记并首次同步
      var db = await _makeDatabase();
      db.setDataKey(dataKey);
      await db.setMeta(MetaKeys.encryptedDataKey, encryptedDataKeyA);
      await db.setMeta(MetaKeys.vaultId, 'test-vault-id');
      var engine = _makeEngine(
        backend: backend,
        database: db,
        dataKey: dataKey,
        encryptedDataKey: encryptedDataKeyA,
        deviceId: 'device-A',
        mk: mkA,
      );
      await db.storeNote(
          _makeNote(uuid: 'uuid-h1', title: 'Note H1', description: 'Desc'));
      await engine.sync();

      // 2. 设备 A 改密码 → 新 MK + 新 encryptedDataKey（dataKey 不变）
      final mkANew = SyncCrypto.deriveMasterKey('password-A-new', salt: salt);
      final encryptedDataKeyANew =
          base64.encode(SyncCrypto.wrapDataKey(mkANew, dataKey));
      await db.setMeta(MetaKeys.encryptedDataKey, encryptedDataKeyANew);
      engine = _makeEngine(
        backend: backend,
        database: db,
        dataKey: dataKey,
        encryptedDataKey: encryptedDataKeyANew,
        deviceId: 'device-A',
        mk: mkANew,
      );

      // 3. 设备 A 同步上传新 manifest（含新 encryptedDataKey）
      final resultA = await engine.sync();
      expect(resultA.success, isTrue, reason: '设备 A 改密码后同步应成功');

      // 4. 设备 B：用新密码登录（派生新 MK），本地 meta 还是旧值 encryptedDataKeyA
      //    模拟用户在设备 B 上输入新密码解锁 vault
      db = await _makeDatabase();
      db.setDataKey(dataKey);
      await db.setMeta(MetaKeys.encryptedDataKey, encryptedDataKeyA);
      await db.setMeta(MetaKeys.vaultId, 'test-vault-id');

      final engineB = _makeEngine(
        backend: backend,
        database: db,
        dataKey: dataKey,
        encryptedDataKey: encryptedDataKeyA,
        deviceId: 'device-B',
        mk: mkANew, // 设备 B 用新密码派生的 MK
      );

      // 5. 设备 B 同步：MK 能解开远端 encryptedDataKey，dataKey 相同 → 只更新本地
      final result = await engineB.sync();
      expect(result.success, isTrue, reason: '设备 B 同步应成功');

      // 6. 验证设备 B 的本地 meta 已更新为新 encryptedDataKey
      final localEncryptedDataKey =
          await db.getMeta(MetaKeys.encryptedDataKey);
      expect(localEncryptedDataKey, equals(encryptedDataKeyANew),
          reason: '设备 B 同步后应把远端 encryptedDataKey 回写本地 meta');
    });
  });

  group('多设备交互 - M1: 硬删除清理远端墓碑', () {
    test('硬删除笔记后同步，远端 manifest 中该 uuid 被移除', () async {
      final backend = FakeBackend();
      final dataKey = SyncCrypto.generateDataKey();
      final salt = SyncCrypto.generateSalt();
      final mk = SyncCrypto.deriveMasterKey('password', salt: salt);
      final encryptedDataKey =
          base64.encode(SyncCrypto.wrapDataKey(mk, dataKey));

      final db = await _makeDatabase();
      db.setDataKey(dataKey);
      await db.setMeta(MetaKeys.encryptedDataKey, encryptedDataKey);
      await db.setMeta(MetaKeys.vaultId, 'test-vault-id');
      final engine = _makeEngine(
        backend: backend,
        database: db,
        dataKey: dataKey,
        encryptedDataKey: encryptedDataKey,
        mk: mk,
      );

      // 创建 2 条笔记并首次同步
      await db.storeNote(_makeNote(uuid: 'uuid-keep', title: 'Keep'));
      await db.storeNote(_makeNote(uuid: 'uuid-purge', title: 'Purge'));
      await engine.sync();

      // 验证远端 manifest 有 2 条
      var remoteManifest = ManifestCrypto.deserialize(
        dataKey,
        (await backend.getManifest()).ciphertext,
      );
      expect(remoteManifest.items.length, 2);

      // 硬删除 note2（从数据库移除，并将 uuid 加入待清理列表）
      final note2Record = await db.readNoteByUuid('uuid-purge');
      await db.hardDelete(note2Record!.id!);

      // 再次同步
      await engine.sync();

      // 验证远端 manifest 中 uuid-purge 被移除
      remoteManifest = ManifestCrypto.deserialize(
        dataKey,
        (await backend.getManifest()).ciphertext,
      );
      expect(remoteManifest.items.containsKey('uuid-purge'), isFalse,
          reason: '硬删除的笔记应从远端 manifest 移除');
      expect(remoteManifest.items.containsKey('uuid-keep'), isTrue);

      // 验证待清理列表已清空
      final purged = await db.getPurgedUuids();
      expect(purged, isEmpty, reason: '同步成功后待清理列表应清空');
    });

    test('硬删除的笔记不会在下次同步时从远端复活', () async {
      final backend = FakeBackend();
      final dataKey = SyncCrypto.generateDataKey();
      final salt = SyncCrypto.generateSalt();
      final mk = SyncCrypto.deriveMasterKey('password', salt: salt);
      final encryptedDataKey =
          base64.encode(SyncCrypto.wrapDataKey(mk, dataKey));

      final db = await _makeDatabase();
      db.setDataKey(dataKey);
      await db.setMeta(MetaKeys.encryptedDataKey, encryptedDataKey);
      await db.setMeta(MetaKeys.vaultId, 'test-vault-id');
      final engine = _makeEngine(
        backend: backend,
        database: db,
        dataKey: dataKey,
        encryptedDataKey: encryptedDataKey,
        mk: mk,
      );

      // 创建并同步一条笔记
      final note =
          await db.storeNote(_makeNote(uuid: 'uuid-revive', title: 'Revive'));
      await engine.sync();

      // 硬删除
      await db.hardDelete(note.id!);
      await engine.sync();

      // 再次同步（模拟下次同步）
      await engine.sync();

      // 验证笔记没有复活
      final notes = await db.readAllNotesIncludingDeleted();
      expect(notes.any((n) => n.uuid == 'uuid-revive'), isFalse,
          reason: '硬删除的笔记不应在后续同步中复活');
    });
  });

  group('多设备交互 - M7: blob hash 校验', () {
    test('下载 blob 内容 hash 不匹配时跳过该笔记', () async {
      final backend = FakeBackend();
      final dataKey = SyncCrypto.generateDataKey();
      final salt = SyncCrypto.generateSalt();
      final mk = SyncCrypto.deriveMasterKey('password', salt: salt);
      final encryptedDataKey =
          base64.encode(SyncCrypto.wrapDataKey(mk, dataKey));

      // 设备 A：创建笔记并同步
      var db = await _makeDatabase();
      db.setDataKey(dataKey);
      await db.setMeta(MetaKeys.encryptedDataKey, encryptedDataKey);
      await db.setMeta(MetaKeys.vaultId, 'test-vault-id');
      final engineA = _makeEngine(
        backend: backend,
        database: db,
        dataKey: dataKey,
        encryptedDataKey: encryptedDataKey,
        mk: mk,
      );
      await db.storeNote(_makeNote(uuid: 'uuid-tamper', title: 'Original'));
      await engineA.sync();

      // 篡改远端 blob：用相同 dataKey 加密不同内容，但保持 hash 不变
      // （模拟服务端返回内容不一致的合法信封）
      final tamperedEnvelope = SyncCrypto.seal(
        dataKey,
        'uuid-tamper',
        Uint8List.fromList(utf8.encode(jsonEncode({
          'title': 'Tampered',
          'description': 'Malicious content',
        }))),
      );
      // 获取原始 manifest 中的 hash
      final remoteManifest = ManifestCrypto.deserialize(
        dataKey,
        (await backend.getManifest()).ciphertext,
      );
      final originalHash = remoteManifest.items['uuid-tamper']!.hash;
      backend.putTamperedBlob(originalHash, tamperedEnvelope);

      // 设备 B：切换数据库
      db = await _makeDatabase();
      db.setDataKey(dataKey);
      await db.setMeta(MetaKeys.encryptedDataKey, encryptedDataKey);
      await db.setMeta(MetaKeys.vaultId, 'test-vault-id');
      final engineB = _makeEngine(
        backend: backend,
        database: db,
        dataKey: dataKey,
        encryptedDataKey: encryptedDataKey,
      );

      final result = await engineB.sync();
      expect(result.success, isTrue);
      expect(result.skipped, greaterThan(0), reason: 'hash 不匹配应跳过下载');

      // 验证设备 B 没有写入篡改的内容
      final note = await db.readNoteByUuid('uuid-tamper');
      expect(note, isNull, reason: 'hash 校验失败时不应写入本地');
    });
  });

  group('多设备交互 - 最终一致性', () {
    test('三台设备交替同步后数据一致', () async {
      // 场景：
      //   设备 A 创建 3 条笔记 → 同步
      //   设备 B 同步 → 获得 A 的 3 条
      //   设备 B 修改 1 条 → 同步
      //   设备 C 同步 → 获得 A 的 3 条（含 B 的修改）
      //   设备 A 同步 → 获得 B 的修改
      //   最终：三台设备数据一致

      final backend = FakeBackend();
      final dataKey = SyncCrypto.generateDataKey();
      final salt = SyncCrypto.generateSalt();
      final mk = SyncCrypto.deriveMasterKey('shared-password', salt: salt);
      final encryptedDataKey =
          base64.encode(SyncCrypto.wrapDataKey(mk, dataKey));

      // 设备 A：创建 3 条笔记
      var db = await _makeDatabase();
      db.setDataKey(dataKey);
      await db.setMeta(MetaKeys.encryptedDataKey, encryptedDataKey);
      await db.setMeta(MetaKeys.vaultId, 'test-vault-id');
      var engine = _makeEngine(
        backend: backend,
        database: db,
        dataKey: dataKey,
        encryptedDataKey: encryptedDataKey,
        deviceId: 'device-A',
        mk: mk,
      );
      await db.storeNote(_makeNote(uuid: 'note-1', title: 'Title 1'));
      await db.storeNote(_makeNote(uuid: 'note-2', title: 'Title 2'));
      await db.storeNote(_makeNote(uuid: 'note-3', title: 'Title 3'));
      await engine.sync();

      // 设备 B：同步获取所有笔记
      db = await _makeDatabase();
      db.setDataKey(dataKey);
      await db.setMeta(MetaKeys.encryptedDataKey, encryptedDataKey);
      await db.setMeta(MetaKeys.vaultId, 'test-vault-id');
      engine = _makeEngine(
        backend: backend,
        database: db,
        dataKey: dataKey,
        encryptedDataKey: encryptedDataKey,
        deviceId: 'device-B',
        mk: mk,
      );
      await engine.sync();

      var notesB = await db.readAllNotes();
      expect(notesB.length, 3);

      // 设备 B：修改 note-2
      final note2 = await db.readNoteByUuid('note-2');
      await db.updateNoteByUuid(note2!.copyWith(
        title: 'Title 2 Modified',
        contentHash: SafeNote.computeHash('Title 2 Modified', 'Test Description'),
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        synced: false,
      ));
      await engine.sync();

      // 设备 C：同步获取所有笔记
      db = await _makeDatabase();
      db.setDataKey(dataKey);
      await db.setMeta(MetaKeys.encryptedDataKey, encryptedDataKey);
      await db.setMeta(MetaKeys.vaultId, 'test-vault-id');
      engine = _makeEngine(
        backend: backend,
        database: db,
        dataKey: dataKey,
        encryptedDataKey: encryptedDataKey,
        deviceId: 'device-C',
        mk: mk,
      );
      await engine.sync();

      final notesC = await db.readAllNotes();
      expect(notesC.length, 3);
      final note2C = await db.readNoteByUuid('note-2');
      expect(note2C!.title, 'Title 2 Modified',
          reason: '设备 C 应获得设备 B 的修改');

      // 设备 A：重新创建并同步获取设备 B 的修改
      db = await _makeDatabase();
      db.setDataKey(dataKey);
      await db.setMeta(MetaKeys.encryptedDataKey, encryptedDataKey);
      await db.setMeta(MetaKeys.vaultId, 'test-vault-id');
      engine = _makeEngine(
        backend: backend,
        database: db,
        dataKey: dataKey,
        encryptedDataKey: encryptedDataKey,
        deviceId: 'device-A',
        mk: mk,
      );
      await engine.sync();
      final note2A = await db.readNoteByUuid('note-2');
      expect(note2A!.title, 'Title 2 Modified',
          reason: '设备 A 应获得设备 B 的修改');

      // 最终一致性验证：设备 A 和 C 的 note-2 内容相同
      expect(note2A.title, equals(note2C.title));
      expect(note2A.title, equals('Title 2 Modified'));
    });
  });

  // ──────────────────────────────────────────────────────────────
  // 场景 d：两设备独立 createNew 后首次同步（相同密码、不同 salt/dataKey）
  //
  // 这是多端 join 的关键场景，之前测试未覆盖：
  //   设备 A 独立 createNew → salt_A / dataKey_A / MK_A
  //   设备 B 独立 createNew → salt_B / dataKey_B / MK_B（相同密码，但 salt 不同）
  //   设备 B 同步时：
  //     - MK_B 解不开远端 encryptedDataKey_A（salt 不同 → MK 不同）
  //     - dataKey_B 解不开远端 manifest items（dataKey 不同）
  //     - 用 keyFingerprint 判别：用远端 salt_A + 密码派生 MK_A，比 fingerprint
  //       → 匹配 → 场景 d：迁移本地数据到远端 dataKey_A
  // ──────────────────────────────────────────────────────────────
  group('多设备交互 - 场景 d：两设备独立 vault 首次同步', () {
    test('相同密码、不同 salt → 迁移本地数据到远端 dataKey 并同步', () async {
      const password = 'test-password-123';
      final backend = FakeBackend();

      // ── 设备 A：独立创建 vault，加 2 条笔记，同步上传 ──
      var db = await _makeDatabase();
      final vaultA = await Vault.createNew(
        password: password,
        database: db,
      );
      db.setDataKey(vaultA.dataKey);

      await db.storeNote(_makeNote(uuid: 'note-a-1', title: 'Note A1'));
      await db.storeNote(_makeNote(uuid: 'note-a-2', title: 'Note A2'));

      final engineA = SyncEngine(
        backend: backend,
        database: db,
        vault: vaultA,
        deviceId: 'device-A',
        passphraseProvider: () => password,
      );
      final resultA = await engineA.sync();
      expect(resultA.success, isTrue, reason: '设备 A 首次同步应成功');
      expect(resultA.uploaded, 2);

      // 保存设备 A 的 vault 参数用于后续验证
      final vaultAVaultId = vaultA.vaultId;
      final vaultASalt = vaultA.kdf.salt;
      final vaultADataKey = vaultA.dataKey;
      final vaultAFingerprint = vaultA.keyFingerprint;

      // ── 设备 B：独立创建 vault（相同密码、不同 salt/dataKey），加 1 条笔记 ──
      db = await _makeDatabase();
      final vaultB = await Vault.createNew(
        password: password,
        database: db,
      );
      db.setDataKey(vaultB.dataKey);

      // 验证前提：两设备 vault 参数确实不同
      expect(vaultB.vaultId, isNot(equals(vaultAVaultId)),
          reason: '独立 vault 应有不同 vaultId');
      expect(vaultB.kdf.salt, isNot(equals(vaultASalt)),
          reason: '独立 vault 应有不同 salt');
      expect(vaultB.dataKey, isNot(equals(vaultADataKey)),
          reason: '独立 vault 应有不同 dataKey');
      expect(vaultB.keyFingerprint, isNot(equals(vaultAFingerprint)),
          reason: '不同 salt → 不同 MK → 不同 fingerprint');

      await db.storeNote(_makeNote(uuid: 'note-b-1', title: 'Note B1'));

      // ── 设备 B 同步：应触发场景 d 迁移 ──
      final engineB = SyncEngine(
        backend: backend,
        database: db,
        vault: vaultB,
        deviceId: 'device-B',
        passphraseProvider: () => password,
      );
      final resultB = await engineB.sync();

      // 验证：同步成功（不是失败）
      expect(resultB.success, isTrue,
          reason: '场景 d：相同密码应迁移成功，而非报 dataKey 迁移失败');
      expect(resultB.migrated, greaterThan(0),
          reason: '应有迁移操作（本地数据重新加密到远端 dataKey）');

      // 验证：设备 B 本地现在有 3 条笔记（A 的 2 条 + B 的 1 条）
      final allNotesB = await db.readAllNotesIncludingDeleted();
      expect(allNotesB.length, 3,
          reason: '迁移 + 同步后，设备 B 应有 A 和 B 的所有笔记');

      // 验证：设备 B 的 vault 元数据已更新为远端（设备 A）的值
      final vaultBAfter = engineB.vault;
      expect(vaultBAfter.vaultId, equals(vaultAVaultId),
          reason: '迁移后 vaultId 应为远端值');
      expect(vaultBAfter.kdf.salt, equals(vaultASalt),
          reason: '迁移后 salt 应为远端值');
      expect(vaultBAfter.dataKey, equals(vaultADataKey),
          reason: '迁移后 dataKey 应为远端值');
      expect(vaultBAfter.keyFingerprint, equals(vaultAFingerprint),
          reason: '迁移后 fingerprint 应为远端值');

      // 验证：远端 manifest 现在包含 3 条笔记
      final remoteManifest = await backend.getManifest();
      final manifest = ManifestCrypto.deserialize(
        vaultADataKey,
        remoteManifest.ciphertext,
      );
      expect(manifest.items.length, 3,
          reason: '远端 manifest 应有 3 条笔记');
      expect(manifest.items.containsKey('note-a-1'), isTrue);
      expect(manifest.items.containsKey('note-a-2'), isTrue);
      expect(manifest.items.containsKey('note-b-1'), isTrue);
    });

    test('不同密码 → 同步失败，提示密码不匹配', () async {
      const passwordA = 'password-A';
      const passwordB = 'password-B';
      final backend = FakeBackend();

      // 设备 A 创建 vault 并同步
      var db = await _makeDatabase();
      final vaultA = await Vault.createNew(
        password: passwordA,
        database: db,
      );
      db.setDataKey(vaultA.dataKey);
      await db.storeNote(_makeNote(uuid: 'note-a-1', title: 'Note A1'));

      final engineA = SyncEngine(
        backend: backend,
        database: db,
        vault: vaultA,
        deviceId: 'device-A',
        passphraseProvider: () => passwordA,
      );
      await engineA.sync();

      // 设备 B 用不同密码创建 vault
      db = await _makeDatabase();
      final vaultB = await Vault.createNew(
        password: passwordB,
        database: db,
      );
      db.setDataKey(vaultB.dataKey);

      final engineB = SyncEngine(
        backend: backend,
        database: db,
        vault: vaultB,
        deviceId: 'device-B',
        passphraseProvider: () => passwordB,
      );
      final resultB = await engineB.sync();

      // 验证：同步失败（密码不匹配）
      expect(resultB.success, isFalse,
          reason: '不同密码应同步失败');
      expect(resultB.errorMessage, contains('密码'),
          reason: '错误信息应提示密码不匹配');
    });
  });
}
