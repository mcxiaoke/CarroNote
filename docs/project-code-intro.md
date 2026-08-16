# SafeNotes 代码与模块结构介绍

> 本文档全面介绍 SafeNotes 项目的代码结构、模块职责与关键设计。
> 适用版本：`3.0.0+30000`（GPL-3.0-or-later）。
> 阅读对象：新接手开发者、代码审计者、架构评审者。

---

## 1. 项目概览

SafeNotes 是一个**端到端加密的跨平台私密笔记应用**，支持 Android / iOS / Windows / Linux / macOS / Web。
所有笔记正文在落库（本地 SQLite）与同步（远端）前都已被 `dataKey`（AES-256-GCM）加密，服务器/同步后端永远看不到明文。

核心工程特征：**Dart pub workspace 双层架构** —— 把"与 Flutter 无关的核心逻辑"抽成独立的纯 Dart 包 `packages/core`，
应用层 `lib`（Flutter UI + 装配）只依赖它。编译器强制 `core` 包**不能 import 任何 Flutter 依赖**，
因此核心逻辑既能被 App 复用，也能被纯 Dart CLI（`bin/`）复用，还便于脱离 UI 做单元测试。

```text
safenotes/
├── lib/                  # 应用层（Flutter UI + 服务装配）
├── packages/core/        # 核心层（纯 Dart：加密 / 数据库 / 同步引擎 / 模型 / 日志）
├── bin/                  # 纯 Dart CLI 前端（核心逻辑的第二个消费者）
├── server/               # SafeServer 同步后端参考实现（Go + Node.js 两套）
├── test/                 # 应用层测试（widget / 流程）
├── packages/core/test/   # 核心层测试（同步混沌 / 多设备 / 加密）
├── assets/               # 图标、字体、调试面板 dashboard.html
├── docs/                 # 设计文档与变更记录
└── pubspec.yaml          # 声明 workspace + 主应用依赖
```

---

## 2. 技术栈

| 领域 | 选型 |
|------|------|
| 语言 / SDK | Dart `>=3.12.0`、Flutter `>=3.44.0` |
| 状态管理 | Provider（`ThemeProvider`、`NotesColor`、`SessionTimeoutManager` 等） |
| 路由 | 集中式 `RouteGenerator`（MaterialPageRoute，适配 animations 的 OpenContainer 转场） |
| 数据库 | `sqflite_common_ffi`（桌面/CLI 走 FFI，移动端走原生 sqlite），schema v4 |
| 加密 | `cryptography` + `cryptography_flutter`（原生加速：AES-GCM、Argon2id、PBKDF2、SHA-256） |
| 本地安全存储 | `flutter_secure_storage`（WebDAV 密码 / SafeServer Token） |
| 配置持久化 | `shared_preferences`（`PreferencesStorage` 封装） |
| 国际化 | `easy_localization`（资产在 `assets/translations`） |
| 设计系统 | `shadcn_ui`（ShadApp）＋ `flex_color_scheme`（MaterialApp）双轨并行 |
| 会话超时 | `local_session_timeout`（`SessionTimeoutManager` 监听空闲锁定） |
| CLI 参数解析 | `args`（`CommandRunner` + 子命令） |
| 同步后端（自托管） | SafeServer：`http` + 固定 Bearer Token（Go / Node.js 参考实现） |

---

## 3. 整体架构（双层 + 端口模式）

```
┌─────────────────────────────────────────────────────────────┐
│  Flutter 应用层  lib/                                        │
│  main / app / authwall / routes / views / widgets / dialogs  │
│  sync/service / config · utils · models · log_webserver       │
│            │ 依赖（import 'package:core/core.dart'）          │
└────────────┼──────────────────────────────────────────────────┘
             ▼
┌─────────────────────────────────────────────────────────────┐
│  核心层  packages/core/  （纯 Dart，零 Flutter 依赖）         │
│  crypto · db · models · sync{engine,keyring,journal,backend}  │
│  logger · ports                                              │
│            │ 通过 ports 抽象访问"平台能力"                     │
└────────────┼──────────────────────────────────────────────────┘
             ▼
   PathProvider / KeyValueStore / SecretStore / LogSink
   （应用层用 path_provider / shared_preferences / secure_storage 实现）
```

