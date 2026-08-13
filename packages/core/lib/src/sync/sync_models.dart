/*
 * 同步数据模型
 *
 * 包含：
 *   - ManifestHeader：远端 manifest 明文头部（version + vaultId + encryptedDataKey + KDF 参数 + 密钥纪元）
 *   - ManifestItem：manifest 加密体中单条笔记的元数据（hash + deleted + updatedAt + updatedBy + createdAt + deletedAt + contentSize）
 *   - Manifest：完整 manifest（header + items），便于内存操作
 *   - SyncState：本地同步状态（version + etag + 最后同步时间）
 *   - SyncResult：单次同步的结果统计
 *   - SyncActionType / SyncAction：单条同步操作（用于 UI 进度反馈）
 *
 * Manifest 文件格式（上传到后端的密文）：
 *   ┌─────────────────────────────────────────────┐
 *   │ 明文 JSON header（UTF-8 字节）              │
 *   │ {                                           │
 *   │   "schemaVersion": 1,                       │
 *   │   "version": 42,                            │
 *   │   "vaultId": "uuid-xxx",                    │
 *   │   "createdAt": 1719470000000,               │
 *   │   "updatedAt": 1719470000000,               │
 *   │   "keyFingerprint": "hex(MK)",              │
 *   │   "keyVersion": 1,                          │
 *   │   "encryptedDataKey": "base64...",          │
 *   │   "kdf": {                                  │
 *   │     "algorithm": "PBKDF2-HMAC-SHA256",      │
 *   │     "salt": "base64(per-vault-random)",     │
 *   │     "iterations": 200000                    │
 *   │   },                                        │
 *   │   "dataKeyWrap": "AES-256-GCM",             │
 *   │   "lastModifiedBy": "android-xxx"           │
 *   │ }                                           │
 *   ├─────────────────────────────────────────────┤
 *   │ 4 字节大端长度（header JSON 字节数）        │
 *   ├─────────────────────────────────────────────┤
 *   │ 加密 items（用 dataKey 加密）               │
 *   │ AES-GCM(dataKey, AAD='manifest-items',      │
 *   │         plaintext=items JSON)               │
 *   └─────────────────────────────────────────────┘
 *
 * 设计理由：
 *   - header 明文：新设备加入时无需 dataKey 即可拿到 encryptedDataKey 和 KDF 参数，
 *     用密码派生 MK 解开它得到 dataKey，再解密 items。这是多端 join 的关键。
 *   - items 加密：笔记元数据虽然不包含内容，但仍加密以防泄露笔记数量和更新模式。
 *   - KDF 参数写入 header：算法透明，per-vault salt 随 header 传播，新设备自动获取。
 *   - 密钥纪元（keyFingerprint/keyVersion）：检测他端改密码，防止翻转战争。
 */

// Dart 原生导入
import 'dart:convert';
import 'dart:typed_data';

// Package 导入
import 'package:core/src/crypto/crypto.dart';
import 'package:core/src/sync/sync_error.dart';
import 'package:crypto/crypto.dart' show sha256;

/// manifest 协议 schema 版本号（v5：可靠性容器重构）
///
/// 历史：
///   - v1：初始（schemaVersion 从未被真实写入，恒默认 1）
///   - v3：移除遗留兼容，blob 仅支持 AAD=`'<epoch>|<hash>'`（纸面版本）
///   - v4：**epoch 消除**——blob 纯化 AAD=hash（去 epoch）、
///     `blobKeyEpoch` 语义从「待现代化」变为「加密版本标签」纯审计元数据、
///     `dataKeyEpoch` 不再驱动同步、新增 item/header 自描述元数据
///     （`dataKeyFingerprint`/`createdBy`/`dataKeyCreatedAt`/`dataKeyCreatedBy`）。
///   - v5：**可靠性容器重构**（manifest-reliability-design §5）——
///     manifest 二进制容器加入 magic `'SMNT'` + fileVer + schemaV 固定头 +
///     尾部无密钥 `pubHash`（SHA-256）损坏校验。彻底区分「数据损坏」与
///     「密钥不匹配」两类失败（详见 §3.2 / §5.3），消除"items GCM 解密失败
///     一律按密钥问题处理"导致的「损坏被误判为 scenario-b 强制重登」回归。
///     新增具名异常 `ManifestAuthException` / `ManifestKeyMismatchException`
///     替代"全靠 GCM 抛错再猜"。不兼容旧 v4 二进制（开发中未发布，废弃重建）。
///
/// 用途（§7.1 / §8.2[G]）：
///   - 所有新写出的 manifest 显式写入此值（`Manifest.empty` / `_buildLocalManifest`
///     / repair），替代过去「从不真实写入、恒默认 1」的纸面版本号。
///   - 下载侧降级拒绝：`header.schemaVersion < kManifestSchemaVersion` 时拒绝
///     解读并提示升级（业界「拒绝旧协议防降级」共识，与不兼容策略 §0 对齐）。
const int kManifestSchemaVersion = 5;

/// manifest 中单条笔记的元数据
///
/// 不含笔记内容，内容通过 hash 在 blob 中寻址。
/// 用于 LWW 冲突解决和增量检测。
class ManifestItem {
  /// 笔记内容的 SHA-256 哈希（十六进制字符串）
  ///
  /// 同时也是 blob 的文件名/键名，实现内容寻址和天然去重。
  final String hash;

  /// 是否已删除（墓碑标记）
  ///
  /// true 表示这条笔记已被软删除，用于同步删除操作到其他设备。
  /// 墓碑按 [deletedAt] 超过 30 天后可被 GC 清理。
  final bool deleted;

  /// 最后更新时间（Unix 毫秒）
  ///
  /// 用于 LWW（Last-Write-Wins）冲突解决：
  ///   远端 updatedAt > 本地 updatedAt → 远端胜
  ///   远端 updatedAt < 本地 updatedAt → 本地胜
  ///   相等但 hash 不同 → 保留 hash 字典序小的（兜底，极少触发）
  final int updatedAt;

  /// 最后修改此笔记的设备 ID（如 'android-xxx'）
  ///
  /// 用于冲突诊断和审计。明文存储，不降低安全性
  /// （攻击者通过 hash 已能侧信道验证内容）。
  final String updatedBy;

  /// 笔记创建时间（Unix 毫秒）
  ///
  /// 解决 R10：远端下载笔记时保留原始创建时间，而非用下载时刻。
  final int createdAt;

  /// 软删除时间（Unix 毫秒，null 表示未删除）
  ///
  /// 用于 GC：墓碑按 deletedAt 超过 30 天后可清理。
  /// 区别于 updatedAt：笔记可能在删除后有其他更新（理论上不应发生，但防御性设计）。
  final int? deletedAt;

