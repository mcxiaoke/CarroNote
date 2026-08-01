# Flutter 同步代码审查报告（DS-002）

- **审查日期**: 2026-08-01
- **审查范围**: `lib/sync/`（sync_engine / sync_models / keyring / journal / crypto / 三个后端）+ `lib/data/database_handler.dart` + `lib/models/safenote.dart` + `lib/models/editor_state.dart` + `lib/sync/sync_service.dart`
- **审查目标**: 同步及各分支逻辑的实质性问题（数据丢失 / 数据重复 / 孤儿条目 / 一致性）
- **结论**: 发现 **2 个高风险问题**（可能导致数据丢失或不可用）、**2 个中等问题**、**2 个低风险健壮性隐患**，以及若干值得注意的设计点。

---

## 严重度速览

| # | 严重度 | 问题 | 影响 |
|---|--------|------|------|
| 1 | 🔴 高 | 上传失败被静默"同步成功"，产生幽灵引用且永不重试 | 笔记永久困在单设备，他端永久 corrupt |
| 2 | 🔴 高 | 并发 GC 误隔离"正在上传"的 blob，注释声称的恢复路径不存在 | 他端不可读（隔离区 30 天可恢复） |
| 3 | 🟡 中 | `_hasEffectiveChange` 被 `updatedBy` 击穿，多设备每次同步无条件 PUT | 版本无限攀升、审计信息被覆盖、ETag 冲突增多 |
| 4 | 🟡 中 | `repairRemote` 3b 分支修不好笔记且制造孤儿 blob | 修复功能失效 + 新增孤儿 |
| 5 | 🟢 低 | `_preserveConflictCopy` 只 `on Exception`，截断 blob 可炸掉整次同步 | 单条坏 blob 使同步崩溃 |
| 6 | 🟢 低 | `markAllSynced()` 无条件全量执行，语义过于激进 | 污染下轮冲突判定 base |

---

## 🔴 问题 1（高）：上传失败被静默"同步成功"——幽灵引用且永不重试

### 现象

`_uploadNote` 的 blob 上传失败（`putBlob` 抛错）只记录 `SyncActionType.uploadFailed`（sync_engine.dart:1479-1513），**不抛异常、不阻断同步**。但两个调用点仍把该笔记条目写入 merged manifest：

- 仅本地有：sync_engine.dart:1147-1148
  ```dart
  if (note != null) {
    await _uploadNote(note, actions);   // 可能 uploadFailed
    mergedItems[uuid] = localItem;      // 仍加入 merged（无论成败）
  }
  ```
- 冲突本地胜：sync_engine.dart:1214-1216（同样无条件 `mergedItems[uuid] = localItem`）

随后：

1. `_hasEffectiveChange` 判定"有变更"（merged.items 与 remote.items 因 hash 不同而不一致，sync_engine.dart:2203-2211）→ **PUT manifest 引用了一个从未成功上传的 blob**。
2. `_updateLocalState` → `markAllSynced()`（sync_engine.dart:1922）把该笔记标成 `synced=1`、`syncedHash = 新 hash`。

### 后果

- 下次同步两端条目 hash 相同 → `_itemsEqual` 走 skip（sync_engine.dart:1153-1166），**该缺失 blob 永远不再重传**。
- `uploadFailed` 无持久化、无重试机制；`blobReuploadPending`（`markAllForBlobReupload`）只服务密钥迁移场景（database_handler.dart:888-923），与上传失败无关。
- 其他设备下载该笔记 → `getBlob` 404 → 无本地明文 → 永久 corrupt，每次同步重试但永不成功。
- `SyncResult.failedNoteUuids` 只统计 download 方向的 `corrupt`（sync_engine.dart:1911-1913），不统计 `uploadFailed`，UI 不主动提示。

即：**一次瞬时的 blob 级失败即可把一条新笔记/新编辑永久困在单设备上**，直到用户再次编辑该笔记才触发重传。

### 修复建议

- `_mergeAndTransfer` 中，上传失败时**不要**把该条目写入 merged（或改为在本地 DB 持久化"待重传"标记，类似 `blobReuploadPending` 的机制）。
- `_updateLocalState` 的 `markAllSynced` 应排除本轮 `uploadFailed` 的笔记（见问题 6）。
- `failedNoteUuids` 或新增失败集合纳入 `uploadFailed`，并在 UI 提示。

