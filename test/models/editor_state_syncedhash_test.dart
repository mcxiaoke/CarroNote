/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under
* the terms of the GPL-3.0+ license.
*/

// T1: editor_state syncedHash 刷新测试
//
// 验证修复后的 updateNote() 在编辑期间同步引擎更新了 syncedHash 后，
// 保存时使用 DB 中的最新值而非 original 静态引用中的旧值。
//
// 背景：NoteEditorState.original 是静态变量，编辑期间不会被同步引擎更新。
// 修复前：copyWith 沿用 original.syncedHash → 回退 DB 正确 base → 虚假冲突。
// 修复后：保存前 readNoteByUuid 获取最新 syncedHash。

import 'package:flutter_test/flutter_test.dart';
import 'package:core/core.dart';

import 'package:safenotes/models/editor_state.dart';
import '../test_helpers.dart';

void main() {
  setUpAll(() async {
    await initFullEnv();
  });

  setUp(() async {
    await prepareUnlockedVault(
      seeds: [(title: 'Test Note', description: 'Original content')],
    );
  });

  tearDown(() async {
    NoteEditorState.destroyValue();
    await disposeVault();
  });

  test('T1-a: 编辑期间 syncedHash 被同步引擎更新后，updateNote 使用 fresh 值', () async {
    // 1. 读取刚创建的笔记（syncedHash 为 null，尚未同步）
    final notes = await NotesDatabase.instance.readAllNotes();
    expect(notes.length, 1);
    var note = notes.first;
    expect(note.syncedHash, isNull);

    // 2. 模拟同步完成：markSyncedForUuids 把 syncedHash 设为 contentHash
    await NotesDatabase.instance.markSyncedForUuids({note.uuid});
    note = (await NotesDatabase.instance.readNoteByUuid(note.uuid))!;
    final syncedHashAfterSync = note.syncedHash;
    expect(syncedHashAfterSync, isNotNull);
    expect(syncedHashAfterSync, note.contentHash);

    // 3. 模拟用户进入编辑器：setState 设置 original（此时 original.syncedHash 是最新值）
    NoteEditorState.setState(note, 'Test Note', 'Original content');
    expect(NoteEditorState.original!.syncedHash, syncedHashAfterSync);

    // 4. 模拟编辑期间再次同步（例如另一端编辑后同步收敛，syncedHash 变化）
    // 直接通过 updateNoteByUuid 模拟 syncedHash 被同步引擎更新为新收敛值
    final newConvergedHash = 'new_converged_hash_value_abc123';
    final updated = note.copyWith(
      contentHash: newConvergedHash,
      syncedHash: newConvergedHash,
      synced: true,
    );
    await NotesDatabase.instance.updateNoteByUuid(updated);

    // 验证 DB 中 syncedHash 已更新
    final dbNote = await NotesDatabase.instance.readNoteByUuid(note.uuid);
    expect(dbNote!.syncedHash, newConvergedHash);

    // 5. 此时 original.syncedHash 仍是旧值（模拟编辑期间不刷新）
    expect(NoteEditorState.original!.syncedHash, isNot(newConvergedHash));

    // 6. 用户编辑内容并保存
    NoteEditorState.title = 'Edited Title';
    NoteEditorState.description = 'Edited content';
    await NoteEditorState().updateNote();

    // 7. 验证保存后的笔记使用了 fresh syncedHash，而非 original 的旧值
    final saved = await NotesDatabase.instance.readNoteByUuid(note.uuid);
    expect(saved, isNotNull);
    expect(
      saved!.syncedHash,
      newConvergedHash,
      reason: 'updateNote 应使用 DB 中最新的 syncedHash，而非 original 中的旧值',
    );
    expect(saved.synced, false, reason: '编辑后 synced 应为 false（本地有未同步变更）');
  });

  test('T1-b: 编辑期间无同步发生时，updateNote 行为不变', () async {
    // 1. 创建笔记并同步
    final notes = await NotesDatabase.instance.readAllNotes();
    expect(notes.length, 1);
    var note = notes.first;

    await NotesDatabase.instance.markSyncedForUuids({note.uuid});
    note = (await NotesDatabase.instance.readNoteByUuid(note.uuid))!;
    final originalSyncedHash = note.syncedHash;

    // 2. 进入编辑器（无编辑期间同步）
    NoteEditorState.setState(note, 'Test Note', 'Original content');

    // 3. 编辑并保存
    NoteEditorState.title = 'New Title';
    NoteEditorState.description = 'New content';
    await NoteEditorState().updateNote();

    // 4. syncedHash 应保持不变（无同步发生）
    final saved = await NotesDatabase.instance.readNoteByUuid(note.uuid);
    expect(saved!.syncedHash, originalSyncedHash);
    expect(saved.synced, false);
  });

  test('T1-c: 笔记从未同步过（syncedHash=null）时，updateNote 正常工作', () async {
    // 1. 笔记刚创建，从未同步
    final notes = await NotesDatabase.instance.readAllNotes();
    expect(notes.length, 1);
    final note = notes.first;
    expect(note.syncedHash, isNull);

    // 2. 进入编辑器
    NoteEditorState.setState(note, 'Test Note', 'Original content');

    // 3. 编辑并保存
    NoteEditorState.title = 'Updated';
    NoteEditorState.description = 'Updated content';
    await NoteEditorState().updateNote();

    // 4. syncedHash 仍为 null（无同步基线）
    final saved = await NotesDatabase.instance.readNoteByUuid(note.uuid);
    expect(saved!.syncedHash, isNull);
    expect(saved.synced, false);
  });
}
