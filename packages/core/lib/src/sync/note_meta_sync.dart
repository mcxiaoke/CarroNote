/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

/*
 * 笔记元数据同步（items.meta，per-note LWW）
 *
 * 设计文档：docs/feature-note-meta-design.md §6 + docs/note-meta-sync-plan.md
 *
 * 远端对象：SyncBackend 根下的单个加密文件 `items.meta`，
 *   内容为全部笔记元数据的全量快照（含待上报墓碑）。
 *   文件级并发为 last-writer-wins（无 ETag CAS），靠「上传前先下载合并」+
 *   「下载时逐条 per-note LWW」在下一轮收敛——两台设备改不同笔记不互相丢失。
 *
 * 加密：AES-GCM(dataKey) 整体加密，AAD 用独立域分隔符 [kNoteMetaAad]
 *   （与 blob 的内容 hash 域、journal-archive 域互斥，防信封互换重放）。
 *   payload 条目在文件内是**明文 JSON 对象**（整文件已加密，避免双重加密）。
 *
 * 红线：
 *   - 绝不触碰 SafeNote.computeHash / toContentBytes / blob AAD；
 *   - wire 格式**不含 locked**（拍板决策：locked 是本地行为标志，不同步）；
 *   - 日志绝不打印 tags / payload 内容（标签名即用户隐私）。
 */

// Dart 导入
import 'dart:convert';
import 'dart:typed_data';

// Project 导入
import 'package:core/src/crypto/crypto.dart';
import 'package:core/src/models/note_meta.dart';

// ──────────────────────────────────────────────
// 常量
// ──────────────────────────────────────────────

/// items.meta 信封的 AAD 域分隔符
///
/// 经 [SyncCrypto.seal]/[open] 的 id 参数传入（id 即 AAD 字节），
/// 与 kJournalAad（journal-archive）、blob 内容 hash 各占独立域。
const String kNoteMetaAad = 'note-meta-v1';

/// items.meta wire 格式版本号
///
/// 解析到更高版本时调用方必须整体跳过本轮 meta 同步（不下也不上），
/// 防止旧客户端把新格式数据降级覆盖掉（与 manifest 的协议降级拒绝同思路）。
const int kNoteMetaWireVersion = 1;

// ──────────────────────────────────────────────
// 解析结果
// ──────────────────────────────────────────────

/// 远端 items.meta 的解析结果
class NoteMetaRemoteFile {
  /// wire 格式版本号（原样透出，供调用方做降级保护判定）
  final int version;

  /// uuid → 元数据条目（synced 恒 false，由 DB 层合并写入时置位）
  final Map<String, NoteMeta> metas;

  const NoteMetaRemoteFile({required this.version, required this.metas});
}

// ──────────────────────────────────────────────
// 编解码器
// ──────────────────────────────────────────────

/// items.meta 编解码器（wire JSON ⇄ NoteMeta）+ 信封加解密封装
class NoteMetaSyncCodec {
  NoteMetaSyncCodec._();

  // ── 信封加解密（AAD 域分隔见 [kNoteMetaAad]）──

  /// 加密 items.meta 明文 → 密文信封
  static Future<Uint8List> seal(Uint8List dataKey, Uint8List plaintext) =>
      SyncCrypto.seal(dataKey, kNoteMetaAad, plaintext);

  /// 解密 items.meta 信封 → 明文；密钥/AAD 不符或损坏抛
  /// [SyncDecryptionException]
  static Future<Uint8List> open(Uint8List dataKey, Uint8List envelope) =>
      SyncCrypto.open(dataKey, kNoteMetaAad, envelope);

  // ── wire 序列化 ──

  /// 序列化全量元数据（含待上报墓碑）为明文 JSON 字节
  ///
  /// 只写非默认值以减小体积；payload 内未识别键经 [NoteMeta.extra] 原样
  /// 透传回顶层（前向兼容，与本地 payload 列同一机制）。
  static Uint8List encode(Map<String, NoteMeta> all) {
    final notes = <String, dynamic>{};
    for (final e in all.entries) {
      notes[e.key] = _entryToJson(e.value);
    }
    return Uint8List.fromList(
      utf8.encode(jsonEncode({'v': kNoteMetaWireVersion, 'notes': notes})),
    );
  }

