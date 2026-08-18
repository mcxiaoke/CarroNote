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
//	  <rootDir>/vaults/<vaultID>/manifest          # manifest 密文
//	  <rootDir>/vaults/<vaultID>/blobs/<hash>       # blob 密文
//	  <rootDir>/vaults/<vaultID>/blobs-orphan/...   # 孤儿 blob 隔离区（v2.2 资源层使用）
//
//	单用户场景使用 DefaultVaultID（"vault-default"）：
//	  <rootDir>/vaults/vault-default/manifest
//	  <rootDir>/vaults/vault-default/blobs/<hash>
package storage

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
)

// FileSystemStorage 是基于文件系统的 Storage 实现
type FileSystemStorage struct {
	rootDir string
}

// NewFileSystem 创建文件系统存储
// 会确保 rootDir 存在。
func NewFileSystem(rootDir string) (*FileSystemStorage, error) {
	if err := os.MkdirAll(rootDir, 0o755); err != nil {
		return nil, err
	}
	return &FileSystemStorage{rootDir: rootDir}, nil
}

// NewVault 创建或获取指定 vaultID 的存储句柄
//
// vaultID 必须通过 ValidateHash 校验（非空、不含路径分隔符等）。
// 单用户场景使用 storage.DefaultVaultID。
func (s *FileSystemStorage) NewVault(vaultID string) (Vault, error) {
	if err := ValidateHash(vaultID); err != nil {
		return nil, ErrInvalidHash
	}
	vaultDir := filepath.Join(s.rootDir, "vaults", vaultID)
	if err := os.MkdirAll(vaultDir, 0o755); err != nil {
		return nil, err
	}
	return &fsVault{dataDir: vaultDir}, nil
}

// fsVault 是基于文件系统的 Vault 实现
type fsVault struct {
	dataDir string
	mu      sync.Mutex // manifest 操作互斥锁（PUT/DELETE 串行化，防 TOCTOU）
}

// manifestPath 返回 manifest 文件路径
func (v *fsVault) manifestPath() string {
	return filepath.Join(v.dataDir, "manifest")
}

// blobsDir 返回 blob 存储目录
func (v *fsVault) blobsDir() string {
	return filepath.Join(v.dataDir, "blobs")
}

// resolveResourcePath 解析 vault 内相对路径为绝对路径，并做路径穿越防护（允许子目录）
//
// 与旧的 resolveBlobPath 不同：此处允许一段子目录（如 "blobs-orphan/<name>"），
// 但仍强制最终路径停留在 dataDir 内。
func (v *fsVault) resolveResourcePath(rel string) (string, error) {
	if err := ValidateVaultPath(rel); err != nil {
		return "", err
	}
	dataDir, _ := filepath.Abs(v.dataDir)
	full := filepath.Join(v.dataDir, rel)
	absFull, _ := filepath.Abs(full)
	// 验证最终路径仍在 dataDir 内（含 dataDir 自身）
	if absFull != dataDir && !strings.HasPrefix(absFull, dataDir+string(os.PathSeparator)) {
		return "", ErrInvalidPath
	}
	return absFull, nil
}

// ──────────────────────────────────────────────
// manifest 操作（权威实现，资源层对 "manifest" 路径复用此处）
// ──────────────────────────────────────────────

