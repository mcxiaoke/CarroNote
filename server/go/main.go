// SafeServer 同步服务端参考实现（Go）
//
// 实现 docs/server-api-spec.md v2.1 协议：
//   - 单用户 + 固定 Bearer Token 认证
//   - 7 个 HTTP 端点：
//       GET/PUT/DELETE /api/v2/manifest     (manifest 资源，DELETE 用于清理损坏文件)
//       GET/PUT/DELETE /api/v2/blob/<hash>  (blob 资源，DELETE 用于 GC)
//       GET              /api/v2/blobs      (列出所有 blob hash，GC 用，需认证)
//       GET              /api/v2/health     (健康检查，无需认证)
//   - ETag 乐观锁（If-Match / If-None-Match）
//   - 认证失败速率限制（防 Token 暴力枚举）
//   - 无 MKCOL、无目录概念、无 WebDAV 包袱
//
// 用法：
//   go run ./server/go [-addr :8080] [-data ./data] [-token my-secret-token] [-rate-limit 10]
package main

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// ──────────────────────────────────────────────
// 配置
// ──────────────────────────────────────────────

type config struct {
	addr      string
	dataDir   string
	token     string
	rateLimit int // 每分钟允许的认证失败次数（0=禁用限速）
}

var cfg = config{
	addr:      ":8080",
	dataDir:   "./data",
	token:     "my-secret-token",
	rateLimit: 10, // 默认每分钟 10 次认证失败后限速
}

// ──────────────────────────────────────────────
// Server
// ──────────────────────────────────────────────

// Server 实现 SafeServer v2.1 协议
//
// 存储布局（cfg.dataDir 下）：
//   <dataDir>/manifest          # manifest 密文（单文件）
//   <dataDir>/blobs/<hash>      # blob 密文
type Server struct {
	dataDir   string
	token     string
	mu        sync.Mutex // manifest 写操作互斥
	rateLimit int        // 每分钟允许的认证失败次数（0=禁用）
	authFail  *AuthFailTracker
}

func newServer() *Server {
	return &Server{
		dataDir:   cfg.dataDir,
		token:     cfg.token,
		rateLimit: cfg.rateLimit,
		authFail:  NewAuthFailTracker(),
	}
}

// ──────────────────────────────────────────────
// 认证失败速率限制（E3：防 Token 暴力枚举）
// ──────────────────────────────────────────────

// AuthFailTracker 跟踪按客户端 IP 分组的认证失败次数
//
// 策略：滑动窗口（1 分钟），超过 rateLimit 次后拒绝该 IP 的所有请求（返回 429）。
// 窗口过期后自动恢复。仅对 401 认证失败计数，成功认证不计数。
type AuthFailTracker struct {
	mu      sync.Mutex
	failures map[string][]time.Time // IP -> 失败时间戳列表
	window  time.Duration
}

func NewAuthFailTracker() *AuthFailTracker {
	return &AuthFailTracker{
		failures: make(map[string][]time.Time),
		window:   time.Minute,
	}
}

// IsRateLimited 检查指定 IP 是否被限速
func (t *AuthFailTracker) IsRateLimited(ip string, limit int) bool {
	if limit <= 0 {
		return false
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	now := time.Now()
	cutoff := now.Add(-t.window)
	// 清理过期记录，统计窗口内失败次数
	failures := t.failures[ip]
	valid := failures[:0]
	for _, ts := range failures {
		if ts.After(cutoff) {
			valid = append(valid, ts)
		}
	}
	t.failures[ip] = valid
	return len(valid) >= limit
}

// RecordFailure 记录一次认证失败
func (t *AuthFailTracker) RecordFailure(ip string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.failures[ip] = append(t.failures[ip], time.Now())
}

// ResetFailures 认证成功后清除该 IP 的失败记录
func (t *AuthFailTracker) ResetFailures(ip string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	delete(t.failures, ip)
}

// extractIP 从请求中提取客户端 IP（仅取 host:port 的 host 部分）
func extractIP(r *http.Request) string {
	// 优先从 X-Forwarded-For 取（反向代理场景）
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		if idx := strings.Index(xff, ","); idx > 0 {
			return strings.TrimSpace(xff[:idx])
		}
		return strings.TrimSpace(xff)
	}
	host := r.RemoteAddr
	if idx := strings.LastIndex(host, ":"); idx > 0 {
		return host[:idx]
	}
	return host
}

// 路径安全检查：校验 hash 不包含路径分隔符或 ..
func (s *Server) resolveBlobPath(hash string) (string, error) {
	if hash == "" || strings.ContainsAny(hash, "/\\") || strings.Contains(hash, "..") {
		return "", fmt.Errorf("invalid hash")
	}
	blobsDir := filepath.Join(s.dataDir, "blobs")
	full := filepath.Join(blobsDir, filepath.Clean("/"+hash))
	absBlobs, _ := filepath.Abs(blobsDir)
	absFull, _ := filepath.Abs(full)
	if !strings.HasPrefix(absFull, absBlobs) {
		return "", fmt.Errorf("path escapes blobs dir")
	}
	return absFull, nil
}

