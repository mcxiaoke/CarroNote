# SafeServer 参考实现文档

> **本文档描述 SafeServer v2.1 协议的两个参考实现（Go / Node.js）的架构设计、模块职责与扩展点。**
>
> - 协议规范（HTTP 端点、ETag、认证等）：[server-api-spec.md](./server-api-spec.md)
> - 客户端同步协议（加密、冲突解决、墓碑）：[sync-protocol-spec.md](./sync-protocol-spec.md)
> - 集成测试：[test/sync/safe_server_integration_test.dart](../test/sync/safe_server_integration_test.dart)

---

## 一、实现概览

| 实现 | 路径 | 语言 | 依赖 | 存储后端 | 协议版本 |
|------|------|------|------|---------|---------|
| Go server | [server/go/](../server/go/) | Go 1.21+ | 仅标准库 | 文件系统 | v2.1 |
| Node.js server | [server/nodejs/](../server/nodejs/) | JavaScript (ESM) | 仅内置模块 | 文件系统 | v2.1 |

两个实现**协议完全一致**，可互换。整个 `server/` 目录已被 `.gitignore` 排除，仅供本地测试和参考。

### 核心特性

| 特性 | 实现方式 |
|------|---------|
| 认证 | Bearer Token + constant-time compare（`crypto/subtle` / `crypto.timingSafeEqual`） |
| 速率限制 | IP + 滑动窗口（1 分钟，默认 10 次），LRU 防 OOM |
| ETag 乐观锁 | SHA-256(密文)，强 ETag，If-Match / If-None-Match |
| 原子写入 | tmp + fsync + rename |
| 路径穿越防护 | hash 校验 + 绝对路径前缀检查 |
| 并发安全 | manifest 操作互斥锁（防 TOCTOU），blob 靠原子 rename |
| 请求体限制 | `http.MaxBytesReader`（Go）/ 流式计数（Node.js），默认 64MB |
| HTTP 超时 | ReadTimeout / WriteTimeout / IdleTimeout |
| graceful shutdown | SIGINT/SIGTERM → 等待在途请求（30s 超时） |
| 结构化日志 | `log/slog`（Go）/ 自实现（Node.js），支持 debug/info/warn/error + 文件输出 |
| 中间件链 | RequestID → Logging → Recover |
| 存储层抽象 | Storage + Vault 接口，支持切换后端 |
| 多 vault 预留 | `NewVault(vaultID)` 接口，vaultID="" 为默认 vault |

---

## 二、代码分层架构

两个实现采用相同的分层设计：

```
入口层（main.go / server.js）
    │
    ├── 配置层（config）    ← 命令行参数 + JSON 配置文件
    │
    ├── HTTP 层（server）
    │   ├── 中间件链        ← RequestID → Logging → Recover
    │   ├── 路由分发        ← 认证 + 限流 + body 限制 + 路由
    │   └── Handlers        ← 调用 Vault 接口，不接触文件系统
    │
    ├── 认证层（auth）      ← Token 校验 + FailTracker
    │
    ├── 存储层（storage）
    │   ├── 接口定义        ← Storage + Vault（抽象）
    │   └── 文件系统实现    ← fs（含 fsync + 路径穿越防护）
    │
    └── 日志层（logging）   ← 结构化日志（slog / 自实现）
```

### 设计原则

1. **Handler 不接触文件系统**：所有数据操作通过 `Vault` 接口，切换存储后端只需实现新 Vault
2. **"校验 + 写入" 同一临界区**：乐观锁校验和写入在同一个锁内完成，防 TOCTOU
3. **零知识**：服务端只处理密文，不解析内容、不计算 hash、不维护版本计数器
4. **幂等性**：DELETE 操作对不存在的资源返回成功（204），PUT blob 相同 hash 覆盖写

---

## 三、Go server 架构

### 3.1 目录结构

