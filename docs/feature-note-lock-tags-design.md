# 笔记锁定 + 标签体系 UI 增强设计文档

> 立项：2026-08-20。对应需求：note_meta 增加 `locked` 列；笔记详情更多菜单加锁定/解锁；
> Drawer/NavigationRail 增加星标入口 + 标签 group（分割线分组）；编辑页标签改为 FilterChip；
> 详情页标题下方右侧浮层展示标签。实施与日志见 `docs/progress-note-lock-tags-task.md`。

## 1. 目标

1. `note_meta` 新增明文列 `locked`（boolean），笔记锁定后只读不可编辑；详情页更多菜单提供
   「锁定 / 解锁」切换项。
2. 抽屉 / 桌面侧栏新增两个导航入口：**星标笔记**（过滤首页只显示星标）与**标签 group**
   （标签一行一个，默认 个人/工作/灵感；group header 右侧编辑图标可增删标签；点击标签过滤首页）。
   入口按需求用分割线分组：`笔记 / 最近删除 / 星标 / —— / 标签组 / —— / 设置 / 锁定`。
3. 首页过滤（星标或某标签）生效时，AppBar 显示过滤态文本（星标 / 标签名），可在其中清除过滤。
4. 编辑页「更多」菜单中的「编辑标签」从纯文本输入框升级为 **FilterChip** 交互（现有标签用 chip 单选动态增删 + 追加新标签）。
5. 笔记详情页在标题下方右侧以浮层 / Wrap 展示标签（chip 控件）。

## 2. 数据层：NoteMeta.locked

- `locked` 为**明文列**（与 `pinned` 同级：boolean 枚举、简单查询判定，不含用户输入文本语义），
  存储于 `note_meta` 表，**不**进加密 payload。
- 前向兼容：`locked` 是布尔标志，无需参与 payload 版本，与 `pinned` 同构。
- 同步：锁定状态是否广播对端？为控制范围，`locked` 作为**本地行为标志**仅随元数据行一起
  upsert，但不作为同步项强制推送语义（与 pinned 相同的一套 LWW 锚点 `updated_at` / 脏标记
  `synced`，同步机制无需改动）。

### 2.1 Schema / 迁移

- 新建库：`_createNoteMetaTable` 建表语句加入 `locked INTEGER NOT NULL DEFAULT 0`。
- 老库升级：`_schemaVersion` 5 → 6；
  - `oldVersion < 5`：走 `_createNoteMetaTable`（含 locked，幂等）。
  - `5 <= oldVersion < 6`：`ALTER TABLE note_meta ADD COLUMN locked INTEGER NOT NULL DEFAULT 0`。
- 墓碑复位：`_markNoteMetaDeletedInTxn` 写入 `locked: 0`。

### 2.2 模型与 DB 方法

- `NoteMeta` 增加 `locked` 字段，纳入 `copyWith / toRow / fromRow / isDefault / toString`。
- `NoteMetaFields.values` 增加 `locked`。
- 新增 `setNoteLocked(uuid, locked)`（与 `setNotePinned` 同构）。
- tags 相关不变：`setNoteTags / readAllTags` 已存在。

## 3. UI 层

### 3.1 编辑页（add_edit_note.dart）

- `initState` 异步读取 `getNoteMeta(uuid)`，以 `_meta`（含 pinned / locked / tags）驱动界面。
- **锁定语义**：`locked == true` 时强制只读——
  - AppBar 隐藏「预览/编辑」切换与「保存」按钮（或禁用其 onPressed）；
  - 隐藏编辑区，仅展示预览；不进入编辑模式。
- 更多菜单（note_actions_sheet）新增「锁定/解锁」项，按 `_meta.locked` 显示 `Lock note` / `Unlock note`。
- 「编辑标签」改为 FilterChip 弹层（见 3.3）。

### 3.2 抽屉 / 桌面侧栏

- `HomeDrawer` 与 `HomeSidebar` 结构调整为：
  `笔记 / 最近删除 / [divider] 星标 / 标签组(header+edit) 逐行标签 / [divider] 设置 / 锁定`。
- 新增回调解偶：`onStarredCallback`、标签相关回调与标签列表数据（由 `HomePageState` 提供，因标签需读库聚合）。
- 已用 key 保持兼容：`ui-home-nav-deleted / -settings / -lock` 不变；新增
  `ui-home-nav-starred`、`ui-home-nav-tag-<name>`、`ui-home-tag-edit`。

### 3.3 标签编辑 FilterChip 弹层

- 新建对话框：列出当前全部可用标签（`readAllTags` 合并持久化管理标签）为 `FilterChip`，
  点选进入本笔记标签集合；另提供「添加标签」输入，将新标签写入本笔记标签集。
- 保存时调用 `setNoteTags`。

### 3.4 首页过滤状态

- `HomePageState` 增加 `_activeTag`（String?）与复用 `_showStarredOnly`。
  - 星标入口：将 `_showStarredOnly = true`。
  - 标签入口：将 `_activeTag = tag`，过滤 `_noteMeta[note.uuid]?.tags.contains(tag)`。
- AppBar 增加过滤态指示 chip / 按钮：显示「星标」或标签名，点击清除过滤。
- 抽屉回调在 pop 后调用上述设置并刷新列表。

### 3.5 详情页标签浮层

- 预览模式下标题下方、右侧以 `Wrap` + `FilterChip`（只读样式）展示 `_meta.tags`。

## 4. 测试

- core：`locked` 字段 CRUD + 迁移（v5→v6 ALTER）+ 墓碑复位。
- widget：note_actions_sheet 新增锁定项及返回枚举；抽屉布局（分割线分组、星标项、标签组）；
  编辑页锁定只读；编辑标签 FilterChip 弹层无溢出；详情页标签浮层渲染无溢出。
- 全量：`dart format`、`flutter analyze`、`dart test packages/core/test`、`flutter test`、
  `flutter build windows --debug`、`flutter test integration_test/ -d windows`。

## 5. 范围外（本期不做）

- locked 的跨设备强制（本地行为标志）。
- 标签改为持久化独立实体类型（仍随笔记 payload + 管理列表持久化于偏好）。