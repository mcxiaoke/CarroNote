// hardDeleteAllDeleted 批量硬删除测试（回收站清空回归）
//
// 背景：回收站「清空」此前在 UI 层逐条 hardDelete，N 条笔记 = N 个事务。
// 改为单事务批量删除（删行 + purged 列表原子写入）后，验证：
//   - 只删软删除行，正常笔记保留
//   - purged 列表完整收集被删 uuid（防墓碑从远端复活）
//   - 空回收站幂等，返回 0
// 纯 Dart 可跑，内存 FFI 库。

import 'package:test/test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:core/core.dart';

SafeNote _makeNote({required String uuid, bool deleted = false}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return SafeNote(
    uuid: uuid,
    title: 'Title $uuid',
    description: 'Desc $uuid',
    contentHash: SafeNote.computeHash('Title $uuid', 'Desc $uuid'),
    deleted: deleted,
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

  group('hardDeleteAllDeleted 批量硬删除', () {
    test('只删软删除行，正常笔记保留，返回删除条数', () async {
      final notes = [
        _makeNote(uuid: 'keep-1'),
        _makeNote(uuid: 'del-1', deleted: true),
        _makeNote(uuid: 'keep-2'),
        _makeNote(uuid: 'del-2', deleted: true),
        _makeNote(uuid: 'del-3', deleted: true),
      ];
      await database.storeNotesInTransaction(notes);

      final deleted = await database.hardDeleteAllDeleted();
      expect(deleted, 3);

      final remain = await database.readAllNotes();
      expect(remain.length, 2);
      expect(remain.map((n) => n.uuid).toSet(), {'keep-1', 'keep-2'});
      // 回收站已空
      expect((await database.readDeletedNotes()).length, 0);
    });

    test('被删 uuid 全部进入 purged 列表（防远端复活）', () async {
      final notes = [
        _makeNote(uuid: 'keep-1'),
        _makeNote(uuid: 'del-1', deleted: true),
        _makeNote(uuid: 'del-2', deleted: true),
      ];
      await database.storeNotesInTransaction(notes);

      await database.hardDeleteAllDeleted();

      final purged = await database.getPurgedUuids();
      expect(purged.toSet(), {'del-1', 'del-2'});
    });

    test('空回收站调用幂等，返回 0', () async {
      await database.storeNotesInTransaction([_makeNote(uuid: 'keep-1')]);
      expect(await database.hardDeleteAllDeleted(), 0);
      expect((await database.readAllNotes()).length, 1);
    });
  });
}
