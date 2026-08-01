# AAD 移除 epoch 设计（从加密参数中消除纪元依赖）

日期：2026-08-01
状态：设计评审（未实现）
关联：`docs/epoch-elimination-design-20260801.md`（同日产出，本方案为其改进替代）
关联事故：`docs/CHANGES-20260801.md`（8 条 manifest 声称 epoch2、blob 实为 epoch1 的脏数据）
演进基线：git `100cffa`（P6/P7 修复 + 设计转向文档）、`cb1eef0`（Q&A 补充）

---

## 0. 与 epoch-elimination-design 的关系

`epoch-elimination-design-20260801.md`（下称"原方案"）的诊断方向是正确的——"item
自描述 + 只读解密 + 删自动改写"——但在**如何让 item 自描述**这一点上，原方案仍然
把 epoch 留在 blob 的 AAD 里，只是把"乐观声明"改成"DB 持久化真实 epoch"。

本方案认为：**epoch 不该出现在 blob 的加密参数里，只该出现在 manifest item 的元数据
里。** 这是让 epoch 回归"纯标签"角色的彻底做法，也是 Joplin / Standard Notes 实际
采用的方式（key id 是 manifest 级元数据，不在 blob 的 AAD 中）。

本方案是原方案的改进替代，不是补充。如果采纳本方案，原方案 §4-§7 中关于 DB 持久化
blobKeyEpoch 的复杂设计、§8.2[A] 的"同一事务"原子性约束、以及 [D2] 的 pendingReupload
矛盾均可简化或消解。兼容性策略（§0 不做旧版本兼容）与本方案一致。

---

## 1. 问题回顾

### 1.1 事故根因（精确还原）

读完 sync_engine.dart / keyring.dart / crypto.dart / database_handler.dart 全部代码
后，事故链还原如下：

1. **Android** scenario-d 迁移：`migrateToRemoteVault` → `reEncryptAllNotes`（用
   Windows 的 dataKey 重新加密本地笔记）+ `markAllForBlobReupload` + epoch 1→2。
   blob 用 `AAD="2|hash"` 重新上传。
2. **Windows** 改密码：`changePassword` → 只重 wrap dataKey（更新
   encryptedDataKey），epoch 不变（=1），blob 零改动。Windows 的 dataKey 值与
   Android 迁移后相同（Android 采用了 Windows 的 dataKey）。
3. Windows 下载 Android 的 item（声明 epoch=2），blob 是 `AAD="2|hash"` 加密。
4. Windows 用 `item.blobKeyEpoch=2` 尝试解密 → dataKey 相同 → **能解开！**
5. 但 `_downloadNote` 的 heal 分支（sync_engine.dart L1783）检查
   `actualEpoch(2) != keyring.dataKeyEpoch(1)` → **触发"现代化"重传**。
6. Windows 用 epoch=1 的 AAD 重新加密上传 → 覆盖了 Android 的 epoch=2 blob。
7. Android 下载发现 epoch=1 ≠ 自己的 2 → 又重传成 epoch=2 → 翻转开始。
8. 双方反复互相覆盖，最终 8 条 manifest 声称 epoch=2、blob 实为 epoch=1。

**致命点**：dataKey 值相同，blob 本来能正常解密。是 heal 的 `!=` 比较制造了"假性
不兼容"——epoch 数字不同但 key 相同，本不该触发任何动作，却触发了覆盖。

### 1.2 结构性根因

`AAD = '$epoch|$contentHash'`（crypto.dart L190-194）。这意味着：

- 即使 dataKey 值没变（adoptRemoteEpoch 场景），只要 epoch 数字变了，旧 blob 用
  新 AAD 解密就 GCM tag 失败。
- 这迫使 adoptRemoteEpoch 调用 `markAllForBlobReupload`（P7 修复），触发全量 blob
  重传——而 dataKey 根本没变，重传的唯一原因是 AAD 里的 epoch 标签变了。
- "乐观声明 + pendingReupload 闭环"机制随之出现：manifest 声明当前 epoch，
  pendingReupload 标记保证旧 blob 被重传对齐。这个闭环就是翻转的战场。

**epoch 被放进了两个角色**：(1) manifest item 的版本标签（元数据），(2) blob 的
加密认证参数（AAD）。角色 (1) 是合理的——item 需要声明自己的加密版本。角色 (2)
是问题的根源——它让 epoch 数字的变化直接影响 blob 能否解密，即使密钥没变。

### 1.3 epoch 引入的历史（代码考古确认）

经查阅 `docs/CHANGES-20260729.md` ~ `CHANGES-20260801.md`，epoch 在 AAD 中的
演变如下：

| 时间 | 事件 | AAD 格式 |
|------|------|---------|
| 07-29 21:54 | v2: AAD 从 uuid 改为 content hash（修共享 blob bug） | `hash`（**无 epoch**） |
| 07-29 22:40 | Layer 3: 引入 `blobKeyEpoch` 放 manifest item，**设计明确说"blob 信封不写 epoch"** | `hash`（无 epoch） |
| 07-30 09:56 | 代码注释说明"为什么不持久化 blobKeyEpoch 到 DB"（crash 一致性） | `hash`（无 epoch） |
| ~08-01 | `_uploadNote` 开始传 `epoch: keyring.dataKeyEpoch` → epoch 进 AAD | `epoch\|hash` |
| 08-01 15:19 | 移除 v1/epoch=0 兼容路径，epoch-in-AAD 成唯一格式 | `epoch\|hash` |
| 08-01 18:36 | P6: 引入 `_probeBlobEpoch`（因为 epoch 在 AAD → 声明与实际不符 → 需要 probe） | `epoch\|hash` |
| 08-01 19:14 | P7: `adoptRemoteEpoch` 加 `markAllForBlobReupload`（因为 epoch 在 AAD → epoch 变了必须重传） | `epoch\|hash` |

