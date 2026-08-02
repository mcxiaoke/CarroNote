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
 *   BUG-3 修复（B3，sync_engine H1 分支 + keyring.adoptRemoteEpoch）：
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
 *     → fingerprint 匹配 → unlockFromRemoteManifest 把远端 keyring 元数据
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
import 'dart:io';
import 'dart:typed_data';

// Package 导入
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:safenotes/data/database_handler.dart';
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/safenote.dart';
import 'package:safenotes/sync/crypto.dart';
import 'package:safenotes/sync/sync_backend.dart';
import 'package:safenotes/sync/sync_engine.dart';
import 'package:safenotes/sync/sync_models.dart';
import 'package:safenotes/sync/sync_service.dart';
import 'package:safenotes/sync/keyring.dart';
import 'package:safenotes/utils/device_id.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// 测试公共支撑（P2：Keyring/Journal 构造 + FakeBackend journal 存储）
import 'sync_test_support.dart';

/// 测试用 PathProvider 替身：让 SyncService 的 journal 能落到真实临时目录。
/// （SyncService._openJournal 依赖 getApplicationSupportDirectory）
class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this._root);
  final String _root;

  @override
  Future<String?> getApplicationSupportPath() async =>
      p.join(_root, 'app-support');

  @override
  Future<String?> getApplicationDocumentsPath() async =>
      p.join(_root, 'app-docs');

  @override
  Future<String?> getTemporaryPath() async => p.join(_root, 'tmp');
}

// ──────────────────────────────────────────────
// 测试用 FakeBackend（内存实现，模拟远端）
// ──────────────────────────────────────────────
class FakeBackend with FakeJournalStore implements SyncBackend {
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
const String kVaultId = 'keyring-under-test';

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

/// 构造 Keyring 实例（模拟不同登录会话持有的内存密钥状态）
Keyring _makeVault({
  required int keyVersion,
  required String encryptedDataKey,
  required String keyFingerprint,
  Uint8List? mk,
}) {
  return makeTestKeyring(
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
  required Keyring keyring,
  required String deviceId,
  String? passphrase,
}) {
  return SyncEngine(
    backend: backend,
    database: database,
    keyring: keyring,
    deviceId: deviceId,
    journal: makeTestJournal(),
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

/// 写入本地 keyring 账本（模拟设备登录前的本地持久化状态）
///
/// P2 变更：原来写 vault_id / encrypted_data_key / kdf_salt / key_fingerprint /
/// key_version / vault_created_at 六个散落键；现在密钥态是 `keyring` 单键
/// JSON 账本，写一次即原子（旧写法的"多键双写半成功"风险随之消失）。
Future<void> _seedMeta(
  NotesDatabase db, {
  required String encryptedDataKey,
  required int keyVersion,
  required String keyFingerprint,
}) async {
  await KeyringLedger(
    vaultId: kVaultId,
    kdf: kdf,
    createdAt: vaultCreatedAt,
    current: KeyringEntry(
      keyFingerprint: keyFingerprint,
      encryptedDataKey: encryptedDataKey,
      keyVersion: keyVersion,
      dataKeyEpoch: 1,
      reason: keyVersion > 1
          ? KeyringReason.changePassword
          : KeyringReason.create,
    ),
  ).persist(db);
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
    keyring: _makeVault(
        keyVersion: 1, encryptedDataKey: edkOld, keyFingerprint: fpOld,
        mk: mkOld),
    deviceId: 'device-A',
    passphrase: kOldPassword,
  );
  await dbA.storeNote(_makeNote(uuid: 'note-1', title: 'Note from A'));
  final res1 = await engineA.sync();
  expect(res1.success, isTrue, reason: '前置：A 首次同步应成功');

  // 2. 设备 A 改密码（等价于 keyring.changePassword 的结果：
  //    dataKey 不变，edk/fp 更新，keyVersion 1→2，本地 meta 已持久化）
  await _seedMeta(dbA,
      encryptedDataKey: edkNew, keyVersion: 2, keyFingerprint: fpNew);
  engineA = _makeEngine(
    backend: backend,
    database: dbA,
    keyring: _makeVault(
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
    keyring: _makeVault(
        keyVersion: 1, encryptedDataKey: edkOld, keyFingerprint: fpOld,
        mk: mkOld),
    deviceId: 'device-B',
    passphrase: kOldPassword, // B 会话里 PhraseHandler.getPass 还是旧密码
  );
  final result = await engineB.sync();
  return (db: dbB, engine: engineB, result: result);
}

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    // 共享密钥素材（PBKDF2 200k 迭代只算两次）
    dataKey = SyncCrypto.generateDataKey();
    salt = SyncCrypto.generateSalt();
    kdf = KdfParams.create(salt: salt);
    mkOld = await SyncCrypto.deriveMasterKey(kOldPassword, salt: salt);
    mkNew = await SyncCrypto.deriveMasterKey(kNewPassword, salt: salt);
    edkOld = base64.encode(await SyncCrypto.wrapDataKey(mkOld, dataKey));
    edkNew = base64.encode(await SyncCrypto.wrapDataKey(mkNew, dataKey));
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
    test('B 旧密码会话同步中止并提示重登录；远端新纪元不被回滚（选项 B 定案）',
        () async {
      final backend = await _deviceAChangesPasswordAndPushes();
      final b = await _deviceBOldSessionSyncs(backend);

      // —— v4（epoch 消除 §8.2[I] 选项 B）：scenario-b 中止同步、强制重登录 ——
      expect(b.result.success, isFalse,
          reason: 'B 旧密码会话同步应中止（他端改了密码，本地密码过期）');
      expect(b.result.errorMessage, contains('密码已在其他设备修改'),
          reason: 'errorMessage 接管 UI 提示（不再用 passwordEpochMismatch 标志）');
      expect(b.result.requiresRelogin, isTrue,
          reason: 'scenario-b 必须携带 requiresRelogin 标志，'
              'UI 据此强制登出并要求重新登录');

      // —— 中止意味着零写入：A 的笔记未被拉取 ——
      final notesOnB = await b.db.readAllNotesIncludingDeleted();
      expect(notesOnB, isEmpty, reason: '同步中止，A 的笔记未拉取（零写入）');

      // —— B 本地账本不被动（旧密码在 B 本地仍可登录，直到用户主动换新密码）——
      expect(await persistedEncryptedDataKey(b.db), edkOld,
          reason: 'B 本地 keyring 账本保持旧包裹：中止时不写任何东西');

      // —— B1-2 修复：远端密钥纪元三元组整体不被回滚 ——
      final header = await _remoteHeader(backend);
      expect(header.encryptedDataKey, edkNew,
          reason: 'B1 守卫：远端新密钥包裹未被 B 回滚');
      expect(header.keyVersion, 2,
          reason: 'B1-2 修复：远端 keyVersion 保持 2 不被回滚');
      expect(header.keyFingerprint, fpNew,
          reason: 'B1-2 修复：远端 fingerprint 保持新值，'
              'header 不再自相矛盾（fp 与 edk 一致，见 S4）');
    });
  });

