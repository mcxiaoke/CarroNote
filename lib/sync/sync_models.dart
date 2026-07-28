/*
 * 同步数据模型
 *
 * 包含：
 *   - ManifestHeader：远端 manifest 明文头部（version + vaultId + encryptedDataKey + KDF 参数）
 *   - ManifestItem：manifest 加密体中单条笔记的元数据（hash + deleted + updatedAt）
 *   - Manifest：完整 manifest（header + items），便于内存操作
 *   - SyncState：本地同步状态（version + etag + 最后同步时间）
 *   - SyncResult：单次同步的结果统计
 *   - SyncActionType / SyncAction：单条同步操作（用于 UI 进度反馈）
 *
 * Manifest 文件格式（上传到后端的密文）：
 *   ┌─────────────────────────────────────────────┐
 *   │ 明文 JSON header（UTF-8 字节）              │
 *   │ {                                           │
 *   │   "version": 42,                            │
 *   │   "vaultId": "uuid-xxx",                    │
 *   │   "updatedAt": 1719470000000,               │
 *   │   "encryptedDataKey": "base64...",          │
 *   │   "kdf": {                                  │
 *   │     "algorithm": "PBKDF2-HMAC-SHA256",      │
 *   │     "salt": "base64(safenotes-v1)",         │
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
 *   - header 明文：新设备加入时无需 dataKey 即可拿到 encryptedDataKey，
 *     用密码派生 MK 解开它得到 dataKey，再解密 items。这是多端 join 的关键。
 *   - items 加密：笔记元数据（hash/deleted/updatedAt）虽然不包含内容，
 *     但仍加密以防泄露笔记数量和更新模式。
 *   - KDF 参数写入 header：算法透明，未来升级迭代次数或算法时老 vault 仍可解析。
 */

// Dart 原生导入
import 'dart:convert';
import 'dart:typed_data';

// Package 导入
import 'package:safenotes/sync/crypto.dart';

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
  /// 墓碑永久保留（或客户端主动清理），确保所有设备都能看到删除事件。
  final bool deleted;

  /// 最后更新时间（Unix 毫秒）
  ///
  /// 用于 LWW（Last-Write-Wins）冲突解决：
  ///   远端 updatedAt > 本地 updatedAt → 远端胜
  ///   远端 updatedAt < 本地 updatedAt → 本地胜
  ///   相等但 hash 不同 → 保留 hash 字典序小的（兜底，极少触发）
  final int updatedAt;

  const ManifestItem({
    required this.hash,
    required this.deleted,
    required this.updatedAt,
  });

  ManifestItem copyWith({
    String? hash,
    bool? deleted,
    int? updatedAt,
  }) =>
      ManifestItem(
        hash: hash ?? this.hash,
        deleted: deleted ?? this.deleted,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  /// 序列化为 JSON（用于 manifest 加密体存储）
  Map<String, dynamic> toJson() => {
        'hash': hash,
        'deleted': deleted,
        'updatedAt': updatedAt,
      };

  /// 从 JSON 反序列化
  factory ManifestItem.fromJson(Map<String, dynamic> json) {
    return ManifestItem(
      hash: json['hash'] as String,
      deleted: json['deleted'] as bool,
      updatedAt: json['updatedAt'] as int,
    );
  }

  @override
  String toString() =>
      'ManifestItem(hash=$hash, deleted=$deleted, updatedAt=$updatedAt)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ManifestItem &&
          hash == other.hash &&
          deleted == other.deleted &&
          updatedAt == other.updatedAt;

  @override
  int get hashCode => Object.hash(hash, deleted, updatedAt);
}

/// MK 派生参数（KDF parameters）
///
/// 写入 manifest header 明文部分，供新设备加入时按相同参数派生 MK。
/// 未来升级算法或迭代次数时，老 vault 仍能用此参数解析。
class KdfParams {
  /// KDF 算法名称（如 'PBKDF2-HMAC-SHA256'）
  final String algorithm;

  /// PBKDF2 salt（base64 编码）
  final String salt;

  /// PBKDF2 迭代次数
  final int iterations;

  const KdfParams({
    required this.algorithm,
    required this.salt,
    required this.iterations,
  });

