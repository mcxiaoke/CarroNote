/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*
*/

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:core/core.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';

SafeNote _makeNote({
  required String uuid,
  required String title,
  String description = 'desc',
  bool deleted = false,
  int? updatedAt,
  String? syncedHash,
  bool synced = false,
}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return SafeNote(
    uuid: uuid,
    title: title,
    description: description,
    contentHash: SafeNote.computeHash(title, description),
    deleted: deleted,
    createdTime: DateTime.now(),
    updatedAt: updatedAt ?? now,
    synced: synced,
    syncedHash: syncedHash,
  );
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tempDir;
  late NotesDatabase database;
  late Uint8List testDataKey;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('db_migration_test_');
    NotesDatabase.dbPathOverride = tempDir.path;

    database = NotesDatabase.instance;
    testDataKey = SyncCrypto.generateDataKey();
    database.setDataKey(testDataKey);
  });

  tearDown(() async {
    await database.close();
    NotesDatabase.dbPathOverride = null;
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('onUpgrade v3 → v7 迁移测试', () {
    test('真实 v3 数据库升级到 v7：synced_deleted 补齐且老数据为 0，note_meta 表创建', () async {
      await database.close();

      final dbPath = p.join(tempDir.path, 'safenotes_sync.db');
      // 1. 手工创建 v3 数据库结构 (tableNotes = safe_notes)
      final v3db = await openDatabase(
        dbPath,
        version: 3,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE safe_notes (
              _id INTEGER PRIMARY KEY AUTOINCREMENT,
              uuid TEXT NOT NULL UNIQUE,
              title TEXT NOT NULL,
              description TEXT NOT NULL,
              content_hash TEXT NOT NULL,
              deleted INTEGER NOT NULL DEFAULT 0,
              created_at TEXT NOT NULL,
              updated_at INTEGER NOT NULL,
              synced INTEGER NOT NULL DEFAULT 0,
              synced_hash TEXT
            )
          ''');
          await db.execute('''
            CREATE TABLE sync_meta (
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL
            )
          ''');
        },
      );

      // 插入一条加密行（使用 testDataKey）
      final encTitle = base64Encode(
        await SyncCrypto.seal(
          testDataKey,
          'uuid-v3-1',
          Uint8List.fromList(utf8.encode('V3 Title')),
        ),
      );
      final encDesc = base64Encode(
        await SyncCrypto.seal(
          testDataKey,
          'uuid-v3-1',
          Uint8List.fromList(utf8.encode('V3 Desc')),
        ),
      );
      await v3db.insert('safe_notes', {
        'uuid': 'uuid-v3-1',
        'title': encTitle,
        'description': encDesc,
        'content_hash': 'hash-v3',
        'deleted': 0,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': 1700000000000,
        'synced': 1,
        'synced_hash': 'hash-v3',
      });
      await v3db.close();

      // 2. 用 NotesDatabase 重新打开（version: 7 自动执行 _onUpgrade）
      database.setDataKey(testDataKey);
      final notes = await database.readAllNotes();
      expect(notes.length, equals(1));
      expect(notes.first.title, equals('V3 Title'));
      expect(
        notes.first.syncedDeleted,
        isFalse,
        reason: '旧数据的 synced_deleted 默认迁移为 false/0',
      );

      // 验证 note_meta 表已创建且可用
      await database.setNotePinned('uuid-v3-1', true);
      final meta = await database.getNoteMeta('uuid-v3-1');
      expect(meta?.pinned, isTrue);
    });
  });

  group(
    'reEncryptAllNotes / reEncryptAllNotesAtomically 异常回滚与 MigrationInProgressException 测试',
    () {
      test('原子化迁移中途异常时回滚：_dataKey 恢复、_isMigrating 复位、旧 key 仍能解密', () async {
        final note1 = _makeNote(
          uuid: 'uuid-roll-1',
          title: 'Note 1',
          description: 'Desc 1',
        );
        final note2 = _makeNote(
          uuid: 'uuid-roll-2',
          title: 'Note 2',
          description: 'Desc 2',
          deleted: true,
        );
        await database.storeNote(note1);
        await database.storeNote(note2);
        await database.setNotePinned('uuid-roll-1', true);

        final newKey = SyncCrypto.generateDataKey();

        // 构造在执行过程中抛异常：用错误格式触发异常或数据库操作失败
        // 我们通过关闭数据库或者故意注入不可加密的数据来制造异常
        // 验证在原子化迁移抛错后，状态正确回滚
        try {
          await database.reEncryptAllNotesAtomically(
            oldKey: Uint8List.fromList(
              List.filled(16, 0),
            ), // 错误的 16 字节 key，导致 open 抛错
            newKey: newKey,
            keyringJson: '{"vaultId":"v"}',
          );
          fail('Should throw exception on wrong oldKey');
        } catch (e) {
          expect(e, isA<SyncDecryptionException>());
        }

        // 验证状态一致性：
        expect(database.getCacheInfo()['isMigrating'], isFalse);
        expect(database.dataKeyForTesting, equals(testDataKey));

        // 用旧密钥仍能完整读取解密
        final readNotes = await database.readAllNotes();
        expect(readNotes.any((n) => n.title == 'Note 1'), isTrue);
      });

      test('reEncryptAllNotes 普通方法异常回滚：_dataKey 恢复、_isMigrating 复位', () async {
        final note1 = _makeNote(uuid: 'uuid-roll-3', title: 'Note 3');
        await database.storeNote(note1);

        try {
          await database.reEncryptAllNotes(
            oldKey: Uint8List.fromList(List.filled(16, 0)), // 错误 key 触发解密异常
            newKey: SyncCrypto.generateDataKey(),
          );
          fail('Should throw exception');
        } catch (e) {
          expect(e, isA<SyncDecryptionException>());
        }

        expect(database.getCacheInfo()['isMigrating'], isFalse);
        expect(database.dataKeyForTesting, equals(testDataKey));
        final readNotes = await database.readAllNotes();
        expect(readNotes.any((n) => n.title == 'Note 3'), isTrue);
      });
    },
  );

  group('损坏 JSON 与容错防护测试', () {
    test(
      '_parseUuidList / getPurgedUuids 损坏 JSON 时抛出 FormatException',
      () async {
        await database.setMeta(MetaKeys.purgedUuids, 'corrupted_json_{[}');

        expect(
          () async => await database.getPurgedUuids(),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('MetaKeys.purgedUuids 解析失败'),
            ),
          ),
        );

        // 非数组 JSON
        await database.setMeta(MetaKeys.purgedUuids, '{"not": "array"}');
        expect(
          () async => await database.getPurgedUuids(),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('根节点不是 JSON 数组'),
            ),
          ),
        );
      },
    );

    test(
      'markAllForBlobReupload / getPendingReuploadUuids / removePendingReuploadUuids 状态与容错',
      () async {
        final note1 = _makeNote(uuid: 'uuid-reup-1', title: 'R1');
        final note2 = _makeNote(uuid: 'uuid-reup-2', title: 'R2');
        final noteDel = _makeNote(
          uuid: 'uuid-reup-3',
          title: 'R3 Del',
          deleted: true,
        );
        await database.storeNote(note1);
        await database.storeNote(note2);
        await database.storeNote(noteDel);

        await database.markAllForBlobReupload();
        final pending = await database.getPendingReuploadUuids();
        expect(pending.contains('uuid-reup-1'), isTrue);
        expect(pending.contains('uuid-reup-2'), isTrue);
        expect(pending.contains('uuid-reup-3'), isFalse, reason: '已删除笔记不标记重传');

        // 部分移除
        await database.removePendingReuploadUuids({'uuid-reup-1'});
        final remaining = await database.getPendingReuploadUuids();
        expect(remaining.contains('uuid-reup-1'), isFalse);
        expect(remaining.contains('uuid-reup-2'), isTrue);

        // 全部移除
        await database.removePendingReuploadUuids({'uuid-reup-2'});
        expect((await database.getPendingReuploadUuids()).isEmpty, isTrue);

        // 损坏 JSON 容错降级返回空集合
        await database.setMeta(MetaKeys.blobReuploadPending, 'corrupt-json');
        expect(await database.getPendingReuploadUuids(), isEmpty);
      },
    );

    test('GC 候选表存取与损坏 JSON 降级', () async {
      await database.setGcOrphanCandidates({'hash1': 1000, 'hash2': 2000});
      final candidates = await database.getGcOrphanCandidates();
      expect(candidates['hash1'], equals(1000));
      expect(candidates['hash2'], equals(2000));

      // 清空
      await database.setGcOrphanCandidates({});
      expect(await database.getGcOrphanCandidates(), isEmpty);

      // 损坏 JSON
      await database.setMeta(MetaKeys.gcOrphanCandidates, 'corrupt');
      expect(await database.getGcOrphanCandidates(), isEmpty);
    });

    test('getManifestVersion 损坏值容错降级为 0', () async {
      expect(await database.getManifestVersion('prov-1'), equals(0));

      await database.setManifestVersion('prov-1', 42);
      expect(await database.getManifestVersion('prov-1'), equals(42));

      // 损坏值为非数字字符串
      await database.setMeta('manifest_version:prov-1', 'not_a_number');
      expect(await database.getManifestVersion('prov-1'), equals(0));
    });
  });

  group('restoreNote 与缓存状态测试', () {
    test('restoreNote 后 deleted=0, synced=0 且 updatedAt 刷新', () async {
      final note = _makeNote(
        uuid: 'uuid-rest-1',
        title: 'To Restore',
        synced: true,
      );
      final stored = await database.storeNote(note);
      await database.softDelete(stored.id!);

      final deletedNotes = await database.readDeletedNotes();
      expect(deletedNotes.length, equals(1));

      final rows = await database.restoreNote(stored.id!);
      expect(rows, equals(1));

      final activeNotes = await database.readAllNotes();
      expect(activeNotes.length, equals(1));
      final restored = activeNotes.first;
      expect(restored.deleted, isFalse);
      expect(restored.synced, isFalse);
      expect(restored.updatedAt, greaterThanOrEqualTo(stored.updatedAt));
    });
  });

  group('隐私红线与导出闭环测试', () {
    test('cachedNoteSummaries 绝对不包含 title 明文与正文', () async {
      final note = _makeNote(
        uuid: 'uuid-priv-1',
        title: 'TopSecretTitle',
        description: 'TopSecretBody',
      );
      await database.storeNote(note);
      await database.readAllNotes(); // 构建缓存

      final summaries = database.cachedNoteSummaries();
      expect(summaries.isNotEmpty, isTrue);
      final summary = summaries.firstWhere((s) => s['uuid'] == 'uuid-priv-1');

      expect(
        summary.containsKey('title'),
        isFalse,
        reason: '隐私红线：不得包含 title 键',
      );
      expect(
        summary.containsKey('description'),
        isFalse,
        reason: '隐私红线：不得包含 description 键',
      );
      expect(summary['titleLength'], equals('TopSecretTitle'.length));
      expect(summary['titleHash'], isNotNull);
    });

    test('_decryptField 对非法 Base64 包装为 SyncDecryptionException', () async {
      // 插入一条 title 包含非法 base64 的行 (safe_notes 表)
      final db = await database.database;
      await db.insert('safe_notes', {
        'uuid': 'uuid-bad-b64',
        'title': '!!!Not Valid Base64 Content!!!',
        'description': 'desc',
        'content_hash': 'h',
        'deleted': 0,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': 100,
        'synced': 0,
        'synced_deleted': 0,
      });

      // 读取该笔记时解密失败抛出 SyncDecryptionException
      expect(
        () async => await database.readNoteByUuid('uuid-bad-b64'),
        throwsA(
          isA<SyncDecryptionException>().having(
            (e) => e.aadId,
            'aadId',
            equals('uuid-bad-b64'),
          ),
        ),
      );
    });

    test('exportAll 与 ImportParser 闭环无损', () async {
      final note1 = _makeNote(
        uuid: 'uuid-exp-1',
        title: 'Export 1',
        description: 'Content 1',
      );
      final note2 = _makeNote(
        uuid: 'uuid-exp-2',
        title: 'Export 2',
        description: 'Content 2',
      );
      await database.storeNote(note1);
      await database.storeNote(note2);

      final jsonStr = await database.exportAll();
      final decodedList = jsonDecode(jsonStr) as List<dynamic>;
      final parsed = ImportParser.fromDecryptedPlaintext(decodedList);

      expect(parsed.totalNotes, equals(2));
      expect(
        parsed.parsedNotes.any(
          (n) => n.title == 'Export 1' && n.description == 'Content 1',
        ),
        isTrue,
      );
      expect(
        parsed.parsedNotes.any(
          (n) => n.title == 'Export 2' && n.description == 'Content 2',
        ),
        isTrue,
      );
    });
  });
}
