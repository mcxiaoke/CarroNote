# 笔记历史版本（note_versions）功能设计

> 状态：设计草案（待实现）
> 日期：2026-08-21
> 前置依赖：note_meta 表（v6 schema）、字段级加密（dataKey + AAD=uuid）
> 首期功能：本地笔记编辑历史的自动捕获、diff 预览与一键恢复
> 不含：版本跨设备同步（本地功能，不参与 sync manifest）

## 0. 方案概要与关键决策

### 0.1 目标

用户在编辑笔记时，系统自动保存内容的历史版本。用户可从编辑页 AppBar 菜单进入全屏历史版本页面，通过下拉框选择版本，查看与当前内容的 diff 对比，并一键恢复到选定版本。

### 0.2 关键决策

| 决策点 | 选择 | 理由 |
|--------|------|------|
| 存储方式 | 新建 `note_versions` 表，字段级加密 | 与 notes 表策略一致，复用 `_encryptField`/`_decryptField`，uuid 作 AAD |
| 是否同步 | **不同步**，纯本地表 | 版本历史是设备级功能；同步会带来版本冲突、manifest 膨胀等不必要的复杂度 |
| 版本上限 | 50 条/笔记，FIFO 清理 | 覆盖数月编辑历史，磁盘开销可控（见 §8.5） |
| 去重策略 | contentHash 比对最新版本 | 复用 `SafeNote.computeHash`，无修改的保存不产生重复版本 |
| Diff 算法 | `diff_match_patch`（Google 库 Dart 移植） | 业界标准，支持字符级 + 语义清理，纯 Dart 无原生依赖 |
| Diff 方向 | `diff(current, selectedVersion)` | 展示"恢复后会发生什么变化"，对恢复操作最直观 |
| Diff 渲染 | 纯文本 RichText，不渲染 Markdown | Markdown 渲染会破坏 diff 高亮；用户可在编辑页预览模式看渲染效果 |
| 捕获时机 | 覆盖前保存旧内容（editor + sync 两个路径） | 确保被覆盖的内容不会丢失 |
| Schema 升级 | v6 → v7，`CREATE TABLE IF NOT EXISTS` | 与 v5→v6（note_meta 表）同样零风险，不动 notes 表 |

### 0.3 不做的事

- **不做版本同步**：版本表不进入 sync manifest，不上传 blob，不参与远端合并
- **不做版本备份**：加密备份（export）只包含当前笔记内容，不含版本历史
- **不做富文本 diff**：description 是纯文本，diff 也按纯文本处理
- **不做版本编辑**：版本内容只读，不能在历史版本页直接编辑
- **不做版本分支/合并**：不是 Git，不支持从某个版本分叉出多条编辑线

## 1. 架构总览

```
┌──────────────────────────────────────────────────────┐
│ UI 层  lib/views/                                     │
│                                                       │
│  编辑页 AppBar                                         │
│    └─ 更多菜单 (note_actions_sheet)                    │
│         └─ 「历史版本」菜单项（新增）                    │
│              └─ Navigator.push → VersionHistoryPage   │
│                   ├─ 顶部：版本选择下拉框               │
│                   ├─ 中间：Diff 渲染区域（可滚动）       │
│                   └─ 底部：恢复到此版本按钮             │
└───────────────────────┬──────────────────────────────┘
                        │ 调用
                        ▼
┌──────────────────────────────────────────────────────┐
│ 数据层  packages/core/lib/src/db/                     │
│                                                       │
│  NotesDatabase                                        │
│    ├─ saveVersion(note)      ← 覆盖前保存旧内容快照     │
│    ├─ readVersions(uuid)     ← 读取版本列表（解密）     │
│    ├─ readVersion(id)        ← 读取单个版本（解密）     │
│    ├─ restoreVersion(id)     ← 恢复版本内容到笔记       │
│    ├─ pruneVersions(uuid)    ← 超限清理最旧版本         │
│    └─ deleteVersionsForNote(uuid) ← 笔记硬删除时清理   │
│                                                       │
│  SQLite                                               │
│    notes 表          ← 零改动                          │
│    note_versions 表  ← 新建（schema v7）               │
└───────────────────────┬──────────────────────────────┘
                        │ 加密
                        ▼
┌──────────────────────────────────────────────────────┐
│ 加密层  复用现有 _encryptField / _decryptField          │
│  AES-256-GCM(dataKey, AAD=note_uuid)                  │
│  与 notes 表 title/description 加密完全一致             │
└──────────────────────────────────────────────────────┘
```

### 数据流

```
版本捕获：
  用户编辑保存 → editor_state.updateNote() → saveVersion(original) → updateNote(new)
  同步下载覆盖 → sync_engine._downloadNote() → saveVersion(existing) → updateNoteByUuid(new)

版本查看：
  VersionHistoryPage → readVersions(uuid) → 下拉框渲染
  用户选择版本 → readVersion(id) → diff(current, version) → RichText 渲染

版本恢复：
  用户点击恢复 → restoreVersion(id) → saveVersion(current) → updateNote(version_content) → autoSync()
```

## 2. 数据模型

### 2.1 NoteVersion 模型

**文件**：`packages/core/lib/src/models/note_version.dart`（新增）

```dart
const String tableNoteVersions = 'note_versions';

class NoteVersionFields {
  static const String id = '_id';
  static const String noteUuid = 'note_uuid';
  static const String title = 'title';           // 密文存储
  static const String description = 'description'; // 密文存储
  static const String contentHash = 'content_hash'; // 明文，用于去重
  static const String savedAt = 'saved_at';       // Unix 毫秒

  static final List<String> values = [id, noteUuid, title, description, contentHash, savedAt];
}

class NoteVersion {
  final int? id;
  final String noteUuid;
  final String title;        // 内存中为明文
  final String description;  // 内存中为明文
  final String contentHash;
  final int savedAt;         // Unix 毫秒

  const NoteVersion({
    this.id,
    required this.noteUuid,
    required this.title,
    required this.description,
    required this.contentHash,
    required this.savedAt,
  });

  DateTime get savedTime =>
      DateTime.fromMillisecondsSinceEpoch(savedAt);

  NoteVersion copyWith({...});
  Map<String, dynamic> toJson() => {...};
  factory NoteVersion.fromJson(Map<String, dynamic> json) => ...;
}
```

**设计要点**：

