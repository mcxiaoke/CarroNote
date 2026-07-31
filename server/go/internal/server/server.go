// Package server 实现 SafeServer v2.1 HTTP 服务
//
// 职责：
//   - HTTP 路由分发
//   - 中间件链（RequestID → Logging → Recover）
//   - 认证 + 速率限制
//   - 请求体大小限制
//   - graceful shutdown
//
// 存储层通过 storage.Storage 接口注入，支持切换后端。
// 当前为单 vault 模式，接口已预留多 vault 扩展（storage.NewVault(vaultID)）。
package server

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"safenotes-server/internal/auth"
	"safenotes-server/internal/config"
	"safenotes-server/internal/storage"
)

// Server 是 SafeServer HTTP 服务
type Server struct {
	cfg       *config.Config
	storage   storage.Storage // 存储后端（多 vault 扩展用）
	vault     storage.Vault   // 默认 vault（单用户场景）
	authFail  *auth.FailTracker
	logger    *slog.Logger
	logCloser io.Closer // 日志文件句柄（graceful shutdown 时关闭，修复 L-6）
}

// New 创建 Server 实例
//
// 初始化存储后端（默认文件系统）和默认 vault。
// 未来多 vault 场景：从请求中提取 vaultID，调用 s.storage.NewVault(vaultID) 获取对应 Vault。
func New(cfg *config.Config) (*Server, error) {
	store, err := storage.NewFileSystem(cfg.DataDir)
	if err != nil {
		return nil, fmt.Errorf("create storage failed: %w", err)
	}
	// 单 vault 模式：使用默认 vault（vaultID=DefaultVaultID）
	vault, err := store.NewVault(storage.DefaultVaultID)
	if err != nil {
		return nil, fmt.Errorf("create default vault failed: %w", err)
	}
	logger, closer := NewLogger(cfg.LogLevel, cfg.LogFile, cfg.LogJSON)
	return &Server{
		cfg:       cfg,
		storage:   store,
		vault:     vault,
		authFail:  auth.NewFailTracker(time.Minute, 10000),
		logger:    logger,
		logCloser: closer,
	}, nil
}

// Run 启动 HTTP 服务（含 graceful shutdown）
//
// 捕获 SIGINT/SIGTERM 信号，等待在途请求完成（最多 30 秒）后退出。
func (s *Server) Run() error {
	// 修复 L-6：graceful shutdown 时关闭日志文件句柄，避免句柄泄漏。
	defer func() {
		if s.logCloser != nil {
			_ = s.logCloser.Close()
		}
	}()

	srv := &http.Server{
		Addr:              s.cfg.Addr,
		Handler:           s.Handler(),
		ReadTimeout:       s.cfg.ReadTimeout.Std(),
		WriteTimeout:      s.cfg.WriteTimeout.Std(),
		IdleTimeout:       s.cfg.IdleTimeout.Std(),
		ReadHeaderTimeout: 10 * time.Second, // 修复 L-5：防 slowloris 慢速请求头耗尽连接
	}

	errCh := make(chan error, 1)
	go func() {
		s.logger.Info("SafeServer v2.2 (Go) starting",
			"addr", s.cfg.Addr,
			"data_dir", s.cfg.DataDir,
			"token_mask", strings.Repeat("*", len(s.cfg.Token)),
			"rate_limit", fmt.Sprintf("%d/min (0=disabled)", s.cfg.RateLimit),
			"max_body_bytes", s.cfg.MaxBodyBytes,
			"read_timeout", s.cfg.ReadTimeout.String(),
			"write_timeout", s.cfg.WriteTimeout.String(),
			"idle_timeout", s.cfg.IdleTimeout.String(),
			"log_level", s.cfg.LogLevelStr,
			"log_file", s.cfg.LogFile,
			"log_json", s.cfg.LogJSON,
		)
		if err := s.listenAndServe(srv); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
	}()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	select {
	case err := <-errCh:
		return err
		case sig := <-sigCh:
		s.logger.Info("received signal, shutting down gracefully", "signal", sig.String())
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		return srv.Shutdown(ctx)
	}
}

