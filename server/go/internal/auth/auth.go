// Package auth 处理认证和速率限制
//
// 提供：
//   - Bearer Token 校验（constant-time compare，防时序攻击）
//   - 认证失败速率限制（IP + 滑动窗口，防 Token 暴力枚举）
//   - 内置 OOM 防护（跟踪的 IP 数超过上限时 LRU 淘汰）
package auth

import (
	"crypto/subtle"
	"net/http"
	"strings"
	"sync"
	"time"
)

// FailTracker 跟踪按客户端 IP 分组的认证失败次数
//
// 策略：滑动窗口（默认 1 分钟），超过 limit 次后拒绝该 IP 的所有请求（返回 429）。
// 仅对 401 认证失败计数，成功认证后清除该 IP 的失败记录。
//
// OOM 防护：跟踪的 IP 数超过 maxIPs 时，先清理过期记录，仍超上限则按 LRU 淘汰最久未访问的 IP。
// 这防止攻击者用大量伪造 IP（如 X-Forwarded-For 篡改）撑爆内存。
type FailTracker struct {
	mu         sync.Mutex
	failures   map[string][]time.Time // IP -> 失败时间戳列表
	lastAccess map[string]time.Time   // IP -> 最后访问时间（用于 LRU 淘汰）
	window     time.Duration          // 滑动窗口大小
	maxIPs     int                    // 最多跟踪多少个 IP
}

// NewFailTracker 创建认证失败跟踪器
//
//   - window: 滑动窗口大小（如 1 分钟）
//   - maxIPs: 最多跟踪多少个 IP（超过时 LRU 淘汰，防 OOM）
func NewFailTracker(window time.Duration, maxIPs int) *FailTracker {
	if maxIPs <= 0 {
		maxIPs = 10000
	}
	return &FailTracker{
		failures:   make(map[string][]time.Time),
		lastAccess: make(map[string]time.Time),
		window:     window,
		maxIPs:     maxIPs,
	}
}

// IsRateLimited 检查指定 IP 是否被限速
//
// 同时清理该 IP 的过期失败记录，并更新最后访问时间。
func (t *FailTracker) IsRateLimited(ip string, limit int) bool {
	if limit <= 0 {
		return false
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	now := time.Now()
	t.lastAccess[ip] = now
	cutoff := now.Add(-t.window)
	// 清理该 IP 的过期记录
	failures := t.failures[ip]
	valid := failures[:0]
	for _, ts := range failures {
		if ts.After(cutoff) {
			valid = append(valid, ts)
		}
	}
	t.failures[ip] = valid
	// 超上限时淘汰
	if len(t.failures) > t.maxIPs {
		t.evict()
	}
	return len(valid) >= limit
}

// RecordFailure 记录一次认证失败
func (t *FailTracker) RecordFailure(ip string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	now := time.Now()
	t.lastAccess[ip] = now
	t.failures[ip] = append(t.failures[ip], now)
	// 超上限时淘汰
	if len(t.failures) > t.maxIPs {
		t.evict()
	}
}

// ResetFailures 认证成功后清除该 IP 的失败记录
func (t *FailTracker) ResetFailures(ip string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	delete(t.failures, ip)
	delete(t.lastAccess, ip)
}

// evict 淘汰策略：先清过期，仍超上限则按 LRU 淘汰最久未访问的 IP
func (t *FailTracker) evict() {
	now := time.Now()
	cutoff := now.Add(-t.window)
	// 1. 清理所有过期记录
	for ip, times := range t.failures {
		valid := times[:0]
		for _, ts := range times {
			if ts.After(cutoff) {
				valid = append(valid, ts)
			}
		}
		if len(valid) == 0 {
			delete(t.failures, ip)
			delete(t.lastAccess, ip)
		} else {
			t.failures[ip] = valid
		}
	}
	// 2. 如果 IP 数仍超上限，按 lastAccess 淘汰最旧的
	for len(t.failures) > t.maxIPs {
		var oldestIP string
		var oldestTime time.Time
		first := true
		for ip, ts := range t.lastAccess {
			if first || ts.Before(oldestTime) {
				oldestIP = ip
				oldestTime = ts
				first = false
			}
		}
		delete(t.failures, oldestIP)
		delete(t.lastAccess, oldestIP)
	}
}

// CheckToken 校验 Bearer Token（constant-time compare，防时序攻击）
//
// expected 是配置的正确 Token，从请求的 Authorization 头提取并比较。
func CheckToken(r *http.Request, expected string) bool {
	authHeader := r.Header.Get("Authorization")
	const prefix = "Bearer "
	if len(authHeader) <= len(prefix) || !strings.EqualFold(authHeader[:len(prefix)], prefix) {
		return false
	}
	token := authHeader[len(prefix):]
	return subtle.ConstantTimeCompare([]byte(token), []byte(expected)) == 1
}

// ExtractIP 从请求中提取客户端 IP
//
// 优先从 X-Forwarded-For 取（反向代理场景），取第一个 IP；
// 否则用 RemoteAddr，处理 IPv6 格式（如 [::1]:port 或 ::1）。
func ExtractIP(r *http.Request) string {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		if idx := strings.Index(xff, ","); idx > 0 {
			return strings.TrimSpace(xff[:idx])
		}
		return strings.TrimSpace(xff)
	}
	host := r.RemoteAddr
	// 处理 IPv6 格式：[::1]:port
	if strings.HasPrefix(host, "[") {
		if idx := strings.LastIndex(host, "]"); idx > 0 {
			return host[1:idx]
		}
	}
	// 处理 IPv4-mapped IPv6：::ffff:127.0.0.1:port
	if strings.HasPrefix(host, "::ffff:") {
		rest := host[len("::ffff:"):]
		if idx := strings.LastIndex(rest, ":"); idx > 0 {
			return rest[:idx]
		}
		return rest
	}
	// 普通 IPv4：127.0.0.1:port
	if idx := strings.LastIndex(host, ":"); idx > 0 {
		return host[:idx]
	}
	return host
}
