/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.
*/

library;

// 笔记历史版本页面（全屏）。
//
// 设计文档：docs/feature-note-version-history-design.md §5
//
// 布局：AppBar + 版本下拉框 + [差异开关] + 内容区 + 底部恢复按钮。
// 默认显示选中版本的完整文本，打开开关后显示与当前版本的 diff。
// Diff 方向：diff(version, current)，
// 绿色 = 此版本之后新增，红色 = 此版本之后被删除。

import 'package:flutter/material.dart';

import 'package:core/core.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:safenotes/sync/sync_service.dart';
import 'package:safenotes/utils/editor_text.dart';
import 'package:safenotes/utils/note_diff.dart';
import 'package:safenotes/utils/snack_message.dart';
import 'package:safenotes/widgets/app_dialogs.dart';

/// Diff 高亮配色（Google/GitHub 标准 Red/Green Palette）。
///
/// 背景统一用半透明色（alpha 0.15），确保 Flutter 系统选区高亮
/// 能透过背景色可见（RenderParagraph 先画选区再画 backgroundColor，
/// 不透明背景会完全遮盖选区）。
class _DiffColors {
  final Color insertionBg;
  final Color insertionFg;
  final Color deletionBg;
  final Color deletionFg;

  const _DiffColors._({
    required this.insertionBg,
    required this.insertionFg,
    required this.deletionBg,
    required this.deletionFg,
  });

  /// 明亮模式
  static const light = _DiffColors._(
    insertionBg: Color.fromRGBO(46, 160, 67, 0.15),
    insertionFg: Color(0xFF1A7F37),
    deletionBg: Color.fromRGBO(248, 81, 73, 0.15),
    deletionFg: Color(0xFFCF222E),
  );

  /// 暗黑模式
  static const dark = _DiffColors._(
    insertionBg: Color.fromRGBO(46, 160, 67, 0.15),
    insertionFg: Color(0xFF7EE787),
    deletionBg: Color.fromRGBO(248, 81, 73, 0.15),
    deletionFg: Color(0xFFFF7B72),
  );

  static _DiffColors of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;
}

class VersionHistoryPage extends StatefulWidget {
  final SafeNote note;

  const VersionHistoryPage({super.key, required this.note});

  @override
  State<VersionHistoryPage> createState() => _VersionHistoryPageState();
}

class _VersionHistoryPageState extends State<VersionHistoryPage> {
  /// 版本列表（DESC 排序：index 0 = 最新，index N-1 = 最旧）
  List<NoteVersion>? _versions;
  int _selectedIndex = 0;
  NoteDiffResult? _diffResult;
  bool _isLoading = false;
  bool _isLocked = false;

