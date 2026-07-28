/*
 * Vault 密钥管理
 *
 * 两层密钥架构（参考 simplified-sync-design.md §4）：
 *   MK  = PBKDF2-HMAC-SHA256(password, FIXED_SALT='safenotes-v1', 200k)  ← 改密码时变化
 *   dataKey = 随机 32 字节                                              ← 永不变化
 *   encryptedDataKey = AES-GCM(MK, dataKey)                              ← 存 manifest header
 *
 * 多端一致性关键：
 *   - MK 派生使用固定 salt，确保相同密码在所有设备派生出相同 MK
 *   - 远端 manifest header（明文）存储 encryptedDataKey，新设备加入时
 *     先派生 MK，再解开远端 encryptedDataKey 得到 dataKey
 *   - 本地 dataKey 与远端不一致时，需要 reEncryptAllNotes 迁移
 *
 * 四种生命周期场景：
 *   1. 首次启用同步：createNew() → 生成 vaultId + dataKey，派生 MK，wrap
 *   2. 本地解锁（已有 vault）：unlockLocal() → 从 meta 读 vaultId + encryptedDataKey，派生 MK，unwrap
 *   3. 新设备加入（本地有 vault，但与远端不一致）：migrateToRemote() →
 *      用本地 MK 解开本地 dataKey → 用本地 MK 解开远端 encryptedDataKey 得到远端 dataKey →
 *      用远端 dataKey 重新加密所有本地笔记
 *   4. 新设备首次加入（本地无 vault）：unlockFromRemoteManifest() →
 *      从远端 manifest 取 vaultId + encryptedDataKey，派生 MK，unwrap
 *
 * 改密码：changePassword() → 旧 MK unwrap dataKey → 新 MK rewrap → 只更新 encryptedDataKey
 *
 * 安全性：
 *   - 密码错误时 GCM tag 验证失败，抛出 WrongPasswordException
 *   - 固定 salt 不影响 PBKDF2 安全性（防彩虹表作用仍在）
 *   - encryptedDataKey 本地存 meta 表，远端存 manifest header（明文部分）
 */

// Dart 原生导入
import 'dart:convert';
import 'dart:math' as dart;
import 'dart:typed_data';

// 项目导入
import 'package:safenotes/data/database_handler.dart';
import 'package:safenotes/sync/crypto.dart';

/// 密码错误异常（GCM tag 验证失败时抛出）
class WrongPasswordException implements Exception {
  final String message;
  WrongPasswordException([this.message = '密码错误：无法解密 dataKey']);

  @override
  String toString() => 'WrongPasswordException: $message';
}

/// Vault 未初始化异常（本地无 vaultId / encryptedDataKey 时抛出）
class VaultNotInitializedException implements Exception {
  final String message;
  VaultNotInitializedException([
    this.message = 'Vault 未初始化：请先启用同步或从远端拉取',
  ]);

  @override
  String toString() => 'VaultNotInitializedException: $message';
}

/// dataKey 迁移结果
///
/// 用于新设备加入已存在同步组时，记录本地数据是否需要重新加密。
class MigrationResult {
  /// 迁移是否需要执行（远端 dataKey 与本地不同）
  final bool needsMigration;

  /// 迁移是否成功
  final bool success;

  /// 远端的 dataKey（迁移成功后用于本地）
  final Uint8List? remoteDataKey;

  /// 远端的 encryptedDataKey（迁移成功后写入本地 meta）
  final String? remoteEncryptedDataKey;

  /// 远端的 vaultId（迁移成功后写入本地 meta）
  final String? remoteVaultId;

  /// 错误信息（失败时）
  final String? error;

  const MigrationResult({
    required this.needsMigration,
    this.success = false,
    this.remoteDataKey,
    this.remoteEncryptedDataKey,
    this.remoteVaultId,
    this.error,
  });

  /// 不需要迁移（本地与远端一致）
  factory MigrationResult.noMigrationNeeded() =>
      const MigrationResult(needsMigration: false, success: true);

  /// 迁移成功
  factory MigrationResult.migrated({
    required Uint8List remoteDataKey,
    required String remoteEncryptedDataKey,
    required String remoteVaultId,
  }) =>
      MigrationResult(
        needsMigration: true,
        success: true,
        remoteDataKey: remoteDataKey,
        remoteEncryptedDataKey: remoteEncryptedDataKey,
        remoteVaultId: remoteVaultId,
      );

