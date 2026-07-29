# SafeServer 参考服务端

> **本文档不是必需的**——服务端 API 规范见 [../docs/server-api-spec.md](../docs/server-api-spec.md)。本目录仅提供两个可运行、可测试的参考实现。

## 目录结构

```
server/
├── go/
│   └── main.go            # Go 参考实现（仅标准库）
└── nodejs/
    └── server.js          # Node.js 参考实现（仅内置模块，无 npm 依赖）
```

两个实现协议完全一致，可互换。整个 `server/` 目录已被 `.gitignore` 排除，仅供本地测试。

## 快速启动

### Go server

```bash
# 默认 :8080，token=my-secret-token，数据存到 ./server/go/data/
go run ./server/go

# 自定义参数
go run ./server/go -addr :9000 -data /tmp/safeserver-data -token my-secret-token
```

### Node.js server

```bash
# 默认 :8080，token=my-secret-token，数据存到 ./server/nodejs/data/
node server/nodejs/server.js

# 自定义参数
node server/nodejs/server.js --port 9000 --data /tmp/safeserver-data --token my-secret-token
```

## 健康检查

启动后访问：

```bash
curl http://localhost:8080/api/v2/health
# ok
```

## 协议验证

完整协议见 [../docs/server-api-spec.md](../docs/server-api-spec.md)。快速手动验证：

```bash
TOKEN="my-secret-token"
BASE="http://localhost:8080"

# 无认证应返回 401 + WWW-Authenticate
curl -i $BASE/api/v2/manifest

# 首次 GET manifest 应返回 404
curl -i -H "Authorization: Bearer $TOKEN" $BASE/api/v2/manifest

# 首次 PUT manifest（If-None-Match: *）
echo -n "test-manifest-v1" | curl -X PUT -i \
  -H "Authorization: Bearer $TOKEN" \
  -H "If-None-Match: *" \
  --data-binary @- \
  $BASE/api/v2/manifest
# 200 + ETag: "<hash>"

# 重复 PUT（应 412）
echo -n "test-manifest-v1" | curl -X PUT -i \
  -H "Authorization: Bearer $TOKEN" \
  -H "If-None-Match: *" \
  --data-binary @- \
  $BASE/api/v2/manifest
# 412 Precondition Failed

# PUT blob
echo -n "blob-content" | curl -X PUT -i \
  -H "Authorization: Bearer $TOKEN" \
  --data-binary @- \
  $BASE/api/v2/blob/abc123

# GET blob
curl -i -H "Authorization: Bearer $TOKEN" $BASE/api/v2/blob/abc123
```

## 集成测试

Flutter 客户端集成测试见 [../test/sync/safe_server_integration_test.dart](../test/sync/safe_server_integration_test.dart)。测试通过环境变量 `SN_SERVER` 选择 server 类型：

```bash
# 用 Go server 测试
$env:SN_SERVER="go"
flutter test test/sync/safe_server_integration_test.dart

# 用 Node.js server 测试
$env:SN_SERVER="node"
flutter test test/sync/safe_server_integration_test.dart
```

测试自动启动/停止 server 子进程，验证完整协议（首次同步、增量同步、LWW 冲突、墓碑传播、ETag 乐观锁等）。

## 存储布局

两个实现都使用文件系统存储：

```
<dataDir>/
├── manifest                # manifest 密文（单文件）
└── blobs/
    └── <hash>              # blob 密文
```

服务端不解析文件内容，只做二进制存储。

## 实现要点

| 特性 | 实现 |
|------|------|
| 认证 | Bearer Token，constant-time compare |
| ETag | SHA-256(密文)，强 ETag，带引号 |
| 乐观锁 | If-Match / If-None-Match，串行化校验+写入 |
| 原子写入 | tmp + rename |
| 路径穿越防护 | 校验 hash 不含 `/`、`\`、`..`，验证绝对路径前缀 |
| 并发安全 | manifest 写入全局锁；blob 写入通过原子 rename 自然解决 |

## 自行实现新 server

参照 [server-api-spec.md](../docs/server-api-spec.md) §12.3 的指引：

1. 提供可执行命令（建议支持 `--port` / `--data` / `--token` 参数）
2. 实现 `/api/v2/health` 端点
3. 在 [../test/sync/safe_server_integration_test.dart](../test/sync/safe_server_integration_test.dart) 的 `startServer()` 函数中添加启动逻辑
4. 跑通全部集成测试即可视为协议兼容

服务端实现语言不限，推荐 Python/Go/Rust/Node.js 等带成熟 HTTP 库的语言。
