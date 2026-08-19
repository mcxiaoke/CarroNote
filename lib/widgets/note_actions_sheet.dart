/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under
* terms of the GPL-3.0+ license.
*/

// 笔记操作菜单（编辑页 AppBar「更多」入口的底部弹层）。
//
// 本 sheet 只负责「让用户选一个动作」，把结果 pop 回调用方，不执行任何业务
// 逻辑：剪贴板写入、星标落库、删除确认都留在编辑页做。这样业务动作总是发生在
// sheet 已关闭之后，不会在被销毁的 sheet context 上弹二级对话框或 toast。

import 'package:flutter/material.dart';

import 'package:easy_localization/easy_localization.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/widgets/shad_settings_tiles.dart';

/// 笔记操作菜单里可选的动作。
enum NoteAction { copyAll, toggleStar, editTags, delete }

/// 弹出笔记操作菜单，返回用户选择的动作；点遮罩或返回键关闭时返回 null。
///
/// [pinned] 决定星标项显示「添加星标」还是「取消星标」——星标与置顶在本项目
/// 是同一概念（`NoteMeta.pinned`）。调用方需在打开前读好当前状态，避免 sheet
/// 内部再异步查库导致文案闪烁。
Future<NoteAction?> showNoteActionsSheet(
  BuildContext context, {
  required bool pinned,
}) {
  return showShadSheet<NoteAction>(
    context: context,
    side: ShadSheetSide.bottom,
    builder: (context) => ShadSheet(
      // 内容自绘背景/抓手/圆角，因此关掉 ShadSheet 默认 padding 与边框，
      // 避免出现双层留白（与 showThemeBottomSheet 保持一致）。
      padding: EdgeInsets.zero,
      backgroundColor: Colors.transparent,
      border: Border.all(color: Colors.transparent),
      radius: const BorderRadius.vertical(top: Radius.circular(16)),
      // 桌面端限宽居中，避免宽窗口下被拉成一条横带。
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kDialogMaxWidthWide),
          child: _NoteActionsSheet(pinned: pinned),
        ),
      ),
    ),
  );
}

class _NoteActionsSheet extends StatelessWidget {
  const _NoteActionsSheet({required this.pinned});

  final bool pinned;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Material(
      color: theme.colorScheme.background,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      child: SafeArea(
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
              const SizedBox(height: 14),
              shadSettingsCard([
                shadActionTile(
                  context,
                  key: const Key('ui-note-action-copy'),
                  icon: LucideIcons.copy,
                  title: 'Copy all'.tr(),
                  onTap: () => Navigator.of(context).pop(NoteAction.copyAll),
                ),
                shadActionTile(
                  context,
                  key: const Key('ui-note-action-star'),
                  icon: pinned ? LucideIcons.starOff : LucideIcons.star,
                  title: pinned ? 'Remove star'.tr() : 'Add star'.tr(),
                  onTap: () => Navigator.of(context).pop(NoteAction.toggleStar),
                ),
                shadActionTile(
                  context,
                  key: const Key('ui-note-action-tags'),
                  icon: LucideIcons.tags,
                  title: 'Edit Tags'.tr(),
                  onTap: () => Navigator.of(context).pop(NoteAction.editTags),
                ),
                shadActionTile(
                  context,
                  key: const Key('ui-note-action-delete'),
                  icon: LucideIcons.trash2,
                  title: 'Delete note'.tr(),
                  destructive: true,
                  onTap: () => Navigator.of(context).pop(NoteAction.delete),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}
