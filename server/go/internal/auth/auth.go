/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

// Package auth 处理认证和速率限制
//
// 提供：
//   - Bearer Token 校验（constant-time compare，防时序攻击）
//   - 认证失败速率限制（IP + 滑动窗口，防 Token 暴力枚举）
//   - 内置 OOM 防护（跟踪的 IP 数超过上限时 LRU 淘汰）
package auth

import (
	"crypto/subtle"
	"net"
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
	cutoff := now.Add(-t.window)
	// 清理该 IP 的过期记录
	failures := t.failures[ip]
	valid := failures[:0]
	for _, ts := range failures {
		if ts.After(cutoff) {
			valid = append(valid, ts)
		}
	}
	if len(valid) == 0 {
		// 无有效失败时不驻留空条目，避免海量探测 IP 膨胀 map 并频繁触发 evict 全表扫描
		delete(t.failures, ip)
		delete(t.lastAccess, ip)
		return false
	}
	t.failures[ip] = valid
	t.lastAccess[ip] = now
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
// trustProxy=false（默认，直连公网）：完全忽略 X-Forwarded-For，直接使用 RemoteAddr。
// 这是安全默认值——攻击者在公网可直接伪造 XFF，若信任它即可无限尝试 token 或把限速
// 转移到受害者 IP（DoS 放大）。
//
// trustProxy=true（位于可信反向代理之后）：才信任 X-Forwarded-For，
// 且只取最右一跳（由可信代理追加的那一段），忽略客户端可自行注入的前置条目。
//
// 无论哪种模式都会正确处理 RemoteAddr 的 IPv6（[::1]:port）与 IPv4-mapped IPv6 格式。
func ExtractIP(r *http.Request, trustProxy bool) string {
	if trustProxy {
		if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
			// 取最右一跳：XFF 格式为 "client, proxy1, proxy2"，最右一段由可信代理追加，最可靠。
			parts := strings.Split(xff, ",")
			return strings.TrimSpace(parts[len(parts)-1])
		}
	}
	host := r.RemoteAddr
	// 优先使用标准库解析，健壮处理 IPv6、IPv4-mapped 及无端口/畸形地址
	if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	} else {
		// 无端口或畸形时回退到手写逻辑（兼容测试中的简写地址）
		if strings.HasPrefix(host, "[") {
			if idx := strings.LastIndex(host, "]"); idx > 0 {
				return host[1:idx]
			}
		}
		if idx := strings.LastIndex(host, ":"); idx > 0 {
			// 区分 IPv4-mapped 前缀
			if strings.HasPrefix(host, "::ffff:") {
				rest := host[len("::ffff:"):]
				if cidx := strings.LastIndex(rest, ":"); cidx > 0 {
					return rest[:cidx]
				}
				return rest
			}
			return host[:idx]
		}
		return host
	}
	// net.SplitHostPort 已去除括号，仍需处理 ::ffff: 前缀的 IPv4 映射
	if strings.HasPrefix(host, "::ffff:") {
		return strings.TrimPrefix(host, "::ffff:")
	}
	return host
}
