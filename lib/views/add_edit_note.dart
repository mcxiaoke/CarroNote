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

import 'package:flutter/material.dart';

import 'package:core/core.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:local_session_timeout/local_session_timeout.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/dialogs/delete_confirmation.dart';
import 'package:safenotes/models/editor_state.dart';
import 'package:safenotes/sync/sync_service.dart';
import 'package:safenotes/utils/motion.dart';
import 'package:safenotes/utils/platform_ui.dart';
import 'package:safenotes/utils/snack_message.dart';
import 'package:safenotes/utils/editor_text.dart';
import 'package:safenotes/utils/text_styles.dart';
import 'package:safenotes/utils/url_launcher.dart';
import 'package:safenotes/widgets/app_dialogs.dart';
import 'package:safenotes/widgets/note_widget.dart';

/// 未保存退出弹框的三种选择：保存 / 放弃 / 取消。

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
  // 默认预览模式；仅新建笔记默认进入编辑，已有笔记打开后先看预览。
  bool _previewMode = true;
  // 正在执行删除：避免 PopScope 在删除后自动保存把已删笔记重新写回。
  bool _isDeleting = false;
  // 正在执行保存：防止保存期间连点/退出拦截重复触发 addOrUpdateNote 产生重复笔记。
  bool _isSaving = false;
  // 已确认关闭（保存/放弃/删除），用于让 PopScope 放行 pop，避免退出弹框死循环。
  bool _allowClose = false;

  @override
  void initState() {
    super.initState();
    title = widget.note?.title ?? '';
    description = widget.note?.description ?? '';
    title = title == ' ' ? '' : title;
    description = description == ' ' ? '' : description;
    // 新建笔记默认进入编辑模式，已有笔记打开后默认预览。
    _previewMode = widget.note != null;
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
    return PopScope(
      // 仅当「已确认关闭 / 正在删除 / 无未保存改动」时才允许直接 pop；
      // 否则在 onPopInvoked 中弹框让用户选择保存/放弃/取消。
      canPop: _allowClose || _isDeleting || !isNoteNewOrContentChanged(),
      onPopInvokedWithResult: (bool didPop, _) => _onPopInvoked(didPop),
      child: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: Scaffold(
          key: const Key('ui-note-screen'),
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
              : // 编辑区由 NoteFormWidget 自带的 SingleChildScrollView 负责滚动；
                // 键盘避让交给局部 _KeyboardAwarePadding（只重建底部 padding，
                // 避免键盘动画期间整页 Scaffold 每帧 rebuild）。
                _KeyboardAwarePadding(child: _buildBody()),
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
    // 保存进行中：不弹未保存框（避免重复触发保存），等保存流程自行关页。
    if (_isSaving) return;
    // 存在未保存改动：让用户选择 保存 / 放弃 / 取消。
    final AppThreeWayResult? action = await _showUnsavedDialog();
    if (!mounted) return;
    if (action == null || action == AppThreeWayResult.cancel) return; // 留在本页
    if (action == AppThreeWayResult.confirm) {
      Log.note.i('退出编辑页前用户选择保存: uuid=${widget.note?.uuid ?? "(新建)"}');
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

  Future<AppThreeWayResult?> _showUnsavedDialog() {
    return showAppThreeWay(
      context,
      title: 'Unsaved changes'.tr(),
      message: 'You have unsaved changes. Save before leaving?'.tr(),
      confirmLabel: 'Save'.tr(),
      discardLabel: 'Discard'.tr(),
      cancelLabel: 'Cancel'.tr(),
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
      key: const Key('ui-note-button-preview'),
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
        Log.ui.i(
          '用户点击删除笔记(编辑页), 弹出确认对话框 '
          'uuid=${widget.note!.uuid}',
        );
        await showDeleteConfirmation(
          context: context,
          onConfirm: () async {
            // 标记删除中，避免 PopScope 在关闭页面时拦截或弹未保存框。
            setState(() => _isDeleting = true);
            Log.note.i(
              '用户确认删除笔记(移入回收站): '
              'uuid=${widget.note!.uuid} id=${widget.note!.id}',
            );
            await NotesDatabase.instance.softDelete(widget.note!.id!);
            // 软删除（移入回收站）后触发自动同步，确保远端及时收到墓碑标记
            Log.sync.d('笔记软删除后触发自动同步');
            SyncService.instance.autoSync();
            await _closePage();
          },
        );
      },
    );
  }

  /// 复刻编辑态 ShadInputFormField 的有效文字样式，保证预览与编辑逐像素一致。
  ///
  /// 编辑态内部实现：`theme.textTheme.muted.copyWith(color: foreground)
  /// .merge(widget.style)`，其中 widget.style = `AppText.x.copyWith(
  /// fontFamily: uiFontFamily, fontFamilyFallback: uiFontFamilyFallback)`。
  /// 关键：在 Android 等移动端 `uiFontFamily` 为 null，并不覆盖 shad muted 的字体，
  /// 编辑态实际落到 shad muted 字体；而预览态若只用 `AppText`（fontFamily 为 null）
  /// 会继承 Material 默认字体（Roboto），两种字体对 `#` 等符号的宽窄/粗细差异明显。
  /// 因此预览态必须直接复用同一来源，而非另设可能为 null 的字体族。
  TextStyle _editorLikeStyle(BuildContext context, TextStyle base) {
    final shad = ShadTheme.of(context);
    return shad.textTheme.muted
        .copyWith(color: shad.colorScheme.foreground)
        .merge(
          base.copyWith(
            fontFamily: uiFontFamily,
            fontFamilyFallback: uiFontFamilyFallback,
          ),
        );
  }

  Widget _buildPreview(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: ListView(
        children: [
          SelectableText(
            title,
            // P1-19：预览标题走 EditorText.title（档位标题尺寸，默认 20 bold），
            // 与编辑器标题一致。复用 _editorLikeStyle 确保预览与编辑逐像素一致
            // （含 Android 上 uiFontFamily 为 null 时落到 shad muted 字体的情况）。
            style: _editorLikeStyle(context, EditorText.title()),
          ),
          // 与编辑态同构：标题/正文间统一分隔线 + 17px 间距，
          // 消除模式切换时的纵向跳动与分隔线闪现。
          const SizedBox(height: 8),
          const Divider(height: 1, thickness: 1),
          const SizedBox(height: 8),
          // Markdown 关闭时预览纯文本，避免把 Markdown 源码直接渲染/解析。
          if (PreferencesStorage.isMarkdownEnabled)
            MarkdownBody(
              data: description,
              selectable: true,
              styleSheet: _markdownStyleSheet(context),
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
            // 预览纯文本走 EditorText.body（档位正文字尺寸，默认 16），与编辑态一致，
            // 不套 Markdown 排版。复用 _editorLikeStyle 保证字体/颜色完全对齐。
            SelectableText(
              description,
              style: _editorLikeStyle(context, EditorText.body()),
            ),
        ],
      ),
    );
  }

  /// Markdown 预览样式：正文 16（与编辑态一致），标题 h1-h6 逐级递减的多级
  /// 字号（24→20→18→17→16→16），blockquote / code 显式设样式，避免落到
  /// Material 默认排印与 shad 风格脱节。Markdown 预览与纯文本编辑态不同，
  /// 是唯一带多级标题排版的视图。
  MarkdownStyleSheet _markdownStyleSheet(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    // 预览与编辑态共用同一套文字样式来源：_editorLikeStyle 复刻 ShadInputFormField
    // 的有效样式（shad muted 字体 + 注入 foreground），避免 Markdown 正文/标题落到
    // Material 排印导致与编辑态字体/色差（尤其 Android 上 uiFontFamily 为 null 时）。
    // h6 / blockquote 保留 M3 弱化色做层级区分。
    // P1-20：Markdown 预览暂不支持自定义字号，正文/标题固定用 AppText.body
    // 基准与 24/20/18/17 固定层级（与编辑/预览页的 EditorText 调节解耦），
    // 避免 Markdown 众多标签（列表/引用/代码/表格等）字号联动失控、排印错乱。
    final TextStyle uiBase = _editorLikeStyle(context, AppText.body);
    final base = MarkdownStyleSheet.fromTheme(theme);
    // 行内代码沿用主题已有配色，仅统一为等宽 + 小一号，避免硬编码颜色在
    // 亮/暗模式下对比度失衡。
    final baseCode = base.code ?? AppText.body;
    const mono = 'monospace';
    return base.copyWith(
      p: uiBase,
      // 标题层级：h1=24 起逐级递减，h5/h6 不小于正文（16），仅用字重/颜色区分。
      h1: uiBase.copyWith(fontSize: 24, fontWeight: FontWeight.w700),
      h2: uiBase.copyWith(fontSize: 20, fontWeight: FontWeight.w700),
      h3: uiBase.copyWith(fontSize: 18, fontWeight: FontWeight.w700),
      h4: uiBase.copyWith(fontSize: 17, fontWeight: FontWeight.w700),
      h5: uiBase.copyWith(fontWeight: FontWeight.w700),
      h6: uiBase.copyWith(
        fontWeight: FontWeight.w600,
        color: cs.onSurfaceVariant,
      ),
      // 引用块：左竖线 + 斜体弱化，shad 风格。
      blockquote: uiBase.copyWith(
        fontStyle: FontStyle.italic,
        color: cs.onSurfaceVariant,
      ),
      blockquoteDecoration: BoxDecoration(
        border: Border(left: BorderSide(color: cs.outlineVariant, width: 3)),
      ),
      // 行内代码 / 代码块：等宽字体，代码块加弱背景 + 圆角。
      code: baseCode.copyWith(fontFamily: mono, fontSize: 14),
      codeblockPadding: const EdgeInsets.all(10),
      codeblockDecoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
    );
  }

  Widget buildButton() {
    final bool isFormValid = title.isNotEmpty || description.isNotEmpty;

    // AppBar 内用图标按钮（与预览/删除图标风格一致），不再用文字按钮。
    // 保存进行中禁用，防止连点重复触发 addOrUpdateNote。
    return IconButton(
      key: const Key('ui-note-button-save'),
      tooltip: 'Save'.tr(),
      icon: const Icon(LucideIcons.save),
      onPressed: (isFormValid && !_isSaving) ? onSaveCallback : null,
    );
  }

  Future<void> onSaveCallback() async {
    // 防重入：保存中忽略重复提交
    if (_isSaving) return;

    Log.note.i(
      '用户点击保存按钮: 模式=${widget.note == null ? "新建" : "编辑"} '
      'len=${title.length}+${description.length}',
    );
    setState(() => _isSaving = true);
    try {
      await NoteEditorState()
          .addOrUpdateNote(); // this will also set NoteEditorState.setSaveAttempted = true
      await _closePage();
    } on Exception catch (e, st) {
      Log.note.e('保存笔记失败', error: e, stackTrace: st);
      if (mounted) {
        showErrorToast(
          context,
          'Failed to save note: {error}'.tr(namedArgs: {'error': '$e'}),
        );
      }
    } finally {
      // 复位防重入（成功路径 pop 后页面已销毁，跳过 setState）
      if (mounted) setState(() => _isSaving = false);
    }
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

/// 键盘避让的局部监听：只有本组件依赖 viewInsets，键盘弹出/收起动画期间
/// 只重建底部 padding，避免整页 Scaffold 每帧 rebuild（原实现直接在 build
/// 开头读 MediaQuery.viewInsets，键盘动画会被整页重建拖慢）。
class _KeyboardAwarePadding extends StatelessWidget {
  const _KeyboardAwarePadding({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // viewInsetsOf 只订阅 viewInsets 细分依赖，比 MediaQuery.of 重建范围更小。
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return AnimatedPadding(
      // P1-11：150ms → AppMotion.normal，与系统键盘节奏对齐。
      duration: AppMotion.normal,
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: bottom),
      child: child,
    );
  }
}
