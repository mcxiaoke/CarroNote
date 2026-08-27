/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*/

/*
 * M1 解密失败容错测试
 *
 * 背景（见 database_handler.dart M1 注释）：notes 表无降级容错，此前任何一行
 * 解密失败都会让整个查询抛异常（整库"不可读"）。
 *
 * 设计：
 *  - 单行失败（隔离损坏，低于阈值）→ 原始删除该行（云端/备份自愈兜底），
 *    健康行正常返回；
 *  - 多条失败（达到阈值
 *    `(broken >= 10 || (broken >= 3 && broken*10 >= total) || broken == total)`）
 *    → 判定系统性故障，抛 [MassDecryptionFailureException]，**不删除任何行**，
 *    由 UI 强提示用户（可能密码错误 / 整库损坏）。
 *    其中 `broken == total` 覆盖超小库（1/1、2/2）全损：全损必为系统性，
 *    防错误 key 下被误判为隔离损坏而悄悄删光。
 *
 * 运行：dart test packages/core/test/db/m1_decrypt_failure_test.dart
 */

import 'dart:convert';
import 'dart:typed_data';

import 'package:core/core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';

/// 直接用生产加密格式（base64(SyncCrypto.seal(dataKey, uuid, plaintext))）
/// 构造加密行，跳过 storeNote 的缓存副作用，保证首次 read 走全量缓存重建，
/// 从而让解密守卫在同一批数据上生效。
Future<String> _enc(String uuid, String plain, Uint8List key) async {
  if (plain.isEmpty) return '';
  final bytes = Uint8List.fromList(utf8.encode(plain));
  return base64.encode(await SyncCrypto.seal(key, uuid, bytes));
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

  /// 直接插入一行；[title]/[desc] 传最终入库值（健康行传加密串，坏行传坏串）。
  Future<void> insertRow(
    String uuid, {
    required String title,
    required String desc,
  }) async {
    final db = await database.database;
    await db.insert(tableNotes, {
      NoteFields.uuid: uuid,
      NoteFields.title: title,
      NoteFields.description: desc,
      NoteFields.contentHash: 'hash-$uuid',
      NoteFields.deleted: 0,
      NoteFields.createdAt: '2026-01-01 00:00:00',
      NoteFields.updatedAt: 1,
      NoteFields.synced: 0,
      NoteFields.syncedHash: null,
      NoteFields.syncedDeleted: 0,
    });
  }

  Future<void> insertHealthy(String uuid, String title, String desc) async {
    await insertRow(
      uuid,
      title: await _enc(uuid, title, testDataKey),
      desc: await _enc(uuid, desc, testDataKey),
    );
  }

  /// 坏行：title 为非法 base64，解密时 base64 解码即抛异常（确定性失败）。
  Future<void> insertBroken(String uuid) async {
    await insertRow(
      uuid,
      title: '%%%invalid-base64%%%',
      desc: '%%%invalid-base64%%%',
    );
  }

  Future<int> countRows() async {
    final db = await database.database;
    final rows = await db.query(tableNotes, columns: [NoteFields.uuid]);
    return rows.length;
  }

  Future<bool> rowExists(String uuid) async {
    final db = await database.database;
    final rows = await db.query(
      tableNotes,
      columns: [NoteFields.uuid],
      where: '${NoteFields.uuid} = ?',
      whereArgs: [uuid],
    );
    return rows.isNotEmpty;
  }

  // ──────────────────────────────────────────────
  // 隔离损坏（单行 / 少数）：删除 + 健康行返回
  // ──────────────────────────────────────────────
  test('单行失败（1/2）：原始删除坏行 + 健康行正常返回', () async {
    await insertHealthy('u-good', 'Good', 'desc-good');
    await insertBroken('u-bad');

    final notes = await database.readAllNotes();

    expect(notes.map((n) => n.uuid), ['u-good']);
    expect(await rowExists('u-bad'), isFalse, reason: '坏行应被原始删除');
  });

  test('阈值以下（2/20，占比 10% 但数量 <3）：删除坏行不抛异常', () async {
    for (var i = 0; i < 18; i++) {
      await insertHealthy('h-$i', 'H$i', 'd$i');
    }
    await insertBroken('b-1');
    await insertBroken('b-2');

    final notes = await database.readAllNotes();

    expect(notes.length, 18);
    expect(await rowExists('b-1'), isFalse);
    expect(await rowExists('b-2'), isFalse);
  });

  // ──────────────────────────────────────────────
  // 系统性故障（达到阈值）：抛异常，不删除
  // ──────────────────────────────────────────────
  test('绝对阈值（12/12 >= 10）：抛 MassDecryptionFailureException，不删除', () async {
    for (var i = 0; i < 12; i++) {
      await insertBroken('mass-$i');
    }

    await expectLater(
      database.readAllNotes(),
      throwsA(isA<MassDecryptionFailureException>()),
    );

    expect(await countRows(), 12, reason: '系统性失败不得删除任何行');
  });

  test('相对阈值边界（3/30 = 10%）：抛 MassDecryptionFailureException，不删除', () async {
    for (var i = 0; i < 27; i++) {
      await insertHealthy('h-$i', 'H$i', 'd$i');
    }
    await insertBroken('b-1');
    await insertBroken('b-2');
    await insertBroken('b-3');

    await expectLater(
      database.readAllNotes(),
      throwsA(isA<MassDecryptionFailureException>()),
    );

    expect(await countRows(), 30, reason: '系统性失败不得删除任何行');
    expect(await rowExists('b-1'), isTrue);
    expect(await rowExists('b-2'), isTrue);
    expect(await rowExists('b-3'), isTrue);
  });

  test('全损 1/1（超小库密码错误）：抛 MassDecryptionFailureException，不删除', () async {
    await insertBroken('only-bad');

    await expectLater(
      database.readAllNotes(),
      throwsA(isA<MassDecryptionFailureException>()),
    );

    expect(await rowExists('only-bad'), isTrue, reason: '全损=系统性，不得删除');
  });

  test('全损 2/2（超小库密码错误）：抛 MassDecryptionFailureException，不删除', () async {
    await insertBroken('b-1');
    await insertBroken('b-2');

    await expectLater(
      database.readAllNotes(),
      throwsA(isA<MassDecryptionFailureException>()),
    );

    expect(await countRows(), 2, reason: '全损=系统性，不得删除任何行');
    expect(await rowExists('b-1'), isTrue);
    expect(await rowExists('b-2'), isTrue);
  });

  // ──────────────────────────────────────────────
  // 单行读取（readNoteByUuid）：失败 → 删除 + 返回 null
  // ──────────────────────────────────────────────
  test('readNoteByUuid 命中坏行：删除并返回 null（视为不存在）', () async {
    await insertHealthy('u-good', 'Good', 'desc');
    await insertBroken('u-bad');

    final note = await database.readNoteByUuid('u-bad');

    expect(note, isNull);
    expect(await rowExists('u-bad'), isFalse);
    // 健康行不受影响
    expect((await database.readNoteByUuid('u-good'))?.title, 'Good');
  });

  test('readNoteByUuid 未命中：返回 null 且无任何副作用', () async {
    await insertHealthy('u-good', 'Good', 'desc');
    expect(await database.readNoteByUuid('no-such'), isNull);
    expect(await rowExists('u-good'), isTrue);
  });

  // ──────────────────────────────────────────────
  // 缓存一致性：删除坏行后 _notesCache 不残留幽灵行
  // ──────────────────────────────────────────────
  test('缓存一致性：删除坏行后 _notesCache 不残留幽灵行', () async {
    // 1. 先构建缓存（含 u-bad）
    await insertHealthy('u-bad', 'Good', 'desc');
    await insertHealthy('u-keep', 'Keep', 'desc');
    expect((await database.readAllNotes()).length, 2);

    // 2. 绕过 API 直接把 u-bad 写成坏行（缓存不失效）
    final db = await database.database;
    await db.update(
      tableNotes,
      {NoteFields.title: '%%%invalid-base64%%%'},
      where: '${NoteFields.uuid} = ?',
      whereArgs: ['u-bad'],
    );

    // 3. 单行守卫删除 u-bad 并同步移除缓存条目
    expect(await database.readNoteByUuid('u-bad'), isNull);
    expect(await rowExists('u-bad'), isFalse);

    // 4. 命中缓存的全量读取不得"复活"幽灵行（_removeCacheEntry 生效）
    final notes = await database.readAllNotesIncludingDeleted();
    expect(notes.map((n) => n.uuid), ['u-keep']);
  });
}
