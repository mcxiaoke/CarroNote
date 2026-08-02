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

// Dart imports:
import 'dart:async';

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:easy_localization/easy_localization.dart';
import 'package:local_session_timeout/local_session_timeout.dart';

// Project imports:
import 'package:safenotes/data/database_handler.dart';
import 'package:safenotes/dialogs/delete_confirmation.dart';
import 'package:safenotes/models/safenote.dart';
import 'package:safenotes/routes/route_generator.dart';
import 'package:safenotes/sync/sync_service.dart';
import 'package:safenotes/utils/app_logger.dart';
import 'package:safenotes/utils/text_direction_util.dart';

class NoteDetailPage extends StatefulWidget {
  final int noteId;
  final StreamController<SessionState> sessionStateStream;

  const NoteDetailPage(
      {super.key, required this.noteId, required this.sessionStateStream});

  @override
  NoteDetailPageState createState() => NoteDetailPageState();
}

class NoteDetailPageState extends State<NoteDetailPage> {
  late SafeNote note;
  bool isLoading = false;

  @override
  void initState() {
    super.initState();

    refreshNote();
  }

  Future refreshNote() async {
    setState(() => isLoading = true);
    note = await NotesDatabase.instance.readNote(widget.noteId);
    // 只记录元数据（uuid/长度），不记录标题正文
    Log.ui.i('笔记详情页已加载: uuid=${note.uuid} id=${widget.noteId} '
        'len=${note.title.length}+${note.description.length}');
    setState(() => isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _appBar(context),
      body: _body(context),
    );
  }

  PreferredSizeWidget _appBar(BuildContext context) {
    return AppBar(
      title: isLoading ? Text('Loading...'.tr()) : null,
      actions: isLoading ? null : [editButton(), deleteButton()],
    );
  }

  Widget _body(BuildContext context) {
    return isLoading
        ? const Center(child: CircularProgressIndicator())
        : Padding(
            padding: const EdgeInsets.all(12),
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                SelectableText(
                  note.title,
                  textDirection: getTextDirecton(note.title),
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 10, bottom: 10),
                  child: Text(
                    DateFormat.yMMMd().format(note.createdTime),
                    textDirection: getTextDirecton(note.title),
                  ),
                ),
                SelectableText(
                  note.description,
                  textDirection: getTextDirecton(note.description),
                  style: const TextStyle(fontSize: 18),
                )
              ],
            ),
          );
  }

  Widget editButton() {
    return IconButton(
      icon: const Icon(Icons.edit_outlined),
      onPressed: () async {
        if (isLoading) return;
        Log.ui.i('界面切换: 笔记详情 → 编辑笔记(/editnote) uuid=${note.uuid}');
        await Navigator.pushNamed(
          context,
          '/editnote',
          arguments: AddEditNoteArguments(
            sessionStream: widget.sessionStateStream,
            note: note,
          ),
        );
        refreshNote();
      },
    );
  }

  Widget deleteButton() {
    return IconButton(
      icon: const Icon(Icons.delete),
      onPressed: () async {
        Log.ui.i('用户点击删除笔记, 弹出确认对话框 uuid=${note.uuid}');
        await confirmAndDeleteDialog(context);
      },
    );
  }

  Future<void> confirmAndDeleteDialog(BuildContext context) async {
    return showDialog(
      context: context,
      barrierDismissible: true,
      builder: (BuildContext contextChild) {
        return DeleteConfirmationDialog(
          callback: () async {
            var childNavigator = Navigator.of(contextChild);
            var navigator = Navigator.of(context);
            Log.note.i('用户确认删除笔记(移入回收站): uuid=${note.uuid} '
                'id=${widget.noteId}');
            await NotesDatabase.instance.softDelete(widget.noteId);
            // 软删除（移入回收站）后触发自动同步，确保远端及时收到墓碑标记
            Log.sync.d('笔记软删除后触发自动同步');
            SyncService.instance.autoSync();
            childNavigator.pop();
            navigator.pop();
          },
        );
      },
    );
  }
}
