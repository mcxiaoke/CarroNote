# SafeServer 同步服务端 API 规范 v2.2

> **自包含的服务端实现规范**：任何按本文档实现的 HTTP 服务端均可与 SafeNotes 客户端的 `safeServer` 后端类型互操作。实现者无需阅读客户端代码或客户端协议细节。
>
> 配套参考实现：[Go server](../server/go/main.go)、[Node.js server](../server/nodejs/server.js)。
> 客户端侧的加密格式、冲突解决、同步算法见 [sync-protocol-spec.md](./sync-protocol-spec.md)。
>
> **v2.2 变更摘要**（详见 §15）：
> - 新增**通用资源层** `/api/v2/resources/<path>`（详见 §5.10），用纯 REST/JSON 表达等价于 WebDAV `GET`/`PUT`/`DELETE`/`MOVE`/`MKCOL`/`COPY`/`PROPFIND` 的语义，兼容任意 HTTP client。
> - 软删除（孤儿 blob 隔离）与 `backupCorruptManifest` 现在可走资源层 `move`/`mkdir`/`propfind`，与 `localFs`/`webdav` 后端能力对齐，消除"能力倒置"。
> - `manifest` 与 `blob` 端点（§5.2–§5.9）作为资源层的**便利接口**保留，语义不变，旧客户端（v2.1）继续兼容。
> - 旧版 v2.1/v2 服务端若不实现资源层，客户端对 405 静默降级（仅失去软删除隔离等增强能力）。
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
6. **无目录概念（便利接口层）**：`manifest` 与 `blob` 端点（§5.2–§5.9）本身无目录概念，URL 路径直接对应单个资源。

   > **v2.2 补充**：通用资源层 `/api/v2/resources/<path>`（§5.10）**允许子目录**，以对齐 `localFs`/`webdav` 后端的软删除隔离能力（孤儿 blob 移入 `blobs-orphan/` 子目录）。资源层内的路径必须做严格穿越防护（§9.7），禁止 `..` 逃逸与绝对路径。

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

此外，v2.2 起提供**通用资源层** `/api/v2/resources/<path>`（§5.10），可在 vault 命名空间内对任意路径（含子目录）做 GET/PUT/DELETE/move/mkdir/copy/propfind 操作。该层是 `manifest`/`blob` 便利接口的通用化表达，所有路径均经 `§9.7` 的穿越防护。

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
| GET | `/api/v2/manifest` | 下载 manifest（便利接口，= `GET /api/v2/resources/manifest`） | — | 是 | v2 |
| PUT | `/api/v2/manifest` | 上传 manifest（便利接口） | If-Match / If-None-Match | 是 | v2 |
| DELETE | `/api/v2/manifest` | 清理损坏 manifest（便利接口） | — | 是 | v2.1 |
| GET | `/api/v2/blob/<hash>` | 下载 blob（便利接口，= `GET /api/v2/resources/blobs/<hash>`） | — | 是 | v2 |
| PUT | `/api/v2/blob/<hash>` | 上传 blob（便利接口） | — | 是 | v2 |
| DELETE | `/api/v2/blob/<hash>` | 删除 blob（GC 用，幂等） | — | 是 | v2.1 |
| GET | `/api/v2/blobs` | 列出所有 blob hash（GC 用） | — | 是 | v2.1 |
| GET | `/api/v2/health` | 健康检查（可选） | — | 否 | v2 |
| GET | `/api/v2/resources/<path>` | 读取任意资源（等价 WebDAV GET） | — | 是 | v2.2 |
| PUT | `/api/v2/resources/<path>` | 写入任意资源（等价 WebDAV PUT，支持乐观锁） | If-Match / If-None-Match | 是 | v2.2 |
| DELETE | `/api/v2/resources/<path>` | 删除任意资源（等价 WebDAV DELETE，幂等） | — | 是 | v2.2 |
| POST | `/api/v2/resources/<path>` | 扩展操作：move / mkdir / copy / propfind / stats | — | 是 | v2.2 |

**注意**：v2.1 端点（DELETE manifest、DELETE blob、GET blobs）用于客户端的 GC 与自愈流程。v2.2 通用资源层（`/api/v2/resources/<path>`）是前述便利接口的通用化表达，语义对齐 `localFs`/`webdav` 后端能力；旧版 v2.1/v2 服务端不实现资源层时返回 405，客户端仅失去软删除隔离等增强能力，其余同步流程不受影响。

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

### 5.10 通用资源层 `/api/v2/resources/<path>`（v2.2 新增）