// GetManifest 读取 manifest 密文
func (v *fsVault) GetManifest() ([]byte, error) {
	data, err := os.ReadFile(v.manifestPath())
	if err != nil {
		if os.IsNotExist(err) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return data, nil
}

// PutManifest 写入 manifest（含乐观锁校验 + 原子写入）
//
// "校验乐观锁条件 + 写入" 在同一个临界区内完成，防 TOCTOU 竞争。
func (v *fsVault) PutManifest(data []byte, opts PutOptions) error {
	v.mu.Lock()
	defer v.mu.Unlock()

	// 在锁内读取当前 manifest（避免使用锁外读到的过期数据）
	existing, err := os.ReadFile(v.manifestPath())
	exists := err == nil

	// 乐观锁校验
	if opts.IfNoneMatch {
		// 首次上传：远端必须不存在
		if exists {
			return ErrPreconditionFailed
		}
	} else if opts.IfMatch != "" {
		// 乐观锁：远端 ETag 必须匹配
		if !exists {
			return ErrPreconditionFailed
		}
		currentEtag := ComputeETag(existing)
		if currentEtag != `"`+opts.IfMatch+`"` {
			return ErrPreconditionFailed
		}
	}

	// 原子写入（tmp + fsync + rename）
	return atomicWrite(v.manifestPath(), data, 0o644)
}

// DeleteManifest 删除 manifest（幂等，不存在返回 nil）
func (v *fsVault) DeleteManifest() error {
	v.mu.Lock()
	defer v.mu.Unlock()
	err := os.Remove(v.manifestPath())
	if err != nil {
		if os.IsNotExist(err) {
			return nil // 幂等
		}
		return err
	}
	return nil
}

// ──────────────────────────────────────────────
// blob 操作（v2.2 起委托到通用资源层）
// ──────────────────────────────────────────────

// GetBlob 读取指定 hash 的 blob 密文（委托到资源层 blobs/<hash>）
func (v *fsVault) GetBlob(hash string) ([]byte, error) {
	return v.GetResource("blobs/" + hash)
}

// PutBlob 写入 blob（幂等，相同 hash 覆盖写；委托到资源层）
func (v *fsVault) PutBlob(hash string, data []byte) error {
	return v.PutResource("blobs/"+hash, data, PutOptions{})
}

// DeleteBlob 删除 blob（幂等，不存在返回 nil；委托到资源层）
func (v *fsVault) DeleteBlob(hash string) error {
	return v.DeleteResource("blobs/" + hash)
}

// ListBlobs 列出所有 blob 的 hash
//
// 返回 blobs/ 目录下所有文件名（即 hash），跳过 .tmp 临时文件和子目录。
// 注意：blobs-orphan/ 与 blobs/ 同级，天然不会进入此目录（孤儿 blob 由资源层
// PropFind 单独管理）。blobs 目录不存在时返回空数组。
func (v *fsVault) ListBlobs() ([]string, error) {
	entries, err := os.ReadDir(v.blobsDir())
	if err != nil {
		if os.IsNotExist(err) {
			return []string{}, nil
		}
		return nil, err
	}
	hashes := []string{}
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		name := entry.Name()
		// 跳过原子写入产生的临时文件
		if strings.HasSuffix(name, ".tmp") {
			continue
		}
		hashes = append(hashes, name)
	}
	return hashes, nil
}

// ──────────────────────────────────────────────
// 通用资源层（v2.2，语义 = WebDAV 动词，纯 REST/JSON 表达）
// ──────────────────────────────────────────────

// GetResource 读取任意 vault 内资源的字节内容
func (v *fsVault) GetResource(rel string) ([]byte, error) {
	if rel == "manifest" {
		return v.GetManifest()
	}
	p, err := v.resolveResourcePath(rel)
	if err != nil {
		return nil, err
	}
	data, err := os.ReadFile(p)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return data, nil
}

// PutResource 写入任意 vault 内资源（含可选乐观锁）
//
// rel == "manifest" 时复用 PutManifest（带互斥锁与乐观锁）；
// 其余资源做原子写入，若携带 If-Match/If-None-Match 则先做条件校验。
func (v *fsVault) PutResource(rel string, data []byte, opts PutOptions) error {
	if rel == "manifest" {
		return v.PutManifest(data, opts)
	}
	p, err := v.resolveResourcePath(rel)
	if err != nil {
		return err
	}
	// 可选乐观锁（普通文件资源；blob 等不使用）
	if opts.IfNoneMatch || opts.IfMatch != "" {
		if _, statErr := os.Stat(p); statErr == nil {
			if opts.IfNoneMatch {
				return ErrPreconditionFailed
			}
			if opts.IfMatch != "" {
				cur, rerr := os.ReadFile(p)
				if rerr != nil {
					return ErrPreconditionFailed
				}
				if ComputeETag(cur) != `"`+opts.IfMatch+`"` {
					return ErrPreconditionFailed
				}
			}
		} else if os.IsNotExist(statErr) {
			if opts.IfMatch != "" {
				return ErrPreconditionFailed
			}
			// IfNoneMatch 且不存在 → 通过
		} else {
			return statErr
		}
	}
	return atomicWrite(p, data, 0o644)
}

