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

import 'package:easy_localization/easy_localization.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:safenotes/utils/markdown_formatter.dart';
import 'package:safenotes/utils/platform_ui.dart';

/// 跨平台 Markdown 编辑快捷工具栏。
///
/// - **移动端**：紧贴软键盘上方（作为 Input Accessory View），单行横向平滑滚动；
/// - **桌面端**：置于编辑器顶部或底部，采用紧凑桌面风格排布，支持 Hover 态与 Tooltip；
/// - **交互与焦点**：点击任一工具按钮均使用 [FocusNode.requestFocus] 保持输入焦点，避免键盘闪退。
class MarkdownToolbar extends StatelessWidget {
  /// 当前处于焦点或正在操作的文本控制器（通常为正文控制器）。
  final TextEditingController controller;

  /// 对应的焦点节点，用于在工具栏点击后恢复编辑器焦点。
  final FocusNode? focusNode;

  /// 是否为桌面端模式（若为 null 则自动读取 [PlatformUI.isDesktop]）。
  final bool? isDesktop;

  /// 自定义背景色（如与笔记背景色融合）。
  final Color? backgroundColor;

  /// 工具栏所处位置：顶部 (top) 还是底部 (bottom)，用于决定边框分割线方向。
  final ToolbarPosition position;

  /// 每次执行格式化后的外部回调。
  final VoidCallback? onAction;

  const MarkdownToolbar({
    super.key,
    required this.controller,
    this.focusNode,
    this.isDesktop,
    this.backgroundColor,
    this.position = ToolbarPosition.bottom,
    this.onAction,
  });