  /// 笔记内容大小（字节）
  ///
  /// §6.3 修订 2（语义注释）：定义为 **payload（JSON）字节长**
  /// （=`SafeNote.toContentBytes().length`，含 `"v"` 字段），与「身份域」
  /// （hash = SHA-256(title+"\n"+description)）解耦——payload 是存储表示，
  /// hash 是逻辑身份，二者域不同。用于 GC 优先级和统计；hash 已是更强的
  /// 内容侧信道，contentSize 不增加安全风险。
  final int contentSize;

  /// blob 密钥纪元（Layer 3 显式标记）
  ///
  /// 记录加密该笔记 blob 时使用的 dataKey 纪元。
  /// **v4（epoch 消除）后语义变为「加密版本标签」纯审计元数据**：解密已不读它
  /// （blob 纯化 AAD=hash），纪元数字不同不代表内容有变更，也不再驱动任何
  /// 重传/自愈动作。「旧 key vs 损坏」的判定改由 [dataKeyFingerprint] 精确承担。
  final int blobKeyEpoch;

  /// 加密该 blob 的 dataKey 的指纹（H(dataKey)，v4 新增，item 自描述）
  ///
  /// 标记「这条 blob 用哪把 dataKey 加密」。本地构建时恒为当前指纹
  /// （本地 blob 全部由迁移单事务重加密为当前 dataKey，与事实相符，非乐观声明）。
  /// 解密端不推断、不比较、不纠正，仅用于：
  ///   - 解密失败时精确区分「旧 key 数据（可提示修复）」与「真损坏（不可修）」：
  ///     `dataKeyFingerprint == 当前指纹` 却解不开 → 真损坏；不等 → 旧密钥数据。
  ///   - 审计（配合 [dataKeyCreatedAt] / [dataKeyCreatedBy] 提示「由谁、何时加密」）。
  ///
  /// 这是 Joplin `master_key_id` 模式的等价物：item 自描述「用哪把 key 加密」，
  /// 指纹是数据派生身份（SHA-256 单向），不依赖两端纪元历史一致，比 epoch 更强。
  final String dataKeyFingerprint;

  /// 创建此笔记的设备 ID（v4 新增，审计元数据）
  ///
  /// 明文存储，只读用于审计与解密失败提示，不驱动同步行为。
  final String createdBy;

  /// 加密该 blob 的 dataKey 的创建时间（Unix 毫秒，v4 新增，审计元数据）
  ///
  /// 等同 keyring 创建时间（dataKey 在 keyring 创建时生成）。用于解密失败时
  /// 给出精确提示「该数据由 X 设备于某时间加密」。
  final int? dataKeyCreatedAt;

  /// 加密该 blob 的 dataKey 的创建设备 ID（v4 新增，审计元数据）
  final String? dataKeyCreatedBy;

  const ManifestItem({
    required this.hash,
    required this.deleted,
    required this.updatedAt,
    required this.updatedBy,
    required this.createdAt,
    this.deletedAt,
    this.contentSize = 0,
    this.blobKeyEpoch = 1,
    this.dataKeyFingerprint = '',
    this.createdBy = '',
    this.dataKeyCreatedAt,
    this.dataKeyCreatedBy,
  });

  ManifestItem copyWith({
    String? hash,
    bool? deleted,
    int? updatedAt,
    String? updatedBy,
    int? createdAt,
    int? deletedAt,
    int? contentSize,
    int? blobKeyEpoch,
    String? dataKeyFingerprint,
    String? createdBy,
    int? dataKeyCreatedAt,
    String? dataKeyCreatedBy,
  }) => ManifestItem(
    hash: hash ?? this.hash,
    deleted: deleted ?? this.deleted,
    updatedAt: updatedAt ?? this.updatedAt,
    updatedBy: updatedBy ?? this.updatedBy,
    createdAt: createdAt ?? this.createdAt,
    deletedAt: deletedAt ?? this.deletedAt,
    contentSize: contentSize ?? this.contentSize,
    blobKeyEpoch: blobKeyEpoch ?? this.blobKeyEpoch,
    dataKeyFingerprint: dataKeyFingerprint ?? this.dataKeyFingerprint,
    createdBy: createdBy ?? this.createdBy,
    dataKeyCreatedAt: dataKeyCreatedAt ?? this.dataKeyCreatedAt,
    dataKeyCreatedBy: dataKeyCreatedBy ?? this.dataKeyCreatedBy,
  );

  /// 序列化为 JSON（用于 manifest 加密体存储）
  Map<String, dynamic> toJson() => {
    'hash': hash,
    'deleted': deleted,
    'updatedAt': updatedAt,
    'updatedBy': updatedBy,
    'createdAt': createdAt,
    if (deletedAt != null) 'deletedAt': deletedAt,
    'contentSize': contentSize,
    'blobKeyEpoch': blobKeyEpoch,
    if (dataKeyFingerprint.isNotEmpty) 'dataKeyFingerprint': dataKeyFingerprint,
    if (createdBy.isNotEmpty) 'createdBy': createdBy,
    if (dataKeyCreatedAt != null) 'dataKeyCreatedAt': dataKeyCreatedAt,
    if (dataKeyCreatedBy != null) 'dataKeyCreatedBy': dataKeyCreatedBy,
  };

  /// 从 JSON 反序列化
  factory ManifestItem.fromJson(Map<String, dynamic> json) {
    return ManifestItem(
      hash: json['hash'] as String,
      deleted: json['deleted'] as bool,
      updatedAt: json['updatedAt'] as int,
      updatedBy: json['updatedBy'] as String? ?? '',
      createdAt: json['createdAt'] as int? ?? json['updatedAt'] as int,
      deletedAt: json['deletedAt'] as int?,
      contentSize: json['contentSize'] as int? ?? 0,
      blobKeyEpoch: (json['blobKeyEpoch'] as int?) ?? 0,
      dataKeyFingerprint: (json['dataKeyFingerprint'] as String?) ?? '',
      createdBy: (json['createdBy'] as String?) ?? '',
      dataKeyCreatedAt: json['dataKeyCreatedAt'] as int?,
      dataKeyCreatedBy: json['dataKeyCreatedBy'] as String?,
    );
  }

  @override
  String toString() =>
      'ManifestItem(hash=$hash, deleted=$deleted, updatedAt=$updatedAt, '
      'updatedBy=$updatedBy, contentSize=$contentSize, blobKeyEpoch=$blobKeyEpoch, '
      'dataKeyFingerprint=${dataKeyFingerprint.length > 8 ? dataKeyFingerprint.substring(0, 8) : dataKeyFingerprint})';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ManifestItem &&
          hash == other.hash &&
          deleted == other.deleted &&
          updatedAt == other.updatedAt &&
          updatedBy == other.updatedBy &&
          createdAt == other.createdAt &&
          deletedAt == other.deletedAt &&
          contentSize == other.contentSize &&
          blobKeyEpoch == other.blobKeyEpoch &&
          dataKeyFingerprint == other.dataKeyFingerprint &&
          createdBy == other.createdBy &&
          dataKeyCreatedAt == other.dataKeyCreatedAt &&
          dataKeyCreatedBy == other.dataKeyCreatedBy;

