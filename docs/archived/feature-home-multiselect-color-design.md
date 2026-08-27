# 首页批量多选 + 笔记颜色方案

> 状态：✅ 已实现（P1-P5 全部完成，含集成测试）
> 日期：2026-08-22
> 关联：`feature-note-meta-design.md`（note_meta 表 / NoteMeta 模型）
> 参考：Google Keep 多选交互（`temp/googlekeep/` 截图，非像素级复刻）

## 0. 需求摘要

在首页实现类似 Google Keep 的多选批量操作模式：

1. **长按卡片** → 进入多选模式，选中当前卡片
2. 多选模式下 AppBar 切换为操作栏，提供批量操作：**星标、锁定、设置标签、修改颜色、删除**
3. 点击其他卡片切换选中/取消，再次点击选中的卡片取消选中
4. 选中态视觉：**仅边框高亮**（参考 Google Keep 截图 1，蓝色边框，不加遮罩、不加勾选徽章）
5. **修改笔记颜色**：同时需要加入编辑页「更多」菜单（`NoteActionsSheet`）
6. 颜色选择器用底部 Sheet（复用项目现有 `showShadSheet`，实现简单，风格统一）
7. 批量 DB 操作：先用循环 + `Future.wait`，暂不新增批量接口
8. 暂不做分享功能

---

## 1. 架构约束分析

### 1.1 当前卡片渲染链路

```
HomePage._buildNotes() / _buildNotesTile()
  └─ _openNoteEditorContainer(note, index, grid)
       └─ OpenContainer(tappable: false, ...)
            ├─ openBuilder → AddEditNotePage
            └─ closedBuilder → NoteCardPressFeedback(onTap: () => action())
                 └─ KeyedSubtree
                      └─ NoteCardWidget / NoteTileWidget / NoteCardWidgetCompact / NoteTileWidgetCompact
                           └─ NoteCardBody(note, index, pinned)
```

**关键点：**
- `OpenContainer.tappable: false` — 点击完全由 `NoteCardPressFeedback.onTap` 显式控制，多选时只需改 `onTap` 回调即可拦截
- `NoteCardPressFeedback` 只有 `onTap`，需新增 `onLongPress`
- 卡片底色由 `OpenContainer.closedColor` 承载（= `NotesColor.getNoteColor`），不是 `NoteCardBody` 内部的 Container
- 4 种卡片壳统一走 `NoteCardBody`，选中态参数只需在最底层加一次

### 1.2 元数据与颜色

- `NoteMeta.color`：已预留的 `int?` 列（ARGB），`null` = 跟随主题默认
- DB 层无 `setNoteColor` 方法，需新增（与 `setNotePinned` 同构）
- 当前卡片颜色来自 `NotesColor.getNoteColor(notIndex, context)`，按**列表位置**取色，与 `NoteMeta.color` 无关
- 改为支持 `NoteMeta.color` 后，优先使用用户设置的颜色，`null` 时回退到现有按位置取色逻辑

### 1.3 状态管理

- `HomePageState` 是纯 `StatefulWidget`，无 MVVM/Provider 驱动笔记列表
- `_noteMeta`（`Map<String, NoteMeta>`）已在 `HomePageState` 中维护，多选模式可直接复用
- 批量操作后调 `refreshNotes()` 即可刷新列表，与现有模式一致

### 1.4 现有锁定能力

- `NoteMeta.locked`：明文 `bool` 列，与 `pinned` 同级
- `NotesDatabase.setNoteLocked(uuid, bool)`：已实现，与 `setNotePinned` 同构
- 编辑页 `_toggleLock`：切换只读/可编辑，锁定后卡片只读预览
- 批量锁定复用 `setNoteLocked`，语义同 Google Keep 批量归档——选中笔记统一切换锁定态

---

## 2. 多选模式设计

### 2.1 新增状态字段

在 `HomePageState` 中新增：

```dart
/// 多选模式状态
bool _isSelectionMode = false;
Set<String> _selectedUuids = {};
```

### 2.2 进入 / 退出多选模式