  bool get _effectiveIsDesktop => isDesktop ?? isDesktopPlatform;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.1)
        : Colors.black.withValues(alpha: 0.08);

    final double height = _effectiveIsDesktop ? 40.0 : 46.0;

    return Container(
      height: height,
      decoration: BoxDecoration(
        color: backgroundColor ?? theme.colorScheme.surface,
        border: Border(
          top: position == ToolbarPosition.bottom
              ? BorderSide(color: borderColor, width: 1.0)
              : BorderSide.none,
          bottom: position == ToolbarPosition.top
              ? BorderSide(color: borderColor, width: 1.0)
              : BorderSide.none,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          padding: EdgeInsets.symmetric(
            horizontal: _effectiveIsDesktop ? 12.0 : 8.0,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _buildHeadingMenu(context),
              _buildDivider(),
              _buildItem(
                context: context,
                key: const Key('ui-toolbar-btn-bold'),
                icon: LucideIcons.bold,
                tooltip: 'Bold'.tr(),
                action: () => _apply(
                  (v) => MarkdownFormatter.wrapSelection(
                    v,
                    prefix: '**',
                    suffix: '**',
                  ),
                ),
              ),
              _buildItem(
                context: context,
                key: const Key('ui-toolbar-btn-italic'),
                icon: LucideIcons.italic,
                tooltip: 'Italic'.tr(),
                action: () => _apply(
                  (v) => MarkdownFormatter.wrapSelection(
                    v,
                    prefix: '*',
                    suffix: '*',
                  ),
                ),
              ),
              _buildItem(
                context: context,
                key: const Key('ui-toolbar-btn-strikethrough'),
                icon: LucideIcons.strikethrough,
                tooltip: 'Strikethrough'.tr(),
                action: () => _apply(
                  (v) => MarkdownFormatter.wrapSelection(
                    v,
                    prefix: '~~',
                    suffix: '~~',
                  ),
                ),
              ),
              _buildDivider(),
              _buildItem(
                context: context,
                key: const Key('ui-toolbar-btn-task'),
                icon: LucideIcons.listTodo,
                tooltip: 'Task List'.tr(),
                action: () => _apply(MarkdownFormatter.toggleTaskList),
              ),
              _buildItem(
                context: context,
                key: const Key('ui-toolbar-btn-bullet-list'),
                icon: LucideIcons.list,
                tooltip: 'Bullet List'.tr(),
                action: () => _apply(
                  (v) => MarkdownFormatter.toggleList(v, ordered: false),
                ),
              ),
              _buildItem(
                context: context,
                key: const Key('ui-toolbar-btn-ordered-list'),
                icon: LucideIcons.listOrdered,
                tooltip: 'Numbered List'.tr(),
                action: () => _apply(
                  (v) => MarkdownFormatter.toggleList(v, ordered: true),
                ),
              ),
              _buildDivider(),
              _buildItem(
                context: context,
                key: const Key('ui-toolbar-btn-quote'),
                icon: LucideIcons.quote,
                tooltip: 'Blockquote'.tr(),
                action: () => _apply(MarkdownFormatter.toggleBlockquote),
              ),
              _buildItem(
                context: context,
                key: const Key('ui-toolbar-btn-inline-code'),
                icon: LucideIcons.code,
                tooltip: 'Inline Code'.tr(),
                action: () => _apply(
                  (v) => MarkdownFormatter.wrapSelection(
                    v,
                    prefix: '`',
                    suffix: '`',
                  ),
                ),
              ),
              _buildItem(
                context: context,
                key: const Key('ui-toolbar-btn-code-block'),
                icon: LucideIcons.fileCode,
                tooltip: 'Code Block'.tr(),
                action: () => _apply(MarkdownFormatter.insertCodeBlock),
              ),
              _buildItem(
                context: context,
                key: const Key('ui-toolbar-btn-link'),
                icon: LucideIcons.link,
                tooltip: 'Link'.tr(),
                action: () => _apply(MarkdownFormatter.insertLink),
              ),
              _buildItem(
                context: context,
                key: const Key('ui-toolbar-btn-hr'),
                icon: LucideIcons.minus,
                tooltip: 'Horizontal Rule'.tr(),
                action: () => _apply(MarkdownFormatter.insertHorizontalRule),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDivider() {
    return Container(
      width: 1,
      height: _effectiveIsDesktop ? 16 : 20,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      color: Colors.grey.withValues(alpha: 0.25),
    );
  }

  /// 标题选择项：支持长按/菜单选择 H1/H2/H3，点击直接按层级轮换。
  Widget _buildHeadingMenu(BuildContext context) {
    final double iconSize = _effectiveIsDesktop ? 17.0 : 20.0;
    final double btnSize = _effectiveIsDesktop ? 30.0 : 36.0;

    return PopupMenuButton<int?>(
      key: const Key('ui-toolbar-btn-heading'),
      tooltip: 'Heading'.tr(),
      iconSize: iconSize,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 120),
      position: position == ToolbarPosition.top
          ? PopupMenuPosition.under
          : PopupMenuPosition.over,
      icon: SizedBox(
        width: btnSize,
        height: btnSize,
        child: Center(child: Icon(LucideIcons.heading, size: iconSize)),
      ),
      onSelected: (level) {
        _apply((v) => MarkdownFormatter.toggleHeading(v, targetLevel: level));
      },
      itemBuilder: (context) => [
        PopupMenuItem<int?>(value: 1, child: Text('Heading 1'.tr())),
        PopupMenuItem<int?>(value: 2, child: Text('Heading 2'.tr())),
        PopupMenuItem<int?>(value: 3, child: Text('Heading 3'.tr())),
        PopupMenuItem<int?>(value: null, child: Text('Default'.tr())),
      ],
    );
  }

  Widget _buildItem({
    required BuildContext context,
    required Key key,
    required IconData icon,
    required String tooltip,
    required VoidCallback action,
  }) {
    final double iconSize = _effectiveIsDesktop ? 17.0 : 20.0;
    final double btnSize = _effectiveIsDesktop ? 30.0 : 36.0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1.0),
      child: Tooltip(
        message: tooltip,
        waitDuration: const Duration(milliseconds: 500),
        child: SizedBox(
          width: btnSize,
          height: btnSize,
          child: IconButton(
            key: key,
            iconSize: iconSize,
            padding: EdgeInsets.zero,
            focusNode: FocusNode(skipTraversal: true),
            icon: Icon(icon),
            onPressed: action,
          ),
        ),
      ),
    );
  }

  void _apply(TextEditingValue Function(TextEditingValue) transform) {
    final current = controller.value;
    final next = transform(current);
    controller.value = next;
    // 恢复焦点，避免软键盘收起或失去光标
    focusNode?.requestFocus();
    onAction?.call();
  }
}

enum ToolbarPosition { top, bottom }
