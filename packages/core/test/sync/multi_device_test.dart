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
import 'package:test/test.dart';
import 'package:core/core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// 测试公共支撑（P2：Keyring/Journal 构造 + FakeBackend journal 存储）
import 'sync_test_support.dart';

/// 测试用 FakeBackend（内存实现，跨设备切换时持久化远端数据）
class FakeBackend with FakeJournalStore implements SyncBackend {
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

  @override
  Future<List<String>> listManifestBackups() async => [];

  @override
  Future<Uint8List?> readManifestBackup(String name) async => null;

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

  @override
  Future<void> deleteBlobSoft(String hash) async => deleteBlob(hash);

  @override
  Future<List<String>> listOrphanBlobs() async => [];

  @override
  Future<void> purgeOrphans(Duration retention) async {}

  @override
  Future<void> backupManifest([Uint8List? currentManifestBytes]) async {}
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
  String vaultId = 'test-keyring-id',
  String deviceId = 'test-device',
  Uint8List? mk,
  int keyVersion = 1,
}) {
  final keyring = makeTestKeyring(
    vaultId: vaultId,
    dataKey: dataKey,
    encryptedDataKey: encryptedDataKey,
    keyFingerprint: '',
    keyVersion: keyVersion,
    kdf: KdfParams.create(salt: SyncCrypto.generateSalt()),
    createdAt: DateTime.now().millisecondsSinceEpoch,
    mk: mk,
  );
  return SyncEngine(
    backend: backend,
    database: database,
    keyring: keyring,
    deviceId: deviceId,
    journal: makeTestJournal(),
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

  group('多设备交互 - H1: 改密码后他端同步（v4：scenario-b 中止 + 只读不 echo）', () {
    test('设备 A 改密码推送成功；设备 B 旧密码同步中止；B 用新密码登录后正常', () async {
      // 场景：
      //   1. 设备 A 和设备 B 共享同一个 keyring（相同 dataKey + encryptedDataKey_A）
      //   2. 设备 A 改密码 → 新 MK + 新 encryptedDataKey（dataKey 不变，keyVersion 2）
      //   3. 设备 A 同步上传新 manifest（本端改密码未推送 → 推送本地新包裹）
      //   4. 设备 B 旧密码会话同步 → v4 scenario-b：中止 + 提示重登录
      //   5. 设备 B 用新密码登录（派生新 MK）→ 同步正常
      //   6. v4 只读不 echo：B 本地账本保持自己的包裹（两端包裹都合法）

      final backend = FakeBackend();

      // 1. 共享 keyring 初始化
      final dataKey = SyncCrypto.generateDataKey();
      final salt = SyncCrypto.generateSalt();
      final mkA = await SyncCrypto.deriveMasterKey('password-A', salt: salt);
      final encryptedDataKeyA = base64.encode(
        await SyncCrypto.wrapDataKey(mkA, dataKey),
      );

      // 设备 A：创建笔记并首次同步
      var db = await _makeDatabase();
      db.setDataKey(dataKey);
      await persistTestKeyring(db, encryptedDataKey: encryptedDataKeyA);
      var engine = _makeEngine(
        backend: backend,
        database: db,
        dataKey: dataKey,
        encryptedDataKey: encryptedDataKeyA,
        deviceId: 'device-A',
        mk: mkA,
      );
      await db.storeNote(
        _makeNote(uuid: 'uuid-h1', title: 'Note H1', description: 'Desc'),
      );
      await engine.sync();

      // 2. 设备 A 改密码 → 新 MK + 新 encryptedDataKey（dataKey 不变，keyVersion 2）
      final mkANew = await SyncCrypto.deriveMasterKey(
        'password-A-new',
        salt: salt,
      );
      final encryptedDataKeyANew = base64.encode(
        await SyncCrypto.wrapDataKey(mkANew, dataKey),
      );
      await persistTestKeyring(
        db,
        encryptedDataKey: encryptedDataKeyANew,
        keyVersion: 2,
      );
      engine = _makeEngine(
        backend: backend,
        database: db,
        dataKey: dataKey,
        encryptedDataKey: encryptedDataKeyANew,
        deviceId: 'device-A',
        mk: mkANew,
        keyVersion: 2,
      );

      // 3. 设备 A 同步：本端改密码未推送（远端 kv=1 < 本地 kv=2）→ 推送本地新包裹
      final resultA = await engine.sync();
      expect(resultA.success, isTrue, reason: '设备 A 改密码后同步应成功');

      // 4. 设备 B：旧密码会话同步 → v4 scenario-b 中止（本地 MK 解不开远端新包裹）
      db = await _makeDatabase();
      db.setDataKey(dataKey);
      await persistTestKeyring(db, encryptedDataKey: encryptedDataKeyA);
      final engineBOld = _makeEngine(
        backend: backend,
        database: db,
        dataKey: dataKey,
        encryptedDataKey: encryptedDataKeyA,
        deviceId: 'device-B',
        mk: mkA, // 旧密码派生的 MK
      );
      final resultBOld = await engineBOld.sync();
      expect(
        resultBOld.success,
        isFalse,
        reason: 'B 旧密码会话同步应中止（scenario-b，他端改了密码）',
      );
      expect(resultBOld.errorMessage, contains('密码已在其他设备修改'));

      // 5. 设备 B 用新密码登录（派生新 MK），本地 meta 仍为旧包裹
      //    模拟真实 login 流程：新密码经远端验证后覆盖本地账本为远端新包裹
      await persistTestKeyring(
        db,
        encryptedDataKey: encryptedDataKeyANew,
        keyVersion: 2,
      );
      final engineB = _makeEngine(
        backend: backend,
        database: db,
        dataKey: dataKey,
        encryptedDataKey: encryptedDataKeyANew,
        deviceId: 'device-B',
        mk: mkANew, // 新密码派生的 MK
        keyVersion: 2,
      );
      final result = await engineB.sync();
      expect(result.success, isTrue, reason: '设备 B 新密码会话同步应成功');

      // 6. v4 只读不 echo：B 本地账本已是远端一致值（登录时覆盖），
      //    同步不再回写任何东西
      final localEncryptedDataKey = await persistedEncryptedDataKey(db);
      expect(
        localEncryptedDataKey,
        equals(encryptedDataKeyANew),
        reason: 'B 本地账本保持登录时采用的新包裹（同步零写入）',
      );
    });
  });

  group('多设备交互 - M1: 硬删除清理远端墓碑', () {
    test('硬删除笔记后同步，远端 manifest 中该 uuid 被移除', () async {
      final backend = FakeBackend();
      final dataKey = SyncCrypto.generateDataKey();
      final salt = SyncCrypto.generateSalt();
      final mk = await SyncCrypto.deriveMasterKey('password', salt: salt);
      final encryptedDataKey = base64.encode(
        await SyncCrypto.wrapDataKey(mk, dataKey),
      );

      final db = await _makeDatabase();
      db.setDataKey(dataKey);
      await persistTestKeyring(db, encryptedDataKey: encryptedDataKey);
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
      var remoteManifest = await ManifestCrypto.deserialize(
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
      remoteManifest = await ManifestCrypto.deserialize(
        dataKey,
        (await backend.getManifest()).ciphertext,
      );
      expect(
        remoteManifest.items.containsKey('uuid-purge'),
        isFalse,
        reason: '硬删除的笔记应从远端 manifest 移除',
      );
      expect(remoteManifest.items.containsKey('uuid-keep'), isTrue);

      // 验证待清理列表已清空
      final purged = await db.getPurgedUuids();
      expect(purged, isEmpty, reason: '同步成功后待清理列表应清空');
    });

    test('硬删除的笔记不会在下次同步时从远端复活', () async {
      final backend = FakeBackend();
      final dataKey = SyncCrypto.generateDataKey();
      final salt = SyncCrypto.generateSalt();
      final mk = await SyncCrypto.deriveMasterKey('password', salt: salt);
      final encryptedDataKey = base64.encode(
        await SyncCrypto.wrapDataKey(mk, dataKey),
      );

      final db = await _makeDatabase();
      db.setDataKey(dataKey);
      await persistTestKeyring(db, encryptedDataKey: encryptedDataKey);
      final engine = _makeEngine(
        backend: backend,
        database: db,
        dataKey: dataKey,
        encryptedDataKey: encryptedDataKey,
        mk: mk,
      );

      // 创建并同步一条笔记
      final note = await db.storeNote(
        _makeNote(uuid: 'uuid-revive', title: 'Revive'),
      );
      await engine.sync();

      // 硬删除
      await db.hardDelete(note.id!);
      await engine.sync();

      // 再次同步（模拟下次同步）
      await engine.sync();

      // 验证笔记没有复活
      final notes = await db.readAllNotesIncludingDeleted();
      expect(
        notes.any((n) => n.uuid == 'uuid-revive'),
        isFalse,
        reason: '硬删除的笔记不应在后续同步中复活',
      );
    });
  });

  // ────────────────────────────────────────────────────────────
  // BUG-P0 回归：删除不得被「冲突副本保留」机制复活
  //
  // 缺陷背景（由长期存续测试 temp/longrun-store 实测暴露）：
  //   _itemsEqual 只比较 hash + deleted，因此「一端已删、另一端仍活跃」
  //   （hash 相同、deleted 不同）也会进入冲突分支；而旧实现的副本保留
  //   条件只判 `timeDiff > 5 分钟`，于是被删内容被另存为新 uuid 的**活跃**
  //   笔记。每台设备各复活一份，副本再被删又再复活，形成无限增殖——
  //   实测一条墓碑最终派生出 9 条活跃副本。
  //
  // 删除时刻与内容最后修改时刻天然相差远超 5 分钟，因此这条路径在真实
  // 使用中几乎必然触发，属数据正确性 P0。
  // ────────────────────────────────────────────────────────────
  group('多设备交互 - BUG-P0: 删除不被冲突副本机制复活', () {
    test('本地删除 + 远端仍活跃（时间差超阈值）→ 不得产生新 uuid 的活跃副本', () async {
      final backend = FakeBackend();
      final dataKey = SyncCrypto.generateDataKey();
      final salt = SyncCrypto.generateSalt();
      final mk = await SyncCrypto.deriveMasterKey('password', salt: salt);
      final encryptedDataKey = base64.encode(
        await SyncCrypto.wrapDataKey(mk, dataKey),
      );

      final db = await _makeDatabase();
      db.setDataKey(dataKey);
      await persistTestKeyring(db, encryptedDataKey: encryptedDataKey);
      final engine = _makeEngine(
        backend: backend,
        database: db,
        dataKey: dataKey,
        encryptedDataKey: encryptedDataKey,
        mk: mk,
      );

      // 1) 一条 10 分钟前写入的笔记，先同步上去（远端记为活跃）
      final tenMinAgo = DateTime.now().millisecondsSinceEpoch - 10 * 60 * 1000;
      final note = await db.storeNote(
        _makeNote(uuid: 'uuid-del', title: 'ToDelete', updatedAt: tenMinAgo),
      );
      await engine.sync();

      // 2) 用户删除它（softDelete 把 updatedAt 刷成当前时刻）
      //    此时本地 deleted=true/t=now，远端 deleted=false/t=now-10min，
      //    hash 相同、deleted 不同、时间差 10 分钟 > 5 分钟阈值。
      await db.softDelete(note.id!);
      await engine.sync();

      // 3) 删除必须真正生效：本地不得残留任何活跃笔记
      final live = await db.readAllNotes();
      expect(
        live,
        isEmpty,
        reason:
            '删除被冲突副本机制复活：本地出现了 ${live.length} 条活跃笔记 '
            '${live.map((n) => n.uuid).toList()}',
      );

      // 4) 远端 manifest 里只应有这一条墓碑，不得多出活跃条目
      final remote = await ManifestCrypto.deserialize(
        dataKey,
        (await backend.getManifest()).ciphertext,
      );
      final remoteLive = remote.items.entries
          .where((e) => !e.value.deleted)
          .toList();
      expect(
        remoteLive,
        isEmpty,
        reason: '远端出现复活副本：${remoteLive.map((e) => e.key).toList()}',
      );
      expect(
        remote.items['uuid-del']?.deleted,
        isTrue,
        reason: '墓碑必须保留，供其他设备同步到这次删除',
      );

      // 5) 反复同步不得再生出副本（增殖是原缺陷最致命的表现）
      await engine.sync();
      await engine.sync();
      expect(await db.readAllNotes(), isEmpty, reason: '多次同步后仍不得出现复活副本');
    });

    test('双方都活跃且内容真分叉 → 仍必须保留败方副本（防止修复过度）', () async {
      // 忠实还原「两台设备从共同祖先离线分叉」：
      //   单例数据库无法同时持有两台设备，且 base hash 修复后，只有真正
      //   偏离共同祖先才保留副本。因此这里显式设 synced_hash=共同祖先 v1，
      //   在一台库上重建设备 B 的视角：它上次同步收敛在 v1，之后离线改成
      //   v3；与此同时远端已被另一台设备推进到 v2。两条分支都偏离 base=v1
      //   → 真并发冲突，必须保留败方副本（这是防止「修复过度」的护栏：
      //   base hash 判据不能把合法的真分叉也一并吞掉）。
      final backend = FakeBackend();
      final dataKey = SyncCrypto.generateDataKey();
      final salt = SyncCrypto.generateSalt();
      final mk = await SyncCrypto.deriveMasterKey('password', salt: salt);
      final encryptedDataKey = base64.encode(
        await SyncCrypto.wrapDataKey(mk, dataKey),
      );

      final db = await _makeDatabase();
      db.setDataKey(dataKey);
      await persistTestKeyring(db, encryptedDataKey: encryptedDataKey);
      final engine = _makeEngine(
        backend: backend,
        database: db,
        dataKey: dataKey,
        encryptedDataKey: encryptedDataKey,
        mk: mk,
      );

      // 共同祖先 v1 的 hash —— 两条分支的 base。
      final baseHash = SafeNote.computeHash('Fork', 'v1');

      // 1) 远端：另一台设备把 v1 推进到了 v2。
      //    先建 v1 同步（远端=v1），再改成 v2 同步（远端=v2），制造既成事实。
      await db.storeNote(
        _makeNote(
          uuid: 'uuid-fork',
          title: 'Fork',
          description: 'v1',
          updatedAt: DateTime.now().millisecondsSinceEpoch - 20 * 60 * 1000,
        ),
      );
      await engine.sync();
      final toV2 = (await db.readNoteByUuid('uuid-fork'))!.copyWith(
        description: 'v2',
        contentHash: SafeNote.computeHash('Fork', 'v2'),
        updatedAt: DateTime.now().millisecondsSinceEpoch - 5 * 60 * 1000,
        synced: false,
      );
      await db.updateNoteByUuid(toV2);
      await engine.sync(); // 远端此刻为 v2

      // 2) 把本地库改写成「设备 B 的视角」：上次同步收敛在共同祖先 v1
      //    （synced_hash=v1），此后离线把内容改成 v3、尚未同步。
      //    v3 的 updatedAt 比 v2 新 → LWW 里 v3 胜、v2 是败方。
      final existing = (await db.readNoteByUuid('uuid-fork'))!;
      await db.updateNoteByUuid(
        SafeNote(
          id: existing.id,
          uuid: 'uuid-fork',
          title: 'Fork',
          description: 'v3',
          contentHash: SafeNote.computeHash('Fork', 'v3'),
          deleted: false,
          createdTime: existing.createdTime,
          updatedAt: DateTime.now().millisecondsSinceEpoch - 1 * 60 * 1000,
          synced: false,
          syncedHash: baseHash, // 关键：共同祖先 = v1（真三方合并 base）
        ),
      );
      await engine.sync();

      // 3) 真并发：v3 胜（updatedAt 更新），败方 v2 必须以【新 uuid】保留，绝不丢。
      final live = await db.readAllNotes();
      expect(live.length, 2, reason: '真实内容分叉时应保留败方副本，实际活跃 ${live.length} 条');
      expect(live.map((n) => n.description).toSet(), {
        'v2',
        'v3',
      }, reason: '胜方 v3 与败方 v2 都应存在');
      expect(
        live.where((n) => n.uuid == 'uuid-fork').single.description,
        'v3',
        reason: '原 uuid 应持有 LWW 胜方内容',
      );
      // 败方必须是【新 uuid】的独立副本（拷贝语义），不能顶掉原 uuid。
      final copy = live.where((n) => n.uuid != 'uuid-fork').single;
      expect(copy.description, 'v2', reason: '败方 v2 必须作为独立副本保留');
    });
  });

  // ────────────────────────────────────────────────────────────
  // BUG-P0-2 回归：冲突判定不能用「时间差」近似
  //
  // 缺陷背景（由长期存续测试 temp/longrun-store 实测暴露）：
  //   副本保留条件是 `timeDiff > 5 分钟`，注释自称「差值 <= 5 分钟视为
  //   并发编辑」。但时间差衡量的是内容新旧，与「是否并发」毫无关系，
  //   于是两个方向同时出错：
  //     1. 单边编辑一条历史笔记（时间差天然很大）被判成真冲突，每台
  //        设备各把自己手上的旧版本另存为新 uuid → 无限增殖。长期库
  //        实测每代稳定 +3 条（三端各一份），活跃数 10 代从 140 涨到 179。
  //     2. 真并发编辑（两端先后几十秒各改一次，时间差很小）被判成
  //        「并发编辑」走 LWW 覆盖 → 败方内容静默丢失。
  //
  // 正确判据是「双方是否都偏离了共同祖先」，需要 base/synced hash，
  // 与时间差无关。以下两个用例分别锁死这两个方向。
  // ────────────────────────────────────────────────────────────
  group('多设备交互 - BUG-P0-2: 冲突判定不得用时间差近似', () {
    test('单边编辑历史笔记 → 不得把旧版本另存为副本', () async {
      final backend = FakeBackend();
      final dataKey = SyncCrypto.generateDataKey();
      final salt = SyncCrypto.generateSalt();
      final mk = await SyncCrypto.deriveMasterKey('password', salt: salt);
      final encryptedDataKey = base64.encode(
        await SyncCrypto.wrapDataKey(mk, dataKey),
      );

      final db = await _makeDatabase();
      db.setDataKey(dataKey);
      await persistTestKeyring(db, encryptedDataKey: encryptedDataKey);
      final engine = _makeEngine(
        backend: backend,
        database: db,
        dataKey: dataKey,
        encryptedDataKey: encryptedDataKey,
        deviceId: 'device-A',
        mk: mk,
      );

      // 1) 30 分钟前建的笔记，已同步：远端与本地完全一致，无任何分歧
      final thirtyMinAgo =
          DateTime.now().millisecondsSinceEpoch - 30 * 60 * 1000;
      await db.storeNote(
        _makeNote(
          uuid: 'uuid-edit',
          title: 'Note',
          description: 'v1',
          updatedAt: thirtyMinAgo,
        ),
      );
      // 首次同步收敛后，markAllSynced 会把 synced_hash 回填为 v1 的 content_hash。
      await engine.sync();

      // 2) 用户在这台设备上编辑它 —— 纯粹的单边更新，不存在任何并发。
      //    远端的 v1 是 v2 的祖先，不是并行分支。
      //    关键：必须像生产 editor_state.updateNote 那样用 copyWith 编辑，
      //    保留首次同步收敛时写入的 syncedHash（v1 的 hash）作为共同祖先 base。
      //    若像旧写法直接 new 一个 SafeNote，会把 base 抹成 null，退化成
      //    「保守保留副本」逻辑 —— 那测的是 null 兜底，不是真实单边判定。
      final edited = (await db.readNoteByUuid('uuid-edit'))!.copyWith(
        description: 'v2',
        contentHash: SafeNote.computeHash('Note', 'v2'),
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        synced: false,
      );
      await db.updateNoteByUuid(edited);
      await engine.sync();

      // 3) 编辑一条笔记不该凭空多出一条笔记
      final live = await db.readAllNotes();
      expect(
        live.length,
        1,
        reason:
            '单边编辑被误判为冲突，旧版本被另存为副本：'
            '${live.map((n) => "${n.uuid.substring(0, 8)}/${n.description}").toList()}',
      );
      expect(live.single.description, 'v2');

      // 4) 反复同步同样不得增殖
      await engine.sync();
      await engine.sync();
      expect((await db.readAllNotes()).length, 1, reason: '多次同步后仍不得出现旧版本副本');
    });

    test('真并发编辑（时间差小于旧阈值）→ 败方内容不得静默丢失', () async {
      // 复现旧缺陷方向 2：两端几乎同时（时间差 < 5 分钟旧阈值）各自从共同
      // 祖先分叉。旧实现按「时间差小 = 并发编辑走 LWW 覆盖」把败方静默丢弃。
      // base hash 判据下，只要双方都偏离共同祖先就必须保留副本，与时间差无关。
      //
      // 单例数据库无法同时持有两台真设备，故沿用 471 的忠实构造：显式设
      // synced_hash=共同祖先 v1，在一台库上重建「设备 B 从 v1 离线分叉到 v3」
      // 的视角，同时远端已被另一台设备推进到 v2，且 v2/v3 时间差仅 1 分钟。
      final backend = FakeBackend();
      final dataKey = SyncCrypto.generateDataKey();
      final salt = SyncCrypto.generateSalt();
      final mk = await SyncCrypto.deriveMasterKey('password', salt: salt);
      final encryptedDataKey = base64.encode(
        await SyncCrypto.wrapDataKey(mk, dataKey),
      );

      final db = await _makeDatabase();
      db.setDataKey(dataKey);
      await persistTestKeyring(db, encryptedDataKey: encryptedDataKey);
      final engine = _makeEngine(
        backend: backend,
        database: db,
        dataKey: dataKey,
        encryptedDataKey: encryptedDataKey,
        deviceId: 'device-B',
        mk: mk,
      );

      // 共同祖先 v1 的 hash —— 两条并发分支的 base。
      final baseHash = SafeNote.computeHash('Race', 'v1');

      // 1) 远端：另一台设备把 v1 推进到 v2（2 分钟前）。
      await db.storeNote(
        _makeNote(
          uuid: 'uuid-race',
          title: 'Race',
          description: 'v1',
          updatedAt: DateTime.now().millisecondsSinceEpoch - 20 * 60 * 1000,
        ),
      );
      await engine.sync();
      final toV2 = (await db.readNoteByUuid('uuid-race'))!.copyWith(
        description: 'v2',
        contentHash: SafeNote.computeHash('Race', 'v2'),
        updatedAt: DateTime.now().millisecondsSinceEpoch - 2 * 60 * 1000,
        synced: false,
      );
      await db.updateNoteByUuid(toV2);
      await engine.sync(); // 远端此刻为 v2

      // 2) 本地改写成「设备 B 视角」：base=v1，离线改成 v3（1 分钟前）。
      //    v2 与 v3 只差 1 分钟——旧阈值下会被误判为「并发编辑」而 LWW 覆盖。
      final existing = (await db.readNoteByUuid('uuid-race'))!;
      await db.updateNoteByUuid(
        SafeNote(
          id: existing.id,
          uuid: 'uuid-race',
          title: 'Race',
          description: 'v3',
          contentHash: SafeNote.computeHash('Race', 'v3'),
          deleted: false,
          createdTime: existing.createdTime,
          updatedAt: DateTime.now().millisecondsSinceEpoch - 60 * 1000,
          synced: false,
          syncedHash: baseHash, // 关键：共同祖先 = v1
        ),
      );
      await engine.sync();

      // 两份并发修改都必须活下来，一个字都不能丢
      final live = await db.readAllNotes();
      final bodies = live.map((n) => n.description).toSet();
      expect(
        bodies.containsAll({'v2', 'v3'}),
        isTrue,
        reason: '并发编辑被 LWW 静默覆盖，丢失了一方内容。当前存活：$bodies',
      );
    });
  });

  // ────────────────────────────────────────────────────────────
  // F1 回归：30 天墓碑 GC（独立审查报告 P3 指出的测试缺口）
  //
  // 长期存续测试里删除的都是「近期删除」，永远够不到 30 天阈值，
  // 因此 I3 只验证了「近期墓碑不丢」，从未验证「超期墓碑被清除」。
  // 这里不引入时间源抽象，直接把墓碑的 updatedAt 写成 31 天前，
  // 用真实时钟触发 _buildLocalManifest 中的 GC 分支。
  // ────────────────────────────────────────────────────────────
  group('多设备交互 - F1: 超期墓碑 GC', () {
    test('墓碑超过 30 天 → 硬删本地记录、移出 manifest 且不复活', () async {
      final backend = FakeBackend();
      final dataKey = SyncCrypto.generateDataKey();
      final salt = SyncCrypto.generateSalt();
      final mk = await SyncCrypto.deriveMasterKey('password', salt: salt);
      final encryptedDataKey = base64.encode(
        await SyncCrypto.wrapDataKey(mk, dataKey),
      );

      final db = await _makeDatabase();
      db.setDataKey(dataKey);
      await persistTestKeyring(db, encryptedDataKey: encryptedDataKey);
      final engine = _makeEngine(
        backend: backend,
        database: db,
        dataKey: dataKey,
        encryptedDataKey: encryptedDataKey,
        mk: mk,
      );

      // 1) 两条笔记：一条留着当对照，一条将成为超期墓碑
      final keep = await db.storeNote(_makeNote(uuid: 'uuid-alive'));
      final old = await db.storeNote(
        _makeNote(uuid: 'uuid-old-tomb', title: 'OldTomb'),
      );
      await engine.sync();

      // 2) 把 uuid-old-tomb 改成「31 天前删除」的墓碑
      final thirtyOneDaysAgo = DateTime.now()
          .subtract(const Duration(days: 31))
          .millisecondsSinceEpoch;
      await db.updateNoteByUuid(
        SafeNote(
          id: old.id,
          uuid: 'uuid-old-tomb',
          title: 'OldTomb',
          description: old.description,
          contentHash: old.contentHash,
          deleted: true,
          createdTime: old.createdTime,
          updatedAt: thirtyOneDaysAgo,
          synced: true,
        ),
      );

      // 3) 同步：GC 应在构建本地 manifest 时触发
      await engine.sync();

      final all = await db.readAllNotesIncludingDeleted();
      expect(
        all.any((n) => n.uuid == 'uuid-old-tomb'),
        isFalse,
        reason: '超期墓碑应被硬删除，否则墓碑会无限累积',
      );
      expect(
        all.any((n) => n.uuid == 'uuid-alive'),
        isTrue,
        reason: '未超期的活跃笔记不得被误删',
      );

      final remote = await ManifestCrypto.deserialize(
        dataKey,
        (await backend.getManifest()).ciphertext,
      );
      expect(
        remote.items.containsKey('uuid-old-tomb'),
        isFalse,
        reason: '超期墓碑应从远端 manifest 移除',
      );
      expect(remote.items.containsKey('uuid-alive'), isTrue);

      // 4) 再次同步不得让它从远端复活（purgedUuids 兜底）
      await engine.sync();
      final after = await db.readAllNotesIncludingDeleted();
      expect(
        after.any((n) => n.uuid == 'uuid-old-tomb'),
        isFalse,
        reason: 'GC 掉的墓碑不得在后续同步中复活',
      );
      expect(keep.uuid, 'uuid-alive');
    });

    test('墓碑未超过 30 天 → 必须保留，供离线设备同步到删除', () async {
      final backend = FakeBackend();
      final dataKey = SyncCrypto.generateDataKey();
      final salt = SyncCrypto.generateSalt();
      final mk = await SyncCrypto.deriveMasterKey('password', salt: salt);
      final encryptedDataKey = base64.encode(
        await SyncCrypto.wrapDataKey(mk, dataKey),
      );

      final db = await _makeDatabase();
      db.setDataKey(dataKey);
      await persistTestKeyring(db, encryptedDataKey: encryptedDataKey);
      final engine = _makeEngine(
        backend: backend,
        database: db,
        dataKey: dataKey,
        encryptedDataKey: encryptedDataKey,
        mk: mk,
      );

      // 笔记本身写于 30 天前，这样后面「29 天前删除」在 LWW 里才是更新的
      // 一方（否则远端那份 updatedAt=同步时刻的活跃条目会赢，把墓碑覆盖掉）。
      final note = await db.storeNote(
        _makeNote(
          uuid: 'uuid-fresh-tomb',
          title: 'FreshTomb',
          updatedAt: DateTime.now()
              .subtract(const Duration(days: 30))
              .millisecondsSinceEpoch,
        ),
      );
      await engine.sync();

      // 29 天前删除 —— 差一天到阈值，必须留着
      final twentyNineDaysAgo = DateTime.now()
          .subtract(const Duration(days: 29))
          .millisecondsSinceEpoch;
      await db.updateNoteByUuid(
        SafeNote(
          id: note.id,
          uuid: 'uuid-fresh-tomb',
          title: 'FreshTomb',
          description: note.description,
          contentHash: note.contentHash,
          deleted: true,
          createdTime: note.createdTime,
          updatedAt: twentyNineDaysAgo,
          synced: true,
        ),
      );
      await engine.sync();

      final remote = await ManifestCrypto.deserialize(
        dataKey,
        (await backend.getManifest()).ciphertext,
      );
      expect(
        remote.items['uuid-fresh-tomb']?.deleted,
        isTrue,
        reason: '未超期墓碑必须保留在 manifest，否则离线设备收不到删除',
      );
    });
  });

  group('多设备交互 - M7: blob hash 校验', () {
    test('下载 blob 内容 hash 不匹配时跳过该笔记', () async {
      final backend = FakeBackend();
      final dataKey = SyncCrypto.generateDataKey();
      final salt = SyncCrypto.generateSalt();
      final mk = await SyncCrypto.deriveMasterKey('password', salt: salt);
      final encryptedDataKey = base64.encode(
        await SyncCrypto.wrapDataKey(mk, dataKey),
      );

      // 设备 A：创建笔记并同步
      var db = await _makeDatabase();
      db.setDataKey(dataKey);
      await persistTestKeyring(db, encryptedDataKey: encryptedDataKey);
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
      // （模拟服务端返回内容不一致的合法信封）。
      // 注意：blob 纯化 v4 后 AAD = hash，信封必须能被解开，内容 hash 才会被比对。
      final remoteManifest = await ManifestCrypto.deserialize(
        dataKey,
        (await backend.getManifest()).ciphertext,
      );
      final originalHash = remoteManifest.items['uuid-tamper']!.hash;
      final tamperedEnvelope = await SyncCrypto.seal(
        dataKey,
        originalHash,
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'title': 'Tampered',
              'description': 'Malicious content',
            }),
          ),
        ),
      );
      backend.putTamperedBlob(originalHash, tamperedEnvelope);

      // 设备 B：切换数据库
      db = await _makeDatabase();
      db.setDataKey(dataKey);
      await persistTestKeyring(db, encryptedDataKey: encryptedDataKey);
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
      final mk = await SyncCrypto.deriveMasterKey(
        'shared-password',
        salt: salt,
      );
      final encryptedDataKey = base64.encode(
        await SyncCrypto.wrapDataKey(mk, dataKey),
      );

      // 设备 A：创建 3 条笔记
      var db = await _makeDatabase();
      db.setDataKey(dataKey);
      await persistTestKeyring(db, encryptedDataKey: encryptedDataKey);
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
      await persistTestKeyring(db, encryptedDataKey: encryptedDataKey);
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
      await db.updateNoteByUuid(
        note2!.copyWith(
          title: 'Title 2 Modified',
          contentHash: SafeNote.computeHash(
            'Title 2 Modified',
            'Test Description',
          ),
          updatedAt: DateTime.now().millisecondsSinceEpoch,
          synced: false,
        ),
      );
      await engine.sync();

      // 设备 C：同步获取所有笔记
      db = await _makeDatabase();
      db.setDataKey(dataKey);
      await persistTestKeyring(db, encryptedDataKey: encryptedDataKey);
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
      expect(note2C!.title, 'Title 2 Modified', reason: '设备 C 应获得设备 B 的修改');

      // 设备 A：重新创建并同步获取设备 B 的修改
      db = await _makeDatabase();
      db.setDataKey(dataKey);
      await persistTestKeyring(db, encryptedDataKey: encryptedDataKey);
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
      expect(note2A!.title, 'Title 2 Modified', reason: '设备 A 应获得设备 B 的修改');

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
  group('多设备交互 - 场景 d：两设备独立 keyring 首次同步', () {
    test('相同密码、不同 salt → 迁移本地数据到远端 dataKey 并同步', () async {
      const password = 'test-password-123';
      final backend = FakeBackend();

      // ── 设备 A：独立创建 keyring，加 2 条笔记，同步上传 ──
      var db = await _makeDatabase();
      final vaultA = await Keyring.createNew(password: password, database: db);
      db.setDataKey(vaultA.dataKey);

      await db.storeNote(_makeNote(uuid: 'note-a-1', title: 'Note A1'));
      await db.storeNote(_makeNote(uuid: 'note-a-2', title: 'Note A2'));

      final engineA = SyncEngine(
        backend: backend,
        database: db,
        keyring: vaultA,
        deviceId: 'device-A',
        journal: makeTestJournal(),
        passphraseProvider: () => password,
      );
      final resultA = await engineA.sync();
      expect(resultA.success, isTrue, reason: '设备 A 首次同步应成功');
      expect(resultA.uploaded, 2);

      // 保存设备 A 的 keyring 参数用于后续验证
      final vaultAVaultId = vaultA.vaultId;
      final vaultASalt = vaultA.kdf.salt;
      final vaultADataKey = vaultA.dataKey;
      final vaultAFingerprint = vaultA.keyFingerprint;

      // ── 设备 B：独立创建 keyring（相同密码、不同 salt/dataKey），加 1 条笔记 ──
      db = await _makeDatabase();
      final vaultB = await Keyring.createNew(password: password, database: db);
      db.setDataKey(vaultB.dataKey);

      // 验证前提：两设备 keyring 参数确实不同
      expect(
        vaultB.vaultId,
        isNot(equals(vaultAVaultId)),
        reason: '独立 keyring 应有不同 vaultId',
      );
      expect(
        vaultB.kdf.salt,
        isNot(equals(vaultASalt)),
        reason: '独立 keyring 应有不同 salt',
      );
      expect(
        vaultB.dataKey,
        isNot(equals(vaultADataKey)),
        reason: '独立 keyring 应有不同 dataKey',
      );
      expect(
        vaultB.keyFingerprint,
        isNot(equals(vaultAFingerprint)),
        reason: '不同 salt → 不同 MK → 不同 fingerprint',
      );

      await db.storeNote(_makeNote(uuid: 'note-b-1', title: 'Note B1'));

      // ── 设备 B 同步：应触发场景 d 迁移 ──
      final engineB = SyncEngine(
        backend: backend,
        database: db,
        keyring: vaultB,
        deviceId: 'device-B',
        journal: makeTestJournal(),
        passphraseProvider: () => password,
      );
      final resultB = await engineB.sync();

      // 验证：同步成功（不是失败）
      expect(
        resultB.success,
        isTrue,
        reason: '场景 d：相同密码应迁移成功，而非报 dataKey 迁移失败',
      );
      expect(
        resultB.migrated,
        greaterThan(0),
        reason: '应有迁移操作（本地数据重新加密到远端 dataKey）',
      );

      // 验证：设备 B 本地现在有 3 条笔记（A 的 2 条 + B 的 1 条）
      final allNotesB = await db.readAllNotesIncludingDeleted();
      expect(allNotesB.length, 3, reason: '迁移 + 同步后，设备 B 应有 A 和 B 的所有笔记');

      // 验证：设备 B 的 keyring 元数据已更新为远端（设备 A）的值
      final vaultBAfter = engineB.keyring;
      expect(
        vaultBAfter.vaultId,
        equals(vaultAVaultId),
        reason: '迁移后 vaultId 应为远端值',
      );
      expect(
        vaultBAfter.kdf.salt,
        equals(vaultASalt),
        reason: '迁移后 salt 应为远端值',
      );
      expect(
        vaultBAfter.dataKey,
        equals(vaultADataKey),
        reason: '迁移后 dataKey 应为远端值',
      );
      expect(
        vaultBAfter.keyFingerprint,
        equals(vaultAFingerprint),
        reason: '迁移后 fingerprint 应为远端值',
      );

      // 验证：远端 manifest 现在包含 3 条笔记
      final remoteManifest = await backend.getManifest();
      final manifest = await ManifestCrypto.deserialize(
        vaultADataKey,
        remoteManifest.ciphertext,
      );
      expect(manifest.items.length, 3, reason: '远端 manifest 应有 3 条笔记');
      expect(manifest.items.containsKey('note-a-1'), isTrue);
      expect(manifest.items.containsKey('note-a-2'), isTrue);
      expect(manifest.items.containsKey('note-b-1'), isTrue);
    });

    test('不同密码 → 同步失败，提示密码不匹配', () async {
      const passwordA = 'password-A';
      const passwordB = 'password-B';
      final backend = FakeBackend();

      // 设备 A 创建 keyring 并同步
      var db = await _makeDatabase();
      final vaultA = await Keyring.createNew(password: passwordA, database: db);
      db.setDataKey(vaultA.dataKey);
      await db.storeNote(_makeNote(uuid: 'note-a-1', title: 'Note A1'));

      final engineA = SyncEngine(
        backend: backend,
        database: db,
        keyring: vaultA,
        deviceId: 'device-A',
        journal: makeTestJournal(),
        passphraseProvider: () => passwordA,
      );
      await engineA.sync();

      // 设备 B 用不同密码创建 keyring
      db = await _makeDatabase();
      final vaultB = await Keyring.createNew(password: passwordB, database: db);
      db.setDataKey(vaultB.dataKey);

      final engineB = SyncEngine(
        backend: backend,
        database: db,
        keyring: vaultB,
        deviceId: 'device-B',
        journal: makeTestJournal(),
        passphraseProvider: () => passwordB,
      );
      final resultB = await engineB.sync();

      // 验证：同步失败（密码不匹配）
      expect(resultB.success, isFalse, reason: '不同密码应同步失败');
      expect(resultB.errorMessage, contains('密码'), reason: '错误信息应提示密码不匹配');
    });
  });
}