---

## 🔴 问题 2（高）：并发 GC 误隔离"正在上传"的 blob，恢复路径不存在

### 现象

`_gcOrphanBlobs`（sync_engine.dart:1958-2012）把"远端有、但 merged manifest 不引用"的 blob 软删到隔离区（`deleteBlobSoft`）。

竞态时序：

1. 设备 B `putBlob(X)` 完成（blob X 已在远端）。
2. B 尚未 `putManifest`（manifest 还不引用 X）。
3. 设备 A 在本轮同步末尾执行 GC，`listBlobs()` 看到 X，merged manifest 无引用 → 误判孤儿 → `deleteBlobSoft(X)` 隔离。
4. B `putManifest` 成功（引用 X），B 标记笔记 synced。

结果：**manifest 引用了一个已进隔离区的 blob**。SafeServer 下 `getBlob(X)` 直接 404；LocalFS 下 `getBlob(X)` 读 `blobs/` 目录，文件已被 rename 到 `blobs-orphan/`，同样 404。

### 代码注释的错误断言

sync_engine.dart:1950-1953 注释声称：

> "极端情况下删除了 B 正在上传的 blob，B 下次同步会重新上传（putBlob 幂等）"

**该恢复路径不存在**：B 下次同步时，本地条目 hash 与远端 manifest 条目 hash 相同 → `_itemsEqual` 直接 skip → **没有任何触发重传的路径**。数据只能在隔离区保留 30 天后被 purged（可恢复窗口内可由人工/修复流程找回，但期间他端不可读）。

### 修复建议

- 方案 A：GC 的 `deleteBlobSoft` 前，对"即将隔离"的 blob 用 `getBlob` 做二次确认已不可靠，需从协议层避免——在 manifest 与 blob 之间引入"上传中"的短期引用（如隔离区 blob 带时间戳，GC 只隔离创建超过 N 分钟的孤儿）。
- 方案 B：把 upload 的 hash 与 PUT manifest 的 hash 集合差异考虑进 GC：仅隔离"本次 GET manifest 之前已存在、且此后未被任何设备 PUT 的新 blob"。此实现成本高，方案 A 更实际。
- 至少：修复注释与真实行为不一致的误导，并明确"隔离区恢复"为唯一兜底。

---

## 🟡 问题 3（中）：`_hasEffectiveChange` 被 `updatedBy` 击穿，多设备每次同步无条件 PUT

### 现象

- `_buildLocalManifest` 给每条 item 打 `updatedBy: deviceId`（sync_engine.dart:1017）。
- 合并时"完全一致：跳过"分支把**本地** item 放进 merged（sync_engine.dart:1164）。
- `_hasEffectiveChange` 用完整 `ManifestItem ==`（含 `updatedBy`，sync_models.dart:178-189）比对 merged 与 remote（sync_engine.dart:2203-2211）。

对任意两台设备 A/B：

- A 同步后，远端每条 item 的 `updatedBy = A`。
- B 下次同步，本地条目 `updatedBy = B` ≠ 远端 `A` → `merged.items[key] != remoteItem` → 判定"有变更"→ PUT。

### 后果

- D3 修复（避免 blob 下载失败时版本无意义 +1 攀升）在多设备下**完全失效**。
- manifest version 随每次同步无限增长。
- `updatedBy` 审计信息被每次同步的设备覆盖，失去"最后修改者"语义。
- 多设备自动同步（3s debounce）接近并发 PUT，ETag 冲突/重试概率显著上升。

### 修复建议

- `_hasEffectiveChange` 的 items 比对应**排除 `updatedBy` 字段**（hash / deleted / updatedAt / deletedAt / contentSize / blobKeyEpoch），或合并时对"一致"条目采用远端 item 而非本地 item。
- 理想做法：`_itemsEqual` 与"是否需要 PUT"的判定解耦，后者只关心影响数据语义的字段。

---

## 🟡 问题 4（中）：`repairRemote` 3b 分支既修不好笔记，又制造孤儿 blob

