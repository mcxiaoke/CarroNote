/*
 * Copyright (C) mcxiaoke 2026 - All Rights Reserved.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * 笔记样式设置页（原「字体样式」升级为「笔记样式」）。
 *
 * 作用范围：仅笔记编辑态（TextField）与纯文本预览（SelectableText），
 * 不作用于 Markdown 预览（Markdown 只跟随全局字体）。
 *
 * 四组设置项：
 * - 字体类型：系统（跟随全局）/ 非衬线 / 衬线 / 等宽 → noteFontFamilyTypeIndex
 * - 字号：小 / 标准 / 大 / 特大 → editorFontSizeIndex
 * - 行高（仅正文）：紧凑 / 标准 / 宽松 / 特松 → noteLineHeightIndex
 * - 正文对齐：起始 / 居中 / 两端 → noteTextAlignIndex
 *
 * 交互与全局字体设置页（FontSettingsPicker）互不写对方偏好。
 */

import 'package:flutter/material.dart';

import 'package:easy_localization/easy_localization.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/utils/editor_text.dart';
import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/widgets/shad_settings_tiles.dart';

/// 笔记样式设置页。
class NoteStylePicker extends StatefulWidget {
  const NoteStylePicker({super.key});

  @override
  State<NoteStylePicker> createState() => _NoteStylePickerState();
}

class _NoteStylePickerState extends State<NoteStylePicker> {
  // 本地选择状态，作为「唯一数据源」。
  late int _fontTypeIndex;
  late int _fontSizeIndex;
  late int _lineHeightIndex;
  late int _textAlignIndex;

  @override
  void initState() {
    super.initState();
    _fontTypeIndex = PreferencesStorage.noteFontFamilyTypeIndex;
    _fontSizeIndex = PreferencesStorage.editorFontSizeIndex;
    _lineHeightIndex = PreferencesStorage.noteLineHeightIndex;
    _textAlignIndex = PreferencesStorage.noteTextAlignIndex;
  }

  /// 是否有「待应用」的改动：任一设置项 ≠ 已保存值才允许 Apply。
  bool get _hasPendingChange =>
      _fontTypeIndex != PreferencesStorage.noteFontFamilyTypeIndex ||
      _fontSizeIndex != PreferencesStorage.editorFontSizeIndex ||
      _lineHeightIndex != PreferencesStorage.noteLineHeightIndex ||
      _textAlignIndex != PreferencesStorage.noteTextAlignIndex;

