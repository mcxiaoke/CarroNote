/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

// ObservableVault 是 storage.Vault 的装饰器，在写操作时联动备份引擎
//
//   - PutBlob 成功 → 立即复制到备份 blob 池（blob 不可变，实时备份）
//   - PutManifest / DeleteManifest → 去抖后触发 CreateSnapshot（防批量同步时快照爆炸）
//   - 读操作透明代理给原始 Vault
package backup

import (
	"strings"
	"sync"
	"time"

	"wsns/internal/storage"
)

type ObservableVault struct {
	storage.Vault
	engine *Engine

	debounceMu    sync.Mutex
	debounceTimer *time.Timer
	wg              sync.WaitGroup
}

// NewObservableVault 创建包装器
func NewObservableVault(inner storage.Vault, engine *Engine) *ObservableVault {
	return &ObservableVault{Vault: inner, engine: engine}
}

// ── blob：即时复制到备份池 ──

// PutBlob 写 blob 后立即备份（无条件复制，数据已在内存）
func (v *ObservableVault) PutBlob(hash string, data []byte) error {
	if err := v.Vault.PutBlob(hash, data); err != nil {
		return err
	}
	// 即时复制，不等去抖（blob 不可变，立即备份）。
	// 复制失败仅记录日志，不阻断请求（主数据已成功落盘，失败由定时 SyncBlobPool 兜底）。
	if err := v.engine.CopyBlobToPool(hash, data); err != nil {
		v.engine.log().Error("backup: copy blob to pool failed",
			"hash", hash, "error", err)
	}
	return nil
}

// PutResource 写通用资源（blobs/ 路径也即时复制；manifest 路径去抖交给 PutManifest）
func (v *ObservableVault) PutResource(rel string, data []byte, opts storage.PutOptions) error {
	if err := v.Vault.PutResource(rel, data, opts); err != nil {
		return err
	}
	// 检查是否是 blobs/ 路径，是则复制到备份池
	if strings.HasPrefix(rel, "blobs/") {
		hash := strings.TrimPrefix(rel, "blobs/")
		if err := v.engine.CopyBlobToPool(hash, data); err != nil {
			v.engine.log().Error("backup: copy blob to pool failed",
				"hash", hash, "error", err)
		}
	}
	// manifest 路径的去抖在 PutManifest 中处理
	return nil
}

// ── manifest：去抖后快照 ──

// PutManifest 写入 manifest 后去抖触发快照
func (v *ObservableVault) PutManifest(data []byte, opts storage.PutOptions) error {
	if err := v.Vault.PutManifest(data, opts); err != nil {
		return err
	}
	v.notifyWrite()
	return nil
}

// DeleteManifest 删除 manifest 后去抖触发快照
func (v *ObservableVault) DeleteManifest() error {
	if err := v.Vault.DeleteManifest(); err != nil {
		return err
	}
	v.notifyWrite()
	return nil
}

// ── 去抖：防止同步期间多次写入导致快照爆炸 ──

// notifyWrite 启动去抖定时器，仅在 autoOnWrite 开启时生效
func (v *ObservableVault) notifyWrite() {
	if !v.engine.cfg.Enabled || !v.engine.cfg.AutoOnWrite {
		return
	}

	v.debounceMu.Lock()
	defer v.debounceMu.Unlock()

	if v.debounceTimer != nil {
		if v.debounceTimer.Stop() {
			v.wg.Done()
		}
	}

	debounceMs := v.engine.cfg.WriteDebounceMs
	if debounceMs <= 0 {
		debounceMs = 5000
	}

	v.wg.Add(1)
	v.debounceTimer = time.AfterFunc(time.Duration(debounceMs)*time.Millisecond, func() {
		defer v.wg.Done()
		// 触发的快照失败不影响后续定时（CreateSnapshot 自身含互斥锁）
		_ = v.engine.CreateSnapshot()
	})
}

// Stop 停止去抖定时器（服务关闭时调用，避免进程退出前的幽灵快照）
// 若快照已在执行中，会等待其安全结束再返回。
func (v *ObservableVault) Stop() {
	v.debounceMu.Lock()
	if v.debounceTimer != nil {
		if v.debounceTimer.Stop() {
			v.wg.Done()
		}
		v.debounceTimer = nil
	}
	v.debounceMu.Unlock()
	v.wg.Wait()
}
