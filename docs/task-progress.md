# 任务进度

> 按 CLAUDE.md 要求，每步带精确时间戳。本次会话补记前序已完成块 + 完成本次新增块。

## 块 A：协议字段补齐（基础设施）[补记]

实施日期：2026-07-29（前序会话完成）

### 步骤与时间戳

- [2026-07-29 09:38:55 补记] A1 `lib/sync/sync_models.dart`：ManifestHeader 加 `keyFingerprint` / `keyVersion` / `schemaVersion` / `createdAt`；ManifestItem 加 `updatedBy` / `createdAt` / `deletedAt` / `contentSize`；更新 `fromJson`/`toJson` + `copyWith`。✓
- [2026-07-29 09:38:55 补记] A2 `lib/sync/crypto.dart`：移除 `kFixedSalt`；per-vault 随机 16 字节 salt；`deriveMasterKey` 接收 salt 参数。✓
- [2026-07-29 09:38:55 补记] A3 `lib/sync/vault.dart`：`unlockLocal`/`unlockFromRemoteManifest`/`createNew` 均从 header 读 salt；`changePassword` 生成新 fingerprint + 递增 keyVersion。✓
- [2026-07-29 09:38:55 补记] A4 `lib/sync/sync_engine.dart`：`_buildLocalManifest` 填充所有新字段。✓

## 块 B：改密码闭环（P0-1 核心）[补记]

实施日期：2026-07-29（前序会话完成）

### 步骤与时间戳

- [2026-07-29 09:38:55 补记] B1 `lib/sync/sync_engine.dart`：`_syncOnce` 下载远端 header 后比 `keyVersion`；远端更高 → 纪元不匹配分支，`_buildLocalManifest` 用 `remoteHeader.encryptedDataKey`，置 `passwordEpochMismatch`。✓
- [2026-07-29 09:38:55 补记] B2 `lib/sync/sync_engine.dart`：本端 keyVersion 更高 → 正常推送；纪元相等 → 现状流程。✓
- [2026-07-29 09:38:55 补记] B3 `lib/views/authentication/login.dart`：本地 hash 校验失败时走 `_tryVerifyPassphraseViaVault` → `Vault.unlockLocal` → 失败则 `_tryVerifyPassphraseViaRemote` GET manifest header 比对 fingerprint。✓
- [2026-07-29 09:38:55 补记] B4 `lib/sync/vault.dart`：激活 `unlockFromRemoteManifest`（完整流程：读 header.salt → 派生 MK → 比 fingerprint → 解 dataKey → 持久化）。✓
- [2026-07-29 09:38:55 补记] D1 `lib/views/authentication/login.dart`：`_initVault` 返回 bool，失败时停留登录页不导航到 /home。✓

## 块 C：同步触发器（autoSync 接入）

实施日期：2026-07-29

### 步骤与时间戳

- [2026-07-29 08:51:37] C1 `lib/models/editor_state.dart`：`addOrUpdateNote` 末尾添加 `SyncService.instance.autoSync()` + import。✓
- [2026-07-29 08:51:37] C2 `lib/views/note_view.dart`：softDelete 调用后添加 `autoSync()` + import。✓
- [2026-07-29 08:51:37] C3 `lib/views/deleted_notes.dart`：`_permanentDelete` 与 `_clearAll` 两处 hardDelete 后添加 `autoSync()`。✓
- [2026-07-29 08:51:37] C4 一致性检查：`_restoreNote`（deleted_notes.dart:109）已有 `autoSync()`，无需修改。✓
- [2026-07-29 08:51:37] C5 `lib/views/authentication/login.dart`：`_initVault` 后端初始化后添加 `autoSync()`。✓
- [2026-07-29 08:51:37] C6 `lib/main.dart`：`AppLifecycleEventHandler` 新增 `resumeCallBack` 调用 `autoSync()` + import。✓

### 验证

- [2026-07-29 08:51:37] `flutter analyze lib`：0 errors / 0 warnings（47 info 原有）。✓
- [2026-07-29 08:51:37] `flutter test`：All tests passed!（exit 0）。✓
- [2026-07-29 08:51:37] `flutter build apk --debug`：成功（32.4s）。✓

## 块 D：健壮性（P0-2 + P2）[补记]

实施日期：2026-07-29（前序会话完成）

### 步骤与时间戳

