# SafeServer 同步服务端 API 规范 v2.1

> **自包含的服务端实现规范**：任何按本文档实现的 HTTP 服务端均可与 SafeNotes 客户端的 `safeServer` 后端类型互操作。实现者无需阅读客户端代码或客户端协议细节。
>
> 配套参考实现：[Go server](../server/go/main.go)、[Node.js server](../server/nodejs/server.js)。
> 客户端侧的加密格式、冲突解决、同步算法见 [sync-protocol-spec.md](./sync-protocol-spec.md)。
>
> **v2.1 变更摘要**（详见 §15）：
> - 新增 `DELETE /api/v2/manifest` 端点（清理损坏文件，客户端 `backupCorruptManifest` 用）
> - 新增 `DELETE /api/v2/blob/<hash>` 端点（GC 清理孤儿 blob）
> - 新增 `GET /api/v2/blobs` 端点（列出所有 blob hash，GC 用，需认证）
> - 速率限制从"推荐"升级为"强烈建议"，并对 401 认证失败做 IP+时间窗口限速
> - 旧版 v2 服务端仍可互操作（客户端对 405 静默降级）

---

## 一、设计目标

### 1.1 核心契约

> **SafeServer = 一个支持 ETag 乐观锁的不透明二进制 KV 存储。**

服务端只存储密文（manifest + blobs），不解释内容、不维护元数据、不做业务逻辑。客户端把服务端当作"带版本控制的不透明二进制文件存储"使用。

### 1.2 与其他后端类型的关系

SafeNotes 客户端支持三种同步后端类型，各自独立的协议：

| 后端类型 | 协议 | 用途 |
|---------|------|------|
| `localFs` | 文件系统 API | 单设备离线、测试 |
| `webdav` | WebDAV (RFC 4918) | 用户已有的云盘（坚果云/NextCloud 等） |
| `safeServer` | **本规范** | 自建轻量同步服务 |

`safeServer` 不兼容 WebDAV，也不依赖文件系统语义。它是一个纯 HTTP API，专为 SafeNotes 设计，目标是简单、清晰、可靠。

### 1.3 设计原则

1. **零知识**：服务端只存储密文，不接触明文、密钥、密码。
2. **无状态**：服务端不维护会话、不维护版本计数器、不清理墓碑。所有状态由客户端通过 manifest 协调。
3. **单用户**：一个 server 实例服务一个 vault，不需要用户注册系统。认证用固定 Bearer Token。
4. **内容寻址**：blob 资源按客户端提供的 hash 命名，服务端不计算也不校验 hash。
5. **单点真相**：整个 server 只有一个 manifest 资源，由 ETag 乐观锁保护全局一致性。
6. **无目录概念**：URL 路径直接对应资源，服务端不需要"创建目录"操作。

---

## 二、术语

| 术语 | 服务端视角含义 |
|------|---------------|
| **manifest** | 路径为 `/api/v2/manifest` 的单一资源。服务端将其视为需要 ETag 保护的二进制文件。 |
| **blob** | 路径为 `/api/v2/blob/<hash>` 的二进制资源。`<hash>` 是客户端提供的字符串，服务端不解析。 |
| **ETag** | manifest 资源的版本标识，由服务端生成并返回。客户端用它做乐观锁。 |
| **Token** | 固定的 Bearer Token，部署时配置，所有请求共用。 |

---

## 三、认证

### 3.1 机制

所有 API 请求（除 `/api/v2/health` 外）必须使用 Bearer Token 认证：

```
Authorization: Bearer <token>
```

### 3.2 服务端职责

- 校验 Token，失败时返回 `401 Unauthorized` 并附带 `WWW-Authenticate: Bearer` 头。
- Token 校验必须使用 **constant-time compare** 防止时序攻击。
- 单用户场景下，Token 由部署者在启动参数中配置（如 `--token my-secret-token`）。
- 服务端不管理多个用户账号。

### 3.3 Token 来源

由客户端在配置同步时指定。客户端配置项：
- `safeServerUrl`：服务端基础 URL（如 `http://192.168.1.118:2025`）
- `safeServerToken`：固定 Bearer Token

---

## 四、资源模型

服务端暴露两类资源（无目录资源）：

```
/api/v2/manifest              # manifest 资源（单一，ETag 保护）
/api/v2/blob/<hash>           # blob 资源（多个，内容寻址）
```

### 4.1 manifest 资源