  /// 默认 KDF 参数（使用固定 salt 'safenotes-v1'）
  factory KdfParams.defaultParams() => KdfParams(
        algorithm: kMkKdfAlgorithm,
        salt: base64.encode(kFixedSalt),
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
/// 新设备加入时，先读取此头部拿到 encryptedDataKey 和 KDF 参数，
/// 用密码按 KDF 参数派生 MK，解开 encryptedDataKey 得到 dataKey，
/// 然后才能解密 items 部分。
class ManifestHeader {
  /// manifest 版本号（每次成功 PUT 后 +1）
  ///
  /// 用于检测冲突和调试。不是乐观锁的依据（ETag 才是）。
  final int version;

  /// vault 唯一标识（UUIDv4）
  ///
  /// 首次启用同步时生成，所有设备共享同一个 vaultId。
  /// 仅作同步组标识，不再作为 PBKDF2 salt。
  final String vaultId;

  /// manifest 自身的更新时间（Unix 毫秒）
  final int updatedAt;

  /// 用 MK 加密后的 dataKey（base64 字符串）
  ///
  /// 改密码时只更新这一个字段，blob 零传输。
  /// 多设备重新认证时，用本地密码派生 MK 解开此字段得到 dataKey。
  final String encryptedDataKey;

  /// MK 派生参数（算法/salt/iterations）
  ///
  /// 写入 header 供未来算法迁移使用。
  final KdfParams kdf;

  /// dataKey 包装算法（如 'AES-256-GCM'）
  final String dataKeyWrap;

  /// 最后修改此 manifest 的设备 ID（如 'android-xxx'）
  ///
  /// 用于调试和并发冲突诊断。
  final String lastModifiedBy;

  const ManifestHeader({
    required this.version,
    required this.vaultId,
    required this.updatedAt,
    required this.encryptedDataKey,
    required this.kdf,
    required this.dataKeyWrap,
    required this.lastModifiedBy,
  });

  ManifestHeader copyWith({
    int? version,
    String? vaultId,
    int? updatedAt,
    String? encryptedDataKey,
    KdfParams? kdf,
    String? dataKeyWrap,
    String? lastModifiedBy,
  }) =>
      ManifestHeader(
        version: version ?? this.version,
        vaultId: vaultId ?? this.vaultId,
        updatedAt: updatedAt ?? this.updatedAt,
        encryptedDataKey: encryptedDataKey ?? this.encryptedDataKey,
        kdf: kdf ?? this.kdf,
        dataKeyWrap: dataKeyWrap ?? this.dataKeyWrap,
        lastModifiedBy: lastModifiedBy ?? this.lastModifiedBy,
      );

  Map<String, dynamic> toJson() => {
        'version': version,
        'vaultId': vaultId,
        'updatedAt': updatedAt,
        'encryptedDataKey': encryptedDataKey,
        'kdf': kdf.toJson(),
        'dataKeyWrap': dataKeyWrap,
        'lastModifiedBy': lastModifiedBy,
      };

  factory ManifestHeader.fromJson(Map<String, dynamic> json) {
    return ManifestHeader(
      version: json['version'] as int,
      vaultId: json['vaultId'] as String,
      updatedAt: json['updatedAt'] as int,
      encryptedDataKey: json['encryptedDataKey'] as String,
      kdf: KdfParams.fromJson(json['kdf'] as Map<String, dynamic>),
      dataKeyWrap: json['dataKeyWrap'] as String,
      lastModifiedBy: json['lastModifiedBy'] as String,
    );
  }

  @override
  String toString() =>
      'ManifestHeader(version=$version, vaultId=$vaultId, updatedAt=$updatedAt, '
      'lastModifiedBy=$lastModifiedBy)';
}

/// 远端 manifest 完整结构（header + items）
///
/// 内存中操作时使用完整 Manifest 对象；
/// 序列化到后端时拆分为 header（明文）+ items（加密）两部分。
class Manifest {
  /// 明文头部（含 vaultId / encryptedDataKey / KDF 参数等）
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
    String? lastModifiedBy,
    Map<String, ManifestItem>? items,
  }) =>
      Manifest(
        header: header.copyWith(
          version: version,
          updatedAt: updatedAt,
          encryptedDataKey: encryptedDataKey,
          lastModifiedBy: lastModifiedBy,
        ),
        items: items ?? this.items,
      );

  /// 创建空 manifest（首次启用同步时用）
  factory Manifest.empty({
    required String vaultId,
    required String encryptedDataKey,
    required String lastModifiedBy,
  }) {
    return Manifest(
      header: ManifestHeader(
        version: 0,
        vaultId: vaultId,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        encryptedDataKey: encryptedDataKey,
        kdf: KdfParams.defaultParams(),
        dataKeyWrap: kDataKeyWrapAlgorithm,
        lastModifiedBy: lastModifiedBy,
      ),
      items: {},
    );
  }

  @override
  String toString() =>
      'Manifest(version=$version, vaultId=$vaultId, items=${items.length})';
}

/// 同步操作类型（用于 UI 进度反馈和日志）
enum SyncActionType {
  upload,    // 上传笔记到远端
  download,  // 从远端下载笔记
  delete,    // 标记为删除（墓碑同步）
  skip,      // 跳过（已同步）
  conflict,  // 冲突（LWW 落败）
  migrate,   // dataKey 迁移（本地数据重新加密）
}

/// 单条同步操作记录
class SyncAction {
  final SyncActionType type;
  final String uuid;      // 笔记 UUID
  final String? hash;     // 涉及的 blob hash（可能为空）
  final String? message;  // 附加信息（如冲突原因）

  const SyncAction({
    required this.type,
    required this.uuid,
    this.hash,
    this.message,
  });

  @override
  String toString() =>
      'SyncAction($type, uuid=$uuid, hash=$hash${message != null ? ', msg=$message' : ''})';
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
      );

  /// 同步失败
  factory SyncResult.failure(String message, {int attempts = 1}) => SyncResult(
        success: false,
        errorMessage: message,
        attempts: attempts,
      );

  /// 是否有实际数据变更（用于判断是否需要触发 UI 刷新）
  bool get hasChanges => uploaded + downloaded + deleted + migrated > 0;

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
      );

  @override
  String toString() => success
      ? 'SyncResult(success, ↑$uploaded ↓$downloaded ✗$deleted skip$skipped '
          'conflict$conflicts migrate$migrated, attempts=$attempts)'
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
  ///   1. 先解析 header（明文），拿到 encryptedDataKey / KDF 参数
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
      // 首次创建 vault：items 为空
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
  ///   1. GET manifest → 仅解析 header 拿到 encryptedDataKey
  ///   2. 用密码派生 MK，解开 encryptedDataKey 得到 dataKey
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
