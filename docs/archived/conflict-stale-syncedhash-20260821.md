# 虚假冲突副本根因分析：编辑期间 syncedHash 回退

> 日期：2026-08-21
> 涉及文件：`lib/models/editor_state.dart`、`packages/core/lib/src/sync/sync_engine.dart`、`packages/core/lib/src/db/database_handler.dart`
> 修复提交：`docs/CHANGES-20260821.md` 顶部

## 1. 现象

用户在 Android 端多次编辑标题为「欧洲监管机构对安全测评保密」的笔记（uuid=`47a1555e-5c7e-40bf-af7e-c441f72e2e77`），随后在 Windows 端打开时发现多了一个冲突副本（uuid=`e95b2552-9b80-4165-a95e-ac2785999f1c`，标题含「(冲突副本 1·androi)」后缀）。按同步引擎设计，只有多端同时编辑才应产生冲突副本，但用户声称只在 Android 上编辑过。

## 2. 调查方法

### 2.1 数据来源

| 数据源 | 路径 | 用途 |
|--------|------|------|
| Android debug 日志 | `temp/android-data/safenotes-20260821.log` | 还原编辑/同步时序 |
| Android debug journal | `temp/android-data/journal.json` | 确认 upload/conflict 记录 |
| Android debug 数据库 | `temp/android-data/safenotes_db_*.db` | 查看最终 syncedHash、note_versions |
| Android release journal | `temp/android-release-data/journal.json` | 排除 release 版作为冲突来源 |
| Windows journal | `temp/carronote-dev/journal/log.json` + `log-444.json` | 排除 Windows 端作为冲突来源 |
| Windows 数据库 | `safenotes_sync.db` | 确认 download 记录 |
| WebDAV 远端数据 | `temp/safenotes-vault` | manifest 版本和 blob 状态 |

### 2.2 调查路径

1. **解密远端 manifest 和 blob** — 用 Dart 测试脚本（`packages/core/test/conflict_investigation_test.dart`）复用 `ManifestCrypto` / `SyncCrypto` 解密，确认两个笔记的标题、内容、`updatedBy` 字段
2. **交叉比对三端 journal** — 确认冲突窗口（16:59:25–16:59:45）内无其他客户端修改远端
3. **还原完整时间线** — 从 Android 日志中 grep `47a1555e` 的所有出现，逐行对齐编辑、同步、冲突事件
4. **代码追踪** — 从冲突检测入口（`_mergeManifests` 行 1543–1615）反向追踪 `base`（`syncedHash`）的更新路径（`markSyncedForUuids` → `_applySyncedToCache`）和 UI 编辑路径（`editor_state.dart` → `copyWith` → `updateNote` → `_toEncryptedRow`）
5. **版本快照验证** — `note_versions` 表的 4 条快照与日志时间线完全吻合

### 2.3 排除的假设

- **假设 A：其他客户端在冲突窗口内修改了远端** — 排除。三端 journal 交叉比对确认窗口内无其他活动
- **假设 B：远端 manifest 被 etag 缓存跳过** — 排除。日志显示 `downloaded=0`，GET manifest 正常返回
- **假设 C：release 版独立同步覆盖了远端** — 排除。release journal 在窗口内无条目

## 3. 根因

### 3.1 机制

`NoteEditorState.original` 是**静态变量**（`editor_state.dart:21`），在进入编辑页时被设置为 `widget.note` 的引用。同步引擎在编辑期间完成同步后，通过 `_applySyncedToCache` 使用 `copyWith` 创建新对象替换缓存中的旧条目，但 `original` 仍持有旧对象引用——其 `syncedHash` 是过时值。

保存编辑时，`copyWith` 不传 `syncedHash` 参数（`safenote.dart:182`：`syncedHash: syncedHash ?? this.syncedHash`），保留了旧值。随后 `updateNote` → `_toEncryptedRow` → `toJson`（`safenote.dart:239`：`NoteFields.syncedHash: syncedHash`）把这个过时值写入数据库，覆盖了同步引擎已正确更新的 base 值。

### 3.2 精确时序