| 触发 | 行为 |
|------|------|
| 长按卡片 | `_isSelectionMode = true` + `_selectedUuids.add(note.uuid)` |
| 多选模式下点击卡片 | 切换选中/取消选中（不进编辑页） |
| 非多选模式下点击卡片 | 正常进入编辑页（现有行为不变） |
| AppBar ✕ 按钮 | 退出多选模式，清空选中 |
| 系统返回键 | 退出多选模式（不退出应用） |
| 全选/取消全选 | 选中/取消当前 `notes` 列表全部 |

核心方法：

```dart
void _enterSelectionMode(String uuid) {
  setState(() {
    _isSelectionMode = true;
    _selectedUuids.add(uuid);
  });
}

void _toggleSelection(String uuid) {
  setState(() {
    if (_selectedUuids.contains(uuid)) {
      _selectedUuids.remove(uuid);
      if (_selectedUuids.isEmpty) {
        _isSelectionMode = false; // 最后一个取消时自动退出
      }
    } else {
      _selectedUuids.add(uuid);
    }
  });
}

void _exitSelectionMode() {
  setState(() {
    _isSelectionMode = false;
    _selectedUuids.clear();
  });
}

void _toggleSelectAll() {
  setState(() {
    final allUuids = notes.map((n) => n.uuid).toSet();
    if (_selectedUuids.containsAll(allUuids)) {
      // 全部已选 → 取消全选
      _selectedUuids.clear();
      _isSelectionMode = false;
    } else {
      _selectedUuids = allUuids;
    }
  });
}
```

### 2.3 返回键拦截

用 `PopScope` 包裹 `Scaffold`：

```dart
PopScope(
  canPop: !_isSelectionMode,
  onPopInvokedWithResult: (didPop, _) {
    if (!didPop && _isSelectionMode) {
      _exitSelectionMode();
    }
  },
  child: Scaffold(...)
)
```

### 2.4 卡片交互改动

**`NoteCardPressFeedback`** 新增 `onLongPress`：

```dart
class NoteCardPressFeedback extends StatelessWidget {
  final VoidCallback onTap;
  final VoidCallback? onLongPress;  // ← 新增
  ...
  InkWell(
    onTap: onTap,
    onLongPress: onLongPress,
    ...
  )
}
```

**`_openNoteEditorContainer`** 中根据 `_isSelectionMode` 切换行为：

```dart
closedBuilder: (context, action) => NoteCardPressFeedback(
  onTap: _isSelectionMode
      ? () => _toggleSelection(note.uuid)
      : () { Log.ui.i(...); action(); },
  onLongPress: () => _enterSelectionMode(note.uuid),
  child: ...
)
```

> 注意：多选模式下 `OpenContainer` 的 `action()` 不会被调用，因此不会打开编辑页。

### 2.5 选中态视觉：边框高亮

参考 Google Keep 截图 1：选中卡片仅加彩色边框，不加遮罩、不加勾选徽章。

在 `NoteCardBody` 新增参数：

```dart
final bool isSelectionMode;
final bool isSelected;
```

在 `Container.decoration` 中条件替换边框：

```dart
final ShadBorder cardBorder = isSelected
    ? ShadBorder.all(
        color: Theme.of(context).colorScheme.primary,
        width: 2,
      )
    : NotesColor.cardBorder(
        outline: isMonochromeMode && !PreferencesStorage.isColorful,
        color: cardScheme.outlineVariant,
        width: 1,
      );
```

多选模式下未选中的卡片保持现有边框不变（不加空心圆圈等额外提示，保持简洁）。

参数透传链路：

```
_openNoteEditorContainer (home.dart)
  → NoteCardWidget / NoteTileWidget / NoteCardWidgetCompact / NoteTileWidgetCompact
    → NoteCardBody (isSelectionMode, isSelected)
```

每个壳 widget 新增 `isSelectionMode` 和 `isSelected` 参数，透传给 `NoteCardBody`。

### 2.6 多选 AppBar（参考 Google Keep）

参考 Google Keep 截图 1+2 的 AppBar 布局，精简为 3 个常用图标 + 溢出菜单：

