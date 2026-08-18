/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

// 文件系统存储实现
//
// 存储布局（rootDir 下）：
//
//	所有 vault 统一在 vaults/ 目录下按 vaultID 隔离：
//	  <rootDir>/vaults/<vaultID>/manifest     # manifest 密文
//	  <rootDir>/vaults/<vaultID>/blobs/<hash> # blob 密文
//	  <rootDir>/vaults/<vaultID>/blobs-orphan/<hash>.<epochMs>  # 孤儿 blob 隔离区（与 blobs/ 同级）
//
//	单用户场景使用 DefaultVaultID（"vault-default"）：
//	  <rootDir>/vaults/vault-default/manifest
//	  <rootDir>/vaults/vault-default/blobs/<hash>

'use strict';

import fs from 'fs';
import path from 'path';
import {
  Vault, Storage, PutOptions, validateHash, validateVaultPath, computeETag,
  ErrNotFound, ErrInvalidHash, ErrPreconditionFailed, ErrInvalidPath, ErrExists, ErrConflict,
  ResourceEntry,
} from './storage.js';

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

  // resolveResourcePath 解析 vault 内相对路径为绝对路径，并做路径穿越防护（允许子目录）
  //
  // 与 resolveBlobPath 不同：此处允许一段子目录（如 "blobs-orphan/<name>"），
  // 但仍强制最终路径停留在 dataDir 内。
  resolveResourcePath(rel) {
    if (!validateVaultPath(rel)) throw ErrInvalidPath;
    const dataDir = path.resolve(this.dataDir);
    const full = path.join(this.dataDir, rel);
    const absFull = path.resolve(full);
    // 验证最终路径仍在 dataDir 内（含 dataDir 自身）
    if (absFull !== dataDir && !absFull.startsWith(dataDir + path.sep)) {
      throw ErrInvalidPath;
    }
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
  // blob 操作（v2.2 起委托到通用资源层）
  // ──────────────────────────────────────────────

  // getBlob 读取指定 hash 的 blob 密文（委托到资源层 blobs/<hash>）
  async getBlob(hash) {
    return this.getResource('blobs/' + hash);
  }

  // putBlob 写入 blob（幂等，相同 hash 覆盖写；委托到资源层）
  async putBlob(hash, data) {
    return this.putResource('blobs/' + hash, data, new PutOptions());
  }

  // deleteBlob 删除 blob（幂等，不存在返回 nil；委托到资源层）
  async deleteBlob(hash) {
    return this.deleteResource('blobs/' + hash);
  }

  // listBlobs 列出所有 blob 的 hash
  //
  // 返回 blobs/ 目录下所有文件名（即 hash），跳过 .tmp 临时文件和子目录。
  // 注意：blobs-orphan/ 与 blobs/ 同级，天然不会进入此目录（孤儿 blob 由资源层
  // PropFind 单独管理）。blobs 目录不存在时返回空数组。
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

  // ──────────────────────────────────────────────
  // 通用资源层（v2.2，语义 = WebDAV 动词，纯 REST/JSON 表达）
  // ──────────────────────────────────────────────

  // getResource 读取任意 vault 内资源的字节内容
  async getResource(rel) {
    if (rel === 'manifest') return this.getManifest();
    const p = this.resolveResourcePath(rel);
    try {
      return await fs.promises.readFile(p);
    } catch (err) {
      if (err.code === 'ENOENT') throw ErrNotFound;
      throw err;
    }
  }

  // putResource 写入任意 vault 内资源（含可选乐观锁）
  //
  // rel == "manifest" 时复用 putManifest（带互斥锁与乐观锁）；
  // 其余资源做原子写入，若携带 If-Match/If-None-Match 则先做条件校验。
  async putResource(rel, data, opts) {
    if (rel === 'manifest') return this.putManifest(data, opts);
    const p = this.resolveResourcePath(rel);
    // 可选乐观锁（普通文件资源；blob 等不使用）
    if (opts.ifNoneMatch || opts.ifMatch) {
      try {
        const cur = await fs.promises.readFile(p);
        if (opts.ifNoneMatch) throw ErrPreconditionFailed;
        if (computeETag(cur) !== `"${opts.ifMatch}"`) throw ErrPreconditionFailed;
      } catch (err) {
        if (err === ErrPreconditionFailed) throw err;
        if (err.code !== 'ENOENT') throw err;
        // 文件不存在：If-None-Match 通过；If-Match 应失败
        if (opts.ifMatch) throw ErrPreconditionFailed;
      }
    }
    await atomicWrite(p, data);
  }

  // deleteResource 删除任意 vault 内资源（幂等）
  async deleteResource(rel) {
    if (rel === 'manifest') return this.deleteManifest();
    const p = this.resolveResourcePath(rel);
    try {
      await fs.promises.unlink(p);
    } catch (err) {
      if (err.code === 'ENOENT') return; // 幂等
      throw err;
    }
  }

  // moveResource 移动/重命名资源（等价 WebDAV MOVE）
  //
  // src 为 URL 路径，dst 为请求体中的 vault 相对目标路径。
  // overwrite=false 且目标存在时返回 ErrConflict（409）。
  // 若 src 或 dst 为 manifest，则在整个操作期间持有 manifest 互斥锁。
  async moveResource(src, dst, overwrite) {
    if (src === 'manifest' || dst === 'manifest') {
      return this.withLock(() => this.moveResourceLocked(src, dst, overwrite));
    }
    return this.moveResourceLocked(src, dst, overwrite);
  }

  async moveResourceLocked(src, dst, overwrite) {
    const sp = this.resolveResourcePath(src);
    const dp = this.resolveResourcePath(dst);
    let fi;
    try {
      fi = await fs.promises.stat(dp);
    } catch (err) {
      if (err.code !== 'ENOENT') throw err;
      fi = null;
    }
    if (fi) {
      if (!overwrite) throw ErrConflict;
      if (fi.isDirectory()) throw ErrConflict;
    }
    // 确保目标父目录存在
    await fs.promises.mkdir(path.dirname(dp), { recursive: true });
    try {
      // 同设备直接 rename（O(1)）；失败退化 copy+delete
      await fs.promises.rename(sp, dp);
    } catch (err) {
      const data = await fs.promises.readFile(sp);
      await atomicWrite(dp, data);
      await fs.promises.unlink(sp);
    }
  }

  // copyResource 复制资源（等价 WebDAV COPY）
  //
  // overwrite=false 且目标存在时返回 ErrConflict（409）。
  async copyResource(src, dst, overwrite) {
    if (src === 'manifest' || dst === 'manifest') {
      return this.withLock(() => this.copyResourceLocked(src, dst, overwrite));
    }
    return this.copyResourceLocked(src, dst, overwrite);
  }

  async copyResourceLocked(src, dst, overwrite) {
    const sp = this.resolveResourcePath(src);
    const dp = this.resolveResourcePath(dst);
    let fi;
    try {
      fi = await fs.promises.stat(dp);
    } catch (err) {
      if (err.code !== 'ENOENT') throw err;
      fi = null;
    }
    if (fi) {
      if (!overwrite) throw ErrConflict;
      if (fi.isDirectory()) throw ErrConflict;
    }
    await fs.promises.mkdir(path.dirname(dp), { recursive: true });
    const data = await fs.promises.readFile(sp);
    await atomicWrite(dp, data);
  }

  // mkCol 创建集合（目录，等价 WebDAV MKCOL）
  //
  // 目标已存在（文件或目录）返回 ErrExists（映射 405，客户端忽略）；
  // 父目录不存在返回 ErrConflict（映射 409）。
  async mkCol(rel) {
    const p = this.resolveResourcePath(rel);
    let fi;
    try {
      fi = await fs.promises.stat(p);
    } catch (err) {
      if (err.code !== 'ENOENT') throw err;
      fi = null;
    }
    if (fi) throw ErrExists; // 已存在
    // 父目录必须存在（RFC 4918 §9.3）
    const parent = path.dirname(p);
    let pfi;
    try {
      pfi = await fs.promises.stat(parent);
    } catch (err) {
      if (err.code === 'ENOENT') throw ErrConflict;
      throw err;
    }
    if (!pfi.isDirectory()) throw ErrInvalidPath;
    try {
      await fs.promises.mkdir(p);
    } catch (err) {
      if (err.code === 'EEXIST') throw ErrExists;
      throw err;
    }
  }

  // propFind 列出资源元数据（等价 WebDAV PROPFIND）
  //
  // depth=0：返回单个资源（文件或目录自身）的元数据（stats）；
  // depth>=1：返回集合本身 + 其直接子项（list）。
  // 返回 JSON 友好的 ResourceEntry 数组，不解析 blob 内容（零知识不变）。
  async propFind(rel, depth) {
    const p = this.resolveResourcePath(rel);
    let fi;
    try {
      fi = await fs.promises.stat(p);
    } catch (err) {
      if (err.code === 'ENOENT') throw ErrNotFound;
      throw err;
    }
    if (fi.isDirectory()) {
      const entries = [resourceEntry(rel, fi, '')];
      if (depth >= 1) {
        const children = await fs.promises.readdir(p, { withFileTypes: true });
        // 子项按名字排序，保证结果稳定
        children.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
        for (const c of children) {
          const cp = rel + '/' + c.name;
          let cfi;
          try {
            cfi = await fs.promises.stat(path.join(p, c.name));
          } catch {
            continue;
          }
          entries.push(resourceEntry(cp, cfi, ''));
        }
      }
      return entries;
    }
    // 单个文件：depth=0 时计算 ETag（供条件请求）；depth>=1 仅单文件也只返回自身
    let etag = '';
    if (depth === 0) {
      const data = await fs.promises.readFile(p);
      etag = computeETag(data);
    }
    return [resourceEntry(rel, fi, etag)];
  }
}

// resourceEntry 构造 ResourceEntry（name 取路径最后一段）
function resourceEntry(rel, fi, etag) {
  let name = rel;
  const idx = rel.lastIndexOf('/');
  if (idx >= 0) name = rel.slice(idx + 1);
  return new ResourceEntry({
    name,
    path: rel,
    isDir: fi.isDirectory(),
    size: fi.size,
    modTime: fi.mtimeMs !== undefined ? Math.round(fi.mtimeMs) : Math.round(fi.mtime.getTime()),
    etag,
  });
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