**动机**：`localFs` 后端用 `rename` 把孤儿 blob 移入 `blobs-orphan/`，`webdav` 后端用 `COPY`+`DELETE` 做同样的事。旧版 `safeServer` 没有"移动/建目录"语义，软删除只能用 `GET`+`PUT`+`DELETE` 三段往返，并在 `blobs/` 内伪造 `0rphan-` 前缀，造成"能力倒置"。

v2.2 引入一个**通用资源层**，用纯 REST/JSON 表达等价于 WebDAV 动词的语义，从而：

1. **兼容任意 HTTP client**：不使用 WebDAV 专有方法（`MOVE`/`MKCOL`/`COPY`/`PROPFIND`），只使用 `GET`/`PUT`/`DELETE`/`POST` + JSON body。
2. **能力对齐 fs/webdav**：客户端可用 `move`/`mkdir`/`copy`/`propfind` 在 vault 命名空间内自由组织子目录（如 `blobs-orphan/`）。
3. **零知识不变**：服务端只操作路径与元数据，不解析 blob 内容。
4. **便利接口保持不变**：`manifest`/`blob` 端点（§5.2–§5.9）作为资源层的特化继续提供，旧客户端无需改动。

**路径安全红线**：`<path>` 是 vault 内的相对路径，必须按 §9.7 校验——禁止空路径、绝对路径、含 `..` 逃逸段、含 NUL 字节。一次请求至多穿越一层目录边界（如 `blobs-orphan/<hash>.<ts>`），不允许逃逸出 vault 根。

#### 5.10.1 GET /api/v2/resources/<path>（读资源）

等价于 WebDAV `GET`。

**响应**：

| 状态码 | 含义 | Body | ETag |
|--------|------|------|------|
| 200 OK | 成功 | 资源字节（二进制） | 文件资源**必须返回**强 ETag |
| 404 Not Found | 资源不存在 | 空 | 无 |
| 400 Bad Request | 路径非法（含 `..` / 绝对路径 / NUL） | 错误描述 | 无 |
| 401 Unauthorized | 认证失败 | 错误描述 | 无 |

`<path>` 为空（即 `/api/v2/resources/`）时返回 400 `resource path required`。

#### 5.10.2 PUT /api/v2/resources/<path>（写资源）

等价于 WebDAV `PUT`，支持 `If-Match` / `If-None-Match` 乐观锁（规则同 §5.3 / §7）。

- `<path> == "manifest"` 时复用 §5.3 的 manifest 写入（含互斥锁与乐观锁）。
- 其余资源做原子写入（§9.3）；携带乐观锁条件时先校验再写入。
- 父目录不存在时由服务端自动创建（§9.6 仍适用）。

**响应**：200 OK / 412 Precondition Failed / 400 Bad Request（路径非法）/ 401 Unauthorized，语义同 §5.3。

#### 5.10.3 DELETE /api/v2/resources/<path>（删资源）

等价于 WebDAV `DELETE`，幂等。

- `<path> == "manifest"` 时复用 §5.7。
- 删除不存在的资源返回 204（视为成功）。
- 不递归删除目录（删除非空目录由客户端先逐子项 DELETE，或用 `move` 隔离后整体 `propfind`+删除）。

**响应**：204 No Content / 400 Bad Request（路径非法）/ 401 Unauthorized。

#### 5.10.4 POST /api/v2/resources/<path>（扩展操作）

请求体为 JSON，通过 `op` 字段区分操作：

```json
{ "op": "move",    "dest": "<vault相对目标路径>", "overwrite": false }
{ "op": "copy",    "dest": "<vault相对目标路径>", "overwrite": false }
{ "op": "mkdir" }
{ "op": "propfind", "depth": 1 }
{ "op": "stats" }
```

**`op: "move"`（等价 WebDAV MOVE）**

- `dest` 必填，为 vault 内相对目标路径（经 §9.7 校验）。
- `overwrite=false` 且目标已存在 → 返回 409 Conflict。
- `overwrite=false` 且目标为目录 → 返回 409 Conflict。
- 成功返回 204 No Content。
- 若 `src` 或 `dest` 为 `manifest`，操作全程持有 manifest 互斥锁。

**`op: "copy"`（等价 WebDAV COPY）**

- 语义、错误码与 `move` 一致；不删除源。

**`op: "mkdir"`（等价 WebDAV MKCOL）**

- 创建集合（目录）。
- 目标已存在（文件或目录）→ 返回 405 Method Not Allowed（客户端忽略，视为已存在）。
- 父目录不存在 → 返回 409 Conflict（RFC 4918 §9.3）。
- 路径非法 → 返回 400 Bad Request。
- 成功返回 201 Created。