```
本方案：
┌──────────────────────────────────────────────┐
│  ✕  3          📌  🎨  🏷  ⋯                │
│  关闭 计数      星标 颜色 标签 溢出菜单       │
└──────────────────────────────────────────────┘

溢出菜单 ⋯ 展开后：
┌──────────────┐
│  🔒 锁定      │
│  ──────────  │
│  ☑ 全选       │
│  🗑 删除      │
└──────────────┘
```

**设计决策：**
- 外侧 3 个高频操作：星标、颜色、标签（与 Google Keep 对齐）
- 低频/危险操作放溢出菜单 `⋯`（PopupMenuButton）：锁定、全选、删除
- 左侧 ✕ 关闭 + 选中计数（纯数字，不加"已选"前缀，参考 Google Keep）
- 桌面端与移动端统一布局，图标足够紧凑

实现方式：在 `build` 方法中根据 `_isSelectionMode` 返回不同的 `AppBar`：

```dart
appBar: _isSelectionMode ? _buildSelectionAppBar() : _buildNormalAppBar(),
```

```dart
PreferredSizeWidget _buildSelectionAppBar() {
  return AppBar(
    leading: IconButton(
      icon: const Icon(LucideIcons.x),
      onPressed: _exitSelectionMode,
    ),
    title: Text('${_selectedUuids.length}'),
    actions: [
      IconButton(icon: const Icon(LucideIcons.pin),     onPressed: _batchToggleStar),   // 星标
      IconButton(icon: const Icon(LucideIcons.palette), onPressed: _showColorPicker),   // 颜色
      IconButton(icon: const Icon(LucideIcons.tag),     onPressed: _batchEditTags),     // 标签
      PopupMenuButton<String>(
        icon: const Icon(LucideIcons.moreVertical),
        onSelected: (value) {
          switch (value) {
            case 'lock':      _batchToggleLock();
            case 'select_all': _toggleSelectAll();
            case 'delete':    _batchDelete();
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(value: 'lock',       child: Row(children: [Icon(LucideIcons.lock), Text('Lock'.tr())])),
          const PopupMenuDivider(),
          PopupMenuItem(value: 'select_all', child: Row(children: [Icon(LucideIcons.checkCheck), Text('Select All'.tr())])),
          PopupMenuItem(value: 'delete',     child: Row(children: [Icon(LucideIcons.trash2), Text('Delete'.tr())])),
        ],
      ),
    ],
  );
}
```

**FAB 在多选模式下隐藏：**

```dart
floatingActionButton: _isSelectionMode ? null : _addANewNoteButton(context),
```

**搜索框在多选模式下隐藏**（或保留但禁用），让操作栏占据完整空间。

---

## 3. 批量操作设计

### 3.1 批量星标

```dart
Future<void> _batchToggleStar() async {
  final allPinned = _selectedUuids.every(
    (uuid) => _noteMeta[uuid]?.pinned ?? false,
  );
  final target = !allPinned; // 全已星标→取消；否则→全部星标

  await Future.wait(
    _selectedUuids.map(
      (uuid) => NotesDatabase.instance.setNotePinned(uuid, target),
    ),
  );
  Log.note.i('批量星标: count=${_selectedUuids.length} pinned=$target');
  SyncService.instance.autoSync();
  _exitSelectionMode();
  refreshNotes();
}
```

### 3.2 批量锁定

```dart
Future<void> _batchToggleLock() async {
  final allLocked = _selectedUuids.every(
    (uuid) => _noteMeta[uuid]?.locked ?? false,
  );
  final target = !allLocked; // 全已锁定→解锁；否则→全部锁定

  await Future.wait(
    _selectedUuids.map(
      (uuid) => NotesDatabase.instance.setNoteLocked(uuid, target),
    ),
  );
  Log.note.i('批量锁定: count=${_selectedUuids.length} locked=$target');
  SyncService.instance.autoSync();
  _exitSelectionMode();
  refreshNotes();
}
```

> **语义说明**：与批量星标一致——选中项中全部已锁定则全部解锁，否则全部锁定。

### 3.3 批量删除

复用现有 `showDeleteConfirmation`，但需扩展文案支持批量：

