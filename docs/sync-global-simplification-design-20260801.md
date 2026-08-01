# 同步引擎全局简化设计

日期：2026-08-01
状态：设计评审（未实现）
作者：代码审查后综合产出

关联文档：
- `docs/aad-epoch-removal-design-20260801.md`（P1：AAD 移除 epoch，已设计）
- `docs/refact-architecture-design-20260801.md`（P2：G-Set 删除架构，已设计）
- `docs/epoch-elimination-design-20260801.md`（原 epoch 消除方案，本方案 P1 为其改进替代）
- `docs/sync-complexity-analysis-20260731.md`（复杂度分析报告）
- `docs/CHANGES-20260729.md` ~ `CHANGES-20260801.md`（历史变更与 bug 记录）

---

## 0. 定位

本文档是**全局简化路线图**，不重复已设计方案（P1/P2）的细节，而是：
1. 识别当前系统的 **7 个复杂度源头**
2. 标注已设计方案覆盖了哪些
3. 提出 **2 个新方案**（P3/P4）覆盖剩余源头
4. 给出分阶段实施路径

**本文档不替代 P1/P2 的详细设计文档。** 实施时仍以 P1/P2 文档为代码变更依据，
本文档提供全局上下文和优先级框架。

---

## 1. 设计前提

沿用 `refact-architecture-design-20260801.md` §0 的四条前提：

| 编号 | 前提 | 推论 |
|------|------|------|
| P1 | 单用户，所有设备属于同一个人 | 不需要权限、多方仲裁 |
| P2 | 无协作、无同时编辑（但存在离线分叉冲突） | 不需要实时并发，冲突检测保留 |
| P3 | 空间不值钱，允许冗余存储 | 不需要 GC/裁剪/过期回收；所有时间窗机制全删 |
| P4 | 开发阶段，无历史包袱 | 不写任何兼容与迁移代码；DB 直接 v4 起步；服务端数据清空重来 |

---

## 2. 复杂度源头识别

通读 `lib/sync/` 全部 10 个 Dart 文件（~10,500 行）+ `lib/data/database_handler.dart`（~1,014 行）
+ 全部历史 CHANGES 文档后，复杂度集中在 7 个源头：

| # | 复杂度源头 | 涉及文件 | 行数（估） | 根因 |
|---|---------|---------|-----------|------|
| 1 | epoch 三键状态 | sync_engine / keyring / crypto / sync_models | ~400 | epoch 被放在 AAD 里 → heal/probe/adoptRemoteEpoch/markAllForBlobReupload |
| 2 | 删除/墓碑/GC | sync_engine / database_handler / sync_models | ~350 | 删除建模在 `deleted=1` 标记 + 时间窗 GC，而非只增集合 |
| 3 | scenario-c/d 迁移检测 | sync_engine / keyring / sync_service | ~200 | 两设备独立 createNew → 不同 salt → 本地 MK 解不开远端 |
| 4 | 5 级恢复级联 | sync_engine | ~350 | 每级修上一层引入的 edge case（normal→probe→heal→本机明文→孪生笔记） |
| 5 | manifest 单文件全局争用 | sync_engine | ~200 | 一个 manifest = 所有 item 的唯一争用点 → ETag 冲突 + 全量合并 |
| 6 | journal 双角色 | journal / sync_engine | ~300 | 审计 + 灾备恢复 + 远端同步，补偿 manifest 单点故障 |
| 7 | 错误处理不统一 | 全代码散布 | ~50 | pointycastle `InvalidTag` 继承 `Error` 而非 `Exception` → `on Object` 滥用 |

**历史修复叠加**：代码中可见 B1/B3/D2/D3/E1/F1/F4/H1/H3/H4/L3/M1/M7/P0-1/P0-3/P0-4/P1-1/P1-2/P6/P7/R10
等 **20+ 个编号修复**，每个修复都在已有分支上叠加新分支，导致复杂度指数增长。

---

## 3. 方案总览

