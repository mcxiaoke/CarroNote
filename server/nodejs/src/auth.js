// 认证与速率限制模块
//
// 提供：
//   - Bearer Token 校验（constant-time compare，防时序攻击）
//   - 认证失败速率限制（IP + 滑动窗口，防 Token 暴力枚举）
//   - 内置 OOM 防护（跟踪的 IP 数超过上限时 LRU 淘汰）

'use strict';

import crypto from 'crypto';

// FailTracker：按 IP 分组跟踪认证失败次数
//
// 策略：滑动窗口（默认 1 分钟），超过 limit 次后拒绝该 IP 的所有请求（返回 429）。
// 仅对 401 认证失败计数，成功认证后清除该 IP 的失败记录。
//
// OOM 防护：跟踪的 IP 数超过 maxIPs 时，先清理过期记录，仍超上限则按 LRU 淘汰最久未访问的 IP。
// 这防止攻击者用大量伪造 IP（如 X-Forwarded-For 篡改）撑爆内存。
export class FailTracker {
  constructor(windowMs = 60000, maxIPs = 10000) {
    this.failures = new Map();       // IP -> 失败时间戳数组
    this.lastAccess = new Map();     // IP -> 最后访问时间（用于 LRU 淘汰）
    this.windowMs = windowMs;
    this.maxIPs = maxIPs;
  }

  // 检查指定 IP 是否被限速
  isRateLimited(ip, limit) {
    if (limit <= 0) return false;
    const now = Date.now();
    this.lastAccess.set(ip, now);
    const cutoff = now - this.windowMs;
    const list = (this.failures.get(ip) || []).filter(ts => ts > cutoff);
    if (list.length === 0) {
      this.failures.delete(ip);
    } else {
      this.failures.set(ip, list);
    }
    if (this.failures.size > this.maxIPs) this.evict();
    return list.length >= limit;
  }

  // 记录一次认证失败
  recordFailure(ip) {
    const now = Date.now();
    this.lastAccess.set(ip, now);
    const list = this.failures.get(ip) || [];
    list.push(now);
    this.failures.set(ip, list);
    if (this.failures.size > this.maxIPs) this.evict();
  }

  // 认证成功后清除该 IP 的失败记录
  resetFailures(ip) {
    this.failures.delete(ip);
    this.lastAccess.delete(ip);
  }

  // 淘汰策略：先清过期，仍超上限则按 LRU 淘汰最久未访问的 IP
  evict() {
    const now = Date.now();
    const cutoff = now - this.windowMs;
    // 1. 清理所有过期记录
    for (const [ip, times] of this.failures) {
      const valid = times.filter(ts => ts > cutoff);
      if (valid.length === 0) {
        this.failures.delete(ip);
        this.lastAccess.delete(ip);
      } else {
        this.failures.set(ip, valid);
      }
    }
    // 2. 如果 IP 数仍超上限，按 lastAccess 淘汰最旧的
    while (this.failures.size > this.maxIPs) {
      let oldestIP = null;
      let oldestTime = Infinity;
      for (const [ip, ts] of this.lastAccess) {
        if (ts < oldestTime) {
          oldestTime = ts;
          oldestIP = ip;
        }
      }
      if (oldestIP === null) break;
      this.failures.delete(oldestIP);
      this.lastAccess.delete(oldestIP);
    }
  }
}

// 校验 Bearer Token（constant-time compare，防时序攻击）
//
// expected 是配置的正确 Token，从请求的 Authorization 头提取并比较。
export function checkToken(req, expected) {
  const auth = req.headers['authorization'] || '';
  const prefix = 'Bearer ';
  if (auth.length <= prefix.length ||
      auth.slice(0, prefix.length).toLowerCase() !== prefix.toLowerCase()) {
    return false;
  }
  const token = auth.slice(prefix.length);
  try {
    // 长度不同时直接返回 false（timingSafeEqual 要求长度相同）
    const a = Buffer.from(token);
    const b = Buffer.from(expected);
    if (a.length !== b.length) return false;
    return crypto.timingSafeEqual(a, b);
  } catch {
    return false;
  }
}

// 从请求中提取客户端 IP
//
// 优先从 X-Forwarded-For 取（反向代理场景），取第一个 IP；
// 否则用 socket.remoteAddress，处理 IPv6 格式（如 ::1）。
export function extractIP(req) {
  const xff = req.headers['x-forwarded-for'];
  if (xff) {
    const first = xff.split(',')[0].trim();
    if (first) return first;
  }
  const addr = req.socket.remoteAddress || '';
  // 处理 IPv6 格式：::1 或 [::1]:port
  if (addr.startsWith('::ffff:')) {
    // IPv4-mapped IPv6：::ffff:127.0.0.1
    return addr.slice(7);
  }
  return addr;
}
