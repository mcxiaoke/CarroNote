// Package backup 实现 SafeServer vault 备份引擎（docs/server-backup-design.md）
//
// 分层：
//   - Engine        备份引擎：blob 副本池维护、manifest 快照、Tier 2 归档、过期清理
//   - ObservableVault 拦截写操作的 Vault 包装器（blob 即时复制 + manifest 去抖快照）
//   - Scheduler     定时调度器（两个独立 ticker：快照 + 归档）
//
// 零知识原则：本包只按字节流复制/打包密文文件，从不解析内容。
package backup

import (
	"archive/tar"
	"archive/zip"
	"compress/gzip"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"wsns/internal/config"
)

// Engine 备份引擎
//
// 单个 vault 对应一个 Engine 实例；mu 保护快照创建与归档的互斥，
// 防止定时器与去抖触发并发执行造成重复文件复制。
type Engine struct {
	vaultDir  string
	backupDir string
	cfg       *config.BackupConfig
	mu        sync.Mutex // 保护快照创建与归档
	logger    *slog.Logger
}

// NewEngine 创建备份引擎
func NewEngine(vaultDir string, cfg *config.BackupConfig) *Engine {
	return &Engine{
		vaultDir:  vaultDir,
		backupDir: filepath.Join(vaultDir, "backups"),
		cfg:       cfg,
		logger:    slog.Default(),
	}
}

// SetLogger 注入自定义日志（未调用时使用 slog.Default()）
func (e *Engine) SetLogger(l *slog.Logger) {
	if l != nil {
		e.logger = l
	}
}

func (e *Engine) log() *slog.Logger {
	if e.logger == nil {
		e.logger = slog.Default()
	}
	return e.logger
}

// BackupBlobsDir 返回备份 blob 池目录
func (e *Engine) BackupBlobsDir() string {
	return filepath.Join(e.backupDir, "blobs")
}

// ── blob 副本池 ──

// CopyBlobToPool 将 blob 即时复制到备份池（PutBlob 拦截时调用）
//
// data 来自 HTTP handler 内存，无需读磁盘。无 mtime 比较 —— 数据在手直接写，
// 对已存在的同 hash 副本无条件覆盖（保证与主数据一致的"最新版本"）。
func (e *Engine) CopyBlobToPool(hash string, data []byte) error {
	if !e.cfg.Enabled {
		return nil
	}
	poolDir := e.BackupBlobsDir()
	if err := os.MkdirAll(poolDir, 0o755); err != nil {
		return err
	}
	return atomicWrite(filepath.Join(poolDir, hash), data, 0o644)
}

// SyncBlobPool 增量同步 blob 副本池（定时器调用）
//
// 扫描主 blobs/ 目录，与备份池比较 mtime：
//   - 备份池中不存在 → 复制（新增 blob）
//   - 备份池中存在但 mtime 更旧 → 覆盖（被客户端 PUT 覆盖过）
//   - 备份池中存在且 mtime 相同或更新 → 跳过
//
// 用于以下场景：
//   1. 备份功能中途启用（此前累积的 blob 未进入副本池）
//   2. 定时器定期兜底（防止 CopyBlobToPool 偶发失败遗漏）
//   3. 服务重启后首次补漏
func (e *Engine) SyncBlobPool() error {
	if !e.cfg.Enabled {
		return nil
	}

	mainBlobs := filepath.Join(e.vaultDir, "blobs")
	entries, err := os.ReadDir(mainBlobs)
	if err != nil {
		if os.IsNotExist(err) {
			return nil // blobs/ 不存在（首次同步前的空 vault）
		}
		return err
	}

	poolDir := e.BackupBlobsDir()
	if err := os.MkdirAll(poolDir, 0o755); err != nil {
		return err
	}

	for _, entry := range entries {
		if entry.IsDir() || strings.HasSuffix(entry.Name(), ".tmp") {
			continue
		}

		info, err := entry.Info()
		if err != nil {
			continue
		}

		src := filepath.Join(mainBlobs, entry.Name())
		dst := filepath.Join(poolDir, entry.Name())

		dstInfo, stErr := os.Stat(dst)
		if stErr == nil {
			// 备份池中已存在：比较修改时间
			if !info.ModTime().After(dstInfo.ModTime()) {
				continue // 未更新 → 跳过
			}
			// 主文件更新 → 覆盖（客户端 PUT 覆盖了同 hash 的 blob）
		}
		// 不存在或已更新 → 复制
		data, rdErr := os.ReadFile(src)
		if rdErr != nil {
			continue // 跳过读取失败（如原子写入窗口中的临时文件）
		}
		if wrErr := atomicWrite(dst, data, 0o644); wrErr != nil {
			return wrErr
		}
	}
	return nil
}