- **核心层** 只定义 *抽象接口*（`ports.dart` 的 `PathProvider` / `KeyValueStore` / `SecretStore` / `LogSink`），
  具体实现由应用层注入。这样核心层可单测、可 CLI 化、不耦合 Flutter 插件。
- **应用层** 是"装配者"：把 `Keyring` + `SyncBackend` + `SyncEngine` 拼成 `SyncService`，把 UI 事件翻译成核心层调用。

---

## 4. 核心层 `packages/core`（纯 Dart）

统一出口为 `packages/core/lib/core.dart`，导出以下模块：

```
src/crypto/crypto.dart       # SyncCrypto：AES-GCM / MK 派生 / dataKey 包裹 / B-KEY
src/db/database_handler.dart  # NotesDatabase：字段级加密 + 软删除 + sync_meta
src/models/safenote.dart      # SafeNote 数据模型 + 内容哈希
src/models/backup_file.dart   # BackupFileCodec：明文 .json / 加密 .snbak 编解码
src/models/parse_import.dart  # ImportParser：snbak v1 文件头解析
src/ports.dart               # 平台能力抽象接口
src/sync/sync_engine.dart     # SyncEngine：5 步同步主流程（约 2874 行）
src/sync/keyring.dart         # Keyring / KeyringLedger：密钥单一真相源
src/sync/journal.dart         # Journal：操作日志（P2 设计）
src/sync/sync_backend.dart    # SyncBackend 抽象接口 + 异常 + 环形备份
src/sync/sync_models.dart     # Manifest/Item/Header、KdfParams、ManifestCrypto(v5)
src/sync/sync_error.dart      # SyncError sealed 体系
src/sync/backends/            # local_fs / webdav / safe_server 三种实现
src/logger/app_logger.dart    # AppLog / Log / 三路输出
```

### 4.1 加密 `crypto.dart`

`SyncCrypto` 是全部密码学操作的汇聚点：

- **AES-256-GCM 信封**：`nonce(12) ‖ ciphertext ‖ tag(16)`，AAD 在 v5 epoch 后恒为内容哈希。
- **MK（主密钥）派生** `deriveMasterKeyAsync`：
  - 新 vault 用 **Argon2id**（`memory=32MiB, t=3, p=2`）；
  - 存量 vault 回退 **PBKDF2-HMAC-SHA256（200k 迭代）**。
  - 每 vault 随机 `salt` 随 manifest header 传播。
- **dataKey 包裹/解裹**：`wrapDataKey(dataKey, mk)` / `unwrapDataKey(...)`，即 MK 加密 32 字节随机 dataKey。
- **备份 B-KEY**：从密码派生，用于 `.snbak` 文件级加密。
- 常数时间 `bytesEqual`，防时序侧信道。

### 4.2 数据库 `database_handler.dart`

`NotesDatabase`（schema v4）是本地唯一真相源：

- 表 `notes`：`uuid / content_hash / title / description / deleted / createdTime / updatedAt / synced / synced_hash / synced_deleted`
  （v3→v4 走 `onUpgrade` 的 `ALTER TABLE` 加 `synced_deleted` 列）。
- **字段级 AES 加密**：`title` / `description` 落库前用 dataKey 加密，读取时解密；`dataKey` 缺失则抛 `DataKeyNotSetException`。
- **软删除**：`deleted=1` 为墓碑，不物理删行；回收站视图按 `deleted` 过滤。
- **同步收敛元信息**：`synced / synced_hash / synced_deleted` 描述"上一次与远端一致时的 (hash, deleted) 二元组"，
  是 sync_engine 三方合并判定 base 的关键（`src/db/database_handler.dart` 注释详述）。