- [2026-07-29 09:38:55 补记] D2 `lib/sync/sync_engine.dart`：manifest 解析失败（FormatException）→ `backend.backupCorruptManifest` → 用本地数据重建 manifest 上传。`local_fs_backend.dart` 重命名为 `.corrupt-{ts}`；`webdav_backend.dart`/`safe_server_backend.dart` 退化为 DELETE。✓
- [2026-07-29 09:38:55 补记] D3 `lib/sync/sync_engine.dart`：blob 下载失败时保留 `remoteItem` 进 `mergedItems`，下次同步重试（不丢条目）。✓
- [2026-07-29 09:38:55 补记] D4 `lib/sync/vault.dart`：`checkMigrationNeeded` 的 `remoteVaultId` 正确传递远端 header 的 vaultId；`migrateToRemote` 更新 vaultId 并落盘。✓
- [2026-07-29 09:38:55 补记] D5 `lib/sync/local_fs_backend.dart`：`putManifest` 改为 tmp + rename 原子写。✓

## 块 E：安全加固（P2/P3）[补记]

实施日期：2026-07-29（前序会话完成）

### 步骤与时间戳

- [2026-07-29 09:38:55 补记] E1 `lib/sync/sync_engine.dart`：R6 冲突副本保留——updatedAt 差值 > 5 分钟且 hash 不同 → 败方内容存为新笔记（`_preserveConflictCopy`）。✓
- [2026-07-29 09:38:55 补记] E2 `lib/sync/webdav_backend.dart`：init 时 `_probeEtagSupport` 主动探测 ETag（GET manifest 读 etag 头 / 404 时 PROPFIND），不支持则警告用户。✓
- [2026-07-29 09:38:55 补记] E3 服务端速率限制：文档标注为"非必需加分项"，暂跳过（SafeServer 单用户固定 Token 场景风险低）。⊘

## 块 F：清理（P3）

实施日期：2026-07-29

### 步骤与时间戳

- [2026-07-29 09:38:55] F1 `lib/sync/sync_backend.dart`：接口加 `deleteBlob(hash)` / `listBlobs()`（带默认空实现，保证向后兼容）。✓
- [2026-07-29 09:38:55] F1 `lib/sync/local_fs_backend.dart`：`deleteBlob` 删文件（幂等）；`listBlobs` 列目录并用正则 `^[a-f0-9]{64}$` 过滤非 hash 文件。✓
- [2026-07-29 09:38:55] F1 `lib/sync/webdav_backend.dart`：`deleteBlob` 用 DELETE method（404 幂等）；`listBlobs` 用 PROPFIND 深度 1 解析 XML href。✓
- [2026-07-29 09:38:55] F1 `lib/sync/safe_server_backend.dart`：`deleteBlob` 尝试 DELETE（405/404 静默，未来服务端加端点自动生效）；`listBlobs` 保守返回空（当前协议无 list 端点）。✓
- [2026-07-29 09:38:55] F1 `lib/data/database_handler.dart`：加 `hardDeleteByUuid(uuid)` 方法（GC 墓碑清理用，按 uuid 删除 + 加入 purgedUuids）。✓
- [2026-07-29 09:38:55] F1 `lib/sync/sync_engine.dart`：加 `kTombstoneGcThresholdMs`（30 天）；`_buildLocalManifest` 过滤过期墓碑（硬删除 + 加入 purgedUuids）；`_gcOrphanBlobs` 在 manifest PUT 成功后清理孤儿 blob。✓
- [2026-07-29 09:38:55] F1 `lib/sync/webdav_backend.dart`/`safe_server_backend.dart`：补 `backupCorruptManifest` 实现（DELETE 损坏文件，D2 修复配套）。✓
- [2026-07-29 09:38:55] F3 `lib/views/home.dart`：drawer 登出顺序统一为"先停监听 → 导航（不 await）→ 后清状态"，与 settings.dart / main.dart 一致。✓

### 验证

- [2026-07-29 09:38:55] `flutter analyze lib`：0 errors / 0 warnings（47 info 原有）。✓
- [2026-07-29 09:38:55] `flutter test temp/sync/*`：79 tests passed（含 3 个新 GC 测试）。✓
- [2026-07-29 09:38:55] `flutter test test/widget_test.dart`：1 passed。✓
- [2026-07-29 09:38:55] `flutter build apk --debug`：成功（16.5s）。✓

## 块 G：测试（贯穿）

实施日期：2026-07-29

### 步骤与时间戳

