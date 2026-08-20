/*
 * Copyright (C) mcxiaoke 2026 - All Rights Reserved.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * 字体样式设置页（原「编辑器字体大小」升级为「字体样式」）。
 *
 * 交互设计（严格参考主题色子页 theme_color_setting.dart）：
 * - 进入页面时控制器初始化为「当前已保存」字体类型与字体大小档位；
 * - 选择仅本地预览（顶部预览区跟随变化），不立即生效；
 * - 底部「Apply」按钮点击后才真正写入 PreferencesStorage，并通知主题重建
 *   （字体类型对整个 App 生效、字体大小仅作用于笔记编辑/预览页）；
 * - 无取消键，返回即放弃本地改动。
 *
 * 控件选型：
 * - 字体类型：一排横向三个分段按钮（衬线 / 非衬线 / 等宽），选中即应用该字体；
 * - 字体大小：一排横向四个分段按钮（小 / 标准 / 大 / 特大），命中区域大、触感明确，
 *   比滑块在真机上更易用；均使用 Material 原生 SegmentedButton
 *   （expandedInsets 撑满整行、单选中、showSelectedIcon 关闭避免勾选图标挤压文案）。
 *
 * 关键：字体类型/大小各自用「本地 int 状态 _fontTypeIndex / _fontSizeIndex」作为
 * 唯一数据源，选中态与预览区都读它，onSelectionChanged 直接 setState 更新。
 * 无需外部 controller，自然避免 rebuild 时 initialValue 回写导致的失同步问题。
 *
 * 顶部预览区用 AppName（标题行）+ AppSlogan（正文行），实时跟随选择；
 * 两行均用 StrutStyle 按「最大档位字号」预留行高，切换档位时文字字号变化
 * 但行高恒定，避免布局高度跳动导致下方内容（含 Apply 栏）上下漂移。
 */

import 'package:flutter/material.dart';

import 'package:easy_localization/easy_localization.dart';
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/app_theme.dart';
import 'package:safenotes/utils/editor_text.dart';
import 'package:safenotes/utils/platform_ui.dart';
import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/widgets/shad_settings_tiles.dart';

/// 字体样式选择页。
class FontStylePicker extends StatefulWidget {
  const FontStylePicker({super.key});

  @override
  State<FontStylePicker> createState() => _FontStylePickerState();
}

class _FontStylePickerState extends State<FontStylePicker> {
  // 本地选择状态，作为「唯一数据源」。
  late int _fontTypeIndex;
  late int _fontSizeIndex;

  @override
  void initState() {
    super.initState();
    _fontTypeIndex = EditorText.fontType.index;
    _fontSizeIndex = PreferencesStorage.editorFontSizeIndex;
  }

  /// 当前待应用的字体类型。
  AppFontType get _pendingFontType => AppFontType.values[_fontTypeIndex];

  /// 当前待应用的字体大小档位。
  int get _pendingIndex => _fontSizeIndex;

  /// 是否有「待应用」的改动：字体类型或字体大小任一 ≠ 已保存值才允许 Apply。
  bool get _hasPendingChange =>
      _fontTypeIndex != EditorText.fontType.index ||
      _fontSizeIndex != PreferencesStorage.editorFontSizeIndex;

  /// 应用所选：写入持久化，通知主题重建（全局字体类型生效），然后返回上一级。
  void _apply() {
    if (!_hasPendingChange) return;
    PreferencesStorage.setFontFamilyTypeIndex(_pendingFontType.index);
    PreferencesStorage.setEditorFontSizeIndex(_pendingIndex).then((_) {
      if (mounted) {
        // 字体类型对整个 App 生效：主题重建由 ThemeProvider 驱动。
        Provider.of<ThemeProvider>(context, listen: false).notifyThemeChanged();
        Navigator.of(context).pop();
      }
    });
  }

  /// 字体类型选择回调。
  void _onFontTypeChanged(Set<int> selection) {
    if (selection.isNotEmpty) {
      setState(() => _fontTypeIndex = selection.first);
    }
  }