- 附带 `queryTableRows` / `inspectMetadata` 供调试面板 Database Inspector 使用。
- 测试用 `createDBForTesting` 可注入任意 schema 版本。

### 4.3 模型

- **`SafeNote`**：`computeHash(title, description)`（JSON `{"v":2,"title","description"}`）、
  `toContentBytes` / `fromContentBytes`、`generateUuid`（UUIDv4）、字段 `uuid/contentHash/deleted/createdTime/updatedAt/synced/syncedHash/syncedDeleted`。
- **`BackupFile` / `BackupFileCodec`**：`plaintext-v1`（明文 `.json`）与加密 `.snbak`（AES-256-GCM + Argon2id/PBKDF2 B-KEY）两套格式编解码。
- **`ImportParser` / `BackupHeader`**：解析 snbak v1 文件头。

### 4.4 同步引擎 `sync_engine.dart`

`SyncEngine` 是整套同步的大脑，核心方法 `_syncOnce` 实现 **5 步流程**：

1. `GET manifest` —— 仅解析 header（`ManifestCrypto.deserializeHeaderOnly`）。
2. 构建本地 manifest。
3. 逐条比对（LWW 冲突解决）。
4. 加密合并 manifest + `PUT`（ETag 乐观锁 `If-Match` / `If-None-Match`）。
5. 更新本地同步状态。

关键能力：

- **LWW（Last-Write-Wins）**：`remote.updatedAt > local` → 远端胜；相等且 hash 不同 → 字典序小者胜。
  用 `syncedHash/syncedDeleted` 区分"单边更新"与"真并发冲突"，做三方合并 base 判定。
- **dataKey 迁移分支**：scenario-b（他端改密码，本地 MK 解不开远端包裹 → `requiresRelogin`）、
  scenario-c/d（两设备各自建 vault 后互通，用 `passphraseProvider` 判别远端密码是否一致，必要时迁移 dataKey）。
- **自恢复**：`_recoverFromCorruptRemoteManifest`、`_mergeAndTransfer`、`_withBlobRetry`（指数退避，
  `maxRetries=3`）、`_resolveConflict`。
- **墓碑 GC**：`kTombstoneGcThresholdMs=30天` 清理过期墓碑。

### 4.5 Keyring 方案 B `keyring.dart`

取代旧 `Vault`，成为**密钥单一真相源**：

- `Keyring` / `KeyringLedger`（持久化账本）/ `KeyringEntry`。
- 关键方法：`createNew`（首次生成 dataKey + 包裹）／ `unlockLocal`（密码解 dataKey）／
  `unlockFromRemoteManifest`（用远端包裹解锁）／ `changePassword`（重包裹 dataKey，dataKey 不变 → 笔记无需重加密）／
  `migrateToRemote` / `migrateToRemoteVault` / `verifyPassword`。
- 元数据：vaultId、keyVersion（改密码递增）、dataKeyEpoch（dataKey 变更递增）、keyFingerprint（MK 指纹，用于远端密码验证）、kdf 参数。

### 4.6 Journal 操作日志 `journal.dart`

P2 设计，作为**可审计 + 可恢复的第二数据源**：本地明文 + 远端 AES-GCM 加密副本。
类型（`JournalEventType`：key 变更 / 笔记增删 / 同步边界）与阶段（`JournalPhase`：开始/完成）枚举，
`findIncompleteOperations` 在启动自检时报告"写到一半就挂掉的两阶段操作"（只报告、不自动重放，避免二次损坏）。

### 4.7 同步后端 `sync_backend.dart` + `backends/`

`SyncBackend` 抽象接口（后端无关、纯存储、内容寻址、ETag 乐观锁）：

