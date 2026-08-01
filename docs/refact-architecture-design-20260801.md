# 重构设计方案（G-Set 删除集合 · 本地回收站 · 真删 · created_at 统一为 INT · 设备溯源字段）

- 文档版本：v3（设计评审稿，**未开始编码**；v3 吸收 2026-08-01 评审意见修订，修订明细见 §14）
- 撰写时间：2026-08-01
- 前身（已删除）：`delete-architecture-design-20260801.md`（v1 通用多端方案）、`delete-architecture-design-20260801-1.md`（v2.1 单用户简化版）。本文件取代并合并二者，吸收 Q7；v2 中吸收 Q8（设备溯源 `by` 字段、`manifest.items` 维持 map、字段命名统一、`deleted` 元数据化、`safe_notes` 预留删除三列）；v3 中吸收评审意见（R1–R6 及行号/引用修正，见 §14）。
- 适用范围：`lib/sync/*`、`lib/data/database_handler.dart`、`lib/models/safenote.dart`（+ 新增 `trash_note.dart`、`deleted_item.dart`、`deleted_meta.dart`）、`lib/utils/device_id.dart`（**已存在，复用**）、`lib/views/deleted_notes.dart`、`lib/views/note_view.dart`
- 目标读者：方案评审人（用户）
- **本文档仅为设计。代码改动见 §9 实施步骤，按任务 #15→#17→#16→#18→#19→#21 顺序在用户批准后执行。**

---

## 0. 设计前提（一切简化的根基）

| 编号 | 前提 | 推论 |
|---|---|---|
| **P1** | **单用户**。所有设备属于同一个人 | 不需要权限、多方仲裁、"谁的改动更重要"策略 |
| **P2** | **无协作、无同时编辑** | 不需要实时并发控制、精巧合并算法 |
| **P3** | **空间不值钱**，服务端与客户端都允许冗余存储 | 不需要 GC / 裁剪 / 过期回收；**所有基于时间窗的机制全部删除**；**元数据多存无害** |
| **P4** | **开发阶段**，无历史包袱 | **不写任何兼容与迁移代码**；DB 直接 v4 起步；服务端数据清空重来 |

### 0.1 关于 P2 的重要澄清（红线，必读）

> **「不存在同时编辑」不等于「不存在冲突」。**

同一个人在手机上改了笔记 X，又在电脑上改了同一条 X，中间没有联网——这不是"同时编辑"，但它**确实产生了内容分叉**，在移动场景下非常常见。

因此：
- **冲突检测机制必须保留**（现有 base-hash 三方合并，上一轮刚修复，不在本次改造范围）。
- P1/P2 只让**冲突处理策略**可以放松：两份都是你自己写的，**一律两份都留、让用户自己挑**，不需要 LWW 精巧裁决或自动文本合并。现有"冲突副本"机制正是如此，保持不变。

**若误以为"单用户 = 无冲突"而删掉冲突检测，会直接丢数据。**

---

## 1. 铁律（唯一验收标准）

| 编号 | 铁律 | 精确定义 |
|---|---|---|
| **D** | 不丢数据 | 任何时刻、任何分支、任何失败点，用户写下的内容必须至少存在于「某设备的活跃笔记」或「某设备的回收站」中，且有 UI 路径可取回 |
| **G** | 无幽灵笔记 | 用户主动删除的笔记，不得在任何设备上以**原身份**自行复活 |
| **R** | 机制不报废 | 任何中断、失败、并发、部分写入，都不得使后续同步进入永久错误、死循环或需人工重置才能恢复的状态 |

**冲突调和器**：当"该保留"与"该消失"打架时，**统一裁决为「移入本地回收站」**。回收站内容对 D 成立（在、可恢复），对 G 也成立（不回传、不复活）。

---

## 2. 核心思想

### 2.1 一句话

> **把「删除」建模成一个只增不减的 uuid 集合（G-Set），服务端与所有客户端各存一份，同步时求并集。
> 凡在集合里的 uuid，本地内容进回收站、远端索引里剔除。删除处理与内容对账彻底解耦。**

### 2.2 完整同步算法

```
──── 步骤 1：合并删除集合（纯集合运算） ────
   D = remote.deleted(uuid 集合)  ∪  local.deleted_items(uuid 集合)

──── 步骤 2：应用删除（对 D 中每个 uuid） ────
   本地 safe_notes 若存在  → 内容拷入 trash_notes，删除活跃行
   merged.items 若存在     → 剔除
   本地 deleted_items      → 回写 D 全集（镜像，含 metadata）
   merged.deleted          → 写入 D 全集（uuid → 元数据对象）

──── 步骤 3：对剩余 uuid（∉ D）做标准三态对账 ────
   仅远端有  → 下载新建
   仅本地有  → 上传
   两边都有  → hash 相同：跳过（顺带修复 syncedHash 基线）
              hash 不同：走现有 base-hash 三方冲突判定
```

**步骤 3 里没有任何一处出现"删除"字样**——这是本方案最重要的结构性收益。

### 2.3 为什么这样是对的：G-Set 的数学性质

`deleted` 是 **grow-only set（只增集合）**，最简单的 CRDT。并集运算满足：

| 性质 | 含义 | 带来的保证 |
|---|---|---|
| **幂等** | `D ∪ D = D` | 同一次同步重放任意次结果相同 → 崩溃重试天然安全 |
| **交换律** | `A ∪ B = B ∪ A` | 两台设备谁先同步都一样 → 无需并发协调 |
| **结合律** | `(A∪B)∪C = A∪(B∪C)` | 任意顺序、任意次数的部分同步，最终收敛到同一结果 |

**正确性不依赖执行顺序、不依赖是否成功、不依赖时间。**

### 2.4 两条不变量

整个删除架构的正确性可归结为两条，实施时写成运行时断言 + 测试断言：

- **INV-1**：`manifest.items 的 uuid 集合 ∩ manifest.deleted 的 uuid 集合 = ∅`（远端：索引与墓碑互斥）
- **INV-2**：`safe_notes.uuid ∩ deleted_items.uuid = ∅`（本地：活跃与墓碑互斥）

步骤 2 是唯一维护这两条不变量的地方。只要它正确，全局就正确。

---

## 3. 简化清单（相对 v2.1 / 当前墓碑实现）

| # | 现有机制 | 处置 | 依据 |
|---|---|---|---|
| 1 | `safe_notes.deleted`/`deleted_at`/`deleted_by` 列 + `idx_notes_deleted` 索引 | **保留为预留列（当前 G-Set 不使用，只为避免未来改表结构）**；`idx_notes_deleted` 索引保留 | — |
| 2 | `ManifestItem.deleted` / `deletedAt` 字段 | **删字段** | — |
| 3 | 30 天墓碑 GC（`_gcOrphanBlobs` / `skipGc` / `kTombstoneGcThresholdMs`） | **移出同步流程**（Q6） | P3 |
| 4 | `purged_uuids` 待清理列表（`getPurgedUuids` 等） | **废弃** | 职责被 G-Set 接管 |
| 5 | v1→v2 / v2→v3 迁移分支（`_upgradeDB` / `_upgradeDBStatic`） | **全删**，直接 v4（Q5） | P4 |
| 6 | `KeyringLedger.fromLegacyMeta` 及 7 个 legacy meta 键 | **全删**（Q5） | P4 |
| 7 | 删除-编辑冲突时以新 uuid 重建活跃笔记 | **简化为只进回收站**（Q1） | 单用户 |
| 8 | 版本闸门 / 一次性升级 / 路径隔离 | **全删**（Q2） | P4 |
| 9 | `deleted_uuids` 表（仅 uuid） | **改名 `deleted_items`**，存元数据不含 content/title（Q7） | debug 友好 |
| 10 | `safe_notes.created_at` TEXT（ISO） | **改 INTEGER（Unix 毫秒）**，与 `updated_at` 统一（Q7） | 消除类型不一致 |
| 11 | `readAllNotesIncludingDeleted` / `softDelete` / `hardDelete` / `restoreNote` / `readDeletedNotes` | **删除**，由 trash/deleted_items 全套方法取代 | — |
| 12 | DB 版本号 `3` | **升到 `4`** | — |
| 13 | `safe_notes` 缺设备溯源 | **新增 `created_by` / `updated_by`**（deviceId）（Q8） | 谁建/谁改可追 |
| 14 | `trash_notes` / `deleted_items` 缺设备溯源 | **新增 `created_by` / `updated_by` / `deleted_by`**（deviceId）（Q8） | 谁删可追，debug 不抓瞎 |
| 15 | `manifest.items` 用 `{uuid: {...}}` map | **维持 `{uuid: {...}}` map**（Q8 修订） | 与 `deleted` 同为 map，保持 manifest 文件内结构一致 |
| 16 | `manifest.deleted` 用 `uuid → timestamp` | **改为 `uuid → 元数据对象`**（含 `deletedBy` 等）（Q8） | 多存元数据，debug/审计 |
| 17 | `ManifestItem.hash` / `ManifestHeader.lastModifiedBy` | **改名 `contentHash` / `updatedBy`**，与本地 `content_hash` / `updated_by` 统一（Q8） | 命名一致 |
| 18 | `ManifestItem` 缺创建溯源 | **新增 `createdBy`**（Q8） | 谁建可跨端追 |

> **保留项（不要误删）**：
> - `SyncResult.deleted`（删除计数）与 `SyncActionType.delete`（删除事件）是**计数/事件类型**，与 `deleted` 字段解耦，**保留**。
> - `MetaKeys.dataKeyHistory`（Layer 3 修复依赖 `appendDataKeyHistory`/`getDataKeyHistory`）**保留**。
> - `SyncBackend` 的 GC 接口方法（`deleteBlob`/`listBlobs`/`deleteBlobSoft`/`listOrphanBlobs`/`purgeOrphans`）**保留但同步路径不再调用**（留给未来独立手动 GC）。
> - **`DeviceIdProvider`（`lib/utils/device_id.dart`）已存在**，所有 `by` 字段值直接复用它，**无需新增 meta 键**。

量化对比：

| 维度 | 墓碑实现（现状） | 本方案 |
|---|---|---|
| 入站判定分支 | 11 条 + GC 分支 | 3 步（删除只占 1 步） |
| 删除相关字段 | `safe_notes.deleted` + `ManifestItem.deleted/deletedAt` | 0（远端仅 `deleted` map） |
| 时间窗机制 | 30 天 GC | 0 处 |
| DB 迁移分支 | 3 段（v1→v2→v3） | **0 段** |
| `created_at` 类型 | TEXT（ISO）/ `updated_at` INTEGER（不一致） | **统一 INTEGER** |
| 设备溯源 | 仅 manifest `updatedBy` / header `lastModifiedBy` | **本地三表 + 远端 items + deleted 全链路 `by` 字段** |
| manifest items 结构 | `{uuid: {...}}` map | **维持 map（与 `deleted` 同结构）** |
| manifest deleted 内容 | `uuid → timestamp` | **`uuid → 元数据对象`** |

---

## 3.1 设备溯源字段（Q8 核心改动）

**deviceId 来源**：项目已有 `lib/utils/device_id.dart` 的 `DeviceIdProvider.instance.getDeviceId()`（首次同步时 `sync_service._deviceId` 已缓存）。它返回形如 `windows-<id>` / `android-<id>` 的设备标识，当前已用于填充 `manifest header.lastModifiedBy` 与 `item.updatedBy`。**本次不新增任何 meta 键**，`by` 字段值统一取自它。

**字段语义**（SQL 用 snake_case，JSON 用 camelCase，但**词根必须一致**）：

| 概念 | 本地列 | manifest 字段 | 值 |
|---|---|---|---|
| 创建者 | `created_by` | `createdBy` | deviceId |
| 最后修改者 | `updated_by` | `updatedBy` | deviceId |
| 删除者 | `deleted_by` | `deletedBy` | deviceId |

**写入时机**：
- `safe_notes.created_by` / `updated_by`：本地新建时均 = 本机 deviceId；本地编辑时 `updated_by` = 本机 deviceId；**从远端拉回**时填入远端 `createdBy` / `updatedBy`（跨端溯源）。
- `trash_notes.created_by` / `updated_by` / `deleted_by`：删除交易内写入，`deleted_by` = 本机 deviceId，`created_by`/`updated_by` 从原 `safe_notes` 行带入。
- `deleted_items` 三件套同上；`deleted_by` 在本地删除交易与远端 `deleted` 合并时都填。
- manifest `items[].createdBy/updatedBy`：本地构建 manifest 时从 `safe_notes.created_by/updated_by` 取；`deleted[uuid].deletedBy` 从删除交易/远端合并取。

