# 测试增强方案（2026-08-23）

> 范围：`packages/core`（纯 Dart 核心包）+ `lib/` 非 UI 部分。
> 方法：实际运行 `dart test --coverage`（core）与 `flutter test --coverage`（app 全量），
> 结合源码逐文件审查得出缺口清单。所有行号基于 2026-08-23 的代码。

---

## 1. 当前覆盖率基线

### 1.1 core 包（dart test，23 个测试文件，327 通过 / 4 失败）

| 文件 | 行覆盖 | 说明 |
|---|---|---|
| `src/crypto/crypto.dart` | **99.0%** | 良好 |
| `src/sync/backends/http_util.dart` | 92.7% | 良好（live 测试需真实服务器） |
| `src/models/backup_file.dart` | 92.0% | 良好 |
| `src/models/note_meta.dart` | 91.9% | 良好 |
| `src/models/safenote.dart` | 85.0% | 尚可 |
| `src/sync/keyring.dart` | 84.7% | 残余分支见 §3.6 |
| `src/sync/backends/local_fs_backend.dart` | 81.1% | 尚可 |
| `src/sync/sync_engine.dart` | 81.0%（951 行中约 180 行未覆盖） | 错误处理 / 恢复编排分支缺失 |
| `src/sync/journal.dart` | 80.4% | 残余分支见 §3.5 |
| `src/db/database_handler.dart` | 79.2%（862 行中约 180 行未覆盖） | 升级迁移 / 失败回滚缺失 |
| `src/models/parse_import.dart` | 77.8% | 恶意文件防护分支不全 |
| `src/sync/sync_models.dart` | **54.8%** | v5 容器负向分支几乎全缺 |
| `src/sync/backends/webdav_backend.dart` | **49.4%** | 状态码矩阵 / 备份轮转未测 |
| `src/sync/sync_backend.dart` | **43.9%** | writeRingBackup 等默认实现未测 |
| `src/models/note_version.dart` | **30.0%** | 模型方法基本没测 |
| `src/sync/backends/safe_server_backend.dart` | **16.4%** | 现有测试依赖真实服务器；MockClient 可全覆盖 |
| `src/sync/sync_error.dart` | **8.7%** | 无任何直接测试 |
| `src/logger/app_logger.dart` | **4.8%** | 无任何直接测试 |

另：**`bin/` CLI（safenotes_cli / cli_commands / cli_context）零测试。**

已知失败测试（与本方案无关但需注意）：chaos_multi_client_test（多 isolate）、
longrun_persistent_store_test、safe_server_integration_test（需要本地起服务器）。

### 1.2 lib 非 UI（flutter test 全量）

| 文件 | 行覆盖 |
|---|---|
| `utils/scheduled_task.dart` | **0%**（119 行，备份重试逻辑完全无测试） |
| `utils/vault_backup.dart` | **0%**（忘记密码逃生通道） |
| `utils/note_diff.dart` | **0%** |
| `data/prefs_store_override.dart` | **0%** |
| `models/file_handler.dart` | **2%** |
| `sync/sync_service.dart` | **27.3%**（同步服务编排核心） |
| `utils/device_id.dart` | 28.6% |
| `src/logger/log_webserver.dart` | 36.8%（token 认证 / 目录穿越未固化） |
| `models/session.dart` | 41.4% |
| `utils/env_config.dart` | 44% |
| `models/editor_state.dart` | 46%（保存守卫分支未测） |
| `data/preference_and_config.dart` | 47.7% |
| `models/pin_auth.dart` | 51.9% |
| `models/biometric_auth.dart` | 66.7% |
| 已良好：`sync_config.dart`(90%)、`editor_text.dart`(89%)、`note_edit_history.dart`(100%)、`authwall.dart`(100%) |

---

## 2. 总体策略

1. **分层补测**：
   - P0 = 数据安全与同步正确性（加密容器负向路径、密钥判定、损坏恢复、DB 迁移回滚）；
   - P1 = 行为契约（日志脱敏、自动同步调度、认证失败路径、备份防线）；
   - P2 = 健壮性与展示层。
2. **优先用 MockClient / fake backend 替代真实服务器集成测试**
   （safe_server / webdav 两个 backend 目前覆盖率最低正是因为只靠 integration test）。
