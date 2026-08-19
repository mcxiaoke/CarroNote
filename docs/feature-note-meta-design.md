# 笔记元数据（note_meta）表设计

> 状态：设计草案（待实现）
> 日期：2026-08-18
> 取代：`feature-starred-tags-design.md`（旧方案为"notes 表加列"，已废弃）
> 首期功能：星标/置顶（pinned）+ 标签（tags）
> 长期定位：笔记级元数据的统一载体 + 跨设备同步

## 0. 方案演进与关键决策

### 0.1 相比旧方案的三处修正

| | 旧方案（已废弃） | 本方案 |
|---|---|---|
| 本地存储 | notes 表 `ALTER TABLE` 加 13 列 | **新建 `note_meta` 表**，notes 表零改动 |
| 迁移风险 | 高（`ALTER TABLE` 动主表数据） | 低（`CREATE TABLE IF NOT EXISTS`，幂等、不 touch notes） |
| 敏感字段 | `tags` 明文列落盘 | 敏感字段进 `payload`（dataKey 加密） |
| 字段扩展 | 预留 13 个列 | 明文列仅留不敏感项，其余走 `payload` JSON，加字段免改 schema |
| 远端合并 | 整文件 LWW（会互相覆盖） | **per-note LWW**（按 uuid 逐条比 `updated_at`） |

### 0.2 已确认决策

- **星标与置顶合并为单个 `pinned`**（非两个独立开关）。
- **新建独立表，而非往 notes 表加列**（避免动主表 + 避免污染加密行映射路径）。
- **查询不用 JOIN**（理由见 §3，读路径主力是内存缓存，JOIN 几乎不会执行且有性能倒退风险）。
- **跨设备同步走独立加密文件 `items.meta`**，笔记 blob 的 `computeHash` / `toContentBytes` / `fromContentBytes` / blob AAD **绝对不动**。
- **敏感字段加密、不敏感字段明文列**：`tags` 等用户输入文本进 `payload`；`pinned`/`archived` 等布尔进明文列以便索引。
- **字段命名不标注加密**：加密列直接叫 `payload`，与 notes 表 `title`/`description`（同为密文却不叫 `enc_title`）保持一致。

## 1. 架构总览

三层，互不耦合：

```
┌──────────────────────────────────────────────────────┐
│ 本地 SQLite                                           │
│  notes 表        ← 零改动（title/description 加密）    │
│  note_meta 表    ← 新建，笔记级元数据                  │
│  sync_meta 表    ← 现有 KV，不再塞 per-note 数据       │
└───────────────┬──────────────────────────────────────┘
                │ 独立小缓存 Map<uuid, NoteMeta>
                │ （不碰 _notesCache，切 pinned 零解密）
                ▼
┌──────────────────────────────────────────────────────┐
│ UI：首页置顶排序 / 侧栏「仅看星标」/ 按标签过滤          │
└──────────────────────────────────────────────────────┘
                │ 同步时序列化
                ▼
┌──────────────────────────────────────────────────────┐
│ 远端加密文件 items.meta                                │
│  SafeServer : resources/items.meta                    │
│  LocalFS    : keyring/items.meta                      │
│  WebDAV     : <userUrl>/safenotes-vault/items.meta    │
│  加密：AES-GCM(dataKey)，与 blob 同密钥                │
│  合并：per-note LWW（逐条比 updated_at）               │
└──────────────────────────────────────────────────────┘
```

## 2. `note_meta` 表设计

### 2.1 建表语句

```sql
CREATE TABLE note_meta (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,  -- 与 notes 表惯例一致
  uuid        TEXT    NOT NULL UNIQUE,            -- 关联 notes.uuid（不加 FK，见 2.3）
  pinned      INTEGER NOT NULL DEFAULT 0,         -- 星标/置顶（不敏感，可索引）
  archived    INTEGER NOT NULL DEFAULT 0,         -- 归档（不敏感）
  color       INTEGER,                            -- 颜色 ARGB（不敏感，NULL=默认）
  deleted     INTEGER NOT NULL DEFAULT 0,         -- 墓碑标记，见 §4
  payload     TEXT,                               -- 敏感/结构化字段，dataKey 加密 JSON
  updated_at  INTEGER NOT NULL,                   -- unix ms，per-note LWW 锚点
  synced      INTEGER NOT NULL DEFAULT 0          -- 0=待上传，1=已同步
);

CREATE UNIQUE INDEX idx_note_meta_uuid    ON note_meta(uuid);
CREATE INDEX        idx_note_meta_pinned  ON note_meta(pinned);
CREATE INDEX        idx_note_meta_synced  ON note_meta(synced);
CREATE INDEX        idx_note_meta_deleted ON note_meta(deleted);
```

