/*
 * 改密码多端场景回归测试
 *
 * 背景（用户报告的问题链）：
 *   「A 端改密码 → B 端（旧密码会话）点同步"正常"、无任何提示 →
 *     B 重启后旧密码无法登录、新密码可以登录、UI 仍无提示」
 *
 * 本文件最初作为排查产物固化了 BUG-1~BUG-4 的证据，修复后断言已反转，
 * 现在验证的是**修复后的正确行为**：
 *
 *   BUG-1/BUG-2 修复（B1-2，sync_engine）：
 *     密钥纪元守卫触发时（远端 keyVersion > 本地），构建上传 header 的
 *     密钥纪元三元组（encryptedDataKey + keyFingerprint + keyVersion）
 *     整体采用远端值 → 旧密码设备的同步不再回滚远端纪元，守卫持续有效，
 *     翻转战争不再发生（S1/S2 验证）。
 *
 *   BUG-3 修复（B3，sync_engine H1 分支 + vault.adoptRemoteEpoch）：
 *     他端改密码 + 本端新密码登录时，本地 meta 的
 *     encryptedDataKey/keyFingerprint/keyVersion 三者整体采用远端纪元，
 *     纪元收敛，epochMismatch 不再误报（S5 验证）。
 *
 *   BUG-4 修复（B4，home.dart）：
 *     HomePage 监听 SyncService.stateStream，消费
 *     SyncResult.passwordEpochMismatch，弹窗提示"密码已在其他设备修改"
 *     并引导安全登出重新登录（UI 层，无单测，见 home.dart._onSyncStateChanged）。
 *
 *   S3（机制说明，非 bug 修复对象）：
 *     B 重启后用新密码登录 → 本地 unlockLocal 失败 → login.dart 走远端验证
 *     → fingerprint 匹配 → unlockFromRemoteManifest 把远端 vault 元数据
 *     覆盖写入本地 meta → 旧密码从此本地解锁失败。此为预期设计
 *     （本地纪元跟随远端收敛），数据不丢失（dataKey 不变）。
 *     B4 修复后用户会在 B 关闭前就收到"密码已变更"弹窗提示。
 *
 *   S4（BUG-1 修复的连锁收益）：
 *     远端 header 不再被污染为 fp=旧/edk=新 的自相矛盾状态，
 *     新密码在任何设备走远端验证 / 场景 d 判别都能正确通过。
 *
 * 运行：flutter test test/sync/change_password_multi_client_test.dart
 */

// Dart 原生导入
import 'dart:convert';
import 'dart:typed_data';

// Package 导入
import 'package:flutter_test/flutter_test.dart';
import 'package:safenotes/data/database_handler.dart';
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/safenote.dart';
import 'package:safenotes/sync/crypto.dart';
import 'package:safenotes/sync/sync_backend.dart';
import 'package:safenotes/sync/sync_engine.dart';
import 'package:safenotes/sync/sync_models.dart';
import 'package:safenotes/sync/sync_service.dart';
import 'package:safenotes/sync/vault.dart';
import 'package:safenotes/utils/device_id.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// ──────────────────────────────────────────────
// 测试用 FakeBackend（内存实现，模拟远端）
// ──────────────────────────────────────────────
class FakeBackend implements SyncBackend {
  Uint8List? _manifestCiphertext;
  String _etag = '';
  final Map<String, Uint8List> _blobs = {};

  @override
  String get displayName => 'FakeBackend';

  @override
  String get providerKey => 'fake-change-password';

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

  @override
  Future<void> deleteBlob(String hash) async {
    _blobs.remove(hash);
  }

  @override
  Future<List<String>> listBlobs() async => _blobs.keys.toList();

  @override
  Future<void> backupCorruptManifest(Uint8List ciphertext) async {}

  @override
  Future<void> close() async {}

  @override
  Future<bool> ping() async => true;

  @override
  Future<void> deleteBlobSoft(String hash) async => deleteBlob(hash);

  @override
  Future<List<String>> listOrphanBlobs() async => [];

  @override
  Future<void> purgeOrphans(Duration retention) async {}

  @override
  Future<void> backupManifest([Uint8List? currentManifestBytes]) async {}
}

