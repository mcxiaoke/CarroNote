# 五项功能可行性评估报告

- **日期**：2026-08-23
- **输入**：`docs/UIUX-REVIEW-HOME-NOTE-20260822.md` 的 P0/P1/P2 待办
- **评估范围**：
  1. 笔记页 Markdown 格式工具栏
  2. 文件附件 / 图片附件
  3. 文件夹 / 笔记本（层级组织）
  4. 清单 / 待办类型支持
  5. 提醒 / 闹钟
- **评估基准**：现有代码 `lib/views/add_edit_note.dart:258` 的 `NoteFormWidget`、`packages/core/lib/src/db/database_handler.dart:521` 的 schema v7、`packages/core/lib/src/models/safenote.dart:270` 的 `toContentBytes()` / `computeHash()`、`packages/core/lib/src/models/note_meta.dart:133` 的 `extra` 透传机制、`packages/core/lib/src/crypto/crypto.dart:386` 的 `SyncCrypto.seal/open`、`packages/core/lib/src/sync/sync_models.dart:837` 的 `ManifestCrypto`、E2EE 约束（`packages/core` 禁止 Flutter 依赖 `AGENTS.md:15`）

---

## 一、总览结论

| # | 功能 | 审查优先级 | 本评估建议优先级 | 复杂度 | 工作量 | 风险 | 一句话定性 |
|---|------|-----------|----------------|--------|--------|------|-----------|
| 1 | Markdown 工具栏 | P0 | **P0 先做** | 低 | 2-3 人日 | 低 | 纯 UI 插入语法，无模型/同步改动，ROI 最高 |
| 2 | 附件 / 图片 | P1 | P1 中期 | **高** | 12-20 人日 | **高** | 触及加密、存储、同步、GC、权限、预览安全全链路 |
| 3 | 文件夹 / 笔记本 | P1 | P1 中期 | 中高 | 8-12 人日 | 中 | 新实体 + 同步 + 双端导航，次于附件 |
| 4 | 清单 / 待办 | P1 | **P0/P1 早期** | 低-中 | 3-6 人日 | 低-中 | 可走 Markdown 语法 + 交互增强，或独立 `note_type` |
| 5 | 提醒 / 闹钟 | P2 | P2 后期 | 中高 | 8-14 人日 | 中高 | 依赖系统通知、权限、后台调度，与 E2EE 正交但平台差异大 |

> 工作量按单人全职计，含设计 + 编码 + 测试 + 文档，未含联调多设备同步的长周期验证。

**落地顺序建议**：`1 → 4 → 3 → 2 → 5`。理由见 §七。

---

## 二、项目约束（所有方案的硬边界）

所有评估均在以下约束下展开，违反即返工：

1. **E2EE 本地优先**：`title`/`description` 字段级加密 `database_handler.dart:457` 的 `_encryptField(uuid, plaintext)`，AAD=`uuid`/`meta:<uuid>`，明文绝不落盘明文字段。任何新字段含用户输入文本必须进加密域。
2. **core 纯 Dart**：`AGENTS.md:15` / `packages/core/pubspec.yaml:2` 明确 `packages/core` 禁止 Flutter 依赖。模型、加密、DB、同步均可在 `dart test packages/core/test` 无 Flutter 环境验证。
3. **内容寻址红线**：`safenote.dart:255` 的 `computeHash(title+"\n"+description)` 与 `safenote.dart:270` 的 `toContentBytes()` 是 blob 身份与 GCM AAD 的锚点，改动即触发全量 blob 失联。`note_meta.dart:29` 已立红线“绝不参与 blob 寻址”。
4. **同步一致性**：`sync_models.dart:90` 的 `Manifest` + `sync_engine.dart:232` 的 `sync()` 乐观锁 + `synced_hash/synced_deleted` 三方合并基线。新增实体不得破坏 `updatedAt` LWW 与墓碑 GC。
5. **隐私渲染**：`add_edit_note.dart:668` 的 `imageBuilder => SizedBox.shrink()` 是有意禁图以防 IP 泄露，附件预览必须延续同等隐私策略。
6. **现有扩展点已验证**：`note_meta.dart:128` 的 `extra` 透传、`database_handler.dart:582` 的 `_createNoteMetaTable` 独立缓存 `_metaCache:322` 与笔记缓存隔离，是后续轻量扩展的正例。