索引风格对齐现有 notes 表（`database_handler.dart:596-606` 的 uuid/deleted/synced 三索引）。

### 2.2 明文列 vs `payload` 的划分准则

**判据：是否泄露用户内容语义。**

| 归属 | 字段 | 理由 |
|---|---|---|
| **明文列** | `pinned` `archived` `color` `deleted` `updated_at` `synced` | 布尔/枚举/时间戳，不含用户输入文本，泄露风险低；且需要 SQL 索引或排序 |
| **`payload`（加密）** | `tags` `icon` `source` `notebook` `reminder` `type` `template` `order` 及一切未来字段 | 含用户输入文本。`tags` 尤其敏感（"就医记录""离职"这类标签本身即隐私），本项目是加密笔记应用，明文落盘是缺口 |

`payload` 明文结构（加密前）：

```json
{
  "v": 1,
  "tags": ["work", "idea"],
  "icon": "📌",
  "type": "markdown",
  "notebook": "<notebook-uuid>",
  "source": "https://...",
  "reminder": 0,
  "order": 0,
  "template": 0,
  "extra": {}
}
```

- 只写非默认值，减小体积。
- `extra` 为透传 map：**加新字段无需改 schema、无需改建表语句、无需 bump version**，这正是"免得以后又要加字段"的解法。
- 不敏感的新字段若将来需要 SQL 索引，再"提升"为真列（一次小迁移）。

### 2.3 为什么**不加** FOREIGN KEY CASCADE

```sql
-- ❌ 绝对不要这样写
uuid TEXT NOT NULL UNIQUE REFERENCES notes(uuid) ON DELETE CASCADE
```

`deleted` 字段的用途是**墓碑**（§4）：笔记被硬删除后，notes 行消失，但 note_meta 行必须**保留**，用于告知远端"这条已删"。若加 CASCADE，墓碑会随 notes 行一起被级联删掉，**正好摧毁墓碑机制的全部意义**。

因此 `uuid` 只是逻辑关联，一致性由应用层负责（§4.3 的 GC 策略）。

### 2.4 元数据变更**不得**触碰 notes 表

**硬性规则**：改 `pinned`/`tags` 等元数据时，**禁止**改动 `notes.updated_at` / `notes.content_hash`。

理由：那两个字段是笔记正文的 LWW 锚点与内容寻址身份。改动会导致：
1. 该笔记被判定为"正文有变更" → 触发不必要的 blob 重新加密上传；
2. 极端情况下影响冲突判定（`sync_engine._mergeAndTransfer` 依赖 `(hash, deleted)` 二元组）。

元数据的时间戳独立走 `note_meta.updated_at`，同步脏标记独立走 `note_meta.synced`。两套 LWW 完全隔离。

## 3. 读路径：为什么**不用 JOIN**

### 3.1 决定性事实：读路径主力是内存缓存，不是 SQL

`_notesCache`（`database_handler.dart:308`）是全量笔记的**解密后**缓存。`readAllNotesIncludingDeleted()`（`:887-891`）命中缓存时**直接返回副本，完全跳过 SQL 查询与解密**；`readAllNotes()`（`:834`）同样复用该缓存按需过滤。

由此两条结论：

1. **JOIN 几乎不会被执行**：只有冷启动首次查询走 SQL，之后全是缓存命中。JOIN 省下的开销可忽略，代价却是侵入 `_fromEncryptedRow`（`:476`）这条最敏感的加密行映射路径。
2. **JOIN 会带来性能倒退**：若 meta 随 notes 行一起读出，那么切换一次 star 就要走 notes 的 update 路径 → `_upsertCacheEntry`（`:320`）甚至 `_invalidateCache`（`:312`）→ 最坏触发**全量笔记重解密**。

### 3.2 正确做法：独立表 + 独立小缓存

