/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

/*
 * 最近删除视图
 *
 * 功能：
 *   - 列出所有软删除（墓碑）笔记
 *   - 支持单条恢复（撤回墓碑标记）
 *   - 支持单条永久删除（hardDelete，不可恢复）
 *   - 支持清空全部（批量 hardDelete）
 *
 * 同步说明：
 *   - 恢复操作会把 deleted 改回 0 并更新 updatedAt，触发同步上传覆盖远端墓碑
 *   - 永久删除只是从本地数据库移除行，远端 manifest 中仍有墓碑
 *     下次同步时 SyncEngine 会发现“仅远端有”→ 重新写回本地墓碑
 *     真正永久清理需要“远端过期墓碑清理”机制（暂未实现，参见 sync_design）
 */

import 'package:flutter/material.dart';

import 'package:core/core.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/sync/sync_service.dart';
import 'package:safenotes/utils/notes_color.dart';
import 'package:safenotes/utils/snack_message.dart';
import 'package:safenotes/utils/spacing.dart';
import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/utils/text_styles.dart';
import 'package:safenotes/utils/time_utils.dart';
import 'package:safenotes/widgets/app_dialogs.dart';
import 'package:safenotes/widgets/states.dart';

class DeletedNotesPage extends StatefulWidget {
  const DeletedNotesPage({super.key});

  @override
  State<DeletedNotesPage> createState() => _DeletedNotesPageState();
}