---

## 三、1. 笔记页 Markdown 格式工具栏

### 3.1 现状

- 编辑器为两段 `ShadInputFormField` 无边框输入 `lib/widgets/note_widget.dart:68` / `:105`，由上层 `TextEditingController` 驱动 `add_edit_note.dart:112`。预览用 `flutter_markdown_plus: ^1.0.12` 的 `MarkdownBody` `add_edit_note.dart:664`，但 `imageBuilder` 被禁。
- 无工具栏，用户需手写 `**`/`# ` / `- ` / ````` 等，对非技术用户门槛高，为审查 P0 痛点 `UIUX-REVIEW-HOME-NOTE-20260822.md:47`。

### 3.2 实现方案

**推荐：轻量插入式工具栏（不引入富文本编辑器）**，对齐 Standard Notes / Joplin 做法。

**UI 位置**：
- 键盘上方 `InputAccessory` / `BottomAppBar` 常驻条，图标：B I H1 H2 引用 列表 任务 代码 链接。桌面端置于 `AppBar` 与正文之间，移动端跟随键盘 `viewInsets` (`add_edit_note.dart:787` 的 `_KeyboardAwarePadding` 已做键盘避让，可复用)。
- 复用 `shadcn_ui` 图标体系 `LucideIcons`，与现有 `add_edit_note.dart:303` 的 undo/redo 同风格。

**交互**：
- 选中文本 → 包裹语法（如 `**选中**`、` `code` `、`[text](url)`），无选中则插入模板并将光标移至占位区。
- 列表/标题为行首插入；任务列表插入 `- [ ] ` 并回车自动续行。
- 撤销栈复用现有 `NoteEditHistory` `add_edit_note.dart:68`，插入操作走同一 `TextEditingValue` 快照，无需新历史。

**核心插入逻辑**（伪代码，落于 `lib/utils/markdown_toolbar.dart`）：

```dart
void insertWrap(TextEditingController c, String left, String right) {
  final sel = c.selection;
  final text = c.text;
  if (!sel.isValid || sel.isCollapsed) {
    c.value = TextEditingValue(
      text: text.replaceRange(sel.start, sel.start, '$left$right'),
      selection: TextSelection.collapsed(offset: sel.start + left.length),
    );
  } else {
    final selText = sel.textInside(text);
    c.value = TextEditingValue(
      text: text.replaceRange(sel.start, sel.end, '$left$selText$right'),
      selection: TextSelection.collapsed(offset: sel.end + left.length + right.length),
    );
  }
}
```

**预览联动**：工具栏常驻编辑态，预览态隐藏；`isMarkdownEnabled` 关闭时工具栏置灰或隐藏，避免纯文本模式误插入。

**备选（不推荐一期）**：引入 `flutter_quill` / `super_editor` 富文本。代价是模型从 Markdown 文本变为 Delta JSON，`computeHash` / `toContentBytes` / 版本历史 `note_versions` 全链路重写，工作量与风险均翻倍。

### 3.3 模型 / 存储 / 同步影响

- **零改动**：仍为 `title`/`description` 纯文本 + Markdown 语法，`safenote.dart:255`、`database_handler.dart:487`、`sync_models.dart:837` 均不动。
- 兼容性：历史笔记已存 Markdown 源码，工具栏仅降低输入门槛，不产生格式迁移。

### 3.4 工作量与复杂度

| 项 | 估算 |
|---|------|
| 工具栏 UI + 插入逻辑 + 光标/选中处理 | 1 人日 |
| 桌面/移动适配、键盘避让、无障碍 | 0.5 人日 |
| 单测（插入单元）+ 集成测 + i18n `zh-CN`/`en-US` | 0.5-1 人日 |
| **合计** | **2-3 人日** |
| **复杂度** | **低** |
| **风险** | 低；唯一坑为多行选中包裹与撤销栈联动，需补用例 |

### 3.5 风险与注意

- 多语言键盘、中文输入法组合输入（IME composition）时 `selection` 可能为 `isComposing`，需守卫。
- `flutter_markdown_plus` 表格是否渲染需验证（审查 P2 疑问），若需表格，在工具栏加 `| |` 插入即可，无需换渲染库。

---

## 四、2. 文件附件 / 图片附件

### 4.1 现状与约束

- 预览禁图 `add_edit_note.dart:669`，设计意图防 IP 泄露；同步层 blob 仅承载笔记 JSON `safenote.dart:270`，无附件通道；DB 无附件表。
- `feature-note-meta-design.md:8.3` 已预留 `attachments` 表设计，但未实现。
- 隐私要求：文件名、MIME、路径均为用户输入敏感信息，必须加密；Server 端为任意 `resources/<path>` 直传 `docs/feature-note-meta-design.md:6.2`，附件可复用同机制但需独立 GC。

### 4.2 终态方案（E2EE 附件）

**存储分层**：

```
本地 SQLite
  attachments 表 —— 元数据（见 4.3）
  app_support/attachments/<hash> —— 密文文件缓存（可选，防大文件进 DB）
