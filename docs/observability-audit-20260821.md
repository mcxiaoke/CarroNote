# 同步系统可观测性与测试覆盖度审计报告

> 日期：2026-08-21
> 触发原因：`conflict-stale-syncedhash-20260821.md` 调查中发现日志/journal 关键信息缺失，导致根因定位耗时数小时而非数分钟
> 审计范围：journal 系统、sync_engine 日志、database_handler 日志、editor_state 日志、测试覆盖

## 一、总览

| 维度 | 审计结果 |
|------|---------|
| Journal 记录点 | 21 个已有 / **15 个缺失**（P0×3, P1×4, P2×4, P3×4） |
| Sync engine 日志 | 68 个调用点 / **最大盲区：`_mergeAndTransfer` 274 行零日志** |
| Database handler 日志 | 58 个调用点 / **10 个公共方法完全无日志** |
| Editor state 日志 | 7 个调用点 / updateNote 缺失 fresh vs original 对比 |
| 测试覆盖 | 311+65 个测试 / **7 个关键场景缺失** |
| 发现的 bug | 2 个（重复日志 L2618/L2619、冗余日志 L298/L307） |

## 二、Journal 系统缺失

### 2.1 架构概述

Journal（`packages/core/lib/src/sync/journal.dart`，1039 行）是同步系统的审计日志，采用内存缓冲 + 批量 flush，明文 JSON 存储在本地 + 加密上传远端。当前 12 种事件类型中 2 种已定义但从未使用（`blob.reupload`、`key.adoptEpoch`）。

### 2.2 P0 缺失（安全 + 数据完整性）

| # | 操作 | 位置 | 当前状态 | 建议 |
|---|------|------|---------|------|
| J1 | **冲突判定三元组** | `sync_engine.dart:1603-1668` | `note.conflict` 有记录但 hash 字段为空，base/local/remote 只在 message 字符串中不可机器解析 | 在 `note.conflict` 补全 hash 字段（胜方 hash），note 中增加 `baseHash`/`localHash`/`remoteHash` |
| J2 | **scenario-b（他端改密码）** | `sync_engine.dart:679-689` | 只有 Log.sync.w，无 journal 记录 | 新增 `key.changePasswordDetected` 类型 |
| J3 | **blob hash 校验失败** | `sync_engine.dart:2162-2175` | 记为 `SyncActionType.skip`，skip 在 `_journalAction` 中被显式跳过 → journal 不可见 | 改为 `note.heal/phase=failed` 或新增 `note.corrupt` 类型 |

### 2.3 P1 缺失（审计可追溯性）

| # | 操作 | 位置 | 当前状态 | 建议 |
|---|------|------|---------|------|
| J4 | **同步开始/结束边界** | `sync_engine.dart:237/263` | 有 Log.sync.i 但无 journal | 新增 `sync.start`/`sync.end`（含 attempt/uploaded/downloaded/conflicts 统计） |
| J5 | **markSynced（syncedHash 刷新）** | `sync_engine.dart:2434` | 有 Log.sync.d（release 不可见）但无 journal | 新增 `note.synced` 类型记录 uuid + syncedHash |
| J6 | **墓碑 GC（过期硬删除）** | `sync_engine.dart:1367` | 完全静默，blob GC 有两阶段 journal 但墓碑 GC 无 | 新增 `note.tombstoneGc` 或 `note.delete/phase=purged` |
| J7 | **UI 层操作（编辑/删除/恢复）** | `editor_state.dart:109/149`、`deleted_notes.dart:126` | UI 层不持有 journal 引用，操作无 journal 痕迹 | 在 SyncService 层包装，DB 写入后补 journal（类似 `key.changePassword` 处理方式） |

### 2.4 P2-P3 缺失（诊断增强 + 完整性）