> **`safe_notes` 预留 `deleted` / `deleted_at` / `deleted_by` 三列（Q8 修订）**：保留为**预留列，当前不使用**（G-Set 删除仍走"移出活跃行 + 墓碑"）。目的：避免未来想加软删/溯源时再改 DDL（开发期改表 = drop 重建 = 丢数据）。三列随 v4 一次性建好；`readAllNotes` 等保留 `WHERE deleted = 0`（恒真，作为未来软删钩子）。Dart `SafeNote` 模型暂不包含这三字段（存储层预留即可，未来要用时再加模型字段，属纯代码改动）。

---

## 4. 数据结构总览

### 4.1 全景

```
┌─────────────── 设备本地（SQLite: safenotes_sync.db, version 4）───────────────┐
│   safe_notes      活跃笔记          title/description 字段级加密              │
│   trash_notes     回收站内容        title/description 字段级加密   ★新增      │
│   deleted_items   墓碑集合(含元数据) 明文 uuid + 元数据          ★新增(Q7改名) │
│   sync_meta       键值元数据        keyring 账本 / manifest version 等        │
└──────────────────────────────────────────────────────────────────────────────┘
                    │  只有 safe_notes 参与 manifest 构建
                    │  trash_notes / deleted_items 中的【内容】永不上传
                    ▼
┌─────────────── 远端（WebDAV / SafeServer / 本地文件夹）───────────────────────┐
│   manifest.json      密文：明文 header + 加密体(items[] + deleted{})           │
│   blobs/<hash>       密文：单条笔记完整内容，内容寻址，永不删除                 │
│   backups/           manifest 覆盖前的环形备份                                │
│   journal/           P2 journal 加密副本（审计 + 灾备）                       │
└──────────────────────────────────────────────────────────────────────────────┘
```

### 4.2 本地 SQLite schema（v4 完整 DDL）

> **v4 是起始版本，无 onUpgrade 迁移代码**（P4/Q5）。`onCreate` 直接建下述四张表。
> 遇到 `oldVersion < 4` 时统一 drop 全部表后重建（开发期唯一处置方式，不做数据保全）。

#### 表 1：`safe_notes` —— 活跃笔记

```sql
CREATE TABLE safe_notes (
  _id           INTEGER PRIMARY KEY AUTOINCREMENT,
  uuid          TEXT    NOT NULL UNIQUE,   -- 身份，明文
  title         TEXT    NOT NULL,          -- 【加密】AES-GCM(dataKey)
  description   TEXT    NOT NULL,          -- 【加密】AES-GCM(dataKey)
  content_hash  TEXT    NOT NULL,          -- H(明文 title + description)
  created_at    INTEGER NOT NULL,          -- ★Q7：Unix 毫秒（原 TEXT ISO，已统一）
  updated_at    INTEGER NOT NULL,          -- Unix 毫秒
  created_by    TEXT    NOT NULL,          -- ★Q8：deviceId（创建设备）
  updated_by    TEXT    NOT NULL,          -- ★Q8：deviceId（最后修改设备）
  deleted       INTEGER NOT NULL DEFAULT 0,-- ★Q8 预留：当前不使用（G-Set 删除走移行+墓碑）
  deleted_at    INTEGER,                   -- ★Q8 预留：删除时间（ms），当前不使用
  deleted_by    TEXT,                      -- ★Q8 预留：删除设备 deviceId，当前不使用
  synced        INTEGER NOT NULL DEFAULT 0,
  synced_hash   TEXT                       -- 上次同步收敛时的 hash（冲突 base）
);
CREATE INDEX idx_notes_uuid   ON safe_notes(uuid);
CREATE INDEX idx_notes_synced ON safe_notes(synced);
CREATE INDEX idx_notes_deleted ON safe_notes(deleted);   -- ★Q8 预留索引
```

- ✅ `created_at` 由 TEXT 改为 INTEGER（Q7）
- ✅ 新增 `created_by` / `updated_by`（Q8）
- ✅ **保留 `deleted` / `deleted_at` / `deleted_by` 为预留列**（Q8 修订）：当前 G-Set 逻辑不使用，仅为避免未来改表结构；`idx_notes_deleted` 索引一并保留
- ✅ 其余字段完全不变（`synced_hash` 是上一轮 base-hash 修复引入的，保留）

**连带影响**：`readAllNotes` 等保留 `WHERE deleted = 0`（预留列恒为 0，条件恒真，作为未来软删钩子，无需改查询）；`SafeNote` 模型增 `createdBy`/`updatedBy`、但**暂不包含** `deleted`/`deleted_at`/`deleted_by`（存储层预留即可）。

#### 表 2：`trash_notes` —— 回收站内容 ★新增

```sql
CREATE TABLE trash_notes (
  _id            INTEGER PRIMARY KEY AUTOINCREMENT,
  original_uuid  TEXT    NOT NULL,   -- 删除前的 uuid，仅供展示/审计，恢复时不复用
  title          TEXT    NOT NULL,   -- 【加密】与 safe_notes 同一套字段级加密
  description    TEXT    NOT NULL,   -- 【加密】
  content_hash   TEXT    NOT NULL,
  created_at     INTEGER NOT NULL,   -- ★Q7：原笔记创建时间（ms，统一为 INT）
  updated_at     INTEGER NOT NULL,   -- 原笔记最后修改时间（ms）
  deleted_at     INTEGER NOT NULL,   -- 进入回收站的时间（ms，列表按此倒序）
  created_by     TEXT    NOT NULL,   -- ★Q8：deviceId（原笔记创建设备）
  updated_by     TEXT    NOT NULL,   -- ★Q8：deviceId（原笔记最后修改设备）
  deleted_by     TEXT    NOT NULL,   -- ★Q8：deviceId（删除操作所在设备）
  origin         TEXT    NOT NULL    -- 'local' | 'remote'
);
CREATE INDEX idx_trash_deleted_at ON trash_notes(deleted_at);
```

设计要点：
- **`original_uuid` 无 UNIQUE 约束**：同一 uuid 理论上可多次进入回收站（删→恢复发新 uuid→…），且允许冗余（P3）。
- **`title`/`description` 必须加密**：回收站是隐私数据，与活跃笔记同等对待。
- **`created_by` / `updated_by` / `deleted_by`**（Q8）：记录"谁建 / 谁最后改 / 谁删"，全部 deviceId。debug 时一眼看出删除来自哪台设备。
- **`origin`**：`local` = 本机删除；`remote` = 其他设备删除后同步传播过来。UI 可据此提示不同文案。
- **永不参与 manifest 构建**，`_buildLocalManifest` 只读 `safe_notes`。

#### 表 3：`deleted_items` —— 墓碑集合（含元数据）★新增（Q7 由 `deleted_uuids` 改名）

```sql
CREATE TABLE deleted_items (
  uuid         TEXT    PRIMARY KEY,   -- 明文身份（G-Set 元素）
  content_hash  TEXT,                 -- 内容 hash（debug 比对；本地删除时有值，远端合并来时无值）
  created_at    INTEGER,              -- 原笔记创建时间（ms，debug）
  updated_at    INTEGER,              -- 原笔记最后修改时间（ms，debug）
  deleted_at    INTEGER NOT NULL,     -- 进入删除集合的时间（ms）；诊断主字段
  created_by    TEXT,                 -- ★Q8：deviceId（创建设备，debug/审计）
  updated_by    TEXT,                 -- ★Q8：deviceId（最后修改设备，debug/审计）
  deleted_by    TEXT,                 -- ★Q8：deviceId（删除设备，debug/审计）
  origin        TEXT,                 -- 'local' | 'remote'（debug/审计，不参与判定）
  synced_hash   TEXT                  -- 可选，debug
);
```

设计要点（**Q7 + Q8 核心**）：
- **不存 `title` / `description`**——满足"只存元数据、不存 content（明文/密文都不存）"，避免回收站/墓碑泄漏隐私，同时保留足够 debug 信息。
- **元数据（含 `by` 字段）允许 NULL**：从远端 `deleted` 合并来的 uuid 只有 `uuid` + 部分元数据，本地删除的 uuid 才有完整元数据。
- **`deleted_at` 为 NOT NULL 诊断主字段**，但在 `deleted_items` 中**不参与任何判定逻辑**（只增集合，并集幂等，无需时间窗）。
- **没有 `pushed` 字段**：并集幂等，无需区分"已推送/未推送"。
- **只增不减**（G-Set 的本地镜像）。清空回收站不动这张表。
- 单条约 120 字节，10 万条约 12 MB，永不裁剪（P3）。

> **debug 价值**：出现"已删笔记复活"或"误删"类故障时，可查 `deleted_items` 看 uuid 是否在内、何时删除、谁删的（deleted_by）、content_hash 是否匹配、来自 local 还是 remote——这正是 Q7/Q8 要的"debug 时候不抓虾"。

#### 表 4：`sync_meta` —— 键值元数据（结构变更）

```sql
CREATE TABLE sync_meta (
  key    TEXT PRIMARY KEY,
  value  TEXT NOT NULL
);
```

| 键 | 内容 | 本次改造 |
|---|---|---|
| `keyring` | P2 Keyring 账本（唯一权威密钥态，JSON） | 不变 |
| `manifest_version:<providerKey>` | 按后端隔离的 manifest 版本号 | 不变 |
| `blob_reupload_pending` | dataKey 变更后待重传的 uuid 列表 | 不变 |
| `data_key_history` | Layer 3 历史 wrapped dataKey 归档 | **保留**（repair 依赖 `appendDataKeyHistory`/`getDataKeyHistory`） |
| `circuit_breaker_release:<providerKey>` | 熔断放行标志（v3 新增，§5.3 / Q10）：值 `'1'` 表示用户已「确认应用」被暂缓的删除，下次同步跳过阈值检测并应用 D 全集，成功后清除 | ✅ 新增 |
| `purged_uuids` | 旧待清理墓碑列表 | ❌ **废弃**，职责由 `deleted_items` 表承接 |
| `vault_id` / `encrypted_data_key` / `kdf_salt` / `key_fingerprint` / `key_version` / `vault_created_at` / `data_key_epoch` | P2 前的 legacy 散键 | ❌ **一并删除** |

> ⚠️ **关键修正（相对 v2.1 §4.2）**：v2.1 误将 `data_key_history` / `data_key_epoch` 一并列入删除。实际核查代码：
> - `MetaKeys.dataKeyHistory` 被 `appendDataKeyHistory`/`getDataDataKeyHistory` 使用 → **Layer 3 修复仍依赖，必须保留**。
> - `MetaKeys.dataKeyEpoch`（meta 键）与 `MetaKeys.vaultCreatedAt` 等 6 键仅被 `KeyringLedger.fromLegacyMeta` 读取，随该方法删除而一并删除。
> - 因此真正删除的 legacy 键共 **7 个**：`vault_id` / `encrypted_data_key` / `kdf_salt` / `key_fingerprint` / `key_version` / `vault_created_at` / `data_key_epoch`。`data_key_history` 保留。
> - **deviceId 不在此表**：由 `DeviceIdProvider` 提供（见 §3.1），无需持久化到 `sync_meta`。

### 4.3 本地 Dart 模型变化

```dart
// lib/models/safenote.dart —— SafeNote 模型
class SafeNote {
  final int? id;
  final String uuid;
  final String title;
  final String description;
  final String contentHash;
  // deleted / deleted_at / deleted_by：DB 预留列，模型暂不包含（未来要用时再加，纯代码改动）
  final DateTime createdTime;          // 模型层仍用 DateTime（UI 友好）
  final int updatedAt;                  // Unix 毫秒
  final String createdBy;               // ★Q8：deviceId
  final String updatedBy;               // ★Q8：deviceId
  final int synced;
  final String? syncedHash;

  // fromJson: created_at 由 int → DateTime
  // toJson: created_at 由 DateTime → int
  // copyWith / toString 同步删除 deleted，增 createdBy/updatedBy
}

// lib/models/trash_note.dart                                    ★新建文件
class TrashNote {
  final int? id;
  final String originalUuid;
  final String title;            // 加密
  final String description;      // 加密
  final String contentHash;
  final int createdAt;           // ms
  final int updatedAt;           // ms
  final int deletedAt;           // ms
  final String createdBy;        // ★Q8
  final String updatedBy;        // ★Q8
  final String deletedBy;        // ★Q8
  final TrashOrigin origin;      // enum { local, remote }
}

// lib/models/deleted_item.dart                                  ★新建文件
class DeletedItem {
  final String uuid;
  final String? contentHash;     // debug
  final int? createdAt;          // ms，debug
  final int? updatedAt;          // ms，debug
  final int deletedAt;           // ms，诊断主字段
  final String? createdBy;       // ★Q8
  final String? updatedBy;       // ★Q8
  final String? deletedBy;       // ★Q8
  final String? origin;          // debug/审计
  final String? syncedHash;      // debug
}

// lib/models/deleted_meta.dart                                  ★新建文件（manifest.deleted 值对象）
class DeletedMeta {
  final int deletedAt;
  final String deletedBy;        // deviceId
  final String? contentHash;
  final int? createdAt;
  final String? createdBy;
  final int? updatedAt;
  final String? updatedBy;
  final String? origin;
}
```