// ── manifest 快照 ──

// CreateSnapshot 创建一次完整备份（定时器/去抖触发）
//
// 流程：
//   1. SyncBlobPool() 增量同步 blob 副本池（兜底）
//   2. 创建 snap-<timestamp>/ 目录（仅 manifest）
//   3. 复制 manifest 文件
//   4. 清理过期快照
//
// blob 不在快照目录中（所有快照共享 backups/blobs/ 副本池）。
// 同一秒内多次调用会复用同一 snap 目录（manifest 覆盖为最新版），不产生重复目录。
func (e *Engine) CreateSnapshot() error {
	if !e.cfg.Enabled {
		return nil
	}

	e.mu.Lock()
	defer e.mu.Unlock()

	// 先同步 blob 池（增量，只复制新增/变化的文件）
	if err := e.SyncBlobPool(); err != nil {
		return fmt.Errorf("backup: sync blob pool: %w", err)
	}

	ts := time.Now().UTC().Format("20060102-150405")
	snapDir := filepath.Join(e.backupDir, "snap-"+ts)

	if err := os.MkdirAll(snapDir, 0o755); err != nil {
		return fmt.Errorf("backup: create snapshot dir: %w", err)
	}

	// 复制 manifest（vault 尚无 manifest 时跳过，不算错误——空 vault 首次快照）
	src := filepath.Join(e.vaultDir, "manifest")
	dst := filepath.Join(snapDir, "manifest")
	if err := copyFile(src, dst); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("backup: copy manifest: %w", err)
	}

	e.pruneSnapshots()
	return nil
}

// ── Tier 2 归档 ──

// CreateArchive 创建全量归档到外部路径
//
// 打包整个 vault（manifest + blobs/），排除 backups/ 自身。
// 输出到 cfg.Archive.Path（支持跨磁盘/网络映射路径）。
// 支持 zip 与 tar.gz 两种格式（均为标准库）。
func (e *Engine) CreateArchive() error {
	if !e.cfg.Enabled || !e.cfg.Archive.Enabled {
		return nil
	}

	e.mu.Lock()
	defer e.mu.Unlock()

	ts := time.Now().UTC().Format("20060102-150405")
	outDir := e.cfg.Archive.Path
	if outDir == "" {
		return fmt.Errorf("backup: archive path not configured")
	}
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return fmt.Errorf("backup: create archive dir: %w", err)
	}

	format := e.cfg.Archive.Format
	if format == "" {
		format = "zip" // 默认 zip
	}
	outPath := filepath.Join(outDir, "vault-"+ts+"."+format)

	switch format {
	case "zip":
		if err := createZip(outPath, e.vaultDir); err != nil {
			return fmt.Errorf("backup: create zip: %w", err)
		}
	case "tar.gz", "tgz":
		if err := createTarGz(outPath, e.vaultDir); err != nil {
			return fmt.Errorf("backup: create tar.gz: %w", err)
		}
	default:
		return fmt.Errorf("backup: unsupported archive format: %s", format)
	}

	e.pruneArchives()
	return nil
}

// ── 清理 ──

// pruneSnapshots 按 MaxSnapshots（数量）与 RetentionDays（天数）清理过期快照。
func (e *Engine) pruneSnapshots() {
	entries, err := os.ReadDir(e.backupDir)
	if err != nil {
		return
	}

	var snapshots []string
	for _, entry := range entries {
		if entry.IsDir() && strings.HasPrefix(entry.Name(), "snap-") {
			snapshots = append(snapshots, entry.Name())
		}
	}
	sort.Sort(sort.Reverse(sort.StringSlice(snapshots)))

	// 数量上限：保留最新 MaxSnapshots 份
	if e.cfg.MaxSnapshots > 0 && len(snapshots) > e.cfg.MaxSnapshots {
		for _, snap := range snapshots[e.cfg.MaxSnapshots:] {
			os.RemoveAll(filepath.Join(e.backupDir, snap))
		}
	}

	// 天数上限：删除早于 retentionDays 的
	if e.cfg.RetentionDays > 0 {
		cutoff := time.Now().AddDate(0, 0, -e.cfg.RetentionDays)
		for _, snap := range snapshots {
			snapTime, err := time.Parse("snap-20060102-150405", snap)
			if err != nil {
				continue
			}
			if snapTime.Before(cutoff) {
				os.RemoveAll(filepath.Join(e.backupDir, snap))
			}
		}
	}
}