/// Bug A 测试专用：可切换离/在线状态的 FakeBackend。
///
/// 离线时 [init] 抛 [BackendUnavailableException]（模拟登录时断网导致后端
/// 初始化失败），联网后 [init] 成功。存储仍委托给内部 [FakeBackend]，
/// 因此联网后首次同步即可正常读写远端。
class _FlakyBackend extends FakeBackend {
  bool offline = true;

  @override
  Future<void> init() async {
    if (offline) {
      throw BackendUnavailableException('simulated offline');
    }
    await super.init();
  }
}

// ──────────────────────────────────────────────
// 共享密钥素材（PBKDF2 只算两次，加速测试）
// ──────────────────────────────────────────────
const String kOldPassword = 'old-password-123';
const String kNewPassword = 'new-password-456';
const String kVaultId = 'vault-under-test';

late Uint8List dataKey; // 永不变化的数据主密钥
late Uint8List salt; // per-vault salt（改密码时不变）
late KdfParams kdf;
late Uint8List mkOld; // 旧密码派生的 MK
late Uint8List mkNew; // 新密码派生的 MK
late String edkOld; // 旧 MK 包裹的 dataKey
late String edkNew; // 新 MK 包裹的 dataKey
late String fpOld; // H(mkOld)
late String fpNew; // H(mkNew)
late int vaultCreatedAt;

// ──────────────────────────────────────────────
// 辅助函数
// ──────────────────────────────────────────────

/// 构造 Vault 实例（模拟不同登录会话持有的内存密钥状态）
Vault _makeVault({
  required int keyVersion,
  required String encryptedDataKey,
  required String keyFingerprint,
  Uint8List? mk,
}) {
  return Vault(
    vaultId: kVaultId,
    dataKey: dataKey,
    encryptedDataKey: encryptedDataKey,
    keyFingerprint: keyFingerprint,
    keyVersion: keyVersion,
    kdf: kdf,
    createdAt: vaultCreatedAt,
    mk: mk,
  );
}

/// 构造 SyncEngine（注入 passphraseProvider，与生产环境一致）
SyncEngine _makeEngine({
  required FakeBackend backend,
  required NotesDatabase database,
  required Vault vault,
  required String deviceId,
  String? passphrase,
}) {
  return SyncEngine(
    backend: backend,
    database: database,
    vault: vault,
    deviceId: deviceId,
    passphraseProvider: passphrase != null ? () => passphrase : null,
  );
}

/// 创建 in-memory 数据库并注入为单例（close → recreate 模式模拟多设备）
Future<NotesDatabase> _makeDatabase() async {
  try {
    await NotesDatabase.instance.close();
  } on Exception {
    // 首次调用无数据库，忽略
  }
  final db = await openDatabase(
    ':memory:',
    version: 2,
    onCreate: NotesDatabase.createDBForTesting,
  );
  NotesDatabase.setDatabaseForTesting(db);
  return NotesDatabase.instance;
}

/// 写入本地 vault 元数据（模拟设备登录前的本地持久化状态）
Future<void> _seedMeta(
  NotesDatabase db, {
  required String encryptedDataKey,
  required int keyVersion,
  required String keyFingerprint,
}) async {
  await db.setMeta(MetaKeys.vaultId, kVaultId);
  await db.setMeta(MetaKeys.encryptedDataKey, encryptedDataKey);
  await db.setMeta(MetaKeys.kdfSalt, base64.encode(salt));
  await db.setMeta(MetaKeys.keyFingerprint, keyFingerprint);
  await db.setMeta(MetaKeys.keyVersion, keyVersion.toString());
  await db.setMeta(MetaKeys.vaultCreatedAt, vaultCreatedAt.toString());
}

/// 读取远端 manifest 的明文 header
Future<ManifestHeader> _remoteHeader(FakeBackend backend) async {
  final response = await backend.getManifest();
  return ManifestCrypto.deserializeHeaderOnly(response.ciphertext);
}

/// 创建测试笔记
SafeNote _makeNote({
  required String uuid,
  String title = 'Title',
  String description = 'Description',
}) {
  return SafeNote(
    uuid: uuid,
    title: title,
    description: description,
    contentHash: SafeNote.computeHash(title, description),
    deleted: false,
    createdTime: DateTime.now(),
    updatedAt: DateTime.now().millisecondsSinceEpoch,
    synced: false,
  );
}

