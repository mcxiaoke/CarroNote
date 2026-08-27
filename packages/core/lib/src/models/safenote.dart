/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

/*
 * 笔记数据模型
 *
 * 改造说明（fork 同步版）：
 *   - 新增 uuid / contentHash / deleted / updatedAt / synced 字段
 *   - 本地存储为字段级加密（title/description 用 dataKey 加密），同步时加密为 envelope 上传到后端
 *   - 软删除（deleted=1 表示墓碑，不真正删除行）
 *   - contentHash 用于 manifest 比对和 blob 寻址
 */

// Dart 导入
import 'dart:convert';
import 'dart:math' show Random;
import 'dart:typed_data';

// 项目导入
import 'package:characters/characters.dart';
import 'package:core/src/crypto/crypto.dart';

const String tableNotes = 'safe_notes';

class NoteFields {
  static final List<String> values = [
    id,
    uuid,
    title,
    description,
    contentHash,
    deleted,
    createdAt,
    updatedAt,
    synced,
    syncedHash,
    syncedDeleted,
  ];

  static const String id = '_id';
  static const String uuid = 'uuid';
  static const String title = 'title';
  static const String description = 'description';
  static const String contentHash = 'content_hash';
  static const String deleted = 'deleted';
  static const String createdAt = 'created_at';
  static const String updatedAt = 'updated_at';
  static const String synced = 'synced';
  // 共同祖先 hash：上次同步成功收敛时的 content_hash。
  // 冲突判定用它区分「单边编辑」与「真并发冲突」（三方合并的 base）。
  // 明文存储，不加密（与 content_hash 同性质，仅用于同步比对）。
  static const String syncedHash = 'synced_hash';
  // 共同祖先 deleted：上次同步成功收敛时的 deleted 状态。
  //
  // 单独存这一列的原因：softDelete 不改 content_hash，只把 deleted 置 1。
  // 若 base 只比 hash，软删除会被判为「未偏离 base」→ fast-forward 误判
  // 为「双方都没改」，导致删除不传播。把 deleted 维度纳入 base 后，
  // 软删除时 localChanged=true、remoteChanged=false，正确走 fast-forward
  // 的「本地单边变更」分支（上传墓碑、不记 conflict）。
  static const String syncedDeleted = 'synced_deleted';
}

class SafeNote {
  final int? id;
  final String uuid;
  final String title;
  final String description;
  final String contentHash;
  final bool deleted;
  final DateTime createdTime;
  final int updatedAt; // Unix 毫秒，用于 LWW 冲突解决
  final bool synced;

  /// 共同祖先 hash：上次同步成功收敛时的 [contentHash]。
  ///
  /// 冲突判定的三方合并 base——用它区分「本地/远端只有一方改过」（单边更新，
  /// 直接采纳，不造副本）与「双方都偏离了共同祖先」（真并发冲突，保留副本）。
  /// null 表示该笔记从未成功同步过（新笔记或迁移前的未同步数据）。
  final String? syncedHash;

  /// 共同祖先 deleted：上次同步成功收敛时的 [deleted] 状态。
  ///
  /// 与 [syncedHash] 配合，让 base 完整描述「上次收敛时的 (hash, deleted) 二元组」，
  /// 解决软删除不改 hash 导致 base 比对失效的问题。详见 [NoteFields.syncedDeleted]。
  /// 默认 false（与数据库 DEFAULT 0 一致），未同步过的笔记视为「未删除」。
  final bool syncedDeleted;

  const SafeNote({
    this.id,
    required this.uuid,
    required this.title,
    required this.description,
    required this.contentHash,
    this.deleted = false,
    required this.createdTime,
    required this.updatedAt,
    this.synced = false,
    this.syncedHash,
    this.syncedDeleted = false,
  });

  /// 卡片列表展示用的摘要文本（P0 性能优化）。
  ///
  /// 只取正文前 [abstractMaxLength] 个字符，避免把整篇大文本送入 [sanitize]、
  /// AutoSizeText 排版与 RTL 检测。点开详情时再读取完整 [description]。
  static const int abstractMaxLength = 200;

  String get abstractText {
    if (description.characters.length <= abstractMaxLength) {
      return description;
    }
    return description.characters.take(abstractMaxLength).toString();
  }

  /// 最后修改时间（由 [updatedAt] 的 Unix 毫秒转换）。
  ///
  /// 列表默认按此字段排序，卡片也可选择展示此时间。
  DateTime get modifiedTime => DateTime.fromMillisecondsSinceEpoch(updatedAt);

  /// 创建新笔记的工厂构造函数
  ///
  /// 自动生成 UUIDv4、计算 contentHash、设置 updatedAt 为当前时间。
  /// synced=false（新建笔记需同步），deleted=false。
  factory SafeNote.create({
    required String title,
    required String description,
    DateTime? createdTime,
  }) {
    final now = DateTime.now();
    return SafeNote(
      uuid: generateUuid(),
      title: title,
      description: description,
      contentHash: computeHash(title, description),
      createdTime: createdTime ?? now,
      updatedAt: now.millisecondsSinceEpoch,
      synced: false,
    );
  }

