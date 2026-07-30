/*
 * Vault 密钥管理
 *
 * 两层密钥架构：
 *   MK  = PBKDF2-HMAC-SHA256(password, per-vault-salt, 200k)  ← 改密码时变化
 *   dataKey = 随机 32 字节                                    ← 永不变化
 *   encryptedDataKey = AES-GCM(MK, dataKey)                    ← 存 manifest header
 *
 * 密钥纪元（P0-1 修复）：
 *   keyFingerprint = H(MK)，跨设备一致，用于检测他端改密码
 *   keyVersion = 单调递增计数器，createNew=1，changePassword +1
 *
 * per-vault 随机 salt（P2-9 修复）：
 *   每个 vault 创建时生成独立随机 salt，写入 manifest header 明文。
 *   相同密码 + 不同 salt → 不同 MK，跨用户预计算彩虹表失效。
 *   多端一致性：salt 随 header 传播，新设备按 header 中的 salt 派生 MK。
 *
 * 四种生命周期场景：
 *   1. 首次启用同步：createNew() → 生成 vaultId + dataKey + salt，派生 MK，wrap
 *   2. 本地解锁（已有 vault）：unlockLocal() → 从 meta 读 salt + vaultId + encryptedDataKey，派生 MK，unwrap
 *   3. 新设备加入（本地有 vault，但与远端不一致）：migrateToRemote() →
 *      用本地 MK 解开本地 dataKey → 用本地 MK 解开远端 encryptedDataKey 得到远端 dataKey →
 *      用远端 dataKey 重新加密所有本地笔记
 *   4. 新设备首次加入（本地无 vault）：unlockFromRemoteManifest() →
 *      从远端 manifest 取 vaultId + encryptedDataKey + kdf(salt)，派生 MK，unwrap
 *
 * 改密码：changePassword() → 旧 MK unwrap dataKey → 新 MK rewrap → 只更新 encryptedDataKey + keyFingerprint + keyVersion
 * 注意：改密码时 salt 不变（salt 是 per-vault 的，与密码无关）
 *
 * 安全性：
 *   - 密码错误时 GCM tag 验证失败，抛出 WrongPasswordException
 *   - per-vault salt 防止跨用户预计算彩虹表
 *   - encryptedDataKey 本地存 meta 表，远端存 manifest header（明文部分）
 *   - keyFingerprint 与 encryptedDataKey 安全性等价（都能离线验证密码）
 */

// Dart 原生导入
import 'dart:convert';
import 'dart:math' as dart;
import 'dart:typed_data';

// 项目导入
import 'package:safenotes/data/database_handler.dart';
import 'package:safenotes/sync/crypto.dart';
import 'package:safenotes/sync/sync_models.dart';