- `noteUuid` 是逻辑外键，不设 SQL 外键约束（与 note_meta 表策略一致——墓碑硬删除后版本仍可存活，由应用层清理）
- `contentHash` 明文存储，与 notes 表的 `content_hash` 同性质（仅用于比对，不含敏感信息）
- `title`/`description` 加密存储，复用 notes 表的 `_encryptField(uuid, plaintext)` / `_decryptField(uuid, ciphertext)`，AAD = `note_uuid`
- 不存 `deleted` 字段：版本不可单独删除（只有 FIFO 清理和笔记硬删除时批量清理）
- 不存 `synced` 字段：版本不同步

### 2.2 note_versions 表

**建表语句**：

```sql
CREATE TABLE IF NOT EXISTS note_versions (
  _id          INTEGER PRIMARY KEY AUTOINCREMENT,
  note_uuid    TEXT    NOT NULL,
  title        TEXT    NOT NULL,           -- AES-256-GCM 密文
  description  TEXT    NOT NULL,           -- AES-256-GCM 密文
  content_hash TEXT    NOT NULL,           -- 明文 SHA-256
  saved_at     INTEGER NOT NULL            -- Unix 毫秒
);

CREATE INDEX IF NOT EXISTS idx_versions_uuid
  ON note_versions(note_uuid);
CREATE INDEX IF NOT EXISTS idx_versions_uuid_time
  ON note_versions(note_uuid, saved_at DESC);
```

**索引说明**：

| 索引 | 消费场景 |
|------|----------|
| `idx_versions_uuid` | `deleteVersionsForNote(uuid)` 按 uuid 批量删除 |
| `idx_versions_uuid_time` | `readVersions(uuid)` 按 saved_at DESC 查询 + `saveVersion` 去重查最新版本 |

### 2.3 Schema 升级（v6 → v7）

**文件**：`packages/core/lib/src/db/database_handler.dart`

```dart
static const int _schemaVersion = 7;  // v6 → v7

Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
  // ... 现有 v2→v3→v4→v5→v6 迁移 ...

  if (oldVersion < 7) {
    await _createNoteVersionsTable(db);
    Log.db.i('已创建 note_versions 表 (schema v7)');
  }
}

Future<void> _createNoteVersionsTable(Database db) async {
  await db.execute('''
  CREATE TABLE IF NOT EXISTS $tableNoteVersions (
    ${NoteVersionFields.id} INTEGER PRIMARY KEY AUTOINCREMENT,
    ${NoteVersionFields.noteUuid} TEXT NOT NULL,
    ${NoteVersionFields.title} TEXT NOT NULL,
    ${NoteVersionFields.description} TEXT NOT NULL,
    ${NoteVersionFields.contentHash} TEXT NOT NULL,
    ${NoteVersionFields.savedAt} INTEGER NOT NULL
  )
  ''');
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_versions_uuid '
    'ON $tableNoteVersions(${NoteVersionFields.noteUuid})',
  );
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_versions_uuid_time '
    'ON $tableNoteVersions(${NoteVersionFields.noteUuid}, ${NoteVersionFields.savedAt} DESC)',
  );
}
```

**升级风险**：零。`CREATE TABLE IF NOT EXISTS` 幂等，不动 notes 表和 note_meta 表，老库无感知升级。

## 3. 版本捕获策略

### 3.1 捕获时机：两个路径

版本捕获的核心原则：**在旧内容被覆盖之前，保存其快照**。

#### 路径 1：用户编辑保存

**文件**：`lib/models/editor_state.dart`，`updateNote()` 方法（当前第 112-126 行）

```dart
Future updateNote() async {
  Log.note.i('保存编辑后的笔记: uuid=${original!.uuid} ...');

  // ✦ 新增：覆盖前保存旧版本
  await NotesDatabase.instance.saveVersion(original!);

  final now = DateTime.now();
  final note = original!.copyWith(
    title: title,
    description: description,
    contentHash: SafeNote.computeHash(title, description),
    updatedAt: now.millisecondsSinceEpoch,
    synced: false,
  );
  await NotesDatabase.instance.updateNote(note);
}
```

**为什么在 `updateNote()` 而非 `addOrUpdateNote()` 中捕获**：

`addOrUpdateNote()` 第 80-81 行已有内容变化检查（`original!.title != title || original!.description != description`），只有内容真正变化时才调用 `updateNote()`。因此 `updateNote()` 一定是"内容即将被覆盖"的时刻，在这里捕获语义最精确。

`original` 是编辑前的笔记快照（在页面 `initState` 时通过 `NoteEditorState.setState()` 设置），正是需要保存的旧版本。

#### 路径 2：同步下载覆盖

**文件**：`packages/core/lib/src/sync/sync_engine.dart`，`_downloadNote()` 方法（当前第 2181-2198 行）

```dart
// 在 _downloadNote() 中，existing 已被读取（第 2181 行）
final existing = await database.readNoteByUuid(uuid);

// ✦ 新增：同步覆盖前保存旧版本（仅当本地已有内容且内容不同时）
if (existing != null && !existing.deleted &&
    existing.contentHash != item.hash) {
  await database.saveVersion(existing);
}

final note = SafeNote(...);
if (existing == null) {
  await database.storeNote(note);
} else {
  await database.updateNoteByUuid(note);
}
```

**条件说明**：

- `existing != null`：本地已有此笔记（新建笔记无需保存版本）
- `!existing.deleted`：本地笔记不是墓碑（墓碑被覆盖不产生有意义的版本）
- `existing.contentHash != item.hash`：内容确实不同（hash 相同说明是 fast-forward，无需保存版本）

#### 不捕获的场景

| 场景 | 不捕获原因 |
|------|------------|
| 新建笔记（`storeNote`） | 没有旧内容可保存 |
| 内容未变化（`addOrUpdateNote` 第 84 行跳过） | 无内容被覆盖 |
| 同步下载墓碑（`item.deleted == true`） | 删除不是内容变更 |
| 同步 fast-forward（hash 相同） | 内容未变化 |
| 同步冲突副本（`_preserveConflictCopy`） | 新 uuid 产生新笔记，无旧版本 |
| `reEncryptAllNotes` 密钥迁移 | 加密层变更，内容不变，不应产生版本 |

### 3.2 contentHash 去重

在 `saveVersion` 内部，比对新版本的 contentHash 与该笔记最新版本的 contentHash，相同则跳过：