  /// 迁移失败
  factory MigrationResult.failed(String error) =>
      MigrationResult(needsMigration: true, success: false, error: error);
}

/// Vault 密钥管理器
///
/// 持有解锁后的 dataKey 和当前 encryptedDataKey，供 SyncEngine 使用。
/// 同时缓存 MK（派生后立即使用，不持久化到磁盘，仅内存）。
class Vault {
  /// vault 唯一标识（UUIDv4，仅用于标识同步组，不再作为 PBKDF2 salt）
  final String vaultId;

  /// 数据主密钥（32 字节，永不变化，真正加密笔记的密钥）
  final Uint8List dataKey;

  /// 当前 MK 加密的 dataKey（base64 字符串，存 manifest header 和本地 meta）
  ///
  /// 改密码后这个值会变化，但 dataKey 本身不变。
  /// 注意：非 final，因为 sync 时需要回写远端值（H1 修复）。
  String encryptedDataKey;

  /// 当前会话派生出的 MK（Master Key）
  ///
  /// 仅缓存在内存中，用于：
  ///   1. changePassword 时验证旧密码
  ///   2. migrateVault 时解开远端 encryptedDataKey
  /// 不持久化到磁盘，logout 时清零。
  final Uint8List? _mk;

  /// 获取 MK（迁移场景需要，可能为 null 表示未缓存）
  Uint8List? get mk => _mk;

  Vault({
    required this.vaultId,
    required this.dataKey,
    required this.encryptedDataKey,
    Uint8List? mk,
  }) : _mk = mk;

  /// 复制并更新部分字段（保留 mk 缓存）
  Vault copyWith({
    String? vaultId,
    Uint8List? dataKey,
    String? encryptedDataKey,
    Uint8List? mk,
  }) =>
      Vault(
        vaultId: vaultId ?? this.vaultId,
        dataKey: dataKey ?? this.dataKey,
        encryptedDataKey: encryptedDataKey ?? this.encryptedDataKey,
        mk: mk ?? _mk,
      );

  // ──────────────────────────────────────────────
  // 创建 / 解锁
  // ──────────────────────────────────────────────

  /// 首次启用同步：生成新 vault
  ///
  /// 流程：
  ///   1. 生成 vaultId（UUIDv4，仅作同步组标识，不再作为 salt）
  ///   2. 生成 dataKey（随机 32 字节，永不变化）
  ///   3. 从密码派生 MK = PBKDF2(password, FIXED_SALT, 200k)
  ///   4. 用 MK 加密 dataKey → encryptedDataKey
  ///   5. 持久化 vaultId + encryptedDataKey 到本地 sync_meta 表
  ///
  /// [password] 用户主密码（明文，用完即弃）
  /// [database] 本地数据库（用于持久化 vault 元数据）
  /// 返回解锁后的 Vault 实例（含 MK 缓存）
  static Future<Vault> createNew({
    required String password,
    required NotesDatabase database,
  }) async {
    // 1. 生成 vaultId（UUIDv4，仅作同步组标识）
    final vaultId = _generateVaultId();

    // 2. 生成 dataKey（随机 32 字节，永不变化）
    final dataKey = SyncCrypto.generateDataKey();

    // 3. 派生 MK 并 wrap dataKey
    final mk = await _deriveMk(password);
    final encryptedDataKeyBytes = SyncCrypto.wrapDataKey(mk, dataKey);
    final encryptedDataKey = base64.encode(encryptedDataKeyBytes);

    // 4. 持久化到本地 sync_meta 表
    await database.setMeta(MetaKeys.vaultId, vaultId);
    await database.setMeta(MetaKeys.encryptedDataKey, encryptedDataKey);

    return Vault(
      vaultId: vaultId,
      dataKey: dataKey,
      encryptedDataKey: encryptedDataKey,
      mk: mk,
    );
  }

