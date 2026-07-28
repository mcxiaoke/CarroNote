# 简化版 E2EE 笔记同步架构（备选方案）

> 来源：针对 litenotes 协议 review 后提出的简化方案
> 定位：safenotes fork 改造的备选架构，非最终方案
> 对照：[sync-feature-design.md](./sync-feature-design.md)（基于 litenotes 的方案）
> 初版日期：2026-07-27
> 修订 2026-07-28：
>   1. 新增"后端无关 + WebDAV 优先"设计（第七章），零服务端开发
>   2. dataKey 层从"可选"提升为默认架构（第四章），解决 WebDAV 下改密码的并发安全问题
>   3. 加入 Joplin 多密钥机制分析（§4.3，反面教材）
>   4. 移除 MVP 划分，改为"一次性完整实现 + 可选增强"（第十一、十四章）
>   5. 新增第十四章"可选增强"，明确列出按需添加的功能

---

## 一、设计目标

针对 litenotes 的痛点重新设计一个**更简单**的架构：

| litenotes 的复杂点 | 本方案的取舍 |
|---|---|
| rev 计数器 + baseRev + 回声过滤 | **去掉**：用 manifest + content hash |
| keystore 同步 + 冲突特判 | **去掉**：每设备独立输密码派生 MK，无 keystore 同步 |
| 乐观锁 + 409 + fork 流程 | **简化**：manifest 层乐观锁，note 层 LWW |
| 9 种同步分支（push/pull/echo/fork/keystore/墓碑…） | **简化**：3 种（下载/上传/删除） |
| 服务端 4 个端点 + 墓碑清理 + 410 对账 | **简化**：服务端无状态，4 个 KV 端点 |
| 墓碑 90 天清理 + pruned_through_rev | **去掉**：客户端管理墓碑，服务端永不删 |

## 二、参考的主流做法

| 借鉴对象 | 借鉴点 |
|---|---|
| **Git** | 内容寻址（content-addressable），hash 即标识 |
| **Joplin** | 文件级同步，客户端主导合并，**后端无关（WebDAV/OneDrive/Dropbox/S3）** |
| **Standard Notes** | E2EE + 单一 manifest 思路 |
| **Syncthing** | manifest 比对 + LWW |
| **Dropbox** | file content hash 做去重 |

**Joplin 的后端无关设计是本方案的重要灵感来源**：Joplin 客户端支持 WebDAV / OneDrive / Dropbox / S3 / 本地文件系统 / 自建 Joplin Server，用户选自己的云盘，不用部署服务器。本方案采用相同的"后端抽象 + 多实现"思路。

---

## 三、整体架构

本方案采用**后端无关**设计：SyncEngine 依赖 `SyncBackend` 抽象接口，底层可以是 WebDAV / 云盘 / 自建 HTTP 服务 / 本地文件系统，**核心逻辑完全不变**。

```
┌──────────────────────────────────────────────────┐
│              Client（Flutter）                   │
│                                                  │
│  Local SQLite (notes.db)                         │
│  ┌────────────────────────────────────────────┐  │
│  │ notes表: id / contentHash / deleted /      │  │
│  │         updatedAt / envelopeBlob           │  │
│  │ meta表: vault_id / mk_salt / manifest_ver  │  │
│  └────────────────────────────────────────────┘  │
│                                                  │
│  SyncEngine（后端无关，~200 行）                 │
│   1. backend.getManifest() → 解密                │
│   2. 比对本地 vs 远端 manifest                   │
│   3. backend.getBlob/putBlob 执行传输            │
│   4. 生成合并 manifest → backend.putManifest()   │
└────────────────────┬─────────────────────────────┘
                     │ SyncBackend 抽象接口
                     ▼
┌──────────────────────────────────────────────────┐
│     可插拔后端（任选其一，MVP 选 WebDAV）        │
├────────────┬────────────┬────────────┬───────────┤
│ WebDAV     │ HTTP API   │ OneDrive   │ Local FS  │
│ (坚果云/   │ (自建Go    │ (OAuth +   │ (测试/    │
│  NextCloud │  服务端)   │  Graph API)│ 单设备)   │
│  /自建)    │            │            │           │
│            │            │            │           │
│ GET/PUT    │ 4 个端点   │ Graph API  │ 文件读写  │
│ If-Match   │ + Bearer   │ + delta    │ + lock    │
│ (RFC4918)  │ + SQLite   │            │           │
│ ~80 行     │ ~150 行 Go │ ~150 行    │ ~50 行    │
└────────────┴────────────┴────────────┴───────────┘
```

**关键简化**：
- 后端**无业务逻辑**——纯存储（KV 或文件），MVP 用 WebDAV 时**零服务端开发**
- 后端**无 rev 计数器**——所有版本逻辑在客户端 manifest 里
- 后端**无墓碑清理**——墓碑是 manifest 里的一条记录，永远保留（或客户端主动清理）
- 后端**可替换**——用户选自己的云盘，不被绑死在某个服务上

---

## 四、加密与密钥

