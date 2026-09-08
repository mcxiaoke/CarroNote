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

/// 合成 v5 库建表：notes + sync_meta + note_meta（**无 locked 列**，模拟 v5 老库）。
Future<void> _createV5Schema(Database db, int version) async {
  await _createV4Schema(db, version);
  await db.execute('''
    CREATE TABLE IF NOT EXISTS note_meta (
      _id INTEGER PRIMARY KEY AUTOINCREMENT,
      uuid TEXT NOT NULL UNIQUE,
      pinned INTEGER NOT NULL DEFAULT 0,
      archived INTEGER NOT NULL DEFAULT 0,
      color INTEGER,
      deleted INTEGER NOT NULL DEFAULT 0,
      payload TEXT,
      updated_at INTEGER NOT NULL,
      synced INTEGER NOT NULL DEFAULT 0
    )
  ''');
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

/// 构造指定 updatedAt 的元数据（同步配套测试用，LWW 锚点需可控）
NoteMeta _metaAt(
  String uuid, {
  bool pinned = false,
  bool archived = false,
  int? updatedAt,
  List<String> tags = const [],
}) => NoteMeta(
  uuid: uuid,
  pinned: pinned,
  archived: archived,
  updatedAt: updatedAt ?? DateTime.now().millisecondsSinceEpoch,
  tags: tags,
);

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

    test('setNoteLocked 写入可读回，且不触碰 pinned', () async {
      const uuid = 'lock-uuid-1';
      final written = await database.setNoteLocked(uuid, true);
      expect(written.locked, isTrue);
      expect(written.pinned, isFalse);
      expect(written.updatedAt, greaterThan(0));

      final read = await database.getNoteMeta(uuid);
      expect(read, isNotNull);
      expect(read!.locked, isTrue);

      // 解锁后读回为 false
      await database.setNoteLocked(uuid, false);
      expect((await database.getNoteMeta(uuid))!.locked, isFalse);
    });

    test('locked 为默认值时 isDefault 为真', () {
      final m = NoteMeta.defaults('x');
      expect(m.locked, isFalse);
      expect(m.isDefault, isTrue);
      expect(m.copyWith(locked: true).isDefault, isFalse);
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
  // B2. 合成 v5 → v6 升级（note_meta 补 locked 列）
  // ──────────────────────────────────────────────
  group('v5 → v6 升级（note_meta 补 locked 列）', () {
    late String dir;

    setUp(() async {
      final tmp = await Directory.systemTemp.createTemp('note_meta_v5_');
      dir = tmp.path;
      final path = '$dir${Platform.pathSeparator}safenotes_sync.db';
      final v5 = await openDatabase(
        path,
        version: 5,
        onCreate: _createV5Schema,
      );
      await v5.insert('note_meta', {
        'uuid': 'legacy-meta-1',
        'pinned': 1,
        'archived': 0,
        'deleted': 0,
        'updated_at': 123,
        'synced': 0,
      });
      await v5.close();

      await _reopenViaProduction(dir);
      database = NotesDatabase.instance;
    });

    tearDown(() async {
      await database.close();
      NotesDatabase.dbPathOverride = null;
      await Directory(dir).delete(recursive: true);
    });

    test('升级后 note_meta 含 locked 列，老行默认 0', () async {
      final db = await NotesDatabase.instance.database;
      final cols = await db.rawQuery('PRAGMA table_info(note_meta)');
      final names = cols.map((c) => c['name']).toSet();
      expect(names, contains('locked'));

      final rows = await db.query(
        'note_meta',
        where: 'uuid = ?',
        whereArgs: ['legacy-meta-1'],
      );
      expect(rows.first['locked'], 0);
    });

    test('升级后可写 locked 并读回', () async {
      database.setDataKey(SyncCrypto.generateDataKey());
      await database.setNoteLocked('legacy-meta-1', true);
      expect((await database.getNoteMeta('legacy-meta-1'))?.locked, isTrue);
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
  // F. 同步配套（items.meta + per-note LWW，docs/note-meta-sync-plan.md C 组）
  // ──────────────────────────────────────────────
  group('note_meta 同步配套', () {
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

    test(
      'readAllNoteMetaIncludingTombstones 含墓碑行，readAllNoteMeta 不含',
      () async {
        const alive = 'alive-1';
        const gone = 'gone-1';
        await database.setNotePinned(alive, true);
        // 直接写墓碑行（模拟 hardDelete 的产物）
        await (await NotesDatabase.instance.database).insert(tableNoteMeta, {
          NoteMetaFields.uuid: gone,
          NoteMetaFields.deleted: 1,
          NoteMetaFields.payload: null,
          NoteMetaFields.updatedAt: DateTime.now().millisecondsSinceEpoch,
          NoteMetaFields.synced: 0,
        }, conflictAlgorithm: ConflictAlgorithm.replace);

        final withTomb = await database.readAllNoteMetaIncludingTombstones();
        expect(withTomb[alive]?.pinned, isTrue);
        expect(withTomb[gone]?.deleted, isTrue);

        final activeOnly = await database.readAllNoteMeta();
        expect(activeOnly.containsKey(gone), isFalse);
        expect(activeOnly[alive]?.pinned, isTrue);
      },
    );

    test('mergeRemoteNoteMetas：远端胜出写入且 synced=1；本地新/相等跳过', () async {
      const uuid = 'lww-1';
      // 本地已有较新条目
      final localNew = await database.upsertNoteMeta(
        _metaAt(uuid, pinned: true, updatedAt: 2000),
      );
      expect(localNew.synced, isFalse);

      var applied = await database.mergeRemoteNoteMetas([
        _metaAt(uuid, pinned: false, updatedAt: 1000), // 更旧 → 跳过
        _metaAt('fresh-1', archived: true, updatedAt: 3000), // 缺失 → 插入
      ]);
      expect(applied, 1);

      // 相等时间戳 → 跳过（保留本地）
      applied = await database.mergeRemoteNoteMetas([
        _metaAt(uuid, pinned: true, updatedAt: 2000),
      ]);
      expect(applied, 0);

      // 远端更新 → 覆盖
      applied = await database.mergeRemoteNoteMetas([
        _metaAt(uuid, pinned: false, tags: ['from-remote'], updatedAt: 5000),
      ]);
      expect(applied, 1);

      final merged = await database.getNoteMeta(uuid);
      expect(merged!.pinned, isFalse);
      expect(merged.tags, ['from-remote']);
      expect(merged.synced, isTrue, reason: '远端胜出写入应视为已对齐');
      expect(merged.updatedAt, 5000);

      final fresh = await database.getNoteMeta('fresh-1');
      expect(fresh!.archived, isTrue);
      expect(fresh.synced, isTrue);
    });

    test('mergeRemoteNoteMetas：墓碑应用擦 payload 且 UI 视角不可见', () async {
      const uuid = 'tomb-merge-1';
      await database.setNoteTags(uuid, ['sensitive-tag']);

      await database.mergeRemoteNoteMetas([
        NoteMeta(
          uuid: uuid,
          deleted: true,
          updatedAt: DateTime.now().millisecondsSinceEpoch + 10000,
        ),
      ]);

      // 行保留为墓碑、payload 擦除
      final rows = await (await NotesDatabase.instance.database).query(
        tableNoteMeta,
        where: '${NoteMetaFields.uuid} = ?',
        whereArgs: [uuid],
      );
      expect(rows.length, 1);
      expect(rows.first[NoteMetaFields.deleted], 1);
      expect(rows.first[NoteMetaFields.payload], isNull);
      expect(rows.first[NoteMetaFields.synced], 1);

      // UI 读路径（readAllNoteMeta / getNoteMeta）不可见
      expect(await database.getNoteMeta(uuid), isNull);
      expect((await database.readAllNoteMeta()).containsKey(uuid), isFalse);
    });

    test('markNoteMetasSynced 条件保护：上传期间再改动不误标 synced', () async {
      const uuid = 'cond-1';
      final written = await database.setNoteTags(uuid, ['v1']);
      // 模拟「快照后用户又改」：updatedAt 前进
      // 等待确保 updatedAt 严格递增（同毫秒内两次写入会导致 WHERE 条件误命中）
      await Future.delayed(const Duration(milliseconds: 5));
      await database.setNoteTags(uuid, ['v2']);

      // M-1 回归锚点：先建立 _metaCache，让后续读走缓存命中路径——
      // 修复前 markNoteMetasSynced 只写 DB 不刷缓存，此断言会读到脏缓存
      await database.readAllNoteMeta();

      // 用旧快照标记 → 不应命中 v2 行
      await database.markNoteMetasSynced([written]);
      final meta = await database.getNoteMeta(uuid);
      expect(meta!.synced, isFalse, reason: '改动晚于快照，必须保持脏标记');
      expect(
        (await database.readAllNoteMeta())[uuid]!.synced,
        isFalse,
        reason: '缓存层同样不得误标',
      );

      // 用最新快照标记 → DB 与缓存都命中
      await database.markNoteMetasSynced([meta]);
      expect((await database.getNoteMeta(uuid))!.synced, isTrue);
      expect(
        (await database.readAllNoteMeta())[uuid]!.synced,
        isTrue,
        reason: 'markNoteMetasSynced 必须同步刷新 _metaCache（M-1）',
      );
    });

    test('purgeReportedNoteMetaTombstones 只删已上报墓碑', () async {
      Future<void> insertRow(String uuid, {required bool deleted}) async {
        await (await NotesDatabase.instance.database).insert(tableNoteMeta, {
          NoteMetaFields.uuid: uuid,
          NoteMetaFields.deleted: deleted ? 1 : 0,
          NoteMetaFields.payload: null,
          NoteMetaFields.updatedAt: DateTime.now().millisecondsSinceEpoch,
          NoteMetaFields.synced: 0,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }

      // 未上报墓碑（synced=0）：GC 必须保留
      await insertRow('tomb-pending', deleted: true);
      // 已上报墓碑（synced=1）：GC 目标
      await (await NotesDatabase.instance.database).insert(tableNoteMeta, {
        NoteMetaFields.uuid: 'tomb-reported',
        NoteMetaFields.deleted: 1,
        NoteMetaFields.payload: null,
        NoteMetaFields.updatedAt: DateTime.now().millisecondsSinceEpoch,
        NoteMetaFields.synced: 1,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      // 活跃已同步行：绝不能删
      await insertRow('alive', deleted: false);
      await database.markNoteMetasSynced([
        await database.readAllNoteMetaIncludingTombstones().then(
          (m) => m['alive']!,
        ),
      ]);

      final purged = await database.purgeReportedNoteMetaTombstones();
      expect(purged, 1);

      final all = await database.readAllNoteMetaIncludingTombstones();
      expect(all.containsKey('tomb-pending'), isTrue);
      expect(all.containsKey('alive'), isTrue);
      expect(all.containsKey('tomb-reported'), isFalse);
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