```dart
/// note_meta 的独立内存缓存，与 _notesCache 完全隔离
Map<String, NoteMeta>? _metaCache;   // key = note uuid
```

- 加载：`SELECT * FROM note_meta WHERE deleted = 0` 一次拿全量 → 解密各行 `payload` → 建 map。
- **切换 pinned**：只 UPDATE 一行 + 只更新 `_metaCache` 一个 entry，**`_notesCache` 完全不动，零笔记解密**。
- UI 取值：`metaOf(note.uuid)`，缺失则返回默认值对象（懒创建，见 3.3）。

这样 note_meta 的写入频率（用户点星标）与笔记正文缓存彻底解耦。

### 3.3 行的懒创建（避免为每条笔记预建行）

note_meta 行**按需创建**：只有当笔记首次被设置任意元数据（星标/标签/归档…）时才 INSERT。

- 读取时 `note_meta` 无对应 uuid → 视为全默认值（`pinned=0, tags=[]`）。
- 好处：老库升级后 note_meta 为空表，无需回填；绝大多数笔记不占行。

### 3.4 标签过滤在内存完成

`payload` 加密后无法 SQL 查询 `tags`，因此侧栏「按标签过滤」在内存进行：从 `_metaCache` 聚合去重得到全部标签，再按 uuid 过滤笔记列表。

当前架构下这不是问题——全量笔记本就已在 `_notesCache` 内存中，过滤是纯内存操作。

## 4. `deleted` 墓碑与 `purgedUuids` 迁移路径

### 4.1 现状机制及其脆弱点

硬删除（回收站清空）时，uuid 被追加进 `sync_meta` 的单个 KV 值 `MetaKeys.purgedUuids`（JSON 数组，`database_handler.dart:1116-1135`，在同一事务内）；SyncEngine 同步时读取（`:1138`）以删除远端并防止笔记复活，同步成功后移除（`:1144`）。

**脆弱点**：`_parseUuidList`（`:1153-1168`）在 JSON 损坏时抛 `FormatException`，**直接中止整条同步链路**。这是有意的故障保护（注释 `:1161-1165` 说明：静默返回空列表会导致已删笔记从远端复活），但代价是**单点损坏 = 全盘皆输**——所有待删 uuid 一起失效。

同时它也正是"整 JSON 塞一个 KV"模式的典型缺陷：写放大（加一个 uuid 重写整数组）、无法单条操作。

### 4.2 迁移目标形态（本期只建字段，不迁移）

将墓碑表达为 note_meta 的行状态：

| 语义 | 表达方式 |
|---|---|
| 笔记存在，有元数据 | `deleted=0`，notes 行存在 |
| 笔记软删（回收站） | `deleted=0`，notes 行 `deleted=1`（软删由 notes 表表达，meta 行不变） |
| 笔记硬删（永久） | **`deleted=1`，notes 行已消失，meta 行保留为墓碑** |
| 墓碑已告知远端 | `deleted=1 AND synced=1` → 可安全物理删除该行 |

**注意队列语义 vs 状态语义的差异**：`purgedUuids` 是队列（处理完即移除），而 `deleted` 是状态。因此必须靠 `synced` 字段区分"墓碑待上报"与"墓碑已上报"，`synced` 不能省。

迁移后收益：
- 单行 `payload`/格式损坏只影响该条，不会中止整条同步链路；
- 单条 INSERT 替代整数组重写，无写放大；
- 可 SQL 直查 `WHERE deleted=1 AND synced=0` 拿待上报墓碑（已建索引）。

### 4.3 一致性与 GC 策略

因无 FK CASCADE，需应用层维护：

1. **软删笔记**：note_meta 行不动（用户可能恢复）。
2. **硬删笔记**：在 `hardDelete*` 的**同一事务内** upsert `note_meta(uuid, deleted=1, synced=0, updated_at=now)`——与现有 `_addPurgedUuidInTxn`（`:1116`）的事务位置一致。
3. **墓碑清理**：同步成功上报后，物理删除 `deleted=1 AND synced=1` 的行（对应现有 `removePurgedUuids` 的时机）。
4. **孤儿兜底**：加载 `_metaCache` 时，`deleted=0` 但 notes 中无对应 uuid 的行属孤儿（异常中断产生），惰性清理即可，不影响正确性。