```
server/go/
├── main.go                          # 入口（极简：解析配置 → 创建 Server → Run）
├── dev.json                         # 开发配置（debug 日志 → ./temp/safeserver-debug.log）
├── go.mod                           # module safenotes-server, go 1.21+
└── internal/
    ├── config/
    │   └── config.go                # 配置（flag + JSON 文件，命令行优先级最高）
    ├── auth/
    │   └── auth.go                  # Bearer Token 校验 + FailTracker（IP 限速 + LRU 防护）
    ├── storage/
    │   ├── storage.go               # Storage + Vault 接口定义 + 哨兵错误 + ValidateHash + ComputeETag
    │   └── fs.go                    # 文件系统实现（fsVault + atomicWrite）
    └── server/
        ├── server.go                # Server 结构 + 路由分发 + graceful shutdown
        ├── handlers.go              # 7 个 HTTP handler（manifest/blob CRUD + blobs 列表）
        ├── middleware.go            # 中间件链（Chain + RequestID + Logging + Recover）
        └── logging.go               # slog 日志器 + statusWriter（捕获状态码/字节数）
```

### 3.2 请求处理流程

```
HTTP 请求
    │
    ▼
中间件链（外到内）：RequestID → Logging → Recover
    │
    ▼
Server.handle()
    ├── 1. http.MaxBytesReader 限制请求体大小
    ├── 2. /api/v2/health → 直接返回 200 "ok"（无需认证）
    ├── 3. FailTracker.IsRateLimited → 429
    ├── 4. auth.CheckToken → 401（记录失败）
    ├── 5. 认证成功 → ResetFailures
    └── 6. 路由分发：
         ├── /api/v2/manifest    → GET/PUT/DELETE
         ├── /api/v2/blobs       → GET
         └── /api/v2/blob/<hash> → GET/PUT/DELETE
```

### 3.3 关键设计

#### 配置合并优先级

```
命令行 flag > 配置文件 > 默认值
```

配置文件用"非零则覆盖"策略合并。**已知限制**：无法通过配置文件设置 `rateLimit: 0`（禁用限速）或 `logJSON: false`，因为这些是零值。如需禁用限速，用命令行 `-rate-limit 0`。

#### FailTracker 速率限制

```go
type FailTracker struct {
    failures   map[string][]time.Time  // IP → 失败时间戳列表
    lastAccess map[string]time.Time    // IP → 最后访问时间（LRU 用）
    window     time.Duration           // 滑动窗口（1 分钟）
    maxIPs     int                     // 最多跟踪 10000 个 IP
}
```

- **滑动窗口**：只统计 1 分钟内的失败次数，超 `limit` 次返回 429
- **OOM 防护**：IP 数超 `maxIPs` 时先清过期记录，仍超则 LRU 淘汰最久未访问的 IP
- **认证成功清除计数**：防止正常用户因偶发 401 被限速

#### 原子写入

```go
func atomicWrite(path string, data []byte, perm os.FileMode) error {
    // 1. 写 .tmp 临时文件
    // 2. f.Sync()（fsync，确保数据落盘）
    // 3. os.Rename(tmpPath, path)（同目录 rename 是原子的）
    // 任何步骤失败都清理 .tmp，不影响已有数据
}
```

#### 乐观锁 + TOCTOU 防护

```go
func (v *fsVault) PutManifest(data []byte, opts PutOptions) error {
    v.mu.Lock()
    defer v.mu.Unlock()

    existing, err := os.ReadFile(v.manifestPath())  // 锁内读取
    exists := err == nil

    // 乐观锁校验（锁内）
    if opts.IfNoneMatch && exists { return ErrPreconditionFailed }
    if opts.IfMatch != "" {
        if !exists { return ErrPreconditionFailed }
        if ComputeETag(existing) != `"`+opts.IfMatch+`"` { return ErrPreconditionFailed }
    }

    // 写入（锁内）
    return atomicWrite(v.manifestPath(), data, 0o644)
}
```

#### graceful shutdown

```go
func (s *Server) Run() error {
    srv := &http.Server{...}
    go srv.ListenAndServe()

    sigCh := make(chan os.Signal, 1)
    signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

    select {
    case err := <-errCh: return err
    case sig := <-sigCh:
        ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
        defer cancel()
        return srv.Shutdown(ctx)  // 等待在途请求完成
    }
}
```

---

## 四、Node.js server 架构

### 4.1 目录结构