**`op: "propfind"`（等价 WebDAV PROPFIND）**

- `depth: 1` → 返回集合本身 + 其直接子项的 `[ResourceEntry]` 数组（list）。
- `depth: 0` → 返回单个资源自身的元数据（等价于 `stats`）。
- 资源不存在 → 404 Not Found。
- 返回 `Content-Type: application/json`，数组按子项名排序（结果稳定）。

**`op: "stats"`（`propfind` depth=0 的别名）**

- 返回单个资源的 `ResourceEntry`（文件或目录自身），含 `modTime` 与（文件）`etag`。

**`ResourceEntry` 字段**：

| 字段 | 类型 | 含义 |
|------|------|------|
| `name` | string | 资源名（路径最后一段） |
| `path` | string | vault 内相对路径 |
| `isDir` | bool | 是否为目录 |
| `size` | int64 | 文件大小（字节），目录为 0 |
| `modTime` | int64 | 最后修改时间（Unix 毫秒） |
| `etag` | string | 文件内容的强 ETag（目录为空） |

**未识别的 `op`** 返回 400 Bad Request。

**客户端用法示例（软删除隔离）**：

```bash
# 1. 确保孤儿隔离区存在
curl -X POST -H "Authorization: Bearer <token>" \
  -d '{"op":"mkdir"}' \
  http://localhost:8080/api/v2/resources/blobs-orphan

# 2. 将孤儿 blob 移入隔离区（等价 localFs rename / webdav COPY+DELETE）
curl -X POST -H "Authorization: Bearer <token>" \
  -d '{"op":"move","dest":"blobs-orphan/<hash>.<epochMs>","overwrite":false}' \
  http://localhost:8080/api/v2/resources/blobs/<hash>

# 3. 列出隔离区内容（等价 webdav PROPFIND blobs-orphan/）
curl -X POST -H "Authorization: Bearer <token>" \
  -d '{"op":"propfind","depth":1}' \
  http://localhost:8080/api/v2/resources/blobs-orphan
```

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
| 201 Created | PUT 首次创建 / `mkdir` 成功 | 继续 |
| 204 No Content | DELETE 成功 / `move`/`copy` 成功（v2.2） | 继续 |
| 400 Bad Request | 路径非法（含 `..` / 绝对路径 / NUL）/ JSON 体非法 / `move`/`copy` 缺 `dest` | 视为请求错误，中止本次操作 |
| 401 Unauthorized | 认证失败 | 提示用户检查配置 |
| 404 Not Found | GET manifest / GET blob / `GET|DELETE` resources / `propfind` 资源不存在 | manifest: 视为首次同步；blob: 跳过本次 |
| 405 Method Not Allowed | v2.1/v2.2 端点未实现（旧版服务端）；`mkdir` 目标已存在（v2.2，客户端忽略） | 客户端静默降级 |
| 409 Conflict | `move`/`copy` 目标已存在且 `overwrite=false`；`mkdir` 父目录不存在（v2.2） | 中止本次操作或改用其他策略 |
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

v2.2 起，资源层可在 vault 命名空间内创建子目录（典型用途见 §9.8）：

```
<dataDir>/
├── manifest
└── blobs/
    ├── <hash-1>
    └── blobs-orphan/        # 孤儿 blob 隔离区（v2.2 资源层使用）
        └── <hash>.<epochMs>
```

其他存储后端应保持等价的逻辑隔离。

### 9.2 路径穿越防护

如果服务端用文件系统存储，必须校验 `<hash>` 不会逃逸出 `<dataDir>/blobs/`：

- 拒绝包含 `..` 或路径分隔符的 hash。
- 拒绝空 hash、含 NUL 字节的 hash。
- 使用 `filepath.Join` + `filepath.Abs` 后验证结果以 `<dataDir>/blobs/` 为前缀。

这是安全红线，缺失会导致目录穿越漏洞。

对于数据库存储，hash 是主键，不存在路径穿越问题。

### 9.7 资源层路径穿越防护（v2.2）

通用资源层 `/api/v2/resources/<path>` 允许相对子目录，但必须执行更严格的校验（对应 §5.10 的路径安全红线）：