> **Q7 的 `created_at` 改 INT 对 UI 零影响**：`note_card.dart` / `note_tile.dart` / `home.dart` / `note_view.dart` 均通过 `note.createdTime`（DateTime）展示时间，模型内部 int↔DateTime 转换即可，调用方不变。

### 4.4 DB 层方法变化对照

| 方法 | 现状 | v4 |
|---|---|---|
| `readAllNotes()` | `WHERE deleted = 0` | **保留**（预留列恒为 0，未来软删钩子） |
| `readAllNotesIncludingDeleted()` | 读全部含墓碑 | ❌ 改名 `readActiveNotes()`（只读 safe_notes，无墓碑行了） |
| `readDeletedNotes()` | `WHERE deleted = 1` | ❌ 删除 → 由 `readTrashNotes()` 取代 |
| `softDelete(int id)` | 置 `deleted = 1`（现有签名参数为 `int id`，非 uuid） | ❌ 删除 → 由 `moveToTrash(uuid, origin, deviceId)` 取代 |
| `hardDelete(id)` | 删行 + 写 `purged_uuids` | ❌ 删除 → 拆为 `permanentDeleteFromTrash(id)` |
| `hardDeleteByUuid(uuid)` | GC 专用 | ❌ 删除（无 GC） |
| `restoreNote(id)` | `deleted` 改回 0 | ❌ 删除 → 由 `restoreFromTrash(id)` 取代（**发新 uuid**） |
| `getPurgedUuids()` / `removePurgedUuids()` / `_addPurgedUuid()` | meta 读写 | ❌ 删除 |
| `_parseUuidList()` / `_serializeUuidList()` | purged 专用 | ❌ 随 purged 删除 |
| `readNoteByContentHash()` | `WHERE ... AND deleted = 0` | **保留**（预留列） |
| `markAllForBlobReupload()` | `WHERE deleted = 0` | **保留**（预留列） |
| `reEncryptAllNotes()` | 调 `readAllNotesIncludingDeleted()` | 改调 `readActiveNotes()` |
| `insertNote(...)` | — | ✅ 增 `createdBy`/`updatedBy` 参数（默认本机 deviceId） |
| `updateNote(...)` | — | ✅ 更新 `updated_by` = 本机 deviceId |
| `moveToTrash(uuid, origin, deviceId)` | — | ✅ 事务：拷入 trash（带 created_by/updated_by/deleted_by）+ 记 deleted_items（带 by 字段）+ 删活跃行 |
| `restoreFromTrash(id)` | — | ✅ 发新 uuid 写回 `safe_notes`（created_by/updated_by = 本机 deviceId），删 trash 行 |
| `readTrashNotes()` | — | ✅ 按 `deleted_at` 倒序 |
| `permanentDeleteFromTrash(id)` | — | ✅ 仅删 trash 行 |
| `emptyTrash()` | — | ✅ 清空 trash 表，**不动 `deleted_items`** |
| `readDeletedItems()` / `mergeDeletedItems(Set)` | — | ✅ 集合读写（含 metadata 镜像回写） |

### 4.5 远端存储布局

```
<keyring root>/
├── manifest.json          # 密文二进制：明文 header + dataKey 加密体
├── blobs/
│   ├── <content-hash-1>   # 密文：单条笔记完整内容（含 title + description）
│   └── <content-hash-2>   # 内容寻址：相同内容的笔记共享同一 blob
├── backups/               # manifest 覆盖前的环形备份
└── journal/               # P2 journal 加密副本（审计 + 灾备）
```

本次改造**不改变目录布局**，只改变 manifest 内容结构与 blob 生命周期（不再删除）。

### 4.6 远端 manifest 结构

**明文 header**（新设备先读这部分拿 KDF 参数派生 MK）——**本次改造仅重命名字段**：

```jsonc
{
  "schemaVersion": 2,        // 1 → 2（协议不兼容标记；读到 ≠2 直接报错，不做转换）
  "version": 137,            // 每次成功 PUT +1
  "vaultId": "uuid-v4",
  "createdAt": 1753000000000,
  "updatedAt": 1754012345678,
  "keyFingerprint": "hex",
  "keyVersion": 3,
  "encryptedDataKey": "base64",
  "kdf": { "algorithm": "PBKDF2-HMAC-SHA256", "salt": "base64", "iterations": 210000 },
  "dataKeyWrap": "AES-256-GCM",
  "dataKeyEpoch": 1,
  "updatedBy": "android-abc123"   // ★Q8：由 lastModifiedBy 改名，与 item.updatedBy 一致
}
```

**加密体**（dataKey 加密，含全部笔记元数据）——**items 维持 `{uuid: {...}}` map（与 deleted 同结构），deleted 改为元数据对象**：

```jsonc
{
  "items": {                                   // 维持 map（与 deleted 同为 map，manifest 文件内结构一致）
    "uuid-a": {
      "contentHash": "sha256-hex",             // ★Q8：由 hash 改名，与本地 content_hash 一致
      "createdAt": 1753000000000,
      "createdBy": "ios-xyz",                  // ★Q8：新增，跨端溯源
      "updatedAt": 1754012345678,
      "updatedBy": "android-abc123",
      "contentSize": 1234,
      "blobKeyEpoch": 1                         // Layer 3：blob 由哪个 dataKey 纪元加密
    }
  },
  "deleted": {                                 // ★Q8：value 由 timestamp 改为元数据对象
    "uuid-x": {
      "deletedAt": 1754012345678,
      "deletedBy": "android-abc123",           // ★Q8：谁删的
      "contentHash": "sha256-hex",
      "createdAt": 1753000000000,
      "createdBy": "ios-xyz",
      "updatedAt": 1753999999999,
      "updatedBy": "android-abc123",
      "origin": "local"
    },
    "uuid-y": { "deletedAt": 1754019999999, "deletedBy": "ios-xyz", "origin": "remote" }
  }
}
```

`ManifestItem` 字段变化：

| 字段 | 现状 | v4 | 说明 |
|---|---|---|---|
| `hash` | ✅ | ❌→**改名 `contentHash`** | 与本地 `content_hash` 统一（Q8） |
| `createdBy` | ❌ | ✅ **新增** | 谁建的（跨端溯源） |
| `updatedAt` / `updatedBy` / `createdAt` / `contentSize` | ✅ | ✅ | — |
| `blobKeyEpoch` | ✅ | ✅ | Layer 3 保留 |
| `deleted` | ✅ bool | ❌ **删除** | 墓碑移出 items |
| `deletedAt` | ✅ int? | ❌ **删除** | 同上 |

`deleted` 集合 vs 旧墓碑的性质对比：

| 维度 | 旧墓碑 `items[uuid].deleted=true` | 新 `deleted` 集合 |
|---|---|---|
| 位置 | 混在 items 主表 | 独立字段，与 items 互斥（INV-1） |
| 内容 | 完整元数据 | **uuid → 元数据对象**（Q8 增强） |
| 参与冲突判定 | 是（8 处分支） | **否**（步骤 3 不知道它存在） |
| 参与 blob 引用 | 是 | **否** |
| 本地是否留行 | 是（`safe_notes` 整行） | **否**（内容在 trash，元数据在 deleted_items） |
| 时间戳用途 | GC 阈值判定（有 bug 风险） | **纯诊断**（无 bug 风险） |

> **`items` 与 `deleted` 同为 map（Q8 修订）**：用户要求同一 manifest 文件内结构一致，故 `items` 维持 `{uuid: {...}}` map（与 `deleted` 的 `uuid → 元数据` 同构），不使用数组。`Manifest.items` 保持 `Map<String, ManifestItem>`，`ManifestCrypto` 序列化/反序列化维持 map 形态，无需 `itemsByUuid` getter。

> **序列化合入（v3 修正：items 维持 map）**：`ManifestCrypto.serialize` 加密体改为 `{'items': manifest.items.map((k,v)=>MapEntry(k, v.toJson())), 'deleted': manifest.deleted.map((k,v)=>MapEntry(k, v.toJson()))}` —— **items 与 deleted 同为 `{uuid:{...}}` map**（与现有 sync_models.dart:728-731 的 map 序列化一致，非数组）；`deserialize` 反向（`items` 读 `Map<String,dynamic>` 缺省 `{}`，`deleted` 同）。`Manifest.copyWith` / `copyWithHeader` **必须透传 `items` 与 `deleted` 字段**。

### 4.7 blob 生命周期：同步流程不再删除任何 blob（Q6）

**同步流程中彻底移除**：`_gcOrphanBlobs()` 全套、listBlobs 枚举、孤儿计算、`skipGc` 保护判断、`kTombstoneGcThresholdMs`、对应 journal phase（`syncGcOrphan` 等）。

`SyncBackend` 接口上的 `deleteBlob` / `listBlobs` / `deleteBlobSoft` / `listOrphanBlobs` / `purgeOrphans` **方法保留**（各后端实现不动），但**同步路径不再调用**——留给未来的独立手动 GC 功能。

| 项 | 说明 |
|---|---|
| **依据** | P3 + Q6 |
| **安全收益** | 现有 `skipGc` 存在正是因为"GC 可能误删其他设备正在引用的 blob"是 P0 风险。不做 GC，风险从根上消失 |
| **数据收益** | 删除在服务端只是解除 items 引用，blob 内容仍在。即使本地回收站被清空，理论上仍可从 blob 捞回 |
| **对 `repairRemote` 的影响** | 已核对：遍历 `manifest.items`（sync_engine.dart:697 的 `if (item.deleted)` 分支随墓碑删除而移除），不遍历 blob 目录 → 不受影响 |
| **代价** | 服务端存储单调增长。每条笔记数 KB，删 1 万条约数十 MB，可接受 |
| **后续** | 需要时新增独立入口「清理服务端未引用数据」，走独立代码路径，**不得混入同步流程** |

### 4.8 数据冗余的四层兜底（P3 换来的安全边际）

同一条内容在删除后，最多同时存在于四处：

| 层 | 位置 | 何时消失 |
|---|---|---|
| 1 | 本机 `trash_notes` | 用户手动清空回收站 |
| 2 | 其他设备的 `trash_notes` | 该设备用户手动清空 |
| 3 | 远端 `blobs/<hash>` | **永不**（除非将来手动 GC） |
| 4 | 远端 `backups/` 中的历史 manifest | 环形覆盖 |

**铁律 D 只依赖第 1 层**；第 2/3/4 层是 P3 白送的额外保险。

### 4.9 字段命名统一对照表（Q8 总览）

| 概念 | 本地 SQLite | 远端 JSON（manifest） | 是否新增 | 说明 |
|---|---|---|---|---|
| 身份 | `uuid` | `uuid` | — | 一致 |
| 内容 hash | `content_hash` | `contentHash` | 改名 | 原 manifest `hash` → `contentHash` |
| 创建时间 | `created_at` (INT) | `createdAt` | — | 一致词根 |
| 创建者 | `created_by` | `createdBy` | 新增 | deviceId |
| 修改时间 | `updated_at` (INT) | `updatedAt` | — | 一致词根 |
| 修改者 | `updated_by` | `updatedBy` | 新增 | deviceId |
| 删除时间 | `deleted_at` (trash/deleted_items) | `deletedAt` (deleted 元数据) | — | 一致词根 |
| 删除者 | `deleted_by` (trash/deleted_items) | `deletedBy` (deleted 元数据) | 新增 | deviceId |
| 来源 | `origin` | `origin` | — | 一致 |
| 同步收敛 hash | `synced_hash` | —（远端用 `contentHash`） | — | 本地仅存 |
| blob 纪元 | — | `blobKeyEpoch` | — | 远端仅存（Layer 3） |
| blob 大小 | — | `contentSize` | — | 远端仅存（服务端大小） |
| manifest 头修改者 | — | `updatedBy`（原 `lastModifiedBy`） | 改名 | header 与 item 词根统一 |