/// 比较两个字节序列是否相等（dataKey 比较用，非安全敏感）
bool _sameKey(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 密码错误异常（GCM tag 验证失败时抛出）
class WrongPasswordException implements Exception {
  final String message;
  WrongPasswordException([this.message = '密码错误：无法解密 dataKey']);

  @override
  String toString() => 'WrongPasswordException: $message';
}

/// Vault 未初始化异常（本地无 vaultId / encryptedDataKey / kdfSalt 时抛出）
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
  /// vault 唯一标识（UUIDv4，仅用于标识同步组）
  final String vaultId;

  /// 数据主密钥（32 字节，永不变化，真正加密笔记的密钥）
  final Uint8List dataKey;

  /// 当前 MK 加密的 dataKey（base64 字符串，存 manifest header 和本地 meta）
  ///
  /// 改密码后这个值会变化，但 dataKey 本身不变。
  /// 注意：非 final，因为 sync 时需要回写远端值（H1 修复）。
  String encryptedDataKey;

  /// 密钥指纹 = H(MK)，跨设备一致
  ///
  /// 用于 manifest header 明文存储，检测他端改密码。
  /// 改密码时更新（新 MK → 新 fingerprint）。
  /// 注意：非 final，因为 sync 时需要采用远端纪元（B1-2/H1 修复，
  /// 见 adoptRemoteEpoch）。
  String keyFingerprint;

  /// 密钥版本号（单调递增）
  ///
  /// createNew=1，changePassword +1。
  /// 用于防止旧密码设备回滚新密码包裹。
  /// 注意：非 final，理由同 keyFingerprint。
  int keyVersion;

  /// dataKey 纪元（Layer 3 显式标记，单调 int，独立于 [keyVersion]）
  ///
  /// 与 [ManifestItem.blobKeyEpoch] 对应：blob 信封 AAD 携带该纪元，
  /// 下载时据此显式判断 blob 是否被「非当前 dataKey」加密。
  ///
  /// 关键区别：
  ///   - [keyVersion] 仅在【改密码】时 +1（dataKey 值不变）；
  ///   - [dataKeyEpoch] 仅在【dataKey 值真正变化】时 +1
  ///     （即 scenario-d / 未来重密钥迁移；改密码【不】加）。
  ///
  /// 默认 1（新建 vault 即为第 1 个纪元）；遗留 vault 未记录时按 1 处理。
  /// 非 final：迁移导致 dataKey 值变化时递增并持久化。
  int dataKeyEpoch;

  /// MK 派生参数（含 per-vault salt）
  ///
  /// salt 在 createNew 时随机生成，之后不变（包括改密码时）。
  /// 写入 manifest header 供新设备派生 MK。
  final KdfParams kdf;

  /// vault 创建时间（Unix 毫秒）
  ///
  /// 首次 createNew 时设置为当前时间，之后不变。
  /// 写入 manifest header 供审计，也写入本地 meta 供 _buildLocalManifest 使用。
  final int createdAt;

  /// 当前会话派生出的 MK（Master Key）
  ///
  /// 仅缓存在内存中，用于：
  ///   1. changePassword 时验证旧密码
  ///   2. migrateVault 时解开远端 encryptedDataKey
  /// 不持久化到磁盘，logout 时清零。
  final Uint8List? mk;

   Vault({
    required this.vaultId,
    required this.dataKey,
    required this.encryptedDataKey,
    required this.keyFingerprint,
    this.keyVersion = 1,
    this.dataKeyEpoch = 1,
    required this.kdf,
    required this.createdAt,
    this.mk,
  });

  /// 复制并更新部分字段（保留 mk 缓存）
  Vault copyWith({
    String? vaultId,
    Uint8List? dataKey,
    String? encryptedDataKey,
    String? keyFingerprint,
    int? keyVersion,
    int? dataKeyEpoch,
    KdfParams? kdf,
    int? createdAt,
    Uint8List? mk,
  }) =>
      Vault(
        vaultId: vaultId ?? this.vaultId,
        dataKey: dataKey ?? this.dataKey,
        encryptedDataKey: encryptedDataKey ?? this.encryptedDataKey,
        keyFingerprint: keyFingerprint ?? this.keyFingerprint,
        keyVersion: keyVersion ?? this.keyVersion,
        dataKeyEpoch: dataKeyEpoch ?? this.dataKeyEpoch,
        kdf: kdf ?? this.kdf,
        createdAt: createdAt ?? this.createdAt,
        mk: mk ?? this.mk,
      );

  // ──────────────────────────────────────────────
  // 创建 / 解锁
  // ──────────────────────────────────────────────

  /// 首次启用同步：生成新 vault
  ///
  /// 流程：
  ///   1. 生成 vaultId（UUIDv4）
  ///   2. 生成 dataKey（随机 32 字节，永不变化）
  ///   3. 生成 per-vault 随机 salt（16 字节）
  ///   4. 用 salt 派生 MK = PBKDF2(password, salt, 200k)
  ///   5. 计算 keyFingerprint = H(MK)
  ///   6. 用 MK 加密 dataKey → encryptedDataKey
  ///   7. 持久化 vaultId + encryptedDataKey + salt + keyFingerprint + keyVersion 到本地 meta
  ///
  /// [password] 用户主密码（明文，用完即弃）
  /// [database] 本地数据库（用于持久化 vault 元数据）
  /// 返回解锁后的 Vault 实例（含 MK 缓存）
  static Future<Vault> createNew({
    required String password,
    required NotesDatabase database,
  }) async {
    // 1. 生成 vaultId（UUIDv4）
    final vaultId = _generateVaultId();

    // 2. 生成 dataKey（随机 32 字节，永不变化）
    final dataKey = SyncCrypto.generateDataKey();

    // 3. 生成 per-vault 随机 salt
    final salt = SyncCrypto.generateSalt();
    final kdf = KdfParams.create(salt: salt);

    // 4. 派生 MK（用 per-vault salt）
    final mk = await _deriveMk(password, salt: salt);

    // 5. 计算密钥指纹
    final keyFingerprint = SyncCrypto.computeKeyFingerprint(mk);

    // 6. 用 MK 加密 dataKey
    final encryptedDataKeyBytes = SyncCrypto.wrapDataKey(mk, dataKey);
    final encryptedDataKey = base64.encode(encryptedDataKeyBytes);

    // 7. 记录 vault 创建时间
    final createdAt = DateTime.now().millisecondsSinceEpoch;

    // 8. 持久化到本地 sync_meta 表
    await database.setMeta(MetaKeys.vaultId, vaultId);
    await database.setMeta(MetaKeys.encryptedDataKey, encryptedDataKey);
    await database.setMeta(MetaKeys.kdfSalt, base64.encode(salt));
    await database.setMeta(MetaKeys.keyFingerprint, keyFingerprint);
    await database.setMeta(MetaKeys.keyVersion, '1');
    await database.setMeta(MetaKeys.dataKeyEpoch, '1');
    await database.setMeta(MetaKeys.vaultCreatedAt, createdAt.toString());

    return Vault(
      vaultId: vaultId,
      dataKey: dataKey,
      encryptedDataKey: encryptedDataKey,
      keyFingerprint: keyFingerprint,
      keyVersion: 1,
      dataKeyEpoch: 1,
      kdf: kdf,
      createdAt: createdAt,
      mk: mk,
    );
  }

  /// 从本地存储解锁已有 vault（后续解锁场景）
  ///
  /// 流程：
  ///   1. 从 sync_meta 表读取 vaultId + encryptedDataKey + kdfSalt + keyFingerprint + keyVersion
  ///   2. 如果本地无 kdfSalt，抛 VaultNotInitializedException（开发阶段不做兼容）
  ///   3. 用 salt 派生 MK = PBKDF2(password, salt, 200k)
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
    final saltBase64 = await database.getMeta(MetaKeys.kdfSalt);
    final keyFingerprint = await database.getMeta(MetaKeys.keyFingerprint);
    final keyVersionStr = await database.getMeta(MetaKeys.keyVersion);
    final dataKeyEpochStr = await database.getMeta(MetaKeys.dataKeyEpoch);
    final createdAtStr = await database.getMeta(MetaKeys.vaultCreatedAt);

    if (vaultId == null || encryptedDataKey == null || saltBase64 == null) {
      throw VaultNotInitializedException(
        '本地无 vault 元数据：vaultId=$vaultId, '
        'hasEncryptedDataKey=${encryptedDataKey != null}, '
        'hasSalt=${saltBase64 != null}',
      );
    }

    // 解析 salt 和 KDF 参数
    final salt = base64.decode(saltBase64);
    final kdf = KdfParams.create(salt: salt);
    final keyVersion = int.tryParse(keyVersionStr ?? '1') ?? 1;
    final dataKeyEpoch = int.tryParse(dataKeyEpochStr ?? '1') ?? 1;
    final createdAt = int.tryParse(createdAtStr ?? '') ??
        DateTime.now().millisecondsSinceEpoch;

    // 派生 MK 并 unwrap dataKey
    return _unlockWith(
      password: password,
      vaultId: vaultId,
      encryptedDataKey: encryptedDataKey,
      salt: salt,
      kdf: kdf,
      keyFingerprint: keyFingerprint ?? '',
      keyVersion: keyVersion,
      dataKeyEpoch: dataKeyEpoch,
      createdAt: createdAt,
      database: database,
    );
  }

  /// 从远端 manifest 解锁（本地无 vault 元数据的新设备首次加入场景）
  ///
  /// 新设备首次同步时，本地无 vault 元数据，需要从远端 manifest header 获取：
  ///   1. 从远端 manifest header 读取 vaultId + encryptedDataKey + kdf(salt) + keyFingerprint + keyVersion + createdAt
  ///   2. 用 header 中的 salt 派生 MK，unwrap dataKey（先验证密码）
  ///   3. 验证成功后持久化到本地 sync_meta 表（后续可用 unlockLocal 快速解锁）
  ///
  /// 安全顺序：先验证密码再持久化。若密码错误，抛出 WrongPasswordException，
  /// 本地 meta 保持原状（不被远端覆盖），避免错误密码污染本地状态。
  ///
  /// [password] 用户主密码（需与创建 vault 时一致）
  /// [remoteVaultId] 远端 manifest header 中的 vaultId
  /// [remoteEncryptedDataKey] 远端 manifest header 中的 encryptedDataKey
  /// [remoteKdf] 远端 manifest header 中的 KDF 参数（含 salt）
  /// [remoteKeyFingerprint] 远端 manifest header 中的 keyFingerprint
  /// [remoteKeyVersion] 远端 manifest header 中的 keyVersion
  /// [remoteCreatedAt] 远端 manifest header 中的 createdAt（vault 创建时间）
  /// [database] 本地数据库
  /// 返回解锁后的 Vault 实例（含 MK 缓存）
  static Future<Vault> unlockFromRemoteManifest({
    required String password,
    required String remoteVaultId,
    required String remoteEncryptedDataKey,
    required KdfParams remoteKdf,
    required String remoteKeyFingerprint,
    required int remoteKeyVersion,
    int remoteDataKeyEpoch = 1,
    required int remoteCreatedAt,
    required NotesDatabase database,
  }) async {
    // 先验证密码（派生 MK + unwrap dataKey），失败则抛 WrongPasswordException
    // 此时本地 meta 尚未修改，保持原状
    final vault = await _unlockWith(
      password: password,
      vaultId: remoteVaultId,
    encryptedDataKey: remoteEncryptedDataKey,
    salt: remoteKdf.saltBytes,
    kdf: remoteKdf,
    keyFingerprint: remoteKeyFingerprint,
    keyVersion: remoteKeyVersion,
    dataKeyEpoch: remoteDataKeyEpoch,
    createdAt: remoteCreatedAt,
    database: database,
  );

  // 验证成功后才持久化远端 vault 元数据到本地
  await database.setMeta(MetaKeys.vaultId, remoteVaultId);
  await database.setMeta(MetaKeys.encryptedDataKey, remoteEncryptedDataKey);
  await database.setMeta(MetaKeys.kdfSalt, remoteKdf.salt);
  await database.setMeta(MetaKeys.keyFingerprint, remoteKeyFingerprint);
  await database.setMeta(MetaKeys.keyVersion, remoteKeyVersion.toString());
  await database.setMeta(MetaKeys.dataKeyEpoch, remoteDataKeyEpoch.toString());
  await database.setMeta(MetaKeys.vaultCreatedAt, remoteCreatedAt.toString());

  return vault;
}