- 路径固定为 `/api/v2/manifest`。
- 内容是**不透明二进制字节流**（客户端视角下是 AES-256-GCM 密文，但服务端不解析）。
- **必须**支持 ETag 乐观锁（If-Match / If-None-Match）。
- 每次 PUT 成功后，返回的 ETag **必须变化**。

### 4.2 blob 资源

- 路径为 `/api/v2/blob/<hash>`，`<hash>` 是客户端提供的任意字符串（实践中是 64 位十六进制 SHA-256）。
- 内容是**不透明二进制字节流**。
- **不可变**：相同 `<hash>` 的多次 PUT 应返回成功（覆盖写或忽略均可）。
- **不需要** ETag、不需要乐观锁。
- 服务端**不应**校验内容与 hash 是否匹配（零知识要求）。
- v2.1 起支持 `DELETE /api/v2/blob/<hash>` 删除 blob（GC 用，幂等）。
- v2.1 起支持 `GET /api/v2/blobs` 列出所有 blob hash（GC 用，需认证——不破坏防枚举原则，因为无 Token 的攻击者无法访问）。

### 4.3 物理存储

服务端内部的物理存储形式由实现者决定：

- 文件系统：`<dataDir>/manifest` + `<dataDir>/blobs/<hash>`
- 数据库：单表存储 `(key, value)`，manifest 用 `key="manifest"`，blob 用 `key="blob:<hash>"`
- 对象存储：S3 bucket，manifest 是一个 object，blob 是多个 object

只要对外暴露的 HTTP API 语义符合本规范，内部存储形式不影响互操作性。

---

## 五、HTTP API

### 5.1 端点汇总

| 方法 | 路径 | 用途 | 乐观锁 | 认证 | 版本 |
|------|------|------|--------|------|------|
| GET | `/api/v2/manifest` | 下载 manifest | — | 是 | v2 |
| PUT | `/api/v2/manifest` | 上传 manifest | If-Match / If-None-Match | 是 | v2 |
| DELETE | `/api/v2/manifest` | 清理损坏 manifest | — | 是 | v2.1 |
| GET | `/api/v2/blob/<hash>` | 下载 blob | — | 是 | v2 |
| PUT | `/api/v2/blob/<hash>` | 上传 blob | — | 是 | v2 |
| DELETE | `/api/v2/blob/<hash>` | 删除 blob（GC 用，幂等） | — | 是 | v2.1 |
| GET | `/api/v2/blobs` | 列出所有 blob hash（GC 用） | — | 是 | v2.1 |
| GET | `/api/v2/health` | 健康检查（可选） | — | 否 | v2 |

**注意**：没有 MKCOL，没有 PROPFIND。服务端不需要"创建目录"——PUT 资源时父级路径不存在由服务端内部自行处理。v2.1 新增的三个端点（DELETE manifest、DELETE blob、GET blobs）均用于客户端的 GC 与自愈流程；旧版 v2 服务端不实现这些端点时返回 405，客户端会静默降级。

### 5.2 GET manifest

**请求**：

```http
GET /api/v2/manifest HTTP/1.1
Authorization: Bearer <token>
```

**语义**：下载当前 manifest 密文。

**响应**：

| 状态码 | 含义 | Body | ETag Header |
|--------|------|------|-------------|
| 200 OK | 成功 | manifest 密文（二进制） | **必须返回** |
| 404 Not Found | 首次同步，远端无 manifest | 空 | 无 |
| 401 Unauthorized | 认证失败 | 错误描述 | 无 |

**实现要点**：
- 404 是正常状态（首次同步），不是错误。
- ETag 必须是**强 ETag**（不带 `W/` 前缀），建议用双引号包裹，如 `"abc123..."`。
- 响应 `Content-Type` 建议 `application/octet-stream`。

### 5.3 PUT manifest（乐观锁）

**请求**：

```http
PUT /api/v2/manifest HTTP/1.1
Authorization: Bearer <token>
Content-Type: application/octet-stream
If-Match: "<expected-etag>"        # 更新已有 manifest 时
If-None-Match: *                    # 首次上传时（确保远端不存在）
```

Body 为 manifest 密文（二进制）。

**语义**：上传新 manifest，按条件头做乐观锁校验后写入。

**乐观锁规则**（详见 §6）：
- 带 `If-Match: "<etag>"`：远端当前 ETag 必须等于此值才能写入，否则返回 412。
- 带 `If-None-Match: *`：远端必须**不存在** manifest，否则返回 412。
- 两个头都不带：服务端应容忍，退化为最后写入胜（不推荐但允许）。