```dart
static const int kMaxVersionsPerNote = 50;

Future<void> saveVersion(SafeNote note) async {
  _checkNotMigrating();
  final db = await database;

  // 去重：查最新版本的 content_hash
  final latest = await db.rawQuery(
    'SELECT ${NoteVersionFields.contentHash} FROM $tableNoteVersions '
    'WHERE ${NoteVersionFields.noteUuid} = ? '
    'ORDER BY ${NoteVersionFields.savedAt} DESC LIMIT 1',
    [note.uuid],
  );
  if (latest.isNotEmpty &&
      latest.first[NoteVersionFields.contentHash] == note.contentHash) {
    Log.note.d('版本内容与最新版本相同, 跳过 uuid=${note.uuid}');
    return;
  }

  // 加密 + 插入
  final row = <String, dynamic>{
    NoteVersionFields.noteUuid: note.uuid,
    NoteVersionFields.title: await _encryptField(note.uuid, note.title),
    NoteVersionFields.description: await _encryptField(note.uuid, note.description),
    NoteVersionFields.contentHash: note.contentHash,
    NoteVersionFields.savedAt: DateTime.now().millisecondsSinceEpoch,
  };
  await db.insert(tableNoteVersions, row);

  Log.note.i(
    '保存版本快照 uuid=${note.uuid} '
    'hash=${_hashBrief(note.contentHash)} '
    'len=${note.title.length}+${note.description.length}',
  );

  // 超限清理
  await _pruneVersions(note.uuid);
}
```

**去重的必要性**：

虽然 `editor_state.dart` 已检查内容变化，但同步路径可能下载到与本地某个旧版本内容相同的笔记（例如：设备 A 编辑 → 设备 B 同步收到 → 设备 A 撤销编辑 → 设备 B 再次同步收到"新"内容恰好等于 B 的某个旧版本）。去重确保这种情况不产生冗余版本。

### 3.3 数量上限与 FIFO 清理

```dart
Future<void> _pruneVersions(String uuid) async {
  final db = await database;
  final count = Sqflite.firstIntValue(await db.rawQuery(
    'SELECT COUNT(*) FROM $tableNoteVersions '
    'WHERE ${NoteVersionFields.noteUuid} = ?',
    [uuid],
  )) ?? 0;

  if (count <= kMaxVersionsPerNote) return;

  final excess = count - kMaxVersionsPerNote;
  await db.rawDelete(
    'DELETE FROM $tableNoteVersions WHERE _id IN ('
    '  SELECT _id FROM $tableNoteVersions '
    '  WHERE ${NoteVersionFields.noteUuid} = ? '
    '  ORDER BY ${NoteVersionFields.savedAt} ASC LIMIT ?'
    ')',
    [uuid, excess],
  );
  Log.note.d('清理旧版本 uuid=$uuid 删除=$excess条 保留=${count - excess}条');
}
```

**为什么 50 条**：

- 文本笔记加密后通常每条 1-20KB，50 条 ≈ 0.05-1MB/笔记，磁盘开销可控
- 假设用户每天编辑同一笔记 5 次，50 条可覆盖 10 天的编辑历史
- 未来可在设置中提供"版本数量上限"配置项（默认 50，可选 10/25/50/100）

**不保留"初始版本"的特殊策略**：

笔记应用用户最关心的是最近能回退到什么状态，而非很久以前的初始版本。FIFO 足够。如果未来需要，可升级为"保留首尾 + 等间隔采样"策略，但当前不做过早优化。

### 3.4 自动保存与版本创建

`handleUngracefulNoteExit()`（会话超时自动保存）调用 `addOrUpdateNote()` → `updateNote()`，因此自动保存也会触发版本捕获。

这是正确行为：自动保存产生的编辑也是合法的内容变更，应该有版本记录。contentHash 去重确保"打开笔记→不改→超时自动保存"不会产生无意义的版本。

### 3.5 事务安全

`saveVersion` 和 `updateNote` 是两次独立的数据库操作，不是原子事务。如果 `saveVersion` 成功但 `updateNote` 失败，会留下一个"多出的版本"。

**影响评估**：多出的版本不影响数据正确性——它只是记录了一个"曾经存在但未被覆盖"的内容状态。用户在版本列表中看到它不会困惑，因为它确实是一个历史内容。

**不使用事务的理由**：

1. 现有 `storeNote` 和 `updateNote` 也不在事务中（只有 `storeNotesInTransaction` 批量导入用事务）
2. `saveVersion` 内部有加密操作（`_encryptField` 是 `async`），sqflite 事务中混用 async 加密可能导致死锁
3. 多出一个版本的风险极低且无害，不值得引入事务复杂度

## 4. Diff 算法选型

### 4.1 库选择：diff_match_patch

**pubspec.yaml 新增依赖**：

```yaml
dependencies:
  diff_match_patch: ^0.4.1
```

**选型理由**：

| 候选 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| `diff_match_patch` | Google 官方库 Dart 移植，业界标准，支持字符级 diff + 语义清理，纯 Dart 无原生依赖 | API 较底层，需自行渲染 | **选用** |
| `pretty_diff_text` | 封装更友好，自带 widget | 维护不活跃，依赖 diff_match_patch | 不选 |
| 自行实现 Myers diff | 无外部依赖 | 重复造轮子，正确性难保证 | 不选 |

### 4.2 Diff 计算

**文件**：`lib/utils/note_diff.dart`（新增）

```dart
import 'package:diff_match_patch/diff_match_patch.dart';

/// Diff 片段类型
enum DiffSegmentType { equal, insertion, deletion }

/// Diff 片段
class DiffSegment {
  final DiffSegmentType type;
  final String text;
  const DiffSegment(this.type, this.text);
}

/// 计算两段文本的 diff
///
/// [base] 基准文本（当前内容）
/// [target] 目标文本（历史版本内容）
///
/// 返回 diff 片段列表：
/// - insertion（绿色）：target 有但 base 没有的内容 → 恢复后会获得
/// - deletion（红色）：base 有但 target 没有的内容 → 恢复后会丢失
/// - equal：两者相同的内容
List<DiffSegment> computeDiff(String base, String target) {
  final dmp = DiffMatchPatch();
  var diffs = dmp.diff(base, target);
  dmp.diffCleanupSemantic(diffs);  // 语义清理，使 diff 更人类友好

  return diffs.map((d) {
    switch (d.operation) {
      case DIFF_EQUAL:
        return DiffSegment(DiffSegmentType.equal, d.text);
      case DIFF_INSERT:
        return DiffSegment(DiffSegmentType.insertion, d.text);
      case DIFF_DELETE:
        return DiffSegment(DiffSegmentType.deletion, d.text);
      default:
        return DiffSegment(DiffSegmentType.equal, d.text);
    }
  }).toList();
}
```