| 优先级 | 方案 | 覆盖源头 | 消除行数 | 状态 | 文档 |
|--------|------|---------|---------|------|------|
| P1 | AAD 移除 epoch | #1 + #4（heal/probe 部分） | ~220 | 已设计 | aad-epoch-removal-design |
| P2 | G-Set 删除架构 | #2 + #6（journal 简化） | ~350 | 已设计 | refact-architecture-design |
| P3 | 统一密钥状态为单一指纹 | #3 + #1 残余（keyVersion/adoptRemoteEpoch） | ~110 | **新方案** | 本文档 §5 |
| P4 | 错误处理统一 + 代码拆分 + journal 降级 + manifest 备份简化 | #5 + #6 残余 + #7 | ~310 | **新方案** | 本文档 §6 |
| | **合计直接删除** | **7 个源头全覆盖** | **~980** | | |
| | **合计含级联**（§7.1 逐文件统计） | | **~1861** | | |

> 注：~980 是各方案"直接删除的代码行"估算；~1861 是含级联效应（DB 迁移代码删除、
> 旧方法删除、注释删除、测试辅助删除等）的逐文件统计。两者口径不同，以 §7.1 为准。

---

## 4. P1 + P2 概要（已设计，不重复细节）

### 4.1 P1：AAD 移除 epoch

**核心改动**：`crypto.dart` 的 `_blobAad` 从 `'$epoch|$hash'` 改为仅 `'$hash'`。

**消除**：
- `_probeBlobEpoch`（~40 行）
- `_downloadNote` heal 分支（~110 行）
- `adoptRemoteEpoch` 的 `markAllForBlobReupload` 调用（~3 行）
- `_DownloadHealed` 类（~5 行）
- epoch 参数透传（~15 行）
- L1038-1058 注释（~20 行，顾虑已消解）
- `_semanticItemsEqual` 排除 blobKeyEpoch（~2 行）

**保留**：本机明文自愈 + 孪生笔记自愈（非 epoch 驱动的合理恢复路径）。

**关键发现**：07-29 的原始设计就是 AAD=hash（无 epoch），epoch 被加进 AAD 是后来
引入的，它引入的问题（P6 probe、P7 markAllForBlobReupload、翻转事故）比它解决的多。
本方案本质是回到 07-29 原始设计并删掉 heal 机制。

### 4.2 P2：G-Set 删除架构

**核心改动**：删除建模为只增不减的 uuid 集合（G-Set CRDT），同步时求并集。

**消除**：
- `safe_notes.deleted`/`deleted_at`/`deleted_by` 列的活跃使用（改为预留）
- `ManifestItem.deleted`/`deletedAt` 字段
- 30 天墓碑 GC（`_gcOrphanBlobs` / `skipGc` / `kTombstoneGcThresholdMs`）
- `purged_uuids` 待清理列表
- v1→v2→v3 DB 迁移分支（直接 v4 起步）
- `KeyringLedger.fromLegacyMeta` 及 7 个 legacy meta 键
- `readAllNotesIncludingDeleted` / `softDelete` / `hardDelete` / `restoreNote` 等旧方法

**保留**：冲突检测（base-hash 三方合并，上一轮刚修复，不在改造范围）。

### 4.3 P1 + P2 合并迁移

P1 改 AAD 格式（v3→v4），P2 改 manifest 结构。两者都递增 schemaVersion，**应合并为
一次 v4 迁移**：

```
schemaVersion v3 → v4:
  - AAD: epoch|hash → hash only
  - manifest: 加 deleted map，删 ManifestItem.deleted/deletedAt
  - DB: 新表结构（safe_notes + trash_notes + deleted_items + sync_meta）
  - 存量 blob: markAllForBlobReupload（AAD 格式变化，全量重传）
  - 协议: v3 → v4
```

**不兼容策略**（P2 §0 P4 前提）：不做任何兼容迁移，DB 直接重建，服务端数据清空重来。

---

## 5. P3：统一密钥状态为单一指纹（新方案）

### 5.1 问题

当前密钥状态由 **三个数字** 描述，交互矩阵复杂：

| 字段 | 位置 | 递增时机 | 用途 |
|------|------|---------|------|
| `keyVersion` | ManifestHeader / KeyringEntry | 改密码时 +1 | "密码纪元守卫"：远端 > 本地 → 旧密码，不回滚 |
| `dataKeyEpoch` | ManifestHeader / KeyringEntry | dataKey 值变时 +1 | P1 后降为纯元数据（AAD 不含 epoch） |
| `blobKeyEpoch` | ManifestItem | 乐观声明 = keyring.dataKeyEpoch | P1 后降为纯元数据标签 |