**响应**：

| 状态码 | 含义 | ETag Header |
|--------|------|-------------|
| 200 OK / 201 Created | 写入成功 | **必须返回新 ETag** |
| 412 Precondition Failed | 乐观锁冲突（条件不满足） | 无 |
| 401 Unauthorized | 认证失败 | 无 |

**实现要点**：
- 412 是协议正常行为，不是错误。客户端收到 412 后会重新 GET 并重试。
- 写入必须**原子**（详见 §9.3），避免崩溃导致半写文件。
- 并发 PUT 应串行化校验+写入，防止 TOCTOU 竞争。

### 5.4 GET blob

**请求**：

```http
GET /api/v2/blob/<hash> HTTP/1.1
Authorization: Bearer <token>
```

**语义**：下载指定 hash 的 blob 密文。

**响应**：

| 状态码 | 含义 | Body |
|--------|------|------|
| 200 OK | 成功 | blob 密文（二进制） |
| 404 Not Found | blob 不存在 | 空 |
| 401 Unauthorized | 认证失败 | 错误描述 |

### 5.5 PUT blob（幂等）

**请求**：

```http
PUT /api/v2/blob/<hash> HTTP/1.1
Authorization: Bearer <token>
Content-Type: application/octet-stream
```

Body 为 blob 密文（二进制）。

**语义**：上传 blob。相同 hash 多次上传结果一致。

**响应**：

| 状态码 | 含义 |
|--------|------|
| 200 OK / 201 Created | 写入成功 |
| 401 Unauthorized | 认证失败 |

**实现要点**：
- 服务端**不应**校验 blob 内容与 hash 是否匹配（零知识要求）。
- 服务端**不应**对 blob 做 ETag 检查（blob 不可变，无需乐观锁）。
- 写入建议原子化，但不强制（blob 损坏客户端会通过 hash 校验发现）。

### 5.6 GET /api/v2/health（可选但推荐）

**请求**：

```http
GET /api/v2/health HTTP/1.1
```

**语义**：服务端健康检查，**不需要认证**。

**响应**：

| 状态码 | 含义 | Body |
|--------|------|------|
| 200 OK | 服务就绪 | `ok` |

**用途**：集成测试与负载均衡器探活。无法提供此端点的实现需在测试中改用其他就绪检测方式。

### 5.7 DELETE /api/v2/manifest（v2.1 新增）

**请求**：

```http
DELETE /api/v2/manifest HTTP/1.1
Authorization: Bearer <token>
```

**语义**：删除 manifest 文件。客户端在 manifest 解析失败（密文损坏、版本不兼容等）时调用此端点清理损坏文件，然后用本地数据重建 manifest 上传。

**幂等性**：删除不存在的 manifest 返回 204（视为成功）。

**响应**：

| 状态码 | 含义 |
|--------|------|
| 204 No Content | 删除成功（或文件本不存在） |
| 401 Unauthorized | 认证失败 |
| 405 Method Not Allowed | 旧版 v2 服务端未实现此端点（客户端静默降级） |
| 500 Internal Server Error | 服务端异常 |

**实现要点**：
- 删除操作应与 PUT manifest 共享同一个互斥锁，避免与并发 PUT 竞争。
- 客户端在调用此端点后会立即用 PUT 重新上传 manifest，因此 DELETE 失败也不应阻断流程（PUT 会覆盖旧文件）。
- 此端点不返回 ETag。

### 5.8 DELETE /api/v2/blob/<hash>（v2.1 新增，GC 用）

**请求**：

```http
DELETE /api/v2/blob/<hash> HTTP/1.1
Authorization: Bearer <token>
```

**语义**：删除指定 hash 的 blob。客户端在 GC 流程中识别出 manifest 未引用的孤儿 blob 后，调用此端点清理。

**幂等性**：删除不存在的 blob 返回 204（视为成功）。

**响应**：

| 状态码 | 含义 |
|--------|------|
| 204 No Content | 删除成功（或 blob 本不存在） |
| 400 Bad Request | hash 格式非法（含路径分隔符或 `..`） |
| 401 Unauthorized | 认证失败 |
| 405 Method Not Allowed | 旧版 v2 服务端未实现此端点（客户端静默降级） |
| 500 Internal Server Error | 服务端异常 |