**关键发现：07-29 的原始设计就是 AAD=hash（无 epoch）**，与本方案一致。epoch 被加进
AAD 是后来引入的，且它引入的问题（P6 probe、P7 markAllForBlobReupload、翻转事故）比
它解决的问题多。本方案本质是**回到 07-29 的原始 AAD 设计**，并在此基础上删掉 heal
机制（07-29 原始设计有 heal，本方案删之）。

### 1.4 07-30 代码注释的 crash 安全性顾虑（已被本方案消解）

`sync_engine.dart` L1051-1057 注释解释了"为什么不持久化 blobKeyEpoch 到 DB"：

> - 老数据迁移默认值（0）会让 manifest 回滚为旧纪元 → 其他设备 isOldKey 判定失效
>   → 旧密钥 blob 无法 heal → 永久 corrupt
> - crash 一致性：_uploadNote 成功但字段更新失败 → manifest 与 blob 实际纪元不一致
>   → 可能导致无法自愈的 corrupt

这两条顾虑的前提是 **epoch 在 AAD 中**：blob 的可解密性依赖 epoch → DB 列与 blob
实际 epoch 不一致 → 解密失败 → 需要 heal 兜底。

**本方案移除 epoch from AAD 后，这两条顾虑同时消解**：blob 的可解密性不依赖 epoch
→ DB 列值不影响解密 → "回滚为旧纪元"无害；crash 窗口：blob 用 dataKey 加密(AAD=hash)，
与 epoch 无关 → DB 列更新失败不影响解密。

---

## 2. 设计原则

1. **epoch 是元数据标签，不是加密参数。** blob 的加解密只依赖 dataKey 值和
   contentHash，不依赖 epoch 数字。epoch 仅声明在 manifest item 中，用于审计和
   错误提示，不参与 GCM 认证。

2. **解密是纯函数。** `decrypt(blob, dataKey, hash)` 的成功与否只取决于
   (密钥是否正确, AAD(hash) 是否匹配, 内容 hash 是否一致)，与任何全局状态无关。
   解密不触发写入。

3. **不兼容策略。** 与原方案 §0 一致：不做旧版本/旧数据兼容，直接删、直接改。
   blob 格式变化（AAD 去掉 epoch）→ 协议 v4 → 一次性全量 blob 重传。

4. **保留显式迁移与 pendingReupload 基建。** scenario-d 迁移（dataKey 真变）
   和一次性格式迁移（AAD 格式变化）仍需 `markAllForBlobReupload` +
   `_mergeAndTransfer` 的 pendingReupload 分支。删的是 heal/probe/乐观声明，
   不是迁移基建。

---

## 3. 核心改动

### 3.1 blob AAD 格式（1 行改动）

```dart
// 改前（crypto.dart L190-194）
static Uint8List _blobAad(String id, int? epoch) {
  if (epoch != null && epoch > 0) {
    return Uint8List.fromList(utf8.encode('$epoch|$id'));
  }
  return Uint8List.fromList(utf8.encode(id));
}

// 改后
static Uint8List _blobAad(String id) {
  return Uint8List.fromList(utf8.encode(id));
}
```

`SyncCrypto.seal` 和 `SyncCrypto.open` 的 `epoch` 参数对 blob 路径不再传入
（其他路径——manifest items 加密、journal 加密——本来就用 `epoch: null`，
即裸 id，不受影响）。

### 3.2 安全性分析

AES-256-GCM 的认证链：

```
密钥正确？ → GCM tag 通过
AAD 正确？ → GCM tag 通过
→ 解密成功 → 内容 hash 校验（manifest hash vs 解密内容 hash）
```

移除 epoch 后，blob 的认证变为：

| 认证层 | 机制 | 是否依赖 epoch |
|--------|------|---------------|
| 密钥认证 | GCM tag（dataKey 正确才能通过） | 否 |
| AAD 认证 | GCM tag（AAD=hash 必须匹配） | 否 |
| 内容认证 | 解密后明文 SHA-256 == manifest hash | 否 |

**epoch 在 AAD 中的唯一"作用"是区分不同 epoch 的 dataKey**。但同一 dataKey 值的
不同 epoch（如 adoptRemoteEpoch 场景）在密码学上是等价的——GCM tag 只认 key +
AAD，不认"epoch 标签"。把 epoch 放进 AAD 是在用一个密码学等价的东西制造密码学
不等价，这是自找麻烦。

与 Joplin 对比（原方案 §3.2 已调研）：Joplin 的 `master_key_id` 是 manifest 级
元数据，不在 blob 的加密参数里。safenotes 当前把 epoch 放进 AAD，等于让 epoch
同时承担"元数据标签"和"加密参数"两个角色，矛盾由此而生。

### 3.3 dataKeyFingerprint 的角色

原方案 [D] 提出的 `ManifestItem.dataKeyFingerprint` 在本方案中仍然保留，且更有
价值：

- **epoch 不在 AAD 里 → blob 不携带 epoch 信息 → 无法从 blob 自身判断用哪个
  dataKey 解密**。
