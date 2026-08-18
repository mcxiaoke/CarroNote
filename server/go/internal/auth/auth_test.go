/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

package auth

import (
	"net/http/httptest"
	"testing"
	"time"
)

// TestCheckToken 覆盖常数时间比较的各类边界。
func TestCheckToken(t *testing.T) {
	cases := []struct {
		name     string
		header   string
		expected string
		want     bool
	}{
		{"正确 token", "Bearer secret", "secret", true},
		{"错误 token", "Bearer wrong", "secret", false},
		{"空前缀", "secret", "secret", false},
		{"空 header", "", "secret", false},
		{"Bearer 前缀大小写容忍", "bearer secret", "secret", true}, // 前缀比较用 EqualFold，容忍大小写
		{"前缀大小写容忍", "Bearer secret", "secret", true},
		{"token 带多余空格", "Bearer  secret", "secret", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r := httptest.NewRequest("GET", "/", nil)
			if c.header != "" {
				r.Header.Set("Authorization", c.header)
			}
			if got := CheckToken(r, c.expected); got != c.want {
				t.Fatalf("CheckToken = %v, want %v", got, c.want)
			}
		})
	}
}

// TestExtractIP 覆盖直连（忽略 XFF）与可信代理（取最右一跳）两种模式。
func TestExtractIP(t *testing.T) {
	cases := []struct {
		name       string
		remoteAddr string
		xff        string
		trustProxy bool
		want       string
	}{
		{"直连 IPv4", "127.0.0.1:1234", "", false, "127.0.0.1"},
		{"直连 IPv4 带 XFF 仍忽略", "127.0.0.1:1234", "1.2.3.4", false, "127.0.0.1"}, // 修复 C-1：直连不信任 XFF
		{"直连 IPv6", "[::1]:4321", "", false, "::1"},
		{"直连 IPv4-mapped", "::ffff:10.0.0.1:4321", "", false, "10.0.0.1"},
		{"代理模式取最右一跳", "127.0.0.1:8080", "203.0.113.7, 10.0.0.1", true, "10.0.0.1"},
		{"代理模式单跳", "127.0.0.1:8080", "203.0.113.7", true, "203.0.113.7"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r := httptest.NewRequest("GET", "/", nil)
			r.RemoteAddr = c.remoteAddr
			if c.xff != "" {
				r.Header.Set("X-Forwarded-For", c.xff)
			}
			if got := ExtractIP(r, c.trustProxy); got != c.want {
				t.Fatalf("ExtractIP = %q, want %q", got, c.want)
			}
		})
	}
}

// TestFailTracker 覆盖记录、触发、清除与窗口过期。
func TestFailTracker(t *testing.T) {
	tr := NewFailTracker(time.Minute, 100)
	ip := "127.0.0.1"

	// 未达上限不触发
	for i := 0; i < 4; i++ {
		tr.RecordFailure(ip)
		if tr.IsRateLimited(ip, 5) {
			t.Fatalf("should not be limited after %d failures", i+1)
		}
	}
	// 第 5 次后触发
	tr.RecordFailure(ip)
	if !tr.IsRateLimited(ip, 5) {
		t.Fatal("should be limited after 5 failures")
	}
	// 成功认证清除失败计数（修复 C-2 自愈）
	tr.ResetFailures(ip)
	if tr.IsRateLimited(ip, 5) {
		t.Fatal("should be cleared after ResetFailures")
	}
}

// TestFailTrackerWindowExpiry 验证滑动窗口会清理过期记录。
func TestFailTrackerWindowExpiry(t *testing.T) {
	tr := NewFailTracker(10*time.Millisecond, 100)
	ip := "127.0.0.1"
	tr.RecordFailure(ip)
	tr.RecordFailure(ip)
	tr.RecordFailure(ip)
	if !tr.IsRateLimited(ip, 3) {
		t.Fatal("should be limited immediately")
	}
	time.Sleep(20 * time.Millisecond)
	if tr.IsRateLimited(ip, 3) {
		t.Fatal("expired failures should no longer limit")
	}
}

// TestFailTrackerDisabled 验证 limit<=0 时完全不限制。
func TestFailTrackerDisabled(t *testing.T) {
	tr := NewFailTracker(time.Minute, 100)
	ip := "127.0.0.1"
	for i := 0; i < 100; i++ {
		tr.RecordFailure(ip)
	}
	if tr.IsRateLimited(ip, 0) {
		t.Fatal("limit<=0 must never limit")
	}
}