// pruneArchives 按 MaxArchives 清理过期归档文件。
func (e *Engine) pruneArchives() {
	if e.cfg.Archive.MaxArchives <= 0 {
		return
	}
	format := e.cfg.Archive.Format
	if format == "" {
		format = "zip"
	}
	prefix := "vault-"
	suffix := "." + format
	entries, err := os.ReadDir(e.cfg.Archive.Path)
	if err != nil {
		return
	}

	var archives []string
	for _, entry := range entries {
		if !entry.IsDir() && strings.HasPrefix(entry.Name(), prefix) && strings.HasSuffix(entry.Name(), suffix) {
			archives = append(archives, entry.Name())
		}
	}
	sort.Sort(sort.Reverse(sort.StringSlice(archives)))

	for _, arch := range archives[e.cfg.Archive.MaxArchives:] {
		os.Remove(filepath.Join(e.cfg.Archive.Path, arch))
	}
}

// ── 工具 ──

// createZip 将 vault 目录打包为 zip（排除 backups/ 自身与原子写入临时文件）。
func createZip(outPath, vaultDir string) error {
	f, err := os.Create(outPath)
	if err != nil {
		return err
	}
	w := zip.NewWriter(f)

	err = filepath.Walk(vaultDir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() {
			return nil
		}
		rel, _ := filepath.Rel(vaultDir, path)
		// 不把自己打包进去
		if strings.HasPrefix(rel, "backups") {
			return nil
		}
		// 跳过原子写入临时文件
		if strings.HasSuffix(rel, ".tmp") {
			return nil
		}

		writer, err := w.Create(strings.ReplaceAll(rel, string(os.PathSeparator), "/"))
		if err != nil {
			return err
		}
		src, serr := os.Open(path)
		if serr != nil {
			return serr
		}
		defer src.Close()
		_, err = io.Copy(writer, src)
		return err
	})

	// 先关 zip writer（刷新中央目录），再关文件，保证 zip 完整可读
	closeErr := w.Close()
	cErr := f.Close()
	if closeErr != nil {
		return closeErr
	}
	if cErr != nil {
		return cErr
	}
	return err
}

// createTarGz 将 vault 目录打包为 tar.gz（排除 backups/ 子目录与临时文件）。
func createTarGz(outPath, vaultDir string) error {
	f, err := os.Create(outPath)
	if err != nil {
		return err
	}
	gz := gzip.NewWriter(f)
	tw := tar.NewWriter(gz)

	err = filepath.Walk(vaultDir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(vaultDir, path)
		if rel == "." {
			return nil // 根目录自身不进归档
		}
		if strings.HasPrefix(rel, "backups") {
			return nil
		}
		if strings.HasSuffix(rel, ".tmp") {
			return nil
		}

		hdr, err := tar.FileInfoHeader(info, "")
		if err != nil {
			return err
		}
		hdr.Name = strings.ReplaceAll(rel, string(os.PathSeparator), "/")
		if err := tw.WriteHeader(hdr); err != nil {
			return err
		}
		if info.IsDir() {
			return nil
		}
		src, serr := os.Open(path)
		if serr != nil {
			return serr
		}
		defer src.Close()
		_, err = io.Copy(tw, src)
		return err
	})
	if err != nil {
		return err
	}

	// 按 gzip → tar → file 顺序关闭，保证归档完整
	if err := tw.Close(); err != nil {
		return err
	}
	if err := gz.Close(); err != nil {
		return err
	}
	return f.Close()
}

// copyFile 简单地复制单个文件（快照用，无需原子性——快照目录本身是一次性的）
func copyFile(src, dst string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return os.WriteFile(dst, data, 0o644)
}

// atomicWrite 原子写入文件：tmp + fsync + rename
//
// 与 storage 包同款策略（此处独立实现，避免跨包调用未导出函数）：
//   - 同目录随机后缀临时文件，避免并发写同一目标相互截断
//   - fsync 确保数据落盘（防断电半写）
//   - rename 原子替换目标
//
// 任何步骤失败都会清理临时文件，不影响已有数据。
func atomicWrite(path string, data []byte, perm os.FileMode) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	buf := make([]byte, 8)
	if _, err := rand.Read(buf); err != nil {
		return err
	}
	tmpPath := fmt.Sprintf("%s.%s.tmp", path, hex.EncodeToString(buf))

	f, err := os.OpenFile(tmpPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, perm)
	if err != nil {
		return err
	}
	cleanup := func() { os.Remove(tmpPath) }

	if _, err := f.Write(data); err != nil {
		f.Close()
		cleanup()
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		cleanup()
		return err
	}
	if err := f.Close(); err != nil {
		cleanup()
		return err
	}
	if err := os.Rename(tmpPath, path); err != nil {
		cleanup()
		return err
	}
	return nil
}