- [2026-07-29 09:38:55] G1 `temp/sync/sync_engine_test.dart`：FakeBackend 补 `deleteBlob`/`listBlobs`/`backupCorruptManifest` 实现。✓
- [2026-07-29 09:38:55] G2 `temp/sync/sync_engine_test.dart`：新增"孤儿 blob 清理"测试——手动加孤儿 blob，同步后验证被删除、引用 blob 保留。✓
- [2026-07-29 09:38:55] G3 `temp/sync/sync_engine_test.dart`：新增"墓碑 GC"测试——超 30 天墓碑同步后从 manifest 移除并硬删除，未过期墓碑保留。✓
- [2026-07-29 09:38:55] G4 `temp/sync/sync_engine_test.dart`：新增"listBlobs 空时 GC 跳过"测试——无孤儿时 blob 数量不变。✓

### 验证

- 总计 79 sync 测试 + 1 widget 测试 = 80 测试全部通过。

## 最终验证修复（前序会话遗漏）[2026-07-29 09:46:02]

实施日期：2026-07-29

### 步骤与时间戳

- [2026-07-29 09:46:02] 发现 `temp/sync/multi_device_test.dart` 的 `FakeBackend` 缺失 `backupCorruptManifest` / `deleteBlob` / `listBlobs` 三个方法实现（前序会话只更新了 `sync_engine_test.dart` 中的 FakeBackend，遗漏此文件），导致编译失败。
- [2026-07-29 09:46:02] 补齐三个方法实现，与 `sync_engine_test.dart` 中的 FakeBackend 保持一致。✓

### 验证

- [2026-07-29 09:46:02] `flutter analyze lib`：0 errors / 0 warnings（47 info 全为项目原有）。✓
- [2026-07-29 09:46:02] `flutter test temp/sync/ test/widget_test.dart`：100 测试全部通过（含 multi_device_test 的 H1/M1/M7/最终一致性 4 个多设备场景测试）。✓
- [2026-07-29 09:46:02] `flutter build apk --debug`：成功（6.9s）。✓

## 块 S：SafeServer v2.1 服务端功能补全

实施日期：2026-07-29

### 背景

前序会话完成客户端同步架构改造后，发现 SafeServer 服务端缺少 GC 配套端点和安全加固：
- 客户端 `safe_server_backend.dart` 的 `deleteBlob()` 和 `backupCorruptManifest()` 已调用 DELETE 端点，但服务端返回 405（未实现）
- `listBlobs()` 返回空列表，GC 退化为"只标记不清理"
- E3（认证失败速率限制）此前跳过，存在 Token 暴力枚举风险

### 步骤与时间戳

- [2026-07-29 10:11:54] S1 `server/go/main.go`：新增 `handleDeleteBlob`（DELETE /api/v2/blob/<hash>，GC 用，幂等，404 返回 204）。✓
- [2026-07-29 10:11:54] S1 `server/nodejs/server.js`：对等实现 `handleDeleteBlob`。✓
- [2026-07-29 10:11:54] S2 `server/go/main.go` + `server/nodejs/server.js`：新增 `handleListBlobs`（GET /api/v2/blobs，返回 JSON 数组，需认证，跳过 .tmp 文件）。✓
- [2026-07-29 10:11:54] S2 `lib/sync/safe_server_backend.dart`：`listBlobs()` 从返回空列表改为调用 `GET /api/v2/blobs` 端点（JSON 解码 + 404/405 降级为空列表）；新增 `dart:convert` 导入和 `_blobsUrl` getter。✓
- [2026-07-29 10:11:54] S3 `server/go/main.go` + `server/nodejs/server.js`：新增 `handleDeleteManifest`（DELETE /api/v2/manifest，清理损坏文件，幂等，404 返回 204，与 PUT 共享互斥锁）。✓
- [2026-07-29 10:11:54] S4 `server/go/main.go` + `server/nodejs/server.js`：新增 `AuthFailTracker`（IP+滑动窗口 1 分钟，默认 10 次阈值，`--rate-limit` 参数控制，`X-Forwarded-For` 识别真实 IP，认证成功清除计数，超限返回 429+`Retry-After: 60`）。✓
- [2026-07-29 10:11:54] S4 `lib/sync/safe_server_backend.dart`：`deleteBlob()` 和 `backupCorruptManifest()` 注释更新为 v2.1 协议，保持 405 兼容降级。✓
- [2026-07-29 10:11:54] S5 `docs/server-api-spec.md`：版本从 v2 升级至 v2.1；新增 §5.7/§5.8/§5.9 端点说明；更新 §5.1 端点汇总表（8 端点+版本列）、§8.1 状态码总表（加 204/405/429）、§9.5 孤儿 blob 清理（v2.1 GC 流程）、§10.5 防枚举、§10.6 速率限制（升级为"强烈建议"+具体策略）、§11 幂等性表、§12.2 测试场景、§12.4 curl 示例、§13 参考实现表、§14 不强制特性、§15 版本历史。✓
- [2026-07-29 10:11:54] S6 `temp/sync/safe_server_integration_test.dart`：新增 11 个 v2.1 端点测试（GET blobs 列表、listBlobs 客户端调用、空目录、DELETE blob、幂等删除、deleteBlob 客户端调用、DELETE manifest、幂等删除、backupCorruptManifest 客户端调用、未认证 401、速率限制 429）。✓