```
server/nodejs/
├── server.js                        # 入口（配置 → 存储 → 路由 → 启动 + graceful shutdown）
├── dev.json                         # 开发配置（debug 日志 → ./temp/safeserver-node-debug.log）
├── package.json                     # type: "module" (ESM), engines: node >=18
└── src/
    ├── config.js                    # 配置（--port/--data/--token + --config 文件）
    ├── auth.js                      # FailTracker + checkToken + extractIP
    ├── logger.js                    # 轻量结构化日志（JSON/文本，支持文件输出）
    ├── middleware.js                # requestID + wrapResponse + makeLogging
    ├── handlers.js                  # 7 个 HTTP handler + readBody（带大小限制）
    └── storage/
        ├── storage.js               # Vault/Storage 基类 + 哨兵错误 + validateHash + computeETag
        └── fs.js                    # FileSystemStorage + FsVault + atomicWrite
```

### 4.2 请求处理流程

```
HTTP 请求
    │
    ▼
handle(req, res)
    ├── 1. requestID(req, res)         ← 生成/读取 X-Request-ID
    ├── 2. wrapResponse(res)           ← 拦截 writeHead/write/end，捕获状态码和字节数
    ├── 3. req._maxBodyBytes = cfg.maxBodyBytes
    ├── 4. /api/v2/health → 200 "ok"（无需认证）
    ├── 5. FailTracker.isRateLimited → 429
    ├── 6. checkToken → 401（记录失败）
    ├── 7. 认证成功 → resetFailures
    ├── 8. 路由分发 → handlers.* 
    └── finally: makeLogging(logger) 记录请求日志
```

### 4.3 关键设计

#### manifest 操作串行化（Promise 链）

```javascript
withLock(fn) {
    const next = this.manifestLock.then(fn, fn);
    this.manifestLock = next.catch(() => {});
    return next;
}

async putManifest(data, opts) {
    return this.withLock(async () => {
        // 锁内：读取 + 乐观锁校验 + 原子写入
    });
}
```

#### 请求体大小限制

```javascript
export function readBody(req, maxBytes) {
    return new Promise((resolve, reject) => {
        const chunks = [];
        let total = 0;
        req.on('data', (c) => {
            total += c.length;
            if (total > maxBytes) {
                req.destroy();
                reject(new Error('Payload Too Large'));
                return;
            }
            chunks.push(c);
        });
        req.on('end', () => resolve(Buffer.concat(chunks)));
    });
}
```

#### 超时配置（对应 Go 语义）

```javascript
server.requestTimeout = cfg.readTimeoutMs;   // 整个请求超时（含 body）
server.headersTimeout = cfg.readTimeoutMs;   // 请求头读取超时
server.timeout = cfg.writeTimeoutMs;          // socket 不活动超时（写响应）
```

---

## 五、存储层抽象与扩展

### 5.1 接口定义

```
Storage（存储后端工厂）
  └── NewVault(vaultID) → Vault

Vault（单 vault 操作句柄）
  ├── GetManifest() → []byte
  ├── PutManifest(data, opts) → error  ← 含乐观锁
  ├── DeleteManifest() → error          ← 幂等
  ├── GetBlob(hash) → []byte
  ├── PutBlob(hash, data) → error       ← 幂等（覆盖写）
  ├── DeleteBlob(hash) → error          ← 幂等
  └── ListBlobs() → []string
```

### 5.2 文件系统存储布局

```
所有 vault 统一在 vaults/ 目录下按 vaultID 隔离：

<rootDir>/vaults/<vaultID>/manifest     # manifest 密文
<rootDir>/vaults/<vaultID>/blobs/<hash> # blob 密文

单用户场景使用 DefaultVaultID（"vault-default"）：
<rootDir>/vaults/vault-default/manifest
<rootDir>/vaults/vault-default/blobs/<hash>
```

不再使用空字符串 `vaultID=""`，这样：
- 文件系统实现中所有 vault 都统一在 `<rootDir>/vaults/<vaultID>/` 下，不污染根目录
- 数据库实现中 vaultID 可直接用作表名前缀或分区键（如 `manifest_vault_default`），无需特判空值
- 存储布局一致，便于管理和扩展