### 4.3 Diff 方向

**方向**：`diff(current, selectedVersion)`

即 base = 当前内容，target = 选中的历史版本内容。

**语义**：

| 颜色 | diff_match_patch 操作 | 含义 | 用户理解 |
|------|----------------------|------|----------|
| 绿色（insertion） | DIFF_INSERT | 历史版本有、当前没有 | "恢复后会获得这段内容" |
| 红色（deletion） | DIFF_DELETE | 当前有、历史版本没有 | "恢复后会丢失这段内容" |
| 默认（equal） | DIFF_EQUAL | 两者相同 | "不受影响" |

**为什么选这个方向**：

用户在历史版本页的意图是"恢复到这个版本"。`diff(current, version)` 展示的是"恢复后会发生什么变化"，对恢复操作最直观。如果反过来 `diff(version, current)`，则展示的是"从版本到现在发生了什么变化"，这更适合"查看编辑历史"而非"预览恢复效果"。

### 4.4 标题与正文分别 Diff

标题和正文是独立字段，分别 diff：

```dart
class NoteDiffResult {
  final List<DiffSegment> titleDiff;
  final List<DiffSegment> descriptionDiff;
  final bool hasDifference;

  NoteDiffResult({
    required this.titleDiff,
    required this.descriptionDiff,
    required this.hasDifference,
  });
}

NoteDiffResult computeNoteDiff(SafeNote current, NoteVersion version) {
  final titleDiff = computeDiff(current.title, version.title);
  final descDiff = computeDiff(current.description, version.description);
  final hasDiff = titleDiff.any((s) => s.type != DiffSegmentType.equal) ||
      descDiff.any((s) => s.type != DiffSegmentType.equal);
  return NoteDiffResult(
    titleDiff: titleDiff,
    descriptionDiff: descDiff,
    hasDifference: hasDiff,
  );
}
```

### 4.5 性能考量

| 内容大小 | 策略 | 预期耗时 |
|----------|------|----------|
| < 10KB（绝大多数笔记） | 直接字符级 diff | < 10ms |
| 10KB - 50KB | 字符级 diff + `diffCleanupSemantic` | 10-50ms |
| > 50KB | 在 isolate 中计算（`compute()`） | 50-200ms |

**阈值处理**：

```dart
Future<NoteDiffResult> computeNoteDiffAsync(
  SafeNote current,
  NoteVersion version,
) async {
  final totalSize = current.title.length + current.description.length +
      version.title.length + version.description.length;

  if (totalSize > 50000) {
    // 大文本：在 isolate 中计算，避免阻塞 UI
    return compute(_computeNoteDiffIsolate, _DiffInput(current, version));
  }
  // 普通文本：直接计算
  return computeNoteDiff(current, version);
}
```

**`diffCleanupSemantic` 的作用**：

原始 diff 可能在词中间断开（如 "hello" → "help" 会产生 "hel" equal + "lo" delete + "p" insert）。`diffCleanupSemantic` 会将断点移动到词边界/标点/空白处，使 diff 更符合人类直觉。

### 4.6 Diff 不渲染 Markdown

description 可能包含 Markdown 语法，但 diff 视图按纯文本渲染，不解析 Markdown。

**理由**：

1. Markdown 渲染（`MarkdownBody`）会把文本转换为结构化 widget，无法在渲染后的内容上叠加 diff 高亮
2. Diff 的目的是展示文本差异，而非内容预览——用户需要看到原始文本的增删
3. 用户可在编辑页的预览模式查看 Markdown 渲染效果

## 5. UI 设计

### 5.1 入口：note_actions_sheet 新增菜单项

**文件**：`lib/widgets/note_actions_sheet.dart`

在 `NoteAction` enum 新增 `versionHistory`：

```dart
enum NoteAction {
  copyAll,
  toggleStar,
  toggleLock,
  editTags,
  versionHistory,  // ✦ 新增
  delete,
}
```

在 sheet 中新增菜单项（插入在 editTags 和 delete 之间）：

```dart
shadActionTile(
  context,
  key: const Key('ui-note-action-history'),
  icon: LucideIcons.history,
  title: 'Version History'.tr(),
  onTap: () => Navigator.of(context).pop(NoteAction.versionHistory),
),
```

**文件**：`lib/views/add_edit_note.dart`，`_moreButton()` 的 switch（当前第 274-285 行）

新增 case：

```dart
case NoteAction.versionHistory:
  await _openVersionHistory(note);
```

```dart
Future<void> _openVersionHistory(SafeNote note) async {
  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => VersionHistoryPage(note: note),
    ),
  );
  // 返回后刷新编辑页状态（恢复操作可能改变了笔记内容）
  if (mounted) {
    // 重新从数据库加载笔记
    final updated = await NotesDatabase.instance.readNoteByUuid(note.uuid);
    if (updated != null && mounted) {
      NoteEditorState.setState(updated, updated.title, updated.description);
      setState(() {});
    }
  }
}
```

**为什么用 `Navigator.push` 而非命名路由**：

与 `pushTagEditor` 模式一致——需要传递 `SafeNote` 参数，直接 push 比 named route + arguments 更简洁。版本历史页不需要 deep link，不进 RouteGenerator。

**入口位置**：放在 "Edit Tags" 和 "Delete" 之间，因为版本历史属于笔记的"管理"类操作，与标签、锁定同类；放在删除前避免用户误触删除。

### 5.2 全屏页面布局

**文件**：`lib/views/version_history_page.dart`（新增）

```
┌─────────────────────────────────────────┐
│  ←  历史版本                        AppBar │
├─────────────────────────────────────────┤
│                                         │
│  ┌─────────────────────────────────┐    │
│  │  版本 3 · 2026-08-21 14:30  ▼  │    │  ← 下拉框
│  └─────────────────────────────────┘    │
│                                         │
├─────────────────────────────────────────┤
│                                         │
│  标题                                    │
│  ┌─────────────────────────────────┐    │
│  │ Meeting Notes                    │    │  ← 标题 diff
│  │ Meeting Notes~~Draft~~           │    │     (inline 字符级高亮)
│  └─────────────────────────────────┘    │
│                                         │
│  正文                                    │
│  ┌─────────────────────────────────┐    │
│  │  - Line removed (red bg)        │    │  ← 正文 diff
│  │  + Line added (green bg)        │    │     (行级 + 行内字符高亮)
│  │   Unchanged line                │    │
│  └─────────────────────────────────┘    │
│                                         │
│         (可滚动区域)                      │
│                                         │
├─────────────────────────────────────────┤
│       [ 恢复到此版本 ]                    │  ← 底部按钮
└─────────────────────────────────────────┘
```