  @override
  int get hashCode => Object.hash(
    hash,
    deleted,
    updatedAt,
    updatedBy,
    createdAt,
    deletedAt,
    contentSize,
    blobKeyEpoch,
    dataKeyFingerprint,
    createdBy,
    dataKeyCreatedAt,
    dataKeyCreatedBy,
  );
}

/// MK 派生参数（KDF parameters）
///
/// 写入 manifest header 明文部分，供新设备加入时按相同参数派生 MK。
/// per-vault 随机 salt 随 header 传播，确保跨用户预计算失效。
class KdfParams {
  /// KDF 算法名称（如 'ARGON2ID' 或 'PBKDF2-HMAC-SHA256'）
  final String algorithm;

  /// 随机 salt（base64 编码，per-vault / per-backup 随机生成）
  final String salt;

  /// 迭代次数（PBKDF2 的 iterations；Argon2id 的 t）
  final int iterations;

  /// Argon2id 内存占用（KiB，如 32768 = 32 MiB）。PBKDF2 为 null。
  final int? memoryKiB;

  /// Argon2id 并行度（lane 数）。PBKDF2 为 null。
  final int? parallelism;

  const KdfParams({
    required this.algorithm,
    required this.salt,
    required this.iterations,
    this.memoryKiB,
    this.parallelism,
  });

  /// 创建 KDF 参数（使用传入的 salt）
  ///
  /// 默认新 vault 走 Argon2id（[kMkKdfAlgorithm]、[kArgon2idIterations]、
  /// [kArgon2idMemoryKib]、[kArgon2idParallelism]）。存量 PBKDF2 老 vault
  /// 走 [KdfParams.fromJson] 反序列化，[memoryKiB]/[parallelism] 为 null。
  ///
  /// [salt] 随机生成的 16 字节 salt
  factory KdfParams.create({required Uint8List salt}) => KdfParams(
    algorithm: kMkKdfAlgorithm,
    salt: base64.encode(salt),
    iterations: kArgon2idIterations,
    memoryKiB: kArgon2idMemoryKib,
    parallelism: kArgon2idParallelism,
  );

  Map<String, dynamic> toJson() => {
    'algorithm': algorithm,
    'salt': salt,
    'iterations': iterations,
    if (memoryKiB != null) 'memoryKiB': memoryKiB,
    if (parallelism != null) 'parallelism': parallelism,
  };

  factory KdfParams.fromJson(Map<String, dynamic> json) {
    return KdfParams(
      algorithm: json['algorithm'] as String,
      salt: json['salt'] as String,
      iterations: json['iterations'] as int,
      memoryKiB: json['memoryKiB'] as int?,
      parallelism: json['parallelism'] as int?,
    );
  }

  /// 获取 salt 的原始字节（解码 base64）
  Uint8List get saltBytes => base64.decode(salt);

  @override
  String toString() =>
      'KdfParams(algorithm=$algorithm, iterations=$iterations, '
      'memoryKiB=$memoryKiB, parallelism=$parallelism, salt=$salt)';
}

/// 远端 manifest 明文头部
///
/// 新设备加入时，先读取此头部拿到 encryptedDataKey、KDF 参数和密钥纪元，
/// 用密码按 KDF 参数派生 MK，解开 encryptedDataKey 得到 dataKey，
/// 然后才能解密 items 部分。
class ManifestHeader {
  /// 协议 schema 版本号（从 1 开始）
  ///
  /// 未来字段迁移时递增，用于自愈和兼容性判断。
  final int schemaVersion;

  /// manifest 版本号（每次成功 PUT 后 +1）
  ///
  /// 用于检测冲突和调试。不是乐观锁的依据（ETag 才是）。
  final int version;

  /// keyring 唯一标识（UUIDv4）
  ///
  /// 首次启用同步时生成，所有设备共享同一个 vaultId。
  /// 仅作同步组标识，不再作为 PBKDF2 salt。
  final String vaultId;

  /// keyring 创建时间（Unix 毫秒）
  ///
  /// 首次启用同步时设置，后续不变。用于审计。
  final int createdAt;

  /// manifest 自身的更新时间（Unix 毫秒）
  final int updatedAt;

  /// 密钥指纹 = H(MK)，跨设备一致（相同密码 + 相同 salt → 相同 MK → 相同 fingerprint）
  ///
  /// 用于检测他端改密码：
  ///   - 远端 fingerprint != 本地 fingerprint → 他端改了密码
  ///   - 安全性：与 encryptedDataKey 等价（都能离线验证密码），不降低安全性
  final String keyFingerprint;

  /// 密钥版本号（单调递增）
  ///
  /// createNew=1，changePassword +1。用于防止旧密码设备回滚新密码包裹。
  final int keyVersion;

  /// 用 MK 加密后的 dataKey（base64 字符串）
  ///
  /// 改密码时只更新这一个字段，blob 零传输。
  /// 多设备重新认证时，用本地密码派生 MK 解开此字段得到 dataKey。
  final String encryptedDataKey;

  /// MK 派生参数（算法/salt/iterations）
  ///
  /// per-vault 随机 salt 写入 header，新设备按此 salt 派生 MK。
  final KdfParams kdf;

  /// dataKey 包装算法（如 'AES-256-GCM'）
  final String dataKeyWrap;

  /// dataKey 纪元（Layer 3 显式标记，单调 int，独立于 keyVersion）
  ///
  /// 记录当前 dataKey 的纪元。下载 blob 时与 [ManifestItem.blobKeyEpoch] 比较：
  ///   - 相等 → blob 用当前 dataKey 加密，正常解密；
  ///   - 不等 → blob 由「非当前 dataKey」加密（旧密钥 blob），走显式修复路径。
  ///
  /// 新设备加入时从此 header 学习当前纪元；发布 manifest 时写入本机纪元。
  /// **v4（epoch 消除）后不再驱动同步行为**，仅作元数据/审计；「旧 key vs
  /// 损坏」判定改由 [dataKeyFingerprint] 精确承担。
  /// 默认 1。
  final int dataKeyEpoch;

  /// 当前 dataKey 的指纹（H(dataKey)，v4 新增，明文自描述）
  ///
  /// 用于 scenario-b 精确判定「dataKey 是否相同」（替代旧「本地 MK 解不开 +
  /// items 能解」的间接信号）与解密失败时的审计提示。恒为创建方当前 dataKey
  /// 的 SHA-256 指纹，单向不泄露 dataKey。
  final String dataKeyFingerprint;

  /// 当前 dataKey 的创建时间（Unix 毫秒，v4 新增，审计元数据）
  ///
  /// 等同 keyring 创建时间（dataKey 在 keyring 创建时生成）。用于解密失败时
  /// 提示「该数据由 X 设备于某时间加密」。
  final int? dataKeyCreatedAt;