> 本期实现范围：**只建 `deleted`/`synced` 字段并在硬删时写入墓碑行**，`purgedUuids` 保持原样继续工作。真正的切换（让 SyncEngine 改读 note_meta）留作独立迁移任务，避免把同步链路改动混进本功能。

## 5. 建表与迁移（schema v4 → v5）

### 5.1 ⚠️ 建表代码有**两份**，必须同时改

`database_handler.dart` 存在两处重复的建表逻辑：

- `_createDBStatic`（`:535-568`）
- `_createDB`（`:571-607`）

**新增 `note_meta` 表必须两处都加**，否则某条建库路径会缺表，运行时报 `no such table`。这是本次最易漏的坑。

### 5.2 升级回调

`_onUpgrade`（`:624-637`）当前只处理 v3→v4。新增分支：

```dart
if (oldVersion < 5) {
  await db.execute('CREATE TABLE IF NOT EXISTS note_meta (...)');
  await db.execute('CREATE UNIQUE INDEX IF NOT EXISTS idx_note_meta_uuid ...');
  // … 其余索引同理，全部 IF NOT EXISTS
  Log.db.i('已创建表: note_meta');
}
```

**风险显著低于旧方案**：`CREATE TABLE IF NOT EXISTS` 幂等、**完全不 touch notes 表数据**，失败也不会损坏既有笔记。无需回填（空表 + 懒创建，见 §3.3）。

### 5.3 诊断工具自动覆盖

现有 dump/诊断逻辑按表名遍历（`:233-279` 的 `PRAGMA table_info` / `COUNT(*)`），新表自动被纳入，无需改动。注意 `payload` 是密文，诊断输出应比照 `sync_meta` 对敏感 value 的处理（`:223`/`:276` 只列 key 不展开）——**不要打印 payload 原文**。

## 6. 同步层：`items.meta` + per-note LWW

### 6.1 后端抽象扩展（`sync/sync_backend.dart`）

参考已有 `putJournalObject`/`getJournalObject`（`sync_backend.dart:216-219`）模式新增一对方法，默认空实现保持向后兼容：

```dart
/// 读写远端笔记元信息加密对象（items.meta）。
/// 单文件整体上传，内部按 note 逐条 LWW 合并（见 6.3）。
Future<void> putMetaObject(Uint8List ciphertext) async {}
Future<Uint8List?> getMetaObject() async => null;
```

### 6.2 三套后端实现（服务端零改动）

| 后端 | 实现方式 | 落点 |
|---|---|---|
| SafeServer | 复用 `_putResource`/`_getResource`（`safe_server_backend.dart:742-781`） | `PUT/GET /api/v2/resources/items.meta` |
| LocalFS | 复用 `putJournalObject`/`getJournalObject`（`local_fs_backend.dart:357/369`）写法 | `keyring/items.meta` |
| WebDAV | 复用 `putJournalObject`/`getJournalObject`（`webdav_backend.dart:689/714`） | `<userUrl>/safenotes-vault/items.meta` |

服务端已支持任意 `resources/<path>` 的 PUT/GET/DELETE（`server/go/internal/server/server.go:276-289`，Node.js 端同理），**服务端零改动**。

### 6.3 文件结构与合并算法

远端文件是**整体上传**（后端为文件粒度），但内容是 **per-note 条目**，每条自带 `updated_at`：

```json
{
  "v": 1,
  "notes": {
    "<noteUuid>": {
      "pinned": 1,
      "archived": 0,
      "color": null,
      "deleted": 0,
      "updated_at": 1755500000000,
      "payload": { "tags": ["work"], "extra": {} }
    }
  }
}
```

**合并算法（下载时）**：对每个 uuid，比较远端与本地的 `updated_at`，**取较新者**；本地不存在则插入。

这解决了旧方案"整文件 LWW"的缺陷：即使 A 设备整文件覆盖上传，B 设备下载后也只会用远端**较新的那些条目**覆盖本地，B 自己更新的条目因 `updated_at` 更大而保留，下次上传时带上。**两台设备改不同笔记不再互相丢失**。

> 注：`payload` 在本地是"加密后的字符串列"，在 `items.meta` 中可直接放**明文对象**（因为整个 `items.meta` 文件已被 AES-GCM 整体加密）。避免双重加密带来的密钥/nonce 管理复杂度。

