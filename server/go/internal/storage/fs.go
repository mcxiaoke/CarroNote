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
package storage

import (
	"os"
	"path/filepath"
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

// resolveBlobPath 解析 blob hash 为绝对路径，并做路径穿越防护
func (v *fsVault) resolveBlobPath(hash string) (string, error) {
	if err := ValidateHash(hash); err != nil {
		return "", err
	}
	blobsDir := v.blobsDir()
	// filepath.Clean("/"+hash) 防止 hash 中含特殊字符
	full := filepath.Join(blobsDir, filepath.Clean("/"+hash))
	absBlobs, _ := filepath.Abs(blobsDir)
	absFull, _ := filepath.Abs(full)
	// 验证最终路径仍在 blobs 目录下
	if !strings.HasPrefix(absFull, absBlobs) {
		return "", ErrInvalidHash
	}
	return absFull, nil
}

// ──────────────────────────────────────────────
// manifest 操作
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
// blob 操作
// ──────────────────────────────────────────────

// GetBlob 读取指定 hash 的 blob 密文
func (v *fsVault) GetBlob(hash string) ([]byte, error) {
	path, err := v.resolveBlobPath(hash)
	if err != nil {
		return nil, err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return data, nil
}

// PutBlob 写入 blob（幂等，相同 hash 覆盖写）
func (v *fsVault) PutBlob(hash string, data []byte) error {
	path, err := v.resolveBlobPath(hash)
	if err != nil {
		return err
	}
	return atomicWrite(path, data, 0o644)
}

// DeleteBlob 删除 blob（幂等，不存在返回 nil）
func (v *fsVault) DeleteBlob(hash string) error {
	path, err := v.resolveBlobPath(hash)
	if err != nil {
		return err
	}
	err = os.Remove(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil // 幂等
		}
		return err
	}
	return nil
}

// ListBlobs 列出所有 blob 的 hash
//
// 返回 blobs/ 目录下所有文件名（即 hash），跳过 .tmp 临时文件和子目录。
// blobs 目录不存在时返回空数组。
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
	tmpPath := path + ".tmp"

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
