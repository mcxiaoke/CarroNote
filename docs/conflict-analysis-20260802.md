# 单客户端 WebDAV 同步误报 conflict 的诊断报告

> 生成时间：2026-08-02 11:25:06
> 环境：Windows 客户端 + WebDAV 同步，单客户端测试（未配置其它同步端）
> 日志来源：`build/windows/x64/runner/Debug/logs/safenotes-20260802.log`
> Journal 来源：`C:/Users/mcxiaoke/AppData/Roaming/com.trisven/safenotes/journal/log.json`

## 1. 结论（TL;DR）

日志里出现的 `conflict` **不是真实的并发冲突，而是同步引擎的「分类逻辑缺陷」**。

在**单客户端**场景下，只要对一条「已同步过」的笔记执行 **删除** 或 **编辑**，同步引擎就一定会把它记成一次 conflict（LWW: local won）。因为场景里只有一个写入方、远端从未改动过该条目，这本质属于「本地单边变更 / 快进（fast-forward）」，不该算冲突。

- 数据结果正确：没有产生重复副本，墓碑最终正确上传，最终状态收敛。
- 但代价是 **WARN 噪音 + `conflicts` 计数虚高**，真正多设备并发冲突会被淹没。

**附带发现一个真实竞态 Bug（P1）**：同步期内的本地写入会被 `_updateLocalState` 错误地标记为「已同步」，污染后续判断的基准（base），在多设备真并发下存在丢数据风险。

---

## 2. 现象

`safenotes-20260802.log` 第 136–137 行，同一时刻、同一 uuid 出现两条记录：

```
10:59:40.942 [INFO]  ✗ delete   uuid=972b5b91… tombstone (no blob)
10:59:40.942 [WARN]  ⚡ conflict uuid=972b5b91… local won (LWW: local newer)
```

- 一条 `delete`（删除动作，生成本地墓碑）；
- 一条 `conflict`（被引擎判为冲突）。

两者针对的是**同一个 uuid、同一秒钟**。这表明「删除动作」与「冲突动作」是**同一件事**——不存在第二个写入方。

---

## 3. 证据链

### 3.1 日志侧

- 删除笔记 `972b5b91…` 时，先打 `delete / tombstone (no blob)`，紧接着打 `conflict / local won (LWW)`。
- 对比新建笔记场景（`10:58:57` 那一次），`conflicts=0`，印证「新建走的是另一条分支，不会误报」。

### 3.2 Journal 侧

`journal/log.json` 中同样成对出现：

| seq | 类型 | uuid 前 8 位 | 说明 |
|----|------|-------------|------|
| 525 | `note.delete` | `972b5b91` | 本地软删除，生成墓碑 |
| 526 | `note.conflict` | `972b5b91` | 引擎把它归类为冲突 |

同一 uuid 的 `delete` 与 `conflict` 紧邻，**证明这是同一次操作被记成了两次语义不同的事件**，而不是真的有两方写入。

---

## 4. 根因

三处代码串起来，构成了误判：

### 4.1 `database_handler.dart:537` `softDelete()`

只修改 `deleted=1 / updatedAt=now / synced=0`，**但 `content_hash` 保持不变**。

```dart
// softDelete: 仅置 deleted 标志、刷新 updatedAt、清空 synced 标志
// 注意：content_hash 未变
```

→ 墓碑条目依然携带「原始内容 hash」，只是多了 `deleted: true`。

### 4.2 `sync_engine.dart:964` 构建本地 manifest

构建本地 manifest 时，墓碑条目仍带原 hash，只是 `deleted: true`、`updatedAt` 变新。

### 4.3 `sync_engine.dart:1236` `_itemsEqual(a, b)`

相等判定要求 `hash 相同 && deleted 相同`：

```
_itemsEqual(a,b):
    return a.hash == b.hash && a.deleted == b.deleted
```

- 本地墓碑（hash=原始, deleted=true） vs 远端活条目（hash=原始, deleted=false）
- → hash 相同，但 deleted 不同 → 返回 **false** → 落进 1126 行的 `else` 分支「冲突：LWW 解决」→ 1198 行**无条件** `_addAction(conflict)`。

