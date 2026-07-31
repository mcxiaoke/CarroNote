# SafeNotes 同步架构复杂度分析报告

> 生成时间：2026-07-31 15:58:40（Asia/Shanghai）
> 数据来源：`lib/sync/` 目录下 10 个 Dart 文件（约 4500 行代码）静态阅读
> 方法：使用 search 子代理对 [sync_engine.dart](file:///c:/Home/Projects/safenotes/lib/sync/sync_engine.dart) / [sync_service.dart](file:///c:/Home/Projects/safenotes/lib/sync/sync_service.dart) / [sync_backend.dart](file:///c:/Home/Projects/safenotes/lib/sync/sync_backend.dart) 及三个 backend 实现进行结构化扫描
> 说明：本文档为只读分析报告，不包含修改建议。改进建议见同目录 [sync-complexity-improvement-proposals-20260731.md](./sync-complexity-improvement-proposals-20260731.md)

---

## 0. 摘要

`lib/sync/` 是经典的"抽象后端 + 引擎 + 服务"三层结构，核心架构（三层分离、抽象 backend、内容寻址、ETag 乐观锁、两层密钥 MK/dataKey）设计合理。但因密钥迁移、容错自愈、冲突保留、墓碑 GC 等需求叠加了大量补丁（注释里可见 B1/B3/D2/D3/E1/F1/H1/H3/H4/L3/M1/M7/P0-1/P0-3/P0-4/P1-1/P1-2/R10 等 20+ 个编号修复），导致复杂度显著膨胀。

主要痛点集中在四点：

1. **单文件体积过大**：`sync_engine.dart` 1800+ 行，包含 5 步同步 + 4 层容错 + 3 种迁移 + 2 种 GC + 冲突解决 + 版本号管理。
2. **错误处理不统一**：8+ 处 `on Object` 兜底吞掉错误类型信息；中英文消息混用；多处静默吞异常。
3. **可观测性不足**：状态机和操作记录都有，但诊断信息散落在 `SyncAction.message` 字符串里，无机器可解析 schema，无历史 metrics，无统一日志。
4. **隐藏状态分散**：DB 的 `sync_meta` 表 7+ 个键、文件系统 4 类辅助文件、内存 6+ 个非 final 可变字段、3 个全局单例。

---

## 1. 三个核心文件的职责与协作

### 1.1 [sync_backend.dart](file:///c:/Home/Projects/safenotes/lib/sync/sync_backend.dart)（抽象接口层，~250 行）

- 定位：**协议契约**，纯抽象类，无业务逻辑。
- `SyncBackend` 抽象类（行 28-178）涵盖 14 个方法：`init / ping / getManifest / putManifest / getBlob / putBlob / deleteBlob / listBlobs / deleteBlobSoft / listOrphanBlobs / purgeOrphans / backupManifest / backupCorruptManifest / close`，以及 2 个 getter（`displayName / providerKey`）。
- 定义 3 个全局异常类型：`ConflictException`（行 187）、`BackendUnavailableException`（行 198）、`BackendNotInitializedException`（行 209）。
- 提供共享工具函数 `writeRingBackup`（行 226-250）和常量 `kManifestBackupRingCount = 5`（行 216），供三个 backend 子类复用。
- 设计原则：纯存储、内容寻址（blob 按 hash 命名天然去重）、ETag 乐观锁只在 `putManifest` 做一次 CAS。

### 1.2 [sync_engine.dart](file:///c:/Home/Projects/safenotes/lib/sync/sync_engine.dart)（核心引擎层，1800+ 行）

- 定位：**业务大脑**，实现 5 步同步算法、密钥迁移、冲突解决、容错自愈、GC。
- 类 `SyncEngine`（行 54-1806），依赖 4 个外部对象：`backend: SyncBackend`、`database: NotesDatabase`、`vault: Vault`（非 final，迁移后会被替换）、`deviceId: String`。
- 持有 4 个关键常量：
  - `maxRetries = 3`（行 83，乐观锁重试上限）
  - `kConflictPreserveThresholdMs = 5 分钟`（行 90）
  - `kTombstoneGcThresholdMs = 30 天`（行 96）
  - `_orphanRetention = 30 天`（行 103）
- 暴露 2 个公开方法：`sync()`（行 133，主同步流程）和 `repairRemote({oldPassword})`（行 536，全量体检+治愈）。
- 内部含 3 个私有异常/抽象类：`_MigrationRequiredException`（行 1811）、`_DownloadOutcome` 及其 3 个子类（行 1830-1846，用代数数据类型表达下载结果）。

### 1.3 [sync_service.dart](file:///c:/Home/Projects/safenotes/lib/sync/sync_service.dart)（应用服务层，~600 行）

- 定位：**生命周期与编排**，单例，对外暴露 UI 可观察的状态。
- 类 `SyncService`（行 94-597），单例 `static final SyncService.instance`（行 96）。
- 持有 4 个私有依赖（行 104-109）：`_vault / _backend / _engine / _deviceId`，通过 `initialize / updateVault / switchBackend / logout / dispose` 管理生命周期。
- 提供 3 个公开触发方法：`sync()`（行 256，手动）、`autoSync()`（行 409，debounce 3 秒）、`repairRemote()`（行 345）。
- 通过 `stateStream`（行 120）和 `SyncServiceState`（行 57-88）+ `SyncStatus` 枚举（行 39-54）暴露状态机。
- 还承担登录流程辅助：`initVaultFromPassword`（行 482）、`initBackend`（行 524）、`cacheVaultFromLogin`（行 594）、`createBackendForVerification`（行 586）。
- 内部维护 `_syncInProgress` 互斥锁（行 129）、`_backendReady` 标志（行 144，Bug A 修复惰性 init）、`_autoSyncTimer`（行 150）。

### 1.4 三者协作流程

```
UI ──> SyncService.sync()
            │
            ├─ 互斥锁检查 (_syncInProgress)
            ├─ 惰性 re-init backend (_backendReady)
            ├─ 状态 → syncing
            │
            └─ SyncEngine.sync()
                  │
                  ├─ backend.getManifest()  ──> SyncBackend 实现
                  ├─ ManifestCrypto.deserialize (用 vault.dataKey)
                  ├─ vault.checkMigrationNeeded()
                  ├─ _buildLocalManifest (从 database 读)
                  ├─ _mergeAndTransfer (LWW + 容错)
                  │     ├─ backend.getBlob / putBlob
                  │     └─ database.readNoteByUuid / storeNote
                  ├─ backend.backupManifest + putManifest (ETag 乐观锁)
                  ├─ _updateLocalState (写 manifest version, markAllSynced)
                  └─ _gcOrphanBlobs (listBlobs - referenced = orphans)
            │
            └─ 状态 → success/error，写回 SyncServiceState
```

依赖关系严格单向：`SyncService → SyncEngine → (SyncBackend, Vault, NotesDatabase)`。`SyncBackend` 接口完全不知道 `SyncEngine` 的存在，`SyncEngine` 也不知道 `SyncService` 的存在。

---

## 2. 完整同步流程的代码路径

入口：`SyncService.sync()` 行 256-338 → `SyncEngine.sync()` 行 133-180 → `SyncEngine._syncOnce(attempt)` 行 191-520。

### 2.1 外层重试循环（`sync()`，行 133-180）

- 状态变量：`allActions` 累积列表、`totalMigrated` 计数、`epochMismatch` 标志。
- `for (attempt = 1..3)` 重试循环（行 138）。
- 分支 A（行 151）：捕获 `ConflictException` → 乐观锁冲突，回到 Step 1 重试。
- 分支 B（行 160）：捕获 `_MigrationRequiredException` → 迁移已完成需要用新 dataKey 重新同步，回到 Step 1 重试（不计入冲突次数但复用循环）。
- 重试上限到达 → 返回 `SyncResult.failure`（行 154、172）。

### 2.2 单次同步尝试（`_syncOnce(attempt)`，行 191-520）

**Step 1 — GET 远端 manifest**（行 193-410）

- 行 193：`backend.getManifest()` 拉取 `(ciphertext, etag)`。
- 行 207：若 `ciphertext` 非空进入解析分支，否则 `remoteManifest` 保持 null（首次同步）。
- 行 215-250：**分支 P0** — `ManifestCrypto.deserializeHeaderOnly` 抛 `FormatException`（远端 manifest 损坏）→ 调用 `backend.backupCorruptManifest` 备份 → 用本地数据重建 → early return。
- 行 256-263：**分支 B1（密钥纪元守卫）** — `remoteHeader.keyVersion > vault.keyVersion` → 他端改了密码，设置 `epochMismatch = true`，整体 override 远端密钥纪元三元组（`encryptedDataKey / keyFingerprint / keyVersion`）。
- 行 266-409：**分支 dataKey 迁移** — 调用 `vault.checkMigrationNeeded(remoteHeader.encryptedDataKey)`，返回 `MigrationResult`：
  - 行 269 `!success` 分支（MK 解不开远端 encryptedDataKey）：
    - 行 286-336：尝试用本地 dataKey 直接解 manifest items；失败则用 `passphraseProvider` 取密码，调用 `Vault.tryDeriveRemoteDataKey` 区分场景 c（密码真不匹配）vs 场景 d（密码相同 salt 不同）。场景 d 调用 `_executeMigrationVault` 后抛 `_MigrationRequiredException` 触发重试。
  - 行 346-384：**分支 B3/H1** — MK 能解开且 `remoteDataKey == localDataKey` → 调用 `vault.adoptRemoteEpoch` 整体采用远端纪元，清除 epochMismatch。
  - 行 385-402：MK 能解开但 `remoteDataKey != localDataKey` → 调用 `_executeMigration` → 抛 `_MigrationRequiredException` 触发重试。
  - 行 403-409：无需迁移 → 直接 `ManifestCrypto.deserialize`。
- 行 417：计算 `skipGc = remoteManifest == null`（P0-1 修复，避免误删其他设备 blob）。

**Step 2 — 构建本地 manifest**（行 420-424）

- `_buildLocalManifest`（行 823-891）从 `database.readAllNotesIncludingDeleted()` 读所有笔记。
- 行 836-839：F1 修复 — 过期墓碑（软删除 > 30 天）硬删除并跳过。
- 行 868：`blobKeyEpoch: vault.dataKeyEpoch` — 乐观标记当前纪元（设计文档在行 848-867 详细解释为何不持久化到 DB）。

**Step 3 — 比对 + 传输**（行 428-435）

`_mergeAndTransfer`（行 902-1078）— 核心合并逻辑：

- 行 911：读取 `database.getPurgedUuids()`（M1 修复，待清理 uuid）。
- 行 917：读取 `database.getPendingReuploadUuids()`（Layer 2a，密钥变更后强制重传）。
- 行 920-929：远端无 manifest 分支 — 直接上传所有本地笔记。
- 行 935-1051：逐条遍历 `allUuids = local ∪ remote`：
  - 行 939 `local == null && remote != null`：仅远端有 → 下载（含 P0-4 blob 缺失自愈、M7 hash 校验、Layer 3 纪元现代化）。
  - 行 964 `local != null && remote == null`：仅本地有 → 上传。
  - 行 983 双方都有：
    - 行 985 `_itemsEqual` → 一致则跳过（或 Layer 2a 强制重传）。
    - 行 999-1049 冲突分支：调用 `_resolveConflict`（LWW），若时间差 > 5 分钟且 hash 不同，调用 `_preserveConflictCopy`（E1 修复）保留败方副本。
- 行 1055-1057：M1 修复 — 从 merged items 移除 purgedSet 中的 uuid。
- 行 1059-1077：构建新 Manifest header（version = remote.version + 1）。

**Step 4 — 判断 + PUT manifest**（行 437-492）

- 行 448-454：D3 修复 — `_hasEffectiveChange` 判断是否有实际变更（避免 version 无意义 +1）。
- 行 456-481：无变更分支 — 跳过 PUT，直接 `_updateLocalState` + 可选 GC，early return。
- 行 484-492：有变更分支 — `ManifestCrypto.serialize` 加密 → `backend.backupManifest`（P1-1 环形备份） → `backend.putManifest(ciphertext, etag)` 乐观锁 PUT。

**Step 5 — 更新本地状态**（行 495-505）

- `_updateLocalState`（行 1651-1667）：写 manifest version、`markAllSynced`、清理已 purged 的 uuid。
- 行 501：`_gcOrphanBlobs`（行 1689-1722）— F1 修复 + P1-2 修复：`listBlobs - referenced = orphans` → `deleteBlobSoft`（软删到隔离区） → `purgeOrphans`（超 30 天才真删）。
- 行 505：`database.clearAllPendingReupload()`（Layer 2a 闭环）。

### 2.3 涉及的关键状态

- **输入状态**：`vault.{dataKey, encryptedDataKey, keyFingerprint, keyVersion, dataKeyEpoch, kdf}`、`database` 中的 `manifest_version / purged_uuids / blob_reupload_pending / data_key_history`、远端 `(ciphertext, etag)`。
- **中间状态**：`remoteManifest / localManifest / merged / allActions / epochMismatch / overrideXxx`。
- **输出状态**：`SyncResult`（success / uploaded / downloaded / deleted / skipped / conflicts / migrated / actions / attempts / passwordEpochMismatch / failedNoteUuids）、新 manifest 密文 + 新 etag、本地 DB 更新。

---

## 3. 三个 backend 接口统一性分析

三个 backend 都 `implements SyncBackend`，**接口签名完全一致**，但行为语义存在明显差异。

### 3.1 接口实现完整性对比

| 方法 | LocalFsBackend | WebDavBackend | SafeServerBackend |
|------|----------------|---------------|-------------------|
| `init` | 创建目录（行 60-66） | MKCOL + 探测 ETag（行 136-143） | GET /health（行 108-125） |
| `ping` | 写探测文件（行 284-298） | PROPFIND depth 0（行 638-657） | GET /health（行 694-703） |
| `getManifest` ETag | 文件 SHA-256（行 304） | 服务器 ETag / fallback 内容 hash（行 252-255） | 服务器 ETag / fallback 内容 hash（行 164-166） |
| `putManifest` 原子性 | **D5 修复：tmp + rename 原子写**（行 117-122） | 直接 PUT（非原子） | 直接 PUT（非原子） |
| `deleteBlob` | 同步删除文件（行 161-167） | DELETE 请求（行 356-376） | DELETE 请求，**405 静默跳过**（行 281-309） |
| `listBlobs` | 扫目录 + 正则过滤（行 173-189） | PROPFIND + 正则解析 XML（行 383-423） | GET /blobs JSON 数组，**过滤 `0rphan-` 前缀**（行 390-393） |
| `deleteBlobSoft` | rename 到 `blobs-orphan/hash.ts`（行 196-214） | COPY + DELETE（行 431-468） | v2.2 资源层 move；降级 `0rphan-` 前缀伪隔离（行 404-432） |
| `backupCorruptManifest` | rename 为 `.corrupt-{ts}`（行 126-139） | **退化 DELETE**（行 613-629，注释明确说"WebDAV 不支持重命名"） | v2.2 move；降级 DELETE（行 319-343） |
| `backupManifest` | 直接调 `writeRingBackup`（行 264-275） | 服务端 MKCOL + GET/PUT 索引 + PUT 备份（行 553-606） | v2.2 资源层；**降级到客户端临时目录**（行 537-558） |
| `close` | `_initialized = false`（行 278-281） | `_client.close()`（行 632-635） | `_client.close()`（行 688-691） |

### 3.2 不一致之处

1. **SafeServerBackend 独有的能力探测机制**（行 72-75、586-595）：`_resourcesSupported / _resourcesProbed` 字段实现"v2.2 资源层 vs 旧版"双路径，其他两个 backend 无此概念。
2. **SafeServerBackend 的 `listBlobs` 隐式过滤**（行 392）：返回前过滤 `0rphan-` 前缀项，因为旧版降级路径用 `0rphan-` 前缀实现伪隔离；LocalFS/WebDAV 的隔离区是独立目录无需过滤。
3. **ETag 强度不同**：LocalFS 是强 ETag（SHA-256，行 304）；WebDAV/SafeServer 可能是弱 ETag（`W/` 前缀，需 `_normalizeEtag` 规范化，行 676-687 / 721-731）。
4. **WebDAV `backupCorruptManifest` 退化实现**（行 613-629）：注释明确说"WebDAV 不支持原子重命名，退化为 DELETE 损坏文件"，与 LocalFS 的 rename 行为不等价。
5. **`init` 的副作用范围**：LocalFS 只创建目录；WebDAV 还会执行 ETag 探测并打印警告日志（行 175-181）；SafeServer 只做健康检查，能力探测推迟到首次需要时（懒执行，行 586-595）。
6. **错误处理策略**：`deleteBlob` 在 SafeServer 中遇到 405/404 静默返回（行 299-303），在 WebDAV 中 404 也静默但其他错误抛 `BackendUnavailableException`（行 372-375）。LocalFS 则任何错误都抛出（行 161-167）。
7. **常量 `kManifestBackupRingCount` 共享**（sync_backend.dart 行 216），三个 backend 都用环形 5 份，但落地位置不同：LocalFS 落 vault 子目录、WebDAV 落服务端子目录、SafeServer v2.2 落服务端但降级时落客户端 temp 目录。

**结论**：接口签名统一，但容错降级路径和语义细节不统一。SafeServer 最复杂（双路径），WebDAV 次之（HTTP 协议限制），LocalFS 最简单直接。

---

## 4. 复杂度热点分布

### 4.1 加密（散布在 3 个文件）

- [crypto.dart](file:///c:/Home/Projects/safenotes/lib/sync/crypto.dart)：底层 AES-256-GCM 原语、PBKDF2 派生、信封格式 `nonce(12) ‖ ciphertext ‖ tag(16)`、AAD 构造（行 185-190 `_blobAad`，支持 `'$epoch|$id'` / `id` 两种格式）。
- [vault.dart](file:///c:/Home/Projects/safenotes/lib/sync/vault.dart)：两层密钥架构（MK / dataKey）、wrap/unwrap、改密码、4 种生命周期场景、scenario-d 迁移。
- [sync_models.dart](file:///c:/Home/Projects/safenotes/lib/sync/sync_models.dart)：`ManifestCrypto` 类（行 675-781）— manifest 序列化：`[4字节大端 header 长度][header JSON 明文][AES-GCM 加密的 items]`，AAD 固定 `'manifest-items'`。

### 4.2 冲突解决（集中在 sync_engine.dart）

- `_resolveConflict`（行 1207-1212）：LWW 规则 — updatedAt 大的胜；相等则 hash 字典序小的胜（兜底）。
- `_preserveConflictCopy`（行 1098-1200）：E1 修复 — 时间差 > 5 分钟且 hash 不同时，败方内容生成新 UUID 存为新笔记 + 上传 blob + 加入 mergedItems。
- `_itemsEqual`（行 1083-1085）：仅比较 `hash + deleted`，不比较 updatedAt（updatedAt 相同但 hash 不同走冲突流程）。

### 4.3 版本号（散布在 3 个文件，3 套独立版本号）

- `manifest.version`（sync_models.dart 行 268）：每次 PUT +1，调试用，**不是乐观锁依据**。
- `keyVersion`（vault.dart 行 160、sync_models.dart 行 294）：单调递增，createNew=1，changePassword +1，防止旧密码设备回滚。
- `dataKeyEpoch`（vault.dart 行 174、sync_models.dart 行 318）：Layer 3 显式标记，仅在 dataKey 值真正变化时 +1（scenario-d 迁移），与 keyVersion 独立。
- `keyFingerprint = H(MK)`（vault.dart 行 153）：跨设备一致的密钥指纹。
- ETag（sync_backend.dart 行 73）：远端实际版本标识，是乐观锁的唯一依据。

### 4.4 Tombstone（墓碑）

- `ManifestItem.deleted` 字段（sync_models.dart 行 69）+ `deletedAt`（行 94）。
- 阈值 `kTombstoneGcThresholdMs = 30 天`（sync_engine.dart 行 96）。
- GC 逻辑：`_buildLocalManifest` 行 836-839 硬删除过期墓碑；`_downloadNote` 行 1336-1352 应用远端墓碑到本地；`_mergeAndTransfer` 行 920-929 处理首次上传时的墓碑。

### 4.5 重试（集中在 sync_engine.dart）

- `sync()` 行 133-180：乐观锁冲突重试循环，`maxRetries = 3`。
- 两种触发重试的异常：`ConflictException`（行 151）和 `_MigrationRequiredException`（行 160）。
- 注意：迁移重试"复用循环但不计入冲突次数"（行 170 注释），逻辑略 tricky。

### 4.6 错误处理（散布在所有文件，最大的复杂度热点）

- 3 个全局异常类型（sync_backend.dart 行 187-213）+ 2 个 vault 异常（vault.dart 行 57-74）+ 1 个引擎内部异常（sync_engine.dart 行 1811）。
- **大量使用 `on Object` 兜底**（cryptography 包的 `InvalidTag` 继承自 `Error` 而非 `Exception`，行 1330 注释解释原因）：
  - sync_engine.dart 行 554、1254、1295、1301、1513、1570、1619、1640
  - 这导致错误类型信息丢失，调试困难。

### 4.7 容错自愈（集中在 sync_engine.dart，分 4 层）

- **Layer 1**（单 blob 故障隔离）：`_uploadNote` 行 1254 `on Object` → `SyncActionType.uploadFailed`；`_downloadNote` 行 1513 `on Object` → `_handleDownloadFailure`。
- **Layer 2a**（密钥变更后强制重传）：`_mergeAndTransfer` 行 986-993 检查 `pendingReupload`；`vault.migrateToRemote` 行 543 `database.markAllForBlobReupload`；`_updateLocalState` 行 505 `clearAllPendingReupload`。
- **Layer 2b**（本机明文自愈）：`_handleDownloadFailure` 行 1542-1640 — 本机有明文则重传覆盖坏 blob；同内容孪生笔记去重自愈（行 1583-1622）。
- **Layer 3**（显式密钥纪元）：`_openBlobEnvelope` 行 1284-1305 三重兼容解密（epoch > 0 → v2 AAD=hash → v1 AAD=uuid）；`_downloadNote` 行 1427-1483 检测旧密钥 blob 并现代化重传。

### 4.8 GC（垃圾回收，集中在 sync_engine.dart）

- `_gcOrphanBlobs` 行 1689-1722：孤儿 blob GC（listBlobs - referenced = orphans）。
- `_buildLocalManifest` 行 836-839：墓碑 GC（> 30 天硬删除）。
- `_updateLocalState` 行 1658-1666：purged uuid 清理。

---

## 5. 可观测性机制

### 5.1 已有的统一机制

- **状态机**：`SyncStatus` 枚举（sync_service.dart 行 39-54）— `uninitialized / idle / syncing / success / error`，通过 `stateStream`（行 120）以 `StreamController.broadcast` 暴露给 UI。
- **状态快照**：`SyncServiceState`（行 57-88）含 `status / lastSyncTime / lastResult / errorMessage`。
- **操作记录**：`SyncAction` + `SyncActionType` 枚举（sync_models.dart 行 499-528）— 9 种操作类型（`upload / download / delete / skip / conflict / migrate / uploadFailed / corrupt / heal`），每条带 `uuid / hash / message`，全部累积到 `SyncResult.actions` 列表。
- **结果统计**：`SyncResult`（行 531-666）含 `uploaded / downloaded / deleted / skipped / conflicts / migrated / attempts / passwordEpochMismatch / failedNoteUuids`，并提供 `hasChanges / hasFailures / hasConflicts / conflictMessage` 等便捷属性（行 603-628）。

### 5.2 散落/缺失之处

1. **日志不统一**：
   - `webdav_backend.dart` 行 49 引入 `package:logger/logger.dart`，仅在 ETag 不支持时打印一次警告（行 177-180）。
   - `local_fs_backend.dart`、`safe_server_backend.dart`、`sync_engine.dart`、`sync_service.dart` **完全没有日志**，只用 `SyncAction.message` 字段携带中文描述字符串。
2. **无结构化事件流**：所有诊断信息都塞在 `SyncAction.message` 字符串里（如行 228 `'远端 manifest 损坏已备份：$e'`、行 1376 `'download: blob 缺失，本机有明文重传修复'`），无机器可解析的事件 schema。
3. **无 metrics/counter**：`SyncResult` 只统计单次同步的计数，无历史指标（如成功率、冲突频率、平均重试次数），无法做趋势分析。
4. **状态机非严格**：`SyncService.sync()` 行 313-320 在 success/error 之间转换，但 `autoSync()` 行 409-422 是 fire-and-forget，状态转换发生在异步回调中，UI 可能错过中间状态。
5. **`attempts` 字段**（sync_models.dart 行 541）：记录实际重试次数用于诊断乐观锁冲突频率，但只在 `SyncResult` 中暴露，无聚合视图。

**总体评价**：有统一的状态机和操作记录，但缺乏统一的日志/事件/metrics 体系，诊断信息散落在 `SyncAction.message` 字符串和零星的 `_logger.w` 调用中。

---

## 6. 错误处理与异常类型

### 6.1 定义的异常类型（6 个）

| 异常 | 文件:行 | 用途 |
|------|---------|------|
| `ConflictException` | sync_backend.dart:187 | 乐观锁冲突（ETag 不匹配） |
| `BackendUnavailableException` | sync_backend.dart:198 | 网络/5xx/认证失败 |
| `BackendNotInitializedException` | sync_backend.dart:209 | 未调 init 就用 |
| `WrongPasswordException` | vault.dart:57 | GCM tag 验证失败（密码错误） |
| `VaultNotInitializedException` | vault.dart:66 | 本地无 vault 元数据 |
| `_MigrationRequiredException` | sync_engine.dart:1811 | 内部：迁移完成需重新同步 |

### 6.2 异常使用的不一致之处

1. **`on Object` 滥用**（sync_engine.dart 多处）：因为 pointycastle 的 `InvalidTag` 继承自 `Error` 而非 `Exception`（行 1330 注释），引擎内大量使用 `on Object` 兜底，吞掉了所有错误类型信息。具体位置：行 554（repairRemote 解 manifest）、1254（_uploadNote 加密）、1295（_openBlobEnvelope epoch 模式）、1301（v2 AAD）、1513（_downloadNote 解密）、1570（自愈上传）、1619（孪生自愈）。
2. **`on Exception` 与 `on Object` 混用**：
   - `sync_engine.dart` 行 1197 `_preserveConflictCopy` 用 `on Exception`（副本保留失败不阻断）。
   - `sync_engine.dart` 行 1254 `_uploadNote` 用 `on Object`（加密失败容错）。
   - 两者都是"失败不阻断"，但捕获范围不同，语义不一致。
3. **错误消息混用中英文**：
   - 中文：`'密码错误：$e'`（vault.dart 行 509）、`'同步服务未初始化'`（sync_service.dart 行 261）、`'远端 manifest 损坏已备份：$e'`（sync_engine.dart 行 228）。
   - 英文：`'LocalFs: etag mismatch (expected=$expectedEtag, actual=$currentEtag)'`（local_fs_backend.dart 行 110）、`'WebDAV If-Match failed: ...'`（webdav_backend.dart 行 291）、`'locally purged (hard-deleted on this device)'`（sync_engine.dart 行 947）。
   - 同一个 `SyncAction.message` 字段既有中文又有英文，UI 显示不一致。
4. **`BackendUnavailableException` 携带的消息格式不统一**：有的带状态码（`'GET manifest failed: ${res.statusCode} ${res.body}'`，webdav 行 243），有的带异常链（`'GET manifest network error: $e'`，webdav 行 234），有的带建议（`'SafeServer auth failed (401): check token'`，safe_server 行 154）。
5. **`FormatException` 用作业务异常**：sync_engine.dart 行 217 `on FormatException catch (e)` 捕获 manifest 解析失败，这是 dart:convert 的标准异常，但语义上属于"数据损坏"，没有专门的 `ManifestCorruptException`。
6. **静默吞异常**：多处 `on Exception { // ignore }` 完全不记录（如 local_fs_backend.dart 行 137-138 备份失败、行 210-212 跨文件系统 rename 失败、sync_engine.dart 行 170-1722 GC 多处）。
7. **`BackendNotInitializedException` 的 toString 是固定字符串**（sync_backend.dart 行 211-212），不带上下文信息，调试困难。

**总体评价**：异常类型定义较清晰（6 种），但使用方式极不统一：`on Object` / `on Exception` / `on FormatException` 混用，中英文消息混用，静默吞异常普遍，错误信息可观测性差。

---

## 7. 隐藏状态与副作用

### 7.1 全局单例（影响同步行为的全局状态）

1. **`SyncService.instance`**（sync_service.dart 行 96）：整个应用共享一个实例，持有 `_vault / _backend / _engine / _deviceId / _state`，任何地方调用 `SyncService.instance.sync()` 都会触发同一实例。
2. **`SyncConfig._prefs`**（sync_config.dart 行 42）：静态 `SharedPreferences` 实例，所有配置读取共享。
3. **`SyncConfig._webdavPasswordCache / _safeServerTokenCache`**（sync_config.dart 行 167、207）：静态缓存，`init()` 时预加载（行 177-190），之后同步访问。**副作用**：`setWebdavPassword` 后必须更新缓存（行 172-174），否则 `webdavPassword` getter 仍返回旧值。
4. **`DeviceIdProvider.instance`**（sync_service.dart 行 171 引用）：设备 ID 单例，首次调用查询系统 API 后缓存。
5. **`PhraseHandler.getPass`**（sync_service.dart 行 178、205、448 注入为 `passphraseProvider`）：全局密码访问点，scenario-d 迁移时通过它取用户密码。**副作用**：如果用户未登录或会话过期，`getPass` 返回 null，sync_engine.dart 行 291 会进入"退回原失败逻辑"分支。

### 7.2 文件系统状态（影响同步行为的持久化状态）

1. **环形备份索引 `.manifest-bak-index`**（sync_backend.dart 行 232-243）：LocalFS 在 vault 目录、WebDAV/SafeServer v2.2 在服务端 `manifest-backup/` 子目录、SafeServer 降级时在客户端 temp 目录。**副作用**：索引文件损坏会重置 slot 为 0（行 240），可能导致备份覆盖最近一份。
2. **隔离区 `blobs-orphan/`**（local_fs_backend.dart 行 200、webdav_backend.dart 行 434、safe_server_backend.dart 行 409）：软删除的 blob 存放处，文件名格式 `hash.<epochMs>`。**副作用**：30 天保留期内可恢复，但跨设备不会同步隔离区状态。
3. **`.corrupt-{ts}` 备份**（local_fs_backend.dart 行 131）：损坏 manifest 的备份，**永不清理**（无 GC）。
4. **`.ping` 探测文件**（local_fs_backend.dart 行 292）：每次 `ping()` 都会写入再删除，**副作用**：如果文件系统只读，ping 会失败但不会留下垃圾。

### 7.3 数据库隐藏状态（`sync_meta` 表，database_handler.dart 行 73-91 定义）

1. **`vault_id / encrypted_data_key / kdf_salt / key_fingerprint / key_version / vault_created_at / data_key_epoch`**：vault 元数据，`vault.dart` 中 `createNew / unlockLocal / migrateToRemote / adoptRemoteEpoch` 等方法读写。
2. **`purged_uuids`**（MetaKeys.purgedUuids，行 83）：M1 修复 — 用户硬删除的 uuid 列表，`_mergeAndTransfer` 行 911 读取、`_updateLocalState` 行 1658 清理。**副作用**：如果 PUT manifest 失败重试，本地已 hardDelete 但 purgedSet 阻止复活，下次同步仍能清除远端墓碑。
3. **`blob_reupload_pending`**（MetaKeys.blobReuploadPending，行 85）：Layer 2a — 密钥变更后需强制重传的 uuid 集合。**副作用**：`markAllForBlobReupload` 后所有笔记进入集合，`clearAllPendingReupload` 只在 PUT manifest 成功后调用（sync_engine.dart 行 505），形成闭环。
4. **`data_key_history`**（MetaKeys.dataKeyHistory，行 91）：归档的历史 wrappedDataKey，供 `repairRemote` 用旧密码恢复（sync_engine.dart 行 573-581）。**副作用**：scenario-d 迁移和改密码都会 append（vault.dart 行 552-557、765-769），永不清理，可能成为隐私泄露点。
5. **`manifest_version`（按 providerKey 隔离）**：`_buildLocalManifest` 行 871 读取、`_updateLocalState` 行 1652 写入。**副作用**：切换 backend 时 providerKey 变化，自动走首次同步；切回原 backend 时恢复增量同步。

### 7.4 内存中的可变状态

1. **`SyncEngine.vault`**（sync_engine.dart 行 66，非 final）：迁移后会被 `vault.migrateToRemote` 返回的新实例替换（行 766、793）。**副作用**：注释明确警告"不能缓存 dataKey 副本，需每次通过 vault.dataKey 获取"（行 64-65）。
2. **`Vault.encryptedDataKey / keyFingerprint / keyVersion / dataKeyEpoch`**（vault.dart 行 145、153、160、174，均非 final）：`adoptRemoteEpoch / updateEncryptedDataKey / migrateToRemote` 会原地修改。**副作用**：如果其他地方持有 Vault 引用副本，会看到字段变化。
3. **`Vault.mk`**（vault.dart 行 194）：MK 内存缓存，不持久化，logout 时不显式清零（仅 `_vault = null`，依赖 GC）。
4. **`NotesDatabase._dataKey`**（database_handler.dart 行 117）：`setDataKey` 注入的 dataKey，所有 read/write 自动加解密。**副作用**：迁移时 `vault.migrateToRemote` 行 562 调用 `database.setDataKey(remoteDataKey)`，如果迁移过程中崩溃，DB 中数据可能用旧 key 加密但 `_dataKey` 已切换为新 key。
5. **`WebDavBackend._etagSupported / _etagWarningLogged`**（webdav_backend.dart 行 85、90）：init 时探测一次，之后不变。**副作用**：如果服务器中途升级支持 ETag，需要重启应用才生效。
6. **`SafeServerBackend._resourcesSupported / _resourcesProbed`**（safe_server_backend.dart 行 72-75）：懒探测，首次需要时执行。**副作用**：探测结果缓存到实例生命周期结束，服务端升级 v2.2 后需重新创建 backend 实例。
7. **`LocalFsBackend._initialized / WebDavBackend._initialized / SafeServerBackend._initialized`**：私有标志，`close()` 后置 false。**副作用**：`SyncService` 的 `_backendReady` 是独立标志（sync_service.dart 行 144），两者可能不同步（Bug A 修复就是处理这种不同步）。
8. **`SyncService._autoSyncTimer`**（sync_service.dart 行 150）：debounce 定时器，`autoSync()` 行 413 每次都 cancel 再重启。**副作用**：L3 修复（行 407-421）— 如果同步被互斥锁跳过，会重新排程一次，可能导致连续两次同步。

### 7.5 跨设备/跨进程的隐藏状态

1. **ETag**：远端实际版本标识，是乐观锁依据。**副作用**：LocalFS 用文件 SHA-256 作 ETag（每次写入必然变化），WebDAV/SafeServer 依赖服务器返回的 ETag，服务器不返回时退化为内容 hash（webdav_backend.dart 行 252），此时 If-Match 可能被服务器忽略（行 251 注释），退化为"最后写入胜"。
2. **manifest version**（manifest header 中的 `version` 字段）：每次 PUT +1，但**不是乐观锁依据**（sync_models.dart 行 268 注释明确说明）。**副作用**：D3 修复（sync_engine.dart 行 448-481）通过 `_hasEffectiveChange` 判断避免无意义 +1，但仍有边缘情况可能导致 version 攀升。
3. **隔离区不同步**：`blobs-orphan/` 是 per-device 的，设备 A 软删除的 blob 不会同步到设备 B 的隔离区。**副作用**：设备 B 的 `listBlobs` 仍会看到该 blob（如果设备 A 还没 purge），可能误判为孤儿再次软删除（但幂等，无数据损失）。

---

## 8. 总结

这是一个**功能完备但复杂度已经显著膨胀的同步引擎**。核心架构（三层分离、抽象 backend、内容寻址、ETag 乐观锁、两层密钥）设计合理，但因密钥迁移、容错自愈、冲突保留、墓碑 GC 等需求叠加了大量补丁（注释中可见 20+ 个编号修复），导致：

- **复杂度热点高度集中在 `sync_engine.dart`**（1800+ 行，单文件包含 5 步同步、4 层容错、3 种迁移、2 种 GC、冲突解决、版本号管理）。
- **错误处理不统一**（`on Object` / `on Exception` / `on FormatException` 混用，中英文消息混用，静默吞异常普遍）。
- **可观测性不足**（有状态机和操作记录，但无统一日志/metrics/事件流）。
- **隐藏状态分散**（数据库 7+ 个 meta 键、文件系统 4 类辅助文件、内存 6+ 个可变字段、3 个全局单例）。
- **三个 backend 接口签名统一但语义不一致**（SafeServer 最复杂有双路径，WebDAV 受协议限制有降级，LocalFS 最简单）。

最大的技术债在于错误处理和可观测性：`on Object` 兜底吞掉了错误类型信息，`SyncAction.message` 字符串成为唯一的诊断渠道但格式不统一，无结构化日志或 metrics 让生产环境调试困难。

---

## 附：关键文件清单

| 文件 | 路径 | 行数 | 职责 |
|------|------|------|------|
| sync_engine.dart | [lib/sync/sync_engine.dart](file:///c:/Home/Projects/safenotes/lib/sync/sync_engine.dart) | 1800+ | 核心引擎 |
| sync_service.dart | [lib/sync/sync_service.dart](file:///c:/Home/Projects/safenotes/lib/sync/sync_service.dart) | ~600 | 应用服务层 |
| sync_backend.dart | [lib/sync/sync_backend.dart](file:///c:/Home/Projects/safenotes/lib/sync/sync_backend.dart) | ~250 | 抽象接口 |
| sync_models.dart | [lib/sync/sync_models.dart](file:///c:/Home/Projects/safenotes/lib/sync/sync_models.dart) | ~780 | 数据模型 + ManifestCrypto |
| sync_config.dart | [lib/sync/sync_config.dart](file:///c:/Home/Projects/safenotes/lib/sync/sync_config.dart) | ~245 | 配置管理 |
| crypto.dart | [lib/sync/crypto.dart](file:///c:/Home/Projects/safenotes/lib/sync/crypto.dart) | ~310 | 加密原语 |
| vault.dart | [lib/sync/vault.dart](file:///c:/Home/Projects/safenotes/lib/sync/vault.dart) | ~890 | 密钥管理 |
| local_fs_backend.dart | [lib/sync/local_fs_backend.dart](file:///c:/Home/Projects/safenotes/lib/sync/local_fs_backend.dart) | ~305 | LocalFS 后端 |
| webdav_backend.dart | [lib/sync/webdav_backend.dart](file:///c:/Home/Projects/safenotes/lib/sync/webdav_backend.dart) | ~725 | WebDAV 后端 |
| safe_server_backend.dart | [lib/sync/safe_server_backend.dart](file:///c:/Home/Projects/safenotes/lib/sync/safe_server_backend.dart) | ~740 | SafeServer 后端 |
| database_handler.dart | [lib/data/database_handler.dart](file:///c:/Home/Projects/safenotes/lib/data/database_handler.dart) | — | 数据库层（MetaKeys 定义在行 73-91） |
