# 笔记编辑 Undo/Redo 设计方案

- 状态：设计稿（未实施）
- 日期：2026-08-22
- 范围：笔记编辑页（AddEditNotePage）标题 + 正文 的撤销 / 重做

## 1. 目标

为笔记编辑器提供可靠的撤销 / 重做能力，满足：

- 一次撤销同时还原 **标题 + 正文**，并恢复正确的光标位置（selection）。
- 支持键盘快捷键（`Ctrl+Z` 撤销、`Ctrl+Y` / `Ctrl+Shift+Z` 重做）。
- 可选：AppBar 提供撤销 / 重做按钮（按 `canUndo` / `canRedo` 启用）。

## 2. 结论（采用方案）

**保留 `ShadInputFormField`，自研“双栈快照”统一撤销栈。不替换为系统 `TextFormField`。**

理由：

- 编辑器当前用 `ShadInputFormField(initialValue + onChanged)`，没有 `TextEditingController`，
  无法在撤销时还原光标。解决方法是**加 `TextEditingController`**，与用哪个输入框组件无关。
- 换成 `TextFormField` 只能获得“每字段独立、键盘触发”的原生 undo，且要重写 borderless 样式、
  并破坏全站 shadcn 视觉一致性——对“加 undo”这件事没有收益，反而增加成本。
- 自研栈可做到“标题 + 正文一步还原 + 可挂按钮 + 全平台一致”，是功能最全、改动最小的路径。

## 3. 架构

### 3.1 快照模型

每个快照保存标题与正文的 `TextEditingValue`（含 `text` 与 `selection`）：

```dart
class EditSnapshot {
  final TextEditingValue titleBefore, titleAfter;
  final TextEditingValue descBefore, descAfter;
  EditSnapshot(this.titleBefore, this.titleAfter, this.descBefore, this.descAfter);
}
```

### 3.2 历史栈（双栈）

- `undo` 栈：已发生的编辑，末项即“当前可撤销到”的状态。
- `redo` 栈：被撤销后暂存，重做后弹回 `undo` 栈。
- 合并策略：**同字段、且距上次记录 < 500ms** 的连续编辑，视为一次输入（替换栈顶 `after`），
  避免逐字符撤销。栈上限 100 步。
- 应用 undo/redo 时设置 `_applyingHistory = true` 守卫，屏蔽 `controller` 监听器回流，
  防止把“还原操作”又记录进历史。

```dart
class NoteEditHistory {
  final List<EditSnapshot> _undo = [];
  final List<EditSnapshot> _redo = [];
  late TextEditingValue _titleAfter, _descAfter;
  String? _lastField;
  int _lastTs = 0;
  static const _max = 100, _coalesceMs = 500;

  void init(TextEditingValue t, TextEditingValue d) => _titleAfter = t, _descAfter = d;

  void record({required TextEditingValue title, required TextEditingValue desc, required String field}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final merge = _lastField == field && _undo.isNotEmpty && now - _lastTs < _coalesceMs;
    if (merge) {
      final top = _undo.last;
      _undo[_undo.length - 1] = EditSnapshot(top.titleBefore, title, top.descBefore, desc);
    } else {
      _undo.add(EditSnapshot(_titleAfter, title, _descAfter, desc));
      if (_undo.length > _max) _undo.removeAt(0);
    }
    _titleAfter = title; _descAfter = desc; _lastField = field; _lastTs = now;
    _redo.clear();
  }

  EditSnapshot? undo() {
    if (_undo.isEmpty) return null;
    final s = _undo.removeLast();
    _titleAfter = s.titleBefore; _descAfter = s.descBefore; _lastField = null;
    _redo.add(s);
    return s;
  }

  EditSnapshot? redo() {
    if (_redo.isEmpty) return null;
    final s = _redo.removeLast();
    _titleAfter = s.titleAfter; _descAfter = s.descAfter;
    _undo.add(s);
    return s;
  }

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
}
```

## 4. 改动文件清单

### 4.1 新建 `lib/utils/note_edit_history.dart`

放置上面的 `EditSnapshot` 与 `NoteEditHistory`。无对外依赖，纯 Dart。

### 4.2 改 `lib/widgets/note_widget.dart`

`NoteFormWidget` 由 `initialValue` 改为接收 `TextEditingController`：