| 方法 | 语义 |
|------|------|
| `init()` | 建目录 / MKCOL / health 检查（幂等） |
| `ping()` | 轻量在线探测，不抛异常 |
| `getManifest()` | 返回密文 + ETag（空密文=首次） |
| `putManifest(ciphertext, expectedEtag)` | CAS 写入，ETag 不符抛 `ConflictException` |
| `getBlob(hash)` / `putBlob(hash,data)` | 内容寻址 blob（幂等） |
| `deleteBlob` / `listBlobs` | GC 用（后端不支持时 no-op） |

三种实现（存储布局对 SyncEngine 透明）：

- **`LocalFsBackend`**：`<root>/manifest.json` + `<root>/blobs/<hash>`，适合单设备/测试。
- **`WebDavBackend`**：`<userUrl>/safenotes-vault/...`，自动附加子目录。
- **`SafeServerBackend`**：`/api/v2/manifest` + `/api/v2/blob/<hash>`，固定 Bearer Token。

### 4.8 日志 `logger/app_logger.dart`

`AppLog` / `Log` / `AppLogBuffer` / `AppLogFile` 三路输出（console / 内存环形缓冲 / 文件），
全平台统一；分类 `APP/NOTE/DB/AUTH/SYNC/BACKUP/SETTINGS/CRYPTO/WEB/UI`。
`Log.sync.i(...)` 等语法贯穿全代码，是排查同步/密钥问题的主力。

### 4.9 端口抽象 `ports.dart`

`PathProvider` / `KeyValueStore` / `SecretStore` / `LogSink` 抽象 —— 核心层通过这些接口使用平台能力，
应用层用 `path_provider` / `shared_preferences` / `flutter_secure_storage` 实现。

---

## 5. 应用层 `lib`（Flutter）

### 5.1 入口与装配

- **`main.dart`**：`runZonedGuarded` 全局异常捕获；`_bootstrap`（sqflite_ffi 初始化、`SyncConfig.init`、
  `Keyring.isInitialized` 预查询、`AppLifecycleEventHandler`）；`_SafeNotesAppState` 持有 `SessionTimeoutManager`。
- **`app.dart`**：`App`（`MultiProvider` + `ShadApp.custom` + `MaterialApp`）。`initialRoute: '/'` → `AuthWall`。
- **`authwall.dart`**：`AuthWall` 依据 `AppBootState.vaultInitialized` 决定跳转登录页（`/login`）还是设置密码页（`/signup`）。
  `AppBootState` 单例缓存 keyring 初始化状态（登录/改密码成功时即时刷新，避免空闲锁定回 authwall 误判）。
- **`routes/route_generator.dart`**：集中式路由（`/`、`/login`、`/signup`、`/authwall`、`/home`、
  `/addnote`、`/editnote`、`/backup`、`/changepassphrase`、`/syncSettings`、`/diagnostics`、`/deletedNotes`、`/settings` 等）。

### 5.2 配置与状态

- **`data/preference_and_config.dart`**：`PreferencesStorage`（SharedPreferences 封装，主题/安全/备份/同步全部 getter/setter）、
  `PhraseHandler`（会话期密码内存态）、`ImportEncryptionControl` / `ImportPassPhraseHandler`、`SafeNotesConfig`（应用常量 + Locale 映射）。
- **`models/session.dart`**：`Session.login/logout/onPasswordSet` + `SessionArguments`（会话状态流驱动空闲锁定）。
- **`sync/sync_config.dart`**：`SyncConfig`（总开关/后端类型/LocalFs/WebDAV/SafeServer 配置；敏感凭据走 `flutter_secure_storage`）、
  `SyncBackendType`（none/localFs/webdav/safeServer）、`SyncBackendDraft`（配置草稿值对象，`buildBackend()` 按类型构造后端）。
