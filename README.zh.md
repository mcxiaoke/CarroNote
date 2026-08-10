# Safe Notes

> 加密、私密的本地优先（local-first）笔记管理器 —— **端到端加密（E2EE）同步版**

Safe Notes 是一款注重隐私的笔记应用：所有笔记**默认在本地设备上加密存储**（AES-256-GCM），不依赖任何第三方云。

本项目基于上游 [keshav-space/safenotes](https://github.com/keshav-space/safenotes) fork 并进行了大幅改造，**核心新增了一套完整的端到端加密多设备同步子系统**：客户端 `SyncEngine` + 可插拔后端抽象（WebDAV / 自建 HTTP 服务 / 本地文件系统），并配套提供了 **Go 与 Node.js 两种**参考实现的服务端（SafeServer）。

> [!IMPORTANT]
> 安全与责任：再强的加密也要求你**牢记自己的主密码（passphrase）**。密码只存在于你的脑中，任何人都无法帮你找回。

---

## 特性

**基础能力（继承自上游）**
- 本地 AES-256 加密存储，笔记在设备上永不以明文落盘
- 生物识别（指纹 / 面容）解锁
- 安卓后台快照保护、隐身键盘、防截屏
- 暴力破解防护、闲置自动锁定（inactivity guard）
- 北极风（Arctic Nord）深 / 浅色主题、列表 / 网格视图、彩色笔记
- 加密备份导出 / 导入（无缝迁移到新设备）

**新增能力（本 fork 改造）**
- 端到端加密同步：**MK + dataKey 两层密钥**，改密码 O(1) 且原子完成
- 后端无关（backend-agnostic）：WebDAV（坚果云 / NextCloud / 自建）、自建 SafeServer HTTP、本地文件系统任选
- 内容寻址（content hash）天然去重、软删除 / 墓碑同步
- 多设备同步 + LWW 冲突解决 + 历史版本保留
- 同步诊断页、同步状态可视化

---

## 架构概览

### 整体分层

```
┌──────────────────────────────────────────────┐
│  Flutter 客户端                               │
│  ├─ UI 层 (views / widgets / dialogs)        │
│  ├─ 状态管理 Provider (models)               │
│  └─ 状态装配 / 平台注入 (main)               │
└──────────────┬───────────────────────────────┘
               ▼
┌──────────────────────────────────────────────┐
│  packages/core（纯 Dart 核心包，无 Flutter）  │
│  ├─ 数据层 SQLite (db/database_handler)      │
│  ├─ 加密层 (crypto/*)                        │
│  ├─ 模型层 (models/*)                        │
│  └─ 同步层 SyncEngine (sync/*)               │
│         │ 依赖 SyncBackend 抽象接口           │
└──────────────┬───────────────────────────────┘
               │ SyncBackend（可插拔）
   ┌───────────┼───────────────┬──────────────┐
   ▼           ▼               ▼              ▼
 WebDAV     SafeServer HTTP   Local FS      （可扩展）
 (云盘)     (Go / Node.js)   (单设备/测试)
```

核心逻辑（加密 / 数据库 / 同步引擎）独立为纯 Dart 包 `packages/core`（禁止 Flutter 依赖，由 pub workspace 编译器强制），App 侧只保留 UI 与状态装配，通过 `package:core/core.dart` 单一出口导入。另提供纯 Dart CLI `bin/safenotes_cli.dart`（无需 Flutter SDK 即可读写加密笔记数据库，可编译为 AOT 原生产物，见 [CLI 客户端](#cli-客户端)）。

### 目录结构（App 侧 `lib/`）

| 目录 / 文件 | 职责 |
|------|------|
| `lib/main.dart` | 应用入口：初始化 Provider、数据库、同步服务；注入平台能力（数据库工厂 / 日志目录） |
| `lib/app.dart` | `MaterialApp` 根，路由与主题装配 |
| `lib/authwall.dart` | 认证闸门：未解锁时显示密码 / 生物识别登录页 |
| `lib/data/` | App 侧偏好 / 配置持久化（核心数据库逻辑已在 `packages/core`） |
| `lib/models/` | App 侧状态模型：session、app_theme、editor_state、biometric_auth 等 |
| `lib/routes/` | `route_generator.dart`：路由表与页面跳转 |
| `lib/sync/` | App 侧同步装配：`sync_service.dart`（互斥 / 状态广播）、`sync_config.dart`（配置） |
| `lib/dialogs/` | 通用对话框：备份导入 / 导出、删除确认、退出登录等 |
| `lib/widgets/` | 复用组件：笔记卡片 / 磁贴、搜索框、抽屉、登录按钮等 |
| `lib/views/` | 页面：`home`、`add_edit_note`、`note_view`、`deleted_notes`、`change_passphrase`、认证页、设置页（含同步设置 / 诊断页） |
| `lib/utils/` | App 侧工具：设备信息、生命周期、样式、时间、密码强度等 |

### 核心包（`packages/core/`）

| 目录 / 文件 | 职责 |
|------|------|
| `lib/core.dart` | 核心包唯一公开出口（统一 `import 'package:core/core.dart'`） |
| `lib/src/ports.dart` | 平台能力注入点：PathProvider / KeyValueStore / SecretStore / LogSink |
| `lib/src/crypto/` | 加密层：`aes_encryption.dart`（本地 AES-256-GCM / CBC）、`crypto.dart`（PBKDF2 / AES / dataKey wrap-unwrap） |
| `lib/src/db/` | `database_handler.dart`：SQLite CRUD（`dbFactoryOverride` / `dbPathOverride` 注入） |
| `lib/src/models/` | 数据模型：`safenote`、`parse_import` |
| `lib/src/logger/` | 统一日志：`app_logger.dart`（`logDirResolverOverride` 注入）、`log_webserver.dart` |
| `lib/src/sync/` | 同步核心（见下文） |
| `bin/../` | （CLI 在根 `bin/safenotes_cli.dart`） |

### 同步子系统（`packages/core/lib/src/sync/`）

| 文件 | 职责 |
|------|------|
| `crypto.dart` | **密钥核心**：PBKDF2-HMAC-SHA256 派生 MK（600k 迭代）、AES-256-GCM、dataKey 的 wrap / unwrap |
| `keyring.dart` | Keyring 管理：vault_id、salt、manifest 版本、改密码、多设备重新认证协调 |
| `sync_models.dart` | 远端 manifest / item 数据模型（hash、deleted、updatedAt） |
| `sync_backend.dart` | **SyncBackend 抽象接口**：`getManifest / putManifest / getBlob / putBlob` |
| `sync_engine.dart` | 同步引擎：5 步流程、manifest 比对、LWW 冲突、乐观锁重试 |
| `journal.dart` | 同步事件日志（跨进程续接、崩溃自愈） |
| `backends/local_fs_backend.dart` | 后端实现：本地文件系统（单设备 / 测试） |
| `backends/webdav_backend.dart` | 后端实现：WebDAV（坚果云 / NextCloud，RFC4918 `If-Match` 乐观锁） |
| `backends/safe_server_backend.dart` | 后端实现：自建 SafeServer HTTP（Bearer Token + ETag） |

### 加密与密钥（两层架构）

```
密码层（改密码时变化）
  MK = PBKDF2-HMAC-SHA256(password, salt, 600k)
  MK 只用于加密 dataKey，不直接加密笔记
        ↓ 加密
数据层（永不变化，真正加密笔记的密钥）
  dataKey = 随机 32 字节（首次启用同步时生成）
  encryptedDataKey = AES-GCM(MK, dataKey)  ← 存入 manifest 随版本同步
        ↓ 加密每条笔记
笔记层
  envelope = AES-256-GCM(dataKey, nonce, AAD=note_id, content)
```

**关键设计**
- `dataKey` 永不变化 → 改密码只需用新 MK 重新包装 32 字节的 dataKey（O(1)，一次 manifest PUT 原子完成），无需重加密所有笔记
- `encryptedDataKey` 随 manifest 同步，无需独立的 keystore 同步层，规避多密钥冲突
- 信封 nonce 随机生成，AAD 绑定笔记 id 防重放

### 同步流程（5 步）

1. `GET /manifest` → 拉取远端 manifest 密文，用 MK 解密
2. 比对本地 vs 远端 manifest（上传 / 下载 / 冲突 / 跳过）
3. 执行传输：上传新 blob / 下载远端 blob / LWW 落败方标记删除或覆盖
4. 生成合并 manifest（version = 远端 + 1）
5. `PUT /manifest`（带 `If-Match` 乐观锁）→ 200 成功；412 冲突则回到第 1 步重试（最多 3 次）

冲突采用 **LWW（Last-Write-Wins）**，乐观锁仅在 manifest 层（一次 PUT）。旧 hash 的 blob 不立即删除，可作为历史版本恢复。

### 同步服务端（`server/`）

本 fork 提供 SafeServer 参考实现，协议版本 **v2.2**，Go 与 Node.js **两种实现协议完全一致、可互换**。`server/` 目录已被 `.gitignore` 排除，仅供本地测试与参考。

- `server/go/`：Go 1.21+，**仅标准库**
- `server/nodejs/`：JavaScript (ESM)，**仅内置模块**

服务端遵循**零知识**原则：只处理密文，不解析内容、不计算 hash、不维护版本计数器；通过 ETag（`SHA-256(密文)`）实现乐观锁，原子写入（`tmp + fsync + rename`）防 TOCTOU，并提供 Bearer Token 认证、速率限制、路径穿越防护、graceful shutdown。存储层通过 `Storage + Vault` 接口抽象，可切换到 SQLite / 对象存储。

> 说明：WebDAV 后端**零服务端开发**，可直接用你自己的云盘（坚果云 / NextCloud）；SafeServer 仅在需要多用户、推送通知、速率限制等高级能力时自建。

---

## CLI 客户端

核心逻辑的**第二个前端**（App 是第一个）：纯 Dart，无需 Flutter SDK，直接读写加密笔记数据库，
是**真实流程测试**（多目录多设备同步、密钥迁移、冲突、改密码等）的主力工具。
用 `--data-dir` 指定一个数据目录即视为**一台设备实例**，用两个目录即可模拟两台设备做同步。

```bash
# 编译为 AOT 原生产物（无 build-hooks 噪声，比 dart run 快约 58x；bundle 需整体分发）
make cli-build        # = task cli-build = just cli-build
                      # 产物：build/cli/bundle/bin/safenotes_cli.exe + bundle/lib/sqlite3.dll

# 常用命令（产物位于 PATH 后可直接执行）
safenotes_cli.exe --data-dir temp/dev-a --password P keyring init
safenotes_cli.exe --data-dir temp/dev-a --password P note add --title 标题 --body 正文
safenotes_cli.exe --data-dir temp/dev-a --password P note list
safenotes_cli.exe --data-dir temp/dev-a --password P sync setup --type localfs --path temp/vault
safenotes_cli.exe --data-dir temp/dev-a --password P sync run
safenotes_cli.exe --data-dir temp/dev-a --password P export --out backup.json
safenotes_cli.exe --data-dir temp/dev-a --password P db info
```

命令分组：`db`（info / wipe）、`keyring`（init / unlock / status / verify / change-password）、
`note`（add / list / get / update / delete / restore / hard-delete / purge-deleted）、
`export` / `import`、`sync`（setup / run / repair / status）、`log` / `journal`、`meta`。
退出码约定：`0` 成功、`1` 用户可预期错误、`2` 异常崩溃。完整说明见
`docs/cli-client-design-20260803.md`，端到端测试见 [测试](#测试) 中的 `e2e`。

---

## 日志系统

Safe Notes 内置一套**全应用统一日志系统**，覆盖所有重要业务操作与未捕获异常，桌面端（Windows / macOS / Linux）与移动端（Android / iOS）一视同仁启用。日志核心在 `packages/core/lib/src/logger/`，平台目录由 App 侧经 `logDirResolverOverride` 注入。

### 核心设计
- **统一入口**：`Log.app` / `Log.note` / `Log.db` / `Log.auth` / `Log.sync` / `Log.backup` / `Log.settings` / `Log.crypto` / `Log.web` / `Log.ui` 十类分级日志（trace / debug / info / warn / error / fatal）。
- **三路输出**：① 调试期 `console`；② 内存环形缓冲（调试面板 / 日志 Web 服务器实时查看）；③ 按日期滚动的日志文件（`safenotes-YYYYMMDD.log`，保留 7 天）。
- **全平台落地**：桌面端日志落在 exe 同目录 `logs/`，移动端落在应用私有数据目录 `logs/`。

### 覆盖范围
- 笔记新增 / 编辑 / 删除 / 恢复 / 永久删除（含 uuid 与内容哈希，便于定位具体笔记）
- 数据库建表 / 升级 / 迁移 / 重加密 / 删库
- 登录 / 登出 / 改密码 / 生物识别
- 备份导入 / 导出
- 同步引擎全部动作（上传 / 下载 / 删除 / 冲突 / 迁移 / 修复）
- **所有未捕获 `Exception` / `Error`**（经 `main.dart` 的 `FlutterError.onError` / `PlatformDispatcher.onError` / `runZonedGuarded` 全局兜底）

### 日志 Web 服务器
进入主界面（HomePage）即自动启动，提供浏览器端实时日志查看器；应用退出时停止。默认访问 `http://127.0.0.1:8888/`。

---

## 技术栈

- **框架**：Flutter ≥ 3.44.0 / Dart ≥ 3.12
- **核心包**：`packages/core`（纯 Dart，pub workspace，禁止 Flutter 依赖；编译器强制）
- **本地存储**：`sqflite`（移动端）、`sqflite_common_ffi`（桌面端 / 测试 / CLI）
- **安全存储**：`flutter_secure_storage`（密码 / MK 缓存于系统钥匙串）
- **加密**：`cryptography` + `cryptography_flutter`（AES-256-GCM / PBKDF2，硬件加速）、`crypto`（SHA-256 内容 hash）
- **网络**：`http`（WebDAV 客户端）
- **状态管理**：`provider`
- **生物识别**：`local_auth`；**本地化**：`easy_localization`
- **CLI 解析**：`args`（CommandRunner）；**任务管理**：`make` / `task` / `just` 三套等价
- **同步服务端**：Go（标准库）/ Node.js（内置模块）

---

## 构建与运行

**任务管理**：`make`（Makefile）、`task`（Taskfile.yml）、`just`（justfile）三份**完全等价**，
按「依赖 / 构建 / 测试」三类组织，均含 `get`、`clean`、`run`、`cli-build`、`build-*`、`test`、
`test-core`、`analyze`、`e2e` 等。Windows 下 `make` 默认不在 PATH，推荐用 `task` 或 `just`
（`task --list` / `just --list` 查看全部任务）。

```bash
# 安装依赖
make get              # = task get = just get（自动注入最新构建信息）

# 调试运行
make run              # = task run = just run

# 构建 CLI 客户端（AOT 原生产物，见「CLI 客户端」一节）
make cli-build

# 构建 Android 发布包
make build-apk        # APK (release)
make build-aab        # AppBundle (release)

# 桌面端（Windows / macOS / Linux，使用 sqflite_common_ffi）
flutter config --enable-<platform>-desktop
make build-windows / build-linux / build-macos
flutter run -d <platform>

# 查看全部任务
task --list
just --list
```

> 首次启动需设置主密码；笔记在本地加密后写入 SQLite。启用同步需在「设置 → 同步」中配置后端。

---

## 构建信息注入（版本 / Git / 构建时间）

每次构建都会把 **Git 提交哈希、分支、tag、工作区是否脏、累计提交数** 以及 **构建时间** 注入到应用内，并在启动时打印一份版本详情，便于复现线上问题与溯源。

实现方式：构建前由 `scripts/generate_build_info.py` 生成 `lib/utils/build_info.dart`（编译期常量，零运行时开销），`lib/main.dart` 的 `_initLogging()` 在启动时读取并打印。

**统一使用 `make` 目标构建**（会自动先注入最新构建信息；`task` / `just` 同理）：

```bash
make run            # 调试运行（自动注入）
make build-apk     # Android APK (release)
make build-aab     # Android AppBundle (release)
make build-windows # Windows 桌面端 (release)
make build-linux   # Linux 桌面端 (release)
make build-macos   # macOS 桌面端 (release)
make release       # 发布打包（多 ABI 拆分 + AppBundle，先注入最新信息）
```

> 若直接执行 `flutter run` / `flutter build`，会沿用 `lib/utils/build_info.dart` 中**上一次生成**的值（文件始终存在，可正常编译，仅信息可能滞后）。需要最新元数据请用上面的 `make` 目标。

**手动生成 / 仅刷新构建信息：**

```bash
make gen-build-info
# 或
python scripts/generate_build_info.py
```

`BuildInfo` 暴露字段：`version` / `buildNumber` / `versionString` / `gitHash` / `gitHashShort` / `gitBranch` / `gitTag` / `gitCommitCount` / `gitDirty` / `buildDate`(UTC) / `buildDateReadable`，以及便捷 getter `summary`（单行）与 `detail`（多行，可用于「关于 / 调试」面板）。

启动日志示例：

```
════════ SafeNotes 启动 ════════
版本: 2.3.0 (build 10)
Git: 0a4d888 @ sync-refact-dev (工作区有未提交改动)
Commit: 0a4d888c82a636d3394d6b6c939c61e2adfe4b7d
Tag: v2.3.0-188-g0a4d888 (累计提交 608)
构建时间: 2026-08-02 12:21:18 (UTC 2026-08-02T04:21:18Z)
平台: windows Microsoft Windows [Version 10.0.22631.0]
Dart: 3.44.8
```

---

## 测试

核心逻辑为纯 Dart 包，**无需 Flutter SDK 即可跑核心测试**；App 侧测试需要 Flutter。

```bash
# 运行全部测试（核心 + App）
make test                # = task test = just test；dart test packages/core/test + flutter test

# 仅运行核心包测试（纯 Dart，无需 Flutter SDK）
make test-core           # dart test packages/core/test
dart test packages/core/test/sync/crypto_test.dart    # 仅加密
dart test packages/core/test/sync                # 仅同步引擎 / 多设备 / 长期存续

# CLI 端到端测试（需先 make cli-build，脚本自动优先用编译产物）
make e2e                 # = task e2e = just e2e

# 运行 App 侧测试（需 Flutter）
flutter test
```

**同步集成测试**（`packages/core/test/sync/safe_server_integration_test.dart`）需要启动 SafeServer：
- 默认使用 **Go** 实现（测试 `setUpAll` 会自动构建 `server/go` 二进制并启动）
- 切换为 **Node.js** 实现：`$env:SN_SERVER="node"`（PowerShell）后运行 `flutter test`
- 覆盖：首次同步、新设备同步、增量同步、LWW 冲突、墓碑同步、幂等性、HTTP 协议（404 / 401 / 412 / ETag）、v2.2 资源层、速率限制
- 清理脚本：`test/scripts/test-cleanup.ps1`（杀残留进程 + 清理临时文件）

---

## 开发文档

详细设计、协议规范与评审记录在 `docs/` 目录：
- `docs/sync-protocol-spec.md` / `docs/server-api-spec.md`：客户端 / 服务端协议规范
- `docs/simplified-sync-design.md` / `docs/sync-feature-design.md`：同步架构设计
- `docs/server-implementation.md`：SafeServer 实现文档
- `docs/cli-client-design-20260803.md`：CLI 客户端设计（命令树 / 验收清单 / 实现要点）
- `docs/pure-dart-core-extraction-research-20260802.md`：核心逻辑纯 Dart 化抽取设计
- `docs/CHANGES-YYYYMMDD.md`：每日变更日志（按日期归档）

---

## 与原版（上游）的主要差异

| 维度 | 上游 | 本 fork |
|------|------|---------|
| 同步 | 无（纯本地） | 完整 E2EE 多设备同步子系统 |
| 服务端 | 无 | Go / Node.js SafeServer v2.2 参考实现 |
| 加密 | 本地 AES 加密 | 本地加密 + 同步层 MK + dataKey 两层密钥 |
| 核心分层 | 与 UI 混编 | 核心逻辑抽为纯 Dart 包 `packages/core`（无 Flutter 依赖，可 CLI / 测试独立驱动） |
| 测试 | 基础 widget 测试 | 新增加密向量、SyncEngine、多设备 / 混沌 / 集成测试（核心测试可脱离 Flutter SDK 运行） |
| 设置页 | 基础 | 新增同步设置、同步诊断页、最近删除 |

---

## 许可证

GPL-3.0-or-later。© Keshav Priyadarshi and others。详见 `LICENSE`、`AUTHORS.md`、`SECURITY.md`。
