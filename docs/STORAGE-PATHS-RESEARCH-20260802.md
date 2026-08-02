# SafeNotes 客户端存储路径调研

> 调研日期：2026-08-02
> 应用包名（Android）：`com.trisven.safenotes`（取自 `SafeNotesConfig.playStoreUrl`）
> 调研范围：数据库、业务数据（同步/密钥环/journal）、配置、日志、临时文件与导出备份文件

所有路径均来自对 `lib/` 下源码的核实，路径解析依赖以下系统 API：

- `path_provider`：`getApplicationSupportDirectory` / `getTemporaryDirectory` / `getApplicationDocumentsDirectory`
- `sqflite`：`getDatabasesPath`（数据库文件专用）
- `shared_preferences`：轻量配置（非敏感）
- `flutter_secure_storage`：敏感凭据（H3 修复后迁移至此）

---

## 1. 总览

| 类别 | 文件 / 目录名 | 解析 API | 是否加密 |
|------|--------------|----------|----------|
| 数据库 | `safenotes_sync.db` | `getDatabasesPath()` | 字段级加密（title/description AES-256-GCM） |
| 密钥环账本 | 在 DB 的 `sync_meta` 表（单键 `keyring`） | `getDatabasesPath()` | 包裹态（encryptedDataKey） |
| 同步 journal | `<supportDir>/journal/` | `getApplicationSupportDirectory()` | 明文 JSON（仅记录密钥态事件） |
| 本地同步数据 | `<rootPath>/manifest.json`、`blobs/`、`blobs-orphan/`、`manifest-backup/` | `SyncConfig.localFsPath`（用户配置） | 加密 blob + 加密 manifest |
| 配置（非敏感） | `SharedPreferences` 存储 | `SharedPreferences` | 否 |
| 配置（敏感凭据） | `flutter_secure_storage` | 系统 Keystore/Keychain/DPAPI | 是 |
| 日志 | `safenotes-YYYYMMDD.log` | `exe同目录/logs` 或 `getApplicationSupportDirectory()` | 明文（禁止写笔记明文） |
| 临时文件 | `getTemporaryDirectory()` | `getTemporaryDirectory()` | 否 |
| 自动备份 | `safenotes_backup.json` | `getApplicationDocumentsDirectory()`（Android 可落到 Download） | 当前为明文 JSON（见代码注释 `plaintext-v1`） |

---

## 2. 数据库（Database）

- **文件名**：`safenotes_sync.db`
- **解析 API**：`NotesDatabase._initDB` → `getDatabasesPath()`（sqflite）
- **源码**：`lib/data/database_handler.dart`
- **Schema**：version 3，两张表
  - `notes`：笔记主体，`title`/`description` 字段级 AES-256-GCM 加密（以 `uuid` 作为 AAD），其余为明文元数据（uuid/contentHash/deleted/updatedAt/synced 等）
  - `sync_meta`：键值表，存放密钥环账本（单键 `keyring` JSON）、`purged_uuids`、`blob_reupload_pending`、`gc_orphan_candidates`、各后端 `manifest_version:<providerKey>`
- **删除**：`NotesDatabase.deleteDbFile()`（忘记密码逃生通道），须先 `close()` 释放文件锁
- **⚠️ 桌面端路径纠正（重要）**：Windows / Linux / macOS 的桌面构建走 `sqflite_common_ffi`（`main.dart` 中 `databaseFactory = databaseFactoryFfi`，且未覆盖 `getDatabasesPath`）。其默认实现（`sqflite_ffi_impl_io.dart:89`）返回：
  ```dart
  absolute(join('.dart_tool', 'sqflite_common_ffi', 'databases'))
  ```
  即**相对于进程当前工作目录（CWD）**，而非应用数据目录。这意味着：
  - `flutter run` / 开发期：`C:\Home\Projects\safenotes\.dart_tool\sqflite_common_ffi\databases\safenotes_sync.db`（已在本机验证存在）
  - 打包后的桌面程序：`<exe 所在目录>\ .dart_tool\sqflite_common_ffi\databases\safenotes_sync.db`（CWD 通常为 exe 目录）
  - **后果**：数据库位置随启动 CWD 变化；这与日志优先写 exe 同目录的设计一致。
- **✅ 已修复（Windows）**：`main.dart` 桌面初始化块中，在 `databaseFactory = databaseFactoryFfi` 之后、首次访问数据库**之前**，针对 Windows 显式调用：
  ```dart
  final supportDir = await getApplicationSupportDirectory();
  await databaseFactory.setDatabasesPath(supportDir.path);
  ```
  从而把 Windows 的数据库目录从默认的相对 CWD 路径**覆盖为应用支持目录**（`%APPDATA%\<app>`）。修复后：
  - **Windows（修复后）**：`%APPDATA%\<app>\safenotes_sync.db`（即 `C:\Users\<user>\AppData\Roaming\<app>\safenotes_sync.db`）
  - macOS / Linux **仍未覆盖**，依旧是上述相对 CWD 的 `.dart_tool/...` 默认路径（如需统一，可把 `setDatabasesPath` 的 `if (Platform.isWindows)` 改为桌面通用判断）。
