# SafeNotes Flutter App 业务功能点清单

> 生成日期：2026-08-03
> 适用范围：Flutter App（`lib/`）+ 纯 Dart 核心包（`packages/core/`）
> 代码分层：核心逻辑（加密 / 数据库 / 同步引擎）为独立纯 Dart 包 `packages/core`（无 Flutter 依赖，编译器强制），App 侧仅保留 UI 与状态装配，统一经 `package:core/core.dart` 出口导入。
> CLI 入口：`bin/safenotes_cli.dart`（纯 Dart，无需 Flutter SDK，可读写加密笔记数据库）。

---

## 功能域 1：认证与密钥管理（Keyring / Session）

### 1.1 首次设置密码
- 页面：`lib/views/authentication/set_passphrase.dart`（路由 `/signup`）
- 调用链：表单校验（`estimateBruteforceStrength`，≥8 字符、强度≥0.5）→ `SyncService.instance.initKeyringFromPassword(password, database)` → `Keyring.isInitialized` → `Keyring.createNew(password, database)`（生成 vaultId + dataKey + salt，PBKDF2-HMAC-SHA256 200k 派生 MK，AES-GCM wrap dataKey）→ `database.setDataKey(dataKey)` → `Session.onPasswordSet(passphrase)`（`PhraseHandler.initPass` + `BiometricAuth.setAuthKey`）→ 若 `SyncConfig.isSyncEnabled` 则 `initBackend(database)` → 导航 `/home`
- CLI 可复用：**是**（Keyring / SyncCrypto 纯 Dart，PBKDF2 走 Isolate）

### 1.2 密码登录（含限流/锁定）
- 页面：`lib/views/authentication/login.dart`（路由 `/login`）
- 调用链：`Keyring.isInitialized` → 本地优先 `SyncService.initKeyringFromPassword`（unlockLocal，GCM tag 验证失败抛 `WrongPasswordException`）→ 失败且启用同步时走远端验证 `_tryVerifyPassphraseViaRemote`：`createBackendForVerification()` → `backend.init()` + `getManifest()` → `ManifestCrypto.deserializeHeaderOnly` → `SyncCrypto.deriveMasterKeyAsync(passphrase, remote salt)` → `computeKeyFingerprint(mk)` 比对 header → `Keyring.unlockFromRemoteManifest(...)` → `database.setDataKey` → `cacheKeyringFromLogin` → `Session.login(passphrase)` → 登录成功 `initBackend` + `autoSync()` → 导航 `/home`
- 限流：`PreferencesStorage.noOfLogginAttemptAllowed`（默认 4 次），`bruteforceLockOutTime`（默认 30 秒），`_isLoggingIn` 防重入；登录成功后 `widget.sessionStream.add(SessionState.startListening)` 启动会话监听
- CLI 可复用：**是**（Keyring 解锁逻辑纯 Dart）

### 1.3 生物识别登录
- 页面：`login.dart` + `lib/models/biometric_auth.dart`
- 调用链：`PreferencesStorage.isBiometricAuthEnabled` → `auth.authenticate(localizedReason, persistAcrossBackgrounding: true)`（local_auth）→ `BiometricAuth.authKey`（secure storage 键 `_secureBiometricAuthKey` 读回密码明文）→ 复用 `_login(passphrase)`
- 凭据刷新：`BiometricAuth.setAuthKey()` 在 `Session.onPasswordSet` 时同步；`disable()` 先置 pref false 再覆写 `"BiometricAuthDisabled"` 并删除
- 每 5 次生物识别强制一次密码挑战：`noOfLoginsBeforeNextPassphraseRememberChallenge = 5`（`isPassphraseRememberChallenge()`）
- CLI 可复用：**否**（local_auth + flutter_secure_storage，需注入端口）