```dart
Future<void> _batchDelete() async {
  final count = _selectedUuids.length;
  await showDeleteConfirmation(
    context: context,
    count: count,  // ← 新增参数
    onConfirm: () async {
      final ids = _selectedUuids.map((uuid) {
        return allnotes.firstWhere((n) => n.uuid == uuid).id!;
      }).toList();

      await Future.wait(
        ids.map((id) => NotesDatabase.instance.softDelete(id)),
      );
      Log.note.i('批量删除(移入回收站): count=$count');
      SyncService.instance.autoSync();
      _exitSelectionMode();
      refreshNotes();
    },
  );
}
```

**`delete_confirmation.dart` 改动：**

```dart
Future<void> showDeleteConfirmation({
  required BuildContext context,
  required VoidCallback onConfirm,
  int? count,  // ← 新增：null = 单条，非 null = 批量
}) async {
  final message = count != null
      ? 'You are about to delete {count} notes. This action cannot be undone.'
          .tr(namedArgs: {'count': '$count'})
      : "You're about to delete this note. This action cannot be undone.".tr();
  ...
}
```

需在 `zh-CN.json` / `en-US.json` 新增对应翻译 key。

### 3.4 批量设置标签

复用现有 `pushTagEditor`（全屏标签编辑页）：

```dart
Future<void> _batchEditTags() async {
  final TagEditorResult? result = await pushTagEditor(
    context,
    title: 'Edit Tags'.tr(),
    pool: PreferencesStorage.managedTags,
    selected: const [],  // 批量场景下不预选
    selectionMode: true,
  );
  if (result == null) return;

  final tags = NoteMeta.normalizeTags(result.selected);
  await Future.wait(
    _selectedUuids.map(
      (uuid) => NotesDatabase.instance.setNoteTags(uuid, tags),
    ),
  );
  await PreferencesStorage.setManagedTags(result.pool);
  Log.note.i('批量设置标签: count=${_selectedUuids.length} tags=${tags.length}');
  SyncService.instance.autoSync();
  _exitSelectionMode();
  refreshNotes();
}
```

> **语义说明**：批量设置标签是「将选中的标签集合**覆盖**到所有选中笔记」。与 Google Keep 一致——选了哪些标签，所有选中笔记就获得这些标签。

### 3.5 批量修改颜色

弹出颜色选择弹窗（参考 Google Keep 截图 3），选中后批量写入 `NoteMeta.color`：

```dart
Future<void> _showColorPicker() async {
  final int? color = await showNoteColorPicker(
    context,
    currentColor: null,  // 批量场景不预选当前色
  );
  if (color == null) return;

  await Future.wait(
    _selectedUuids.map(
      (uuid) => NotesDatabase.instance.setNoteColor(uuid, color),
    ),
  );
  Log.note.i('批量设置颜色: count=${_selectedUuids.length} color=$color');
  SyncService.instance.autoSync();
  _exitSelectionMode();
  refreshNotes();
}
```

---

## 4. 笔记颜色功能

### 4.1 DB 层：新增 `setNoteColor`

在 `database_handler.dart` 中新增，与 `setNotePinned` 同构：

```dart
/// 设置笔记颜色（ARGB int），null = 恢复默认（跟随主题取色）。
///
/// 与 [setNotePinned] 同构：只写 note_meta，不动笔记正文与 `updated_at`。
Future<NoteMeta> setNoteColor(String uuid, int? color) async {
  final current = await getNoteMeta(uuid) ?? NoteMeta.defaults(uuid);
  return upsertNoteMeta(
    current.copyWith(
      uuid: uuid,
      color: color,
      clearColor: color == null,  // null 时清空
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      synced: false,
    ),
  );
}
```

> `NoteMeta.copyWith` 已支持 `clearColor` 参数（见 `note_meta.dart:184`），无需改模型。

### 4.2 卡片取色逻辑改动

当前 `NoteCardBody.build` 中：

```dart
final Color color = NotesColor.getNoteColor(
  notIndex: index,
  context: context,
);
```

改为优先使用 `NoteMeta.color`：

```dart
final Color color = noteColor ?? NotesColor.getNoteColor(
  notIndex: index,
  context: context,
);
```