### 4.1 两层密钥架构（dataKey 为默认）

采用 **MK + dataKey 两层架构**（参考 CarrotNotes，但更简化）：

```
┌─────────────────────────────────────────────────────┐
│  密码层（改密码时变化）                              │
│    MK = PBKDF2-HMAC-SHA256(password, salt, 600k)   │
│    salt = vault_id（明文存 meta 表，通过 manifest 同步）│
│    MK 只用来加密 dataKey，不直接加密笔记              │
└─────────────────────────────────────────────────────┘
                      ↓ 加密
┌─────────────────────────────────────────────────────┐
│  数据层（永不变化，真正加密笔记的密钥）              │
│    dataKey = 随机 32 字节（首次启用同步时生成）     │
│    encryptedDataKey = AES-GCM(MK, dataKey)          │
│    encryptedDataKey 存在 manifest 里随版本同步       │
└─────────────────────────────────────────────────────┘
                      ↓ 加密每条笔记
┌─────────────────────────────────────────────────────┐
│  笔记层                                             │
│    envelope = AES-GCM(dataKey, nonce, AAD=id, content)│
└─────────────────────────────────────────────────────┘
```

**关键设计**：
- **dataKey 永不变化**——改密码时 dataKey 不动，所有 envelope 不动，只重 wrap dataKey
- **MK 只加密 dataKey**——改密码 = 用新 MK 重新加密一个 32 字节的 dataKey（O(1)）
- **encryptedDataKey 在 manifest 里**——随 manifest PUT 原子同步，无需独立的 keystore 同步层

### 4.2 为什么选 dataKey 层（而不是单层 MK）

之前曾考虑过"单层 MK = PBKDF2(password, salt)"的极简方案，但在 WebDAV 后端下有**致命的并发安全问题**：

**单层 MK 方案的改密码流程**：
```
1. 旧 MK 解密所有 envelope → 明文
2. 新 MK 加密明文 → 新 envelope（新 hash）
3. 上传 N 个新 blob          ← 耗时最长
4. 上传新 manifest            ← 原子切换点
```

**问题 1：上传 blob 期间其他客户端同步**
```
T=0  设备 A 改密码，开始上传 1000 个新 blob
T=1  设备 B 同步：GET manifest → 拿到旧 manifest
T=2  设备 A 上传完 500 个 blob + 新 manifest
T=3  设备 B 同步：GET manifest → 拿到新 manifest
     GET blob/newHash_501 → 404！← 设备 A 还没上传完
     同步失败
```

**问题 2：上传中途崩溃**
```
T=0  设备 A 上传 500/1000 个 blob 后崩溃
T=1  设备 A 重启：本地已是新 MK，远端 manifest 还是旧 MK
     无法判断该继续上传还是回滚
```

**问题 3：manifest PUT 失败产生孤儿 blob**
```
T=0  设备 A 上传完所有 blob，但 manifest PUT 返回 412 冲突
T=1  远端多了 1000 个孤儿 blob，无 manifest 引用
T=2  WebDAV 没有引用计数，这些 blob 永远不会被清理
```

**根本原因**：WebDAV 是文件级存储，没有事务。多个文件上传不是原子的，manifest 和 blob 之间存在时间窗口。

**dataKey 层完美解决**：
```
改密码 = 旧 MK 解 encryptedDataKey → dataKey
       → 新 MK 加密 dataKey → 新 encryptedDataKey
       → 上传新 manifest（含新 encryptedDataKey）  ← 一次 PUT，原子操作
       → blob 文件零传输
```

**无并发窗口、无崩溃恢复、无孤儿 blob**。dataKey 层的 ~80 行代码换来的是 WebDAV 下的正确性，不只是性能优化。

### 4.3 Joplin 的多密钥机制（反面教材）

Joplin 支持多个 master key 共存，但这是**设计缺陷被兼容**，不是真正的多密码支持：