- **`sync/sync_service.dart`**：**同步服务单例**，核心协调者：
  - 持有 `Keyring` / `SyncBackend` / `SyncEngine` / `Journal`（journal 跨重建保持单例，保证 seq 连续）。
  - `SyncStatus` 枚举 + `stateStream`（UI 用 `StreamBuilder` 监听）。
  - **互斥锁**：`sync()` 入口第一行抢锁，避免并发引擎（`_syncInProgress`）。
  - **autoSync**：debounce 3 秒，失败重试一次（防死循环）；处理"sync 被跳过需重排程"等竞态。
  - `initialize / updateKeyring / switchBackend / applyConfigToService / repairRemote / dispose / logout`。
  - 登录流程辅助：`initKeyringFromPassword`（B1：无论是否启用同步都生成/解锁 dataKey）、`initBackend`、`testBackendConfig`。
  - 调试面板数据：`getDiagnosticsSnapshot` / `getDebugJson` / `getMemorySnapshot` / `getJournalDump`（均脱敏 URL/用户名）。

### 5.3 视图 `views/`

- **`home.dart`**：主界面。`StatefulWidget` + `RouteAware`，监听 `SyncService.stateStream`；
  同步完成自动刷新列表、捕获"他端改密码"(`requiresRelogin`)弹强制重登录框；
  AppBar 同步状态按钮（旋转图标）、调试面板入口、网格/列表切换、搜索；
  桌面端 `NavigationRail` + 移动端 `Drawer` 双形态；笔记卡片用 `OpenContainer` 容器放大转场进编辑页。
- **`add_edit_note.dart`**：编辑/新建页。Markdown 预览/编辑切换；`PopScope` 拦截未保存退出（保存/放弃/取消）；
  通过 `NoteEditorState.addOrUpdateNote` 落库并触发 `autoSync`；删除走软删除 + 自动同步。
- **`authentication/login.dart`**：登录页。本地 `Keyring.unlockLocal` 优先；启用同步时远端验证
  （`unlockFromRemoteManifest`，三态 `RemotePasswordResult`）；暴力破解限流 + 锁定倒计时（`_BiometricState`）；
  "忘记密码"逃生通道（清空本地数据重来）；生物识别登录。
- **`authentication/set_passphrase.dart`**：首次设置密码页。`Keyring.createNew` 生成 dataKey + 注入数据库；
  安全守卫拒绝"已初始化却走设置页"的异常路由（防覆盖旧 keyring）；密码强度校验。
- **`change_passphrase.dart`**：改密码页。步骤：校验旧密码 → 前置检查（强制备份/同步/服务器 ping）→
  `keyring.changePassword`（推进 keyVersion，dataKey 不变）→ `updateKeyring`（重建引擎）→ 推送新密钥到远端。
- **`deleted_notes.dart`**：回收站。单条恢复（撤墓碑）/ 永久删除（hardDelete）/ 清空全部。
- **`settings/`**：`settings` / `theme_setting` / `notes_color_setting` / `language_setting` /
  `biometric_setting` / `inactivity_setting` / `backup_setting` / `sync_settings` / `sync_backend_config_page` / `sync_diagnostics_page`。

### 5.4 控件与对话框 `widgets/` + `dialogs/`

- **widgets**：`drawer` / `footer` / `home_navigation_rail` / `note_card`(+compact) / `note_tile`(+compact) /
  `note_widget`（纯展示卡片）/ `search_widget` / `shad_dialog` / `shad_nav_items` / `shad_settings_tiles`。
- **dialogs**：`backup_import` / `backup_passphrase` / `backup_password_input` / `confirm_import` /
  `delete_confirmation` / `export_backup_dialog` / `generic` / `logout_alert`（全部统一用 `ShadDialog`）。

### 5.5 模型、工具、日志服务

- **`models/`**：`editor_state`（`NoteEditorState`：保存互斥守卫，超时自动保存草稿）、
  `session` / `app_theme` / `shad_theme` / `biometric_auth` / `file_handler`。
- **`utils/`**：`app_scroll_behavior` / `build_info`(生成) / `cache_manager` / `device_id` / `device_info` /
  `lifecycle_handler` / `notes_color` / `passphrase_util`(强度估计) / `platform_ui` / `route_observer` /
  `scheduled_task`(定时备份) / `snack_message` / `storage_permission` / `string_utils` / `styles` /
  `text_direction_util` / `time_utils` / `url_launcher` / `window_title_bar`。