- 构造函数新增 `final TextEditingController titleController; final TextEditingController descriptionController;`
- 两个 `ShadInputFormField` 删掉 `initialValue`，改传 `controller: titleController` / `controller: descriptionController`。
- **必须保留** `key: const Key('ui-note-field-title')` 和 `key: const Key('ui-note-field-body')`
  （集成测试 `app_test.dart` / `first_run_test.dart` 用这两个 Key 做 `enterText`）。

### 4.3 改 `lib/views/add_edit_note.dart`

在 `AddEditNotePageState` 内接线：

- 新增 `late final TextEditingController _titleController, _descriptionController;`
  与 `final _history = NoteEditHistory();`，以及 `_applyingHistory`、`_canUndo`、`_canRedo` 标志位。
- `initState`：用 `title` / `description` 初始化 controller，调用 `_history.init(...)`，
  并对两个 controller 各挂 `addListener` → `_onEdit(field)`。
- `_onEdit(field)`：守卫 `_applyingHistory`；更新 `title/description` 与 `NoteEditorState.setState`
  （与原 `onChangedTitle/Description` 逻辑一致）；调用 `_history.record(...)`；刷新按钮状态。
- `_undo()` / `_redo()`：取快照 → `_apply()`；`_apply()` 内设置 `_applyingHistory` 守卫，
  写回两个 controller 的 `value`，并同步 `title/description` 与 `NoteEditorState.setState`。
- `dispose()`：dispose 两个 controller。
- 快捷键：用 `CallbackShortcuts` 包裹编辑区，绑定 `Ctrl+Z`→`_undo`、`Ctrl+Y` 与
  `Ctrl+Shift+Z`→`_redo`（macOS 可补 `meta` 变体）。
- AppBar：新增撤销 / 重做 `IconButton`，`onPressed: _canUndo ? _undo : null`，
  在 `!_previewMode && !_isLocked` 时可用。

## 5. 边界与兼容性

- **与版本历史解耦**：现有 `note_version.dart` 是按“保存”做整篇快照，属 save 级历史；
  本方案是编辑会话级，互不影响。
- **预览 / 锁定态**：仅在 `!_previewMode && !_isLocked` 时允许 undo/redo。
- **自动保存不污染栈**：后台 / pop 自动保存只写 DB、不改 controller 值，不产生撤销项。
- **不破坏测试**：保留 `ui-note-field-title` / `ui-note-field-body` 两个 Key，
  现有编辑器测试（含设置相关 `app_test.dart` 中的笔记段落）继续可用。
- **IME 隐身模式**：保留 `enableIMEPersonalizedLearning` 映射，行为不变。

## 6. 验证

- `flutter analyze`
- `dart test packages\core\test` 与 `flutter test`（现有套件不退化）
- `flutter build windows --debug`（编译无错）
- 集成测试：手动验证 `Ctrl+Z` / `Ctrl+Y` 还原标题+正文与光标；AppBar 按钮启用态正确；
  预览/锁定态禁用；后台自动保存后栈不被污染。

## 7. 与当前在途改动的冲突分析

当前未提交改动集中在**设置页 + 相关测试 + i18n**：

- `lib/views/settings/*`、`lib/routes/route_generator.dart`、`integration_test/app_test.dart`、
  `assets/translations/*.json`、`docs/CHANGES-20260822.md`

本方案目标文件（`add_edit_note.dart`、`note_widget.dart`、新建 `note_edit_history.dart`）
**均不在上述列表**，无文件级重叠，可并行。

需注意的间接接触点（实施时处理）：

1. **`docs/CHANGES-20260822.md`**：实施时按约定在顶部追加变更摘要，注意与设置页改动的顺序合并。
2. **i18n 文案**：撤销 / 重做按钮标签若需新增 key，会触碰 `en-US.json` / `zh-CN.json`
   （当前正在编辑）——建议复用现有 key 或等设置页 i18n 提交后再补，避免并发冲突。
3. **测试**：若新增 undo/redo 测试，建议放在**新建的独立测试文件**（如 `integration_test/note_undo_redo_test.dart`），
   不改动正在编辑的 `app_test.dart`，规避合并冲突。

## 8. 实施顺序（待确认后执行）

1. 新建 `lib/utils/note_edit_history.dart`。
2. 改 `lib/widgets/note_widget.dart`（接收 controller，保留 Key）。
3. 改 `lib/views/add_edit_note.dart`（controller + history + 快捷键 + 按钮 + dispose）。
4. 如需文案，独立提交 i18n key（错开设置页并发期）。
5. 跑分析 / 编译 / 测试验证。