| # | 操作 | 位置 | 当前状态 |
|---|------|------|---------|
| J8 | GET manifest 结果（含 version） | `sync_engine.dart:513` | 有 Log.sync.d 但无 journal，不打印 version |
| J9 | repair 开始/结束边界 | `sync_engine.dart:918/1181` | repair 的 PUT 有 journal，但 repair 操作本身无边界 |
| J10 | blobReupload 事件 | `sync_engine.dart:1523` | 已定义 `blob.reupload` 类型从未使用，走普通 `note.upsert` |
| J11 | 冲突副本创建标记 | `sync_engine.dart:1739` | 副本上传记为 `note.upsert`，无法区分冲突副本 vs 正常上传 |
| J12 | schema 版本拒绝 | `sync_engine.dart:559` | 无 journal，直接返回 failure |
| J13 | GC 候选首次观察 | `sync_engine.dart:2534` | 隔离和清除有 journal，首次观察无 |
| J14 | 迁移重试计数 | `sync_engine.dart:293-314` | 有 Log.sync.i 但无 journal |
| J15 | 冲突副本创建失败 | `sync_engine.dart:1865` | 只有 Log.sync.w，无 journal |

## 三、Sync Engine 日志缺失

### 3.1 最大盲区：`_mergeAndTransfer`（L1420-1694，274 行零日志）

这是同步引擎最核心的合并决策逻辑，包含 `_itemsEqual` 快速路径、base/local/remote 三元组计算、fast-forward 分支选择、真冲突 + LWW + `shouldPreserveCopy` 判定——**完全没有日志**。

**建议增加的关键日志点**：

```
L1561-1574 三元组计算处：
  Log.sync.d('merge: uuid=$uuid base=${base?.substring(0,12) ?? "null"} '
      'local=${localItem.hash.substring(0,12)} remote=${remoteItem.hash.substring(0,12)} '
      'localChanged=$localChanged remoteChanged=$remoteChanged');

L1603-1606 真冲突入口处：
  Log.sync.w('⚡ conflict uuid=$uuid '
      'base=${base?.substring(0,12) ?? "null"} '
      'local=${localItem.hash.substring(0,12)} remote=${remoteItem.hash.substring(0,12)} '
      'localChanged=$localChanged remoteChanged=$remoteChanged '
      '→ ${winner == localItem ? "local won" : "remote won"}');

L1613-1618 shouldPreserveCopy 判定处：
  Log.sync.d('conflict copy: uuid=$uuid shouldPreserve=$shouldPreserveCopy '
      'localDeleted=$localItem.deleted remoteDeleted=$remoteItem.deleted '
      'hashSame=${localItem.hash == remoteItem.hash}');
```

### 3.2 确认的 4 项用户指出的缺失

| 缺失项 | 确认位置 | 现状 |
|--------|---------|------|
| 冲突不打印 base/local/remote 三元组 | L1561-1574 | **完全无日志**，且 conflict action 创建时未传 hash，`_logAction` 输出的冲突日志连单个 hash 都没有 |
| markSynced 不打印 syncedHash 刷新值 | L2453 / DB L1882 | **完全无日志**，DB 层只打印行数，tag 是 DB 非 SYNC |
| GET manifest 不打印远端 version | L515/L531 | L515 只打印 empty/etag/attempt，header 解析后拿到 version 但从不输出 |
| updateNote 不追踪 syncedHash 变更 | L2443-2453 | **完全无日志**，converged 判定过程不可观测 |

### 3.3 发现的 bug

| 问题 | 位置 | 说明 |
|------|------|------|
| **重复日志** | L2618 + L2619 | `_gcOrphanBlobs` 外层 catch 中两行完全相同的 `Log.sync.w`，同一异常记录两次 |
| **冗余日志** | L298 + L307 | `sync()` 中 `_MigrationRequiredException` 分支两条几乎相同的 `Log.sync.i` |

### 3.4 release 可见性风险

以下关键路径仅用 `d` 级（release 不输出），生产环境用户遇到问题时将是盲区：

- GET manifest 结果（L515）
- `_updateLocalState` 收敛统计（L2472）
- GC 隔离决策（L2558）
- `repairRemote` 解密异常（L1083）

