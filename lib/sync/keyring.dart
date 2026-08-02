/*
 * Keyring 密钥环（P2 方案 B：取代 Vault，密钥单一真相源）
 *
 * 设计文档：docs/p2-keyring-journal-design-fixed.md（v2 方案 B）
 *
 * 两层密钥架构：
 *   MK      = PBKDF2-HMAC-SHA256(password, per-vault-salt, 200k)  ← 改密码时变化
 *   dataKey = 随机 32 字节                                        ← 仅 scenario-c/d 迁移时变化
 *   encryptedDataKey = AES-GCM(MK, dataKey)                       ← 存 manifest header
 *
 * 密钥态收敛为一个账本对象（单键 `keyring` JSON，setMeta 原子，无双写不一致）：
 *   - current : 当前生效密钥条目（keyFingerprint / encryptedDataKey /
 *               keyVersion / dataKeyEpoch）
 *
 * 可变性约定（重要，偏离设计文档的地方，理由见下）：
 *   设计文档 §2.5 写作 `keyring = keyring.copyWithCurrent(...)`（返回新实例）。
 *   实现上 [current] 采用**可变字段 + 原地字段级更新**，因为：
 *     - SyncService 与 SyncEngine 共享同一个 Keyring 实例（旧 Vault 亦然），
 *       若 adoptRemoteEpoch / updateEncryptedDataKey 返回新实例，SyncService
 *       持有的旧引用不会同步，会重新引入"本地纪元落后"的 BUG-3 类问题。
 *     - C2 的核心要求是"字段级更新、保留 raw dataKey/mk"，原地更新同样满足，
 *       且更安全。[copyWithCurrent] 仍作为纯函数版本保留，供测试断言等价性。
 *   changePassword / migrateToRemote / migrateToRemoteVault 因 dataKey 或 kdf
 *   变化，仍返回**新实例**（与旧 Vault 行为一致，调用方已处理引用替换）。
 */

// Dart 原生导入
import 'dart:convert';
import 'dart:math' as dart;
import 'dart:typed_data';

// 项目导入
import 'package:safenotes/data/database_handler.dart';
import 'package:safenotes/sync/crypto.dart';
import 'package:safenotes/sync/sync_models.dart';
import 'package:safenotes/utils/app_logger.dart';

/// keyring 持久化 JSON 的 schema 版本（未来格式迁移用）
const int kKeyringSchemaVersion = 1;

/// 指纹脱敏：日志中只输出前 8 位，便于比对又不泄露完整指纹
String _fpBrief(String fingerprint) => fingerprint.length > 8
    ? '${fingerprint.substring(0, 8)}…'
    : (fingerprint.isEmpty ? '(空)' : fingerprint);

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

/// Keyring 未初始化异常（本地既无 keyring 键也无旧 keyring 元数据时抛出）
class KeyringNotInitializedException implements Exception {
  final String message;
  KeyringNotInitializedException([
    this.message = 'Keyring 未初始化：请先启用同步或从远端拉取',
  ]);

  @override
  String toString() => 'KeyringNotInitializedException: $message';
}

/// 密钥条目产生原因（枚举常量）
class KeyringReason {
  /// 新建 keyring
  static const String create = 'create';

  /// 改密码（dataKey 不变，keyVersion+1）
  static const String changePassword = 'changePassword';

  /// 采用远端纪元（H1 场景，dataKey 不变）
  static const String adoptRemoteEpoch = 'adoptRemoteEpoch';

  /// 迁移到不同 dataKey（scenario-c / scenario-d，dataKeyEpoch+1）
  static const String migrateDataKey = 'migrateDataKey';
}

/// 单个密钥条目（一次密钥状态快照，包裹态，可持久化）
///
/// 不含任何明文密钥：[encryptedDataKey] 是 MK 包裹后的密文，
/// 其余字段（指纹/版本/纪元/时间）本就非密。
class KeyringEntry {
  /// H(MK)，跨设备一致，标识"哪个 MK 能解开本条目"
  final String keyFingerprint;

  /// AES-GCM(MK, dataKey) 的 base64（包裹态）
  final String encryptedDataKey;

  /// 密钥版本号，改密码 +1（dataKey 值不变）
  final int keyVersion;

  /// dataKey 纪元，仅 dataKey 值真正变化时 +1
  final int dataKeyEpoch;

  /// 归档时间（Unix 毫秒）
  final int archivedAt;

  /// 产生原因，取值见 [KeyringReason]
  final String reason;