### 5.3 切换存储后端

实现新的 `Storage` + `Vault` 即可，无需改 Handler。例如用 SQLite：

```go
// Go 示例
type SQLiteStorage struct { db *sql.DB }
type SQLiteVault struct { db *sql.DB; vaultID string }

func (s *SQLiteStorage) NewVault(vaultID string) (Vault, error) {
    // 创建表（如不存在）
    return &SQLiteVault{db: s.db, vaultID: vaultID}, nil
}

func (v *SQLiteVault) PutManifest(data []byte, opts PutOptions) error {
    // 单事务内完成：SELECT 现有 → 乐观锁校验 → UPSERT
    // 数据库事务天然保证原子性，不需要 tmp+rename
}
```

```javascript
// Node.js 示例
class SQLiteVault extends Vault {
    async putManifest(data, opts) {
        // BEGIN TRANSACTION
        // SELECT existing → 乐观锁校验 → INSERT OR REPLACE
        // COMMIT
    }
}
```

### 5.4 多 vault / 多用户扩展

当前为单 vault 模式（`vaultID=""`），接口已预留：

1. **多 vault**：`NewVault(vaultID)` 按 vaultID 隔离存储。文件系统按目录隔离，数据库按表名前缀/分区键隔离
2. **多用户**：在 `Storage` 层之上加用户认证层（替换当前的固定 Token），每个用户对应一个或多个 vault
3. **向后兼容**：vaultID="" 始终使用默认布局（`<rootDir>/`），不改变现有存储格式

---

## 六、配置

### 6.1 配置来源与优先级

```
命令行参数 > JSON 配置文件 > 默认值
```

### 6.2 Go server 配置

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `-config` | string | "" | JSON 配置文件路径 |
| `-addr` | string | `:4080` | 监听地址 |
| `-data` | string | `./data` | 数据存储目录 |
| `-token` | string | `my-secret-token` | Bearer Token |
| `-rate-limit` | int | 10 | 每分钟认证失败上限（<=0 禁用，建议用 -1） |
| `-max-body` | int64 | 67108864 (64MB) | 请求体最大大小 |
| `-read-timeout` | duration | 60s | HTTP 读超时 |
| `-write-timeout` | duration | 60s | HTTP 写超时 |
| `-idle-timeout` | duration | 120s | HTTP 空闲超时 |
| `-log-level` | string | info | 日志级别（debug/info/warn/error） |
| `-log-file` | string | "" | 日志文件路径（空=stdout） |
| `-log-json` | bool | false | JSON 格式日志 |

### 6.3 Node.js server 配置

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `--config` | string | "" | JSON 配置文件路径 |
| `--port` | int | 4080 | 监听端口 |
| `--data` | string | `./data` | 数据存储目录 |
| `--token` | string | `my-secret-token` | Bearer Token |
| `--rate-limit` | int | 10 | 每分钟认证失败上限（<=0 禁用，建议用 -1） |
| `--max-body` | int | 67108864 (64MB) | 请求体最大大小 |
| `--read-timeout` | int | 60000 | 读超时（毫秒） |
| `--write-timeout` | int | 60000 | 写超时（毫秒） |
| `--log-level` | string | info | 日志级别 |
| `--log-file` | string | "" | 日志文件路径（空=stdout） |
| `--log-json` | bool | false | JSON 格式日志 |

### 6.4 示例配置文件

完整的示例配置文件见 [server/go/dev.config.json](../server/go/dev.config.json) 和 [server/nodejs/dev.config.json](../server/nodejs/dev.config.json)，包含所有字段和注释。

Go `server/go/dev.config.json`:
```json
{
  "addr": ":4080",
  "dataDir": "./data",
  "token": "change-me-to-a-strong-token",
  "rateLimit": 10,
  "maxBodyBytes": 67108864,
  "readTimeout": "60s",
  "writeTimeout": "60s",
  "idleTimeout": "120s",
  "logLevel": "debug",
  "logFile": "./temp/safeserver-debug.log",
  "logJSON": false
}
```