  /// 当前 dataKey 的创建设备 ID（v4 新增，审计元数据）
  final String? dataKeyCreatedBy;

  /// 最后修改此 manifest 的设备 ID（如 'android-xxx'）
  ///
  /// 用于调试和并发冲突诊断。
  final String lastModifiedBy;

  const ManifestHeader({
    this.schemaVersion = kManifestSchemaVersion,
    required this.version,
    required this.vaultId,
    required this.createdAt,
    required this.updatedAt,
    required this.keyFingerprint,
    this.keyVersion = 1,
    required this.encryptedDataKey,
    required this.kdf,
    required this.dataKeyWrap,
    this.dataKeyEpoch = 1,
    this.dataKeyFingerprint = '',
    this.dataKeyCreatedAt,
    this.dataKeyCreatedBy,
    required this.lastModifiedBy,
  });

  ManifestHeader copyWith({
    int? schemaVersion,
    int? version,
    String? vaultId,
    int? createdAt,
    int? updatedAt,
    String? keyFingerprint,
    int? keyVersion,
    String? encryptedDataKey,
    KdfParams? kdf,
    String? dataKeyWrap,
    int? dataKeyEpoch,
    String? dataKeyFingerprint,
    int? dataKeyCreatedAt,
    String? dataKeyCreatedBy,
    String? lastModifiedBy,
  }) => ManifestHeader(
    schemaVersion: schemaVersion ?? this.schemaVersion,
    version: version ?? this.version,
    vaultId: vaultId ?? this.vaultId,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    keyFingerprint: keyFingerprint ?? this.keyFingerprint,
    keyVersion: keyVersion ?? this.keyVersion,
    encryptedDataKey: encryptedDataKey ?? this.encryptedDataKey,
    kdf: kdf ?? this.kdf,
    dataKeyWrap: dataKeyWrap ?? this.dataKeyWrap,
    dataKeyEpoch: dataKeyEpoch ?? this.dataKeyEpoch,
    dataKeyFingerprint: dataKeyFingerprint ?? this.dataKeyFingerprint,
    dataKeyCreatedAt: dataKeyCreatedAt ?? this.dataKeyCreatedAt,
    dataKeyCreatedBy: dataKeyCreatedBy ?? this.dataKeyCreatedBy,
    lastModifiedBy: lastModifiedBy ?? this.lastModifiedBy,
  );

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'version': version,
    'vaultId': vaultId,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    'keyFingerprint': keyFingerprint,
    'keyVersion': keyVersion,
    'encryptedDataKey': encryptedDataKey,
    'kdf': kdf.toJson(),
    'dataKeyWrap': dataKeyWrap,
    'dataKeyEpoch': dataKeyEpoch,
    if (dataKeyFingerprint.isNotEmpty) 'dataKeyFingerprint': dataKeyFingerprint,
    if (dataKeyCreatedAt != null) 'dataKeyCreatedAt': dataKeyCreatedAt,
    if (dataKeyCreatedBy != null) 'dataKeyCreatedBy': dataKeyCreatedBy,
    'lastModifiedBy': lastModifiedBy,
  };

  factory ManifestHeader.fromJson(Map<String, dynamic> json) {
    return ManifestHeader(
      schemaVersion: json['schemaVersion'] as int? ?? 1,
      version: json['version'] as int,
      vaultId: json['vaultId'] as String,
      createdAt: json['createdAt'] as int? ?? json['updatedAt'] as int,
      updatedAt: json['updatedAt'] as int,
      keyFingerprint: json['keyFingerprint'] as String? ?? '',
      keyVersion: json['keyVersion'] as int? ?? 1,
      encryptedDataKey: json['encryptedDataKey'] as String,
      kdf: KdfParams.fromJson(json['kdf'] as Map<String, dynamic>),
      dataKeyWrap: json['dataKeyWrap'] as String,
      dataKeyEpoch: (json['dataKeyEpoch'] as int?) ?? 1,
      dataKeyFingerprint: (json['dataKeyFingerprint'] as String?) ?? '',
      dataKeyCreatedAt: json['dataKeyCreatedAt'] as int?,
      dataKeyCreatedBy: json['dataKeyCreatedBy'] as String?,
      lastModifiedBy: json['lastModifiedBy'] as String,
    );
  }

  @override
  String toString() =>
      'ManifestHeader(schemaVersion=$schemaVersion, version=$version, '
      'vaultId=$vaultId, keyVersion=$keyVersion, lastModifiedBy=$lastModifiedBy)';
}

/// 远端 manifest 完整结构（header + items）
///
/// 内存中操作时使用完整 Manifest 对象；
/// 序列化到后端时拆分为 header（明文）+ items（加密）两部分。
class Manifest {
  /// 明文头部（含 vaultId / encryptedDataKey / KDF 参数 / 密钥纪元等）
  final ManifestHeader header;

  /// 所有笔记的元数据（note uuid → ManifestItem）
  ///
  /// 包含已删除的墓碑。客户端可主动清理过期墓碑（30 天前）。
  final Map<String, ManifestItem> items;

  const Manifest({required this.header, required this.items});

  // ── 便捷访问器（委托给 header） ─────────────────────────

  int get version => header.version;
  String get vaultId => header.vaultId;
  int get updatedAt => header.updatedAt;
  String get encryptedDataKey => header.encryptedDataKey;
  String get keyFingerprint => header.keyFingerprint;
  int get keyVersion => header.keyVersion;

  Manifest copyWith({
    ManifestHeader? header,
    Map<String, ManifestItem>? items,
  }) => Manifest(header: header ?? this.header, items: items ?? this.items);

  /// 仅更新 header 的部分字段（便捷方法）
  Manifest copyWithHeader({
    int? version,
    int? updatedAt,
    String? encryptedDataKey,
    String? keyFingerprint,
    int? keyVersion,
    String? lastModifiedBy,
    Map<String, ManifestItem>? items,
  }) => Manifest(
    header: header.copyWith(
      version: version,
      updatedAt: updatedAt,
      encryptedDataKey: encryptedDataKey,
      keyFingerprint: keyFingerprint,
      keyVersion: keyVersion,
      lastModifiedBy: lastModifiedBy,
    ),
    items: items ?? this.items,
  );

  /// 创建空 manifest（首次启用同步时用）
  factory Manifest.empty({
    required String vaultId,
    required String encryptedDataKey,
    required String keyFingerprint,
    required KdfParams kdf,
    required int createdAt,
    required String lastModifiedBy,
  }) {
    return Manifest(
      header: ManifestHeader(
        // v4：schemaVersion 真值化（§7.1），不再写死 1
        schemaVersion: kManifestSchemaVersion,
        version: 0,
        vaultId: vaultId,
        createdAt: createdAt,
        updatedAt: createdAt,
        keyFingerprint: keyFingerprint,
        keyVersion: 1,
        encryptedDataKey: encryptedDataKey,
        kdf: kdf,
        dataKeyWrap: kDataKeyWrapAlgorithm,
        lastModifiedBy: lastModifiedBy,
      ),
      items: {},
    );
  }