**页面结构**：

```dart
class VersionHistoryPage extends StatefulWidget {
  final SafeNote note;
  const VersionHistoryPage({super.key, required this.note});
  // ...
}

class _VersionHistoryPageState extends State<VersionHistoryPage> {
  List<NoteVersion>? _versions;
  int _selectedIndex = 0;
  NoteDiffResult? _diffResult;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadVersions();
  }

  Future<void> _loadVersions() async {
    final versions = await NotesDatabase.instance.readVersions(widget.note.uuid);
    if (!mounted) return;
    setState(() {
      _versions = versions;
      _selectedIndex = 0;
    });
    if (versions.isNotEmpty) {
      await _updateDiff();
    }
  }

  Future<void> _updateDiff() async {
    if (_versions == null || _versions!.isEmpty) return;
    setState(() => _isLoading = true);

    final current = await NotesDatabase.instance.readNoteByUuid(widget.note.uuid);
    if (current == null || !mounted) return;

    final version = _versions![_selectedIndex];
    final diff = await computeNoteDiffAsync(current, version);

    if (!mounted) return;
    setState(() {
      _diffResult = diff;
      _isLoading = false;
    });
  }

  Future<void> _onVersionChanged(int index) async {
    setState(() => _selectedIndex = index);
    await _updateDiff();
  }

  Future<void> _onRestore() async {
    // 见 §6 恢复流程
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Version History'.tr())),
      body: _buildBody(),
      bottomNavigationBar: _buildRestoreButton(),
    );
  }
}
```

### 5.3 版本选择下拉框

使用 `ShadSelect`（与项目 shadcn_ui 风格一致）或 Flutter 原生 `DropdownButton`。

**下拉项格式**：

```
版本 3 · 2026-08-21 14:30
版本 2 · 2026-08-20 09:15
版本 1 · 2026-08-19 18:42
```

- 版本编号从新到旧递减（版本 1 = 最新版本，版本 N = 最旧）
- 时间戳格式化用 `intl` 包的 `DateFormat`（与项目现有时间格式化一致）
- 下拉项数量受 FIFO 上限控制（最多 50 项），无需分页

```dart
Widget _buildVersionSelector() {
  if (_versions == null || _versions!.isEmpty) {
    return Text('No version history'.tr());
  }
  return ShadSelect<int>(
    initialValue: _selectedIndex,
    onChanged: (index) {
      if (index != null) _onVersionChanged(index);
    },
    options: _versions!.asMap().entries.map((entry) {
      final v = entry.value;
      return ShadOption(
        value: entry.key,
        child: Text('${'Version'.tr()} ${entry.key + 1} · ${_formatTime(v.savedAt)}'),
      );
    }).toList(),
    selectedOptionBuilder: (context, index) {
      final v = _versions![index];
      return Text('${'Version'.tr()} ${index + 1} · ${_formatTime(v.savedAt)}');
    },
  );
}

String _formatTime(int millis) {
  final dt = DateTime.fromMillisecondsSinceEpoch(millis);
  return DateFormat('yyyy-MM-dd HH:mm').format(dt);
}
```

### 5.4 Diff 渲染

使用 `RichText` + `TextSpan` 渲染 diff 高亮：

```dart
Widget _buildDiffContent() {
  final diff = _diffResult;
  if (diff == null) return const SizedBox.shrink();

  return SingleChildScrollView(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题 diff
          if (diff.titleDiff.any((s) => s.type != DiffSegmentType.equal)) ...[
            Text('Title'.tr(), style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 4),
            _buildDiffText(diff.titleDiff, isTitle: true),
            const SizedBox(height: 16),
          ],

          // 正文 diff
          Text('Content'.tr(), style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 4),
          _buildDiffText(diff.descriptionDiff, isTitle: false),
        ],
      ),
    ),
  );
}

Widget _buildDiffText(List<DiffSegment> segments, {required bool isTitle}) {
  return Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(8),
    ),
    child: RichText(
      text: TextSpan(
        style: isTitle ? EditorText.title() : EditorText.body(),
        children: segments.map((seg) {
          switch (seg.type) {
            case DiffSegmentType.insertion:
              return TextSpan(
                text: seg.text,
                style: TextStyle(
                  backgroundColor: Colors.green.withValues(alpha: 0.2),
                  color: Colors.green[800],
                ),
              );
            case DiffSegmentType.deletion:
              return TextSpan(
                text: seg.text,
                style: TextStyle(
                  backgroundColor: Colors.red.withValues(alpha: 0.2),
                  color: Colors.red[800],
                  decoration: TextDecoration.lineThrough,
                ),
              );
            case DiffSegmentType.equal:
              return TextSpan(text: seg.text);
          }
        }).toList(),
      ),
    ),
  );
}
```

### 5.5 空状态处理

**无版本时**（新建笔记或从未编辑过的笔记）：

```dart
Widget _buildEmptyState() {
  return Center(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(LucideIcons.history, size: 48,
            color: Theme.of(context).colorScheme.outline),
        const SizedBox(height: 16),
        Text('No version history yet'.tr()),
        const SizedBox(height: 8),
        Text(
          'Versions are saved automatically when you edit.'.tr(),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ),
  );
}
```

### 5.6 无差异状态

当选中的版本与当前内容完全相同时（contentHash 相同）：

```dart
Widget _buildNoDifference() {
  return Center(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(LucideIcons.check, size: 36,
            color: Colors.green),
        const SizedBox(height: 12),
        Text('No differences from current version'.tr()),
      ],
    ),
  );
}
```

**何时出现**：

理论上 contentHash 去重会阻止相同内容的版本被保存。但存在边缘情况：恢复操作先保存当前版本（可能恰好与某个已存在的版本内容相同），或同步下载的内容恰好与本地某版本相同但 contentHash 去重失败（数据库并发写入竞态）。因此需要处理此状态。

### 5.7 锁定笔记处理

笔记锁定（`NoteMeta.locked`）后，编辑页变为只读预览模式。版本历史页的处理：

- **可查看**：用户可以查看历史版本和 diff
- **不可恢复**：恢复按钮禁用或隐藏，显示提示"请先解锁笔记"

