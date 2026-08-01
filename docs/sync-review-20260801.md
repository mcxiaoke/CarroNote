# 同步子系统全局审查（可靠性 × 复杂度）

日期：2026-08-01
方法：3 路并行逐行对抗性审查（sync_engine / 状态恢复层 / 持久化传输层），人工汇合去重
背景：epoch 消除设计（v4）落地前的全局体检。主设计文档：`docs/epoch-elimination-design-20260801.md`（v4.0）
范围：`lib/sync/*`（engine / service / keyring / journal / config / crypto / backends）+ `lib/data/database_handler.dart` + `server/`（Go / Node.js）

---

## 一、总体结论

同步子系统存在两类根问题：

1. **可靠性**：多处状态副本 + 非原子窗口 + 自动改写路径，累积出「崩溃即全库不可解」「永久删除复活」「同步无限挂起」等 P0 级隐患。
2. **复杂度**：补丁累积（git 历史：`bad blob` → `self-heal` → `epoch 自愈`，每个 bug 打一个补丁、补丁引入新状态新分支）+ 无生产调用方的半成品设施（「第二数据源」链路约 200 行）。

**处理口径**：
- P0 五项已纳入 v4 同期实施（见 §二，主文档 §10 步骤 8）。
- 其余列本文档 backlog（§三/四/五）。

---

## 二、已纳入 v4 的 P0 五项（主文档 §10.8）

| # | 位置 | 问题 | 建议 | 成本 |
|---|---|---|---|---|
| **B1** | `keyring.dart:580-603/653-678` | 迁移的 `reEncryptAllNotes`（全库新 key 重加密、单事务提交）与账本 `persist` **不在同一事务**。崩溃在两者之间 → DB 全新 key 密文 + keyring 旧 encryptedDataKey → `unlockLocal` 成功但所有笔记 GCM 失败 → **全库内容不可解** | 账本与笔记同一 SQLite 事务；或 write-ahead（先持久化新账本 + `pending_migration` 标记，unlock 检测后恢复） | 中 |
| **B2** | `sync_engine.dart:907/965` + `sync_service.dart:609` | 迁移后只替换 `SyncEngine.keyring`（新实例），`SyncService._keyring` 仍是旧实例（旧 dataKey/vaultId）。此时改密码 → 用旧 dataKey 重 wrap 覆盖账本 → **回滚成旧金库，全库不可解** | 迁移成功后把新 keyring 回写 `SyncService`（回调 / `updateKeyring`） | 中 |
| **B3** | `safe_server_backend.dart:125-269`、`webdav_backend.dart:228-354` | 所有 HTTP 调用**无超时**。服务端接连接不响应 → 同步无限挂起，`_syncInProgress` 恒 true 锁死互斥，UI 永远「同步中」 | 统一 `.timeout(15-30s)`，超时映射 `BackendUnavailableException`（可重试语义） | 低 |
| **B4** | `database_handler.dart:553-584, 591-603` | `hardDelete`/`hardDeleteByUuid` 的「删行 + 写 purgedUuid」**不在同一事务**。删行后、写 purged 前崩溃 → 远端 manifest 仍引用该 uuid → **永久删除的笔记复活**（隐私事故） | 「读 uuid → delete → 追加 purgedUuid」包进 `db.transaction` | 低 |
| **B5** | `local_fs_backend.dart:151-156` | `putBlob` 直接 `writeAsBytes`，崩溃/磁盘满留**截断半写文件**；LocalFS 常指向云同步文件夹，半写 blob 会被上传成脏数据。与同文件 `putManifest`（tmp+rename）不一致 | 改 `写 .tmp → fsync → rename`；`listBlobs` 已过滤 `.tmp` 无需改 | 低 |

---

## 三、P1 高价值 backlog（建议近期做）