  // ────────────────────────────────────────────
  // S2：B 继续用旧会话操作——守卫必须持续有效（原翻转战争场景）
  // ────────────────────────────────────────────
  group('S2: B 继续用旧会话新建笔记并同步（用户场景第二步）', () {
    test('B 旧会话继续同步仍被中止，远端新纪元稳定不翻转', () async {
      final backend = await _deviceAChangesPasswordAndPushes();
      final b = await _deviceBOldSessionSyncs(backend);
      expect(b.result.success, isFalse,
          reason: 'B 旧会话首次同步即中止（scenario-b，本地密码过期）');

      // —— 用户操作：在 B 上新建笔记（触发 autoSync）——
      await b.db.storeNote(_makeNote(uuid: 'note-2', title: 'New note on B'));
      final res2 = await b.engine.sync();

      expect(res2.success, isFalse,
          reason: 'B 旧会话第二次同步同样中止（密码仍未更新）');
      expect(res2.errorMessage, contains('密码已在其他设备修改'));

      // —— B1-2 修复：远端 keyVersion 未被回滚 → 中止持续有效 ——
      final header = await _remoteHeader(backend);
      expect(header.encryptedDataKey, edkNew,
          reason: 'B1-2 修复：旧密钥包裹不再被写回远端，'
              'A 的改密码不会被撤销（翻转战争消除）');
      expect(header.keyFingerprint, fpNew);
      expect(header.keyVersion, 2);

      // —— 中止 = 不 PUT：B 新建的笔记未到达远端 ——
      final response = await backend.getManifest();
      final manifest = await ManifestCrypto.deserialize(dataKey, response.ciphertext);
      expect(manifest.items.keys, isNot(contains('note-2')),
          reason: '同步中止，B 的本地新笔记未上传（零写入）');

      // —— A 用新密码会话再次同步：纪元一致，无感知、无翻转 ——
      final dbA2 = await _makeDatabase();
      dbA2.setDataKey(dataKey);
      await _seedMeta(dbA2,
          encryptedDataKey: edkNew, keyVersion: 2, keyFingerprint: fpNew);
      final engineA2 = _makeEngine(
        backend: backend,
        database: dbA2,
        keyring: _makeVault(
            keyVersion: 2, encryptedDataKey: edkNew, keyFingerprint: fpNew,
            mk: mkNew),
        deviceId: 'device-A',
        passphrase: kNewPassword,
      );
      final resA = await engineA2.sync();
      expect(resA.success, isTrue);

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
          await Keyring.unlockLocal(password: kOldPassword, database: dbB);
      expect(base64.encode(vaultViaOld.dataKey), base64.encode(dataKey),
          reason: '本地 meta 未被覆盖时旧密码仍可登录（B4 修复后，'
              '用户在此之前已收到"密码已变更"弹窗，知道要用新密码）');

      // —— 用户用新密码登录：本地解锁失败 → login.dart 进入远端验证分支 ——
      await expectLater(
        Keyring.unlockLocal(password: kNewPassword, database: dbB),
        throwsA(isA<WrongPasswordException>()),
        reason: '新密码解不开本地旧包裹 → login.dart 走远端验证',
      );

      // —— login.dart._tryVerifyPassphraseViaRemote 的行为 ——
      final header = await _remoteHeader(backend);
      final mkTry = await SyncCrypto.deriveMasterKey(kNewPassword,
          salt: header.kdf.saltBytes);
      expect(SyncCrypto.computeKeyFingerprint(mkTry), header.keyFingerprint,
          reason: '远端 header 是新纪元 → fingerprint 匹配新密码');

      // fingerprint 匹配 → unlockFromRemoteManifest 持久化远端元数据（覆盖本地）
      await Keyring.unlockFromRemoteManifest(
        password: kNewPassword,
        remoteVaultId: header.vaultId,
        remoteEncryptedDataKey: header.encryptedDataKey,
        remoteKdf: header.kdf,
        remoteKeyFingerprint: header.keyFingerprint,
        remoteKeyVersion: header.keyVersion,
        remoteCreatedAt: header.createdAt,
        database: dbB,
      );

      // —— 本地账本采用远端新纪元（预期设计：本地纪元跟随远端收敛）——
      expect(await persistedEncryptedDataKey(dbB), edkNew,
          reason: '本地 keyring 账本（encryptedDataKey）采用远端新纪元');
      expect(await persistedKeyVersion(dbB), 2);
      expect(await persistedKeyFingerprint(dbB), fpNew);

      // —— 此后旧密码本地登录失败（预期：全局只有一个有效密码）——
      await expectLater(
        Keyring.unlockLocal(password: kOldPassword, database: dbB),
        throwsA(isA<WrongPasswordException>()),
        reason: '纪元收敛后旧密码失效是预期行为',
      );

      // —— 新密码正常登录，dataKey 不变、笔记完好 ——
      final vaultViaNew =
          await Keyring.unlockLocal(password: kNewPassword, database: dbB);
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
      final result = await Keyring.tryDeriveRemoteDataKey(
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
      final resultOld = await Keyring.tryDeriveRemoteDataKey(
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
  group('S5: B 用新密码会话同步（v4：本地账本已收敛，无回写动作）', () {
    test('B 新密码登录后同步正常，本地纪元与远端一致（v4 只读不 echo）',
        () async {
      final backend = await _deviceAChangesPasswordAndPushes();

      // B：用户已用新密码完成登录（login 流程 unlockFromRemoteManifest
      // 已把本地账本覆盖为远端新纪元——S3 已验证该机制）。
      // v4 删除了「H1 回写 adoptRemoteEpoch」分支：本地与远端一致时
      // 无任何回写/echo 动作，正常对账即可。
      final dbB = await _makeDatabase();
      dbB.setDataKey(dataKey);
      await _seedMeta(dbB,
          encryptedDataKey: edkNew, keyVersion: 2, keyFingerprint: fpNew);
      final engineB = _makeEngine(
        backend: backend,
        database: dbB,
        keyring: _makeVault(
            keyVersion: 2, encryptedDataKey: edkNew, keyFingerprint: fpNew,
            mk: mkNew),
        deviceId: 'device-B',
        passphrase: kNewPassword,
      );

      final res = await engineB.sync();
      expect(res.success, isTrue);

      // —— 本地账本与远端一致（包裹完全相同），v4 无需任何回写/echo ——
      expect(await persistedEncryptedDataKey(dbB), edkNew);
      expect(await persistedKeyVersion(dbB), 2);
      expect(await persistedKeyFingerprint(dbB), fpNew);

      // —— 内存 keyring 与远端一致 ——
      expect(engineB.keyring.keyVersion, 2);
      expect(engineB.keyring.encryptedDataKey, edkNew);

      // —— 远端 header 保持新纪元不被回滚 ——
      final header = await _remoteHeader(backend);
      expect(header.keyVersion, 2,
          reason: '远端 keyVersion 不被回滚');
      expect(header.keyFingerprint, fpNew,
          reason: '远端 fingerprint 保持新值，header 自洽');
      expect(header.encryptedDataKey, edkNew);

      // —— 用户已持有新密码：无纪元不匹配提示（v4 无该标志）——
      expect(res.passwordEpochMismatch, isFalse);

      // —— 再次同步：完全正常 ——
      final res2 = await engineB.sync();
      expect(res2.success, isTrue);
    });
  });

  // ────────────────────────────────────────────
  // S6：A 改密码后保持打开；B 用新密码新建并同步；A（旧密码）点同步
  // v4（epoch 消除 §8.2[I] 选项 B）：A 旧会话检测到他端改密码 →
  // 同步中止 + 提示重登录（不再「继续拉取 + 标志提示」）。
  // ────────────────────────────────────────────
  group('S6: A 改密码后保持打开，B 用新密码新建并同步，A 旧会话同步被中止', () {
    test('A 旧会话同步中止并提示重登录；重登录后才能拉到 B 的笔记', () async {
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
        keyring: _makeVault(
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
      final manifestB = await ManifestCrypto.deserialize(dataKey, respB.ciphertext);
      expect(manifestB.items.keys, containsAll(['note-1', 'note-B']),
          reason: 'B 的笔记已 push 上远端（push 没坏）');

      // 3. A 保持旧会话（kv=1，旧密码）点同步——v4 选项 B：中止
      final dbA = await _makeDatabase();
      dbA.setDataKey(dataKey);
      await _seedMeta(dbA,
          encryptedDataKey: edkOld, keyVersion: 1, keyFingerprint: fpOld);
      final engineA = _makeEngine(
        backend: backend,
        database: dbA,
        keyring: _makeVault(
            keyVersion: 1, encryptedDataKey: edkOld, keyFingerprint: fpOld,
            mk: mkOld),
        deviceId: 'device-A-old',
        passphrase: kOldPassword,
      );
      final resA = await engineA.sync();

      // —— v4：A 旧会话检测到他端改密码 → 中止 + 提示重登录 ——
      expect(resA.success, isFalse,
          reason: 'A 旧会话同步应中止（远端已被新密码覆盖，本地密码过期）');
      expect(resA.errorMessage, contains('密码已在其他设备修改'),
          reason: 'errorMessage 提示「他端改了密码，请重新输入密码」');

      // —— 中止意味着零拉取：A 本地 DB 不含 B 的笔记 ——
      final notesOnA = await dbA.readAllNotesIncludingDeleted();
      expect(notesOnA.map((n) => n.uuid), isNot(contains('note-B')),
          reason: 'scenario-b 中止同步，A 不拉取任何笔记（选项 B 零写入）');

      // —— 远端不被回滚（翻转战争彻底消除）——
      final headerAfterA = await _remoteHeader(backend);
      expect(headerAfterA.encryptedDataKey, edkNew);
      expect(headerAfterA.keyVersion, 2);

      // 4. A 用新密码重登录后同步：正常拉到 B 的笔记（验证恢复路径）
      final dbA2 = await _makeDatabase();
      dbA2.setDataKey(dataKey);
      await _seedMeta(dbA2,
          encryptedDataKey: edkNew, keyVersion: 2, keyFingerprint: fpNew);
      final engineA2 = _makeEngine(
        backend: backend,
        database: dbA2,
        keyring: _makeVault(
            keyVersion: 2, encryptedDataKey: edkNew, keyFingerprint: fpNew,
            mk: mkNew),
        deviceId: 'device-A-new',
        passphrase: kNewPassword,
      );
      final resA2 = await engineA2.sync();
      expect(resA2.success, isTrue,
          reason: 'A 用新密码重登录后同步正常');
      final notesOnA2 = await dbA2.readAllNotesIncludingDeleted();
      expect(notesOnA2.map((n) => n.uuid), containsAll(['note-1', 'note-B']),
          reason: '重登录后 A 正常拉到 B 的笔记（恢复路径完整）');
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
      final keyring = _makeVault(
          keyVersion: 2, encryptedDataKey: edkNew, keyFingerprint: fpNew,
          mk: mkNew);

      final service = SyncService.instance;
      // journal 沙盒目录：注入测试替身（真实 path_provider 在纯 Dart 测试里不可用）
      final supportRoot = await Directory.systemTemp.createTemp('sn-bug-a');
      PathProviderPlatform.instance = _FakePathProvider(supportRoot.path);
      // 登录时离线：initialize 内部的 backend.init() 会抛错，
      // 与真实"进主界面就提示"同源。捕获后服务处于"引擎已建、后端未就绪"。
      bool initThrew = false;
      try {
        await service.initialize(keyring: keyring, backend: backend, database: db);
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
      try {
        await supportRoot.delete(recursive: true);
      } on Exception {
        // 忽略清理失败
      }
    });
  });
}