3. **负向路径优先于正向路径**：现有测试主流程覆盖已好，缺口集中在
   异常分支、字节篡改、状态码矩阵、并发互斥——这些恰是数据丢失事故的来源。
4. 新增 core 测试放 `packages/core/test/`，保持 core 零 Flutter 依赖；
   lib 测试放根 `test/`，沿用 `test_helpers.dart` / `harness.dart` 现有基建。

---

## 3. core 包增强项

### 3.1 sync_models.dart — v5 容器"损坏 vs 密钥不匹配"分流（P0）

这是 §11.1 设计契约的实现地，负向分支全部未测：

- `_parseAndVerifyContainer` 六个负向分支（sync_models.dart:1030-1096）：
  过短输入 FormatException、magic 错误、fileVer 错误、headerLen 越界、
  pubHash 位翻转 → ManifestAuthException、固定头 schemaV 与 header 不一致。
  写法：先 serialize 合法容器，再逐一篡改单字节断言异常类型精确匹配。
- pubHash 通过但 dataKey 错 → 必须是 **ManifestKeyMismatchException** 而非 Auth
  （sync_models.dart:1004-1010）。serialize 用 keyA、deserialize 用 keyB。
- 空 items 容器 round-trip 返回空 map（:986-989）。
- `deserializeHeaderOnly` 不需要 dataKey 且同样验 pubHash（:1022-1024）。
- `ManifestItem.fromJson` 缺省回退：createdAt 回退 updatedAt、blobKeyEpoch 默认 0
  —— 注意与构造器默认值 1 不一致，测试时应确认是否有意（:235-250）。
- `ManifestHeader.fromJson` 旧协议兼容（schemaVersion 缺省 1 等，:521-539）。
- `rejectOldSchemaVersion` 边界：v4 拒绝、v5 通过（sync_engine.dart:2979-2986）。
- `KdfParams.create/fromJson` round-trip；Argon2id 写入 memoryKiB/parallelism、
  PBKDF2 时省略（:327-354）。

### 3.2 safe_server_backend.dart + webdav_backend.dart — 状态码矩阵（P0）

用 `package:http/testing` 的 MockClient 注入，无需真实服务器即可全覆盖：

**SafeServerBackend：**
- `init()`：health 500 / body != 'ok' / SocketException 三例 → BackendUnavailableException（:128-144）。
- `getManifest`：404→(空,'')、401→auth failed、其他非 200→失败、
  **200 但无 ETag 头→抛 "v2.2 required"**（协议红线）、超大 body→checkRemoteReadSize（:194-225）。
- `putManifest`：expectedEtag 空→发 `If-None-Match:*`、非空→`If-Match:"etag"`；
  412→ConflictException；新响应缺 ETag 抛（:235-278）。用捕获的请求对象断言头拼装。
- `deleteBlob` 五状态码矩阵，405 必须静默幂等成功（F-H08）（:370-393）。
- `deleteBlobSoft` 409→退化为 deleteBlob 兜底（:490-508）。
- manifest 环形备份：索引损坏 slot=0、`(slot+1)%5` 轮转顺序、
  `listManifestBackups` 从新到旧排序、`readManifestBackup` 正则拒绝 `../evil`（:599-685）。
- journal：PUT 非 2xx→StateError（F-H07 禁止假成功）；GET 超大小上限抛（:700-745）。