| 位置 | 问题 | 建议 | 成本 |
|---|---|---|---|
| `sync_service.dart:584-586` | `switchBackend` 失败路径：`_backend?.close()` 后 `backend.init()` 抛异常 → `_backendReady` 仍是旧 true、`_engine` 引用已关闭旧后端 → 每次 sync 直接失败且**永不重试新后端**，只能杀进程 | init 成功前不动 `_backend`/`_backendReady`；失败恢复旧引用或置 false | 低 |
| `journal.dart:463-464, 482-488, 704-719` | journal 目录**非 per-vault**（所有金库共用）。换金库后归档不隔离、`nextSeq` 从旧库续号、`readAll()` 读旧库归档 → 审计/「第二数据源」**串库** | 目录按 vault 隔离（`<base>/journal/<vaultId>/`），或 open 时隔离旧 vault 归档 | 低-中 |
| `sync_engine.dart:2045-2064` + `database_handler.dart:799-812` | `markAllSyncedExcept` 只排除 `uploadFailed`，**下载失败**的本地旧内容也被标记 synced、`syncedHash` 写本地旧 hash → 污染三方合并 base → 后续编辑生成**虚假冲突副本** | 排除集合并入 `_failedUuids(actions)`（corrupt 也算未收敛）；或下载失败时本地 synced 置 0 | 低 |
| `sync_service.dart:443-470, 521-540` | `sync()`/`repairRemote()` 用 `on Exception` 兜底，`Error`（类型转换/RangeError）穿出 → `_state.status` 卡 `syncing`，UI 永久同步中 | 兜底统一 `on Object`，失败路径补 `_updateState(error)` | 低 |
| `sync_engine.dart:1027` | 墓碑 GC 的 `hardDeleteByUuid` 及用户硬删（M1 purgedUuids）**不在 journal 内**——最高危操作反而无记录，审计链断 | 墓碑 GC/硬删记 `noteDelete` 类事件 | 低 |
| `sync_service.dart:177-222` | `initialize` **非幂等、无并发守卫**：重复触发开出第二个 Journal/Engine 实例写同一 `log.json` → 交错写、条目丢失 | 加 `_initialized` 守卫，或 init 前 `_closeJournal()` | 低 |
| `sync_engine.dart:2095-2173` + `webdav:467`/`local_fs:209`/`safe_server:399` | 两阶段 GC 的「连续两次观察」窗口被自动同步节奏压缩；且 `deleteBlobSoft` 在 MOVE/COPY 失败时**退化为硬删** → 他端刚上传未提交 manifest 的 blob 可能被误删，30 天保留失效 | 首次观察时间纳入隔离判定；隔离失败时**跳过而非硬删**（宁留孤儿不丢数据） | 中 |
| `journal.dart:878-965` + `sync_engine.dart:2204-2271` | 「第二数据源」链路（`syncToRemote`/`fetchRemoteEntries`/`replayKeyState`/`.journal-state` 水位）**零生产调用方**；`blobReupload` 事件在 `_journalAction` 无映射；`updateEncryptedDataKey` 改写后不记 journal | v4 删 heal/adopt 时**删掉或接一个真实恢复流程**，二选一，不要停在半成品 | 低 |
| `database_handler.dart:606-628, 869-879` | meta 表三处 read-modify-write（purged/重传标记）**非事务**且**解析失败静默清空** → 并发丢失或损坏后「硬删复活」「旧 blob 永久残留」 | RMW 事务化；解析失败记 FATAL + 保留原值，而非返回空 | 低 |
| `webdav_backend.dart:194-220` | ETag 探测硬编码 `<D:getetag>` 匹配，真实 WebDAV 常用 `d:getetag`/`ns0:getetag` → 误判不支持 → **静默退化**为内容 hash 比较 + 多端覆盖无提示 | 正则匹配 `getetag` 关键字（不引入 XML 库） | 低 |
| `sync_engine.dart:574-584, 2045-2064` | PUT manifest 成功与本地 `_updateLocalState` 之间**无事务屏障**，崩溃后本地旧内容可能覆盖刚合并的结果 | 两阶段意图记录（PUT 前落预期 version/etag 标记），或文档化该边界 | 中 |
| `webdav_backend.dart:310-354` | getBlob/putBlob 的 401 只报「后端不可用」，密码过期/令牌失效排障困难（SafeServer 有专门 401 分支） | 对齐 SafeServer，401 抛带「检查账号密码」语义的异常 | 低 |

---

## 四、P2/P3 完整清单（backlog）

