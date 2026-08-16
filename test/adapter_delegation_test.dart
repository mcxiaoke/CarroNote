// 委托测试：NotesDatabaseRepository / NotesDbAdminAdapter 到达真实 SQLite
//
// 背景：P3 重构给 NotesDatabase 和 NotesDbAdmin 包了一层 ChangeNotifier 接口
// 适配器（NotesDatabaseRepository / NotesDbAdminAdapter），所有方法直接委托
// 给 NotesDatabase.instance。本测试用内存 SQLite 做 round-trip 验证：
//   - 委托确实到达真实 DB（若注入一个未缝合的假实现，CRUD 会失败）
//   - 接口方法的签名与真实 DB 一致（不会漏参数/错类型）
//
// 用 `flutter test` 运行：走内存 FFI SQLite（sqflite_common_ffi），不依赖
// 平台通道，也不绑定真实文件。

import 'package:core/core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:safenotes/data/db_admin_port.dart';
import 'package:safenotes/data/note_repository.dart';

/// 构造一条测试笔记。
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

  late NotesDatabaseRepository repo;
  late NotesDbAdminAdapter admin;
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

    repo = NotesDatabaseRepository();
    admin = NotesDbAdminAdapter();
  });

  tearDown(() async {
    await database.close();
  });

  group('NotesDatabaseRepository — CRUD 全流程', () {
    test(
      'storeNote → readNote → updateNote → softDelete → hardDelete',
      () async {
        final note = _makeNote(uuid: 'crud-1');
        final stored = await repo.storeNote(note);
        expect(stored.id, isNotNull);
        expect(stored.uuid, 'crud-1');

        final read = await repo.readNote(stored.id!);
        expect(read.uuid, 'crud-1');

        final updated = stored.copyWith(title: 'Updated Title');
        await repo.updateNote(updated);
        final readAgain = await repo.readNote(stored.id!);
        expect(readAgain.title, 'Updated Title');

        // 软删除
        await repo.softDelete(stored.id!);
        final deletedNotes = await repo.readDeletedNotes();
        expect(deletedNotes.map((n) => n.uuid), contains('crud-1'));
        // 正常笔记列表不应包含它
        final allNotes = await repo.readAllNotes();
        expect(allNotes.map((n) => n.uuid), isNot(contains('crud-1')));

        // 恢复
        await repo.restoreNote(stored.id!);
        final afterRestore = await repo.readAllNotes();
        expect(afterRestore.map((n) => n.uuid), contains('crud-1'));

        // 硬删除
        await repo.hardDelete(stored.id!);
        expect(() => repo.readNote(stored.id!), throwsException);
      },
    );
  });

  group('NotesDatabaseRepository — 批量操作', () {
    test('storeNotesInTransaction 幂等去重', () async {
      final note1 = _makeNote(uuid: 'batch-1');
      final note2 = _makeNote(uuid: 'batch-2');

      await repo.storeNotesInTransaction([note1, note2]);
      expect(await repo.readAllNotes(), hasLength(2));

      // 相同 uuid 的笔记应跳过
      await repo.storeNotesInTransaction([note1]);
      expect(await repo.readAllNotes(), hasLength(2));
    });
  });

  group('NotesDatabaseRepository — 加密状态', () {
    test('setDataKey / clearDataKey / isEncryptionEnabled', () async {
      database.clearDataKey();
      expect(repo.isEncryptionEnabled, false);

      database.setDataKey(SyncCrypto.generateDataKey());
      expect(repo.isEncryptionEnabled, true);

      repo.clearDataKey();
      expect(repo.isEncryptionEnabled, false);
    });
  });

  group('NotesDbAdminAdapter', () {
    test('inspectMetadata 返回结构元数据', () async {
      final meta = await admin.inspectMetadata();
      expect(meta, isA<Map<String, dynamic>>());
      expect(meta.containsKey('tables'), isTrue);
    });

    test('exportAll 返回 JSON 字符串', () async {
      await repo.storeNote(_makeNote(uuid: 'export-1'));
      final exported = await admin.exportAll();
      expect(exported, isA<String>());
      expect(exported, contains('export-1'));
    });
  });
}
