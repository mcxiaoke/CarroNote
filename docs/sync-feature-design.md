# Carro Note 同步功能改造设计文档

> 版本：v1.0
> 适用项目：safenotes（Flutter / Android，fork 改造版）
> 参考实现：[litenotes](https://github.com/...) 的 SimpleBox.Core/Sync/（C# WPF 桌面端）+ server/go（Go 服务端）
> 参考协议：`litenotes/docs/sync-design.md` v1.1
>
> 定位：本文档是 safenotes fork 改造的实施依据，不涉及存量数据迁移与旧格式兼容——
> fork 项目按"新数据库 + 新加密格式"从零启动，旧 safenotes 备份不复用。
>
> **注意（2026-08-11 补记）**：本文档 §KDF 章节的「PBKDF2-SHA256 600k」属本 fork 设计的独立选型，
> 与主应用 `crypto-overview.md` 所述**当前实现不一致**——主应用自 2026-08-11 起
> 默认 KDF 为 **Argon2id**（`m=32MiB, t=3, p=2`），存量 PBKDF2 按 header `algorithm` 字段回退。
> 阅读本文档时请以本 fork 的设计口径为准，勿与主线实现混用。
>
> **架构状态（2026-08-16 补记）**：本文档描述的同步架构（`ISyncTransport` / `SyncClient` / `Keystore`、
> 「纯 fork 冲突、保留双份」）**并非最终实现**。实际落地的是 `docs/simplified-sync-design.md` 的
> **manifest 架构 + LWW 冲突解决 + 后端无关（WebDAV / SafeServer / localFs）**方案（见 `sync_engine.dart`）。
> 本文档保留为早期设计依据，架构/fork-冲突相关描述请勿当作当前实现。

---

## 目录

1. [改造范围与原则](#1-改造范围与原则)
2. [现状与差距](#2-现状与差距)
3. [目标架构](#3-目标架构)
4. [数据模型与存储改造](#4-数据模型与存储改造)
5. [加密层重写](#5-加密层重写)
6. [Keystore 与主密钥架构](#6-keystore-与主密钥架构)
7. [同步引擎（SyncEngine）](#7-同步引擎syncengine)
8. [同步传输（SyncClient）](#8-同步传输syncclient)
9. [同步状态与配置](#9-同步状态与配置)
10. [UI 集成](#10-ui-集成)
11. [触发与并发](#11-触发与并发)
12. [服务端复用](#12-服务端复用)
13. [测试策略](#13-测试策略)
14. [分步实施计划](#14-分步实施计划)
15. [明确不做的事](#15-明确不做的事)
16. [风险与对策](#16-风险与对策)

---

## 1. 改造范围与原则

### 1.1 范围

- **核心层**：数据模型、加密层、Keystore、SyncEngine、SyncClient、SyncState
- **UI 层**：设置页新增"同步"分组、状态栏同步图标、冲突提示
- **服务端**：直接复用 litenotes/server/go，不重写

### 1.2 原则

1. **协议对等**：Dart 客户端与 C# 客户端对同一服务端互操作；加密参数完全一致以保证互解。
2. **不兼容旧格式**：safenotes 原有的 AES-CBC + 自研 KDF 加密、`INTEGER AUTOINCREMENT` 主键、硬删除模型全部废弃，按新格式重建数据库。fork 项目不带历史包袱。
3. **同步默认关闭**：safenotes 原本以"完全匿名、无入站出站请求"为隐私承诺；同步是用户显式启用的可选功能，未配置时不发任何网络请求。
4. **本地优先、永不丢数据**：同步失败不影响本地编辑；下次有网络时重试即可。冲突采用纯 fork 策略，保留双份。
5. **不实现后台同步**：不做 Doze 友好、不做前台服务、不做 WorkManager 调度。同步仅在 App 在前台时进行。
6. **核心层可在 Windows 上单测**：加密、同步引擎、数据层不依赖 Android 平台 API，`flutter test` 在 Windows 上直接可跑。

---

## 2. 现状与差距

### 2.1 safenotes 现状

| 维度 | 现状 | 文件位置 |
|---|---|---|
| 主键 | `INTEGER PRIMARY KEY AUTOINCREMENT` | [safenote.dart](file:///c:/Home/Projects/safenotes/lib/models/safenote.dart) `NoteFields.id` |
| 字段 | `title / description / time`（仅 createdTime，无 updatedAt） | 同上 |
| 删除 | 硬删除 `DELETE FROM` | [database_handler.dart:117](file:///c:/Home/Projects/safenotes/lib/data/database_handler.dart) |
| 加密 | AES-256-**CBC** + PKCS7，自研 EVP_BytesToKey 风格 KDF（SHA256 迭代拼接） | [aes_encryption.dart:70](file:///c:/Home/Projects/safenotes/lib/encryption/aes_encryption.dart) |
| 密钥 | 口令直接派生密钥加密每条笔记，无主密钥中间层 | 同上 |
| 数据库 | sqflite 单文件，文件名 `._my_system_note`，无 meta 表 | [database_handler.dart:35](file:///c:/Home/Projects/safenotes/lib/data/database_handler.dart) |
| 配置 | `SharedPreferences`，仅本地偏好，无同步配置 | [preference_and_config.dart](file:///c:/Home/Projects/safenotes/lib/data/preference_and_config.dart) |
| 网络 | 无（README 明确"无入站出站请求"） | — |

### 2.2 协议要求

参见 `litenotes/docs/sync-design.md` v1.1。要点：

- 主键 `UUIDv4` 字符串
- 字段 `id / content / contentType / deleted / updatedAt / rev`
- 软删除（墓碑）
- 加密 `AES-256-GCM + PBKDF2-SHA256(600k)`
- Keystore：随机主密钥 MK + 口令派生 KEK 包裹
- REST API：`GET /sync?since=N`、`PUT /items`、`GET /items/{id}`、`GET /health`
- 乐观并发：`baseRev` 不匹配返回 409，逐条给结果
- 冲突在客户端解决：默认 fork（保留双份）
- 同步进度持久化在 `notes.db` meta 表（键 `sync_state`）

### 2.3 差距汇总

| 项目 | safenotes | 协议要求 | 改造类型 |
|---|---|---|---|
| 主键 | int 自增 | UUIDv4 | **重写** |
| 字段集 | 4 个 | 6 个 | 扩展 |
| 删除 | 硬删除 | 软删除 | **架构改变** |
| 加密算法 | AES-CBC | AES-GCM | **重写** |
| KDF | 自研迭代 | PBKDF2-SHA256 600k | **重写** |
| 密钥架构 | 口令→密钥 | MK + KEK + Keystore | **新增层** |
| meta 表 | 无 | 有（keystore / sync_state / vault_id） | 新增 |
| 同步配置 | 无 | serverUrl / token / 开关 / 间隔 | 新增 |
| 网络 | 无 | HTTP + Bearer | 新增 |

---

## 3. 目标架构

```
┌──────────────────────────────────────────────────┐
│              Carro Note App (Flutter)            │
│                                                  │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐  │
│  │   Views    │  │  Settings  │  │  Sync UI   │  │
│  │ (home.dart │  │   page     │  │ (状态/触发) │  │
│  │  等)       │  │            │  │            │  │
│  └─────┬──────┘  └─────┬──────┘  └─────┬──────┘  │
│        │               │               │         │
│        └───────────────┼───────────────┘         │
│                        ▼                         │
│  ┌────────────────────────────────────────────┐  │
│  │            SyncService（应用层）            │  │
│  │  定时器 / 防抖触发 / 互斥锁 / 状态通知      │  │
│  └──────────────────┬─────────────────────────┘  │
│                     ▼                            │
│  ┌────────────────────────────────────────────┐  │
│  │             SyncEngine（核心）              │  │
│  │  推送 / 拉取 / 回声过滤 / 冲突 fork / keystore│  │
│  └──────┬──────────────────────┬───────────────┘  │
│         ▼                      ▼                  │
│  ┌─────────────┐      ┌─────────────────────┐    │
│  │  Vault/DB   │      │   SyncClient(HTTP)  │    │
│  │ (sqflite)   │      │   Bearer + JSON     │    │
│  │ + 加密信封  │      └──────────┬──────────┘    │
│  │ + Keystore  │                 │               │
│  └──────┬──────┘                 │               │
└─────────┼────────────────────────┼───────────────┘
          │                        │ HTTPS
          ▼                        ▼
   本地 SQLite notes.db      ┌──────────────┐
                             │  Go 服务端   │
                             │ (复用 litenotes)│
                             └──────────────┘
```

### 3.1 分层与依赖

| 层 | 职责 | 依赖 |
|---|---|---|
| Views | UI 展示、用户交互 | SyncService |
| SyncService | 触发时机、互斥、状态广播 | SyncEngine |
| SyncEngine | 同步流程编排、冲突处理 | Vault、ISyncTransport |
| SyncClient | HTTP 传输 | ISyncTransport 接口 |
| Vault / DB | 数据持久化、加解密 | sqflite、pointycastle |
| Keystore | MK 包装 / 解包 | Crypto |
| Crypto | PBKDF2 / AES-GCM 原语 | pointycastle |

**关键解耦**：SyncEngine 通过 `ISyncTransport` 抽象访问服务端，单测可注入假实现，不依赖网络与平台。

---

## 4. 数据模型与存储改造

### 4.1 数据库 schema

废弃现有 `._my_system_note` 数据库，新建 `notes.db`。表结构对齐 litenotes（见 [NoteDatabase.cs:75](file:///C:/Home/Projects/litenotes/SimpleBox.Core/NoteDatabase.cs#L75)）：

```sql
-- 元数据表：keystore、vault_id、sync_state、autolock 等
CREATE TABLE meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

-- 笔记表
CREATE TABLE notes (
  id          TEXT PRIMARY KEY,      -- UUIDv4，客户端创建时生成
  envelope    BLOB NOT NULL,         -- Crypto.Seal(MK, AAD=id, JSON{name,content})
  created_at  INTEGER NOT NULL,      -- Unix 毫秒
  modified_at INTEGER NOT NULL,      -- Unix 毫秒，明文（供 dirty 判定）
  deleted     INTEGER NOT NULL DEFAULT 0  -- 墓碑标记
);
CREATE INDEX idx_notes_modified ON notes(modified_at);
```

### 4.2 meta 表键值

| key | value | 用途 |
|---|---|---|
| `format` | `2` | 存储格式版本 |
| `vault_id` | UUIDv4 | vault 唯一标识（首次创建生成） |
| `keystore` | JSON | Keystore 序列化（见 §6） |
| `autolock_minutes` | 整数 | 自动锁定分钟数（沿用 safenotes 现有功能） |
| `sync_state` | JSON | 同步进度（见 §9） |

### 4.3 Note 模型改造

`lib/models/safenote.dart` 中的 `SafeNote` 改为：

```dart
class SafeNote {
  final String id;              // UUIDv4，取代 int? id
  final String name;            // 取代 title（与协议字段对齐）
  final String content;         // 取代 description
  final int createdAt;          // Unix 毫秒
  final int modifiedAt;         // Unix 毫秒，新增
  final bool deleted;           // 新增（墓碑）

  // ... copy / equals / hashCode
}
```

> 命名调整（`title→name`、`description→content`）是为了与协议字段、litenotes 客户端字段对齐，减少后续翻译/对照成本。UI 层展示文案不受影响。

### 4.4 数据库 handler 改造

`lib/data/database_handler.dart` 中的 `NotesDatabase` 重写：

- 打开：`openDatabase(path, version: 1, onCreate: _createDB)`
- `create(SafeNote)`：生成 UUIDv4，加密 envelope，INSERT
- `update(SafeNote)`：加密 envelope，UPDATE modified_at
- `delete(String id)`：UPDATE deleted=1, modified_at=now（**软删除**）
- `getAllNotes()`：`WHERE deleted = 0`，解密返回
- `getSyncItems()`：返回全部行（含墓碑），**不解密**，供 SyncEngine 推送
- `saveChanges(upserts, deletedIds, deleteTs)`：单事务批量 upsert + 墓碑
- `loadSyncState() / saveSyncState(json)`：读写 meta 表 `sync_state`
- `loadKeystore() / saveKeystore(json)`：读写 meta 表 `keystore`

### 4.5 写入原子性

所有写入用 sqflite 事务包裹；批量保存使用 `db.transaction((txn) async { ... })`。文件级原子性由 sqflite WAL 模式保证（打开时指定 `journal_mode: WAL`）。

### 4.6 数据库文件位置

沿用 safenotes 现有位置（`getDatabasesPath()` 返回的应用私有目录），仅文件名从 `._my_system_note` 改为 `notes.db`（与 litenotes 一致，便于排查问题）。

---

## 5. 加密层重写

### 5.1 算法与参数

完全对齐 litenotes `Crypto.cs`（[Crypto.cs](file:///C:/Home/Projects/litenotes/SimpleBox.Core/Crypto.cs)）：

| 项 | 值 |
|---|---|
| 对称加密 | AES-256-GCM |
| 密钥长度 | 32 字节 |
| Salt 长度 | 16 字节 |
| Nonce 长度 | 12 字节 |
| Tag 长度 | 16 字节 |
| KDF | PBKDF2-HMAC-SHA256 |
| 迭代次数 | 200,000 |
| 信封格式 | `nonce(12) ‖ ciphertext ‖ tag(16)` 单字节串 |

### 5.2 新文件 `lib/encryption/crypto.dart`

```dart
import 'dart:typed_data';
import 'package:pointycastle/block/aes_gcm.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/macs/hmac.dart';
import 'package:pointycastle/padded_block_cipher/padded_block_cipher_parameters.dart';
import 'package:pointycastle/stream/ctr.dart';

// 注意：以下为接口示意，实际实现时需查阅 pointycastle 的 GCM API
// 并与 C# System.Security.Cryptography.AesGcm 行为逐字节对齐

class Crypto {
  static const int keySizeBytes = 32;
  static const int saltSizeBytes = 16;
  static const int nonceSizeBytes = 12;
  static const int tagSizeBytes = 16;
  static const int defaultIterations = 200000;

  /// PBKDF2-HMAC-SHA256 派生密钥
  static Uint8List deriveKey(String password, Uint8List salt, {int iterations = defaultIterations}) { ... }

  /// AES-256-GCM 加密，返回 (ciphertext, tag)
  static (Uint8List ciphertext, Uint8List tag) encrypt({
    required Uint8List key,
    required Uint8List nonce,
    Uint8List? aad,
    required Uint8List plaintext,
  }) { ... }

  /// AES-256-GCM 解密，校验失败抛异常
  static Uint8List decrypt({
    required Uint8List key,
    required Uint8List nonce,
    Uint8List? aad,
    required Uint8List ciphertext,
    required Uint8List tag,
  }) { ... }

  /// 一体化信封：随机 nonce，返回 nonce ‖ ciphertext ‖ tag
  static Uint8List seal(Uint8List key, Uint8List? aad, Uint8List plaintext) { ... }

  /// 解开 seal 生成的信封
  static Uint8List unseal(Uint8List key, Uint8List? aad, Uint8List blob) { ... }
}
```

### 5.3 跨平台互解测试向量

这是改造的最高风险点。**必须**在写实现前先写测试向量：

1. 在 C# 端用固定 `(password, salt, nonce, plaintext, aad)` 跑一次 `Crypto.Seal`，导出十六进制密文
2. Dart 端用相同输入跑 `Crypto.seal`，比对输出
3. 反向：Dart 加密 → C# 解密；C# 加密 → Dart 解密
4. 涵盖：空 aad、有 aad、空 plaintext、长 plaintext

测试向量文件放 `test/crypto_vectors.dart`，作为单测数据源。

### 5.4 废弃 `aes_encryption.dart`

safenotes 现有 `lib/encryption/aes_encryption.dart` 整体废弃，由 `crypto.dart` 取代。原文件中的 `encryptAES / decryptAES / deriveKeyAndIV` 不再使用。

### 5.5 依赖

`pubspec.yaml` 新增：

```yaml
dependencies:
  pointycastle: ^3.7.4   # AES-GCM + PBKDF2
  uuid: ^4.3.3           # UUIDv4 生成
  http: ^1.2.0           # SyncClient
```

`safenotes` 现有 `encrypt` 包可移除（仅旧 AES-CBC 用到）。

---

## 6. Keystore 与主密钥架构

### 6.1 密钥层次

完全对齐 litenotes `Keystore.cs`（[Keystore.cs](file:///C:/Home/Projects/litenotes/SimpleBox.Core/Keystore.cs)）：

```
MK (Master Key, 32 字节纯随机)
   │  真正加密笔记的密钥，创建笔记本时生成一次，永不改变
   │
   ▼
KEK = PBKDF2(password, salt='safenotes-v1', 200000)
   │  唯一用途：包裹 MK
   │
   ▼
WrappedMk = AES-256-GCM(KEK, MK, AAD="litenotes-mk-v1")
   │  落盘 / 同步到服务端的密文形态
   │
   ▼
Keystore JSON = { v, kdf, iter, salt, wrappedMk }
```

**好处**：
- 改密码只需用新 KEK 重新 wrap 同一把 MK，笔记零重加密（毫秒级）
- 多端同步时把 Keystore 作为普通条目推送，新设备凭相同密码派生 KEK 解开 MK 即可解全部笔记
- 密码错误由 GCM 校验失败天然检测

### 6.2 新文件 `lib/encryption/keystore.dart`

```dart
class Keystore {
  static const int formatVersion = 1;
  static final Uint8List wrapAad = Uint8List.fromList('litenotes-mk-v1'.codeUnits);

  final Uint8List kdfSalt;
  final int iterations;
  final Uint8List wrappedMk;

  Keystore._(this.kdfSalt, this.iterations, this.wrappedMk);

  /// 创建全新 keystore：随机生成 MK，用密码派生 KEK 包裹
  static (Keystore, Uint8List mk) createNew(String password, {int iterations = Crypto.defaultIterations}) { ... }

  /// 用密码包裹给定 MK（改密码用）
  static Keystore wrapMk(Uint8List mk, String password, {int iterations = Crypto.defaultIterations}) { ... }

  /// 用密码解开 MK，密码错误抛 WrongPasswordException
  Uint8List unwrapMk(String password) { ... }

  /// 校验密码（不返回 MK）
  bool verifyPassword(String password) { ... }

  /// 序列化为 JSON（同步协议里的 keystore 载荷，全字段为盐/密文，无敏感明文）
  String toJson() { ... }

  /// 从 JSON 反序列化
  static Keystore fromJson(String json) { ... }
}
```

### 6.3 笔记加密信封

每条笔记用 MK 加密，AAD 绑定笔记 id（防止密文行间挪用）：

```
envelope = Crypto.Seal(
  key = MK,
  aad = UTF8(id),
  plaintext = UTF8(JSON({ "name": ..., "content": ... }))
)
```

对应 litenotes `NoteDatabase.EncryptBody`（[NoteDatabase.cs:314](file:///C:/Home/Projects/litenotes/SimpleBox.Core/NoteDatabase.cs#L314)）。

### 6.4 Keystore 同步

Keystore 作为一个特殊条目参与同步（见 [SyncEngine.cs:215-227](file:///C:/Home/Projects/litenotes/SimpleBox.Core/Sync/SyncEngine.cs#L215)）：

- `id = "keystore"`
- `contentType = "keystore"`
- `content = Keystore.toJson()`（**不加密**，本身已是密文形态）
- 首次同步先推 keystore
- 第二台设备首次同步先拉 keystore，用本机密码解 MK，解不开即"密码不一致"中止
- 改密码后 `KeystoreHash` 变化 → 自动重推

### 6.5 解锁流程改造

safenotes 现有解锁流程：用户输口令 → 校验 hash → `PhraseHandler.initPass`。

改造后：
1. 用户输口令
2. 从 meta 表读 keystore
3. `keystore.unwrapMk(password)` → 失败则密码错误
4. 成功则持有 MK 与口令（口令仍用于其他需要的位置，如 keystore 重包装时）
5. `Vault` 进入已解锁状态，加载笔记明文到内存

`lib/models/session.dart` 中的 `Session` 类需扩展：持有 `Vault` 实例（包含 MK、Keystore、内存文档），锁定时清零 MK。

---

## 7. 同步引擎（SyncEngine）

### 7.1 流程概览

完全对齐 litenotes `SyncEngine.cs`（[SyncEngine.cs](file:///C:/Home/Projects/litenotes/SimpleBox.Core/Sync/SyncEngine.cs)），采用"先推后拉"：

```
Phase 0  准备
  读 sync_state → since = lastRev
  收集 dirty 集合（modified_at > localModified，或尚未推送的新建）

Phase 1  推送
  PUT /items（含 dirty 笔记 + keystore 若 hash 变化）
  - ok       → 更新 baseRev / localModified / keystoreRev / keystoreHash
  - conflict → ForkConflict：本地版本保留原 id，服务端版本存为冲突副本（新 UUID）
              LocalModified 置 0 → 下轮以 baseRev=server.Rev 重新推送覆盖服务端
              冲突副本作为新建加入下一轮推送

Phase 2  拉取
  GET /sync?since=lastRev
  对每条 item：
  - contentType == "keystore" → SetKeystore（MK 不变，笔记零重加密）
  - tracked && baseRev >= item.rev → 自己的回声，跳过
  - 本地有未同步编辑 → 冲突 fork（服务端版本存为副本）
  - 否则 → MergeRemoteNote（覆盖或新建；墓碑则本地置墓碑）

Phase 3  收尾
  持久化：并入的笔记与冲突副本写回本地库
  更新 sync_state（lastRev / items）
```

### 7.2 新文件 `lib/sync/sync_engine.dart`

```dart
class SyncEngine {
  static const String keystoreItemId = 'keystore';
  static const String noteType = 'note';
  static const String keystoreType = 'keystore';

  final Vault _vault;
  final NoteDatabase _db;
  final ISyncTransport _transport;

  SyncEngine(this._vault, this._db, this._transport);

  Future<SyncOutcome> runAsync(String token, SyncState state, {CancelToken? cancelToken}) async {
    final outcome = SyncOutcome();
    int decryptFailures = 0;

    // ===== 推送 =====
    final pushItems = await _buildPushItemsAsync(state);
    if (pushItems.isNotEmpty) {
      final result = await _transport.pushAsync(pushItems, token);
      if (result.status == PushStatus.transportError) {
        outcome.error = '无法连接同步服务器（网络或认证失败）';
        return outcome;
      }
      // ... 处理 results：ok / conflict
    }

    // ===== 拉取 =====
    long since = state.lastRev;
    bool hasMore = true;
    while (hasMore) {
      final resp = await _transport.pullAsync(since, token);
      for (final item in resp.items) {
        // keystore / 回声 / 冲突 fork / 普通合并 / 墓碑
      }
      state.lastRev = resp.syncToken;
      since = resp.syncToken;
      hasMore = resp.hasMore;
    }

    // ===== 收尾 =====
    if (outcome.pushed > 0 || outcome.conflicts > 0 || outcome.pulled > 0) {
      await _vault.saveAsync();
    }
    await _vault.withSaveLockAsync(() => _vault.saveSyncState(state));

    return outcome;
  }
}
```

### 7.3 关键决策（与 litenotes v1.1 一致）

1. **回声过滤**：`baseRev >= item.rev` 即跳过，**不**在 push 后快进 `lastRev`（避免漏拉其他设备夹在中间的变更）
2. **冲突策略**：纯 fork，不做"按 updatedAt 选主"。本地版本始终保留原 id 继续推送，服务端版本存为冲突副本（名称加「 (冲突)」后缀，重名递增「 (冲突 2)」）
3. **删除 vs 编辑**：编辑优先。远端墓碑到达时若本地 dirty，保留本地编辑并继续推送，不执行删除
4. **墓碑时间戳**：远端并入的删除，`modified_at` 沿用服务端 `updatedAt`，避免被误判 dirty 而回声风暴
5. **keystore 检测**：用 SHA-256(keystore JSON) 检测密码变更，hash 变化即重推
6. **解密失败容错**：密钥不匹配的条目跳过，不中断同步，最后汇总提示

### 7.4 ISyncTransport 抽象

```dart
abstract class ISyncTransport {
  Future<SyncPullResult> pullAsync(int since, String token, {CancelToken? cancelToken});
  Future<PushResult> pushAsync(List<PushItem> items, String token, {CancelToken? cancelToken});
}

class PushResult {
  final PushStatus status;   // ok / conflict / transportError
  final SyncPushResult body;
}

enum PushStatus { ok, conflict, transportError }
```

单测用 `FakeServer` 实现 `ISyncTransport`（参见 litenotes [SyncTests.cs:42](file:///C:/Home/Projects/litenotes/SimpleBox.Tests/SyncTests.cs#L42)）。

---

## 8. 同步传输（SyncClient）

### 8.1 新文件 `lib/sync/sync_client.dart`

基于 `package:http` 实现，对应 C# [SyncClient.cs](file:///C:/Home/Projects/litenotes/SimpleBox.Core/Sync/SyncClient.cs)：

```dart
class SyncClient implements ISyncTransport {
  final http.Client _http;
  final String _baseUrl;

  SyncClient(this._baseUrl, {http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  @override
  Future<SyncPullResult> pullAsync(int since, String token, {CancelToken? cancelToken}) async {
    final resp = await _http.get(
      Uri.parse('$_baseUrl/sync?since=$since'),
      headers: _authHeaders(token),
    );
    _ensureOk(resp);
    return SyncPullResult.fromJson(jsonDecode(resp.body));
  }

  @override
  Future<PushResult> pushAsync(List<PushItem> items, String token, {CancelToken? cancelToken}) async {
    final resp = await _http.put(
      Uri.parse('$_baseUrl/items'),
      headers: { ..._authHeaders(token), 'Content-Type': 'application/json' },
      body: jsonEncode({ 'items': items.map((e) => e.toJson()).toList() }),
    );
    final body = SyncPushResult.fromJson(jsonDecode(resp.body));
    final status = switch (resp.statusCode) {
      200 => PushStatus.ok,
      409 => PushStatus.conflict,
      _   => PushStatus.transportError,
    };
    return PushResult(status: status, body: body);
  }

  Map<String, String> _authHeaders(String token) =>
      token.isEmpty ? {} : {'Authorization': 'Bearer $token'};

  void _ensureOk(http.Response resp) {
    if (resp.statusCode != 200) {
      throw SyncException('HTTP ${resp.statusCode}: ${resp.body}');
    }
  }

  void close() => _http.close();
}
```

### 8.2 协议数据模型

新文件 `lib/sync/sync_models.dart`，对应 C# [SyncModels.cs](file:///C:/Home/Projects/litenotes/SimpleBox.Core/Sync/SyncModels.cs)：

```dart
class ServerItem {
  final String id;
  final String content;
  final String contentType;
  final bool deleted;
  final int updatedAt;
  final int rev;
  // fromJson / toJson
}

class PushItem {
  final String id;
  final String content;
  final String contentType;
  final bool deleted;
  final int updatedAt;
  final int? baseRev;    // null 表示新建
  // toJson 时 baseRev==null 不序列化
}

class PushItemResult {
  final String id;
  final String status;   // "ok" | "conflict"
  final int rev;
  final ServerItem? server;
}

class SyncPushResult {
  final List<PushItemResult> results;
  final int syncToken;
}

class SyncPullResult {
  final List<ServerItem> items;
  final int syncToken;
  final bool hasMore;
}

class SyncOutcome {
  int pushed = 0;
  int pulled = 0;
  int conflicts = 0;
  String? error;
  bool get success => error == null;
}
```

### 8.3 服务器地址与 HTTPS

- 用户在设置页填写 `serverUrl`，如 `https://sync.example.com` 或 `http://192.168.1.10:8787`
- 自签证书：默认校验失败。可选方案——MVP 阶段仅支持系统信任的证书或局域网 HTTP；自签证书支持作为后续增强
- 超时：30 秒（与 C# 端一致）

---

## 9. 同步状态与配置

### 9.1 SyncState

对应 C# [SyncState.cs](file:///C:/Home/Projects/litenotes/SimpleBox.Core/Sync/SyncState.cs)，持久化在 meta 表 `sync_state`：

```dart
class SyncState {
  int lastRev = 0;                              // GET /sync 的 since 游标
  int keystoreRev = 0;                          // keystore 在服务端的 rev
  String? keystoreHash;                         // keystore JSON 的 SHA-256（检测密码变更）
  Map<String, ItemState> items = {};            // 每条笔记的同步进度

  static SyncState fromJson(String json) { ... }
  String toJson() { ... }

  static String hashKeystore(String keystoreJson) {
    // SHA-256(keystoreJson) → 小写十六进制
  }
}

class ItemState {
  int baseRev;          // 上次确认的服务端 rev
  int localModified;    // 上次成功推送时的本地 modified_at（0 表示从未推送）
}
```

### 9.2 dirty 判定

**显式基线，不用时间比较**（与 litenotes v1.1 一致，见 §15.2 ③）：

```
note.dirty ⟺ note.modifiedAt != syncState.items[note.id].localModified
            或 note.id 不在 items 中（新建未推送）
```

### 9.3 SyncSettings（用户偏好）

对应 C# [AppConfig.cs](file:///C:/Home/Projects/litenotes/SimpleBox.App/Infrastructure/AppConfig.cs) 的 `SyncSettings`，但 safenotes 用 `SharedPreferences`：

```dart
class SyncSettings {
  bool enabled = false;             // 默认关闭
  String serverUrl = '';
  String token = '';
  bool autoSync = true;
  int intervalMinutes = 10;
}
```

存 `SharedPreferences` 的键：

| key | 类型 | 默认 |
|---|---|---|
| `sync_enabled` | bool | false |
| `sync_server_url` | String | '' |
| `sync_token` | String | '' |
| `sync_auto` | bool | true |
| `sync_interval_minutes` | int | 10 |

**进度跟随 vault 走**（在 notes.db 的 sync_state），**偏好跟随设备走**（在 SharedPreferences）——与 litenotes 一致。这样更换设备时偏好需重设，但同步进度不丢。

---

## 10. UI 集成

UI 改动很小，三处：

### 10.1 设置页新增"同步"分组

`lib/views/settings/settings.dart` 增加一组：

- 启用同步（`SwitchListTile`，默认关）
- 服务器地址（`TextField`，仅启用后可编辑）
- 同步令牌（`TextField`，obscure）
- 自动同步（`SwitchListTile`）
- 同步间隔（下拉选择：1/5/10/30 分钟）
- "测试连接"按钮 → 调 `GET /health`，弹 SnackBar 显示结果
- "立即同步"按钮 → 触发 `SyncService.syncNow()`

### 10.2 状态栏同步图标

`lib/views/home.dart` 的 `AppBar.actions` 加一个 `IconButton`：

- 同步中：`Icons.sync` + 旋转动画
- 已同步：`Icons.cloud_done`，长按显示"已同步 HH:mm"
- 同步失败：`Icons.sync_problem`，长按显示错误
- 未启用：不显示

点击触发立即同步。同步状态由 `SyncService.statusStream`（`Stream<SyncStatus>`）驱动，`HomePage` 监听并 `setState`。

### 10.3 冲突提示

同步结束后若有冲突，弹 `SnackBar`："发现 N 处冲突，已保留副本"，点击跳转到搜索" (冲突)"过滤的笔记列表。

UI 上不内置 diff 算法，冲突副本与原笔记并排存在，由用户自行取舍。

### 10.4 隐私政策与文案

safenotes README 与 privacy-policy.md 明确宣传"完全匿名、无入站出站请求"。启用同步后这一承诺不再成立。处理方式：

- 设置页"启用同步"开关上方加显著提示："启用同步后，应用会向你配置的服务器发送加密数据。服务端无法解密内容，但能感知笔记数量与修改时间。"
- `privacy-policy.md` 增补"同步功能"小节
- README Features 中"Completely anonymous no inbound and outbound request"改为"同步为可选功能，默认关闭；启用后仅与你配置的服务器通信"

---

## 11. 触发与并发

### 11.1 触发时机

| 时机 | 实现 |
|---|---|
| App 解锁后 | `Session` 解锁成功 → `SyncService.start()` → 立即一次同步 |
| 笔记保存后 | `NotesDatabase.encryptAndUpdate` 后防抖 3 秒触发 |
| 手动按钮 | 状态栏图标点击 / 设置页"立即同步" |
| 定时轮询 | `Timer.periodic` 按 `intervalMinutes` 触发（仅 autoSync=true） |

### 11.2 互斥与并发纪律

`SyncService` 持有 `Mutex`（或 `Completer`）保证同一时刻只有一轮同步：

```dart
class SyncService {
  final Mutex _gate = Mutex();

  Future<void> syncNow() async {
    if (!await _gate.acquire(timeout: Duration.zero)) return;  // 已有同步在进行
    try {
      // ... 调 SyncEngine.runAsync
    } finally {
      _gate.release();
    }
  }
}
```

**数据库访问串行化**：sqflite 单连接，SyncEngine 的所有 DB 访问需与 UI 编辑/保存串行。引入 `Vault.withSaveLockAsync(action)` 包装，对应 C# [Vault.cs:191](file:///C:/Home/Projects/litenotes/SimpleBox.Core/Vault.cs#L191)：

```dart
Future<T> withSaveLockAsync<T>(Future<T> Function() action) async {
  await _saveLock.acquire();
  try {
    return await action();
  } finally {
    _saveLock.release();
  }
}
```

UI 编辑保存、SyncEngine 读写数据库都走这把锁。

### 11.3 锁定与生命周期

- App 锁定（`Session.logout()`）时销毁 `SyncService`：停定时器、关 `SyncClient`、清空 MK
- 同步进行中用户锁定：当前同步完成后才退出（不强制中断，避免半完成状态）
- 同步是后台增值功能，任何失败都不应影响本地编辑——所有异常在 `SyncService` 层捕获，转为状态事件

---

## 12. 服务端复用

### 12.1 直接复用

litenotes 的 Go 服务端（[server/go/](file:///C:/Home/Projects/litenotes/server/go)）无需任何改动即可使用。端点：

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/health` | 健康检查 + 返回当前 syncToken |
| GET | `/sync?since=N&limit=M` | 增量拉取 rev > N 的条目 |
| PUT | `/items` | 批量 upsert + 乐观锁 |
| GET | `/items/{id}` | 取单条 |

### 12.2 部署

- 编译：`cd server/go && go build -o wsns`
- 配置：`config.json`（参见 [config.example.json](file:///C:/Home/Projects/litenotes/server/go/config.example.json)）
- 运行：`./wsns -config config.json`
- systemd 服务：参考 `wsns.service.example`

### 12.3 鉴权

服务端配置 `token` 字段；客户端在设置页填同一 token。
- 服务端未配 token → 免鉴权（内网自用）
- 服务端配了 token → 客户端必须填一致 token，否则 401

### 12.4 墓碑清理

服务端默认 90 天后物理清理墓碑，推进 `pruned_through_rev`。客户端 since 早于该值时返回 410，需要全量对账。

**MVP 阶段**：410 全量对账路径暂不实现（与 litenotes v1.1 §15.2 ⑧ 一致），单用户数据量小，墓碑清理可推迟。客户端收到 410 时报错"同步进度过旧，需重新对账"，提示用户手动处理（重新登录或重置同步状态）。

---

## 13. 测试策略

### 13.1 单元测试（Windows 上 `flutter test`）

**核心：70% 的逻辑能用单测覆盖，秒级反馈。**

| 测试文件 | 覆盖 | 用例数 |
|---|---|---|
| `test/crypto_test.dart` | PBKDF2 / AES-GCM 与 C# 测试向量互解 | ~5 |
| `test/keystore_test.dart` | wrap / unwrap / 改密码 / 密码错误 | ~4 |
| `test/sync_models_test.dart` | JSON 序列化往返 | ~3 |
| `test/sync_state_test.dart` | 状态序列化往返 | ~2 |
| `test/sync_engine_test.dart` | 同步流程（用 FakeServer） | 9（翻译自 [SyncTests.cs](file:///C:/Home/Projects/litenotes/SimpleBox.Tests/SyncTests.cs)） |
| `test/database_test.dart` | CRUD、墓碑、sync_state 持久化 | ~6 |

### 13.2 SyncEngine 9 个核心用例（翻译自 C# 单测）

| 用例 | 验证点 |
|---|---|
| FirstSync_PushesNotesAndKeystore | 首次同步推送笔记 + keystore，进度持久化 |
| SecondSync_NoChanges_IsNoOp | 二次同步无变化时无推拉（回声过滤生效） |
| TwoDevices_NotePropagates | 双端笔记传播，并入笔记不被误判回推 |
| ConcurrentEdit_ForksConflictCopy_AndConverges | 并发编辑 → fork → 双端收敛 |
| RemoteDelete_Propagates_WithoutEchoRepush | 远端删除传播，墓碑不回推 |
| PasswordChange_KeystorePropagates | 改密码后 keystore 同步，新设备用新密码解锁 |
| EmptyToken_AllowedForNoAuthServer | 空 token 在无鉴权服务器上正常工作 |
| GetSyncItems_IncludesTombstones | GetSyncItems 包含墓碑行 |
| SyncState_RoundTrip | SyncState 序列化往返 |

### 13.3 端到端测试（手动 + 集成测试）

- 启动本地 Go 服务器
- Dart 客户端单测中通过 `http.Client` 直连本地服务器，跑 push/pull/conflict 全流程
- 与 C# 客户端互测：C# 推 → Dart 拉；Dart 推 → C# 拉；两端并发 → fork 收敛

### 13.4 平台/UI 测试（真机或模拟器）

- 设置页配置流程：填地址 → 测试连接 → 保存 → 状态栏显示"已同步"
- 触发时机：解锁后自动同步、保存后防抖、手动按钮、定时轮询
- 冲突提示 SnackBar 展示与跳转
- 后台/前台切换行为（不实现后台同步，仅观察前台恢复后是否触发）

---

## 14. 分步实施计划

### 阶段 1：加密层与 Keystore（基础设施）

**目标**：在 Windows 上 `flutter test` 全绿，加密与 C# 端互解。

1. 新建 `lib/encryption/crypto.dart`，实现 PBKDF2 + AES-GCM
2. 导出 C# 端测试向量到 `test/crypto_vectors.dart`
3. 写 `test/crypto_test.dart`，比对密文逐字节一致
4. 新建 `lib/encryption/keystore.dart`，实现 wrap/unwrap/toJson/fromJson
5. 写 `test/keystore_test.dart`
6. 新建 `lib/models/exceptions.dart`，定义 `WrongPasswordException`、`CorruptedException`

### 阶段 2：数据层改造

**目标**：新数据库 schema 与 CRUD 全部可用。

1. 重写 `lib/models/safenote.dart`：UUID 主键、新字段
2. 重写 `lib/data/database_handler.dart`：新 schema、meta 表、软删除、`getSyncItems`、`saveChanges`、`loadSyncState`/`saveSyncState`、`loadKeystore`/`saveKeystore`
3. 新建 `lib/models/vault.dart`：`Vault` 类，持有 MK、Keystore、内存文档、保存锁，提供 `createNote`/`findNote`/`updateContent`/`deleteNote`/`saveAsync`/`withSaveLockAsync`/`tryDecodeEnvelope`/`mergeRemoteNote`/`createConflictCopy`/`setKeystore`
4. 写 `test/database_test.dart`、`test/vault_test.dart`

### 阶段 3：同步引擎与传输

**目标**：9 个核心单测全绿。

1. 新建 `lib/sync/sync_models.dart`
2. 新建 `lib/sync/sync_state.dart`
3. 新建 `lib/sync/sync_transport.dart`（接口 + `FakeServer` 测试实现）
4. 新建 `lib/sync/sync_engine.dart`
5. 翻译 [SyncTests.cs](file:///C:/Home/Projects/litenotes/SimpleBox.Tests/SyncTests.cs) 9 个用例到 `test/sync_engine_test.dart`
6. 新建 `lib/sync/sync_client.dart`，基于 `package:http`
7. 写 `test/sync_client_test.dart`，连本地 Go 服务器跑端到端

### 阶段 4：UI 集成与触发

**目标**：真机上同步可用。

1. `lib/data/preference_and_config.dart` 增加 `SyncSettings` 存取
2. 新建 `lib/services/sync_service.dart`：定时器、防抖、互斥、状态广播
3. `lib/views/settings/` 新增同步设置子页
4. `lib/views/home.dart` AppBar 加同步状态图标
5. 冲突提示 SnackBar
6. `Session` 解锁流程改造：`keystore.unwrapMk` → 持有 `Vault` → 启动 `SyncService`
7. `Session.logout` 改造：销毁 `SyncService` → 清零 MK

### 阶段 5：联调与文档

1. 与 C# 客户端互测
2. 隐私政策、README 文案更新
3. 真机回归测试

---

## 15. 明确不做的事

### 15.1 MVP 不做

- **后台同步**：不做 WorkManager / 前台服务 / Doze 友好。同步失败就等下次 App 在前台时重试，数据不会丢。
- **断网重试退避**：失败即报错，下次触发时再试。不实现指数退避、不实现离线队列。
- **410 全量对账**：服务端墓碑清理触发的 410 路径暂不实现，单用户数据量小。
- **冲突 diff UI**：只 fork 保留副本，不做 3-way diff、不做合并 UI。
- **LWW 设置项**：不做"最后写入胜出"模式，只做 fork。
- **自签证书支持**：MVP 仅支持系统信任的证书或局域网 HTTP。
- **增量分页**：协议支持 `limit + hasMore`，但纯文本场景单次响应足够，MVP 不分页。

### 15.2 后续可选

- 后台同步（WorkManager + 前台服务）
- 410 全量对账
- 冲突 diff UI
- 自签证书 / 客户端证书
- 多 vault 支持
- 墓碑清理后的客户端清理

### 15.3 永不做

- **存量数据迁移**：fork 项目从零启动，不读旧 safenotes 数据库
- **旧加密格式兼容**：旧的 AES-CBC 加密彻底废弃
- **服务端解密/合并**：服务端永远只搬运不透明密文

---

## 16. 风险与对策

### 16.1 加密互解不一致（最高风险）

**风险**：`pointycastle` 的 GCM 实现与 .NET `AesGcm` 在 tag 位置、IV 长度约定、AAD 处理上可能存在差异，导致 Dart 加密的密文 C# 解不开。

**对策**：
- 实施前先写测试向量，固定 `(password, salt, nonce, plaintext, aad)` 比对密文
- 实现时严格按 litenotes `Crypto.cs` 的信封格式：`nonce(12) ‖ ciphertext ‖ tag(16)`
- 如 `pointycastle` 行为不一致，可改用 `cryptography` 包或自行拼接 GCM 原语

### 16.2 sqflite 并发访问

**风险**：SyncEngine 与 UI 自动保存并发访问单连接 sqflite，可能锁错误或数据错乱。

**对策**：
- 所有 DB 访问经 `Vault.withSaveLockAsync` 串行化
- SyncEngine 内不直接持有 `_db`，通过 `Vault` 间接访问
- 单测覆盖"同步进行中用户编辑"场景

### 16.3 隐私承诺冲突

**风险**：safenotes 用户因"无网络请求"选择此 App，启用同步后体验冲突。

**对策**：
- 同步默认关闭
- 启用前显著提示
- 隐私政策增补
- 不主动联网：未配置 serverUrl 时 `SyncClient` 不创建，`http` 包不引入热路径

### 16.4 服务端单点

**风险**：单 JSON / 单 SQLite 服务端，无副本。

**对策**：服务端建议每日备份 `litenotes-sync.db`；客户端数据本地始终完整，服务端丢失最多丢失"其他设备的最新变更"，已同步数据不受影响。

### 16.5 Flutter 端 MK 内存泄漏

**风险**：MK 长期驻留内存，被 swap 出或被 dump。

**对策**：
- `Vault` 持有 MK 为 `Uint8List`，锁定时 `fillRange(0, len, 0)` 清零
- 不把 MK 写入 SharedPreferences 或任何持久存储（仅以 wrapped 形态存 meta 表）
- 不打印 MK、不上传 MK 到日志服务

---

## 附：与 litenotes 协议的字段对照表

| 概念 | litenotes C# | safenotes Dart（目标） |
|---|---|---|
| 笔记 id | `Note.Id` (string UUID) | `SafeNote.id` (String UUID) |
| 笔记名称 | `Note.Name` | `SafeNote.name` |
| 笔记正文 | `Note.Content` | `SafeNote.content` |
| 创建时间 | `Note.CreatedAt` (long) | `SafeNote.createdAt` (int) |
| 修改时间 | `Note.ModifiedAt` (long) | `SafeNote.modifiedAt` (int) |
| 墓碑标记 | `notes.deleted` (int 0/1) | `SafeNote.deleted` (bool) |
| 主密钥 | `Vault._mk` (byte[]) | `Vault._mk` (Uint8List) |
| Keystore | `Keystore` 类 | `Keystore` 类 |
| 同步状态 | `SyncState` 类 | `SyncState` 类 |
| 单条进度 | `ItemState` 类 | `ItemState` 类 |
| 同步引擎 | `SyncEngine` 类 | `SyncEngine` 类 |
| 传输抽象 | `ISyncTransport` 接口 | `ISyncTransport` 抽象类 |
| HTTP 客户端 | `SyncClient` (System.Net.Http) | `SyncClient` (package:http) |
| 应用层服务 | `SyncService` (SimpleBox.App) | `SyncService` (lib/services) |
| 用户偏好 | `SyncSettings` (AppConfig) | `SyncSettings` (SharedPreferences) |
| 数据库 | `NoteDatabase` (Microsoft.Data.Sqlite) | `NotesDatabase` (sqflite) |
| 加密原语 | `Crypto` (System.Security.Cryptography) | `Crypto` (pointycastle) |

---

## 附：代码量估算

| 模块 | 文件 | 行数估算 |
|---|---|---|
| 加密层 | `crypto.dart` | 150 |
| Keystore | `keystore.dart` | 120 |
| 数据模型 | `safenote.dart` (改造) | 80 |
| 数据库 | `database_handler.dart` (重写) | 200 |
| Vault | `vault.dart` | 250 |
| 同步数据类 | `sync_models.dart` | 80 |
| 同步状态 | `sync_state.dart` | 60 |
| 同步引擎 | `sync_engine.dart` | 300 |
| 同步传输 | `sync_client.dart` | 100 |
| SyncService | `sync_service.dart` | 120 |
| SyncSettings | `preference_and_config.dart` (扩展) | 50 |
| UI 集成 | `settings.dart` + `home.dart` (扩展) | 200 |
| 异常类 | `exceptions.dart` | 30 |
| 单测 | `test/*.dart` | 400 |
| **合计** | | **~2140 行** |

不含测试约 1740 行，含测试约 2140 行。比从零设计省约 30%，主要节省在协议设计、服务端、参考实现三方面。

---

*本文档基于 litenotes v1.1 实现（2026-07-27）编写。实施过程中如遇协议细节与本描述不一致，以 `litenotes/docs/sync-design.md` §15 与 litenotes 实际代码为准。*