  @override
  String toString() =>
      'Manifest(version=$version, vaultId=$vaultId, keyVersion=$keyVersion, '
      'items=${items.length})';
}

/// 同步操作类型（用于 UI 进度反馈和日志）
enum SyncActionType {
  upload, // 上传笔记到远端
  download, // 从远端下载笔记
  delete, // 标记为删除（墓碑同步）
  skip, // 跳过（已同步）
  conflict, // 冲突（LWW 落败）
  migrate, // dataKey 迁移（本地数据重新加密）
  uploadFailed, // 单个 blob 上传失败（容错，不中断同步）
  corrupt, // blob 下载解密失败且无本地明文可自愈（记录为失败，重试）
  heal, // blob 下载失败时用本地明文自愈重传（覆盖服务器坏 blob）
}

/// 单条同步操作记录
class SyncAction {
  final SyncActionType type;
  final String uuid; // 笔记 UUID
  final String? hash; // 涉及的 blob hash（可能为空）

  /// 附加信息（如冲突原因、修复说明等）
  ///
  /// 向后兼容字段：旧 UI 直接显示此字段。新代码应优先使用 [error]，
  /// 当 [error] 为 null 时此字段作为补充说明。
  final String? message;

  /// 结构化错误信息（可选）
  ///
  /// 当 [type] 为 [SyncActionType.uploadFailed] / [SyncActionType.corrupt] 等
  /// 失败类型时，此字段持有具体错误信息，便于调试面板展示和日志聚合。
  /// 与 [message] 的关系：error 是机器可读结构化信息，message 是人可读补充说明。
  /// 调试面板应优先显示 error.toDisplayString()，其次显示 message。
  final SyncError? error;

  const SyncAction({
    required this.type,
    required this.uuid,
    this.hash,
    this.message,
    this.error,
  });

  /// 调试面板展示用：优先返回 error 的描述，其次返回 message
  String get displayMessage => error?.toDisplayString() ?? message ?? type.name;

  @override
  String toString() =>
      'SyncAction($type, uuid=$uuid, hash=$hash'
      '${error != null ? ', err=${error!.label}' : ''}'
      '${message != null ? ', msg=$message' : ''})';
}

/// 同步结果统计
class SyncResult {
  final bool success;
  final int uploaded;
  final int downloaded;
  final int deleted;
  final int skipped;
  final int conflicts;
  final int migrated; // 迁移的笔记数（dataKey 变更时）
  final String? errorMessage;
  final List<SyncAction> actions; // 详细操作记录（用于 UI 和日志）
  final int attempts; // 实际重试次数（用于诊断乐观锁冲突频率）
  /// 密钥纪元不匹配标志（远端 keyVersion > 本地）
  ///
  /// true 表示他端改了密码，UI 应提示用户输入新密码。
  /// 注意：v4（epoch 消除）后引擎不再设置该标志（恒为 false），
  /// scenario-b 改用 [requiresRelogin] 表达"必须重新登录"。保留字段仅为
  /// 兼容旧诊断面板展示。
  final bool passwordEpochMismatch;

  /// 是否需要强制重新登录（v4 scenario-b：他端改了密码，本地密码已过期）
  ///
  /// true 表示同步被中止（零写入），UI 必须提示用户退出并重新登录，
  /// 否则本地新建/修改的笔记无法同步到远端。对应设计定案
  /// 「选项 B（失败 + 强制重登录）」（docs/epoch-elimination-design-20260801.md §8.2[I]）。
  final bool requiresRelogin;

  /// 因密钥不匹配 / 数据损坏等原因，本次同步未能获取（且无本地明文可自愈）的笔记 uuid 列表。
  ///
  /// 自愈（Layer 2b）成功的笔记不计入此列表；只有"下载解密失败 + 本地无明文"的笔记才计入，
  /// 这类笔记会在后续同步中继续重试下载。
  final List<String> failedNoteUuids;

  const SyncResult({
    required this.success,
    this.uploaded = 0,
    this.downloaded = 0,
    this.deleted = 0,
    this.skipped = 0,
    this.conflicts = 0,
    this.migrated = 0,
    this.errorMessage,
    this.actions = const [],
    this.attempts = 1,
    this.passwordEpochMismatch = false,
    this.requiresRelogin = false,
    this.failedNoteUuids = const [],
  });

  /// 同步成功
  factory SyncResult.success({
    int uploaded = 0,
    int downloaded = 0,
    int deleted = 0,
    int skipped = 0,
    int conflicts = 0,
    int migrated = 0,
    List<SyncAction> actions = const [],
    int attempts = 1,
    bool passwordEpochMismatch = false,
    List<String> failedNoteUuids = const [],
  }) => SyncResult(
    success: true,
    uploaded: uploaded,
    downloaded: downloaded,
    deleted: deleted,
    skipped: skipped,
    conflicts: conflicts,
    migrated: migrated,
    actions: actions,
    attempts: attempts,
    passwordEpochMismatch: passwordEpochMismatch,
    failedNoteUuids: failedNoteUuids,
  );

  /// 同步失败
  factory SyncResult.failure(
    String message, {
    int attempts = 1,
    bool requiresRelogin = false,
  }) => SyncResult(
    success: false,
    errorMessage: message,
    attempts: attempts,
    requiresRelogin: requiresRelogin,
  );

  /// 是否有实际数据变更（用于判断是否需要触发 UI 刷新）
  bool get hasChanges => uploaded + downloaded + deleted + migrated > 0;

  /// 未能同步（且无本地明文可自愈）的笔记数量
  int get failed => failedNoteUuids.length;

  /// 是否存在因密钥/损坏导致未能同步的笔记
  bool get hasFailures => failedNoteUuids.isNotEmpty;

  /// H4 修复：是否有 LWW 冲突（供 UI 提示用户）
  bool get hasConflicts => conflicts > 0;

  /// H4 修复：生成冲突提示消息（供 UI 显示）
  ///
  /// 返回 null 表示无冲突。返回的消息包含冲突数量和受影响的笔记 uuid 列表。
  String? get conflictMessage {
    if (!hasConflicts) return null;
    final conflictActions = actions
        .where((a) => a.type == SyncActionType.conflict)
        .toList();
    final uuids = conflictActions.map((a) => a.uuid).take(5).join(', ');
    final more = conflictActions.length > 5
        ? ' 等 ${conflictActions.length} 条'
        : '';
    return '检测到 $conflicts 条笔记冲突（LWW 自动解决，'
        '较晚的编辑覆盖较早的）: $uuids$more';
  }