### 4.4 合并循环缺第四种分支

合并循环当前只有三个分支：
1. 只本地有 → 上传；
2. 只远端有 → 下载；
3. 双方都有且不等 → 冲突（LWW + 可选冲突副本）。

**缺了第四种：双方都有，但只有一边偏离了共同祖先（base）——这是快进（fast-forward），不是冲突。**

### 4.5 引擎其实已经算出了答案（却没用上）

`sync_engine.dart:1142-1148` 已经用 `syncedHash` 当 base 算了 `localChanged` / `remoteChanged`：

```dart
// base = syncedHash（即上次收敛时远端的 hash）
localChanged  = (localHash != baseHash) || (localDeleted != baseDeleted)
remoteChanged = (remoteHash != baseHash) || (remoteDeleted != baseDeleted)
```

本例中 `base == 远端 hash`，远端从未改动 → `remoteChanged = false`。
但这个结果**只喂给了 `shouldPreserveCopy` 决定是否保留副本，没有用来决定 action 类型**，于是仍走「冲突」分支。

---

## 5. 影响面

| 操作 | 是否误报 conflict | 说明 |
|------|------------------|------|
| 删除已同步笔记 | **必现** | 本次复现的就是这一条 |
| 编辑已同步笔记 | **必现** | hash 变化，`_itemsEqual` 同样返回 false；本次会话未编辑旧笔记，故只出现 1 次 |
| 新建笔记 | 不会 | 走「只本地有」分支（日志 `10:58:57` 那次 `conflicts=0` 印证） |

**数据正确性**：`shouldPreserveCopy=false`，没有生成重复副本，墓碑正确上传，最终状态正确。问题集中在 WARN 噪音与 `conflicts` 计数虚高。

---

## 6. 附带发现的真实 Bug（P1）：同步期内写入竞态

日志 `10:59:32`–`10:59:36` 一段揭示了第二个问题：

```
10:59:32.342  同步开始
10:59:34.419  读全量快照 43 条（墓碑 1）      ← 删除还没发生
10:59:34.443  用户确认删除
10:59:34.464  softDelete 落库，synced=0
10:59:34.497  标记全部笔记为已同步: 43 条      ← 把「刚删的这条」也标成已同步了！
10:59:36.632  同步完成 skipped=43 conflicts=0  ← 墓碑根本没上传
```

`_updateLocalState` 的 `markAllSyncedExcept` 只排除了「上传失败」的 uuid，**没有排除「快照之后才改动」的行**。于是这一轮把一个**从未上传**的墓碑标记成了 `synced=1` 且 `synced_hash = content_hash`（等于宣称已与远端收敛）。

- 本次侥幸没事：下一轮走的是「全量 manifest diff」，而不是信任 `synced` 标志。
- 但**它污染了 base**：换成**编辑**场景（编辑会改 `content_hash`），下一轮的 base 会是「远端根本没有的新 hash」→ `localChanged` 被算成 `false` → 不保留冲突副本 → 多设备真并发时**有丢数据风险**。

这正好是 `sync_engine` 注释里 DS002 / P6 想堵的洞，只是排除集合漏了「快照之后变更」这一类。

---

## 7. 修复建议

### 7.1 加快进（fast-forward）分支（优先级最高，消掉误报）

在 `sync_engine.dart:1126` 的 `else` 分支里，先按 base 做三方分类：

```dart
// 进入 else 分支：双方都有，但不一定真冲突
if (localChanged && !remoteChanged) {
  // 远端未偏离 base -> 本地单边变更 -> 正常上传 / 删除
  _addAction(local.deleted ? delete : upload, uuid);
} else if (!localChanged && remoteChanged) {
  // 本地未偏离 base -> 远端单边变更 -> 正常下载
  _addAction(download, uuid);
} else {
  // 双方都偏离 base -> 真冲突 -> 沿用现有 LWW + 冲突副本逻辑
  _addAction(conflict, uuid);
}
```

### 7.2 base 需带 `deleted` 维度

`synced_hash` 只存内容 hash，而软删除不改 hash，直接拿它判 `localChanged` 会得到 `false`（实际本地改了 deleted）。