  const KeyringEntry({
    required this.keyFingerprint,
    required this.encryptedDataKey,
    this.keyVersion = 1,
    this.dataKeyEpoch = 1,
    this.archivedAt = 0,
    this.reason = KeyringReason.create,
  });

  KeyringEntry copyWith({
    String? keyFingerprint,
    String? encryptedDataKey,
    int? keyVersion,
    int? dataKeyEpoch,
    int? archivedAt,
    String? reason,
  }) =>
      KeyringEntry(
        keyFingerprint: keyFingerprint ?? this.keyFingerprint,
        encryptedDataKey: encryptedDataKey ?? this.encryptedDataKey,
        keyVersion: keyVersion ?? this.keyVersion,
        dataKeyEpoch: dataKeyEpoch ?? this.dataKeyEpoch,
        archivedAt: archivedAt ?? this.archivedAt,
        reason: reason ?? this.reason,
      );

  Map<String, dynamic> toJson() => {
        'keyFingerprint': keyFingerprint,
        'encryptedDataKey': encryptedDataKey,
        'keyVersion': keyVersion,
        'dataKeyEpoch': dataKeyEpoch,
        'archivedAt': archivedAt,
        'reason': reason,
      };

  factory KeyringEntry.fromJson(Map<String, dynamic> json) => KeyringEntry(
        keyFingerprint: (json['keyFingerprint'] as String?) ?? '',
        encryptedDataKey: (json['encryptedDataKey'] as String?) ?? '',
        keyVersion: (json['keyVersion'] as num?)?.toInt() ?? 1,
        dataKeyEpoch: (json['dataKeyEpoch'] as num?)?.toInt() ?? 1,
        archivedAt: (json['archivedAt'] as num?)?.toInt() ?? 0,
        reason: (json['reason'] as String?) ?? KeyringReason.create,
      );

  @override
  String toString() => 'KeyringEntry(v=$keyVersion, epoch=$dataKeyEpoch, '
      'fp=${keyFingerprint.length > 8 ? keyFingerprint.substring(0, 8) : keyFingerprint}, '
      'reason=$reason)';
}

/// Keyring 的持久化账本（不含运行时密钥）
///
/// 与 [Keyring] 分离的原因：解锁前只能读到包裹态账本（还没有密码去解 dataKey），
/// `isInitialized` / 诊断页等场景都只需要账本，不需要明文密钥。
class KeyringLedger {
  final String vaultId;
  final KdfParams kdf;
  final int createdAt;
  final KeyringEntry current;

  const KeyringLedger({
    required this.vaultId,
    required this.kdf,
    required this.createdAt,
    required this.current,
  });

  Map<String, dynamic> toJson() => {
        'schemaVersion': kKeyringSchemaVersion,
        'vaultId': vaultId,
        'kdf': kdf.toJson(),
        'createdAt': createdAt,
        'current': current.toJson(),
      };

  factory KeyringLedger.fromJson(Map<String, dynamic> json) => KeyringLedger(
        vaultId: json['vaultId'] as String,
        kdf: KdfParams.fromJson(
          Map<String, dynamic>.from(json['kdf'] as Map),
        ),
        createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
        current: KeyringEntry.fromJson(
          Map<String, dynamic>.from(json['current'] as Map),
        ),
      );

  /// 写入 sync_meta 的单键 `keyring`（单键 setMeta 原子，无双写不一致）
  Future<void> persist(NotesDatabase database) {
    // 密钥账本落盘是关键状态变化，记录版本/纪元/指纹前缀（不含任何密钥明文）
    Log.crypto.i('持久化 keyring 账本: vaultId=$vaultId '
        'keyVersion=${current.keyVersion} epoch=${current.dataKeyEpoch} '
        'fp=${_fpBrief(current.keyFingerprint)} reason=${current.reason}');
    return database.setMeta(MetaKeys.keyring, jsonEncode(toJson()));
  }