- **`src/logger/log_webserver.dart`**：**日志 HTTP 服务器**（全平台单例，默认端口 8888）。
  进入主界面即启动、应用退出才停止。端点：`/`（实时日志查看器 HTML）、`/logs`、`/logfile`、`/panel`（调试面板 dashboard）、
  `/stream`（WebSocket）、`/api/status|sync|actions|memory|db|prefs`、`/api/download/{db,sp,journal}`。
  绑定 `0.0.0.0`（局域网），诊断 JSON 已过滤敏感凭据，URL/用户名脱敏。

---

## 6. 密钥与加密生命周期（端到端）

```
                ┌─────────────── 本地 ───────────────┐         ┌──── 远端 ────┐
用户输入密码 → KDF(password, salt) → MK
                                   │
                          wrap(dataKey, MK)        ── encryptedDataKey ──▶ manifest header
                                   │                                        (vaultId/kdf/fp/keyVersion/epoch)
                          dataKey (随机32字节, 永不变)
                                   │
                    AES-256-GCM(dataKey) 加密笔记正文 ── blob(内容寻址 hash) ──▶ blobs/<hash>
                                                     合并 manifest ─────────▶ manifest(encrypted)
```

- **两层密钥**：MK 改密码时变化（仅重包裹 dataKey）；dataKey **永不因改密码变化**，故改密码无需重加密全部笔记（O(1)）。
- **登录**：`unlockLocal` 解 dataKey → 注入 `NotesDatabase.setDataKey` → 此后所有读写自动加解密。
- **同步**：manifest 用 dataKey 加密；blob 用"内容 hash"做内容寻址，天然幂等去重。
- **他端改密码**：本地 MK 解不开远端包裹 → 引擎中止同步并置 `requiresRelogin` → 主页弹强制重登录框；
  本地笔记（dataKey 加密）不受影响，用新密码登录后完好且继续同步。

---

## 7. 设计系统（双轨）

`app.dart` 同时挂 `ShadApp.custom`（shadcn_ui 组件）与 `MaterialApp`（`FlexColorScheme` 主题）。
新页面/对话框逐步采用 Shad 组件（`ShadDialog` / `ShadButton` / `ShadInputFormField`），旧页面保留 Material 控件；
两者共享 `ThemeProvider` 与 `NotesColor`（笔记卡片取色）。主题切换经 `ThemeProvider` 即时重建。

---

## 8. 辅助目录

### 8.1 纯 Dart CLI `bin/`

核心逻辑的**第二个前端**，是"core 不能依赖 Flutter"的架构守卫（CLI 编译不过即说明 core 被塞了 Flutter 依赖）。

- `safenotes_cli.dart`：`main`，`CommandRunner` 分发，退出码约定（0=成功 / 1=用户可预期错误 / 2=未预期异常）。
- `cli_context.dart`：`CliContext` 引导数据目录 → sqflite FFI → 日志 → 打开 DB → 恢复设备 ID（模拟多设备做同步测试）。
- `cli_commands.dart`：命令树 `db`(info/wipe)、`keyring`(init/unlock/status/verify/change-password)、
  `note`(add/list/get/update/delete/restore/hard-delete/purge-deleted)、`sync`(setup/sync/repair/status) 等。
- 密码优先级：`--password` > `--password-file` > 环境变量 `SN_PASSWORD`；凭据不入库。

### 8.2 SafeServer 参考实现 `server/`

自托管轻量同步服务，实现 `docs/server-api-spec.md` v2.2 协议：

- **Go**：`server/go/`（`main.go` 极简入口；`internal/config|auth|storage|server` 分层；
  `server.go` 路由 + graceful shutdown；`auth.go` 固定 Token + 速率限制含 OOM 防护；
  `fs.go` 原子写 tmp+fsync+rename；slog 结构化日志）。
