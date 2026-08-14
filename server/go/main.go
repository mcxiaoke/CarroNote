// SafeServer 同步服务端参考实现（Go）
//
// 实现 docs/server-api-spec.md v2.1 协议：
//   - 单用户 + 固定 Bearer Token 认证
//   - 7 个 HTTP 端点（manifest/blob 的 CRUD + health + blobs 列表）
//   - ETag 乐观锁（If-Match / If-None-Match）
//   - 认证失败速率限制（防 Token 暴力枚举，含 OOM 防护）
//   - 原子写入（tmp + fsync + rename）
//   - 中间件链（RequestID → Logging → Recover）
//   - graceful shutdown
//   - 存储层抽象（支持切换后端，预留多 vault 扩展）
//
// 代码分层结构：
//
//	main.go                          # 入口（极简）
//	internal/config/config.go        # 配置（命令行参数）
//	internal/auth/auth.go            # 认证 + 速率限制（含 LRU 防护）
//	internal/storage/
//	  storage.go                      # Vault + Storage 接口（预留多 vault）
//	  fs.go                           # 文件系统实现（含 fsync）
//	internal/server/
//	  server.go                       # Server + 路由 + graceful shutdown
//	  handlers.go                     # HTTP handlers
//	  middleware.go                   # 中间件链
//	  logging.go                      # 结构化日志（slog）
//
// 用法：
//
//	go run ./server/go [-addr :8080] [-data ./data] [-token my-secret-token]
//	                    [-rate-limit 10] [-max-body 67108864]
//	                    [-read-timeout 60s] [-write-timeout 60s] [-idle-timeout 120s]
package main

import (
	"log"

	"wsns/internal/config"
	"wsns/internal/server"
)

func main() {
	cfg := config.ParseFlags()
	srv, err := server.New(cfg)
	if err != nil {
		log.Fatalf("create server failed: %v", err)
	}
	if err := srv.Run(); err != nil {
		log.Fatalf("server failed: %v", err)
	}
}
