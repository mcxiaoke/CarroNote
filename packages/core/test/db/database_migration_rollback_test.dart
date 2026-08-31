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
        // M1：错误的 oldKey 使全量行解密失败 → 迁移严格读取抛异常回滚
        //（reEncryptAllNotes* 走 _readAllNotesStrict，任何失败即抛 SyncDecryptionException）
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
          // M1：错误 oldKey → 迁移严格读取（_readAllNotesStrict）解密失败即抛，
          // 不会走隔离删除容错把小库悄悄删光；异常向上传播由调用方回滚。
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

        // 损坏 JSON：与 purgedUuids（_parseUuidList）同一容错策略——不静默返回空，
        // 否则同步会认为"无需重传"导致旧 key blob 永久残留远端，显式抛异常中止链路。
        await database.setMeta(MetaKeys.blobReuploadPending, 'corrupt-json');
        await expectLater(
          database.getPendingReuploadUuids(),
          throwsA(isA<FormatException>()),
        );

        // 非数组 / 元素非法 type 同样抛 FormatException
        await database.setMeta(MetaKeys.blobReuploadPending, '{"a":1}');
        await expectLater(
          database.getPendingReuploadUuids(),
          throwsA(isA<FormatException>()),
        );
        await database.setMeta(MetaKeys.blobReuploadPending, '["x", 1]');
        await expectLater(
          database.getPendingReuploadUuids(),
          throwsA(isA<FormatException>()),
        );
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

  group('评审第一批修复回归（P0-3 / P1-3）', () {
    test(
      'P1-3：queryTableRows(sync_meta) 不返回 value 列（keyring 材料不可泄露）',
      () async {
        await database.setMeta(
          MetaKeys.keyring,
          '{"encryptedDataKey":"secret"}',
        );

        final rows = await database.queryTableRows('sync_meta');
        expect(rows, isNotEmpty);
        for (final row in rows) {
          expect(
            row.containsKey('value'),
            isFalse,
            reason:
                'sync_meta.value 含 keyring JSON（encryptedDataKey + KDF '
                'salt + iterations），泄露等同交出可离线爆破的密码哈希',
          );
          expect(row.containsKey('key'), isTrue);
        }
      },
    );

    test('P0-3：迁移窗口内 8 处写路径全部抛 MigrationInProgressException', () async {
      final note = _makeNote(uuid: 'uuid-guard-1', title: 'Guard');
      final stored = await database.storeNote(note);

      database.migratingForTesting = true;
      try {
        expect(
          () => database.upsertNoteMeta(NoteMeta.defaults('uuid-guard-1')),
          throwsA(isA<MigrationInProgressException>()),
        );
        expect(
          () => database.softDelete(stored.id!),
          throwsA(isA<MigrationInProgressException>()),
        );
        expect(
          () => database.hardDelete(stored.id!),
          throwsA(isA<MigrationInProgressException>()),
        );
        expect(
          () => database.hardDeleteByUuid('uuid-guard-1'),
          throwsA(isA<MigrationInProgressException>()),
        );
        expect(
          () => database.restoreNote(stored.id!),
          throwsA(isA<MigrationInProgressException>()),
        );
        expect(
          () => database.markSynced('uuid-guard-1'),
          throwsA(isA<MigrationInProgressException>()),
        );
        expect(
          () => database.markAllSynced(),
          throwsA(isA<MigrationInProgressException>()),
        );
        expect(
          () => database.markSyncedForUuids({'uuid-guard-1'}),
          throwsA(isA<MigrationInProgressException>()),
        );
      } finally {
        database.migratingForTesting = false;
      }

      // 复位后写路径恢复正常（守卫不残留）
      await database.markSynced('uuid-guard-1');
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

    test('M1：读路径遇非法 Base64 坏行返回 null（隔离删除，不再抛异常）', () async {
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

      // M1：单行解密失败（隔离损坏）→ 视为"笔记不存在"返回 null，
      // 原始加密行先隔离落盘再删除（详见 m1_decrypt_failure_test.dart）。
      expect(await database.readNoteByUuid('uuid-bad-b64'), isNull);

      final rows = await db.query(
        'safe_notes',
        where: 'uuid = ?',
        whereArgs: ['uuid-bad-b64'],
      );
      expect(rows, isEmpty, reason: 'M1：坏行应被原始删除');
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