- 方案 A：新增列 `synced_deleted`，base 比较时同时比较 `hash` 与 `deleted`；
- 方案 B：把 base 存成 `hash:deleted` 组合值（如 `sha256:bool`）。

### 7.3 修复竞态（P1，单独提交）

`_updateLocalState` 的 exclude 集合补上「快照时间之后 `updatedAt` 有变化」的行；或改为**按快照里的 `uuid + hash` 逐条 `markSynced`**，仅对确实已上传/已确认的条目置 `synced=1` 与 `synced_hash`。

### 7.4 测试

- 单客户端删除/编辑已同步笔记 → 断言 `conflicts == 0`、产生 `upload`/`delete` 动作、无 `conflict` 事件；
- 双客户端并发编辑同一笔记 → 断言仍产生 `conflict` 且保留副本（`shouldPreserveCopy=true`）；
- 同步期内本地写入 → 断言不会被误标 `synced=1`。

---

## 8. 后续动作

建议顺序：先落地 7.1 + 7.2（消除误报且不改变现有数据流），7.3 单独一个提交，改完各自补齐测试。

是否需要直接动手改？若需要，我倾向先做 7.1 + 7.2，再单独提交 7.3。

---

## 9. 修复实施总结（2026-08-02 落地）

### 9.1 已完成修复

#### P0-B：fast-forward 单边变更分流（消除误报 conflict）

**实施内容**（commit `2b497f8`）：

1. **`lib/models/safenote.dart`**：新增 `syncedDeleted` 字段，与 `syncedHash` 共同构成三方合并 base 的 `(hash, deleted)` 二元组。`softDelete` 不改 `content_hash`，单独比 hash 无法识别本地删除为变更（§7.2 方案 A 落地）。

2. **`lib/data/database_handler.dart`**：
   - schema version 3 → 4：`ALTER TABLE ... ADD COLUMN synced_deleted INTEGER NOT NULL DEFAULT 0`
   - `_onUpgrade` 老库迁移：老数据 `synced_deleted` 初始化为 0（与已同步笔记的 deleted=false 语义一致）
   - `markSynced` / `markAllSynced` / `markAllSyncedExcept` 同步刷新 `syncedDeleted = deleted`

3. **`lib/sync/sync_engine.dart` `_mergeAndTransfer`**（§7.1 落地）：`else` 分支三分流
   - `base != null && localChanged && !remoteChanged` → fast-forward 本地单边（上传覆盖，不记 conflict）
   - `base != null && !localChanged && remoteChanged` → fast-forward 远端单边（下载覆盖，不记 conflict）
   - 双方都偏离 base 或 `base == null` → 真冲突，沿用 LWW + `shouldPreserveCopy` 副本保留

**关键决策**：`base == null`（从未同步过）保守退化为真冲突——绝不丢数据，顶多多留一份副本，且仍要求双方活跃。

#### P1-A：`_updateLocalState` 白名单 markSynced（堵同步期写入竞态）

**实施内容**（commit `ca37f7b`）：

1. **`lib/data/database_handler.dart`**：新增 `markSyncedForUuids(Set<String> uuids)`，只标记传入的 uuid（白名单语义，与 `markAllSyncedExcept` 的黑名单相对）。

2. **`lib/sync/sync_engine.dart` `_updateLocalState`**：改为白名单模式
   - 读全量本地笔记，逐条比对「当前 `(content_hash, deleted) == merged.items[uuid]`」才纳入收敛集合
   - 同步期间被编辑的笔记：当前 hash ≠ merged 快照 → 跳过，保持 `synced=0`、`synced_hash=旧 base`
   - 下载覆盖的笔记：`_downloadNote` 已把本地更新为远端内容 → 当前 == merged → 标记
   - 同步期间新建的笔记：不在 `merged.items` → 跳过

**关键洞察**：`merged` 基于同步开始的本地快照构建，同步期间被改的笔记当前状态必然 ≠ merged，从根上杜绝误标。

### 9.2 测试覆盖