### 6.4 加密与引擎集成

新增模块 `packages/core/lib/src/sync/note_meta_sync.dart`：

- 加密：`AES-GCM(dataKey, json)`，与 blob 同一把 `dataKey`（任意授权设备可解），复用 `SyncCrypto` 现有封装。
- 集成点：`sync_engine.dart` 的 `sync()` 流程中，**manifest 阶段之后**插入：
  1. 先 `getMetaObject()` → 解密 → per-note 合并入本地（本机先获知他端最新状态）；
  2. 若本地存在 `synced=0` 的 meta 行 → 序列化全量 → `putMetaObject()` 上传 → 成功后置 `synced=1`。
- **容错**：meta 同步失败只记日志/下次重试，**绝不抛异常中断笔记正文同步**。元数据永远是次要数据。

## 7. UI 层（lib/）

### 7.1 首页置顶排序（`lib/views/home.dart`）

`_sortAndStoreNotes`（`home.dart:289-312`）当前是纯内存排序（`readAllNotes()` 后 `..sort()`）。改为两级排序：

```dart
// pinned 恒在最前，其次按原有时间键
tmpNotes.sort((a, b) {
  final pa = metaOf(a.uuid).pinned, pb = metaOf(b.uuid).pinned;
  if (pa != pb) return pb.compareTo(pa);       // pinned 优先
  return sortAsc ? keyOf(a).compareTo(keyOf(b)) : keyOf(b).compareTo(keyOf(a));
});
```

保持现有 `PreferencesStorage.isSortByModified` 语义不变，只在最外层叠加 pinned 维度。

### 7.2 侧栏双端（`lib/widgets/home_navigation_rail.dart` + `lib/widgets/drawer.dart`）

桌面 Rail 与移动 Drawer 是两套独立 widget，**新增项与回调必须两边同步改**（易漏）：

- 「仅看星标」→ 置 `HomePageState._filterPinned`，过滤 `metaOf(uuid).pinned == 1`。
- 「按标签过滤」→ 打开标签选择弹窗（标签源自 `_metaCache` 聚合去重）→ 置 `_activeTag`。
- 沿用 `home.dart:603-630` 现有导航回调下传模式。

### 7.3 卡片角标与编辑器

- `note_card*.dart` / `note_tile*.dart`：pinned 加星标/置顶角标；有标签时可显示标签 chip。
- 编辑器：`lib/models/editor_state.dart` 扩展 tags 编辑；星标切换按钮直接调 `setNotePinned(uuid, bool)`。
- **关键**：这些操作只写 note_meta + 更新 `_metaCache`，**不得**走 notes 的 update 路径（§2.4、§3.2）。

### 7.4 偏好持久化（可选）

`lib/data/preference_and_config.dart`：持久化「仅看星标 / 当前标签」过滤态（`shared_preferences`）。

## 8. 笔记相关数据的长期表规划

### 8.1 判断准则（决定"进 payload"还是"建新表"）

| 数据特征 | 归属 | 原因 |
|---|---|---|
| 一对一的标量属性 | `note_meta` 明文列或 `payload` | 无需独立行，随 meta 一起读写 |
| **一对多**（一条笔记 N 条记录） | **独立表** | 塞 JSON 会无限膨胀、无法单条增删 |
| 需要**反向查询**（由 B 找 A） | **独立表** | JSON 无法反查 |
| 需要**独立生命周期**（可单独删除/GC） | **独立表** | 如附件的 blob 回收 |
| 有**自身属性**（不只是名字） | **独立表** | 如标签的颜色/父子层级 |

### 8.2 候选表清单

| # | 表 | 关系 | 何时需要 | 本期 |
|---|---|---|---|---|
| 1 | `note_meta` | 1:1 | 星标/标签/归档等元数据 | ✅ **本期建** |
| 2 | `attachments` | 1:N | 图片/文件附件——**最可能的下一个大功能** | 预留 |
| 3 | `note_revisions` | 1:N | 版本历史（防误删误改，加密笔记价值高） | 预留 |
| 4 | `note_links` | N:N | 双链/反向链接（Obsidian 风格） | 预留 |
| 5 | `notebooks` | 树形 | 多级笔记本/文件夹 | 预留 |
| 6 | `tags` + `note_tags` | N:N | 标签需要独立属性（颜色/重命名/层级）时才升级 | 暂放 payload |
| 7 | `reminders` | 1:N | 单笔记多提醒时才需要；单提醒放 payload 即可 | 暂放 payload |

