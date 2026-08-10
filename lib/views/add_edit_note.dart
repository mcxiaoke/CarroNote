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
import 'package:safenotes/models/editor_state.dart';
import 'package:core/core.dart';
import 'package:safenotes/widgets/note_widget.dart';

class AddEditNotePage extends StatefulWidget {
  final StreamController<SessionState> sessionStateStream;
  final SafeNote? note;

  const AddEditNotePage({
    super.key,
    this.note,
    required this.sessionStateStream,
  });

  @override
  AddEditNotePageState createState() => AddEditNotePageState();
}

class AddEditNotePageState extends State<AddEditNotePage> {
  final _formKey = GlobalKey<FormState>();

  late String title;
  late String description;

  @override
  void initState() {
    super.initState();
    title = widget.note?.title ?? '';
    description = widget.note?.description ?? '';
    title = title == ' ' ? '' : title;
    description = description == ' ' ? '' : description;
    NoteEditorState.setSaveAttempted(false);
    // 界面切换埋点：区分新建 / 编辑，只记录 uuid 与长度
    Log.ui.i(
      '进入笔记编辑页: 模式=${widget.note == null ? "新建" : "编辑"} '
      'uuid=${widget.note?.uuid ?? "(未生成)"} '
      'len=${title.length}+${description.length}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && isNoteNewOrContentChanged()) {
          Log.note.i(
            '退出编辑页时检测到内容变更, 自动保存 '
            'uuid=${widget.note?.uuid ?? "(新建)"}',
          );
          NoteEditorState().addOrUpdateNote();
        }
      },
      child: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: Scaffold(
          resizeToAvoidBottomInset: false,
          appBar: AppBar(actions: [buildButton()]),
          body: SingleChildScrollView(
            reverse: true,
            child: Padding(
              padding: EdgeInsets.only(bottom: bottom),
              child: _buildBody(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    return Form(
      key: _formKey,
      child: NoteFormWidget(
        title: title,
        description: description,
        sessionStateStream: widget.sessionStateStream,
        onChangedTitle: (title) => setState(() {
          this.title = title;
          NoteEditorState.setState(widget.note, this.title, description);
        }),
        onChangedDescription: (description) => setState(() {
          this.description = description;
          NoteEditorState.setState(widget.note, title, this.description);
        }),
      ),
    );
  }

  Widget buildButton() {
    final isFormValid = title.isNotEmpty || description.isNotEmpty;
    const double buttonFontSize = 17.0;
    final String buttonText = 'Save'.tr();

    // AppBar 内不使用凸起按钮（更像原生桌面应用）：改用文字按钮。
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      child: TextButton(
        onPressed: isFormValid ? onSaveCallback : null,
        child: Text(
          buttonText,
          style: const TextStyle(
            fontSize: buttonFontSize,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Future<void> onSaveCallback() async {
    Log.note.i(
      '用户点击保存按钮: 模式=${widget.note == null ? "新建" : "编辑"} '
      'len=${title.length}+${description.length}',
    );
    // TODO: refactor without using BuildContexts across async gap
    var navigator = Navigator.of(context);
    await NoteEditorState()
        .addOrUpdateNote(); // this will also set NoteEditorState.setSaveAttempted = true
    navigator.pop();
  }

  bool isNoteNewOrContentChanged() {
    if (widget.note == null) {
      //New Note and content is not empty
      if (title.isNotEmpty || description.isNotEmpty) return true;
    } else {
      // 评审 #13 修复：原条件把「清空标题」(title=='') 判为未变更，退出丢改动。
      // 改为与原始内容逐字段比较——只要任一字段不同即视为已变更
      // （清空标题也属于改动，保存时 addOrUpdateNote 会把空标题归一化为 ' '）。
      if (widget.note!.title != title ||
          widget.note!.description != description) {
        return true;
      }
    }
    return false;
  }
}