  /// 应用所选：写入四个偏好，返回上一级。
  ///
  /// 不触发 notifyThemeChanged（笔记字体不作用于全局 TextTheme），
  /// 编辑/预览页下次进入重建即生效。
  void _apply() {
    if (!_hasPendingChange) return;
    PreferencesStorage.setNoteFontFamilyTypeIndex(_fontTypeIndex);
    PreferencesStorage.setEditorFontSizeIndex(_fontSizeIndex);
    PreferencesStorage.setNoteLineHeightIndex(_lineHeightIndex);
    PreferencesStorage.setNoteTextAlignIndex(_textAlignIndex);
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  // ---- 回调 ----

  void _onFontTypeChanged(Set<int> selection) {
    if (selection.isNotEmpty) {
      setState(() => _fontTypeIndex = selection.first);
    }
  }

  void _onFontSizeChanged(Set<int> selection) {
    if (selection.isNotEmpty) {
      setState(() => _fontSizeIndex = selection.first);
    }
  }

  void _onLineHeightChanged(Set<int> selection) {
    if (selection.isNotEmpty) {
      setState(() => _lineHeightIndex = selection.first);
    }
  }

  void _onTextAlignChanged(Set<int> selection) {
    if (selection.isNotEmpty) {
      setState(() => _textAlignIndex = selection.first);
    }
  }

  // ---- 显示名 ----

  /// 笔记字体类型显示名（本地化）：系统 / 非衬线 / 衬线 / 等宽。
  static String _fontTypeLabel(int idx) {
    return switch (idx) {
      0 => 'System'.tr(),
      1 => 'Sans-serif'.tr(),
      2 => 'Serif'.tr(),
      3 => 'Monospace'.tr(),
      _ => 'System'.tr(),
    };
  }

  /// 行高档位显示名（本地化）。
  static String _lineHeightLabel(int idx) {
    return switch (idx) {
      0 => 'Compact'.tr(),
      1 => 'Standard'.tr(),
      2 => 'Relaxed'.tr(),
      3 => 'Extra relaxed'.tr(),
      _ => 'Standard'.tr(),
    };
  }

  /// 正文对齐显示名（本地化）。
  static String _textAlignLabel(int idx) {
    return switch (idx) {
      0 => 'Align start'.tr(),
      1 => 'Center'.tr(),
      2 => 'Justify'.tr(),
      _ => 'Align start'.tr(),
    };
  }

  // ---- 选项列表 ----

  List<ButtonSegment<int>> _fontTypeItems() {
    return [
      for (var i = 0; i < 4; i++)
        ButtonSegment(
          value: i,
          label: Text(
            _fontTypeLabel(i),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
    ];
  }

  List<ButtonSegment<int>> _fontSizeItems() {
    return [
      for (var i = 0; i < EditorText.bodySizes.length; i++)
        ButtonSegment(
          value: i,
          label: Text(
            EditorText.labelOf(i),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
    ];
  }

  List<ButtonSegment<int>> _lineHeightItems() {
    return [
      for (var i = 0; i < PreferencesStorage.noteLineHeights.length; i++)
        ButtonSegment(
          value: i,
          label: Text(
            _lineHeightLabel(i),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
    ];
  }

  List<ButtonSegment<int>> _textAlignItems() {
    return [
      for (var i = 0; i < 3; i++)
        ButtonSegment(
          value: i,
          label: Text(
            _textAlignLabel(i),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
    ];
  }

  // ---- 样式 ----

  static ButtonStyle _segmentStyle(ShadThemeData theme) {
    return SegmentedButton.styleFrom(
      side: BorderSide(color: theme.colorScheme.border),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    );
  }

  // ---- 预览区 ----

  Widget _preview(BuildContext context, ShadThemeData theme) {
    final isCurrent = !_hasPendingChange;
    final tag = isCurrent
        ? '${'Current'.tr()}: ${_fontTypeLabel(_fontTypeIndex)} · '
              '${EditorText.labelOf(_fontSizeIndex)}'
        : '${'Preview'.tr()}: ${_fontTypeLabel(_fontTypeIndex)} · '
              '${EditorText.labelOf(_fontSizeIndex)}';

    final pendingHeight = EditorText.lineHeightOf(_lineHeightIndex);
    final pendingAlign = EditorText.textAlignOf(_textAlignIndex);

    // 预览文案：多行正文以体现行高与对齐效果。
    const previewBody =
        'SafeNotes keeps your notes encrypted and private. '
        'No cloud, no tracking, just your thoughts, secured.\n'
        'Second paragraph to show line height and alignment.';

    return ShadCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tag,
            style: theme.textTheme.p.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          Text(
            SafeNotesConfig.appName,
            style: EditorText.titleOf(_fontSizeIndex, _fontTypeIndex),
          ),
          const SizedBox(height: 6),
          Text(
            previewBody,
            style: EditorText.bodyOf(
              _fontSizeIndex,
              _fontTypeIndex,
              pendingHeight,
            ),
            textAlign: pendingAlign,
          ),
        ],
      ),
    );
  }

  // ---- 选择卡片 ----

  Widget _fontTypeCard(BuildContext context, ShadThemeData theme) {
    return ShadCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Note font family'.tr(),
            style: theme.textTheme.p.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          SegmentedButton<int>(
            segments: _fontTypeItems(),
            selected: {_fontTypeIndex},
            onSelectionChanged: _onFontTypeChanged,
            showSelectedIcon: false,
            expandedInsets: EdgeInsets.zero,
            style: _segmentStyle(theme),
          ),
          const SizedBox(height: 8),
          Text(
            'Notes editor and preview only'.tr(),
            style: theme.textTheme.muted,
          ),
        ],
      ),
    );
  }

  Widget _fontSizeCard(BuildContext context, ShadThemeData theme) {
    return ShadCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Font size'.tr(),
            style: theme.textTheme.p.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          SegmentedButton<int>(
            segments: _fontSizeItems(),
            selected: {_fontSizeIndex},
            onSelectionChanged: _onFontSizeChanged,
            showSelectedIcon: false,
            expandedInsets: EdgeInsets.zero,
            style: _segmentStyle(theme),
          ),
        ],
      ),
    );
  }

  Widget _lineHeightCard(BuildContext context, ShadThemeData theme) {
    return ShadCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Line height'.tr(),
            style: theme.textTheme.p.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          SegmentedButton<int>(
            segments: _lineHeightItems(),
            selected: {_lineHeightIndex},
            onSelectionChanged: _onLineHeightChanged,
            showSelectedIcon: false,
            expandedInsets: EdgeInsets.zero,
            style: _segmentStyle(theme),
          ),
        ],
      ),
    );
  }

  Widget _textAlignCard(BuildContext context, ShadThemeData theme) {
    return ShadCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Text align'.tr(),
            style: theme.textTheme.p.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          SegmentedButton<int>(
            segments: _textAlignItems(),
            selected: {_textAlignIndex},
            onSelectionChanged: _onTextAlignChanged,
            showSelectedIcon: false,
            expandedInsets: EdgeInsets.zero,
            style: _segmentStyle(theme),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text('Note style'.tr(), style: appBarTitle)),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Align(
            alignment: Alignment.center,
            heightFactor: 1.0,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Markdown preview does not support font size adjustment'
                        .tr(),
                    style: theme.textTheme.muted,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  ShadButton(
                    width: double.infinity,
                    onPressed: _hasPendingChange ? _apply : null,
                    child: Text('Apply'.tr()),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      body: shadSettingsList([
        _preview(context, theme),
        const SizedBox(height: 12),
        _fontTypeCard(context, theme),
        const SizedBox(height: 12),
        _fontSizeCard(context, theme),
        const SizedBox(height: 12),
        _lineHeightCard(context, theme),
        const SizedBox(height: 12),
        _textAlignCard(context, theme),
      ]),
    );
  }
}