> 命名原则：**SQL 用 snake_case、JSON 用 camelCase，但词根（created/updated/deleted/by/at/hash）必须一致**。改动只在词根层面消除不一致，不引入新的歧义字段。

---

## 5. 同步流程详解

### 5.1 本地删除（用户点"删除笔记 X"）

**单个 SQLite 事务，顺序不可调换：**

```
BEGIN TRANSACTION
  1. INSERT INTO trash_notes
       ← 从 safe_notes 完整拷贝 X（加密 title/description），
         created_by/updated_by 带入原行值，deleted_by = 本机 deviceId，origin='local'
  2. INSERT OR REPLACE INTO deleted_items
       (uuid, content_hash, created_at, created_by, updated_at, updated_by,
        deleted_at, deleted_by, origin, synced_hash)
       ← X 的全部元数据 + by 字段，deleted_at=now，deleted_by=本机 deviceId，origin='local'
  3. DELETE FROM safe_notes WHERE uuid = X
COMMIT
```

- 先写 trash 再删活跃行：事务若失效，最坏是"两处都有"（可自愈），**绝不会两处都无**（守 **D**）。
- 三步同事务：绝不会"笔记删了但墓碑丢了"（守 **G**）。
- **不触发网络**，离线可用。

### 5.2 同步执行序（含失败点）

```
① GET manifest（含 ETag）
      失败 → 整体中止，本地零变更 → 下次重来（幂等）

② D = remote.deleted(uuid 集合) ∪ local.deleted_items(uuid 集合)

③ 熔断检查：|D ∩ 本地活跃 uuid| 超阈值 → 见 §5.3

④ 应用删除
      本地：D 中 uuid 若在 safe_notes → 拷入 trash(origin='remote', deleted_by 取远端 deletedBy) + 删活跃行
      本地：deleted_items      ← D 全量镜像回写（含 metadata；远端来的缺省填 deleted_at/deleted_by）
      远端草稿：merged.items 剔除 D 中所有 uuid；merged.deleted = D（uuid → 元数据对象）

⑤ 三态对账（仅对 ∉ D 的 uuid）：下载 / 上传 / 跳过 / 冲突副本
      下载新建时填 created_by/updated_by = 远端 item.createdBy/updatedBy
      单条失败 → 隔离该 uuid（沿用 failedNoteUuids），不影响其余

⑥ PUT manifest（ETag 乐观锁）
      412  → 重新 GET，回到 ②（并集可交换，重算安全）
      失败 → local.deleted_items 已含 D，下次重新并集重推（幂等）
      成功 → 【无需任何结算动作】
```

**⑥ 成功后不需要做任何事**——"PUT 成功才翻转 pushed"那套状态机连同它的边缘情况一起消失了。

### 5.2.1 D 集合元数据合并优先级（v3 定案，Q9）

`deleted_items` 表与 `manifest.deleted` 对同一 uuid 各持一份元数据。合并时可能出现「本地先删、远端后传播」或「远端先传播、本地后删」两种交错，直接 `INSERT OR REPLACE` 会让后写者覆盖先写者，导致 `deleted_by` / `deleted_at` / `origin` 丢失「首次删除者」信息（Q8 溯源失真）。

**合并规则（唯一权威）——远端优先、本地缺省填充**：

```
对 D 中每个 uuid：
  remoteMeta = remote.deleted[uuid]      // 全局真相（跨设备一致）
  localMeta  = local.deleted_items[uuid] // 本地镜像（可能缺失或滞后）

  合并结果 deleted_meta[uuid] = {
    deletedAt:  remoteMeta?.deletedAt  ?? localMeta?.deletedAt  ?? now,
    deletedBy:  remoteMeta?.deletedBy  ?? localMeta?.deletedBy  ?? deviceId,
    contentHash: remoteMeta?.contentHash ?? localMeta?.contentHash,   // debug，可为空
    createdAt:  remoteMeta?.createdAt  ?? localMeta?.createdAt,
    createdBy:  remoteMeta?.createdBy  ?? localMeta?.createdBy,
    updatedAt:  remoteMeta?.updatedAt  ?? localMeta?.updatedAt,
    updatedBy:  remoteMeta?.updatedBy  ?? localMeta?.updatedBy,
    origin:     remoteMeta?.origin      ?? localMeta?.origin      ?? 'local',
  }
```

- **`deletedBy` / `deletedAt` 取远端值（首次发起删除的设备），本地删除交易只填充「远端缺失」的字段**。`moveToTrash` 写 `deleted_items` 时若该 uuid 已有远端传播的墓碑，保留远端 `deleted_by`/`deleted_at`，仅补本地 `origin='remote'` 或 `='local'`（按删除来源）。
- **`deleted_items` 表用 `INSERT`（遇冲突按上述规则更新缺失字段），不用无条件 `INSERT OR REPLACE`**，避免整行覆盖丢失远端溯源。
- 该规则同时约束 `merged.deleted`（步骤 2 写入 D 时）与本地 `deleted_items` 回写，保证两边一致。

### 5.3 唯一保留的安全阀：入站删除熔断

```
inboundDeleteCount = |D ∩ 本地活跃 uuid|
阈值 = max(20, 本地活跃总数 × 30%)

超阈值时：
  - 本次同步【完全跳过这批 uuid 的一切处理】
    （不移入 trash，不从 merged.items 剔除，不写 merged.deleted）
  - 记录 journal + UI 提示："检测到 N 条笔记的删除记录，已暂缓应用"
  - 用户可在设置页点「确认应用」：设置放行标志并立即同步一次（见下）
  - 不点也无妨：下次同步重新判定（幂等保证）
```

**放行机制（v3 定案，Q10）——「确认应用」= 设标志 + 去阈值 + 立即同步一次**：

1. **持久化标志**：`sync_meta` 新增键 `circuit_breaker_release:<providerKey>`，值为 `'1'`。
2. **用户点「确认应用」**：写入标志 → 调用 `SyncService.instance.sync()` 立即触发一次同步。
3. **本次同步**：读取标志 → **跳过熔断检查（阈值检测失效，直接应用 D 全集）** → 正常执行步骤 2（含被暂缓批次）→ PUT 成功后**清除标志**。
4. **标志清除时机**：只在「本次同步成功完成」后清除；同步失败则保留，下次同步继续放行——用户意图不被吞。
5. **幂等**：被放行的 uuid 应用后已移入 trash / 从 items 剔除，不再属于「活跃 ∩ D」，后续同步自然不再触发熔断。标志是一次性的，无需二次确认。

- **跳过整批处理而非只跳过本地删除**：本地与远端状态**都不变**（除非用户在窗口内编辑被暂缓的笔记），下次重来完全等价，不产生中间态。
- **只熔断入站，不熔断出站**：用户主动清空 500 条是明确意图，拦截反而是 bug。
- **不参与正确性推导**——即使整个删掉，D/G/R 依然成立。
- **表述修正（v3）**：熔断期间「状态完全未变」严格限定于「被暂缓的 uuid 未被本地编辑/上传」的情形。若用户编辑了被暂缓的笔记，其 `updatedAt`/hash 会变（属于本地正常编辑，不违反幂等，下次同步仍会判定）。

### 5.4 从回收站恢复

```
恢复 trash 中某条（id） → 生成【全新 uuid Y】写入 safe_notes
                      （created_by/updated_by = 本机 deviceId，syncedHash = null）
                      → 删除该 trash 行
                      → 原 uuid 保持在 deleted_items 中，永久死亡
```

**为什么必须发新 uuid**：原 uuid 在 D 中，而 D 只增。即使本地把它从 `deleted_items` 删掉，下次同步 `D = remote.deleted ∪ local` 又会并回来，步骤 2 立刻再次把它移入回收站——**恢复会被自动撤销**。发新 uuid 是 G-Set 的必然推论，逻辑自洽。

### 5.5 清空回收站

只删 `trash_notes` 行，**`deleted_items` 保持不动**，防复活能力不受影响（守 **G**）。

---

## 6. 边缘情况清单

格式：**场景 → 判定 → 动作 → 守则**。

### 6.1 删除与编辑的交织

| # | 场景 | 判定 | 动作 | 守则 |
|---|---|---|---|---|
| E01 | A 删 X，B 无改动 | X ∈ D | B **若本地持有 X 明文** → 移入回收站；**若 B 从未持有 X**（冷启动/从未下载）→ 只写 `deleted_items` 墓碑，trash 无行，回收站 UI 展示墓碑记录（见 E36） | G |
| E02 | A 删 X，B 离线改了 X | X ∈ D（**优先于内容对账**） | B 把改动后的完整内容移入回收站（origin='remote', deleted_by=远端 deletedBy），用户可自行恢复为新笔记 | D,G |
| E03 | A 删 X，B 也删 X | 并集去重 | 幂等，无额外动作 | R |
| E04 | A 改 X，B 删 X，A 先同步 | B 的 deleted_items 含 X → X ∈ D | X 从远端剔除；A 下次同步时 X ∈ D → A 的（含改动的）X 进 A 的回收站 | D,G |
| E05 | A 删 X 后立刻恢复（同步前） | 恢复发新 uuid Y | X 从远端剔除，Y 正常上传 | G |
| E06 | A 删 X 并同步后再恢复 | 同上 | Y 作为新笔记上传，X 永久死亡 | G |
| E07 | removed 裁剪导致记录不完整 | 已消失（P3 不裁剪） | — | — |

> **E02 裁决说明（Q1）**：不再以新 uuid 重建活跃笔记，改为整体进回收站。代价：B 上的编辑不会自动出现在活跃列表，需去回收站手动恢复。收益：**「凡在 D 中的 uuid 一律进回收站」成为无例外铁则**，步骤 2 不需要任何子分支。

### 6.2 同步中断与失败

| # | 场景 | 判定 | 动作 | 守则 |
|---|---|---|---|---|
| E08 | blob 上传成功，manifest PUT 失败 | — | 远端多几个未引用 blob；本地未变；下次重来。**因不做 GC，孤儿 blob 无害且永久保留** | R |
| E09 | PUT 成功但 pushed 翻转前崩溃 | 已消失（无 pushed 状态） | — | — |
| E10 | 乐观锁 412 并发冲突 | 重新 GET → 重新并集 → 重新 PUT | 并集可交换，谁先谁后都收敛 | R |
| E11 | 删除事务中途失败 | SQLite 事务原子性 | 即使异常出现"活跃有 X + deleted_items 有 X"，**下次同步步骤 2 自动把 X 移入 trash 修复**（INV-2 自愈） | D,R |
| E12 | blob GC 失败 | 已消失（不做 GC） | — | — |
| E13 | DB 迁移失败 | 已消失（无迁移代码，见 §7） | — | — |
| E14 | 网络在 PUT 中断，结果未知 | 下次 GET 看实际状态 | manifest 全量覆盖 + 并集幂等，重放安全 | R |

### 6.3 服务端与环境异常

| # | 场景 | 判定 | 动作 | 守则 |
|---|---|---|---|---|
| E15 | 服务端被清空 / 首次同步 | `remote.deleted` 空 → D = 本地墓碑集 | 本地活跃全部 ∉ D → **全部上传**（自动正确，无需安全阀） | D |
| E16 | 服务端回滚（本机删过的） | 旧 deleted 少几条，`local.deleted_items` 补齐 → 仍在 D | 从 items 剔除并 PUT，**自动修正服务端** | G |
| E17 | 服务端回滚（**其他设备删的、本机从不知情**） | 该 uuid ∉ D（信息在服务端丢了） | 本机会下载它 → **短暂复活**。但删过它的设备下次同步再次并入 D → **最终收敛为删除**。属服务端数据丢失，客户端在信息缺失下无法阻止，**可自愈** | R（有损但收敛） |
| E18 | 连到错误的服务器 | 那个库的 deleted 不含本机 uuid | 全部上传，不会误删 | D |
| E19 | manifest 解密失败 | 走现有自愈/重建分支 | 与删除逻辑完全解耦 | R |
| E20 | 判定 bug 导致批量误删 | 熔断（§5.3） | 降级为提示 | D |
| E21 | 新设备冷启动 | 本地空 → D = remote.deleted | 全量下载 ∉ D 的条目；D 中 uuid 因本地无行而无操作；`deleted_items` 一次性建立完整镜像 | — |
| E22 | 设备重装（`deleted_items` 随本地库丢失） | 首次同步从 `remote.deleted` 拉回全集 | **镜像自动重建**——这正是"服务端也存一份"的冗余价值（P3） | G |