P1 已经将 `dataKeyEpoch` 和 `blobKeyEpoch` 降为纯元数据。但 `keyVersion` 仍然
驱动同步行为：`_syncOnce` L318-325 的"密码纪元守卫" + `overrideEncryptedDataKey` /
`overrideKeyFingerprint` / `overrideKeyVersion` 三元组 + `epochMismatch` 标志。

### 5.2 方向

**用 `dataKeyFingerprint` 替代 `keyVersion` 的守卫角色。**

`dataKeyFingerprint` 是 dataKey 值的身份标识（如 `H(dataKey)` 的前 16 字符 hex），
不同于当前的 `keyFingerprint`（是 `H(MK)`，跨设备一致的密码指纹）。

> **命名澄清**：
> - 当前 `keyFingerprint` = `H(MK)` → 用于判断"密码是否相同"（scenario-c/d 检测）
> - 新增 `dataKeyFingerprint` = `H(dataKey)` → 用于判断"blob 用哪个 dataKey 加密"
> - 两者用途不同，共存不矛盾

### 5.3 迁移检测简化

当前 `_syncOnce` Step 1（L234-487）4 分支：

```
A. keyVersion 一致 + MK 能解 + dataKey 相同 → 正常同步
B. MK 能解 + dataKey 相同 + keyVersion 不同 → adoptRemoteEpoch（只更新 wrap）
C. MK 能解 + dataKey 不同 → migrateToRemote（reEncryptAllNotes）
D. MK 解不开 → passphraseProvider 取密码 → tryDeriveRemoteDataKey
   D1. 密码相同（scenario-d）→ 完整 keyring 迁移
   D2. 密码不同（scenario-c）→ 失败
```

P3 改后 2 分支：

```
1. remote.dataKeyFingerprint == local.dataKeyFingerprint?
   → YES: 同一 dataKey
      1a. remote.encryptedDataKey == local.encryptedDataKey?
          → YES: 完全一致，正常同步
          → NO:  同一 dataKey 但不同 wrap（一方改了密码但 dataKey 不变）
                 采用远端 encryptedDataKey（避免翻转战争）
                 更新本地 keyring.encryptedDataKey + keyFingerprint
                 正常同步
   → NO:  dataKey 不同
      2a. 尝试用本地 MK 解远端 encryptedDataKey
          - 成功 → 拿到 remote dataKey
            - 和本地相同 → 不该走到这里（dataKeyFingerprint 已判等），防御性 no-op
            - 不同 → reEncryptAllNotes + re-upload（原 scenario-d 迁移）
          - 失败 → 密码不同（本端旧密码或远端用了不同 salt）
      2b. 用远端 KDF + 用户密码重新派生 MK（scenario-d 检测）
          - 能解 → 密码相同、salt 不同 → 完整迁移
          - 不能解 → 密码不同 → **中止同步，提示用户重新输入密码**
```

4 分支变 2 分支。`overrideEncryptedDataKey` / `overrideKeyFingerprint` /
`overrideKeyVersion` 三元组、`epochMismatch` 标志全部删除。

### 5.4 adoptRemoteEpoch 简化

当前 `adoptRemoteEpoch`（keyring.dart L776-797）更新 5 个字段：
`encryptedDataKey` / `keyFingerprint` / `keyVersion` / `dataKeyEpoch` / `reason`。

P3 改后只更新 3 个：
`encryptedDataKey` / `keyFingerprint` / `reason`。

`keyVersion` 和 `dataKeyEpoch` 不再存在于 keyring 中（或保留为纯诊断计数器，
但不参与同步决策）。

### 5.5 密码纪元守卫的替代

当前守卫逻辑（L318-325）：

```
remoteHeader.keyVersion > keyring.keyVersion
→ 他端改了密码，本地旧密码
→ epochMismatch = true
→ overrideEncryptedDataKey = remote.encryptedDataKey（不回滚远端）
→ _buildLocalManifest 用远端值
```