### 3.5 其他关键缺失

- `_hasEffectiveChange` 返回值（L803）：决定是否 PUT manifest，完全无日志
- `_preserveConflictCopy` 函数入口和各步骤（L1747-1871）：只有失败有日志，成功路径无日志
- `repairRemote` 入口/出口（L918/1181）：无边界日志
- 密钥迁移不打印旧 epoch/vaultId（L1205/L1255/L1279/L1338）：只有新值无旧值对比
- `_downloadNote` hash 校验失败（L2162-2175）：只记为 skip，无 WARN 日志
- `conflict` action 创建时未传 hash 字段（L1659-1667）：导致 `_logAction` 输出 `⚡ conflict uuid=xxx` 无任何 hash

## 四、Database Handler 日志缺失

### 4.1 P0 缺失（直接影响同步冲突诊断）

| # | 方法 | 行号 | 缺失项 | 影响 |
|---|------|------|--------|------|
| D1 | `updateNote` (UI 路径) | L1053 | 不打印 syncedHash/syncedDeleted/base 值 | 无法排查"虚假冲突副本"根因 |
| D2 | `markSynced` (单条) | L1803 | **完全无日志** | 单条同步收敛无任何留痕 |
| D3 | `markSyncedForUuids` | L1868 | 不打印每条 syncedHash 刷新值 | 无法验证收敛后 base 是否正确 |
| D4 | `softDelete` | L1285 | 只打印 id，缺 uuid/contentHash/synced_deleted 变更 | 删除的同步状态变更无法追踪 |
| D5 | `restoreNote` | L1518 | 同 D4 | 恢复的同步状态变更无法追踪 |

### 4.2 P1 缺失（缓存一致性与自愈诊断）

| # | 方法 | 行号 | 缺失项 | 影响 |
|---|------|------|--------|------|
| D6 | `_applySyncedToCache` | L367 | 无缓存-DB 不一致检测 | 缓存漂移无法发现 |
| D7 | `readNoteByUuid` | L917 | **完全无日志** | editor 读取 fresh base 的关键路径无留痕 |
| D8 | `readNoteByContentHash` | L939 | **完全无日志** | 同步自愈（孪生笔记查找）无诊断 |
| D9 | `existsContentHash` | L960 | **完全无日志** | 冲突副本去重探测无诊断 |
| D10 | `saveVersion` | L1119 | 无 try-catch / 无错误日志 | 版本保存失败静默中断 |

### 4.3 完全无日志的公共方法清单

`markSynced`、`readNoteByUuid`、`readNoteByContentHash`、`existsContentHash`、`getMeta`、`setMeta`、`readNote`、`readVersion`、`close`、`clearAllPendingReupload`

### 4.4 无 try-catch 的关键方法

`saveVersion`、`hardDeleteByUuid`、`_onUpgrade`、`editor_state.updateNote`、`editor_state.addOrUpdateNote`

## 五、Editor State 日志缺失

### `updateNote()`（L125-150，UI 编辑保存的核心路径）

当前只有入口日志 `保存编辑后的笔记: uuid=... len=...`，关键诊断信息全部缺失：

| 缺失项 | 建议级别 | 说明 |
|--------|---------|------|
| fresh syncedHash 读取结果 | `note.i` | 验证修复是否生效的核心证据 |
| syncedHash 过期检测 | `note.w` | 若 `original.syncedHash != fresh.syncedHash`，说明编辑期间同步更新了 base |
| contentHash 变更 | `note.i` | 旧 hash → 新 hash |
| 保存完成 | `note.i` | 当前无完成日志 |
| 异常处理 | `note.e` | 整个方法无 try-catch |

## 六、测试覆盖缺失

### 6.1 现有测试概览

| 层 | 测试文件数 | 测试数量 |
|----|-----------|---------|
| packages/core/test/ | 22 | ~311 |
| test/ | 19 | ~14 + ~51 widget |
| **合计** | 41 | ~376 |

