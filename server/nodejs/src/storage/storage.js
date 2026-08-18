/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

// 存储后端抽象接口
//
// 设计目标：
//   - 解耦 HTTP 层与存储层，支持切换存储后端（文件系统/数据库/对象存储）
//   - 预留多 vault 扩展接口（单用户场景用默认 vault，未来可扩展为多用户/多 vault）
//
// 接口分层：
//   - Storage：存储后端工厂，负责创建 Vault 实例
//   - Vault：单个保险库的操作句柄，包含 manifest 和 blob 的 CRUD
//
// 所有 PUT 操作必须保证原子性和耐久性（fsync + rename），防止崩溃导致半写文件。

'use strict';

import crypto from 'crypto';
import path from 'path';

// DefaultVaultID 是单用户场景下使用的默认 vault ID
//
// 不再用空字符串 ""，这样：
//   - 文件系统实现中所有 vault 都统一在 <rootDir>/vaults/<vaultID>/ 下，不污染根目录
//   - 数据库实现中 vaultID 可直接用作表名前缀或分区键，无需特判空值
//   - 存储布局一致，便于管理和扩展
export const DefaultVaultID = 'vault-default';

// 哨兵错误
export const ErrNotFound = Object.freeze(new Error('not found'));
export const ErrInvalidHash = Object.freeze(new Error('invalid hash'));
export const ErrPreconditionFailed = Object.freeze(new Error('precondition failed'));
// ErrInvalidPath 资源路径非法（空路径 / 绝对路径 / 含 .. 逃逸 / 含 NUL 等）
export const ErrInvalidPath = Object.freeze(new Error('invalid path'));
// ErrExists 资源已存在（MKCOL 目标已存在，映射为 405）
export const ErrExists = Object.freeze(new Error('already exists'));
// ErrConflict 目标已存在且 overwrite=false（MOVE/COPY 冲突或父目录缺失，映射 409）
export const ErrConflict = Object.freeze(new Error('conflict'));

// ValidateHash 校验 blob hash 是否合法（防路径穿越）
//
// 拒绝：空 hash、含路径分隔符（/ \）、含 .. 、含 NUL 字节。
export function validateHash(hash) {
  if (!hash) return false;
  if (hash.includes('/') || hash.includes('\\')) return false;
  if (hash.includes('..')) return false;
  if (hash.includes('\0')) return false;
  return true;
}

// ValidateVaultPath 校验 vault 内相对路径是否合法（允许子目录，禁止路径穿越）
//
// 与 validateHash 的区别：允许一个相对子目录（如 "blobs-orphan/<hash>.<ts>"），
// 但仍禁止绝对路径、空路径、含 NUL 字节，以及任何 ".." 逃逸段。
// 这是通用资源层（v2.2）的安全红线。
export function validateVaultPath(rel) {
  if (!rel) return false;
  if (rel.includes('\0')) return false;
  if (rel.includes('\\')) return false;
  const clean = path.posix.normalize(rel);
  // 拒绝绝对路径（POSIX 以 "/" 开头；Windows 盘符在 URL 中不会出现）
  if (clean.startsWith('/')) return false;
  // 拒绝逃逸出 vault 根（规范化后以 ".." 开头或含 ".." 段）
  const segs = clean.split('/');
  for (const seg of segs) {
    if (seg === '..') return false;
  }
  return true;
}

// ComputeETag 计算内容的 SHA-256 作为强 ETag（带引号）
export function computeETag(data) {
  const h = crypto.createHash('sha256').update(data).digest('hex');
  return `"${h}"`;
}

// PutOptions 是 PUT manifest 的乐观锁参数
//   - ifNoneMatch: true 时要求资源不存在（首次上传）
//   - ifMatch: 非空时要求当前 ETag 匹配此值（不带引号）
export class PutOptions {
  constructor({ ifNoneMatch = false, ifMatch = '' } = {}) {
    this.ifNoneMatch = ifNoneMatch;
    this.ifMatch = ifMatch;
  }
}

// ResourceEntry 是 PropFind 返回的单个资源元数据
//
// 等价于 WebDAV PROPFIND 的属性集合（getcontentlength / getlastmodified / resourcetype），
// 但以普通 JSON 返回，避免 XML 解析。
export class ResourceEntry {
  constructor({ name, path: p, isDir, size, modTime, etag = '' }) {
    this.name = name;       // 资源名（路径最后一段）
    this.path = p;          // vault 内相对路径
    this.isDir = isDir;     // 是否为目录
    this.size = size;       // 文件大小（字节），目录为 0
    this.modTime = modTime; // 最后修改时间（Unix 毫秒）
    this.etag = etag;       // 文件内容的强 ETag（目录为空）
  }
}

// Vault 表示一个同步保险库的存储操作句柄
//
// 单用户场景下只有一个默认 Vault（vaultID="vault-default"）；
// 未来多 vault 场景下，每个 vaultID 对应一个独立的 Vault 实例，存储相互隔离。
//
// 实现要求：
//   - 所有 PUT 操作必须原子写入（tmp + fsync + rename）
//   - manifest 的 PUT/DELETE 必须串行化（实现内部加锁）
//   - "校验乐观锁条件 + 写入" 必须在同一个临界区内完成（防 TOCTOU）
//   - DELETE 操作必须幂等（删除不存在的资源返回 nil）
export class Vault {
  async getManifest() { throw new Error('not implemented'); }
  async putManifest(data, opts) { throw new Error('not implemented'); }
  async deleteManifest() { throw new Error('not implemented'); }
  async getBlob(hash) { throw new Error('not implemented'); }
  async putBlob(hash, data) { throw new Error('not implemented'); }
  async deleteBlob(hash) { throw new Error('not implemented'); }
  async listBlobs() { throw new Error('not implemented'); }

  // ── v2.2 通用资源层 ──
  // 语义等价于 WebDAV 的 GET / PUT / DELETE / MOVE / MKCOL / COPY / PROPFIND，
  // 但用纯 REST/JSON 表达（move/mkdir/copy/propfind 通过 POST + {op} 触发），
  // 从而兼容任意 HTTP client，不依赖 WebDAV 专有方法或头。
  // 全部操作都在 vault 命名空间内，服务端不解析 blob 内容（零知识不变）。
  async getResource(rel) { throw new Error('not implemented'); }
  async putResource(rel, data, opts) { throw new Error('not implemented'); }
  async deleteResource(rel) { throw new Error('not implemented'); }
  async moveResource(src, dst, overwrite) { throw new Error('not implemented'); }
  async copyResource(src, dst, overwrite) { throw new Error('not implemented'); }
  async mkCol(rel) { throw new Error('not implemented'); }
  async propFind(rel, depth) { throw new Error('not implemented'); }
}

// Storage 是存储后端的抽象接口
//
// 实现方可以是文件系统、数据库、对象存储等。
// newVault 创建或获取指定 vaultID 的存储句柄：
//   - 单用户场景使用 DefaultVaultID（"vault-default"）
//   - vaultID 必须通过 validateHash 校验（非空、不含路径分隔符等）
//   - 未来多 vault 场景下，每个 vaultID 对应一个独立的 Vault 实例，存储相互隔离
export class Storage {
  async newVault(vaultID) { throw new Error('not implemented'); }
}