/// 场景公共步骤：设备 A 初始同步（旧密码）→ 改密码 → 推送新密钥包裹。
/// 返回改密码后的远端状态供各场景断言/续接。
Future<FakeBackend> _deviceAChangesPasswordAndPushes() async {
  final backend = FakeBackend();

  // 1. 设备 A（旧密码会话，kv=1）创建笔记并首次同步
  final dbA = await _makeDatabase();
  dbA.setDataKey(dataKey);
  await _seedMeta(dbA,
      encryptedDataKey: edkOld, keyVersion: 1, keyFingerprint: fpOld);
  var engineA = _makeEngine(
    backend: backend,
    database: dbA,
    vault: _makeVault(
        keyVersion: 1, encryptedDataKey: edkOld, keyFingerprint: fpOld,
        mk: mkOld),
    deviceId: 'device-A',
    passphrase: kOldPassword,
  );
  await dbA.storeNote(_makeNote(uuid: 'note-1', title: 'Note from A'));
  final res1 = await engineA.sync();
  expect(res1.success, isTrue, reason: '前置：A 首次同步应成功');

  // 2. 设备 A 改密码（等价于 vault.changePassword 的结果：
  //    dataKey 不变，edk/fp 更新，keyVersion 1→2，本地 meta 已持久化）
  await _seedMeta(dbA,
      encryptedDataKey: edkNew, keyVersion: 2, keyFingerprint: fpNew);
  engineA = _makeEngine(
    backend: backend,
    database: dbA,
    vault: _makeVault(
        keyVersion: 2, encryptedDataKey: edkNew, keyFingerprint: fpNew,
        mk: mkNew),
    deviceId: 'device-A',
    passphrase: kNewPassword,
  );

  // 3. 改密码后立即同步（change_passphrase.dart 的行为）
  final res2 = await engineA.sync();
  expect(res2.success, isTrue, reason: '前置：A 改密码后推送应成功');

  // 4. 验证远端 header 已是新纪元
  final header = await _remoteHeader(backend);
  expect(header.keyVersion, 2, reason: '前置：远端 keyVersion 应为 2');
  expect(header.encryptedDataKey, edkNew,
      reason: '前置：远端应持有新密钥包裹');
  expect(header.keyFingerprint, fpNew,
      reason: '前置：远端 fingerprint 应为新值');

  return backend;
}