  /// 从本地存储解锁已有 vault（后续解锁场景）
  ///
  /// 流程：
  ///   1. 从 sync_meta 表读取 vaultId + encryptedDataKey
  ///   2. 如果本地无 encryptedDataKey（新设备首次启动），抛 VaultNotInitializedException
  ///   3. 从密码派生 MK = PBKDF2(password, FIXED_SALT, 200k)
  ///   4. 用 MK 解密 encryptedDataKey → dataKey
  ///   5. 密码错误时 GCM tag 验证失败 → 抛 WrongPasswordException
  ///
  /// [password] 用户主密码
  /// [database] 本地数据库
  /// 返回解锁后的 Vault 实例（含 MK 缓存）
  static Future<Vault> unlockLocal({
    required String password,
    required NotesDatabase database,
  }) async {
    // 读取本地 vault 元数据
    final vaultId = await database.getMeta(MetaKeys.vaultId);
    final encryptedDataKey = await database.getMeta(MetaKeys.encryptedDataKey);

    if (vaultId == null || encryptedDataKey == null) {
      throw VaultNotInitializedException(
        '本地无 vault 元数据：vaultId=$vaultId, '
        'hasEncryptedDataKey=${encryptedDataKey != null}',
      );
    }

    // 派生 MK 并 unwrap dataKey
    return _unlockWith(
      password: password,
      vaultId: vaultId,
      encryptedDataKey: encryptedDataKey,
      database: database,
    );
  }

  /// 从远端 manifest 解锁（本地无 vault 元数据的新设备首次加入场景）
  ///
  /// 新设备首次同步时，本地无 vault 元数据，需要从远端 manifest header 获取：
  ///   1. 从远端 manifest header 读取 vaultId + encryptedDataKey
  ///   2. 持久化到本地 sync_meta 表（后续可用 unlockLocal 快速解锁）
  ///   3. 派生 MK（固定 salt），unwrap dataKey
  ///
  /// [password] 用户主密码（需与创建 vault 时一致）
  /// [remoteVaultId] 远端 manifest header 中的 vaultId
  /// [remoteEncryptedDataKey] 远端 manifest header 中的 encryptedDataKey
  /// [database] 本地数据库
  /// 返回解锁后的 Vault 实例（含 MK 缓存）
  static Future<Vault> unlockFromRemoteManifest({
    required String password,
    required String remoteVaultId,
    required String remoteEncryptedDataKey,
    required NotesDatabase database,
  }) async {
    // 持久化远端 vault 元数据到本地（后续可用 unlockLocal 快速解锁）
    await database.setMeta(MetaKeys.vaultId, remoteVaultId);
    await database.setMeta(MetaKeys.encryptedDataKey, remoteEncryptedDataKey);

    return _unlockWith(
      password: password,
      vaultId: remoteVaultId,
      encryptedDataKey: remoteEncryptedDataKey,
      database: database,
    );
  }

  /// 内部解锁逻辑：派生 MK + unwrap dataKey
  static Future<Vault> _unlockWith({
    required String password,
    required String vaultId,
    required String encryptedDataKey,
    required NotesDatabase database,
  }) async {
    final mk = await _deriveMk(password);
    final encryptedBytes = base64.decode(encryptedDataKey);

    final Uint8List dataKey;
    try {
      dataKey = SyncCrypto.unwrapDataKey(mk, encryptedBytes);
    } on Exception catch (e) {
      // GCM tag 验证失败 = 密码错误
      throw WrongPasswordException(
        '无法解密 dataKey（GCM tag 验证失败）：$e',
      );
    }

    return Vault(
      vaultId: vaultId,
      dataKey: dataKey,
      encryptedDataKey: encryptedDataKey,
      mk: mk,
    );
  }

  // ──────────────────────────────────────────────
  // dataKey 迁移（本地 vault 与远端不一致时）
  // ──────────────────────────────────────────────