| 测试组 | 用例数 | 验证点 |
|--------|--------|--------|
| `fast-forward 单边变更（P0-B 修复）` | 3 | 单边删除/编辑不记 conflict、base 正确更新、二次同步稳定 |
| `LWW 冲突解决`（补充） | 3 | 单边编辑不记 conflict、base=null 退化真冲突、真双方冲突仍记 conflict+副本 |
| `P1-A 同步期写入竞态` | 3 | 同步期间编辑/新建不被误标 synced=1、base 不污染、下次同步不丢数据 |

测试结果：
- `test/sync/sync_engine_test.dart`：24 tests passed
- `test/sync/multi_device_test.dart` + `test/sync/p0p1_self_heal_test.dart` + sync_engine：47 tests passed
- `flutter analyze`：No issues found

### 9.3 影响面分析（同步逻辑改动风险评估）

用户特别要求评估「同步逻辑修改会不会影响别的同步或数据逻辑导致新 bug」。逐项核查：

| 场景 | P0-B 前 | P0-B 后 | 风险 |
|------|---------|---------|------|
| 单客户端删除已同步笔记 | 误报 conflict，墓碑仍上传 | fast-forward 上传墓碑，不记 conflict | ✓ 行为改进，数据流不变 |
| 单客户端编辑已同步笔记 | 误报 conflict，新内容仍上传 | fast-forward 上传覆盖，不记 conflict | ✓ 行为改进，数据流不变 |
| 真双方并发冲突（都偏离 base） | LWW + 副本保留 + conflict | 同上，不变 | ✓ 无影响 |
| `base == null`（从未同步/迁移前） | 保守真冲突 + 副本 | 同上，不变 | ✓ 无影响 |
| 首次同步（仅本地有） | 走「仅本地有」上传分支 | 不变 | ✓ 无影响 |
| 新设备同步（仅远端有） | 走「仅远端有」下载分支 | 不变 | ✓ 无影响 |
| 已同步且双方一致 | `_itemsEqual` → skip | 不变 | ✓ 无影响 |
| 同步期间用户编辑 | 误标 synced=1，base 污染，下次可能丢数据 | 跳过 markSynced，下次 fast-forward 上传 | ✓ 修复丢数据 |

**关键不变量**：
- `conflicts` 计数仅用于日志统计和 `hasConflicts` UI 提示（`sync_service.dart:669`）。P0-B 后单边编辑不再触发提示是预期改进，非 bug。
- `_preserveConflictCopy` 只在 `shouldPreserveCopy=true`（双方都偏离 base 且都未删且 hash 不同）时调用。fast-forward 场景下 `shouldPreserveCopy` 必然 false，原实现也只是多记 conflict action、不调 `_preserveConflictCopy`。P0-B 实际只是「不再多记 conflict action」，数据流完全不变。
- `markAllSyncedExcept` 保留未删除（仅 `_updateLocalState` 不再调用），其他测试若直接调用不受影响。

**多设备既有测试全部通过**（multi_device 23 + p0p1_self_heal），印证 fast-forward 分流与白名单 markSynced 不破坏多设备并发、改密码迁移、墓碑 GC、blob 自愈等既有逻辑。

### 9.4 未实施项（P2/P3，建议后续单独评估）

本次只落地数据正确性相关的 P0-B + P1-A。以下优化项**不涉及数据正确性**，风险/收益需单独评估：

- **P2：`SyncBackend.headBlob` 上传前探测**——避免 manifest PUT 失败后重复上传 blob（性能优化）。需改 `SyncBackend` 接口 + 所有实现（LocalFS/WebDAV/SafeServer/FakeBackend），影响面较大。
- ~~P3-a：blob 上传重试退避~~（已实施，见 §10）
- ~~P3-b：`autoSync` 互斥增强~~（已实施，见 §10）
- ~~P3-c：journal 增加 manifest PUT 事件~~（已实施，见 §10）

建议：P2 单独立项，配套测试，避免与本次数据正确性修复混在一起增加回滚难度。本次 P0-B + P1-A 的两个 commit 可独立回滚。

---

## 10. P3 低风险优化实施总结（2026-08-02 12:10 落地）