**实现要点**：
- 必须复用 GET/PUT blob 的路径安全校验（`resolveBlobPath`），防止目录穿越。
- 服务端**不应**校验 blob 内容与 hash 是否匹配（零知识要求）。
- 客户端对非 2xx 状态静默跳过，GC 失败不阻断同步流程。

### 5.9 GET /api/v2/blobs（v2.1 新增，GC 用）

**请求**：

```http
GET /api/v2/blobs HTTP/1.1
Authorization: Bearer <token>
```

**语义**：列出服务端存储的所有 blob hash。客户端用此列表与 manifest 引用的 blob hash 对比，识别孤儿 blob。

**响应**：

| 状态码 | 含义 | Body |
|--------|------|------|
| 200 OK | 成功 | JSON 数组，如 `["hash1", "hash2", ...]` |
| 401 Unauthorized | 认证失败 | 错误描述 |
| 405 Method Not Allowed | 旧版 v2 服务端未实现此端点（客户端静默降级为空列表） | 空 |

**响应体格式**：

```json
["a1b2c3d4e5f6...", "f7e6d5c4b3a2...", ...]
```

**实现要点**：
- 返回 `blobs/` 目录下所有文件的文件名（即 hash），跳过 `.tmp` 临时文件和子目录。
- 服务端不解析 blob 内容，仅列文件名。
- **需认证**：此端点不破坏 §10.5 防枚举原则——攻击者无 Token 无法访问。
- blobs 目录不存在时返回空数组 `[]`。
- 客户端对 404/405/网络错误静默降级为空列表，GC 退化为"只标记不清理"。

---

## 六、ETag 规范

### 6.1 格式要求

- **强 ETag**：禁止使用弱 ETag（`W/` 前缀）。
- **引号包裹**：建议格式 `"opaque-token"`，如 `"a1b2c3..."`。
- **内容不透明**：客户端不解析 ETag 内容，只做字符串比较。服务端可用 hash、版本号、UUID 等任意形式。

### 6.2 变化时机

- 每次 manifest PUT 成功后，新返回的 ETag **必须**与上一次不同。
- 同一 manifest 内容多次 GET 返回的 ETag 应保持稳定（直到下次 PUT）。

### 6.3 实现建议

| 方案 | 优点 | 缺点 |
|------|------|------|
| `ETag = "\"" + SHA-256(密文) + "\""` | 内容寻址、纯函数、无状态 | 大文件 hash 计算开销 |
| `ETag = "\"" + 自增版本号 + "\""` | 计算快、单调递增 | 需要服务端维护版本状态 |
| `ETag = "\"" + UUID + "\""` | 简单 | 与内容无关，无法去重 |

参考实现采用 SHA-256 方案，因为 manifest 通常只有几 KB 到几十 KB。

### 6.4 ETag 比较规则

客户端发送的 `If-Match` 值可能带引号也可能不带（HTTP 客户端行为不一致）。服务端实现应在比较前**统一去掉首尾引号**后再做字符串匹配。

---

## 七、乐观锁规则

### 7.1 If-None-Match: *

**语义**：请求要求资源在服务端**不存在**。

**服务端行为**：
- 资源不存在 → 通过，继续写入。
- 资源已存在 → 返回 412 Precondition Failed。

**客户端用途**：首次上传 manifest 时确保不会覆盖他人已有数据。

### 7.2 If-Match: "<etag>"

**语义**：请求要求资源在服务端**存在且 ETag 等于指定值**。

**服务端行为**：
- 资源不存在 → 返回 412。
- 资源存在但 ETag 不匹配 → 返回 412。
- 资源存在且 ETag 匹配 → 通过，继续写入。

**客户端用途**：更新 manifest 时防止覆盖其他设备的并发更新。

### 7.3 都不带条件头

**服务端行为**：应容忍，直接写入（最后写入胜）。

**风险**：失去并发保护。客户端不应主动使用此模式，但服务端不应拒绝。

### 7.4 并发安全

服务端必须保证"条件检查 + 写入"是**原子操作**，不能出现：

1. 设备 A 检查 If-Match 通过
2. 设备 B 检查 If-Match 通过（同一旧 ETag）
3. 设备 A 写入
4. 设备 B 写入（覆盖 A）

实现方式：全局锁、文件锁、数据库事务、CAS 原语均可。

---

## 八、错误处理

### 8.1 HTTP 状态码总表

