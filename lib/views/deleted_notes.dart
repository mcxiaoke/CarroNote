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

// Project 导入
import 'package:safenotes/data/database_handler.dart';
import 'package:safenotes/models/safenote.dart';
import 'package:safenotes/sync/sync_service.dart';
import 'package:safenotes/utils/styles.dart';

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
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _isLoading = true);
    final notes = await NotesDatabase.instance.readDeletedNotes();
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
          '最近删除',
          style: appBarTitle,
        ),
        actions: [
          if (_deletedNotes.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: '清空全部',
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
      return const Center(
        child: Text(
          '没有已删除的笔记',
          style: TextStyle(fontSize: 16, color: Colors.grey),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: _deletedNotes.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
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
    await NotesDatabase.instance.restoreNote(note.id!);
    // 触发自动同步（如果已启用）
    SyncService.instance.autoSync();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已恢复："${_truncateTitle(note.title)}"')),
      );
      _refresh();
    }
  }

  Future<void> _permanentDelete(SafeNote note) async {
    await NotesDatabase.instance.hardDelete(note.id!);
    // 永久删除后触发自动同步，让远端记录该 uuid 已被 purged（不复活）
    SyncService.instance.autoSync();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已永久删除："${_truncateTitle(note.title)}"'),
        ),
      );
      _refresh();
    }
  }

  // ──────────────────────────────────────────────
  // 批量清空
  // ──────────────────────────────────────────────

  void _confirmClearAll() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空全部已删除笔记'),
        content: Text(
          '将永久删除 ${_deletedNotes.length} 条笔记，此操作不可恢复。'
          '\n\n注意：远端 manifest 中的墓碑仍会保留，'
          '下次同步时这些笔记可能从远端重新同步回来。'
          '\n要真正清理远端墓碑，需要等待"过期墓碑清理"功能。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () async {
              Navigator.pop(context);
              await _clearAll();
            },
            child: const Text('永久删除'),
          ),
        ],
      ),
    );
  }

  Future<void> _clearAll() async {
    for (final note in _deletedNotes) {
      await NotesDatabase.instance.hardDelete(note.id!);
    }
    // 批量永久删除后触发一次自动同步（debounce 合并，只同步一次）
    SyncService.instance.autoSync();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已清空 ${_deletedNotes.length} 条笔记')),
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
          note.title.isEmpty ? '(无标题)' : note.title,
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
              '删除于 $timeStr',
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
            const PopupMenuItem(
              value: 'restore',
              child: ListTile(
                leading: Icon(Icons.restore),
                title: Text('恢复'),
                dense: true,
              ),
            ),
            const PopupMenuItem(
              value: 'delete',
              child: ListTile(
                leading: Icon(Icons.delete_forever, color: Colors.red),
                title: Text('永久删除',
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
      builder: (context) => AlertDialog(
        title: const Text('永久删除'),
        content: Text('确定要永久删除"${note.title.isEmpty ? '无标题' : note.title}"吗？\n'
            '此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () {
              Navigator.pop(context);
              onPermanentDelete();
            },
            child: const Text('永久删除'),
          ),
        ],
      ),
    );
  }
}