- 拒绝空路径。
- 拒绝绝对路径（POSIX 以 `/` 开头；Windows 盘符）。
- 拒绝含 `..` 逃逸段的路径（任一路径段为 `..` 即拒绝）。
- 拒绝含 NUL 字节（`\0`）或反斜杠 `\` 的路径。
- 规范化后验证最终物理路径仍停留在 `<dataDir>/vaults/<vaultID>/` 内（含其自身），不允许逃逸。

参考实现提供 `ValidateVaultPath(rel)`（`server/go/internal/storage/storage.go`）与 `validateVaultPath(rel)`（`server/nodejs/src/storage/storage.js`）作为统一校验入口。

对于数据库存储，`<path>` 作为 key 前缀，不存在物理穿越问题，但仍应拒绝 `..` 与绝对路径段以保证语义一致。

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
3. 客户端对每个孤儿 blob 调用 `DELETE /api/v2/blob/<hash>` 清理。**或**（v2.2）先 `move` 到 `blobs-orphan/<hash>.<epochMs>` 隔离，确认无误后再整体清理（见 §9.8）。

**安全性考量**：
- 客户端可能回滚到引用旧 blob 的 manifest 版本，因此 GC 应在 manifest 稳定后执行（如同步成功后延迟一段时间）。
- DELETE 是幂等的，重复删除同一 blob 安全。
- 旧版 v2 服务端未实现这些端点时，客户端 GC 退化为"只标记不清理"，不影响同步正确性。

### 9.6 资源自动创建

PUT 资源时，如果内部存储的父目录/命名空间不存在，服务端应**自动创建**。客户端不需要、也不应该预先"创建目录"。

v2.2 资源层的 `move` / `copy` / `putResource` 同样保证目标父目录存在（不足时自动 `MkdirAll`），因此 `<path>` 可以含子目录层次。但 `mkdir`（`MKCOL`）遵循 RFC 4918 §9.3：父目录必须已存在，否则返回 409 Conflict——这是为了与 WebDAV 语义对齐，客户端应先用 `mkdir` 逐级建目录。

### 9.8 软删除隔离与孤儿 blob（v2.2 资源层）

v2.2 之前，软删除（孤儿 blob 隔离）在 `safeServer` 上只能用 `GET`+`PUT`+`DELETE` 三段往返，并在 `blobs/` 内伪造 `0rphan-<hash>.<epoch>` 前缀——既多往返又污染 `blobs/` 列表，形成对 `localFs`/`webdav` 的"能力倒置"。

v2.2 资源层消除该倒置，使 `safeServer` 与另两个后端能力对齐：

| 操作 | localFs | webdav | safeServer (v2.2) |
|------|---------|--------|-------------------|
| 软删除 | `rename` → `blobs-orphan/<h>.<ts>` | `COPY`+`DELETE` → `blobs-orphan/<h>.<ts>` | `POST {op:"move", dest:"blobs-orphan/<h>.<ts>"}` |
| 列孤儿 | `readdir blobs-orphan` | `PROPFIND blobs-orphan/` | `POST {op:"propfind", depth:1} blobs-orphan` |
| 清理孤儿 | `unlink` | `DELETE` | `DELETE /api/v2/resources/blobs-orphan/<h>.<ts>` |
| 备份损坏 manifest | `rename` → `.corrupt-<ts>` | `COPY`+`DELETE` | `POST {op:"move", dest:".corrupt-<ts>"}` |

**要点**：
- `blobs-orphan/` 是 `blobs/` 的子目录，不影响 `GET /api/v2/blobs` 的列目录结果（该端点只列 `blobs/` 的直接文件）。
- `move` 等价于 `localFs rename`：单次 `rename`（跨设备时退化为 copy+unlink），比旧方案的 `GET`+`PUT`+`DELETE` 节省一次往返与一倍流量。
- 客户端对旧版 v2.1/v2 服务端仍走降级路径（伪造 `0rphan-` 前缀），保证向后兼容。

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

# ── v2.2 通用资源层验证 ──

# 创建孤儿隔离区（等价 webdav MKCOL blobs-orphan/）
curl -i -X POST -H "Authorization: Bearer my-secret-token" \
  -d '{"op":"mkdir"}' \
  http://localhost:8080/api/v2/resources/blobs-orphan
# HTTP/1.1 201 Created

# 重复创建应返回 405（客户端忽略，视为已存在）
curl -i -X POST -H "Authorization: Bearer my-secret-token" \
  -d '{"op":"mkdir"}' \
  http://localhost:8080/api/v2/resources/blobs-orphan
# HTTP/1.1 405 Method Not Allowed

# 写入任意资源（等价 webdav PUT，可含子目录）
curl -X PUT -H "Authorization: Bearer my-secret-token" \
  --data-binary @note.bin \
  http://localhost:8080/api/v2/resources/blobs-orphan/note1

# 软删除：将 blob 移到隔离区（等价 localFs rename / webdav COPY+DELETE）
curl -i -X POST -H "Authorization: Bearer my-secret-token" \
  -d '{"op":"move","dest":"blobs-orphan/<hash>.<epochMs>","overwrite":false}' \
  http://localhost:8080/api/v2/resources/blobs/<hash>
# HTTP/1.1 204 No Content

# 列出隔离区（等价 webdav PROPFIND blobs-orphan/ depth=1）
curl -X POST -H "Authorization: Bearer my-secret-token" \
  -d '{"op":"propfind","depth":1}' \
  http://localhost:8080/api/v2/resources/blobs-orphan
# [{"name":"<hash>.<epochMs>","path":"blobs-orphan/<hash>.<epochMs>","isDir":false,...}]

# 单资源元数据（等价 PROPFIND depth=0）
curl -X POST -H "Authorization: Bearer my-secret-token" \
  -d '{"op":"stats"}' \
  http://localhost:8080/api/v2/resources/blobs/<hash>
# {"name":"<hash>","path":"blobs/<hash>","isDir":false,"size":...,"modTime":...,"etag":"\"...\""}

# 路径穿越应返回 400
curl -i -X POST -H "Authorization: Bearer my-secret-token" \
  -d '{"op":"move","dest":"../../etc/passwd","overwrite":false}' \
  http://localhost:8080/api/v2/resources/blobs/<hash>
# HTTP/1.1 400 Bad Request
```