Node.js `server/nodejs/dev.config.json`:
```json
{
  "port": 4080,
  "dataDir": "./data",
  "token": "change-me-to-a-strong-token",
  "rateLimit": 10,
  "maxBodyBytes": 67108864,
  "readTimeoutMs": 60000,
  "writeTimeoutMs": 60000,
  "logLevel": "debug",
  "logFile": "./temp/safeserver-node-debug.log",
  "logJSON": false
}
```

用法：
```bash
# Go
cd server/go && go run . -config dev.config.json

# Node.js
node server/nodejs/server.js --config server/nodejs/dev.config.json
```

### 6.5 部署：systemd 服务

生产环境部署用 systemd 管理进程，见 [server/deploy/safeserver.service](../server/deploy/safeserver.service)。

快速部署（Linux）：
```bash
# 1. 构建二进制
cd /opt/safenotes/server/go && go build -o /usr/local/bin/safeserver .

# 2. 创建专用用户和数据目录
sudo useradd -r -s /usr/sbin/nologin safenotes
sudo mkdir -p /var/lib/safenotes
sudo chown safenotes:safenotes /var/lib/safenotes

# 3. 安装 systemd 服务
sudo cp server/deploy/safeserver.service /etc/systemd/system/
# 编辑 token 和路径
sudo $EDITOR /etc/systemd/system/safeserver.service

# 4. 启用并启动
sudo systemctl daemon-reload
sudo systemctl enable safeserver
sudo systemctl start safeserver

# 5. 查看日志
sudo journalctl -u safeserver -f
```

systemd 服务文件包含安全加固：专用用户运行、`ProtectSystem=strict`、`MemoryMax=256M`、`LimitNOFILE=4096` 等。

---

## 七、日志

### 7.1 日志格式

**文本格式**（默认）：
```
time=2026-07-29T11:09:47.577+08:00 level=INFO msg="SafeServer v2.1 (Go) starting" addr=:8080 ...
time=2026-07-29T11:09:48.088+08:00 level=DEBUG msg="request detailed" method=GET path=/api/v2/health status=200 duration_ms=0 request_id=5f63f6b7...
```

**JSON 格式**（`-log-json`）：
```json
{"time":"2026-07-29T11:09:47.577+08:00","level":"INFO","msg":"SafeServer v2.1 (Go) starting","addr":":8080",...}
```

### 7.2 日志级别

| 级别 | 记录内容 |
|------|---------|
| `error` | panic 恢复、handler 内部错误、graceful shutdown 超时 |
| `warn` | graceful shutdown 超时强制退出 |
| `info` | server 启动信息、每个请求的精简日志（method/path/status/duration_ms/request_id/remote_addr） |
| `debug` | 每个请求的详细日志（额外包含 req_headers、resp_bytes、host；Authorization 头脱敏） |

### 7.3 debug 日志示例

```
time=2026-07-29T11:09:48.175+08:00 level=DEBUG msg="request detailed" 
  method=PUT path=/api/v2/manifest query="" status=200 duration_ms=4 
  request_id=a96b09c3383a4d77 remote_addr=127.0.0.1 
  req_headers="map[authorization:Bearer test-...(masked) content-length:444 
  content-type:application/octet-stream if-match: if-none-match:* x-forwarded-for:]" 
  resp_bytes=0 host=localhost:8131
```

---

## 八、安全机制

### 8.1 认证

- **Bearer Token**：固定 Token，部署时配置
- **constant-time compare**：防时序攻击（Go `crypto/subtle.ConstantTimeCompare` / Node.js `crypto.timingSafeEqual`）
- **Token 脱敏**：日志中只显示 `Bearer test-...(masked)`，不泄露完整 Token

### 8.2 速率限制

- **触发条件**：仅 401 认证失败计数（不是所有请求）
- **窗口**：滑动窗口（1 分钟），超 `limit` 次后返回 429 + `Retry-After: 60`
- **清除**：认证成功后立即清除该 IP 的失败计数
- **OOM 防护**：最多跟踪 10000 个 IP，超限时先清过期记录，仍超则 LRU 淘汰

### 8.3 路径穿越防护

