/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

// HTTP handlers（SafeServer v2.1 + v2.2 协议端点）
//
// 所有 handler 通过 vault 操作存储层，不直接接触文件系统。
// 这样切换存储后端（数据库/对象存储）时只需实现新的 Vault，无需改 handler。
//
// v2.2 新增 /api/v2/resources/<path> 通用资源层：用纯 REST/JSON 表达等价于
// WebDAV GET/PUT/DELETE/MOVE/MKCOL/COPY/PROPFIND 的语义，兼容任意 HTTP client。

'use strict';

import {
  computeETag, PutOptions,
  ErrNotFound, ErrInvalidHash, ErrInvalidPath,
  ErrPreconditionFailed, ErrExists, ErrConflict,
} from './storage/storage.js';

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

  // ──────────────────────────────────────────────
  // 通用资源层 /api/v2/resources/<path>（v2.2）
  //
  // 语义等价于 WebDAV 的 GET / PUT / DELETE / MOVE / MKCOL / COPY / PROPFIND，
  // 但用纯 REST/JSON 表达：
  //   GET  /api/v2/resources/<path>        → 读资源内容（WebDAV GET）
  //   PUT  /api/v2/resources/<path>        → 写资源（WebDAV PUT，支持 If-Match/If-None-Match）
  //   DELETE /api/v2/resources/<path>      → 删资源（WebDAV DELETE）
  //   POST /api/v2/resources/<path>        → 扩展操作（body 中指定 op）：
  //       {op:"move",   dest, overwrite}   → 移动/重命名（WebDAV MOVE）
  //       {op:"mkdir"}                     → 建目录（WebDAV MKCOL）
  //       {op:"copy",   dest, overwrite}   → 复制（WebDAV COPY）
  //       {op:"propfind", depth}           → 列目录+属性（WebDAV PROPFIND，depth=1）
  //       {op:"stats"}                     → 单资源元数据（WebDAV PROPFIND depth=0 的别名）
  // 所有操作都在 vault 命名空间内，服务端不解析 blob 内容（零知识不变）。
  // ──────────────────────────────────────────────

  // 统一映射 blob/资源层错误到 HTTP 状态码
  function mapResourceErr(err, res, notFoundCode) {
    if (err === ErrNotFound) { res.writeHead(notFoundCode); res.end(err.message); return true; }
    if (err === ErrInvalidPath || err === ErrInvalidHash) { res.writeHead(400); res.end(err.message); return true; }
    return false;
  }

  // GET /api/v2/resources/<path> → 读资源内容
  async function getResource(req, res, rel) {
    if (rel === '') { res.writeHead(400); res.end('resource path required'); return; }
    let data;
    try {
      data = await vault.getResource(rel);
    } catch (err) {
      if (mapResourceErr(err, res, 404)) return;
      logger.error('getResource failed', { error: err.message, rel });
      res.writeHead(500); res.end(`read failed: ${err.message}`); return;
    }
    res.setHeader('ETag', computeETag(data));
    res.setHeader('Content-Type', 'application/octet-stream');
    res.writeHead(200);
    res.end(data);
  }

  // PUT /api/v2/resources/<path> → 写资源（支持 If-Match / If-None-Match）
  async function putResource(req, res, rel) {
    if (rel === '') { res.writeHead(400); res.end('resource path required'); return; }
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
    const opts = new PutOptions({
      ifNoneMatch: ifNoneMatch === '*',
      ifMatch: ifMatch ? ifMatch.replace(/^"(.*)"$/, '$1') : '',
    });
    try {
      await vault.putResource(rel, body, opts);
    } catch (err) {
      if (err === ErrPreconditionFailed) { res.writeHead(412); res.end(err.message); return; }
      if (err === ErrInvalidPath || err === ErrInvalidHash) { res.writeHead(400); res.end(err.message); return; }
      logger.error('putResource failed', { error: err.message, rel });
      res.writeHead(500); res.end(`write failed: ${err.message}`); return;
    }
    res.setHeader('ETag', computeETag(body));
    res.writeHead(200);
    res.end();
  }

  // DELETE /api/v2/resources/<path> → 删资源（幂等）
  async function deleteResource(req, res, rel) {
    if (rel === '') { res.writeHead(400); res.end('resource path required'); return; }
    try {
      await vault.deleteResource(rel);
    } catch (err) {
      if (err === ErrInvalidPath || err === ErrInvalidHash) { res.writeHead(400); res.end(err.message); return; }
      logger.error('deleteResource failed', { error: err.message, rel });
      res.writeHead(500); res.end(`delete failed: ${err.message}`); return;
    }
    res.writeHead(204);
    res.end();
  }

  // POST /api/v2/resources/<path> → 扩展操作（move / mkdir / copy / propfind / stats）
  async function resourceOp(req, res, rel) {
    if (rel === '') { res.writeHead(400); res.end('resource path required'); return; }
    let ob;
    try {
      const raw = await readBody(req, req._maxBodyBytes);
      ob = JSON.parse(raw.toString('utf8'));
    } catch (err) {
      res.writeHead(400); res.end('invalid JSON body'); return;
    }

    const op = ob.op;
    try {
      switch (op) {
        case 'move': {
          if (!ob.dest) { res.writeHead(400); res.end('dest required'); return; }
          await vault.moveResource(rel, ob.dest, !!ob.overwrite);
          res.writeHead(204); res.end();
          return;
        }
        case 'copy': {
          if (!ob.dest) { res.writeHead(400); res.end('dest required'); return; }
          await vault.copyResource(rel, ob.dest, !!ob.overwrite);
          res.writeHead(204); res.end();
          return;
        }
        case 'mkdir': {
          await vault.mkCol(rel);
          res.writeHead(201); res.end();
          return;
        }
        case 'propfind':
        case 'stats': {
          const depth = op === 'stats' ? 0 : (ob.depth || 0);
          const entries = await vault.propFind(rel, depth);
          res.setHeader('Content-Type', 'application/json');
          res.writeHead(200);
          res.end(JSON.stringify(entries));
          return;
        }
        default:
          res.writeHead(400); res.end(`unknown op: ${op}`); return;
      }
    } catch (err) {
      if (err === ErrNotFound) { res.writeHead(404); res.end(err.message); return; }
      if (err === ErrConflict) { res.writeHead(409); res.end(err.message); return; }
      if (err === ErrExists) { res.writeHead(405); res.end('already exists'); return; }
      if (err === ErrInvalidPath || err === ErrInvalidHash) { res.writeHead(400); res.end(err.message); return; }
      logger.error('resourceOp failed', { error: err.message, rel, op });
      res.writeHead(500); res.end(`${op} failed: ${err.message}`); return;
    }
  }

  return {
    getManifest, putManifest, deleteManifest,
    getBlob, putBlob, deleteBlob, listBlobs,
    getResource, putResource, deleteResource, resourceOp,
  };
}
