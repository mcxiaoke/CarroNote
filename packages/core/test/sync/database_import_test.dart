// storeNotesInTransaction uuid 幂等去重测试（导入备份回归）
//
// 背景：备份导入此前裸 INSERT，同一份备份「导出后再导回」会撞
// safe_notes.uuid 唯一约束（SQLITE_CONSTRAINT_UNIQUE）而整体回滚。
// 修复后按 uuid 去重：已存在（含墓碑）跳过，仅新增本地没有的。
// 纯 Dart 可跑，内存 FFI 库。

import 'package:test/test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:core/core.dart';

SafeNote _makeNote({
  required String uuid,
  String title = 'Test Title',
  String description = 'Test Description',
  bool deleted = false,
}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return SafeNote(
    uuid: uuid,
    title: title,
    description: description,
    contentHash: SafeNote.computeHash(title, description),
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

  group('storeNotesInTransaction uuid 幂等去重', () {
    test('首次导入全量写入，返回实际条数', () async {
      final notes = [
        _makeNote(uuid: 'u-1'),
        _makeNote(uuid: 'u-2'),
        _makeNote(uuid: 'u-3'),
      ];
      final inserted = await database.storeNotesInTransaction(notes);
      expect(inserted, 3);
      expect((await database.readAllNotes()).length, 3);
    });

    test('重复导入同一份备份：全部跳过，不抛 UNIQUE 冲突', () async {
      final notes = [
        _makeNote(uuid: 'u-1'),
        _makeNote(uuid: 'u-2'),
      ];
      expect(await database.storeNotesInTransaction(notes), 2);
      // 再次导入同一份 → 应全部跳过返回 0，而不是抛 DatabaseException
      expect(await database.storeNotesInTransaction(notes), 0);
      expect((await database.readAllNotes()).length, 2);
    });

    test('混合场景：已存在的跳过，其余新增', () async {
      final first = _makeNote(uuid: 'u-1', title: '本机标题');
      expect(await database.storeNotesInTransaction([first]), 1);

      final mixed = [
        _makeNote(uuid: 'u-1', title: '备份里的新标题'),
        _makeNote(uuid: 'u-2'),
        _makeNote(uuid: 'u-3'),
      ];
      final inserted = await database.storeNotesInTransaction(mixed);
      expect(inserted, 2); // 仅 u-2、u-3
      expect((await database.readAllNotes()).length, 3);
      // 已存在的笔记不被覆盖：仍是首次导入的内容
      final kept = await database.readNoteByUuid('u-1');
      expect(kept?.title, '本机标题');
    });

    test('墓碑也占 uuid：同 uuid 已删除的笔记同样跳过', () async {
      final tomb = _makeNote(uuid: 'u-1', deleted: true);
      expect(await database.storeNotesInTransaction([tomb]), 1);
      // 墓碑不载入 readAllNotes，但 uuid 仍占用唯一键
      expect((await database.readAllNotes()).length, 0);
      final alive = _makeNote(uuid: 'u-1');
      expect(await database.storeNotesInTransaction([alive]), 0);
    });
  });
}