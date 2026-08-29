/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

import 'package:flutter/widgets.dart';

/// 一次编辑快照：标题与正文的 [TextEditingValue]（含 text 与 selection）。
class EditSnapshot {
  const EditSnapshot(
    this.titleBefore,
    this.titleAfter,
    this.descBefore,
    this.descAfter,
  );

  final TextEditingValue titleBefore;
  final TextEditingValue titleAfter;
  final TextEditingValue descBefore;
  final TextEditingValue descAfter;
}

/// 笔记编辑撤销/重做历史（双栈）。
///
/// 一次撤销同时还原标题与正文，并恢复光标位置。同字段、且间隔小于
/// [_coalesceMs] 的连续编辑合并为一步，避免逐字符撤销；栈上限 [_max] 步。
class NoteEditHistory {
  NoteEditHistory({this._max = _kMax, this._coalesceMs = _kCoalesceMs});

  static const int _kMax = 100;
  static const int _kCoalesceMs = 500;

  final int _max;
  final int _coalesceMs;

  final List<EditSnapshot> _undoStack = <EditSnapshot>[];
  final List<EditSnapshot> _redoStack = <EditSnapshot>[];

  late TextEditingValue _titleAfter;
  late TextEditingValue _descAfter;
  String? _lastField;
  int _lastTs = 0;

  /// 用编辑页初始内容初始化基准状态。
  void init(TextEditingValue title, TextEditingValue desc) {
    _titleAfter = title;
    _descAfter = desc;
  }

  /// 记录一次编辑。[field] 为发生变更的字段（'title' | 'description'）。
  ///
  /// 仅移动光标/改变选区时，文本不变也会触发 controller 监听回调（见
  /// `AddEditNotePage._onEdit`）。这种“纯选区事件”不构成一次可撤销编辑：
  /// 若照录入栈，每次真实键入前都会被记成一条 before==after 的“空快照”，
  /// 导致点一次撤销看似无响应、撤销栈被垃圾步骤污染。判定统一收敛在这里，
  /// 保证任何调用方都遵守同一规则。
  void record({
    required TextEditingValue title,
    required TextEditingValue desc,
    required String field,
  }) {
    // 文本未变 → 纯光标/选区事件，不入栈、也不清空 redo 栈。
    if (title.text == _titleAfter.text && desc.text == _descAfter.text) {
      return;
    }
    final int now = DateTime.now().millisecondsSinceEpoch;
    final bool merge =
        _lastField == field &&
        _undoStack.isNotEmpty &&
        now - _lastTs < _coalesceMs;
    if (merge) {
      final EditSnapshot top = _undoStack.last;
      _undoStack[_undoStack.length - 1] = EditSnapshot(
        top.titleBefore,
        title,
        top.descBefore,
        desc,
      );
    } else {
      _undoStack.add(EditSnapshot(_titleAfter, title, _descAfter, desc));
      if (_undoStack.length > _max) _undoStack.removeAt(0);
    }
    _titleAfter = title;
    _descAfter = desc;
    _lastField = field;
    _lastTs = now;
    _redoStack.clear();
  }

  /// 撤销，返回待应用的快照；无可撤销时返回 null。
  EditSnapshot? undo() {
    if (_undoStack.isEmpty) return null;
    final EditSnapshot snap = _undoStack.removeLast();
    _titleAfter = snap.titleBefore;
    _descAfter = snap.descBefore;
    _lastField = null;
    _redoStack.add(snap);
    return snap;
  }

  /// 重做，返回待应用的快照；无可重做时返回 null。
  EditSnapshot? redo() {
    if (_redoStack.isEmpty) return null;
    final EditSnapshot snap = _redoStack.removeLast();
    _titleAfter = snap.titleAfter;
    _descAfter = snap.descAfter;
    _undoStack.add(snap);
    return snap;
  }

  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;
}