| 状态码 | 场景 | 客户端行为 |
|--------|------|-----------|
| 200 OK | GET / PUT 成功 | 继续 |
| 201 Created | PUT 首次创建 | 继续 |
| 204 No Content | DELETE 成功（v2.1） | 继续 |
| 401 Unauthorized | 认证失败 | 提示用户检查配置 |
| 404 Not Found | GET manifest / GET blob 资源不存在 | manifest: 视为首次同步；blob: 跳过本次 |
| 405 Method Not Allowed | v2.1 端点未实现（旧版 v2 服务端） | 客户端静默降级 |
| 412 Precondition Failed | PUT manifest 乐观锁冲突 | 重新 GET manifest 并重试（最多 3 次） |
| 429 Too Many Requests | 认证失败速率限制触发（v2.1） | 等待 Retry-After 后重试 |
| 5xx Server Error | 服务端异常 | 中止本次同步，等下次触发 |

### 8.2 重试语义

服务端不负责重试，由客户端实现。服务端只需保证：
- 412 不是错误，是协议正常的并发冲突信号。
- 5xx 可以被客户端重试。

### 8.3 响应 Body

错误响应的 Body 内容客户端不解析，仅供人类调试。建议返回简短的纯文本错误描述，如 `"If-Match failed (etag mismatch)"`。

---

## 九、存储实现指引

本节非强制，但强烈建议遵循。

### 9.1 物理布局示例（文件系统）

```
<dataDir>/
├── manifest                # manifest 密文（单文件）
└── blobs/
    ├── <hash-1>            # 按 hash 命名的 blob 文件
    └── <hash-2>
```

其他存储后端应保持等价的逻辑隔离。

### 9.2 路径穿越防护

如果服务端用文件系统存储，必须校验 `<hash>` 不会逃逸出 `<dataDir>/blobs/`：

- 拒绝包含 `..` 或路径分隔符的 hash。
- 拒绝空 hash、含 NUL 字节的 hash。
- 使用 `filepath.Join` + `filepath.Abs` 后验证结果以 `<dataDir>/blobs/` 为前缀。

这是安全红线，缺失会导致目录穿越漏洞。

对于数据库存储，hash 是主键，不存在路径穿越问题。

### 9.3 原子写入

manifest 与 blob 的 PUT 应使用原子写入：

```
1. 写入临时文件（同目录，带 .tmp 后缀）
2. fsync 临时文件
3. rename 临时文件为目标路径
```

避免崩溃导致半写文件污染旧版本。文件系统 `rename` 在同一目录下是原子的（POSIX 保证；Windows `MoveFileEx` 也支持）。

对于数据库存储，用单事务的 UPDATE/INSERT 即可保证原子性。

### 9.4 并发控制

- manifest 写入必须串行化（全局锁或文件锁）。
- blob 写入可并发，但相同 hash 的并发 PUT 应通过原子 rename 自然解决。
- GET 与 PUT 同一资源可并发，GET 应读到完整旧版本或完整新版本，不能读到半写。

### 9.5 孤儿 blob 清理

服务端**不应**主动清理未被 manifest 引用的 blob（零知识要求：服务端不知道 manifest 内容）。

v2.1 起，服务端提供 GC 配套端点，由客户端在合适时机驱动清理：

1. 客户端调用 `GET /api/v2/blobs` 获取服务端所有 blob hash 列表。
2. 客户端用当前 manifest 引用的 blob hash 集合做差集，识别孤儿 blob。
3. 客户端对每个孤儿 blob 调用 `DELETE /api/v2/blob/<hash>` 清理。

**安全性考量**：
- 客户端可能回滚到引用旧 blob 的 manifest 版本，因此 GC 应在 manifest 稳定后执行（如同步成功后延迟一段时间）。
- DELETE 是幂等的，重复删除同一 blob 安全。
- 旧版 v2 服务端未实现这些端点时，客户端 GC 退化为"只标记不清理"，不影响同步正确性。

### 9.6 资源自动创建

PUT 资源时，如果内部存储的父目录/命名空间不存在，服务端应**自动创建**。客户端不需要、也不应该预先"创建目录"。

---

## 十、安全要求

### 10.1 传输层

生产环境**必须**使用 HTTPS。HTTP 仅限本地测试。

### 10.2 Token 安全

