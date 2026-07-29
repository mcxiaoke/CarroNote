// 文件系统存储实现
//
// 存储布局（rootDir 下）：
//
//	所有 vault 统一在 vaults/ 目录下按 vaultID 隔离：
//	  <rootDir>/vaults/<vaultID>/manifest     # manifest 密文
//	  <rootDir>/vaults/<vaultID>/blobs/<hash> # blob 密文
//
//	单用户场景使用 DefaultVaultID（"vault-default"）：
//	  <rootDir>/vaults/vault-default/manifest
//	  <rootDir>/vaults/vault-default/blobs/<hash>

'use strict';

import fs from 'fs';
import path from 'path';
import { Vault, Storage, validateHash, computeETag, ErrNotFound, ErrInvalidHash, ErrPreconditionFailed } from './storage.js';

// FileSystemStorage 是基于文件系统的 Storage 实现
export class FileSystemStorage extends Storage {
  constructor(rootDir) {
    super();
    this.rootDir = rootDir;
    fs.mkdirSync(rootDir, { recursive: true });
  }

  // newVault 创建或获取指定 vaultID 的存储句柄
  //
  // vaultID 必须通过 validateHash 校验（非空、不含路径分隔符等）。
  // 单用户场景使用 DefaultVaultID。
  async newVault(vaultID) {
    if (!validateHash(vaultID)) return Promise.reject(ErrInvalidHash);
    const vaultDir = path.join(this.rootDir, 'vaults', vaultID);
    fs.mkdirSync(vaultDir, { recursive: true });
    return new FsVault(vaultDir);
  }
}

// FsVault 是基于文件系统的 Vault 实现
class FsVault extends Vault {
  constructor(dataDir) {
    super();
    this.dataDir = dataDir;
    this.manifestLock = Promise.resolve();
  }

  // manifest 操作串行化（PUT/DELETE 串行化，防 TOCTOU）
  withLock(fn) {
    const next = this.manifestLock.then(fn, fn);
    this.manifestLock = next.catch(() => {});
    return next;
  }

  manifestPath() { return path.join(this.dataDir, 'manifest'); }
  blobsDir() { return path.join(this.dataDir, 'blobs'); }

  // 解析 blob hash 为绝对路径，并做路径穿越防护
  resolveBlobPath(hash) {
    if (!validateHash(hash)) return null;
    const full = path.join(this.blobsDir(), hash);
    const absBlobs = path.resolve(this.blobsDir());
    const absFull = path.resolve(full);
    if (!absFull.startsWith(absBlobs)) return null;
    return absFull;
  }

  // ──────────────────────────────────────────────
  // manifest 操作
  // ──────────────────────────────────────────────

  async getManifest() {
    try {
      return await fs.promises.readFile(this.manifestPath());
    } catch (err) {
      if (err.code === 'ENOENT') throw ErrNotFound;
      throw err;
    }
  }

  // putManifest 写入 manifest（含乐观锁校验 + 原子写入）
  //
  // "校验乐观锁条件 + 写入" 在同一个临界区内完成，防 TOCTOU 竞争。
  async putManifest(data, opts) {
    return this.withLock(async () => {
      let existing = null;
      try {
        existing = await fs.promises.readFile(this.manifestPath());
      } catch (err) {
        if (err.code !== 'ENOENT') throw err;
      }
      const exists = existing !== null;

      // 乐观锁校验
      if (opts.ifNoneMatch) {
        if (exists) throw ErrPreconditionFailed;
      } else if (opts.ifMatch) {
        if (!exists) throw ErrPreconditionFailed;
        const currentEtag = computeETag(existing);
        if (currentEtag !== `"${opts.ifMatch}"`) throw ErrPreconditionFailed;
      }

      // 原子写入（tmp + fsync + rename）
      await atomicWrite(this.manifestPath(), data);
    });
  }

  async deleteManifest() {
    return this.withLock(async () => {
      try {
        await fs.promises.unlink(this.manifestPath());
      } catch (err) {
        if (err.code === 'ENOENT') return; // 幂等
        throw err;
      }
    });
  }

  // ──────────────────────────────────────────────
  // blob 操作
  // ──────────────────────────────────────────────

  async getBlob(hash) {
    const p = this.resolveBlobPath(hash);
    if (!p) throw ErrInvalidHash;
    try {
      return await fs.promises.readFile(p);
    } catch (err) {
      if (err.code === 'ENOENT') throw ErrNotFound;
      throw err;
    }
  }

  async putBlob(hash, data) {
    const p = this.resolveBlobPath(hash);
    if (!p) throw ErrInvalidHash;
    await atomicWrite(p, data);
  }

  async deleteBlob(hash) {
    const p = this.resolveBlobPath(hash);
    if (!p) throw ErrInvalidHash;
    try {
      await fs.promises.unlink(p);
    } catch (err) {
      if (err.code === 'ENOENT') return; // 幂等
      throw err;
    }
  }

  // listBlobs 列出所有 blob 的 hash
  //
  // 返回 blobs/ 目录下所有文件名（即 hash），跳过 .tmp 临时文件和子目录。
  async listBlobs() {
    try {
      const entries = await fs.promises.readdir(this.blobsDir(), { withFileTypes: true });
      const hashes = [];
      for (const entry of entries) {
        if (!entry.isFile()) continue;
        if (entry.name.endsWith('.tmp')) continue;
        hashes.push(entry.name);
      }
      return hashes;
    } catch (err) {
      if (err.code === 'ENOENT') return [];
      throw err;
    }
  }
}

// atomicWrite 原子写入文件：tmp + fsync + rename
//
// 步骤：
//  1. 写入临时文件（同目录，.tmp 后缀）
//  2. fsync 临时文件（确保数据落盘，防断电半写）
//  3. rename 临时文件为目标路径（同目录下 rename 是原子的）
//
// 任何步骤失败都会清理临时文件，不影响已有数据。
// 使用同步 API 避免 promise 链问题（fsync 在 Windows 上可能不稳定）。
async function atomicWrite(filePath, data) {
  const dir = path.dirname(filePath);
  const tmpPath = filePath + '.tmp';
  await fs.promises.mkdir(dir, { recursive: true });
  try {
    // 写入 + fsync + 关闭（用同步 API 保证 fsync 执行）
    const fd = fs.openSync(tmpPath, 'w');
    try {
      fs.writeSync(fd, data);
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }
    // rename 是原子的（POSIX 保证；Windows MoveFileEx 也支持）
    await fs.promises.rename(tmpPath, filePath);
  } catch (err) {
    try { fs.unlinkSync(tmpPath); } catch {}
    throw err;
  }
}