/// 场景公共步骤：设备 B（旧密码会话）接入并同步一次。
/// 返回 (db, engine, result)。
Future<({NotesDatabase db, SyncEngine engine, SyncResult result})>
    _deviceBOldSessionSyncs(FakeBackend backend) async {
  final dbB = await _makeDatabase();
  dbB.setDataKey(dataKey);
  await _seedMeta(dbB,
      encryptedDataKey: edkOld, keyVersion: 1, keyFingerprint: fpOld);
  final engineB = _makeEngine(
    backend: backend,
    database: dbB,
    vault: _makeVault(
        keyVersion: 1, encryptedDataKey: edkOld, keyFingerprint: fpOld,
        mk: mkOld),
    deviceId: 'device-B',
    passphrase: kOldPassword, // B 会话里 PhraseHandler.getPass 还是旧密码
  );
  final result = await engineB.sync();
  return (db: dbB, engine: engineB, result: result);
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    // 共享密钥素材（PBKDF2 200k 迭代只算两次）
    dataKey = SyncCrypto.generateDataKey();
    salt = SyncCrypto.generateSalt();
    kdf = KdfParams.create(salt: salt);
    mkOld = SyncCrypto.deriveMasterKey(kOldPassword, salt: salt);
    mkNew = SyncCrypto.deriveMasterKey(kNewPassword, salt: salt);
    edkOld = base64.encode(SyncCrypto.wrapDataKey(mkOld, dataKey));
    edkNew = base64.encode(SyncCrypto.wrapDataKey(mkNew, dataKey));
    fpOld = SyncCrypto.computeKeyFingerprint(mkOld);
    fpNew = SyncCrypto.computeKeyFingerprint(mkNew);
    vaultCreatedAt = DateTime.now().millisecondsSinceEpoch;
  });

  tearDown(() async {
    try {
      await NotesDatabase.instance.close();
    } on Exception {
      // 忽略
    }
  });

  // ────────────────────────────────────────────
  // S1：用户场景第一步——B 旧密码会话点同步
  // ────────────────────────────────────────────
  group('S1: A 改密码后，B 旧密码会话手动同步', () {
    test('B 同步成功、检测到纪元不匹配，且远端新纪元不被回滚（B1-2 修复）',
        () async {
      final backend = await _deviceAChangesPasswordAndPushes();
      final b = await _deviceBOldSessionSyncs(backend);

      // —— 同步本身正常完成（笔记不受改密码影响，dataKey 不变）——
      expect(b.result.success, isTrue,
          reason: 'B 点同步应成功（笔记传输与密码无关）');
      final notesOnB = await b.db.readAllNotesIncludingDeleted();
      expect(notesOnB.map((n) => n.uuid), contains('note-1'),
          reason: 'A 的笔记正常同步下来');

      // —— 引擎检测到他端改密码，标志置位（B4 修复后 UI 会弹窗提示）——
      expect(b.result.passwordEpochMismatch, isTrue,
          reason: '引擎应置位 passwordEpochMismatch，'
              'HomePage._onSyncStateChanged 消费此标志弹窗提示用户');

      // —— B 本地 meta 不被动（旧密码在 B 本地仍可登录，直到用户主动换新密码）——
      expect(await b.db.getMeta(MetaKeys.encryptedDataKey), edkOld,
          reason: 'B 本地 meta 保持旧包裹：旧密码会话不采用新纪元'
              '（B 不知道新密码，无法验证新包裹），仅避免回滚远端');

      // —— B1-2 修复：远端密钥纪元三元组整体不被回滚 ——
      final header = await _remoteHeader(backend);
      expect(header.encryptedDataKey, edkNew,
          reason: 'B1 守卫：远端新密钥包裹未被 B 回滚');
      expect(header.keyVersion, 2,
          reason: 'B1-2 修复：远端 keyVersion 保持 2 不被回滚'
              '（守卫在 B 后续同步中持续有效）');
      expect(header.keyFingerprint, fpNew,
          reason: 'B1-2 修复：远端 fingerprint 保持新值，'
              'header 不再自相矛盾（fp 与 edk 一致，见 S4）');
    });
  });

  // ────────────────────────────────────────────
  // S2：B 继续用旧会话操作——守卫必须持续有效（原翻转战争场景）
  // ────────────────────────────────────────────
  group('S2: B 继续用旧会话新建笔记并同步（用户场景第二步）', () {
    test('B 第二次同步守卫仍有效，远端新纪元稳定不翻转（B1-2 修复）',
        () async {
      final backend = await _deviceAChangesPasswordAndPushes();
      final b = await _deviceBOldSessionSyncs(backend);
      expect(b.result.passwordEpochMismatch, isTrue);

      // —— 用户操作：在 B 上新建笔记（触发 autoSync）——
      await b.db.storeNote(_makeNote(uuid: 'note-2', title: 'New note on B'));
      final res2 = await b.engine.sync();

      expect(res2.success, isTrue,
          reason: '新建笔记正常同步（笔记传输与密码无关）');

      // —— B1-2 修复：远端 keyVersion 未被回滚 → 守卫第二次依然触发 ——
      expect(res2.passwordEpochMismatch, isTrue,
          reason: 'B1-2 修复：远端 keyVersion 保持 2 > 本地 1，'
              '守卫持续有效，每次同步都提醒（而非被自己击穿）');

      final header = await _remoteHeader(backend);
      expect(header.encryptedDataKey, edkNew,
          reason: 'B1-2 修复：旧密钥包裹不再被写回远端，'
              'A 的改密码不会被撤销（翻转战争消除）');
      expect(header.keyFingerprint, fpNew);
      expect(header.keyVersion, 2);

      // —— B 新建的笔记正常到达远端 manifest ——
      final response = await backend.getManifest();
      final manifest = ManifestCrypto.deserialize(dataKey, response.ciphertext);
      expect(manifest.items.keys, containsAll(['note-1', 'note-2']),
          reason: '纪元守卫不阻断笔记同步');

      // —— A 再次同步：纪元一致，无感知、无翻转 ——
      final dbA2 = await _makeDatabase();
      dbA2.setDataKey(dataKey);
      await _seedMeta(dbA2,
          encryptedDataKey: edkNew, keyVersion: 2, keyFingerprint: fpNew);
      final engineA2 = _makeEngine(
        backend: backend,
        database: dbA2,
        vault: _makeVault(
            keyVersion: 2, encryptedDataKey: edkNew, keyFingerprint: fpNew,
            mk: mkNew),
        deviceId: 'device-A',
        passphrase: kNewPassword,
      );
      final resA = await engineA2.sync();
      expect(resA.success, isTrue);
      expect(resA.passwordEpochMismatch, isFalse,
          reason: 'A 端纪元与远端一致（kv=2），无误报');

      final headerAfterA = await _remoteHeader(backend);
      expect(headerAfterA.encryptedDataKey, edkNew,
          reason: '远端密钥状态收敛稳定：始终保持新纪元，不再翻转');
      expect(headerAfterA.keyVersion, 2);
      expect(headerAfterA.keyFingerprint, fpNew);
    });
  });

  // ────────────────────────────────────────────
  // S3：B 重启后的登录机制（预期设计，B4 修复补齐提示）
  // ────────────────────────────────────────────
  group('S3: B 重启后的登录行为（"旧密码无法登录、新密码可以"的机制）', () {
    test('新密码经远端验证覆盖本地 meta；dataKey 不变，笔记数据完好',
        () async {
      final backend = await _deviceAChangesPasswordAndPushes();

      // B 的本地 meta 仍是旧包裹（模拟 B 关闭前的状态，S1 已证明同步不改它）
      final dbB = await _makeDatabase();
      dbB.setDataKey(dataKey);
      await _seedMeta(dbB,
          encryptedDataKey: edkOld, keyVersion: 1, keyFingerprint: fpOld);

      // —— 本地 meta 未被覆盖前，旧密码仍可本地登录 ——
      final vaultViaOld =
          await Vault.unlockLocal(password: kOldPassword, database: dbB);
      expect(base64.encode(vaultViaOld.dataKey), base64.encode(dataKey),
          reason: '本地 meta 未被覆盖时旧密码仍可登录（B4 修复后，'
              '用户在此之前已收到"密码已变更"弹窗，知道要用新密码）');

      // —— 用户用新密码登录：本地解锁失败 → login.dart 进入远端验证分支 ——
      await expectLater(
        Vault.unlockLocal(password: kNewPassword, database: dbB),
        throwsA(isA<WrongPasswordException>()),
        reason: '新密码解不开本地旧包裹 → login.dart 走远端验证',
      );

      // —— login.dart._tryVerifyPassphraseViaRemote 的行为 ——
      final header = await _remoteHeader(backend);
      final mkTry = SyncCrypto.deriveMasterKey(kNewPassword,
          salt: header.kdf.saltBytes);
      expect(SyncCrypto.computeKeyFingerprint(mkTry), header.keyFingerprint,
          reason: '远端 header 是新纪元 → fingerprint 匹配新密码');

      // fingerprint 匹配 → unlockFromRemoteManifest 持久化远端元数据（覆盖本地）
      await Vault.unlockFromRemoteManifest(
        password: kNewPassword,
        remoteVaultId: header.vaultId,
        remoteEncryptedDataKey: header.encryptedDataKey,
        remoteKdf: header.kdf,
        remoteKeyFingerprint: header.keyFingerprint,
        remoteKeyVersion: header.keyVersion,
        remoteCreatedAt: header.createdAt,
        database: dbB,
      );

      // —— 本地 meta 采用远端新纪元（预期设计：本地纪元跟随远端收敛）——
      expect(await dbB.getMeta(MetaKeys.encryptedDataKey), edkNew,
          reason: '本地 meta（encryptedDataKey）采用远端新纪元');
      expect(await dbB.getMeta(MetaKeys.keyVersion), '2');
      expect(await dbB.getMeta(MetaKeys.keyFingerprint), fpNew);

      // —— 此后旧密码本地登录失败（预期：全局只有一个有效密码）——
      await expectLater(
        Vault.unlockLocal(password: kOldPassword, database: dbB),
        throwsA(isA<WrongPasswordException>()),
        reason: '纪元收敛后旧密码失效是预期行为',
      );

      // —— 新密码正常登录，dataKey 不变、笔记完好 ——
      final vaultViaNew =
          await Vault.unlockLocal(password: kNewPassword, database: dbB);
      expect(base64.encode(vaultViaNew.dataKey), base64.encode(dataKey),
          reason: 'dataKey 永不变化：改密码/登出/纪元覆盖都不影响笔记数据');
    });
  });

  // ────────────────────────────────────────────
  // S4：远端 header 一致性——新密码可正确通过远端验证（B1-2 修复收益）
  // ────────────────────────────────────────────
  group('S4: B 旧会话同步后的远端 header 一致性', () {
    test('header 保持 fp=新/edk=新 自洽，新密码通过 fingerprint 判别（B1-2 修复）',
        () async {
      final backend = await _deviceAChangesPasswordAndPushes();
      // B 旧会话同步一次——修复后远端 header 保持新纪元不被污染
      await _deviceBOldSessionSyncs(backend);

      final header = await _remoteHeader(backend);
      expect(header.keyFingerprint, fpNew,
          reason: 'B1-2 修复：fingerprint 不再被回滚为旧值');
      expect(header.encryptedDataKey, edkNew);
      expect(header.keyVersion, 2);

      // —— 新密码走 login.dart 远端验证 / 场景 d 判别：正确通过 ——
      final result = await Vault.tryDeriveRemoteDataKey(
        password: kNewPassword,
        remoteKdf: header.kdf,
        remoteEncryptedDataKey: header.encryptedDataKey,
        remoteKeyFingerprint: header.keyFingerprint,
      );
      expect(result, isNotNull,
          reason: 'B1-2 修复收益：header 自洽（fp=新/edk=新），'
              '新密码 fingerprint 比对通过且能解开远端包裹');
      expect(base64.encode(result!.dataKey), base64.encode(dataKey),
          reason: '解开的 dataKey 与原始一致');

      // —— 旧密码被正确拒绝（fingerprint 不匹配）——
      final resultOld = await Vault.tryDeriveRemoteDataKey(
        password: kOldPassword,
        remoteKdf: header.kdf,
        remoteEncryptedDataKey: header.encryptedDataKey,
        remoteKeyFingerprint: header.keyFingerprint,
      );
      expect(resultOld, isNull,
          reason: '旧密码 fingerprint 不匹配新纪元，正确拒绝');
    });
  });

  // ────────────────────────────────────────────
  // S5：H1 分支——本地纪元整体收敛（B3 修复）
  // ────────────────────────────────────────────
  group('S5: B 用新密码会话同步（H1 回写分支）', () {
    test('encryptedDataKey/keyVersion/keyFingerprint 三者整体收敛到远端纪元（B3 修复）',
        () async {
      final backend = await _deviceAChangesPasswordAndPushes();

      // B：用户已用新密码登录，但本地 meta 还是旧包裹、旧纪元
      // （对应 multi_device_test H1 场景：MK=新，能解开远端新包裹）
      final dbB = await _makeDatabase();
      dbB.setDataKey(dataKey);
      await _seedMeta(dbB,
          encryptedDataKey: edkOld, keyVersion: 1, keyFingerprint: fpOld);
      final engineB = _makeEngine(
        backend: backend,
        database: dbB,
        vault: _makeVault(
            keyVersion: 1, encryptedDataKey: edkOld, keyFingerprint: fpOld,
            mk: mkNew), // 新密码派生的 MK
        deviceId: 'device-B',
        passphrase: kNewPassword,
      );

      final res = await engineB.sync();
      expect(res.success, isTrue);

      // —— B3 修复：本地纪元三元组整体收敛 ——
      expect(await dbB.getMeta(MetaKeys.encryptedDataKey), edkNew,
          reason: '本地 encryptedDataKey 更新为远端新值（H1 原有行为）');
      expect(await dbB.getMeta(MetaKeys.keyVersion), '2',
          reason: 'B3 修复：本地 keyVersion 收敛到 2，'
              'B 下次同步不再误报 epochMismatch');
      expect(await dbB.getMeta(MetaKeys.keyFingerprint), fpNew,
          reason: 'B3 修复：本地 keyFingerprint 收敛到新值');

      // —— 内存 vault 同步更新（引擎与 SyncService 共享同一实例）——
      expect(engineB.vault.keyVersion, 2,
          reason: 'B3 修复：内存 vault.keyVersion 同步更新');
      expect(engineB.vault.keyFingerprint, fpNew);
      expect(engineB.vault.encryptedDataKey, edkNew);

      // —— 远端 header 保持新纪元不被回滚 ——
      final header = await _remoteHeader(backend);
      expect(header.keyVersion, 2,
          reason: 'B3 修复：远端 keyVersion 不再被 H1 分支回滚');
      expect(header.keyFingerprint, fpNew,
          reason: 'B3 修复：远端 fingerprint 保持新值，header 自洽');
      expect(header.encryptedDataKey, edkNew);

      // —— 用户已持有新密码：不误报纪元不匹配（避免"永远提示"）——
      expect(res.passwordEpochMismatch, isFalse,
          reason: 'B3 修复：本端已收敛到新纪元，不再误报，'
              'UI 不会对已换新密码的用户弹"密码已变更"');

      // —— 收敛后再次同步：完全正常，无任何纪元动作 ——
      final res2 = await engineB.sync();
      expect(res2.success, isTrue);
      expect(res2.passwordEpochMismatch, isFalse,
          reason: '纪元已收敛，后续同步稳定');
    });
  });

  // ────────────────────────────────────────────
  // S6：用户报告 Bug B 的根因隔离——
  //   A 改密码后保持打开；B 用新密码新建并同步；A 点同步
  // 断言 A 的本地 DB 能拉到 B 的笔记，证明引擎 pull 正常，
  // "没显示"是主页 UI 未在后台同步后重查列表（见 home.dart Bug B 修复）。
  // ────────────────────────────────────────────
  group('S6: A 改密码后保持打开，B 用新密码新建并同步，A 同步后本地 DB 含 B 的笔记', () {
    test('A 同步把 B 新建的笔记拉入本地数据库（引擎 pull 正常，Bug B 是 UI 未刷新）',
        () async {
      // 1. A 改密码并推送（复用公共步骤：远端 kv=2，含 A 的 note-1）
      final backend = await _deviceAChangesPasswordAndPushes();

      // 2. B 用新密码重新登录：本地 meta 已是新纪元
      final dbB = await _makeDatabase();
      dbB.setDataKey(dataKey);
      await _seedMeta(dbB,
          encryptedDataKey: edkNew, keyVersion: 2, keyFingerprint: fpNew);
      final engineB = _makeEngine(
        backend: backend,
        database: dbB,
        vault: _makeVault(
            keyVersion: 2, encryptedDataKey: edkNew, keyFingerprint: fpNew,
            mk: mkNew),
        deviceId: 'device-B',
        passphrase: kNewPassword,
      );
      // B 新建笔记并同步（push 到远端）
      await dbB.storeNote(_makeNote(uuid: 'note-B', title: 'Note from B'));
      final resB = await engineB.sync();
      expect(resB.success, isTrue, reason: 'B 用新密码同步应成功');
      // 远端现在同时持有 note-1 与 note-B
      final respB = await backend.getManifest();
      final manifestB = ManifestCrypto.deserialize(dataKey, respB.ciphertext);
      expect(manifestB.items.keys, containsAll(['note-1', 'note-B']),
          reason: 'B 的笔记已 push 上远端（push 没坏）');

      // 3. A 保持旧会话（kv=1，旧密码）点同步——用户报告的"没拉下来"路径
      final dbA = await _makeDatabase();
      dbA.setDataKey(dataKey);
      await _seedMeta(dbA,
          encryptedDataKey: edkOld, keyVersion: 1, keyFingerprint: fpOld);
      final engineA = _makeEngine(
        backend: backend,
        database: dbA,
        vault: _makeVault(
            keyVersion: 1, encryptedDataKey: edkOld, keyFingerprint: fpOld,
            mk: mkOld),
        deviceId: 'device-A-old',
        passphrase: kOldPassword,
      );
      final resA = await engineA.sync();

      // —— 引擎检测到他端改密码（B4 修复后会在 UI 弹窗提示）——
      expect(resA.passwordEpochMismatch, isTrue,
          reason: 'A 旧会话应检测到远端 kv=2 > 本地 1');

      // —— 关键断言：B 的笔记已被拉入 A 的本地数据库 ——
      // 这说明 push 与 pull 都没坏；Bug B 的"没显示"纯粹是主页 UI
      // 没有在后台同步完成后重查列表（主页用普通数组而非 MVVM/Provider 驱动）。
      final notesOnA = await dbA.readAllNotesIncludingDeleted();
      expect(notesOnA.map((n) => n.uuid), containsAll(['note-1', 'note-B']),
          reason: 'A 同步后本地 DB 应已含 B 新建的 note-B'
              '（引擎 pull 正常，Bug B 根因是 UI 未刷新而非同步失败）');
    });
  });

  // ────────────────────────────────────────────
  // Bug A：离线时后端初始化失败，联网后重新同步不应再报
  //   "Call init() before using the backend"
  // 验证 SyncService 的惰性（重）初始化：
  //   离线首次 init 失败 → sync 优雅返回"网络不可用"；
  //   联网后再次 sync 自动恢复，不再抛出 cryptic 的 init 错误。
  // ────────────────────────────────────────────
  group('Bug A: 离线初始化失败后联网重新同步能自动恢复', () {
    test('sync() 惰性重初始化后端：离线优雅失败，联网后自动恢复', () async {
      DeviceIdProvider.instance.overrideForTesting('test-device-bug-a');
      final backend = _FlakyBackend();
      final db = await _makeDatabase();
      db.setDataKey(dataKey);
      await _seedMeta(db,
          encryptedDataKey: edkNew, keyVersion: 2, keyFingerprint: fpNew);
      final vault = _makeVault(
          keyVersion: 2, encryptedDataKey: edkNew, keyFingerprint: fpNew,
          mk: mkNew);

      final service = SyncService.instance;
      // 登录时离线：initialize 内部的 backend.init() 会抛错，
      // 与真实"进主界面就提示"同源。捕获后服务处于"引擎已建、后端未就绪"。
      bool initThrew = false;
      try {
        await service.initialize(vault: vault, backend: backend, database: db);
      } on BackendUnavailableException {
        initThrew = true;
      }
      expect(initThrew, isTrue,
          reason: '登录离线时 backend.init 应失败（复现 Bug A 触发条件）');

      // —— 仍离线时点同步：应优雅失败，绝不能再抛
      //    "Call init() before using the backend" 这类 cryptic 错误 ——
      final offlineResult = await service.sync();
      expect(offlineResult, isNotNull,
          reason: '离线同步应返回结果而非抛未捕获异常');
      expect(offlineResult!.success, isFalse,
          reason: '离线同步应失败');
      expect(offlineResult.errorMessage?.toLowerCase().contains('init()'),
          isFalse,
          reason: 'Bug A 修复：错误文案应为"网络不可用"等友好提示，'
              '而非 cryptic 的 "Call init() before using the backend"');

      // —— 联网后再次同步：自动重初始化并成功，无需杀进程重进 ——
      // 引擎由 SyncService 单例以 PhraseHandler.getPass 作为 passphraseProvider
      // 构建，因此需先注入密码（与真实登录一致）。
      backend.offline = false;
      PhraseHandler.initPass(kNewPassword);
      final onlineResult = await service.sync();
      expect(onlineResult, isNotNull);
      expect(onlineResult!.success, isTrue,
          reason: 'Bug A 修复：联网后 sync 应自动重初始化后端并成功');

      // 清理：关闭服务（仅本文件使用 SyncService 单例）
      await service.dispose();
      PhraseHandler.destroy();
      DeviceIdProvider.instance.clearTestingOverride();
    });
  });
}
