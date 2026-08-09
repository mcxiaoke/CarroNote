# SafeServer 参考服务端

> **服务端实现文档**：[../docs/server-implementation.md](../docs/server-implementation.md)（架构设计、模块职责、扩展点）
> **API 规范**：[../docs/server-api-spec.md](../docs/server-api-spec.md)（HTTP 端点、ETag、认证）
>
> 本目录提供两个可运行、可测试的参考实现，协议完全一致，可互换。整个 `server/` 目录已被 `.gitignore` 排除，仅供本地测试。

## 目录结构

```
server/
├── go/                         # Go 参考实现（仅标准库）
│   ├── main.go                 # 入口
│   ├── dev.config.json         # 开发配置示例（完整字段）
│   ├── dev.json                # 开发配置（仅日志，精简版）
│   ├── go.mod                  # module safenotes-server
│   └── internal/
│       ├── config/config.go    # 配置（flag + JSON 文件）
│       ├── auth/auth.go        # 认证 + 速率限制（LRU 防护）
│       ├── storage/
│       │   ├── storage.go      # Vault + Storage 接口 + DefaultVaultID
│       │   └── fs.go           # 文件系统实现（含 fsync）
│       ├── backup/             # ★ vault 备份系统（详见 docs/server-backup-design.md）
│       │   ├── engine.go       #   blob 副本池 + manifest 快照 + Tier 2 归档 + 清理
│       │   ├── vault.go        #   ObservableVault：写拦截（blob 即时复制 + manifest 去抖）
│       │   └── scheduler.go    #   双定时器（快照 + 归档）
│       └── server/
│           ├── server.go       # Server + 路由 + graceful shutdown
│           ├── handlers.go     # HTTP handlers
│           ├── middleware.go   # 中间件链（RequestID → Logging → Recover）
│           └── logging.go      # 结构化日志（slog）
├── nodejs/                     # Node.js 参考实现（仅内置模块，无 npm 依赖）
│   ├── server.js               # 入口
│   ├── dev.config.json         # 开发配置示例（完整字段）
│   ├── dev.json                # 开发配置（仅日志，精简版）
│   ├── package.json            # type: "module" (ESM), node >=18
│   └── src/
│       ├── config.js           # 配置（--port/--data/--token + --config 文件）
│       ├── auth.js             # FailTracker + checkToken + extractIP
│       ├── logger.js           # 结构化日志（JSON/文本）
│       ├── middleware.js       # requestID + wrapResponse + makeLogging
│       ├── handlers.js         # HTTP handlers + readBody
│       └── storage/
│           ├── storage.js      # Vault/Storage 基类 + DefaultVaultID
│           └── fs.js           # 文件系统实现
└── deploy/
    └── safeserver.service      # systemd 服务单元文件
```

## 快速启动

### Go server

```bash
# 默认 :4080，token=my-secret-token，数据存到 ./data/
go run ./server/go

# 自定义参数
go run ./server/go -addr :9000 -data /tmp/safeserver-data -token my-secret-token

# 用开发配置（debug 日志 → ./temp/safeserver-debug.log）
cd server/go && go run . -config dev.config.json
```

### Node.js server

```bash
# 默认 :4080，token=my-secret-token，数据存到 ./data/
node server/nodejs/server.js

# 自定义参数
node server/nodejs/server.js --port 9000 --data /tmp/safeserver-data --token my-secret-token

# 用开发配置（debug 日志 → ./temp/safeserver-node-debug.log）
node server/nodejs/server.js --config server/nodejs/dev.config.json
```

## 健康检查

```bash
curl http://localhost:4080/api/v2/health
# ok
```

## 集成测试

```bash
# Go server（默认）
flutter test test/sync/safe_server_integration_test.dart

# Node.js server
$env:SN_SERVER="node"
flutter test test/sync/safe_server_integration_test.dart

# 完整测试套件
flutter test
```

测试前会自动运行 [test/scripts/test-cleanup.ps1](../test/scripts/test-cleanup.ps1) 清理残留进程和临时文件。

## 存储布局

```
<dataDir>/
└── vaults/
    └── vault-default/          # DefaultVaultID（单用户场景）
        ├── manifest            # manifest 密文（单文件）
        ├── blobs/
        │   └── <hash>          # blob 密文
        └── backups/            # ★ 备份区（启用 backup.* 配置后产生）
            ├── blobs/          #   blob 副本池（只增不删，独立 inode）
            └── snap-<ts>/      #   manifest 快照（仅 manifest，共享 blob 池）
```

服务端不解析文件内容，只做二进制存储。多 vault 扩展见 [实现文档 §5](../docs/server-implementation.md#五存储层抽象与扩展)。

## 实现要点

| 特性 | 实现 |
|------|------|
| 认证 | Bearer Token，constant-time compare |
| 速率限制 | IP + 滑动窗口（10/min），`rateLimit: -1` 禁用，LRU 防 OOM |
| ETag | SHA-256(密文)，强 ETag，带引号 |
| 乐观锁 | If-Match / If-None-Match，串行化校验+写入（防 TOCTOU） |
| 原子写入 | tmp + fsync + rename |
| 路径穿越防护 | 校验 hash 不含 `/`、`\`、`..`，验证绝对路径前缀 |
| 并发安全 | manifest 写入互斥锁；blob 写入通过原子 rename |
| 请求体限制 | 默认 64MB，超限返回 413 |
| graceful shutdown | SIGINT/SIGTERM → 等待在途请求（30s 超时） |
| 存储层抽象 | Storage + Vault 接口，支持切换后端 |
| 多 vault 预留 | `NewVault(vaultID)` 接口，默认用 `DefaultVaultID`（"vault-default"） |
| 备份（Go 版） | Tier 1 manifest 快照 + blob 副本池 + Tier 2 zip/tar.gz 归档，配置见 [server-backup-design.md](../docs/server-backup-design.md) |
| 部署 | systemd 服务单元文件（含安全加固），见 [deploy/safeserver.service](deploy/safeserver.service) |

## 自行实现新 server

参照 [server-api-spec.md](../docs/server-api-spec.md) §12.3 的指引：

1. 提供可执行命令（建议支持 `--port` / `--data` / `--token` 参数）
2. 实现 `/api/v2/health` 端点
3. 在 [../test/sync/safe_server_integration_test.dart](../test/sync/safe_server_integration_test.dart) 的 `startServer()` 函数中添加启动逻辑
4. 跑通全部集成测试即可视为协议兼容

服务端实现语言不限，推荐 Python/Go/Rust/Node.js 等带成熟 HTTP 库的语言。