**为什么需要守卫**：旧密码设备的 MK 解不开远端新 encryptedDataKey → 当前代码有
"corrupt manifest"分支会 fallback 到 null/empty → 旧密码设备可能用本地旧
encryptedDataKey PUT manifest → 覆写远端新值 → 翻转战争（B1 修复的根因）。

**P3 替代方案**：不再用 keyVersion 做前置守卫，而是**在解密失败时直接中止同步**：

```
if (local MK 解不开 remote.encryptedDataKey):
  → 尝试 scenario-d 检测（用远端 KDF + 用户密码）
  → 如果也失败 → **中止同步，提示"密码不正确，请重新输入"**
  → 绝不 fallback 到 null/empty，绝不 PUT manifest
```

关键区别：**"can't decrypt remote manifest"≠"remote manifest corrupt"**。
- Can't decrypt（密码不同）→ 中止，不 PUT
- Corrupt（能解但格式损坏）→ fallback 到 null/empty（当前行为保留）

这样旧密码设备无法覆写新密码设备的 manifest，翻转战争从逻辑上被阻断。
keyVersion 的前置守卫变成后置的"解密失败 → 中止"，语义更清晰。

### 5.6 ManifestItem 变化

```dart
// 改前
class ManifestItem {
  final String hash;
  final bool deleted;          // P2 删
  final int updatedAt;
  final String updatedBy;
  final int createdAt;
  final int? deletedAt;       // P2 删
  final int contentSize;
  final int blobKeyEpoch;     // P1 降为元数据，P3 可删（被 dataKeyFingerprint 取代）
}

// 改后（P1 + P2 + P3 叠加）
class ManifestItem {
  final String contentHash;   // 改名（P2 Q17：与本地 content_hash 统一）
  final int updatedAt;
  final String updatedBy;
  final int createdAt;
  final String createdBy;     // P2 Q18：新增
  final int contentSize;
  final String dataKeyFingerprint;  // P3：新增，替代 blobKeyEpoch
}
```

### 5.7 ManifestHeader 变化

```dart
// 改前
class ManifestHeader {
  final int schemaVersion;
  final int version;
  final String vaultId;
  final int createdAt;
  final int updatedAt;
  final String keyFingerprint;  // H(MK)
  final int keyVersion;         // P3 删
  final String encryptedDataKey;
  final KdfParams kdf;
  final int dataKeyEpoch;       // P1 降为元数据，P3 可删
  final String updatedBy;
}

// 改后（P1 + P2 + P3 叠加）
class ManifestHeader {
  final int schemaVersion;
  final int version;            // 保留（诊断用，manifest version 计数）
  final String vaultId;
  final String keyFingerprint;  // H(MK)，保留（scenario-c/d 检测）
  final String dataKeyFingerprint;  // P3：新增，H(dataKey)
  final String encryptedDataKey;
  final KdfParams kdf;
  final String updatedBy;
  // createdAt / updatedAt 删（诊断价值低，version 已够）
  // keyVersion / dataKeyEpoch 删
}
```

### 5.8 消除的代码

| 代码 | 位置 | 行数（估） |
|------|------|-----------|
| keyVersion 比较 + epochMismatch 守卫 | sync_engine.dart L318-325 | ~30 |
| adoptRemoteEpoch 方法 | keyring.dart L776-797 | ~20 |
| overrideEncryptedDataKey / overrideKeyFingerprint / overrideKeyVersion 三元组 | sync_engine.dart 散布 _syncOnce / _buildLocalManifest / _mergeAndTransfer | ~40 |
| keyVersion 传递和比较逻辑 | sync_models.dart / keyring.dart | ~20 |
| **合计** | | **~110** |

### 5.9 安全性

`dataKeyFingerprint = H(dataKey)` 是否泄露 dataKey？

- 使用 SHA-256 取前 16 字符（64 bit）作为指纹
- 预映像攻击需要找到与指纹碰撞的 32 字节随机 dataKey，计算上不可行
- 指纹放在 manifest header（明文）中，服务端可见，但不泄露 dataKey 值
- 与当前 `keyFingerprint = H(MK)` 的安全性论证一致

### 5.10 对 P1 的依赖