> **E17 是唯一"有损"场景**，损失形式是"短暂复活后自愈"，不是数据丢失。

### 6.4 回收站自身

| # | 场景 | 动作 | 守则 |
|---|---|---|---|
| E23 | 手动清空回收站 | 只删 trash 行，`deleted_items` 保留，防复活继续有效 | G |
| E24 | 回收站内容会不会被同步上去 | `_buildLocalManifest` 只读 `safe_notes` → 永不上传、不参与冲突、不产生 blob 引用 | G |
| E25 | 从回收站恢复 | 发新 uuid（§5.4），原 uuid 永久死亡 | D,G |
| E26 | 恢复后又删除 | 新 uuid 走标准删除流程 | G |
| E27 | 回收站内容与某活跃笔记 hash 相同 | blob 引用只看 items，无影响 | R |
| E36 | **删除传播到本机无明文的设备**（v3 新增，Q11） | 步骤 2 只在「本地 `safe_notes` 有该 uuid 行」时拷入 trash；无明文则只写 `deleted_items` 墓碑，**trash 无行**。回收站 UI 分两区：①「内容」区读 `trash_notes`（可恢复/可清除）；②「墓碑记录」区读 `deleted_items`（仅显示"已被 `<deleted_by>` 于 `<deleted_at>` 删除"，无内容、不可恢复、可单独清除墓碑行）。目的：用户看到"笔记已在其他设备被删除"而非神秘消失；内容安全不受影响（铁律 D 只依赖删除发起设备的 trash，§4.8 第 1 层） | D,G |

### 6.5 与既有机制的交互

| # | 场景 | 处置 |
|---|---|---|
| E28 | 冲突副本机制 | 与删除正交。`_preserveConflictCopy` 中 `if (loserItem.deleted) return;`（sync_engine.dart:1298）删除 |
| E29 | 冲突副本标题序号 | 现有 `标题 (冲突副本 N·设备ID)` **保持不变** |
| E30 | 密钥纪元变更 / `pending_reupload` | 与删除无关；trash 中笔记不参与重传 |
| E31 | `repairRemote` | 遍历 `manifest.items`（sync_engine.dart:697 的 `if (item.deleted)` 分支删除），不体检孤儿 blob |
| E32 | Journal 审计 | 删除/记录 `delete_local` / `delete_inbound` / `trash_restore` / `trash_empty` 四类事件；**移除 blob GC 相关的 `syncGcOrphan` 等 phase** |
| E33 | `created_at` 改 INT | SafeNote 模型内部 int↔DateTime 转换，UI 零改动（Q7） |
| E34 | `deleted_items` 元数据（含 by 字段） | debug 时查 uuid/content_hash/origin/deleted_by，定位复活/误删（Q7+Q8） |
| E35 | `by` 字段跨端溯源 | 拉回的笔记 `created_by/updated_by` 填远端 `createdBy/updatedBy`；删除传播时 `deleted_by` 填远端 `deletedBy`（§5.1/§5.2） |

---

## 7. 开发期一刀切策略（Q2 + Q5 裁决）

**不写任何兼容与迁移代码，不做 fallback，不支持新旧共存。**

| 对象 | 策略 |
|---|---|
| **服务端数据** | 部署新版前**清空数据目录**（manifest + blobs + backups + journal）。不写迁移代码 |
| **manifest 协议** | `ManifestItem` 直接删 `deleted`/`deletedAt`；加密体直接加 `deleted` map；`schemaVersion` = 2；`items` **维持 `{uuid:{...}}` map**（与 `deleted` 同构，Q8 定案，非数组）；`hash`→`contentHash`、`lastModifiedBy`→`updatedBy`、`createdBy` 新增。**读 manifest 后必须校验 `schemaVersion == 2`，≠2 直接报错中断**（不兼容旧数据；实现点见 §9 步骤 4） |
| **本地 DB** | **直接 v4 起步**。`onCreate` 建四张表；`onUpgrade` 对 `oldVersion < 4` 一律 **drop 全部表 + 重建**，不保全数据 |
| **删除的迁移代码** | `_upgradeDB` 的 v1→v2 分支、v2→v3 分支；`_upgradeDBStatic`（测试）的对应分支；`KeyringLedger.fromLegacyMeta` 一次性转换；`MetaKeys` 中 7 个 legacy 键常量 |
| **旧客户端** | 不共存。开发期所有设备一起升级 |

> 开发者本机原有测试数据会在升级时清空，需重新造数据——这是 Q5 明确接受的代价，换来 `database_handler.dart` 中约 40 行迁移代码与全部 legacy 常量的彻底消失。

---

## 8. 铁律对照证明

### D（不丢数据）— 穷举内容可能消失的路径

| 路径 | 保底 |
|---|---|
| 本地删除 | 事务内先写 trash 再删活跃行 |
| 入站删除传播 | 同上（步骤 2 统一处理） |
| 删除-编辑冲突（E02） | 编辑后的完整内容进 trash，可恢复 |
| 服务端为空/回滚/连错 | 那些 uuid ∉ D → 走上传分支（E15/E16/E18） |
| 未同步的新建笔记 | ∉ D → 上传（步骤 3） |
| 判定 bug 批量误删 | 熔断（§5.3）+ 内容仍在 trash |
| 同步任何一步失败 | 所有失败点均不产生"无备份的内容删除" |
| （额外）本机 trash 也被清空 | 远端 blob 永不删除（§4.7/4.8），理论上仍可捞回 |

**不存在任何一条路径，会在没有 trash 备份的前提下删除内容。**

### G（无幽灵笔记）

| 复活路径 | 拦截点 |
|---|---|
| 已删 uuid 从远端被下载 | 步骤 2 先于步骤 3，D 中 uuid 已从 merged.items 剔除，步骤 3 看不到它 |
| 已删 uuid 被本机重新上传 | 本地 `safe_notes` 无此行，`_buildLocalManifest` 不可能构造出它 |
| 回收站内容被上传 | trash 不参与 manifest 构建 |
| 恢复导致原 uuid 复活 | 强制发新 uuid，且 G-Set 保证原 uuid 无法移出 D |
| 服务端回滚导致复活 | 本机墓碑镜像补齐并集，自动修正（E16）；E17 已知有损但收敛 |
| 新旧客户端互相复活 | P4 一刀切，不共存 |

### R（机制不报废）

| 风险 | 缓解 |
|---|---|
| 中断后状态不一致 | 本地变更单事务；无跨网络状态机；INV-2 每次同步自愈 |
| 重放不幂等 | G-Set 幂等 + manifest 全量覆盖 + 内容寻址 blob |
| 并发写覆盖 | ETag 乐观锁 + 重试；并集可交换，重算永远安全 |
| 单条笔记失败拖垮全局 | 沿用 `failedNoteUuids` 隔离 |
| 无限循环 | D 只增且删除处理先于对账 → 已删 uuid 单向消失，不可能被加回 |
| 结构无限膨胀 | P3 接受；`deleted` 仅元数据，10 万条约 12 MB |
| 迁移代码引入的历史包袱 | P4 全删，无迁移分支即无迁移 bug |

---

## 9. 实施步骤

| 步骤 | 内容 | 关联任务 |
|---|---|---|
| 1 | DB v4：`onCreate` 建四张表（`created_at` INTEGER、`created_by`/`updated_by` 在 safe_notes、`created_by`/`updated_by`/`deleted_by` 在 trash/deleted_items）；`onUpgrade` 一律 drop 重建；**删除全部 v1→v2 / v2→v3 迁移分支与 7 个 legacy meta 键**；版本号 3→4 | #15 |
| 2 | 模型：`SafeNote` 删 `deleted`、增 `createdBy`/`updatedBy`；新增 `TrashNote` / `DeletedItem` / `DeletedMeta`；`created_at` int↔DateTime 转换 | #15 |
| 3 | DB CRUD：新增 trash / deleted_items 全套（含 by 字段填充）；`insertNote`/`updateNote` 填 by 字段；删除 §4.4 表中标 ❌ 的旧方法；`readAllNotesIncludingDeleted`→`readActiveNotes` | #17 |
| 4 | manifest 模型：`ManifestItem` 删 `deleted`/`deletedAt`、**`hash`→`contentHash`**、**新增 `createdBy`**；`ManifestHeader.lastModifiedBy`→**`updatedBy`**；`Manifest` 加 `Map<String,DeletedMeta> deleted`（items 维持 `Map<String,ManifestItem>`）；`copyWith`/`copyWithHeader` 透传；`ManifestCrypto` 序列化 items(map) + deleted 元数据；`Manifest.empty` schemaVersion=2。**新增 schemaVersion 校验（R2 定案）**：在 `sync_service.sync()` 与 `repairRemote()` 的 manifest `deserialize`/`deserializeHeaderOnly` 之后校验 `schemaVersion == 2`，≠2 抛同步错误（"manifest 协议版本不符，请清空服务端数据重来"）并中断，不解析、不转换、不兼容旧数据 | #16 |
| 5 | `sync_engine`：实现 §2.2 三步算法；**删除**墓碑分支、`_gcOrphanBlobs` 全套与 `skipGc`/`kTombstoneGcThresholdMs`、purged 逻辑、`_preserveConflictCopy` 的 deleted 早退、`repairRemote` 的 `if (item.deleted)`、`_itemsEqual` 的 deleted 比较；`repairRemote` 维持 `for (entry in items.entries)` 遍历；合并/对账维持 `Map<String,ManifestItem>` 按 uuid 取用；`_buildLocalManifest` 填 `createdBy`/`updatedBy`（从 safe_notes 取）；拉回笔记填 `created_by`/`updated_by`；删除交易填 `deleted_by`；`readActiveNotes` 替换。**D 过滤注入 `_mergeAndTransfer`（v3 明确实现位置）**：参照现有 `purgedSet` 模式——计算 D 后，对 `allUuids` 中 ∈ D 的 uuid 在「仅远端有」「仅本地有」「双方都有」三分支统一跳过并**不加入 mergedItems**（`merged.deleted = D` 按 §5.2.1 规则写入，不依赖遍历）；**`_hasEffectiveChange` 增加 `merged.deleted` 与 `remote.deleted` 的键集 + 条目比较**（防"远端 deleted 回滚且 items 恰好一致"时漏 PUT）；熔断放行标志读写（§5.3 Q10，`sync_meta` 键） | #16 |
| 6 | UI：`note_view.dart` 的 `softDelete`→`moveToTrash`；`deleted_notes.dart` 改读 trash、恢复走新 uuid、清空走 `emptyTrash`；回收站展示 `deleted_by`/`deleted_at` | #18 |
| 7 | 测试（§10） | #19 |
| 8 | `flutter analyze` 零 error/warning + 全量测试 + CHANGES 日志 | #21 |

**步骤 4、5 必须一起合入**，中间态不可用。步骤 5 预计是**净删代码**。

---

## 10. 测试清单

1. 本地删除 → trash 有完整内容（含 `created_by`/`updated_by`/`deleted_by`）、`safe_notes` 无行、`deleted_items` 有 uuid + 元数据（§5.1）
2. 同步后远端 `items` 无该 uuid、`deleted` 含该 uuid 且为元数据对象，**INV-1 成立**
3. `manifest.items` map 往返：序列化→反序列化后 uuid 键集与字段完整一致
4. `manifest.deleted` 元数据对象往返：含 `deletedBy`/`contentHash`/`createdBy` 等
5. PUT 失败后重试 → 状态收敛，无重复无丢失（E08/E14）
6. 跨设备删除传播：A 删 → B 同步 → B 的 trash 有内容且 `deleted_by` = A 的 deviceId（E01/E02）
7. 删除-编辑冲突：B 离线改 → 上线后完整改动进 trash（E02）
8. 服务端回滚（手工替换旧 manifest）→ 墓碑补齐并集，已删 uuid 不复活且远端被修正（E16）
9. 服务端清空 → 全部上传，零入站删除（E15）
10. 新设备冷启动 → `deleted_items` 完整建立镜像（E21）
11. 设备重装 → 镜像从远端 `deleted` 自动重建（E22）
12. 熔断：构造超阈值入站删除 → 本次完全跳过且状态零变更，再次同步等价（§5.3）
13. 恢复发新 uuid，原 uuid 不复活（E25）
14. 清空回收站后 `deleted_items` 仍拦截复活（E23）
15. 跨端溯源：拉回笔记的 `created_by`/`updated_by` = 远端 `createdBy`/`updatedBy`
16. **INV-1 / INV-2 不变量断言**：随机化操作序列后始终成立
17. **并集幂等性**：同一次同步连续执行 3 次，结果完全一致
18. **顺序无关性**：A→B 与 B→A 两种同步顺序，最终状态一致（交换律）
19. **blob 永不减少**：任意删除操作后断言远端 blob 数量单调不减（§4.7）
20. longrun 长期库：连跑 N 代删除/恢复/编辑混合，断言 `活跃数 + trash 数` 守恒、`deleted` 集合单调增、无增殖