P0-B + P1-A 数据正确性修复落地后，用户要求继续实施 P3 低风险优化（不改数据流、不破坏既有功能）。本节记录 P3-a / P3-b / P3-c / P3-log 四项的实施内容、影响面分析与回归验证。

### 10.1 已完成 P3 修复

#### P3-a：blob 操作重试退避（commit `e9e6a79`）

**实施内容**：

1. `lib/sync/sync_engine.dart` 新增私有 helper `_withBlobRetry<T>(op, opName, hash)`，对 `backend.putBlob` / `getBlob` 做指数退避重试：
   - **仅重试 `BackendUnavailableException`**：网络/存储临时不可用。`ConflictException`（manifest 层语义）与其他 `Object` 异常直接抛出，不吞掉。
   - **重试次数 2 次（共 3 次尝试）**：与 `sync()` 的 `maxRetries` 对齐。
   - **指数退避 200ms → 400ms**：小步长避免同步时长被放大太多。
   - **`getBlob` 返回 null 不重试**：null 是「blob 不存在」的合法语义，重试无意义。
   - **`putBlob` 幂等**：`SyncBackend.putBlob` 契约保证相同 hash+data 多次调用结果一致，重试覆盖写安全。

2. 替换 4 个 blob 操作调用点：
   - `_uploadNote` 中的 `putBlob`（line 1609）
   - `_repairRemoteOnce` 中的 `getBlob`（line 750）
   - `_preserveConflictCopy` 中的 `getBlob`（line 1424）
   - `_downloadNote` 中的 `getBlob`（line 1725）

#### P3-b：autoSync 互斥增强（commit `5b52525`）

**实施内容**：

1. `lib/sync/sync_service.dart` `autoSync()` 的 `then()` 回调增强：
   - **race 修复**：sync 完成后的 L3 re-schedule 检查 `_autoSyncTimer?.isActive`，若已有用户在 sync 期间新触发的 pending timer 则不覆盖，避免「T6 完成的 sync 覆盖 T4 用户编辑排程的 timer」导致用户最新编辑被立即基于旧状态同步、多余一次同步开销。
   - **失败可重试**：sync 返回非 null 但 `success=false` 时（网络抖动等），排程一次重试；为避免失败死循环，限制最多 1 次失败重试（`_autoSyncFailureRetried` 标志位），重试成功或再次失败后清零。
   - **状态可见**：在 timer 触发 / 被跳过 / re-schedule 各路径补 debug 日志。

2. `dispose()` / `logout()` 时清零 `_autoSyncFailureRetried`，避免状态泄漏。

#### P3-c：journal manifest PUT 事件 + 乐观锁重试事件（commit `e4147ad` + `e9e6a79`）

**实施内容**：

1. `lib/sync/journal.dart` `JournalEventType` 扩展两个事件类型：
   - `syncManifestPut('sync.manifestPut')`：manifest PUT 成功（与 `syncManifestRebuild` 区分：后者是「损坏后用本地数据重建」的异常路径，本项是「正常合并后写回远端」的常规路径）。
   - `syncOptimisticLockRetry('sync.optimisticLockRetry')`：乐观锁冲突重试（ETag 不匹配触发的回退重试）。

2. `lib/sync/sync_engine.dart` 三条 PUT manifest 路径都补 journal 落地：
   - 正常合并路径（line 617）：`syncManifestPut(done, version/attempt/items/backedUp)`
   - 损坏重建路径（line 338）：`syncManifestPut(done, rebuild-after-corrupt)`
   - repair 路径（line 882）：`syncManifestPut(done, repair)`

3. 乐观锁冲突 catch 分支（line 241）：`syncOptimisticLockRetry(attempt/$maxRetries: $e)`

#### P3-log：关键日志记录补全（commit `e9e6a79` + `5b52525`）

**实施内容**：通过 search 子代理扫描 `lib/sync/` 全部 .dart 文件，识别 11 个潜在缺失点，按 P0/P1/P2/P3 优先级补全 7 处关键日志（其他 4 处经评估为「已通过 `_logAction` 间接覆盖」或「设计性分层不应改动」）：

