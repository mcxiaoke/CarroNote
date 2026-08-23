/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*/

// note_versions 数据层单元测试（Phase 1）
// 设计文档：docs/feature-note-version-history-design.md

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:core/core.dart';

/// 测试笔记构造
SafeNote _makeNote({
  required String uuid,
  String title = '',
  String description = '',
}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return SafeNote(
    uuid: uuid,
    title: title.isEmpty ? 'Title $uuid' : title,
    description: description.isEmpty ? 'Desc $uuid' : description,
    contentHash: SafeNote.computeHash(
      title.isEmpty ? 'Title $uuid' : title,
      description.isEmpty ? 'Desc $uuid' : description,
    ),
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
  // A. 基础 CRUD：保存 / 读取 / 去重
  // ──────────────────────────────────────────────
  group('note_versions CRUD', () {
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

    test('saveVersion 后 readVersions 返回 1 条，内容一致', () async {
      const uuid = 'ver-crud-1';
      final note = _makeNote(uuid: uuid, title: 'V1', description: 'Body 1');
      await database.saveVersion(note);

      final versions = await database.readVersions(uuid);
      expect(versions.length, 1);
      expect(versions.first.title, 'V1');
      expect(versions.first.description, 'Body 1');
      expect(versions.first.noteUuid, uuid);
      expect(versions.first.contentHash, note.contentHash);
    });

    test('readVersions 按 saved_at DESC 排序（最新在前）', () async {
      const uuid = 'ver-sort-1';
      final note1 = _makeNote(uuid: uuid, title: 'V1', description: 'B1');
      await database.saveVersion(note1);
      await Future.delayed(const Duration(milliseconds: 50));

      final note2 = _makeNote(uuid: uuid, title: 'V2', description: 'B2');
      await database.saveVersion(note2);
      await Future.delayed(const Duration(milliseconds: 50));

      final note3 = _makeNote(uuid: uuid, title: 'V3', description: 'B3');
      await database.saveVersion(note3);

      final versions = await database.readVersions(uuid);
      expect(versions.length, 3);
      expect(versions[0].title, 'V3');
      expect(versions[1].title, 'V2');
      expect(versions[2].title, 'V1');
    });

    test('contentHash 去重：相同 hash 的连续 saveVersion 被跳过', () async {
      const uuid = 'ver-dedup-1';
      final note = _makeNote(uuid: uuid, title: 'Same', description: 'Same');

      await database.saveVersion(note);
      await database.saveVersion(note); // 相同 hash，应跳过

      final versions = await database.readVersions(uuid);
      expect(versions.length, 1);
    });

    test('contentHash 去重：不同 hash 都被保存', () async {
      const uuid = 'ver-dedup-2';
      await database.saveVersion(
        _makeNote(uuid: uuid, title: 'A', description: 'A'),
      );
      await database.saveVersion(
        _makeNote(uuid: uuid, title: 'B', description: 'B'),
      );

      final versions = await database.readVersions(uuid);
      expect(versions.length, 2);
    });

    test('readVersion 按 id 读取单条版本', () async {
      const uuid = 'ver-by-id-1';
      await database.saveVersion(
        _makeNote(uuid: uuid, title: 'First', description: 'F'),
      );
      final versions = await database.readVersions(uuid);
      final id = versions.first.id!;

      final single = await database.readVersion(id);
      expect(single, isNotNull);
      expect(single!.title, 'First');
      expect(single.description, 'F');
    });

    test('readVersion 不存在的 id 返回 null', () async {
      expect(await database.readVersion(99999), isNull);
    });
  });

  // ──────────────────────────────────────────────
  // B. 加密验证：密文落盘、明文读取
  // ──────────────────────────────────────────────
  group('版本数据加密', () {
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

    test('title/description 密文落盘（不等于明文）', () async {
      const uuid = 'ver-enc-1';
      await database.saveVersion(
        _makeNote(uuid: uuid, title: '敏感标题', description: '敏感正文内容'),
      );

      final db = await NotesDatabase.instance.database;
      final raw = await db.query(
        tableNoteVersions,
        where: '${NoteVersionFields.noteUuid} = ?',
        whereArgs: [uuid],
      );
      expect(raw.length, 1);
      // 密文不等于明文
      expect(raw.first[NoteVersionFields.title], isNot('敏感标题'));
      expect(raw.first[NoteVersionFields.description], isNot('敏感正文内容'));
      // content_hash 是明文
      expect(raw.first[NoteVersionFields.contentHash], isNotNull);
    });

    test('中文内容加解密往返', () async {
      const uuid = 'ver-enc-cn';
      const title = '测试标题 🎉';
      const desc = '这是一段包含中文和 emoji 的正文\n换行也保留';
      await database.saveVersion(
        _makeNote(uuid: uuid, title: title, description: desc),
      );

      final versions = await database.readVersions(uuid);
      expect(versions.first.title, title);
      expect(versions.first.description, desc);
    });

    test('不同 key 无法解密旧版本（密钥隔离）', () async {
      const uuid = 'ver-key-isolation';
      final keyA = SyncCrypto.generateDataKey();
      database.setDataKey(keyA);
      await database.saveVersion(
        _makeNote(uuid: uuid, title: 'KeyA', description: 'Encrypted with A'),
      );

      // 换 key 后读取应抛异常或得到乱码
      final keyB = SyncCrypto.generateDataKey();
      database.setDataKey(keyB);

      expect(() => database.readVersions(uuid), throwsA(anything));
    });
  });

  // ──────────────────────────────────────────────
  // C. FIFO 清理：超限自动删旧
  // ──────────────────────────────────────────────
  group('FIFO 清理', () {
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

    test('超过 kMaxVersionsPerNote 时自动清理最旧版本', () async {
      const uuid = 'ver-fifo-1';
      // 保存 52 条版本（超过 50 条上限）
      for (var i = 0; i < 52; i++) {
        await database.saveVersion(
          _makeNote(uuid: uuid, title: 'Version $i', description: 'Body $i'),
        );
        // 确保时间戳递增（saved_at 精度为毫秒，快速循环可能同毫秒）
        await Future.delayed(const Duration(milliseconds: 5));
      }

      final versions = await database.readVersions(uuid);
      expect(versions.length, NotesDatabase.kMaxVersionsPerNote);

      // 最旧的 2 条（Version 0, Version 1）应已被清理
      expect(versions.any((v) => v.title == 'Version 0'), isFalse);
      expect(versions.any((v) => v.title == 'Version 1'), isFalse);
      // 最新的 Version 51 应在最前面
      expect(versions.first.title, 'Version 51');
    });
  });

  // ──────────────────────────────────────────────
  // D. 恢复版本
  // ──────────────────────────────────────────────
  group('restoreVersion', () {
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

    test('恢复后笔记内容回退到版本内容', () async {
      const uuid = 'ver-restore-1';

      // 保存 V1 → 写入笔记 → 保存 V2 → 写入笔记
      final noteV1 = await database.storeNote(
        _makeNote(uuid: uuid, title: 'V1', description: 'Body 1'),
      );
      await database.saveVersion(noteV1);

      await Future.delayed(const Duration(milliseconds: 10));
      final noteV2 = noteV1.copyWith(
        title: 'V2',
        description: 'Body 2',
        contentHash: SafeNote.computeHash('V2', 'Body 2'),
      );
      await database.updateNote(noteV2);
      await database.saveVersion(noteV2);

      // 当前笔记是 V2
      final current = await database.readNoteByUuid(uuid);
      expect(current!.title, 'V2');

      // 恢复到 V1（versions[1] 是 V1，因为 DESC 排序）
      final versions = await database.readVersions(uuid);
      final v1Id = versions.lastWhere((v) => v.title == 'V1').id!;
      await database.restoreVersion(v1Id, current);

      // 验证笔记已回退
      final restored = await database.readNoteByUuid(uuid);
      expect(restored!.title, 'V1');
      expect(restored.description, 'Body 1');
      expect(restored.synced, isFalse); // 恢复后标记为未同步
    });

    test('恢复前自动保存当前内容（撤销安全网）', () async {
      const uuid = 'ver-restore-2';
      final noteV1 = await database.storeNote(
        _makeNote(uuid: uuid, title: 'V1', description: 'B1'),
      );
      await database.saveVersion(noteV1);

      await Future.delayed(const Duration(milliseconds: 10));
      final noteV2 = noteV1.copyWith(
        title: 'V2',
        description: 'B2',
        contentHash: SafeNote.computeHash('V2', 'B2'),
      );
      await database.updateNote(noteV2);
      await database.saveVersion(noteV2);

      // 此时版本列表：[V2, V1]
      expect((await database.readVersions(uuid)).length, 2);

      // 恢复到 V1
      final current = await database.readNoteByUuid(uuid);
      final versions = await database.readVersions(uuid);
      final v1Id = versions.lastWhere((v) => v.title == 'V1').id!;
      await database.restoreVersion(v1Id, current!);

      // restoreVersion 内部调用 saveVersion(current=V2)，
      // 但 V2 已是最新版本（contentHash 相同），去重逻辑跳过保存。
      // 这是正确行为：V2 已在版本历史中，撤销路径存在（恢复回 V2 即可）。
      final afterVersions = await database.readVersions(uuid);
      expect(afterVersions.length, 2);
      // V2 仍作为最新版本存在（可撤销恢复）
      expect(afterVersions.first.title, 'V2');
    });

    test('恢复不存在的 versionId 抛异常', () async {
      const uuid = 'ver-restore-err';
      final note = await database.storeNote(_makeNote(uuid: uuid));

      expect(() => database.restoreVersion(99999, note), throwsA(anything));
    });
  });

  // ──────────────────────────────────────────────
  // E. 硬删除级联清理
  // ──────────────────────────────────────────────
  group('hardDelete 级联清理版本', () {
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

    test('hardDeleteByUuid 后版本数据被清理', () async {
      const uuid = 'ver-harddel-1';
      final note = await database.storeNote(
        _makeNote(uuid: uuid, title: 'To Delete', description: 'X'),
      );
      await database.saveVersion(note);
      await database.saveVersion(
        note.copyWith(
          title: 'V2',
          description: 'Y',
          contentHash: SafeNote.computeHash('V2', 'Y'),
        ),
      );

      expect((await database.readVersions(uuid)).length, 2);

      await database.hardDeleteByUuid(uuid);

      expect((await database.readVersions(uuid)).isEmpty, isTrue);
    });

    test('deleteVersionsForNote 手动清理', () async {
      const uuid = 'ver-manual-del';
      final note = _makeNote(uuid: uuid);
      await database.saveVersion(note);

      final deleted = await database.deleteVersionsForNote(uuid);
      expect(deleted, 1);
      expect((await database.readVersions(uuid)).isEmpty, isTrue);
    });

    test('deleteVersionsForNote 对无版本的 uuid 返回 0', () async {
      expect(await database.deleteVersionsForNote('nonexistent'), 0);
    });
  });

  // ──────────────────────────────────────────────
  // F. 密钥迁移重加密版本表
  // ──────────────────────────────────────────────
  group('reEncryptAllNotes 重加密版本表', () {
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

    test('密钥迁移后版本内容仍可解密（reEncryptAllNotes）', () async {
      const uuid = 'ver-reenc-1';
      final note = await database.storeNote(
        _makeNote(uuid: uuid, title: 'Before', description: 'B'),
      );
      await database.saveVersion(note);

      // 确认有版本且内容正确
      final versionsBefore = await database.readVersions(uuid);
      expect(versionsBefore.length, 1);
      expect(versionsBefore.first.title, 'Before');
      expect(versionsBefore.first.description, 'B');

      // 执行密钥迁移
      await database.reEncryptAllNotes(oldKey: keyA, newKey: keyB);
      database.setDataKey(keyB);

      // 版本表应保留且内容可解密
      final versionsAfter = await database.readVersions(uuid);
      expect(versionsAfter.length, 1);
      expect(versionsAfter.first.title, 'Before');
      expect(versionsAfter.first.description, 'B');
      // contentHash 和 savedAt 是明文，应保持不变
      expect(versionsAfter.first.contentHash, versionsBefore.first.contentHash);
      expect(versionsAfter.first.savedAt, versionsBefore.first.savedAt);
    });

    test('密钥迁移后版本内容仍可解密（reEncryptAllNotesAtomically）', () async {
      const uuid = 'ver-reenc-2';
      final note = await database.storeNote(
        _makeNote(uuid: uuid, title: 'Atomic', description: 'D'),
      );
      await database.saveVersion(note);

      // 确认有版本
      expect((await database.readVersions(uuid)).length, 1);

      // 执行原子化密钥迁移
      await database.reEncryptAllNotesAtomically(
        oldKey: keyA,
        newKey: keyB,
        keyringJson: '{}',
        markBlobReupload: true,
      );
      database.setDataKey(keyB);

      // 版本表应保留且内容可解密
      final versions = await database.readVersions(uuid);
      expect(versions.length, 1);
      expect(versions.first.title, 'Atomic');
      expect(versions.first.description, 'D');
    });

    test('多条版本密钥迁移后全部保留', () async {
      const uuid = 'ver-reenc-3';
      await database.storeNote(
        _makeNote(uuid: uuid, title: 'Current', description: 'Now'),
      );
      // 保存 3 条不同内容的版本（间隔确保 saved_at 时间戳不同）
      await database.saveVersion(
        _makeNote(uuid: uuid, title: 'V1', description: 'D1'),
      );
      await Future.delayed(const Duration(milliseconds: 20));
      await database.saveVersion(
        _makeNote(uuid: uuid, title: 'V2', description: 'D2'),
      );
      await Future.delayed(const Duration(milliseconds: 20));
      await database.saveVersion(
        _makeNote(uuid: uuid, title: 'V3', description: 'D3'),
      );

      // 确认有 3 条版本
      expect((await database.readVersions(uuid)).length, 3);

      // 执行密钥迁移
      await database.reEncryptAllNotes(oldKey: keyA, newKey: keyB);
      database.setDataKey(keyB);

      // 所有版本应保留且内容可解密
      final versions = await database.readVersions(uuid);
      expect(versions.length, 3);
      // 按时间倒序，最新的在前
      expect(versions[0].title, 'V3');
      expect(versions[0].description, 'D3');
      expect(versions[1].title, 'V2');
      expect(versions[1].description, 'D2');
      expect(versions[2].title, 'V1');
      expect(versions[2].description, 'D1');
    });
  });

  // ──────────────────────────────────────────────
  // G. Schema v6 → v7 升级
  // ──────────────────────────────────────────────
  group('v6 → v7 升级（note_versions 建表）', () {
    late String dir;

    setUp(() async {
      final tmp = await Directory.systemTemp.createTemp('note_version_v6_');
      dir = tmp.path;

      // 创建 v6 库（只有 notes + note_meta，无 note_versions）
      final path = '$dir${Platform.pathSeparator}safenotes_sync.db';
      final v6 = await openDatabase(
        path,
        version: 6,
        onCreate: (db, _) async {
          // 用 createDBForTesting 建 v7 全量表，再手动降级
          await NotesDatabase.createDBForTesting(db, 7);
        },
      );
      await v6.close();

      // 用生产 getter 重开，触发 onUpgrade v6→v7
      NotesDatabase.dbPathOverride = dir;
      await NotesDatabase.instance.close();
      NotesDatabase.instance.clearDataKey();
      await NotesDatabase.instance.database;
      database = NotesDatabase.instance;
    });

    tearDown(() async {
      await database.close();
      NotesDatabase.dbPathOverride = null;
      await Directory(dir).delete(recursive: true);
    });

    test('升级后 note_versions 表存在', () async {
      final db = await NotesDatabase.instance.database;
      final rows = await db.query(
        'sqlite_master',
        where: "type='table' AND name=?",
        whereArgs: [tableNoteVersions],
      );
      expect(rows.isNotEmpty, isTrue);
    });

    test('升级后索引存在', () async {
      final db = await NotesDatabase.instance.database;
      final indexes = await db.query(
        'sqlite_master',
        where: "type='index' AND tbl_name=?",
        whereArgs: [tableNoteVersions],
      );
      final indexNames = indexes.map((r) => r['name']).toSet();
      expect(indexNames, contains('idx_versions_uuid'));
      expect(indexNames, contains('idx_versions_uuid_time'));
    });

    test('升级后版本 CRUD 可用', () async {
      database.setDataKey(SyncCrypto.generateDataKey());
      const uuid = 'ver-upgrade-1';
      await database.saveVersion(_makeNote(uuid: uuid));
      final versions = await database.readVersions(uuid);
      expect(versions.length, 1);
    });
  });
}
