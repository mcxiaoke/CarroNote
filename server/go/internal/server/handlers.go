// HTTP handlers（SafeServer v2.1 协议端点）
//
// 所有 handler 通过 s.vault 操作存储层，不直接接触文件系统。
// 这样切换存储后端（数据库/对象存储）时只需实现新的 Vault，无需改 handler。
package server

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"

	"safenotes-server/internal/storage"
)

// maxBytesErr 检测是否是 http.MaxBytesReader 超限错误，返回 true 时应响应 413
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
	body, err := io.ReadAll(r.Body)
	if err != nil {
		if isPayloadTooLarge(err) {
			http.Error(w, "Payload Too Large", http.StatusRequestEntityTooLarge)
			return
		}
		http.Error(w, "read body failed: "+err.Error(), http.StatusBadRequest)
		return
	}
	defer r.Body.Close()

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
		case errors.Is(err, storage.ErrInvalidHash):
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
	body, err := io.ReadAll(r.Body)
	if err != nil {
		if isPayloadTooLarge(err) {
			http.Error(w, "Payload Too Large", http.StatusRequestEntityTooLarge)
			return
		}
		http.Error(w, "read body failed: "+err.Error(), http.StatusBadRequest)
		return
	}
	defer r.Body.Close()

	if err := s.vault.PutBlob(hash, body); err != nil {
		switch {
		case errors.Is(err, storage.ErrInvalidHash):
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
		case errors.Is(err, storage.ErrInvalidHash):
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