| 位置 | 级别 | 内容 | 优先级 |
|------|------|------|--------|
| `_gcOrphanBlobs` 入口 | info | 扫描结果（remote/referenced/orphans） | P0 |
| `_gcOrphanBlobs` 隔离 | debug | 本轮隔离 N 个孤儿（候选表剩 M） | P0 |
| `_gcOrphanBlobs` purge | info | 隔离区结算（before/purged/remaining） | P0 |
| `_gcOrphanBlobs` 三处异常 | warn | 单 blob 软删除失败 / purgeOrphans 失败 / 整体 GC 失败 | P0 |
| `_updateLocalState` 结尾 | debug | version/local/converged/skipped/excluded/purged | P0 |
| `_executeMigration` 入口/出口/失败 | info / error | 开始 / 完成笔记数+新纪元 / 失败 | P1 |
| `_executeMigrationVault` 入口/出口/失败 | info / error | scenario-d 开始 / 完成笔记数+新 vaultId / 失败 | P1 |
| `SyncService.initialize` 完成 | info | status=idle, backendReady=true | P1 |
| `SyncService.updateKeyring` 完成 | info | keyVersion 切换 + SyncEngine 重建状态 | P1 |
| `SyncService.switchBackend` 拒绝 | warn | 同步进行中，抛 StateError | P1 |
| `SyncService.switchBackend` 完成 | info | providerKey + SyncEngine 重建状态 | P1 |

**保持现状的项**：
- `keyring.dart` 全部使用 `Log.crypto.*`（34 处）——设计性分层，密钥层不污染 sync 日志流。
- `_uploadNote` / `_downloadNote` 成功路径——已通过 `_addAction → _logAction` 间接输出 `↑ upload` / `↓ download` 日志，重复补充会造成噪音。
- `_preserveConflictCopy` 成功路径——同上，已通过 upload action 间接覆盖。

### 10.2 测试覆盖与回归验证

| 测试套件 | 用例数 | 结果 |
|----------|--------|------|
| `test/sync/sync_engine_test.dart` | 24 | ✓ passed |
| `test/sync/multi_device_test.dart` + `p0p1_self_heal_test.dart` + sync_engine | 47 | ✓ passed |
| `test/sync/webdav_integration_test.dart` | 38 | ✓ passed |
| `test/sync/chaos_multi_client_test.dart` + `keyring_test.dart` + 其他 | 139 | ✓ passed |
| `test/encryption/*` | 全部 | ✓ passed |
| **合计** | **248 passed / 2 skipped / 0 failed** | ✓ |
| `flutter analyze lib/sync lib/models lib/data` | — | ✓ No issues found |

**P0-B 引发的测试适配**（commit `8a22af3`）：`webdav_integration_test.dart` 中「Layer 2b 持有明文时下载失败自愈重传」用例在 P0-B 提交后即失败（非 P3 引入）。P0-B 修复后该场景走 fast-forward 单边本地变更，不再进入 `_handleDownloadFailure`，因此不产生 heal 动作。测试断言更新为期望 `upload` 动作、不期望 `heal` 动作，注释说明 P0-B 前后路径差异。两条路径最终结果一致（远端被本地内容覆盖、损坏 blob 被新 blob 替代）。

### 10.3 影响面分析（同步逻辑改动风险评估）

用户特别要求评估「P3 修改会不会影响别的同步或数据逻辑导致新 bug」。逐项核查：

| 修改项 | 改动性质 | 对同步控制流影响 | 对数据正确性影响 | 风险评估 |
|--------|----------|------------------|------------------|----------|
| **P3-a** `_withBlobRetry` | 行为增强（重试包裹） | 单 blob 临时网络抖动不再立即失败，重试 2 次后才放弃；上层 catch 行为不变 | putBlob 幂等覆盖写安全；getBlob null 不重试；其他异常直接抛出 | ✓ 低风险，仅网络抖动场景行为改进 |
| **P3-b** autoSync race 修复 | 行为修复（避免覆盖） | sync 完成后的 re-schedule 不再覆盖用户 debounce timer | sync 本身幂等（基于 manifest version + ETag），多次执行不丢数据 | ✓ 低风险，修复潜在 race |
| **P3-b** autoSync 失败重试 | 行为增强（自动重试） | sync 失败后自动重试 1 次（限最多 1 次避免死循环） | sync 幂等，重试不丢数据；重试失败后等用户下次触发 | ✓ 低风险，限制次数避免死循环 |
| **P3-c** journal 事件扩展 | 纯日志（新增枚举） | 不改变任何控制流 | 不影响 | ✓ 零风险 |
| **P3-log** 关键日志补全 | 纯日志（新增 Log.sync 调用） | 不改变任何控制流 | 不影响 | ✓ 零风险 |

