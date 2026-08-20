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

import 'package:flutter/material.dart';

import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/utils/spacing.dart';
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
  void didUpdateWidget(SearchWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部 query 变化时同步 controller（如空状态 CTA 清空搜索），
    // 避免清除按钮点了但文字还在。
    if (widget.text != oldWidget.text && widget.text != controller.text) {
      controller.text = widget.text;
    }
  }

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
    // P1-14：圆角走 AppShape.inputRadius（8），与 ShadInput 主题一致。
    final bool enableIMEPLFlag = !PreferencesStorage.keyboardIncognito;
    // 亮色/暗色统一用 surfaceContainerHighest（浅亮灰/深灰容器），
    // 与页面背景 surfaceContainerLow 拉开对比，保证搜索框有清晰背景色块；
    // 亮色不再用与页面同色的 surfaceContainerLow（会"融化"在页面里，看起来没背景）。
    final Color boxColor = colorScheme.surface;

    return Container(
      // P1-14：高度走 AppShape.searchHeight（48），与 ShadInput 48 对齐。
      height: AppShape.searchHeight,
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppShape.inputRadius),
        color: boxColor,
        // 轻描边勾勒框体：outlineVariant 亮色浅灰/暗色深灰，非突兀黑线。
        border: Border.all(color: colorScheme.outlineVariant, width: 1),
      ),
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
      // 搜索图标、输入框、清除按钮放在同一 Row，由 Row 统一垂直居中。
      // 注意：不要给 TextField 设 textAlignVertical —— 在 isCollapsed + 零内边距下，
      // 它会把文字/hint 额外下移约 4px（真实字体实测）；不设时文字天然居中。
      // 也不用 InputDecoration 的 leading icon / suffixIcon，避免内部布局差异。
      child: Row(
        children: [
          Icon(LucideIcons.search, color: style.color, size: AppIcon.md),
          const SizedBox(width: 10),
          Expanded(
            child: ShadInput(
              key: const Key('ui-home-search-input'),
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
              // 显式锁死内边距：外层 Container 48 高含 1px 边框（可用 46），
              // 垂直取 12（12*2+行高约20=44 < 46）留裕量防溢出，文字近似居中；
              // 防止主题 inputTheme padding 变动波及搜索框内部布局。
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
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