- 使用 constant-time compare 校验 Token。
- Token 不明文记录到日志。
- Token 应具有足够熵（建议 ≥ 32 字符随机字符串）。
- 部署时通过环境变量或启动参数传入，不硬编码。

### 10.3 零知识保证

服务端**禁止**做以下事情：

- 解析 manifest 或 blob 的内容。
- 计算或校验 blob 的 hash。
- 缓存、记录、推断笔记明文。
- 维护笔记列表、删除状态、版本历史。

### 10.4 ETag 不泄露信息

ETag 是密文的衍生物（如 SHA-256(密文)），不泄露明文信息。服务端不应使用基于明文的 ETag。

### 10.5 blob 防枚举

服务端**不应**向未认证客户端暴露 blob 列表。客户端只能通过 manifest 获知存在哪些 blob hash。

v2.1 起 `GET /api/v2/blobs` 端点**需认证**才能访问，不破坏防枚举原则——无 Token 的攻击者无法遍历 blob。部署者应确保 Token 足够强（≥ 32 字符随机字符串），并通过 §10.6 速率限制防止暴力枚举。

### 10.6 速率限制（强烈建议）

服务端**应**对 401 认证失败做 IP + 时间窗口限速，防止 Token 暴力枚举。

**推荐策略**（参考实现已采用）：
- 按客户端 IP 分组，滑动窗口 1 分钟。
- 同一 IP 在窗口内累计 10 次认证失败后，拒绝该 IP 的所有请求（返回 `429 Too Many Requests`，附 `Retry-After: 60` 头）。
- 认证成功后清除该 IP 的失败计数。
- 通过 `X-Forwarded-For` 头识别反向代理后的真实客户端 IP。
- 可通过启动参数 `--rate-limit N` 配置阈值，`0` 表示禁用（仅测试环境用）。

**其他速率限制**（可选）：
- PUT manifest 频率限制（防恶意覆盖）。
- 总请求频率限制（防 DoS）。

---

## 十一、幂等性保证

| 操作 | 幂等性 | 说明 |
|------|--------|------|
| GET manifest | ✅ | 同一状态多次 GET 返回相同内容与 ETag |
| PUT manifest | ⚠️ 条件幂等 | 带相同 If-Match 的重复 PUT 会被 412 拒绝（已更新过）；带 If-None-Match: * 的重复 PUT 第二次也会被 412 拒绝 |
| DELETE manifest | ✅ | 重复删除返回 204（v2.1） |
| GET blob | ✅ | 多次 GET 返回相同内容 |
| PUT blob | ✅ | 相同 hash + 内容多次上传结果一致 |
| DELETE blob | ✅ | 重复删除返回 204（v2.1） |
| GET blobs | ✅ | 多次 GET 返回相同列表（直到 PUT/DELETE 改变状态）（v2.1） |

服务端实现必须保证上述幂等性，这是协议正确性的基础。

---

## 十二、测试验证

### 12.1 必须通过的测试套件

服务端实现必须通过 `test/sync/safe_server_integration_test.dart` 集成测试。该测试自动启动 server 子进程并验证完整协议。

### 12.2 测试覆盖场景

1. **首次同步**：空远端 + 空本地 → 只上传 manifest
2. **上传笔记**：本地 3 条笔记 → 上传到远端
3. **新设备下载**：模拟新设备同步 → 从远端拉取所有笔记
4. **增量同步**：双方各有独占笔记 → 互相同步后互相获得
5. **LWW 冲突解决**：同 uuid 不同内容 → updatedAt 大的胜出
6. **墓碑传播**：设备 A 软删除 → 设备 B 同步后本地标记删除
7. **幂等性**：连续两次同步 → 第二次无重复传输
8. **HTTP 协议验证**：
   - GET 不存在的 manifest 返回 404
   - 无认证返回 401 并附 WWW-Authenticate
   - PUT manifest 带 If-None-Match: * 首次成功，重复返回 412
   - PUT manifest 带 If-Match 错误 etag 返回 412
   - PUT/GET blob 端到端
9. **v2.1 GC 与自愈流程**：
   - `GET /api/v2/blobs` 返回所有 blob hash（需认证）
   - `DELETE /api/v2/blob/<hash>` 删除孤儿 blob（幂等，404 返回 204）
   - `DELETE /api/v2/manifest` 清理损坏文件（幂等，404 返回 204）
   - 未认证访问 `GET /api/v2/blobs` 返回 401
   - 连续 10 次认证失败后返回 429 Too Many Requests