- `dataKeyFingerprint` 在 manifest item 中提供"加密此 blob 的 dataKey 的指纹"，
  本地可精确判定"我有正确的 dataKey 吗"（而非靠 epoch 数字间接推断）。
- 这与 Joplin 的 `master_key_id`（item 自描述 key 标识）完全对齐。

### 3.4 _semanticItemsEqual 修正

当前 `_semanticItemsEqual`（sync_engine.dart L1331-1339）把 `blobKeyEpoch` 纳入
比较。如果两端声明不同 epoch，每次同步都判定"有变更"→ 无条件 PUT manifest。

本方案下 `blobKeyEpoch` 仍是 item 的自描述字段，但**不应触发 PUT**——各端加密时
用的 epoch 天然可能不同（各自 adoptRemoteEpoch 的时间点不同），这不代表内容有变化：

```dart
bool _semanticItemsEqual(ManifestItem a, ManifestItem b) {
  return a.hash == b.hash &&
      a.deleted == b.deleted &&
      a.updatedAt == b.updatedAt &&
      a.createdAt == b.createdAt &&
      a.deletedAt == b.deletedAt &&
      a.contentSize == b.contentSize;
      // blobKeyEpoch 不参与比对 —— 各端加密时用的 epoch 天然可能不同
}
```

---

## 4. 各场景数据流

### 4.1 正常同步

```
设备A: _uploadNote → seal(dataKey, hash, plaintext)  // AAD=hash
       → putBlob(envelope)
       → manifest item: {hash, blobKeyEpoch: A.dataKeyEpoch, dataKeyFingerprint: ...}

设备B: _downloadNote → open(dataKey, hash, envelope)  // AAD=hash
       → GCM tag 通过（dataKey 相同）
       → 解密成功 → hash 校验 → 物化到本地 DB
```

与当前实现完全等价，唯一区别是 AAD 不含 epoch。

### 4.2 changePassword（改密码）

```
dataKey 值不变 → blob 零改动
MK 变 → encryptedDataKey 重新 wrap → manifest header 更新
epoch 不变 → blobKeyEpoch 不变
```

与当前实现完全等价。

### 4.3 adoptRemoteEpoch（关键简化）

**当前实现**（P7 修复后，keyring.dart L776-797）：

```dart
Future<void> adoptRemoteEpoch({...}) async {
  final epochAdvanced = remoteDataKeyEpoch > current.dataKeyEpoch;
  current = current.copyWith(
    dataKeyEpoch: remoteDataKeyEpoch,
    // ...
  );
  await persist(database);
  if (epochAdvanced) {
    await database.markAllForBlobReupload();  // ← 必须重传所有 blob
  }
}
```

P7 加这行是因为 AAD 含 epoch：epoch 变了 → AAD 变了 → 旧 blob 用新 AAD 解不开 →
必须重传。

**本方案**：`markAllForBlobReupload` 调用删除。adoptRemoteEpoch 变成纯账本更新：

```dart
Future<void> adoptRemoteEpoch({...}) async {
  current = current.copyWith(
    encryptedDataKey: remoteEncryptedDataKey,
    keyFingerprint: remoteKeyFingerprint,
    keyVersion: remoteKeyVersion,
    dataKeyEpoch: remoteDataKeyEpoch,
    reason: KeyringReason.adoptRemoteEpoch,
  );
  await persist(database);
  // dataKey 不变，blob AAD 不含 epoch → 不需要 markAllForBlobReupload
}
```

**adoptRemoteEpoch 从 O(N)（全量 blob 重传）变成 O(1)（纯 DB 写）。**

事故根因（adoptRemoteEpoch 后 blob 与 epoch 不匹配）从物理上被消除——不再有
"epoch 变了但 blob 没跟着变"的状态。

### 3.4 _buildLocalManifest 乐观声明（无需 DB 持久化）

**关键简化**：原方案 §4.1 和 epoch-elimination-design 都要求 DB schema 加
`blob_key_epoch` 列来持久化每条笔记的真实 epoch。**本方案不需要。**

`sync_engine.dart` L1038-1058 注释解释了乐观声明 `blobKeyEpoch: keyring.dataKeyEpoch`
的安全性依赖 pendingReupload 闭环兑现。该闭环存在的**唯一原因是 epoch 在 AAD 中**——
声明与实际不符 → GCM tag 失败 → 需要重传对齐。

移除 epoch from AAD 后：
- blob 的可解密性与 epoch 无关 → 声明什么 epoch 都不影响解密
- "乐观声明当前纪元"是完全安全的——声明值只是元数据，不参与 GCM 认证
- 不需要 DB 列、不需要迁移、不需要 crash 一致性顾虑

`_buildLocalManifest` 代码只需删除注释，`blobKeyEpoch: keyring.dataKeyEpoch`
这行本身**保持不变**（声明当前纪元作为元数据），但不再需要 DB 持久化。

**schema 变化对比**：

| 维度 | 原方案 | 本方案 |
|------|--------|--------|
| DB schema | v4，加 `blob_key_epoch` 列 | v4（协议版本递增即可，AAD 格式变了） |
| DB 迁移 | ALTER TABLE + 存量 blob 重传对齐 | 仅 markAllForBlobReupload + blob 重传（AAD 格式变化） |
| 乐观声明 | 改为读 DB 列（消除乐观） | **保留乐观声明**（epoch 是元数据，乐观无害） |
| crash 一致性 | 需要"同一事务"原子绑定 | **不需要**（blob 不依赖 epoch） |