```dart
Widget _buildRestoreButton() {
  final isLocked = _locked;  // 从 note_meta 读取
  final hasDiff = _diffResult?.hasDifference ?? false;

  return SafeArea(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: ShadButton(
        enabled: !isLocked && hasDiff && _versions != null && _versions!.isNotEmpty,
        onPressed: _onRestore,
        child: Text(
          isLocked ? 'Unlock note to restore'.tr() : 'Restore to this version'.tr(),
        ),
      ),
    ),
  );
}
```

### 5.8 颜色无障碍

Diff 高亮不仅用颜色区分，还用文本样式区分：

| 类型 | 颜色 | 文本样式 | 辅助标识 |
|------|------|----------|----------|
| 新增（insertion） | 绿色背景 | 正常 | 前缀 `+`（在行级 diff 中） |
| 删除（deletion） | 红色背景 | 删除线 | 前缀 `-`（在行级 diff 中） |
| 相同（equal） | 默认 | 正常 | 无 |

对于色觉障碍用户，删除线 + 颜色双重标识确保可辨识。

### 5.9 国际化

所有 UI 字符串使用 `easy_localization` 的 `.tr()` 方法，翻译文件添加 `zh-CN` 和 `en-US`：

```json
// assets/translations/zh-CN.json
{
  "Version History": "历史版本",
  "Version": "版本",
  "No version history yet": "暂无历史版本",
  "Versions are saved automatically when you edit.": "编辑笔记时会自动保存版本。",
  "No differences from current version": "与当前版本无差异",
  "Restore to this version": "恢复到此版本",
  "Unlock note to restore": "解锁笔记后可恢复",
  "Restore successful": "恢复成功",
  "Title": "标题",
  "Content": "正文"
}
```

```json
// assets/translations/en-US.json
{
  "Version History": "Version History",
  "Version": "Version",
  "No version history yet": "No version history yet",
  "Versions are saved automatically when you edit.": "Versions are saved automatically when you edit.",
  "No differences from current version": "No differences from current version",
  "Restore to this version": "Restore to this version",
  "Unlock note to restore": "Unlock note to restore",
  "Restore successful": "Restore successful",
  "Title": "Title",
  "Content": "Content"
}
```

## 6. 恢复流程

### 6.1 恢复操作

```dart
Future<void> _onRestore() async {
  final version = _versions![_selectedIndex];
  final current = await NotesDatabase.instance.readNoteByUuid(widget.note.uuid);
  if (current == null || !mounted) return;

  // 确认对话框
  final confirmed = await _showRestoreConfirm(version);
  if (!confirmed || !mounted) return;

  // 执行恢复
  await NotesDatabase.instance.restoreVersion(version.id!, current);

  if (!mounted) return;
  showSnackBarMessage(context, 'Restore successful'.tr());

  // 触发自动同步
  SyncService.instance.autoSync();

  // 返回编辑页
  Navigator.of(context).pop();
}
```

### 6.2 restoreVersion 实现

**文件**：`packages/core/lib/src/db/database_handler.dart`

```dart
/// 恢复指定版本的内容到笔记
///
/// 恢复前会先保存当前笔记内容作为新版本（确保可撤销恢复）。
/// 恢复后笔记标记为未同步（synced=false），触发 autoSync 上传。
Future<void> restoreVersion(int versionId, SafeNote current) async {
  _checkNotMigrating();
  final db = await database;

  // 1. 读取版本内容（解密）
  final version = await _readVersionRow(db, versionId);
  if (version == null) {
    throw Exception('Version not found: $versionId');
  }

  // 2. 保存当前内容为新版本（撤销安全网）
  await saveVersion(current);

  // 3. 将版本内容写回笔记（作为新编辑）
  final restored = current.copyWith(
    title: version.title,
    description: version.description,
    contentHash: version.contentHash,
    updatedAt: DateTime.now().millisecondsSinceEpoch,
    synced: false,
  );
  await updateNote(restored);

  Log.note.i(
    '恢复版本: note_uuid=${current.uuid} version_id=$versionId '
    'hash=${_hashBrief(version.contentHash)}',
  );
}
```

### 6.3 恢复确认对话框

```dart
Future<bool> _showRestoreConfirm(NoteVersion version) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => ShadDialog(
      title: Text('Restore to this version'.tr()),
      description: Text(
        'Current content will be replaced. A version of the current '
        'content will be saved automatically.'.tr(),
      ),
      actions: [
        ShadButton.outline(
          child: Text('Cancel'.tr()),
          onPressed: () => Navigator.of(context).pop(false),
        ),
        ShadButton(
          child: Text('Restore'.tr()),
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    ),
  );
  return result ?? false;
}
```

### 6.4 恢复后的编辑页刷新

恢复操作改变了笔记内容，返回编辑页后需要刷新：

1. `VersionHistoryPage` pop 返回 `AddEditNotePage`
2. `_openVersionHistory` 的 `await Navigator.push` 返回后，重新从数据库读取笔记
3. 更新 `NoteEditorState` 和编辑页 UI

（具体代码见 §5.1 的 `_openVersionHistory`）

## 7. 与同步引擎的关系

### 7.1 交互矩阵

| 同步场景 | 版本表行为 | 说明 |
|----------|------------|------|
| 用户编辑保存 | 创建版本快照 → 触发 autoSync | 版本捕获在保存前 |
| 同步下载覆盖 | 创建版本快照（内容不同时） | 捕获其他设备带来的变更 |
| 同步 fast-forward | 不创建版本 | hash 相同，内容未变 |
| 同步冲突副本 | 不创建版本 | 新 uuid 产生新笔记，无旧版本 |
| 笔记软删除（墓碑） | 不创建版本，保留已有版本 | 删除不是内容变更 |
| 笔记硬删除（墓碑 GC） | 删除该笔记所有版本 | 清理磁盘，见 §8.1 |
| 密钥迁移（reEncryptAllNotes） | 不创建版本 | 加密层变更，内容不变 |
| 恢复版本 | 保存当前为新版本 → 触发 autoSync | 恢复等同于一次编辑 |

### 7.2 核心原则

**版本表完全独立于同步流程**：

- 同步引擎不感知 `note_versions` 表的存在
- 同步只管 `notes` 表的内容收敛
- 版本表是"旁路记录"，不影响同步逻辑
- 版本表不参与 manifest、不上传 blob、不参与冲突解决

### 7.3 同步期间的版本查看