// DeleteResource 删除任意 vault 内资源（幂等）
func (v *fsVault) DeleteResource(rel string) error {
	if rel == "manifest" {
		return v.DeleteManifest()
	}
	p, err := v.resolveResourcePath(rel)
	if err != nil {
		return err
	}
	if err := os.Remove(p); err != nil {
		if os.IsNotExist(err) {
			return nil // 幂等
		}
		return err
	}
	return nil
}

// MoveResource 移动/重命名资源（等价 WebDAV MOVE）
//
// src 为 URL 路径，dst 为请求体中的 vault 相对目标路径。
// overwrite=false 且目标存在时返回 ErrConflict（409）。
// 若 src 或 dst 为 manifest，则在整个操作期间持有 manifest 互斥锁。
func (v *fsVault) MoveResource(src, dst string, overwrite bool) error {
	if src == "manifest" || dst == "manifest" {
		v.mu.Lock()
		defer v.mu.Unlock()
	}
	return v.moveResourceLocked(src, dst, overwrite)
}

func (v *fsVault) moveResourceLocked(src, dst string, overwrite bool) error {
	sp, err := v.resolveResourcePath(src)
	if err != nil {
		return err
	}
	dp, err := v.resolveResourcePath(dst)
	if err != nil {
		return err
	}
	if fi, statErr := os.Stat(dp); statErr == nil {
		if !overwrite {
			return ErrConflict
		}
		if fi.IsDir() {
			return ErrConflict
		}
	} else if !os.IsNotExist(statErr) {
		return statErr
	}
	// 确保目标父目录存在
	if err := os.MkdirAll(filepath.Dir(dp), 0o755); err != nil {
		return err
	}
	// 同设备直接 rename（O(1)）；跨设备退化 copy+delete
	if err := os.Rename(sp, dp); err != nil {
		data, rerr := os.ReadFile(sp)
		if rerr != nil {
			return rerr
		}
		if werr := atomicWrite(dp, data, 0o644); werr != nil {
			return werr
		}
		if rerr2 := os.Remove(sp); rerr2 != nil {
			return rerr2
		}
	}
	return nil
}

// CopyResource 复制资源（等价 WebDAV COPY）
//
// overwrite=false 且目标存在时返回 ErrConflict（409）。
func (v *fsVault) CopyResource(src, dst string, overwrite bool) error {
	if src == "manifest" || dst == "manifest" {
		v.mu.Lock()
		defer v.mu.Unlock()
	}
	sp, err := v.resolveResourcePath(src)
	if err != nil {
		return err
	}
	dp, err := v.resolveResourcePath(dst)
	if err != nil {
		return err
	}
	if fi, statErr := os.Stat(dp); statErr == nil {
		if !overwrite {
			return ErrConflict
		}
		if fi.IsDir() {
			return ErrConflict
		}
	} else if !os.IsNotExist(statErr) {
		return statErr
	}
	if err := os.MkdirAll(filepath.Dir(dp), 0o755); err != nil {
		return err
	}
	data, err := os.ReadFile(sp)
	if err != nil {
		return err
	}
	return atomicWrite(dp, data, 0o644)
}

// MkCol 创建集合（目录，等价 WebDAV MKCOL）
//
// 目标已存在（文件或目录）返回 ErrExists（映射 405，客户端忽略）；
// 父目录不存在返回 ErrConflict（映射 409）。
func (v *fsVault) MkCol(rel string) error {
	p, err := v.resolveResourcePath(rel)
	if err != nil {
		return err
	}
	if _, statErr := os.Stat(p); statErr == nil {
		return ErrExists // 已存在
	} else if !os.IsNotExist(statErr) {
		return statErr
	}
	// 父目录必须存在（RFC 4918 §9.3）
	parent := filepath.Dir(p)
	if fi, perr := os.Stat(parent); perr != nil {
		if os.IsNotExist(perr) {
			return ErrConflict
		}
		return perr
	} else if !fi.IsDir() {
		return ErrInvalidPath
	}
	if err := os.Mkdir(p, 0o755); err != nil {
		if os.IsExist(err) {
			return ErrExists
		}
		return err
	}
	return nil
}

