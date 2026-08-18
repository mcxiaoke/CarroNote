/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

// HTTP 中间件
//
// 中间件链顺序（外到内）：requestID → logging → recover → handler
//   - requestID：为每个请求生成唯一 ID，放入 context 和响应头
//   - logging：记录请求日志（方法、路径、状态码、耗时、请求ID、客户端IP）
//   - recover：捕获 handler 异常，防止进程崩溃；logging 仍能记录到 500

'use strict';

import crypto from 'crypto';
import { extractIP } from './auth.js';

// 生成 16 字符的随机十六进制 ID
function generateID() {
  return crypto.randomBytes(8).toString('hex');
}

// requestID 为每个请求生成唯一 ID
//
// 优先使用客户端传入的 X-Request-ID 头，否则生成随机 ID。
// 响应头回传 X-Request-ID，便于客户端关联日志。
export function requestID(req, res) {
  let id = req.headers['x-request-id'];
  if (!id) id = generateID();
  req._requestID = id;
  res.setHeader('X-Request-ID', id);
}

// 脱敏 Authorization 头（只显示前缀，不泄露 token）
function maskAuth(authHeader) {
  if (authHeader && authHeader.length > 12) {
    return authHeader.slice(0, 12) + '...(masked)';
  }
  return authHeader || '';
}

// wrapResponse 包装 ServerResponse，捕获状态码和写入字节数用于日志
export function wrapResponse(res) {
  const originalWriteHead = res.writeHead.bind(res);
  const originalEnd = res.end.bind(res);
  const wrapped = {
    statusCode: 200,
    bytesWritten: 0,
    headersSent: false,
  };

  res.writeHead = function(code, ...args) {
    wrapped.statusCode = code;
    wrapped.headersSent = true;
    return originalWriteHead(code, ...args);
  };

  const origWrite = res.write.bind(res);
  res.write = function(chunk, ...args) {
    if (chunk && chunk.length) wrapped.bytesWritten += chunk.length;
    return origWrite(chunk, ...args);
  };

  res.end = function(chunk, ...args) {
    if (chunk && chunk.length) wrapped.bytesWritten += chunk.length;
    if (!wrapped.headersSent) {
      wrapped.headersSent = true;
    }
    return originalEnd(chunk, ...args);
  };

  return wrapped;
}

// logging 记录请求访问日志
//
// info 级别：method、path、status、duration_ms、request_id、remote_addr
// debug 级别：额外记录请求头、body 大小、响应字节数
export function makeLogging(logger) {
  return function logging(req, res, wrapped, startTime) {
    const duration = Date.now() - startTime;
    const rid = req._requestID || '';
    const fields = {
      method: req.method,
      path: req.url,
      status: wrapped.statusCode,
      duration_ms: duration,
      request_id: rid,
      remote_addr: extractIP(req),
    };

    if (logger.enabled('debug')) {
      // debug 级别：记录详细的请求头
      fields.req_headers = {
        authorization: maskAuth(req.headers['authorization']),
        'if-match': req.headers['if-match'] || '',
        'if-none-match': req.headers['if-none-match'] || '',
        'content-type': req.headers['content-type'] || '',
        'content-length': req.headers['content-length'] || '',
        'x-forwarded-for': req.headers['x-forwarded-for'] || '',
      };
      fields.resp_bytes = wrapped.bytesWritten;
      fields.host = req.headers.host || '';
      logger.debug('request detailed', fields);
    } else {
      logger.info('request', fields);
    }
  };
}
