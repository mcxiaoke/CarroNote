// SafeServer 同步服务端参考实现（Node.js）
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
//   node server/nodejs/server.js [--port 8080] [--data ./data] [--token my-secret-token] [--rate-limit 10]

'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

// ──────────────────────────────────────────────
// 配置（命令行参数解析）
// ──────────────────────────────────────────────

function parseArgs() {
  const args = process.argv.slice(2);
  const cfg = { port: 8080, dataDir: './data', token: 'my-secret-token', rateLimit: 10 };
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === '--port') cfg.port = parseInt(args[++i], 10);
    else if (a === '--data') cfg.dataDir = args[++i];
    else if (a === '--token') cfg.token = args[++i];
    else if (a === '--rate-limit') cfg.rateLimit = parseInt(args[++i], 10);
    else if (a.startsWith('--port=')) cfg.port = parseInt(a.slice(7), 10);
    else if (a.startsWith('--data=')) cfg.dataDir = a.slice(7);
    else if (a.startsWith('--token=')) cfg.token = a.slice(8);
    else if (a.startsWith('--rate-limit=')) cfg.rateLimit = parseInt(a.slice(13), 10);
  }
  return cfg;
}

const cfg = parseArgs();

// ──────────────────────────────────────────────
// 认证失败速率限制（E3：防 Token 暴力枚举）
// ──────────────────────────────────────────────

// AuthFailTracker：按 IP 分组跟踪认证失败次数，滑动窗口（1 分钟）
class AuthFailTracker {
  constructor(windowMs = 60000) {
    this.failures = new Map(); // IP -> 失败时间戳数组
    this.windowMs = windowMs;
  }

  // 检查指定 IP 是否被限速
  isRateLimited(ip, limit) {
    if (limit <= 0) return false;
    const now = Date.now();
    const cutoff = now - this.windowMs;
    const list = (this.failures.get(ip) || []).filter(ts => ts > cutoff);
    this.failures.set(ip, list);
    return list.length >= limit;
  }

  // 记录一次认证失败
  recordFailure(ip) {
    const list = this.failures.get(ip) || [];
    list.push(Date.now());
    this.failures.set(ip, list);
  }

  // 认证成功后清除该 IP 的失败记录
  resetFailures(ip) {
    this.failures.delete(ip);
  }
}

const authFail = new AuthFailTracker();

// 从请求中提取客户端 IP
function extractIP(req) {
  // 优先从 X-Forwarded-For 取（反向代理场景）
  const xff = req.headers['x-forwarded-for'];
  if (xff) {
    const first = xff.split(',')[0].trim();
    if (first) return first;
  }
  const addr = req.socket.remoteAddress || '';
  // 去掉端口部分
  const idx = addr.lastIndexOf(':');
  if (idx > 0) return addr.slice(0, idx);
  return addr;
}

// ──────────────────────────────────────────────
// Server
// ──────────────────────────────────────────────

// 存储布局（cfg.dataDir 下）：
//   <dataDir>/manifest          # manifest 密文（单文件）
//   <dataDir>/blobs/<hash>      # blob 密文

const manifestPath = () => path.join(cfg.dataDir, 'manifest');
const blobsDir = () => path.join(cfg.dataDir, 'blobs');

// 路径安全检查：校验 hash 不包含路径分隔符或 ..
function resolveBlobPath(hash) {
  if (!hash || hash.includes('/') || hash.includes('\\') || hash.includes('..')) {
    return null;
  }
  const full = path.join(blobsDir(), hash);
  const absBlobs = path.resolve(blobsDir());
  const absFull = path.resolve(full);
  if (!absFull.startsWith(absBlobs)) return null;
  return absFull;
}

// 计算内容的 SHA-256 作为强 ETag（带引号）
function computeEtag(data) {
  const h = crypto.createHash('sha256').update(data).digest('hex');
  return `"${h}"`;
}

// Bearer Token 校验（constant-time compare）
function checkAuth(req) {
  const auth = req.headers['authorization'] || '';
  const prefix = 'Bearer ';
  if (auth.length <= prefix.length || auth.slice(0, prefix.length).toLowerCase() !== prefix.toLowerCase()) {
    return false;
  }
  const token = auth.slice(prefix.length);
  try {
    return crypto.timingSafeEqual(Buffer.from(token), Buffer.from(cfg.token));
  } catch {
    return false;
  }
}