// PropFind 列出资源元数据（等价 WebDAV PROPFIND）
//
// depth=0：返回单个资源（文件或目录自身）的元数据（stats）；
// depth>=1：返回集合本身 + 其直接子项（list）。
// 返回 JSON 友好的 ResourceEntry 数组，不解析 blob 内容（零知识不变）。
func (v *fsVault) PropFind(rel string, depth int) ([]ResourceEntry, error) {
	p, err := v.resolveResourcePath(rel)
	if err != nil {
		return nil, err
	}
	fi, err := os.Stat(p)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	if fi.IsDir() {
		entries := []ResourceEntry{resourceEntry(rel, fi, "")}
		if depth >= 1 {
			children, derr := os.ReadDir(p)
			if derr != nil {
				return nil, derr
			}
			// 子项按名字排序，保证结果稳定
			sort.Slice(children, func(i, j int) bool { return children[i].Name() < children[j].Name() })
			for _, c := range children {
				cp := rel + "/" + c.Name()
				cfi, cerr := os.Stat(filepath.Join(p, c.Name()))
				if cerr != nil {
					continue
				}
				entries = append(entries, resourceEntry(cp, cfi, ""))
			}
		}
		return entries, nil
	}
	// 单个文件：depth=0 时计算 ETag（供条件请求）；depth>=1 仅单文件也只返回自身
	var etag string
	if depth == 0 {
		if data, rerr := os.ReadFile(p); rerr == nil {
			etag = ComputeETag(data)
		}
	}
	return []ResourceEntry{resourceEntry(rel, fi, etag)}, nil
}

// resourceEntry 构造 ResourceEntry（name 取路径最后一段）
func resourceEntry(rel string, fi os.FileInfo, etag string) ResourceEntry {
	name := rel
	if idx := strings.LastIndex(rel, "/"); idx >= 0 {
		name = rel[idx+1:]
	}
	return ResourceEntry{
		Name:    name,
		Path:    rel,
		IsDir:   fi.IsDir(),
		Size:    fi.Size(),
		ModTime: fi.ModTime().UnixMilli(),
		ETag:    etag,
	}
}

// ──────────────────────────────────────────────
// 原子写入工具
// ──────────────────────────────────────────────

// atomicWrite 原子写入文件：tmp + fsync + rename
//
// 步骤：
//  1. 写入临时文件（同目录，.tmp 后缀）
//  2. fsync 临时文件（确保数据落盘，防断电半写）
//  3. rename 临时文件为目标路径（同目录下 rename 是原子的）
//
// 任何步骤失败都会清理临时文件，不影响已有数据。
// 这是规范 §9.3 的强制要求。
func atomicWrite(path string, data []byte, perm os.FileMode) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	// 修复 C-3：临时文件名加随机后缀，保证并发写入同一目标（如同 hash 的 blob 重试）
	// 各自使用独立临时文件，O_TRUNC 不会相互截断，rename 也不会互相覆盖。
	buf := make([]byte, 8)
	if _, err := rand.Read(buf); err != nil {
		return err
	}
	tmpPath := fmt.Sprintf("%s.%s.tmp", path, hex.EncodeToString(buf))

	f, err := os.OpenFile(tmpPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, perm)
	if err != nil {
		return err
	}

	// 写入失败时清理临时文件
	cleanup := func() { os.Remove(tmpPath) }

	if _, err := f.Write(data); err != nil {
		f.Close()
		cleanup()
		return err
	}
	// fsync 确保数据落盘（防断电导致 rename 后看到空文件或半写文件）
	if err := f.Sync(); err != nil {
		f.Close()
		cleanup()
		return err
	}
	if err := f.Close(); err != nil {
		cleanup()
		return err
	}
	// rename 是原子的（POSIX 保证；Windows MoveFileEx 也支持）
	if err := os.Rename(tmpPath, path); err != nil {
		cleanup()
		return err
	}
	return nil
}