### 8.3 各候选表要点

**2. `attachments`（优先级最高的预留）**

```sql
CREATE TABLE attachments (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  uuid       TEXT NOT NULL UNIQUE,
  note_uuid  TEXT NOT NULL,          -- 无 FK CASCADE，同 note_meta 理由
  blob_hash  TEXT NOT NULL,          -- 内容寻址，复用现有 blob 体系
  meta       TEXT,                   -- 加密 JSON: {filename, mime, size, width…}
  created_at INTEGER NOT NULL,
  deleted    INTEGER NOT NULL DEFAULT 0,
  synced     INTEGER NOT NULL DEFAULT 0
);
```

与现有 E2EE 架构天然契合：每个附件就是一个加密 blob，可直接复用 blob 内容寻址与 GC 机制。文件名属敏感信息，进加密 `meta`。**必须一对多，绝不能塞 payload。**

**3. `note_revisions`**：`(id, note_uuid, title, description, content_hash, created_at)`，title/description 沿用 notes 表的加密方式。需配套保留策略（如仅留最近 N 版 / M 天）以防库膨胀。

**4. `note_links`**：`(from_uuid, to_uuid, anchor)` + 两个方向的索引。反向链接查询是 N:N，JSON 完全无法支撑。

**5. `notebooks`**：`(id, uuid, parent_uuid, name(加密), order)`。若只需单层归类，`payload.notebook` 存 id 就够；**要树形展示/拖拽移动才值得建表**。

**6. `tags` 升级路径**：本期标签仅是 `payload.tags` 字符串数组。当需要"标签重命名（批量生效）/标签颜色/标签层级"时再升级为 `tags` + `note_tags`。
> 注意权衡：标签名敏感需加密，而**加密后 SQL 无法按标签名反查**，独立表的检索优势会大幅缩水。因此除非需要标签自身属性，否则**留在 payload 更划算**。

### 8.4 ⚠️ 走不通的方案：SQLite FTS 全文搜索

不要为搜索建 FTS 虚表。`title`/`description` 以密文存储，**FTS 无法索引密文**。当前搜索是内存遍历（`home.dart` 的 `_searchNote`），这是 E2EE 的固有约束。

若将来需要更强搜索，可选路径是「内存倒排索引」或「可搜索加密（SSE）」，均属独立课题，与本设计无关。

### 8.5 统一约定（所有未来新表共用）

1. 主键结构：`id INTEGER PRIMARY KEY AUTOINCREMENT` + `uuid TEXT NOT NULL UNIQUE`（对齐 notes/note_meta）。
2. **不加 FOREIGN KEY CASCADE**：墓碑需在父行消失后存活（§2.3）。
3. 同步三件套：`updated_at`（LWW）+ `synced`（脏标记）+ `deleted`（墓碑）。
4. 敏感文本统一进单个加密列（命名 `payload` / `meta`），不加 `enc_` 前缀。
5. 每张表配一个**加密 JSON 兜底列**，保证后续加字段无需迁移。
6. 缓存独立：新表用自己的内存缓存，**永不与 `_notesCache` 耦合**。
7. 建表语句记得写**两处**（§5.1）。

## 9. 改动文件清单

| 模块 | 文件 | 改动量 | 风险 |
|---|---|---|---|
| 新增模型 | 新增 `packages/core/lib/src/models/note_meta.dart` | 中 | 低 |
| 笔记模型 | `packages/core/lib/src/models/safenote.dart` | **零改动** | **0** |
| 本地 DB | `packages/core/lib/src/db/database_handler.dart`（建表×2 + v5 升级 + meta CRUD + `_metaCache`） | 中-大 | 低-中 |
| 后端抽象 | `packages/core/lib/src/sync/sync_backend.dart` | 小 | 低 |
| 后端实现 ×3 | `safe_server_backend.dart` / `local_fs_backend.dart` / `webdav_backend.dart` | 小 | 低 |
| meta 同步 | 新增 `packages/core/lib/src/sync/note_meta_sync.dart` | 中 | 低 |
| 同步集成 | `packages/core/lib/src/sync/sync_engine.dart` | 小 | 低（容错、不阻断） |
| 首页 | `lib/views/home.dart`（排序 + 过滤态） | 中 | 低 |
| 侧栏 ×2 | `home_navigation_rail.dart` + `drawer.dart` + 标签选择弹窗 | 中 | 低-中（双端一致） |
| 卡片 | `note_card*.dart` / `note_tile*.dart` | 小 | 低 |
| 编辑器 | `lib/models/editor_state.dart` + 编辑页 | 中 | 低 |
| 偏好 | `lib/data/preference_and_config.dart` | 小 | 低 |
| **notes 表 / blob 协议 / 服务端** | **无** | **0** | **0** |