// listenAndServe 启动 HTTP/HTTPS 服务（修复 L-1）
//
// 同时配置了 -cert 与 -key 时启用 TLS（ListenAndServeTLS）；否则明文 HTTP，
// 并打印告警提醒「禁止公网裸跑，必须前置 TLS 反向代理」。
func (s *Server) listenAndServe(srv *http.Server) error {
	if s.cfg.CertFile != "" && s.cfg.KeyFile != "" {
		s.logger.Info("TLS enabled", "cert", s.cfg.CertFile, "key", s.cfg.KeyFile)
		return srv.ListenAndServeTLS(s.cfg.CertFile, s.cfg.KeyFile)
	}
	log.Printf("WARNING: server is running WITHOUT TLS (plain HTTP). Do not expose it to public networks without a TLS reverse proxy.")
	return srv.ListenAndServe()
}

// Handler 返回 HTTP handler（中间件链 + 路由）
//
// 中间件顺序（外到内）：RequestID → Logging → Recover → routes
func (s *Server) Handler() http.Handler {
	return Chain(
		s.routes(),
		RequestID,
		s.Logging,
		s.Recover,
	)
}

// routes 返回路由 handler
func (s *Server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/", s.handle)
	return mux
}

// handle 主路由分发
//
// 处理流程：
//  1. 请求体大小限制（防恶意大文件上传）
//  2. 健康检查（无需认证）
//  3. 速率限制检查
//  4. 认证
//  5. 路由分发到具体 handler
func (s *Server) handle(w http.ResponseWriter, r *http.Request) {
	// 限制请求体大小（防恶意大文件上传撑满磁盘）
	r.Body = http.MaxBytesReader(w, r.Body, s.cfg.MaxBodyBytes)

	// 健康检查（不需要认证、不受速率限制）
	if r.URL.Path == "/api/v2/health" && r.Method == "GET" {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok"))
		return
	}

	// 速率限制与认证：
	// 修复 C-2 ——「正确凭证即白名单」。先校验 token：
	//   - token 正确：直接放行并清除失败计数，被限速的合法用户立即可恢复（无需等窗口过期）；
	//   - token 错误：再判断是否已被限速（防暴力枚举），命中则 429，否则记录一次失败并返回 401。
	clientIP := auth.ExtractIP(r, s.cfg.BehindProxy)
	if !auth.CheckToken(r, s.cfg.Token) {
		if s.authFail.IsRateLimited(clientIP, s.cfg.RateLimit) {
			w.Header().Set("Retry-After", "60")
			http.Error(w, "Too Many Requests (auth failure rate limit)", http.StatusTooManyRequests)
			return
		}
		s.authFail.RecordFailure(clientIP)
		w.Header().Set("WWW-Authenticate", "Bearer")
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}
	// 认证成功：清除失败计数（限速自愈）
	s.authFail.ResetFailures(clientIP)

	// 路由分发
	switch {
	case r.URL.Path == "/api/v2/manifest":
		switch r.Method {
		case "GET":
			s.handleGetManifest(w, r)
		case "PUT":
			s.handlePutManifest(w, r)
		case "DELETE":
			s.handleDeleteManifest(w, r)
		default:
			w.Header().Set("Allow", "GET, PUT, DELETE")
			http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		}
	case r.URL.Path == "/api/v2/blobs" && r.Method == "GET":
		// 列出所有 blob hash（GC 用，需认证——不破坏防枚举原则）
		s.handleListBlobs(w, r)
	case strings.HasPrefix(r.URL.Path, "/api/v2/blob/"):
		hash := strings.TrimPrefix(r.URL.Path, "/api/v2/blob/")
		switch r.Method {
		case "GET":
			s.handleGetBlob(w, r, hash)
		case "PUT":
			s.handlePutBlob(w, r, hash)
		case "DELETE":
			s.handleDeleteBlob(w, r, hash)
		default:
			w.Header().Set("Allow", "GET, PUT, DELETE")
			http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		}
	case strings.HasPrefix(r.URL.Path, "/api/v2/resources/"):
		// 通用资源层（v2.2）：语义 = WebDAV 动词，纯 REST/JSON 表达
		rel := strings.TrimPrefix(r.URL.Path, "/api/v2/resources/")
		switch r.Method {
		case "GET":
			s.handleGetResource(w, r, rel)
		case "PUT":
			s.handlePutResource(w, r, rel)
		case "DELETE":
			s.handleDeleteResource(w, r, rel)
		case "POST":
			s.handleResourceOp(w, r, rel)
		default:
			w.Header().Set("Allow", "GET, PUT, DELETE, POST")
			http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		}
	default:
		http.NotFound(w, r)
	}
}
