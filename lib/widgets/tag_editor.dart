/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under
* terms of the GPL-3.0+ license.
*/

// 全屏标签编辑页（Google Keep 风格）。
//
// 顶部输入框 + 添加按钮，下方标签列表（一行一个）。
// 两处共用同一页面：
//   - [pushTagEditor] selectionMode=true：编辑**单条笔记**的标签。
//     行首勾选框控制该标签是否归属当前笔记，行尾 X 删除全局标签池中的标签；
//   - [pushTagEditor] selectionMode=false：管理抽屉「标签」组的**全局标签池**。
//     只做增删，无勾选语义。
//
// 返回 [TagEditorResult]（含完整标签池 + 勾选子集）；返回/系统返回取消时为 null。

import 'package:flutter/material.dart';

import 'package:core/core.dart';
import 'package:easy_localization/easy_localization.dart';

/// 全屏标签编辑页的返回结果。
///
/// [pool] 是完整的标签列表（含本次新增、不含本次删除，即新的全局标签池）；
/// [selected] 是勾选子集（仅「编辑单条笔记标签」时有意义；管理态下恒等于 [pool]）。
class TagEditorResult {
  const TagEditorResult({required this.pool, required this.selected});

  final List<String> pool;
  final List<String> selected;
}

/// 打开全屏标签编辑页。
///
/// - [title]：AppBar 标题（编辑单条笔记标签 / 管理全局标签池）。
/// - [pool]：全局标签池初始项（抽屉「标签」组来源）。
/// - [selected]：已归属当前笔记的标签（仅 [selectionMode] 时用于初始化勾选态）。
/// - [selectionMode]：是否展示行首勾选框（编辑单条笔记 = true，管理池 = false）。
///
/// 返回 [TagEditorResult]；系统返回键/页面取消返回 null。
Future<TagEditorResult?> pushTagEditor(
  BuildContext context, {
  required String title,
  required List<String> pool,
  required List<String> selected,
  bool selectionMode = true,
}) {
  return Navigator.of(context).push<TagEditorResult>(
    MaterialPageRoute(
      builder: (_) => TagEditorPage(
        title: title,
        initialPool: pool,
        initialSelected: selected,
        selectionMode: selectionMode,
      ),
    ),
  );
}

class TagEditorPage extends StatefulWidget {
  final String title;
  final List<String> initialPool;
  final List<String> initialSelected;
  final bool selectionMode;

  const TagEditorPage({
    super.key,
    required this.title,
    required this.initialPool,
    required this.initialSelected,
    this.selectionMode = true,
  });

  @override
  State<TagEditorPage> createState() => _TagEditorPageState();
}

class _TagEditorPageState extends State<TagEditorPage> {
  late final List<String> _pool = NoteMeta.normalizeTags(widget.initialPool);
  late final Set<String> _selected = NoteMeta.normalizeTags(
    widget.initialSelected,
  ).toSet();
  late final TextEditingController _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// 添加新标签：加入全局池；勾选模式下同时归属当前笔记。
  void _add() {
    final name = _ctrl.text.trim();
    if (name.isEmpty) return;
    setState(() {
      if (!_pool.contains(name)) _pool.add(name);
      if (widget.selectionMode) _selected.add(name);
      _ctrl.clear();
    });
  }

  /// 删除标签：同时从全局池与勾选子集移除。
  void _remove(String tag) {
    setState(() {
      _pool.remove(tag);
      _selected.remove(tag);
    });
  }

  /// 勾选/取消勾选（仅勾选模式下生效；add 返回 true 表示原本未选中）。
  void _toggle(String tag) {
    if (!widget.selectionMode) return;
    setState(() {
      if (!_selected.add(tag)) _selected.remove(tag);
    });
  }

  void _save() {
    Navigator.of(context).pop(
      TagEditorResult(
        pool: NoteMeta.normalizeTags(_pool),
        selected: NoteMeta.normalizeTags(_selected.toList()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            key: const Key('ui-tag-save'),
            tooltip: 'Save'.tr(),
            icon: const Icon(Icons.check),
            onPressed: _save,
          ),
        ],
      ),
      body: Column(
        children: [
          // 顶部：输入框 + 添加按钮
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('ui-tag-new'),
                    controller: _ctrl,
                    decoration: InputDecoration(
                      labelText: 'Add tag'.tr(),
                      hintText: 'Tag name'.tr(),
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _add(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const Key('ui-tag-add'),
                  onPressed: _add,
                  child: Text('Add Tag'.tr()),
                ),
              ],
            ),
          ),
          // 下方：标签列表（一行一个，行尾 X 删除；勾选模式行首有复选框）
          Expanded(
            child: _pool.isEmpty
                ? Center(
                    child: Text(
                      'No tags yet'.tr(),
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  )
                : ListView.builder(
                    itemCount: _pool.length,
                    itemBuilder: (context, index) {
                      final tag = _pool[index];
                      final isSelected = _selected.contains(tag);
                      return ListTile(
                        key: Key('ui-tag-row-$tag'),
                        leading: widget.selectionMode
                            ? Checkbox(
                                key: Key('ui-tag-toggle-$tag'),
                                value: isSelected,
                                onChanged: (_) => _toggle(tag),
                              )
                            : null,
                        title: Text(
                          tag,
                          style: widget.selectionMode && !isSelected
                              ? Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(color: scheme.onSurfaceVariant)
                              : Theme.of(context).textTheme.bodyMedium,
                        ),
                        trailing: IconButton(
                          key: Key('ui-tag-delete-$tag'),
                          tooltip: 'Delete'.tr(),
                          icon: Icon(
                            Icons.close,
                            color: scheme.onSurfaceVariant,
                          ),
                          onPressed: () => _remove(tag),
                        ),
                        onTap: widget.selectionMode ? () => _toggle(tag) : null,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