  /// 检查是否需要迁移到远端 dataKey
  ///
  /// 场景：本地已初始化 vault（有 dataKey_A），但远端 manifest 使用 dataKey_B。
  /// 这种情况发生在：
  ///   - 设备 A 创建 vault 后，设备 B 独立创建 vault（不同 dataKey）
  ///   - 用户在设备 A 改密码后，设备 B 仍用旧密码登录（MK 不匹配）
  ///
  /// 检查方法：用本地 MK 解开远端 encryptedDataKey，得到 remoteDataKey，
  /// 与本地 dataKey 比较。
  ///
  /// [remoteEncryptedDataKey] 远端 manifest header 中的 encryptedDataKey
  /// 返回 MigrationResult：
  ///   - noMigrationNeeded: 本地与远端 dataKey 一致
  ///   - migrated: 需要迁移，已解开远端 dataKey 供调用方使用
  ///   - failed: MK 不匹配（密码错误）或解密失败
  MigrationResult checkMigrationNeeded(String remoteEncryptedDataKey) {
    // 本地与远端 encryptedDataKey 完全相同 → 无需迁移（不需要 MK）
    // 必须先做此比较：相同密码不同设备派生出相同 MK + 相同 dataKey 时，
    // encryptedDataKey 一致，无需迁移也无需 MK。
    if (remoteEncryptedDataKey == encryptedDataKey) {
      return MigrationResult.noMigrationNeeded();
    }

    // encryptedDataKey 不同，需要 MK 来解密远端 dataKey 进行迁移
    final mk = _mk;
    if (mk == null) {
      return MigrationResult.failed('MK 未缓存，无法检查迁移');
    }

    // 尝试用本地 MK 解开远端 encryptedDataKey
    try {
      final remoteEncryptedBytes = base64.decode(remoteEncryptedDataKey);
      final remoteDataKey = SyncCrypto.unwrapDataKey(mk, remoteEncryptedBytes);
      return MigrationResult.migrated(
        remoteDataKey: remoteDataKey,
        remoteEncryptedDataKey: remoteEncryptedDataKey,
        remoteVaultId: vaultId,
      );
    } on Exception catch (e) {
      // MK 不匹配（密码错误）或数据损坏
      return MigrationResult.failed(
        '无法解密远端 encryptedDataKey（密码不匹配或数据损坏）：$e',
      );
    }
  }

  /// 执行迁移到远端 dataKey
  ///
  /// 这是关键操作：用 remoteDataKey 重新加密所有本地笔记。
  /// 调用方需确保：
  ///   1. database.reEncryptAllNotes 在事务中执行（crash 安全）
  ///   2. 迁移成功后立即更新本地 meta（vaultId / encryptedDataKey）
  ///   3. 迁移成功后返回新 Vault 实例（含 remoteDataKey 和 MK 缓存）
  ///
  /// [result] checkMigrationNeeded 返回的 MigrationResult
  /// [database] 本地数据库
  /// 返回新的 Vault 实例（使用远端 dataKey），失败抛异常
  Future<Vault> migrateToRemote({
    required MigrationResult result,
    required NotesDatabase database,
  }) async {
    if (!result.needsMigration) {
      return this; // 无需迁移
    }
    if (!result.success || result.remoteDataKey == null) {
      throw WrongPasswordException(
        result.error ?? '迁移失败：远端 dataKey 不可用',
      );
    }

    final remoteDataKey = result.remoteDataKey!;
    final remoteEncryptedDataKey = result.remoteEncryptedDataKey!;

    // 1. 重新加密所有本地笔记（事务保护，crash 安全）
    //    旧 dataKey 解密 → 新 dataKey 重新加密
    //    database_handler.reEncryptAllNotes 内部用 SQLite transaction
    await database.reEncryptAllNotes(
      oldKey: dataKey,
      newKey: remoteDataKey,
    );

    // 2. 更新本地 meta（vaultId 不变，encryptedDataKey 更新）
    await database.setMeta(MetaKeys.encryptedDataKey, remoteEncryptedDataKey);

    // 3. 更新 database 的 dataKey（后续读写用新 key）
    database.setDataKey(remoteDataKey);

    // 4. 返回新 Vault（dataKey 已更新，MK 缓存保留）
    return copyWith(
      dataKey: remoteDataKey,
      encryptedDataKey: remoteEncryptedDataKey,
    );
  }

  // ──────────────────────────────────────────────
  // 改密码
  // ──────────────────────────────────────────────

