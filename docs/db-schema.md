# 本地数据库表结构

> 适用范围：SafeNotes 本地 SQLite 数据库（`safenotes_sync.db`）的表结构说明。
>
> 权威实现：`packages/core/lib/src/db/database_handler.dart`
> （`NotesDatabase` / `_createDB` / `_onUpgrade` / `MetaKeys`）。
> 笔记模型字段定义：`packages/core/lib/src/models/safenote.dart`
> （`NoteFields` / `tableNotes` / `tableMeta`）。
>
> 数据库基本信息：
> - 文件名：`safenotes_sync.db`
> - Schema 版本：**4**（onCreate 建 v4；onUpgrade 负责 v3 → v4 加列）
> - 引擎：sqflite（移动端）/ sqflite_common_ffi（桌面端、CLI、测试）

---

## 1. 总览

| 表名          | 常量              | 用途                                   |
|---------------|-------------------|----------------------------------------|
| `safe_notes`  | `tableNotes`      | 笔记主表（字段级加密的 title/description）|
| `sync_meta`   | `tableMeta`       | 键值元数据（keyring 账本、同步状态、GC 候选等）|

索引：

```sql
CREATE INDEX idx_notes_uuid     ON safe_notes(uuid);
CREATE INDEX idx_notes_deleted  ON safe_notes(deleted);
CREATE INDEX idx_notes_synced   ON safe_notes(synced);
```

---

## 2. `safe_notes` 表

笔记主表。除 `title` / `description` 外的字段均为明文；`title` / `description`
写入前用当前会话 `dataKey` 做 **AES-256-GCM 字段级加密**，以
`base64(nonce(12) ‖ ciphertext ‖ tag(16))` 形式存储，AAD = 该笔记 `uuid`。

### 2.1 列定义

```sql
CREATE TABLE safe_notes (
  _id            INTEGER PRIMARY KEY AUTOINCREMENT,
  uuid           TEXT NOT NULL UNIQUE,
  title          TEXT NOT NULL,   -- 加密信封（base64）
  description    TEXT NOT NULL,   -- 加密信封（base64）
  content_hash   TEXT NOT NULL,
  deleted        INTEGER NOT NULL DEFAULT 0,
  created_at     TEXT NOT NULL,   -- ISO-8601 时间字符串
  updated_at     INTEGER NOT NULL,-- Unix 毫秒，用于 LWW
  synced         INTEGER NOT NULL DEFAULT 0,
  synced_hash    TEXT,
  synced_deleted INTEGER NOT NULL DEFAULT 0
);
```

| 列名            | 类型    | 约束            | 说明                                                                                     |
|-----------------|---------|-----------------|------------------------------------------------------------------------------------------|
| `_id`           | INTEGER | PK AUTOINCREMENT| 本地自增主键（内部用）                                                                   |
| `uuid`          | TEXT    | NOT NULL UNIQUE | 笔记全局唯一标识（UUIDv4），同步与加密 AAD 都用它                                        |
| `title`         | TEXT    | NOT NULL        | 标题，字段级 AES-GCM 加密（base64 信封）                                                |
| `description`   | TEXT    | NOT NULL        | 正文，字段级 AES-GCM 加密（base64 信封）                                                |
| `content_hash`  | TEXT    | NOT NULL        | 内容 SHA-256 哈希（明文，`SHA-256(title + "\n" + description)`），用于同步比对和 blob 寻址 |
| `deleted`       | INTEGER | NOT NULL DEFAULT 0 | 软删除墓碑标记（1=已删）。软删除不真正删行                              |
| `created_at`    | TEXT    | NOT NULL        | 创建时间，ISO-8601 字符串                                                                 |
| `updated_at`    | INTEGER | NOT NULL        | 最后更新时间（Unix 毫秒），LWW 冲突解决依据                                             |
| `synced`        | INTEGER | NOT NULL DEFAULT 0 | 是否已与远端收敛（1=已同步）                                                        |
| `synced_hash`   | TEXT    | 可空            | 上次收敛时的共同祖先 `content_hash`（三方合并 base，区分单边编辑与真并发冲突）          |
| `synced_deleted`| INTEGER | NOT NULL DEFAULT 0 | 上次收敛时的 `deleted` 状态；与 `synced_hash` 共同描述 `(hash, deleted)` base，解决软删除不改 hash 导致误判 |

### 2.2 字段级加密说明

- `setDataKey` 注入 `dataKey` 后才能读写；未注入读写抛 `DataKeyNotSetException`。
- 加密（`_encryptField`）：`SyncCrypto.seal(dataKey, uuid, utf8(title))`
  → `base64` 信封；`uuid` 作 AAD，防止信封在笔记间互换。
- 解密（`_decryptField`）：`base64` 解码 → `SyncCrypto.open(dataKey, uuid, env)`
  → UTF-8 明文；失败抛异常（不静默返回原值）。
