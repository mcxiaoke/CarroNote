// HTTP handlers（SafeServer v2.1 + v2.2 协议端点）
//
// 所有 handler 通过 s.vault 操作存储层，不直接接触文件系统。
// 这样切换存储后端（数据库/对象存储）时只需实现新的 Vault，无需改 handler。
//
// v2.2 新增 /api/v2/resources/<path> 通用资源层：用纯 REST/JSON 表达等价于
// WebDAV GET/PUT/DELETE/MOVE/MKCOL/COPY/PROPFIND 的语义，兼容任意 HTTP client。
package server

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"

	"wsns/internal/storage"
)

// isPayloadTooLarge 检测错误是否源自 http.MaxBytesReader 请求体超限，
// 命中时应响应 413 Payload Too Large。
func isPayloadTooLarge(err error) bool {
	var maxErr *http.MaxBytesError
	return errors.As(err, &maxErr)
}

// ──────────────────────────────────────────────
// manifest 端点
// ──────────────────────────────────────────────

// GET /api/v2/manifest
//
// 下载 manifest 密文。404 表示首次同步（远端无 manifest）。
func (s *Server) handleGetManifest(w http.ResponseWriter, r *http.Request) {
	data, err := s.vault.GetManifest()
	if err != nil {
		if errors.Is(err, storage.ErrNotFound) {
			http.Error(w, "Not Found", http.StatusNotFound)
			return
		}
		http.Error(w, "read failed: "+err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("ETag", storage.ComputeETag(data))
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Write(data)
}

// PUT /api/v2/manifest（乐观锁 + 临界区保护）
//
// 乐观锁由 Vault 实现内部保证（"校验 + 写入" 在同一个锁内完成，防 TOCTOU）。
func (s *Server) handlePutManifest(w http.ResponseWriter, r *http.Request) {
	defer r.Body.Close() // 修复 L-7：尽早注册关闭，错误分支也能释放连接
	body, err := io.ReadAll(r.Body)
	if err != nil {
		if isPayloadTooLarge(err) {
			http.Error(w, "Payload Too Large", http.StatusRequestEntityTooLarge)
			return
		}
		http.Error(w, "read body failed: "+err.Error(), http.StatusBadRequest)
		return
	}

	ifMatch := r.Header.Get("If-Match")
	ifNoneMatch := r.Header.Get("If-None-Match")

	// 构造乐观锁参数
	var opts storage.PutOptions
	if ifNoneMatch == "*" {
		opts.IfNoneMatch = true
	} else if ifMatch != "" {
		opts.IfMatch = strings.Trim(ifMatch, `"`)
	}

	if err := s.vault.PutManifest(body, opts); err != nil {
		if errors.Is(err, storage.ErrPreconditionFailed) {
			http.Error(w, err.Error(), http.StatusPreconditionFailed)
			return
		}
		http.Error(w, "write failed: "+err.Error(), http.StatusInternalServerError)
		return
	}

	w.Header().Set("ETag", storage.ComputeETag(body))
	w.WriteHeader(http.StatusOK)
}

// DELETE /api/v2/manifest（清理损坏文件，backupCorruptManifest 用）
//
// 幂等：删除不存在的 manifest 返回 204。
func (s *Server) handleDeleteManifest(w http.ResponseWriter, r *http.Request) {
	if err := s.vault.DeleteManifest(); err != nil {
		http.Error(w, "delete manifest failed: "+err.Error(), http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ──────────────────────────────────────────────
// blob 端点
// ──────────────────────────────────────────────

// GET /api/v2/blob/<hash>
func (s *Server) handleGetBlob(w http.ResponseWriter, r *http.Request, hash string) {
	data, err := s.vault.GetBlob(hash)
	if err != nil {
		switch {
		case errors.Is(err, storage.ErrNotFound):
			http.Error(w, "Not Found", http.StatusNotFound)
		case errors.Is(err, storage.ErrInvalidHash), errors.Is(err, storage.ErrInvalidPath):
			http.Error(w, err.Error(), http.StatusBadRequest)
		default:
			http.Error(w, "read failed: "+err.Error(), http.StatusInternalServerError)
		}
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Write(data)
}

// PUT /api/v2/blob/<hash>（幂等）
func (s *Server) handlePutBlob(w http.ResponseWriter, r *http.Request, hash string) {
	defer r.Body.Close() // 修复 L-7：尽早注册关闭
	body, err := io.ReadAll(r.Body)
	if err != nil {
		if isPayloadTooLarge(err) {
			http.Error(w, "Payload Too Large", http.StatusRequestEntityTooLarge)
			return
		}
		http.Error(w, "read body failed: "+err.Error(), http.StatusBadRequest)
		return
	}

	if err := s.vault.PutBlob(hash, body); err != nil {
		switch {
		case errors.Is(err, storage.ErrInvalidHash), errors.Is(err, storage.ErrInvalidPath):
			http.Error(w, err.Error(), http.StatusBadRequest)
		default:
			http.Error(w, "write failed: "+err.Error(), http.StatusInternalServerError)
		}
		return
	}
	w.WriteHeader(http.StatusOK)
}

// DELETE /api/v2/blob/<hash>（GC 用，幂等）
func (s *Server) handleDeleteBlob(w http.ResponseWriter, r *http.Request, hash string) {
	if err := s.vault.DeleteBlob(hash); err != nil {
		switch {
		case errors.Is(err, storage.ErrInvalidHash), errors.Is(err, storage.ErrInvalidPath):
			http.Error(w, err.Error(), http.StatusBadRequest)
		default:
			http.Error(w, "delete failed: "+err.Error(), http.StatusInternalServerError)
		}
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// GET /api/v2/blobs（列出所有 blob hash，GC 用）
//
// 返回 JSON 数组，包含 blobs/ 目录下所有 blob 的 hash。
// 服务端不解析 blob 内容，仅列文件名。
func (s *Server) handleListBlobs(w http.ResponseWriter, r *http.Request) {
	hashes, err := s.vault.ListBlobs()
	if err != nil {
		http.Error(w, "list blobs failed: "+err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(hashes)
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

// resourceOpBody 是 POST /api/v2/resources/<path> 的请求体
type resourceOpBody struct {
	Op       string `json:"op"`
	Dest     string `json:"dest"`
	Overwrite bool  `json:"overwrite"`
	Depth    int    `json:"depth"`
}

// GET /api/v2/resources/<path> → 读资源内容
func (s *Server) handleGetResource(w http.ResponseWriter, r *http.Request, rel string) {
	if rel == "" {
		http.Error(w, "resource path required", http.StatusBadRequest)
		return
	}
	data, err := s.vault.GetResource(rel)
	if err != nil {
		switch {
		case errors.Is(err, storage.ErrNotFound):
			http.Error(w, "Not Found", http.StatusNotFound)
		case errors.Is(err, storage.ErrInvalidPath), errors.Is(err, storage.ErrInvalidHash):
			http.Error(w, err.Error(), http.StatusBadRequest)
		default:
			http.Error(w, "read failed: "+err.Error(), http.StatusInternalServerError)
		}
		return
	}
	w.Header().Set("ETag", storage.ComputeETag(data))
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Write(data)
}

// PUT /api/v2/resources/<path> → 写资源（支持 If-Match / If-None-Match）
func (s *Server) handlePutResource(w http.ResponseWriter, r *http.Request, rel string) {
	if rel == "" {
		http.Error(w, "resource path required", http.StatusBadRequest)
		return
	}
	defer r.Body.Close() // 修复 L-7：尽早注册关闭
	body, err := io.ReadAll(r.Body)
	if err != nil {
		if isPayloadTooLarge(err) {
			http.Error(w, "Payload Too Large", http.StatusRequestEntityTooLarge)
			return
		}
		http.Error(w, "read body failed: "+err.Error(), http.StatusBadRequest)
		return
	}

	var opts storage.PutOptions
	if ifNoneMatch := r.Header.Get("If-None-Match"); ifNoneMatch == "*" {
		opts.IfNoneMatch = true
	} else if ifMatch := r.Header.Get("If-Match"); ifMatch != "" {
		opts.IfMatch = strings.Trim(ifMatch, `"`)
	}

	if err := s.vault.PutResource(rel, body, opts); err != nil {
		switch {
		case errors.Is(err, storage.ErrPreconditionFailed):
			http.Error(w, err.Error(), http.StatusPreconditionFailed)
		case errors.Is(err, storage.ErrInvalidPath), errors.Is(err, storage.ErrInvalidHash):
			http.Error(w, err.Error(), http.StatusBadRequest)
		default:
			http.Error(w, "write failed: "+err.Error(), http.StatusInternalServerError)
		}
		return
	}
	w.Header().Set("ETag", storage.ComputeETag(body))
	w.WriteHeader(http.StatusOK)
}

// DELETE /api/v2/resources/<path> → 删资源（幂等）
func (s *Server) handleDeleteResource(w http.ResponseWriter, r *http.Request, rel string) {
	if rel == "" {
		http.Error(w, "resource path required", http.StatusBadRequest)
		return
	}
	if err := s.vault.DeleteResource(rel); err != nil {
		switch {
		case errors.Is(err, storage.ErrInvalidPath), errors.Is(err, storage.ErrInvalidHash):
			http.Error(w, err.Error(), http.StatusBadRequest)
		default:
			http.Error(w, "delete failed: "+err.Error(), http.StatusInternalServerError)
		}
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// POST /api/v2/resources/<path> → 扩展操作（move / mkdir / copy / propfind / stats）
func (s *Server) handleResourceOp(w http.ResponseWriter, r *http.Request, rel string) {
	if rel == "" {
		http.Error(w, "resource path required", http.StatusBadRequest)
		return
	}
	var ob resourceOpBody
	if err := json.NewDecoder(r.Body).Decode(&ob); err != nil {
		http.Error(w, "invalid JSON body", http.StatusBadRequest)
		return
	}

	switch ob.Op {
	case "move":
		if ob.Dest == "" {
			http.Error(w, "dest required", http.StatusBadRequest)
			return
		}
		if err := s.vault.MoveResource(rel, ob.Dest, ob.Overwrite); err != nil {
			if e := mapResourceErr(err); e != 0 {
				http.Error(w, err.Error(), e)
				return
			}
			http.Error(w, "move failed: "+err.Error(), http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusNoContent)

	case "copy":
		if ob.Dest == "" {
			http.Error(w, "dest required", http.StatusBadRequest)
			return
		}
		if err := s.vault.CopyResource(rel, ob.Dest, ob.Overwrite); err != nil {
			if e := mapResourceErr(err); e != 0 {
				http.Error(w, err.Error(), e)
				return
			}
			http.Error(w, "copy failed: "+err.Error(), http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusNoContent)

	case "mkdir":
		if err := s.vault.MkCol(rel); err != nil {
			if errors.Is(err, storage.ErrExists) {
				http.Error(w, "already exists", http.StatusMethodNotAllowed) // 405，客户端忽略
				return
			}
			if errors.Is(err, storage.ErrConflict) {
				http.Error(w, "parent not found", http.StatusConflict)
				return
			}
			if errors.Is(err, storage.ErrInvalidPath) {
				http.Error(w, err.Error(), http.StatusBadRequest)
				return
			}
			http.Error(w, "mkdir failed: "+err.Error(), http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusCreated)

	case "propfind", "stats":
		depth := ob.Depth
		if ob.Op == "stats" {
			depth = 0
		}
		entries, err := s.vault.PropFind(rel, depth)
		if err != nil {
			if errors.Is(err, storage.ErrNotFound) {
				http.Error(w, "Not Found", http.StatusNotFound)
				return
			}
			if errors.Is(err, storage.ErrInvalidPath) {
				http.Error(w, err.Error(), http.StatusBadRequest)
				return
			}
			http.Error(w, "propfind failed: "+err.Error(), http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(entries)

	default:
		http.Error(w, "unknown op: "+ob.Op, http.StatusBadRequest)
	}
}

// mapResourceErr 将 Move/Copy 的资源层错误映射为 HTTP 状态码
func mapResourceErr(err error) int {
	switch {
	case errors.Is(err, storage.ErrNotFound):
		return http.StatusNotFound
	case errors.Is(err, storage.ErrConflict):
		return http.StatusConflict
	case errors.Is(err, storage.ErrInvalidPath), errors.Is(err, storage.ErrInvalidHash):
		return http.StatusBadRequest
	default:
		return 0
	}
}