  /// 复制并更新部分字段（用于累积多次重试的统计）
  SyncResult copyWith({
    bool? success,
    int? uploaded,
    int? downloaded,
    int? deleted,
    int? skipped,
    int? conflicts,
    int? migrated,
    String? errorMessage,
    List<SyncAction>? actions,
    int? attempts,
    bool? passwordEpochMismatch,
    bool? requiresRelogin,
    List<String>? failedNoteUuids,
  }) => SyncResult(
    success: success ?? this.success,
    uploaded: uploaded ?? this.uploaded,
    downloaded: downloaded ?? this.downloaded,
    deleted: deleted ?? this.deleted,
    skipped: skipped ?? this.skipped,
    conflicts: conflicts ?? this.conflicts,
    migrated: migrated ?? this.migrated,
    errorMessage: errorMessage ?? this.errorMessage,
    actions: actions ?? this.actions,
    attempts: attempts ?? this.attempts,
    passwordEpochMismatch: passwordEpochMismatch ?? this.passwordEpochMismatch,
    requiresRelogin: requiresRelogin ?? this.requiresRelogin,
    failedNoteUuids: failedNoteUuids ?? this.failedNoteUuids,
  );

  @override
  String toString() => success
      ? 'SyncResult(success, ↑$uploaded ↓$downloaded ✗$deleted skip$skipped '
            'conflict$conflicts migrate$migrated, attempts=$attempts, '
            'epochMismatch=$passwordEpochMismatch)'
      : 'SyncResult(failed: $errorMessage, attempts=$attempts, '
            'requiresRelogin=$requiresRelogin)';
}

/// manifest 序列化/反序列化辅助方法（v5 容器格式）
///
/// v5 容器布局（manifest-reliability-design §5.1）：
/// ```
/// 0         4        6        8        12
/// ┌─────────┬────────┬────────┬────────┬──────────────┬──────────────┬──────────────┐
/// │  magic   │fileVer│schemaV │headerLen│    header    │     items    │    pubHash   │
/// │  4 字节   │ 2 字节 │ 2 字节 │ 4 字节  │   明文 JSON   │  AES-GCM 密文 │   SHA-256 32B │
/// └─────────┴────────┴────────┴────────┴──────────────┴──────────────┴──────────────┘
/// ```
///
/// - `magic`：`'SMNT'` 容器家族标识（不带版本数字）。
/// - `fileVer`：文件级容器布局版本（当前 `1`），与 schemaVersion 解耦。
/// - `schemaVersion`：协议语义版本（= `header.schemaVersion`）。
/// - `headerLen`：header 字节数。
/// - `header`：明文 JSON（新设备无 dataKey 即可解析）。
/// - `items`：`AES-256-GCM(dataKey, AAD='manifest-items', items JSON)`。
/// - `pubHash`：`SHA-256(容器 [0, pubHash 起始处) 全部字节)`，**无密钥**损坏校验。
///
/// 验证矩阵（§5.3，一次性区分损坏 / 密钥不匹配）：
///   - `magic`/`fileVer`/`headerLen` 失败 → 结构损坏
///   - `pubHash` 失败 → 数据损坏（位翻转 / 截断 / 半写）
///   - `pubHash` 通过 + GCM 失败 → 密钥不匹配
///
/// 异常分流契约（§5.5 / §11.1）：
///   - 结构 / pubHash 失败 → 抛 [ManifestAuthException] → 走 §7 统一恢复编排
///   - GCM 失败 → 抛 [ManifestKeyMismatchException] → 走 scenario-b 密钥/迁移流程
class ManifestCrypto {
  static const String _itemsAad = 'manifest-items';

  /// 容器 magic 字节：'SMNT'（SafeNotes ManifesT）
  static const List<int> _magic = [0x53, 0x4D, 0x4E, 0x54];

  /// 当前支持的容器布局版本（fileVer 字段值）
  static const int _kFileVer = 1;

  /// pubHash 字段长度（SHA-256 = 32 字节）
  static const int _kPubHashLen = 32;

  /// 固定头长度：magic(4) + fileVer(2) + schemaV(2) + headerLen(4) = 12
  static const int _kFixedHeaderLen = 12;

  /// 4 字节大端整数编码
  static Uint8List _encodeUint32(int value) {
    return Uint8List(4)
      ..[0] = (value >> 24) & 0xFF
      ..[1] = (value >> 16) & 0xFF
      ..[2] = (value >> 8) & 0xFF
      ..[3] = value & 0xFF;
  }