  /// 从 sync_meta 的 `keyring` 单键读取账本；不存在或损坏返回 null
  static Future<KeyringLedger?> load(NotesDatabase database) async {
    final raw = await database.getMeta(MetaKeys.keyring);
    if (raw == null || raw.isEmpty) {
      Log.crypto.d('加载 keyring 账本: 本地无记录(未初始化)');
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        Log.crypto.e('加载 keyring 账本失败: 顶层不是 JSON 对象 (${raw.length} 字节)');
        return null;
      }
      final ledger = KeyringLedger.fromJson(Map<String, dynamic>.from(decoded));
      Log.crypto.d('已加载 keyring 账本: vaultId=${ledger.vaultId} '
          'keyVersion=${ledger.current.keyVersion} '
          'epoch=${ledger.current.dataKeyEpoch} '
          'fp=${_fpBrief(ledger.current.keyFingerprint)}');
      return ledger;
    } on Object catch (e) {
      // JSON 损坏（混沌测试会主动制造）：视为无账本，报未初始化
      Log.crypto.e('加载 keyring 账本失败(视为未初始化): $e');
      return null;
    }
  }
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

  /// 远端的 encryptedDataKey（迁移成功后写入本地账本）
  final String? remoteEncryptedDataKey;

  /// 远端的 vaultId（迁移成功后写入本地账本）
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

/// 密钥环：SyncEngine 持有的唯一密钥对象
///
/// 同时承担两个角色：
///   1. 持久化账本（vaultId / kdf / createdAt / current）
///   2. 会话运行时（dataKey / mk，仅内存，logout 随实例丢弃）
class Keyring {
  /// keyring 唯一标识（UUIDv4，仅用于标识同步组）
  String vaultId;

  /// MK 派生参数（含 per-vault salt）；scenario-d 迁移时会整体切换为远端参数
  KdfParams kdf;

  /// keyring 创建时间（Unix 毫秒）
  int createdAt;

  /// 当前生效密钥条目
  ///
  /// 可变：adoptRemoteEpoch / updateEncryptedDataKey 需原地字段级更新，
  /// 以保证 SyncService 与 SyncEngine 共享的同一实例状态一致（见文件头说明）。
  KeyringEntry current;

  /// 数据主密钥（32 字节明文，真正加密笔记与 blob 的钥匙）
  ///
  /// 运行时字段：不持久化。方案 B 下由 Keyring 持有，取代 Vault.dataKey。
  Uint8List dataKey;

  /// 当前会话派生出的 MK（Master Key）
  ///
  /// 运行时字段：不持久化，logout 随实例丢弃。用于：
  ///   1. changePassword 时验证旧密码
  ///   2. 迁移时解开远端 encryptedDataKey
  Uint8List? mk;

  Keyring({
    required this.vaultId,
    required this.kdf,
    required this.createdAt,
    required this.current,
    required this.dataKey,
    this.mk,
  });

  // ──────────────────────────────────────────────
  // 便捷访问器
  // ──────────────────────────────────────────────

  String get encryptedDataKey => current.encryptedDataKey;
  String get keyFingerprint => current.keyFingerprint;
  int get keyVersion => current.keyVersion;
  int get dataKeyEpoch => current.dataKeyEpoch;

  /// 当前账本快照（用于持久化 / 诊断 / 测试断言）
  KeyringLedger get ledger => KeyringLedger(
        vaultId: vaultId,
        kdf: kdf,
        createdAt: createdAt,
        current: current,
      );

  /// 本地持久化：只写包裹态账本到 sync_meta 的 `keyring` 单键
  ///
  /// dataKey / mk 是运行时字段，天然不在持久化范围内（无泄露面）。
  Future<void> persist(NotesDatabase database) => ledger.persist(database);

  /// 纯函数版字段级更新（返回新实例，保留运行时 dataKey/mk）
  ///
  /// 生产路径使用原地更新（[adoptRemoteEpoch] 等），此方法主要供测试断言
  /// "字段级更新不丢 dataKey"的等价性（防止回归 C2）。
  Keyring copyWithCurrent({
    String? encryptedDataKey,
    String? keyFingerprint,
    int? keyVersion,
    int? dataKeyEpoch,
    String? reason,
  }) =>
      Keyring(
        vaultId: vaultId,
        kdf: kdf,
        createdAt: createdAt,
        current: current.copyWith(
          encryptedDataKey: encryptedDataKey,
          keyFingerprint: keyFingerprint,
          keyVersion: keyVersion,
          dataKeyEpoch: dataKeyEpoch,
          reason: reason,
        ),
        // 关键：raw dataKey / mk 原样保留，绝不被包裹态更新抹掉（C2）
        dataKey: dataKey,
        mk: mk,
      );