用户查看版本历史时，同步可能在后台运行并修改笔记内容。

**处理策略**：

- 版本列表在页面打开时一次性加载，不实时更新
- diff 计算时重新读取当前笔记内容（`readNoteByUuid`），确保 diff 基准是最新的
- 如果同步在 diff 计算期间修改了笔记，diff 可能不完全准确——但这只是视觉问题，不影响数据正确性
- 用户可以重新选择版本来刷新 diff

## 8. 边界情况与风险

### 8.1 笔记硬删除时清理版本

当墓碑超过 30 天被 GC 硬删除时（`_buildLocalManifest` 中 `hardDeleteByUuid`），同时清理该笔记的所有版本：

```dart
Future<int> hardDeleteByUuid(String uuid) async {
  final db = await database;
  // 现有：删除 notes 表行
  final rows = await db.delete(tableNotes,
      where: '${NoteFields.uuid} = ?', whereArgs: [uuid]);

  // ✦ 新增：清理版本表
  await db.delete(tableNoteVersions,
      where: '${NoteVersionFields.noteUuid} = ?', whereArgs: [uuid]);

  Log.note.i('硬删除笔记及版本: uuid=$uuid versions_cleaned');
  return rows;
}
```

### 8.2 笔记软删除时保留版本

软删除（`softDelete`）只标记 `deleted=1`，不删除版本。用户可能恢复已删除的笔记，此时版本历史应仍然可用。

### 8.3 导入备份时无版本

导入备份（`storeNotesInTransaction`）只恢复笔记当前内容，不恢复版本历史。导入的笔记从空白版本历史开始。这是设计决策——版本是本地功能，不随备份迁移。

### 8.4 密钥变更后的版本解密

密钥迁移（`reEncryptAllNotes`）会重新加密 notes 表，但**不重新加密版本表**。

**问题**：如果 dataKey 变更（如修改密码），版本表中的旧密文将无法用新密钥解密。

**解决方案**：密钥迁移时同时重新加密版本表。在 `reEncryptAllNotes` 方法中追加：

```dart
// 在 reEncryptAllNotes 中，笔记重加密完成后：
await _reEncryptAllVersions(oldKey, newKey);

Future<void> _reEncryptAllVersions(Uint8List oldKey, Uint8List newKey) async {
  final db = await database;
  final rows = await db.query(tableNoteVersions);
  for (final row in rows) {
    final uuid = row[NoteVersionFields.noteUuid] as String;
    // 用旧 key 解密
    final title = await _decryptFieldWithKey(uuid,
        row[NoteVersionFields.title] as String, oldKey);
    final desc = await _decryptFieldWithKey(uuid,
        row[NoteVersionFields.description] as String, oldKey);
    // 用新 key 重新加密
    await db.update(
      tableNoteVersions,
      {
        NoteVersionFields.title: await _encryptFieldWithKey(uuid, title, newKey),
        NoteVersionFields.description: await _encryptFieldWithKey(uuid, desc, newKey),
      },
      where: '${NoteVersionFields.id} = ?',
      whereArgs: [row[NoteVersionFields.id]],
    );
  }
}
```

**注意**：这需要在 `database_handler.dart` 中新增 `_encryptFieldWithKey` 和 `_decryptFieldWithKey` 方法（接受显式 key 参数），或重构现有 `_encryptField` 使其可接受可选 key 参数。

**替代方案**：如果密钥迁移场景较少（仅在修改密码时触发），可以在迁移时直接清空版本表（`DELETE FROM note_versions`），丢弃历史版本。这是更简单但更激进的方案，适合首期实现。

**首期建议**：采用替代方案（清空版本表），在文档中记录为已知限制。后续根据用户反馈决定是否实现重加密。

### 8.5 磁盘空间评估

| 场景 | 单条版本大小 | 50 条版本总大小 |
|------|-------------|----------------|
| 短笔记（100 字） | ~0.5KB（加密后） | ~25KB |
| 中等笔记（1000 字） | ~3KB | ~150KB |
| 长笔记（5000 字） | ~12KB | ~600KB |
| 超长笔记（20000 字） | ~45KB | ~2.2MB |

假设用户有 500 条笔记，平均每条 1000 字，50 条版本/笔记：
- 总版本数：500 × 50 = 25000 条
- 总大小：25000 × 3KB ≈ 75MB

对于桌面应用，75MB 是可接受的。对于移动端，可在设置中提供更小的版本上限（如 20 条）。

### 8.6 并发写入安全

`saveVersion` 和 `updateNote` 是两次独立的数据库操作。`_isSaving` 互斥守卫（`editor_state.dart:66-69`）确保编辑路径不会并发调用 `updateNote`。

同步路径的并发由同步引擎自身的锁机制保证（同步是串行的）。

编辑路径和同步路径可能并发（用户编辑时后台同步运行），但它们操作不同的笔记 uuid（同步只处理远端变更，用户编辑的是当前笔记），不会产生写冲突。

极端情况：用户正在编辑笔记 A，同步下载了笔记 A 的远端更新。此时 `updateNote`（编辑）和 `updateNoteByUuid`（同步）可能并发操作同一行。但 `_isSaving` 守卫不阻止同步路径（同步不经过 `editor_state`），因此存在竞态。

**缓解措施**：这不是版本功能引入的问题——现有代码已有此竞态。版本功能不加剧风险（`saveVersion` 只是 INSERT，不影响 notes 表的 UPDATE 竞态）。

### 8.7 版本列表为空时的下拉框

下拉框在无版本时隐藏，显示空状态组件。恢复按钮禁用。

### 8.8 版本时间戳精度

`savedAt` 使用 `DateTime.now().millisecondsSinceEpoch`，精度为毫秒。如果用户快速连续保存两次（< 1ms 间隔），两条版本的 `savedAt` 可能相同。

**影响**：版本列表按 `saved_at DESC` 排序，相同时间戳的版本顺序不确定（由 `_id` 隐式决定，AUTOINCREMENT 保证 _id 递增）。

**缓解**：SQLite 的 `ORDER BY saved_at DESC` 在相同值时按行返回顺序（通常是 rowid 顺序），因此相同时间戳的版本会按插入顺序排列。这在实践中是正确的。

## 9. 实施计划