### 1.4 修改密码
- 页面：`lib/views/change_passphrase.dart`（路由 `/changepassphrase`）
- 调用链（5 步）：① `keyring.verifyPassword(oldPassword)` ② `_preChangeCheck()`（`ScheduledTask.forceBackup()` 强制备份 + `backend.ping()` + `SyncService.sync()` + `readUnsyncedNotes()` 检查，失败弹警告可继续）③ `keyring.changePassword(oldPassword, newPassword, database)`（重新 wrap dataKey，keyVersion+1，dataKey 不变故 epoch 不变，返回新实例）④ `SyncService.instance.updateKeyring(keyring, database)`（重建 SyncEngine，keyVersion 递增时 journal 记 `keyChangePassword` 事件）⑤ `Session.onPasswordSet(newPassword)`（刷新 PhraseHandler + biometric 凭据）+ `SyncService.sync()` 推送新 encryptedDataKey
- CLI 可复用：**是**

### 1.5 登出 / 会话超时锁定
- 入口：抽屉 `_logoutToLogin`、`main.dart` 的 `sessionHandler`（`userInactivityTimeout` / `appFocusTimeout`）
- 调用链：`sessionStream.add(SessionState.stopListening)` → 导航清栈 → `NoteEditorState().handleUngracefulNoteExit()`（未保存草稿自动落库）→ `Session.logout()`：`ScheduledTask.backup()` → `SyncService.instance.logout()`（关 journal + 关 backend + 置 uninitialized）→ `NotesDatabase.instance.clearDataKey()` → `PhraseHandler.destroy()`
- 超时参数：`inactivityTimeout`（choices [30,60,120,180,300,600,900]s）、`focusTimeout`、`preInactivityLogoutCounter`（15s 倒计时提示）
- CLI 可复用：**是**（核心清理逻辑纯 Dart；备份需注入）

### 1.6 忘记密码逃生通道（本地重置）
- 页面：`login.dart` `_showForgotPassphraseDialog` → `_confirmResetLocalData` → `_performLocalDataReset`
- 调用链：`NotesDatabase.instance.close()` → `deleteDbFile()`（FATAL 级留痕，`safenotes_sync.db` 物理删除）→ `PreferencesStorage.clearVaultRelatedKeys()` → `AppBootState.vaultInitialized = false` → `pushNamedAndRemoveUntil('/authwall')`
- CLI 可复用：**是**

### 1.7 启动路由决策（AuthWall）
- `lib/authwall.dart`：`AppBootState.vaultInitialized`（main 启动时 `Keyring.isInitialized` 预查）→ true 走 `/login`，false 走 `/signup`

---

## 功能域 2：笔记 CRUD（数据库层 `database_handler.dart`）

统一约束：schema v4，title/description **字段级 AES-256-GCM**（`SyncCrypto.seal/open`，uuid 作 AAD），contentHash 明文（同步比对用），软删除墓碑 deleted=1，dataKey 未注入抛 `DataKeyNotSetException`，迁移中抛 `MigrationInProgressException`。

