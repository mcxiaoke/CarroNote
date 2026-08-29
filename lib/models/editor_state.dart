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

  // P0-7：在途保存完成信号。防重入跳过时调用方必须能等待在途保存结束，
  // 否则「跳过」会被误当作「成功」，退出页面的最新改动被静默丢弃。
  static Completer<void>? _saveCompleter;

  /// 是否有保存在途（供 UI 展示保存状态/守卫判断）。
  static bool get isSaving => _isSaving;

  /// 等待在途保存完成；无在途保存时立即返回。
  static Future<void> waitForSave() async {
    final completer = _saveCompleter;
    if (completer != null) await completer.future;
  }

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

  /// 自动保存：退出编辑页或 App 进入后台时触发。
  ///
  /// [destroyAfter] 为 true 时保存后清理静态状态（用于退出页面）；
  /// 为 false 时保留状态但将 [original] 更新为最新已保存的笔记（用于后台保存后
  /// 仍停留在编辑页，避免新建笔记重复入库或旧引用导致版本捕获错位）。
  ///
  /// 返回 `(saved, skipped)`：
  /// - [skipped] 为 true 表示被防重入守卫跳过（有并发保存在途），**一行都没
  ///   写库**——调用方必须等待在途保存完成后重试，绝不能当作成功关闭页面
  ///   （P0-7：跳过曾被误判为成功，退出时最新输入被静默丢弃）。
  /// - [saved] 为落库后的笔记；「内容未变化」或「内容为空」时为 null 且
  ///   skipped 为 false，属正常跳过。
  Future<({SafeNote? saved, bool skipped})> addOrUpdateNote({
    bool destroyAfter = true,
  }) async {
    // 评审 #13：防重入，避免超时保存与正常保存并发双写。
    // 若已有保存在进行中，返回 skipped 让调用方等待后重试。
    if (_isSaving) {
      Log.note.d('笔记保存已在进行中, 本次调用跳过 uuid=${original?.uuid ?? "(新建)"}');
      return (saved: null, skipped: true);
    }
    _isSaving = true;
    _saveCompleter = Completer<void>();
    SafeNote? saved;
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
            saved = await updateNote();
          } else {
            Log.note.d('笔记内容未变化, 跳过保存 uuid=${original!.uuid}');
          }
        } else {
          saved = await addNote();
        }
        // 笔记新增/编辑后触发自动同步（debounce 3 秒，非阻塞）
        // 确保本地变更能及时上传到远端，避免多端数据不一致
        if (saved != null) {
          Log.sync.d('笔记变更后触发自动同步(debounce 3 秒)');
          SyncService.instance.autoSync();
        }
      } else {
        Log.note.d('编辑器内容为空, 不保存笔记');
      }
      if (destroyAfter) {
        destroyValue();
      } else if (saved != null) {
        // 后台保存：保持编辑态，但更新 original 为最新已落库的笔记
        original = saved;
        // title/description 已是归一化后的值（空串已补空格）
      }
      return (saved: saved, skipped: false);
    } finally {
      _isSaving = false;
      _saveCompleter?.complete();
      _saveCompleter = null;
    }
  }

  Future<SafeNote> addNote() async {
    final note = SafeNote.create(title: title, description: description);
    // 只记录长度，正文内容不入日志（隐私红线）
    Log.note.i(
      '保存新建笔记: uuid=${note.uuid} '
      'len=${title.length}+${description.length}',
    );
    final saved = await NotesDatabase.instance.storeNote(note);
    return saved;
  }

  /// 保存用户编辑后的笔记内容。
  ///
  /// **syncedHash 刷新修复（2026-08-21）**：
  ///
  /// `original` 是进入编辑页时设置的静态引用，在编辑期间不会被更新。
  /// 若同步引擎在此期间完成了同步（`markSyncedForUuids` 把 DB 中的
  /// `synced_hash` 刷新为新收敛值），`original.syncedHash` 仍是旧值。
  /// 直接 `original!.copyWith(...)` 会把过时的 `syncedHash` 写回数据库，
  /// 覆盖同步引擎已正确更新的 base 值，导致下次同步误判为「双方都偏离 base」
  /// → 产生虚假冲突副本。
  ///
  /// 修复：保存前从数据库读取最新 `syncedHash`，确保 base 值不被编辑路径回退。
  /// 详见 `docs/conflict-stale-syncedhash-20260821.md`。
  Future<SafeNote> updateNote() async {
    Log.note.i(
      '保存编辑后的笔记: uuid=${original!.uuid} '
      'len=${title.length}+${description.length}',
    );
    final now = DateTime.now();

    // 从数据库读取最新的 syncedHash / syncedDeleted，避免编辑期间同步引擎
    // 更新了 base 值但 original 静态引用仍持有旧值导致回退覆盖。
    final fresh = await NotesDatabase.instance.readNoteByUuid(original!.uuid);

    // P0-log：检测 syncedHash 是否在编辑期间被同步引擎更新过
    // 若 original.syncedHash ≠ fresh.syncedHash，说明编辑期间发生了同步，
    // fresh 值才是正确的 base。修复前这里会用 original 的旧值导致回退。
    if (original!.syncedHash != null &&
        fresh != null &&
        fresh.syncedHash != null &&
        original!.syncedHash != fresh.syncedHash) {
      Log.note.w(
        '编辑期间 syncedHash 已更新: uuid=${original!.uuid} '
        'original=${original!.syncedHash} '
        'fresh=${fresh.syncedHash} '
        '(使用 fresh 值避免回退)',
      );
    }

    final note = original!.copyWith(
      title: title,
      description: description,
      contentHash: SafeNote.computeHash(title, description),
      updatedAt: now.millisecondsSinceEpoch,
      synced: false,
      syncedHash: fresh?.syncedHash,
      syncedDeleted: fresh?.syncedDeleted,
    );

    // 版本捕获：保存旧内容快照（覆盖前）
    // contentHash 去重由 saveVersion 内部处理，无修改时自动跳过
    await NotesDatabase.instance.saveVersion(original!);

    await NotesDatabase.instance.updateNote(note);
    return note;
  }
}
