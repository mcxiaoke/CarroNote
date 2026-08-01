/*
 * Keyring 密钥环（P2 方案 B：取代 Vault，密钥单一真相源）
 *
 * 设计文档：docs/p2-keyring-journal-design-fixed.md（v2 方案 B）
 *
 * 两层密钥架构（与旧 Vault 完全一致，不改加密格式 —— G6）：
 *   MK      = PBKDF2-HMAC-SHA256(password, per-vault-salt, 200k)  ← 改密码时变化
 *   dataKey = 随机 32 字节                                        ← 仅 scenario-c/d 迁移时变化
 *   encryptedDataKey = AES-GCM(MK, dataKey)                       ← 存 manifest header
 *
 * 相对旧 Vault 的结构性变化：
 *   1. 【单一真相源 G1】密钥态收敛为一个账本对象：
 *        - current : 当前生效密钥条目（keyFingerprint / encryptedDataKey /
 *                    keyVersion / dataKeyEpoch）
 *        - history : 历史条目（旧 wrappedDataKey，供旧密码 repair），
 *                    local-only、按 keyVersion 去重、上限 20 条
 *      旧实现散落在 8 个 sync_meta 键 + data_key_history 键，靠 33 处 setMeta
 *      手动互相回写，是 BUG-3 / H1 的根源。
 *   2. 【运行时字段】dataKey / mk 仍是内存态（不持久化），随 Keyring 一起持有，
 *      使 Keyring 能真正取代 Vault 供 SyncEngine 加解密（解决评审 C1）。
 *   3. 【持久化 G5】只写 sync_meta 的单键 `keyring`（一个 JSON），单键 setMeta
 *      天然原子，不存在"多键双写半成功"。旧多键仅由 fromLegacyMeta 一次性读取转换。
 *
 * 可变性约定（重要，偏离设计文档的地方，理由见下）：
 *   设计文档 §2.5 写作 `keyring = keyring.copyWithCurrent(...)`（返回新实例）。
 *   实现上 [current] / [history] 采用**可变字段 + 原地字段级更新**，因为：
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

/// keyring 持久化 JSON 的 schema 版本（未来格式迁移用）
const int kKeyringSchemaVersion = 1;

/// history 保留上限（D3 决策：最近 20 条，按 keyVersion 去重）
///
/// 约对应 20 次改密码 / 迁移的恢复窗口，足够 scenario-d 修复；
/// 同时避免开发/测试阶段频繁改密码导致 meta 无限增长。
const int kKeyringHistoryLimit = 20;

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
///
/// 补齐草案遗漏场景（评审 A-P2#9 / 审查 C-问题4）：
/// 把原 `migrateVault` / `scenario-d` 合并为 [migrateDataKey]（二者都是
/// dataKey 值真变、epoch+1）；新增 [adoptRemoteEpoch]（H1 场景）与
/// [unknown]（legacy 数据无来源字段时的默认值）。
class KeyringReason {
  /// 新建 keyring
  static const String create = 'create';

  /// 改密码（dataKey 不变，keyVersion+1）
  static const String changePassword = 'changePassword';

  /// 采用远端纪元（H1 场景，dataKey 不变）
  static const String adoptRemoteEpoch = 'adoptRemoteEpoch';

  /// 迁移到不同 dataKey（scenario-c / scenario-d，dataKeyEpoch+1）
  static const String migrateDataKey = 'migrateDataKey';

  /// legacy 数据迁移默认值（旧 data_key_history 无来源字段）
  static const String unknown = 'unknown';
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

  /// 归档时间（Unix 毫秒）；legacy 迁移项无时间字段，填 0（评审 B-L1）
  final int archivedAt;

  /// 产生原因，取值见 [KeyringReason]
  final String reason;

  const KeyringEntry({
    required this.keyFingerprint,
    required this.encryptedDataKey,
    this.keyVersion = 1,
    this.dataKeyEpoch = 1,
    this.archivedAt = 0,
    this.reason = KeyringReason.unknown,
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
        reason: (json['reason'] as String?) ?? KeyringReason.unknown,
      );

  @override
  String toString() => 'KeyringEntry(v=$keyVersion, epoch=$dataKeyEpoch, '
      'fp=${keyFingerprint.length > 8 ? keyFingerprint.substring(0, 8) : keyFingerprint}, '
      'reason=$reason)';
}

/// Keyring 的持久化账本（不含运行时密钥）
///
/// 与 [Keyring] 分离的原因：解锁前只能读到包裹态账本（还没有密码去解 dataKey），
/// `isInitialized` / 诊断页 / legacy 转换等场景都只需要账本，不需要明文密钥。
class KeyringLedger {
  final String vaultId;
  final KdfParams kdf;
  final int createdAt;
  final KeyringEntry current;
  final List<KeyringEntry> history;

  const KeyringLedger({
    required this.vaultId,
    required this.kdf,
    required this.createdAt,
    required this.current,
    this.history = const [],
  });

  Map<String, dynamic> toJson() => {
        'schemaVersion': kKeyringSchemaVersion,
        'vaultId': vaultId,
        'kdf': kdf.toJson(),
        'createdAt': createdAt,
        'current': current.toJson(),
        'history': history.map((e) => e.toJson()).toList(),
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
        history: ((json['history'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => KeyringEntry.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
      );

  /// 写入 sync_meta 的单键 `keyring`（单键 setMeta 原子，无双写不一致）
  Future<void> persist(NotesDatabase database) =>
      database.setMeta(MetaKeys.keyring, jsonEncode(toJson()));

  /// 从 sync_meta 的 `keyring` 单键读取账本；不存在或损坏返回 null
  static Future<KeyringLedger?> loadFromMeta(NotesDatabase database) async {
    final raw = await database.getMeta(MetaKeys.keyring);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return KeyringLedger.fromJson(Map<String, dynamic>.from(decoded));
    } on Object {
      // JSON 损坏（混沌测试会主动制造）：视为无账本，交由 legacy 回退或报未初始化
      return null;
    }
  }

  /// 从旧 keyring 的多键 meta 一次性重建账本（升级路径，G5 一次性、不进长期代码）
  ///
  /// 旧键：vault_id / encrypted_data_key / kdf_salt / key_fingerprint /
  ///       key_version / vault_created_at / data_key_epoch / data_key_history
  /// 缺少必需键（vaultId / encryptedDataKey / kdfSalt）时返回 null。
  static Future<KeyringLedger?> fromLegacyMeta(NotesDatabase database) async {
    final vaultId = await database.getMeta(MetaKeys.vaultId);
    final encryptedDataKey = await database.getMeta(MetaKeys.encryptedDataKey);
    final saltBase64 = await database.getMeta(MetaKeys.kdfSalt);
    if (vaultId == null || encryptedDataKey == null || saltBase64 == null) {
      return null;
    }

    final keyFingerprint =
        await database.getMeta(MetaKeys.keyFingerprint) ?? '';
    final keyVersion =
        int.tryParse(await database.getMeta(MetaKeys.keyVersion) ?? '1') ?? 1;
    final dataKeyEpoch =
        int.tryParse(await database.getMeta(MetaKeys.dataKeyEpoch) ?? '1') ?? 1;
    final createdAt = int.tryParse(
          await database.getMeta(MetaKeys.vaultCreatedAt) ?? '',
        ) ??
        DateTime.now().millisecondsSinceEpoch;

    // 旧 data_key_history 仅有 {keyVersion, wrappedDataKey, keyFingerprint}，
    // 无时间与来源 → archivedAt=0 / reason=unknown（评审 B-L1）。
    final legacyHistory = await database.getDataKeyHistory();
    final history = <KeyringEntry>[];
    for (final e in legacyHistory) {
      final wrapped = e['wrappedDataKey'];
      if (wrapped is! String || wrapped.isEmpty) continue;
      history.add(KeyringEntry(
        keyFingerprint: (e['keyFingerprint'] as String?) ?? '',
        encryptedDataKey: wrapped,
        keyVersion: (e['keyVersion'] as num?)?.toInt() ?? 1,
        // 旧记录不含纪元：按当前纪元记录，仅用于 repair 时解包，不参与纪元判定
        dataKeyEpoch: dataKeyEpoch,
        archivedAt: 0,
        reason: KeyringReason.unknown,
      ));
    }

    return KeyringLedger(
      vaultId: vaultId,
      kdf: KdfParams.create(salt: base64.decode(saltBase64)),
      createdAt: createdAt,
      current: KeyringEntry(
        keyFingerprint: keyFingerprint,
        encryptedDataKey: encryptedDataKey,
        keyVersion: keyVersion,
        dataKeyEpoch: dataKeyEpoch,
        archivedAt: 0,
        reason: KeyringReason.unknown,
      ),
      history: _normalizeHistory(history),
    );
  }

  /// 读取账本：优先 `keyring` 单键，缺失时回退旧多键并**立即转换落盘**
  ///
  /// 返回 null 表示本地完全未初始化。
  static Future<KeyringLedger?> load(NotesDatabase database) async {
    final fromMeta = await loadFromMeta(database);
    if (fromMeta != null) return fromMeta;

    final legacy = await fromLegacyMeta(database);
    if (legacy == null) return null;
    // 一次性转换：立刻写入新单键，后续走正常路径
    await legacy.persist(database);
    return legacy;
  }
}

/// history 规范化：按 keyVersion 去重 + 降序截断到上限
///
/// 去重沿用旧 [NotesDatabase.appendDataKeyHistory] 的语义（同 keyVersion 只留一条），
/// 排序按 keyVersion 降序，保留最近 [kKeyringHistoryLimit] 条。
List<KeyringEntry> _normalizeHistory(List<KeyringEntry> input) {
  final seen = <int>{};
  final deduped = <KeyringEntry>[];
  for (final e in input) {
    if (seen.add(e.keyVersion)) deduped.add(e);
  }
  deduped.sort((a, b) => b.keyVersion.compareTo(a.keyVersion));
  if (deduped.length > kKeyringHistoryLimit) {
    return deduped.sublist(0, kKeyringHistoryLimit);
  }
  return deduped;
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

/// 密钥环：SyncEngine 持有的唯一密钥对象（取代旧 Vault）
///
/// 同时承担两个角色：
///   1. 持久化账本（vaultId / kdf / createdAt / current / history）
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

  /// 历史密钥条目（local-only、去重、上限 20），供旧密码 repair 使用
  List<KeyringEntry> history;

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
    List<KeyringEntry>? history,
    this.mk,
  }) : history = history ?? <KeyringEntry>[];

  // ──────────────────────────────────────────────
  // 便捷访问器（语义与旧 Vault 同名字段一致）
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
        history: List<KeyringEntry>.unmodifiable(history),
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
        history: List<KeyringEntry>.from(history),
        // 关键：raw dataKey / mk 原样保留，绝不被包裹态更新抹掉（C2）
        dataKey: dataKey,
        mk: mk,
      );

  /// 投影为远端 manifest 明文头部（唯一出口，消除内联构造漏字段）
  ///
  /// [overrideEncryptedDataKey] / [overrideKeyFingerprint] /
  /// [overrideKeyVersion]：纪元不匹配时（他端改密码）传入远端三元组，
  /// 避免把远端新纪元回滚（B1-2 修复）。
  ManifestHeader toManifestHeader({
    int schemaVersion = 1,
    required int version,
    required int updatedAt,
    required String lastModifiedBy,
    String dataKeyWrap = kDataKeyWrapAlgorithm,
    String? overrideEncryptedDataKey,
    String? overrideKeyFingerprint,
    int? overrideKeyVersion,
  }) =>
      ManifestHeader(
        schemaVersion: schemaVersion,
        version: version,
        vaultId: vaultId,
        createdAt: createdAt,
        updatedAt: updatedAt,
        keyFingerprint: overrideKeyFingerprint ?? keyFingerprint,
        keyVersion: overrideKeyVersion ?? keyVersion,
        encryptedDataKey: overrideEncryptedDataKey ?? encryptedDataKey,
        kdf: kdf,
        dataKeyWrap: dataKeyWrap,
        dataKeyEpoch: dataKeyEpoch,
        lastModifiedBy: lastModifiedBy,
      );

  /// 从远端 manifest header 构建 Keyring
  ///
  /// 注意（设计约束，评审 A-P1#2）：[ManifestHeader] 只含当前密钥三元组，
  /// **不含 history**，因此新设备从远端加入时 history 必然为空。这不是 bug：
  /// 新设备本就没有旧密码派生的 MK，拿到旧 wrappedDataKey 也解不开。
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
          reason: KeyringReason.unknown,
        ),
        history: const [],
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
    return keyring;
  }

  /// 从本地存储解锁已有 keyring
  ///
  /// 优先读 `keyring` 单键；缺失时由 [KeyringLedger.load] 自动做一次性
  /// legacy 转换（旧多键 → 新单键）后继续。密码错误抛 [WrongPasswordException]。
  static Future<Keyring> unlockLocal({
    required String password,
    required NotesDatabase database,
  }) async {
    final ledger = await KeyringLedger.load(database);
    if (ledger == null) {
      throw KeyringNotInitializedException(
        '本地无 keyring 账本，也无可转换的旧 keyring 元数据',
      );
    }

    final mk = await _deriveMk(password, salt: ledger.kdf.saltBytes);
    final dataKey = _unwrapOrThrow(mk, ledger.current.encryptedDataKey);

    return Keyring(
      vaultId: ledger.vaultId,
      kdf: ledger.kdf,
      createdAt: ledger.createdAt,
      current: ledger.current,
      history: List<KeyringEntry>.from(ledger.history),
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
        reason: KeyringReason.unknown,
      ),
      // history 必然为空：远端 header 不含历史（设计约束，见 fromRemoteHeader）
      history: const [],
      dataKey: dataKey,
      mk: mk,
    );
    await keyring.persist(database);
    return keyring;
  }

  /// 解包 dataKey，失败统一转为 [WrongPasswordException]
  static Uint8List _unwrapOrThrow(Uint8List mk, String encryptedDataKey) {
    try {
      return SyncCrypto.unwrapDataKey(mk, base64.decode(encryptedDataKey));
    } on Exception catch (e) {
      // GCM tag 验证失败 = 密码错误
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
      return MigrationResult.noMigrationNeeded();
    }

    final mk = this.mk;
    if (mk == null) {
      return MigrationResult.failed('MK 未缓存，无法检查迁移');
    }

    try {
      final remoteDataKey = SyncCrypto.unwrapDataKey(
        mk,
        base64.decode(remoteEncryptedDataKey),
      );
      return MigrationResult.migrated(
        remoteDataKey: remoteDataKey,
        remoteEncryptedDataKey: remoteEncryptedDataKey,
        remoteVaultId: remoteVaultId ?? vaultId,
      );
    } on Exception catch (e) {
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
    if (!result.needsMigration) return this;
    if (!result.success || result.remoteDataKey == null) {
      throw WrongPasswordException(result.error ?? '迁移失败：远端 dataKey 不可用');
    }

    final remoteDataKey = result.remoteDataKey!;
    final remoteEncryptedDataKey = result.remoteEncryptedDataKey!;
    final remoteVaultId = result.remoteVaultId ?? vaultId;
    final keyChanged = !_sameKey(dataKey, remoteDataKey);

    // 1. 重新加密所有本地笔记（database 内部单事务，crash 安全）
    await database.reEncryptAllNotes(oldKey: dataKey, newKey: remoteDataKey);

    // Layer 2a/3：仅当 dataKey 值真正变化时标记 blob 重传并递增纪元。
    // 改密码场景（dataKey 不变）不标记，避免无谓的全量 blob 重传。
    int nextEpoch = dataKeyEpoch;
    if (keyChanged) {
      await database.markAllForBlobReupload();
      nextEpoch = dataKeyEpoch + 1;
    }

    // 2. 归档旧条目（供旧密码 repair），再切换 current
    final nextHistory = keyChanged
        ? _normalizeHistory([
            current.copyWith(
              archivedAt: DateTime.now().millisecondsSinceEpoch,
              reason: KeyringReason.migrateDataKey,
            ),
            ...history,
          ])
        : List<KeyringEntry>.from(history);

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
      history: nextHistory,
      dataKey: remoteDataKey,
      mk: mk,
    );
    await migrated.persist(database);

    // 3. 更新 database 的 dataKey（后续读写用新 key）
    database.setDataKey(remoteDataKey);
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
      return null; // 密码不匹配 → 场景 c
    }
    try {
      final dataKey = SyncCrypto.unwrapDataKey(
        mk,
        base64.decode(remoteEncryptedDataKey),
      );
      return (mk: mk, dataKey: dataKey);
    } on Exception {
      // fingerprint 匹配但 unwrap 失败（理论上不应发生，防御性处理）
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
    final keyChanged = !_sameKey(dataKey, remoteDataKey);

    await database.reEncryptAllNotes(oldKey: dataKey, newKey: remoteDataKey);

    int nextEpoch = dataKeyEpoch;
    if (keyChanged) {
      await database.markAllForBlobReupload();
      nextEpoch = dataKeyEpoch + 1;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final nextHistory = keyChanged
        ? _normalizeHistory([
            current.copyWith(
              archivedAt: now,
              reason: KeyringReason.migrateDataKey,
            ),
            ...history,
          ])
        : List<KeyringEntry>.from(history);

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
      history: nextHistory,
      dataKey: remoteDataKey,
      mk: remoteMk,
    );
    await migrated.persist(database);

    database.setDataKey(remoteDataKey);
    return migrated;
  }

  // ──────────────────────────────────────────────
  // 改密码 / 纪元采用
  // ──────────────────────────────────────────────

  /// 验证密码是否正确（不持久化，不改状态）
  Future<void> verifyPassword(String password) async {
    final probe = await _deriveMk(password, salt: kdf.saltBytes);
    try {
      SyncCrypto.unwrapDataKey(probe, base64.decode(encryptedDataKey));
    } on Exception catch (e) {
      throw WrongPasswordException('密码错误：$e');
    }
  }

  /// 修改密码：重新 wrap dataKey + 递增 keyVersion（O(1)，不触碰笔记）
  ///
  /// 返回**新实例**（mk 变为新派生 MK），调用方必须替换持有的引用（评审 B-M3）。
  /// dataKey 值不变 → dataKeyEpoch 不变。旧 current 压入 history 供 repair。
  Future<Keyring> changePassword({
    required String oldPassword,
    required String newPassword,
    required NotesDatabase database,
  }) async {
    final salt = kdf.saltBytes;

    // 1. 验证旧密码
    final oldMk = await _deriveMk(oldPassword, salt: salt);
    try {
      SyncCrypto.unwrapDataKey(oldMk, base64.decode(encryptedDataKey));
    } on Exception catch (e) {
      throw WrongPasswordException('旧密码错误：$e');
    }

    // 2. 新 MK 重新 wrap（dataKey 本身不变）
    final newMk = await _deriveMk(newPassword, salt: salt);
    final newEncryptedDataKey =
        base64.encode(SyncCrypto.wrapDataKey(newMk, dataKey));
    final newKeyFingerprint = SyncCrypto.computeKeyFingerprint(newMk);
    final now = DateTime.now().millisecondsSinceEpoch;

    // 3. 归档旧条目 + 生成新 current（一次 persist 取代旧实现的 4 次写）
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
      history: _normalizeHistory([
        current.copyWith(
          archivedAt: now,
          reason: KeyringReason.changePassword,
        ),
        ...history,
      ]),
      dataKey: dataKey,
      mk: newMk,
    );
    await changed.persist(database);
    return changed;
  }

  /// 更新 encryptedDataKey（H1：同步时回写远端包裹值）
  ///
  /// dataKey 未变（只是 wrap 它的 MK 变了），无需重加密笔记。
  /// **原地更新**，保证共享同一实例的 SyncService/SyncEngine 状态一致。
  Future<void> updateEncryptedDataKey(
    String newEncryptedDataKey,
    NotesDatabase database,
  ) async {
    if (newEncryptedDataKey == encryptedDataKey) return;
    current = current.copyWith(encryptedDataKey: newEncryptedDataKey);
    await persist(database);
  }

  /// 采用远端密钥纪元（B1-2 / H1 修复；C2 的正确写法）
  ///
  /// 场景：设备 A 改密码上传新纪元，设备 B 用新密码登录但本地账本仍是旧纪元。
  /// 此时必须整体采用远端三元组，否则本地 keyVersion 永远落后 → 每轮误报
  /// "他端改密码"，且构建 header 时回滚远端纪元（BUG-3）。
  ///
  /// **关键：只更新包裹态与纪元字段，raw dataKey / mk 绝不触碰**
  /// （改密码场景 dataKey 值本就未变；整条目替换会抹掉 raw dataKey → C2）。
  Future<void> adoptRemoteEpoch({
    required String remoteEncryptedDataKey,
    required String remoteKeyFingerprint,
    required int remoteKeyVersion,
    int remoteDataKeyEpoch = 1,
    required NotesDatabase database,
  }) async {
    // 归档被替换的本地条目：远端换过密码时，本地旧 wrappedDataKey 仍可能是
    // repair 的恢复锚点（用旧密码解开）。仅在包裹值确实变化时归档。
    if (current.encryptedDataKey != remoteEncryptedDataKey &&
        current.encryptedDataKey.isNotEmpty) {
      history = _normalizeHistory([
        current.copyWith(
          archivedAt: DateTime.now().millisecondsSinceEpoch,
          reason: KeyringReason.adoptRemoteEpoch,
        ),
        ...history,
      ]);
    }

    current = current.copyWith(
      encryptedDataKey: remoteEncryptedDataKey,
      keyFingerprint: remoteKeyFingerprint,
      keyVersion: remoteKeyVersion,
      dataKeyEpoch: remoteDataKeyEpoch,
      reason: KeyringReason.adoptRemoteEpoch,
    );
    await persist(database);
    // dataKey / mk 保持原值，绝不被触碰
  }

  // ──────────────────────────────────────────────
  // 检查 / 工具方法
  // ──────────────────────────────────────────────

  /// 本地是否已初始化（有 keyring 单键，或可从旧 meta 转换）
  static Future<bool> isInitialized(NotesDatabase database) async {
    final fromMeta = await KeyringLedger.loadFromMeta(database);
    if (fromMeta != null) return true;
    return (await KeyringLedger.fromLegacyMeta(database)) != null;
  }

  /// 读取 vaultId（不解锁）
  static Future<String?> getVaultId(NotesDatabase database) async =>
      (await KeyringLedger.load(database))?.vaultId;

  /// 读取 encryptedDataKey（不解锁）
  static Future<String?> getEncryptedDataKey(NotesDatabase database) async =>
      (await KeyringLedger.load(database))?.current.encryptedDataKey;

  /// 候选历史 dataKey：用旧密码派生的 MK 逐个解开 history 中的包裹条目
  ///
  /// 供 `SyncEngine.repairRemote(oldPassword:)` 构建候选 dataKey 集合，
  /// 取代旧的 `database.getDataKeyHistory()` 直读。解不开的条目静默跳过
  /// （它们是用别的 MK 包裹的）。
  List<Uint8List> unwrapHistoryWith(Uint8List oldMk) {
    final result = <Uint8List>[];
    for (final entry in history) {
      if (entry.encryptedDataKey.isEmpty) continue;
      try {
        final dk = SyncCrypto.unwrapDataKey(
          oldMk,
          base64.decode(entry.encryptedDataKey),
        );
        if (!result.any((c) => _sameKey(c, dk))) result.add(dk);
      } on Object {
        // 该条目不是用 oldMk 包裹的（或已损坏），跳过
        continue;
      }
    }
    return result;
  }

  @override
  String toString() => 'Keyring(vaultId=$vaultId, current=$current, '
      'history=${history.length})';

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