| 功能点 | 方法签名 | CLI 可复用 |
|---|---|---|
| 新增 | `storeNote(SafeNote note)`（返回带 id 副本，`SafeNote.create` 生成 uuid+hash） | 是 |
| 按 id 读取 | `readNote(int id)`（详情页用，找不到抛异常） | 是 |
| 按 uuid 读取 | `readNoteByUuid(String uuid)`（同步用） | 是 |
| 按内容 hash 读取（孪生自愈） | `readNoteByContentHash(String contentHash)`（limit:1 未删除） | 是 |
| 全量列表 | `readAllNotes()`（未删除，createdTime 排序，走缓存） | 是 |
| 含墓碑全量 | `readAllNotesIncludingDeleted()`（同步对账 + 解密缓存 `_notesCache`） | 是 |
| 未同步笔记 | `readUnsyncedNotes()`（synced=0） | 是 |
| 更新 | `updateNote(SafeNote note)` / `updateNoteByUuid(SafeNote note)` | 是 |
| 软删除 | `softDelete(int id)`（deleted=1 + updatedAt=now + synced=0） | 是 |
| 永久删除 | `hardDelete(int id)`（删行 + 写 purged_uuids 同一事务 B4，防远端复活） | 是 |
| 按 uuid 永久删除 | `hardDeleteByUuid(String uuid)`（GC 墓碑清理用） | 是 |
| 恢复 | `restoreNote(int id)`（deleted=0 + updatedAt=now + synced=0） | 是 |
| 导出 | `exportAll()`（JSON 数组，明文，供备份） | 是 |
| 全库重加密 | `reEncryptAllNotes(oldKey, newKey)` / `reEncryptAllNotesAtomically(oldKey, newKey, keyringJson, markBlobReupload)`（迁移事务化 B1） | 是 |
| 同步收敛标记 | `markSynced(uuid)` / `markAllSynced()` / `markAllSyncedExcept(set)` / `markSyncedForUuids(set)` | 是 |
| 元数据 CRUD | `getMeta(key)` / `setMeta(key, value)` / `getManifestVersion(providerKey)` / `setManifestVersion(...)` | 是 |
| purged 列表 | `getPurgedUuids()` / `removePurgedUuids(...)` | 是 |
| blob 重传标记 | `markAllForBlobReupload()` / `getPendingReuploadUuids()` / `clearAllPendingReupload()` / `removePendingReuploadUuids(...)` | 是 |
| 孤儿 GC 候选 | `getGcOrphanCandidates()` / `setGcOrphanCandidates(...)` | 是 |
| 关闭/删除 | `close()` / `deleteDbFile()` | 是 |

- 注入点：`dbFactoryOverride` / `dbPathOverride`（纯 Dart 用 `databaseFactoryFfi`），`setDatabaseForTesting`（in-memory）
- **UI 流程**：
  - 新建/编辑：`lib/views/add_edit_note.dart` → `NoteEditorState().addOrUpdateNote()` → `storeNote`/`updateNote` → `SyncService.instance.autoSync()`（3 秒 debounce）；PopScope 拦截自动保存
  - 查看：`lib/views/note_view.dart` → `readNote(noteId)` → 软删除经 `confirmAndDeleteDialog` → `softDelete` + `autoSync`
  - 会话超时草稿：`NoteEditorState.handleUngracefulNoteExit()`（wasNoteSaveAttempted==false 且内容非空时自动保存）

---

## 功能域 3：回收站（最近删除）

- 页面：`lib/views/deleted_notes.dart`（路由 `/deletedNotes`）
- 调用链：`readDeletedNotes()`（deleted=1，updatedAt DESC）→ 单条恢复 `restoreNote(id)` + `autoSync()`；单条永久删除 `hardDelete(id)` + `autoSync()`；清空全部循环 `hardDelete` + `autoSync()`
- 说明：硬删除仅本地删行 + purged 标记，远端墓碑由下一次同步的 M1 清理（`getPurgedUuids` 从 merged items 移除），过期墓碑（30 天 `kTombstoneGcThresholdMs`）由 SyncEngine 在 `_buildLocalManifest` 中 GC
- CLI 可复用：**是**（数据库方法全部纯 Dart）

---

## 功能域 4：同步子系统（核心）

### 4.1 同步配置管理
- 文件：`lib/sync/sync_config.dart`；后端类型 `SyncBackendType {none, localFs, webdav, safeServer}`
- SharedPreferences 键：`sync_backend_type` / `sync_localfs_path` / `sync_webdav_url` / `sync_webdav_username` / `sync_safeserver_url` / `sync_auto_sync`
- flutter_secure_storage 键（H3）：`sync_webdav_password` / `sync_safeserver_token`（init 时 `_preloadCredentials` 预载缓存）
- CLI 可复用：**需注入端口**（shared_preferences + flutter_secure_storage 均为插件）