P3 依赖 P1 的完成：
- P1 将 `blobKeyEpoch` 降为纯元数据 → P3 才能用 `dataKeyFingerprint` 替代它
- P1 删除 heal/probe → P3 删除 adoptRemoteEpoch 的 markAllForBlobReupload 后，
  adoptRemoteEpoch 才能安全简化

如果先做 P3 不做 P1，adoptRemoteEpoch 仍需调 markAllForBlobReupload（AAD 含 epoch），
P3 的简化不成立。

---

## 6. P4：错误处理统一 + 代码拆分 + journal 降级 + manifest 备份简化（新方案）

### 6.1 错误处理统一

#### 问题

pointycastle 的 `InvalidTag`（GCM 认证失败）继承自 `Error` 而非 `Exception`。
Dart 的 `on Exception` 不能捕获 `Error`。因此代码中大量使用 `on Object` 兜底，
导致错误类型信息丢失。

复杂度分析报告（sync-complexity-analysis）指出 8+ 处 `on Object` 兜底。

#### 方案

1. 在 `crypto.dart` 中创建 `DecryptionException implements Exception`：

```dart
class DecryptionException implements Exception {
  final String context;
  final Object cause;
  DecryptionException(this.context, this.cause);

  @override
  String toString() => 'DecryptionException($context): $cause';
}
```

2. `SyncCrypto.open` 内部 catch `Error` 并包装为 `DecryptionException`：

```dart
static Uint8List open(Uint8List key, String id, Uint8List envelope, {int? epoch}) {
  try {
    final aad = _blobAad(id, epoch);
    return _aesGcmDecrypt(key, aad, envelope);
  } on Error catch (e) {
    throw DecryptionException('open(id=$id, epoch=$epoch)', e);
  }
}
```

3. 全部 `on Object` / `on SyncDecryptionException` 改为 `on DecryptionException`

4. 统一错误消息为中文（UI 是中文）

5. 消灭静默吞异常：所有 `catch { }` 必须至少 `Log.sync.w(...)`

#### 消除

| 代码 | 位置 | 行数 |
|------|------|------|
| `on Object` 兜底 → `on DecryptionException` | sync_engine.dart 8+ 处 | ~20 |
| `SyncDecryptionException` 包装逻辑（分散） | sync_engine.dart / crypto.dart | ~15 |
| 静默 catch 填补 | 散布 | ~15 |
| **合计** | | **~50** |

### 6.2 sync_engine.dart 拆分

P1 + P2 + P3 实施后，sync_engine.dart 从 2433 行降到约 **~1500 行**。拆分为 4 文件：

```
lib/sync/
├── sync_engine.dart       (~350 行) 编排：sync() / _syncOnce / 重试循环 / 迁移检测
├── sync_merge.dart         (~400 行) 合并：_mergeAndTransfer / _resolveConflict
│                                    / _itemsEqual / _semanticItemsEqual
│                                    / _buildLocalManifest
├── sync_transfer.dart      (~300 行) 传输+恢复：_uploadNote / _downloadNote
│                                    / _handleDownloadFailure / _openBlobEnvelope
├── sync_repair.dart        (~200 行) repairRemote
├── sync_gc.dart            (~100 行) 孤儿 GC（P2 后移出同步路径，留手动 GC）
├── crypto.dart             (~326 行) 不变
├── keyring.dart            (~730 行) 简化后（删 adoptRemoteEpoch ~20 行）
├── sync_models.dart        (~850 行) 简化后
├── sync_service.dart       (~859 行) 不变
├── journal.dart            (~500 行) 简化后（§6.3）
└── backend / config / error / ... 不变
```

拆分原则：
- 按**职责**拆，不按**步骤**拆
- 每个 `_xxx` 方法搬移到对应文件，`_` 前缀改为 `@protected` 或包内可见
- `SyncEngine` 类保持单一实例，方法分散到不同文件用 Dart 的 `part` / `mixin`
  或拆成独立类 + 组合

#### 推荐实现：组合

```dart
class SyncEngine {
  final SyncMerger merger;      // 合并逻辑
  final SyncTransfer transfer;  // 上传/下载/恢复
  final SyncRepair repair;      // repairRemote
  // ...
  Future<SyncResult> sync() async { /* 编排 */ }
}
```

