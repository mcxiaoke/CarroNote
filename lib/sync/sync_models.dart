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
import 'package:safenotes/sync/crypto.dart';
import 'package:safenotes/sync/sync_error.dart';

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
  /// 用于 GC 优先级和统计。hash 已是更强的内容侧信道，不增加安全风险。
  final int contentSize;

  /// blob 密钥纪元（Layer 3 显式标记）
  ///
  /// 记录加密该笔记 blob 时使用的 dataKey 纪元。
  /// 与 [ManifestHeader] 中的当前 [Keyring.dataKeyEpoch] 比较：
  ///   - 相等 → blob 用当前 dataKey 加密，正常解密；
  ///   - 不等且本机持有匹配的历史 dataKey → 旧密钥 blob，走显式修复路径（重传）；
  ///   - 不等且本机无匹配密钥 → 内容已损坏/不可达，跳过并标记。
  ///
  /// 默认 0 表示「遗留 blob（Layer 3 之前的客户端上传）」，向后兼容：
  /// 下载时按旧格式 AAD（contentHash / uuid）尝试解密，能解开即接受；
  /// 仅当纪元确实不匹配时才触发修复（一次性重传代价，可接受）。
  final int blobKeyEpoch;

  const ManifestItem({
    required this.hash,
    required this.deleted,
    required this.updatedAt,
    required this.updatedBy,
    required this.createdAt,
    this.deletedAt,
    this.contentSize = 0,
    this.blobKeyEpoch = 0,
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
  }) =>
      ManifestItem(
        hash: hash ?? this.hash,
        deleted: deleted ?? this.deleted,
        updatedAt: updatedAt ?? this.updatedAt,
        updatedBy: updatedBy ?? this.updatedBy,
        createdAt: createdAt ?? this.createdAt,
        deletedAt: deletedAt ?? this.deletedAt,
        contentSize: contentSize ?? this.contentSize,
        blobKeyEpoch: blobKeyEpoch ?? this.blobKeyEpoch,
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
    );
  }

  @override
  String toString() =>
      'ManifestItem(hash=$hash, deleted=$deleted, updatedAt=$updatedAt, '
      'updatedBy=$updatedBy, contentSize=$contentSize, blobKeyEpoch=$blobKeyEpoch)';

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
          blobKeyEpoch == other.blobKeyEpoch;

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
      );
}

/// MK 派生参数（KDF parameters）
///
/// 写入 manifest header 明文部分，供新设备加入时按相同参数派生 MK。
/// per-vault 随机 salt 随 header 传播，确保跨用户预计算失效。
class KdfParams {
  /// KDF 算法名称（如 'PBKDF2-HMAC-SHA256'）
  final String algorithm;

  /// PBKDF2 salt（base64 编码，per-vault 随机生成）
  final String salt;

  /// PBKDF2 迭代次数
  final int iterations;

  const KdfParams({
    required this.algorithm,
    required this.salt,
    required this.iterations,
  });

  /// 创建 KDF 参数（使用传入的 per-vault salt）
  ///
  /// [salt] 随机生成的 16 字节 salt
  factory KdfParams.create({required Uint8List salt}) => KdfParams(
        algorithm: kMkKdfAlgorithm,
        salt: base64.encode(salt),
        iterations: kPbkdf2Iterations,
      );

  Map<String, dynamic> toJson() => {
        'algorithm': algorithm,
        'salt': salt,
        'iterations': iterations,
      };

  factory KdfParams.fromJson(Map<String, dynamic> json) {
    return KdfParams(
      algorithm: json['algorithm'] as String,
      salt: json['salt'] as String,
      iterations: json['iterations'] as int,
    );
  }

  /// 获取 salt 的原始字节（解码 base64）
  Uint8List get saltBytes => base64.decode(salt);

  @override
  String toString() =>
      'KdfParams(algorithm=$algorithm, iterations=$iterations, salt=$salt)';
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
  /// 默认 1（遗留服务器不发送此字段时按 1 处理）。
  final int dataKeyEpoch;