### 4.2 后端抽象接口 `SyncBackend`
- 文件：`packages/core/lib/src/sync/sync_backend.dart`（纯 Dart）
- 核心方法：`init()` / `ping()` / `getManifest()` / `putManifest(ciphertext, expectedEtag)`（乐观锁 CAS，冲突抛 `ConflictException`）/ `getBlob(hash)` / `putBlob(hash, data)`（幂等）/ `deleteBlob` / `listBlobs` / `deleteBlobSoft` / `listOrphanBlobs` / `purgeOrphans` / `backupManifest` / `backupCorruptManifest` / journal 三件套（`putJournalObject`/`getJournalObject`/`listJournalObjects`）/ `close()`
- 异常：`ConflictException`（ETag 不匹配）、`BackendUnavailableException`（网络/5xx）、`BackendNotInitializedException`
- `writeRingBackup(dir, bytes, count=5)`：manifest 代际环形备份通用函数，`kManifestBackupRingCount = 5`

### 4.3 三个后端实现（构造参数 + providerKey 生成方式）

| 后端 | 构造参数 | 存储布局 | providerKey | CLI 可复用 |
|---|---|---|---|---|
| `LocalFsBackend` | `LocalFsBackend({required String rootPath})`（绝对路径，调用方用 path_provider 解析） | `<rootPath>/manifest.json` + `<rootPath>/blobs/<hash>` + `blobs-orphan/` + `manifest-backup/` + `journal/` | `SyncCrypto.hashString('localFs:$rootPath').substring(0, 16)` | **是**（纯 dart:io） |
| `WebDavBackend` | `WebDavBackend({required String baseUrl, required String username, required String password, http.Client? client})` | `<userUrl>/safenotes-vault/manifest.json` + `.../blobs/<hash>`（`kWebDavVaultSubdir='safenotes-vault'` 自动附加，**勿改名**=线上物理路径） | `SyncCrypto.hashString('webdav:$_userBaseUrl').substring(0, 16)`（用原始输入 URL） | 是（dart:io + http，无 Flutter 依赖） |
| `SafeServerBackend` | `SafeServerBackend({required String baseUrl, required String token, http.Client? client})` | `<serverUrl>/api/v2/manifest` + `.../blob/<hash>`（`kSafeServerApiPrefix='/api/v2'`） | `SyncCrypto.hashString('safeServer:$baseUrl').substring(0, 16)` | 是（http，Bearer Token） |

- 工厂：`SyncService._createBackendFromConfig()`（localFs 需 `localFsPath` 非空；webdav 需 url+username；safeServer 需 url+token；配置缺失返回 null）；`createBackendForVerification()` 公开工厂供登录页
- HTTP 统一超时：`_httpTimeout = Duration(seconds: 30)`；WebDAV 用 If-Match/If-None-Match 乐观锁，服务器无 ETag 时退化为内容 hash

### 4.4 同步服务 `SyncService`（单例）
- 文件：`lib/sync/sync_service.dart`
- 生命周期：`initialize({keyring, backend, database})`（打开 journal + 构建 SyncEngine + `backend.init()` + 启动自检 `_reportIncompleteOperations`）；`dispose()`；`logout()`（保留 stateStream/deviceId，清敏感）
- 同步触发：
  - `sync()`：互斥锁 `_syncInProgress` + 后端惰性重初始化（Bug A 修复），委托 `engine.sync()`，返回 `SyncResult`
  - `autoSync()`：3 秒 debounce，失败最多重试 1 次（`_autoSyncFailureRetried`），跳过时 re-schedule 一次（L3/P3-b）
  - `repairRemote()`：委托 `engine.repairRemote()`（全量体检 + 治愈，乐观锁冲突重试）
