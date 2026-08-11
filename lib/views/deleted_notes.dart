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
 *     下次同步时 SyncEngine 会发现"仅远端有"→ 重新写回本地墓碑
 *     真正永久清理需要"远端过期墓碑清理"机制（暂未实现，参见 sync_design）
 */

// Flutter 导入
import 'package:flutter/material.dart';

// Package 导入
import 'package:easy_localization/easy_localization.dart';

// Project 导入
import 'package:core/core.dart';
import 'package:safenotes/sync/sync_service.dart';
import 'package:safenotes/utils/styles.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:safenotes/widgets/shad_dialog.dart';

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
        title: Text(
          'Recently Deleted'.tr(),
          style: appBarTitle,
        ),
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
      return const Center(child: CircularProgressIndicator());
    }
    if (_deletedNotes.isEmpty) {
      return Center(
        child: Text(
          'No deleted notes'.tr(),
          style: TextStyle(fontSize: 16, color: Colors.grey),
        ),
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
          content: Text('Restored: "{title}"'
              .tr(namedArgs: {'title': _truncateTitle(note.title)})),
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
          content: Text('Permanently deleted: "{title}"'
              .tr(namedArgs: {'title': _truncateTitle(note.title)})),
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
          shadDialogActionBar(actions: [
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
          ]),
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
        SnackBar(content: Text('Cleared {count} notes'
            .tr(namedArgs: {'count': '${_deletedNotes.length}'}))),
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
class _DeletedNoteTile extends StatelessWidget {
  final SafeNote note;
  final VoidCallback onRestore;
  final VoidCallback onPermanentDelete;

  const _DeletedNoteTile({
    required this.note,
    required this.onRestore,
    required this.onPermanentDelete,
  });

  @override
  Widget build(BuildContext context) {
    final deletedTime = DateTime.fromMillisecondsSinceEpoch(note.updatedAt);
    final timeStr = '${deletedTime.month}/${deletedTime.day} '
        '${deletedTime.hour}:${deletedTime.minute.toString().padLeft(2, '0')}';

    return Card(
      child: ListTile(
        leading: const Icon(Icons.delete_outline, color: Colors.grey),
        title: Text(
          note.title.isEmpty ? '(Untitled)'.tr() : note.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(decoration: TextDecoration.lineThrough),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              note.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Deleted at {time}'.tr(namedArgs: {'time': timeStr}),
              style: TextStyle(
                fontSize: 10,
                color: Colors.grey.shade500,
              ),
            ),
          ],
        ),
        trailing: PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          onSelected: (value) {
            switch (value) {
              case 'restore':
                onRestore();
                break;
              case 'delete':
                _confirmPermanentDelete(context);
                break;
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem(
              value: 'restore',
              child: ListTile(
                leading: Icon(Icons.restore),
                title: Text('Restore'.tr()),
                dense: true,
              ),
            ),
            PopupMenuItem(
              value: 'delete',
              child: ListTile(
                leading: Icon(Icons.delete_forever, color: Colors.red),
                title: Text('Permanently Delete'.tr(),
                    style: TextStyle(color: Colors.red)),
                dense: true,
              ),
            ),
          ],
        ),
        onTap: onRestore,
      ),
    );
  }

  void _confirmPermanentDelete(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => ShadDialog(
        title: Text('Permanently Delete'.tr()),
        actions: [
          shadDialogActionBar(actions: [
            ShadDialogAction(
              label: 'Cancel'.tr(),
              onPressed: () => Navigator.pop(context),
            ),
            ShadDialogAction(
              label: 'Permanently Delete'.tr(),
              destructive: true,
              onPressed: () {
                Navigator.pop(context);
                onPermanentDelete();
              },
            ),
          ]),
        ],
        child: Text('Permanently delete "{title}"? This cannot be undone.'
            .tr(namedArgs: {'title': note.title.isEmpty ? '(Untitled)'.tr() : note.title})),
      ),
    );
  }
}
