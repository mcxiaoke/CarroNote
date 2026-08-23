/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You can use, distribute and modify this code under
* terms of the GPL-3.0+ license.
*/

// 笔记颜色选择底部 Sheet。
//
// 与 NoteActionsSheet 同构：showShadSheet + 限宽居中 + 自绘背景/抓手。
// 颜色选项固定使用 Google Keep 同款 11 色色板（kNoteColorPalette），
// 加上第一个「默认」选项（恢复跟随主题取色）。
//
// 返回 [NoteColorResult]?：
// - null：用户关闭了 sheet（滑动关闭 / 点击遮罩），不做任何操作。
// - NoteColorResult.clear()：用户选择了「默认」，清除笔记颜色。
// - NoteColorResult.color(value)：用户选择了一个具体颜色。

import 'package:flutter/material.dart';

import 'package:easy_localization/easy_localization.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/utils/notes_color.dart';
import 'package:safenotes/utils/styles.dart';

/// 颜色选择结果，区分「关闭 sheet」与「选择默认色」。
///
/// - [NoteColorResult.color]：用户选择了一个具体颜色。
/// - [NoteColorResult.clear]：用户选择了「默认」（清除颜色）。
///
/// sheet 被关闭（非主动选择）时 `showNoteColorPicker` 返回 `null`。
class NoteColorResult {
  const NoteColorResult._(this.color, {required this.isClear});

  /// 用户选择的 ARGB int 值；`null` 表示选择「默认」（清除颜色）。
  final int? color;

  /// 是否为「清除颜色」操作。
  final bool isClear;

  /// 用户选择了一个具体颜色。
  const NoteColorResult.color(int value) : this._(value, isClear: false);

  /// 用户选择了「默认」（清除颜色）。
  const NoteColorResult.clear() : this._(null, isClear: true);
}

/// 弹出颜色选择 Sheet，返回 [NoteColorResult]?。
///
/// - [currentColor]：当前已设置的颜色（用于高亮选中态），null 表示未设置。
/// - 返回值：
///   - `null`：用户关闭了 sheet（不做任何操作）。
///   - [NoteColorResult.color]：用户选择了一个具体颜色。
///   - [NoteColorResult.clear]：用户选择了「默认」（清除颜色）。
Future<NoteColorResult?> showNoteColorPicker(
  BuildContext context, {
  int? currentColor,
}) {
  return showShadSheet<NoteColorResult>(
    context: context,
    side: ShadSheetSide.bottom,
    builder: (context) => ShadSheet(
      padding: EdgeInsets.zero,
      backgroundColor: Colors.transparent,
      border: Border.all(color: Colors.transparent),
      radius: const BorderRadius.vertical(top: Radius.circular(16)),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kDialogMaxWidthWide),
          child: _NoteColorSheet(currentColor: currentColor),
        ),
      ),
    ),
  );
}

class _NoteColorSheet extends StatelessWidget {
  const _NoteColorSheet({this.currentColor});

  /// 当前已设置的颜色（浅色 ARGB，作为颜色身份）。
  final int? currentColor;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final isDark = PreferencesStorage.isThemeDark;
    // 选择器展示当前主题对应的色板：浅色模式显示浅色，暗色模式显示暗色。
    final displayColors = isDark ? kNoteColorPaletteDark : kNoteColorPalette;

    return Material(
      color: theme.colorScheme.background,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      child: SafeArea(
        child: ConstrainedBox(
          // 限制 Sheet 最大高度，避免色板过多时溢出屏幕。
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.6,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 顶部抓手
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(4),
                      color: theme.colorScheme.border,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                // 标题
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(
                    'Note Color'.tr(),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                // 颜色圆点网格：可滚动，避免色板过多时溢出。
                Flexible(
                  child: SingleChildScrollView(
                    child: _ColorDotGrid(
                      displayColors: displayColors,
                      currentColor: currentColor,
                      isDark: isDark,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ColorDotGrid extends StatelessWidget {
  const _ColorDotGrid({
    required this.displayColors,
    this.currentColor,
    required this.isDark,
  });

  /// 当前主题下要显示的色板（浅色或暗色）。
  final List<Color> displayColors;

  /// 当前已设置的颜色（浅色 ARGB，作为颜色身份）。
  final int? currentColor;

  /// 是否暗色模式。
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    // 第一项是「默认」（null），后面是色板。
    // 显示用 displayColors（当前主题色板），但 key 和返回值始终用浅色 ARGB。
    final lightColors = kNoteColorPalette;
    final allItems = <({Color display, int? lightArgb})>[
      (display: Colors.transparent, lightArgb: null),
      for (var i = 0; i < displayColors.length; i++)
        (display: displayColors[i], lightArgb: lightColors[i].toARGB32()),
    ];

    return Wrap(
      spacing: 16,
      runSpacing: 16,
      children: allItems.map((item) {
        final isNull = item.lightArgb == null;
        final isSelected = item.lightArgb == currentColor;

        return GestureDetector(
          key: Key('ui-color-picker-${isNull ? 'default' : item.lightArgb}'),
          onTap: () {
            if (isNull) {
              Navigator.of(context).pop(const NoteColorResult.clear());
            } else {
              Navigator.of(context).pop(NoteColorResult.color(item.lightArgb!));
            }
          },
          child: _ColorDot(
            color: isNull ? null : item.display,
            isDefault: isNull,
            isSelected: isSelected,
          ),
        );
      }).toList(),
    );
  }
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({
    this.color,
    this.isDefault = false,
    this.isSelected = false,
  });

  final Color? color;
  final bool isDefault;
  final bool isSelected;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final double size = 48;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        border: Border.all(
          // 选中态：primary 色 3px 粗环；未选中：border 色 2px（比原来的 1px 更清晰）。
          color: isSelected
              ? theme.colorScheme.primary
              : theme.colorScheme.border,
          width: isSelected ? 3 : 2,
        ),
      ),
      child: isDefault
          ? Icon(
              LucideIcons.ban,
              size: 32,
              color: theme.colorScheme.mutedForeground,
            )
          : isSelected
          ? Icon(
              LucideIcons.check,
              size: 32,
              color: color != null
                  ? (ThemeData.estimateBrightnessForColor(color!) ==
                            Brightness.dark
                        ? Colors.white
                        : Colors.black)
                  : null,
            )
          : null,
    );
  }
}
