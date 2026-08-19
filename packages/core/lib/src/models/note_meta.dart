/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

/*
 * 笔记元数据模型（note_meta 表）
 *
 * 设计文档：docs/feature-note-meta-design.md
 *
 * 定位：笔记级元数据的统一载体（星标/置顶、标签、归档、颜色…），
 *       与 notes 表**完全解耦**——notes 表与 SafeNote 模型零改动。
 *
 * 存储划分（判据：是否泄露用户内容语义）：
 *   - 明文列：pinned / archived / color / deleted / updated_at / synced
 *     （布尔、枚举、时间戳，不含用户输入文本，且需要 SQL 索引或排序）
 *   - payload（dataKey 加密）：tags 及一切含用户输入文本的字段
 *     （标签名本身即隐私，如"就医记录""离职"，明文落盘是缺口）
 *
 * 前向兼容：payload 内**未知的顶层键**由 [NoteMeta.extra] 原样透传，
 *   序列化时写回顶层。因此新增 payload 字段**无需改 schema、无需 bump
 *   数据库版本**，且旧版本读到新版本写入的字段也不会丢失。
 *
 * 红线：
 *   - 本模型**绝不参与** blob 内容寻址。SafeNote.computeHash /
 *     toContentBytes / fromContentBytes / blob AAD 一概不碰。
 *   - 元数据变更**不得**改动 notes.updated_at / notes.content_hash，
 *     元数据自己的 LWW 锚点是 [NoteMeta.updatedAt]。
 */

// Dart 导入
import 'dart:convert';

/// note_meta 表名
const String tableNoteMeta = 'note_meta';

/// note_meta 表的列名常量
class NoteMetaFields {
  static final List<String> values = [
    id,
    uuid,
    pinned,
    archived,
    color,
    deleted,
    payload,
    updatedAt,
    synced,
  ];

  static const String id = '_id';
  static const String uuid = 'uuid';

  /// 星标/置顶（本项目二者合并为同一概念）
  static const String pinned = 'pinned';

  /// 归档（区别于 deleted，本期建列不接 UI）
  static const String archived = 'archived';

  /// 卡片颜色 ARGB，NULL = 跟随主题默认
  static const String color = 'color';

  /// 墓碑标记：笔记被硬删除后此行**保留**用于告知远端。
  ///
  /// 正因如此，note_meta.uuid **绝不能**加 `REFERENCES notes(uuid)
  /// ON DELETE CASCADE`——级联删除会连墓碑一起清掉，摧毁机制本身。
  static const String deleted = 'deleted';

  /// 敏感/结构化字段的加密 JSON（dataKey 加密）。
  ///
  /// 命名不加 `enc_` 前缀，与 notes 表 title/description
  /// （同为密文却直接叫 title）保持一致。
  static const String payload = 'payload';

  /// 元数据自身的 LWW 锚点（unix ms）。
  ///
  /// **与 notes.updated_at 完全独立**：改星标只动这里，
  /// 不会触发笔记正文 blob 重新加密上传。
  static const String updatedAt = 'updated_at';

  /// 同步脏标记：0 = 待上传，1 = 已同步。
  ///
  /// 墓碑语义需要它：`deleted=1 AND synced=0` 是"待上报的墓碑"，
  /// `deleted=1 AND synced=1` 才可安全物理删除该行。
  static const String synced = 'synced';
}

/// 笔记元数据
///
/// 行**按需创建**（懒创建）：只有笔记首次被设置任意元数据时才 INSERT。
/// 读取时若 note_meta 无对应 uuid，视为 [NoteMeta.defaults] 全默认值。
/// 好处：老库升级后为空表无需回填，绝大多数笔记不占行。
class NoteMeta {
  final int? id;
  final String uuid;
  final bool pinned;
  final bool archived;
  final int? color;

  /// 墓碑标记，见 [NoteMetaFields.deleted]
  final bool deleted;

