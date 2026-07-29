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

// Vault 表示一个同步保险库的存储操作句柄
//
// 单用户场景下只有一个默认 Vault（vaultID=""）；
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
