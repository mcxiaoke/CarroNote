// SafeServer 同步服务端参考实现（Node.js）
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
//   - 结构化日志（支持配置文件调整级别/输出路径）
//
// 代码分层结构：
//
//	server.js                      # 入口（极简）
//	src/config.js                  # 配置（命令行参数 + 配置文件）
//	src/auth.js                    # 认证 + 速率限制（含 LRU 防护）
//	src/storage/
//	  storage.js                    # Vault + Storage 接口（预留多 vault）
//	  fs.js                         # 文件系统实现（含 fsync）
//	src/middleware.js              # 中间件链
//	src/logger.js                  # 结构化日志
//	src/handlers.js                # HTTP handlers
//
// 用法：
//
//	node server/nodejs/server.js [--port 8080] [--data ./data] [--token my-secret-token]
//	                            [--rate-limit 10] [--max-body 67108864]
//	                            [--read-timeout 60000] [--write-timeout 60000]
//	                            [--log-level info] [--log-file xxx] [--log-json]
//	                            [--config dev.json]

'use strict';

import http from 'http';
import { parseArgs } from './src/config.js';
import { FailTracker, checkToken, extractIP } from './src/auth.js';
import { FileSystemStorage } from './src/storage/fs.js';
import { DefaultVaultID } from './src/storage/storage.js';
import { Logger } from './src/logger.js';
import { requestID, wrapResponse, makeLogging } from './src/middleware.js';
import { createHandlers } from './src/handlers.js';

// ──────────────────────────────────────────────
// 启动流程
// ──────────────────────────────────────────────

const cfg = parseArgs();
const logger = new Logger({
  level: cfg.logLevel,
  file: cfg.logFile,
  json: cfg.logJSON,
});

// 初始化存储后端（默认文件系统）+ 默认 vault（单用户场景）
const storage = new FileSystemStorage(cfg.dataDir);
const vault = await storage.newVault(DefaultVaultID);

// 认证失败跟踪器（1 分钟窗口，最多跟踪 10000 个 IP 防 OOM）
const authFail = new FailTracker(60000, 10000);

// 创建 handlers
const handlers = createHandlers(vault, logger);

// 中间件：日志记录器
const logRequest = makeLogging(logger);

// ──────────────────────────────────────────────
// 路由分发
// ──────────────────────────────────────────────

async function handle(req, res) {
  // 1. 中间件：RequestID
  requestID(req, res);
  const startTime = Date.now();
  // 包装 res 以捕获状态码和写入字节数（用于日志）
  const wrapped = wrapResponse(res);

  try {
    // 2. 请求体大小限制（防恶意大文件上传撑满磁盘）
    req._maxBodyBytes = cfg.maxBodyBytes;

    // 3. 健康检查（不需要认证、不受速率限制）
    if (req.url === '/api/v2/health' && req.method === 'GET') {
      res.writeHead(200, { 'Content-Type': 'text/plain' });
      res.end('ok');
      return;
    }

    // 4. 速率限制检查（认证失败超限的 IP 直接拒绝）
    const clientIP = extractIP(req);
    if (authFail.isRateLimited(clientIP, cfg.rateLimit)) {
      res.writeHead(429, { 'Retry-After': '60' });
      res.end('Too Many Requests (auth failure rate limit)');
      return;
    }

    // 5. 认证
    if (!checkToken(req, cfg.token)) {
      authFail.recordFailure(clientIP);
      res.writeHead(401, { 'WWW-Authenticate': 'Bearer' });
      res.end('Unauthorized');
      return;
    }
    // 认证成功：清除失败计数
    authFail.resetFailures(clientIP);

    // 6. 路由分发
    const url = new URL(req.url, `http://${req.headers.host}`);
    const pathname = url.pathname;

    if (pathname === '/api/v2/manifest') {
      if (req.method === 'GET') await handlers.getManifest(req, res);
      else if (req.method === 'PUT') await handlers.putManifest(req, res);
      else if (req.method === 'DELETE') await handlers.deleteManifest(req, res);
      else {
        res.writeHead(405, { 'Allow': 'GET, PUT, DELETE' });
        res.end('Method not allowed');
      }
      return;
    }

    if (pathname === '/api/v2/blobs' && req.method === 'GET') {
      await handlers.listBlobs(req, res);
      return;
    }

    if (pathname.startsWith('/api/v2/blob/')) {
      const hash = decodeURIComponent(pathname.slice('/api/v2/blob/'.length));
      if (req.method === 'GET') await handlers.getBlob(req, res, hash);
      else if (req.method === 'PUT') await handlers.putBlob(req, res, hash);
      else if (req.method === 'DELETE') await handlers.deleteBlob(req, res, hash);
      else {
        res.writeHead(405, { 'Allow': 'GET, PUT, DELETE' });
        res.end('Method not allowed');
      }
      return;
    }

    res.writeHead(404);
    res.end('Not Found');
  } catch (err) {
    // 异常捕获（等同于 Recover 中间件）
    logger.error('panic recovered', {
      error: err.message,
      stack: err.stack || '',
      request_id: req._requestID || '',
      method: req.method,
      path: req.url,
    });
    if (!wrapped.headersSent) {
      res.writeHead(500);
      res.end('Internal Server Error');
    }
  } finally {
    // 中间件：Logging（记录每个请求的访问日志）
    logRequest(req, res, wrapped, startTime);
  }
}

// ──────────────────────────────────────────────
// HTTP Server + graceful shutdown
// ──────────────────────────────────────────────

const server = http.createServer((req, res) => {
  handle(req, res);
});

// 请求超时配置（使用配置项，对应 Go server 语义）
//   - requestTimeout：整个请求的超时（含 headers + body），对应 Go ReadTimeout
//   - headersTimeout：请求头必须在 readTimeoutMs 内读完
//   - timeout：socket 不活动超时（写响应），对应 Go WriteTimeout
server.requestTimeout = cfg.readTimeoutMs;
server.headersTimeout = cfg.readTimeoutMs;
server.timeout = cfg.writeTimeoutMs;

server.listen(cfg.port, () => {
  logger.info('SafeServer v2.1 (Node.js) starting', {
    port: cfg.port,
    data_dir: cfg.dataDir,
    token_mask: '*'.repeat(cfg.token.length),
    rate_limit: `${cfg.rateLimit}/min (0=disabled)`,
    max_body_bytes: cfg.maxBodyBytes,
    read_timeout_ms: cfg.readTimeoutMs,
    write_timeout_ms: cfg.writeTimeoutMs,
    log_level: cfg.logLevel,
    log_file: cfg.logFile,
    log_json: cfg.logJSON,
  });
});

// graceful shutdown：捕获信号，等待在途请求完成
let shuttingDown = false;
function shutdown(sig) {
  if (shuttingDown) return;
  shuttingDown = true;
  logger.info('received signal, shutting down gracefully', { signal: sig });
  server.close(() => {
    logger.info('server closed', { signal: sig });
    process.exit(0);
  });
  // 30 秒后强制退出
  setTimeout(() => {
    logger.warn('graceful shutdown timeout, forcing exit', { signal: sig });
    process.exit(1);
  }, 30000).unref();
}

process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('uncaughtException', (err) => {
  logger.error('uncaughtException', { error: err.message, stack: err.stack });
});
process.on('unhandledRejection', (reason) => {
  logger.error('unhandledRejection', { reason: String(reason) });
});