  /// 投影为远端 manifest 明文头部（唯一出口，消除内联构造漏字段）
  ///
  /// v4（epoch 消除）：
  ///   - 不再有 override 三元组——header 恒用本地 keyring 值。本地包裹永远
  ///     合法（能解开本地全部 blob），只读不 echo 远端（§0）；scenario-b
  ///     （他端改密码）在引擎层即中止，不会走到这里。
  ///   - 新增自描述元数据：dataKeyFingerprint = H(dataKey)，
  ///     dataKeyCreatedAt = keyring 创建时间（dataKey 在创建时生成）。
  ///     [dataKeyCreatedBy] 由调用方（SyncEngine）传入本机 deviceId。
  ManifestHeader toManifestHeader({
    int schemaVersion = 1,
    required int version,
    required int updatedAt,
    required String lastModifiedBy,
    String dataKeyWrap = kDataKeyWrapAlgorithm,
    String? dataKeyCreatedBy,
  }) =>
      ManifestHeader(
        schemaVersion: schemaVersion,
        version: version,
        vaultId: vaultId,
        createdAt: createdAt,
        updatedAt: updatedAt,
        keyFingerprint: keyFingerprint,
        keyVersion: keyVersion,
        encryptedDataKey: encryptedDataKey,
        kdf: kdf,
        dataKeyWrap: dataKeyWrap,
        dataKeyEpoch: dataKeyEpoch,
        dataKeyFingerprint: SyncCrypto.computeDataKeyFingerprint(dataKey),
        dataKeyCreatedAt: createdAt,
        dataKeyCreatedBy: dataKeyCreatedBy,
        lastModifiedBy: lastModifiedBy,
      );

  /// 从远端 manifest header 构建 Keyring
  ///
  /// [dataKey] / [mk] 必须由调用方提供（远端 header 只有包裹态，解包需要密码），
  /// 这也是 C1 的同源约束：没有 raw dataKey 的 Keyring 无法工作。
  factory Keyring.fromRemoteHeader(
    ManifestHeader header, {
    required Uint8List dataKey,
    Uint8List? mk,
  }) =>
      Keyring(
        vaultId: header.vaultId,
        kdf: header.kdf,
        createdAt: header.createdAt,
        current: KeyringEntry(
          keyFingerprint: header.keyFingerprint,
          encryptedDataKey: header.encryptedDataKey,
          keyVersion: header.keyVersion,
          dataKeyEpoch: header.dataKeyEpoch,
          archivedAt: 0,
          reason: KeyringReason.adoptRemoteEpoch,
        ),
        dataKey: dataKey,
        mk: mk,
      );

  // ──────────────────────────────────────────────
  // 创建 / 解锁
  // ──────────────────────────────────────────────

  /// 首次启用同步：生成新 keyring
  ///
  /// 流程：生成 vaultId + dataKey + per-vault salt → 派生 MK → wrap dataKey →
  /// 写入 `keyring` 单键（一次写入，取代旧实现的 7 次 setMeta）。
  static Future<Keyring> createNew({
    required String password,
    required NotesDatabase database,
  }) async {
    final sw = Stopwatch()..start();
    Log.crypto.i('创建新 Keyring: 生成 vaultId/dataKey/salt 并派生 MK (PBKDF2)');
    final vaultId = _generateVaultId();
    final dataKey = SyncCrypto.generateDataKey();
    final salt = SyncCrypto.generateSalt();
    final kdf = KdfParams.create(salt: salt);
    final mk = await _deriveMk(password, salt: salt);
    final keyFingerprint = SyncCrypto.computeKeyFingerprint(mk);
    final encryptedDataKey = base64.encode(SyncCrypto.wrapDataKey(mk, dataKey));
    final createdAt = DateTime.now().millisecondsSinceEpoch;

    final keyring = Keyring(
      vaultId: vaultId,
      kdf: kdf,
      createdAt: createdAt,
      current: KeyringEntry(
        keyFingerprint: keyFingerprint,
        encryptedDataKey: encryptedDataKey,
        keyVersion: 1,
        dataKeyEpoch: 1,
        archivedAt: createdAt,
        reason: KeyringReason.create,
      ),
      dataKey: dataKey,
      mk: mk,
    );
    await keyring.persist(database);
    Log.crypto.i('新 Keyring 创建完成: vaultId=$vaultId '
        'fp=${_fpBrief(keyFingerprint)} keyVersion=1 epoch=1 '
        '(耗时 ${sw.elapsedMilliseconds}ms)');
    return keyring;
  }

