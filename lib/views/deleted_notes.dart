/*
 * 鏈€杩戝垹闄よ鍥? *
 * 鍔熻兘锛? *   - 鍒楀嚭鎵€鏈夎蒋鍒犻櫎锛堝纰戯級绗旇
 *   - 鏀寔鍗曟潯鎭㈠锛堟挙鍥炲纰戞爣璁帮級
 *   - 鏀寔鍗曟潯姘镐箙鍒犻櫎锛坔ardDelete锛屼笉鍙仮澶嶏級
 *   - 鏀寔娓呯┖鍏ㄩ儴锛堟壒閲?hardDelete锛? *
 * 鍚屾璇存槑锛? *   - 鎭㈠鎿嶄綔浼氭妸 deleted 鏀瑰洖 0 骞舵洿鏂?updatedAt锛岃Е鍙戝悓姝ヤ笂浼犺鐩栬繙绔纰? *   - 姘镐箙鍒犻櫎鍙槸浠庢湰鍦版暟鎹簱绉婚櫎琛岋紝杩滅 manifest 涓粛鏈夊纰? *     涓嬫鍚屾鏃?SyncEngine 浼氬彂鐜?浠呰繙绔湁"鈫?閲嶆柊鍐欏洖鏈湴澧撶
 *     鐪熸姘镐箙娓呯悊闇€瑕?杩滅杩囨湡澧撶娓呯悊"鏈哄埗锛堟殏鏈疄鐜帮紝鍙傝 sync_design锛? */

// Flutter 瀵煎叆

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:core/core.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

// Project imports:
import 'package:safenotes/sync/sync_service.dart';
import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/widgets/shad_dialog.dart';
import 'package:safenotes/widgets/states.dart';

// Package 瀵煎叆

// Project 瀵煎叆

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
      appBar: AppBar(
        title: Text('Recently Deleted'.tr(), style: appBarTitle),
        actions: [
          if (_deletedNotes.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
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
        icon: Icons.delete_outline,
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Restored: "{title}"'.tr(
              namedArgs: {'title': _truncateTitle(note.title)},
            ),
          ),
        ),
      );
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Permanently deleted: "{title}"'.tr(
              namedArgs: {'title': _truncateTitle(note.title)},
            ),
          ),
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
    showDialog(
      context: context,
      builder: (context) => ShadDialog(
        title: Text('Clear All Deleted Notes'.tr()),
        actions: [
          shadDialogActionBar(
            actions: [
              ShadDialogAction(
                label: 'Cancel'.tr(),
                onPressed: () {
                  Log.ui.i('用户取消清空回收站');
                  Navigator.pop(context);
                },
              ),
              ShadDialogAction(
                label: 'Permanently Delete'.tr(),
                destructive: true,
                onPressed: () async {
                  Navigator.pop(context);
                  await _clearAll();
                },
              ),
            ],
          ),
        ],
        child: Text(
          'This will permanently delete {count} notes. This action cannot be undone.\n\nNote: tombstones in the remote manifest remain; these notes may be re-synced from remote on the next sync.\nTo truly clean remote tombstones, wait for the "expired tombstone cleanup" feature.'
              .tr(namedArgs: {'count': '${_deletedNotes.length}'}),
        ),
      ),
    );
  }

  Future<void> _clearAll() async {
    final sw = Stopwatch()..start();
    final total = _deletedNotes.length;
    // 批量不可恢复删除：起止都必须留痕（条数 + 耗时）
    Log.note.w('开始清空回收站(不可恢复): 共 $total 条');
    for (final note in _deletedNotes) {
      await NotesDatabase.instance.hardDelete(note.id!);
    }
    Log.note.w('清空回收站完成: 已永久删除 $total 条, 耗时 ${sw.elapsedMilliseconds}ms');
    // 批量永久删除后触发一次自动同步（debounce 合并，只同步一次）
    SyncService.instance.autoSync();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Cleared {count} notes'.tr(
              namedArgs: {'count': '${_deletedNotes.length}'},
            ),
          ),
        ),
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
    final theme = ShadTheme.of(context);
    final note = widget.note;
    final deletedTime = DateTime.fromMillisecondsSinceEpoch(note.updatedAt);
    final timeStr =
        '${deletedTime.month}/${deletedTime.day} '
        '${deletedTime.hour}:${deletedTime.minute.toString().padLeft(2, '0')}';

    return ShadCard(
      // 回收站卡片与页面背景区分：主题色板中 background == card（ShadSlate），
      // 直接包 Card 会让卡片与背景"融在一起"，故改用 muted 底色 + 边框勾勒。
      backgroundColor: theme.colorScheme.muted,
      border: ShadBorder.all(color: theme.colorScheme.border, width: 1),
      radius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Icon(Icons.delete_outline, color: Colors.grey),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    note.title.isEmpty ? '(Untitled)'.tr() : note.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      decoration: TextDecoration.lineThrough,
                    ),
                  ),
                  Text(
                    note.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Deleted at {time}'.tr(namedArgs: {'time': timeStr}),
                    style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            ShadPopover(
              controller: _menuController,
              child: ShadIconButton.raw(
                variant: ShadButtonVariant.ghost,
                icon: const Icon(Icons.more_vert),
                onPressed: () => _menuController.toggle(),
              ),
              popover: (context) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _menuRow(
                    icon: Icons.restore,
                    label: 'Restore'.tr(),
                    onTap: () {
                      _menuController.hide();
                      widget.onRestore();
                    },
                  ),
                  _menuRow(
                    icon: Icons.delete_forever,
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
      ),
      // 注意：刻意不绑定 onTap —— 点击整条 item 直接恢复容易误操作，
      // 恢复动作只保留在右上角更多菜单（Restore）中。
    );
  }

  Widget _menuRow({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool destructive = false,
  }) {
    final color = destructive ? Colors.red : null;
    return InkWell(
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
    );
  }

  void _confirmPermanentDelete(BuildContext context) {
    final note = widget.note;
    showDialog(
      context: context,
      builder: (context) => ShadDialog(
        title: Text('Permanently Delete'.tr()),
        actions: [
          shadDialogActionBar(
            actions: [
              ShadDialogAction(
                label: 'Cancel'.tr(),
                onPressed: () => Navigator.pop(context),
              ),
              ShadDialogAction(
                label: 'Permanently Delete'.tr(),
                destructive: true,
                onPressed: () {
                  Navigator.pop(context);
                  widget.onPermanentDelete();
                },
              ),
            ],
          ),
        ],
        child: Text(
          'Permanently delete "{title}"? This cannot be undone.'.tr(
            namedArgs: {
              'title': note.title.isEmpty ? '(Untitled)'.tr() : note.title,
            },
          ),
        ),
      ),
    );
  }
}
