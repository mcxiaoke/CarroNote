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
import 'package:flutter/services.dart';

import 'package:core/core.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:local_session_timeout/local_session_timeout.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/dialogs/delete_confirmation.dart';
import 'package:safenotes/models/editor_state.dart';
import 'package:safenotes/sync/sync_service.dart';
import 'package:safenotes/utils/editor_text.dart';
import 'package:safenotes/utils/motion.dart';
import 'package:safenotes/utils/note_edit_history.dart';
import 'package:safenotes/utils/platform_ui.dart';
import 'package:safenotes/utils/snack_message.dart';
import 'package:safenotes/utils/text_styles.dart';
import 'package:safenotes/utils/url_launcher.dart';
import 'package:safenotes/widgets/note_actions_sheet.dart';
import 'package:safenotes/widgets/note_widget.dart';
import 'package:safenotes/widgets/tag_editor.dart';
import 'package:safenotes/views/version_history_page.dart';

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

class AddEditNotePageState extends State<AddEditNotePage>
    with WidgetsBindingObserver {
  final _formKey = GlobalKey<FormState>();

  late String title;
  late String description;

  /// 标题 / 正文编辑控制器：撤销栈通过它还原文本与光标（selection）。
  late final TextEditingController _titleController;
  late final TextEditingController _descriptionController;

  /// 编辑会话级撤销/重做历史（双栈快照）。
  final NoteEditHistory _history = NoteEditHistory();

  /// 正在应用撤销/重做：守卫 controller 监听器，避免“还原操作”又被记录进历史。
  bool _applyingHistory = false;

  /// 撤销/重做可用性，驱动 AppBar 按钮启用态。
  bool _canUndo = false;
  bool _canRedo = false;
  // 默认预览模式；仅新建笔记默认进入编辑，已有笔记打开后先看预览。
  bool _previewMode = true;
  // 正在执行删除：避免 PopScope 在删除后自动保存把已删笔记重新写回。
  bool _isDeleting = false;
  // 正在执行保存：防止保存期间重复触发 addOrUpdateNote 产生重复笔记。
  bool _isSaving = false;
  // 已确认关闭，用于让 PopScope 放行 pop，避免死循环。
  bool _allowClose = false;

  /// 已落库的笔记快照（用于新建笔记后台自动保存后追踪 uuid，避免重复新建）。
  ///
  /// 初始值为 [widget.note]；新建笔记后台自动保存后更新为新入库的笔记，
  /// 后续改动判定、更多菜单等均以此为准。
  SafeNote? _effectiveNote;

  /// 当前笔记的元数据快照（星标/锁定/标签），异步加载。
  ///
  /// 锁定语义依赖它：`locked == true` 时页面强制只读预览。加载完成前视作未锁定，
  /// 避免首帧卡住；锁定笔记在加载完成后切换为只读。
  NoteMeta? _meta;

  /// 是否锁定（只读）。锁定后隐藏 编辑 入口，仅展示预览。
  bool get _isLocked => _meta?.locked ?? false;

  /// 当前标签列表（用于预览页标题下方浮层展示）。
  List<String> get _tags => _meta?.tags ?? const [];

  @override
  void initState() {
    super.initState();
    _effectiveNote = widget.note;
    title = widget.note?.title ?? '';
    description = widget.note?.description ?? '';
    title = title == ' ' ? '' : title;
    description = description == ' ' ? '' : description;
    // 用初始内容初始化控制器与撤销栈基准状态。
    _titleController = TextEditingController(text: title);
    _descriptionController = TextEditingController(text: description);
    _history.init(
      TextEditingValue(text: title),
      TextEditingValue(text: description),
    );
    // 控制器监听器统一驱动：预览态同步 + 撤销栈记录。
    _titleController.addListener(() => _onEdit('title'));
    _descriptionController.addListener(() => _onEdit('description'));
    // 新建笔记默认进入编辑模式，已有笔记打开后默认预览。
    _previewMode = widget.note != null;
    if (widget.note != null) {
      _loadMeta();
    }
    NoteEditorState.setSaveAttempted(false);
    NoteEditorState.setState(_effectiveNote, title, description);
    WidgetsBinding.instance.addObserver(this);
    // 界面切换埋点：区分新建 / 编辑，只记录 uuid 与长度
    Log.ui.i(
      '进入笔记编辑页: 模式=${widget.note == null ? "新建" : "编辑"} '
      'uuid=${widget.note?.uuid ?? "(未生成)"} '
      'len=${title.length}+${description.length}',
    );
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    // 若页面因非 pop 路径被 dispose（如会话超时登出），静默自动保存
    // 使用 destroyAfter=false 的路径由 handleUngracefulNoteExit 兜底，这里
    // 仅清理静态状态标记，避免泄漏到下一次编辑。
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // App 进入后台（paused/inactive/hidden/detached）时自动保存
    // 不弹框、不关页，仅静默落库；有历史版本兜底，用户无需手动保存。
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      if (_isLocked || _isDeleting || _isSaving) return;
      Log.app.i('笔记编辑页: App进入后台自动保存 state=$state');
      unawaited(_performAutoSave(keepEditing: true));
    }
  }

  /// 异步读取笔记元数据（星标/锁定/标签），加载完成后驱动锁定语义与预览标签。
  Future<void> _loadMeta() async {
    final note = _effectiveNote;
    if (note == null || !mounted) return;
    final meta = await NotesDatabase.instance.getNoteMeta(note.uuid);
    if (!mounted) return;
    setState(() => _meta = meta);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // 仅当「已确认关闭 / 正在删除」时直接放行；有未保存改动时在 onPopInvoked
      // 中自动保存后再放行（无弹框）。
      canPop: _allowClose || _isDeleting,
      onPopInvokedWithResult: (bool didPop, _) => _onPopInvoked(didPop),
      child: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: Scaffold(
          key: const Key('ui-note-screen'),
          resizeToAvoidBottomInset: false,
          appBar: AppBar(
            actions: [
              // 锁定笔记只读：AppBar 顶部用「已锁定」文本指示，正文布局不被改动。
              if (_isLocked) _lockedIndicator(),
              // 锁定笔记隐藏「编辑/预览」切换，仅保留操作菜单，
              // 供复制 / 星标 / 解锁 / 标签 / 删除使用。
              if (!_isLocked) _previewToggle(),
              // 编辑态（非锁定）提供撤销 / 重做按钮，按 _canUndo/_canRedo 启用。
              if (!_isLocked && !_previewMode) _undoRedoButtons(),
              // 复制/星标/锁定/标签/删除/版本历史收进「更多」菜单，AppBar 仅保留预览切换。
              // 新建笔记后台自动保存后 _effectiveNote 会被赋值，同样可调起菜单。
              if (_effectiveNote != null) _moreButton(),
            ],
          ),
          body: (_isLocked || _previewMode)
              ? _buildPreview(context)
              : // 编辑区由 NoteFormWidget 自带的 SingleChildScrollView 负责滚动；
                // 键盘避让交给局部 _KeyboardAwarePadding（只重建底部 padding，
                // 避免键盘动画期间整页 Scaffold 每帧 rebuild）。
                _KeyboardAwarePadding(child: _buildBody()),
        ),
      ),
    );
  }

  /// 拦截退出：自动保存有改动的笔记，无弹框。
  Future<void> _onPopInvoked(bool didPop) async {
    // pop 已发生，无需处理。
    if (didPop) return;
    // 删除流程或已确认关闭：兜底直接放行，结束页面。
    if (_allowClose || _isDeleting) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    // 保存进行中：等待保存流程自行关页，避免重复触发。
    if (_isSaving) return;
    // 锁定笔记不需要保存
    if (_isLocked) {
      await _closePage();
      return;
    }
    // 有未保存改动则自动保存，再关闭页面
    if (isNoteNewOrContentChanged()) {
      Log.note.i('退出编辑页自动保存: uuid=${_effectiveNote?.uuid ?? "(新建)"}');
      await _performAutoSave(keepEditing: false);
    } else {
      // 无改动也需清理编辑态
      NoteEditorState.destroyValue();
    }
    await _closePage();
  }

  /// 执行自动保存（退出或后台）。
  ///
  /// [keepEditing] 为 true 时（后台）保留编辑态，[original] 更新为最新落库
  /// 笔记以避免新建笔记重复入库；为 false 时（退出）销毁静态状态。
  Future<SafeNote?> _performAutoSave({required bool keepEditing}) async {
    if (_isSaving || _isDeleting) return null;
    if (_isLocked) return null;
    if (!isNoteNewOrContentChanged()) return null;
    if (title.trim().isEmpty && description.trim().isEmpty) {
      Log.note.d('自动保存跳过: 内容为空');
      if (!keepEditing) NoteEditorState.destroyValue();
      return null;
    }
    // 确保静态状态与当前输入同步（预览模式下也可能有未同步的 title/description）
    NoteEditorState.setState(_effectiveNote, title, description);
    if (mounted) setState(() => _isSaving = true);
    try {
      final saved = await NoteEditorState().addOrUpdateNote(
        destroyAfter: !keepEditing,
      );
      if (saved != null) {
        _effectiveNote = saved;
        if (keepEditing && mounted) {
          // 新建笔记后台保存后，更多菜单应立即可用
          setState(() {});
          // 后台保存后懒加载元数据（新建笔记首次有 uuid）
          if (_meta == null) _loadMeta();
        }
      }
      return saved;
    } on Exception catch (e, st) {
      Log.note.e('自动保存失败', error: e, stackTrace: st);
      if (!keepEditing && mounted) {
        showErrorToast(
          context,
          'Failed to save note: {error}'.tr(namedArgs: {'error': '$e'}),
        );
      }
      return null;
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  /// 安全关闭页面：先置 [_allowClose] 触发重建使 canPop=true，等一帧后再 pop，
  /// 避免 PopScope 在 canPop 仍为 false 时反复拦截导致死循环。
  Future<void> _closePage() async {
    if (!mounted) return;
    setState(() => _allowClose = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.of(context).pop();
  }

  Widget _buildBody() {
    return Focus(
      onKeyEvent: _handleKeyEvent,
      child: Form(
        key: _formKey,
        child: NoteFormWidget(
          titleController: _titleController,
          descriptionController: _descriptionController,
          sessionStateStream: widget.sessionStateStream,
        ),
      ),
    );
  }

  /// 撤销 / 重做按钮组：按可用性启用，仅在编辑态（非锁定）出现。
  Widget _undoRedoButtons() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: const Key('ui-note-button-undo'),
          tooltip: 'Undo'.tr(),
          icon: const Icon(LucideIcons.undo2),
          onPressed: _canUndo ? _undo : null,
        ),
        IconButton(
          key: const Key('ui-note-button-redo'),
          tooltip: 'Redo'.tr(),
          icon: const Icon(LucideIcons.redo2),
          onPressed: _canRedo ? _redo : null,
        ),
      ],
    );
  }

  /// 键盘拦截：在 focus 遍历中先于原生 Shortcuts（系统 undo）执行。
  /// 命中 Ctrl+Z / Ctrl+Shift+Z / Ctrl+Y 时由本栈处理并返回 handled，
  /// 阻止 EditableText 原生 undo 造成“双撤销”。
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (_previewMode || _isLocked) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final bool ctrl =
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed; // macOS Cmd 同义
    if (!ctrl) return KeyEventResult.ignored;
    final bool shift = HardwareKeyboard.instance.isShiftPressed;
    if (event.physicalKey == PhysicalKeyboardKey.keyZ) {
      if (shift) {
        _redo();
      } else {
        _undo();
      }
      return KeyEventResult.handled;
    } else if (event.physicalKey == PhysicalKeyboardKey.keyY && !shift) {
      _redo();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 编辑变更回调（controller 监听器）：同步预览态并向撤销栈记录一步。
  ///
  /// 光标/选区移动也会触发本回调，此时文本未变；是否入栈由
  /// `NoteEditHistory.record` 内部判定（统一收敛），这里只负责同步状态。
  void _onEdit(String field) {
    if (_applyingHistory) return;
    title = _titleController.text;
    description = _descriptionController.text;
    NoteEditorState.setState(_effectiveNote, title, description);
    _history.record(
      title: _titleController.value,
      desc: _descriptionController.value,
      field: field,
    );
    setState(() {
      _canUndo = _history.canUndo;
      _canRedo = _history.canRedo;
    });
  }

  /// 撤销：取回上一步快照并把标题/正文还原到编辑前的状态。
  void _undo() {
    if (_previewMode || _isLocked) return;
    final EditSnapshot? snap = _history.undo();
    if (snap == null) return;
    _apply(snap.titleBefore, snap.descBefore);
  }

  /// 重做：把标题/正文还原到被撤销的那一步之后。
  void _redo() {
    if (_previewMode || _isLocked) return;
    final EditSnapshot? snap = _history.redo();
    if (snap == null) return;
    _apply(snap.titleAfter, snap.descAfter);
  }

  /// 把快照中的标题/正文写回两个 controller（含光标 selection），
  /// 并同步预览态与按钮可用性。用 [_applyingHistory] 守卫，避免回流到监听器被再次记录。
  void _apply(TextEditingValue titleValue, TextEditingValue descValue) {
    _applyingHistory = true;
    _titleController.value = titleValue;
    _descriptionController.value = descValue;
    _applyingHistory = false;
    title = titleValue.text;
    description = descValue.text;
    NoteEditorState.setState(_effectiveNote, title, description);
    setState(() {
      _canUndo = _history.canUndo;
      _canRedo = _history.canRedo;
    });
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

  /// 锁定笔记的 AppBar 指示：锁图标 + 「已锁定」文本，不改动标题/正文布局。
  Widget _lockedIndicator() {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        key: const Key('ui-note-locked-indicator'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.lock, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(
            'Locked'.tr(),
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _moreButton() {
    return IconButton(
      key: const Key('ui-note-button-more'),
      tooltip: 'More'.tr(),
      icon: const Icon(LucideIcons.ellipsisVertical),
      onPressed: _onMorePressed,
    );
  }

  /// 打开操作菜单：先读星标状态定文案，再按用户选择分派动作。
  ///
  /// 动作一律在 sheet 关闭之后执行（[showNoteActionsSheet] 只返回选择结果），
  /// 这样删除确认框与 toast 都挂在本页 context 上，不会用到已销毁的 sheet。
  Future<void> _onMorePressed() async {
    final SafeNote? note = _effectiveNote;
    if (note == null) return;

    // 无 meta 行即视为未加星/未锁定：元数据是懒创建的，只有设置过才会有行。
    // 优先用已加载的 _meta；为避免状态漂移再查一枚最新值（星标/锁定/标签）。
    final NoteMeta? meta = await NotesDatabase.instance.getNoteMeta(note.uuid);
    if (!mounted) return;
    setState(() => _meta = meta);
    final bool pinned = meta?.pinned ?? false;
    final bool locked = meta?.locked ?? false;

    final NoteAction? action = await showNoteActionsSheet(
      context,
      pinned: pinned,
      locked: locked,
    );
    if (!mounted || action == null) return;

    switch (action) {
      case NoteAction.copyAll:
        await _copyAll();
      case NoteAction.toggleStar:
        await _toggleStar(note, !pinned);
      case NoteAction.toggleLock:
        await _toggleLock(note, !locked);
      case NoteAction.editTags:
        await _editTags(note);
      case NoteAction.versionHistory:
        await _openVersionHistory(note);
      case NoteAction.delete:
        await _deleteNote(note);
    }
  }

  /// 复制全文到剪贴板：标题与正文之间空一行，空字段直接跳过不留空白。
  ///
  /// 复制的是编辑器当前内容（含未保存改动），与用户所见一致。
  Future<void> _copyAll() async {
    final List<String> parts = [
      title.trim(),
      description.trim(),
    ].where((s) => s.isNotEmpty).toList();
    final String text = parts.join('\n\n');
    if (text.isEmpty) {
      Log.ui.d('复制全文跳过: 内容为空');
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    // 隐私：只记录长度，不记录内容
    Log.ui.i(
      '复制笔记全文: uuid=${_effectiveNote?.uuid ?? "(新建)"} len=${text.length}',
    );
    if (mounted) showSnackBarMessage(context, 'Copied to clipboard'.tr());
  }

  /// 切换星标（本项目星标即置顶 pinned）。
  ///
  /// 只写 note_meta，不动笔记正文与 `updated_at`，因此不会触发正文重传。
  Future<void> _toggleStar(SafeNote note, bool pinned) async {
    await NotesDatabase.instance.setNotePinned(note.uuid, pinned);
    Log.note.i('笔记星标切换: uuid=${note.uuid} pinned=$pinned');
    if (!mounted) return;
    setState(() => _meta = _meta?.copyWith(pinned: pinned));
    showSnackBarMessage(context, pinned ? 'Starred'.tr() : 'Star removed'.tr());
  }

  /// 切换锁定（只读）。锁定后本页刷新为只读预览；解锁后恢复可编辑。
  ///
  /// 只写 note_meta，不动笔记正文与 `updated_at`。
  Future<void> _toggleLock(SafeNote note, bool locked) async {
    await NotesDatabase.instance.setNoteLocked(note.uuid, locked);
    Log.note.i('笔记锁定切换: uuid=${note.uuid} locked=$locked');
    if (!mounted) return;
    setState(() => _meta = _meta?.copyWith(locked: locked));
    // 解锁后回到预览态（不自动进入编辑，避免误触）；锁定态恒为只读预览。
    if (!locked) {
      setState(() => _previewMode = true);
    }
    showSnackBarMessage(
      context,
      locked ? 'Note locked'.tr() : 'Note unlocked'.tr(),
    );
  }

  /// 编辑笔记标签：打开全屏标签编辑页（见 [pushTagEditor]），行首勾选归属当前笔记。
  ///
  /// 标签只写 note_meta（payload 加密），不动正文与 `updated_at`，
  /// 不触发正文重传；新增标签同步进全局管理标签池（抽屉「标签」组来源）。
  Future<void> _editTags(SafeNote note) async {
    final NoteMeta? meta = await NotesDatabase.instance.getNoteMeta(note.uuid);
    final List<String> initialTags = meta?.tags ?? const [];
    if (!mounted) return;

    final TagEditorResult? result = await pushTagEditor(
      context,
      title: 'Edit Tags'.tr(),
      pool: PreferencesStorage.managedTags,
      selected: initialTags,
      selectionMode: true,
    );
    if (result == null || !mounted) return;

    final tags = NoteMeta.normalizeTags(result.selected);
    await NotesDatabase.instance.setNoteTags(note.uuid, tags);
    // 用返回的完整标签池覆盖全局管理池（含新增与删除），抽屉里立即可见。
    await PreferencesStorage.setManagedTags(result.pool);
    // 隐私：标签名本身即用户隐私，只记数量不记内容。
    Log.note.i('笔记标签更新: uuid=${note.uuid} count=${tags.length}');
    if (!mounted) return;
    // 重新读取元数据再 setState，确保底部标签即时刷新为最新值。
    final refreshed = await NotesDatabase.instance.getNoteMeta(note.uuid);
    if (!mounted) return;
    setState(() => _meta = refreshed);
    showSnackBarMessage(context, 'Tags saved'.tr());
  }

  /// 打开版本历史页面，返回后刷新编辑页状态（恢复操作可能改变了笔记内容）。
  Future<void> _openVersionHistory(SafeNote note) async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => VersionHistoryPage(note: note)));
    // 返回后重新从数据库加载笔记（恢复操作可能改变了内容）
    if (mounted) {
      final updated = await NotesDatabase.instance.readNoteByUuid(note.uuid);
      if (updated != null && mounted) {
        _effectiveNote = updated;
        title = updated.title == ' ' ? '' : updated.title;
        description = updated.description == ' ' ? '' : updated.description;
        NoteEditorState.setState(updated, title, description);
        // 同步编辑控制器，使回到编辑态时显示恢复后的内容；
        // 用守卫避免把“外部恢复”当作一次可撤销编辑，并重置历史基线。
        _applyingHistory = true;
        _titleController.text = title;
        _descriptionController.text = description;
        _applyingHistory = false;
        _history.init(
          TextEditingValue(text: title),
          TextEditingValue(text: description),
        );
        _canUndo = false;
        _canRedo = false;
        setState(() {});
      }
    }
  }

  Future<void> _deleteNote(SafeNote note) async {
    Log.ui.i('用户点击删除笔记(编辑页), 弹出确认对话框 uuid=${note.uuid}');
    await showDeleteConfirmation(
      context: context,
      onConfirm: () async {
        // 标记删除中，避免 PopScope 自动保存把已删笔记重新写回。
        setState(() => _isDeleting = true);
        // 删除前若有未保存改动，先丢弃（删除优先级高于保存）
        NoteEditorState.destroyValue();
        Log.note.i('用户确认删除笔记(移入回收站): uuid=${note.uuid} id=${note.id}');
        await NotesDatabase.instance.softDelete(note.id!);
        // 软删除（移入回收站）后触发自动同步，确保远端及时收到墓碑标记
        Log.sync.d('笔记软删除后触发自动同步');
        SyncService.instance.autoSync();
        await _closePage();
      },
    );
  }

  /// 复刻编辑态 ShadInputFormField 的有效文字样式，保证预览与编辑逐像素一致。
  ///
  /// 不覆盖 base 的 fontFamily——调用方负责传入正确字体的 base：
  /// - 纯文本预览：传 [EditorText.title()]/[EditorText.body()]（携带笔记字体，
  ///   "系统"档时即全局字体）；
  /// - Markdown 预览：传 [AppText.body.copyWith(fontFamily: appFontFamilyFor(EditorText.fontType), ...)]
  ///   （携带笔记字体，与编辑态一致）。
  TextStyle _editorLikeStyle(BuildContext context, TextStyle base) {
    final shad = ShadTheme.of(context);
    return shad.textTheme.muted
        .copyWith(color: shad.colorScheme.foreground)
        .merge(base);
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
              textAlign: EditorText.textAlign,
            ),
          // 标签展示到**正文最底部**（不放标题下方），靠左 chip 排布。
          if (_tags.isNotEmpty) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                alignment: WrapAlignment.start,
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final tag in _tags)
                    Chip(
                      key: Key('ui-note-tag-$tag'),
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      label: Text(
                        tag,
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Markdown 预览样式：正文 16（与编辑态一致），标题 h1-h6 逐级递减的多级
  /// 字号（24→20→18→17→16→16），blockquote / code 显式设样式，避免落到
  /// Material 默认排印与 shad 风格脱节。Markdown 预览与纯文本编辑态不同，
  /// 是唯一带多级标题排版的视图。
  ///
  /// 字体族跟随笔记字体设置（EditorText.fontType），与编辑态/纯文本预览一致；
  /// 代码块始终用 monospace，不受笔记字体影响。
  /// P1-20：Markdown 预览暂不支持自定义字号，正文/标题固定用 AppText.body
  /// 基准与 24/20/18/17 固定层级（与编辑/预览页的 EditorText 调节解耦），
  /// 避免 Markdown 众多标签（列表/引用/代码/表格等）字号联动失控、排印错乱。
  MarkdownStyleSheet _markdownStyleSheet(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final TextStyle uiBase = _editorLikeStyle(
      context,
      AppText.body.copyWith(
        fontFamily: appFontFamilyFor(EditorText.fontType),
        fontFamilyFallback: appFontFallbackFor(EditorText.fontType),
      ),
    );
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

  bool isNoteNewOrContentChanged() {
    if (_effectiveNote == null) {
      if (title.isNotEmpty || description.isNotEmpty) return true;
    } else {
      if (_effectiveNote!.title != title ||
          _effectiveNote!.description != description) {
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