### 现象

`repairRemote` Step 3b（sync_engine.dart:796-813）：所有候选 dataKey 均解密失败后回退本机明文时，**不校验 `local.contentHash == item.hash`**：

```dart
final local = await database.readNoteByUuid(uuid);
final twin = local == null ? await database.readNoteByContentHash(item.hash) : null;
final source = local ?? twin;
if (source != null && !source.deleted) {
  await _uploadNote(source, actions);                    // 上传的是 source.contentHash
  repairedItems[uuid] = item.copyWith(blobKeyEpoch: ...); // 却保留旧的 item.hash
  ...
}
```

若本地笔记已编辑（`local.contentHash != item.hash`）：

- `_uploadNote(source)` 上传的 blob 键名是 `source.contentHash`（新 hash）。
- `repairedItems[uuid]` 保留 `item.hash`（旧、解不开的 hash）。

结果：

1. **修复无效**：manifest 仍引用解不开的旧 blob。
2. **制造孤儿**：新上传的新 hash blob 无人引用 → 下轮 GC 隔离 → 30 天后 purged。

### 对比

`_handleDownloadFailure`（sync_engine.dart:1826-1834）正确处理为 `hash: local.contentHash`（自愈后 manifest 指向重传的新 hash）。`repairRemote` 的 blob 缺失分支（sync_engine.dart:707-714）也校验了 `canHealLocal = local.contentHash == item.hash`。**3b 分支与两者不一致，属遗漏。**

### 修复建议

- 3b 分支应仿照 `_handleDownloadFailure`：本地 hash 与 item.hash 不一致时，`repairedItems[uuid]` 改用 `source.contentHash`（并更新 updatedAt/updatedBy），使 manifest 指向修复后的 blob；hash 一致时维持原逻辑。

---

## 🟢 问题 5（低）：`_preserveConflictCopy` 只 `on Exception`，截断 blob 可炸掉整次同步

### 现象

sync_engine.dart:1300-1395，`_preserveConflictCopy` 的整体 try 块只捕获 `on Exception`（1393 行）。但 `_openBlobEnvelope` → `SyncCrypto.open` → `_aesGcmDecrypt` → `envelope.sublist(0, _nonceLength)`（crypto.dart:283）在信封短于 12 字节时抛 **`RangeError`（Error，非 Exception）**。

异常穿透链：

1. `_preserveConflictCopy` 的 `on Exception` 捕获不住。
2. `_mergeAndTransfer`（无 try）→ `_syncOnce` → `sync()`（只捕 `ConflictException` / `_MigrationRequiredException`，sync_engine.dart:190/201）。
3. `SyncService.sync()`（只 `on Exception` / `on BackendUnavailableException`，sync_service.dart:469/477）→ **直达 UI 崩溃**。

同一场景在 `_downloadNote` 用 `on Object catch` 正确兜底（sync_engine.dart:1778），此处是漏网。

### 修复建议

- 将 `on Exception` 改为 `on Object catch (e, st)`，并记录日志、跳过副本保留（与 `_downloadNote` 的 Layer 1 容错语义一致）。

---

## 🟢 问题 6（低）：`markAllSynced()` 无条件全量执行，语义过于激进

### 现象

`_updateLocalState`（sync_engine.dart:1920-1936）在 PUT 成功后无条件调用 `markAllSynced()`（database_handler.dart:868-874）：

```sql
UPDATE safe_notes SET synced = 1, synced_hash = content_hash
```

这会把**本轮并未收敛**的笔记也标记为已同步：

- 上传失败的笔记（问题 1）→ `syncedHash` 被写成失败版本的新 hash。
- 下载失败（corrupt）的笔记 → 本地仍是旧内容，却被标记 synced，`syncedHash` 写成旧内容 hash。

### 后果

`syncedHash` 是冲突判定的三方合并 base（sync_engine.dart:1183-1189）。被污染的 base 会使下轮判定失真：

- 上传失败后，若他端先行编辑该笔记，本端 base = 失败的 hash，可能触发错误方向的冲突裁决。
- 下载失败时，用户若在"看似已同步"的旧版本上继续编辑，会走"双方都偏离 base"→ 生成冲突副本，虽不丢数据，但产生无谓副本。