**关键不变量核查**：

1. **`_withBlobRetry` 异常语义保持**：仅捕获 `BackendUnavailableException` 重试，其他异常（如 `FormatException`、`ConflictException`）直接抛出，与原 `backend.putBlob` / `getBlob` 调用点的 catch 分支语义完全一致。上层 `_uploadNote` 的 `catch (BackendUnavailableException)` / `catch (Object)` 分支无需调整。

2. **`_withBlobRetry` 在 `_repairRemoteOnce` 中的冒泡**：`repairRemote` 没有 catch `BackendUnavailableException`，重试耗尽后异常冒泡到 `SyncService.repairRemote` 的 `catch (Exception)` 分支，与原行为一致。

3. **autoSync 失败重试不会死循环**：`_autoSyncFailureRetried` 标志位保证单次失败只重试一次。重试 timer 触发时立即清零标志位，允许「下次用户编辑触发的 autoSync 失败」再获得一次重试机会，但单次失败不会无限重试。

4. **autoSync race 修复不丢数据**：检查 `_autoSyncTimer?.isActive` 后让用户的 debounce timer 接管，用户最新编辑会在 debounce 窗口结束后被同步。即使用户编辑后立即关闭应用，下次启动时 sync 仍会读取 DB 最新状态同步。

5. **P3-c journal 落地不改变 phase 语义**：三条 PUT manifest 路径都用 `phase: JournalPhase.done`，与现有 `syncManifestRebuild` 的 phase 语义一致。`note` 字段区分路径（`rebuild-after-corrupt` / `repair` / 空=正常），不参与机器判定。

6. **P3-log 不引入新的副作用**：所有新增 `Log.sync.*` 调用都在 try/catch 之外或独立语句，不改变异常处理路径。`_gcOrphanBlobs` 三处 `on Exception` 由静默吞掉改为 `Log.sync.w` 记录，仍不阻断同步——只是把「GC 失败」从黑盒变成可观测。

**多设备既有测试全部通过**（multi_device 23 + p0p1_self_heal 24 + chaos_multi_client 18 + webdav_integration 38），印证 P3 修改不破坏多设备并发、改密码迁移、墓碑 GC、blob 自愈、孤儿 blob 两阶段 GC 等既有逻辑。

### 10.4 提交记录

| Commit | 类型 | 内容 |
|--------|------|------|
| `e4147ad` | feat(sync) | P3-c journal 新增 manifest PUT 与乐观锁重试事件类型 |
| `e9e6a79` | feat(sync) | P3-a/P3-c/P3-log 同步引擎重试退避 + journal 落地 + 关键日志 |
| `5b52525` | feat(sync) | P3-b/P3-log autoSync 互斥增强 + 生命周期关键日志 |
| `8a22af3` | test(sync) | 适配 P0-B 后 Layer 2b 自愈场景走 fast-forward 的新行为 |

4 个 commit 按主题分离，P3-a/P3-b/P3-c/P3-log 可独立回滚（P3-c 的 journal.dart enum 扩展是 P3-c sync_engine.dart 调用的前置依赖，回滚 P3-c 需同时回滚两个 commit）。

### 10.5 后续建议

- **P2 `SyncBackend.headBlob` 上传前探测**：仍未实施，需改接口 + 所有实现，建议单独立项。
- **P3-log 缺失点 5（墓碑"应用 vs 空标记"区分日志）** 与 **缺失点 6（`_handleDownloadFailure` 决策入口日志）**：本次未补，可作为后续可观测性迭代。需注意 P0-B 后部分原 `_handleDownloadFailure` 触发场景已走 fast-forward，区分日志的必要性下降。