### 6.2 缺失测试清单（按优先级）

#### T1（最高优先级）：编辑期间同步完成后保存编辑 — syncedHash 回退修复

- **场景**：`original` 持有旧 syncedHash → 同步引擎更新 DB → 保存时是否回退
- **位置**：`lib/models/editor_state.dart:125-150`
- **当前覆盖**：**无**。sync_engine_test 的 P1-A 组测试了引擎侧，但 editor_state 完全没有测试
- **建议用例**：
  1. 同步后 syncedHash=V1 → 模拟编辑器打开 → markSynced 更新为 V2 → updateNote → 验证 DB 中 syncedHash=V2 而非 V1
  2. 同步未更新 syncedHash → updateNote → 验证行为不变
  3. 编辑期间 syncedDeleted 变化 → 验证 syncedDeleted 也被正确刷新

#### T2（高优先级）：缓存一致性 — `_applySyncedToCache` 替换对象后旧引用失效

- **场景**：外部持有旧对象引用，`_applySyncedToCache` 用 `copyWith` 创建新对象替换缓存
- **位置**：`database_handler.dart:367-383`
- **当前覆盖**：**无**
- **建议用例**：
  1. 存入笔记 → 获取外部引用 → markSyncedForUuids → readAllNotes 获取新引用 → 验证新引用 synced=true，旧引用 synced=false
  2. 存入笔记 → 获取引用 → updateNoteByUuid → 验证缓存已替换

#### T3（高优先级）：`updateNote` vs `updateNoteByUuid` 对 syncedHash 的不同处理

- **场景**：UI 路径（按 id）不修改 synced_hash 列；同步路径（按 uuid）会写入
- **位置**：`database_handler.dart:1053` vs `1081`
- **当前覆盖**：**无**。测试分别使用了两个方法但没有断言行为差异
- **建议用例**：
  1. updateNote 修改内容 → 验证 synced_hash 不变、synced 变为 0
  2. updateNoteByUuid 修改内容并设 synced_hash → 验证 synced_hash 已更新

#### T4（高优先级）：`existsContentHash` 含墓碑 — 冲突副本标题去重

- **场景**：已删除笔记的 content_hash 仍占位，冲突副本标题生成时跳过碰撞
- **位置**：`database_handler.dart:960`、`sync_engine.dart:1888`
- **当前覆盖**：**无**。existsContentHash 在所有测试文件中均未被引用
- **建议用例**：
  1. 存入笔记 → 硬删除 → existsContentHash → 应返回 true（墓碑占位）
  2. 模拟冲突场景验证副本标题包含设备标识且 hash 不碰撞
  3. 验证 99 个序号全碰撞的兜底路径

#### T5（中优先级）：`markSyncedForUuids` 数据库层直接单元测试

- **场景**：P1-A 白名单的核心方法，当前只通过引擎间接测试
- **位置**：`database_handler.dart:1868`
- **当前覆盖**：**部分**（引擎间接测试，无直接单元测试）
- **建议用例**：空集合、不存在的 uuid、部分匹配、幂等性

#### T6（中优先级）：编辑器与同步引擎端到端竞态测试

- **场景**：完整的「编辑器 → 同步 → 保存」流程
- **位置**：editor_state + sync_engine + database_handler 联合
- **当前覆盖**：**无**。P1-A 修复和 editor_state 修复的联合效果没有测试
- **建议用例**：
  1. V1 → 同步 → 编辑器打开 → 编辑为 V2 并保存 → 同步上传 V2 → 验证无冲突副本
  2. V1 → 同步 → 编辑器打开 → 编辑期间同步下载 V3 → 保存 V2 → 验证 syncedHash=V3 而非 V1

#### T7（中优先级）：冲突副本保留与墓碑交互边界