| 位置 | 问题 | 成本 |
|---|---|---|
| `sync_engine.dart:537-566` | skip-PUT 路径不调用 `_uploadJournal` → journal 远端副本滞后（「第二数据源」失实时） | 低 |
| `sync_engine.dart:843-865` | `repairRemote` 无任何修复也强制 PUT（version+1/updatedAt=now）→ version 空涨 + ETag 竞争 | 低 |
| `sync_engine.dart:170-223` | 迁移与乐观锁冲突共享 attempt 预算（迁移吃掉 3 次重试预算）；`allActions` 只写不读，migrate action 不进返回结果，UI 看不到 | 低 |
| `sync_engine.dart:221-223` | `sync()` 结尾 dead code（循环内各分支都 return，末尾不可达） | 低 |
| `sync_engine.dart:558-560, 604-609` | `skipped` 统计把 conflict 混入（同时计 conflicts + skipped），UI「跳过」数字虚高 | 低 |
| `sync_engine.dart:2299-2301` | `_logAction` skip case 冗余 `break`（Dart 3 已隐式 break；风格易误读为 C 直落） | 低 |
| `keyring.dart:784-791` | `adoptRemoteEpoch` 先改内存再 persist，persist 失败 → 内存新纪元 + DB 旧纪元半态（v4 删 adopt 后自然消解） | 低 |
| `sync_service.dart:383-435, 550-563` | `sync()` 返回 null 语义二义（未初始化 vs 互斥跳过），autoSync 可能漏最后一次变更 | 低 |
| `sync_service.dart:82-93, 130-138` | `SyncServiceState` 纯内存 + `copyWith` 用 `?? this` 无法清空 `lastResult`/`errorMessage`；`status`/`_syncInProgress`/`_backendReady` 三状态源可 drift | 低 |
| `sync_config.dart:75-78` | `backendType` 用 `SyncBackendType.values[index]`，prefs 残留非法 int → RangeError 崩溃 | 低 |
| `sync_service.dart:320-333` | dispose 不等 in-flight sync，关闭 controller 后 `_updateState` 抛 StateError | 低 |
| `journal.dart:631-642` | 每次 flush 序列化整个 `_entries`（≤1000 条）全量重写 log.json，同步密集时每 100ms 一次整文件重写 | 中 |
| `journal.dart:63, 971-994` | `kJournalSchemaVersion` 写入但读取时不校验，未来格式迁移无版本可依 | 低 |
| `sync_service.dart:477-541` | `repairRemote` 惰性初始化失败路径不更新 `_state`（与 sync 不一致），错误不上报 | 低 |
| `keyring.dart:748-755` | `updateEncryptedDataKey` 注释称「原地字段级更新」实为 `copyWith` 换新对象，与 `changePassword/migrate*` 返回新实例的约定割裂（B2 引用陷阱根源） | 低 |
| `server/nodejs/src/storage/fs.js:395-414` | Node `atomicWrite` 固定 `.tmp` 文件名，与 Go 随机后缀不一致 → 并发同目标写竞态 | 低 |
| `server/go/.../handlers.go:34-86` + `storage.go:116-130` | schemaVersion 服务端零知识不校验 → 漏网旧客户端覆盖口；blob hash 只校验无穿越、不校验 64 位 hex，`foo` 之类名字可入库 | 中（可选）/低 |
| `sync_engine.dart:176-188` | `passwordEpochMismatch` 提示依赖被删的 epochMismatch 状态机（v4 由 scenario-b errorMessage 接管，见 §六 A5） | 中 |

---

## 五、复杂度削减清单（backlog，建议 v4 实施时顺手做）

| 位置 | 冗余 | 建议 | 量级 |
|---|---|---|---|
| 三 backend（webdav/safe_server/local_fs） | `_normalizeEtag`/`_computeContentEtag`/`_backupManifestOnServer`/孤儿隔离 PROPFIND/journal 对象读写各写一遍 | 抽共享工具（ETag 规范化、XML href 正则、环形备份），三后端仅留传输差异 | -150~250 行 |
| `sync_backend.dart:121-194` + 各 backend | 孤儿隔离区 + manifest 环形备份 + journal 远端副本**三层保险**叠加（约 500+ 行） | 取舍评审：保留 manifest 代际备份；journal 远端副本降级可选；孤儿隔离简化；索引与备份文件同一次原子提交 | 中 |
| `sync_engine.dart:1366-1471` | `_preserveConflictCopy` 两分支（远端败/本地败）~90 行几乎重复 | 抽 `_createAndUploadCopy(...)`，两分支只提供源 SafeNote | 低 |
| `sync_engine.dart:652-878 vs 1671-2019` | repair 与 download 各自实现「blob 缺失→本机明文/twin 兜底→解密失败→重传」三份拷贝（v4 改动时容易漏改分叉） | 收敛为单一「blob 校验+自愈/标记损坏」函数，sync 与 repair 共用 | 中 |
| `sync_engine.dart:1318 vs 1331` | `_itemsEqual` 与 `_semanticItemsEqual` 两个相等比较并存 | 合并（v4 改指纹判据时一并收敛） | 低 |
| `sync_engine.dart:161/234、631/652` | `sync`/`repairRemote` 各带一套 `_xxxOnce(attempt)` 重试封装 | 抽公共重试助手 | 低 |