### 修复建议

- `_updateLocalState` 改为仅对"本轮 merged 中实际采纳并成功传输/本就一致"的 uuid 调 `markSynced`（或分批 `markSynced(uuid)`）。
- 至少：排除本轮 `uploadFailed` 对应的 uuid。

---

## 附：非 Bug 但值得注意的设计点

### A. 冲突副本（数据重复的主要来源，属设计取舍）

- "冲突副本 N·设备"机制在真并发时保数据、牺牲整洁，是刻意的。
- 副本**永久保留、无去重/清理机制**；多次历史冲突会累积多份副本。
- 有设备后缀（`deviceId` 前 6 位）+ 序号探测防同 hash 链式增殖（sync_engine.dart:1413-1425），增殖已受控。
- 若产品上接受"冲突副本长期存在"，建议至少提供手动清理入口。

### B. 远端 manifest 损坏重建（D2）可能用"不完整本机数据"覆盖远端

- sync_engine.dart:251-308：远端 manifest 格式损坏时，`backupCorruptManifest` 后用**本机全量数据重建覆盖远端**。
- 若本机库长期未同步、缺他端条目 → 重建后他端条目从 manifest 消失，其 blob 变孤儿（30 天后被 purged）。
- 已有缓解：损坏文件备份 + 环形 manifest 备份（`manifest-backup/`，5 份）+ journal 远端副本（第二数据源）。但**无自动恢复**，建议在重建前提示用户，或优先尝试从环形备份恢复。

### C. `sync()` 重试循环丢弃失败尝试的 actions

- `ConflictException` / `_MigrationRequiredException` 触发重试时，前一次 `_syncOnce` 产生的笔记级 actions 不累积（仅统计 migrated 计数）。属可观测性损耗，不影响数据正确性（DB 状态已按需应用）。

### D. LWW 时钟偏差

- LWW 依赖各设备墙钟 `updatedAt`。时钟偏差会影响"谁胜"但败方经冲突副本机制保留，不丢数据。时钟严重超前设备会持续"胜出"。可考虑引入单调逻辑时钟（设计成本高，当前可接受）。

---

## 已核实的正确性亮点（无问题）

- 冲突副本判定改用"共同祖先 base"（`syncedHash`），单边编辑不造副本、真并发才保留败方（sync_engine.dart:1183-1201）。
- 下载失败保留远端条目进 merged（D3），下次同步可重试，不回滚远端较新数据（sync_engine.dart:1127-1131）。
- `_handleDownloadFailure` 自愈时正确切换 manifest hash 到重传后的 hash（sync_engine.dart:1826-1834）。
- `_buildLocalManifest` 对过期墓碑（>30 天）硬删除并加入 purgedSet，防止从远端复活（sync_engine.dart:1006-1012）。
- `repairRemote` 的 blob 缺失分支正确校验 `contentHash` 相等才用本机明文兜底（sync_engine.dart:707-714）。
- 密钥纪元守卫（B1-2）整体采用远端三元组，避免回滚远端新纪元、翻转战争（sync_engine.dart:314-321）。
- blob 内容寻址 + AAD=hash，跨设备共享 blob 去重正确（sync_engine.dart:1458-1471）。
- `markAllSynced` 之外的增量 `markSynced`、`_updateLocalState` 对 purgedUuids 的清理逻辑一致。
- 后端 putManifest 乐观锁（If-Match / If-None-Match）与 ETag 规范化正确；LocalFS 原子写（.tmp + rename）。

---

## 修复优先级建议

1. **P0**：问题 1（上传失败幽灵引用）——新增上传失败重试/持久化，或上传失败不推进 manifest。
2. **P0**：问题 2（并发 GC 误隔离）——GC 增加"新 blob 保护期"或隔离区时间戳判定。
3. **P1**：问题 4（repairRemote 3b 修不好 + 孤儿）——低风险、改动局部，可直接修。
4. **P1**：问题 3（updatedBy 击穿 `_hasEffectiveChange`）——比对排除 `updatedBy`，消除版本 churn。
5. **P2**：问题 5、6 及附注 A/B 的改进。
