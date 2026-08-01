/*
 * Keyring 单元测试
 *
 * 验证两层密钥架构的核心流程：
 *   - createNew：首次创建 keyring（生成 vaultId + dataKey + encryptedDataKey）
 *   - unlockLocal：本地解锁（正确密码 / 错误密码 / 未初始化）
 *   - unlockFromRemoteManifest：新设备从远端 manifest 解锁
 *   - changePassword：改密码（dataKey 不变 / 旧密码验证 / 新密码可解锁）
 *   - 多设备协调：设备 A 改密码 → 设备 B 用新密码解锁
 *
 * 使用 in-memory SQLite（sqflite_common_ffi）避免文件 IO。
 */

// Dart 导入
import 'dart:convert';
import 'dart:typed_data';

// Package 导入
import 'package:flutter_test/flutter_test.dart';
import 'package:safenotes/data/database_handler.dart';
import 'package:safenotes/models/safenote.dart';
import 'package:safenotes/sync/crypto.dart';
import 'package:safenotes/sync/sync_models.dart';
import 'package:safenotes/sync/keyring.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// 测试公共支撑（P2：Keyring/Journal 构造 + FakeBackend journal 存储）
import 'sync_test_support.dart';

/// 测试辅助：构造远端 manifest（header + 空 items）
///
/// 模拟设备 A 上传到远端的 manifest，设备 B 拉取后用于 unlockFromRemoteManifest。
Manifest _makeRemoteManifest({
  required int version,
  required String vaultId,
  required String encryptedDataKey,
  required String keyFingerprint,
  required int keyVersion,
  required KdfParams kdf,
  required int createdAt,
  int? updatedAt,
}) {
  return Manifest(
    header: ManifestHeader(
      schemaVersion: 1,
      version: version,
      vaultId: vaultId,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now().millisecondsSinceEpoch,
      keyFingerprint: keyFingerprint,
      keyVersion: keyVersion,
      encryptedDataKey: encryptedDataKey,
      kdf: kdf,
      dataKeyWrap: kDataKeyWrapAlgorithm,
      lastModifiedBy: 'test-device-a',
    ),
    items: {},
  );
}

