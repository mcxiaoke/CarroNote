/*
* Copyright (C) Keshav Priyadarshi and others - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*
* You should have received a copy of the GNU General Public License v3.0 with
* this file. If not, please visit https://www.gnu.org/licenses/gpl-3.0.html
*
* See https://safenotes.dev for support or download.
*/

import 'dart:async';

import 'package:core/core.dart';

import 'package:safenotes/sync/sync_service.dart';

class NoteEditorState {
  static SafeNote? original;
  static String title = '';
  static String description = '';

  static bool wasNoteSaveAttempted = false;
  static void setSaveAttempted(bool flag) => wasNoteSaveAttempted = flag;

  // to be called everytime content of note in editor is changes
  static void setState(SafeNote? note, String titleNew, String descriptionNew) {
    original = note;
    title = titleNew;
    description = descriptionNew;
    wasNoteSaveAttempted = false;
  }

  // 评审 #13：保存互斥守卫。handleUngracefulNoteExit（超时登出）与用户正常
  // 保存（onSaveCallback) 可能并发触发 addOrUpdateNote，双写同一份内容会造成
  // 幂等竞态/重复入库。静态字段共享实例，进入即置位、完成才复位。
  static bool _isSaving = false;

  static void destroyValue() {
    original = null;
    title = description = '';
    wasNoteSaveAttempted = false;
  }

  // to be called during inactivity timeOut
  Future<void> handleUngracefulNoteExit() async {
    // if note content was changed and note editor was closed(due to inactivity)
    // without user opting for saving or discarding
    if (wasNoteSaveAttempted == false &&
        (title.isNotEmpty || description.isNotEmpty)) {
      // 超时锁定导致的非正常退出：自动保存草稿，属于需要关注的事件
      Log.note.w(
        '编辑器非正常退出(会话超时): 自动保存未提交内容 '
        'uuid=${original?.uuid ?? "(新建)"} '
        'len=${title.length}+${description.length}',
      );
      await addOrUpdateNote();
    }
  }

  Future<void> addOrUpdateNote() async {
    // 评审 #13：防重入，避免超时保存与正常保存并发双写。
    // 若已有保存在进行中，直接返回（后台保存会覆盖同一份 title/description）。
    if (_isSaving) {
      Log.note.d('笔记保存已在进行中, 本次调用跳过 uuid=${original?.uuid ?? "(新建)"}');
      return;
    }
    _isSaving = true;
    try {
      // if atleast one of the field is non empty save note
      if (title.isNotEmpty || description.isNotEmpty) {
        // fill empty title or description with
        title = title.isEmpty ? ' ' : title;
        description = description.isEmpty ? ' ' : description;

        final isUpdating = original != null;
        if (isUpdating) {
          if (original!.title != title ||
              original!.description != description) {
            await updateNote();
          } else {
            Log.note.d('笔记内容未变化, 跳过保存 uuid=${original!.uuid}');
          }
        } else {
          await addNote();
        }
        // 笔记新增/编辑后触发自动同步（debounce 3 秒，非阻塞）
        // 确保本地变更能及时上传到远端，避免多端数据不一致
        Log.sync.d('笔记变更后触发自动同步(debounce 3 秒)');
        SyncService.instance.autoSync();
      } else {
        Log.note.d('编辑器内容为空, 不保存笔记');
      }
      destroyValue();
    } finally {
      _isSaving = false;
    }
  }

  Future addNote() async {
    final note = SafeNote.create(title: title, description: description);
    // 只记录长度，正文内容不入日志（隐私红线）
    Log.note.i(
      '保存新建笔记: uuid=${note.uuid} '
      'len=${title.length}+${description.length}',
    );
    await NotesDatabase.instance.storeNote(note);
  }

  Future updateNote() async {
    Log.note.i(
      '保存编辑后的笔记: uuid=${original!.uuid} '
      'len=${title.length}+${description.length}',
    );
    final now = DateTime.now();
    final note = original!.copyWith(
      title: title,
      description: description,
      contentHash: SafeNote.computeHash(title, description),
      updatedAt: now.millisecondsSinceEpoch,
      synced: false,
    );
    await NotesDatabase.instance.updateNote(note);
  }
}