- **平台典型位置**：
  - Android：`/data/data/com.trisven.safenotes/databases/safenotes_sync.db`（Context.getDatabasePath，正确）
  - iOS：`<App>/Documents/safenotes_sync.db`（sqflite_darwin 用 `NSDocumentDirectory`，正确）
  - **Windows（修复后）**：`%APPDATA%\<app>\safenotes_sync.db`（**不是** 相对 CWD 的 `.dart_tool/...`）
  - **macOS**：`~/Documents/safenotes_sync.db`（sqflite_darwin 用 `NSDocumentDirectory`，**不是** `~/Library/Application Support`）
  - **Linux**：`<CWD>\ .dart_tool\sqflite_common_ffi\databases\safenotes_sync.db`（与 Windows 修复前同理，CWD 相对）

---

## 3. 业务数据 / 同步数据（Data）

分三个子区域：

### 3.1 应用支持目录（始终存在）
- **API**：`getApplicationSupportDirectory()`（由 `SyncService._openJournal` 调用）
- **journal 目录**：`<supportDir>/journal/`
  - `log.json`：当前进程的操作日志（两阶段操作审计）
  - `.journal-state.json`：远端上传水位（`uploadedSeq`）
  - `log-{seq}.json`：归档日志副本
  - `log.json.corrupt-<ts>`：损坏隔离文件（用于取证，不阻断同步）
- **密钥环（Keyring）**：**不落独立文件**，持久化在数据库 `sync_meta` 表的 `keyring` 单键（包裹态 JSON）。`dataKey` / `mk` 为运行时内存字段，logout 即丢弃，不持久化。

### 3.2 本地同步后端（LocalFs，可选）
- **启用条件**：`SyncConfig.backendType == localFs`
- **根路径**：`SyncConfig.localFsPath`（键名 `sync_localfs_path`，存于 `SharedPreferences`，由用户在设置中选择，默认空）
- **目录结构**（`lib/sync/local_fs_backend.dart`）：
  - `manifest.json`：加密 manifest（密钥态头部）
  - `blobs/`：按内容 hash 寻址的加密 blob（笔记正文）
  - `blobs-orphan/`：孤儿 blob 两阶段 GC 隔离区
  - `manifest-backup/`：manifest 备份
  - `journal/`：该后端独立的 journal

### 3.3 远端同步后端（WebDAV / SafeServer）
- 数据存于远端服务器，**本地无文件**，仅凭据经 `flutter_secure_storage` 本地保存（见 §4.2）。

---

## 4. 配置（Config）

### 4.1 非敏感配置 —— `SharedPreferences`
- **类**：`PreferencesStorage`（UI 偏好）、`SyncConfig`（同步开关/路径/URL）
- **典型平台位置**：
  - Android：`/data/data/com.trisven.safenotes/shared_prefs/*.xml`
  - iOS：`<App>/Library/Preferences/<bundle>.plist`
  - 桌面：应用支持目录下的 SharedPreferences 存储文件
- **PreferencesStorage 关键键**：主题（`isthemedark` 等）、`isGridView`、`isNewFirst`、`isBiometricAuthEnabled`、`inactivityTimeout`、`isBackupOn`、`lastBackupTime`、`appVersionCode` 等
- **SyncConfig 关键键**：`sync_backend_type`、`sync_localfs_path`、`sync_webdav_url`、`sync_webdav_username`、`sync_safeserver_url`、`sync_auto_sync`

### 4.2 敏感凭据 —— `flutter_secure_storage`（H3 修复）
- **存储内容**：WebDAV 密码（`sync_webdav_password`）、SafeServer Token（`sync_safeserver_token`）
- **平台安全后端**：
  - Android：EncryptedSharedPreferences（Keystore）
  - iOS：Keychain
  - Windows：DPAPI
  - macOS：Keychain
  - Linux：libsecret（SecretService）
- **源码**：`lib/sync/sync_config.dart`

---

## 5. 日志（Logs）

- **类**：`AppLogFile`（`lib/utils/app_logger.dart`）
- **目录解析逻辑**（`_resolveLogDir`）：
  1. 桌面端优先：`<exe 可执行文件所在目录>/logs/`
  2. 若该目录不可写（如安装在 `Program Files`）→ 回退 `<supportDir>/logs/`
  3. 移动端：`getApplicationSupportDirectory()` 下的 `logs/`
- **文件命名**：`safenotes-YYYYMMDD.log`，按日期滚动，保留最近 **7 天**（`_keepDays = 7`）
- **输出三路**：① 文件（持久化）② 内存环形缓冲（2000 条，调试面板/日志 WebServer）③ console（仅 Debug 模式）
- **隐私红线**：日志中**禁止**出现笔记标题/正文明文，仅记录 uuid、内容长度、contentHash 前缀、时间戳、影响行数（见 `database_handler.dart` 头部注释）
- **附加**：`log_webserver.dart` 可将日志目录以 HTTP 形式对外提供（远程查看，不新增存储）

---