`noteColor` 从 `NoteMeta.color` 透传而来。透传链路：

```
HomePage._openNoteEditorContainer
  → _noteMeta[note.uuid]?.color  // 读取用户设置的颜色
  → 4 种卡片壳(noteColor 参数)
  → NoteCardBody(noteColor)
```

同时需要改 `OpenContainer.closedColor`：

```dart
final int? metaColor = _noteMeta[note.uuid]?.color;
final Color cardColor = metaColor != null
    ? Color(metaColor)
    : NotesColor.getNoteColor(notIndex: colorIndex, context: context);
```

**暗色模式适配**：用户设置的 ARGB 颜色在暗色模式下需做压暗处理，复用 `NotesColor` 现有逻辑：

```dart
final Color cardColor = metaColor != null
    ? (PreferencesStorage.isThemeDark
        ? Color.alphaBlend(Color(metaColor).withValues(alpha: 0.5), darkBase)
        : Color(metaColor))
    : NotesColor.getNoteColor(notIndex: colorIndex, context: context);
```

### 4.3 颜色选择 Sheet

用底部 Sheet 而非居中 Dialog——与项目现有 `NoteActionsSheet`、`showThemeBottomSheet` 风格一致，实现更简单（复用 `showShadSheet`），桌面端自动限宽居中。

新建 `lib/widgets/note_color_picker.dart`：

```
底部 Sheet 布局：
┌─────────────────────────────────┐
│  ────── (抓手)                  │
│  笔记颜色                        │
│                                 │
│  ⚪    🔵    🟠    🟡    🟢     │  ← 第 1 行：默认 + 4 色
│  🟣    🔷    🩵    🌸    🍑     │  ← 第 2 行：5 色
│                                 │
└─────────────────────────────────┘

⚪ = 带斜线的圆圈，表示"默认/无颜色"（恢复跟随主题取色）
```

颜色选项来自当前彩色主题色板：`allNotesColorTheme[PreferencesStorage.colorfulNotesColorIndex].colorList`，加上第一个「默认」选项。

弹出方式：`showShadSheet`（底部弹层），与 `NoteActionsSheet` 完全同构：

```dart
Future<int?> showNoteColorPicker(
  BuildContext context, {
  int? currentColor,
}) {
  return showShadSheet<int>(
    context: context,
    side: ShadSheetSide.bottom,
    builder: (context) => ShadSheet(
      padding: EdgeInsets.zero,
      backgroundColor: Colors.transparent,
      border: Border.all(color: Colors.transparent),
      radius: const BorderRadius.vertical(top: Radius.circular(16)),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kDialogMaxWidthWide),
          child: _NoteColorSheet(currentColor: currentColor),
        ),
      ),
    ),
  );
}
```

> 选 Sheet 而非 Dialog 的理由：
> - 复用项目现有 `showShadSheet` + `kDialogMaxWidthWide` 限宽模式，零额外样式
> - 与 `NoteActionsSheet` 同构，代码风格统一
> - 移动端底部 Sheet 操作更自然，桌面端自动限宽居中
> - 无需额外处理 `AlertDialog` 的 `contentPadding` / 圆点间距等细节

### 4.4 编辑页「更多」菜单加入颜色

`NoteAction` 枚举已有 `toggleLock`，新增 `setColor`：

```dart
enum NoteAction {
  copyAll,
  toggleStar,
  toggleLock,
  setColor,      // ← 新增
  editTags,
  versionHistory,
  delete,
}
```

在 `NoteActionsSheet` 中新增对应项（位于 `toggleLock` 之后、`editTags` 之前）。

在 `add_edit_note.dart` 的 `_showMoreMenu` 中处理：

```dart
case NoteAction.setColor:
  final color = await showNoteColorPicker(context, currentColor: _meta?.color);
  if (color != null) {
    await NotesDatabase.instance.setNoteColor(note.uuid, color);
    setState(() => _meta = _meta?.copyWith(color: color, clearColor: color == null));
    refreshNotes();
  }
```

---

## 5. 交互流程图

