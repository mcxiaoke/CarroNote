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
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

// Project imports:
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/editor_state.dart';
import 'package:core/core.dart';
import 'package:safenotes/dialogs/delete_confirmation.dart';
import 'package:safenotes/sync/sync_service.dart';
import 'package:safenotes/widgets/note_widget.dart';
import 'package:safenotes/utils/url_launcher.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:safenotes/widgets/shad_dialog.dart';

/// 未保存退出弹框的三种选择。
enum UnsavedAction { save, discard, cancel }

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
  // 默认进入预览模式（而非编辑），符合"默认预览而不是编辑"的需求。
  bool _previewMode = true;
  // 正在执行删除：避免 PopScope 在删除后自动保存把已删笔记重新写回。
  bool _isDeleting = false;
  // 已确认关闭（保存/放弃/删除），用于让 PopScope 放行 pop，避免退出弹框死循环。
  bool _allowClose = false;

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
      // 仅当「已确认关闭 / 正在删除 / 无未保存改动」时才允许直接 pop；
      // 否则在 onPopInvoked 中弹框让用户选择保存/放弃/取消。
      canPop: _allowClose || _isDeleting || !isNoteNewOrContentChanged(),
      onPopInvokedWithResult: (bool didPop, _) => _onPopInvoked(didPop),
      child: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: Scaffold(
          resizeToAvoidBottomInset: false,
          appBar: AppBar(
            actions: [
              _previewToggle(),
              // 仅编辑已有笔记时才提供删除；新建笔记尚无 id，不可删。
              if (widget.note != null) _deleteButton(),
              buildButton(),
            ],
          ),
          body: _previewMode
              ? _buildPreview(context)
              : SingleChildScrollView(
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

  /// 拦截退出：有未保存改动时弹框确认，避免误丢改动。
  Future<void> _onPopInvoked(bool didPop) async {
    // pop 已发生（如无可关闭的未保存改动），无需处理。
    if (didPop) return;
    // 删除流程或已确认关闭：兜底直接放行，结束页面。
    if (_allowClose || _isDeleting) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    // 存在未保存改动：让用户选择 保存 / 放弃 / 取消。
    final UnsavedAction? action = await _showUnsavedDialog();
    if (!mounted) return;
    if (action == null || action == UnsavedAction.cancel) return; // 留在本页
    if (action == UnsavedAction.save) {
      Log.note.i(
        '退出编辑页前用户选择保存: uuid=${widget.note?.uuid ?? "(新建)"}',
      );
      await NoteEditorState().addOrUpdateNote();
    }
    // 保存或放弃都关闭页面（放弃不写库）。
    await _closePage();
  }

  /// 安全关闭页面：先置 [_allowClose] 触发重建使 canPop=true，等一帧后再 pop，
  /// 避免 PopScope 在 canPop 仍为 false 时反复拦截导致死循环。
  Future<void> _closePage() async {
    if (!mounted) return;
    setState(() => _allowClose = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.of(context).pop();
  }

  Future<UnsavedAction?> _showUnsavedDialog() {
    return showDialog<UnsavedAction>(
      context: context,
      builder: (BuildContext ctx) {
        return ShadDialog(
          title: Text('Unsaved changes'.tr()),
          actions: [
            shadDialogActionBar(actions: [
              ShadDialogAction(
                label: 'Cancel'.tr(),
                onPressed: () => Navigator.of(ctx).pop(UnsavedAction.cancel),
              ),
              ShadDialogAction(
                label: 'Discard'.tr(),
                onPressed: () => Navigator.of(ctx).pop(UnsavedAction.discard),
              ),
              ShadDialogAction(
                label: 'Save'.tr(),
                primary: true,
                onPressed: () => Navigator.of(ctx).pop(UnsavedAction.save),
              ),
            ]),
          ],
          child: Text(
            'You have unsaved changes. Save before leaving?'.tr(),
          ),
        );
      },
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

  Widget _previewToggle() {
    final bool isPreview = _previewMode;
    return IconButton(
      tooltip: isPreview ? 'Edit'.tr() : 'Preview'.tr(),
      icon: Icon(isPreview ? LucideIcons.squarePen : LucideIcons.eye),
      onPressed: () => setState(() => _previewMode = !_previewMode),
    );
  }

  Widget _deleteButton() {
    return IconButton(
      icon: const Icon(LucideIcons.trash2),
      tooltip: 'Delete'.tr(),
      onPressed: () async {
        if (widget.note == null) return;
        Log.ui.i('用户点击删除笔记(编辑页), 弹出确认对话框 '
            'uuid=${widget.note!.uuid}');
        await showDialog(
          context: context,
          barrierDismissible: true,
          builder: (BuildContext contextChild) {
            return DeleteConfirmationDialog(
              callback: () async {
                // 标记删除中，避免 PopScope 在关闭页面时拦截或弹未保存框。
                setState(() => _isDeleting = true);
                final childNavigator = Navigator.of(contextChild);
                Log.note.i('用户确认删除笔记(移入回收站): '
                    'uuid=${widget.note!.uuid} id=${widget.note!.id}');
                await NotesDatabase.instance.softDelete(widget.note!.id!);
                // 软删除（移入回收站）后触发自动同步，确保远端及时收到墓碑标记
                Log.sync.d('笔记软删除后触发自动同步');
                SyncService.instance.autoSync();
                childNavigator.pop();
                await _closePage();
              },
            );
          },
        );
      },
    );
  }

  Widget _buildPreview(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: ListView(
        children: [
          SelectableText(
            title,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 10),
          // Markdown 关闭时预览纯文本，避免把 Markdown 源码直接渲染/解析。
          if (PreferencesStorage.isMarkdownEnabled)
            MarkdownBody(
              data: description,
              selectable: true,
              styleSheet:
                  MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                p: const TextStyle(fontSize: 18),
              ),
              // 隐私：不加载任何网络/本地图片，避免泄露 IP / 元数据
              imageBuilder: (uri, _, _) => const SizedBox.shrink(),
              onTapLink: (text, href, _) {
                // 用户主动点击才打开，外部浏览器；不做自动加载
                if (href != null) {
                  unawaited(
                    launchUrlExternal(Uri.parse(href)).catchError((_) {}),
                  );
                }
              },
            )
          else
            SelectableText(
              description,
              style: const TextStyle(fontSize: 18),
            ),
        ],
      ),
    );
  }

  Widget buildButton() {
    final bool isFormValid = title.isNotEmpty || description.isNotEmpty;

    // AppBar 内用图标按钮（与预览/删除图标风格一致），不再用文字按钮。
    return IconButton(
      tooltip: 'Save'.tr(),
      icon: const Icon(LucideIcons.save),
      onPressed: isFormValid ? onSaveCallback : null,
    );
  }

  Future<void> onSaveCallback() async {
    Log.note.i(
      '用户点击保存按钮: 模式=${widget.note == null ? "新建" : "编辑"} '
      'len=${title.length}+${description.length}',
    );
    await NoteEditorState()
        .addOrUpdateNote(); // this will also set NoteEditorState.setSaveAttempted = true
    await _closePage();
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