// 原子写入：tmp + rename
function atomicWrite(filePath, data) {
  const tmpPath = filePath + '.tmp';
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(tmpPath, data);
  fs.renameSync(tmpPath, filePath);
}

// 读取请求 body 为 Buffer
function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

// ──────────────────────────────────────────────
// HTTP Handlers
// ──────────────────────────────────────────────

// manifest 写操作互斥锁
let manifestLock = Promise.resolve();
function withManifestLock(fn) {
  const next = manifestLock.then(fn, fn);
  manifestLock = next.catch(() => {});
  return next;
}

async function handle(req, res) {
  // 健康检查（不需要认证、不受速率限制）
  if (req.url === '/api/v2/health' && req.method === 'GET') {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('ok');
    return;
  }

  // 速率限制检查（认证失败超限的 IP 直接拒绝）
  const clientIP = extractIP(req);
  if (authFail.isRateLimited(clientIP, cfg.rateLimit)) {
    res.writeHead(429, { 'Retry-After': '60' });
    res.end('Too Many Requests (auth failure rate limit)');
    return;
  }

  // 认证
  if (!checkAuth(req)) {
    authFail.recordFailure(clientIP);
    res.writeHead(401, { 'WWW-Authenticate': 'Bearer' });
    res.end('Unauthorized');
    return;
  }
  // 认证成功：清除失败计数
  authFail.resetFailures(clientIP);

  const url = new URL(req.url, `http://${req.headers.host}`);
  const pathname = url.pathname;

  if (pathname === '/api/v2/manifest') {
    if (req.method === 'GET') return handleGetManifest(req, res);
    if (req.method === 'PUT') return handlePutManifest(req, res);
    if (req.method === 'DELETE') return handleDeleteManifest(req, res);
    res.writeHead(405, { 'Allow': 'GET, PUT, DELETE' });
    res.end('Method not allowed');
    return;
  }

  if (pathname === '/api/v2/blobs' && req.method === 'GET') {
    return handleListBlobs(req, res);
  }

  if (pathname.startsWith('/api/v2/blob/')) {
    const hash = decodeURIComponent(pathname.slice('/api/v2/blob/'.length));
    if (req.method === 'GET') return handleGetBlob(req, res, hash);
    if (req.method === 'PUT') return handlePutBlob(req, res, hash);
    if (req.method === 'DELETE') return handleDeleteBlob(req, res, hash);
    res.writeHead(405, { 'Allow': 'GET, PUT, DELETE' });
    res.end('Method not allowed');
    return;
  }

  res.writeHead(404);
  res.end('Not Found');
}

// GET /api/v2/manifest
function handleGetManifest(req, res) {
  const p = manifestPath();
  if (!fs.existsSync(p)) {
    res.writeHead(404);
    res.end('Not Found');
    return;
  }
  const data = fs.readFileSync(p);
  res.writeHead(200, {
    'ETag': computeEtag(data),
    'Content-Type': 'application/octet-stream',
  });
  res.end(data);
}

// PUT /api/v2/manifest（乐观锁）
async function handlePutManifest(req, res) {
  const body = await readBody(req);

  await withManifestLock(async () => {
    const p = manifestPath();
    const exists = fs.existsSync(p);
    const existing = exists ? fs.readFileSync(p) : null;

    const ifMatch = req.headers['if-match'];
    const ifNoneMatch = req.headers['if-none-match'];

    if (ifNoneMatch === '*') {
      // 首次上传：远端必须不存在
      if (exists) {
        res.writeHead(412);
        res.end('If-None-Match: * failed (manifest exists)');
        return;
      }
    } else if (ifMatch) {
      // 乐观锁：远端 ETag 必须匹配
      if (!exists) {
        res.writeHead(412);
        res.end('If-Match failed (manifest not found)');
        return;
      }
      const currentEtag = computeEtag(existing);
      const expected = ifMatch.replace(/^"(.*)"$/, '$1');
      if (currentEtag !== `"${expected}"`) {
        res.writeHead(412);
        res.end('If-Match failed (etag mismatch)');
        return;
      }
    }

    // 原子写入
    atomicWrite(p, body);
    res.writeHead(200, { 'ETag': computeEtag(body) });
    res.end();
  });
}