```
                    ┌─────────────┐
                    │  首页正常态  │
                    └──────┬──────┘
                           │
              ┌────────────┼────────────┐
              │ 长按卡片    │ 点击卡片   │
              ▼            ▼            ▼
      ┌──────────────┐           ┌──────────┐
      │ 进入多选模式  │           │ 进入编辑  │
      │ + 选中当前    │           │   页面   │
      └──────┬───────┘           └──────────┘
             │
    ┌────────┼─────────────────────────────────────┐
    │ 点击卡片     │ AppBar 操作                      │
    ▼             ▼
  切换选中     ┌────┬────┬────┬────┬────┐
    │         ▼    ▼    ▼    ▼
    │       星标  颜色  标签  ⋯溢出
    │                         │
    │                  ┌───────┼───────┐
    │                  ▼       ▼       ▼
    │                锁定    全选    删除
    │         │    │    │    │    │    │
    │         ▼    ▼    ▼    ▼    ▼    ▼
    │       批量  批量  批量  批量  批量  批量
    │       星标  颜色  标签  锁定  全选  删除
    │         │    │    │    │    │
    └────────┬────┴────┴────┴────┴────┘
             ▼
      → autoSync()
      → refreshNotes()
      → 退出多选模式
```

---

## 6. 改动文件清单

### 6.1 核心包（packages/core）

| 文件 | 改动 | 功能 |
|------|------|------|
| `packages/core/lib/src/db/database_handler.dart` | 新增 `setNoteColor(uuid, int?)` 方法 | 颜色功能 |

### 6.2 UI 层（lib/）

| 文件 | 改动 | 功能 |
|------|------|------|
| `lib/views/home.dart` | 多选状态字段、AppBar 切换（含溢出菜单）、卡片交互分支、5 个批量操作方法（星标/锁定/删除/标签/颜色）、FAB 显隐、`PopScope` 返回拦截 | 多选模式 |
| `lib/widgets/note_card_press_feedback.dart` | 新增 `onLongPress` 参数 | 多选模式 |
| `lib/widgets/note_card_body.dart` | 新增 `isSelectionMode` / `isSelected` / `noteColor` 参数，条件边框，取色优先级 | 多选 + 颜色 |
| `lib/widgets/note_card.dart` | 透传 `isSelectionMode` / `isSelected` / `noteColor` | 多选 + 颜色 |
| `lib/widgets/note_tile.dart` | 同上 | 多选 + 颜色 |
| `lib/widgets/note_card_compact.dart` | 同上 | 多选 + 颜色 |
| `lib/widgets/note_tile_compact.dart` | 同上 | 多选 + 颜色 |
| `lib/widgets/note_color_picker.dart` | **新建**，颜色选择底部 Sheet（圆点矩阵） | 颜色功能 |
| `lib/widgets/note_actions_sheet.dart` | 新增 `setColor` 枚举值 + 菜单项 | 颜色功能 |
| `lib/dialogs/delete_confirmation.dart` | 新增 `count` 参数支持批量文案 | 多选删除 |
| `lib/views/add_edit_note.dart` | 处理 `setColor` action，调用颜色选择器 | 颜色功能 |

### 6.3 资源与配置

| 文件 | 改动 |
|------|------|
| `assets/translations/zh-CN.json` | 新增翻译 key（批量删除文案、颜色选择弹窗文案、多选操作栏文案） |
| `assets/translations/en-US.json` | 同上 |

---

## 7. 翻译 key 清单

| key | zh-CN | en-US |
|-----|-------|-------|
| `You are about to delete {count} notes. This action cannot be undone.` | `即将删除 {count} 条笔记，此操作无法撤销。` | `You are about to delete {count} notes. This action cannot be undone.` |
| `Select All` | `全选` | `Select All` |
| `Note Color` | `笔记颜色` | `Note Color` |
| `Default Color` | `默认` | `Default` |
| `Lock` | `锁定` | `Lock` |
| `Set Color` | `修改颜色` | `Set Color` |

> 注：AppBar 的星标/锁定/标签/颜色图标用 `tooltip`，复用已有翻译 key（`Starred` / `Note locked` / `Edit Tags` / `Note Color`）。