  /// 元数据自身的 LWW 时间戳（unix ms），见 [NoteMetaFields.updatedAt]
  final int updatedAt;
  final bool synced;

  // ── 以下字段存于加密 payload ──

  /// 标签列表（用户输入文本，敏感 → 加密存储）
  final List<String> tags;

  /// payload 内未被本版本识别的顶层键，原样透传。
  ///
  /// 两个用途：
  ///   1. **前向兼容**：旧版本读到新版本写入的字段不会丢失；
  ///   2. **零成本扩展**：加新字段直接写这里，无需改建表语句或 bump 版本。
  ///      待该字段稳定且需要 SQL 索引时，再"提升"为真列。
  final Map<String, dynamic> extra;

  const NoteMeta({
    this.id,
    required this.uuid,
    this.pinned = false,
    this.archived = false,
    this.color,
    this.deleted = false,
    required this.updatedAt,
    this.synced = false,
    this.tags = const [],
    this.extra = const {},
  });

  /// payload 结构版本号
  static const int payloadVersion = 1;

  /// payload 中由本版本显式识别的键（其余进 [extra] 透传）
  static const Set<String> _knownPayloadKeys = {_kVersion, _kTags};
  static const String _kVersion = 'v';
  static const String _kTags = 'tags';

  /// 全默认值的元数据（读取时 note_meta 无此 uuid 的行时返回）
  ///
  /// [updatedAt] 取 0 而非当前时间：0 表示"从未设置过元数据"，
  /// 在 per-note LWW 合并中恒被任何真实远端条目覆盖，语义正确。
  factory NoteMeta.defaults(String uuid) => NoteMeta(uuid: uuid, updatedAt: 0);

  /// 是否全为默认值（无任何用户设置）
  ///
  /// 注意：**不要**据此自动删除数据库行。元数据被清空（如取消星标）
  /// 这一事实本身需要带 [updatedAt] 保留下来并同步给其他设备，
  /// 否则他端的旧值会在下次合并时把本端的"取消"覆盖回去。
  bool get isDefault =>
      !pinned &&
      !archived &&
      color == null &&
      !deleted &&
      tags.isEmpty &&
      extra.isEmpty;

  NoteMeta copyWith({
    int? id,
    String? uuid,
    bool? pinned,
    bool? archived,
    int? color,
    bool? clearColor,
    bool? deleted,
    int? updatedAt,
    bool? synced,
    List<String>? tags,
    Map<String, dynamic>? extra,
  }) => NoteMeta(
    id: id ?? this.id,
    uuid: uuid ?? this.uuid,
    pinned: pinned ?? this.pinned,
    archived: archived ?? this.archived,
    color: (clearColor ?? false) ? null : (color ?? this.color),
    deleted: deleted ?? this.deleted,
    updatedAt: updatedAt ?? this.updatedAt,
    synced: synced ?? this.synced,
    tags: tags ?? this.tags,
    extra: extra ?? this.extra,
  );

  /// 规范化标签：去首尾空白 → 丢弃空串 → 去重（保持首次出现顺序）
  ///
  /// UI 输入与远端合并都应过此函数，保证"同一标签"在各处判定一致。
  static List<String> normalizeTags(Iterable<String> input) {
    final seen = <String>{};
    final out = <String>[];
    for (final raw in input) {
      final t = raw.trim();
      if (t.isEmpty) continue;
      if (seen.add(t)) out.add(t);
    }
    return out;
  }

  // ──────────────────────────────────────────────
  // payload 序列化（明文 JSON ⇄ 字段）
  // ──────────────────────────────────────────────