// DELETE /api/v2/manifest（清理损坏文件，backupCorruptManifest 用）
//
// 删除 manifest 文件。客户端在 manifest 解析失败时调用此端点
// 清理损坏文件，然后用本地数据重建 manifest 上传。
// 404 视为成功（幂等删除）。
async function handleDeleteManifest(req, res) {
  await withManifestLock(async () => {
    const p = manifestPath();
    if (!fs.existsSync(p)) {
      // 幂等：删除不存在的文件视为成功
      res.writeHead(204);
      res.end();
      return;
    }
    try {
      fs.unlinkSync(p);
      res.writeHead(204);
      res.end();
    } catch (err) {
      res.writeHead(500);
      res.end(`delete manifest failed: ${err.message}`);
    }
  });
}

// GET /api/v2/blob/<hash>
function handleGetBlob(req, res, hash) {
  const p = resolveBlobPath(hash);
  if (!p) {
    res.writeHead(400);
    res.end('Invalid hash');
    return;
  }
  if (!fs.existsSync(p)) {
    res.writeHead(404);
    res.end('Not Found');
    return;
  }
  const data = fs.readFileSync(p);
  res.writeHead(200, { 'Content-Type': 'application/octet-stream' });
  res.end(data);
}

// PUT /api/v2/blob/<hash>（幂等）
async function handlePutBlob(req, res, hash) {
  const p = resolveBlobPath(hash);
  if (!p) {
    res.writeHead(400);
    res.end('Invalid hash');
    return;
  }
  const body = await readBody(req);
  atomicWrite(p, body);
  res.writeHead(200);
  res.end();
}

// DELETE /api/v2/blob/<hash>（GC 用，幂等）
//
// 删除指定 hash 的 blob。404 视为成功（幂等删除）。
// 客户端在 GC 流程中调用此端点清理孤儿 blob。
function handleDeleteBlob(req, res, hash) {
  const p = resolveBlobPath(hash);
  if (!p) {
    res.writeHead(400);
    res.end('Invalid hash');
    return;
  }
  if (!fs.existsSync(p)) {
    // 幂等：删除不存在的 blob 视为成功
    res.writeHead(204);
    res.end();
    return;
  }
  try {
    fs.unlinkSync(p);
    res.writeHead(204);
    res.end();
  } catch (err) {
    res.writeHead(500);
    res.end(`delete blob failed: ${err.message}`);
  }
}

// GET /api/v2/blobs（列出所有 blob hash，GC 用）
//
// 返回 JSON 数组，包含 blobs/ 目录下所有 blob 的 hash。
// 服务端不解析内容，仅列文件名。需认证（不破坏防枚举原则——
// 攻击者无 Token 无法访问）。
function handleListBlobs(req, res) {
  const dir = blobsDir();
  if (!fs.existsSync(dir)) {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end('[]');
    return;
  }
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch (err) {
    res.writeHead(500);
    res.end(`list blobs failed: ${err.message}`);
    return;
  }
  const hashes = [];
  for (const entry of entries) {
    if (!entry.isFile()) continue;
    const name = entry.name;
    // 跳过 .tmp 临时文件
    if (name.endsWith('.tmp')) continue;
    hashes.push(name);
  }
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(hashes));
}

// ──────────────────────────────────────────────
// main
// ──────────────────────────────────────────────

// 确保数据目录存在
fs.mkdirSync(cfg.dataDir, { recursive: true });

const server = http.createServer((req, res) => {
  handle(req, res).catch((err) => {
    console.error('handler error:', err);
    if (!res.headersSent) {
      res.writeHead(500);
      res.end('Internal Server Error');
    }
  });
});

server.listen(cfg.port, () => {
  console.log(`SafeServer v2.1 (Node.js) listening on :${cfg.port}`);
  console.log(`  data dir:   ${path.resolve(cfg.dataDir)}`);
  console.log(`  token:      ${'*'.repeat(cfg.token.length)}`);
  console.log(`  rate limit: ${cfg.rateLimit}/min (0=disabled)`);
});