  /// 最后修改此 manifest 的设备 ID（如 'android-xxx'）
  ///
  /// 用于调试和并发冲突诊断。
  final String lastModifiedBy;

  const ManifestHeader({
    this.schemaVersion = 1,
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
    String? lastModifiedBy,
  }) =>
      ManifestHeader(
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

  const Manifest({
    required this.header,
    required this.items,
  });

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
  }) =>
      Manifest(
        header: header ?? this.header,
        items: items ?? this.items,
      );

  /// 仅更新 header 的部分字段（便捷方法）
  Manifest copyWithHeader({
    int? version,
    int? updatedAt,
    String? encryptedDataKey,
    String? keyFingerprint,
    int? keyVersion,
    String? lastModifiedBy,
    Map<String, ManifestItem>? items,
  }) =>
      Manifest(
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
        schemaVersion: 1,
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
  upload,    // 上传笔记到远端
  download,  // 从远端下载笔记
  delete,    // 标记为删除（墓碑同步）
  skip,      // 跳过（已同步）
  conflict,  // 冲突（LWW 落败）
  migrate,   // dataKey 迁移（本地数据重新加密）
  uploadFailed, // 单个 blob 上传失败（容错，不中断同步）
  corrupt,   // blob 下载解密失败且无本地明文可自愈（记录为失败，重试）
  heal,      // blob 下载失败时用本地明文自愈重传（覆盖服务器坏 blob）
}

/// 单条同步操作记录
class SyncAction {
  final SyncActionType type;
  final String uuid;      // 笔记 UUID
  final String? hash;     // 涉及的 blob hash（可能为空）

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
  String get displayMessage =>
      error?.toDisplayString() ?? message ?? type.name;

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
  final int migrated;      // 迁移的笔记数（dataKey 变更时）
  final String? errorMessage;
  final List<SyncAction> actions; // 详细操作记录（用于 UI 和日志）
  final int attempts; // 实际重试次数（用于诊断乐观锁冲突频率）
  /// 密钥纪元不匹配标志（远端 keyVersion > 本地）
  ///
  /// true 表示他端改了密码，UI 应提示用户输入新密码。
  final bool passwordEpochMismatch;

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
  }) =>
      SyncResult(
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
  factory SyncResult.failure(String message, {int attempts = 1}) => SyncResult(
        success: false,
        errorMessage: message,
        attempts: attempts,
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
    List<String>? failedNoteUuids,
  }) =>
      SyncResult(
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
        failedNoteUuids: failedNoteUuids ?? this.failedNoteUuids,
      );

  @override
  String toString() => success
      ? 'SyncResult(success, ↑$uploaded ↓$downloaded ✗$deleted skip$skipped '
          'conflict$conflicts migrate$migrated, attempts=$attempts, '
          'epochMismatch=$passwordEpochMismatch)'
      : 'SyncResult(failed: $errorMessage, attempts=$attempts)';
}

/// manifest 序列化/反序列化辅助方法
///
/// manifest 文件格式：
///   [4 字节大端 header 长度] [header JSON 字节] [加密的 items 字节]
///
/// header 明文：新设备加入时无需 dataKey 即可解析。
/// items 加密：用 dataKey 加密，AAD 固定为 'manifest-items'。
class ManifestCrypto {
  static const String _itemsAad = 'manifest-items';

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

  /// 序列化 manifest 为密文二进制
  ///
  /// 流程：
  ///   1. header → JSON → UTF-8 字节
  ///   2. items → JSON → UTF-8 字节 → AES-GCM(dataKey, AAD='manifest-items')
  ///   3. 拼接：[4字节 header 长度][header 字节][加密 items 字节]
  static Uint8List serialize(Uint8List dataKey, Manifest manifest) {
    // 1. header JSON
    final headerJson = jsonEncode(manifest.header.toJson());
    final headerBytes = Uint8List.fromList(utf8.encode(headerJson));

    // 2. items JSON + 加密
    final itemsJson = jsonEncode({
      'items': manifest.items
          .map((k, v) => MapEntry(k, v.toJson())),
    });
    final itemsBytes = Uint8List.fromList(utf8.encode(itemsJson));
    final encryptedItems = SyncCrypto.seal(dataKey, _itemsAad, itemsBytes);

    // 3. 拼接
    final headerLenBytes = _encodeUint32(headerBytes.length);
    return Uint8List.fromList(
      [...headerLenBytes, ...headerBytes, ...encryptedItems],
    );
  }