**v3 补充（对应评审 R2–R6，Q9–Q11）：**

21. **schemaVersion 校验**：构造 schemaVersion=1 的旧 manifest（items 含 `deleted=true` 墓碑）→ 同步报错中断、本地零变更、不解析（R2）
22. **熔断放行全流程**：构造超阈值入站删除 → 本次跳过且零变更 → 点「确认应用」写入标志 + 立即同步 → 该批被应用（进 trash）→ 标志清除 → 后续同步不再熔断（R3/Q10）
23. **溯源优先级**：A 删 X 并同步 → B 同步收到远端墓碑 → B 再删本地残留 X → 断言 `deleted_items` / `manifest.deleted` 的 `deleted_by` 仍 = A（远端优先，§5.2.1）（R4/Q9）
24. **删除传播到无明文设备**：B 从未持有 X → B 同步后 trash 无 X 行、`deleted_items` 有 X 墓碑 → 回收站「墓碑记录」区正确显示（R5/Q11）
25. **E17 复活窗口内编辑**：服务端回滚导致 X 短暂复活 → 用户在窗口内编辑 X → 下次同步 X ∈ D → 编辑后完整内容进 trash 不丢
26. **远端 deleted 回滚触发 PUT**：构造 remote.deleted 缺一条、items 恰好一致 → 本次同步仍 PUT 修正远端（R6）

> ❌ 已移除：v3→v4 迁移测试（无迁移代码）、blob GC 相关测试（含 `kTombstoneGcThresholdMs`、`_gcOrphanBlobs`、`syncGcOrphan` journal 事件）、`purged_uuids` 测试。
> ⚠️ **以下测试文件会因字段/方法移除而编译失败，必须改写或删除**（详见 §12.1）：
> `test/sync/sync_engine_test.dart`、`multi_device_test.dart`、`p0p1_self_heal_test.dart`、`safe_server_integration_test.dart`、`webdav_integration_test.dart`、`chaos_multi_client_test.dart`、`longrun_persistent_store_test.dart`、`diag_baseline_integrity_test.dart`、`journal_test.dart`、`change_password_multi_client_test.dart`、`keyring_test.dart`。
> 这些文件中 `_makeNote(... deleted: false ...)` 帮助函数需删除 `deleted` 参数；凡断言 `item.deleted` / `note.deleted` / `purgedUuids` / `kTombstoneGcThresholdMs` / `syncGcOrphan` 的用例需整体改写或删除。

---

## 11. 决议记录

| 编号 | 问题 | 决议 |
|---|---|---|
| Q1 | 删除-编辑冲突是否重建活跃笔记 | **否**，只进回收站让用户自行恢复 |
| Q2 | 版本兼容策略 | **一刀切**，不兼容、不 fallback、服务端清空重来 |
| Q3 | 是否保留删除声明字段 | **保留**，命名为 `deleted` |
| Q4 | 熔断阈值 `max(20, 30%)` | **采纳** |
| Q5 | 本地 DB 迁移与 legacy 转换 | **全部删除**，直接 v4 起步，`oldVersion < 4` 一律 drop 重建；删 `fromLegacyMeta` 与 7 个 legacy 键 |
| Q6 | blob GC | **同步流程不处理**；接口方法保留供未来独立手动 GC |
| Q7 | `created_at` 类型与 `deleted_uuids` 内容 | **(a)** `safe_notes.created_at` 由 TEXT 改为 INTEGER（与 `updated_at` 统一）；**(b)** `deleted_uuids` 改名 `deleted_items`，除 uuid 外**额外存元数据（content_hash / created_at / updated_at / deleted_at / origin / synced_hash），但不存 title / description**，便于 debug |
| Q8 | 设备溯源 `by` 字段 / manifest 结构 / 字段命名统一 | **(a)** 三张笔记表增加 `created_by` / `updated_by`（safe_notes 不加 `deleted_by`，删除记录落在 trash/deleted_items）；值统一取自已有 `DeviceIdProvider`；**(b)** `manifest.items` **维持 `{uuid:{...}}` map**（v3 修正：Q8 修订已改为与 `deleted` 同构的 map，非数组）；**(c)** `manifest.deleted` 由 `uuid→timestamp` 改为 `uuid→元数据对象`（含 `deletedBy` 等）；**(d)** `ManifestItem.hash`→`contentHash`、`ManifestHeader.lastModifiedBy`→`updatedBy`、`ManifestItem` 新增 `createdBy`，与本地 `content_hash` / `updated_by` 词根统一 |
| Q9 | D 集合元数据合并优先级（v3，评审 R4） | **远端优先、本地缺省填充**：`deletedBy`/`deletedAt`/`origin` 取远端（首次删除者），本地缺失字段补齐；`deleted_items` 用「冲突时补缺字段」的条件写入而非无条件 `INSERT OR REPLACE`（§5.2.1） |
| Q10 | 熔断放行机制（v3，评审 R3） | **「确认应用」= 写 `circuit_breaker_release:<providerKey>` 标志 + 立即同步一次**；本次同步跳过阈值检测、应用 D 全集，成功后清标志（§5.3） |
| Q11 | 删除传播到无明文设备（v3，评审 R5） | 只写 `deleted_items` 墓碑、trash 无行；回收站 UI 增「墓碑记录」区展示（E36） |

### 遗留待确认

- 无。本方案所有决策均已裁决（含 Q8 修订：`manifest.items` 维持 map 与 `deleted` 一致；`safe_notes` 预留 `deleted`/`deleted_at`/`deleted_by` 三列）。

---

## 12. 可运行性审查（对照现有代码，确保改完后仍能编译运行）

> 本节为本次"对照现有代码和原来的 sync- 文档"审查结论。逐条列出会破坏编译/运行的引用点，实现时**必须**逐一清理。所有行号基于本次审查时读取的代码。

### 12.1 会因字段/方法移除而编译失败的位置（lib/）

**`lib/models/safenote.dart`**
- `NoteFields.deleted`（第 40 行，且出现在 `values` 列表第 28 行）→ 删除常量与列表项。
- `SafeNote.deleted`（第 56 行构造函数参数、第 74 行默认值、第 136 行 copyWith、第 157 行 fromJson、第 187 行 toJson、第 232 行 toString）→ 全部删除。
- **新增 `NoteFields.createdBy='created_by'` / `NoteFields.updatedBy='updated_by'`**，并在 `SafeNote` 模型增 `createdBy`/`updatedBy` 字段、构造/fromJson/toJson/copyWith/toString 同步。
- `created_at` 转换（第 151、171、188 行）：fromJson 改读 `int` → `DateTime.fromMillisecondsSinceEpoch`（v3 修正：P4 一刀切下无旧数据，**不做 ISO 字符串兼容**，直接读 int）；toJson 写 `createdTime.millisecondsSinceEpoch`。

**`lib/data/database_handler.dart`**
- `MetaKeys.purgedUuids`（第 102 行）及 `getPurgedUuids`/`removePurgedUuids`/`_addPurgedUuid`/`_parseUuidList`/`_serializeUuidList`（第 690-731 行）→ 删除。
- `MetaKeys` 中 7 个 legacy 键（第 93-99、106 行：vaultId/edk/kdfSalt/keyFingerprint/keyVersion/vaultCreatedAt/dataKeyEpoch）→ 删除；**保留 `dataKeyHistory`（第 110 行）**。
- `_createDBStatic` / `_createDB`（第 322-386 行）：`deleted`/`deleted_at`/`deleted_by` 三列**保留为预留列** + `idx_notes_deleted` **保留**（v3 修正：与 §3 简化清单 #1 / §4.2 表 1 一致，不删列）；`created_at` 改 INTEGER；新增 `trash_notes` / `deleted_items` 建表（含 `created_by`/`updated_by`/`deleted_by`）；`safe_notes` 加 `created_by`/`updated_by`。
- `_upgradeDBStatic`（第 299-319 行）/ `_upgradeDB`（第 395-417 行）：删 v1→v2 / v2→v3 分支，改 `oldVersion < 4` 一律 drop+重建。
- `_initDB` 中 `version: 3`（第 252 行）→ `4`。
- `readAllNotes` 的 `WHERE deleted = 0`（第 522 行）→ **保留**（v3 修正：预留列恒为 0，作为未来软删钩子，与 §4.4 一致）。
- `readDeletedNotes`（第 529-539 行）→ 删除，由 `readTrashNotes` 取代。
- `readAllNotesIncludingDeleted`（第 553 行）→ 改名 `readActiveNotes`，更新调用方：`reEncryptAllNotes`（第 801 行）与 `sync_engine.dart`（第 915、979、1001、1089 行）。
- `readNoteByContentHash` 的 `AND deleted = 0`（第 487 行）→ **保留**（v3 修正）。
- `softDelete`（第 604 行）/ `hardDelete`（第 637 行）/ `hardDeleteByUuid`（第 675 行）/ `restoreNote`（第 739 行）→ 删除，由 §4.4 新方法取代。
- `markAllForBlobReupload` 的 `WHERE deleted = 0`（第 893 行）→ **保留**（v3 修正）。
- **新增编译遗漏（v3）**：`updateNoteByUuid` 日志第 594 行 `'deleted=${note.deleted} rows=$rows'` 访问 `SafeNote.deleted`，模型删该字段后**编译失败** → 去掉 `deleted=` 插值，改为 `rows=$rows` 或记录 `contentHash`。
- **新增语义说明（v3）**：`existsContentHash`（第 502-513 行）无 `deleted` 过滤（注释「含墓碑」）；G-Set 下 `safe_notes` 不再含墓碑行 → 方法自动降级为「仅活跃笔记」查询，**无需改代码**，但注释需更新；被 `sync_engine.dart:1421`（冲突副本标题 hash 探测）使用，行为变化在 G-Set 下正确。
- **新增** `insertNote`/`updateNote` 的 `createdBy`/`updatedBy` 写入；`moveToTrash`/`mergeDeletedItems` 的 by 字段写入；**`moveToTrash` 写 `deleted_items` 时按 §5.2.1 规则「远端优先补缺」条件更新，不用无条件 `INSERT OR REPLACE`**。