### 4.4 scenario-d 迁移（dataKey 真变）

```
migrateToRemoteVault:
  reEncryptAllNotes(oldKey, newKey)  // SQLite 事务，crash 安全
  markAllForBlobReupload()           // 标记全量重传（dataKey 真变了）
  epoch+1
  persist(database)
  database.setDataKey(remoteDataKey)
  ↓ 下次 sync:
  _mergeAndTransfer 的 pendingReupload 分支:
    seal(NEW dataKey, hash, plaintext)  // 用新 dataKey 加密，AAD=hash
    putBlob → 成功 → 更新 DB → 清标记
```

与当前实现等价——dataKey 值真变了，必须重新加密所有 blob。`markAllForBlobReupload`
保留，`_mergeAndTransfer` 的 pendingReupload 分支保留。

### 4.5 crash 窗口

**当前实现**：

```
_uploadNote 成功（blob 用 epoch=N AAD 上传）
  ↓ crash
DB 列未更新（仍 = N-1）
→ 下次 sync: _buildLocalManifest 读 DB → 声明 epoch=N-1
→ 他端用 epoch=N-1 的 AAD 解密 → GCM tag 失败（blob 实际是 epoch=N AAD）
→ 无 heal → 永久 corrupt
```

**本方案**：

```
_uploadNote 成功（blob 用 AAD=hash 上传，与 epoch 无关）
  ↓ crash
DB 列未更新
→ 下次 sync: manifest 声明的 epoch 可能"过时"
→ 但他端用 dataKey + AAD=hash 解密 → GCM tag 通过（dataKey 没变）
→ 解密成功 → hash 校验 → 内容可用
→ pendingReupload 标记仍在 → 下次 sync 重传对齐（不影响正确性，只影响一致性）
```

**crash 窗口无害。** 这是因为 blob 的可解密性不再依赖 epoch 数字。

### 4.6 schema 迁移（v3→v4）

blob AAD 格式从 `'$epoch|$hash'` 变为 `'$hash'`，所有现存 blob 必须重新上传。

```
schema v3→v4:
  1. ALTER TABLE 加 blob_key_epoch 列（默认当前 dataKeyEpoch）
  2. markAllForBlobReupload()  ← 标记全量重传（AAD 格式变了）
  ↓ 下次 sync:
  3. _mergeAndTransfer 的 pendingReupload 分支:
       seal(dataKey, hash, plaintext)  // 新 AAD=hash
       putBlob → 成功 → 更新 DB 列 → 清标记
       失败 → 保留标记，下次重试
  4. _buildLocalManifest 读 DB 列（已重传的 = 新格式，未重传的下次继续）
```

与原方案的对比：

| 维度 | 原方案（AAD含epoch） | 本方案（AAD仅hash） |
|------|---------------------|---------------------|
| 迁移时是否需要 blob 重传 | 需要（epoch 对齐） | 需要（AAD 格式变化） |
| 迁移原子性 | ❌ "同一事务"不可行（网络IO在SQLite事务外） | ✅ pendingReupload 闭环保证最终一致 |
| crash 安全 | ❌ crash 窗口永久 corrupt | ✅ crash 窗口无害（blob 不依赖 epoch） |
| 后续 adoptRemoteEpoch | O(N) blob 全重传 | **O(1) 纯 DB 写** |

两者一次性迁移成本相同（都需全量 blob 重传），但本方案后续运营收益显著。

---

## 5. 删除与保留清单

### 5.1 可删除的代码

| 代码 | 位置 | 行数（估） | 理由 |
|------|------|-----------|------|
| `_probeBlobEpoch` | sync_engine.dart L1634-1670 | ~40 | blob 不绑定 epoch，有 dataKey 就能解，无需逐个试 epoch |
| `_downloadNote` 的 heal 分支 | sync_engine.dart L1738-1845 | ~110 | 解密成功即可，不比较 epoch → 不触发"现代化"重传 |
| `_DownloadHealed` 类 | sync_engine.dart L2425-2428 | ~5 | heal 分支删除后无产出此类型 |
| `_buildLocalManifest` 乐观声明 | sync_engine.dart L1030-1050 | ~20 | 改为读 DB 列（与原方案一致） |
| `adoptRemoteEpoch` 的 `markAllForBlobReupload` 调用 | keyring.dart L794-796 | ~3 | AAD 不含 epoch，adopt 不需重传 |
| epoch 参数透传 | crypto.dart seal/open + sync_engine `_openBlobEnvelope`/`_uploadNote` | ~15 | blob 路径不再传 epoch |
| **改后小计** | | **~193** | |

> **注意**：`_handleDownloadFailure`（sync_engine.dart L1880-2020）的本机明文自愈
> 和孪生笔记自愈**不删除**（见 §8.4 修订）。这两个机制是"远端 blob 坏了 → 用本地
> 明文覆盖"的合理恢复路径，不依赖 epoch 比较，不触发翻转。仅删除其中
> `isOldKey` 判定的 epoch 比较部分（改为 `dataKeyFingerprint` 判定）。

### 5.2 保留的代码