  /// 修改密码：重新 wrap dataKey
  ///
  /// 这是 O(1) 操作——只重新加密 32 字节的 dataKey，不触碰任何笔记。
  /// 流程：
  ///   1. 验证旧密码：用旧 MK 解开 dataKey（验证旧密码正确）
  ///   2. 用新密码派生新 MK，重新 wrap dataKey → 新 encryptedDataKey
  ///   3. 持久化新 encryptedDataKey 到本地 sync_meta 表
  ///   4. 返回新 Vault（dataKey 不变，encryptedDataKey 已更新）
  ///
  /// 注意：调用方还需要在下次同步时把新 encryptedDataKey 写入 manifest 上传到远端。
  /// 这由 SyncEngine 自动处理（manifest 的 encryptedDataKey 字段来自 Vault）。
  ///
  /// [oldPassword] 旧密码（用于验证）
  /// [newPassword] 新密码（用于重新加密 dataKey）
  /// [database] 本地数据库（持久化新 encryptedDataKey）
  Future<Vault> changePassword({
    required String oldPassword,
    required String newPassword,
    required NotesDatabase database,
  }) async {
    // 1. 验证旧密码：用旧 MK 解开 dataKey
    final oldMk = await _deriveMk(oldPassword);
    final oldEncryptedBytes = base64.decode(encryptedDataKey);

    try {
      // 验证旧密码能解开 dataKey（如果失败说明旧密码错误）
      SyncCrypto.unwrapDataKey(oldMk, oldEncryptedBytes);
    } on Exception catch (e) {
      throw WrongPasswordException('旧密码错误：$e');
    }

    // 2. 用新密码派生新 MK，重新 wrap dataKey
    final newMk = await _deriveMk(newPassword);
    final newEncryptedDataKeyBytes = SyncCrypto.wrapDataKey(newMk, dataKey);
    final newEncryptedDataKey = base64.encode(newEncryptedDataKeyBytes);

    // 3. 持久化到本地 sync_meta 表
    await database.setMeta(MetaKeys.encryptedDataKey, newEncryptedDataKey);

    // 4. 返回新 Vault（dataKey 不变，MK 更新为新派生的）
    return Vault(
      vaultId: vaultId,
      dataKey: dataKey,
      encryptedDataKey: newEncryptedDataKey,
      mk: newMk,
    );
  }

  /// 更新 encryptedDataKey（H1 修复：sync 时回写远端值）
  ///
  /// 场景：设备 A 改密码后上传新 manifest，设备 B 同步时拉到新 encryptedDataKey。
  /// dataKey 本身没变（只是 wrap 它的 MK 变了），所以不需要 reEncryptAllNotes。
  /// 此方法更新内存中的 encryptedDataKey + 持久化到本地 meta。
  ///
  /// 调用前提：调用方已确认远端 encryptedDataKey 与本地 dataKey 匹配
  /// （即 checkMigrationNeeded 返回 noMigrationNeeded）。
  Future<void> updateEncryptedDataKey(
    String newEncryptedDataKey,
    NotesDatabase database,
  ) async {
    if (newEncryptedDataKey == encryptedDataKey) return;

    // 持久化到本地 meta
    await database.setMeta(MetaKeys.encryptedDataKey, newEncryptedDataKey);

    // 更新内存（encryptedDataKey 是非 final 字段）
    encryptedDataKey = newEncryptedDataKey;
  }

  // ──────────────────────────────────────────────
  // 检查 / 工具方法
  // ──────────────────────────────────────────────

  /// 检查本地是否已初始化 vault（有 vaultId 和 encryptedDataKey）
  static Future<bool> isInitialized(NotesDatabase database) async {
    final vaultId = await database.getMeta(MetaKeys.vaultId);
    final encryptedDataKey = await database.getMeta(MetaKeys.encryptedDataKey);
    return vaultId != null && encryptedDataKey != null;
  }

  /// 从本地读取 vaultId（不解锁，用于 SyncEngine 构造）
  static Future<String?> getVaultId(NotesDatabase database) =>
      database.getMeta(MetaKeys.vaultId);

  /// 从本地读取 encryptedDataKey（不解锁，用于 SyncEngine 构造）
  static Future<String?> getEncryptedDataKey(NotesDatabase database) =>
      database.getMeta(MetaKeys.encryptedDataKey);

  // ──────────────────────────────────────────────
  // 内部辅助方法
  // ──────────────────────────────────────────────

  /// 生成 vaultId（UUIDv4，仅作同步组标识，不再作为 PBKDF2 salt）
  ///
  /// 使用 Dart 内置 Random.secure() 保证密码学安全。
  static String _generateVaultId() => _uuidV4();

  /// 从密码派生 MK（Master Key）
  ///
  /// 使用固定 salt [kFixedSalt]（'safenotes-v1'）保证多端一致性。
  /// 使用 Isolate 后台线程执行 PBKDF2，避免阻塞 UI（手机端约 1-1.5 秒）。
  static Future<Uint8List> _deriveMk(String password) async {
    return SyncCrypto.deriveMasterKeyAsync(password);
  }

  /// 生成 UUIDv4（RFC 4122）
  static String _uuidV4() {
    final random = dart.Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0F) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3F) | 0x80; // variant 10
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20, 32)}';
  }
}
