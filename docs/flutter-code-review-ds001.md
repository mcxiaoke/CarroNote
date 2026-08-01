# Flutter 客户端同步流程代码审查

> 审查日期：2026-08-01
> 审查范围：`lib/sync/` 全量代码（约 5000+ 行）
> 审查目标：数据丢失、数据重复、幽灵条目、边缘情况故障，以及复杂度降低方案

---

## 一、同步架构概览

当前同步子系统由以下组件构成：

| 组件 | 文件 | 行数 | 职责 |
|------|------|------|------|
| SyncEngine | `sync_engine.dart` | ~2270 | 核心同步算法（5 步流程 + 冲突解决 + 自愈 + GC + repair） |
| Keyring | `keyring.dart` | ~1030 | 密钥管理（创建/解锁/改密码/迁移/纪元采纳） |
| Journal | `journal.dart` | ~1040 | 操作日志（审计 + 第二数据源） |
| SyncModels | `sync_models.dart` | ~1000 | 数据模型（Manifest/ManifestItem/SyncResult 等） |
| SyncService | `sync_service.dart` | ~870 | 应用层（生命周期/互斥锁/状态广播/autoSync） |
| SyncBackend | `sync_backend.dart` | ~280 | 后端抽象接口 + 环形备份工具函数 |
| 其他 | 6 个文件 | ~1200 | 后端实现（LocalFS/WebDAV/SafeServer）、加密、配置、错误类型 |

---

## 二、潜在问题

### 2.1 数据丢失

#### P1. `repairRemote` 未处理乐观锁冲突（BUG）