| 代码 | 理由 |
|------|------|
| `markAllForBlobReupload` / `getPendingReuploadUuids` / `removePendingReuploadUuids` | scenario-d 迁移 + 一次性格式迁移的可靠执行机制 |
| `_mergeAndTransfer` 的 pendingReupload 强制重传分支 | 服务真正的 dataKey 变更和格式迁移 |
| `migrateToRemoteVault` | 显式迁移流程，dataKey 真变时必须 |
| `ManifestItem.blobKeyEpoch` | item 自描述字段，用于审计和错误提示 |
| `ManifestItem.dataKeyFingerprint`（新增，原方案 [D]） | 比 epoch 更强的身份判定，Joplin `master_key_id` 模式 |
| `repairRemote()` | 用户手动修复兜底 |
| `_itemsEqual`（hash + deleted） | 决定是否需要传输 blob |
| `_handleDownloadFailure` 的本机明文自愈 + 孪生笔记自愈 | "远端 blob 坏了 → 用本地明文覆盖"的合理恢复路径，不依赖 epoch 比较，不触发翻转 |
| `_DownloadSuccess` / `_DownloadFailed` 类 | 下载成功/失败的结果类型仍需要 |

### 5.3 修改的代码

| 代码 | 改动 |
|------|------|
| `crypto.dart _blobAad` | 移除 epoch 参数，AAD = 仅 hash |
| `crypto.dart seal/open` | epoch 参数保留但 blob 路径不传（其他路径仍用 null） |
| `keyring.dart adoptRemoteEpoch` | 删 `markAllForBlobReupload` 调用 |
| `sync_engine.dart _buildLocalManifest` | **保留乐观声明**（不改代码，删注释 L1038-1058） |
| `sync_engine.dart _semanticItemsEqual` | 排除 blobKeyEpoch 比较 |
| `sync_engine.dart _uploadNote` | seal 调用不传 epoch |
| `sync_engine.dart _openBlobEnvelope` | open 调用不传 epoch |
| `database_handler.dart` | schema version 递增（v3→v4），**不加 blob_key_epoch 列** |
| `sync_models.dart ManifestItem` | 新增 dataKeyFingerprint 字段 |

### 5.4 代码量对比

| 维度 | 原方案 | 本方案 |
|------|--------|--------|
| 删除行数 | ~310 | ~193（不删本机明文自愈） |
| 保留行数 | markAllForBlobReupload 基建（~50） | 同 + pendingReupload 分支（~30）+ 本机明文自愈（~140） |
| 新增行数 | DB 列迁移 ~20 + dataKeyFingerprint ~15 | dataKeyFingerprint ~15（**不需要 DB 列迁移**） |
| **净减** | **~310** | **~220**（不需 DB 列迁移，净减更多） |

> 本方案净减行数少于原方案，因为保留了本机明文自愈（~140 行）。这是有意为之：
> 本机明文自愈是"远端 blob 坏了用本地覆盖"的合理恢复路径，不应为了追求行数
> 指标而删除。关键收益不在行数，而在**后续 adoptRemoteEpoch 从 O(N) 变 O(1)**，
> 以及 **crash 窗口无害**。

---

## 6. 待删除代码的详细分析

### 6.1 _probeBlobEpoch（可全删）

**当前职责**：当 manifest 声明的 epoch 与 blob 实际 epoch 不符时，从 epoch=1 递增
到当前纪元逐个尝试解密，找到能解开的纪元。

**为何可删**：blob 的 AAD 不含 epoch → 用当前 dataKey 直接 open → GCM tag 通过
即可解密，无需逐个试 epoch。

**安全保证**：
- dataKey 正确 → GCM tag 通过 → 解密成功
- dataKey 不正确 → GCM tag 失败 → 不会放行错误明文
- 解密后内容 hash 校验进一步保证

### 6.2 heal 分支（可全删）

**当前职责**（sync_engine.dart L1738-1845）：
1. 用 item.blobKeyEpoch 解密 → 失败
2. 调 _probeBlobEpoch 找到 actualEpoch
3. 检查 actualEpoch != keyring.dataKeyEpoch → 触发"现代化"重传
4. 用当前 epoch 重传 blob → 返回 _DownloadHealed

**为何可删**：
- AAD 不含 epoch → 用 item 声明的 epoch 或当前 epoch 都能解密（只要 dataKey 相同）
- 不比较 epoch → 不触发"现代化"
- 解密成功即可物化到本地，无需重传

**与 `_handleDownloadFailure` 的边界**：
`_handleDownloadFailure`（sync_engine.dart L1880-2020）包含两类逻辑：

1. **本机明文自愈 + 孪生笔记自愈**（L1890-2003）：远端 blob 解密失败 → 检查本地
   是否有同 uuid 的明文笔记（之前同步过）→ 用当前 dataKey 重新加密上传覆盖坏
   blob。或找到同 contentHash 的孪生笔记 → 物化 + 重传。**这部分保留**——它是
   "远端坏了用本地覆盖"的合理恢复路径，不比较 epoch、不触发翻转。

2. **isOldKey 判定**（L2008）：`remoteItem.blobKeyEpoch != keyring.dataKeyEpoch`
   → 仅用于错误提示文案。**这部分修改**——改为用 `dataKeyFingerprint` 判定
   "缺 key vs 损坏"，不再比较 epoch。

需保留的边界情况处理：如果 blob 用旧 dataKey 加密（scenario-d 迁移后他端未
同步），当前 dataKey 无法解密 → `_handleDownloadFailure` 尝试本机明文自愈 →
无本地明文则报 corrupt + 提示 repair。这与原方案一致。

### 6.3 乐观声明（改为 DB 读取）

**当前**（sync_engine.dart L1030-1050）：