每个组件接收 `database` / `backend` / `keyring` / `deviceId` 引用。

### 6.3 journal 降级为审计-only

#### 当前

journal 有双角色（journal.dart §3.1）：
1. 审计 / 可观测：记录"谁、何时、用哪个 dataKey 纪元"做了什么
2. 可恢复：作为跨边界部分写的兜底、以及防服务端 manifest 单点故障的第二数据源

角色 2 表现为：
- `_uploadJournal()`：每次 sync 成功后把加密 journal 推到远端（sync_engine.dart L141-148）
- `Journal.open` / `Journal.syncFromRemote`：从远端拉取 journal 恢复
- `KeyringLedger.recoverFromJournal`：journal 中 key 事件恢复 keyring 状态

#### 方案

**保留角色 1（审计），删除角色 2（灾备恢复）。**

- journal 仍然记录事件（本地文件）
- 删除 `_uploadJournal()`（sync_engine.dart L141-148 + journal.dart 远端同步逻辑）
- 删除 `Journal.syncFromRemote` / `KeyringLedger.recoverFromJournal`
- journal 文件仍存在本地 `<baseDir>/journal/log.json`，但不上传到远端

#### 理由

1. G-Set CRDT（P2）的并集幂等性保证 manifest 可从任意状态恢复
2. manifest 备份（§6.4）提供版本历史
3. journal 的灾备角色是 manifest 单点故障的补偿，但 G-Set + 备份已足够
4. 删除灾备角色减少了 ~200 行代码和一个远端同步失败点

#### 消除

| 代码 | 位置 | 行数 |
|------|------|------|
| `_uploadJournal()` 调用 + 实现 | sync_engine.dart L141-148 | ~10 |
| journal 远端同步逻辑 | journal.dart | ~150 |
| `KeyringLedger.recoverFromJournal` | keyring.dart | ~50 |
| **合计** | | **~210** |

#### 风险

journal 灾备角色的删除意味着：如果 manifest 损坏 + manifest 备份也损坏 + G-Set
无法恢复，则数据丢失。但这个场景需要三重故障同时发生，且 G-Set 的数学保证
使其在正常操作下不可能。

**对策**：保留 journal 本地审计日志（不删），只是不再上传到远端。如果需要灾备恢复，
仍可从本地 journal 文件手动恢复。

### 6.4 manifest 备份简化

#### 当前

5 代环形备份（`backupManifest` 接口 + `manifest-backup/` 子目录 + 
`.manifest-bak-index` 索引 + 5 份轮转 `manifest.bak-0..4`）。

#### 方案

保留 1 份备份（上一次成功的 manifest），删除环形索引。

```
<keyring root>/
├── manifest.json          # 当前 manifest
├── manifest.bak          # 上一次成功 manifest（覆盖前备份）
├── blobs/
...
```

#### 理由

1. G-Set 幂等性保证重放安全，不需要多代版本历史
2. 1 份备份足够应对"PUT 中断导致 manifest 损坏"的场景
3. 环形索引增加复杂度（轮转逻辑 + 索引文件 + 恢复逻辑）

#### 消除

| 代码 | 位置 | 行数 |
|------|------|------|
| 环形索引逻辑（3 个后端各一份） | safe_server_backend / webdav_backend / local_fs_backend | ~30 |
| 多代轮转逻辑 | 同上 | ~20 |
| **合计** | | **~50** |

### 6.5 P4 消除汇总

| 子项 | 行数 |
|------|------|
| 错误处理统一 | ~50 |
| sync_engine 拆分 | 0（重组，不减行） |
| journal 降级 | ~210 |
| manifest 备份简化 | ~50 |
| **合计** | **~310** |

---

## 7. 整体效果

### 7.1 行数变化