// manifest 文件路径
func (s *Server) manifestPath() string {
	return filepath.Join(s.dataDir, "manifest")
}

// 计算内容的 SHA-256 作为强 ETag（带引号）
func computeEtag(data []byte) string {
	h := sha256.Sum256(data)
	return `"` + hex.EncodeToString(h[:]) + `"`
}

// Bearer Token 校验（constant-time compare）
func (s *Server) checkAuth(r *http.Request) bool {
	auth := r.Header.Get("Authorization")
	const prefix = "Bearer "
	if len(auth) <= len(prefix) || !strings.EqualFold(auth[:len(prefix)], prefix) {
		return false
	}
	token := auth[len(prefix):]
	return subtle.ConstantTimeCompare([]byte(token), []byte(s.token)) == 1
}

// ──────────────────────────────────────────────
// HTTP Handlers
// ──────────────────────────────────────────────

func (s *Server) handler(w http.ResponseWriter, r *http.Request) {
	// 健康检查（不需要认证、不受速率限制）
	if r.URL.Path == "/api/v2/health" && r.Method == "GET" {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok"))
		return
	}

	// 速率限制检查（认证失败超限的 IP 直接拒绝）
	clientIP := extractIP(r)
	if s.authFail.IsRateLimited(clientIP, s.rateLimit) {
		w.Header().Set("Retry-After", "60")
		http.Error(w, "Too Many Requests (auth failure rate limit)", http.StatusTooManyRequests)
		return
	}

	// 认证
	if !s.checkAuth(r) {
		s.authFail.RecordFailure(clientIP)
		w.Header().Set("WWW-Authenticate", `Bearer`)
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}
	// 认证成功：清除失败计数
	s.authFail.ResetFailures(clientIP)

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
	default:
		http.NotFound(w, r)
	}
}

// GET /api/v2/manifest
func (s *Server) handleGetManifest(w http.ResponseWriter, r *http.Request) {
	data, err := os.ReadFile(s.manifestPath())
	if err != nil {
		if os.IsNotExist(err) {
			http.Error(w, "Not Found", http.StatusNotFound)
			return
		}
		http.Error(w, "read failed: "+err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("ETag", computeEtag(data))
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Write(data)
}

// PUT /api/v2/manifest（乐观锁 + 临界区保护）
//
// 修复 C3 竞态：把 "读取当前 manifest + ETag 校验 + 写入" 整体移入 s.mu 临界区，
// 与 Node.js 参考实现（withManifestLock）对齐。
// 原实现 ETag 校验在锁外，两个并发 PUT 都会通过校验然后顺序写入，后写覆盖先写且不返回 412。
func (s *Server) handlePutManifest(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "read body failed: "+err.Error(), http.StatusBadRequest)
		return
	}
	defer r.Body.Close()

	ifMatch := r.Header.Get("If-Match")
	ifNoneMatch := r.Header.Get("If-None-Match")

	// 临界区：读 + 校验 + 写 必须在同一个锁内完成（TOCTOU 修复）
	s.mu.Lock()
	defer s.mu.Unlock()

	// 在锁内重新读取当前 manifest（避免使用锁外读到的过期数据）
	existing, err := os.ReadFile(s.manifestPath())
	exists := err == nil

	if ifNoneMatch == "*" {
		// 首次上传：远端必须不存在
		if exists {
			http.Error(w, "If-None-Match: * failed (manifest exists)", http.StatusPreconditionFailed)
			return
		}
	} else if ifMatch != "" {
		// 乐观锁：远端 ETag 必须匹配
		if !exists {
			http.Error(w, "If-Match failed (manifest not found)", http.StatusPreconditionFailed)
			return
		}
		currentEtag := computeEtag(existing)
		expected := strings.Trim(ifMatch, `"`)
		if currentEtag != `"`+expected+`"` {
			http.Error(w, "If-Match failed (etag mismatch)", http.StatusPreconditionFailed)
			return
		}
	}

	// 确保父目录存在
	if err := os.MkdirAll(s.dataDir, 0o755); err != nil {
		http.Error(w, "mkdir failed: "+err.Error(), http.StatusInternalServerError)
		return
	}
	// 原子写入：tmp + rename
	tmpPath := s.manifestPath() + ".tmp"
	if err := os.WriteFile(tmpPath, body, 0o644); err != nil {
		http.Error(w, "write failed: "+err.Error(), http.StatusInternalServerError)
		return
	}
	if err := os.Rename(tmpPath, s.manifestPath()); err != nil {
		http.Error(w, "rename failed: "+err.Error(), http.StatusInternalServerError)
		return
	}

	w.Header().Set("ETag", computeEtag(body))
	w.WriteHeader(http.StatusOK)
}