```
16:59:22  用户保存编辑（第1次）
          original.syncedHash = 2c3a3e99（16:39:32 同步后的收敛值）
          → DB: contentHash=805d1ced, syncedHash=2c3a3e99  ✓ 正确

16:59:23  用户再次进入编辑页
          → original 被重新设置，仍持有 syncedHash=2c3a3e99

16:59:25  autoSync 触发同步
          base=2c3a3e99, remote=2c3a3e99 → fast-forward，上传 805d1ced
          markSyncedForUuids → DB: syncedHash=805d1ced  ✓ 正确
          _applySyncedToCache → 缓存中对象被 copyWith 替换为新对象
          ⚠️ 但 original 仍持有旧对象引用，syncedHash=2c3a3e99

16:59:42  用户保存编辑（第2次）
          original!.copyWith(...) 保留 syncedHash=2c3a3e99  ← 过时！
          → DB: contentHash=dd22f090, syncedHash=2c3a3e99
          ✗ 覆盖了 16:59:25 同步正确写入的 805d1ced！

16:59:45  autoSync 触发同步
          base = syncedHash = 2c3a3e99  ← 被覆盖的旧值
          localItem.hash  = dd22f090（16:59:42 编辑后）
          remoteItem.hash = 805d1ced（16:59:25 上传的）
          localChanged  = (dd22f090 ≠ 2c3a3e99) = true
          remoteChanged = (805d1ced ≠ 2c3a3e99) = true  ← 误判！
          → "双方都偏离 base" → 真冲突 → 生成冲突副本 e95b2552
```

### 3.3 冲突副本内容验证

冲突副本 `e95b2552` 的 description 长度为 839 字符，与 `805d1ced` 版本（16:59:25 上传到远端）一致。败方是远端，本地胜出（LWW: local newer）。这证实了 `remoteItem.hash` 确实是 `805d1ced`，而非被覆盖的 `2c3a3e99`。

## 4. 修复方案

### 4.1 方案 A（已实施）：保存前从数据库读取最新 syncedHash

在 `editor_state.dart` 的 `updateNote()` 中，保存前调用 `readNoteByUuid` 获取数据库中的最新 `syncedHash`/`syncedDeleted`，而非沿用 `original` 的过时值：

```dart
final fresh = await NotesDatabase.instance.readNoteByUuid(original!.uuid);
final note = original!.copyWith(
  title: title,
  description: description,
  contentHash: SafeNote.computeHash(title, description),
  updatedAt: now.millisecondsSinceEpoch,
  synced: false,
  syncedHash: fresh?.syncedHash,
  syncedDeleted: fresh?.syncedDeleted,
);
```

**优点**：改动最小，语义清晰，不影响数据库层的写路径
**缺点**：多一次数据库读取（可接受，保存操作不是高频路径）

### 4.2 方案 B（备查）：数据库层不覆盖 synced 列

在 `database_handler.dart` 的 `updateNote()` 中，SQL 只更新内容列，不覆盖 `synced_hash` / `synced_deleted`：

```dart
// UPDATE notes SET title=?, description=?, content_hash=?, updated_at=?, synced=0
// WHERE _id=?  —— 不动 synced_hash / synced_deleted 列
```

**优点**：从源头杜绝任何 UI 路径覆盖 synced 列；`_toEncryptedRow` 天然不会泄露旧 syncedHash
**缺点**：需区分 UI 编辑路径（`updateNote`，按 id 更新）和同步下载路径（`updateNoteByUuid`，按 uuid 更新）。后者确实需要写 `syncedHash`（下载覆盖后标记已同步），因此不能简单地在两个方法中都排除 synced 列。需要：
  - `updateNote`（UI 路径）：排除 `synced_hash` / `synced_deleted` 列
  - `updateNoteByUuid`（同步路径）：保持写入 `synced_hash` / `synced_deleted`
  - 或者新增一个 `updateNoteContent` 方法专供 UI 路径使用

**适用场景**：如果未来发现还有其他 UI 路径也通过 `updateNote` 写入数据库并可能携带过时 syncedHash，方案 B 可以一劳永逸地在数据库层兜底。当前选择方案 A 是因为只有 `editor_state.dart` 一个入口。

## 5. 日志/journal 缺失分析

本次调试过程中，以下关键信息在日志或 journal 中**缺失或不足**，显著增加了定位难度：

### 5.1 冲突判定时缺少 base/local/remote 三元组

**现状**：冲突日志只打印了 `⚡ conflict uuid=47a1555e local won (LWW: local newer, remote preserved as copy)`，没有打印判定冲突时使用的 `base`（syncedHash）、`localItem.hash`、`remoteItem.hash` 三个关键值。

**影响**：无法直接从日志确认冲突是否为误判。如果打印了这三个值，会立即看到 `base=2c3a3e99`（已被回退覆盖）而 `remoteItem.hash=805d1ced`（Android 自己刚上传的），从而直接定位到 syncedHash 被错误回退。