```dart
items[note.uuid] = ManifestItem(
  // ...
  blobKeyEpoch: keyring.dataKeyEpoch,  // ← 乐观声明当前纪元
);
```

**本方案**：

```dart
items[note.uuid] = ManifestItem(
  // ...
  blobKeyEpoch: note.blobKeyEpoch,  // ← 从 DB 列读取真实值
  dataKeyFingerprint: keyring.keyFingerprint,  // ← 自描述 key 身份
);
```

注意：即使 DB 列的值"过时"（crash 窗口未更新），也不会导致解密失败——blob 的
可解密性不依赖 epoch。DB 列只影响 manifest 声明的 epoch 值，该值是纯元数据。

---

## 7. _downloadNote 新流程

删除 heal/probe 后，`_downloadNote` 简化为：

```
1. getBlob(item.hash) → envelope
2. open(dataKey, item.hash, envelope)  // AAD=hash, 无 epoch
   ✓ 成功 → hash 校验 → 物化到本地 DB → _DownloadSuccess
   ✗ 失败 → 进入失败处理
3. 失败处理（_handleDownloadFailure）：
   a. 本机有同 uuid 明文笔记？ → 用当前 dataKey 重新加密上传覆盖 → 返回 item
   b. 有同 contentHash 孪生笔记？ → 物化 + 重传 → 返回 item
   c. 都没有：
      item.dataKeyFingerprint == keyring.keyFingerprint?
      → 是：dataKey 应该能解开但没解开 → blob 真损坏 → corrupt
      → 否：blob 用了不同的 dataKey（旧密钥）→ corrupt + 提示 repair
   d. 返回 null
4. 调用方据返回值包装：
   非空 → _DownloadSuccess(item)  // item 可能含更新后的 blobKeyEpoch
   null   → _DownloadFailed(uuid)
```

`_DownloadHealed` 类不再需要——本机明文自愈和孪生笔记自愈返回的 item 由调用方
包装为 `_DownloadSuccess`。healed 与正常下载的区别只在"远端 blob 被本地覆盖了"，
对合并 manifest 而言没有特殊处理需求（hash 不变，epoch 是纯元数据）。

与原方案的区别：解密失败后仍尝试本机明文自愈和孪生笔记自愈，但**不尝试
_probeBlobEpoch**（不存在 epoch 探测），**不比较 epoch 触发现代化重传**。

**关键保证**：只要 dataKey 相同（item.dataKeyFingerprint == keyring.keyFingerprint），
任何 epoch 的 blob 都能直接 open 成功——不会走到失败处理。只有 dataKey 真不同
或 blob 真损坏才走失败处理。

### 7.1 repairRemote 变更

`repairRemote`（sync_engine.dart L631-830）是用户手动触发的"全量体检 + 修复"。
当前流程：

```
对每个 remote item:
  1. getBlob → 如果缺失 → 本机明文/孪生自愈重传
  2. 用 item.blobKeyEpoch 解密 → 如果失败 → _probeBlobEpoch 找 actualEpoch
  3. actualEpoch != keyring.dataKeyEpoch → "现代化"重传（用当前 epoch 重新加密上传）
  4. actualEpoch == keyring.dataKeyEpoch → 采用，但 manifest 仍更新 blobKeyEpoch
  5. probe 失败 → 本机明文/孪生自愈 → 仍失败则 corrupt
```

**本方案后简化为**：

```
对每个 remote item:
  1. getBlob → 如果缺失 → 本机明文/孪生自愈重传（保留）
  2. open(dataKey, item.hash, blob)  // AAD=hash, 无 epoch
     ✓ 成功 → 采用，manifest 更新 blobKeyEpoch 为当前值（纯元数据）
     ✗ 失败 → 本机明文/孪生自愈（保留）→ 仍失败则 corrupt
  3. 不需要 probe、不需要"现代化"重传
```

删除的 repairRemote 代码：`_probeBlobEpoch` 调用（L752）、actualEpoch 比较
（L764）、现代化重传分支（L765-795）。保留：本机明文自愈 + 孪生笔记自愈。

---

## 8. 风险与对策

### 8.1 不兼容策略风险（接受）

blob 格式变化（AAD 去掉 epoch）→ 所有现存 blob 必须重新上传。旧客户端无法
解读新格式 blob，新客户端无法解读旧格式 blob。与原方案 §0 一致，作为安全应用，
全量升级是可控前提。

**对策**：协议版本 v3→v4，`_downloadManifest` 校验 `header.schemaVersion`，
低于 v4 直接拒绝并提示升级（原方案 [G]）。

### 8.2 迁移期间数据可用性

迁移期间（schema 升级后、blob 全量重传完成前），已重传的 blob 用新格式，未重传
的仍是旧格式。新格式客户端尝试解密旧格式 blob → GCM tag 失败 → 报 corrupt。

**对策**：
- `markAllForBlobReupload` 标记全量重传 → `_mergeAndTransfer` 的 pendingReupload
  分支逐条重传，成功一条清一条
- 失败的保留标记，下次 sync 继续重试
- 在此期间，其他设备下载到未重传的 item → 报 corrupt → 等 he 端重传完成后
  下次 sync 恢复
- 用户可手动 `repairRemote()` 加速

这与原方案的迁移风险相同——两者都需要一次性全量 blob 重传，都有"未重传完期间
部分笔记不可用"的窗口。区别是本方案后续不再有此风险（adoptRemoteEpoch 不再
触发重传），而原方案每次 adoptRemoteEpoch 都会重现此窗口。