- 密钥注入：`initKeyringFromPassword` / `initBackend` / `updateKeyring({keyring, database})` / `switchBackend({backend, database})`（同步进行中抛 StateError）/ `cacheKeyringFromLogin`
- 诊断出口：`getDiagnosticsSnapshot()`（`SyncDiagnosticsSnapshot`）/ `getLogEntries()` / `logStream` / `clearLogBuffer()` / `getLogFilePath()` / `exportAllLogsAsText()`；`LogWebServer.instance.diagnosticsProvider = exportAllLogsAsText`（反向注入）
- `SyncStatus {uninitialized, idle, syncing, success, error}`；`SyncServiceState`（status/lastSyncTime/lastResult/errorMessage）经 broadcast stream 暴露
- CLI 可复用：**部分**（依赖 path_provider 解析 journal 目录——`getApplicationSupportDirectory()` 需注入；其余纯 Dart）

### 4.5 同步引擎 `SyncEngine`
- 文件：`packages/core/lib/src/sync/sync_engine.dart`（纯 Dart）
- 构造：`SyncEngine({backend, database, keyring, deviceId, journal, passphraseProvider, onKeyringChanged, orphanRetention})`
- `sync()`：重试循环 `maxRetries`（默认 3），捕获 `ConflictException`（乐观锁回 Step 1 重试）与 `_MigrationRequiredException`（迁移后重同步）
- `_syncOnce` 5 步流程：① GET manifest（仅解析 header）→ ② schemaVersion 降级拒绝（`_rejectOldSchemaVersion`）→ ③ dataKeyFingerprint 精确判定（scenario-b 他端改密码 → **中止 + requiresRelogin=true**，零写入）→ ④ `_buildLocalManifest`（含 30 天墓碑 GC `hardDeleteByUuid`）→ ⑤ `_mergeAndTransfer`（三层：仅本地→上传、仅远端→下载、双方→三方合并判定 fast-forward/真冲突）
- 冲突解决：`_resolveConflict` LWW（updatedAt 大者胜，相等取 hash 字典序小者）；`_preserveConflictCopy` 差异 >5 分钟时保留败方副本（新 uuid + 标题加"冲突副本 N" + 设备标识，`_makeConflictCopyTitle` 探测 hash 碰撞防增殖）
- 容错：Layer 1 解密容错、Layer 2a 密钥变更强制重传（pendingReupload）、Layer 2b 孪生自愈（`readNoteByContentHash`）、D3 下载失败保留 remoteItem、P1 上传失败不写 merged 防幽灵引用
- `repairRemote()`：逐条 getBlob 验证 → 坏 blob 用本机明文/孪生重传覆盖（`heal` action）→ 仍失败记 `failedNoteUuids`
- blob 重试退避：`_withBlobRetry`（BackendUnavailableException 重试 2 次，200ms→400ms）
- 常量：`kTombstoneGcThresholdMs = 30 天`，`maxRetries = 3`
- CLI 可复用：**是**

### 4.6 Keyring（密钥环）
- 文件：`packages/core/lib/src/sync/keyring.dart`（纯 Dart）
- 架构：MK=PBKDF2-HMAC-SHA256(password, per-vault-salt, 200k)；dataKey=随机 32 字节；encryptedDataKey=AES-GCM(MK, dataKey) 存 manifest header；持久化为 sync_meta 单键 `keyring`（`KeyringLedger`，schema v1，原子 setMeta）
- 公开 API：`createNew` / `unlockLocal` / `unlockFromRemoteManifest` / `isInitialized` / `getVaultId` / `getEncryptedDataKey` / `verifyPassword` / `changePassword`（返回新实例，keyVersion+1）/ `checkMigrationNeeded` / `migrateToRemote`（同 vault 换 dataKey）/ `migrateToRemoteVault`（场景 d 整体切换）/ `tryDeriveRemoteDataKey` / `toManifestHeader`（header 唯一出口）/ `persist`
- 迁移事务化（B1）：`database.reEncryptAllNotesAtomically(oldKey, newKey, keyringJson, markBlobReupload)` 同一事务内完成重加密 + 账本 upsert + blob 重传标记
- CLI 可复用：**是**