**约 13-16 个文件。相比旧方案：notes 表与 `SafeNote` 模型完全不动，风险面显著缩小。**

## 10. 实施顺序建议

1. **阶段 1**：`NoteMeta` 模型 + note_meta 建表（两处）+ v5 升级 + CRUD + `_metaCache`。**先跑通迁移测试**。
2. **阶段 2**：首页置顶排序 + 卡片角标 + 编辑器星标按钮（无同步，可见效果）。
3. **阶段 3**：侧栏双端「仅看星标」+ 标签输入与「按标签过滤」。
4. **阶段 4**：`items.meta` 同步（后端抽象 → 三实现 → note_meta_sync → 引擎集成）。
5. **阶段 5（独立任务）**：`purgedUuids` → note_meta 墓碑迁移。

阶段 1-3 完全不碰同步链路；阶段 4 才引入同步，可独立回滚。

## 11. 验证计划

- `dart format` + `dart pub run import_sorter:main`（仅改动文件，禁止全仓库）。
- `flutter analyze`。
- `dart test packages/core/test`，重点：
  - **v4 老库升级 v5**：建表成功、notes 数据零损伤、空 note_meta 表可正常读；
  - 全新建库（`_createDB` 与 `_createDBStatic` **两条路径都要测**，防 §5.1 漏改）；
  - `payload` 加解密往返；
  - per-note LWW 合并（本地新/远端新/双方新/仅一方存在四种组合）；
  - 硬删写墓碑行 + 墓碑 GC。
- `flutter test`；改 UI 后 `flutter test integration_test/ -d windows`。
- `flutter build windows --debug`。
- **性能验证**：切换 pinned 时确认 `_notesCache` **未**失效（不发生全量重解密）——这是 §3 的核心收益，必须实测。
- 多设备手工验证：A 星标笔记1 / B 星标笔记2 → 双向同步 → **两者都应保留**（验证 per-note LWW 生效）。

## 12. 风险与红线

### 12.1 绝对红线（改动将导致全量 blob 失联）

**永不触碰**：`SafeNote.computeHash` / `toContentBytes` / `fromContentBytes` / blob AAD。

它们是 blob 的内容寻址身份锚点。本设计的全部价值就在于把元数据完全隔离在这条红线之外。

### 12.2 主要风险

| 风险 | 缓解 |
|---|---|
| **建表代码两份漏改一处**（§5.1） | 两条建库路径都写测试 |
| 元数据变更误改 `notes.updated_at`/`content_hash` | 代码评审重点；meta 写入路径与 notes 写入路径物理分离（§2.4） |
| 误加 FK CASCADE 导致墓碑被级联删 | 建表语句注释标注；§2.3 明确记录 |
| meta 缓存与 `_notesCache` 耦合导致重解密 | §11 性能实测卡口 |
| 双端导航（Rail/Drawer）漏改一边 | 两端同时改 + 集成测试覆盖 |
| note_meta 孤儿行 | 惰性 GC（§4.3），不影响正确性 |
| `payload` 密文被诊断工具打印 | 比照 `sync_meta` 敏感 value 处理（§5.3） |

### 12.3 已消除的旧风险

- ~~`ALTER TABLE` 加 13 列的主表迁移风险~~ → 改为 `CREATE TABLE IF NOT EXISTS`，不动 notes 数据。
- ~~整文件 LWW 导致多设备互相覆盖~~ → per-note LWW（§6.3）。
- ~~`tags` 明文落盘~~ → 进加密 `payload`。
- ~~需预留 13 个列以免返工~~ → `payload` + `extra` 兜底，加字段零迁移。