**`lib/sync/sync_models.dart`**
- `ManifestItem`：删 `deleted`（第 70 行）、`deletedAt`（第 95 行）字段；`copyWith`（第 126-145 行）、`toJson`（第 148-157 行，去掉 `deleted`/`deletedAt`）、`fromJson`（第 160-171 行）、`operator==`（第 179-189 行）、`hashCode`（第 192-201 行）同步删除。
- **`ManifestItem.hash`（第 64 行）→ 改名 `contentHash`**：构造函数参数（第 116 行）、`copyWith`（第 127/137/149 行）、`toJson`（第 149 行 `'hash'`→`'contentHash'`）、`fromJson`（第 162 行 `json['hash']`→`json['contentHash']`）、`toString`（第 175 行）、`operator==`（第 182 行）、`hashCode`（第 192-193 行）全部同步；类注释（第 6 行）更新。
- **`ManifestItem` 新增 `createdBy`（第 ~64 行附近）**：构造函数、`copyWith`、`toJson`、`fromJson`、`toString`、`==`、`hashCode` 全部加上。
- `ManifestHeader.lastModifiedBy`（第 324 行）→ **改名 `updatedBy`**：构造函数（第 338 行）、`copyWith`（第 351-367 行）、`toJson`（第 382 行 `'lastModifiedBy'`→`'updatedBy'`）、`fromJson`（第 398 行）、`toString`（第 405 行）、`ManifestHeader.encrypted`（第 451-487 行）全部同步；类注释（第 30 行示例）更新。
- `Manifest`：加 `Map<String,DeletedMeta> deleted` 字段（`items` 维持 `Map<String,ManifestItem>` 不变）；更新构造函数（第 421 行）、`copyWith`（第 435-442 行）、`copyWithHeader`（第 445-464 行，**必须透传 items 与 deleted**）；`Manifest.empty`（第 467-491 行）`schemaVersion: 1`→`2`、`deleted: {}`（items 维持 `{}`）；删注释"包含已删除的墓碑"（第 418 行）。序列化见 `ManifestCrypto`。
- **新增 `DeletedMeta` 类**（§4.3）及其 `toJson`/`fromJson`。
- `ManifestCrypto.serialize`（第 728-731 行）：加密体改为 `{'items': manifest.items.map((k,v)=>MapEntry(k, v.toJson())), 'deleted': manifest.deleted.map((k,v)=>MapEntry(k, v.toJson()))}`（**items 维持 `{uuid:{...}}` map 形态**，v3 修正，与现有 map 序列化一致，非数组）；`deserialize`（第 775-777 行）：`items` 读 `Map<String,dynamic>` 反序列化为 `Map<String,ManifestItem>`（缺省 `{}`），`deleted` 读 `Map` 反序列化为 `Map<String,DeletedMeta>`（缺省 `{}`）。
- `SyncActionType.delete`（第 503 行）与 `SyncResult.deleted`（第 578 行等）**保留**。
- `SyncActionType.delete` 的注释"标记为删除（墓碑同步）"可改为"删除应用（移入回收站 / 从 items 剔除）"。
- **注释同步（v3）**：类注释（第 6 行 `ManifestItem：...hash + deleted...`）、文件头示例（第 30 行 `"lastModifiedBy"`）、`Manifest.items` 注释（第 418 行「包含已删除的墓碑」）均需更新为 G-Set 语义。

**`lib/sync/sync_engine.dart`**（本方案最大的删除面）
- 删除 `kTombstoneGcThresholdMs`（第 98 行）。
- 删除 `skipGc`（第 491 行）及其调用（第 540-541、575 行 `_gcOrphanBlobs(merged)`）。
- 删除 `_gcOrphanBlobs`（第 1958-2010 行）。
- 删除 GC 墓碑块（第 1001-1019 行：`note.deleted && ... > kTombstoneGcThresholdMs`、`hardDeleteByUuid`、`deleted:`/`deletedAt:` 构建、`purgedUuids` 注释）。
- 删除 `getPurgedUuids` 用法（第 1079、1927 行）与 M1 purged 兜底逻辑。
- `repairRemote` 的 `if (item.deleted)`（第 697 行）→ 删除；`for (final entry in remoteManifest.items.entries)`（第 694 行）**维持不变**（items 仍为 map）。
- `_preserveConflictCopy` 的 `if (loserItem.deleted) return;`（第 1298 行）→ 删除。
- base-hash 冲突判定（第 1198-1199 行 `!localItem.deleted && !remoteItem.deleted`）→ 因无墓碑，`localItem`/`remoteItem` 恒为活跃，去除 deleted 守卫，仅保留内容比较分支；其中 `localItem.hash`/`remoteItem.hash`（第 1188/1189/1200 行）→ `localItem.contentHash`/`remoteItem.contentHash`（重命名跟随）。
- `_itemsEqual`（第 1272 行 `a.hash == b.hash && a.deleted == b.deleted`）→ `a.contentHash == b.contentHash`（删 deleted 比较）。
- 下载逻辑（第 1582-1625 行）：删 `if (item.deleted)` 墓碑下载分支及 `local != null && !local.deleted` 等守卫；构建 SafeNote 时删 `deleted:`（第 1731 行）/ `deletedAt:`（第 1735 行）；`item.hash` 全部 → `item.contentHash`（第 1611/1630/1642/1652/1663/1689/1705/1720/1725/1730/1750/1766/1773 行等约 50 处，机械全局替换）。
- 合并/对账内部 `Map<String,ManifestItem>` 访问（第 1094/1101/1104/1105/1930/1965/2200/2203/2204 行）**维持 map 形态不变**（`local.items[uuid]`、`remote.items[uuid]`、`merged.items.containsKey`、`merged.items.values`、`merged.items.keys`、`remote.items[key]` 等）；`repairRemote` 遍历 `items.entries` 维持原样。
- `_buildLocalManifest` 构建 `ManifestItem` 时（第 1014/1017/1350/1388/1733/1830 行）：`hash: note.contentHash`→`contentHash: note.contentHash`；新增 `createdBy: note.createdBy`（从 safe_notes 取）；`updatedBy: deviceId` 保留。
- 其余 `!local.deleted` / `!remoteItem.deleted` 守卫（第 1595、1620、1625、1814、1850 行）→ 删除。
- `readAllNotesIncludingDeleted` → `readActiveNotes`（第 915、979、1001、1089 行）。
- header 构建（第 836/1052/1259 行）：`lastModifiedBy: deviceId` → `updatedBy: deviceId`。
- 拉回笔记（下载建 SafeNote 处）：增 `createdBy: remoteItem.createdBy`、`updatedBy: remoteItem.updatedBy`。
- `SyncActionType.delete` 用于 journal（第 1451、1603 行）与统计（第 182、301、590 行）**保留**。
- **D 过滤注入（v3 明确实现位置）**：`_mergeAndTransfer`（第 1070 行起）入口计算 D，对 `allUuids` 中 ∈ D 的 uuid 在「仅远端有 / 仅本地有 / 双方都有」三分支统一跳过并**不加入 mergedItems**（参照现有 `purgedSet` 在 1107-1118 / 1132-1143 / 1246-1250 的处理模式）；`merged.deleted = D` 按 §5.2.1 规则直接写入，不依赖遍历。
- **`_hasEffectiveChange`（第 2164 行起）增加 `merged.deleted` 与 `remote.deleted` 比较**（键集长度 + 逐条 `DeletedMeta` 相等），防「远端 deleted 回滚且 items 恰好一致」时漏 PUT（v3，R6）。
- **熔断放行标志（v3，Q10）**：`_syncOnce` 开头读 `circuit_breaker_release:<providerKey>` 标志 → 有则跳过 §5.3 阈值检查直接应用 D；PUT 成功后清标志。
- **schemaVersion 校验（v3，R2）**：manifest `deserialize`/`deserializeHeaderOnly` 之后校验 `schemaVersion == 2`，≠2 抛同步错误中断（实现于 `sync_service.sync()` / `repairRemote()`，见 §9 步骤 4）。

**`lib/sync/keyring.dart`**
- `fromLegacyMeta`（第 246-**297** 行，v3 修正行号：读取 legacy 键在 247-267、History 构建在 268-281、返回构造在 283-296）及调用方（第 306、969 行）→ 删除；7 个 legacy 键随删除。`MetaKeys.dataKeyEpoch` 仅此处消费，一并删除；`dataKeyHistory` 保留。
- `ManifestHeader` 构造（第 491/509 行）`required String lastModifiedBy` → `required String updatedBy`（`toManifestHeader` 是 keyring 投影 header 的唯一出口，仅此 2 处 + sync_engine 三处传参）。
- **注释同步（v3）**：`database_handler.dart:89` 与 `sync_engine.dart:668` 的注释引用了 `fromLegacyMeta`，随删除更新。
- **注明（v3）**：`keyring.dart:200` 的 `kKeyringSchemaVersion` 是 **keyring 自身的 schema 版本常量（值 1）**，非 manifest `schemaVersion`，**不受影响**，勿误改。

**`lib/views/note_view.dart`**
- 第 144 行 `softDelete(widget.noteId)` → `moveToTrash(uuid, 'local', deviceId)`。**v3 补充实现细节**：`widget.noteId` 是 `int` 自增 id，`moveToTrash` 需 `uuid` + `deviceId` → 先 `readNote(widget.noteId!)` 取笔记对象拿 `uuid`，再调用；`deviceId` 用 `DeviceIdProvider.instance`（首次需 `await getDeviceId()`）。

**`lib/views/deleted_notes.dart`**（v3 补充编译点：不止方法调用行）
- 第 45 行 `readDeletedNotes()` → `readTrashNotes()`。
- 第 107 行 `_restoreNote` → `restoreFromTrash(note.id)`（发新 uuid）。
- 第 119 / 167 行 `hardDelete(note.id!)` → `permanentDeleteFromTrash(note.id!)`。
- 清空全部 → `emptyTrash()`。
- **类型**：第 34 行 `List<SafeNote> _deletedNotes` 与第 191 行 `_DeletedNoteTile.note` 由 `SafeNote` 改为 `TrashNote`（**编译失败点**）；第 203 行删除时间 `note.updatedAt` → `note.deletedAt`（回收站按删除时间语义）；文件头注释（第 7-14 行）更新为回收站 + G-Set 语义。
- **回收站展示**：列表展示 `deleted_by`/`deleted_at`；**新增「墓碑记录」区（v3，Q11/E36）**：读 `deleted_items`，展示"已被 `<deleted_by>` 于 `<deleted_at>` 删除（内容在其他设备）"，可单独清除墓碑行。

**`lib/views/settings/sync_settings.dart`**
- 第 221 行 `r.deleted > 0` → 保留（`SyncResult.deleted` 计数仍存在）。

**`lib/sync/sync_service.dart`**
- 第 667 行 `lastResultDeleted` → 保留（`SyncResult.deleted` 计数）。
- `repairRemote` 委托（第 492-554 行）→ **仅委托给 `SyncEngine.repairRemote`，无遍历逻辑**（v3 修正：原稿写「`for (entry in items.entries)` → `for (item in items)`」归属错误，该遍历在 `sync_engine.dart:694`，此处不改）。
- **schemaVersion 校验点（v3，R2）**：`sync()` / `repairRemote()` 在 manifest 反序列化后校验 `schemaVersion == 2`，≠2 报错中断（见 §9 步骤 4）。

### 12.2 新增字段/结构对编译的影响（Q8 专项）

| 改动 | 影响面 | 处置 |
|---|---|---|
| `by` 字段（created_by/updated_by/deleted_by） | 模型增字段；DB CRUD 写；`sync_engine` 构建 ManifestItem / 拉回笔记 / 删除交易填值 | 同步增字段；`DeviceIdProvider` 已在 `_deviceId` 缓存，直接传参 |
| `manifest.items` 维持 map | 与 `deleted` 同为 map（Q8 修订）；`Manifest.items` 类型不变、`ManifestCrypto` 序列化不变、`repairRemote` 遍历不变 | 无改动（结构一致性决策） |
| `manifest.deleted` timestamp→元数据对象 | `Manifest.deleted` 类型 `Map<String,DeletedMeta>`；`ManifestCrypto` 序列化；`moveToTrash`/`mergeDeletedItems` 填 `DeletedMeta` | 新增 `DeletedMeta` 类 |
| `hash`→`contentHash` | sync_models + sync_engine 约 50 处 `item.hash`/`localItem.hash`/`remoteItem.hash`/`hash:`/`'hash'` | 全局机械替换 `.hash`→`.contentHash`、`hash:`→`contentHash:`、`'hash'`→`'contentHash'`（`SyncAction.hash` 是另一类，不改） |
| `lastModifiedBy`→`updatedBy` | ManifestHeader（sync_models/keyring）+ sync_engine 3 处构建 | 全局替换（词根一致，无歧义） |

### 12.2.1 注释 / 命名保留（v3 补充）

不影响编译但应同步更新（避免误导），以及明确「不受影响」避免误改：

| 位置 | 内容 | 处置 |
|---|---|---|
| `lib/utils/device_id.dart:5` | 注释「为 manifest header.lastModifiedBy 提供设备标识」 | 改 `updatedBy` |
| `lib/sync/sync_engine.dart:36/72` | 注释「manifest header.lastModifiedBy」 | 改 `updatedBy` |
| `lib/views/deleted_notes.dart:7-14` | 文件头注释描述旧墓碑/软删除机制 | 改回收站 + G-Set 语义 |
| `lib/views/home.dart:483` / `widgets/drawer.dart:34/44/139/144` | `onDeletedNotesCallback` / `DeletedNotesPage` 命名 | **保留**（若页面类名不改）；若改名为回收站（TrashNotesPage）需同步回调与路由 |
| `lib/sync/keyring.dart:200` `kKeyringSchemaVersion`、`journal.dart:63/664` `kJournalSchemaVersion` | keyring / journal **各自的独立 schema 版本** | **不受 manifest `schemaVersion` 改造影响**，勿误改 |