  /// 解析明文 JSON 字节。
  ///
  /// 返回值分三种情况：
  ///   - 正常：[NoteMetaRemoteFile]，metas 为有效条目（单条目损坏时跳过该条）；
  ///   - 未来版本：version > [kNoteMetaWireVersion]，metas 为空——调用方必须
  ///     跳过本轮（既不应用也不上传），等客户端升级；
  ///   - 结构性损坏（根不是 map / v 缺失非法）：返回 null——调用方走自愈重建。
  ///
  /// updatedAt <= 0 或 uuid 为空的条目视为无效，跳过。
  static NoteMetaRemoteFile? decode(Uint8List plaintext) {
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(plaintext));
    } on Object {
      return null; // 非 UTF-8 / 非法 JSON → 结构性损坏
    }
    if (decoded is! Map<String, dynamic>) return null;
    final v = decoded['v'];
    if (v is! int || v < 1) return null;
    if (v > kNoteMetaWireVersion) {
      // 未来版本：空结果 + 版本号透出，由调用方决定跳过策略
      return NoteMetaRemoteFile(version: v, metas: const {});
    }

    final rawNotes = decoded['notes'];
    if (rawNotes != null && rawNotes is! Map<String, dynamic>) return null;

    final metas = <String, NoteMeta>{};
    for (final e in (rawNotes as Map<String, dynamic>? ?? {}).entries) {
      final uuid = e.key;
      if (uuid.isEmpty) continue;
      final json = e.value;
      if (json is! Map<String, dynamic>) continue; // 单条目损坏 → 跳过
      final meta = _entryFromJson(uuid, json);
      if (meta == null) continue;
      metas[uuid] = meta;
    }
    return NoteMetaRemoteFile(version: v, metas: metas);
  }

  // ── per-note LWW ──

  /// per-note LWW 判定：远端条目是否应覆盖本地
  ///
  /// 本地缺失 → 远端胜；时间戳相等 → 保留本地（减少无谓写入抖动）。
  /// 时钟倒挂可能旧值覆盖新值，属 LWW 固有限制（与笔记正文 LWW 一致）。
  static bool remoteWins(NoteMeta remote, NoteMeta? local) {
    if (local == null) return true;
    return remote.updatedAt > local.updatedAt;
  }

  // ── 内部：单条目映射 ──

  static Map<String, dynamic> _entryToJson(NoteMeta m) {
    final json = <String, dynamic>{
      'pinned': m.pinned ? 1 : 0,
      'archived': m.archived ? 1 : 0,
      'color': m.color,
      'deleted': m.deleted ? 1 : 0,
      'updated_at': m.updatedAt,
    };
    // payload 放明文对象（整文件已加密）；null 表示无内容不写字段
    final payload = _payloadToJson(m);
    if (payload != null) json['payload'] = payload;
    return json;
  }

  static Map<String, dynamic>? _payloadToJson(NoteMeta m) {
    final s = m.encodePayload();
    if (s == null) return null;
    // 防御性容错：encodePayload 产物理论恒为合法 JSON，但 extra 透传内容
    // 来自历史 payload，不信任其可再解码——失败时丢弃 payload（元数据次要，
    // 单条降级好过整文件序列化崩溃）。
    try {
      final decoded = jsonDecode(s);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on Object {
      return null;
    }
  }

  /// wire 条目 → NoteMeta；无效（updatedAt<=0 等）返回 null
  static NoteMeta? _entryFromJson(String uuid, Map<String, dynamic> json) {
    final updatedAt = (json['updated_at'] as num?)?.toInt() ?? 0;
    if (updatedAt <= 0) return null; // 无效锚点，无法参与 LWW

    final payload = json['payload'];
    String? payloadStr;
    if (payload is Map<String, dynamic>) {
      payloadStr = jsonEncode(payload);
    } else if (payload is String) {
      payloadStr = payload; // 容错：兼容字符串形式的历史实现
    }
    final parsed = NoteMeta.decodePayload(payloadStr);

    return NoteMeta(
      uuid: uuid,
      pinned: json['pinned'] == 1,
      archived: json['archived'] == 1,
      color: (json['color'] as num?)?.toInt(),
      deleted: json['deleted'] == 1,
      updatedAt: updatedAt,
      tags: parsed.tags,
      extra: parsed.extra,
    );
  }
}
