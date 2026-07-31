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
│  ├─ 数据层 SQLite (data/database_handler)    │
│  ├─ 加密层 (encryption / sync/crypto)        │
│  └─ 同步层 SyncEngine (sync/*)               │
│         │ 依赖 SyncBackend 抽象接口           │
│         ▼                                    │
└──────────────┬───────────────────────────────┘
               │ SyncBackend（可插拔）
   ┌───────────┼───────────────┬──────────────┐
   ▼           ▼               ▼              ▼
 WebDAV     SafeServer HTTP   Local FS      （可扩展）
 (云盘)     (Go / Node.js)   (单设备/测试)
```

### 目录结构（`lib/`）

| 目录 / 文件 | 职责 |
|------|------|
| `lib/main.dart` | 应用入口：初始化 Provider、数据库、同步服务 |
| `lib/app.dart` | `MaterialApp` 根，路由与主题装配 |
| `lib/authwall.dart` | 认证闸门：未解锁时显示密码 / 生物识别登录页 |
| `lib/data/` | `database_handler.dart`（SQLite CRUD）、`preference_and_config.dart`（偏好 / 配置持久化） |
| `lib/encryption/` | `aes_encryption.dart`：笔记本地加密（AES-256-GCM / CBC） |
| `lib/models/` | 数据模型：`safenote`、`session`、`app_theme`、`editor_state`、`biometric_auth`、`file_handler`、`parse_import` |
| `lib/routes/` | `route_generator.dart`：路由表与页面跳转 |
| `lib/sync/` | **同步子系统**（见下文） |
| `lib/dialogs/` | 通用对话框：备份导入 / 导出、删除确认、退出登录等 |
| `lib/widgets/` | 复用组件：笔记卡片 / 磁贴、搜索框、抽屉、登录按钮等 |
| `lib/views/` | 页面：`home`、`add_edit_note`、`note_view`、`deleted_notes`、`change_passphrase`、认证页、设置页（含同步设置 / 诊断页） |
| `lib/utils/` | 工具：设备信息、缓存、生命周期、样式、时间、密码强度等 |

### 同步子系统（`lib/sync/`）

| 文件 | 职责 |
|------|------|
| `crypto.dart` | **密钥核心**：PBKDF2-HMAC-SHA256 派生 MK（600k 迭代）、AES-256-GCM、dataKey 的 wrap / unwrap |
| `vault.dart` | Vault 管理：vault_id、salt、manifest 版本、改密码、多设备重新认证协调 |
| `sync_models.dart` | 远端 manifest / item 数据模型（hash、deleted、updatedAt） |
| `sync_backend.dart` | **SyncBackend 抽象接口**：`getManifest / putManifest / getBlob / putBlob` |
| `sync_engine.dart` | 同步引擎：5 步流程、manifest 比对、LWW 冲突、乐观锁重试 |
| `sync_service.dart` | 同步服务：触发、互斥、状态广播（Provider） |
| `sync_config.dart` | 同步配置（后端类型、连接参数、开关） |
| `local_fs_backend.dart` | 后端实现：本地文件系统（单设备 / 测试） |
| `webdav_backend.dart` | 后端实现：WebDAV（坚果云 / NextCloud，RFC4918 `If-Match` 乐观锁） |
| `safe_server_backend.dart` | 后端实现：自建 SafeServer HTTP（Bearer Token + ETag） |
| `sync_logging.dart` / `sync_log_webserver.dart` | 同步日志（内存 / 文件 + 可选上报） |

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

## 日志系统

Safe Notes 内置一套**全应用统一日志系统**，覆盖所有重要业务操作与未捕获异常，桌面端（Windows / macOS / Linux）与移动端（Android / iOS）一视同仁启用。

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
- **本地存储**：`sqflite`（移动端）、`sqflite_common_ffi`（桌面端 / 测试）
- **安全存储**：`flutter_secure_storage`（密码 / MK 缓存于系统钥匙串）
- **加密**：`pointycastle`（AES-256-GCM / PBKDF2-SHA256）、`crypto`
- **网络**：`http`（WebDAV 客户端）
- **状态管理**：`provider`
- **生物识别**：`local_auth`；**本地化**：`easy_localization`
- **同步服务端**：Go（标准库）/ Node.js（内置模块）

---

## 构建与运行

```bash
# 安装依赖
flutter pub get

# 调试运行
flutter run

# 构建 Android 发布包
flutter build apk --release
flutter build appbundle --release

# 桌面端（Windows / macOS / Linux，使用 sqflite_common_ffi）
flutter config --enable-<platform>-desktop
flutter run -d <platform>

```

> 首次启动需设置主密码；笔记在本地加密后写入 SQLite。启用同步需在「设置 → 同步」中配置后端。

---

## 测试

```bash

# 运行全部测试
flutter test

# 仅运行加密单元测试
flutter test test/encryption

# 仅运行同步引擎单元测试（内存 FakeBackend，纯本地可跑）
flutter test test/sync/sync_engine_test.dart
```

**同步集成测试**（`test/sync/safe_server_integration_test.dart`）需要启动 SafeServer：
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
- `docs/CHANGES-YYYYMMDD.md`：每日变更日志（按日期归档）

---

## 与原版（上游）的主要差异

| 维度 | 上游 | 本 fork |
|------|------|---------|
| 同步 | 无（纯本地） | 完整 E2EE 多设备同步子系统 |
| 服务端 | 无 | Go / Node.js SafeServer v2.2 参考实现 |
| 加密 | 本地 AES 加密 | 本地加密 + 同步层 MK + dataKey 两层密钥 |
| 测试 | 基础 widget 测试 | 新增加密向量、SyncEngine、多设备 / 混沌 / 集成测试 |
| 设置页 | 基础 | 新增同步设置、同步诊断页、最近删除 |

---

## 许可证

GPL-3.0-or-later。© Keshav Priyadarshi and others。详见 `LICENSE`、`AUTHORS.md`、`SECURITY.md`。