  /// 从本地存储解锁已有 keyring
  ///
  /// 密码错误抛 [WrongPasswordException]。
  static Future<Keyring> unlockLocal({
    required String password,
    required NotesDatabase database,
  }) async {
    final sw = Stopwatch()..start();
    Log.crypto.d('解锁本地 Keyring: 开始读取账本');
    final ledger = await KeyringLedger.load(database);
    if (ledger == null) {
      Log.crypto.w('解锁本地 Keyring 失败: 本地无 keyring 账本(未初始化)');
      throw KeyringNotInitializedException('本地无 keyring 账本');
    }

    final mk = await _deriveMk(password, salt: ledger.kdf.saltBytes);
    final dataKey = _unwrapOrThrow(mk, ledger.current.encryptedDataKey);

    Log.crypto.i('本地 Keyring 解锁成功: vaultId=${ledger.vaultId} '
        'keyVersion=${ledger.current.keyVersion} '
        'epoch=${ledger.current.dataKeyEpoch} '
        'fp=${_fpBrief(ledger.current.keyFingerprint)} '
        '(耗时 ${sw.elapsedMilliseconds}ms)');
    return Keyring(
      vaultId: ledger.vaultId,
      kdf: ledger.kdf,
      createdAt: ledger.createdAt,
      current: ledger.current,
      dataKey: dataKey,
      mk: mk,
    );
  }

