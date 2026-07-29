// Package storage 定义存储后端的抽象接口
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
package storage

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"strings"
)

// DefaultVaultID 是单用户场景下使用的默认 vault ID
//
// 不再用空字符串 ""，这样：
//   - 文件系统实现中所有 vault 都统一在 <rootDir>/vaults/<vaultID>/ 下，不污染根目录
//   - 数据库实现中 vaultID 可直接用作表名前缀或分区键，无需特判空值
//   - 存储布局一致，便于管理和扩展
const DefaultVaultID = "vault-default"

// 哨兵错误
var (
	// ErrNotFound 资源不存在（GET manifest/blob 时文件缺失）
	ErrNotFound = errors.New("not found")
	// ErrInvalidHash blob hash 格式非法（含路径分隔符、.. 或 NUL 字节）
	ErrInvalidHash = errors.New("invalid hash")
	// ErrPreconditionFailed 乐观锁条件不满足（If-Match / If-None-Match 校验失败）
	ErrPreconditionFailed = errors.New("precondition failed")
)

// PutOptions 是 PUT manifest 的乐观锁参数
type PutOptions struct {
	// IfNoneMatch 为 true 时要求资源不存在（首次上传）
	IfNoneMatch bool
	// IfMatch 非空时要求当前 ETag 匹配此值（不带引号）
	IfMatch string
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
type Vault interface {
	GetManifest() ([]byte, error)
	PutManifest(data []byte, opts PutOptions) error
	DeleteManifest() error

	GetBlob(hash string) ([]byte, error)
	PutBlob(hash string, data []byte) error
	DeleteBlob(hash string) error
	ListBlobs() ([]string, error)
}

// Storage 是存储后端的抽象接口
//
// 实现方可以是文件系统、数据库、对象存储等。
// NewVault 创建或获取指定 vaultID 的存储句柄：
//   - 单用户场景使用 storage.DefaultVaultID（"vault-default"）
//   - vaultID 必须通过 ValidateHash 校验（非空、不含路径分隔符等）
//   - 未来多 vault 场景下，每个 vaultID 对应一个独立的 Vault 实例，存储相互隔离
//
// 扩展示例：
//   - 文件系统：vaultID="vault-default" → <rootDir>/vaults/vault-default/
//   - 数据库：vaultID 用作表名前缀或分区键（如 manifest_vault_default）
//   - 对象存储：vaultID 用作 bucket 或 key 前缀
type Storage interface {
	NewVault(vaultID string) (Vault, error)
}

// ValidateHash 校验 blob hash 是否合法（防路径穿越）
//
// 拒绝：空 hash、含路径分隔符（/ \）、含 .. 、含 NUL 字节。
// 这是安全红线，缺失会导致目录穿越漏洞。
func ValidateHash(hash string) error {
	if hash == "" {
		return ErrInvalidHash
	}
	if strings.ContainsAny(hash, "/\\") {
		return ErrInvalidHash
	}
	if strings.Contains(hash, "..") {
		return ErrInvalidHash
	}
	if strings.ContainsRune(hash, 0) {
		return ErrInvalidHash
	}
	return nil
}

// ComputeETag 计算内容的 SHA-256 作为强 ETag（带引号）
//
// ETag 是密文的衍生物，不泄露明文信息。
// 格式："<64位十六进制 sha256>"
func ComputeETag(data []byte) string {
	h := sha256.Sum256(data)
	return `"` + hex.EncodeToString(h[:]) + `"`
}