## 6. 临时文件（Temp）与导出/备份文件

### 6.1 临时目录
- **API**：`getTemporaryDirectory()`
- **使用点**：`CacheManager.emptyCache()` —— 清空并重建该目录（如"清除缓存"功能）
- **平台典型位置**：
  - Android：`/data/data/com.trisven.safenotes/cache`
  - iOS：`NSTemporaryDirectory()`
  - Windows：`%LOCALAPPDATA%\Temp\<app>` 或系统临时目录子目录
  - macOS：`NSTemporaryDirectory()`
  - Linux：`/tmp` 下的应用子目录

### 6.2 自动备份文件（ScheduledTask）
- **Android**：默认写入 `SafeNotesConfig.androidBackupDirectory` =
  `/storage/emulated/0/Download/Safe Notes/safenotes_backup.json`
  （权限不足时回退到 `getApplicationDocumentsDirectory()` → `/storage/emulated/0/Android/data/com.trisven.safenotes/files/`）
- **iOS**：`getApplicationDocumentsDirectory()` → `<App>/Documents/safenotes_backup.json`
- **文件名**：`safenotes_backup.json` 或带冗余计数 `safenotes_backup<N>.json`
- **内容**：当前为**明文** JSON（代码注释标明 `plaintext-v1`，完整加密改造待做）

### 6.3 手动导出/导入
- 通过 `file_picker` 由用户自选位置，无固定路径；导出内容同样为明文 JSON（`FileHandler.exportAll`）。

---

## 7. 平台路径速查（path_provider 基础目录）

| path_provider API | Android | iOS | Windows | macOS | Linux |
|-------------------|---------|-----|---------|-------|-------|
| `getApplicationSupportDirectory` | `/data/data/<pkg>/files` | `<App>/Library/Application Support` | `%APPDATA%\<app>` | `~/Library/Application Support/<bundle>` | `~/.local/share/<app>` |
| `getTemporaryDirectory` | `<pkg>/cache` | `NSTemporaryDirectory()` | `%LOCALAPPDATA%\Temp\<app>` | `NSTemporaryDirectory()` | `/tmp/<app>` |
| `getApplicationDocumentsDirectory` | `/storage/emulated/0/Android/data/<pkg>/files` | `<App>/Documents` | `Documents` | `~/Documents` | `~/Documents` |
| `getDatabasesPath`（sqflite） | `<pkg>/databases` | `<App>/Documents` | `%APPDATA%\<app>`（**已修复**，见 §2） | `~/Documents` | `<CWD>/.dart_tool/sqflite_common_ffi/databases` |

> 注：桌面端 `getDatabasesPath`（Windows / Linux / macOS）**实际默认是相对于进程 CWD 的 `.dart_tool/sqflite_common_ffi/databases`**（sqflite FFI 默认实现）。Windows 已在 `main.dart` 中通过 `databaseFactory.setDatabasesPath(getApplicationSupportDirectory())` 覆盖为 `%APPDATA%\<app>`；macOS 为 `~/Documents`（sqflite_darwin 用 `NSDocumentDirectory`，因 `databaseFactory` 被 FFI 覆盖，实际同样走 CWD 相对路径，待统一）；Linux 仍为 CWD 相对路径。Android 为系统 databases 目录、iOS 为 App Documents 目录，均正确。

---

## 8. 安全与隐私要点

1. **笔记正文加密**：`notes` 表的 `title`/`description` 字段级 AES-256-GCM，密钥 `dataKey` 仅在内存，由 Keyring 在登录时注入。
2. **密钥环不落地明文**：`keyring` 账本仅保存 `encryptedDataKey`（MK 包裹态），`dataKey`/`mk` 不持久化。
3. **凭据隔离**：WebDAV 密码 / SafeServer Token 使用系统级安全存储（Keystore/Keychain/DPAPI/libsecret），不进 SharedPreferences。
4. **日志脱敏**：日志禁止记录笔记明文，仅保留非敏感元数据（隐私优先设计）。
5. **逃生通道**：忘记密码时 `deleteDbFile()` + `clearVaultRelatedKeys()` 可彻底清除本地数据（不可恢复，以 FATAL 级留痕）。

---

## 9. 关键源码索引

| 关注点 | 文件 |
|--------|------|
| 数据库 schema / 加密 / 删除 | `lib/data/database_handler.dart` |
| 密钥环（Keyring）持久化 | `lib/sync/keyring.dart` |
| 同步 journal 路径 | `lib/sync/journal.dart` |
| 本地同步后端目录结构 | `lib/sync/local_fs_backend.dart` |
| 同步配置（含凭据存储） | `lib/sync/sync_config.dart` |
| 日志目录解析 | `lib/utils/app_logger.dart` |
| 临时目录 / 缓存清理 | `lib/utils/cache_manager.dart` |
| 配置与常量（含路径常量） | `lib/data/preference_and_config.dart` |
| 自动备份 / 导出落盘 | `lib/utils/scheduled_task.dart`、`lib/models/file_handler.dart` |
| 设备 ID（运行时计算，不落盘） | `lib/utils/device_id.dart` |