### 12.3 测试文件编译失败清单（必须改写/删除）

| 文件 | 失败原因 | 处置 |
|---|---|---|
| `sync_engine_test.dart` | `_makeNote(deleted:)`、`softDelete`、`result.deleted`、`item.deleted`、`_gcOrphanBlobs` GC 用例、`item.hash` 断言 | 改 `_makeNote` 去 `deleted`、加 `createdBy`/`updatedBy`；`item.hash`→`item.contentHash`；删 GC 用例；其余按 §10 改写 |
| `multi_device_test.dart` | `hardDelete`、`getPurgedUuids`、`softDelete`、`item.deleted` 断言 | 改写删除相关用例 |
| `p0p1_self_heal_test.dart` | `softDelete`、skipGc GC 用例 | 删除 GC 分支用例 |
| `safe_server_integration_test.dart` | `item.deleted` / `note.deleted` 墓碑断言 | 去掉墓碑断言 |
| `webdav_integration_test.dart` | 孤儿 blob GC 组、`deleted` 断言 | 删除 GC 组 |
| `chaos_multi_client_test.dart` | `softDelete`、`item.deleted`、`kTombstoneGcThresholdMs`、墓碑 GC 组 | 按 G-Set 改写不变量；删 GC 组 |
| `longrun_persistent_store_test.dart` | 内部模型 `deleted` 集合、I3 墓碑不变量 | 改用 `deleted_items` 不变量 |
| `diag_baseline_integrity_test.dart` | `item.deleted` | 改写 |
| `journal_test.dart` | `syncGcOrphan` wire 断言 | 删除该断言 |
| `change_password_multi_client_test.dart` / `keyring_test.dart` | `_makeNote(deleted: false)` | 改 `_makeNote` 去 `deleted` 参数 |

**v3 补充遗漏引用（评审核实，均会导致编译失败）**：

| 文件 | 遗漏的受影响引用 | 处置 |
|---|---|---|
| `keyring_test.dart` | **5 处 `lastModifiedBy:`（第 55/750/763/776/798 行）**、1 处 `readAllNotesIncludingDeleted`（第 630 行） | 改名 `updatedBy`；方法改 `readActiveNotes` |
| `diag_baseline_integrity_test.dart` | **10+ 处 `item.hash`**（第 63-105 行），不止 `item.deleted`（第 59 行） | 全局 `item.hash`→`item.contentHash` |
| `webdav_integration_test.dart` | `lastModifiedBy:`（第 308 行）、`readAllNotesIncludingDeleted`（第 683/922 行） | 改名；改方法 |
| `chaos_multi_client_test.dart` | `lastModifiedBy:`（第 154 行）、`readAllNotesIncludingDeleted`（第 484/709 行） | 改名；改方法 |
| `longrun_persistent_store_test.dart` | `lastModifiedBy:`（第 370 行）、`readAllNotesIncludingDeleted`（第 569 行） | 改名；改方法 |
| `p0p1_self_heal_test.dart` | `readAllNotesIncludingDeleted` 调用 | 改 `readActiveNotes` |
| `safe_server_integration_test.dart` | `readAllNotesIncludingDeleted`（第 598/842 行） | 改 `readActiveNotes` |

> 另：`test/widget_test.dart`、`test/encryption/aes_encryption_test.dart`、`test/sync/local_fs_backend_test.dart`、`test/sync/crypto_test.dart` 已排查**无受影响引用**（v3 补充确认）。
> `SyncAction.hash` / `JournalEntry.hash` 是另一类（journal 操作记录），**不随 `ManifestItem.hash` 改名**，`sync_diagnostics_page.dart:440-441`、`sync_engine.dart:2053-2105` 无需改。

> 实施时务必先 `flutter analyze` 跑一遍，让编译器报出所有遗漏的 `deleted`/`purged`/`hash`/`lastModifiedBy` 引用，再逐一清理——这是"改完还能 run"的最可靠保障。

### 12.4 与原 sync 文档的兼容性审查

- **`docs/sync-protocol-spec.md`**：本方案实施后**与代码不符**的章节超出初稿所列（v3 评审核实），需一并更新为 G-Set 语义（`deleted` map 元数据对象、`items` **维持 map**、`contentHash`/`createdBy`/`updatedBy` 命名、schemaVersion=2、本地回收站 + 只增集合）：
  - §3 存储模型（第 72 行「不清理孤儿 blob、不删除墓碑」）→ 补「blob 永不删除（G-Set）」
  - §5 JSON 示例（第 184-203 行，items 内嵌 `deleted:true/false`、无 deleted map）→ 改 `contentHash`/`createdBy`，增独立 `deleted` map 示例
  - §5.1 items 字段说明（第 213 行「包含墓碑」）→ 改「不含墓碑，已删除项在独立 deleted map」
  - §5.2 ManifestItem 字段表（第 217-222 行）→ 完整重写：去 `deleted`、`hash`→`contentHash`、增 `createdBy`/`contentSize`/`blobKeyEpoch`
  - §5.3 加密说明 → 补「加密体含 items + deleted」
  - §8.1 主流程 → 补 G-Set 删除前置步骤（§2.2 三步算法）
  - §8.3 墓碑处理（第 348-354 行）→ 替换为 G-Set 删除集合语义
  - §12.1 测试描述（第 408 行「覆盖 LWW/墓碑/乐观锁重试」）→ 改 LWW/G-Set 删除
  - （新增）`schemaVersion`、`deleted` map / `DeletedMeta` 目前协议文档完全缺失，需新增描述
  - 该文档是协议权威，应一并修订（属文档更新，不影响编译）。
- **`docs/server-api-spec.md`**：**无需修订**（服务端零知识，不解析 manifest JSON）。其 12.2 节测试场景「墓碑传播」属客户端行为描述，可在客户端协议文档更新时移动/改写。
- **`docs/simplified-sync-design.md` / `docs/sync-feature-design.md`**：背景与设计动机仍有效（单 vault、零知识、内容寻址、乐观锁、冲突 LWW），涉及"墓碑/软删除"的段落需标注为本方案取代。
- **`docs/sync-complexity-analysis-20260731.md` / `sync-complexity-improvement-proposals-20260731.md`**：本方案即"改进提案"的落地，可与本文互引。
- 后端传输层（WebDAV / SafeServer / LocalFS）**完全不变**，`SyncBackend` 接口签名不变（GC 方法保留），故 `local_fs_backend.dart` / `webdav_backend.dart` / `safe_server_backend.dart` 无需改动（v3 确认：Go / Node 服务端均将 manifest 视为不透明二进制，不解析 JSON 字段）。

### 12.5 关键修正（相对 v2.1 / 初稿）

1. **`dataKeyHistory` 不得删除**：v2.1 §4.2 误将其与 legacy 键一并删除；实际 Layer 3 修复（`appendDataKeyHistory`/`getDataDataKeyHistory`）依赖它，必须保留。真正删除的 legacy 键为 7 个。
2. **`SyncResult.deleted` / `SyncActionType.delete` 保留**：它们是计数/事件类型，与 `deleted` 字段解耦，误删会导致统计与 journal 逻辑编译失败。
3. **`created_at` 改 INT 对 UI 零影响**：模型内部转换，调用方不变。
4. **`Manifest.copyWithHeader` 必须透传 `deleted`（及 `items`）**：否则合并后删除集合/items 丢失，导致复活 bug。
5. **deviceId 无需新增 meta 键**：`DeviceIdProvider`（`lib/utils/device_id.dart`）已存在，`by` 字段值直接复用，避免重复持久化。
6. **`hash`→`contentHash`、`lastModifiedBy`→`updatedBy` 是重命名不是新语义**：纯词根统一，避免 manifest 与本地字段名各说各话。

---

## 13. 一句话总结

> 单用户 + 空间不值钱 + 开发期不兼容，这三条前提让「删除」从一套需要**状态机、时间窗、安全阀、迁移代码**协同维护的分布式协议，塌缩成一个**只增集合的并集运算**；顺便把 `created_at` 统一为 INTEGER、把墓碑表升级为带元数据的 `deleted_items`、给所有笔记表加上 deviceId 溯源的 `by` 字段、把 manifest 的 `items` 与 `deleted` 统一为同构的 `{uuid:{...}}` map、`deleted` 升级为元数据对象，并让 manifest 与本地字段名彻底统一——让 debug 不再抓瞎。
>
> **不丢数据靠回收站，不出幽灵靠只增集合，不报废靠幂等——而幂等是并集运算白送的，不需要额外设计。**

---

## 14. 评审修订记录（v2 → v3）

> v3 依据 2026-08-01 评审（`docs/code-review-refact-architecture-design-20260801.md`）对照现有代码逐条核实后修订。所有修订均已在正文落位，本节为索引。

| 编号 | 评审问题 | v3 修订落位 |
|---|---|---|
| R1 | §12.1 与 §4.2/§4.4 矛盾（`deleted` 列 / `WHERE deleted = 0` 删 vs 留） | 统一为**保留预留列**：§12.1 database_handler 段「保留三列 + idx_notes_deleted」「`WHERE deleted = 0` 保留」 |
| R2 | schemaVersion=2 校验无实现点（旧 manifest 墓碑复活 → 违反 G） | §7 manifest 协议行、§9 步骤 4、§12.1 sync_service 段：反序列化后校验 `schemaVersion == 2`，≠2 报错中断，不兼容旧数据 |
| R3 | 熔断「确认应用」持久化机制缺失 | §5.3 重写：写 `circuit_breaker_release:<providerKey>` 标志 + 立即同步一次 + 本次去阈值 + 成功后清标志（Q10） |
| R4 | D 集合元数据合并优先级未定义（溯源失真） | 新增 §5.2.1：**远端优先、本地缺省填充**；`moveToTrash` 条件更新而非无条件 `INSERT OR REPLACE`（Q9） |
| R5 | 删除传播到无明文设备 trash 空壳 | E01 补充 + 新增 E36：只写 `deleted_items` 墓碑，回收站 UI 增「墓碑记录」区（Q11） |
| R6 | `_hasEffectiveChange` 未比较 deleted 集合 | §9 步骤 5、§12.1 sync_engine 段：增加 `merged.deleted` 与 `remote.deleted` 键集 + 条目比较 |
| M1 | 编译遗漏：`updateNoteByUuid:594` 日志访问 `note.deleted` | §12.1 database_handler 段补充 |
| M2 | 编译遗漏：测试文件 `lastModifiedBy`/`item.hash`/`readAllNotesIncludingDeleted` 引用 | §12.3 v3 补充表（keyring_test 5 处、diag_baseline 10+ 处、webdav/chaos/longrun 各 1 处等） |
| M3 | 编译遗漏：`deleted_notes.dart` 类型/属性 | §12.1 deleted_notes 段补充（List\<TrashNote\>、deletedAt、墓碑记录区） |
| M4 | 归属错误：`items.entries` 遍历写在 sync_service 段 | §12.1 sync_service 段修正（实际在 `sync_engine.dart:694`） |
| M5 | `fromLegacyMeta` 行号 246-270 → 246-297 | §12.1 keyring 段修正 |
| M6 | Q8 残留「items 数组」表述与「维持 map」矛盾 | §7、§4.6 序列化、§11 Q8(b)、§12.1 sync_models、§13 全部统一为**维持 map** |
| M7 | `existsContentHash` 语义变化未提 | §12.1 database_handler 段补充（自动降级为仅活跃查询） |
| M8 | `created_at` ISO 兼容与 P4 矛盾 | §12.1 safenote 段修正：不做 ISO 兼容，直接读 int |
| M9 | 注释点未列（`lastModifiedBy` 注释、`kKeyringSchemaVersion`/`kJournalSchemaVersion` 区分） | 新增 §12.2.1「注释 / 命名保留」 |
| M10 | 协议文档修订面低估 | §12.4 扩大为 §3/§5/§5.1/§5.2/§5.3/§8.1/§8.3/测试描述 + 新增 deleted map/schemaVersion 描述 |
| M11 | 测试清单补充（T1-T6） | §10 新增 21-26 条 |
| M12 | 熔断「状态完全未变」表述过强 | §5.3 限定为「被暂缓 uuid 未被本地编辑时」 |
| M13 | `softDelete` 签名、`sync_service` 定位、`dataKeyHistory` typo | §4.4 签名修正；§12.1 归属修正；§4.2 typo 修正 |