  /// 默认显示完整版本文本，开关打开后显示 diff
  bool _showDiff = false;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final uuid = widget.note.uuid;
    List<NoteVersion> versions;
    try {
      versions = await NotesDatabase.instance.readVersions(uuid);
    } on Exception catch (e, st) {
      // H3：读取失败不能永久卡骨架屏——降级为空列表并提示
      Log.note.e('版本历史加载失败', error: e, stackTrace: st);
      versions = const [];
    }
    final meta = await NotesDatabase.instance.getNoteMeta(uuid);
    if (!mounted) return;
    setState(() {
      _versions = versions;
      _selectedIndex = 0;
      _isLocked = meta?.locked ?? false;
    });
    if (versions.isNotEmpty && _showDiff) {
      await _updateDiff();
    }
  }

  /// diff 计算代际序号：快速连切版本时丢弃乱序返回的旧结果。
  int _diffSeq = 0;

  Future<void> _updateDiff() async {
    if (_versions == null || _versions!.isEmpty) return;
    final seq = ++_diffSeq;
    setState(() => _isLoading = true);

    final current = await NotesDatabase.instance.readNoteByUuid(
      widget.note.uuid,
    );
    if (current == null || !mounted || seq != _diffSeq) {
      // 笔记已不存在 / 页面已销毁 / 已有更新的请求在途：复位加载态，
      // 避免永久转圈（H3）
      if (mounted && seq == _diffSeq) {
        setState(() => _isLoading = false);
      }
      return;
    }

    final version = _versions![_selectedIndex];
    final diff = await computeNoteDiffAsync(current, version);

    if (!mounted || seq != _diffSeq) return;
    setState(() {
      _diffResult = diff;
      _isLoading = false;
    });
  }

  Future<void> _onVersionChanged(int? index) async {
    if (index == null || index == _selectedIndex) return;
    setState(() => _selectedIndex = index);
    if (_showDiff) {
      await _updateDiff();
    }
  }

  void _onToggleDiff(bool value) {
    setState(() => _showDiff = value);
    // H3：每次开启都必须重算——此前仅首次（_diffResult == null）计算，
    // 「开→关→切版本→再开」会显示旧版本的过期 diff
    if (value && _versions != null && _versions!.isNotEmpty) {
      _updateDiff();
    }
  }

  Future<void> _onRestore() async {
    if (_versions == null || _versions!.isEmpty) return;
    final version = _versions![_selectedIndex];

    final current = await NotesDatabase.instance.readNoteByUuid(
      widget.note.uuid,
    );
    if (current == null || !mounted) return;

    final confirmed = await showAppConfirm(
      context,
      title: 'Restore to this version'.tr(),
      message:
          'Current content will be replaced. A version of the current content will be saved automatically.'
              .tr(),
      confirmLabel: 'Restore'.tr(),
    );
    if (confirmed != true || !mounted) return;

    await NotesDatabase.instance.restoreVersion(version.id!, current);

    if (!mounted) return;
    showSnackBarMessage(context, 'Restore successful'.tr());
    SyncService.instance.autoSync();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Version History'.tr())),
      body: _buildBody(),
      bottomNavigationBar: _buildRestoreButton(),
    );
  }

  Widget _buildBody() {
    if (_versions == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_versions!.isEmpty) {
      return _buildEmptyState();
    }
    return Column(
      children: [
        _buildVersionSelector(),
        const Divider(height: 1),
        Expanded(child: _buildContentArea()),
      ],
    );
  }

  Widget _buildVersionSelector() {
    // 版本编号：最旧 = 版本 1，最新 = 版本 N
    // _versions 按 DESC 排序（index 0 = 最新），所以显示编号 = length - index
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          const Icon(LucideIcons.history, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButton<int>(
              value: _selectedIndex,
              isExpanded: true,
              underline: const SizedBox(),
              items: _versions!.asMap().entries.map((entry) {
                final v = entry.value;
                final displayNumber = _versions!.length - entry.key;
                return DropdownMenuItem(
                  value: entry.key,
                  child: Text(
                    '${'Version'.tr()} $displayNumber \u00b7 ${_formatTime(v.savedAt)}',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                );
              }).toList(),
              onChanged: _onVersionChanged,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'Show diff'.tr(),
            style: Theme.of(context).textTheme.labelMedium,
          ),
          Switch(value: _showDiff, onChanged: _onToggleDiff),
        ],
      ),
    );
  }

  Widget _buildContentArea() {
    if (_showDiff) {
      return _buildDiffArea();
    }
    return _buildFullTextArea();
  }

  /// 显示选中版本的完整文本（默认视图）
  Widget _buildFullTextArea() {
    final version = _versions![_selectedIndex];

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSelectableText(version.title, isTitle: true),
          const SizedBox(height: 8),
          const Divider(height: 1, thickness: 1),
          const SizedBox(height: 8),
          _buildSelectableText(version.description, isTitle: false),
        ],
      ),
    );
  }

  /// 显示 diff 视图
  Widget _buildDiffArea() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    final diff = _diffResult;
    if (diff == null) return const SizedBox.shrink();
    if (!diff.hasDifference) {
      return _buildNoDifference();
    }

    // 标题始终显示，避免切换版本时布局跳动
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildDiffText(diff.titleDiff, isTitle: true),
          const SizedBox(height: 8),
          const Divider(height: 1, thickness: 1),
          const SizedBox(height: 8),
          _buildDiffText(diff.descriptionDiff, isTitle: false),
        ],
      ),
    );
  }

  /// 可选择复制的纯文本展示（完整版本视图）
  Widget _buildSelectableText(String text, {required bool isTitle}) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
      ),
      child: SelectableText(
        text,
        style: (isTitle ? EditorText.title() : EditorText.body()).copyWith(
          color: colorScheme.onSurface,
        ),
        textAlign: isTitle ? TextAlign.start : EditorText.textAlign,
      ),
    );
  }

  /// 可选择复制的 diff 高亮展示
  Widget _buildDiffText(List<DiffSegment> segments, {required bool isTitle}) {
    final colorScheme = Theme.of(context).colorScheme;
    final dc = _DiffColors.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
      ),
      child: SelectableText.rich(
        TextSpan(
          children: segments.map((seg) {
            switch (seg.type) {
              case DiffSegmentType.insertion:
                return TextSpan(
                  text: seg.text,
                  style: TextStyle(
                    backgroundColor: dc.insertionBg,
                    color: dc.insertionFg,
                  ),
                );
              case DiffSegmentType.deletion:
                return TextSpan(
                  text: seg.text,
                  style: TextStyle(
                    backgroundColor: dc.deletionBg,
                    color: dc.deletionFg,
                    decoration: TextDecoration.lineThrough,
                  ),
                );
              case DiffSegmentType.equal:
                return TextSpan(text: seg.text);
            }
          }).toList(),
        ),
        style: (isTitle ? EditorText.title() : EditorText.body()).copyWith(
          color: colorScheme.onSurface,
        ),
        textAlign: isTitle ? TextAlign.start : EditorText.textAlign,
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            LucideIcons.history,
            size: 48,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text('No version history yet'.tr()),
          const SizedBox(height: 8),
          Text(
            'Versions are saved automatically when you edit.'.tr(),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _buildNoDifference() {
    final dc = _DiffColors.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(LucideIcons.check, size: 36, color: dc.insertionFg),
          const SizedBox(height: 12),
          Text('No differences from current version'.tr()),
        ],
      ),
    );
  }

  Widget _buildRestoreButton() {
    // 完整文本视图下始终可恢复（无需 diff 存在差异）
    // diff 视图下需要有差异才可恢复
    final canRestore =
        !_isLocked &&
        _versions != null &&
        _versions!.isNotEmpty &&
        (!_showDiff || (_diffResult?.hasDifference ?? false));

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: ShadButton(
          width: double.infinity,
          enabled: canRestore,
          onPressed: _onRestore,
          child: Text(
            _isLocked
                ? 'Unlock note to restore'.tr()
                : 'Restore to this version'.tr(),
          ),
        ),
      ),
    );
  }

  String _formatTime(int millis) {
    final dt = DateTime.fromMillisecondsSinceEpoch(millis);
    return DateFormat('yyyy-MM-dd HH:mm').format(dt);
  }
}