**位置**：[sync_engine.dart#L848](file:///c:/Home/Projects/safenotes/lib/sync/sync_engine.dart#L848)

```dart
await backend.putManifest(ciphertext, remoteResponse.etag);
```

`repairRemote` 在行 848 调用 `putManifest`，但未 catch `ConflictException`。如果另一个设备在 `repairRemote` 的 GET（行 620）和 PUT（行 848）之间修改了 manifest，本次 PUT 会直接抛未处理异常。调用方 [SyncService.repairRemote](file:///c:/Home/Projects/safenotes/lib/sync/sync_service.dart#L540) 的 `on Exception` 能捕获到，但用户收到的错误信息是 `修复异常：ConflictException: ...`，没有重试机制。

**对比**：`sync()` 有完整的 3 次重试循环（行 171-223），而 `repairRemote` 是一次性操作。

**影响**：修复任务在冲突时失败，用户需要重新点击"修复"按钮。修复过程中其他设备的正常同步可能导致修复反复失败。

---

#### P2. 墓碑 GC 硬删除与 PUT 失败之间的竞态

**位置**：[sync_engine.dart#L1006-L1011](file:///c:/Home/Projects/safenotes/lib/sync/sync_engine.dart#L1006-L1011)

```dart
if (note.deleted && (now - note.updatedAt) > kTombstoneGcThresholdMs) {
  await database.hardDeleteByUuid(note.uuid);
  continue;
}
```

`_buildLocalManifest` 在构建 manifest 时，对超过 30 天的墓碑 **直接硬删除**本地数据库记录。这是**在 PUT manifest 成功之前**就执行的破坏性操作。

**触发路径**：
1. 墓碑 A 超过 30 天
2. `_buildLocalManifest` 硬删除 A 的本地记录，不放入 manifest items
3. `_mergeAndTransfer` 中 `purgedSet` 包含 A 的 uuid，阻止从远端重下载
4. PUT manifest 因乐观锁冲突失败（3 次重试均失败）
5. 本地已无 A 的记录，远端 manifest 中 A 的墓碑仍在
6. 下次同步：`_buildLocalManifest` 不会产生 A（已硬删除），`purgedSet` 仍阻止重下载
7. A 在所有设备上"消失"——既不在本地，manifest 也引用不到

**恢复路径**：只能通过 journal 的 `replayKeyState` + `fetchRemoteEntries` 手动恢复，但这条路径当前无 UI 入口。

**设计权衡**：30 天阈值保证离线设备在此期间已同步到删除操作。但"PUT 前硬删除"的时序是根本问题。

---

#### P3. dataKey 迁移后重试失败导致 pendingReupload 悬空

**位置**：[sync_engine.dart#L889-L893](file:///c:/Home/Projects/safenotes/lib/sync/sync_engine.dart#L889-L893)

`_executeMigration` 调用 `keyring.migrateToRemote`，该函数内部依次执行：
1. `database.reEncryptAllNotes`（本地重加密，单事务）
2. `database.markAllForBlobReupload`（标记所有笔记需要强制重传 blob）
3. 返回新 Keyring 实例

然后 `_syncOnce` 抛 `_MigrationRequiredException`。外层 `sync()` 的 catch 块（行 201-218）捕获后继续重试循环（行 213-219）。

**问题**：如果重试也因为乐观锁冲突达到 3 次上限而失败，`clearAllPendingReupload`（行 579）不会执行。下次同步时 `pendingReupload` 集合包含所有笔记，每篇笔记都会触发强制 blob 重传——虽然不丢数据，但产生一次全量 blob 上传。

**影响**：对于有 1000 篇笔记的用户，下次同步会产生 1000 次额外的 `putBlob` 调用，网络流量和耗时陡增。

---

### 2.2 数据重复 / 幽灵条目

#### P4. 冲突副本链式增殖风险

**位置**：[sync_engine.dart#L1286-L1396](file:///c:/Home/Projects/safenotes/lib/sync/sync_engine.dart#L1286-L1396)

`_preserveConflictCopy` + `_makeConflictCopyTitle` 的设计已明确考虑了增殖问题：
- 标题追加 `(冲突副本 N·dev)` 使 hash 与原件不同
- 用 `existsContentHash` 探测到 99 次碰撞
- 设备 ID 后缀防止多设备生成同名副本

**剩余风险**：N 设备并发冲突时，每台设备都独立触发副本保留。例如 3 台设备同时对同一笔记做不同编辑，同步后可能出现：
- `笔记 (冲突副本 1·devA)` — A 设备生成
- `笔记 (冲突副本 1·devB)` — B 设备生成
- `笔记 (冲突副本 1·devC)` — C 设备生成

虽然不会无限增殖（每台设备最多 1 份），但用户会看到 3 条内容几乎相同的笔记。

**历史**：注释提到"实测曾出现一份内容对应 13 个活跃 uuid"，当前设计已大幅改善，但多设备场景仍非零风险。

---

#### P5. 孤儿 blob GC 的并发竞态

**位置**：[sync_engine.dart#L1958-L2012](file:///c:/Home/Projects/safenotes/lib/sync/sync_engine.dart#L1958-L2012)

```dart
// 注意：并发同步场景下，A 设备正在 GC 时 B 设备可能正在上传新 blob。
// 此时 A 设备的 listBlobs 可能包含 B 刚上传但还未写入 manifest 的 blob，
// 误判为孤儿删除。
```

**触发路径**：
1. 设备 B 上传 blob X（`putBlob` 成功）
2. 设备 A 执行 `_gcOrphanBlobs`：`listBlobs()` 返回包含 X，当前 manifest 不引用 X
3. A 把 X 软删除到隔离区（`deleteBlobSoft`）
4. 30 天后 B 设备仍未 PUT manifest（离线或故障）
5. `purgeOrphans` 彻底删除 X
6. B 上线后 PUT manifest 引用 X，但 X 已不存在

**缓解**：P1-2 的软删除到隔离区 + 30 天保留期显著降低了风险窗口。且 `putBlob` 幂等，B 下次同步会重新上传 blob。最坏情况是 B 的 blob 被删除后，B 必须再次同步才能恢复。

---

### 2.3 边缘情况 / 竞态

#### P6. `switchBackend` 不检查同步互斥锁

**位置**：[sync_service.dart#L590-L613](file:///c:/Home/Projects/safenotes/lib/sync/sync_service.dart#L590-L613)

```dart
Future<void> switchBackend({...}) async {
  await _backend?.close();  // 可能正在被 engine.sync() 使用
  _backend = backend;
  await backend.init();
  ...
}
```

`switchBackend` 未检查 `_syncInProgress`。如果用户在同步进行中切换后端：
- `_backend.close()` 关闭正在被 `SyncEngine` 使用的 HTTP 连接或文件句柄
- `SyncEngine` 的后续 I/O 操作可能收到 `BackendUnavailableException` 或静默 I/O 错误
- 同步结果不可预测

**对比**：`sync()` 和 `repairRemote()` 都检查了 `_syncInProgress` 互斥锁，但 `switchBackend` 漏了。

---

#### P7. autoSync 连续编辑的延迟累积

**位置**：[sync_service.dart#L568-L581](file:///c:/Home/Projects/safenotes/lib/sync/sync_service.dart#L568-L581)

```dart
void autoSync() {
  _autoSyncTimer?.cancel();
  _autoSyncTimer = Timer(_autoSyncDelay, () {
    sync().then((result) {
      if (result == null && _engine != null) {
        _autoSyncTimer = Timer(_autoSyncDelay, () => sync());
      }
    });
  });
}
```

**触发路径**：
1. 用户快速连续编辑（如打字时自动保存）
2. 每次编辑重置 debounce 定时器
3. 编辑停止后 3 秒触发 `sync()`
4. 若上次 sync 尚未完成，`sync()` 返回 null
5. L3 修复再排程一次 3 秒
6. 用户从停止编辑到同步实际开始：最多 6 秒

**影响**：对于已经习惯"即刻同步"的用户，感知延迟较明显。但这是避免重复同步的设计取舍，不影响正确性。

---

#### P8. Journal 归档未上传即被淘汰，不可恢复

**位置**：[journal.dart#L716-L732](file:///c:/Home/Projects/safenotes/lib/sync/journal.dart#L716-L732)

```dart
if (seq > _uploadedSeq) {
  Log.sync.w('[Journal] 归档 log-$seq.json 尚未上传远端即被淘汰，'
      '该段历史将不可恢复（uploadedSeq=$_uploadedSeq）');
}
```

**触发路径**：
1. 离线状态下用户做了大量操作（填满 1000 条 journal 条目）
2. journal 归档为 `log-1000.json`
3. 继续操作，再次归档（`log-2000.json`）
4. 再归档（`log-3000.json`）→ 最早归档 `log-1000.json` 被删除
5. 网络恢复，此时 `log-1000.json` 已永久丢失
6. 若 manifest 损坏且 journal 是唯一恢复来源，则 `log-1000.json` 覆盖的时段不可恢复

---

### 2.4 降级行为

#### P9. Journal 内存模式使第二数据源完全失效

**位置**：[journal.dart#L423-L435](file:///c:/Home/Projects/safenotes/lib/sync/journal.dart#L423-L435)

`Journal.inMemory` 的 `syncToRemote` 在行 909 直接 return：

```dart
if (_closed || _memoryOnly) return;
```

当 `getApplicationSupportDirectory()` 在某些受限环境失败时，`SyncService._openJournal`（行 234-252）降级为内存模式。此时：
- Journal 仍有审计日志功能（`append` 正常工作）
- 但远端副本不上传，第二数据源角色完全失效
- 如果 manifest 损坏，没有远端 journal 可恢复 key state

---

## 三、复杂度分析

### 3.1 量化指标

| 测量维度 | 数值 |
|---------|------|
| SyncEngine 总行数 | ~2270 |
| \_syncOnce 方法行数 | ~370 行 |
| \_mergeAndTransfer 方法行数 | ~200 行 |
| \_downloadNote + \_handleDownloadFailure 行数 | ~320 行 |
| Keyring 总行数 | ~1030 行 |
| Journal 总行数 | ~1040 行 |
| SyncActionType 种类 | 11 种 |
| 容错/自愈层数 | 4 层（Layer 1/2a/2b/3） |
| 解密 AAD 回退格式数 | 3 种（epoch/v2/v1） |
| 冲突解决交互路径数 | 8 条（_mergeAndTransfer 的 allUuids 循环） |

### 3.2 主要复杂度来源

**来源 1：dataKey 迁移逻辑与同步流程高度耦合**
`_syncOnce` 的第 251-483 行（约 230 行）是 dataKey 迁移逻辑，含 4 个场景（a/b/c/d）的分支，嵌套 3 层 try-catch。这段逻辑与"同步"的核心职责（拉取 manifest → 比对 → 传输）正交，但完全嵌入在 `_syncOnce` 内部。

**来源 2：下载/自愈的错误处理链跨 4 个方法**
- `_downloadNote`（行 1587-1786）→ 尝试下载 blob
- `_handleDownloadFailure`（行 1807-1909）→ blob 解密失败时的自愈
- `_openBlobEnvelope`（行 1536-1561）→ 3 种 AAD 格式的回退
- 三个 `_DownloadOutcome` 子类型（Success/Healed/Failed）

阅读一条笔记的下载路径需要跨 4 个方法、约 320 行代码，且每个方法都有独立的 try-catch 边界。

**来源 3：SyncEngine 承担了太多职责**
SyncEngine 同时负责：
- 同步算法（5 步流程）
- 密钥迁移（4 种场景 + 密码验证）
- 冲突解决（LWW + 副本保留 + 标题碰撞探测）
- 自愈重传（3 层容错 + 孪生笔记匹配）
- 垃圾回收（孤儿 blob 软删除 + 隔离区清理 + journal 记录）
- 远程修复（repairRemote 全量校验）

**来源 4：Journal 的"第二数据源"角色增加约 200 行但无实际调用方**
`syncToRemote`、`fetchRemoteEntries`、`replayKeyState` 等功能在全局代码中无调用方，但增加了约 200 行代码和远端副本上传水位的追踪复杂度。

---

## 四、降低复杂度的建议

### 建议 1（高收益，推荐立即实施）：把 dataKey 迁移从 `_syncOnce` 剥离

**现状**：`_syncOnce` 的 ~230 行迁移逻辑与同步主流程深度耦合，4 个场景分支嵌套大量 try-catch。

**方案**：在 `_syncOnce` 开头抽取为独立方法：

```dart
Future<MigrationPrepResult> _prepareMigration({
  required SyncBackendResponse remoteResponse,
  required List<SyncAction> actions,
}) async {
  // 1. 解析远端 header
  // 2. 检查是否需要迁移（4 种场景）
  // 3. 执行迁移（如需）
  // 4. 返回解析后的 remoteManifest + 迁移结果
}
```

**效果**：
- `_syncOnce` 减少约 200 行
- 迁移逻辑可单独编写单元测试
- 每个场景的边界更清晰

---

### 建议 2（高收益，推荐实施）：修复 `repairRemote` 的乐观锁冲突

**现状**：`repairRemote` 的 PUT manifest 无重试机制，遇到 `ConflictException` 直接失败。

**方案**：在 `repairRemote` 的 PUT manifest 周围添加简单的 3 次重试循环（与 `sync()` 一致）：

```dart
for (int attempt = 1; attempt <= 3; attempt++) {
  try {
    await backend.putManifest(ciphertext, remoteResponse.etag);
    break;
  } on ConflictException {
    if (attempt == 3) rethrow;
    // 重新 GET manifest 获取最新 etag
    final updated = await backend.getManifest();
    remoteResponse = updated;
    // 重新序列化（items 不变，header version+1）
    ciphertext = ManifestCrypto.serialize(_dataKey, manifest);
  }
}
```

**效果**：修复一个真实 bug，与 `sync()` 的可靠性对齐。

---

### 建议 3（中收益，推荐重构时实施）：合并下载/自愈的错误处理链

**现状**：`_downloadNote` → `_handleDownloadFailure` → `_openBlobEnvelope` 链跨 320 行。

**方案**：合并为一个方法，保持单一职责但减少跳转：

```dart
Future<DownloadResult> _downloadNote(
  String uuid, ManifestItem item, List<SyncAction> actions,
) async {
  // 1. 墓碑处理（6 行）
  // 2. 下载 blob + 判空（10 行）
  // 3. 解密 blob（三重 AAD 回退，20 行）
  // 4. 解密失败 → 本机明文自愈（15 行）
  // 5. 解密失败 → 孪生笔记自愈（15 行）
  // 6. 解密成功 → hash 校验（10 行）
  // 7. 写入本地数据库（10 行）
  // 总共约 90 行，不跳转
}
```

**效果**：减少 3 个方法、约 200 行代码，阅读路径从 4 次跳转变为 1 个方法。

---

### 建议 4（中收益，推荐重构时实施）：简化冲突副本保留策略

**现状**：`_preserveConflictCopy` + `_makeConflictCopyTitle` 的探测循环（1-99 次哈希碰撞检查）复杂且仍有增殖风险。

**方案 A（推荐）**：败方以纯文本追加到胜方笔记末尾，不创建新 UUID。

```dart
if (shouldPreserveCopy) {
  final loserContent = _downloadLoserContent(loserItem);
  _appendToWinnerNote(winner, loserContent);
  // 不创建新 UUID，不加入 mergedItems
}
```

**优点**：
- 零增殖风险（没有新 UUID 就不会被再次卷入同步）
- 不需要标题碰撞探测循环
- 用户在同一笔记中看到"冲突历史"，体验更直观

**缺点**：
- 败方丢失了独立的创建/更新时间戳
- 败方内容无法被其他设备单独引用

**方案 B（次选）**：保留现有方案，但把 `_makeConflictCopyTitle` 的探测改为基于设备 ID + 时间戳，避免碰撞探测循环：

```dart
final copyTitle = '$baseTitle (冲突副本 $dev-${DateTime.now().millisecondsSinceEpoch})';
```

**优点**：O(1) 复杂度，零碰撞风险
**缺点**：标题时间戳精确到毫秒，可读性略差

---

### 建议 5（中收益，可选）：减少 SyncActionType 种类

**现状**：11 种 SyncActionType，部分语义重叠。

**方案**：合并为 7 种：

| 当前 | 合并后 | 理由 |
|------|--------|------|
| upload | upload | — |
| download | download | — |
| delete | delete | — |
| skip | skip | — |
| conflict | conflict | — |
| **uploadFailed** | **error** | 与 corrupt 语义重叠 |
| **corrupt** | **error** | 与 uploadFailed 语义重叠 |
| heal | heal | 保留，自愈是重要诊断信息 |
| migrate | 删除 | 由 journal key.migrate 事件替代 |
| 新增 | — | — |

**效果**：减少 4 种类型，switch 分支减少，`_journalAction` 和 `_logAction` 的代码减少约 30 行。

---

### 建议 6（低收益，未来考虑）：Journal 第二数据源可选化

**现状**：`syncToRemote`、`fetchRemoteEntries`、`replayKeyState` 等功能增加约 200 行复杂度，但当前无任何调用方使用远端 journal 恢复。

**方案**：将 Journal 远端副本改为"显式触发"模式：
- 保留本地 journal（审计日志）
- 移除 `syncToRemote` 的自动调用
- 在设置页添加"备份 journal 到远端"按钮
- 或移除远端副本功能，保持 journal 本地-only

**风险**：移除后 manifest 单点故障的恢复能力下降。需评估是否值得。

---

### 建议 7（低收益，未来考虑）：修复 `switchBackend` 的互斥锁

**现状**：`switchBackend` 不检查 `_syncInProgress`。

**方案**：在 `switchBackend` 开头检查互斥锁，有同步进行时等待或拒绝：

```dart
Future<void> switchBackend({...}) async {
  if (_syncInProgress) {
    throw StateError('同步进行中，无法切换后端，请稍后重试');
  }
  // ... 现有逻辑
}
```

**效果**：防止竞态导致的后端连接损坏。

---

## 五、按优先级汇总

| 优先级 | 建议 | 类型 | 预计工作量 |
|--------|------|------|-----------|
| **P0** | 建议 2：修复 `repairRemote` 乐观锁冲突 | Bug 修复 | 1 小时 |
| **P0** | 建议 7：`switchBackend` 加互斥锁 | Bug 修复 | 0.5 小时 |
| **P1** | 建议 1：dataKey 迁移逻辑剥离 | 重构 | 3-4 小时 |
| **P1** | 建议 3：合并下载/自愈方法链 | 重构 | 2-3 小时 |
| **P2** | 建议 4：简化冲突副本保留策略 | 重构 | 2 小时 |
| **P2** | 建议 5：减少 SyncActionType | 重构 | 1 小时 |
| **P3** | 建议 6：Journal 远端副本可选化 | 特性调整 | 2 小时 |

---

## 六、与现有测试的关系

| 测试文件 | 覆盖范围 | 建议变更后的影响 |
|----------|---------|----------------|
| `sync_engine_test.dart` | 基本同步路径、LWW、墓碑、乐观锁 | 建议 1/3 不影响测试逻辑，无需改测试 |
| `chaos_multi_client_test.dart` | 多客户端并发 + 随机时序 | 建议 4 需验证冲突副本减少后仍不丢数据 |
| `p0p1_self_heal_test.dart` | 自愈/下载失败修复 | 建议 3 需确保自愈路径不退化 |
| `multi_device_test.dart` | 多设备场景 | 建议 1 需确保迁移场景覆盖 |
| `journal_test.dart` | Journal 日志 | 建议 6 需调整远端副本测试 |
| `keyring_test.dart` | 密钥管理 | 建议 1 无影响 |