- **Node.js**：`server/nodejs/server.js`（同协议的另一实现）。
- 端点：manifest/blob 的 CRUD + `health` + `blobs` 列表；ETag 乐观锁（`If-Match`/`If-None-Match`）。

### 8.3 测试 `test/` + `packages/core/test/`

- **应用层 `test/`**：`widget_test`、`auth_flow_test`、`settings_flow_test`、`export_backup_dialog_test`、
  `sync/change_password_multi_client_test`、`sync/sync_config_test`（含 `sync_test_support`）。
- **核心层 `packages/core/test/sync/`**：`sync_engine_test`、`keyring_test`、`journal_test`、
  `multi_device_test`、`chaos_multi_client_test`（混沌/并发冲突）、`blob_addressing_test`、
  `local_fs_backend_test`、`webdav_integration_test`、`safe_server_integration_test`、`p0p1_self_heal_test` 等。

---

## 9. 数据流与典型流程

**新建笔记并同步**：
`AddEditNotePage` → `NoteEditorState.addOrUpdateNote`（写库，`synced=false`）→ `SyncService.autoSync()`
（debounce 3s）→ `SyncEngine.sync()`：构建本地 manifest → 比对 → 加密 blob → `PUT manifest`（ETag 乐观锁）
→ 更新 `synced/synced_hash`（标记 base）。

**登录**：
`main` 预查 `Keyring.isInitialized` → `AuthWall` 分流 → `login.dart` 本地/远端验证 →
`Session.login` + `SyncService.initKeyringFromPassword` + （若启用同步）`initBackend` → `autoSync` 拉取远端。

**改密码**：
`change_passphrase` → `keyring.verifyPassword`(旧) → 前置检查 → `keyring.changePassword`
（推进 keyVersion，dataKey 不变）→ `updateKeyring`（重建引擎）→ `sync()` 推送新 `encryptedDataKey`。

---

## 10. 构建与运行

```bash
# 开发依赖（首次）
flutter pub get

# 应用层运行（桌面示例）
flutter run -d windows

# 纯 Dart CLI（验证核心逻辑 / 模拟多设备同步）
dart run bin/safenotes_cli.dart help
dart run bin/safenotes_cli.dart note list --data-dir ./cli-a --password 12345678
dart run bin/safenotes_cli.dart sync setup --type localfs --localfs-path ./sync-folder
dart run bin/safenotes_cli.dart sync sync   --data-dir ./cli-a --password 12345678

# 自托管 SafeServer（Go）
go run ./server/go -addr :2025 -data ./data -token my-secret-token

# 测试
flutter test
# 核心层（纯 Dart，无需 Flutter）
cd packages/core && dart test
```

---

## 11. 关键设计文档索引（docs/）

| 文档 | 内容 |
|------|------|
| `simplified-sync-design.md` / `sync-feature-design.md` | 同步引擎与 5 步流程设计 |
| `spec-manifest.md` / `spec-journal.md` / `spec-blob.md` | manifest v5 / journal / blob 格式规范 |
| `crypto-overview.md` | 密码学总览（MK / dataKey / Argon2id / AES-GCM） |
| `plaintext-passphrase-elimination-design-20260810.md` | 移除明文密码哈希、Keyring 方案 B 演进 |
| `manifest-reliability-design.md` | manifest 自恢复与冲突处理 |
| `cli-client-design.md` | CLI 设计 |
| `server-api-spec.md` / `server-implementation.md` | SafeServer 协议与实现 |
| `db-schema.md` | 数据库 schema v4 详解 |
| `tests-overview.md` | 测试总览 |
| `CHANGES-YYYYMMDD.md` | 每日变更记录 |

---

> 文档系基于全量阅读 `lib/`、`packages/core/` 源码撰写，覆盖加密、数据库、同步引擎、Keyring、Journal、
> 后端、日志、UI 装配与 CLI/Server 辅助模块。如需深入某一模块，建议结合上述 `docs/` 设计文档与对应源码注释对照阅读。