---

## 8. 隐私与同步考量

### 8.1 隐私

- `NoteMeta.color` 是明文 `int?` 列（ARGB 值不含用户内容语义），与 `pinned` / `locked` 同级
- 颜色值不泄露笔记内容，明文存储可接受（已在 `feature-note-meta-design.md §2` 确认）
- 日志只记 uuid + count + color 值，不记笔记内容

### 8.2 同步

- 颜色写入 `note_meta` 表，走 `upsertNoteMeta` → `synced=false` → 自动同步
- 同步走 `items.meta` 加密文件，per-note LWW 合并，与星标/标签/锁定完全一致
- 不碰 `notes` 表的 `content_hash` / `updated_at`，不触发笔记正文重传

### 8.3 性能

- 批量操作用 `Future.wait` 并行执行，N 条笔记的 DB 写入并行（SQLite 内部串行化但调用不阻塞）
- `autoSync` 有 debounce，N 次写入只触发一次同步
- 后续如有性能需求，可在 `database_handler` 新增 `setNotePinnedMany` / `softDeleteMany` / `setNoteColorMany` / `setNoteLockedMany` 批量接口（单事务），当前不必要

---

## 9. 测试要点

### 9.1 单元测试

- `setNoteColor` 写入后 `getNoteMeta` 能读到正确的 color 值
- `setNoteColor(uuid, null)` 能正确清空 color
- 批量 `Future.wait` 多个 `setNotePinned` / `setNoteLocked` 后所有 uuid 状态正确

### 9.2 Widget 测试

- 长按卡片进入多选模式，AppBar 切换为操作栏
- 多选模式下点击卡片切换选中态，边框高亮
- 全选/取消全选
- 批量删除弹确认对话框，确认后笔记移入回收站
- 批量星标后刷新列表，置顶排序正确
- 批量锁定后刷新列表，锁定状态正确
- 颜色选择弹窗弹出，选择颜色后卡片变色
- 退出多选模式后恢复正常 AppBar

### 9.3 集成测试

- `flutter test integration_test/app_test.dart -d windows`
- 长按 → 选中 → 星标 → 验证置顶
- 长按 → 选中 → 锁定 → 验证只读
- 长按 → 选中 → 删除 → 验证回收站
- 长按 → 选中 → 颜色 → 选择颜色 → 验证卡片变色
- 编辑页「更多」→ 颜色 → 选择颜色 → 验证卡片变色

---

## 10. 实施建议

### 10.1 分阶段

| 阶段 | 内容 | 依赖 |
|------|------|------|
| P1 | DB 层 `setNoteColor` + 卡片取色支持 `NoteMeta.color` | 无 |
| P2 | 颜色选择弹窗 + 编辑页菜单集成 | P1 |
| P3 | 多选模式核心（状态 + 交互 + 边框高亮 + AppBar 切换） | 无 |
| P4 | 批量操作（星标 / 锁定 / 删除 / 标签 / 颜色） | P3 |
| P5 | 翻译 + 测试 | P1-P4 |

P1/P2（颜色）和 P3/P4（多选）互相独立，可并行开发。

### 10.2 风险点

1. **`OpenContainer` 与多选交互**：多选模式下 `OpenContainer` 仍存在但不触发 `action()`，需确认不会有视觉异常（如卡片仍保持 closed 态外观）
2. **桌面端右键**：桌面端长按行为可能与右键菜单冲突，需测试桌面端的 `onLongPress` 触发条件（Flutter 桌面端 `onLongPress` 由鼠标右键或长按触发，需验证）
3. **大量笔记批量操作**：`Future.wait` 并行 N 个 DB 写入，SQLite 串行执行但可能阻塞 UI 线程，需测试 100+ 条笔记的性能
4. **颜色与暗色模式**：用户设置的 ARGB 颜色在暗色模式下可能对比度不足，需复用 `NotesColor` 现有的 `alphaBlend` 压暗逻辑
5. **批量锁定语义**：锁定是只读标记，批量锁定后用户在编辑页打开笔记将看到只读预览——需确保 UX 上不会让用户困惑"为什么突然不能编辑了"