### 4.7 Journal（P2 操作日志）
- 位置：`Journal.open(baseDir, vaultId, deviceId)`（SyncService 生命周期内单实例，跨 SyncEngine 重建保持 seq 连续）；journal 文件 + 远端副本（`journal.syncToRemote(backend, dataKey)` 加密上传，永不阻断同步）
- 事件类型：`keyChangePassword` / `syncOptimisticLockRetry` / `syncManifestRebuild` / `syncManifestPut` / key.migrate 等；`findIncompleteOperations` 启动自检只报告不重放

### 4.8 同步设置 UI
- 页面：`lib/views/settings/sync_settings.dart`（路由 `/syncSettings`）
- 功能：后端类型选择（`SyncConfig.setBackendType`）、LocalFs 路径（`FilePicker.getDirectoryPath` → `setLocalFsPath`）、WebDAV URL/用户名/密码（`_showTextEditor` → `setWebdavUrl`/`setWebdavUsername`/`setWebdavPassword`）、SafeServer URL/Token、自动同步开关（`setAutoSyncEnabled`）、立即同步（`initBackend` + `sync`）、修复同步数据（`repairRemote`）、Keyring 状态展示

---

## 功能域 5：备份 / 导入

### 5.1 自动/手动备份
- 文件：`lib/utils/scheduled_task.dart` + `lib/models/file_handler.dart`
- 调用链：`ScheduledTask.backup()`（受 `isBackupOn` + `isBackupNeeded` 门控，`maxBackupRetryAttempts` 默认 50 次重试循环）→ `unitBackupAttempt()` → `androidBackup()`/`iosBackup()` → `FileHandler.encryptedOutputBackupContent()` → `NotesDatabase.instance.exportAll()` → 组 JSON `{records, recordHandlerHash:"plaintext-v1", total}`（**明文导出**，密码校验已移除，见 `docs/登录验证简化方案-20260729.md`）→ 写入 `SafeNotesConfig.androidBackupDirectory`（`/storage/emulated/0/Download/Safe Notes/`，失败回退应用私有目录）或 iOS 文档目录 → `MediaScanner.loadMedia` → `setLastBackupTime()` + `setIsBackupNeeded(false)`
- 备份文件名：`safenotes_backup.json`（冗余计数>0 时 `safenotes_backupN.json`）
- 触发时机：登出时、应用 inactive 时（`AppLifecycleEventHandler`）、升级后（`onAppUpdate`）、改密码前置检查（`forceBackup` 绕过开关）
- CLI 可复用：**否**（path_provider + media_scanner + 平台目录常量；核心 `exportAll` 纯 Dart 可复用）

### 5.2 导入
- 页面：`lib/models/file_handler.dart` `selectFileAndImport(context)` + `lib/dialogs/confirm_import.dart`
- 调用链：`getFileAsString()`（Android ≥29 用 `FileType.custom` json 扩展名 + `CacheManager.emptyCache`）→ `jsonDecode` → `ImportParser.fromJson` → `confirmImportDialog`（条数确认）→ `insertNotes(List<SafeNote>)`（逐条 `storeNote`）
- 明文备份不校验密码：`ImportEncryptionControl.setIsImportEncrypted(false)` + `destroyImportCredentials()`
- CLI 可复用：**否**（file_picker；`ImportParser` + `storeNote` 纯 Dart 可复用）

### 5.3 备份设置 UI
- 页面：`lib/views/settings/backup_setting.dart`（路由 `/backup`）：开关（`setIsBackupOn` + 开启即 `onBackupNow`）、上次备份时间、位置展示（Android 提示 / iOS 可 `launchUrl('shareddocuments://')` 打开）、立即备份按钮（`handleBackupPermissionAndLocation` + `ScheduledTask.backup`）

---