  /// 从远端 manifest header 解锁（本地无账本的新设备首次加入）
  ///
  /// 安全顺序：**先验证密码再持久化**。密码错误时抛异常且不写本地，
  /// 避免错误密码把本地状态污染成远端值。
  static Future<Keyring> unlockFromRemoteManifest({
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
    final sw = Stopwatch()..start();
    Log.crypto.i('从远端 manifest 解锁 Keyring: vaultId=$remoteVaultId '
        'keyVersion=$remoteKeyVersion epoch=$remoteDataKeyEpoch '
        'fp=${_fpBrief(remoteKeyFingerprint)}');
    final mk = await _deriveMk(password, salt: remoteKdf.saltBytes);
    final dataKey = _unwrapOrThrow(mk, remoteEncryptedDataKey);

    final keyring = Keyring(
      vaultId: remoteVaultId,
      kdf: remoteKdf,
      createdAt: remoteCreatedAt,
      current: KeyringEntry(
        keyFingerprint: remoteKeyFingerprint,
        encryptedDataKey: remoteEncryptedDataKey,
        keyVersion: remoteKeyVersion,
        dataKeyEpoch: remoteDataKeyEpoch,
        archivedAt: DateTime.now().millisecondsSinceEpoch,
        reason: KeyringReason.adoptRemoteEpoch,
      ),
      dataKey: dataKey,
      mk: mk,
    );
    await keyring.persist(database);
    Log.crypto.i('远端 Keyring 解锁并落盘完成: vaultId=$remoteVaultId '
        '(耗时 ${sw.elapsedMilliseconds}ms)');
    return keyring;
  }

  /// 解包 dataKey，失败统一转为 [WrongPasswordException]
  static Uint8List _unwrapOrThrow(Uint8List mk, String encryptedDataKey) {
    try {
      return SyncCrypto.unwrapDataKey(mk, base64.decode(encryptedDataKey));
    } on Exception catch (e) {
      // GCM tag 验证失败 = 密码错误
      Log.crypto.w('解包 dataKey 失败(通常为密码错误): $e');
      throw WrongPasswordException('无法解密 dataKey（GCM tag 验证失败）：$e');
    }
  }

  // ──────────────────────────────────────────────
  // dataKey 迁移（本地与远端不一致时）
  // ──────────────────────────────────────────────

  /// 检查是否需要迁移到远端 dataKey
  ///
  /// 用本地 MK 尝试解开远端 encryptedDataKey，得到 remoteDataKey 与本地比较。
  MigrationResult checkMigrationNeeded(
    String remoteEncryptedDataKey, {
    String? remoteVaultId,
  }) {
    // 完全相同 → 无需迁移（不需要 MK）
    if (remoteEncryptedDataKey == encryptedDataKey) {
      Log.crypto.d('dataKey 迁移检查: 本地与远端包裹一致, 无需迁移');
      return MigrationResult.noMigrationNeeded();
    }

    final mk = this.mk;
    if (mk == null) {
      Log.crypto.w('dataKey 迁移检查失败: MK 未缓存(会话可能已登出)');
      return MigrationResult.failed('MK 未缓存，无法检查迁移');
    }

    try {
      final remoteDataKey = SyncCrypto.unwrapDataKey(
        mk,
        base64.decode(remoteEncryptedDataKey),
      );
      Log.crypto.i('dataKey 迁移检查: 远端包裹可解开, 需要迁移到远端 dataKey '
          '(远端 vaultId=${remoteVaultId ?? vaultId})');
      return MigrationResult.migrated(
        remoteDataKey: remoteDataKey,
        remoteEncryptedDataKey: remoteEncryptedDataKey,
        remoteVaultId: remoteVaultId ?? vaultId,
      );
    } on Exception catch (e) {
      Log.crypto.e('dataKey 迁移检查失败: 无法解密远端 encryptedDataKey: $e');
      return MigrationResult.failed(
        '无法解密远端 encryptedDataKey（密码不匹配或数据损坏）：$e',
      );
    }
  }

  /// 执行迁移到远端 dataKey（同 keyring、dataKey 不同）
  ///
  /// 返回**新实例**（dataKey 变化）。调用方必须替换持有的引用。
  Future<Keyring> migrateToRemote({
    required MigrationResult result,
    required NotesDatabase database,
  }) async {
    if (!result.needsMigration) {
      Log.crypto.d('执行 dataKey 迁移: 无需迁移, 直接返回当前 Keyring');
      return this;
    }
    if (!result.success || result.remoteDataKey == null) {
      Log.crypto.e('执行 dataKey 迁移失败: ${result.error ?? "远端 dataKey 不可用"}');
      throw WrongPasswordException(result.error ?? '迁移失败：远端 dataKey 不可用');
    }

    final sw = Stopwatch()..start();
    final remoteDataKey = result.remoteDataKey!;
    final remoteEncryptedDataKey = result.remoteEncryptedDataKey!;
    final remoteVaultId = result.remoteVaultId ?? vaultId;
    final keyChanged = !_sameKey(dataKey, remoteDataKey);

    // Layer 2a/3：仅当 dataKey 值真正变化时标记 blob 重传并递增纪元。
    // 改密码场景（dataKey 不变）不标记，避免无谓的全量 blob 重传。
    int nextEpoch = dataKeyEpoch;
    if (keyChanged) {
      nextEpoch = dataKeyEpoch + 1;
    }
    Log.crypto.i('执行 dataKey 迁移(同 vault): vaultId=$vaultId → $remoteVaultId, '
        'dataKey ${keyChanged ? "已变化" : "未变化"}, '
        'epoch $dataKeyEpoch → $nextEpoch, '
        'blob 重传标记=${keyChanged ? "是" : "否"}');

    final migrated = Keyring(
      vaultId: remoteVaultId,
      kdf: kdf,
      createdAt: createdAt,
      current: current.copyWith(
        encryptedDataKey: remoteEncryptedDataKey,
        dataKeyEpoch: nextEpoch,
        archivedAt: DateTime.now().millisecondsSinceEpoch,
        reason: KeyringReason.migrateDataKey,
      ),
      dataKey: remoteDataKey,
      mk: mk,
    );

    // B1 修复（epoch 消除 P0 五项）：重加密 + 新账本 + 重传标记**同一事务**，
    // 消除「重加密成功但账本未更新 → 崩溃后全库不可解」窗口。
    // 替代旧的 reEncryptAllNotes（独立事务）+ markAllForBlobReupload +
    // persist（独立写）三步。
    await database.reEncryptAllNotesAtomically(
      oldKey: dataKey,
      newKey: remoteDataKey,
      keyringJson: jsonEncode(migrated.ledger.toJson()),
      markBlobReupload: keyChanged,
    );

    // 事务成功后更新 database 的 dataKey（后续读写用新 key）
    database.setDataKey(remoteDataKey);
    Log.crypto.i('dataKey 迁移完成(同 vault): 全库已重加密并切换 dataKey, '
        'epoch=$nextEpoch (耗时 ${sw.elapsedMilliseconds}ms)');
    return migrated;
  }

  /// 场景 d：用远端 KDF 参数派生 MK，验证密码是否匹配远端 keyring
  ///
  /// 判别原理：keyFingerprint = H(MK)。用远端 salt + 用户密码派生 MK_remote，
  /// 若 H(MK_remote) == 远端 keyFingerprint → 密码相同（场景 d），否则场景 c。
  static Future<({Uint8List mk, Uint8List dataKey})?> tryDeriveRemoteDataKey({
    required String password,
    required KdfParams remoteKdf,
    required String remoteEncryptedDataKey,
    required String remoteKeyFingerprint,
  }) async {
    final mk = await _deriveMk(password, salt: remoteKdf.saltBytes);
    if (SyncCrypto.computeKeyFingerprint(mk) != remoteKeyFingerprint) {
      Log.crypto.i('远端密码判别: 指纹不匹配(场景 c, 远端与本地密码不同) '
          'remoteFp=${_fpBrief(remoteKeyFingerprint)}');
      return null; // 密码不匹配 → 场景 c
    }
    try {
      final dataKey = SyncCrypto.unwrapDataKey(
        mk,
        base64.decode(remoteEncryptedDataKey),
      );
      Log.crypto.i('远端密码判别: 指纹匹配(场景 d, 密码相同), 已解出远端 dataKey');
      return (mk: mk, dataKey: dataKey);
    } on Exception catch (e) {
      // fingerprint 匹配但 unwrap 失败（理论上不应发生，防御性处理）
      Log.crypto.e('远端密码判别异常: 指纹匹配但解包 dataKey 失败: $e');
      return null;
    }
  }

  /// 场景 d 迁移：本地完全切换到远端 keyring 参数（含 kdf/salt/vaultId）
  ///
  /// 返回**新实例**。与 [migrateToRemote] 的区别：那个是同 keyring 换 dataKey，
  /// 这个是不同 keyring（salt 也不同），需要整体采用远端 KDF 参数。
  Future<Keyring> migrateToRemoteVault({
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
    final sw = Stopwatch()..start();
    final keyChanged = !_sameKey(dataKey, remoteDataKey);

    int nextEpoch = dataKeyEpoch;
    if (keyChanged) {
      nextEpoch = dataKeyEpoch + 1;
    }

    Log.crypto.i('执行 vault 整体迁移(场景 d): vaultId=$vaultId → $remoteVaultId, '
        'kdf/salt 切换为远端, keyVersion=$remoteKeyVersion, '
        'dataKey ${keyChanged ? "已变化" : "未变化"}, epoch $dataKeyEpoch → $nextEpoch, '
        'fp=${_fpBrief(remoteKeyFingerprint)}');

    final now = DateTime.now().millisecondsSinceEpoch;

    final migrated = Keyring(
      vaultId: remoteVaultId,
      kdf: remoteKdf,
      createdAt: remoteCreatedAt,
      current: KeyringEntry(
        keyFingerprint: remoteKeyFingerprint,
        encryptedDataKey: remoteEncryptedDataKey,
        keyVersion: remoteKeyVersion,
        dataKeyEpoch: nextEpoch,
        archivedAt: now,
        reason: KeyringReason.migrateDataKey,
      ),
      dataKey: remoteDataKey,
      mk: remoteMk,
    );

    // B1 修复（epoch 消除 P0 五项）：重加密 + 新账本 + 重传标记**同一事务**，
    // 消除「重加密成功但账本未更新 → 崩溃后全库不可解」窗口。
    await database.reEncryptAllNotesAtomically(
      oldKey: dataKey,
      newKey: remoteDataKey,
      keyringJson: jsonEncode(migrated.ledger.toJson()),
      markBlobReupload: keyChanged,
    );

    database.setDataKey(remoteDataKey);
    Log.crypto.i('vault 整体迁移完成(场景 d): 全库已重加密, '
        'vaultId=$remoteVaultId epoch=$nextEpoch '
        '(耗时 ${sw.elapsedMilliseconds}ms)');
    return migrated;
  }

  // ──────────────────────────────────────────────
  // 改密码 / 纪元采用
  // ──────────────────────────────────────────────

  /// 验证密码是否正确（不持久化，不改状态）
  Future<void> verifyPassword(String password) async {
    final sw = Stopwatch()..start();
    final probe = await _deriveMk(password, salt: kdf.saltBytes);
    try {
      SyncCrypto.unwrapDataKey(probe, base64.decode(encryptedDataKey));
      Log.crypto.d('密码校验通过 (耗时 ${sw.elapsedMilliseconds}ms)');
    } on Exception catch (e) {
      Log.crypto.w('密码校验失败: $e (耗时 ${sw.elapsedMilliseconds}ms)');
      throw WrongPasswordException('密码错误：$e');
    }
  }

  /// 修改密码：重新 wrap dataKey + 递增 keyVersion（O(1)，不触碰笔记）
  ///
  /// 返回**新实例**（mk 变为新派生 MK），调用方必须替换持有的引用（评审 B-M3）。
  /// dataKey 值不变 → dataKeyEpoch 不变。
  Future<Keyring> changePassword({
    required String oldPassword,
    required String newPassword,
    required NotesDatabase database,
  }) async {
    final sw = Stopwatch()..start();
    final salt = kdf.saltBytes;
    Log.crypto.i('Keyring 改密码开始: vaultId=$vaultId '
        '当前 keyVersion=$keyVersion epoch=$dataKeyEpoch');

    // 1. 验证旧密码
    final oldMk = await _deriveMk(oldPassword, salt: salt);
    try {
      SyncCrypto.unwrapDataKey(oldMk, base64.decode(encryptedDataKey));
      Log.crypto.d('Keyring 改密码: 旧密码验证通过');
    } on Exception catch (e) {
      Log.crypto.w('Keyring 改密码中止: 旧密码错误: $e');
      throw WrongPasswordException('旧密码错误：$e');
    }

    // 2. 新 MK 重新 wrap（dataKey 本身不变）
    final newMk = await _deriveMk(newPassword, salt: salt);
    final newEncryptedDataKey =
        base64.encode(SyncCrypto.wrapDataKey(newMk, dataKey));
    final newKeyFingerprint = SyncCrypto.computeKeyFingerprint(newMk);
    final now = DateTime.now().millisecondsSinceEpoch;

    // 3. 生成新 current（一次 persist 取代旧实现的 4 次写）
    final changed = Keyring(
      vaultId: vaultId,
      kdf: kdf, // salt 不变
      createdAt: createdAt,
      current: KeyringEntry(
        keyFingerprint: newKeyFingerprint,
        encryptedDataKey: newEncryptedDataKey,
        keyVersion: keyVersion + 1,
        dataKeyEpoch: dataKeyEpoch, // 改密码不改纪元
        archivedAt: now,
        reason: KeyringReason.changePassword,
      ),
      dataKey: dataKey,
      mk: newMk,
    );
    await changed.persist(database);
    Log.crypto.i('Keyring 改密码完成: keyVersion $keyVersion → ${keyVersion + 1}, '
        'fp ${_fpBrief(keyFingerprint)} → ${_fpBrief(newKeyFingerprint)}, '
        'dataKey 未变(epoch=$dataKeyEpoch, 无需重加密笔记) '
        '(耗时 ${sw.elapsedMilliseconds}ms)');
    return changed;
  }

  /// 更新 encryptedDataKey（H1：同步时回写远端包裹值）
  ///
  /// dataKey 未变（只是 wrap 它的 MK 变了），无需重加密笔记。
  /// **原地更新**，保证共享同一实例的 SyncService/SyncEngine 状态一致。
  ///
  /// v4（epoch 消除）：引擎层已无调用方（scenario-b 中止 + 只读解密不再
  /// 回写/echo 远端包裹），保留此方法供未来显式流程（如用户主动重登录）使用。
  Future<void> updateEncryptedDataKey(
    String newEncryptedDataKey,
    NotesDatabase database,
  ) async {
    if (newEncryptedDataKey == encryptedDataKey) {
      Log.crypto.t('更新 encryptedDataKey: 与当前值一致, 跳过');
      return;
    }
    Log.crypto.i('更新 encryptedDataKey: 采用新的包裹值(dataKey 未变, 无需重加密)');
    current = current.copyWith(encryptedDataKey: newEncryptedDataKey);
    await persist(database);
  }

  // ──────────────────────────────────────────────
  // 检查 / 工具方法
  // ──────────────────────────────────────────────

  /// 本地是否已初始化（有 keyring 单键）
  static Future<bool> isInitialized(NotesDatabase database) async =>
      await KeyringLedger.load(database) != null;

  /// 读取 vaultId（不解锁）
  static Future<String?> getVaultId(NotesDatabase database) async =>
      (await KeyringLedger.load(database))?.vaultId;

  /// 读取 encryptedDataKey（不解锁）
  static Future<String?> getEncryptedDataKey(NotesDatabase database) async =>
      (await KeyringLedger.load(database))?.current.encryptedDataKey;

  @override
  String toString() => 'Keyring(vaultId=$vaultId, current=$current)';

  // ──────────────────────────────────────────────
  // 内部辅助
  // ──────────────────────────────────────────────

  /// 从密码派生 MK（Isolate 后台执行，避免阻塞 UI）
  static Future<Uint8List> _deriveMk(
    String password, {
    required Uint8List salt,
  }) =>
      SyncCrypto.deriveMasterKeyAsync(password, salt: salt);

  /// 生成 vaultId（UUIDv4，RFC 4122，Random.secure）
  static String _generateVaultId() {
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