远端 Backend
  blobs/<hash> 或 resources/attachments/<hash> —— 密文 blob（与笔记 blob 同源）
  manifest items.<uuid>.attachments[] —— 引用清单（或独立 items.attachments 段）
```

两种远端形态二选一，推荐 **A 方案：复用现有 blob 存储**（内容寻址 + 去重 + GC 已有），附件内容即一个独立 blob，`hash = SHA-256(明文字节)`，`envelope = SyncCrypto.seal(dataKey, hash, bytes)`，AAD=`hash` 与笔记 blob `crypto.dart:386` 同规。

**为什么必须独立表**（而非塞 `note_meta.payload`）：`feature-note-meta-design.md:8.1` 已定性——一对多、独立生命周期、需反向查询、需 GC，均指向独立表。塞 JSON 会导致单笔记附件膨胀、无法单条增删、无法按 hash 去重。

### 4.3 本地表设计（v8）

```sql
CREATE TABLE attachments (
  _id         INTEGER PRIMARY KEY AUTOINCREMENT,
  uuid        TEXT NOT NULL UNIQUE,          -- 附件自身 uuid
  note_uuid   TEXT NOT NULL,                 -- 所属笔记 uuid，无 FK CASCADE（墓碑需存活）
  blob_hash   TEXT NOT NULL,                 -- 内容寻址 hash，复用 blob 体系
  meta        TEXT,                          -- 加密 JSON：{filename,mime,size,width,height,createdAt}
  created_at  INTEGER NOT NULL,
  deleted     INTEGER NOT NULL DEFAULT 0,    -- 墓碑
  updated_at  INTEGER NOT NULL,              -- per-attachment LWW
  synced      INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_attachments_note ON attachments(note_uuid);
CREATE INDEX idx_attachments_hash ON attachments(blob_hash);
CREATE INDEX idx_attachments_synced ON attachments(synced);
```

- `meta` 加密：AAD=`attachment:<uuid>` 或 `meta:<attachment-uuid>`，与 `database_handler.dart:1154` 的 `_metaAad` 同域隔离模式一致。
- 大文件：`file_picker: ^11.0.2` 已在依赖中，`pubspec.yaml:32`，读取后直接 `SyncCrypto.seal`，密文落应用支持目录，不进 SQLite BLOB，避免 DB 膨胀。
- 迁移：`CREATE TABLE IF NOT EXISTS` 幂等，同 `note_meta` / `note_versions` 模式，`_schemaVersion = 8`。

### 4.4 同步设计

- **上传**：笔记保存时扫描附件 `synced=0` → `putBlob(hash, envelope)` → manifest 写入引用 → `markSynced`。
- **下载**：manifest 拉取 → 对比本地缺失 `blob_hash` → `getBlob(hash)` → `SyncCrypto.open(dataKey, hash, envelope)` → 落缓存。
- **去重**：同 `safenote.dart:258` 的内容寻址天然去重，同一图片被多笔记引用仅存一份 blob。
- **墓碑**：`deleted=1` 同步为墓碑，30 天 GC 窗口后 `hardDeleteByUuid` 清理，复用 `database_handler.dart:1404` 的 purged 机制或独立 `attachments_deleted` 索引。
- **冲突**：附件维度 `updatedAt` LWW，与 `note_meta` `per-note LWW` 同构，不触碰笔记正文 `updatedAt`。

备选：附件引用走独立 `items-attachments` 加密段而非混入 `manifest.items`，可减少 manifest 体积，但首版混入即可，后续再拆。

### 4.5 UI/UX

- 编辑页：正文下方附件条（`ListView` 横向缩略图 + 文件行），“添加附件”按钮调 `file_picker` + `permission_handler: ^12.0.3` 已有依赖。
- 预览页：图片缩略图（解密后内存渲染，不走网络 `imageBuilder`，不泄露 IP），文件显示名 + 大小 + 下载/打开。
- 卡片：附件角标（📎 + 计数），与现有星标角标 `note_card_body.dart:206` 同区域。
- 桌面拖拽：可选二期，`file_picker` 先覆盖。

### 4.6 平台与依赖

- 权限：`permission_handler` 已有；桌面端 `file_picker` 走原生对话框无额外权限。
- 图片压缩：可选 `flutter_image_compress`（未在当前依赖，需新增），否则原图直传需提示流量。
- 依赖新增：`mime: ^1.0`（MIME 推断）、`crypto: ^3.0.3` 已有用于 hash。

### 4.7 工作量与复杂度

| 阶段 | 内容 | 估算 |
|------|------|------|
| 1. 模型与 DB | `Attachment` 模型、`attachments` 建表×2 路径、v8 升级、CRUD + 缓存独立（同 `_metaCache` 隔离） | 3 人日 |
| 2. 加密与存储 | `SyncCrypto.seal/open` 复用、文件缓存、缩略图、meta 加解密 | 2 人日 |
| 3. 同步 | SyncEngine 附件上下行、去重、墓碑、GC（两阶段候选 `gc_orphan_candidates:110` 同理） | 4-6 人日 |
| 4. UI | 编辑/预览/卡片附件 UI、选择器、错误态、进度 | 3-4 人日 |
| 5. 测试与联调 | 迁移测试、加解密往返、per-attachment LWW、多设备附件同步、权限矩阵 | 2-3 人日 |
| **合计** |  | **14-20 人日**（精简版 12 人日起） |
| **复杂度** |  | **高** |
| **风险** |  | **高**：加密域、GC 误删、WebDAV/SafeServer 大文件超时、旧版本兼容 |

### 4.8 关键风险

- **GC 误隔离**：`database_handler.dart:107` 的 `gc_orphan_candidates` 已有两阶段 GC 防“刚 putBlob 未 putManifest”误删，附件需同等机制。
- **密钥迁移**：`database_handler.dart:1604` 的 `reEncryptAllNotes` 需同步覆盖 `attachments.meta` 与文件缓存密文，否则换 key 后附件永久不可解（同 `note_meta.payload` 教训）。
- **流量与配额**：附件远大于笔记 `contentSize:131` 的 `toContentBytes` 体量，需限单文件大小、分片/重试（参考 `sync_engine.dart:205` 的 `_withBlobRetry`）。
- **隐私**：缩略图不得写入系统相册（`media_scanner: ^2.1.0` 仅备份场景用），附件打开用应用内预览。

---

## 五、3. 文件夹 / 笔记本（层级组织）

### 5.1 现状

- 仅扁平标签 + `pinned` 置顶 `home.dart:995` 的 `_applyViewFilter` 为标题+正文子串匹配，`note_meta.payload.tags` 加密存储 `note_meta.dart:124`。超百条后定位困难，为审查 P1 缺失 `UIUX-REVIEW-HOME-NOTE-20260822.md:33`。

### 5.2 方案对比

| 方案 | 形态 | 优点 | 缺点 | 推荐度 |
|------|------|------|------|--------|
| A. 单层笔记本 | `payload.notebook = "<notebook-uuid>"` 单字段 | 零新表，复用 `extra` 透传；一期最快 | 无树形、无法嵌套、拖拽移动弱 | ⭐⭐⭐ 一期可用 |
| B. 独立表树形 | `notebooks` 表 + `note_meta.notebook` 外键逻辑关联 | 支持多级、排序、重命名级联 | 需新表、同步、UI 树 | ⭐⭐⭐⭐ 终态 |
| C. 标签层级化 | 标签加 `/` 层级（如 `工作/项目A`） | 无新实体 | 加密标签无法 SQL 前缀查询，内存过滤复杂 | ⭐⭐ 不推荐 |

**推荐路径：A → B 渐进**。一期用 `note_meta.extra["notebook"]` 跑通筛选与侧栏，验证交互后再升级为独立表，避免一口吃成胖子。

### 5.3 终态模型（B 方案）

```sql
CREATE TABLE notebooks (
  _id         INTEGER PRIMARY KEY AUTOINCREMENT,
  uuid        TEXT NOT NULL UNIQUE,
  parent_uuid TEXT,                          -- NULL=根，树形
  name        TEXT NOT NULL,                 -- 加密存储（用户输入，敏感）
  sort_order  INTEGER NOT NULL DEFAULT 0,
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL,              -- per-notebook LWW
  deleted     INTEGER NOT NULL DEFAULT 0,
  synced      INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_notebooks_parent ON notebooks(parent_uuid);
```

- `name` 加密：AAD=`notebook:<uuid>`，同 `note_meta` 域隔离。
- 笔记归属：`note_meta.payload.notebook` 存 `notebook uuid`（非名字，避免重命名级联改名风暴），或提升为明文列 `notebook_uuid` 若需按笔记本 SQL 过滤（权衡：uuid 非敏感可明文）。
- 树形约束：应用层维护 `parent_uuid` 环检测，删除为软删 + 子节点上移或级联软删（产品定）。

同步：`notebooks` 全量 `items.notebooks` 加密段，`per-notebook LWW` 合并，与 `note_meta` 同引擎集成点 `sync_engine.dart:232`。

### 5.4 UI

- 侧栏 `home_navigation_rail.dart:15`：新增“笔记本”分组，树形 `ExpansionTile`，拖拽移动（`ReorderableListView`）。
- 首页过滤：笔记本筛选与现有 `pinned`/`tags` 过滤正交，`_applyViewFilter` 叠加 `notebook == activeNotebook` 条件。
- 笔记页：`note_actions_sheet.dart` 加“移动到笔记本”。
- 新建笔记本：重用 `tag_editor.dart` 的 `pushTagEditor` 模式，全屏编辑 + 校验重名。

### 5.5 工作量与复杂度

| 阶段 | 估算 |
|------|------|
| A 方案（payload 单层）UI+过滤 | 2-3 人日 |
| B 方案增量：表 + 模型 + CRUD + v9 | 2 人日 |
| 树形 UI + 拖拽 + 双端导航（Rail/Drawer） | 2-3 人日 |
| 同步 per-notebook LWW + 迁移 | 2-3 人日 |
| 测试（树操作、重命名、删除、同步） | 1 人日 |
| **合计** | **A: 2-3 / B全量 8-12 人日** |
| **复杂度** | **中高**（A 为中，B 为中高） |
| **风险** | 中：树形一致性、循环引用、同步并发重命名 |

---

## 六、4. 清单 / 待办类型支持

### 6.1 现状

- 无 checklist，笔记仅 `title`/`description` 文本 `safenote.dart:68`。Markdown 预览 `flutter_markdown_plus` 已支持 `- [ ]` / `- [x]` 语法渲染，但无交互勾选。
- 需求为 Keep 灵魂功能，审查 P1 `UIUX-REVIEW-HOME-NOTE-20260822.md:58`。

### 6.2 方案对比

| 方案 | 实现 | 优点 | 缺点 | 推荐度 |
|------|------|------|------|--------|
| A. 纯 Markdown 任务列表 | 复用 `- [ ] task` 语法，工具栏一键插入，回车续行，预览渲染复选框可点 | 零模型改动，兼容现有 `computeHash`/`toContentBytes` | 交互需解析行更新文本，历史版本 diff 友好 | ⭐⭐⭐⭐⭐ 推荐一期 |
| B. 独立 `note_type` + 子任务表 | `note_meta.payload.type="checklist"` + `checklist_items` 表 | 支持拖拽排序、独立勾选态 LWW、进度条 | 新表 + 同步 + 迁移，重量级 | ⭐⭐⭐ 二期可选 |
| C. 混合：文本 + 结构化索引 | 文本仍为 Markdown，本地解析建内存索引用于统计/过滤 | 兼顾兼容与功能 | 解析一致性成本 | ⭐⭐⭐ |

**推荐：A 方案起步**，与 3.1 的工具栏协同，一次性补齐 `B/I/列表/任务` 全套。

### 6.3 A 方案细节

- **工具栏**：任务按钮插入 `- [ ] `，选中多行则逐行前缀。
- **编辑辅助**：回车检测上一行是否为 `- [ ] / - [x]`，自动续 `- [ ] `；空任务行回车则退出列表（同 Typora/Joplin）。
- **预览交互**：`MarkdownBody` 的 `checkboxBuilder` 自定义可点 `Checkbox`，点击时反向修改 `description` 文本中对应行的 `[ ] ↔ [x]`，走 `TextEditingController` + `NoteEditHistory`，自动触发 `_onEdit:352` 与 `isNoteNewOrContentChanged:771` 保存。
- **统计**：卡片/预览底部 `已完成 x/y` 计数，内存正则 `RegExp(r'^- \[[ xX]\]', multiLine: true)` 扫描，无需新字段。

```dart
// 伪代码：切换第 i 行任务状态
String toggleTask(String text, int lineIndex) {
  final lines = text.split('\n');
  final line = lines[lineIndex];
  if (line.startsWith('- [ ] ')) lines[lineIndex] = line.replaceFirst('- [ ] ', '- [x] ');
  else if (RegExp(r'^- \[[xX]\] ').hasMatch(line)) lines[lineIndex] = line.replaceFirst(RegExp(r'^- \[[xX]\] '), '- [ ] ');
  return lines.join('\n');
}
```

### 6.4 B 方案（结构化）预留

```sql
CREATE TABLE checklist_items (
  _id         INTEGER PRIMARY KEY AUTOINCREMENT,
  uuid        TEXT NOT NULL UNIQUE,
  note_uuid   TEXT NOT NULL,
  text        TEXT NOT NULL,                 -- 加密
  checked     INTEGER NOT NULL DEFAULT 0,
  sort_order  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL,
  deleted     INTEGER NOT NULL DEFAULT 0,
  synced      INTEGER NOT NULL DEFAULT 0
);
```

- 适用场景：需独立 LWW（多设备同时勾选不同条目不互相覆盖全文）、拖拽重排、归档已完成。
- 代价：文本与结构双写一致性、`computeHash` 是否纳入 checklist 的取舍（建议纳入，否则同步无法感知变更）。

### 6.5 工作量与复杂度

| 项 | 估算 |
|---|------|
| A 方案：工具栏 + 回车续行 + 预览勾选 + 计数 | 3-4 人日 |
| B 方案增量：表 + 同步 + 拖拽 + 迁移 | +4-6 人日 |
| 测试（解析、切换、撤销、同步并发） | 0.5-1 人日 |
| **合计** | **A: 3-6 / B全量 7-12 人日** |
| **复杂度** | **低-中**（A 低，B 中高） |
| **风险** | 低-中；A 风险仅行号定位与中文输入法联动 |

---

## 七、5. 提醒 / 闹钟

### 7.1 现状

- 无提醒，审查 P2 `UIUX-REVIEW-HOME-NOTE-20260822.md:62`。E2EE 场景下提醒为差异化而非必需，但 Keep/Apple Notes 均有。
- 现有未用 `flutter_local_notifications` 等通知依赖，需新增。

### 7.2 方案

**存储**：`note_meta.payload.reminder` 轻量起步（单提醒场景 `feature-note-meta-design.md:91` 已预留），多提醒再升级独立表。

```json
// payload.reminder
{
  "reminder": {
    "at": 1755500000000,          // UTC ms，必选
    "repeat": "none|daily|weekly",// 可选，二期
    "snoozedUntil": null
  }
}
```

**调度**：

| 平台 | 机制 | 说明 |
|------|------|------|
| Android | `flutter_local_notifications` + `exactAlarm` | 需 `SCHEDULE_EXACT_ALARM` / `POST_NOTIFICATIONS` 权限，`permission_handler` 已有 |
| iOS | 同插件 + `Darwin` 通知 | 精确度受系统节流，需提示“可能延迟” |
| Windows/macOS/Linux | `flutter_local_notifications` 桌面实现 + `window_manager` | 桌面通知能力弱，二期再做或仅移动端 |
| 后台 | `workmanager` 可选 | 用于重复提醒的周期性调度，一期可不用，单次提醒用系统 alarm 足够 |

**加密**：`reminder.at` 为时间戳非敏感可明文，但为统一走 `payload` 加密，与 `tags` 同域，同步需解密后调度本地通知。

**同步**：`reminder` 随 `note_meta` 的 `updatedAt` LWW 同步；收到远端更新时重排本地通知（`cancel(old) → schedule(new)`）。注意时区：存储 UTC，展示按本地时区 `easy_localization` + `timeago` 已有。

**UI**：笔记页 AppBar 闹钟图标 → 日期时间选择器（`showDatePicker` + `showTimePicker`），预览/卡片显示 `⏰ 08-23 14:00`，侧栏可加“提醒”过滤。

### 7.3 工作量与复杂度

| 阶段 | 估算 |
|------|------|
| 模型与存储（payload 单提醒） | 1 人日 |
| 通知插件接入 + 权限 + 平台适配 | 2-3 人日 |
| 调度/取消/更新/时区/重复 | 2-3 人日 |
| UI（选择器、展示、过滤、管理页） | 1-2 人日 |
| 同步联动 + 多设备一致性 + 重启后重建 | 1-2 人日 |
| 测试（权限拒绝、精确闹钟、勿扰、重启、时区切换） | 1-2 人日 |
| **合计** | **8-14 人日** |
| **复杂度** | **中高** |
| **风险** | **中高**：系统权限、厂商定制 ROM 保活、精确闹钟被拒、桌面通知不一致 |

### 7.4 风险与取舍

- **精确性**：Android 12+ 精确闹钟需用户额外授权，iOS 本就不保证精确，需文案兜底。
- **隐私**：通知内容不应明文显示敏感笔记标题，默认显示“有笔记提醒”+ 点击才解锁（与 `local_auth`/`local_session_timeout` 联动）。
- **与 E2EE 正交**：提醒不触碰 `computeHash`/`toContentBytes`，但若后续要“在通知中显示笔记内容”则需权衡隐私。

---

## 八、横向对比与依赖

### 8.1 依赖图

```
Markdown 工具栏 (1) ──→ 清单 (4) 复用工具栏与预览交互
                    └─→ 附件 (2) 的 Markdown 图片语法 ![alt](attachment:<hash>)

note_meta.extra 透传 ──→ 文件夹 A 方案 + 提醒单值（零 schema）
         ↓ 升级
独立表 (attachments/notebooks/checklist_items/reminders) ──→ 同步 per-entity LWW + GC
```

### 8.2 对现有链路的侵入度

| 功能 | 改 `SafeNote` | 改 `safe_notes` 表 | 改 `note_meta` | 新表 | 动 `computeHash` | 动同步 blob | 动 `reEncrypt` | 新增 Flutter 依赖 |
|------|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| 1 工具栏 | 否 | 否 | 否 | 否 | 否 | 否 | 否 | 否 |
| 2 附件 | 否 | 否 | 否 | 是 | 否 | 是（新 blob） | 是 | `file_picker` 已有，+`mime` 可选 |
| 3 文件夹 A | 否 | 否 | extra | 否 | 否 | 否 | 否 | 否 |
| 3 文件夹 B | 否 | 否 | 关联 | 是 | 否 | 是 | 是 | 否 |
| 4 清单 A | 否 | 否 | 否 | 否 | 否 | 否 | 否 | 否 |
| 4 清单 B | 否 | 否 | 关联 | 是 | 是/否 | 是 | 是 | 否 |
| 5 提醒 | 否 | 否 | extra | 可选 | 否 | 否 | 是 | `flutter_local_notifications` 新增 |

### 8.3 测试策略（统一）

- `dart test packages/core/test`：迁移 v7→v8/v9、加解密往返、LWW 合并、墓碑 GC、重加密覆盖。
- `flutter test`：工具栏插入、清单行切换、附件选择、笔记本树操作。
- `flutter test integration_test/app_test.dart -d windows`：重大 UI 重构后。
- 多设备手工：A 附件上传 → B 同步可见；A 笔记本重命名 → B 不丢归属；A 勾选清单 → B 全文不被覆盖。

---

## 九、落地路线（分阶段）

**Phase 0（本周，P0）**：
- 1 Markdown 工具栏（2-3d）
- 4 清单 A（Markdown 任务列表，3-4d，与 1 同 PR 可复用）
- 交付：非技术用户可不手写语法完成基础排版与待办。

**Phase 1（2-3 周，P1）**：
- 3 文件夹 A（payload 单层，2-3d）→ 验证后再定是否升级 B
- 2 附件 MVP（单文件、图片优先、限 10MB、无分片，8-10d 精简版）
- 交付：层级组织 + 基础附件闭环。

**Phase 2（1-2 月，P1/P2 增强）**：
- 2 附件完整（多文件、缩略图、GC、重加密、二阶段候选）
- 3 文件夹 B（树形 + 拖拽 + per-notebook 同步）
- 4 清单 B（若 A 的全文 LWW 在多设备勾选中出现丢失，再升级结构化）
- 5 提醒 MVP（单次、移动端）

---

## 十、风险总表

| 风险 | 影响功能 | 缓解 |
|------|---------|------|
| `core` 误引 Flutter | 2,3,4,5 | 模型与加密限 `packages/core`，`dart test` 卡口 + `dependency_validator` |
| `computeHash` 被误改 | 2,4B | CR 红线 + `blob_addressing_test.dart` 锁定不变量 |
| 附件 GC 误删 | 2 | 复用 `gc_orphan_candidates` 两阶段，隔离期 30 天 `sync_models.dart:118` |
| 密钥迁移漏表 | 2,3,5 | `reEncryptAllNotes` 同事务覆盖 `attachments.meta`/`notebooks.name`/`reminders`，与 `note_meta.payload:1604` 同模式 |
| 大文件 OOM / 超时 | 2 | 限大小、分片、流式 seal、后台 isolate（参考 `crypto.dart:232` 的 isolate 模式） |
| 通知权限被拒 | 5 | 降级为应用内横幅 + 引导授权，文案不承诺精确 |
| 双端导航不一致 | 3 | Rail 与 Drawer 同改，集成测覆盖 |

---

## 十一、结论

- **必做且最划算**：1 Markdown 工具栏与 4 清单 A，零模型零同步，2-6 人日内显著拉齐与 Joplin/Standard Notes 的基础体验，且为附件的图片 Markdown 语法铺路。
- **次优**：3 文件夹 A（payload）先行验证，再决定是否 B 树形；附件与提醒属重资产，需独立里程碑与多设备长测。
- **不建议并行**：附件与文件夹的同步改造均涉及新实体 LWW，二者并行易冲突，建议串行（先文件夹 A，再附件）。

> 本评估基于 `safenotes_sync.db:521` 的 v7 基线与 `ManifestCrypto:837` 的 v5 容器；任一新增表均需 bump `_schemaVersion` 并在 `_createDBStatic`/`_createDB`/`_onUpgrade` 三路径幂等建表，复用 `note_meta`/`note_versions` 的 `CREATE TABLE IF NOT EXISTS` 范式。

