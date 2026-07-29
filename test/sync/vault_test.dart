/*
 * Vault 单元测试
 *
 * 验证两层密钥架构的核心流程：
 *   - createNew：首次创建 vault（生成 vaultId + dataKey + encryptedDataKey）
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
import 'package:safenotes/sync/vault.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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

  group('Vault - createNew', () {
    test('创建新 vault 生成 vaultId + dataKey + encryptedDataKey', () async {
      final vault = await Vault.createNew(
        password: 'test-password-123',
        database: database,
      );

      // vaultId 是 UUIDv4 格式（36 字符，含 4 个连字符）
      expect(vault.vaultId.length, 36);
      expect(vault.vaultId.split('-').length, 5);

      // dataKey 是 32 字节
      expect(vault.dataKey.length, 32);

      // encryptedDataKey 是 base64 字符串
      final decoded = base64.decode(vault.encryptedDataKey);
      // 信封格式：nonce(12) + ciphertext(32) + tag(16) = 60 字节
      expect(decoded.length, 60);

      // MK 应已缓存（用于后续迁移检查）
      expect(vault.mk, isNotNull);
    });

    test('创建后 vaultId 和 encryptedDataKey 持久化到 meta 表', () async {
      final vault = await Vault.createNew(
        password: 'test-password-123',
        database: database,
      );

      final storedVaultId = await database.getMeta(MetaKeys.vaultId);
      final storedEncryptedDataKey =
          await database.getMeta(MetaKeys.encryptedDataKey);

      expect(storedVaultId, vault.vaultId);
      expect(storedEncryptedDataKey, vault.encryptedDataKey);
    });

    test('两次创建生成不同的 vaultId 和 dataKey', () async {
      final vault1 = await Vault.createNew(
        password: 'password1',
        database: database,
      );

      // 清空 meta 表以模拟全新状态
      await database.setMeta(MetaKeys.vaultId, '');
      await database.setMeta(MetaKeys.encryptedDataKey, '');

      final vault2 = await Vault.createNew(
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
      expect(await Vault.isInitialized(database), isFalse);

      await Vault.createNew(
        password: 'test-password',
        database: database,
      );

      expect(await Vault.isInitialized(database), isTrue);
    });
  });

  group('Vault - unlockLocal', () {
    test('正确密码解锁成功，dataKey 与创建时一致', () async {
      // 先创建
      final created = await Vault.createNew(
        password: 'correct-password',
        database: database,
      );

      // 用相同密码解锁
      final unlocked = await Vault.unlockLocal(
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
      await Vault.createNew(
        password: 'correct-password',
        database: database,
      );

      expect(
        () => Vault.unlockLocal(
          password: 'wrong-password',
          database: database,
        ),
        throwsA(isA<WrongPasswordException>()),
      );
    });

    test('未初始化时抛 VaultNotInitializedException', () async {
      // 不创建 vault，直接尝试解锁
      expect(
        () => Vault.unlockLocal(
          password: 'any-password',
          database: database,
        ),
        throwsA(isA<VaultNotInitializedException>()),
      );
    });

    test('getVaultId / getEncryptedDataKey 读取本地元数据', () async {
      final vault = await Vault.createNew(
        password: 'test-password',
        database: database,
      );

      expect(await Vault.getVaultId(database), vault.vaultId);
      expect(
        await Vault.getEncryptedDataKey(database),
        vault.encryptedDataKey,
      );
    });
  });

  group('Vault - unlockFromRemoteManifest', () {
    test('从远端 manifest 解锁，dataKey 与原始一致', () async {
      // 设备 A 创建 vault
      final vaultA = await Vault.createNew(
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
      final vaultB = await Vault.unlockFromRemoteManifest(
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
      final vaultA = await Vault.createNew(
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
        () => Vault.unlockFromRemoteManifest(
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
      final vaultA = await Vault.createNew(
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

      await Vault.unlockFromRemoteManifest(
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
      final unlocked = await Vault.unlockLocal(
        password: 'shared-password',
        database: database,
      );
      expect(unlocked.dataKey, vaultA.dataKey);
    });
  });

  group('Vault - changePassword', () {
    test('改密码后 dataKey 不变，encryptedDataKey 变化', () async {
      final vault = await Vault.createNew(
        password: 'old-password',
        database: database,
      );

      final oldDataKey = vault.dataKey;
      final oldEncryptedDataKey = vault.encryptedDataKey;

      final newVault = await vault.changePassword(
        oldPassword: 'old-password',
        newPassword: 'new-password',
        database: database,
      );

      // dataKey 不变
      expect(newVault.dataKey, oldDataKey);
      // encryptedDataKey 变化
      expect(newVault.encryptedDataKey, isNot(equals(oldEncryptedDataKey)));
      // vaultId 不变
      expect(newVault.vaultId, vault.vaultId);
    });

    test('改密码后新密码可解锁，旧密码不可解锁', () async {
      final vault = await Vault.createNew(
        password: 'old-password',
        database: database,
      );

      await vault.changePassword(
        oldPassword: 'old-password',
        newPassword: 'new-password',
        database: database,
      );

      // 新密码可解锁
      final unlocked = await Vault.unlockLocal(
        password: 'new-password',
        database: database,
      );
      expect(unlocked.dataKey, vault.dataKey);

      // 旧密码不可解锁
      expect(
        () => Vault.unlockLocal(
          password: 'old-password',
          database: database,
        ),
        throwsA(isA<WrongPasswordException>()),
      );
    });

    test('旧密码错误时抛 WrongPasswordException', () async {
      final vault = await Vault.createNew(
        password: 'correct-old-password',
        database: database,
      );

      expect(
        () => vault.changePassword(
          oldPassword: 'wrong-old-password',
          newPassword: 'new-password',
          database: database,
        ),
        throwsA(isA<WrongPasswordException>()),
      );
    });

    test('改密码后 encryptedDataKey 持久化到 meta 表', () async {
      final vault = await Vault.createNew(
        password: 'old-password',
        database: database,
      );

      final newVault = await vault.changePassword(
        oldPassword: 'old-password',
        newPassword: 'new-password',
        database: database,
      );

      final stored = await database.getMeta(MetaKeys.encryptedDataKey);
      expect(stored, newVault.encryptedDataKey);
    });
  });

  group('Vault - 多设备协调', () {
    test('设备 A 改密码 → 设备 B 同步后用新密码解锁', () async {
      // 设备 A 创建 vault
      final vaultA = await Vault.createNew(
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
      final vaultB = await Vault.unlockFromRemoteManifest(
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
        () => Vault.unlockLocal(
          password: 'original-password',
          database: database,
        ),
        throwsA(isA<WrongPasswordException>()),
      );
    });

    test('改密码不改变 dataKey（笔记信封无需重新加密）', () async {
      final vault = await Vault.createNew(
        password: 'old-password',
        database: database,
      );

      // 用 dataKey 加密一条笔记
      final plaintext =
          Uint8List.fromList(utf8.encode('{"title":"Test","description":"Hello"}'));
      final envelope = SyncCrypto.seal(
        vault.dataKey,
        'note-uuid-1',
        plaintext,
      );

      // 改密码
      final newVault = await vault.changePassword(
        oldPassword: 'old-password',
        newPassword: 'new-password',
        database: database,
      );

      // 用新 vault 的 dataKey（应与旧 dataKey 相同）解密信封
      final decrypted = SyncCrypto.open(
        newVault.dataKey,
        'note-uuid-1',
        envelope,
      );

      expect(decrypted, plaintext);
      expect(newVault.dataKey, vault.dataKey);
    });
  });

  group('Vault - dataKey 迁移检查', () {
    test('checkMigrationNeeded：远端 encryptedDataKey 相同时无需迁移', () async {
      final vault = await Vault.createNew(
        password: 'test-password',
        database: database,
      );

      // 构造无 MK 缓存的 Vault（模拟 SyncEngine 中 Vault 未缓存 MK 的场景）
      // checkMigrationNeeded 应先比较 encryptedDataKey，相同时直接返回无需迁移
      final vaultNoMk = Vault(
        vaultId: vault.vaultId,
        dataKey: vault.dataKey,
        encryptedDataKey: vault.encryptedDataKey,
        keyFingerprint: vault.keyFingerprint,
        keyVersion: vault.keyVersion,
        kdf: vault.kdf,
        createdAt: vault.createdAt,
      );

      final result = vaultNoMk.checkMigrationNeeded(vault.encryptedDataKey);
      expect(result.needsMigration, isFalse);
      expect(result.success, isTrue);
    });

    test('checkMigrationNeeded：远端 encryptedDataKey 不同且 MK 已缓存 → 迁移成功', () async {
      final vault = await Vault.createNew(
        password: 'test-password',
        database: database,
      );

      // 用相同 MK 包装一个不同的 dataKey（模拟远端换了 dataKey）
      final remoteDataKey = SyncCrypto.generateDataKey();
      final remoteEncryptedDataKey = base64.encode(
        SyncCrypto.wrapDataKey(vault.mk!, remoteDataKey),
      );

      final result = vault.checkMigrationNeeded(remoteEncryptedDataKey);
      expect(result.needsMigration, isTrue);
      expect(result.success, isTrue);
      expect(result.remoteDataKey, remoteDataKey);
      expect(result.remoteEncryptedDataKey, remoteEncryptedDataKey);
    });

    test('checkMigrationNeeded：MK 未缓存且 encryptedDataKey 不同 → 失败', () async {
      final vault = await Vault.createNew(
        password: 'test-password',
        database: database,
      );

      // 构造无 MK 缓存的 Vault
      final vaultNoMk = Vault(
        vaultId: vault.vaultId,
        dataKey: vault.dataKey,
        encryptedDataKey: vault.encryptedDataKey,
        keyFingerprint: vault.keyFingerprint,
        keyVersion: vault.keyVersion,
        kdf: vault.kdf,
        createdAt: vault.createdAt,
      );

      // 远端 encryptedDataKey 不同，但本地无 MK → 失败
      final result = vaultNoMk.checkMigrationNeeded('different-encrypted-key');
      expect(result.needsMigration, isTrue);
      expect(result.success, isFalse);
      expect(result.error, contains('MK 未缓存'));
    });

    test('migrateToRemote：重新加密本地笔记并更新 dataKey', () async {
      final vault = await Vault.createNew(
        password: 'test-password',
        database: database,
      );

      // 注入 dataKey 到 database 并存储笔记
      database.setDataKey(vault.dataKey);
      final note = SafeNoteForTest(
        uuid: 'test-uuid-1',
        title: 'Test Title',
        description: 'Test Description',
      );
      await database.storeNote(note.toSafeNote());

      // 生成远端 dataKey 并用本地 MK 包装
      final remoteDataKey = SyncCrypto.generateDataKey();
      final remoteEncryptedDataKey = base64.encode(
        SyncCrypto.wrapDataKey(vault.mk!, remoteDataKey),
      );

      final migrationResult = vault.checkMigrationNeeded(remoteEncryptedDataKey);
      expect(migrationResult.needsMigration, isTrue);

      // 执行迁移
      final newVault = await vault.migrateToRemote(
        result: migrationResult,
        database: database,
      );

      // 验证：vault 的 dataKey 已更新为远端 dataKey
      expect(newVault.dataKey, remoteDataKey);
      expect(newVault.encryptedDataKey, remoteEncryptedDataKey);

      // 验证：database 的 dataKey 也已更新
      expect(database.dataKeyForTesting, remoteDataKey);

      // 验证：本地笔记能用新 dataKey 解密
      final notes = await database.readAllNotesIncludingDeleted();
      expect(notes.length, 1);
      expect(notes.first.title, 'Test Title');
      expect(notes.first.description, 'Test Description');

      // 验证：本地 meta 已更新
      final storedEncryptedDataKey =
          await database.getMeta(MetaKeys.encryptedDataKey);
      expect(storedEncryptedDataKey, remoteEncryptedDataKey);
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
