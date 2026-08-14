// HTTP 中间件
//
// 中间件链顺序（外到内）：RequestID → Logging → Recover → handler
//   - RequestID 最外层：为每个请求生成唯一 ID，放入 context 和响应头
//   - Logging 次外层：记录请求日志（方法、路径、状态码、耗时、请求ID、客户端IP）
//   - Recover 最内层：捕获 handler panic，防止进程崩溃；Logging 仍能记录到 500
//
// 注意：Recover 必须在 Logging 内层，这样 panic 被 Recover 捕获后，
// Logging 仍能正常记录日志（否则 panic 会跳过日志记录代码）。
package server

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"log/slog"
	"net/http"
	"runtime/debug"
	"time"

	"wsns/internal/auth"
)

// contextKey 是 context.Value 的键类型，避免与其他包冲突
type contextKey string

const requestIDKey contextKey = "request_id"

// Middleware 是 HTTP 中间件类型
type Middleware func(http.Handler) http.Handler

// Chain 把多个中间件串成链
//
// Chain(h, A, B, C) => A(B(C(h)))，即第一个参数最外层、最先执行。
func Chain(h http.Handler, mws ...Middleware) http.Handler {
	for i := len(mws) - 1; i >= 0; i-- {
		h = mws[i](h)
	}
	return h
}

// RequestID 为每个请求生成唯一 ID
//
// 优先使用客户端传入的 X-Request-ID 头，否则生成随机 ID。
// 响应头回传 X-Request-ID，便于客户端关联日志。
func RequestID(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := r.Header.Get("X-Request-ID")
		if id == "" {
			id = generateID()
		}
		w.Header().Set("X-Request-ID", id)
		ctx := context.WithValue(r.Context(), requestIDKey, id)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// Logging 记录每个请求的访问日志
//
// info 级别：method、path、status、duration_ms、request_id、remote_addr
// debug 级别：额外记录请求头、body 大小、响应字节数、If-Match/If-None-Match 等关键头
func (s *Server) Logging(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		ww := &statusWriter{ResponseWriter: w}
		next.ServeHTTP(ww, r)

		rid, _ := r.Context().Value(requestIDKey).(string)
		duration := time.Since(start).Milliseconds()

		// debug 级别：记录详细的请求/响应信息
		if s.logger.Enabled(r.Context(), slog.LevelDebug) {
			// 收集关键请求头用于调试
			keyHeaders := map[string]string{
				"authorization":   maskAuth(r.Header.Get("Authorization")),
				"if-match":        r.Header.Get("If-Match"),
				"if-none-match":   r.Header.Get("If-None-Match"),
				"content-type":    r.Header.Get("Content-Type"),
				"content-length":  r.Header.Get("Content-Length"),
				"x-forwarded-for": r.Header.Get("X-Forwarded-For"),
			}
			s.logger.Debug("request detailed",
				"method", r.Method,
				"path", r.URL.Path,
				"query", r.URL.RawQuery,
				"status", ww.status,
				"duration_ms", duration,
				"request_id", rid,
				"remote_addr", auth.ExtractIP(r, s.cfg.BehindProxy),
				"req_headers", keyHeaders,
				"resp_bytes", ww.bytesWritten,
				"host", r.Host,
			)
		} else {
			// info 级别：精简日志
			s.logger.Info("request",
				"method", r.Method,
				"path", r.URL.Path,
				"status", ww.status,
				"duration_ms", duration,
				"request_id", rid,
				"remote_addr", auth.ExtractIP(r, s.cfg.BehindProxy),
			)
		}
	})
}

// maskAuth 脱敏 Authorization 头（修复 L-2）
//
// 不再保留 token 明文前缀，只输出其 SHA-256 的前 8 位十六进制，
// 既可用于关联同一 token 的请求，又不泄露任何 token 明文字节。
func maskAuth(authHeader string) string {
	if authHeader == "" {
		return ""
	}
	sum := sha256.Sum256([]byte(authHeader))
	return "sha256:" + hex.EncodeToString(sum[:])[:8] + "(masked)"
}

// Recover 捕获 handler 中的 panic，防止进程崩溃
//
// panic 发生时记录堆栈和错误信息，返回 500。
// 因为 Recover 在 Logging 内层，Logging 仍能记录到 500 状态码。
func (s *Server) Recover(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if err := recover(); err != nil {
				rid, _ := r.Context().Value(requestIDKey).(string)
				s.logger.Error("panic recovered",
					"error", err,
					"request_id", rid,
					"method", r.Method,
					"path", r.URL.Path,
					"stack", string(debug.Stack()),
				)
				ww := w.(*statusWriter)
				if !ww.wroteHead {
					http.Error(w, "Internal Server Error", http.StatusInternalServerError)
				}
			}
		}()
		next.ServeHTTP(w, r)
	})
}

// generateID 生成 16 字符的随机十六进制 ID
func generateID() string {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}
