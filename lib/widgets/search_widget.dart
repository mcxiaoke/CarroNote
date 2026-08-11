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

// Flutter imports:
import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

// Project imports:
import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/utils/text_direction_util.dart';

class SearchWidget extends StatefulWidget {
  final String text;
  final ValueChanged<String> onChanged;
  final String hintText;

  const SearchWidget({
    super.key,
    required this.text,
    required this.onChanged,
    required this.hintText,
  });

  @override
  SearchWidgetState createState() => SearchWidgetState();
}

class SearchWidgetState extends State<SearchWidget> {
  final controller = TextEditingController();

  @override
  void dispose() {
    // F-H11 修复：搜索框 controller 需要 dispose
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final styleActive = TextStyle(color: colorScheme.onSurface);
    final styleHint = TextStyle(color: colorScheme.onSurfaceVariant);
    final style = widget.text.isEmpty ? styleHint : styleActive;
    const searchBoxRadius = 7.0;
    final bool enableIMEPLFlag = !PreferencesStorage.keyboardIncognito;
    // 亮色模式用更浅的 surfaceContainerLow，避免 surfaceContainerHighest 偏深发灰；
    // 暗色模式沿用 surfaceContainerHighest（本就是深色容器）。
    final bool isDark = colorScheme.brightness == Brightness.dark;
    final Color boxColor = isDark
        ? colorScheme.surfaceContainerHighest
        : colorScheme.surfaceContainerLow;

    return Container(
      height: 44,
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(searchBoxRadius),
        color: boxColor,
        // 不再画 outlineVariant 边框：避免深色"黑线"突兀。
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      // 搜索图标、输入框、清除按钮放在同一 Row，由 Row 统一垂直居中。
      // 注意：不要给 TextField 设 textAlignVertical —— 在 isCollapsed + 零内边距下，
      // 它会把文字/hint 额外下移约 4px（真实字体实测）；不设时文字天然居中。
      // 也不用 InputDecoration 的 leading icon / suffixIcon，避免内部布局差异。
      child: Row(
        children: [
          Icon(LucideIcons.search, color: style.color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: ShadInput(
              enableIMEPersonalizedLearning: enableIMEPLFlag,
              textDirection: getTextDirecton(widget.text),
              controller: controller,
              enableInteractiveSelection: true,
              autofocus: false,
              maxLines: 1,
              contextMenuBuilder: (context, editableTextState) {
                final List<ContextMenuButtonItem> buttonItems =
                    editableTextState.contextMenuButtonItems;

                final itemsToRemove = [
                  ContextMenuButtonType.share,
                  ContextMenuButtonType.searchWeb,
                  ContextMenuButtonType.lookUp,
                ];

                buttonItems.removeWhere((ContextMenuButtonItem buttonItem) {
                  return itemsToRemove.contains(buttonItem.type);
                });

                return AdaptiveTextSelectionToolbar.buttonItems(
                  anchors: editableTextState.contextMenuAnchors,
                  buttonItems: buttonItems,
                );
              },
              // 沿用外层 Container 的彩色圆角框，内部输入框保持无边框/透明，
              // 与迁移前 TextField(isCollapsed + zero padding + border none) 视觉一致。
              placeholder: Text(widget.hintText, style: styleHint),
              style: styleActive,
              inputPadding: EdgeInsets.zero,
              decoration: const ShadDecoration(
                border: ShadBorder.none,
                focusedBorder: ShadBorder.none,
                errorBorder: ShadBorder.none,
                secondaryBorder: ShadBorder.none,
                secondaryFocusedBorder: ShadBorder.none,
                secondaryErrorBorder: ShadBorder.none,
                color: Colors.transparent,
              ),
              onChanged: widget.onChanged,
            ),
          ),
          if (widget.text.isNotEmpty)
            GestureDetector(
              child: Icon(LucideIcons.x, color: style.color),
              onTap: () {
                controller.clear();
                widget.onChanged('');
                //FocusScope.of(context).requestFocus(FocusNode());
              },
            ),
        ],
      ),
    );
  }
}