### 8.3 dataKeyFingerprint 新字段

`ManifestItem.dataKeyFingerprint` 是新增字段，需在 manifest 序列化/反序列化中
支持。旧格式 manifest 无此字段 → 解析时缺省为 null → 解密失败时无法精确判定
"缺 key vs 损坏" → 统一报 corrupt + 提示 repair。

这与原方案 [D] 一致，无额外风险。

### 8.4 _probeBlobEpoch 删除后的恢复能力

当前 `_probeBlobEpoch` 能在"声明 epoch 与实际不符"时恢复数据。删除后，这类
情况变成 corrupt。

**本方案下此情况不存在**：blob 的可解密性不依赖 epoch → 不会出现"声明 epoch
与实际不符导致无法解密"。只要 dataKey 正确，任何 epoch 声明都能解密。

唯一无法解密的情况：dataKey 真的不对（他端 scenario-d 迁移后本端未同步）或
blob 真损坏。这两种情况 `_probeBlobEpoch` 也无法恢复（不同 dataKey 解不开），
当前实现靠 `_handleDownloadFailure` 的本机明文自愈兜底。

**本方案保留本机明文自愈**：如果本地有同 uuid 的明文笔记（之前同步过），
可以用当前 dataKey 重新加密上传覆盖坏 blob。这与"heal"不同——它是"用本地
明文覆盖远端损坏"，不比较 epoch、不触发翻转。

> 修订（v2）：经审查代码，`_handleDownloadFailure` 中的本机明文自愈和孪生笔记
> 自愈应保留，仅删除 heal/probe 部分。这两个机制不是 epoch 驱动的，是"远端 blob
> 坏了→用本地明文覆盖"的合理恢复路径。§5.1 已据此调整删除清单。

### 8.5 测试策略

#### 需要修改的测试文件

| 文件 | 需修改的用例 | 改动说明 |
|------|-------------|---------|
| `test/sync/keyring_test.dart` | P7 回归（L714-757）"纪元递增触发 blob 重传" | 断言反转：adopt 后 pending set **为空**（AAD 不含 epoch，不需要重传） |
| `test/sync/keyring_test.dart` | P7 回归（L759-782）"纪元不变时不触发重传" | 不变（仍然不触发） |
| `test/sync/p0p1_self_heal_test.dart` | heal 动作断言（L304-309） | `SyncActionType.heal` → `SyncActionType.download`（本机明文自愈仍工作，但不再有 epoch 驱动的 heal） |
| `test/sync/p0p1_self_heal_test.dart` | 混沌翻转 blob（L525-564） | 保留：本机明文自愈仍覆盖损坏 blob。断言改为 `SyncActionType.download` 或 `corrupt`（无 heal 类型） |
| `test/sync/multi_device_test.dart` | M7 篡改 blob（L849-867） | `SyncCrypto.seal(..., epoch: 1)` → `SyncCrypto.seal(...)`（不传 epoch）；断言不变（内容 hash 校验仍捕获篡改） |
| `test/sync/multi_device_test.dart` | 共享 blob 测试 | AAD=hash 不变，共享 blob 行为一致。仅需删除 `epoch:` 参数 |
| `test/sync/chaos_multi_client_test.dart` | epoch 相关断言 | 检查所有 `blobKeyEpoch` 断言，确认改为纯元数据语义 |
| `test/sync/crypto_test.dart` | `seal/open` 往返测试 | 删除 `epoch:` 参数（或保留 `epoch: null` 的默认行为） |
| `test/sync/change_password_multi_client_test.dart` | BUG-3 / B3 回归 | 改密码不碰 epoch → 行为一致。如果有 `adoptRemoteEpoch` 触发重传的断言，改为不触发 |

#### 新增测试

- **AAD 格式测试**：旧格式 blob（AAD=`epoch|hash`）无法用新代码解密 → 报 corrupt
- **adoptRemoteEpoch 后零重传**：adopt 纪元 1→2 → pending set 为空 → 下次 sync
  blob 不重传 → 他端正常解密（dataKey 相同，AAD=hash）
- **crash 窗口无害**：upload 成功 / DB 列更新失败 → 下次 sync 仍可正常解密
  （blob AAD=hash，与 epoch 无关）
- **本机明文自愈**：远端 blob 损坏 + 本地有明文 → 自愈重传成功（保留的恢复路径）
- **dataKeyFingerprint 判定**：item.fingerprint == keyring.fingerprint 但解密
  失败 → 报"blob 真损坏"；fingerprint 不匹配 → 报"缺 key"
- **chaos 翻转回归**：多设备混合 adoptRemoteEpoch / changePassword / scenario-d
  → 确认翻转不再出现

#### 不会回归的测试（验证清单）

| 历史修复 | 测试名 | 本方案是否保持 |
|---------|--------|--------------|
| 共享 blob AAD=hash（07-29） | webdav_integration_test.dart「共享 blob」 | ✅ AAD 仍是 hash |
| 错误 dataKey 解密失败 | crypto_test.dart | ✅ GCM tag 仍保证 |
| 错误 AAD 解密失败 | crypto_test.dart | ✅ AAD=hash 仍提供认证 |
| 内容 hash 校验（M7 篡改） | multi_device_test.dart M7 | ✅ 解密后 hash 比对不变 |
| 本机明文自愈 | p0p1_self_heal_test.dart | ✅ 保留此恢复路径 |
| 孪生笔记自愈 | p0p1_self_heal_test.dart | ✅ 保留此恢复路径 |
| adoptRemoteEpoch dataKey 不变 | keyring_test.dart C2 回归 | ✅ 仍不变 |
| 改密码不触发重传 | keyring_test.dart P7b | ✅ 仍不触发 |
| scenario-d 迁移重传 | change_password_multi_client_test.dart | ✅ dataKey 真变仍重传 |