**建议**：在 `_mergeManifests` 的真冲突分支（行 1604 附近）增加 DEBUG 级日志：

```dart
Log.sync.w(
  '⚡ conflict uuid=$uuid '
  'base=${base?.substring(0, 12) ?? "null"} '
  'local=${localItem.hash.substring(0, 12)} '
  'remote=${remoteItem.hash.substring(0, 12)} '
  'localChanged=$localChanged remoteChanged=$remoteChanged '
  '→ ${winner == localItem ? "local won" : "remote won"}',
);
```

### 5.2 markSynced 时缺少每条笔记的 syncedHash 刷新记录

**现状**：日志只打印 `按 uuid 集合标记已同步: 50 条已标记 (请求 50 个)`，没有打印每条笔记的 `contentHash → syncedHash` 映射。

**影响**：无法从日志直接确认 16:59:25 同步后 `47a1555e` 的 `syncedHash` 是否被正确更新为 `805d1ced`。需要查数据库最终状态反推，但最终状态已被 16:59:42 的编辑覆盖。

**建议**：在 `markSyncedForUuids` 中对**发生变化的**条目增加 DEBUG 日志（避免稳态噪音）：

```dart
// 仅对 syncedHash 实际变化的条目打日志
if (oldSyncedHash != note.contentHash) {
  Log.sync.d('markSynced: uuid=${note.uuid.substring(0, 8)} '
      'syncedHash ${oldSyncedHash?.substring(0, 12) ?? "null"} → ${note.contentHash.substring(0, 12)}');
}
```

### 5.3 updateNote 时缺少 syncedHash 变更追踪

**现状**：日志打印 `修改笔记 uuid=47a1555e id=4 hash=dd22f090… len=14+2246 rows=1`，只打印了新的 `contentHash`，没有打印 `syncedHash` 是否变化、是否被回退。

**影响**：16:59:42 保存编辑时，如果日志打印了 `syncedHash: 805d1ced → 2c3a3e99`（回退），会立即发现 syncedHash 被错误覆盖。

**建议**：在 `updateNote` 中，当 `syncedHash` 值与数据库当前值不同时打印 WARN 日志：

```dart
// 读取当前 DB 中的 syncedHash 做对比
final oldSyncedHash = ...; // 可从缓存或 DB 获取
if (note.syncedHash != null && oldSyncedHash != null && note.syncedHash != oldSyncedHash) {
  Log.note.w('updateNote syncedHash changed: uuid=${note.uuid.substring(0, 8)} '
      '${oldSyncedHash.substring(0, 12)} → ${note.syncedHash!.substring(0, 12)}');
}
```

### 5.4 journal 缺少 syncedHash 快照

**现状**：journal 的 `note.upsert` 条目只记录 `uuid`、`hash`（contentHash）、`type`（upload/download）、`by`，不记录 `syncedHash`。

**影响**：无法从 journal 追踪 syncedHash 的变化历史，只能依赖运行时日志。如果日志已滚动覆盖，则完全无法回溯。

**建议**：在 `note.upsert` 条目中增加 `syncedHash` 字段（可选，仅当值发生变化时记录）。或者在 `markSynced` 操作时增加专门的 journal 条目类型 `note.synced`，记录 `uuid` + `syncedHash`。

### 5.5 缺少 manifest version 在 GET 时的打印

**现状**：日志打印 `GET manifest empty=false etag=present attempt=1`，但不打印远端 manifest 的 version。

**影响**：无法从日志直接确认两次同步之间远端 manifest 是否被其他客户端修改过（version 是否变化）。本次调试需要通过三端 journal 交叉比对来排除，如果日志直接打印了 version，一步即可确认。

**建议**：在 GET manifest 解析 header 后增加 version 打印：

```dart
Log.sync.d('GET manifest empty=false etag=present version=${remoteHeader.version} attempt=$attempt');
```

## 6. 总结

| 维度 | 结论 |
|------|------|
| 根因 | `NoteEditorState.original` 静态引用在编辑期间不随同步引擎更新，保存时 `copyWith` 保留过时 `syncedHash` 写回 DB |
| 触发条件 | 编辑页打开期间后台同步完成（更新了 syncedHash），随后用户保存编辑（用旧 syncedHash 覆盖） |
| 影响 | 虚假冲突副本；不会丢数据（LWW + 副本保留），但用户体验差 |
| 修复 | 方案 A：保存前从 DB 读取最新 syncedHash |
| 日志改进 | 5 项关键缺失：冲突三元组、markSynced 刷新值、updateNote syncedHash 变更、journal syncedHash 快照、GET manifest version |
