/*
 * Copyright (C) mcxiaoke 2026 - All Rights Reserved.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 * You may use, distribute and modify this code under the
 * terms of the GPL-3.0+ license.
 */

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
      seeds: [(title: '原始笔记标题', description: '原始正文内容')],
    );
    NoteEditorState.destroyValue();
  });

  tearDown(() async {
    NoteEditorState.destroyValue();
    await disposeVault();
  });

  group('NoteEditorState 保存守卫与内容归一化', () {
    test('标题与正文均为空时不保存笔记且返回 null', () async {
      NoteEditorState.setState(null, '', '');

      final result = await NoteEditorState().addOrUpdateNote();
      expect(result.saved, isNull);
      expect(result.skipped, isFalse);

      final allNotes = await NotesDatabase.instance.readAllNotes();
      expect(allNotes.length, 1); // 仅原有 seed
    });

    test('仅输入标题时正文自动补空格归一化并成功保存新建笔记', () async {
      NoteEditorState.setState(null, '仅有标题', '');

      final result = await NoteEditorState().addOrUpdateNote(
        destroyAfter: false,
      );
      expect(result.saved, isNotNull);
      expect(result.saved!.title, '仅有标题');
      expect(result.saved!.description, ' ');

      final allNotes = await NotesDatabase.instance.readAllNotes();
      expect(allNotes.length, 2);
    });

    test('仅输入正文时标题自动补空格归一化并成功保存新建笔记', () async {
      NoteEditorState.setState(null, '', '仅有正文');

      final result = await NoteEditorState().addOrUpdateNote(
        destroyAfter: false,
      );
      expect(result.saved, isNotNull);
      expect(result.saved!.title, ' ');
      expect(result.saved!.description, '仅有正文');
    });

    test('修改已存在笔记但内容未发生变化时跳过保存并返回 null', () async {
      final originalNote = (await NotesDatabase.instance.readAllNotes()).first;
      NoteEditorState.setState(originalNote, '原始笔记标题', '原始正文内容');

      final result = await NoteEditorState().addOrUpdateNote();
      expect(result.saved, isNull);
      expect(result.skipped, isFalse);
    });

    test('destroyAfter: false 保留状态并将 original 更新为最新已保存笔记', () async {
      NoteEditorState.setState(null, '首次新建', '首次正文');

      // 首次保存（模拟后台自动保存）
      final first = await NoteEditorState().addOrUpdateNote(
        destroyAfter: false,
      );
      expect(first.saved, isNotNull);
      expect(NoteEditorState.original, isNotNull);
      expect(NoteEditorState.original!.uuid, first.saved!.uuid);

      // 再次编辑同一篇笔记（由于 original 已指向新笔记，这次将作为更新而非新建）
      NoteEditorState.title = '第二次修改';
      final second = await NoteEditorState().addOrUpdateNote(
        destroyAfter: true,
      );
      expect(second.saved, isNotNull);
      expect(second.saved!.uuid, first.saved!.uuid);
      expect(second.saved!.title, '第二次修改');

      // 数据库中总共应只有 2 条（1 条 seed + 1 条新建编辑后），绝不能产生重复插入
      final allNotes = await NotesDatabase.instance.readAllNotes();
      expect(allNotes.length, 2);
    });
  });

  group('P0-7 防重入跳过的等待与重试', () {
    test('在途保存持锁时返回 skipped，等待完成后可重试保存最新输入', () async {
      NoteEditorState.setState(null, '并发保存', '第一版内容');

      // 启动在途保存（不 await）：模拟周期/后台保存正持有锁。
      // 同步段立即读取当前内容并置位 _isSaving。
      final inFlight = NoteEditorState().addOrUpdateNote(destroyAfter: false);

      // 在途期间用户继续输入（模拟 T1..T2 的增量）
      NoteEditorState.title = '并发保存';
      NoteEditorState.description = '用户最新的第二版内容';

      // 退出保存触发：此刻被防重入守卫跳过——必须返回 skipped 而非 null
      final result = await NoteEditorState().addOrUpdateNote();
      expect(result.skipped, isTrue);
      expect(result.saved, isNull);

      // 等待在途保存完成（页面路径的 waitForSave）
      await inFlight;
      await NoteEditorState.waitForSave();
      expect(NoteEditorState.isSaving, isFalse);

      // 页面路径的重新同步 + 重试：应把最新输入落库而非静默丢弃
      NoteEditorState.setState(
        NoteEditorState.original,
        NoteEditorState.title,
        NoteEditorState.description,
      );
      final retried = await NoteEditorState().addOrUpdateNote();
      expect(retried.skipped, isFalse);
      expect(retried.saved, isNotNull);

      final fresh = await NotesDatabase.instance.readNoteByUuid(
        retried.saved!.uuid,
      );
      expect(fresh, isNotNull);
      expect(fresh!.description, '用户最新的第二版内容');

      // 数据库仍只有 2 条（seed + 新建），重试不得产生重复插入
      final allNotes = await NotesDatabase.instance.readAllNotes();
      expect(allNotes.length, 2);
    });

    test('无在途保存时 waitForSave 立即返回', () async {
      await NoteEditorState.waitForSave();
      expect(NoteEditorState.isSaving, isFalse);
    });
  });

  group('NoteEditorState handleUngracefulNoteExit 超时退出处理', () {
    test('未尝试保存且内容非空时自动保存草稿', () async {
      NoteEditorState.setState(null, '未保存草稿', '草稿内容');
      expect(NoteEditorState.wasNoteSaveAttempted, isFalse);

      await NoteEditorState().handleUngracefulNoteExit();

      final allNotes = await NotesDatabase.instance.readAllNotes();
      expect(allNotes.length, 2);
      expect(allNotes.any((n) => n.title == '未保存草稿'), isTrue);
    });

    test('已显式标记 setSaveAttempted(true) 时不重复保存', () async {
      NoteEditorState.setState(null, '已尝试保存', '正文');
      NoteEditorState.setSaveAttempted(true);

      await NoteEditorState().handleUngracefulNoteExit();

      final allNotes = await NotesDatabase.instance.readAllNotes();
      expect(allNotes.length, 1);
    });

    test('内容为空时 handleUngracefulNoteExit 不保存', () async {
      NoteEditorState.setState(null, '', '');

      await NoteEditorState().handleUngracefulNoteExit();

      final allNotes = await NotesDatabase.instance.readAllNotes();
      expect(allNotes.length, 1);
    });
  });
}
