/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under
* terms of the GPL-3.0+ license.
*/

// note_meta 数据层单元测试（阶段 1.9）—— 见底部实现占位

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:core/core.dart';

/// 真实库迁移验证（E 组）为可选测试，需通过环境变量提供，避免把本机路径与
/// 口令写进仓库。未设置时该组自动 skip，不影响 CI 与他人 clone。
///
/// 用法（bash）：
///   SAFENOTES_TEST_DB=/path/to/safenotes_sync.db \
///   SAFENOTES_TEST_PASSWORD=xxxx \
///   dart test packages/core/test/db/note_meta_test.dart
final String _realDbPath = Platform.environment['SAFENOTES_TEST_DB'] ?? '';
final String _realDbPassword =
    Platform.environment['SAFENOTES_TEST_PASSWORD'] ?? '';

/// 合成 v4 库建表（notes + sync_meta，无 note_meta）
Future<void> _createV4Schema(Database db, int version) async {
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
      synced_hash TEXT,
      synced_deleted INTEGER NOT NULL DEFAULT 0
    )
  ''');
  await db.execute('''
    CREATE TABLE sync_meta (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )
  ''');
  await db.execute('CREATE INDEX idx_notes_uuid ON safe_notes(uuid)');
  await db.execute('CREATE INDEX idx_notes_deleted ON safe_notes(deleted)');
  await db.execute('CREATE INDEX idx_notes_synced ON safe_notes(synced)');
}

/// 经生产 `database` getter 重新打开 [dir] 下的 safenotes_sync.db，
/// 触发真实 onUpgrade 流程（v4→v5 创建 note_meta）。
Future<Database> _reopenViaProduction(String dir) async {
  NotesDatabase.dbPathOverride = dir;
  await NotesDatabase.instance.close();
  NotesDatabase.instance.clearDataKey();
  return NotesDatabase.instance.database;
}

/// 表是否存在
Future<bool> _tableExists(Database db, String name) async {
  final rows = await db.query(
    'sqlite_master',
    where: "type='table' AND name=?",
    whereArgs: [name],
  );
  return rows.isNotEmpty;
}

/// 测试笔记构造
SafeNote _makeNote({required String uuid}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return SafeNote(
    uuid: uuid,
    title: 'Title $uuid',
    description: 'Desc $uuid',
    contentHash: SafeNote.computeHash('Title $uuid', 'Desc $uuid'),
    deleted: false,
    createdTime: DateTime.now(),
    updatedAt: now,
    synced: false,
  );
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late NotesDatabase database;

  // ──────────────────────────────────────────────
  // A. 内存 CRUD（标准 in-memory 模式）
  // ──────────────────────────────────────────────
  group('note_meta CRUD（in-memory）', () {
    setUp(() async {
      final db = await openDatabase(
        ':memory:',
        version: 2,
        onCreate: NotesDatabase.createDBForTesting,
      );
      NotesDatabase.setDatabaseForTesting(db);
      database = NotesDatabase.instance;
      database.setDataKey(SyncCrypto.generateDataKey());
    });

    tearDown(() async {
      await database.close();
    });

    test('懒创建：无 meta 行时 getNoteMeta 返回 null', () async {
      expect(await database.getNoteMeta('nonexistent'), isNull);
      expect((await database.readAllNoteMeta()).isEmpty, isTrue);
    });

    test('setNotePinned 写入并可读回', () async {
      const uuid = 'pin-uuid-1';
      final written = await database.setNotePinned(uuid, true);
      expect(written.pinned, isTrue);
      expect(written.updatedAt, greaterThan(0));

      final read = await database.getNoteMeta(uuid);
      expect(read, isNotNull);
      expect(read!.pinned, isTrue);

      final all = await database.readAllNoteMeta();
      expect(all[uuid]?.pinned, isTrue);
    });

    test('setNoteTags 规范化：去空白 / 丢空串 / 去重', () async {
      const uuid = 'tags-uuid-1';
      final written = await database.setNoteTags(uuid, [
        ' 工作 ',
        '工作',
        '',
        '读书',
        ' 读书',
      ]);
      expect(written.tags, ['工作', '读书']);

      final read = await database.getNoteMeta(uuid);
      expect(read!.tags, ['工作', '读书']);
    });

    test('payload 加解密往返：标签名密文落盘、读取还原', () async {
      const uuid = 'payload-uuid-1';
      await database.setNoteTags(uuid, ['就医记录', '离职']);

      final raw = await (await NotesDatabase.instance.database).query(
        tableNoteMeta,
        columns: [NoteMetaFields.payload, NoteMetaFields.pinned],
        where: '${NoteMetaFields.uuid} = ?',
        whereArgs: [uuid],
      );
      expect(raw.first[NoteMetaFields.payload], isNotNull);
      expect(raw.first[NoteMetaFields.pinned], 0);

      final meta = await database.getNoteMeta(uuid);
      expect(meta!.tags, ['就医记录', '离职']);
    });

    test('readAllTags 跨笔记聚合去重并排序', () async {
      // 注意：标签大小写敏感（normalizeTags 只去空白/去重/保序），
      // 故 'Alpha' 与 'alpha' 视为两个不同标签。
      await database.setNoteTags('t-a', ['Beta', 'Alpha', 'Beta']);
      await database.setNoteTags('t-b', ['Gamma', 'Delta']);
      final tags = await database.readAllTags();
      expect(tags, ['Alpha', 'Beta', 'Delta', 'Gamma']);
    });

    test('切 pinned 不使 _notesCache 失效（零笔记解密）', () async {
      await database.storeNote(_makeNote(uuid: 'n-cache-1'));
      final before = await database.readAllNotes();
      expect(database.getCacheInfo()['cacheBuilt'], isTrue);
      final beforeCount = database.cachedNoteSummaries().length;
      expect(before, isNotEmpty);

      await database.setNotePinned('n-cache-1', true);

      expect(database.getCacheInfo()['cacheBuilt'], isTrue);
      expect(database.cachedNoteSummaries().length, beforeCount);

      final after = await database.readAllNotes();
      expect(after.length, before.length);
      expect(
        after.firstWhere((n) => n.uuid == 'n-cache-1').title,
        'Title n-cache-1',
      );
    });
  });

  // ──────────────────────────────────────────────
  // B. 合成 v4 → v5 升级（手工 v4 库）
  // ──────────────────────────────────────────────
  group('v4 → v5 升级（合成 v4 库）', () {
    late String dir;

    setUp(() async {
      final tmp = await Directory.systemTemp.createTemp('note_meta_v4_');
      dir = tmp.path;
      final path = '$dir${Platform.pathSeparator}safenotes_sync.db';
      final v4 = await openDatabase(
        path,
        version: 4,
        onCreate: _createV4Schema,
      );
      await v4.insert('safe_notes', {
        'uuid': 'legacy-note-1',
        'title': 'legacy',
        'description': 'legacy desc',
        'content_hash': 'h',
        'deleted': 0,
        'created_at': '2024',
        'updated_at': 1,
        'synced': 0,
        'synced_hash': null,
        'synced_deleted': 0,
      });
      await v4.close();

      await _reopenViaProduction(dir);
      database = NotesDatabase.instance;
    });

    tearDown(() async {
      await database.close();
      NotesDatabase.dbPathOverride = null;
      await Directory(dir).delete(recursive: true);
    });

    test('升级后 note_meta 表被创建', () async {
      final db = await NotesDatabase.instance.database;
      expect(await _tableExists(db, tableNoteMeta), isTrue);
    });

    test('既有笔记行完好未被破坏', () async {
      final db = await NotesDatabase.instance.database;
      final rows = await db.query(
        'safe_notes',
        where: 'uuid = ?',
        whereArgs: ['legacy-note-1'],
      );
      expect(rows.length, 1);
      expect(rows.first['uuid'], 'legacy-note-1');
    });

    test('升级后 note_meta 为空（懒创建，无需回填）', () async {
      expect((await database.readAllNoteMeta()).isEmpty, isTrue);
      expect(await database.getNoteMeta('legacy-note-1'), isNull);
    });

    test('升级后元数据 CRUD 仍可用', () async {
      database.setDataKey(SyncCrypto.generateDataKey());
      await database.setNotePinned('legacy-note-1', true);
      expect((await database.getNoteMeta('legacy-note-1'))?.pinned, isTrue);
    });
  });

  // ──────────────────────────────────────────────
  // C. 硬删除写墓碑
  // ──────────────────────────────────────────────
  group('硬删除写墓碑', () {
    setUp(() async {
      final db = await openDatabase(
        ':memory:',
        version: 2,
        onCreate: NotesDatabase.createDBForTesting,
      );
      NotesDatabase.setDatabaseForTesting(db);
      database = NotesDatabase.instance;
      database.setDataKey(SyncCrypto.generateDataKey());
    });

    tearDown(() async {
      await database.close();
    });

    test('hardDeleteByUuid 后 meta 行转为墓碑且 payload 擦除', () async {
      const uuid = 'del-meta-1';
      await database.storeNote(_makeNote(uuid: uuid));
      await database.setNotePinned(uuid, true);
      await database.setNoteTags(uuid, ['secret-tag']);

      final db = await NotesDatabase.instance.database;
      final before = await db.query(
        tableNoteMeta,
        where: '${NoteMetaFields.uuid} = ?',
        whereArgs: [uuid],
      );
      expect(before.length, 1);
      expect(before.first[NoteMetaFields.deleted], 0);
      expect(before.first[NoteMetaFields.payload], isNotNull);

      await database.hardDeleteByUuid(uuid);

      final after = await db.query(
        tableNoteMeta,
        where: '${NoteMetaFields.uuid} = ?',
        whereArgs: [uuid],
      );
      expect(after.length, 1);
      expect(after.first[NoteMetaFields.deleted], 1);
      expect(after.first[NoteMetaFields.payload], isNull);

      expect(await database.getNoteMeta(uuid), isNull);
      expect((await database.readAllNoteMeta())[uuid], isNull);
    });

    test('hardDelete（按 id）同样写墓碑', () async {
      const uuid = 'del-meta-2';
      final note = await database.storeNote(_makeNote(uuid: uuid));
      await database.setNoteTags(uuid, ['x']);
      await database.hardDelete(note.id!);

      final db = await NotesDatabase.instance.database;
      final rows = await db.query(
        tableNoteMeta,
        where: '${NoteMetaFields.uuid} = ?',
        whereArgs: [uuid],
      );
      expect(rows.length, 1);
      expect(rows.first[NoteMetaFields.deleted], 1);
    });
  });

  // ──────────────────────────────────────────────
  // D. dataKey 轮换：payload 同步重加密
  // ──────────────────────────────────────────────
  group('reEncryptAllNotes 重加密 payload', () {
    late Uint8List keyA;
    late Uint8List keyB;

    setUp(() async {
      final db = await openDatabase(
        ':memory:',
        version: 2,
        onCreate: NotesDatabase.createDBForTesting,
      );
      NotesDatabase.setDatabaseForTesting(db);
      database = NotesDatabase.instance;
      keyA = SyncCrypto.generateDataKey();
      keyB = SyncCrypto.generateDataKey();
      database.setDataKey(keyA);
    });

    tearDown(() async {
      await database.close();
    });

    test('轮换后 payload 用新 key 可解密，密文已变化', () async {
      const uuid = 'reenc-1';
      await database.storeNote(_makeNote(uuid: uuid));
      await database.setNoteTags(uuid, ['rotation-secret']);

      final db = await NotesDatabase.instance.database;
      final payloadBefore =
          (await db.query(
                tableNoteMeta,
                columns: [NoteMetaFields.payload],
                where: '${NoteMetaFields.uuid} = ?',
                whereArgs: [uuid],
              )).first[NoteMetaFields.payload]
              as String;

      await database.reEncryptAllNotes(oldKey: keyA, newKey: keyB);
      database.setDataKey(keyB);

      final payloadAfter =
          (await db.query(
                tableNoteMeta,
                columns: [NoteMetaFields.payload],
                where: '${NoteMetaFields.uuid} = ?',
                whereArgs: [uuid],
              )).first[NoteMetaFields.payload]
              as String;

      expect(payloadAfter, isNot(payloadBefore));

      final meta = await database.getNoteMeta(uuid);
      expect(meta!.tags, ['rotation-secret']);
    });
  });

  // ──────────────────────────────────────────────
  // E. 真实库迁移验证（可选，需环境变量提供库与口令）
  // ──────────────────────────────────────────────
  group('真实库迁移（可选）', () {
    final hasReal =
        _realDbPath.isNotEmpty &&
        _realDbPassword.isNotEmpty &&
        File(_realDbPath).existsSync();

    test(
      '真实库升级后全部笔记保全且 meta CRUD 可用',
      skip: hasReal
          ? false
          : '未设置 SAFENOTES_TEST_DB / SAFENOTES_TEST_PASSWORD，跳过真实库验证',
      () async {
        final tmp = await Directory.systemTemp.createTemp('note_meta_real_');
        final dir = tmp.path;
        final path = '$dir${Platform.pathSeparator}safenotes_sync.db';
        await File(_realDbPath).copy(path);

        await _reopenViaProduction(dir);
        database = NotesDatabase.instance;

        final db = await NotesDatabase.instance.database;
        expect(await _tableExists(db, tableNoteMeta), isTrue);

        final keyring = await Keyring.unlockLocal(
          password: _realDbPassword,
          database: NotesDatabase.instance,
        );
        database.setDataKey(keyring.dataKey);

        // 升级后全部笔记（含回收站软删）仍可解密，说明迁移未损坏既有数据
        final all = await database.readAllNotesIncludingDeleted();
        expect(all, isNotEmpty, reason: '升级后应能解密出既有笔记');
        // 活跃笔记数量 > 0，说明未删除的笔记也能正常解密
        final active = await database.readAllNotes();
        expect(active, isNotEmpty);

        final target = active.first.uuid;
        await database.setNotePinned(target, true);
        final meta = await database.getNoteMeta(target);
        expect(meta, isNotNull);
        expect(meta!.pinned, isTrue);

        await database.close();
        NotesDatabase.dbPathOverride = null;
        await tmp.delete(recursive: true);
      },
    );
  });
}