```go
// 三层防护
1. ValidateHash(hash)              // 拒绝空/含 / \ .. \0 的 hash
2. filepath.Join(blobsDir, hash)   // 拼接路径
3. filepath.Abs + HasPrefix 校验   // 验证最终路径仍在 blobs/ 下
```

### 8.4 请求体限制

- `http.MaxBytesReader`（Go）/ 流式计数（Node.js），默认 64MB
- 超限返回 413 Payload Too Large（Go 在修复后正确返回 413）

### 8.5 超时控制

| 超时 | Go | Node.js | 作用 |
|------|-----|---------|------|
| ReadTimeout | `http.Server.ReadTimeout` | `server.requestTimeout` | 整个请求读取超时（含 body） |
| WriteTimeout | `http.Server.WriteTimeout` | `server.timeout` | 响应写入超时 |
| IdleTimeout | `http.Server.IdleTimeout` | `server.keepAliveTimeout` | keep-alive 空闲超时 |
| HeadersTimeout | — | `server.headersTimeout` | 请求头读取超时 |

---

## 九、测试

### 9.1 集成测试

[test/sync/safe_server_integration_test.dart](../test/sync/safe_server_integration_test.dart) 覆盖：

| 测试组 | 内容 |
|--------|------|
| 首次同步 | 空数据库首次同步、上传 3 条笔记 |
| 新设备同步 | 从远端下载所有笔记 |
| 增量同步 | 双方各有独占笔记，同步后互相获得 |
| LWW 冲突 | updatedAt 更大的远端笔记覆盖本地 |
| 墓碑同步 | 软删除传播到已下载笔记的设备 |
| 幂等性 | 连续两次同步结果一致 |
| HTTP 协议 | 404/401/412/ETag/If-Match/If-None-Match 端到端验证 |
| v2.1 GC 端点 | GET blobs、DELETE blob、DELETE manifest、幂等性 |
| 速率限制 | 连续认证失败超限后返回 429 |

### 9.2 运行测试

```bash
# Go server（默认）
flutter test test/sync/safe_server_integration_test.dart

# Node.js server
$env:SN_SERVER="node"
flutter test test/sync/safe_server_integration_test.dart

# 完整测试套件
flutter test
```

### 9.3 测试基础设施

- **清理脚本**：[test/scripts/test-cleanup.ps1](../test/scripts/test-cleanup.ps1) 杀残留进程 + 清理临时文件
- **setUpAll**：清理 → 构建 Go 二进制 → 生成配置文件 → 启动 server → 等待就绪
- **tearDownAll**：停 server → 清理残留进程
- **每个测试**：`clearData()` 清理 manifest + blobs（比重启 server 快）

---

## 十、已知限制与未来扩展

### 10.1 已知限制

1. **配置文件零值合并**：JSON 配置文件用"非零则覆盖"策略，`rateLimit: 0` 无法从配置文件设置（用 `rateLimit: -1` 禁用，命令行 `-rate-limit 0` 也可）
2. **单 vault**：当前只有默认 vault（vaultID="vault-default"），多 vault 接口已预留但未在 HTTP 层暴露
3. **无 HTTPS**：server 只监听 HTTP，HTTPS 由反向代理（nginx/caddy）处理
4. **无持久化限速状态**：FailTracker 在内存中，server 重启后清空

### 10.2 扩展方向

| 方向 | 实现方式 |
|------|---------|
| 切换到 SQLite/数据库存储 | 实现 `SQLiteStorage` + `SQLiteVault`，用事务替代 tmp+rename |
| 多 vault | HTTP 层从请求中提取 vaultID，调用 `storage.NewVault(vaultID)`，当前默认用 `DefaultVaultID` |
| 多用户 | 在 Storage 层之上加用户认证层，每用户对应独立 Storage 实例 |
| 对象存储（S3） | 实现 `S3Storage`，用 ETag 头替代文件系统 ETag |
| HTTPS | 用 `http.ListenAndServeTLS` 替代 `ListenAndServe`（Go）/ `https.createServer`（Node.js） |
| Prometheus metrics | 新增 `/metrics` 端点（当前未实现，用户明确表示暂不需要） |
| 热更新 | 配置文件 watch + SIGHUP 重新加载（当前未实现，用户明确表示暂不需要） |