---

## 六、与 v4 方案的连带修改（已写入主文档 §10 步骤 3-5）

- **A1 [I] scenario-b 定案**：`_syncOnce` 检测「本地 MK 解不开远端包裹但 dataKey 能解 items」→ 中止 + 报「他端改了密码，请重新输入密码」，不 PUT（主文档 §8.2[I]）。
- **A2 epoch 删除连带改指纹判据**：`isOldKey`（engine:2008）、`_semanticItemsEqual`（engine:1331）、repair 判据（engine:752/764-798）、`_buildLocalManifest`（engine:1058）统一改用 `dataKeyFingerprint`。
- **A3 迁移重传显式化**：删常驻 pendingReupload 分支后，把「本地 blob 全量重传」搬进 `_executeMigration`/`_executeMigrationVault`（DB 的 `markAllForBlobReupload`/`removePendingReuploadUuids` 保留作失败重试）。
- **A4 删 `_DownloadHealed`**：连带清理 `_mergeAndTransfer`（L1154/1267）与 repair（L754）全部调用方。
- **A5 UI 提示接管**：`passwordEpochMismatch`（engine:176-188）由 scenario-b 的 errorMessage 接管。
- **A6 错误处理统一（v4.1 吸收 P4a）**：`crypto.dart` 包装 `DecryptionException`（`open` 内 `on Error`），全库 `on Object` → `on DecryptionException`（对应 §三「sync_service.dart:443-470, 521-540 on Exception 兜底」P1 项）。
- **A7 scenario 判定指纹化（v4.1 吸收 P3）**：`_syncOnce` 判定改用 `header.dataKeyFingerprint`，4 分支→2 分支，删 `keyVersion` 前置守卫 + override 三元组 + `epochMismatch` 标志（对应 §三「passwordEpochMismatch 依赖被删状态机」项）；[I] 定案保持（同一 dataKey 不同 wrap 仍中止重登录，不 echo）。

---

## 七、决策记录

- **[I] scenario-b = 选项 B（失败 + 强制重登录）**——不保留两端密码不同共存，彻底堵死 header 翻转战争。
- **v4 范围 = v4 协议 + P0 五项**（B1-B5）；P1/P2/P3/复杂度项列 backlog 后续处理。
- **主文档版本号 v3.1 → v4.0 → v4.1**（v4.1 合并吸收平行方案可吸收项）。
- **v4.1 吸收清单**：`aad-epoch-removal-design-20260801.md`（事故致命点、epoch 考古表、07-30 crash 顾虑消解、本机明文/孪生自愈保留、`_semanticItemsEqual` 排除 blobKeyEpoch）+ `sync-global-simplification-design-20260801.md`（P3 指纹判定、P4a 错误处理统一）；**不吸进 v4**：P2 G-Set 删除架构（独立未来方案）、P4b 拆文件 / P4c journal 降级 / P4d 备份简化（backlog 决策项）。
- CHANGES 暂不记录（仅文档改动）。
- 临时会话转储 `temp/session-safenotes-sync-fix-20260801.md` 已清理。

---

## 附：方法论备注

- 3 路子代理并行，互不重复领域；人工汇合时发现并修正主文档一处自相矛盾（§6.2「blobKeyEpoch 读 DB 持久化值」 vs §4.1「无需 DB 列」，已改）。
- 子代理 1 实测 `dart analyze lib/sync/sync_engine.dart` 无告警；Dart 3.12 switch 非空 case 已隐式 break，未把缺失 `break` 列为问题。
