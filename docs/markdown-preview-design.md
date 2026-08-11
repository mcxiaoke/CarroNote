# 笔记 Markdown 渲染与编辑/预览切换 设计文档

- 状态：实施中
- 日期：2026-08-11
- 涉及文件：`pubspec.yaml`、`lib/views/add_edit_note.dart`、`lib/views/note_view.dart`
- 后续（本文档范围外）：`lib/widgets/note_card.dart` 列表摘要的标记处理

## 1. 目标

让加密笔记支持轻量 Markdown 标记（加粗、斜体、标题、列表、链接等），并且**在编辑页内用按钮切换「编辑 / 预览」**，而不再依赖独立的详情页才能看到排版效果。

## 2. 依赖包选择

- 选用 **`flutter_markdown_plus`**（最新 `^1.0.12`，Foresight Mobile 维护）。
- 理由：它是 Google 已停更的 `flutter_markdown` 的**官方接手维护版**，活跃维护、定期发补丁；API 与原包基本一致，迁移成本为零。
- 默认语法：GitHub Flavored Markdown（GFM），天然支持加粗/斜体/删除线/标题/列表/表格/任务列表/代码块/链接/脚注/emoji，覆盖本需求的「简单标记」。
- 明确**不支持内联 HTML** → 不存在 HTML/脚本注入风险，对隐私笔记 App 是关键安全点。
- 导入：`import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';`
- 三个 Widget：
  - `Markdown`：独立可滚动视图（自带 padding/scroll）——本次不用。
  - `MarkdownBody`：嵌入自有布局、自适应内容、**默认 `shrinkWrap: true`**——预览用这个。
  - `MarkdownRaw`：无 Material 主题——不用。

## 3. 存储方案（零迁移）

- `SafeNote.description`（在 `core` 包）继续是 **String**。
- Markdown 本身就是纯文本，因此**直接把 Markdown 文本存进 `description` 即可**：加密、数据库、同步、备份、导出全部无需改动。
- 老笔记（无标记）原样显示，天然兼容，无需数据迁移。
- 标题 `title` **保持纯文本**（在列表卡片、搜索里使用，避免 Markdown 标记露馅）。

## 4. 编辑器预览切换（`add_edit_note.dart`）

改动集中在 `AddEditNotePageState`，不新建页面：

1. 新增状态 `bool _previewMode = false;`
2. AppBar `actions` 增加切换按钮 `_previewToggle()`（图标在 `visibility_outlined` / `edit_outlined` 间切换，tooltip 为 Preview/Edit）。
3. `build()` 的 body 改为互斥子树：
   - `_previewMode == false`：保留原 `SingleChildScrollView(reverse:true)` + `NoteFormWidget`（编辑）。
   - `_previewMode == true`：渲染 `_buildPreview()`。
4. `_buildPreview()` 用 `MarkdownBody` 渲染当前内存里的 `description`（编辑时已通过 `onChanged` 同步到页面 `title`/`description`，新建笔记也能预览，不依赖数据库）。

> 关于 `TextFormField` 的 `initialValue` 重建：切换到预览时整个 `NoteFormWidget` 被移出 widget 树，切回编辑时它重新创建并用最新的 `title`/`description` 初始化，因此已输入内容不会丢失。（如需更稳妥，后续可改为 `TextEditingController`，本次不必须。）

## 5. 详情页渲染（`note_view.dart`）

将 `note.description` 的 `SelectableText` 替换为 `MarkdownBody`（与编辑器预览同款参数），使从列表点进的详情页也能看到排版。标题仍用 `SelectableText` 纯文本，日期行保留。

## 6. 安全要点（隐私笔记 App 关键）

- **图片**：`imageBuilder: (uri, title, alt) => const SizedBox.shrink()` —— 不加载任何网络/本地图片，避免泄露 IP / 元数据。
- **链接**：`onTapLink` 由用户**主动点击**后才打开（`launchUrlExternal`，外部浏览器）；不做自动加载。内联 HTML 本身不被渲染，安全。
- **零明文外发**：渲染只发生在本地，Markdown 文本始终处于加密存储链路内。

## 7. 验证方式

1. `flutter pub get`
2. `flutter analyze`（修复所有 Error；Warning 酌情处理）
3. 项目无 markdown 相关单测，跳过测试并注明。
4. 手动验证：新建/编辑笔记输入 `# 标题`、`**加粗**`、`*斜体*`、`[链接](https://flutter.dev)`，确认预览与详情页排版正确、切换不丢内容、链接点击打开、图片不加载。

## 8. 风险与回滚

- 风险极低：仅新增 1 个依赖 + 2 个文件局部改动，存储/模型/数据库不变。
- 回滚：原文件已备份至 `temp/backups/<时间戳>/`；如需撤销，`flutter pub get` 后还原备份文件、移除 `pubspec.yaml` 依赖行即可。
- 已知后续项：列表卡片 `note_card.dart` 的描述摘要需决定「剥除标记 / 渲染 Markdown」，避免 `#`、`**` 直接出现在卡片上；本文档暂不处理。