  /// 生成 UUIDv4（RFC 4122）
  ///
  /// 使用 Random.secure() 保证密码学安全。
  /// 格式：xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx（y ∈ {8,9,a,b}）
  static String generateUuid() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    // 设置 version 和 variant 位
    bytes[6] = (bytes[6] & 0x0F) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3F) | 0x80; // variant 10
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20, 32)}';
  }

  SafeNote copyWith({
    int? id,
    String? uuid,
    String? title,
    String? description,
    String? contentHash,
    bool? deleted,
    DateTime? createdTime,
    int? updatedAt,
    bool? synced,
    String? syncedHash,
    bool? syncedDeleted,
  }) => SafeNote(
    id: id ?? this.id,
    uuid: uuid ?? this.uuid,
    title: title ?? this.title,
    description: description ?? this.description,
    contentHash: contentHash ?? this.contentHash,
    deleted: deleted ?? this.deleted,
    createdTime: createdTime ?? this.createdTime,
    updatedAt: updatedAt ?? this.updatedAt,
    synced: synced ?? this.synced,
    syncedHash: syncedHash ?? this.syncedHash,
    syncedDeleted: syncedDeleted ?? this.syncedDeleted,
  );

  /// 从数据库行构造（明文存储，无需解密）
  ///
  /// 兼容旧备份格式：如果缺少 uuid/contentHash/updatedAt/synced 等字段，
  /// 自动补全（生成 uuid、计算 hash、设为当前时间/未同步）。
  /// 这样导入旧版本导出的备份（只有 title/description/createdAt）也能正常工作。
  static SafeNote fromJson(Map<String, dynamic> json) {
    final title = json[NoteFields.title] as String? ?? '';
    final description = json[NoteFields.description] as String? ?? '';
    final createdAt = json[NoteFields.createdAt] as String?;

    // 兼容旧格式：缺少的字段自动补全
    final uuid = json[NoteFields.uuid] as String? ?? generateUuid();
    final contentHash =
        json[NoteFields.contentHash] as String? ??
        computeHash(title, description);
    final deleted = (json[NoteFields.deleted] as int?) == 1;
    final updatedAt =
        (json[NoteFields.updatedAt] as int?) ??
        DateTime.now().millisecondsSinceEpoch;
    final synced = (json[NoteFields.synced] as int?) == 1;
    // 共同祖先 hash：可空。旧备份格式无此字段 → null（视为未同步基线）。
    final syncedHash = json[NoteFields.syncedHash] as String?;
    // 共同祖先 deleted：兼容旧备份（无此字段 → false，与 DEFAULT 0 一致）
    final syncedDeleted = (json[NoteFields.syncedDeleted] as int?) == 1;

    return SafeNote(
      id: json[NoteFields.id] as int?,
      uuid: uuid,
      title: title,
      description: description,
      contentHash: contentHash,
      deleted: deleted,
      createdTime: createdAt != null
          ? DateTime.parse(createdAt)
          : DateTime.now(),
      updatedAt: updatedAt,
      synced: synced,
      syncedHash: syncedHash,
      syncedDeleted: syncedDeleted,
    );
  }

  /// 转为数据库行（明文存储）
  Map<String, dynamic> toJson() {
    return {
      NoteFields.uuid: uuid,
      NoteFields.title: title,
      NoteFields.description: description,
      NoteFields.contentHash: contentHash,
      NoteFields.deleted: deleted ? 1 : 0,
      NoteFields.createdAt: createdTime.toIso8601String(),
      NoteFields.updatedAt: updatedAt,
      NoteFields.synced: synced ? 1 : 0,
      NoteFields.syncedHash: syncedHash,
      NoteFields.syncedDeleted: syncedDeleted ? 1 : 0,
    };
  }

  /// 计算笔记内容的 SHA-256 哈希
  ///
  /// hash = SHA-256(title + "\n" + description)
  /// 用于 manifest 比对和 blob 寻址。
  ///
  /// §6.3 修订 2（语义注释）：此 hash 是**逻辑内容身份**，与 blob payload
  /// 字节哈希是两个域——payload 是 JSON（含 v 字段），此 hash 只取
  /// title/description 拼接。已知该编码非单射（`"A\nB"+"C"` 与 `"A"+"B\nC"`
  /// 哈希相同），但概率极低且改动牵连面广（computeHash / DB 列 / 孪生查询 /
  /// blob 寻址 / M7 校验共 5 处），保留现状。详见 manifest-reliability-design
  /// §0「已移除项说明」。
  static String computeHash(String title, String description) {
    final content = '$title\n$description';
    return SyncCrypto.hashString(content);
  }

  /// 将笔记内容序列化为明文字节（用于加密为 envelope）
  ///
  /// §6.3 修订 4：payload 加 `"v"` 版本字段，未来加字段时可判别新老格式。
  /// v=2（v1 为无版本字段的旧格式，开发中未发布已废弃）。
  /// 身份与 payload 解耦：加字段不影响已寻址的 blob（hash 仍由
  /// [computeHash] 决定，与 payload 字节无关）。
  ///
  /// 格式：JSON {"v":2, "title": "...", "description": "..."}
  /// 同步时：envelope = SyncCrypto.seal(dataKey, hash, toContentBytes())
  /// （v4 blob 纯化：AAD = hash，不再含 epoch）
  Uint8List toContentBytes() {
    final content = jsonEncode({
      'v': 2,
      'title': title,
      'description': description,
    });
    return Uint8List.fromList(utf8.encode(content));
  }

  /// 从加密信封的明文字节反序列化笔记内容
  ///
  /// [bytes] 是 SyncCrypto.open() 解密后的明文字节。
  /// §6.3 修订 4：payload 含 `"v"` 版本字段（v=2），反序列化只取
  /// title/description；v 字段用于格式判别，当前所有版本均取这两个字段，
  /// 故无需分支处理。
  /// 返回 (title, description)
  static ({String title, String description}) fromContentBytes(
    Uint8List bytes,
  ) {
    final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    return (
      title: json['title'] as String,
      description: json['description'] as String,
    );
  }

  @override
  String toString() =>
      'SafeNote(id=$id, uuid=$uuid, title=<redacted>, hash=$contentHash, '
      'deleted=$deleted, updatedAt=$updatedAt, synced=$synced, '
      'syncedHash=$syncedHash)';
}
