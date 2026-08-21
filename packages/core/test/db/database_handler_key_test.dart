/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*/

/*
 * 数据库层关键场景测试 (T2-T4)
 *
 * T2: 缓存一致性 — _applySyncedToCache 替换对象后旧引用失效
 * T3: updateNote vs updateNoteByUuid 对 syncedHash 的不同处理
 * T4: existsContentHash 含墓碑 — 冲突副本标题去重
 *
 * 运行：dart test packages/core/test/db/database_handler_key_test.dart
 */

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:core/core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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

  late NotesDatabase database;
  late Uint8List testDataKey;

  setUp(() async {
    final db = await openDatabase(
      ':memory:',
      version: 2,
      onCreate: NotesDatabase.createDBForTesting,
    );
    NotesDatabase.setDatabaseForTesting(db);
    database = NotesDatabase.instance;
    testDataKey = SyncCrypto.generateDataKey();
    database.setDataKey(testDataKey);
  });

  tearDown(() async {
    await database.close();
  });

  // ──────────────────────────────────────────────
  // T2: 缓存一致性 — _applySyncedToCache 替换对象后旧引用失效
  // ──────────────────────────────────────────────
  group('T2: 缓存一致性', () {
    test('markSyncedForUuids 后旧引用 synced=false，新引用 synced=true', () async {
      final note = _makeNote(uuid: 'uuid-t2-1', title: 'T2 Note');
      await database.storeNote(note);

      // 获取旧引用（synced=false）
      final oldNotes = await database.readAllNotes();
      final oldRef = oldNotes.first;
      expect(oldRef.synced, isFalse);

      // markSynced 更新缓存
      await database.markSyncedForUuids({'uuid-t2-1'});

      // 旧引用应仍为 synced=false（对象未被修改）
      expect(
        oldRef.synced,
        isFalse,
        reason: '旧引用应保持原值，_applySyncedToCache 创建新对象替换缓存',
      );

      // 新引用应 synced=true
      final newNotes = await database.readAllNotes();
      final newRef = newNotes.first;
      expect(newRef.synced, isTrue, reason: '新引用应反映 markSynced 后的状态');
      expect(identical(oldRef, newRef), isFalse, reason: '应是不同对象实例');
    });

    test('updateNoteByUuid 后缓存已替换', () async {
      final note = _makeNote(
        uuid: 'uuid-t2-2',
        title: 'Original',
        synced: true,
        syncedHash: 'hash-original',
      );
      await database.storeNote(note);

      // 获取旧引用
      final oldNotes = await database.readAllNotes();
      final oldRef = oldNotes.first;
      expect(oldRef.title, 'Original');

      // updateNoteByUuid 修改内容
      await database.updateNoteByUuid(
        note.copyWith(
          title: 'Updated',
          contentHash: SafeNote.computeHash('Updated', 'desc'),
        ),
      );

      // 新引用应反映更新
      final newNotes = await database.readAllNotes();
      final newRef = newNotes.first;
      expect(newRef.title, 'Updated', reason: '缓存应已替换为新内容');
      expect(identical(oldRef, newRef), isFalse);
    });
  });

  // ──────────────────────────────────────────────
  // T3: updateNote vs updateNoteByUuid 对 syncedHash 的不同处理
  // ──────────────────────────────────────────────
  // 两个方法在 SQL 层都写 synced_hash 列（_toEncryptedRow 序列化全部字段）。
  // 差异在于调用方：UI 路径(updateNote) 的 note 对象可能携带过时 syncedHash，
  // 同步路径(updateNoteByUuid) 的 note 对象始终由引擎从 manifest 构造，值正确。
  // editor_state.dart 的修复就是在调用 updateNote 前从 DB 读取最新 syncedHash。
  group('T3: updateNote vs updateNoteByUuid syncedHash 行为', () {
    test('updateNote 按 id 更新，写入 note 对象中的 syncedHash', () async {
      final stored = await database.storeNote(
        _makeNote(
          uuid: 'uuid-t3-1',
          title: 'T3 UI',
          synced: true,
          syncedHash: 'hash-v1',
        ),
      );

      // updateNote 写入新 syncedHash（模拟 editor_state 修复后的行为）
      await database.updateNote(
        stored.copyWith(
          title: 'T3 UI Modified',
          contentHash: SafeNote.computeHash('T3 UI Modified', 'desc'),
          synced: false,
          syncedHash: 'hash-v1', // 保留原始 base（修复后的正确行为）
        ),
      );

      final result = await database.readNoteByUuid('uuid-t3-1');
      expect(result!.synced, isFalse);
      expect(
        result.syncedHash,
        'hash-v1',
        reason: 'updateNote 写入 note 对象中的 syncedHash',
      );
    });

    test('updateNote 若传入旧 syncedHash 会覆盖 DB 中的新值（bug 复现）', () async {
      final stored = await database.storeNote(
        _makeNote(
          uuid: 'uuid-t3-2',
          title: 'T3 Bug',
          synced: true,
          syncedHash: 'hash-v1',
        ),
      );

      // 模拟同步引擎更新了 DB 中的 syncedHash
      await database.markSyncedForUuids({'uuid-t3-2'});
      final afterSync = await database.readNoteByUuid('uuid-t3-2');
      expect(
        afterSync!.syncedHash,
        afterSync.contentHash,
        reason: '同步后 syncedHash 应等于 contentHash',
      );

      // 模拟 bug：UI 路径传入过时的 syncedHash（original 持有旧值）
      await database.updateNote(
        stored.copyWith(
          title: 'T3 Bug Modified',
          contentHash: SafeNote.computeHash('T3 Bug Modified', 'desc'),
          synced: false,
          syncedHash: 'hash-v1', // 过时值！这就是 bug
        ),
      );

      final result = await database.readNoteByUuid('uuid-t3-2');
      expect(
        result!.syncedHash,
        'hash-v1',
        reason: '过时的 syncedHash 被写回 DB（这就是 bug 的根因）',
      );
      expect(
        result.syncedHash != result.contentHash,
        isTrue,
        reason: 'syncedHash ≠ contentHash 说明 base 被错误回退',
      );
    });

    test('updateNoteByUuid 按 uuid 更新，写入 note 对象中的 syncedHash', () async {
      await database.storeNote(
        _makeNote(
          uuid: 'uuid-t3-3',
          title: 'T3 Sync',
          synced: false,
          syncedHash: 'hash-old',
        ),
      );

      // updateNoteByUuid 写入新 syncedHash（同步引擎始终传入正确值）
      await database.updateNoteByUuid(
        _makeNote(
          uuid: 'uuid-t3-3',
          title: 'T3 Sync Modified',
          synced: true,
          syncedHash: 'hash-new',
        ),
      );

      final result = await database.readNoteByUuid('uuid-t3-3');
      expect(result!.synced, isTrue);
      expect(
        result.syncedHash,
        'hash-new',
        reason: 'updateNoteByUuid 写入 note 对象中的 syncedHash',
      );
    });
  });

  // ──────────────────────────────────────────────
  // T4: existsContentHash 含墓碑 — 冲突副本标题去重
  // ──────────────────────────────────────────────
  group('T4: existsContentHash 含墓碑', () {
    test('硬删除后 existsContentHash 仍返回 true（墓碑占位）', () async {
      final stored = await database.storeNote(
        _makeNote(
          uuid: 'uuid-t4-1',
          title: 'T4 Tombstone',
          synced: true,
          syncedHash: SafeNote.computeHash('T4 Tombstone', 'desc'),
        ),
      );

      // 软删除（墓碑）
      await database.softDelete(stored.id!);

      // existsContentHash 应返回 true（墓碑仍占位）
      final exists = await database.existsContentHash(stored.contentHash);
      expect(exists, isTrue, reason: '墓碑的 content_hash 仍应占位，防止冲突副本 hash 碰撞');
    });

    test('不存在的内容 hash 返回 false', () async {
      final exists = await database.existsContentHash('nonexistent-hash-12345');
      expect(exists, isFalse);
    });

    test('活跃笔记的 content_hash 返回 true', () async {
      final note = _makeNote(uuid: 'uuid-t4-3', title: 'Active Note');
      await database.storeNote(note);

      final exists = await database.existsContentHash(note.contentHash);
      expect(exists, isTrue);
    });

    test('不同内容的笔记有不同的 content_hash', () async {
      final note1 = _makeNote(uuid: 'uuid-t4-4a', title: 'Title A');
      final note2 = _makeNote(uuid: 'uuid-t4-4b', title: 'Title B');
      await database.storeNote(note1);
      await database.storeNote(note2);

      expect(note1.contentHash != note2.contentHash, isTrue);
      expect(await database.existsContentHash(note1.contentHash), isTrue);
      expect(await database.existsContentHash(note2.contentHash), isTrue);
    });
  });

  // ──────────────────────────────────────────────
  // T5: markSyncedForUuids 数据库层直接单元测试
  // ──────────────────────────────────────────────
  group('T5: markSyncedForUuids 直接单元测试', () {
    test('空集合跳过', () async {
      // 不应抛异常
      await database.markSyncedForUuids({});
      // 验证无副作用
      final notes = await database.readAllNotes();
      expect(notes, isEmpty);
    });

    test('不存在的 uuid 不影响其他笔记', () async {
      final note = _makeNote(uuid: 'uuid-t5-1', title: 'T5 Real');
      await database.storeNote(note);

      await database.markSyncedForUuids({'uuid-t5-1', 'nonexistent-uuid'});

      final result = await database.readNoteByUuid('uuid-t5-1');
      expect(result!.synced, isTrue);
      expect(
        result.syncedHash,
        result.contentHash,
        reason: 'markSynced 后 synced_hash 应等于 content_hash',
      );
    });

    test('部分匹配只标记匹配的', () async {
      final note1 = _makeNote(uuid: 'uuid-t5-2a', title: 'T5 A');
      final note2 = _makeNote(uuid: 'uuid-t5-2b', title: 'T5 B');
      await database.storeNote(note1);
      await database.storeNote(note2);

      await database.markSyncedForUuids({'uuid-t5-2a'});

      final r1 = await database.readNoteByUuid('uuid-t5-2a');
      final r2 = await database.readNoteByUuid('uuid-t5-2b');
      expect(r1!.synced, isTrue, reason: '匹配的应被标记');
      expect(r2!.synced, isFalse, reason: '未匹配的应保持原状');
    });

    test('幂等性：多次调用结果一致', () async {
      final note = _makeNote(uuid: 'uuid-t5-3', title: 'T5 Idempotent');
      await database.storeNote(note);

      await database.markSyncedForUuids({'uuid-t5-3'});
      await database.markSyncedForUuids({'uuid-t5-3'});

      final result = await database.readNoteByUuid('uuid-t5-3');
      expect(result!.synced, isTrue);
      expect(result.syncedHash, result.contentHash);
    });

    test('synced_hash 设为 content_hash，synced_deleted 设为 deleted', () async {
      final note = _makeNote(
        uuid: 'uuid-t5-4',
        title: 'T5 Hash Check',
        deleted: false,
      );
      await database.storeNote(note);

      await database.markSyncedForUuids({'uuid-t5-4'});

      final result = await database.readNoteByUuid('uuid-t5-4');
      expect(
        result!.syncedHash,
        result.contentHash,
        reason: 'synced_hash 应等于 content_hash',
      );
      expect(result.syncedDeleted, false, reason: 'synced_deleted 应等于 deleted');
    });
  });
}