### 12.3 测试适配

测试通过环境变量 `SN_SERVER` 选择 server 类型（`go` / `node`）。新实现需提供：

1. 可执行命令（如 `myserver --port 8090 --data <dir> --token <token>`）
2. 启动后监听指定端口
3. 实现 `/api/v2/health` 端点供测试轮询就绪
4. 在 `test/sync/safe_server_integration_test.dart` 的 `startServer()` 函数中添加启动逻辑

### 12.4 手动验证

启动 server 后可用 curl 验证基本协议：

```bash
# 健康检查
curl http://localhost:8080/api/v2/health
# ok

# 无认证应返回 401
curl -i http://localhost:8080/api/v2/manifest

# 首次上传 manifest
curl -X PUT -H "Authorization: Bearer my-secret-token" \
  -H "If-None-Match: *" \
  --data-binary @manifest.bin \
  http://localhost:8080/api/v2/manifest

# 重复上传应返回 412
curl -X PUT -H "Authorization: Bearer my-secret-token" \
  -H "If-None-Match: *" \
  --data-binary @manifest.bin \
  http://localhost:8080/api/v2/manifest

# 下载 manifest（带返回的 ETag）
curl -i -H "Authorization: Bearer my-secret-token" \
  http://localhost:8080/api/v2/manifest

# v2.1：列出所有 blob hash（GC 用）
curl -H "Authorization: Bearer my-secret-token" \
  http://localhost:8080/api/v2/blobs
# ["hash1", "hash2", ...]

# v2.1：删除孤儿 blob（幂等，404 返回 204）
curl -i -X DELETE -H "Authorization: Bearer my-secret-token" \
  http://localhost:8080/api/v2/blob/<hash>
# HTTP/1.1 204 No Content

# v2.1：清理损坏 manifest（自愈用）
curl -i -X DELETE -H "Authorization: Bearer my-secret-token" \
  http://localhost:8080/api/v2/manifest
# HTTP/1.1 204 No Content

# v2.1：未认证访问 blobs 列表应返回 401
curl -i http://localhost:8080/api/v2/blobs
# HTTP/1.1 401 Unauthorized

# v2.1：连续 10 次错误 Token 后应返回 429
for i in $(seq 1 11); do
  curl -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer wrong-token" \
    http://localhost:8080/api/v2/manifest
done
# 401 401 401 401 401 401 401 401 401 401 429
```

---

## 十三、参考实现

| 实现 | 路径 | 语言 | 依赖 | 存储后端 | 协议版本 |
|------|------|------|------|---------|---------|
| Go server | [server/go/main.go](../server/go/main.go) | Go | 仅标准库 | 文件系统 | v2.1 |
| Node.js server | [server/nodejs/server.js](../server/nodejs/server.js) | JavaScript | 仅内置模块 | 文件系统 | v2.1 |

两个参考实现使用相同协议语义，可互换，均已实现 v2.1 全部端点（含 DELETE manifest、DELETE blob、GET blobs 与认证失败速率限制）。实现新 server 时建议参照其中之一。

---

## 十四、不强制支持的特性（v2.1）

以下功能在 v2.1 中**不要求**服务端实现，客户端也不会使用：

- MKCOL / PROPFIND / COPY / MOVE 等 WebDAV 方法（注意：DELETE 已在 v2.1 中支持）
- WebDAV 锁定（LOCK / UNLOCK）
- 多用户账号系统、注册、登录
- 分块上传
- 范围请求（Range / Content-Range）
- 压缩传输（Content-Encoding: gzip）
- 配额管理
- 审计日志

未来版本可能扩展其中部分功能。

---

## 十五、版本历史

| 版本 | 日期 | 变更 |
|------|------|------|
| v2.1 | 2026-07-29 | 新增 `DELETE /api/v2/manifest`、`DELETE /api/v2/blob/<hash>`、`GET /api/v2/blobs` 端点（GC 与自愈配套）；速率限制从"推荐"升级为"强烈建议"，并对 401 认证失败做 IP+时间窗口限速；客户端对旧版 v2 服务端（返回 405）静默降级 |
| v2 | 2026-07-28 | 重新设计：单用户 + Bearer Token + `/api/v2/` 路径 + 移除 MKCOL + 移除 vault-root 路径概念 |
| v1 | 2026-07-28 | 初版：WebDAV 子集（含 MKCOL、vault-root 路径、Basic Auth） |