## 功能域 6：设置与偏好

### 6.1 偏好存储 `PreferencesStorage`（`lib/data/preference_and_config.dart`）
- 主题：`isThemeDark`（含系统跟随 `isSystemDarkLightSwitchEnabled`）、`isDimTheme`、`darkThemeEnum`
- 安全：`isFlagSecure`（防截屏）、`keyboardIncognito`（键盘无痕）、`noOfLogginAttemptAllowed`、`bruteforceLockOutTime`、`isInactivityTimeoutOn`/`inactivityTimeout`、`isBiometricAuthEnabled`
- 显示：`isGridView`、`isNewFirst`、`isColorful`/`colorfulNotesColorIndex`、`isCompactPreview`、`isAutoRotate`
- 备份：`isBackupOn`、`isBackupNeeded`、`lastBackupTime`、`maxBackupRetryAttempts`、`backupRedundancyCounter`
- 其他：`appVersionCode`、`biometricAttemptAllTimeCount`、`clearVaultRelatedKeys()`（逃生通道）
- CLI 可复用：**需注入端口**（shared_preferences）

### 6.2 设置页面路由（`route_generator.dart`）
`/settings`（`settings.dart`）→ 子页：`/chooseColorSettings`（ColorPallet）、`/inactivityTimerSettings`、`/chooseLanguageSettings`（14 语言）、`/secureDisplaySetting`、`/biometricSetting`、`/autoRotateSettings`

### 6.3 常量配置 `SafeNotesConfig`
版本 2.3.0 / code 10；Android 备份目录 `/storage/emulated/0/Download/Safe Notes/`；导入扩展名 `json`；14 种语言；各 URL（github/faq/反馈/bug 报告/play store）

---

## 功能域 7：诊断与日志

### 7.1 日志系统（`app_logger.dart`，纯 Dart 可编译）
- 三路输出：console + 内存环形缓冲（`AppLogBuffer`，容量 2000，`stream` 实时推送）+ 文件（`AppLogFile`，`safenotes-YYYYMMDD.log`，按日滚动保留 7 天）
- 注入点：`logDirResolverOverride`（`Future<String?> Function()?`，App 注入 path_provider、CLI 注入临时目录，null 时降级 console+缓冲）
- 编译期常量 `kDebugMode/kReleaseMode/kProfileMode`（`bool.fromEnvironment`）替代 Flutter 的 kDebugMode → 保证纯 Dart 可编译
- 格式：`2026-07-31 17:42:03.123 [INFO ] [NOTE] msg`；分类 tag（NOTE/SYNC/AUTH/DB/BACKUP/CRYPTO/UI/WEB/SETTINGS/APP）；`_maxStackFrames = 12`
- **隐私红线**：日志只记 uuid/长度/hash 前缀/时间戳，绝不记标题正文与密码
- CLI 可复用：**是**

### 7.2 日志 Web 服务器（`log_webserver.dart`，纯 Dart）
- `LogWebServer.instance` 全局单例；`start({port = 8888})` 端口占用自动 +1 最多 10 次；`stop()`
- 端点：`/`（HTML 实时查看器 + WebSocket）、`/logs`（内存全量文本）、`/logfile`（当天文件下载，防目录穿越）、`/files`（JSON 列表）、`/diagnostics`（诊断快照，`diagnosticsProvider` 注入）、`/stream`（WebSocket 实时推送，先补发历史）
- 生命周期：HomePage initState 启动（幂等），main.dart `_shutdown` 停止；绑 0.0.0.0，日志不含敏感信息
- CLI 可复用：**是**