// GET /api/v2/blob/<hash>
func (s *Server) handleGetBlob(w http.ResponseWriter, r *http.Request, hash string) {
	path, err := s.resolveBlobPath(hash)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			http.Error(w, "Not Found", http.StatusNotFound)
			return
		}
		http.Error(w, "read failed: "+err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Write(data)
}

// PUT /api/v2/blob/<hash>（幂等）
func (s *Server) handlePutBlob(w http.ResponseWriter, r *http.Request, hash string) {
	path, err := s.resolveBlobPath(hash)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "read body failed: "+err.Error(), http.StatusBadRequest)
		return
	}
	defer r.Body.Close()

	// 确保父目录存在
	parent := filepath.Dir(path)
	if err := os.MkdirAll(parent, 0o755); err != nil {
		http.Error(w, "mkdir failed: "+err.Error(), http.StatusInternalServerError)
		return
	}
	// 原子写入
	tmpPath := path + ".tmp"
	if err := os.WriteFile(tmpPath, body, 0o644); err != nil {
		http.Error(w, "write failed: "+err.Error(), http.StatusInternalServerError)
		return
	}
	if err := os.Rename(tmpPath, path); err != nil {
		http.Error(w, "rename failed: "+err.Error(), http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusOK)
}

// DELETE /api/v2/blob/<hash>（GC 用，幂等）
//
// 删除指定 hash 的 blob。404 视为成功（幂等删除）。
// 客户端在 GC 流程中调用此端点清理孤儿 blob。
func (s *Server) handleDeleteBlob(w http.ResponseWriter, r *http.Request, hash string) {
	path, err := s.resolveBlobPath(hash)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if err := os.Remove(path); err != nil {
		if os.IsNotExist(err) {
			// 幂等：删除不存在的 blob 视为成功
			w.WriteHeader(http.StatusNoContent)
			return
		}
		http.Error(w, "delete failed: "+err.Error(), http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// GET /api/v2/blobs（列出所有 blob hash，GC 用）
//
// 返回 JSON 数组，包含 blobs/ 目录下所有 blob 的 hash。
// 服务端不解析内容，仅列文件名。需认证（不破坏防枚举原则——
// 攻击者无 Token 无法访问）。
func (s *Server) handleListBlobs(w http.ResponseWriter, r *http.Request) {
	blobsDir := filepath.Join(s.dataDir, "blobs")
	entries, err := os.ReadDir(blobsDir)
	if err != nil {
		if os.IsNotExist(err) {
			// blobs 目录不存在：返回空数组
			w.Header().Set("Content-Type", "application/json")
			w.Write([]byte("[]"))
			return
		}
		http.Error(w, "list blobs failed: "+err.Error(), http.StatusInternalServerError)
		return
	}
	hashes := []string{}
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		name := entry.Name()
		// 跳过 .tmp 临时文件
		if strings.HasSuffix(name, ".tmp") {
			continue
		}
		hashes = append(hashes, name)
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(hashes)
}

// DELETE /api/v2/manifest（清理损坏文件，backupCorruptManifest 用）
//
// 删除 manifest 文件。客户端在 manifest 解析失败时调用此端点
// 清理损坏文件，然后用本地数据重建 manifest 上传。
// 404 视为成功（幂等删除）。
func (s *Server) handleDeleteManifest(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := os.Remove(s.manifestPath()); err != nil {
		if os.IsNotExist(err) {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		http.Error(w, "delete manifest failed: "+err.Error(), http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ──────────────────────────────────────────────
// main
// ──────────────────────────────────────────────

func main() {
	flag.StringVar(&cfg.addr, "addr", cfg.addr, "监听地址")
	flag.StringVar(&cfg.dataDir, "data", cfg.dataDir, "数据存储目录")
	flag.StringVar(&cfg.token, "token", cfg.token, "Bearer Token（认证用）")
	flag.IntVar(&cfg.rateLimit, "rate-limit", cfg.rateLimit, "每分钟允许的认证失败次数（0=禁用限速）")
	flag.Parse()

	// 确保数据目录存在
	if err := os.MkdirAll(cfg.dataDir, 0o755); err != nil {
		log.Fatalf("create data dir failed: %v", err)
	}

	srv := newServer()
	http.HandleFunc("/", srv.handler)

	log.Printf("SafeServer v2.1 (Go) listening on %s", cfg.addr)
	log.Printf("  data dir:   %s", cfg.dataDir)
	log.Printf("  token:      %s", strings.Repeat("*", len(cfg.token)))
	log.Printf("  rate limit: %d/min (0=disabled)", cfg.rateLimit)
	if err := http.ListenAndServe(cfg.addr, nil); err != nil {
		log.Fatalf("server failed: %v", err)
	}
}