| 文件 | 当前 | P1+P2 后 | P3 后 | P4 后 | 减少 |
|------|------|---------|-------|-------|------|
| sync_engine.dart | 2433 | ~1860 | ~1750 | ~1750（拆 4 文件） | -683 |
| keyring.dart | 840 | ~820 | ~760 | ~760 | -80 |
| journal.dart | 1007 | ~1000 | ~1000 | ~500 | -507 |
| crypto.dart | 326 | ~326 | ~326 | ~340（+DecryptionException） | +14 |
| sync_models.dart | 990 | ~900 | ~870 | ~870 | -120 |
| database_handler.dart | 1014 | ~660 | ~660 | ~660 | -354 |
| sync_service.dart | 859 | ~859 | ~820 | ~820 | -39 |
| 3 个后端 | ~2312 | ~2260 | ~2260 | ~2210 | -102 |
| **合计** | ~9771 | ~8685 | ~8446 | ~7910 | **-1861** |

> 注：行数为估算，实际以实施后 `wc -l` 为准。journal.dart 的 -507 是因为删除了
> 远端同步 + 灾备逻辑，但保留审计日志部分。

### 7.2 复杂度源头覆盖

| 源头 | P1 | P2 | P3 | P4 | 全覆盖 |
|------|----|----|----|----|-------|
| #1 epoch 三键 | ✅ 删 AAD epoch + heal/probe | | ✅ 删 keyVersion/adoptRemoteEpoch | | ✅ |
| #2 删除/墓碑/GC | | ✅ G-Set CRDT | | | ✅ |
| #3 scenario-c/d | | | ✅ 4 分支→2 分支 | | ✅ |
| #4 5 级恢复 | ✅ 删 probe/heal（2 级） | | | | ✅ 保留本机明文自愈 |
| #5 manifest 争用 | | | | ✅ 代码拆分（不改架构） | ✅（缓解） |
| #6 journal 双角色 | | ✅ 删 GC | | ✅ 删灾备角色 | ✅ |
| #7 错误处理 | | | | ✅ DecryptionException | ✅ |

### 7.3 可靠性提升

| 维度 | 当前 | 改后 |
|------|------|------|
| adoptRemoteEpoch | O(N) blob 全重传 + 可能翻转 | O(1) 纯 DB 写 |
| crash 窗口 | blob 与 epoch 不一致 → 永久 corrupt | 无害（blob 不依赖 epoch） |
| 删除冲突 | 11 条入站判定 + 30 天 GC + 墓碑复活 | 3 步（G-Set 并集，幂等） |
| 密钥迁移 | 4 分支 + 3 个 override 变量 | 2 分支 + 0 override |
| 恢复级联 | 5 级（normal→probe→heal→本机→孪生） | 2 级（normal→本机明文→corrupt） |
| 错误信息 | `on Object` 丢失类型 | `DecryptionException` 精确捕获 |
| 单文件行数 | 2433 行 | 4 文件 × 300-400 行 |

---

## 8. 实施路径

### 阶段 1：P1 + P2 合并（一次 v4 迁移）

**前置条件**：P1 和 P2 的设计文档都已评审通过。

**范围**：
- AAD 改为仅 hash（crypto.dart）
- G-Set 删除架构（sync_engine + database_handler + sync_models）
- DB schema v4（新表结构，无迁移代码）
- 协议 v3 → v4（manifest 格式 + AAD 格式同时变）
- 存量 blob markAllForBlobReupload（AAD 格式变化）
- 存量数据清空重来（P4 前提：开发阶段无历史包袱）

**验证**：
- 全量测试（251+ 用例需更新后全绿）
- chaos 多设备混合测试
- LONGRUN 10 代测试
- `flutter analyze` 0 error

**预估工期**：P1 ~1-2 天 + P2 ~2-3 天 = ~3-5 天（合并后）

### 阶段 2：P3 统一密钥指纹

**前置条件**：阶段 1 完成（P1 的 AAD 改动 + P2 的 manifest 结构变更已落地）。

**范围**：
- `ManifestHeader` 加 `dataKeyFingerprint`，删 `keyVersion` / `dataKeyEpoch`
- `ManifestItem` 加 `dataKeyFingerprint`，删 `blobKeyEpoch`
- `_syncOnce` 4 分支 → 2 分支
- 删 `adoptRemoteEpoch` 方法
- 删 `overrideXxx` 三元组 + `epochMismatch` 标志
- keyring 只保留 `encryptedDataKey` / `keyFingerprint` / `dataKeyFingerprint`