### 7.3 调试面板（`sync_diagnostics_page.dart`，路由 `/diagnostics`）
- 5 Tab：
  1. **状态**：`SyncService.getDiagnosticsSnapshot()`（`SyncDiagnosticsSnapshot`）——同步状态/后端配置（含 providerKey）/Keyring 元数据（vaultId/keyVersion/dataKeyEpoch/kdf）/设备 ID/日志目录；可复制、可导出诊断+日志
  2. **同步结果**：`lastResult` 统计（uploaded/downloaded/deleted/conflicts/migrated/skipped）、`failedNoteUuids`、`requiresRelogin`、错误信息
  3. **操作记录**：`SyncAction` 列表（type/uuid/hash/message/errorLabel/errorDisplay），过滤 skip
  4. **日志**：实时 logcat 风格查看器，级别过滤（`AppLogLevel`）、自动滚动、复制、导出、清空内存缓冲
  5. **Web 服务器**：启停 + 状态（本机 IP:port）、安全提示

### 7.4 设备 ID（`lib/utils/device_id.dart`）
- `DeviceIdProvider.instance.getDeviceId()` → `<platform>-<id>`（android/ios/windows/macos/linux/unknown）
- 用途：manifest header `lastModifiedBy`；诊断"哪个设备最后修改"；`overrideForTesting` / `clearTestingOverride` 供测试
- CLI 可复用：**否**（device_info_plus；但已有测试注入点）

---

## CLI 可复用性总表（`bin/safenotes_cli.dart`）

当前 CLI 已示范：`db info` / `note add`（注入 `databaseFactoryFfi` + `dbPathOverride` + `logDirResolverOverride` + `setDataKey`）。

| 能力 | CLI 直接可复用 | 需注入端口 |
|---|---|---|
| 笔记 CRUD / 回收站 / 导出 | ✅ 全部（NotesDatabase 纯 Dart） | `dbFactoryOverride`/`dbPathOverride` |
| 加密 / Keyring / dataKey 迁移 | ✅ | 无 |
| SyncEngine / Journal / 三后端 | ✅ | journal 目录解析（可注入） |
| 日志三路输出 + Web 服务器 | ✅ | `logDirResolverOverride` |
| SyncConfig / PreferencesStorage | ❌ | shared_preferences + flutter_secure_storage |
| 生物识别 / 会话超时 | ❌ | local_auth / local_session_timeout |
| 文件选择 / 媒体扫描 / 平台备份目录 | ❌ | file_picker / media_scanner / path_provider |

## 跨域联动注意
- 几乎所有"写"操作（增删改、恢复、硬删）后都调用 `SyncService.instance.autoSync()`（3 秒 debounce）
- 主界面 `_onSyncStateChanged`：同步完成态刷新列表 + 失败笔记提示 + `requiresRelogin` 强制重登录弹窗（防弹窗轰炸 `_passwordChangedDialogShown`）
- 改密码是唯一触发 `forceBackup` + 强制 `sync()` + journal `keyChangePassword` 的复合流程

---

## 附：本次调研的关键事实（FAQ）

- **SyncEngine 同步 5 步**：GET manifest（仅 header）→ schema 降级拒绝 → dataKeyFingerprint 判定（他端改密码=requiresRelogin 中止）→ buildLocalManifest（含 30 天墓碑 GC）→ mergeAndTransfer 三层合并
- **同步冲突策略**：LWW（updatedAt 大者胜，相等 hash 字典序小者），差异 >5 分钟保留败方副本
- **三个后端 providerKey**：`hashString('localFs:$rootPath')` / `hashString('webdav:$_userBaseUrl')` / `hashString('safeServer:$baseUrl')`，均 substring(0,16)
- **WebDAV 数据物理路径**：`<userUrl>/safenotes-vault/`，注释明确警告勿随 Vault→Keyring 改名而改
- **备份格式**：明文 JSON `{records, recordHandlerHash:"plaintext-v1", total}`（密码校验已移除）
- **日志隐私红线**：只记 uuid/长度/hash 前缀，绝不记标题正文与密码
- **迁移事务化 B1**：`reEncryptAllNotesAtomically` 单事务完成重加密 + keyring 账本 upsert + blob 重传标记