class _DeletedNotesPageState extends State<DeletedNotesPage> {
  List<SafeNote> _deletedNotes = [];
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    Log.ui.i('进入回收站页面（最近删除）');
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _isLoading = true);
    final notes = await NotesDatabase.instance.readDeletedNotes();
    Log.ui.i('回收站列表已装载: ${notes.length} 条已删除笔记');
    if (mounted) {
      setState(() {
        _deletedNotes = notes;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('ui-deleted-screen'),
      appBar: AppBar(
        title: Text('Recently Deleted'.tr(), style: appBarTitle),
        actions: [
          if (_deletedNotes.isNotEmpty)
            IconButton(
              key: const Key('ui-deleted-clearall'),
              icon: const Icon(LucideIcons.trash2),
              tooltip: 'Clear All'.tr(),
              onPressed: _confirmClearAll,
            ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      // P0-5：骨架占位替代转圈。
      return loadingState();
    }
    if (_deletedNotes.isEmpty) {
      return emptyState(
        icon: LucideIcons.trash2,
        text: 'No deleted notes'.tr(),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(14),
      itemCount: _deletedNotes.length,
      // 与主界面笔记列表 12px 间距保持一致。
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final note = _deletedNotes[index];
        return _DeletedNoteTile(
          note: note,
          onRestore: () => _restoreNote(note),
          onPermanentDelete: () => _permanentDelete(note),
        );
      },
    );
  }

  // ──────────────────────────────────────────────
  // 单条操作
  // ──────────────────────────────────────────────

  Future<void> _restoreNote(SafeNote note) async {
    Log.note.i('用户从回收站恢复笔记: uuid=${note.uuid} id=${note.id}');
    await NotesDatabase.instance.restoreNote(note.id!);
    // 触发自动同步（如果已启用）
    SyncService.instance.autoSync();
    if (mounted) {
      // P2-3：信息提示走 ShadToast。
      // showSnackBarMessage(
      //   context,
      //   'Restored: "{title}"'.tr(
      //     namedArgs: {'title': _truncateTitle(note.title)},
      //   ),
      // );
      _refresh();
    }
  }

  Future<void> _permanentDelete(SafeNote note) async {
    // 不可恢复的破坏性操作，用 warning 级别突出显示
    Log.note.w('用户从回收站永久删除笔记(不可恢复): uuid=${note.uuid} id=${note.id}');
    await NotesDatabase.instance.hardDelete(note.id!);
    // 永久删除后触发自动同步，让远端记录该 uuid 已被 purged（不复活）
    SyncService.instance.autoSync();
    if (mounted) {
      // P2-3：信息提示走 ShadToast。
      showErrorToast(
        context,
        'Permanently deleted: "{title}"'.tr(
          namedArgs: {'title': _truncateTitle(note.title)},
        ),
      );
      _refresh();
    }
  }

  // ──────────────────────────────────────────────
  // 批量清空
  // ──────────────────────────────────────────────

  void _confirmClearAll() {
    Log.ui.i('用户请求清空回收站, 待确认条数=${_deletedNotes.length}');
    showAppDestructive(
      context,
      title: 'Clear All Deleted Notes'.tr(),
      message:
          'This will permanently delete {count} notes. This action cannot be undone.\n\nNote: tombstones in the remote manifest remain; these notes may be re-synced from remote on the next sync.\nTo truly clean remote tombstones, wait for the "expired tombstone cleanup" feature.'
              .tr(namedArgs: {'count': '${_deletedNotes.length}'}),
      confirmLabel: 'Permanently Delete'.tr(),
      cancelLabel: 'Cancel'.tr(),
    ).then((ok) {
      if (ok == true) {
        Log.ui.i('用户确认清空回收站');
        _clearAll();
      } else {
        Log.ui.i('用户取消清空回收站');
      }
    });
  }

  Future<void> _clearAll() async {
    final sw = Stopwatch()..start();
    final total = _deletedNotes.length;
    // 批量不可恢复删除：起止都必须留痕（条数 + 耗时）
    Log.note.w('开始清空回收站(不可恢复): 共 $total 条');
    // 单事务批量硬删除（删行 + purged 列表原子写入），替代逐条 hardDelete 的 N 次事务
    final deleted = await NotesDatabase.instance.hardDeleteAllDeleted();
    Log.note.w('清空回收站完成: 已永久删除 $deleted 条, 耗时 ${sw.elapsedMilliseconds}ms');
    // 批量永久删除后触发一次自动同步（debounce 合并，只同步一次）
    SyncService.instance.autoSync();
    if (mounted) {
      // P2-3：信息提示走 ShadToast。
      showErrorToast(
        context,
        'Cleared {count} notes'.tr(namedArgs: {'count': '$deleted'}),
      );
      _refresh();
    }
  }

  // ──────────────────────────────────────────────
  // 辅助
  // ──────────────────────────────────────────────

  String _truncateTitle(String title) {
    if (title.length <= 20) return title;
    return '${title.substring(0, 20)}...';
  }
}

/// 单条已删除笔记的列表项
class _DeletedNoteTile extends StatefulWidget {
  final SafeNote note;
  final VoidCallback onRestore;
  final VoidCallback onPermanentDelete;

  const _DeletedNoteTile({
    required this.note,
    required this.onRestore,
    required this.onPermanentDelete,
  });

  @override
  State<_DeletedNoteTile> createState() => _DeletedNoteTileState();
}

class _DeletedNoteTileState extends State<_DeletedNoteTile> {
  final ShadPopoverController _menuController = ShadPopoverController();

  @override
  void dispose() {
    _menuController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final note = widget.note;
    final deletedTime = DateTime.fromMillisecondsSinceEpoch(note.updatedAt);
    // 删除时间展示与主界面列表一致（相对/绝对跟随设置）。
    final String timeStr = noteTimeLabel(
      time: deletedTime,
      localeString: context.locale.toString(),
      isRelative: PreferencesStorage.isRelativeTime,
    );

    // 回收站不启用彩色笔记：底色沿用主界面「未开启彩色笔记」时的卡片底色
    // （surfaceContainerHighest 叠加 14% 品牌主色），视觉上与主界面列表一致。
    final Color backgroundColor = NotesColor.neutralCardColor(context);
    // 字体色按背景对比度计算，与主界面列表（NoteCardBody）一致。
    final Color fontColor = getFontColorForBackground(backgroundColor);

    return ShadCard(
      backgroundColor: backgroundColor,
      border: ShadBorder.none,
      radius: BorderRadius.circular(AppShape.cardRadius),
      // 与主界面卡片一致：关闭默认 lg 阴影，扁平化。
      shadows: const [],
      padding: AppSpace.cardPadding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  note.title.isEmpty ? '(Untitled)'.tr() : note.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.title.copyWith(
                    color: fontColor,
                    // 保留删除线，标识已删除状态。
                    decoration: TextDecoration.lineThrough,
                  ),
                ),
                const SizedBox(height: AppSpace.xs),
                Text(
                  'Deleted at {time}'.tr(namedArgs: {'time': timeStr}),
                  style: AppText.label.copyWith(color: fontColor),
                ),
                const SizedBox(height: AppSpace.sm),
                Text(
                  note.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.body.copyWith(color: fontColor),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpace.xs),
          ShadPopover(
            controller: _menuController,
            child: ShadIconButton.raw(
              variant: ShadButtonVariant.ghost,
              icon: Icon(LucideIcons.moreVertical, color: fontColor),
              onPressed: () => _menuController.toggle(),
            ),
            popover: (context) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _menuRow(
                  key: const Key('ui-deleted-menu-restore'),
                  icon: LucideIcons.rotateCcw,
                  label: 'Restore'.tr(),
                  onTap: () {
                    _menuController.hide();
                    widget.onRestore();
                  },
                ),
                _menuRow(
                  key: const Key('ui-deleted-menu-permdelete'),
                  icon: LucideIcons.trash2,
                  label: 'Permanently Delete'.tr(),
                  destructive: true,
                  onTap: () {
                    _menuController.hide();
                    _confirmPermanentDelete(context);
                  },
                ),
              ],
            ),
          ),
        ],
      ),
      // 注意：刻意不绑定 onTap —— 点击整条 item 直接恢复容易误操作，
      // 恢复动作只保留在右上角更多菜单（Restore）中。
    );
  }

  Widget _menuRow({
    Key? key,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool destructive = false,
  }) {
    // P1-22：错误色统一走 shad destructive。
    final color = destructive
        ? ShadTheme.of(context).colorScheme.destructive
        : null;
    return KeyedSubtree(
      key: key,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 10),
              Text(label, style: TextStyle(color: color)),
            ],
          ),
        ),
      ),
    );
  }

  void _confirmPermanentDelete(BuildContext context) {
    final note = widget.note;
    showAppDestructive(
      context,
      title: 'Permanently Delete'.tr(),
      message: 'Permanently delete "{title}"? This cannot be undone.'.tr(
        namedArgs: {
          'title': note.title.isEmpty ? '(Untitled)'.tr() : note.title,
        },
      ),
      confirmLabel: 'Permanently Delete'.tr(),
      cancelLabel: 'Cancel'.tr(),
    ).then((ok) {
      if (ok == true) widget.onPermanentDelete();
    });
  }
}