void main() {
  // 初始化 sqflite_ffi（桌面测试用）
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late NotesDatabase database;

  setUp(() async {
    final db = await openDatabase(
      ':memory:',
      version: 2,
      onCreate: NotesDatabase.createDBForTesting,
    );
    NotesDatabase.setDatabaseForTesting(db);
    database = NotesDatabase.instance;
  });

  tearDown(() async {
    await database.close();
  });

  group('Keyring - createNew', () {
    test('创建新 keyring 生成 vaultId + dataKey + encryptedDataKey', () async {
      final keyring = await Keyring.createNew(
        password: 'test-password-123',
        database: database,
      );

      // vaultId 是 UUIDv4 格式（36 字符，含 4 个连字符）
      expect(keyring.vaultId.length, 36);
      expect(keyring.vaultId.split('-').length, 5);

      // dataKey 是 32 字节
      expect(keyring.dataKey.length, 32);

      // encryptedDataKey 是 base64 字符串
      final decoded = base64.decode(keyring.encryptedDataKey);
      // 信封格式：nonce(12) + ciphertext(32) + tag(16) = 60 字节
      expect(decoded.length, 60);

      // MK 应已缓存（用于后续迁移检查）
      expect(keyring.mk, isNotNull);
    });

    test('创建后 vaultId 和 encryptedDataKey 持久化到 meta 表', () async {
      final keyring = await Keyring.createNew(
        password: 'test-password-123',
        database: database,
      );

      // P2：密钥态落 MetaKeys.keyring 单键 JSON 账本，不再写散落键
      final ledger = await readPersistedKeyring(database);
      expect(ledger, isNotNull, reason: 'createNew 后账本应已落盘');
      expect(ledger!.vaultId, keyring.vaultId);
      expect(ledger.current.encryptedDataKey, keyring.encryptedDataKey);
      expect(ledger.current.keyVersion, 1);
      expect(ledger.current.dataKeyEpoch, 1);
      expect(ledger.current.reason, KeyringReason.create);
    });

    test('两次创建生成不同的 vaultId 和 dataKey', () async {
      final vault1 = await Keyring.createNew(
        password: 'password1',
        database: database,
      );

      // 清空账本以模拟全新状态（Keyring 单键 JSON；load 对空串返回 null）
      await database.setMeta(MetaKeys.keyring, '');

      final vault2 = await Keyring.createNew(
        password: 'password1',
        database: database,
      );

      expect(vault1.vaultId, isNot(equals(vault2.vaultId)));
      expect(
        vault1.dataKey,
        isNot(equals(vault2.dataKey)),
      );
    });

    test('isInitialized 在创建前返回 false，创建后返回 true', () async {
      expect(await Keyring.isInitialized(database), isFalse);

      await Keyring.createNew(
        password: 'test-password',
        database: database,
      );

      expect(await Keyring.isInitialized(database), isTrue);
    });
  });

  group('Keyring - unlockLocal', () {
    test('正确密码解锁成功，dataKey 与创建时一致', () async {
      // 先创建
      final created = await Keyring.createNew(
        password: 'correct-password',
        database: database,
      );

      // 用相同密码解锁
      final unlocked = await Keyring.unlockLocal(
        password: 'correct-password',
        database: database,
      );

      expect(unlocked.vaultId, created.vaultId);
      expect(unlocked.dataKey, created.dataKey);
      expect(unlocked.encryptedDataKey, created.encryptedDataKey);
      // MK 应已缓存
      expect(unlocked.mk, isNotNull);
    });

    test('错误密码抛 WrongPasswordException', () async {
      await Keyring.createNew(
        password: 'correct-password',
        database: database,
      );

      expect(
        () => Keyring.unlockLocal(
          password: 'wrong-password',
          database: database,
        ),
        throwsA(isA<WrongPasswordException>()),
      );
    });

    test('未初始化时抛 KeyringNotInitializedException', () async {
      // 不创建 keyring，直接尝试解锁
      expect(
        () => Keyring.unlockLocal(
          password: 'any-password',
          database: database,
        ),
        throwsA(isA<KeyringNotInitializedException>()),
      );
    });

    test('getVaultId / getEncryptedDataKey 读取本地元数据', () async {
      final keyring = await Keyring.createNew(
        password: 'test-password',
        database: database,
      );

      expect(await Keyring.getVaultId(database), keyring.vaultId);
      expect(
        await Keyring.getEncryptedDataKey(database),
        keyring.encryptedDataKey,
      );
    });
  });

  group('Keyring - unlockFromRemoteManifest', () {
    test('从远端 manifest 解锁，dataKey 与原始一致', () async {
      // 设备 A 创建 keyring
      final vaultA = await Keyring.createNew(
        password: 'shared-password',
        database: database,
      );

      // 构造远端 manifest（模拟设备 A 上传的）
      final manifest = _makeRemoteManifest(
        version: 1,
        vaultId: vaultA.vaultId,
        encryptedDataKey: vaultA.encryptedDataKey,
        keyFingerprint: vaultA.keyFingerprint,
        keyVersion: vaultA.keyVersion,
        kdf: vaultA.kdf,
        createdAt: vaultA.createdAt,
      );

      // 设备 B：新数据库（模拟新设备）
      await database.close();
      final dbB = await openDatabase(
        ':memory:',
        version: 2,
        onCreate: NotesDatabase.createDBForTesting,
      );
      NotesDatabase.setDatabaseForTesting(dbB);

      // 设备 B 用相同密码从远端 manifest 解锁
      final vaultB = await Keyring.unlockFromRemoteManifest(
        password: 'shared-password',
        remoteVaultId: manifest.vaultId,
        remoteEncryptedDataKey: manifest.encryptedDataKey,
        remoteKdf: manifest.header.kdf,
        remoteKeyFingerprint: manifest.header.keyFingerprint,
        remoteKeyVersion: manifest.header.keyVersion,
        remoteCreatedAt: manifest.header.createdAt,
        database: database,
      );

      // 验证：dataKey 与设备 A 一致（能互解笔记）
      expect(vaultB.vaultId, vaultA.vaultId);
      expect(vaultB.dataKey, vaultA.dataKey);
      expect(vaultB.encryptedDataKey, vaultA.encryptedDataKey);
    });

    test('从 manifest 解锁时错误密码抛 WrongPasswordException', () async {
      final vaultA = await Keyring.createNew(
        password: 'correct-password',
        database: database,
      );

      final manifest = _makeRemoteManifest(
        version: 1,
        vaultId: vaultA.vaultId,
        encryptedDataKey: vaultA.encryptedDataKey,
        keyFingerprint: vaultA.keyFingerprint,
        keyVersion: vaultA.keyVersion,
        kdf: vaultA.kdf,
        createdAt: vaultA.createdAt,
      );

      expect(
        () => Keyring.unlockFromRemoteManifest(
          password: 'wrong-password',
          remoteVaultId: manifest.vaultId,
          remoteEncryptedDataKey: manifest.encryptedDataKey,
          remoteKdf: manifest.header.kdf,
          remoteKeyFingerprint: manifest.header.keyFingerprint,
          remoteKeyVersion: manifest.header.keyVersion,
          remoteCreatedAt: manifest.header.createdAt,
          database: database,
        ),
        throwsA(isA<WrongPasswordException>()),
      );
    });

    test('从 manifest 解锁后持久化到本地（后续可用 unlockLocal）', () async {
      final vaultA = await Keyring.createNew(
        password: 'shared-password',
        database: database,
      );

      final manifest = _makeRemoteManifest(
        version: 1,
        vaultId: vaultA.vaultId,
        encryptedDataKey: vaultA.encryptedDataKey,
        keyFingerprint: vaultA.keyFingerprint,
        keyVersion: vaultA.keyVersion,
        kdf: vaultA.kdf,
        createdAt: vaultA.createdAt,
      );

      // 新设备从 manifest 解锁
      await database.close();
      final dbB = await openDatabase(
        ':memory:',
        version: 2,
        onCreate: NotesDatabase.createDBForTesting,
      );
      NotesDatabase.setDatabaseForTesting(dbB);

      await Keyring.unlockFromRemoteManifest(
        password: 'shared-password',
        remoteVaultId: manifest.vaultId,
        remoteEncryptedDataKey: manifest.encryptedDataKey,
        remoteKdf: manifest.header.kdf,
        remoteKeyFingerprint: manifest.header.keyFingerprint,
        remoteKeyVersion: manifest.header.keyVersion,
        remoteCreatedAt: manifest.header.createdAt,
        database: database,
      );

      // 验证已持久化，可用 unlockLocal 直接解锁
      final unlocked = await Keyring.unlockLocal(
        password: 'shared-password',
        database: database,
      );
      expect(unlocked.dataKey, vaultA.dataKey);
    });
  });

  group('Keyring - changePassword', () {
    test('改密码后 dataKey 不变，encryptedDataKey 变化', () async {
      final keyring = await Keyring.createNew(
        password: 'old-password',
        database: database,
      );

      final oldDataKey = keyring.dataKey;
      final oldEncryptedDataKey = keyring.encryptedDataKey;

      final newKeyring = await keyring.changePassword(
        oldPassword: 'old-password',
        newPassword: 'new-password',
        database: database,
      );

      // dataKey 不变
      expect(newKeyring.dataKey, oldDataKey);
      // encryptedDataKey 变化
      expect(newKeyring.encryptedDataKey, isNot(equals(oldEncryptedDataKey)));
      // vaultId 不变
      expect(newKeyring.vaultId, keyring.vaultId);
    });

    test('改密码后新密码可解锁，旧密码不可解锁', () async {
      final keyring = await Keyring.createNew(
        password: 'old-password',
        database: database,
      );

      await keyring.changePassword(
        oldPassword: 'old-password',
        newPassword: 'new-password',
        database: database,
      );

      // 新密码可解锁
      final unlocked = await Keyring.unlockLocal(
        password: 'new-password',
        database: database,
      );
      expect(unlocked.dataKey, keyring.dataKey);

      // 旧密码不可解锁
      expect(
        () => Keyring.unlockLocal(
          password: 'old-password',
          database: database,
        ),
        throwsA(isA<WrongPasswordException>()),
      );
    });

    test('旧密码错误时抛 WrongPasswordException', () async {
      final keyring = await Keyring.createNew(
        password: 'correct-old-password',
        database: database,
      );

      expect(
        () => keyring.changePassword(
          oldPassword: 'wrong-old-password',
          newPassword: 'new-password',
          database: database,
        ),
        throwsA(isA<WrongPasswordException>()),
      );
    });

    test('改密码后 encryptedDataKey 持久化到 meta 表', () async {
      final keyring = await Keyring.createNew(
        password: 'old-password',
        database: database,
      );

      final newKeyring = await keyring.changePassword(
        oldPassword: 'old-password',
        newPassword: 'new-password',
        database: database,
      );

      expect(await persistedEncryptedDataKey(database),
          newKeyring.encryptedDataKey);
      expect(await persistedKeyVersion(database), 2,
          reason: '改密码 keyVersion +1');
      expect(await persistedDataKeyEpoch(database), 1,
          reason: '改密码不动 dataKey，纪元必须原地不动');
    });
  });

  group('Keyring - 多设备协调', () {
    test('设备 A 改密码 → 设备 B 同步后用新密码解锁', () async {
      // 设备 A 创建 keyring
      final vaultA = await Keyring.createNew(
        password: 'original-password',
        database: database,
      );
      final originalDataKey = vaultA.dataKey;

      // 设备 A 改密码
      final vaultAAfterChange = await vaultA.changePassword(
        oldPassword: 'original-password',
        newPassword: 'new-password',
        database: database,
      );

      // 设备 A 同步后 manifest 包含新的 encryptedDataKey
      final manifest = _makeRemoteManifest(
        version: 2,
        vaultId: vaultA.vaultId,
        encryptedDataKey: vaultAAfterChange.encryptedDataKey,
        keyFingerprint: vaultAAfterChange.keyFingerprint,
        keyVersion: vaultAAfterChange.keyVersion,
        kdf: vaultAAfterChange.kdf,
        createdAt: vaultAAfterChange.createdAt,
      );

      // 设备 B：新数据库，从远端 manifest 解锁
      await database.close();
      final dbB = await openDatabase(
        ':memory:',
        version: 2,
        onCreate: NotesDatabase.createDBForTesting,
      );
      NotesDatabase.setDatabaseForTesting(dbB);

      // 设备 B 用新密码解锁
      final vaultB = await Keyring.unlockFromRemoteManifest(
        password: 'new-password',
        remoteVaultId: manifest.vaultId,
        remoteEncryptedDataKey: manifest.encryptedDataKey,
        remoteKdf: manifest.header.kdf,
        remoteKeyFingerprint: manifest.header.keyFingerprint,
        remoteKeyVersion: manifest.header.keyVersion,
        remoteCreatedAt: manifest.header.createdAt,
        database: database,
      );

      // 验证：设备 B 解出的 dataKey 与设备 A 原始 dataKey 一致
      expect(vaultB.dataKey, originalDataKey);

      // 设备 B 用旧密码无法解锁
      expect(
        () => Keyring.unlockLocal(
          password: 'original-password',
          database: database,
        ),
        throwsA(isA<WrongPasswordException>()),
      );
    });

    test('改密码不改变 dataKey（笔记信封无需重新加密）', () async {
      final keyring = await Keyring.createNew(
        password: 'old-password',
        database: database,
      );

      // 用 dataKey 加密一条笔记
      final plaintext =
          Uint8List.fromList(utf8.encode('{"title":"Test","description":"Hello"}'));
      final envelope = SyncCrypto.seal(
        keyring.dataKey,
        'note-uuid-1',
        plaintext,
      );

      // 改密码
      final newKeyring = await keyring.changePassword(
        oldPassword: 'old-password',
        newPassword: 'new-password',
        database: database,
      );

      // 用新 keyring 的 dataKey（应与旧 dataKey 相同）解密信封
      final decrypted = SyncCrypto.open(
        newKeyring.dataKey,
        'note-uuid-1',
        envelope,
      );

      expect(decrypted, plaintext);
      expect(newKeyring.dataKey, keyring.dataKey);
    });
  });

  group('Keyring - dataKey 迁移检查', () {
    test('checkMigrationNeeded：远端 encryptedDataKey 相同时无需迁移', () async {
      final keyring = await Keyring.createNew(
        password: 'test-password',
        database: database,
      );

      // 构造无 MK 缓存的 Keyring（模拟 SyncEngine 中 Keyring 未缓存 MK 的场景）
      // checkMigrationNeeded 应先比较 encryptedDataKey，相同时直接返回无需迁移
      final vaultNoMk = makeTestKeyring(
        vaultId: keyring.vaultId,
        dataKey: keyring.dataKey,
        encryptedDataKey: keyring.encryptedDataKey,
        keyFingerprint: keyring.keyFingerprint,
        keyVersion: keyring.keyVersion,
        kdf: keyring.kdf,
        createdAt: keyring.createdAt,
      );

      final result = vaultNoMk.checkMigrationNeeded(keyring.encryptedDataKey);
      expect(result.needsMigration, isFalse);
      expect(result.success, isTrue);
    });

    test('checkMigrationNeeded：远端 encryptedDataKey 不同且 MK 已缓存 → 迁移成功', () async {
      final keyring = await Keyring.createNew(
        password: 'test-password',
        database: database,
      );

      // 用相同 MK 包装一个不同的 dataKey（模拟远端换了 dataKey）
      final remoteDataKey = SyncCrypto.generateDataKey();
      final remoteEncryptedDataKey = base64.encode(
        SyncCrypto.wrapDataKey(keyring.mk!, remoteDataKey),
      );

      final result = keyring.checkMigrationNeeded(remoteEncryptedDataKey);
      expect(result.needsMigration, isTrue);
      expect(result.success, isTrue);
      expect(result.remoteDataKey, remoteDataKey);
      expect(result.remoteEncryptedDataKey, remoteEncryptedDataKey);
    });

    test('checkMigrationNeeded：MK 未缓存且 encryptedDataKey 不同 → 失败', () async {
      final keyring = await Keyring.createNew(
        password: 'test-password',
        database: database,
      );

      // 构造无 MK 缓存的 Keyring
      final vaultNoMk = makeTestKeyring(
        vaultId: keyring.vaultId,
        dataKey: keyring.dataKey,
        encryptedDataKey: keyring.encryptedDataKey,
        keyFingerprint: keyring.keyFingerprint,
        keyVersion: keyring.keyVersion,
        kdf: keyring.kdf,
        createdAt: keyring.createdAt,
      );

      // 远端 encryptedDataKey 不同，但本地无 MK → 失败
      final result = vaultNoMk.checkMigrationNeeded('different-encrypted-key');
      expect(result.needsMigration, isTrue);
      expect(result.success, isFalse);
      expect(result.error, contains('MK 未缓存'));
    });

    test('migrateToRemote：重新加密本地笔记并更新 dataKey', () async {
      final keyring = await Keyring.createNew(
        password: 'test-password',
        database: database,
      );

      // 注入 dataKey 到 database 并存储笔记
      database.setDataKey(keyring.dataKey);
      final note = SafeNoteForTest(
        uuid: 'test-uuid-1',
        title: 'Test Title',
        description: 'Test Description',
      );
      await database.storeNote(note.toSafeNote());

      // 生成远端 dataKey 并用本地 MK 包装
      final remoteDataKey = SyncCrypto.generateDataKey();
      final remoteEncryptedDataKey = base64.encode(
        SyncCrypto.wrapDataKey(keyring.mk!, remoteDataKey),
      );

      final migrationResult = keyring.checkMigrationNeeded(remoteEncryptedDataKey);
      expect(migrationResult.needsMigration, isTrue);

      // 执行迁移
      final newKeyring = await keyring.migrateToRemote(
        result: migrationResult,
        database: database,
      );

      // 验证：keyring 的 dataKey 已更新为远端 dataKey
      expect(newKeyring.dataKey, remoteDataKey);
      expect(newKeyring.encryptedDataKey, remoteEncryptedDataKey);

      // 验证：database 的 dataKey 也已更新
      expect(database.dataKeyForTesting, remoteDataKey);

      // 验证：本地笔记能用新 dataKey 解密
      final notes = await database.readAllNotesIncludingDeleted();
      expect(notes.length, 1);
      expect(notes.first.title, 'Test Title');
      expect(notes.first.description, 'Test Description');

      // 验证：本地 keyring 账本已更新
      expect(await persistedEncryptedDataKey(database), remoteEncryptedDataKey);
    });
  });

  // ════════════════════════════════════════════
  // P2 收敛后的新增回归组
  // ════════════════════════════════════════════

  group('P2 - adoptRemoteEpoch', () {
    test('采用远端纪元后 dataKey 原封不动（C2 回归：绝不能丢明文密钥）', () async {
      final keyring = await Keyring.createNew(
        password: 'pw-adopt-1',
        database: database,
      );
      final dataKeyBefore = Uint8List.fromList(keyring.dataKey);
      final mkBefore = keyring.mk == null
          ? null
          : Uint8List.fromList(keyring.mk!);

      await keyring.adoptRemoteEpoch(
        remoteEncryptedDataKey: 'REMOTE-EDK-BASE64',
        remoteKeyFingerprint: 'remote-fp',
        remoteKeyVersion: 7,
        remoteDataKeyEpoch: 3,
        database: database,
      );

      // 三元组整体收敛到远端（B1-2：不能只改一个字段）
      expect(keyring.encryptedDataKey, 'REMOTE-EDK-BASE64');
      expect(keyring.keyFingerprint, 'remote-fp');
      expect(keyring.keyVersion, 7);
      expect(keyring.dataKeyEpoch, 3);

      // 运行时明文密钥不受影响——这是本用例存在的唯一理由
      expect(keyring.dataKey, dataKeyBefore,
          reason: 'adoptRemoteEpoch 只换包裹态，明文 dataKey 必须原样保留');
      expect(keyring.mk, mkBefore, reason: 'MK 同理不被触碰');
    });

    test('原地更新会落盘（BUG-3 回归：本地纪元不能落后于内存）', () async {
      final keyring = await Keyring.createNew(
        password: 'pw-adopt-2',
        database: database,
      );

      await keyring.adoptRemoteEpoch(
        remoteEncryptedDataKey: 'EDK-V9',
        remoteKeyFingerprint: 'fp-v9',
        remoteKeyVersion: 9,
        remoteDataKeyEpoch: 2,
        database: database,
      );

      // 内存与磁盘必须一致：只改内存 → 重启后回退到旧纪元 → 反复误报 mismatch
      expect(await persistedKeyVersion(database), 9);
      expect(await persistedKeyFingerprint(database), 'fp-v9');
      expect(await persistedEncryptedDataKey(database), 'EDK-V9');
      expect(await persistedDataKeyEpoch(database), 2);
    });

    test('采用与当前一致的包裹值时不抛异常且状态不变（幂等）', () async {
      final keyring = await Keyring.createNew(
        password: 'pw-adopt-3',
        database: database,
      );
      final sameEdk = keyring.encryptedDataKey;

      await keyring.adoptRemoteEpoch(
        remoteEncryptedDataKey: sameEdk,
        remoteKeyFingerprint: keyring.keyFingerprint,
        remoteKeyVersion: keyring.keyVersion,
        database: database,
      );

      // 包裹值没变：current 保持原值，落盘后读回一致
      expect(keyring.encryptedDataKey, sameEdk);
      expect(await persistedEncryptedDataKey(database), sameEdk);
    });

    test('P7 回归：纪元实际递增时标记全部 blob 重传（adoptRemoteEpoch 生产侧根因）',
        () async {
      final keyring = await Keyring.createNew(
        password: 'pw-adopt-p7',
        database: database,
      );
      // 本地已有 2 条笔记（epoch 1 blob 已上传过）
      await database.storeNote(SafeNote(
        uuid: 'note-p7-1',
        title: 'n1',
        description: 'd1',
        contentHash: SafeNote.computeHash('n1', 'd1'),
        deleted: false,
        createdTime: DateTime.now(),
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        synced: true,
      ));
      await database.storeNote(SafeNote(
        uuid: 'note-p7-2',
        title: 'n2',
        description: 'd2',
        contentHash: SafeNote.computeHash('n2', 'd2'),
        deleted: false,
        createdTime: DateTime.now(),
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        synced: true,
      ));
      expect(await database.getPendingReuploadUuids(), isEmpty);

      // 远端纪元 2 > 本地 1：采用后必须触发 blob 重传标记
      await keyring.adoptRemoteEpoch(
        remoteEncryptedDataKey: 'EDK-P7',
        remoteKeyFingerprint: 'fp-p7',
        remoteKeyVersion: 8,
        remoteDataKeyEpoch: 2,
        database: database,
      );

      final pending = await database.getPendingReuploadUuids();
      expect(pending, containsAll(['note-p7-1', 'note-p7-2']),
          reason: '纪元递增必须把本地 blob 标记重传，'
              '否则 manifest 乐观声明新纪元而 blob 仍是旧纪元（P7 根因）');
      expect(keyring.dataKeyEpoch, 2);
    });

    test('P7 回归：纪元不变时采用不触发 blob 重传（改密码场景）', () async {
      final keyring = await Keyring.createNew(
        password: 'pw-adopt-p7b',
        database: database,
      );
      await database.storeNote(SafeNote(
        uuid: 'note-p7-3',
        title: 'n3',
        description: 'd3',
        contentHash: SafeNote.computeHash('n3', 'd3'),
        deleted: false,
        createdTime: DateTime.now(),
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        synced: true,
      ));

      // 改密码场景：dataKeyEpoch 不变，只是包裹态变化 → 不该触发全量重传
      await keyring.adoptRemoteEpoch(
        remoteEncryptedDataKey: 'EDK-P7B',
        remoteKeyFingerprint: 'fp-p7b',
        remoteKeyVersion: 5,
        remoteDataKeyEpoch: 1,
        database: database,
      );

      expect(await database.getPendingReuploadUuids(), isEmpty,
          reason: '纪元未变、dataKey 值未变，blob 仍是当前纪元，无需重传');
    });
  });

  group('P2 - copyWithCurrent（纯函数版等价性）', () {
    test('字段级更新保留运行时 dataKey/mk', () async {
      final keyring = await Keyring.createNew(
        password: 'pw-copy',
        database: database,
      );
      final updated = keyring.copyWithCurrent(
        encryptedDataKey: 'NEW-EDK',
        keyVersion: 5,
      );

      expect(updated.encryptedDataKey, 'NEW-EDK');
      expect(updated.keyVersion, 5);
      expect(updated.dataKey, keyring.dataKey);
      expect(updated.mk, keyring.mk);
      // 未指定的字段保持原值
      expect(updated.vaultId, keyring.vaultId);
      expect(updated.dataKeyEpoch, keyring.dataKeyEpoch);
    });
  });

  group('P2 - toManifestHeader（唯一投影点）', () {
    test('无 override 时逐字段映射 keyring 状态', () async {
      final keyring = await Keyring.createNew(
        password: 'pw-hdr-1',
        database: database,
      );
      final header = keyring.toManifestHeader(
        version: 42,
        updatedAt: 1700000000000,
        lastModifiedBy: 'device-X',
      );

      expect(header.vaultId, keyring.vaultId);
      expect(header.createdAt, keyring.createdAt);
      expect(header.encryptedDataKey, keyring.encryptedDataKey);
      expect(header.keyFingerprint, keyring.keyFingerprint);
      expect(header.keyVersion, keyring.keyVersion);
      expect(header.dataKeyEpoch, keyring.dataKeyEpoch);
      expect(header.kdf.salt, keyring.kdf.salt);
      expect(header.kdf.iterations, keyring.kdf.iterations);
      expect(header.version, 42);
      expect(header.updatedAt, 1700000000000);
      expect(header.lastModifiedBy, 'device-X');
      expect(header.schemaVersion, 1);
      expect(header.dataKeyWrap, kDataKeyWrapAlgorithm);
    });

    test('override 三元组整体生效，其余字段仍来自 keyring（B1-2 回归）', () async {
      final keyring = await Keyring.createNew(
        password: 'pw-hdr-2',
        database: database,
      );
      final header = keyring.toManifestHeader(
        version: 2,
        updatedAt: 1,
        lastModifiedBy: 'device-Y',
        overrideEncryptedDataKey: 'EDK-REMOTE',
        overrideKeyFingerprint: 'FP-REMOTE',
        overrideKeyVersion: 11,
      );

      expect(header.encryptedDataKey, 'EDK-REMOTE');
      expect(header.keyFingerprint, 'FP-REMOTE');
      expect(header.keyVersion, 11);
      // vaultId/kdf/createdAt/dataKeyEpoch 不在 override 范围内
      expect(header.vaultId, keyring.vaultId);
      expect(header.dataKeyEpoch, keyring.dataKeyEpoch);
    });

    test('序列化→反序列化后 header 字段完全一致（防漏字段）', () async {
      final keyring = await Keyring.createNew(
        password: 'pw-hdr-3',
        database: database,
      );
      final header = keyring.toManifestHeader(
        version: 3,
        updatedAt: 1700000000001,
        lastModifiedBy: 'device-Z',
      );
      final restored =
          ManifestHeader.fromJson(jsonDecode(jsonEncode(header.toJson())));

      expect(restored.toJson(), header.toJson(),
          reason: 'toManifestHeader 是 SyncEngine 唯一的 header 构造点，'
              '任何字段漏填都会在这里暴露');
    });
  });

  group('P2 - KeyringLedger 持久化', () {
    test('账本 JSON round-trip 保真', () {
      final ledger = KeyringLedger(
        vaultId: 'v-rt',
        kdf: KdfParams.create(salt: SyncCrypto.generateSalt()),
        createdAt: 1700000000000,
        current: const KeyringEntry(
          keyFingerprint: 'fp-cur',
          encryptedDataKey: 'edk-cur',
          keyVersion: 3,
          dataKeyEpoch: 2,
          reason: KeyringReason.changePassword,
        ),
      );

      final restored = KeyringLedger.fromJson(
          jsonDecode(jsonEncode(ledger.toJson())) as Map<String, dynamic>);

      expect(restored.toJson(), ledger.toJson());
    });

    test('load：缺失键返回 null（未初始化）', () async {
      expect(await KeyringLedger.load(database), isNull);
    });

    test('load：写入单键后能读回（P2 单键 JSON 账本）', () async {
      final ledger = KeyringLedger(
        vaultId: 'v-load',
        kdf: KdfParams.create(salt: SyncCrypto.generateSalt()),
        createdAt: 1700000000000,
        current: const KeyringEntry(
          keyFingerprint: 'fp-load',
          encryptedDataKey: 'edk-load',
          keyVersion: 2,
          dataKeyEpoch: 1,
          reason: KeyringReason.changePassword,
        ),
      );
      await ledger.persist(database);

      final loaded = await KeyringLedger.load(database);
      expect(loaded, isNotNull);
      expect(loaded!.vaultId, 'v-load');
      expect(loaded.current.encryptedDataKey, 'edk-load');
      expect(await database.getMeta(MetaKeys.keyring), isNotNull,
          reason: '账本只写 MetaKeys.keyring 单键');
    });

    test('load：JSON 损坏返回 null 而不是抛异常', () async {
      await database.setMeta(MetaKeys.keyring, '{not valid json');
      expect(await KeyringLedger.load(database), isNull,
          reason: '账本损坏要能降级到"未初始化"，而不是让 App 崩在启动路径上');
    });
  });
}

/// 测试辅助：构造 SafeNote（避免外部依赖）
class SafeNoteForTest {
  final String uuid;
  final String title;
  final String description;

  SafeNoteForTest({
    required this.uuid,
    required this.title,
    required this.description,
  });

  SafeNote toSafeNote() {
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
}
