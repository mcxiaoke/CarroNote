/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

/*
 * 笔记历史版本模型（note_versions 表）
 *
 * 设计文档：docs/feature-note-version-history-design.md
 *
 * 定位：笔记编辑历史的本地快照，与 notes 表**完全解耦**——
 *       不参与同步、不参与 blob 寻址、不参与 manifest 比对。
 *
 * 存储划分：
 *   - title / description：AES-256-GCM 密文（复用 _encryptField/_decryptField，
 *     AAD = note_uuid，与 notes 表加密策略一致）
 *   - content_hash：明文 SHA-256（用于去重比对，不含敏感信息）
 *   - note_uuid / saved_at：明文（逻辑关联 + 排序）
 *
 * 红线：
 *   - 本模型**绝不参与** blob 内容寻址。SafeNote.computeHash /
 *     toContentBytes / fromContentBytes / blob AAD 一概不碰。
 *   - 版本表**不同步**——不进入 sync manifest，不上传 blob。
 *   - 密钥迁移时清空版本表（首期待定项，见设计文档 §8.4）。
 */

/// note_versions 表名
const String tableNoteVersions = 'note_versions';

/// note_versions 表的列名常量
class NoteVersionFields {
  static final List<String> values = [
    id,
    noteUuid,
    title,
    description,
    contentHash,
    savedAt,
  ];

  static const String id = '_id';

  /// 所属笔记的 uuid（逻辑外键，无 SQL 外键约束）
  static const String noteUuid = 'note_uuid';

  /// 笔记标题快照（AES-256-GCM 密文，AAD = note_uuid）
  static const String title = 'title';

  /// 笔记正文快照（AES-256-GCM 密文，AAD = note_uuid）
  static const String description = 'description';

  /// 内容哈希（明文 SHA-256，用于去重比对）
  static const String contentHash = 'content_hash';

  /// 保存时间（Unix 毫秒，用于排序与 FIFO 清理）
  static const String savedAt = 'saved_at';
}

/// 笔记历史版本
///
/// 内存中 title/description 为明文；数据库中为 AES-256-GCM 密文。
/// 加解密由 [NotesDatabase] 的 `_encryptField` / `_decryptField` 完成，
/// 与 notes 表的 title/description 加密完全一致。
class NoteVersion {
  final int? id;
  final String noteUuid;

  /// 标题明文（内存态）
  final String title;

  /// 正文明文（内存态）
  final String description;

  /// 内容哈希（与 SafeNote.computeHash 口径一致）
  final String contentHash;

  /// 保存时间（Unix 毫秒）
  final int savedAt;

  const NoteVersion({
    this.id,
    required this.noteUuid,
    required this.title,
    required this.description,
    required this.contentHash,
    required this.savedAt,
  });

  /// 保存时间（DateTime）
  DateTime get savedTime => DateTime.fromMillisecondsSinceEpoch(savedAt);

  NoteVersion copyWith({
    int? id,
    String? noteUuid,
    String? title,
    String? description,
    String? contentHash,
    int? savedAt,
  }) => NoteVersion(
    id: id ?? this.id,
    noteUuid: noteUuid ?? this.noteUuid,
    title: title ?? this.title,
    description: description ?? this.description,
    contentHash: contentHash ?? this.contentHash,
    savedAt: savedAt ?? this.savedAt,
  );

  /// 从数据库行构造（密文已由 _decryptField 解密为明文）
  factory NoteVersion.fromJson(Map<String, dynamic> json) {
    return NoteVersion(
      id: json[NoteVersionFields.id] as int?,
      noteUuid: json[NoteVersionFields.noteUuid] as String? ?? '',
      title: json[NoteVersionFields.title] as String? ?? '',
      description: json[NoteVersionFields.description] as String? ?? '',
      contentHash: json[NoteVersionFields.contentHash] as String? ?? '',
      savedAt: (json[NoteVersionFields.savedAt] as num?)?.toInt() ?? 0,
    );
  }

  /// 转为数据库行（title/description 此时已是密文，由调用方加密）
  Map<String, dynamic> toJson() {
    return {
      NoteVersionFields.noteUuid: noteUuid,
      NoteVersionFields.title: title,
      NoteVersionFields.description: description,
      NoteVersionFields.contentHash: contentHash,
      NoteVersionFields.savedAt: savedAt,
    };
  }

  @override
  String toString() =>
      'NoteVersion(id=$id, noteUuid=$noteUuid, '
      'title=<redacted>, hash=$contentHash, savedAt=$savedAt)';
}