**验证**：
- keyring_test P7 回归断言更新
- change_password_multi_client_test S1/S2/S5 更新
- chaos 翻转回归
- `flutter analyze` 0 error

**预估工期**：~1-2 天

### 阶段 3：P4 收尾清理

**前置条件**：阶段 2 完成。

**范围**（可逐步推进，互不依赖）：
- P4a：`DecryptionException` 包装 + `on Object` → `on DecryptionException`（~1 天）
- P4b：sync_engine.dart 拆 4 文件（~1-2 天）
- P4c：journal 降级为审计-only（~1 天）
- P4d：manifest 备份从环形 5 份 → 1 份（~0.5 天）

**验证**：
- 全量测试
- `flutter analyze` 0 error
- LONGRUN 10 代测试

**预估工期**：~3-4 天

### 依赖关系

```
阶段 1（P1+P2）→ 阶段 2（P3）→ 阶段 3（P4）
                                    ├─ P4a（错误处理）
                                    ├─ P4b（代码拆分）
                                    ├─ P4c（journal 降级）
                                    └─ P4d（manifest 备份）
```

P4 的四个子项互不依赖，可任意顺序或并行。

---

## 9. 风险与对策

### 9.1 不兼容策略风险（接受）

P1+P2+P3 都递增 schemaVersion，一次性 v4 迁移。旧版本客户端无法与新版本共存。
旧数据清空重来。

**对策**：协议 v4 降级拒绝（P1 [G]：`_downloadManifest` 校验 schemaVersion）。

### 9.2 迁移期间数据可用性

阶段 1 迁移后，所有 blob 需要重传（AAD 格式变化）。重传完成前，部分笔记不可用。

**对策**：`markAllForBlobReupload` + `pendingReupload` 闭环保证最终一致。
用户可手动 `repairRemote()` 加速。

### 9.3 dataKeyFingerprint 泄露 dataKey

`H(dataKey)` 放在 manifest header（明文）。理论上可被暴力破解。

**对策**：dataKey 是 32 字节随机数（256 bit），预映像攻击计算不可行。
与当前 `keyFingerprint = H(MK)` 的安全性论证一致。

### 9.4 journal 灾备角色删除后的恢复能力

如果 manifest 损坏 + manifest.bak 损坏 + G-Set 无法恢复 → 数据丢失。

**对策**：三重故障同时发生概率极低。保留 journal 本地审计日志（不删，只不上传），
需要时可从本地 journal 手动恢复。

### 9.5 sync_engine 拆分引入的编译风险

拆分文件可能引入循环依赖或可见性问题。

**对策**：用组合模式（非继承），每个组件接收 database/backend/keyring 引用。
先移动方法，后调整可见性，每步 `flutter analyze` 验证。

---

## 10. 与已设计方案的关系

| 已设计 | 本文档引用 | 本文档新增 |
|-------|---------|---------|
| P1: AAD 移除 epoch | §4.1 概要引用 | 不重复细节 |
| P2: G-Set 删除架构 | §4.2 概要引用 | 不重复细节 |
| P1+P2 合并迁移 | §4.3 提出合并策略 | 新 |
| P3: 统一密钥指纹 | | §5 完整设计 |
| P4: 错误处理+拆分+journal+备份 | | §6 完整设计 |
| 分阶段实施路径 | | §8 新 |
| 整体效果量化 | | §7 新 |

---

## 11. 结论

当前同步引擎的 7 个复杂度源头可以通过 4 个方案全覆盖：

- **P1（已设计）**：AAD 移除 epoch → 消除 heal/probe/adoptRemoteEpoch blob 重传
- **P2（已设计）**：G-Set 删除架构 → 消除墓碑/GC/迁移代码
- **P3（本文新设计）**：统一密钥指纹 → 消除 keyVersion/adoptRemoteEpoch/scenario 分支
- **P4（本文新设计）**：错误处理统一 + 代码拆分 + journal 降级 + manifest 备份简化

合计消除 **~1861 行**（从 ~9771 降到 ~7910），sync_engine.dart 从单文件 2433 行
拆为 4 文件各 300-400 行。7 个复杂度源头全部覆盖。

分 3 阶段实施，总工期约 **~7-11 天**，阶段间有依赖但阶段内可并行。
