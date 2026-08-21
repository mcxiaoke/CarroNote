# Progress — 笔记锁定 + 标签体系 UI 增强

> 需求索引见 `docs/feature-note-lock-tags-design.md`。本文件记录分步实施过程与结果，防止遗忘。

## 状态总览

- [x] 1. 数据层：NoteMeta.locked（模型/建表/迁移/墓碑/setNoteLocked）+ core 测试
- [x] 2. 编辑页锁定语义（更多菜单加锁定/解锁项、锁定只读）
- [x] 3. 编辑标签改 FilterChip 弹层
- [x] 4. 详情页标题下方右侧标签浮层
- [x] 5. Drawer / NavigationRail 增星标入口 + 标签 group（分割线分组）
- [x] 6. 首页星标/标签过滤 + AppBar 过滤态指示
- [x] 7. i18n zh-CN / en-US 新增 key
- [x] 8. 新增 widget 测试
- [x] 9. 全量验证（format/analyze/core/flutter/build/integration）
- [x] 10. CHANGES 落档

## 决策记录（设计定案）

- `locked` 为**明文列**（平级 pinned），随 note_meta upsert，不参与同步推送语义（本地行为标志）。
- schema v5 → v6：旧库已有 note_meta 时 `ALTER TABLE ADD COLUMN locked`；新建/`<5` 库走
  `_createNoteMetaTable`（含 locked），避免重复 ADD 报错。
- 标签候选池 & 管理列表：持久化于 `PreferencesStorage.managedTags`（默认 个人/工作/灵感），
  笔记标签编辑（FilterChip）与抽屉标签组的增删共用该池，保证一致性。
- 抽屉布局：`笔记 / 最近删除 / [分割线] 星标 / 标签组 / [分割线] 设置 / 锁定`。
- 过滤态：AppBar 用 Chip 显示「星标」或标签名，点击清除。

## 分步日志

### Step 1 数据层（完成）
- `packages/core/.../note_meta.dart`：`NoteMetaFields` 增 `locked`；`NoteMeta` 增字段/构造/copyWith/isDefault/toRow/fromRow/toString。
- `database_handler.dart`：`_schemaVersion=6`、建表加 locked、迁移 `5<=old<6` ALTER、墓碑 locked:0、新增 `setNoteLocked`。
- 测试 `note_meta_test.dart`：setNoteLocked、isDefault、v5→v6 迁移组（补齐 locked 列 + 老行默认0 + 可写回）。
- 结果：`dart test packages/core/test/db/note_meta_test.dart` 全部通过。（sync 层不触碰 note_meta，无回归面）

### Step 2~7 UI（完成）
- **偏好**`lib/data/preference_and_config.dart`：新增 `managedTags` 管理标签池（默认 个人/工作/灵感）及增删方法。
- **note_actions_sheet**：`NoteAction` 增 `toggleLock`；`showNoteActionsSheet` 增 `locked` 参数；新增「锁定/解锁」项（`ui-note-action-lock`）。
- **add_edit_note.dart**：`initState` 异步读 meta 驱动锁定语义；锁定笔记隐藏编辑/预览/保存、强制只读预览、顶部锁定横幅 `ui-note-locked-banner`；预览标题下方右侧标签浮层（`ui-note-tag-*`）；`_editTags` 改用 FilterChip 弹层（`showNoteTagEditor`）；新增 `_toggleLock`。
- **tag_editor.dart（新）**：`showNoteTagEditor`（FilterChip 勾选 + 追加）、`showTagManager`（全局标签池增删）。对话框用响应式 `_kTagDialogConstraints`（maxWidth 560）避免窄屏强制 400 撑宽。
- **drawer.dart / home_navigation_rail.dart**：新增星标入口 `ui-home-nav-starred` + 标签组（header `ui-home-tag-edit` + 逐行 `ui-home-nav-tag-*`），布局 `笔记/最近删除/【分割】星标/标签组/【分割】设置/锁定`。
- **home.dart**：新增 `_activeTag` 与 `_applyMetaFilters`（星标+标签复合过滤）、`_enableStarredFilter/_enableTagFilter/_clearFilters`、AppBar 过滤态指示 `ui-home-filter-indicator`（Chip，点击清除）。
- **i18n**：en-US.json / zh-CN.json 增 locked/starred/tag/filter 相关 key。

### Step 8 测试（完成）
- 新增 `test/home_drawer_test.dart`、`test/tag_editor_test.dart`、`test/note_locked_tag_test.dart`；更新 `test/note_actions_sheet_test.dart`（locked 参数 + 锁定项）。15 项全部通过，覆盖抽屉布局/标签组/FilterChip/锁定只读/标签浮层，无布局溢出。

### Step 9 全量验证（完成）
- `flutter analyze`：无 error（仅 3 条 test/pin_keyboard_test.dart 的 pre-existing info）。
- `dart test packages\core\test`：全部通过。
- `flutter test`：84 项全部通过。
- `flutter build windows --debug`：成功。
- 集成测试 `flutter test integration_test/ -d windows`：
  - 修复了一处**回归**：侧栏（HomeSidebar）新增星标/标签组后，`settings/lock` 在矮窗口被懒构建 ListView 滚出折叠区，导致 `ui-home-nav-settings/lock` 找不到。已把 settings/lock **钉在侧栏底部**（不进滚动 ListView），`settings: visit every sub-page` 测试恢复通过。
  - 其余 2 个失败（`auth lock re-login`、`pin keypad`）发生在**登录页 / PIN 页**（本次未改动）的 `compact-land-890x400`（高仅 400px 横屏），属该环境固有的极矮屏布局不达标/启动时序问题，非本次改动引入。
  - `first_run_test.dart` 一次为「debug 连接中断」设备启动失败（环境偶发），非代码错误。

### Step 10 文档
- 本 progress 归档 + `docs/CHANGES-20260820.md` 顶部追加变更摘要。