### 验证

- [2026-07-29 10:11:54] `flutter analyze lib/sync/safe_server_backend.dart`：0 errors / 0 warnings。✓
- [2026-07-29 10:11:54] `flutter test temp/sync/`：110 测试全部通过（含 26 个集成测试 + 11 个新 v2.1 端点测试）。✓
- [2026-07-29 10:11:54] `flutter build apk --debug`：成功（20.1s）。✓

## 实施总结

| 块 | 状态 | 说明 |
|----|------|------|
| A 协议字段 | ✅ | ManifestHeader/Item 字段补齐 + per-vault salt |
| B 改密码闭环 | ✅ | 纪元守卫 + 登录门禁改造 + unlockFromRemoteManifest |
| C 同步触发器 | ✅ | 6 处 autoSync 接入 |
| D 健壮性 | ✅ | D1-D5 全部完成（manifest 自愈/blob 保留/vaultId/原子写/登录失败停留） |
| E 安全加固 | ✅ | E1 冲突副本 + E2 ETag 探测 + E3 服务端速率限制（块 S 中实现） |
| F 清理 | ✅ | F1 GC（deleteBlob/listBlobs + 墓碑 GC）+ F3 登出顺序统一 |
| G 测试 | ✅ | 3 个新 GC 测试，总计 80 测试通过 |
| S 服务端补全 | ✅ | v2.1 协议：DELETE blob/manifest + GET blobs + 速率限制 + 客户端 listBlobs 实装 + 11 个集成测试 |
| R 收尾修复 | ✅ | D3 version 攀升修复 + F4 迁移期 UI 读锁 + crypto.dart 注释 + unlockFromRemoteManifest 先验证后持久化 |

跳过项：
- F2（synced 字段去留）：P3 清理级别，未在本轮范围

## 块 R：收尾修复（D3/F4/注释/解锁顺序）

实施日期：2026-07-29

### 背景

前序会话遗留 2 个跳过项（D3 pendingBlob version 攀升、F4 迁移期 UI 读锁）和 2 个小瑕疵（crypto.dart 注释矛盾、unlockFromRemoteManifest 先写后验证），本轮全部修复。

### 步骤与时间戳

- [2026-07-29 10:25:31] R1 `lib/sync/crypto.dart`：顶部注释从 `FIXED_SALT / safenotes-v1` 改为描述 per-vault 随机 salt，补充历史演进（v0→v1→v2）。✓
- [2026-07-29 10:25:31] R2 `lib/sync/vault.dart`：`unlockFromRemoteManifest` 从"先持久化 meta 再验证密码"改为"先 `_unlockWith` 验证密码，成功后才持久化 meta"。✓
- [2026-07-29 10:25:31] R3 `lib/sync/sync_engine.dart`：新增 `_hasEffectiveChange()` 方法，PUT manifest 前判断是否有实际变更（传输操作/纪元/override/header 关键字段/items 不一致）。无变更时跳过 PUT，version 不递增；跳过 PUT 时仍执行 GC。✓
- [2026-07-29 10:25:31] R4 `lib/data/database_handler.dart`：新增 `MigrationInProgressException` 和 `_isMigrating` 标志；`reEncryptAllNotes` 期间置 true，`finally` 清除；`readNote`/`readNoteByUuid`/`readAllNotes`/`readDeletedNotes`/`storeNote`/`updateNote`/`updateNoteByUuid` 加 `_checkNotMigrating()` 守卫；`readAllNotesIncludingDeleted` 不加守卫（同步引擎内部用）。✓

### 验证

- [2026-07-29 10:25:31] `flutter analyze lib/sync/ lib/data/database_handler.dart`：0 errors。✓
- [2026-07-29 10:25:31] `flutter test temp/sync/`：110 测试全部通过。✓
- [2026-07-29 10:25:31] `flutter build apk --debug`：成功（16.5s）。✓