  /// 序列化 payload 为**明文** JSON 字符串；无内容时返回 null。
  ///
  /// 加密由 DB 层负责（写入前 seal，读取后 open），本模型只产出明文，
  /// 保证模型可被纯 Dart 测试而无需 dataKey。
  ///
  /// 只写非默认值以减小体积；[extra] 展开为顶层键（前向兼容，见其文档）。
  String? encodePayload() {
    final map = <String, dynamic>{};
    if (tags.isNotEmpty) map[_kTags] = tags;
    map.addAll(extra); // 未知键透传回顶层
    if (map.isEmpty) return null; // 无内容不写，payload 列留 NULL
    return jsonEncode({_kVersion: payloadVersion, ...map});
  }

  /// 解析**明文** payload JSON，返回 (tags, extra)。
  ///
  /// 容错：payload 损坏/非法时返回空值而**不抛异常**——元数据永远是次要
  /// 数据，单行损坏不应阻断笔记列表加载（对比 purgedUuids 整个 JSON 损坏
  /// 会中止整条同步链路的旧缺陷，见设计文档 §4.1）。
  static ({List<String> tags, Map<String, dynamic> extra}) decodePayload(
    String? plaintext,
  ) {
    const empty = (tags: <String>[], extra: <String, dynamic>{});
    if (plaintext == null || plaintext.isEmpty) return empty;
    try {
      final decoded = jsonDecode(plaintext);
      if (decoded is! Map<String, dynamic>) return empty;

      final rawTags = decoded[_kTags];
      final tags = rawTags is List
          ? normalizeTags(rawTags.whereType<String>())
          : const <String>[];

      final extra = <String, dynamic>{};
      for (final e in decoded.entries) {
        if (!_knownPayloadKeys.contains(e.key)) extra[e.key] = e.value;
      }
      return (tags: tags, extra: extra);
    } on Object {
      return empty;
    }
  }

  // ──────────────────────────────────────────────
  // 数据库行映射
  // ──────────────────────────────────────────────

  /// 转为数据库行。
  ///
  /// [encryptedPayload] 由 DB 层用 dataKey 加密 [encodePayload] 的结果后传入；
  /// 为 null 表示 payload 列写 NULL。
  Map<String, dynamic> toRow({String? encryptedPayload}) => {
    if (id != null) NoteMetaFields.id: id,
    NoteMetaFields.uuid: uuid,
    NoteMetaFields.pinned: pinned ? 1 : 0,
    NoteMetaFields.archived: archived ? 1 : 0,
    NoteMetaFields.color: color,
    NoteMetaFields.deleted: deleted ? 1 : 0,
    NoteMetaFields.payload: encryptedPayload,
    NoteMetaFields.updatedAt: updatedAt,
    NoteMetaFields.synced: synced ? 1 : 0,
  };

  /// 从数据库行构造。
  ///
  /// [decryptedPayload] 由 DB 层解密 payload 列后传入（明文 JSON）。
  static NoteMeta fromRow(
    Map<String, dynamic> row, {
    String? decryptedPayload,
  }) {
    final parsed = decodePayload(decryptedPayload);
    return NoteMeta(
      id: row[NoteMetaFields.id] as int?,
      uuid: row[NoteMetaFields.uuid] as String? ?? '',
      pinned: (row[NoteMetaFields.pinned] as int?) == 1,
      archived: (row[NoteMetaFields.archived] as int?) == 1,
      color: row[NoteMetaFields.color] as int?,
      deleted: (row[NoteMetaFields.deleted] as int?) == 1,
      updatedAt: (row[NoteMetaFields.updatedAt] as int?) ?? 0,
      synced: (row[NoteMetaFields.synced] as int?) == 1,
      tags: parsed.tags,
      extra: parsed.extra,
    );
  }

  /// 调试输出。
  ///
  /// 隐私红线：**绝不打印 tags / payload 内容**（标签名本身即用户隐私），
  /// 只输出计数与非敏感标志位。与 database_handler 的日志约定一致。
  @override
  String toString() =>
      'NoteMeta(uuid: $uuid, pinned: $pinned, archived: $archived, '
      'deleted: $deleted, tags: ${tags.length}, extra: ${extra.length}, '
      'updatedAt: $updatedAt, synced: $synced)';
}
