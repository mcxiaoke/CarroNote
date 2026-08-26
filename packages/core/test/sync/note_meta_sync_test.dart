/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*/

// note_meta 同步编解码器单测（items.meta wire 格式 + 信封加解密 + LWW 判定）
//
// 覆盖 docs/note-meta-sync-plan.md B 组：
//   - wire 往返（全字段 / 墓碑 / extra 透传 / 空文件）
//   - decode 容错分级（结构损坏 → null；单条目损坏 → 跳过；未来版本 → 保护）
//   - AAD 域分离（meta 信封不能被 journal 域解开）
//   - per-note LWW remoteWins 四象限

import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:core/core.dart';

NoteMeta _meta({
  required String uuid,
  bool pinned = false,
  bool archived = false,
  int? color,
  bool deleted = false,
  int updatedAt = 1755500000000,
  List<String> tags = const [],
  Map<String, dynamic> extra = const {},
}) => NoteMeta(
  uuid: uuid,
  pinned: pinned,
  archived: archived,
  color: color,
  deleted: deleted,
  updatedAt: updatedAt,
  tags: tags,
  extra: extra,
);

void main() {
  group('NoteMetaSyncCodec - wire 往返', () {
    test('全字段条目 encode→decode 往返一致', () {
      final meta = _meta(
        uuid: 'uuid-1',
        pinned: true,
        archived: true,
        color: 0xFFFF0000,
        tags: ['工作', 'idea'],
      );
      final plain = NoteMetaSyncCodec.encode({'uuid-1': meta});
      final parsed = NoteMetaSyncCodec.decode(plain);

      expect(parsed, isNotNull);
      expect(parsed!.version, kNoteMetaWireVersion);
      final out = parsed.metas['uuid-1'];
      expect(out, isNotNull);
      expect(out!.pinned, isTrue);
      expect(out.archived, isTrue);
      expect(out.color, 0xFFFF0000);
      expect(out.deleted, isFalse);
      expect(out.updatedAt, meta.updatedAt);
      expect(out.tags, ['工作', 'idea']);
    });

    test('墓碑条目往返（deleted=1、无 payload）', () {
      final tombstone = _meta(uuid: 'tomb-1', deleted: true, updatedAt: 1234);
      final parsed = NoteMetaSyncCodec.decode(
        NoteMetaSyncCodec.encode({'tomb-1': tombstone}),
      );
      final out = parsed!.metas['tomb-1'];
      expect(out!.deleted, isTrue);
      expect(out.tags, isEmpty);
      // 墓碑 payload 为空 → wire 不含 payload 字段
      final wire =
          jsonDecode(
                utf8.decode(NoteMetaSyncCodec.encode({'tomb-1': tombstone})),
              )
              as Map<String, dynamic>;
      expect((wire['notes'] as Map)['tomb-1'].containsKey('payload'), isFalse);
    });

    test('extra 未知键透传穿过 wire（前向兼容）', () {
      final meta = _meta(
        uuid: 'ext-1',
        tags: ['a'],
        extra: {'futureField': 42},
      );
      final parsed = NoteMetaSyncCodec.decode(
        NoteMetaSyncCodec.encode({'ext-1': meta}),
      );
      final out = parsed!.metas['ext-1']!;
      expect(out.extra['futureField'], 42);
      expect(out.tags, ['a']);
    });

    test('locked 不进 wire（拍板决策：本地行为标志不同步）', () {
      final meta = _meta(uuid: 'lock-1').copyWith(locked: true);
      final wire =
          jsonDecode(utf8.decode(NoteMetaSyncCodec.encode({'lock-1': meta})))
              as Map<String, dynamic>;
      final entry = (wire['notes'] as Map)['lock-1'] as Map<String, dynamic>;
      expect(entry.containsKey('locked'), isFalse);
    });

    test('空 map 序列化为合法空文件并可解析', () {
      final parsed = NoteMetaSyncCodec.decode(
        NoteMetaSyncCodec.encode(const {}),
      );
      expect(parsed, isNotNull);
      expect(parsed!.version, kNoteMetaWireVersion);
      expect(parsed.metas, isEmpty);
    });

    test('synced / id 不进 wire', () {
      final wire =
          jsonDecode(
                utf8.decode(NoteMetaSyncCodec.encode({'u': _meta(uuid: 'u')})),
              )
              as Map<String, dynamic>;
      final entry = (wire['notes'] as Map)['u'] as Map<String, dynamic>;
      expect(entry.containsKey('synced'), isFalse);
      expect(entry.containsKey('id'), isFalse);
      expect(entry.containsKey('_id'), isFalse);
    });
  });

  group('NoteMetaSyncCodec - decode 容错', () {
    test('非法 JSON 字节 → null（结构性损坏）', () {
      expect(
        NoteMetaSyncCodec.decode(Uint8List.fromList([0, 1, 2, 3])),
        isNull,
      );
    });

    test('根不是对象 → null', () {
      expect(
        NoteMetaSyncCodec.decode(Uint8List.fromList(utf8.encode('[1,2]'))),
        isNull,
      );
    });

    test('v 缺失或非法 → null', () {
      expect(
        NoteMetaSyncCodec.decode(
          Uint8List.fromList(utf8.encode('{"notes":{}}')),
        ),
        isNull,
      );
      expect(
        NoteMetaSyncCodec.decode(
          Uint8List.fromList(utf8.encode('{"v":"x","notes":{}}')),
        ),
        isNull,
      );
    });

    test('notes 非对象 → null', () {
      expect(
        NoteMetaSyncCodec.decode(
          Uint8List.fromList(utf8.encode('{"v":1,"notes":42}')),
        ),
        isNull,
      );
    });

    test('单条目损坏 → 跳过该条，其余保留', () {
      final wire =
          jsonDecode(
                utf8.decode(
                  NoteMetaSyncCodec.encode({
                    'good': _meta(uuid: 'good', pinned: true),
                  }),
                ),
              )
              as Map<String, dynamic>;
      (wire['notes'] as Map)['bad'] = 'not-an-object';
      final parsed = NoteMetaSyncCodec.decode(
        Uint8List.fromList(utf8.encode(jsonEncode(wire))),
      );
      expect(parsed!.metas.containsKey('bad'), isFalse);
      expect(parsed.metas['good']?.pinned, isTrue);
    });

    test('updatedAt<=0 条目跳过（无效 LWW 锚点）', () {
      final wire =
          jsonDecode(
                utf8.decode(
                  NoteMetaSyncCodec.encode({
                    'zero': _meta(uuid: 'zero', updatedAt: 0),
                  }),
                ),
              )
              as Map<String, dynamic>;
      ((wire['notes'] as Map)['zero'] as Map)['updated_at'] = 0;
      final parsed = NoteMetaSyncCodec.decode(
        Uint8List.fromList(utf8.encode(jsonEncode(wire))),
      );
      expect(parsed!.metas, isEmpty);
    });

    test('未来版本 → version 透出且 metas 为空（调用方跳过保护）', () {
      final parsed = NoteMetaSyncCodec.decode(
        Uint8List.fromList(utf8.encode('{"v":999,"notes":{"x":{}}}')),
      );
      expect(parsed, isNotNull);
      expect(parsed!.version, 999);
      expect(parsed.metas, isEmpty);
    });
  });

  group('NoteMetaSyncCodec - 信封加解密', () {
    test('seal/open 往返', () async {
      final dataKey = SyncCrypto.generateDataKey();
      final plaintext = Uint8List.fromList(utf8.encode('{"v":1,"notes":{}}'));
      final sealed = await NoteMetaSyncCodec.seal(dataKey, plaintext);
      final opened = await NoteMetaSyncCodec.open(dataKey, sealed);
      expect(opened, equals(plaintext));
    });

    test('AAD 域分离：journal 域解不开 meta 信封，blob hash 域同样解不开', () async {
      final dataKey = SyncCrypto.generateDataKey();
      final sealed = await NoteMetaSyncCodec.seal(dataKey, utf8.encode('x'));

      await expectLater(
        SyncCrypto.open(dataKey, kJournalAad, sealed),
        throwsA(isA<SyncDecryptionException>()),
      );
      await expectLater(
        SyncCrypto.open(dataKey, 'some-blob-hash', sealed),
        throwsA(isA<SyncDecryptionException>()),
      );
      // 正域可解（对照组）
      await expectLater(NoteMetaSyncCodec.open(dataKey, sealed), completes);
    });

    test('错误 dataKey 解密抛 SyncDecryptionException', () async {
      final sealed = await NoteMetaSyncCodec.seal(
        SyncCrypto.generateDataKey(),
        utf8.encode('secret'),
      );
      await expectLater(
        NoteMetaSyncCodec.open(SyncCrypto.generateDataKey(), sealed),
        throwsA(isA<SyncDecryptionException>()),
      );
    });
  });

  group('NoteMetaSyncCodec.remoteWins - per-note LWW', () {
    test('本地缺失 → 远端胜', () {
      expect(NoteMetaSyncCodec.remoteWins(_meta(uuid: 'r'), null), isTrue);
    });

    test('远端更新 → 远端胜；本地更新 → 本地守', () {
      final local = _meta(uuid: 'u', updatedAt: 2000);
      expect(
        NoteMetaSyncCodec.remoteWins(_meta(uuid: 'u', updatedAt: 3000), local),
        isTrue,
      );
      expect(
        NoteMetaSyncCodec.remoteWins(_meta(uuid: 'u', updatedAt: 1000), local),
        isFalse,
      );
    });

    test('相等 → 保留本地（减少抖动）', () {
      final local = _meta(uuid: 'u', updatedAt: 2000);
      expect(
        NoteMetaSyncCodec.remoteWins(_meta(uuid: 'u', updatedAt: 2000), local),
        isFalse,
      );
    });

    test('本地 defaults（updatedAt=0）恒被任何真实远端条目覆盖', () {
      expect(
        NoteMetaSyncCodec.remoteWins(
          _meta(uuid: 'u', updatedAt: 1),
          NoteMeta.defaults('u'),
        ),
        isTrue,
      );
    });
  });
}