- **场景**：墓碑 vs 活跃、墓碑 vs 墓碑的冲突判定
- **位置**：`sync_engine.dart:_preserveConflictCopy`
- **当前覆盖**：**部分**。BUG-P0 组测试了删除不被复活，但缺少远端墓碑+本地活跃、双方墓碑
- **建议用例**：
  1. 本地活跃 + 远端墓碑（updatedAt 更大）→ 本地标记 deleted，不产生活跃副本
  2. 双方墓碑 → 不产生副本，保留 updatedAt 更大的

## 七、实施优先级建议

### 第一批（直接解决本次 bug 暴露的诊断困难）

| 类型 | 编号 | 内容 | 预计工作量 |
|------|------|------|-----------|
| 日志 | §3.2-1 | `_mergeManifests` 冲突三元组日志（base/local/remote） | 小 |
| 日志 | §3.2-2 | `markSyncedForUuids` 打印 syncedHash 刷新值 | 小 |
| 日志 | §3.2-3 | GET manifest 打印远端 version | 小 |
| 日志 | §4.1-D1 | `updateNote` (DB) 打印 syncedHash 变更 | 小 |
| 日志 | §5 | `editor_state.updateNote` 打印 fresh vs original 对比 | 小 |
| 日志 | §3.3 | 修复重复日志 bug (L2618/L2619) | 极小 |
| 测试 | T1 | editor_state syncedHash 刷新测试 | 中 |

### 第二批（补齐审计盲区）

| 类型 | 编号 | 内容 | 预计工作量 |
|------|------|------|-----------|
| Journal | J1 | 冲突三元组结构化进 journal | 中 |
| Journal | J4-J5 | sync.start/end + markSynced 进 journal | 中 |
| Journal | J3 | blob hash 校验失败不再用 skip | 小 |
| 日志 | §3.1 | `_mergeAndTransfer` 全流程 DEBUG 日志 | 中 |
| 日志 | §3.4 | 关键路径 d→i 级别提升 | 小 |
| 测试 | T2-T4 | 缓存一致性 + updateNote 差异 + existsContentHash | 中 |

### 第三批（完整性）

| 类型 | 编号 | 内容 | 预计工作量 |
|------|------|------|-----------|
| Journal | J2/J6/J7 | scenario-b + 墓碑GC + UI操作进 journal | 大 |
| Journal | J8-J15 | 其余诊断增强 | 中 |
| 日志 | §4.2 | DB 层 P1 缺失（缓存检测/自愈诊断） | 中 |
| 测试 | T5-T7 | DB 直接单元测试 + 端到端竞态 + 墓碑边界 | 大 |

## 八、附：本次 bug 调查中如果日志完善的定位路径对比

### 实际定位路径（当前日志）

```
1. 发现冲突副本 → 解密 manifest/blob 确认内容
2. 查 Android journal → 发现冲突在 Android 端产生
3. 查 Android 日志 → 还原 16:59:22-16:59:45 时间线
4. 查 release journal + Windows journal → 排除其他客户端（三端交叉比对）
5. 读 sync_engine 冲突检测代码 → 理解 base/local/remote 三元组逻辑
6. 读 markSyncedForUuids 代码 → 理解 syncedHash 更新机制
7. 读 _updateLocalState 白名单逻辑 → 确认 16:59:25 同步后 syncedHash 应已更新
8. 读 editor_state.updateNote → 发现 copyWith 保留旧 syncedHash
9. 读 _applySyncedToCache → 确认缓存替换不更新外部引用
10. 用 note_versions 表验证时间线
→ 总计：~3 小时，需读 4 个文件 ~6000 行代码
```

### 如果日志完善的定位路径

```
1. 查冲突日志 → 看到 base=2c3a3e99 local=dd22f090 remote=805d1ced
   → remote 是 Android 自己 16:59:25 上传的 → 立即知道 base 被错误回退
2. 查 markSynced 日志 → 看到 16:59:25 syncedHash 已正确刷新为 805d1ced
3. 查 updateNote 日志 → 看到 16:59:42 syncedHash 从 805d1ced 回退为 2c3a3e99
   → stale_base_detected=true
→ 总计：~5 分钟，只需查日志无需读代码
```