  /// 反序列化密文为 manifest
  ///
  /// 两阶段解析：
  ///   1. 先解析 header（明文），拿到 encryptedDataKey / KDF 参数 / 密钥纪元
  ///   2. 用 dataKey 解密 items
  ///
  /// 如果 dataKey 不正确，items 解密会抛 GCM tag 验证异常。
  static Manifest deserialize(Uint8List dataKey, Uint8List bytes) {
    if (bytes.length < 4) {
      throw FormatException('manifest 数据过短：${bytes.length} 字节');
    }

    // 1. 读取 header 长度
    final headerLen = _decodeUint32(bytes, 0);
    if (bytes.length < 4 + headerLen) {
      throw FormatException(
          'manifest header 不完整：期望 $headerLen 字节，实际 ${bytes.length - 4} 字节');
    }

    // 2. 解析 header（明文 JSON）
    final headerBytes = bytes.sublist(4, 4 + headerLen);
    final headerJson = jsonDecode(utf8.decode(headerBytes)) as Map<String, dynamic>;
    final header = ManifestHeader.fromJson(headerJson);

    // 3. 解密 items
    final encryptedItems = bytes.sublist(4 + headerLen);
    if (encryptedItems.isEmpty) {
      // 首次创建 keyring：items 为空
      return Manifest(header: header, items: {});
    }

    final itemsBytes = SyncCrypto.open(dataKey, _itemsAad, encryptedItems);
    final itemsJson = jsonDecode(utf8.decode(itemsBytes)) as Map<String, dynamic>;
    final itemsRaw = itemsJson['items'] as Map<String, dynamic>;
    final items = itemsRaw.map((k, v) =>
        MapEntry(k, ManifestItem.fromJson(v as Map<String, dynamic>)));

    return Manifest(header: header, items: items);
  }

  /// 仅解析 manifest header（不解密 items，不需要 dataKey）
  ///
  /// 用于新设备加入场景：
  ///   1. GET manifest → 仅解析 header 拿到 encryptedDataKey + KDF 参数 + 密钥纪元
  ///   2. 用密码 + header.kdf.salt 派生 MK，解开 encryptedDataKey 得到 dataKey
  ///   3. 用 dataKey 调用 deserialize 解析完整 manifest
  static ManifestHeader deserializeHeaderOnly(Uint8List bytes) {
    if (bytes.length < 4) {
      throw FormatException('manifest 数据过短：${bytes.length} 字节');
    }

    final headerLen = _decodeUint32(bytes, 0);
    if (bytes.length < 4 + headerLen) {
      throw FormatException(
          'manifest header 不完整：期望 $headerLen 字节，实际 ${bytes.length - 4} 字节');
    }

    final headerBytes = bytes.sublist(4, 4 + headerLen);
    final headerJson = jsonDecode(utf8.decode(headerBytes)) as Map<String, dynamic>;
    return ManifestHeader.fromJson(headerJson);
  }
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
    b.writeln('上传: $lastResultUploaded, 下载: $lastResultDownloaded, '
        '删除: $lastResultDeleted, 冲突: $lastResultConflicts, '
        '迁移: $lastResultMigrated, 跳过: $lastResultSkipped');
    b.writeln('密钥纪元不匹配: $lastResultPasswordEpochMismatch');
    if (lastResultErrorMessage != null) {
      b.writeln('错误: $lastResultErrorMessage');
    }
    if (lastResultFailedNoteUuids != null &&
        lastResultFailedNoteUuids!.isNotEmpty) {
      b.writeln('失败笔记 (${lastResultFailedNoteUuids!.length}): '
          '${lastResultFailedNoteUuids!.join(", ")}');
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
}