  /// 4 字节大端整数解码
  static int _decodeUint32(Uint8List bytes, int offset) {
    return (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
  }

  /// 2 字节大端整数编码
  static Uint8List _encodeUint16(int value) {
    return Uint8List(2)
      ..[0] = (value >> 8) & 0xFF
      ..[1] = value & 0xFF;
  }

  /// 2 字节大端整数解码
  static int _decodeUint16(Uint8List bytes, int offset) {
    return (bytes[offset] << 8) | bytes[offset + 1];
  }

  /// 计算 SHA-256（返回 32 字节原始摘要）
  static Uint8List _sha256(List<int> data) {
    return Uint8List.fromList(sha256.convert(data).bytes);
  }

  /// 常量时间字节比较（防时序侧信道；pubHash 虽无密钥，保持习惯）
  static bool _constTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  /// 序列化 manifest 为 v5 容器二进制
  ///
  /// 流程：
  ///   1. header → JSON → UTF-8 字节
  ///   2. items → JSON → UTF-8 字节 → AES-GCM(dataKey, AAD='manifest-items')
  ///   3. 拼接固定头 + header + items
  ///   4. 计算 pubHash = SHA-256(除 pubHash 外的整个容器)
  ///   5. 返回 [固定头][header][items][pubHash]
  static Future<Uint8List> serialize(
    Uint8List dataKey,
    Manifest manifest,
  ) async {
    // 1. header JSON
    final headerJson = jsonEncode(manifest.header.toJson());
    final headerBytes = Uint8List.fromList(utf8.encode(headerJson));

    // 2. items JSON + 加密
    final itemsJson = jsonEncode({
      'items': manifest.items.map((k, v) => MapEntry(k, v.toJson())),
    });
    final itemsBytes = Uint8List.fromList(utf8.encode(itemsJson));
    final encryptedItems = await SyncCrypto.seal(
      dataKey,
      _itemsAad,
      itemsBytes,
    );

    // 3. 拼接固定头 + header + items（pubHash 覆盖此前所有字节）
    final fixedHeader = Uint8List.fromList([
      ..._magic,
      ..._encodeUint16(_kFileVer),
      ..._encodeUint16(manifest.header.schemaVersion),
      ..._encodeUint32(headerBytes.length),
    ]);
    final prefix = Uint8List.fromList([
      ...fixedHeader,
      ...headerBytes,
      ...encryptedItems,
    ]);

    // 4. 计算 pubHash 并拼接
    final pubHash = _sha256(prefix);
    return Uint8List.fromList([...prefix, ...pubHash]);
  }

  /// 反序列化 v5 容器为 manifest
  ///
  /// 三阶段解析（§5.5）：
  ///   1. 结构校验：magic / fileVer / headerLen 范围
  ///   2. 损坏校验：pubHash（无密钥 SHA-256）
  ///   3. 密钥校验：GCM 解密 items
  ///
  /// 异常：
  ///   - [FormatException]：数据过短（结构性问题）
  ///   - [ManifestAuthException]：magic/fileVer/headerLen 非法 或 pubHash 失败 → 数据损坏
  ///   - [ManifestKeyMismatchException]：pubHash 通过但 GCM 失败 → 密钥不匹配
  static Future<Manifest> deserialize(
    Uint8List dataKey,
    Uint8List bytes,
  ) async {
    final info = _parseAndVerifyContainer(bytes);

    // 解密 items
    if (info.encryptedItems.isEmpty) {
      // 首次创建 keyring：items 为空
      return Manifest(header: info.header, items: {});
    }

    try {
      final itemsBytes = await SyncCrypto.open(
        dataKey,
        _itemsAad,
        info.encryptedItems,
      );
      final itemsJson =
          jsonDecode(utf8.decode(itemsBytes)) as Map<String, dynamic>;
      final itemsRaw = itemsJson['items'] as Map<String, dynamic>;
      final items = itemsRaw.map(
        (k, v) => MapEntry(k, ManifestItem.fromJson(v as Map<String, dynamic>)),
      );
      return Manifest(header: info.header, items: items);
    } on SyncDecryptionException catch (e) {
      // pubHash 已通过（数据未损坏），GCM 失败 = 密钥不匹配
      throw ManifestKeyMismatchException(
        'items GCM 解密失败（pubHash 已通过，密钥不匹配或为旧密钥数据）',
        cause: e,
      );
    }
  }

  /// 仅解析 manifest header（不解密 items，不需要 dataKey）
  ///
  /// 用于新设备加入场景：
  ///   1. GET manifest → 仅解析 header 拿到 encryptedDataKey + KDF 参数 + 密钥纪元
  ///   2. 用密码 + header.kdf.salt 派生 MK，解开 encryptedDataKey 得到 dataKey
  ///   3. 用 dataKey 调用 deserialize 解析完整 manifest
  ///
  /// v5 容器会同时验 magic/fileVer/headerLen/pubHash（§5.3 新设备 onboarding 两段式），
  /// 失败抛 [ManifestAuthException] 或 [FormatException]——上层应同时 catch 两者走 §7 恢复。
  static ManifestHeader deserializeHeaderOnly(Uint8List bytes) {
    return _parseAndVerifyContainer(bytes).header;
  }

  /// v5 容器解析 + pubHash 校验（deserialize / deserializeHeaderOnly 共用）
  ///
  /// 返回 header + encryptedItems（不解密 items）。
  /// 失败抛 [FormatException]（过短）或 [ManifestAuthException]（结构/pubHash 问题）。
  static _ContainerInfo _parseAndVerifyContainer(Uint8List bytes) {
    // 1. 长度检查：固定头(12) + pubHash(32) = 44 最小
    final minLen = _kFixedHeaderLen + _kPubHashLen;
    if (bytes.length < minLen) {
      throw FormatException('manifest 数据过短：${bytes.length} 字节（最小 $minLen）');
    }

    // 2. magic 检查
    for (var i = 0; i < 4; i++) {
      if (bytes[i] != _magic[i]) {
        final actual = bytes
            .sublist(0, 4)
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
        throw ManifestAuthException('magic 不匹配：期望 SMNT(534d4e54)，实际 0x$actual');
      }
    }

    // 3. fileVer 检查
    final fileVer = _decodeUint16(bytes, 4);
    if (fileVer != _kFileVer) {
      throw ManifestAuthException(
        '不支持的容器布局版本：fileVer=$fileVer（当前支持 $_kFileVer）',
      );
    }

    // 4. schemaVersion 读取（不从固定头判定降级，header.schemaVersion 才是协议判定依据）
    final schemaV = _decodeUint16(bytes, 6);

    // 5. headerLen 范围检查（headerLen 不能让 items 起始超过 pubHash 起始）
    final headerLen = _decodeUint32(bytes, 8);
    final itemsStart = _kFixedHeaderLen + headerLen;
    final pubHashStart = bytes.length - _kPubHashLen;
    if (headerLen < 0 || itemsStart > pubHashStart) {
      throw ManifestAuthException(
        'headerLen 越界：headerLen=$headerLen，文件长度=${bytes.length}，'
        'itemsStart=$itemsStart，pubHashStart=$pubHashStart',
      );
    }

    // 6. 验 pubHash（覆盖 [0, pubHashStart) 全部字节）
    final expectedPubHash = bytes.sublist(pubHashStart);
    final actualPubHash = _sha256(bytes.sublist(0, pubHashStart));
    if (!_constTimeEquals(expectedPubHash, actualPubHash)) {
      throw ManifestAuthException('pubHash 校验失败（数据损坏：位翻转 / 截断 / 半写）');
    }

    // 7. 解析 header（明文 JSON）
    final headerBytes = bytes.sublist(_kFixedHeaderLen, itemsStart);
    final headerJson =
        jsonDecode(utf8.decode(headerBytes)) as Map<String, dynamic>;
    final header = ManifestHeader.fromJson(headerJson);

    // 8. 一致性检查：固定头 schemaV 与 header.schemaVersion 应一致
    if (schemaV != header.schemaVersion) {
      throw ManifestAuthException(
        'schemaVersion 不一致：固定头=$schemaV，header=${header.schemaVersion}',
      );
    }

    // 9. 提取 encryptedItems
    final encryptedItems = Uint8List.fromList(
      bytes.sublist(itemsStart, pubHashStart),
    );

    return _ContainerInfo(header: header, encryptedItems: encryptedItems);
  }
}

/// v5 容器解析中间结果（ManifestCrypto._parseAndVerifyContainer 返回值）
class _ContainerInfo {
  final ManifestHeader header;
  final Uint8List encryptedItems;
  const _ContainerInfo({required this.header, required this.encryptedItems});
}

// ──────────────────────────────────────────────
// 调试面板数据模型（E1）
// ──────────────────────────────────────────────

/// 同步诊断快照（调试面板"状态"页展示用）
///
/// 由 [SyncService.getDiagnosticsSnapshot] 生成，包含同步子系统当前状态的
/// 完整信息（不含敏感凭据如密码/Token）。调试面板可直接渲染此对象。
class SyncDiagnosticsSnapshot {
  /// 快照捕获时间
  final DateTime captureTime;

  // 同步状态
  final String status;
  final DateTime? lastSyncTime;
  final String? errorMessage;
  final bool isSyncing;
  final bool backendReady;