- `content_hash` / `deleted` / `synced*` 等为明文（仅用于同步比对，不泄露内容）。
- 隐私红线：日志中绝不出现 title/description 明文，只记 uuid、长度、hash 前缀、时间戳。

### 2.3 Schema 升级（v3 → v4）

```sql
-- version 3 → 4 唯一变更：新增 synced_deleted
ALTER TABLE safe_notes ADD COLUMN synced_deleted INTEGER NOT NULL DEFAULT 0;
```

- 老数据 `synced_deleted` 全初始化为 0（未删除），与语义一致。
- 真实写入当前的列定义（含 `synced_deleted`）由 `_createDB`（v4）创建；
  测试内存库用 `createDBForTesting` → `_createDBStatic`（同一 SQL）。

---

## 3. `sync_meta` 表

键值元数据表，持久化同步状态与账本。`key` 为主键，`value` 为字符串（多为 JSON）。

```sql
CREATE TABLE sync_meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
```

### 3.1 已知键（`MetaKeys`）

| 键（`MetaKeys`）           | value 类型           | 说明                                                                 |
|----------------------------|----------------------|----------------------------------------------------------------------|
| `keyring`                  | JSON 对象            | **P2 单键**密钥账本（JSON 序列化），含 vaultId/kdf/current 密钥态    |
| `purged_uuids`             | JSON 数组（string[]）| 已本地硬删除、待下次同步从远端 manifest 清除的 uuid 列表（M1）        |
| `blob_reupload_pending`    | JSON 数组（string[]）| dataKey 变更后需强制重传 blob 的笔记 uuid 列表（Layer 2a）           |
| `gc_orphan_candidates`     | JSON 对象（hash→ts） | 孤儿 blob 两阶段 GC 候选表（hash → 首次观察时间戳），连续两次观察才隔离 |
| `manifest_version:<pk>`    | 字符串整数           | 各后端实例（`providerKey`）的本地 manifest 版本号，按后端隔离存储     |

> 说明：`manifest_version:<pk>` 由 `NotesDatabase.getManifestVersion` /
> `setManifestVersion` 通过 `_manifestVersionKey(providerKey)` 动态生成，
> 不在 `MetaKeys` 枚举里，但落在本表。不同后端类型/URL 的 version 互不影响。

### 3.2 操作语义要点

- `keyring`：P2 收敛后用**单键 JSON** 原子落盘（`ConflictAlgorithm.replace`），
  取代旧的多键散落写法，杜绝"双写半成功"。
- `purged_uuids`：硬删除（`hardDelete` / `hardDeleteByUuid`）在**同一 SQLite 事务**
  内"删行 + 追加 purged 列表"（B4 修复），防止"删行成功但 purged 未写"导致墓碑
  从远端复活。同步成功后由引擎调用 `removePurgedUuids` 清除。
- `blob_reupload_pending`：密钥变更后 `markAllForBlobReupload` 写入；同步成功后
  `removePendingReuploadUuids`（仅移除本轮成功重传的）或 `clearAllPendingReupload`
  清除，避免旧密钥 blob 永久残留。
- `gc_orphan_candidates`：首次观察只登记候选、不隔离；连续第二次观察仍为孤儿才隔离，
  避开"他端刚 putBlob 尚未 putManifest"的并发窗口。

---

## 4. 行内缓存（非数据库结构，但相关）

`NotesDatabase` 维护一个内存解密缓存 `_notesCache`（含墓碑全量 `SafeNote`），
作为 DB 的**强一致镜像**：每次写都先落 DB、再用同一份内存对象更新缓存。
- 收敛的写路径收口到 4 个私有方法：`_invalidateCache` / `_upsertCacheEntry` /
  `_removeCacheEntry` / `_applySyncedToCache`。
- `setDatabaseForTesting` / `close` / `logout` 等会清空缓存。
- 该缓存是内存结构，不落盘，不影响上表物理结构。

---

## 5. 主要读写入口（供对照）

| 方法                        | 作用                                         |
|-----------------------------|----------------------------------------------|
| `storeNote` / `updateNote`  | 新增/更新（自动加密 title/description）       |
| `readNote` / `readNoteByUuid` | 按 id/uuid 读取（自动解密）                |
| `readAllNotes`              | 所有未删除笔记（UI 列表）                    |
| `readDeletedNotes`          | 已删除笔记（回收站）                          |
| `readUnsyncedNotes`         | 待同步笔记（synced=0）                        |
| `readAllNotesIncludingDeleted` | 全量含墓碑（同步对账、缓存来源）          |
| `softDelete` / `restoreNote`| 软删除/恢复                                   |
| `hardDelete` / `hardDeleteByUuid` | 永久删除（同事务写 purged 列表）       |
| `reEncryptAllNotes*`        | dataKey 迁移重加密（事务内原子）              |
| `markSynced*`               | 标记已同步并刷新 `(synced_hash, synced_deleted)` base |
| `getMeta` / `setMeta`       | sync_meta 键值读写                            |
| `exportAll`                 | 导出全部笔记明文 JSON（备份用，上层负责加密）|