---

## 9. 实施顺序

1. **定案 dataKeyFingerprint 字段格式**（参考 Joplin `master_key_id` / Standard
   Notes `itemsKey` 的 key 身份标识设计），更新 manifest 序列化。
2. **生产 DB 备份**（不兼容迁移为破坏性操作）。
3. **crypto.dart**：`_blobAad` 改为仅 hash，`seal/open` 的 blob 路径不传 epoch。
4. **database_handler.dart**：schema version 递增（v3→v4），迁移触发
   `markAllForBlobReupload`（AAD 格式变化，全量重传）。**不需要加 `blob_key_epoch` 列**。
5. **keyring.dart**：`adoptRemoteEpoch` 删 `markAllForBlobReupload` 调用。
6. **sync_engine.dart**：
   - `_buildLocalManifest`：**保留乐观声明** `blobKeyEpoch: keyring.dataKeyEpoch`
     （epoch 是元数据，乐观无害），删除 L1038-1058 的注释（顾虑已消解）
   - `_uploadNote`：seal 不传 epoch
   - `_openBlobEnvelope`：open 不传 epoch
   - `_semanticItemsEqual`：排除 blobKeyEpoch
   - 删 `_probeBlobEpoch`
   - 删 `_downloadNote` 的 heal 分支（保留本机明文自愈）
   - 保留 `_mergeAndTransfer` 的 pendingReupload 分支
7. **sync_models.dart**：`ManifestItem` 新增 `dataKeyFingerprint`，
   `ManifestHeader` 新增 `dataKeyFingerprint`。
8. **sync-protocol-spec.md**：协议 v4，更新 AAD 格式、blobKeyEpoch 语义
   （纯元数据标签）、新增 dataKeyFingerprint 字段。
9. **`_downloadManifest`**：增加 schemaVersion 降级拒绝（原方案 [G]）。
10. **全量测试** + `make valid`。
11. **更新 CHANGES**。
12. **观察一轮真实多端同步**确认无翻转回归。

---

## 10. 与原方案的逐项对比

| 维度 | 原方案 | 本方案 | 评价 |
|------|--------|--------|------|
| 根因诊断 | epoch 当全局状态机驱动纠正 | 同 + 进一步：epoch 在 AAD 里才是根因 | 本方案更深层 |
| 核心方向 | item 自描述 + 只读解密 | 同 | 一致 |
| AAD 格式 | 保留 `epoch\|hash` | 改为 `hash` | 本方案根除 |
| [A] 原子性 | "同一事务"不可行 | pendingReupload 闭环 | 本方案可行 |
| [D2] pendingReupload | 矛盾（保留标记删执行分支） | 标记和执行都保留，adopt 不再设标记 | 本方案无矛盾 |
| crash 窗口 | 永久 corrupt | 无害 | 本方案胜出 |
| adoptRemoteEpoch | O(N) blob 全重传 | O(1) 纯 DB 写 | 本方案胜出 |
| _probeBlobEpoch | 删除 | 不存在 | 等价 |
| heal 机制 | 删除 | 不存在 | 等价 |
| dataKeyFingerprint [D] | 保留 | 保留 | 一致 |
| 一次性迁移成本 | blob 重传（epoch 对齐） | blob 重传（格式变化） | 相同 |
| 代码净减 | ~310 行 | ~220 行 | 原方案多删了本机明文自愈；本方案保留它，且不需要 DB 列迁移 |
| 不兼容策略 | v3→v4 | v3→v4 | 一致 |
| 协议降级拒绝 [G] | 需要 | 需要 | 一致 |
| 新增元数据字段 | 5 个（createdBy/dataKeyCreatedAt/...） | 1 个（dataKeyFingerprint） | 本方案更简洁 |
| 本机明文自愈 | 删除 | 保留（非 epoch 驱动） | 本方案保留合理恢复路径 |
| DB 加 blob_key_epoch 列 | 需要 | **不需要** | 乐观声明无害（epoch 是元数据） |
| _buildLocalManifest 改为读 DB | 需要 | **不需要**（保留乐观声明） | epoch 不在 AAD → 乐观声明不影响解密 |

---

## 11. 结论

本方案在原方案正确的根因诊断基础上，进一步将 epoch 从 blob 的加密参数中移除，
使其彻底回归"纯元数据标签"角色。这带来三个关键优势：

1. **adoptRemoteEpoch 从 O(N) 变 O(1)**：不再需要全量 blob 重传，从事故根因的
   物理层面消除"epoch 变了但 blob 没跟着变"的状态。

2. **crash 窗口无害**：blob 的可解密性不再依赖 epoch 数字，upload 成功/DB 更新
   失败的 crash 窗口不会导致永久 corrupt。

3. **pendingReupload 无矛盾**：标记和执行分支都保留，只服务真正的 dataKey 变更
   和一次性格式迁移，adoptRemoteEpoch 不再触发标记。

代价是一次性全量 blob 重传（与原方案相同）和 v4 协议不兼容（与原方案相同）。
后续运营中不再有此类风险。