  /// 字体大小选择回调。
  void _onFontSizeChanged(Set<int> selection) {
    if (selection.isNotEmpty) {
      setState(() => _fontSizeIndex = selection.first);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text('Font style'.tr(), style: appBarTitle)),
      // 底部固定操作栏：Apply 按钮始终可见（不随内容滚动）。
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
      ]),
    );
  }

  /// 字体类型显示名（本地化）：衬线 / 非衬线 / 等宽。
  static String _fontTypeLabel(AppFontType t) {
    switch (t) {
      case AppFontType.serif:
        return 'Serif'.tr();
      case AppFontType.sans:
        return 'Sans-serif'.tr();
      case AppFontType.mono:
        return 'Monospace'.tr();
    }
  }

  /// 构建字体类型选项列表。
  List<ButtonSegment<int>> _fontTypeItems() {
    return [
      for (final t in AppFontType.values)
        ButtonSegment(
          value: t.index,
          label: Text(
            _fontTypeLabel(t),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
    ];
  }

  /// 构建字体大小选项列表。
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

  /// Material SegmentedButton 的统一样式：与自绘 SegmentedGroup 视觉接近——
  /// 选中段填充主题主色、未选段透明，整组圆角边框。
  static ButtonStyle _segmentStyle(ShadThemeData theme) {
    return SegmentedButton.styleFrom(
      // backgroundColor: Colors.transparent,
      // foregroundColor: theme.colorScheme.foreground,
      // selectedBackgroundColor: theme.colorScheme.primary,
      // selectedForegroundColor: theme.colorScheme.primaryForeground,
      side: BorderSide(color: theme.colorScheme.border),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      // padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    );
  }

  /// 顶部预览：标题行 AppName + 正文行 AppSlogan，实时跟随字体类型与大小；
  /// 标签区分 Current（=已保存）/ Preview（=选择中）。
  Widget _preview(BuildContext context, ShadThemeData theme) {
    final isCurrent = !_hasPendingChange;
    final tag = isCurrent
        ? '${'Current'.tr()}: ${_fontTypeLabel(_pendingFontType)} · '
              '${EditorText.labelOf(_pendingIndex)}'
        : '${'Preview'.tr()}: ${_fontTypeLabel(_pendingFontType)} · '
              '${EditorText.labelOf(_pendingIndex)}';

    // 按最大档位预留行高：标题=最大正文+4，正文=最大正文。
    final titleStrut = StrutStyle(
      fontSize: EditorText.bodySizes.last + EditorText.titleDelta,
      forceStrutHeight: true,
    );
    final bodyStrut = StrutStyle(
      fontSize: EditorText.bodySizes.last,
      forceStrutHeight: true,
    );

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
          // 预览标题行：AppName，字号 = 档位标题尺寸，字体族 = 待选类型。
          Text(
            SafeNotesConfig.appName,
            style: EditorText.titleOf(_pendingIndex, _pendingFontType),
            strutStyle: titleStrut,
          ),
          const SizedBox(height: 6),
          // 预览正文行：AppSlogan，字号 = 档位正文字尺寸，字体族 = 待选类型。
          Text(
            SafeNotesConfig.appSlogan,
            style: EditorText.bodyOf(_pendingIndex, _pendingFontType),
            strutStyle: bodyStrut,
          ),
        ],
      ),
    );
  }

  /// 字体类型选择区：一排横向三个分段按钮（衬线 / 非衬线 / 等宽），
  /// 选中态由 [_fontTypeIndex] 驱动，Apply 才写入。
  Widget _fontTypeCard(BuildContext context, ShadThemeData theme) {
    return ShadCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Font family'.tr(),
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
        ],
      ),
    );
  }

  /// 字体大小选择区：一排横向四个分段按钮（小 / 标准 / 大 / 特大），
  /// 选中态由 [_fontSizeIndex] 驱动。
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
}