- 每个 master key 完全独立，每条笔记 header 记录 `master_key_id`
- 多 key 产生场景：两台设备离线各自启用 E2EE，同步后产生冲突
- 官方明确说"Do not manually enable encryption on multiple devices in parallel...most probably not what you want"
- 用户陷入多 key 状态后极难清理（[论坛讨论](https://discourse.joplinapp.org/t/delete-e2ee-master-keys/906) 充满崩溃式求助）

**正确做法**（本方案采用）：同一个 dataKey，可以允许有多个 encryptedDataKey（每个用不同密码加密）。所有客户端解出同一个 dataKey，能互相解密笔记。这是 CarrotNotes 验证过的设计，避免 Joplin 式的多 key 冲突地狱。多密码支持作为可选增强（见第十四章）。

### 4.4 加密信封

```
envelope = nonce(12) ‖ ciphertext ‖ tag(16)
       = AES-256-GCM(dataKey, nonce, AAD=id, plaintext)
```

- 算法与 litenotes 一致（AES-256-GCM），保证互操作基础
- AAD 绑定笔记 id，防止重放攻击
- nonce 用 `crypto.randomBytes(12)` 生成（无需计数器，dataKey 只在一个客户端使用）

### 4.5 与 litenotes / CarrotNotes 对比

| 项 | litenotes | CarrotNotes | **本方案** |
|---|---|---|---|
| 密钥层次 | MK + KEK + wrappedMk | rootKey + masterKey + dataKey + itemKey | **MK + dataKey**（两层） |
| Keystore 同步 | 作为特殊 item 推/拉（有冲突 bug） | dataKey item 同步 | **encryptedDataKey 在 manifest 里**（无独立同步） |
| 改密码成本 | 重 wrap MK（O(1)） | 重 wrap dataKey（O(1)） | **重 wrap dataKey（O(1)）** |
| 改密码原子性 | ✅（自建服务端事务） | ✅（单端点 push） | ✅（一次 manifest PUT） |
| 多设备协议 | keystore 推送 + 解 MK | dataKey 推送 + 解 | **输相同密码即可**（最简） |
| 代码量 | Keystore 类 ~120 行 | ~280 行（四层） | **~80 行**（两层） |

**取舍**：相比 litenotes，省去了 keystore 独立同步层（冲突 bug 来源）；相比 CarrotNotes，省去了 masterKey + itemKey 两层（纯文本笔记不需要 per-item key 粒度）。dataKey 层是"改密码原子性"和"密钥管理复杂度"的最佳平衡点。

---

## 五、数据模型

### 5.1 本地 SQLite schema

```sql
CREATE TABLE notes (
  id           TEXT PRIMARY KEY,       -- UUIDv4
  content_hash TEXT NOT NULL,          -- SHA-256(明文 content)十六进制
  envelope     BLOB NOT NULL,          -- 加密信封
  deleted      INTEGER NOT NULL DEFAULT 0,
  updated_at   INTEGER NOT NULL,       -- Unix 毫秒
  base_updated_at INTEGER NOT NULL DEFAULT 0  -- 上次同步时的 updated_at
);

CREATE TABLE meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
-- meta 键: vault_id / mk_salt / manifest_version / format
```

### 5.2 远端 manifest 格式（加密前）

```json
{
  "version": 42,
  "vaultId": "uuid-xxx",
  "updatedAt": 1719470000000,
  "encryptedDataKey": "base64...",
  "items": {
    "<note-uuid>": {
      "hash": "abc123...",
      "deleted": false,
      "updatedAt": 1719460000000
    },
    "<note-uuid-2>": {
      "hash": "def456...",
      "deleted": true,
      "updatedAt": 1719470000000
    }
  }
}
```

**manifest 存元数据 + hash + encryptedDataKey**：
- `items` 只存 hash，content 在 blob 里（hash 寻址，天然 dedup）
- `encryptedDataKey` 是用 MK 加密后的 dataKey，改密码时只更新这一个字段
- 整个 manifest 用 dataKey 加密后上传（`encryptedDataKey` 本身已经是密文，双重保护）

### 5.3 远端存储

```
blobs 表:
  hash (PK) | data
  "abc123..." | <加密信封二进制>
  "def456..." | <加密信封二进制>

manifest 单行:
  version | ciphertext
  42      | <加密后的 manifest JSON>
```

**天然 dedup**：相同内容只存一份（同 hash）。两台设备独立编辑出相同内容 → 自动合并为一份。

---

## 六、同步流程

### 6.1 主流程（5 步）

```
Step 1  GET /manifest
        → 远端 manifest 密文
        → 用 MK 解密 → remoteManifest

Step 2  比对 localManifest vs remoteManifest
        对每条 note：
        - 仅本地有 → 待上传
        - 仅远端有 → 待下载
        - 双方有但 hash 不同 → 冲突（LWW）
        - 双方有且 hash 相同 → 跳过

Step 3  执行传输
        待上传: PUT /blob/{hash} + envelope
        待下载: GET /blob/{hash} → 解密 → 写本地
        LWW 落败方: 标记本地为已删除（若远端 deleted）或覆盖（若远端更新）

Step 4  生成本地新 manifest
        mergedManifest = merge(localManifest, remoteManifest)
        mergedManifest.version = remoteManifest.version + 1

Step 5  PUT /manifest（带 If-Match: remoteManifest.version）
        → 200 成功 → 本地 manifest_version = 新 version
        → 409 冲突 → 回到 Step 1 重试（最多 3 次）
```

### 6.2 冲突处理（极简）

**Note 层：纯 LWW**

```dart
if (remote.updatedAt > local.updatedAt) {
  // 远端胜
  if (remote.deleted) local.delete();
  else local.replaceWith(remote);
} else if (remote.updatedAt < local.updatedAt) {
  // 本地胜，待下次推送覆盖远端
  pendingPush.add(local);
} else {
  // updatedAt 相同但 hash 不同（极少见）→ 保留 hash 字典序小的
  // 实际中几乎不会触发，加这个兜底避免无限冲突
}
```

**为什么不做 fork？**
- fork 产生副本污染笔记列表，用户要手动清理
- LWW 对纯文本笔记足够：用户看到内容丢失会去"历史版本"找回
- **历史版本**：服务端保留旧 hash 的 blob 不删除，客户端可加"查看历史"功能（可选）

### 6.3 乐观锁只在 manifest 层

整个同步只在 **PUT /manifest** 时有一次乐观锁检查。note 级别**没有锁**——因为 manifest 是单点真相，谁先 PUT 谁赢，输的人重试一次即可。

对比 litenotes 的每条 item 一次乐观锁（baseRev 比对 + 409），本方案乐观锁次数 = 1。

### 6.4 与 litenotes 流程对比

| 步骤 | litenotes | 本方案 |
|---|---|---|
| 准备 | 收集 dirty 集合 + keystore hash 检测 | 直接读本地 manifest |
| 推送 | PUT /items + 逐条 409 处理 + fork | **无独立推送**（合并到 manifest PUT） |
| 拉取 | GET /sync?since=N + 逐条合并 + 回声过滤 | GET /manifest + 一次性比对 |
| 冲突 | 每条 note 独立 fork | LWW（manifest 整体乐观锁） |
| 收尾 | 更新 sync_state + 持久化 | 更新 manifest_version + 持久化 |
| 分支数 | ~9 种 | **3 种**（上传/下载/删除） |

---

## 七、后端实现（MVP 首选 WebDAV，零服务端开发）

### 7.1 SyncBackend 抽象接口

```dart
abstract class SyncBackend {
  /// 获取远端 manifest，返回密文和当前 ETag（用于乐观锁）
  Future<({Uint8List ciphertext, String etag})> getManifest();

  /// 上传新 manifest，带 expectedEtag 做乐观锁
  /// 成功返回新 etag，失败（409）抛 ConflictException
  Future<String> putManifest(Uint8List ciphertext, String expectedEtag);

  /// 下载 blob，不存在返回 null
  Future<Uint8List?> getBlob(String hash);

  /// 上传 blob，相同 hash 幂等
  Future<void> putBlob(String hash, Uint8List data);
}
```

SyncEngine 只依赖此接口，**完全不知道底层是 WebDAV 还是自建服务端**。

### 7.2 MVP 首选：WebDAV 后端（~80 行 Dart，零服务端开发）

**为什么选 WebDAV**：
- WebDAV 的 `If-Match: <etag>` 是 RFC 4918 标准功能，天然实现 manifest 乐观锁
- 用户用坚果云 / NextCloud / 自建 WebDAV，**零运维**
- 数据在用户自己的云盘，**隐私强**
- 国内可用性好（坚果云 WebDAV）
- Joplin 已验证此方案可行

**WebDAV 目录结构**：

```
/safenotes-vault/
├── manifest.json          # 单文件，If-Match ETag 乐观锁保护
└── blobs/
    ├── abc123def...        # 按 hash 命名的 blob 文件
    ├── 456789abc...
    └── ...
```

**WebDavBackend 实现**（~80 行 Dart）：

```dart
class WebDavBackend implements SyncBackend {
  final String baseUrl;  // e.g. "https://dav.jianguoyun.com/dav/safenotes-vault"
  final String username;
  final String password;

  Future<({Uint8List ciphertext, String etag})> getManifest() async {
    final res = await http.get(
      Uri.parse('$baseUrl/manifest.json'),
      headers: _authHeaders(),
    );
    if (res.statusCode == 404) {
      return (ciphertext: Uint8List(0), etag: '');  // 首次同步
    }
    return (
      ciphertext: res.bodyBytes,
      etag: res.headers['etag'] ?? '',
    );
  }

  Future<String> putManifest(Uint8List data, String expectedEtag) async {
    final res = await http.put(
      Uri.parse('$baseUrl/manifest.json'),
      headers: {
        ..._authHeaders(),
        'Content-Type': 'application/octet-stream',
        if (expectedEtag.isNotEmpty) 'If-Match': expectedEtag,
      },
      body: data,
    );
    if (res.statusCode == 412) {  // Precondition Failed = 乐观锁冲突
      throw ConflictException();
    }
    return res.headers['etag'] ?? '';
  }

  Future<Uint8List?> getBlob(String hash) async {
    final res = await http.get(
      Uri.parse('$baseUrl/blobs/$hash'),
      headers: _authHeaders(),
    );
    if (res.statusCode == 404) return null;
    return res.bodyBytes;
  }

  Future<void> putBlob(String hash, Uint8List data) async {
    await http.put(
      Uri.parse('$baseUrl/blobs/$hash'),
      headers: {
        ..._authHeaders(),
        'Content-Type': 'application/octet-stream',
      },
      body: data,
    );
    // WebDAV PUT 幂等：相同内容覆盖写，不影响正确性
  }

  Map<String, String> _authHeaders() {
    final credentials = base64Encode(utf8.encode('$username:$password'));
    return {'Authorization': 'Basic $credentials'};
  }
}
```

**WebDAV 兼容性测试矩阵**（需实测）：

| 服务 | If-Match 支持 | ETag 返回 | 备注 |
|---|---|---|---|
| 坚果云 | ✅ | ✅ | 国内首选，免费版限流量 |
| NextCloud | ✅ | ✅ | 自建首选 |
| ownCloud | ✅ | ✅ | 同 NextCloud |
| Box | ✅ | ✅ | 企业用 |
| Synology WebDAV | ✅ | ✅ | NAS 用户 |
| OneDrive（WebDAV 桥） | ⚠️ | ⚠️ | 不推荐，用 Graph API |
| Apache mod_dav | ✅ | ✅ | 自建轻量方案 |

### 7.3 可选：自建 HTTP 服务端（~150 行 Go）

当 WebDAV 不满足需求（如要多用户、push 通知、rate limit）时，可自建服务端。SyncEngine 代码不变，只换 Backend 实现。

```go
// 极简服务端，无业务逻辑
type Server struct {
    db *sql.DB  // SQLite 或 Postgres
}

// GET /manifest
func (s *Server) GetManifest(w, r) {
    var version int64
    var ciphertext []byte
    s.db.QueryRow("SELECT version, ciphertext FROM manifest WHERE id=1").Scan(&version, &ciphertext)
    json.Encode(w, {"version": version, "ciphertext": ciphertext})
}

// PUT /manifest  (If-Match: version)
func (s *Server) PutManifest(w, r) {
    expectedVersion := r.Header.Get("If-Match")
    var newCiphertext []byte
    json.Decode(r.Body, &newCiphertext)
    
    result, _ := s.db.Exec(
        "UPDATE manifest SET version=version+1, ciphertext=? WHERE id=1 AND version=?",
        newCiphertext, expectedVersion)
    if rowsAffected == 0 {
        w.WriteHeader(409)  // 版本冲突
        return
    }
    w.WriteHeader(200)
}

// GET /blob/{hash}
func (s *Server) GetBlob(w, r) {
    hash := chi.URLParam(r, "hash")
    var data []byte
    s.db.QueryRow("SELECT data FROM blobs WHERE hash=?", hash).Scan(&data)
    w.Write(data)
}

// PUT /blob/{hash}
func (s *Server) PutBlob(w, r) {
    hash := chi.URLParam(r, "hash")
    data := io.ReadAll(r.Body)
    s.db.Exec("INSERT OR IGNORE INTO blobs (hash, data) VALUES (?, ?)", hash, data)
    // OR IGNORE: 相同 hash 幂等，天然 dedup
}
```

### 7.4 后端选择对比

| 维度 | WebDAV（MVP 首选） | 自建 HTTP | OneDrive | 本地 FS |
|---|---|---|---|---|
| 服务端开发量 | **0 行** | ~150 行 Go | 0 行 | 0 行 |
| 客户端开发量 | ~80 行 | ~80 行 | ~150 行 | ~50 行 |
| 运维 | **零运维** | 需部署 | 零运维 | N/A |
| 隐私 | 数据在用户云盘 | 数据在自建服务器 | 数据在微软 | 本地 |
| 多用户 | 天然隔离 | 需加 accounts 表 | 天然隔离 | N/A |
| push 通知 | 不支持 | 可加 SSE | 支持 delta | N/A |
| 国内可用 | **坚果云可用** | 看部署位置 | 不稳定 | N/A |
| rate limit | 云盘限制 | 可自控 | 微软限制 | N/A |

**对比 litenotes / CarrotNotes**：
- litenotes：必须有专用服务端（~500 行 Go）
- CarrotNotes：必须有专用服务端（~1500 行 TS）
- **本方案**：MVP 用 WebDAV，**零服务端开发**；需要高级功能时再自建

---

## 八、关键决策对照

| 问题 | litenotes 做法 | 本方案做法 | 评价 |
|---|---|---|---|
| 回声过滤 | baseRev 比对（错的） | **不需要**（manifest 比对天然无回声） | 胜 |
| Keystore 冲突 | 没处理（bug） | **不存在**（无 keystore） | 胜 |
| 410 全量对账 | 没实现（bug） | **不需要**（无墓碑清理） | 胜 |
| Push 幂等性 | 没有（bug） | **天然幂等**（PUT blob OR IGNORE + manifest version） | 胜 |
| contentHash 优化 | 没有 | **核心机制**（hash 寻址天然 dedup） | 胜 |
| Push 通知 | 没有 | 可加 SSE（manifest 更新时通知） | 平 |
| Per-device token | 没有 | 仍可加（独立于协议） | 平 |
| 3-way merge | 没有 | 可加（保留 base hash + diff3） | 平 |
| 冲突交互式解决 | 没有 | LWW 默认 + 可选"保留双份" | 平 |
| 服务器迁移 | 难（sync_state 绑定） | **简单**（换 URL + 重置 manifest_version 即可） | 胜 |
| sync_state 备份 | 需要 | **不需要**（manifest_version 单值，丢失就重拉） | 胜 |
| 历史版本 | 没有 | **天然支持**（旧 hash blob 不删除） | 胜 |
| 改密码 | O(1)（keystore wrap） | **O(1)**（dataKey wrap） | 平 |
| 改密码原子性（WebDAV） | N/A（需自建服务端） | **原子**（一次 manifest PUT） | 胜 |
| 多用户 | 单用户 | 需额外加 accounts 表 | 平 |

---

## 九、本方案的代价

### 9.1 全量 manifest 拉取

每次同步都要拉整个 manifest。1000 条笔记的 manifest 约 100KB（加密后），10000 条约 1MB。

**优化**（可选增强，见第十四章）：服务端支持 `GET /manifest?since=V`，返回从版本 V 到当前的 manifest diff。客户端合并到本地。这是 Git 的 pack 协议思路。

### 9.2 LWW 会丢数据

并发编辑时，先 PUT 的赢，后 PUT 的覆盖前者的内容。用户感知是"我的修改没了"。

**缓解**：保留旧 hash 的 blob（不删除），UI 提供"历史版本"恢复入口。比 fork 副本污染列表更友好。可选增强：3-way merge（见第十四章）。

### 9.3 没有墓碑清理

墓碑永久留在 manifest 里，时间长了 manifest 会膨胀。

**缓解**：客户端主动清理——30 天前的墓碑从 manifest 移除，blob 保留（用作历史）。这是客户端决策，后端无感。

### 9.4 多用户需要额外扩展

本方案原设计是单用户/单 vault。要支持多用户：
- 自建 HTTP 服务端加 accounts 表
- manifest 和 blobs 表都加 `user_id` 列
- 每 user 独立 manifest 单行

约 200 行服务端代码（参考 review-litenotes-sync.md 中多用户改造估算）。WebDAV 后端天然多用户隔离（每个用户用自己云盘）。

### 9.5 改密码的多设备协调

改密码本身是 O(1) 原子操作，但其他设备需要**检测到密码已变更**并提示重新输入：

```
设备 B 同步时：
  1. 拉到新 manifest，发现 encryptedDataKey 与本地缓存不同
  2. 尝试用本地密码派生 MK → 解新 encryptedDataKey → 失败
  3. 标记 needsReauth = true，UI 提示"密码已在其他设备变更，请输入新密码"
  4. 用户输新密码 → 派生新 MK → 解 encryptedDataKey → 成功 → 继续同步
```

这是所有 E2EE 方案的共同流程（litenotes / CarrotNotes / SN 都需要），约 80 行客户端代码。不复杂，但必须实现。

**多设备并发改密码冲突**：用 manifest 乐观锁天然解决——先 PUT 的赢，后 PUT 的收到 412，提示"密码已被其他设备修改为不同密码，请输入那个密码"。

---

## 十、代码量估算

### 10.1 客户端代码量（Dart）

| 模块 | litenotes 估算 | 本方案估算 | 节省 |
|---|---|---|---|
| 加密层 | 150 行 | 150 行 | 0 |
| dataKey 层（含多设备协调） | 120 行（Keystore） | **80 行** | -40 |
| 数据模型 + DB | 280 行 | 200 行 | -80 |
| Vault | 250 行 | 150 行 | -100 |
| SyncModels | 80 行 | 60 行 | -20 |
| SyncState | 60 行 | 30 行（只有 version） | -30 |
| SyncEngine | 300 行 | 200 行 | -100 |
| SyncBackend 接口 | 0 | 30 行 | +30 |
| WebDavBackend | 0 | 80 行 | +80 |
| SyncService | 120 行 | 120 行 | 0 |
| UI | 200 行 | 200 行 | 0 |
| 测试 | 400 行 | 250 行 | -150 |
| **客户端合计** | **~2060 行** | **~1550 行**（含 dataKey + WebDavBackend） | **-510 行（-25%）** |

### 10.2 服务端代码量

| 方案 | 代码量 | 说明 |
|---|---|---|
| **WebDAV（MVP 首选）** | **0 行** | 直接用坚果云/NextCloud，零开发 |
| 自建 HTTP（可选） | ~150 行 Go | 多用户/push 通知时才需要 |
| litenotes 服务端 | ~500 行 Go | 必须自建 |
| CarrotNotes 服务端 | ~1500 行 TS | 必须自建 |

**WebDAV 路线总节省**：客户端 -29%，服务端 **-100%**（零开发）。

---

## 十一、一次性完整实现（不分 MVP）

本项目规模小（~1550 行客户端 + 0 行服务端），**一次性做完整核心功能**比"先 MVP 再迭代"更省事——避免后期重构、避免 dataKey 事后加导致的迁移、避免临时方案变成长期方案。

### 11.1 完整实现包含

**核心层（必做，一次性完成）**：
- MK + dataKey 两层密钥架构（含改密码 + 多设备协调）
- AES-256-GCM 加密 + PBKDF2-HMAC-SHA256 600k 派生
- 本地 SQLite schema（notes + meta 表）
- manifest 同步协议（5 步流程 + LWW + 乐观锁重试）
- SyncBackend 抽象接口 + WebDavBackend 实现
- SyncService（触发 + 互斥 + 状态）
- UI 集成（设置页 + 状态图标 + 冲突提示 + 改密码页 + 重新认证流程）
- 最近删除视图（软删除架构的必要补充）
- 服务器迁移工具（切换 WebDAV 服务器时重置 manifest_version）

**测试（必做）**：
- 加密互解向量（固定 salt + nonce + plaintext → 比对密文）
- SyncEngine 流程测试（用 FakeBackend，纯 Windows 可跑）
- WebDavBackend 集成测试（本地 WebDAV 服务器）
- 改密码流程测试（含多设备协调）
- LWW 冲突测试

### 11.2 完整实现代码清单

```
客户端（~1550 行 Dart）:
  - crypto.dart: PBKDF2 + AES-GCM + dataKey wrap/unwrap（230 行）
  - database.dart: notes 表 + meta 表 + CRUD（200 行）
  - sync_engine.dart: 5 步同步流程 + LWW + 乐观锁重试（200 行）
  - sync_backend.dart: 抽象接口（30 行）
  - webdav_backend.dart: WebDAV 实现（80 行）
  - sync_service.dart: 触发 + 互斥 + 状态（120 行）
  - vault.dart: vault 管理 + 改密码 + 多设备协调（230 行）
  - UI: 设置页 + 状态图标 + 冲突提示 + 改密码页 + 重新认证 + 最近删除（300 行）
  - 服务器迁移工具（50 行）

测试（~300 行 Dart，纯 Windows 可跑）:
  - crypto 互解向量
  - sync_engine 流程（用 FakeBackend）
  - webdav_backend 集成测试
  - 改密码 + 多设备协调
  - LWW 冲突
```

**总代码量 ~1850 行**，比 litenotes 方案的 ~2060 行少 10%，但：
- **零服务端开发**（用 WebDAV）
- **无已知 bug**（回声过滤错误、410 缺失、keystore 冲突都不存在）
- **后端可替换**（未来加自建服务端 / OneDrive 都是增量）
- **改密码 O(1) 且原子**（dataKey 层）
- **一次到位，无需后期重构**

### 11.3 不在本方案范围（明确不做）

- 后台同步 / Doze 处理 / 断网重试退避（失败等下次前台重试）
- 服务端搜索索引（违反零知识）
- CRDT/OT 操作日志（复杂度太高）
- Forward secrecy（与本地优先架构冲突）
- 块级/增量同步（笔记太小，不值得）
- 附件/图片加密（首版不做，预留扩展点）

这些功能如果需要，都是后续独立项目，不影响核心架构。

---

## 十二、何时选本方案 vs litenotes / CarrotNotes

### 选本方案（推荐）

- 个人用、单用户、笔记量 < 10000 条
- 想要后端无关（用 WebDAV / 云盘，零服务端开发）
- 想要一次到位、最少后期重构
- 重视改密码的原子性和多设备协调

### 选 litenotes 方案

- 多用户共享 vault
- 需要服务端业务逻辑（rate limit / push 通知 / per-device 撤销）
- 已经有 C# 参考实现可逐行翻译
- 可以接受 4 个已知协议 bug 需要修复

### 选 CarrotNotes 方案

- 需要多用户 + 完善的鉴权 + Recovery
- 想要最现代的加密架构（XChaCha20 + Argon2id + HKDF）
- 客户端是 Web/TS（不是 Flutter，否则 XChaCha20 + Argon2id 跨平台互解坑深）
- 可以接受更复杂的服务端

---

## 十三、总结

本方案的核心思想：**把"同步协议"从"服务端 rev 计数器 + 客户端 baseRev 比对"重构为"客户端 manifest + 后端 CAS 存储"**。

- **后端**从"业务逻辑 + 计数器 + 墓碑清理"简化为"无状态存储"，甚至直接用 WebDAV（**零服务端开发**）
- **客户端**从"9 种同步分支"简化为"3 种（上传/下载/删除）"
- **冲突**从"fork 保留双份"简化为"LWW + 历史版本"
- **密钥**从"MK + KEK + keystore 同步"简化为"**MK + dataKey 两层**"（O(1) 改密码 + WebDAV 原子性）
- **后端可替换**——SyncBackend 抽象接口，WebDAV / 自建 HTTP / OneDrive / 本地 FS 任选

**本方案相比 litenotes / CarrotNotes 的最大差异化优势**：
1. 后端无关——MVP 用 WebDAV 时零服务端开发，用户用自己的云盘
2. 改密码原子性——dataKey 层让 WebDAV 下改密码也是一次 manifest PUT
3. 一次到位——无已知 bug，无需后期重构加 dataKey 层

代价是全量 manifest 拉取（百 KB 级，可用 manifest delta 优化）和 LWW 可能丢数据（用历史版本 + 3-way merge 缓解）——对个人笔记场景完全可接受。

---

## 十四、可选增强（按需添加，不破坏核心架构）

以下功能都是**独立的、可回退的、增量添加的**，每项不破坏核心架构。按性价比排序：

### 14.1 强烈建议（低成本高收益）

| 增强项 | 代码量 | 收益 |
|---|---|---|
| **3-way merge（diff3）** | ~150 行 | 消除 80%+ LWW 数据丢失，纯文本笔记场景的教科书方案 |
| **冲突交互式解决** | ~100 行 | LWW 失败时弹窗让用户选"保留我的/对方的/双份" |
| **同步进度反馈** | ~30 行 | UI 显示"已同步 X/Y 条"，体验提升 |
| **每条笔记同步状态** | ~20 行 | 笔记卡片加图标显示"已同步/待同步" |
| **同步历史日志** | ~80 行 | 内存缓存最近 50 条同步记录，便于诊断 |

### 14.2 中等价值（按需添加）

| 增强项 | 代码量 | 收益 |
|---|---|---|
| **manifest delta（`GET /manifest?since=V`）** | ~100 行 | 大 vault 同步省带宽，Git pack 协议思路 |
| **SSE push 通知** | ~80 行（自建服务端） | 多设备协作时近实时同步 |
| **Per-device token 撤销** | ~60 行（自建服务端） | 设备丢失时单独吊销 |
| **历史版本 UI** | ~120 行 | 浏览旧 hash blob，恢复误删/误改 |
| **多密码支持（Joplin 反例的正确版）** | ~100 行 | 见 14.3 |
| **TLS 证书固定** | ~100 行 | 防企业 CA 中间人攻击 |

### 14.3 多密码支持（CarrotNotes 风格，非 Joplin 风格）

**目标**：允许多台设备用不同密码访问同一个 vault。

**正确做法**（同一 dataKey，多个 encryptedDataKey）：

```json
// manifest 里
{
  "encryptedDataKeys": [
    { "id": "key-1", "wrappedDataKey": "base64...", "createdAt": ... },
    { "id": "key-2", "wrappedDataKey": "base64...", "createdAt": ... }
  ],
  "items": { ... }
}
```

- 每台设备用自己密码派生 MK → 加密同一个 dataKey → 生成一个 encryptedDataKey 条目
- 设备拉到 manifest 后，逐个尝试用本地密码解 encryptedDataKey，解开的就用
- 改密码 = 删除自己的 encryptedDataKey 条目，添加新密码加密的条目
- 删除设备 = 删除该设备的 encryptedDataKey 条目（吊销访问）

**对比 Joplin 的多 master key（反面教材）**：
- Joplin：每个 master key 独立，笔记绑定 master_key_id，多 key 是冲突状态
- 本方案：同一个 dataKey，多个 encryptedDataKey 是正常状态，无冲突

**代码量**：~100 行（manifest 格式扩展 + 设备密码管理 UI）。

### 14.4 高级功能（评估后再决定）

| 增强项 | 代码量 | 评估 |
|---|---|---|
| **Recovery code（BIP-39 助记词）** | ~200 行 | CarrotNotes 风格，密码丢失恢复 |
| **附件/图片加密** | ~300 行 | 用 dataKey 加密 blob，content_type 区分 |
| **多用户（自建服务端）** | ~200 行服务端 | accounts 表 + user_id 贯穿 |
| **Rate limiting** | ~30 行服务端 | 多用户场景必备 |
| **服务端墓碑清理 + 410 对账** | ~130 行 | 长期使用 manifest 膨胀时才需要 |

### 14.5 不建议添加

- **CRDT/OT 操作日志**：复杂度太高，纯文本笔记收益有限
- **Forward secrecy（Double Ratchet）**：与本地优先架构冲突，需要所有设备在线
- **服务端搜索索引**：违反零知识原则
- **块级/增量同步**：笔记太小，不值得
- **Per-item itemKey（CarrotNotes 四层）**：纯文本笔记不需要这么细的密钥粒度

### 14.6 增强项的独立性

每个增强项都满足：
1. **可独立添加**——不需要同时加其他增强
2. **可回退**——删除增强代码不影响核心架构
3. **不破坏协议**——核心 SyncEngine + SyncBackend 接口不变
4. **增量代码**——每项都有明确的代码量估算

这是本方案相比 litenotes / CarrotNotes 的另一个优势：**功能解耦**，而不是"全部绑在一起"。

---

## 附：决策矩阵

| 需求优先级 | 推荐方案 |
|---|---|
| 后端无关 + 用户自选云盘 + 零服务端 | **本方案 + WebDAV**（唯一选项） |
| 一次到位 + 改密码原子性 + 最少后期重构 | **本方案**（dataKey 已包含） |
| 有 C# 参考实现可逐行翻译 | litenotes |
| 多用户 + Recovery + 现代加密 | CarrotNotes |
| 多用户 + 自建服务端 | **本方案 + 自建 HTTP + accounts 表** |
| 允许多设备不同密码 | **本方案 + 14.3 多密码增强** |
| 需要近实时同步 | **本方案 + 14.2 SSE push 通知** |

---

*本文档基于 2026-07-27 的 review-litenotes-sync.md 讨论整理。实施时如需选择此方案，建议先做加密互解测试向量验证可行性。*
