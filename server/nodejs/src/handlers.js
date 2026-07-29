// HTTP handlers（SafeServer v2.1 协议端点）
//
// 所有 handler 通过 vault 操作存储层，不直接接触文件系统。
// 这样切换存储后端（数据库/对象存储）时只需实现新的 Vault，无需改 handler。

'use strict';

import { computeETag, ErrNotFound, ErrInvalidHash, ErrPreconditionFailed, PutOptions } from './storage/storage.js';

// 读取请求 body 为 Buffer（带大小限制）
export function readBody(req, maxBytes) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;
    let aborted = false;
    req.on('data', (c) => {
      if (aborted) return;
      total += c.length;
      if (total > maxBytes) {
        aborted = true;
        const err = new Error('Payload Too Large');
        err.code = 'PAYLOAD_TOO_LARGE';
        req.destroy();
        reject(err);
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => { if (!aborted) resolve(Buffer.concat(chunks)); });
    req.on('error', (err) => { if (!aborted) reject(err); });
  });
}

// 创建 handlers 工厂
//
// 传入 vault 和 logger，返回各端点的 handler 函数。
export function createHandlers(vault, logger) {

  // ──────────────────────────────────────────────
  // manifest 端点
  // ──────────────────────────────────────────────

  // GET /api/v2/manifest
  async function getManifest(req, res) {
    let data;
    try {
      data = await vault.getManifest();
    } catch (err) {
      if (err === ErrNotFound) {
        res.writeHead(404); res.end('Not Found'); return;
      }
      logger.error('getManifest failed', { error: err.message });
      res.writeHead(500); res.end(`read failed: ${err.message}`); return;
    }
    res.setHeader('ETag', computeETag(data));
    res.setHeader('Content-Type', 'application/octet-stream');
    res.writeHead(200);
    res.end(data);
  }

  // PUT /api/v2/manifest（乐观锁 + 临界区保护）
  async function putManifest(req, res) {
    let body;
    try {
      body = await readBody(req, req._maxBodyBytes);
    } catch (err) {
      if (err.code === 'PAYLOAD_TOO_LARGE') {
        res.writeHead(413); res.end('Payload Too Large'); return;
      }
      res.writeHead(400); res.end(`read body failed: ${err.message}`); return;
    }

    const ifMatch = req.headers['if-match'];
    const ifNoneMatch = req.headers['if-none-match'];

    // 构造乐观锁参数
    const opts = new PutOptions({
      ifNoneMatch: ifNoneMatch === '*',
      ifMatch: ifMatch ? ifMatch.replace(/^"(.*)"$/, '$1') : '',
    });

    try {
      await vault.putManifest(body, opts);
    } catch (err) {
      if (err === ErrPreconditionFailed) {
        res.writeHead(412); res.end(err.message); return;
      }
      logger.error('putManifest failed', { error: err.message });
      res.writeHead(500); res.end(`write failed: ${err.message}`); return;
    }
    res.setHeader('ETag', computeETag(body));
    res.writeHead(200);
    res.end();
  }

  // DELETE /api/v2/manifest（清理损坏文件，backupCorruptManifest 用）
  async function deleteManifest(req, res) {
    try {
      await vault.deleteManifest();
    } catch (err) {
      logger.error('deleteManifest failed', { error: err.message });
      res.writeHead(500); res.end(`delete manifest failed: ${err.message}`); return;
    }
    res.writeHead(204);
    res.end();
  }

  // ──────────────────────────────────────────────
  // blob 端点
  // ──────────────────────────────────────────────

  // GET /api/v2/blob/<hash>
  async function getBlob(req, res, hash) {
    let data;
    try {
      data = await vault.getBlob(hash);
    } catch (err) {
      if (err === ErrNotFound) { res.writeHead(404); res.end('Not Found'); return; }
      if (err === ErrInvalidHash) { res.writeHead(400); res.end(err.message); return; }
      logger.error('getBlob failed', { error: err.message, hash });
      res.writeHead(500); res.end(`read failed: ${err.message}`); return;
    }
    res.setHeader('Content-Type', 'application/octet-stream');
    res.writeHead(200);
    res.end(data);
  }

  // PUT /api/v2/blob/<hash>（幂等）
  async function putBlob(req, res, hash) {
    let body;
    try {
      body = await readBody(req, req._maxBodyBytes);
    } catch (err) {
      if (err.code === 'PAYLOAD_TOO_LARGE') {
        res.writeHead(413); res.end('Payload Too Large'); return;
      }
      res.writeHead(400); res.end(`read body failed: ${err.message}`); return;
    }
    try {
      await vault.putBlob(hash, body);
    } catch (err) {
      if (err === ErrInvalidHash) { res.writeHead(400); res.end(err.message); return; }
      logger.error('putBlob failed', { error: err.message, hash });
      res.writeHead(500); res.end(`write failed: ${err.message}`); return;
    }
    res.writeHead(200);
    res.end();
  }

  // DELETE /api/v2/blob/<hash>（GC 用，幂等）
  async function deleteBlob(req, res, hash) {
    try {
      await vault.deleteBlob(hash);
    } catch (err) {
      if (err === ErrInvalidHash) { res.writeHead(400); res.end(err.message); return; }
      logger.error('deleteBlob failed', { error: err.message, hash });
      res.writeHead(500); res.end(`delete failed: ${err.message}`); return;
    }
    res.writeHead(204);
    res.end();
  }

  // GET /api/v2/blobs（列出所有 blob hash，GC 用）
  async function listBlobs(req, res) {
    let hashes;
    try {
      hashes = await vault.listBlobs();
    } catch (err) {
      logger.error('listBlobs failed', { error: err.message });
      res.writeHead(500); res.end(`list blobs failed: ${err.message}`); return;
    }
    res.setHeader('Content-Type', 'application/json');
    res.writeHead(200);
    res.end(JSON.stringify(hashes));
  }

  return { getManifest, putManifest, deleteManifest, getBlob, putBlob, deleteBlob, listBlobs };
}
