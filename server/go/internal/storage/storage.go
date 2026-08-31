/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

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
	"path/filepath"
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
	// ErrInvalidPath 资源路径非法（空路径 / 绝对路径 / 含 .. 逃逸 / 含 NUL 等）
	ErrInvalidPath = errors.New("invalid path")
	// ErrExists 资源已存在（MKCOL 目标已存在，映射为 405）
	ErrExists = errors.New("already exists")
	// ErrConflict 目标已存在且 overwrite=false（MOVE/COPY 冲突，映射为 409）
	ErrConflict = errors.New("conflict")
)

// PutOptions 是 PUT 资源的乐观锁参数（manifest 与通用资源层共用）
type PutOptions struct {
	// IfNoneMatch 为 true 时要求资源不存在（首次上传）
	IfNoneMatch bool
	// IfMatch 非空时要求当前 ETag 匹配此值（不带引号）
	IfMatch string
}

// ResourceEntry 是 PropFind 返回的单个资源元数据
//
// 等价于 WebDAV PROPFIND 的属性集合（getcontentlength / getlastmodified / resourcetype），
// 但以普通 JSON 返回，避免 XML 解析。
type ResourceEntry struct {
	Name    string `json:"name"`              // 资源名（路径最后一段）
	Path    string `json:"path"`              // vault 内相对路径
	IsDir   bool   `json:"isDir"`             // 是否为目录
	Size    int64  `json:"size"`              // 文件大小（字节），目录为 0
	ModTime int64  `json:"modTime"`           // 最后修改时间（Unix 毫秒）
	ETag    string `json:"etag,omitempty"`    // 文件内容的强 ETag（目录为空）
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
type Vault interface {
	GetManifest() ([]byte, error)
	PutManifest(data []byte, opts PutOptions) error
	DeleteManifest() error

	GetBlob(hash string) ([]byte, error)
	PutBlob(hash string, data []byte) error
	DeleteBlob(hash string) error
	ListBlobs() ([]string, error)

	// ── v2.2 通用资源层 ──
	// 语义等价于 WebDAV 的 GET / PUT / DELETE / MOVE / MKCOL / COPY / PROPFIND，
	// 但用纯 REST/JSON 表达（move/mkdir/copy/propfind 通过 POST + {op} 触发），
	// 从而兼容任意 HTTP client，不依赖 WebDAV 专有方法或头。
	// 全部操作都在 vault 命名空间内，服务端不解析 blob 内容（零知识不变）。
	GetResource(rel string) ([]byte, error)
	PutResource(rel string, data []byte, opts PutOptions) error
	DeleteResource(rel string) error
	MoveResource(src, dst string, overwrite bool) error
	CopyResource(src, dst string, overwrite bool) error
	MkCol(rel string) error
	PropFind(rel string, depth int) ([]ResourceEntry, error)
}

// Storage 是存储后端的抽象接口
//
// 实现方可以是文件系统、数据库、对象存储等。
// NewVault 创建或获取指定 vaultID 的存储句柄：
//   - 单用户场景使用 storage.DefaultVaultID（"vault-default"）
//   - vaultID 必须通过 ValidateHash 校验（非空、不含路径分隔符等）
//   - 未来多 vault 场景下，每个 vaultID 对应一个独立的 Vault 实例，存储相互隔离
type Storage interface {
	NewVault(vaultID string) (Vault, error)
}

// ValidateHash 校验 blob hash 是否合法（防路径穿越）
//
// 拒绝：空 hash、含路径分隔符（/ \）、含 .. 、含 NUL 字节、含冒号（Windows ADS）。
// 这是安全红线，缺失会导致目录穿越漏洞。
func ValidateHash(hash string) error {
	if hash == "" {
		return ErrInvalidHash
	}
	if strings.ContainsAny(hash, "/\\:") {
		return ErrInvalidHash
	}
	if strings.Contains(hash, "..") {
		return ErrInvalidHash
	}
	if strings.ContainsRune(hash, 0) {
		return ErrInvalidHash
	}
	if isWindowsReservedName(hash) {
		return ErrInvalidHash
	}
	return nil
}

// ValidateVaultPath 校验 vault 内相对路径是否合法（允许子目录，禁止路径穿越）
//
// 与 ValidateHash 的区别：允许一个相对子目录（如 "blobs-orphan/<hash>.<ts>"），
// 但仍禁止绝对路径、空路径、含 NUL 字节、含冒号（Windows ADS），以及任何 ".." 逃逸段。
// 这是通用资源层（v2.2）的安全红线。
func ValidateVaultPath(rel string) error {
	if rel == "" {
		return ErrInvalidPath
	}
	if strings.ContainsRune(rel, 0) {
		return ErrInvalidPath
	}
	if strings.ContainsAny(rel, "\\:") {
		return ErrInvalidPath
	}
	clean := filepath.Clean(rel)
	// 拒绝绝对路径（含 Windows 盘符）
	if filepath.IsAbs(clean) {
		return ErrInvalidPath
	}
	// 拒绝以分隔符开头的路径（如 Unix 的 "/abs" 或 Windows 上 Clean 后的 "\abs"）。
	// 注意：Windows 下无盘符的 "/abs/path" 经 Clean 变为 "\abs\path"，
	// filepath.IsAbs 会误判为非绝对，因此必须单独拦截以分隔符开头的情形。
	if strings.HasPrefix(clean, string(filepath.Separator)) {
		return ErrInvalidPath
	}
	// 拒绝逃逸出 vault 根（规范化后仍以 ".." 开头）
	if clean == ".." || strings.HasPrefix(clean, ".."+string(filepath.Separator)) {
		return ErrInvalidPath
	}
	// 拒绝任何路径段为 ".." 或 Windows 保留设备名
	for _, seg := range strings.Split(clean, string(filepath.Separator)) {
		if seg == ".." {
			return ErrInvalidPath
		}
		if isWindowsReservedName(seg) {
			return ErrInvalidPath
		}
	}
	return nil
}

// isWindowsReservedName 检测 Windows 保留设备名（CON, PRN, AUX, NUL, COM1-9, LPT1-9）
//
// 匹配规则：大小写不敏感，忽略扩展名（"." 后的部分），并去除尾部空格和点（Windows 会自动截断）。
// 例如 "CON", "con.txt", "COM1", "lpt9.dat" 均命中。
func isWindowsReservedName(seg string) bool {
	// 取扩展名前的主名
	base := seg
	if idx := strings.Index(seg, "."); idx >= 0 {
		base = seg[:idx]
	}
	// Windows 会忽略尾部空格和点
	base = strings.TrimRight(base, " .")
	if base == "" {
		return false
	}
	upper := strings.ToUpper(base)
	switch upper {
	case "CON", "PRN", "AUX", "NUL":
		return true
	}
	if len(upper) == 4 {
		prefix := upper[:3]
		suffix := upper[3:]
		if (prefix == "COM" || prefix == "LPT") && suffix >= "1" && suffix <= "9" {
			return true
		}
	}
	return false
}

// ComputeETag 计算内容的 SHA-256 作为强 ETag（带引号）
//
// ETag 是密文的衍生物，不泄露明文信息。
// 格式："<64位十六进制 sha256>"
func ComputeETag(data []byte) string {
	h := sha256.Sum256(data)
	return `"` + hex.EncodeToString(h[:]) + `"`
}