**WebdavBackend：**
- MKCOL 矩阵 201/405 通过、401 auth failed（:1050-1075）。
- `_probeEtagSupport` 四分支 + 警告只记一次（:187-225）。
- getManifest 无 ETag → 内容 SHA-256 fallback etag（:321-346）。
- putManifest 412/**409**→ConflictException（:377-393）。
- `listBlobs` href 正则 + Uri.decodeComponent + 非 64hex 过滤 + PROPFIND 失败返回 []（:483-530）。
- `deleteBlobSoft` COPY 失败→硬删除退化且不抛（:538-594）。
- journal 与环形备份同 SafeServer 对应项（两端共用语义可共享测试辅助）。
- `_normalizeEtag` 表驱动：W/"x"、带引号、裸串、null（safe_server :824-834）。

### 3.3 database_handler.dart — 升级迁移 / 失败回滚 / JSON 防护（P0）

- **onUpgrade v3→v4 分支**（:750-756）：手工 openDatabase(version:3) 建 v3 结构插数据，
  重开 version:7，断言 synced_deleted 列存在且老数据为 0。现有升级测试都从 v4 起。
- **reEncryptAllNotes 失败回滚**（:1722-1730、:1876-1882）：中途注入异常后断言
  _dataKey 恢复原值、旧 key 仍能读全部笔记、_isMigrating 复位。
- `MigrationInProgressException` 守卫（:437-441）：迁移窗口内 readNote/readAllNotes 抛、
  readAllNotesIncludingDeleted 不抛、结束后恢复。
- `_parseUuidList` 损坏 JSON 抛 FormatException（防"已删笔记复活"守卫）（:1526-1541）。
- `markAllForBlobReupload` / `getPendingReuploadUuids`（损坏 JSON→空集合）/
  `removePendingReuploadUuids`（部分成功剩余保留）（:1985-2043，Layer 2a 强制重传持久化侧）。
- GC 候选表存取 + 损坏 JSON→{}（:2056-2080）。
- `getManifestVersion` meta 值非整数降级 0 不崩溃（:2117-2131）。
- `restoreNote` 后 deleted=0/synced=0 且缓存同步（:1554-1588）。
- 隐私红线：`cachedNoteSummaries` 输出不含 title 明文（:150-180）。
- `_decryptField` 对非法 base64 包装为 SyncDecryptionException（:485-488）。
- `exportAll` → ImportParser.fromDecryptedPlaintext 导出导入闭环（:2447-2452）。

### 3.4 sync_engine.dart — 密钥判定与损坏恢复编排（P0/P1）

**密钥判定（_syncOnce 内）：**
- F-M05：MK 能解远端包裹但解出的 dataKey ≠ 本地 → 失败中止、零写入（:631-639）。
- MK==null 兜底三分支：能解 items→保守继续；不能解→失败；Auth→重建（:641-682）。
- 本端改密码未推送：remote keyVersion < local → 正常 PUT 新包裹（:683-695）。
- 他端改密后本端同步 → requiresRelogin=true 且**无任何 PUT**（journal 无
  syncManifestPut done 条目）（:697-722）。
- 场景 c/d：passphraseProvider 未注入失败；tryDeriveRemoteDataKey null→relogin；
  场景 d 整库迁移后 `_MigrationRequiredException` 重试成功（:749-800）。

**远端 manifest 损坏恢复（§7.1）：**
- re-GET 成功→merge（recoveredSource='reget'）且**不做 backupCorruptManifest**（:365-387）。
- bak 循环：坏 pubHash bak + 旧 key bak + 完好 bak 共存时选中完好份；
  所有 bak 解不开→跳过试下一份绝不触发 scenario-b，最终本地重建（:395-422）。
- putEtag 三分支：local 重建→''（If-None-Match 首传 F-H01）、reget→新 etag、bak→原 etag（:462-471）。

**传输细节：**
- `_withBlobRetry`：BackendUnavailableException 重试恰好 2 次退避后成功 / 3 次耗尽抛 /
  ConflictException 不重试仅调用 1 次（:205-230）。
- M7 hash 错位：blob 解密成功但内容 hash ≠ item.hash → skip + heal failed（:2261-2300）。
- LWW updatedAt 相等 → hash 字典序小者胜（:2016-2021，双设备集成用例断言）。
- `_handleDownloadFailure` 自愈重传再次失败→corrupt；isOldKey 提示文案区分（:2420-2518）。
- `_gcOrphanBlobs` 单个软删除失败不阻断其余处理（:2724-2757）。
- `_hasEffectiveChange`：items 全同但 encryptedDataKey 变仍触发 PUT version+1（:2941-2947）。

### 3.5 journal.dart / sync_backend.dart 残余（P1/P2）

- journal 批量阈值：pending 攒满 50 条立即落盘不走 Timer（:666-678）。
- 归档 rename 失败→沿用当前日志继续工作（:753-758，Windows 可用文件句柄锁制造）。
- `.journal-state.json` 损坏（Exception/Error 两 catch）水位归零不抛（:550-562）。
- vaultMismatch 判定：fileVaultId 为空字符串不算 mismatch（:1095-1099）。
- `writeRingBackup` 完整状态机（sync_backend.dart:305-343）：轮转 7 次只留 5 份、
  index 内容损坏→slot=0、index 写失败不阻断、tmp 写成功 rename 失败→清 tmp rethrow。
- SyncBackend 抽象类全部默认 no-op 实现逐个调用，守护"GC 保守退化"契约（:115-229）。

### 3.6 keyring.dart 残余（P1）

- `unlockFromRemoteManifest` 先验证后持久化：错误密码抛出后断言
  `hasKeyringRecord(db)==false`（C1 安全顺序回归保护）（:553-563）。
- PBKDF2 老 vault changePassword → 升级 Argon2id：salt 沿用、keyVersion+1、
  旧 dataKey 仍解得开笔记（:876-887）。
- encryptedDataKey 非法 base64 → KeyringCorrupted（非 WrongPassword）（:603-607）。
- `updateEncryptedDataKey` 相同值跳过 persist / 不同值原地更新落盘（:949-960）。

### 3.7 app_logger.dart（当前 4.8%，P1）

- init 前 `Log.*` 必须 no-op（:673、:591）。
- 环形缓冲 2000 条裁剪 + broadcast stream 推送（:188-194）。
- `_HybridOutput` message/error/stackTrace 三段拆分与 `_stripPrefix`
  （message 含 "] " 时不得误剥）（:274-307）。
- consoleEnabled=false 静默（CLI --json 输出纯净性依赖）（:296-328）。
- init 幂等 + 目录解析失败降级 console+内存（:344-405）。
- `_cleanupOldFiles`：过期删、非法日期名/非日志名保留（:497-523）。
- setLevel 手动覆盖优先于 refreshLevel 自动策略、resetLevel 恢复（:607-624）。

### 3.8 parse_import.dart / note_version.dart / sync_error.dart（P1/P2）

- parse_import：`fromDecryptedPlaintext` expectedTotal 三态（:53-65）；
  BackupHeader 畸形头表驱动（format 错 / formatVersion<1 / salt 缺失或长度错 /
  payload<28 字节 / iterations<=0 → FormatException 及中文消息）（:130-223）；
  Argon2id 缺 memoryKiB/parallelism 抛而 PBKDF2 为 null 合法（:184-199）。
- note_version 模型：fromJson 缺字段默认值、copyWith、toString 标题脱敏 `<redacted>`
  （隐私红线）（note_version.dart:94-138）。新建纯单测文件即可。
- sync_error：各子类 toDisplayString 全字段/缺字段两态参数化；
  **已知隐患**：`DecryptionError`/`BlobMissingError` 的 `blobHash.substring(0, 8)`
  在 hash 长度 <8 时会抛 RangeError（sync_error.dart:106、:169），先写暴露测试再修复；
  `_truncateCause` 截断格式（:295-299）；`wrapDecryptionError` isTagError 两分支（:333-342）。

### 3.9 bin/ CLI（当前零测试，P1）

- 退出码映射：UsageException=64、CliException/WrongPassword=1、未知=2
  （safenotes_cli.dart:50-71，直接调 runner.run 捕获类型断言）。
- **端到端冒烟最有价值**：init → add 两条 → export plaintext → wipe → import →
  数量一致；export encrypted(snbak) → import 解密回读（cli_commands.dart:361-746）。
  同时守护 core 编译无 Flutter 依赖这一架构约束。
- `resolveCliPassword` 三级优先级 + 密码文件不存在→CliException（cli_context.dart:74-90）。
- 危险操作确认门：db wipe / hard-delete / purge-deleted 缺 `--yes` 抛 CliException
  （:167-169、:578-580、:601-603）。
- `buildBackend` 凭据三级优先（显式 > credentials.json > 环境变量）（:296-348）。

---

## 4. lib 非 UI 增强项

### 4.1 sync_service.dart（27.3%，最重要）

- **`_redactUrl` / `_maskUsername` 凭据脱敏**（:1231-1254）：
  userInfo/query 均 `***`、非法 URL 正则回退、短用户名掩码。
  纯静态函数、半天完成、防止凭据经局域网日志服务器泄漏，性价比最高。
- `autoSync()` debounce / L3 重排程 / 失败重试一次标志位 / onError 兜底
  （:710-779）："改了笔记却不再同步"类 bug 全部在此。用 FakeAsync / tester.pump 验证
  连续 3 次触发只跑 1 次 sync、failure 后恰重试一次、成功清标志。
- `sync()` 入口互斥锁（:449-453）：engine.sync 用 Completer 挂起，并发第二次返回 null。
- 同步总开关拦截（:435-444）与 `applyConfigToService` 各分支（关开关/配置不完整/
  keyring 空/engine 未就绪）（:868-925，F-H06 回归）。
- `switchBackend` 同步中互斥拒绝 + 初始化失败回滚（:803-823）。
- `updateKeyring` keyVersion 递增写 journal 并 flush（:318-335，改密码取真依据）。
- `logout()` 执行顺序与 `dispose()` 差异（:365-417）。
- `initialize` 幂等化：重复调用先关旧 journal/backend，防句柄泄漏（:193-197）。

### 4.2 scheduled_task.dart（0%）与 vault_backup.dart（0%）— 数据安全最后防线

- 开关关闭时 `backup()` 不产生任何文件；`forceBackup` 绕过开关仍写出 `.snbak`
  且 lastBackupTime 更新（:28-36、:285-322）。
- 会话密码为空时 `unitBackupAttempt` 返回 false（**禁止明文备份**红线）（:94-98）。
- 总超时中断重试循环（Session.logout 不得被无界阻塞）（:48-55、:296-303）；
  指数退避封顶 5s、接近超时不等待（:124-132）。
- desktopBackup 真实落盘 + 父目录创建（Windows 主机可直接跑）（:247-267）。
- `_simplifyBackupError` errno 13/17 映射（:200-209）。
- vault_backup：db 文件不存在抛异常；快照含 db 副本 + preferences.json；
  prune 只留 5 份按目录名字典序删最旧；清理失败不阻断重置（vault_backup.dart:47-92）。
- 写法：SharedPreferences.setMockInitialValues + path_provider mock + 临时目录。

### 4.3 editor_state.dart 保存守卫（46%，数据丢失相关）

复用现有 syncedhash 测试 harness：
- `_isSaving` 防重入返回 null（:71-75）。
- 空标题/正文补空格归一化、内容未变跳过保存、空内容不保存（:81-103）。
- `destroyAfter:false` 时 original 更新为新笔记防重复入库（:106-109）。
- `handleUngracefulNoteExit` 双条件组合（:48-61）。

### 4.4 pin_auth / biometric_auth / session（认证安全语义）

一套 MethodChannel secure-storage mock 同时覆盖三个文件：
- setPin 时 biometric 已启用自动关闭（互斥）（pin_auth.dart:251-254）。
- 连续错误 PIN 5 次 `onPinFailed` 第 5 次自动 disable 返回 true（:305-315）。
- disable 删除全部 4 个 storage key（:318-327）；refreshCredential 缺 wrap key
  跳过不抛（:333-356）；verifyPin 凭据不完整/错误 PIN 返回空串（:274-298）。
- biometric 旧版明文格式兼容读取（无 v1: 前缀原样返回）（biometric_auth.dart:54-56）；
  wrap key 被删→authKey==''（指纹登录走失败分支的安全保证）（:116-128）。
- session.logout 顺序：backup → SyncService.logout → clearDataKey → destroy
  （session.dart:51-71；预置 isBackupOn=false 防副作用）。

### 4.5 log_webserver.dart 安全端点固化（36.8%）

在现有 log_webserver_test 基础上扩展（127.0.0.1 随机高端口）：
- 无 token / 错 token → 403（:236-243）；正确 token → 200。
- OPTIONS 预检 → 204（注意当前实现绕过 token 校验，用测试固化该行为并加注释说明是否预期）（:229-234）。
- `/logfile?name=../../etc/passwd` 及 `\`、`..` 变体 → 400（目录穿越拒绝，:442-448）。
- 端口冲突 +1 重试、10 次耗尽抛（:152-167）。

### 4.6 快速胜利（各约 1 小时内）

- **note_diff.dart（0%）**：computeDiff insertion/deletion/equal 映射、
  hasDifference 判定、>50000 字符走 isolate 结果与同步版一致（:60-152）。
- **prefs_store_override.dart（0%）**：前缀过滤 getAllWithPrefix('flutter.')、
  setValue/remove/clear JSON 往返、损坏 JSON 视为空 store 不崩溃（:38-89）。
  唯一可纯 Dart 测的 lib 文件。
- **device_id.dart（28.6%）**：overrideForTesting 优先级、缓存命中、clearTestingOverride
  清两字段（:75-96），约 20 行把覆盖率拉到 ~60%。
- **preference_and_config.dart 有逻辑分支**：inactivityTimeoutIndex 越界(-1/99)回退 180s
  （:324-371）、managedTags 归一化去重（:80-103）、backupFileName 冗余计数后缀、
  时间戳格式 `\d{8}_\d{6}`（:833-871）、clearVaultRelatedKeys 清 4 个 key（:162-169）。

### 4.7 暂缓项（明确不做或降级）

- `env_config.dart`：`_genericCache` 进程级懒加载 + Platform.environment 只读，
  当前设计不可测；建议小幅重构抽出 envLookup 注入点后再测。
- `file_handler.dart` 导入 UI 编排链路：下沉到包层用 BackupFileCodec encode/decode
  round-trip 覆盖编解码，widget 流程留给集成测试。
- `dialogs/generic.dart`、`backup_import.dart`：薄包装无业务逻辑，不值得单独测；
  `confirm_import.dart`（数量插值）与 `delete_confirmation.dart`（点取消不得触发 onConfirm）
  可用各 ~30 行 widget test 固化。

---

## 5. 实施批次建议

### 5.1 大批次概览

| 批次 | 内容 | 预估规模 | 目标 |
|---|---|---|---|
| B1（P0） | sync_models 容器负向分支；safe_server/webdav MockClient 状态码矩阵；sync_engine 密钥判定 + §7.1 恢复编排；database_handler v3→v4 升级 / 迁移回滚 / _parseUuidList；writeRingBackup | core 覆盖率整体 ≥90%，四个低覆盖文件 ≥80% | 数据安全回归防线 |
| B2（P1） | sync_service 脱敏/autoSync/互斥/applyConfig；scheduled_task + vault_backup；pin/biometric 失败路径；app_logger；CLI 冒烟 + 退出码；keyring C1/C2 | lib 非 UI 关键文件 ≥70% | 行为契约固化 |
| B3（P2） | sync_error（含 substring<8 隐患修复）；parse_import 恶意头表驱动；journal/writeRingBackup 残余；note_version 模型；快速胜利四件套；log_webserver 安全端点；confirm/delete 对话框 | 补齐长尾 | 健壮性 |

### 5.2 推荐的细粒度分步实施路径（4 阶段小步推进）

为避免单个大批次跨度过大、排查困难，实际落地推荐按以下 4 阶段拆解执行：

#### 阶段 0：基建就绪与快速胜利（低风险、立竿见影）
1. **测试基建与公共 Mock**：
   - 固化覆盖率统计脚本（如 `tool/coverage.ps1`），先记录初始精确基线。
   - 在 `packages/core/test/sync/sync_test_support.dart` 补充通用的 `MockClient` 响应生成与异常注入辅助工具。
2. **快速胜利四件套（纯逻辑，零副作用）**：
   - `note_diff.dart`（0% → 90%+）：比对算法与差异判定。
   - `prefs_store_override.dart`（0% → 95%+）：纯 Dart 内存 Store 往返与容错。
   - `models/note_version.dart`（30% → 95%+）：模型 copyWith 与脱敏 toString。
   - `utils/device_id.dart`（28.6% → 80%+）：overrideForTesting 机制。

#### 阶段 1：Core 核心数据安全防线（P0，纯 Dart 极速执行）
1. **Step 1.1 — `sync_models.dart` v5 容器负向解析**：
   - 覆盖 `_parseAndVerifyContainer` 6 个负向篡改分支（过短、magic 错误、pubHash 翻转、固定头不匹配）。
   - 验证关键分流：DataKey 错误时精确抛出 `ManifestKeyMismatchException` 而非 `ManifestAuthException`。
2. **Step 1.2 — `database_handler.dart` 迁移回滚与故障防护**：
   - v3→v4 升级迁移（真实 v3 结构验证）。
   - `reEncryptAllNotes` 中途异常回滚旧密钥与状态复位。
   - `_parseUuidList` / GC 表解析坏 JSON 防御（防已删笔记复活）。
3. **Step 1.3 — `safe_server_backend` & `webdav_backend` 状态码矩阵**：
   - 使用 `MockClient` 全面替代对真实服务器的依赖。
   - 覆盖 404/401/412/409/405、ETag 缺失抛错、MKCOL 矩阵、环形备份 5 份轮转与越权路径校验。
4. **Step 1.4 — `sync_engine.dart` 密钥判定与自愈编排**：
   - Scenario a/b/c/d 密钥判定矩阵（改密未推、他端改密 requiresRelogin、跨版本重试）。
   - 远端 manifest 损坏恢复流程（reget 成功不备份、坏 pubHash/旧 key 备份跳过、最终本地重建）。
   - 传输重试退避与 M7 hash 错位处理。

#### 阶段 2：Lib 业务调度与认证安全（P1，Flutter/平台模拟）
1. **Step 2.1 — `sync_service.dart` 调度与并发控制**：
   - 凭据脱敏静态函数（`_redactUrl` / `_maskUsername`，防止凭据进入局域网日志）。
   - `autoSync` 的 debounce 防抖、失败重试一次标志位、`sync()` 入口并发互斥锁。
2. **Step 2.2 — `scheduled_task.dart` 与 `vault_backup.dart`**：
   - 禁止明文备份守卫（会话密码为空时拒绝备份）。
   - 自动备份开关拦截、`forceBackup` 强制落盘。
   - 备份目录滚动修剪（只留最新 5 份快照，最旧目录自动删除）。
3. **Step 2.3 — 认证安全与会话生命周期（`pin_auth` / `biometric_auth` / `session`）**：
   - Mock SecureStorage / MethodChannel：连续 5 次错误 PIN 自动禁用 PIN 登录。
   - PIN 与生物识别互斥逻辑。
   - `session.logout` 严格执行顺序（先备份 → sync logout → 清 key → 销毁）。
4. **Step 2.4 — `editor_state.dart` 保存守卫**：
   - `_isSaving` 防重入、空内容跳过保存、`destroyAfter:false` 防重复插入。

#### 阶段 3：CLI 工具、日志与已知隐患修复（P1/P2，健壮性与长尾）
1. **Step 3.1 — 已知隐患修复与异常模型（`sync_error.dart`）**：
   - 遵循 TDD 流程：先为 `blobHash.substring(0, 8)` 在长度 `< 8` 时编写暴露崩溃的测试，再修复代码验证通过。
2. **Step 3.2 — `bin/` CLI 冒烟与退出码测试**：
   - 直接调用 `CliRunner` 测试 UsageException(64)、CliException(1)、未知(2) 退出码。
   - 危险操作（db wipe / purge-deleted）缺少 `--yes` 确认门的阻断测试。
   - 端到端冒烟：`init → add → export → wipe → import` 数量与数据一致性闭环。
3. **Step 3.3 — `app_logger.dart` 与 `log_webserver.dart` 安全固化**：
   - 日志环形缓冲区 2000 条裁剪、前缀误剥离防护、`consoleEnabled` 静默开关。
   - WebServer 的 Token 鉴权、`../` / `..\` 目录穿越防御。

### 5.3 实施准则与质量控制
1. **原子化推进（One Step per Commit/PR）**：按细粒度步骤推进，每步完成后运行 `dart format`、`flutter analyze`、`dart test packages\core\test` 和 `flutter test` 确保全绿。
2. **零网络依赖与极速运行**：所有测试严格使用 `MockClient` / 假数据 / 内存 DB，避免真实网络与外部服务器依赖，保证全量测试在 30 秒内跑完。
3. **日志记录**：重要改动与阶段性覆盖率提升记录于 `docs/CHANGES-YYYYMMDD.md`。

## 6. 工程配套

- 覆盖率采集命令（本方案数据来源）：
  - core：`cd packages\core && dart test --coverage=temp\coverage_core`，
    再 `dart pub global run coverage:format_coverage --package=packages\core
    --report-on=packages\core\lib --in=packages\core\temp\coverage_core
    --out=temp\core_lcov.info --lcov`
  - app：`flutter test --coverage`（输出 `coverage\lcov.info`）
- 建议把上述命令固化为脚本（如 `tool/coverage.ps1`），并在 CI 中对
  P0 文件设置 fail-under 阈值（初始 80%，B1 完成后提至 90%）。
- 新增测试遵循项目规范：改动后运行 `dart format`（仅改动文件）、
  `flutter analyze`、`dart test packages\core\test`、`flutter test`。