---

## 十三、参考实现

| 实现 | 路径 | 语言 | 依赖 | 存储后端 | 协议版本 |
|------|------|------|------|---------|---------|
| Go server | [server/go/main.go](../server/go/main.go) | Go | 仅标准库 | 文件系统 | v2.2 |
| Node.js server | [server/nodejs/server.js](../server/nodejs/server.js) | JavaScript | 仅内置模块 | 文件系统 | v2.2 |

两个参考实现使用相同协议语义，可互换，均已实现 v2.2 全部端点（v2.1 的 DELETE manifest、DELETE blob、GET blobs、认证失败速率限制，外加 v2.2 通用资源层 `/api/v2/resources/<path>`）。实现新 server 时建议参照其中之一。

---

## 十四、不强制支持的特性（v2.2）

以下功能在 v2.2 中**不要求**服务端实现，客户端也不会使用：

- **WebDAV 专有方法**：服务端**无需**实现 `MOVE`/`MKCOL`/`COPY`/`PROPFIND` 等 WebDAV HTTP 方法。其等价语义已由通用资源层 `/api/v2/resources/<path>`（§5.10）用 `GET`/`PUT`/`DELETE`/`POST {op}` 表达，以兼容任意 HTTP client。
- WebDAV 锁定（LOCK / UNLOCK）
- 多用户账号系统、注册、登录
- 分块上传
- 范围请求（Range / Content-Range）
- 压缩传输（Content-Encoding: gzip）
- 配额管理
- 审计日志

> 注意：v2.2 资源层的 `move`/`mkdir`/`copy`/`propfind` 操作**正是**对 WebDAV 语义的重新表达，只是协议形态不同（纯 REST/JSON 而非 WebDAV 方法）。客户端对未实现资源层的旧服务端（返回 405）走降级路径。

未来版本可能扩展其中部分功能。

---

## 十五、版本历史

| 版本 | 日期 | 变更 |
|------|------|------|
| v2.2 | 2026-07-31 | 新增通用资源层 `/api/v2/resources/<path>`（GET/PUT/DELETE + POST {op}: move/mkdir/copy/propfind/stats），用纯 REST/JSON 表达等价于 WebDAV 的语义，消除 safeServer 对 localFs/webdav 的"能力倒置"（软删除隔离可走 `move` 到 `blobs-orphan/`）；新增路径安全红线 `ValidateVaultPath`（§9.7）；`manifest`/`blob` 端点作为资源层便利接口保留；Go 与 Node.js 参考实现同步升级 |
| v2.1 | 2026-07-29 | 新增 `DELETE /api/v2/manifest`、`DELETE /api/v2/blob/<hash>`、`GET /api/v2/blobs` 端点（GC 与自愈配套）；速率限制从"推荐"升级为"强烈建议"，并对 401 认证失败做 IP+时间窗口限速；客户端对旧版 v2 服务端（返回 405）静默降级 |
| v2 | 2026-07-28 | 重新设计：单用户 + Bearer Token + `/api/v2/` 路径 + 移除 MKCOL + 移除 vault-root 路径概念 |
| v1 | 2026-07-28 | 初版：WebDAV 子集（含 MKCOL、vault-root 路径、Basic Auth） |