### 9.1 文件清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `packages/core/lib/src/models/note_version.dart` | 新增 | NoteVersion 模型 |
| `packages/core/lib/core.dart` | 修改 | 导出 note_version.dart |
| `packages/core/lib/src/db/database_handler.dart` | 修改 | schema v7 + 版本 CRUD |
| `packages/core/lib/src/sync/sync_engine.dart` | 修改 | `_downloadNote` 中新增版本捕获 |
| `lib/models/editor_state.dart` | 修改 | `updateNote` 中新增版本捕获 |
| `lib/utils/note_diff.dart` | 新增 | diff 计算工具 |
| `lib/views/version_history_page.dart` | 新增 | 版本历史全屏页面 |
| `lib/widgets/note_actions_sheet.dart` | 修改 | 新增版本历史菜单项 |
| `lib/views/add_edit_note.dart` | 修改 | 新增菜单项处理 + 页面跳转 |
| `pubspec.yaml` | 修改 | 新增 diff_match_patch 依赖 |
| `assets/translations/zh-CN.json` | 修改 | 新增翻译 |
| `assets/translations/en-US.json` | 修改 | 新增翻译 |
| `packages/core/test/note_version_test.dart` | 新增 | 版本 CRUD 测试 |
| `packages/core/test/note_diff_test.dart` | 新增 | diff 计算测试 |
| `test/version_history_page_test.dart` | 新增 | UI 集成测试 |
| `docs/CHANGES-20260821.md` | 修改 | 记录变更 |

### 9.2 实施步骤

按依赖顺序分 5 个阶段：

#### 阶段 1：数据层（packages/core）

1. 新建 `note_version.dart` 模型
2. `database_handler.dart`：schema v7 升级 + `_createNoteVersionsTable`
3. `database_handler.dart`：实现 `saveVersion`、`readVersions`、`readVersion`、`restoreVersion`、`_pruneVersions`、`deleteVersionsForNote`
4. `database_handler.dart`：`hardDeleteByUuid` 追加版本清理
5. `core.dart` 导出 `note_version.dart`
6. 编写 `packages/core/test/note_version_test.dart` 单元测试

**验证**：`dart test packages/core/test/note_version_test.dart` 通过

#### 阶段 2：版本捕获

7. `editor_state.dart`：`updateNote()` 中新增 `saveVersion(original!)`
8. `sync_engine.dart`：`_downloadNote()` 中新增版本捕获（条件：existing != null && !deleted && hash 不同）

**验证**：编辑笔记后查看数据库，确认版本表有记录；同步后确认版本表有记录

#### 阶段 3：Diff 工具

9. `pubspec.yaml` 新增 `diff_match_patch` 依赖
10. 新建 `lib/utils/note_diff.dart`：`computeDiff`、`computeNoteDiff`、`computeNoteDiffAsync`
11. 编写 `packages/core/test/note_diff_test.dart` 单元测试

**验证**：`dart test packages/core/test/note_diff_test.dart` 通过

#### 阶段 4：UI 层

12. `note_actions_sheet.dart`：新增 `versionHistory` 枚举和菜单项
13. `add_edit_note.dart`：新增 `_openVersionHistory` 方法和 switch case
14. 新建 `version_history_page.dart`：全屏页面（下拉框 + diff 渲染 + 恢复按钮）
15. 翻译文件：新增 zh-CN 和 en-US 翻译

**验证**：`flutter analyze` 无错误；手动测试全流程

#### 阶段 5：集成与文档

16. `flutter build windows --debug` 验证编译
17. `flutter test` 全量测试通过
18. `flutter test integration_test/ -d windows` 集成测试通过
19. 更新 `docs/CHANGES-20260821.md`
20. `dart format` + `import_sorter` 格式化

### 9.3 测试计划

#### 单元测试（packages/core/test/）

| 测试文件 | 测试内容 |
|----------|----------|
| `note_version_test.dart` | saveVersion 基本功能、contentHash 去重、FIFO 清理（超 50 条）、readVersions 排序、restoreVersion（恢复后当前内容被保存为新版本）、deleteVersionsForNote、空 title/description 处理 |
| `note_diff_test.dart` | 相同文本（无差异）、纯新增、纯删除、混合变更、空文本、超长文本性能、Unicode/中文 diff 正确性 |

#### 集成测试（integration_test/）

| 测试场景 | 验证点 |
|----------|--------|
| 编辑笔记 → 打开历史版本 | 版本列表正确显示，diff 正确渲染 |
| 选择不同版本 | diff 区域更新 |
| 恢复版本 | 笔记内容更新，返回编辑页内容正确 |
| 新建笔记的历史版本 | 空状态正确显示 |
| 锁定笔记的历史版本 | 恢复按钮禁用 |
| 无差异版本 | "无差异"提示正确显示 |

#### 测试要点

- **加密一致性**：版本表加密/解密使用与 notes 表相同的 dataKey 和 AAD(uuid)
- **schema 升级**：从 v6 数据库升级到 v7 后，版本表正常工作
- **contentHash 去重**：连续保存相同内容的笔记，不产生重复版本
- **FIFO 清理**：保存超过 50 条版本后，最旧的被自动删除
- **恢复撤销**：恢复版本后，原内容作为新版本保存，可再次恢复回去
- **中文 diff**：确保 diff_match_patch 正确处理中文字符（多字节 UTF-8）

## 10. 已知限制与后续演进

### 10.1 首期已知限制

| 限制 | 影响 | 后续方向 |
|------|------|----------|
| 版本不同步 | 换设备后看不到旧设备的版本历史 | 可选：将版本作为独立 blob 同步 |
| 版本不随备份导出 | 导入备份后版本历史丢失 | 可选：备份格式扩展版本数据 |
| 密钥迁移清空版本表 | 修改密码后版本历史丢失 | 实现 `_reEncryptAllVersions` |
| 无版本搜索/过滤 | 50 条版本只能下拉框浏览 | 版本列表页（替代下拉框） |
| 无版本对比（两个历史版本之间） | 只能 diff 当前 vs 历史 | 支持选择两个版本互相对比 |

### 10.2 后续演进方向

1. **版本列表页**：当下拉框 50 条不够直观时，升级为独立列表页（类似 Git log），支持搜索和过滤
2. **版本间对比**：选择两个历史版本进行 diff，不仅限于与当前对比
3. **版本同步**：将版本作为加密 blob 上传，多设备共享版本历史
4. **版本备注**：允许用户为重要版本添加标记/备注（如"发布前最终版"）
5. **智能清理策略**：从 FIFO 升级为"保留首尾 + 等间隔采样"，确保初始版本不被清除
6. **版本数量配置**：在设置中提供版本上限配置（10/25/50/100）