/// 内部解锁逻辑：派生 MK + unwrap dataKey
static Future<Vault> _unlockWith({
  required String password,
  required String vaultId,
  required String encryptedDataKey,
  required Uint8List salt,
  required KdfParams kdf,
  required String keyFingerprint,
  required int keyVersion,
  required int dataKeyEpoch,
  required int createdAt,
  required NotesDatabase database,
}) async {
  final mk = await _deriveMk(password, salt: salt);
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
    keyFingerprint: keyFingerprint,
    keyVersion: keyVersion,
    dataKeyEpoch: dataKeyEpoch,
    kdf: kdf,
    createdAt: createdAt,
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
  /// [remoteVaultId] 远端 manifest header 中的 vaultId（P2-7 修复：正确传递远端 vaultId）
  /// 返回 MigrationResult：
  ///   - noMigrationNeeded: 本地与远端 dataKey 一致
  ///   - migrated: 需要迁移，已解开远端 dataKey 供调用方使用
  ///   - failed: MK 不匹配（密码错误）或解密失败
  MigrationResult checkMigrationNeeded(
    String remoteEncryptedDataKey, {
    String? remoteVaultId,
  }) {
    // 本地与远端 encryptedDataKey 完全相同 → 无需迁移（不需要 MK）
    if (remoteEncryptedDataKey == encryptedDataKey) {
      return MigrationResult.noMigrationNeeded();
    }

    // encryptedDataKey 不同，需要 MK 来解密远端 dataKey 进行迁移
    final mk = this.mk;
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
        // P2-7 修复：使用远端 vaultId，而非本地 vaultId
        remoteVaultId: remoteVaultId ?? vaultId,
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
    final remoteVaultId = result.remoteVaultId ?? vaultId;

    // 1. 重新加密所有本地笔记（事务保护，crash 安全）
    await database.reEncryptAllNotes(
      oldKey: dataKey,
      newKey: remoteDataKey,
    );

    // Layer 2a: dataKey 值真正变化时才标记 blob 重传。
    // 改密码场景（dataKey 不变）不标记，避免无谓的全量 blob 重传；
    // scenario-d（不同 dataKey）必然进入此分支，确保服务器旧密钥 blob 被覆盖。
    int nextEpoch = dataKeyEpoch;
    if (!_sameKey(dataKey, remoteDataKey)) {
      await database.markAllForBlobReupload();
      // Layer 3: dataKey 值真正变化 → dataKey 纪元 +1（独立于 keyVersion）。
      nextEpoch = dataKeyEpoch + 1;
      await database.setMeta(MetaKeys.dataKeyEpoch, nextEpoch.toString());
    }

    // 2. 更新本地 meta（P2-7 修复：vaultId 也更新为远端值）
    // 归档被替换的本地 wrappedDataKey（scenario-d 下为旧 dataKey），供 repair 恢复。
    if (!_sameKey(dataKey, remoteDataKey)) {
      await database.appendDataKeyHistory(
        keyVersion: keyVersion,
        wrappedDataKey: encryptedDataKey,
        keyFingerprint: keyFingerprint,
      );
    }
    await database.setMeta(MetaKeys.vaultId, remoteVaultId);
    await database.setMeta(MetaKeys.encryptedDataKey, remoteEncryptedDataKey);

    // 3. 更新 database 的 dataKey（后续读写用新 key）
    database.setDataKey(remoteDataKey);

    // 4. 返回新 Vault（dataKey 和 vaultId 已更新，MK 缓存保留）
    return copyWith(
      vaultId: remoteVaultId,
      dataKey: remoteDataKey,
      encryptedDataKey: remoteEncryptedDataKey,
      dataKeyEpoch: nextEpoch,
    );
  }

  /// 场景 d：用远端 KDF 参数派生 MK，验证密码是否匹配远端 vault
  ///
  /// 场景：两设备独立 createNew → 不同 salt → 不同 MK → 本地 MK 解不开远端
  /// encryptedDataKey。但密码其实相同——用远端 salt 重新派生 MK 即可验证。
  ///
  /// 判别原理：
  ///   - keyFingerprint = H(MK) = H(PBKDF2(password, salt, iterations))
  ///   - 用远端 salt + 用户密码派生 MK_remote
  ///   - 若 H(MK_remote) == 远端 keyFingerprint → 密码相同（场景 d）
  ///   - 若不匹配 → 密码真的不同（场景 c）
  ///
  /// [password] 用户当前输入的密码
  /// [remoteKdf] 远端 manifest header 中的 KDF 参数（含远端 salt）
  /// [remoteEncryptedDataKey] 远端 manifest header 中的 encryptedDataKey
  /// [remoteKeyFingerprint] 远端 manifest header 中的 keyFingerprint
  ///
  /// 返回 (MK_remote, dataKey_remote)：
  ///   - 密码匹配 → 返回远端 MK 和解开后的 dataKey
  ///   - 密码不匹配 → 返回 null
  static Future<({Uint8List mk, Uint8List dataKey})?> tryDeriveRemoteDataKey({
    required String password,
    required KdfParams remoteKdf,
    required String remoteEncryptedDataKey,
    required String remoteKeyFingerprint,
  }) async {
    // 1. 用远端 salt + 用户密码派生 MK_remote
    final mk = await _deriveMk(password, salt: remoteKdf.saltBytes);

    // 2. 比对 keyFingerprint
    final fp = SyncCrypto.computeKeyFingerprint(mk);
    if (fp != remoteKeyFingerprint) {
      // 密码不匹配 → 场景 c
      return null;
    }

    // 3. 密码匹配 → unwrap 远端 dataKey
    try {
      final encryptedBytes = base64.decode(remoteEncryptedDataKey);
      final dataKey = SyncCrypto.unwrapDataKey(mk, encryptedBytes);
      return (mk: mk, dataKey: dataKey);
    } on Exception {
      // fingerprint 匹配但 unwrap 失败（理论上不应发生，防御性处理）
      return null;
    }
  }

  /// 场景 d 迁移：本地 vault 完全切换到远端 vault 参数
  ///
  /// 与 [migrateToRemote] 的区别：
  ///   - migrateToRemote：同 vault、dataKey 不同（他端改密码后本端用新密码登录）
  ///     只更新 dataKey + encryptedDataKey + vaultId
  ///   - migrateToRemoteVault：不同 vault、salt 不同（两设备独立初始化）
  ///     更新 dataKey + encryptedDataKey + vaultId + kdf + keyFingerprint + keyVersion + createdAt
  ///
  /// 流程：
  ///   1. 用 remoteDataKey 重新加密所有本地笔记（事务保护，crash 安全）
  ///   2. 持久化远端 vault 全部元数据到本地 meta
  ///   3. 更新 database 的 dataKey
  ///   4. 返回新 Vault（所有字段用远端值，MK 缓存为 MK_remote）
  Future<Vault> migrateToRemoteVault({
    required Uint8List remoteDataKey,
    required String remoteEncryptedDataKey,
    required String remoteVaultId,
    required KdfParams remoteKdf,
    required String remoteKeyFingerprint,
    required int remoteKeyVersion,
    required int remoteCreatedAt,
    required Uint8List remoteMk,
    required NotesDatabase database,
  }) async {
    // 1. 重新加密所有本地笔记（事务保护，crash 安全）
    await database.reEncryptAllNotes(
      oldKey: dataKey,
      newKey: remoteDataKey,
    );

    // Layer 2a: dataKey 值真正变化时才标记 blob 重传（见 migrateToRemote 同名注释）。
    // scenario-d 两设备独立 dataKey，此处 remoteDataKey 必然 != 本地 dataKey。
    int nextEpoch = dataKeyEpoch;
    if (!_sameKey(dataKey, remoteDataKey)) {
      await database.markAllForBlobReupload();
      // Layer 3: dataKey 值真正变化 → dataKey 纪元 +1（独立于 keyVersion）。
      nextEpoch = dataKeyEpoch + 1;
      await database.setMeta(MetaKeys.dataKeyEpoch, nextEpoch.toString());
    }

    // 2. 持久化远端 vault 全部元数据到本地 meta
    // 归档被替换的本地 wrappedDataKey（scenario-d 下为旧 dataKey），供 repair 恢复。
    if (!_sameKey(dataKey, remoteDataKey)) {
      await database.appendDataKeyHistory(
        keyVersion: keyVersion,
        wrappedDataKey: encryptedDataKey,
        keyFingerprint: keyFingerprint,
      );
    }
    await database.setMeta(MetaKeys.vaultId, remoteVaultId);
    await database.setMeta(MetaKeys.encryptedDataKey, remoteEncryptedDataKey);
    await database.setMeta(MetaKeys.kdfSalt, remoteKdf.salt);
    await database.setMeta(MetaKeys.keyFingerprint, remoteKeyFingerprint);
    await database.setMeta(MetaKeys.keyVersion, remoteKeyVersion.toString());
    await database.setMeta(MetaKeys.dataKeyEpoch, nextEpoch.toString());
    await database.setMeta(MetaKeys.vaultCreatedAt, remoteCreatedAt.toString());

    // 3. 更新 database 的 dataKey
    database.setDataKey(remoteDataKey);

    // 4. 返回新 Vault（所有字段用远端值，MK 缓存为 MK_remote）
    return Vault(
      vaultId: remoteVaultId,
      dataKey: remoteDataKey,
      encryptedDataKey: remoteEncryptedDataKey,
      keyFingerprint: remoteKeyFingerprint,
      keyVersion: remoteKeyVersion,
      dataKeyEpoch: nextEpoch,
      kdf: remoteKdf,
      createdAt: remoteCreatedAt,
      mk: remoteMk,
    );
  }

  // ──────────────────────────────────────────────
  // 改密码
  // ──────────────────────────────────────────────

  /// 修改密码：重新 wrap dataKey + 更新密钥纪元
  ///
  /// 这是 O(1) 操作——只重新加密 32 字节的 dataKey，不触碰任何笔记。
  /// 注意：改密码时 salt 不变（salt 是 per-vault 的，与密码无关）。
  ///
  /// 流程：
  ///   1. 验证旧密码：用旧密码 + 当前 salt 派生旧 MK，解开 dataKey
  ///   2. 用新密码 + 当前 salt 派生新 MK，重新 wrap dataKey → 新 encryptedDataKey
  ///   3. 计算新 keyFingerprint = H(新 MK)
  ///   4. 递增 keyVersion
  ///   5. 持久化新 encryptedDataKey + keyFingerprint + keyVersion 到本地 meta
  ///   6. 返回新 Vault（dataKey 不变，encryptedDataKey/keyFingerprint/keyVersion 已更新）
  ///
  /// [oldPassword] 旧密码（用于验证）
  /// [newPassword] 新密码（用于重新加密 dataKey）
  /// [database] 本地数据库（持久化新元数据）

  /// 验证密码是否正确（不持久化，不改状态）
  ///
  /// 用于改密码前的旧密码前置验证：用密码派生 MK，尝试 unwrap dataKey。
  /// 成功 = 密码正确，失败抛 WrongPasswordException。
  ///
  /// 与 [changePassword] 的区别：verifyPassword 只验证不持久化，
  /// changePassword 验证 + 持久化一体。改密码流程先调 verifyPassword
  /// 前置验证，通过后再做 _preChangeCheck，最后调 changePassword 持久化。
  Future<void> verifyPassword(String password) async {
    final mk = await _deriveMk(password, salt: kdf.saltBytes);
    final encryptedBytes = base64.decode(encryptedDataKey);
    try {
      SyncCrypto.unwrapDataKey(mk, encryptedBytes);
    } on Exception catch (e) {
      throw WrongPasswordException('密码错误：$e');
    }
  }

  Future<Vault> changePassword({
    required String oldPassword,
    required String newPassword,
    required NotesDatabase database,
  }) async {
    final salt = kdf.saltBytes;

    // 1. 验证旧密码：用旧密码 + salt 派生旧 MK
    final oldMk = await _deriveMk(oldPassword, salt: salt);
    final oldEncryptedBytes = base64.decode(encryptedDataKey);

    try {
      // 验证旧密码能解开 dataKey（如果失败说明旧密码错误）
      SyncCrypto.unwrapDataKey(oldMk, oldEncryptedBytes);
    } on Exception catch (e) {
      throw WrongPasswordException('旧密码错误：$e');
    }

    // 2. 用新密码 + salt 派生新 MK，重新 wrap dataKey
    final newMk = await _deriveMk(newPassword, salt: salt);
    final newEncryptedDataKeyBytes = SyncCrypto.wrapDataKey(newMk, dataKey);
    final newEncryptedDataKey = base64.encode(newEncryptedDataKeyBytes);

    // 3. 计算新密钥指纹
    final newKeyFingerprint = SyncCrypto.computeKeyFingerprint(newMk);

    // 4. 递增密钥版本号
    final newKeyVersion = keyVersion + 1;

    // 5. 持久化到本地 sync_meta 表
    // 归档被替换的旧 wrappedDataKey（用旧 MK 包裹），供 repair 时由旧密码恢复。
    // 注意：dataKey 本身不变，旧 wrappedDataKey 解开后仍是同一 dataKey；
    // 此归档主要为"历史曾用不同 dataKey"的场景（如 scenario-d 迁移）保留恢复锚点。
    await database.appendDataKeyHistory(
      keyVersion: keyVersion,
      wrappedDataKey: encryptedDataKey,
      keyFingerprint: keyFingerprint,
    );
    await database.setMeta(MetaKeys.encryptedDataKey, newEncryptedDataKey);
    await database.setMeta(MetaKeys.keyFingerprint, newKeyFingerprint);
    await database.setMeta(MetaKeys.keyVersion, newKeyVersion.toString());

    // 6. 返回新 Vault（dataKey 不变，MK 更新为新派生的）
    return Vault(
      vaultId: vaultId,
      dataKey: dataKey,
      encryptedDataKey: newEncryptedDataKey,
      keyFingerprint: newKeyFingerprint,
      keyVersion: newKeyVersion,
      kdf: kdf, // salt 不变
      createdAt: createdAt, // vault 创建时间不变
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

  /// 整体采用远端密钥纪元（B1-2/H1 修复：他端改密码 + 本端已持有新 MK）
  ///
  /// 场景：设备 A 改密码后上传新纪元（keyVersion+1 / 新 fingerprint / 新
  /// encryptedDataKey），设备 B 用新密码登录但本地 meta 还是旧纪元。
  /// B 同步时 MK 能解开远端 encryptedDataKey 且 dataKey 一致（H1 分支），
  /// 说明本端密码就是新密码——此时必须把远端纪元三元组
  /// （encryptedDataKey + keyFingerprint + keyVersion）整体采用，
  /// 否则本地 keyVersion 永远落后，每次同步都误报"他端改密码"，
  /// 且构建 header 时会把远端 keyVersion/fingerprint 回滚（BUG-3）。
  ///
  /// dataKey 不变，不触碰任何笔记。内存 + 本地 meta 同步更新，
  /// 保持 SyncService 持有的同一 Vault 实例一致。
  Future<void> adoptRemoteEpoch({
    required String remoteEncryptedDataKey,
    required String remoteKeyFingerprint,
    required int remoteKeyVersion,
    int remoteDataKeyEpoch = 1,
    required NotesDatabase database,
  }) async {
    await database.setMeta(MetaKeys.encryptedDataKey, remoteEncryptedDataKey);
    await database.setMeta(MetaKeys.keyFingerprint, remoteKeyFingerprint);
    await database.setMeta(MetaKeys.keyVersion, remoteKeyVersion.toString());
    // dataKey 不变（改密码场景），其纪元与远端一致，直接采用远端权威值。
    await database.setMeta(MetaKeys.dataKeyEpoch, remoteDataKeyEpoch.toString());

    encryptedDataKey = remoteEncryptedDataKey;
    keyFingerprint = remoteKeyFingerprint;
    keyVersion = remoteKeyVersion;
    dataKeyEpoch = remoteDataKeyEpoch;
  }

  // ──────────────────────────────────────────────
  // 检查 / 工具方法
  // ──────────────────────────────────────────────

  /// 检查本地是否已初始化 vault（有 vaultId 和 encryptedDataKey 和 kdfSalt）
  static Future<bool> isInitialized(NotesDatabase database) async {
    final vaultId = await database.getMeta(MetaKeys.vaultId);
    final encryptedDataKey = await database.getMeta(MetaKeys.encryptedDataKey);
    final salt = await database.getMeta(MetaKeys.kdfSalt);
    return vaultId != null && encryptedDataKey != null && salt != null;
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

  /// 生成 vaultId（UUIDv4，仅作同步组标识）
  ///
  /// 使用 Dart 内置 Random.secure() 保证密码学安全。
  static String _generateVaultId() => _uuidV4();

  /// 从密码派生 MK（Master Key）
  ///
  /// 使用 per-vault salt 保证多端一致性。
  /// 使用 Isolate 后台线程执行 PBKDF2，避免阻塞 UI（手机端约 1-1.5 秒）。
  static Future<Uint8List> _deriveMk(
    String password, {
    required Uint8List salt,
  }) async {
    return SyncCrypto.deriveMasterKeyAsync(password, salt: salt);
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
