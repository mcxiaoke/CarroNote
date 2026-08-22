/*
 * Copyright (C) mcxiaoke 2026 - All Rights Reserved.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * 全局字体设置页：选择 App 全局字体类型（非衬线 / 衬线 / 等宽），
 * 对整个 App 生效（经 applyUiFont 注入 TextTheme）。
 *
 * 与「笔记样式」页（NoteStylePicker）互不干扰：
 * - 本页写入 fontFamilyTypeIndex（全局字体类型）；
 * - 笔记样式页写入 noteFontFamilyTypeIndex（笔记专属字体类型）。
 */

import 'package:flutter/material.dart';

import 'package:easy_localization/easy_localization.dart';
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/app_theme.dart';
import 'package:safenotes/utils/platform_ui.dart';
import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/widgets/shad_settings_tiles.dart';

/// 全局字体设置页。
class FontSettingsPicker extends StatefulWidget {
  const FontSettingsPicker({super.key});

  @override
  State<FontSettingsPicker> createState() => _FontSettingsPickerState();
}

class _FontSettingsPickerState extends State<FontSettingsPicker> {
  late int _fontTypeIndex;

  @override
  void initState() {
    super.initState();
    _fontTypeIndex = PreferencesStorage.fontFamilyTypeIndex;
  }

  bool get _hasPendingChange =>
      _fontTypeIndex != PreferencesStorage.fontFamilyTypeIndex;

  /// 当前待应用的字体类型。
  AppFontType get _pendingFontType =>
      AppFontType.values[_fontTypeIndex.clamp(
        0,
        AppFontType.values.length - 1,
      )];

  void _onFontTypeChanged(Set<int> selection) {
    if (selection.isNotEmpty) {
      setState(() => _fontTypeIndex = selection.first);
    }
  }

  /// 应用所选：写入全局字体类型，通知主题重建（对整个 App 生效），返回。
  void _apply() {
    if (!_hasPendingChange) return;
    PreferencesStorage.setFontFamilyTypeIndex(_fontTypeIndex);
    if (mounted) {
      Provider.of<ThemeProvider>(context, listen: false).notifyThemeChanged();
      Navigator.of(context).pop();
    }
  }

  /// 字体类型显示名（本地化）。
  static String _fontTypeLabel(AppFontType t) {
    return switch (t) {
      AppFontType.serif => 'Serif'.tr(),
      AppFontType.sans => 'Sans-serif'.tr(),
      AppFontType.mono => 'Monospace'.tr(),
    };
  }

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

  static ButtonStyle _segmentStyle(ShadThemeData theme) {
    return SegmentedButton.styleFrom(
      side: BorderSide(color: theme.colorScheme.border),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    );
  }

  Widget _preview(BuildContext context, ShadThemeData theme) {
    final isCurrent = !_hasPendingChange;
    final tag = isCurrent
        ? '${'Current'.tr()}: ${_fontTypeLabel(_pendingFontType)}'
        : '${'Preview'.tr()}: ${_fontTypeLabel(_pendingFontType)}';

    final family = appFontFamilyFor(_pendingFontType);
    final fallback = appFontFallbackFor(_pendingFontType);

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
            style: TextStyle(
              fontFamily: family,
              fontFamilyFallback: fallback,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            SafeNotesConfig.appSlogan,
            style: TextStyle(
              fontFamily: family,
              fontFamilyFallback: fallback,
              fontSize: 16,
            ),
          ),
        ],
      ),
    );
  }

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
          const SizedBox(height: 8),
          Text('Applies to entire app'.tr(), style: theme.textTheme.muted),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text('Font settings'.tr(), style: appBarTitle)),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Align(
            alignment: Alignment.center,
            heightFactor: 1.0,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: ShadButton(
                width: double.infinity,
                onPressed: _hasPendingChange ? _apply : null,
                child: Text('Apply'.tr()),
              ),
            ),
          ),
        ),
      ),
      body: shadSettingsList([
        _preview(context, theme),
        const SizedBox(height: 12),
        _fontTypeCard(context, theme),
      ]),
    );
  }
}