  // 后端配置（不含密码/Token）
  final String backendType;
  final String backendDisplayName;
  final String? backendRuntimeType;
  final String? providerKey;
  final String localFsPath;
  final String webdavUrl;
  final String webdavUsername;
  final String safeServerUrl;

  /// 同步总开关（用户可独立于后端配置关闭同步）
  final bool syncEnabled;
  final bool autoSyncEnabled;

  // Keyring 元数据
  final String? vaultId;
  final int? keyVersion;
  final int? dataKeyEpoch;
  final String? keyFingerprint;
  final String? kdfAlgorithm;
  final int? kdfIterations;

  // 设备
  final String? deviceId;

  // 最近同步结果
  final bool? lastResultSuccess;
  final int? lastResultAttempts;
  final int? lastResultUploaded;
  final int? lastResultDownloaded;
  final int? lastResultDeleted;
  final int? lastResultConflicts;
  final int? lastResultMigrated;
  final int? lastResultSkipped;
  final bool? lastResultPasswordEpochMismatch;
  final bool? lastResultRequiresRelogin;
  final String? lastResultErrorMessage;
  final List<String>? lastResultFailedNoteUuids;
  final List<SyncActionInfo>? lastResultActions;

  // 日志
  final String? logDirPath;
  final int logBufferCount;

  const SyncDiagnosticsSnapshot({
    required this.captureTime,
    required this.status,
    this.lastSyncTime,
    this.errorMessage,
    required this.isSyncing,
    required this.backendReady,
    required this.backendType,
    required this.backendDisplayName,
    this.backendRuntimeType,
    this.providerKey,
    required this.localFsPath,
    required this.webdavUrl,
    required this.webdavUsername,
    required this.safeServerUrl,
    required this.syncEnabled,
    required this.autoSyncEnabled,
    this.vaultId,
    this.keyVersion,
    this.dataKeyEpoch,
    this.keyFingerprint,
    this.kdfAlgorithm,
    this.kdfIterations,
    this.deviceId,
    this.lastResultSuccess,
    this.lastResultAttempts,
    this.lastResultUploaded,
    this.lastResultDownloaded,
    this.lastResultDeleted,
    this.lastResultConflicts,
    this.lastResultMigrated,
    this.lastResultSkipped,
    this.lastResultPasswordEpochMismatch,
    this.lastResultRequiresRelogin,
    this.lastResultErrorMessage,
    this.lastResultFailedNoteUuids,
    this.lastResultActions,
    this.logDirPath,
    required this.logBufferCount,
  });

  /// 转为可读文本（调试面板"复制状态"按钮用）
  String toReadableText() {
    final b = StringBuffer();
    b.writeln('=== SafeNotes 同步诊断快照 ===');
    b.writeln('捕获时间: $captureTime');
    b.writeln('');
    b.writeln('-- 同步状态 --');
    b.writeln('状态: $status');
    b.writeln('正在同步: $isSyncing');
    b.writeln('后端就绪: $backendReady');
    b.writeln('上次同步: $lastSyncTime');
    if (errorMessage != null) b.writeln('错误信息: $errorMessage');
    b.writeln('');
    b.writeln('-- 后端配置 --');
    b.writeln('同步总开关: $syncEnabled');
    b.writeln('类型: $backendDisplayName ($backendType)');
    b.writeln('运行时类型: $backendRuntimeType');
    b.writeln('providerKey: $providerKey');
    if (localFsPath.isNotEmpty) b.writeln('LocalFs 路径: $localFsPath');
    if (webdavUrl.isNotEmpty) {
      b.writeln('WebDAV URL: $webdavUrl');
      b.writeln('WebDAV 用户: $webdavUsername');
    }
    if (safeServerUrl.isNotEmpty) b.writeln('SafeServer URL: $safeServerUrl');
    b.writeln('自动同步: $autoSyncEnabled');
    b.writeln('');
    b.writeln('-- Keyring 元数据 --');
    b.writeln('Keyring ID: $vaultId');
    b.writeln('keyVersion: $keyVersion');
    b.writeln('dataKeyEpoch: $dataKeyEpoch');
    b.writeln('keyFingerprint: $keyFingerprint');
    b.writeln('KDF: $kdfAlgorithm (iterations=$kdfIterations)');
    b.writeln('');
    b.writeln('-- 设备 --');
    b.writeln('设备 ID: $deviceId');
    b.writeln('');
    b.writeln('-- 最近同步结果 --');
    b.writeln('成功: $lastResultSuccess');
    b.writeln('重试次数: $lastResultAttempts');
    b.writeln(
      '上传: $lastResultUploaded, 下载: $lastResultDownloaded, '
      '删除: $lastResultDeleted, 冲突: $lastResultConflicts, '
      '迁移: $lastResultMigrated, 跳过: $lastResultSkipped',
    );
    b.writeln('密钥纪元不匹配: $lastResultPasswordEpochMismatch');
    b.writeln('需要重新登录: $lastResultRequiresRelogin');
    if (lastResultErrorMessage != null) {
      b.writeln('错误: $lastResultErrorMessage');
    }
    if (lastResultFailedNoteUuids != null &&
        lastResultFailedNoteUuids!.isNotEmpty) {
      b.writeln(
        '失败笔记 (${lastResultFailedNoteUuids!.length}): '
        '${lastResultFailedNoteUuids!.join(", ")}',
      );
    }
    b.writeln('');
    b.writeln('-- 日志 --');
    b.writeln('日志目录: $logDirPath');
    b.writeln('内存缓冲条目数: $logBufferCount');
    return b.toString();
  }
}

/// SyncAction 的可展示信息（调试面板用）
///
/// 从 [SyncAction] 转换而来，只保留调试面板需要展示的字段，
/// 避免 UI 层直接依赖 [SyncError] 体系。
class SyncActionInfo {
  final String type;
  final String uuid;
  final String? hash;
  final String? message;
  final String? errorLabel;
  final String? errorDisplay;

  const SyncActionInfo({
    required this.type,
    required this.uuid,
    this.hash,
    this.message,
    this.errorLabel,
    this.errorDisplay,
  });

  /// 从 [SyncAction] 转换
  factory SyncActionInfo.fromAction(SyncAction action) => SyncActionInfo(
    type: action.type.name,
    uuid: action.uuid,
    hash: action.hash,
    message: action.message,
    errorLabel: action.error?.label,
    errorDisplay: action.error?.toDisplayString(),
  );

  @override
  String toString() =>
      'SyncActionInfo($type, uuid=$uuid${errorLabel != null ? ', err=$errorLabel' : ''})';

  /// 序列化为 JSON（供 LogWebServer /api/actions 端点使用）
  Map<String, dynamic> toJson() => {
    'type': type,
    'uuid': uuid,
    'hash': hash,
    'message': message,
    'errorLabel': errorLabel,
    'errorDisplay': errorDisplay,
  };
}
