# SafeNotes 同步协议规范 v2

> 客户端侧同步协议规范，涵盖加密格式、manifest 结构、冲突解决、同步算法、多后端隔离。
> 设计背景：[simplified-sync-design.md](./simplified-sync-design.md)。
>
> **文档分工**：
> - 本文档为**完整的客户端侧协议规范**，描述与具体后端无关的同步语义（加密、冲突解决、LWW、墓碑传播等）以及三种后端的传输层差异。
> - 如果想实现一个 SafeServer 服务端，请阅读自包含的 **[服务端 API 规范](./server-api-spec.md)**，无需本文档。
> - 如果想接入现有的 WebDAV 云盘，本文档 §四.2 描述的存储布局与 WebDAV 一致，可直接使用。

---

## 〇、多后端架构

SafeNotes 客户端支持三种同步后端，各自走独立协议：

| 后端类型 | 协议规范 | 适用场景 |
|---------|---------|---------|
| `localFs` | 文件系统（dart:io） | 单设备离线、单元测试 |
| `webdav` | [WebDAV (RFC 4918)](https://datatracker.ietf.org/doc/html/rfc4918) | 用户已有的云盘（坚果云/NextCloud/ownCloud 等） |
| `safeServer` | [服务端 API 规范](./server-api-spec.md) v2 | 自建轻量同步服务 |

**本文档描述的同步语义（manifest 格式、加密、冲突解决、LWW、墓碑传播）对所有后端类型通用**。差异仅在传输层：
- `webdav` 后端：manifest 路径为 `<用户URL>/safenotes-vault/manifest.json`（客户端自动附加 `safenotes-vault` 子目录避免污染根目录），blob 路径为 `<用户URL>/safenotes-vault/blobs/<hash>`。需要 MKCOL 创建目录、用 Basic Auth。
- `safeServer` 后端：manifest 路径为 `<serverUrl>/api/v2/manifest`，blob 路径为 `<serverUrl>/api/v2/blob/<hash>`。无 MKCOL、用 Bearer Token。
- `localFs` 后端：直接读写文件系统，manifest 在 `<rootPath>/manifest.json`、blob 在 `<rootPath>/blobs/<hash>`。

每种后端的 `SyncBackend` 实现负责把统一接口映射到具体协议，SyncEngine 不关心后端类型。

---

## 一、设计原则

1. **零知识**：所有后端只存储密文，不接触明文、密钥、密码。
2. **无状态**：后端不维护会话、不维护版本计数器、不清理墓碑。
3. **后端无关**：同步语义（manifest 比对、LWW、加密）与具体后端解耦，可同时支持 WebDAV/SafeServer/LocalFS。
4. **内容寻址**：blob 按 SHA-256 哈希命名，天然去重、幂等。
5. **单点真相**：一个 vault 一个 manifest，全局唯一，乐观锁保护。

---

## 二、术语

| 术语 | 含义 |
|------|------|
| **vault** | 一个独立的同步域，由 `vaultId`（UUIDv4）唯一标识。 |
| **manifest** | vault 的元数据清单，包含所有笔记的 hash、删除状态、更新时间。整个 manifest 用 dataKey 加密后存储。 |
| **blob** | 单条笔记的加密信封，按内容 hash 寻址。 |
| **ETag** | manifest 的版本标识，由服务端生成，用于乐观锁。 |
| **dataKey** | 数据主密钥（32 字节随机），加密所有 blob 和 manifest。永不变化。 |
| **MK** | Master Key，由用户密码派生，仅用于加密 dataKey。 |
| **envelope** | AES-256-GCM 加密后的笔记密文（nonce ‖ ciphertext ‖ tag）。 |

---

## 三、存储模型

服务端为每个 vault 维护如下存储布局：

```
<vault-root>/
├── manifest.json      # manifest 密文（二进制），单文件
└── blobs/
    ├── <hash-1>       # 按 SHA-256 哈希命名的 blob 文件
    ├── <hash-2>
    └── ...
```

- `manifest.json` 是整个 vault 的唯一同步协调点，**必须**支持 ETag 乐观锁。
- `blobs/<hash>` 是内容寻址的不可变文件，相同 hash 的 PUT 幂等。
- 服务端**不**解释 manifest.json 和 blob 的内容（全是密文）。
- 服务端**不**维护版本号、不清理孤儿 blob、不删除墓碑。

---

## 四、传输层（HTTP API）

三种后端的传输层差异较大，但同步语义（manifest 比对、LWW、加密）完全一致。本节按后端类型分别描述。

### 4.1 通用语义（所有后端共享）

以下语义对所有后端一致：

- **manifest 乐观锁**：PUT manifest 时带 `If-Match`（更新已有）或 `If-None-Match: *`（首次上传），冲突返回 412。
- **ETag**：manifest 的版本标识，每次 PUT 成功后必须变化。必须是强 ETag（不带 `W/` 前缀）。
- **blob 幂等**：相同 hash + 内容多次 PUT 结果一致。
- **零知识**：后端不解析 manifest/blob 内容，不校验 hash，不维护笔记列表。
- **412 是正常信号**：不是错误，客户端收到后重新 GET 并重试。

### 4.2 WebDAV 后端

适用于坚果云 / NextCloud / ownCloud / Apache mod_dav 等标准 WebDAV 服务。

**认证**：HTTP Basic Auth（RFC 7617）

```
Authorization: Basic <base64(username:password)>
```

**存储布局**：客户端在用户输入的 baseUrl 后自动附加固定子目录 `safenotes-vault`，避免污染用户网盘根目录：

```
<userUrl>/safenotes-vault/       # 客户端自动附加
├── manifest.json
└── blobs/
    └── <hash>
```

**端点**：

| 方法 | 路径 | 用途 | 乐观锁 |
|------|------|------|--------|
| MKCOL | `<userUrl>/safenotes-vault` | 创建 vault 目录（幂等） | — |
| MKCOL | `<userUrl>/safenotes-vault/blobs` | 创建 blobs 目录（幂等） | — |
| GET | `<userUrl>/safenotes-vault/manifest.json` | 获取 manifest | — |
| PUT | `<userUrl>/safenotes-vault/manifest.json` | 上传 manifest | If-Match / If-None-Match |
| GET | `<userUrl>/safenotes-vault/blobs/<hash>` | 下载 blob | — |
| PUT | `<userUrl>/safenotes-vault/blobs/<hash>` | 上传 blob | — |

**MKCOL 语义**：
- 201 Created：目录新建成功
- 405 Method Not Allowed：目录已存在（**幂等，不算错误**）
- 客户端在 `init()` 时调用两次 MKCOL 创建 vault-root 和 blobs 子目录

**子目录常量**：`kWebDavVaultSubdir = 'safenotes-vault'`（客户端固定常量，多设备共享时只要 baseUrl 一样即自动一致）

### 4.3 SafeServer 后端

适用于自建轻量同步服务，专为 SafeNotes 设计的纯 HTTP API。完整规范见 **[server-api-spec.md](./server-api-spec.md)**。

**认证**：Bearer Token（固定 Token，部署时配置）

```
Authorization: Bearer <token>
```

**存储布局**：无目录概念，单用户场景下整个 server 实例服务一个 vault：

```
<serverUrl>/api/v2/manifest       # manifest 资源
<serverUrl>/api/v2/blob/<hash>    # blob 资源
<serverUrl>/api/v2/health         # 健康检查（无需认证）
```

**端点**：

| 方法 | 路径 | 用途 | 乐观锁 | 认证 |
|------|------|------|--------|------|
| GET | `/api/v2/manifest` | 获取 manifest | — | 是 |
| PUT | `/api/v2/manifest` | 上传 manifest | If-Match / If-None-Match | 是 |
| GET | `/api/v2/blob/<hash>` | 下载 blob | — | 是 |
| PUT | `/api/v2/blob/<hash>` | 上传 blob | — | 是 |
| GET | `/api/v2/health` | 健康检查 | — | 否 |

**与 WebDAV 的差异**：
- 无 MKCOL（服务端自动创建存储空间）
- 无 vault-root 路径前缀（单用户，整个 server 即一个 vault）
- Bearer Token 而非 Basic Auth
- `/api/v2/` 路径前缀为未来版本预留扩展空间

### 4.4 LocalFs 后端

适用于单设备离线、单元测试。直接读写文件系统，无 HTTP 协议。

**存储布局**：

```
<rootPath>/
├── manifest.json
└── blobs/
    └── <hash>
```

**ETag 策略**：用文件内容的 SHA-256 作为强 ETag，与 WebDAV 语义一致。

**乐观锁实现**：PUT manifest 时读取当前文件算 hash 比对，不匹配抛 `ConflictException`。

---

## 五、manifest 格式

manifest 在客户端用 dataKey 加密后上传。**加密前**的明文 JSON 格式如下：

```json
{
  "version": 42,
  "vaultId": "550e8400-e29b-41d4-a716-446655440000",
  "updatedAt": 1719470000000,
  "encryptedDataKey": "base64-encoded-ciphertext",
  "items": {
    "550e8400-e29b-41d4-a716-446655440001": {
      "hash": "a1b2c3d4e5...",
      "deleted": false,
      "updatedAt": 1719460000000
    },
    "550e8400-e29b-41d4-a716-446655440002": {
      "hash": "f6g7h8i9j0...",
      "deleted": true,
      "updatedAt": 1719470000000
    }
  }
}
```

### 5.1 字段说明

| 字段 | 类型 | 含义 |
|------|------|------|
| `version` | int | manifest 版本号，每次成功 PUT 后 +1。仅用于调试，**不是乐观锁依据**。 |
| `vaultId` | string (UUIDv4) | vault 唯一标识，所有设备共享。 |
| `updatedAt` | int (Unix ms) | manifest 自身的更新时间。 |
| `encryptedDataKey` | string (base64) | 用 MK 加密后的 dataKey。改密码时只更新此字段。 |
| `items` | object | note-uuid → ManifestItem 映射。包含墓碑。 |

### 5.2 ManifestItem 字段

| 字段 | 类型 | 含义 |
|------|------|------|
| `hash` | string (hex) | 笔记内容的 SHA-256 哈希，同时是 blob 的寻址键。 |
| `deleted` | bool | 是否已删除（墓碑标记）。true 时不需要 blob。 |
| `updatedAt` | int (Unix ms) | 最后更新时间，用于 LWW 冲突解决。 |

### 5.3 加密

manifest 整体 JSON → UTF-8 字节 → AES-256-GCM 加密 → 密文二进制上传。

- 密钥：dataKey
- AAD（Additional Authenticated Data）：固定字符串 `"manifest"`（区别于单条笔记的 AAD=uuid）
- nonce：随机 12 字节
- 输出格式：`nonce(12) ‖ ciphertext ‖ tag(16)`

服务端只存储密文，不解释。

---

## 六、blob 格式（envelope）

每条笔记的明文内容加密后形成 envelope：

```
envelope = nonce(12) ‖ ciphertext ‖ tag(16)
         = AES-256-GCM(dataKey, nonce, AAD=note-uuid, plaintext)
```

- 密钥：dataKey（与 manifest 同一密钥）
- AAD：笔记的 UUID（防止重放攻击——把 A 的密文挪到 B 的位置会解密失败）
- nonce：随机 12 字节
- plaintext：笔记内容的 JSON 序列化字节

服务端只存储 envelope 二进制，不解释。

---

## 七、加密层（服务端无关，仅供客户端实现参考）

### 7.1 密钥层次

```
用户密码
  ↓ PBKDF2-HMAC-SHA256(password, salt='safenotes-v1' 固定常量, iterations=200000, dkLen=32)
MK (Master Key, 32 bytes)
  ↓ AES-256-GCM(MK, nonce, AAD="dataKey", dataKey)
encryptedDataKey (base64, 存在 manifest 里)
  ↓ 解密得到
dataKey (32 bytes, 随机生成, 永不变化)
  ↓ AES-256-GCM(dataKey, nonce, AAD=uuid/manifest, plaintext)
envelope / manifest 密文
```

### 7.2 改密码流程

```
1. 旧 MK 解 encryptedDataKey → dataKey
2. 新密码派生新 MK
3. 新 MK 加密 dataKey → 新 encryptedDataKey
4. 上传新 manifest（含新 encryptedDataKey，blob 零传输）
```

**O(1) 操作，一次 manifest PUT 原子完成**。

### 7.3 多设备协调

设备 B 同步时发现远端 `encryptedDataKey` 与本地不同，按以下逻辑处理：

```
1. checkMigrationNeeded(remoteEncryptedDataKey)
   - 远端 == 本地 → 无需迁移，继续正常同步
   - 远端 != 本地 → 用本地 MK 尝试解开远端 encryptedDataKey

2. MK 能解开远端 encryptedDataKey：
   - remoteDataKey == 本地 dataKey → 只更新本地 encryptedDataKey（他端改密码，本端用新密码登录）
     不需要 reEncryptAllNotes，O(1) 操作
   - remoteDataKey != 本地 dataKey → 执行 reEncryptAllNotes 迁移（新设备加入已存在同步组）
     事务保护，crash 安全；迁移后重新同步

3. MK 解不开远端 encryptedDataKey（密码不匹配）：
   - 尝试用本地 dataKey 解远端 manifest items
   - 成功 → 本地改密码还没推送，继续同步会上传新 encryptedDataKey
   - 失败 → 真正的密码不匹配，提示用户输入新密码
```

**关键场景**：
- **他端改密码，本端用新密码登录**：MK 匹配，dataKey 相同 → 只更新 encryptedDataKey，无需重加密笔记
- **本端改密码，还没同步**：MK 不匹配（本地是新 MK，远端是旧 encryptedDataKey），但 dataKey 能解远端 manifest → 继续同步，PUT 时推送新 encryptedDataKey
- **新设备加入同步组**：本地 dataKey 与远端不同 → reEncryptAllNotes 迁移所有本地笔记
- **密码真正不匹配**：MK 不匹配 + dataKey 不匹配 → 同步失败，提示用户重新登录

---

## 八、同步算法

### 8.1 主流程（5 步）

```
Step 1  GET /manifest.json
        → 200：用 dataKey 解密 → remoteManifest
        → 404：remoteManifest = null（首次同步）

Step 2  构建本地 manifest（从本地数据库读取所有笔记元数据）

Step 3  逐条比对 localManifest.items vs remoteManifest.items：
        - 仅本地有       → PUT blob + 加入 merged
        - 仅远端有       → GET blob → 解密 → 写本地 + 加入 merged
        - 双方都有，hash 相同 → 跳过，加入 merged
        - 双方都有，hash 不同 → LWW 冲突解决

Step 4  合并后的 manifest → dataKey 加密 → PUT /manifest.json（带 If-Match）

Step 5  PUT 成功 → 更新本地 manifest version + 标记所有笔记 synced
        PUT 返回 412 → 回到 Step 1 重试（最多 3 次）
```

### 8.2 LWW 冲突解决

```
remote.updatedAt > local.updatedAt → 远端胜（下载覆盖本地）
remote.updatedAt < local.updatedAt → 本地胜（上传覆盖远端）
remote.updatedAt == local.updatedAt 但 hash 不同 → 保留 hash 字典序小的（兜底）
```

**不做 fork**。LWW 落败的内容通过保留旧 hash 的 blob 可恢复（历史版本）。

### 8.3 墓碑处理

- 删除笔记 = 设置 `deleted=true`，不删除 blob。
- 墓碑在 manifest 里永久保留（或客户端 30 天后主动清理）。
- 远端墓碑传播到本地：本地笔记标记 `deleted=true`。
- 墓碑不需要 blob（`deleted=true` 的 item 没有 blob）。

---

## 九、错误处理

### 9.1 HTTP 状态码

| 状态码 | 客户端行为 | 适用后端 |
|--------|-----------|---------|
| 200 / 201 | 成功，继续 | 所有 |
| 401 | 认证失败，提示用户检查配置 | 所有 |
| 404 (GET manifest) | 首次同步，正常 | 所有 |
| 404 (GET blob) | blob 不存在，跳过本次，下次重试 | 所有 |
| 405 (MKCOL) | 目录已存在，正常 | WebDAV 仅 |
| 412 (PUT manifest) | 乐观锁冲突，重试 | 所有 |
| 5xx | 服务端错误，中止本次同步 | WebDAV / SafeServer |

### 9.2 重试策略

- 乐观锁冲突（412）：最多重试 3 次，每次重新 GET manifest。
- 网络错误：不重试，等下次同步触发。
- blob missing：跳过，下次同步再试。

### 9.3 幂等性

- `PUT blob`：相同 hash + 内容多次上传结果一致。
- `PUT manifest`：带相同 If-Match 的重复 PUT 会被 412 拒绝（已更新过）。
- `MKCOL`（WebDAV 仅）：已存在的目录返回 405，不影响正确性。

---

## 十、安全考量

1. **传输层**：生产环境必须使用 HTTPS。测试可用 HTTP。
2. **认证**：WebDAV 用 HTTP Basic Auth + HTTPS；SafeServer 用 Bearer Token（constant-time compare 校验）。两者都满足单用户场景的安全需求。
3. **零知识**：服务端永远不接触明文、密钥、密码。即使数据库泄露，攻击者只能看到密文。
4. **ETag 不泄露信息**：ETag 是密文的哈希，不泄露明文信息。
5. **blob 不可枚举**：blob 名是内容哈希，攻击者无法通过遍历获取笔记列表（需先拿到 manifest）。SafeServer 不提供 blob 列表接口。
6. **重放攻击**：GCM 的 AAD 绑定 uuid/manifest，防止密文挪用。
7. **路径穿越**：WebDAV/SafeServer 服务端用文件系统存储时必须校验 `<hash>` 不含 `..` 或路径分隔符。

---

## 十一、参考实现

| 实现 | 路径 | 语言 | 说明 |
|------|------|------|------|
| Flutter 客户端 | `lib/sync/` | Dart | 生产实现（含三种后端） |
| Go server | `server/go/main.go` | Go | SafeServer 参考实现，纯标准库 |
| Node.js server | `server/nodejs/server.js` | JavaScript | SafeServer 参考实现，纯内置模块 |
| LocalFs backend | `lib/sync/local_fs_backend.dart` | Dart | 本地文件系统后端（测试用） |
| FakeBackend | `test/sync/sync_engine_test.dart` | Dart | 内存 mock，单元测试用 |

**测试套件**：
- `test/sync/sync_engine_test.dart`：SyncEngine 单元测试（FakeBackend，覆盖 LWW/墓碑/乐观锁重试）
- `test/sync/local_fs_backend_test.dart`：LocalFs 后端单元测试
- `test/sync/safe_server_integration_test.dart`：SafeServer 集成测试（自动启动 Go/Node.js server 子进程，端到端验证）
- `test/sync/crypto_test.dart`：加密层单元测试
- `test/sync/vault_test.dart`：Vault 管理单元测试

---

## 十二、后端隔离（providerKey）

### 12.1 问题

客户端支持多种后端，用户可能中途切换后端类型或切换同类型的不同实例（如从 WebDAV 服务器 A 切到 B）。切换后，本地 manifest version 必须重置，否则：

- 新后端的 manifest version 从 0 开始，但本地记录的是旧后端的 version → 客户端误以为"远端落后"。
- 实际上切换后端等于换了一个全新的远端，本地应视为首次同步。

### 12.2 方案：providerKey 绑定

每个后端实例有一个 `providerKey`（16 字符哈希），用于隔离 manifest version：

```
providerKey = SHA-256("<backendType>:<baseUrl>")[:16]
```

各后端的 providerKey 计算方式：

| 后端 | providerKey 输入 | 示例 |
|------|-----------------|------|
| `localFs` | `"localFs:<rootPath>"` | `"localFs:/data/safenotes"` |
| `webdav` | `"webdav:<userBaseUrl>"` | `"webdav:https://dav.jianguoyun.com/dav/"` |
| `safeServer` | `"safeServer:<baseUrl>"` | `"safeServer:http://192.168.1.118:2025"` |

### 12.3 存储

本地数据库的 manifest version 按 providerKey 隔离存储：

```
meta 表：
  key = "manifest_version:<providerKey>"
  value = "<version>"
```

切换后端时，新 providerKey 对应的 version 默认为 0（首次同步），旧 providerKey 的 version 保留在数据库中（切回来时可恢复）。

### 12.4 WebDAV 子目录常量

WebDAV 后端在用户输入的 baseUrl 后自动附加固定子目录 `safenotes-vault`：

```dart
const String kWebDavVaultSubdir = 'safenotes-vault';
```

- 多设备共享时只要 baseUrl 一样，子目录路径自动一致。
- providerKey 用**原始 baseUrl**（不含子目录）计算，因为子目录是固定的，区分后端只需看用户输入的 URL。

### 12.5 SafeServer 无子目录

SafeServer 是单用户设计，整个 server 实例服务一个 vault，不需要子目录隔离。providerKey 直接基于 `baseUrl` 计算。

---

## 十三、版本历史

| 版本 | 日期 | 变更 |
|------|------|------|
| v2 | 2026-07-28 | 多后端架构：§四 按后端类型分别描述传输层；新增 §十二 后端隔离（providerKey）；移除 MKCOL 作为通用要求（改为 WebDAV 仅）；认证方式按后端区分（Basic Auth / Bearer Token） |
| v1 | 2026-07-28 | 初版：4 个 HTTP 端点 + MKCOL + ETag 乐观锁 + manifest JSON 格式 |
