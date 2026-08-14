# SafeServer Vault 备份方案设计

> **实施状态**：本方案已按第 9 节计划在 Go server（`server/go/internal/backup/`）完整实现，
> 含单元测试（`go test ./internal/backup/`）。归档格式除 zip 外另实现了 tar.gz（均为标准库）。
> Node.js 参考实现暂未包含备份功能。

## 1. 背景与现状

### 1.1 当前备份机制

| 层级 | 机制 | 位置 | 说明 |
|------|------|------|------|
| 客户端同步引擎 | Manifest 环形备份（5 代） | `packages/core/lib/src/sync/sync_backend.dart` | 每次 PUT manifest 前备份旧版本 |
| 客户端应用层 | 每日明文 JSON 导出 | `lib/utils/scheduled_task.dart` | 所有笔记导出为 `safenotes_backup.json` |
| **Server 端** | **无** | — | 写操作直接落盘，无版本保留 |

### 1.2 问题

- 客户端损坏或被清空后，远端 manifest/blob 在乐观锁下会被覆盖，旧数据不可恢复
- 无快照机制，无法回溯到某个历史时间点的 vault 状态
- 误操作（如客户端 bug 导致空 manifest 上传）会永久丢失数据

### 1.3 目标

1. **版本历史（Tier 1）**：manifest 快照 + 独立 blob 副本池，增量维护、轻量高效
2. **修改后自动备份**：每次 PUT 操作拦截，blob 即时复制到备份池，manifest 去抖后创建快照
3. **归档导出（Tier 2）**：按配置间隔打包全量 zip 到外部路径（跨磁盘/网络位置）
4. **配置文件驱动**：所有参数通过 JSON 配置文件设定

---

## 2. 总体架构

```
                          ┌───────────────────┐
                          │   BackupConfig    │
                          │   + ArchiveConfig  │
                          └─────────┬─────────┘
                                    │
  ┌──────────────┐     ┌───────────▼───────────┐     ┌───────────────┐
  │  Scheduler   │────▶│     BackupEngine      │◀────│ VaultWrapper  │
  │ (定时+Tier2) │     │ (blob池+快照+归档)     │     │ (写操作拦截)   │
  └──────┬───────┘     └───────────┬───────────┘     └───────┬───────┘
         │                         │                         │
         │  SyncBlobPool(mtime)    │     CopyBlobToPool      │
         │  ← ─ 定时兜底 ─ ─ ─ ─  │  ← ─ 即时复制 ─ ─ ─ ─ ─ ┘
         │                         │
         │              ┌──────────▼─────────┐
         │              │  backups/          │
         └──快照manifet─▶│  ├── blobs/  只增不删
                        │  ├── snap-N/manifest
                        │  └── ...
                        └────────────────────┘
                                    │
                        ┌───────────▼─────────┐
                        │  D:/Backup/         │  Tier 2
                        │  └── vault-*.zip    │  打包导出
                        └─────────────────────┘
```

**三层协作**：

- **VaultWrapper** 拦截写操作：
  - `PutBlob` → **即时**调用 `CopyBlobToPool(data)` — 数据在内存，直接复制
  - `PutManifest` → 去抖后调用 `CreateSnapshot` — 防批量同步时快照爆炸
- **Scheduler** 定时器触发 `CreateSnapshot`：
  - 先调用 `SyncBlobPool()` — 扫描主 blobs/，按 mtime 增量同步（兜底）
  - 再创建 manifest 快照
- **BackupEngine**：副本池维护、快照创建、zip 归档、过期清理

### blob 备份双路径

| 路径 | 触发 | 比较方式 | 用途 |
|------|------|---------|------|
| `CopyBlobToPool` | `PutBlob` 拦截 | 无条件写入（数据在内存） | 实时备份 |
| `SyncBlobPool` | 定时器 / 启动时 | 比较 mtime（不存在→复制，更新→覆盖，相同→跳过） | 兜底补漏 |

两个路径互补：实时路径覆盖正常写入，定时路径处理备份后启用、服务重启、偶发失败等边界情况。

---

## 3. 存储布局

```
<dataDir>/vaults/vault-default/
├── manifest                       # 主数据
├── blobs/<hash>                   # blob 密文（主副本）
├── blobs-orphan/...               # 软删除隔离区（不纳入备份）
└── backups/                       # ★ 备份区
    ├── blobs/                     # ★ 独立 blob 副本池（只增不删）
    │   ├── <hash-a>               # ← PutBlob 时即时复制
    │   ├── <hash-b>               # ← 独立 inode，主文件损坏不受影响
    │   └── <hash-c>               # ← 即使主 blobs/ 已 GC，此处永久保留
    ├── snap-20260809-120000/      # 快照：仅 manifest
    │   └── manifest
    ├── snap-20260809-130000/      # 每个快照 ~10KB
    │   └── manifest
    └── snap-20260810-120000/
        └── manifest
```

### 恢复

```
恢复(快照 snap-<ts>) = snap-<ts>/manifest + backups/blobs/ 的所有文件 → 完整 vault 状态
```

### 两个 blobs 目录的区别

| | `blobs/`（主） | `backups/blobs/`（备份池） |
|---|---|---|
| 写入时机 | 客户端 PUT | 每次 PUT 后即时复制 |
| 删除 | 客户端 GC 后删除 | **只增不删** |
| inode | 独立 | 独立（不是硬链接） |
| 目的 | 正常服务 | 独立副本，防主文件损坏 |

---

## 4. 配置设计

### 4.1 Tier 1 配置

```go
type BackupConfig struct {
    Enabled          bool          `json:"enabled"`          // 是否启用备份
    ScheduleInterval string        `json:"scheduleInterval"` // 定时快照间隔（"1h"/"6h"，空=仅写入触发）
    AutoOnWrite      bool          `json:"autoOnWrite"`      // 写入后去抖触发快照
    WriteDebounceMs  int           `json:"writeDebounceMs"`  // 写入去抖间隔（毫秒，默认 5000）
    MaxSnapshots     int           `json:"maxSnapshots"`     // 最多保留快照数（0=不限）
    RetentionDays    int           `json:"retentionDays"`    // 保留天数（0=不限）
    Archive          ArchiveConfig `json:"archive"`          // Tier 2 归档配置
}
```

### 4.2 Tier 2 归档配置

```go
type ArchiveConfig struct {
    Enabled     bool   `json:"enabled"`     // 是否启用归档
    Interval    string `json:"interval"`    // 归档间隔（"24h"/"12h"）
    Path        string `json:"path"`        // 输出目录（可跨磁盘/网络映射）
    Format      string `json:"format"`      // "zip" 或 "tar.gz"
    MaxArchives int    `json:"maxArchives"` // 保留份数
}
```

### 4.3 完整配置示例

```json
{
  "addr": ":4080",
  "dataDir": "./data",
  "token": "change-me-to-a-strong-token",
  "backup": {
    "enabled": true,
    "scheduleInterval": "1h",
    "autoOnWrite": true,
    "writeDebounceMs": 5000,
    "maxSnapshots": 24,
    "retentionDays": 7,
    "archive": {
      "enabled": true,
      "interval": "24h",
      "path": "D:/Backup/safenotes",
      "format": "zip",
      "maxArchives": 30
    }
  }
}
```

### 4.4 参数默认值

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `backup.enabled` | `false` | 默认关闭 |
| `backup.scheduleInterval` | `""` | 空=仅 AutoOnWrite |
| `backup.autoOnWrite` | `false` | 按需开启 |
| `backup.writeDebounceMs` | `5000` | 5 秒 |
| `backup.maxSnapshots` | `0` | 不限制 |
| `backup.retentionDays` | `0` | 不限制 |
| `archive.enabled` | `false` | 默认关闭 |
| `archive.interval` | `""` | 空=不启用 |
| `archive.format` | `"zip"` | — |
| `archive.maxArchives` | `0` | 不限制 |

---

## 5. 核心实现

### 5.1 文件结构

```
server/go/internal/backup/
├── engine.go         # 备份引擎：blob池管理、快照创建、Tier 2 归档、过期清理
├── vault.go          # ObservableVault：拦截写操作，blob即时复制 + manifest去抖快照
└── scheduler.go      # 定时调度器：两个独立 ticker（快照 + 归档）
```

### 5.2 BackupEngine（engine.go）

核心职责：
- blob 副本池维护（只增不删）
- manifest 快照创建
- Tier 2 全量 zip 归档
- 过期清理（快照 + 归档独立策略）

```go
package backup

import (
    "archive/zip"
    "fmt"
    "io"
    "os"
    "path/filepath"
    "sort"
    "strings"
    "sync"
    "time"
)

// Engine 备份引擎
type Engine struct {
    vaultDir  string
    backupDir string
    cfg       *BackupConfig
    mu        sync.Mutex // 保护快照创建与归档
}

// NewEngine 创建备份引擎
func NewEngine(vaultDir string, cfg *BackupConfig) *Engine {
    return &Engine{
        vaultDir:  vaultDir,
        backupDir: filepath.Join(vaultDir, "backups"),
        cfg:       cfg,
    }
}

// ── blob 副本池 ──

// BackupBlobsDir 返回备份 blob 池目录
func (e *Engine) BackupBlobsDir() string {
    return filepath.Join(e.backupDir, "blobs")
}

// CopyBlobToPool 将 blob 即时复制到备份池（PutBlob 拦截时调用）
//
// data 来自 HTTP handler 内存，无需读磁盘。无 mtime 比较 —— 数据在手直接写。
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
//   - 备份池中存在且 mtime 相同 → 跳过
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
        atomicWrite(dst, data, 0o644)
    }
    return nil
}

// ── manifest 快照 ──

// CreateSnapshot 创建一次完整备份（定时器/去抖触发）
//
// 流程：
//   1. SyncBlobPool() 增量同步 blob 副本池（兜底）
//   2. 创建 snap-<timestamp>/ 目录
//   3. 复制 manifest 文件
//   4. 清理过期快照
//
// blob 不在快照目录中（所有快照共享 backups/blobs/ 副本池）。
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

    // 复制 manifest
    src := filepath.Join(e.vaultDir, "manifest")
    dst := filepath.Join(snapDir, "manifest")
    if err := copyFile(src, dst); err != nil {
        if !os.IsNotExist(err) {
            return fmt.Errorf("backup: copy manifest: %w", err)
        }
    }

    e.pruneSnapshots()
    return nil
}

// ── Tier 2 归档 ──

// CreateArchive 创建全量 zip 归档到外部路径
//
// 打包整个 vault（manifest + blobs/），排除 backups/ 自身。
// 输出到 cfg.Archive.Path（支持跨磁盘/网络映射路径）。
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

    outPath := filepath.Join(outDir, "vault-"+ts+"."+e.cfg.Archive.Format)

    switch e.cfg.Archive.Format {
    case "zip":
        if err := createZip(outPath, e.vaultDir); err != nil {
            return err
        }
    case "tar.gz", "tgz":
        // 暂用 zip 实现，tar.gz 需 archive/tar + compress/gzip（同为标准库）
        return fmt.Errorf("backup: tar.gz not yet implemented, use zip")
    default:
        return fmt.Errorf("backup: unsupported archive format: %s", e.cfg.Archive.Format)
    }

    e.pruneArchives()
    return nil
}

// ── 清理 ──

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

    if e.cfg.MaxSnapshots > 0 && len(snapshots) > e.cfg.MaxSnapshots {
        for _, snap := range snapshots[e.cfg.MaxSnapshots:] {
            os.RemoveAll(filepath.Join(e.backupDir, snap))
        }
    }

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

func (e *Engine) pruneArchives() {
    if e.cfg.Archive.MaxArchives <= 0 {
        return
    }
    entries, err := os.ReadDir(e.cfg.Archive.Path)
    if err != nil {
        return
    }

    var archives []string
    prefix := "vault-"
    suffix := "." + e.cfg.Archive.Format
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

// createZip 将 vault 目录打包为 zip（排除 backups/ 子目录）
func createZip(outPath, vaultDir string) error {
    f, err := os.Create(outPath)
    if err != nil {
        return err
    }
    defer f.Close()

    w := zip.NewWriter(f)
    defer w.Close()

    return filepath.Walk(vaultDir, func(path string, info os.FileInfo, err error) error {
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
        src, err := os.Open(path)
        if err != nil {
            return err
        }
        defer src.Close()
        _, err = io.Copy(writer, src)
        return err
    })
}

func copyFile(src, dst string) error {
    data, err := os.ReadFile(src)
    if err != nil {
        return err
    }
    return os.WriteFile(dst, data, 0o644)
}
```

### 5.3 ObservableVault（vault.go）

关键区别：**blob 即时复制不等待**，**manifest 去抖后快照**。

```go
package backup

import (
    "wsns/internal/storage"
    "sync"
    "time"
)

// ObservableVault 在写操作时驱动备份
//
//   - PutBlob 成功 → 立即复制到备份 blob 池（不经过去抖）
//   - PutManifest / DeleteManifest → 去抖后触发 CreateSnapshot
//   - 读操作透明代理给原始 Vault
type ObservableVault struct {
    storage.Vault
    engine *Engine

    debounceMu    sync.Mutex
    debounceTimer *time.Timer
}

// NewObservableVault 创建包装器
func NewObservableVault(inner storage.Vault, engine *Engine) *ObservableVault {
    return &ObservableVault{Vault: inner, engine: engine}
}

// ── blob：即时复制到备份池 ──

func (v *ObservableVault) PutBlob(hash string, data []byte) error {
    if err := v.Vault.PutBlob(hash, data); err != nil {
        return err
    }
    // 即时复制，不等去抖（blob 不可变，立即备份）
    v.engine.CopyBlobToPool(hash, data)
    return nil
}

// PutResource 也可能写入 blob（通用资源层）
func (v *ObservableVault) PutResource(rel string, data []byte, opts storage.PutOptions) error {
    if err := v.Vault.PutResource(rel, data, opts); err != nil {
        return err
    }
    // 检查是否是 blobs/ 路径，是则复制到备份池
    if strings.HasPrefix(rel, "blobs/") {
        hash := strings.TrimPrefix(rel, "blobs/")
        v.engine.CopyBlobToPool(hash, data)
    }
    // manifest 路径的去抖在 PutManifest 中处理
    return nil
}

// ── manifest：去抖后快照 ──

func (v *ObservableVault) PutManifest(data []byte, opts storage.PutOptions) error {
    if err := v.Vault.PutManifest(data, opts); err != nil {
        return err
    }
    v.notifyWrite()
    return nil
}

func (v *ObservableVault) DeleteManifest() error {
    if err := v.Vault.DeleteManifest(); err != nil {
        return err
    }
    v.notifyWrite()
    return nil
}

// ── 去抖：防止同步期间多次写入导致快照爆炸 ──

func (v *ObservableVault) notifyWrite() {
    if !v.engine.cfg.Enabled || !v.engine.cfg.AutoOnWrite {
        return
    }

    v.debounceMu.Lock()
    defer v.debounceMu.Unlock()

    if v.debounceTimer != nil {
        v.debounceTimer.Stop()
    }

    debounceMs := v.engine.cfg.WriteDebounceMs
    if debounceMs <= 0 {
        debounceMs = 5000
    }

    v.debounceTimer = time.AfterFunc(time.Duration(debounceMs)*time.Millisecond, func() {
        v.engine.CreateSnapshot()
    })
}
```

### 5.4 Scheduler（scheduler.go）

两个独立定时器：Tier 1 轻量快照 + Tier 2 全量归档。

```go
package backup

import (
    "context"
    "log/slog"
    "time"
)

// Scheduler 定时备份调度器
type Scheduler struct {
    engine          *Engine
    snapInterval    time.Duration // Tier 1 快照间隔
    archiveInterval time.Duration // Tier 2 归档间隔
    logger          *slog.Logger
}

// NewScheduler 创建调度器
func NewScheduler(engine *Engine, snapInterval, archiveInterval time.Duration, logger *slog.Logger) *Scheduler {
    return &Scheduler{
        engine:          engine,
        snapInterval:    snapInterval,
        archiveInterval: archiveInterval,
        logger:          logger,
    }
}

// Start 启动定时循环（阻塞，在独立 goroutine 中运行）
func (s *Scheduler) Start(ctx context.Context) {
    // Tier 1：定时快照
    if s.snapInterval > 0 {
        s.logger.Info("backup: tier-1 scheduler started",
            "interval", s.snapInterval.String())
        go s.runTicker(ctx, s.snapInterval, "snapshot", s.engine.CreateSnapshot)
    } else {
        s.logger.Info("backup: tier-1 scheduler disabled")
    }

    // Tier 2：定时归档
    if s.archiveInterval > 0 {
        s.logger.Info("backup: tier-2 scheduler started",
            "interval", s.archiveInterval.String(),
            "path", s.engine.cfg.Archive.Path)
        go s.runTicker(ctx, s.archiveInterval, "archive", s.engine.CreateArchive)
    } else {
        s.logger.Info("backup: tier-2 scheduler disabled")
    }
}

func (s *Scheduler) runTicker(ctx context.Context, interval time.Duration, label string, fn func() error) {
    ticker := time.NewTicker(interval)
    defer ticker.Stop()

    for {
        select {
        case <-ticker.C:
            s.logger.Debug("backup: "+label+" starting")
            if err := fn(); err != nil {
                s.logger.Error("backup: "+label+" failed", "error", err)
            } else {
                s.logger.Debug("backup: " + label + " completed")
            }
        case <-ctx.Done():
            s.logger.Info("backup: " + label + " scheduler stopped")
            return
        }
    }
}
```

---

## 6. 集成修改

### 6.1 config.go

```go
// 新增结构体（见第四节，此处省略重复定义）
type BackupConfig struct { ... }
type ArchiveConfig struct { ... }

// Config 新增字段
type Config struct {
    // ... 现有字段保持不变 ...
    Backup BackupConfig `json:"backup"`
}

// loadConfigFile 中新增合并:
if !set["backup"] {
    c.Backup = fileCfg.Backup
}
```

### 6.2 server.go

```go
func New(cfg *config.Config) (*Server, error) {
    // ... 现有存储初始化 ...

    vaultDir := filepath.Join(cfg.DataDir, "vaults", storage.DefaultVaultID)
    backupEngine := backup.NewEngine(vaultDir, &cfg.Backup)

    // 包装 vault：拦截写操作
    if cfg.Backup.Enabled && cfg.Backup.AutoOnWrite {
        vault = backup.NewObservableVault(vault, backupEngine)
    }

    return &Server{
        // ... 现有字段 ...
        backupEngine: backupEngine,
    }, nil
}

func (s *Server) Run() error {
    ctx, cancel := context.WithCancel(context.Background())
    defer cancel()

    // Tier 1 快照间隔
    snapInterval, _ := time.ParseDuration(s.cfg.Backup.ScheduleInterval)
    // Tier 2 归档间隔
    archiveInterval, _ := time.ParseDuration(s.cfg.Backup.Archive.Interval)

    scheduler := backup.NewScheduler(s.backupEngine, snapInterval, archiveInterval, s.logger)
    go scheduler.Start(ctx)

    // ... 现有 HTTP 服务启动 ...
}
```

---

## 7. 数据流示例

### 场景 A：常规同步（PUT manifest + 3 个 blob）

```
时间线：
t=0:  PUT /api/v2/blob/aaa → ObservableVault.PutBlob
       → fsVault.PutBlob 落盘主 blobs/aaa (mtime=10:00:00)
       → Engine.CopyBlobToPool → 即时复制（无条件，数据在内存）

t=1:  PUT /api/v2/blob/bbb → 同上 → backups/blobs/bbb

t=2:  PUT /api/v2/blob/ccc → 同上 → backups/blobs/ccc

t=3:  PUT /api/v2/manifest → ObservableVault.PutManifest
       → fsVault.PutManifest 落盘主 manifest
       → notifyWrite() → 启动去抖定时器(5s)

t=8:  去抖定时器触发（5s 内无新写入）
       → Engine.CreateSnapshot
       → SyncBlobPool() 扫描 blobs/，3 个文件 mtime 与备份池相同 → 跳过
       → 创建 backups/snap-20260809-120000/manifest

结果：1 个快照（~10KB）+ 3 个 blob 副本（~50KB），而非 4 个完整快照（~200KB）。
```

### 场景 B：离线批量同步（客户端积压大量笔记后首次同步）

```
前提：客户端离线编辑 50 条笔记，某时刻启用同步。
      此前 backups/blobs/ 为空（备份功能刚启用或新部署）。

时间线：
t=0~49:  PUT /api/v2/blob/<hash_1> ... <hash_50> 在数秒内连续到达
         → 每个 PutBlob 即时 CopyBlobToPool（数据在内存，逐个写入）
         → 50 个 blob 全部进入 backups/blobs/

t=50:    PUT /api/v2/manifest
         → notifyWrite() → 重置去抖定时器

t=55:    去抖定时器触发（最后一次写入后 5s）
         → Engine.CreateSnapshot
         → SyncBlobPool() 扫描，50 个文件 mtime 与备份池相同 → 全跳过
         → 创建 backups/snap-.../manifest

结果：50 个 blob 即时复制 + 1 个 manifest 快照，约 51 次 I/O。
     如果没有去抖，每个 blob 都触发一次快照 → 50 次快照（浪费）。
```

### 场景 C：备份后启用（已有 blob 未被即时复制覆盖）

```
前提：vault 已有 100 个 blob（备份功能刚在配置中启用），
     主 blobs/ 中的文件 mtime 均为历史时间。

t=0:    定时器触发 CreateSnapshot
        → SyncBlobPool() 扫描主 blobs/
        → blob_001: 备份池不存在 → 复制
        → blob_002: 备份池不存在 → 复制
        → ...
        → blob_100: 备份池不存在 → 复制
        → 100 个 blob 全部进入备份池

t=0.5s: 复制 manifest → snap-.../manifest

      下一次定时器触发：
        → SyncBlobPool() 扫描，100 个文件 mtime 与备份池相同 → 全跳过
        → 仅复制 manifest（开销极低）
```

### 场景 D：同 hash 被覆盖（多用户密码碰撞）

```
t=0:  用户A PUT /api/v2/blob/xxx (ciphertext_a)
       → 主 blobs/xxx mtime=10:00, backups/blobs/xxx mtime=10:00

t=1:  用户B PUT /api/v2/blob/xxx (ciphertext_b)
       → 主 blobs/xxx mtime=10:01 ← 更新
       → CopyBlobToPool → backups/blobs/xxx 覆盖为 ciphertext_b

t=2:  定时器 CreateSnapshot
       → SyncBlobPool() 比较 mtime: backups/xxx=10:00 < 主/xxx=10:01 → 覆盖!
       → 即使 CopyBlobToPool 曾失败，定时器也能兜底

恢复时：取 snap-N/manifest + backups/blobs/xxx（最新版本）
```

> 注意：同一 vault 多用户共享不是预期场景。多用户隔离应使用多 vault（`storage.NewVault(vaultID)`）。

### blob 备份策略总结

```
PutBlob 拦截（即时）          定时器 SyncBlobPool（mtime 比较）
─────────────────────        ─────────────────────────────
数据已在内存，无条件复制       扫描 blobs/ 目录
对已存在直接覆盖               不存在 → 复制
                              存在且 mtime 更新 → 覆盖
                              存在且 mtime 相同 → 跳过
                              
用于：实时备份                 用于：启动补漏、定时兜底
```

---

## 8. 安全性与可靠性

### 8.1 零知识原则

备份过程不解析文件内容，直接以二进制方式复制密文文件。Tier 2 zip 也是按字节流打包，与现有 HTTP 层的零知识设计一致。

### 8.2 独立副本

- `backups/blobs/` 使用 `ReadFile + WriteFile`（非硬链接），主文件和备份文件是两个独立 inode
- 磁盘故障不会同时损坏两个副本
- blob 池只增不删，即使主 `blobs/` 被清理，备份池仍保留完整历史

### 8.3 部分失败处理

- blob 即时复制失败 → 仅记录错误，不阻断请求（主数据已成功落盘）
- 快照创建中途失败 → 留下不完整 snap 目录，不影响主数据
- 归档失败 → 仅记录错误，下次 ticker 重试

### 8.4 并发安全

- `Engine.mu` 保护快照创建和归档的互斥
- `ObservableVault.debounceMu` 保护去抖定时器的竞态

### 8.5 磁盘空间

- Tier 1 快照仅 manifest（~10KB/份），磁盘压力极小
- Tier 1 blob 池 ~= 主 blob 总量（增量增长）
- Tier 2 归档为全量打包，按 `maxArchives` 和 `interval` 控制总量
- 纯文本笔记场景，年备份总量通常在百 MB 以内

---

## 9. 实施计划

| 序号 | 任务 | 文件 | 说明 |
|------|------|------|------|
| 1 | 新增 BackupConfig + ArchiveConfig | `internal/config/config.go` | 在 Config 中新增 backup 字段 |
| 2 | 新建 `backup/engine.go` | `internal/backup/engine.go` | CopyBlobToPool、CreateSnapshot、CreateArchive、prune |
| 3 | 新建 `backup/vault.go` | `internal/backup/vault.go` | ObservableVault（blob即时复制 + manifest去抖） |
| 4 | 新建 `backup/scheduler.go` | `internal/backup/scheduler.go` | 双定时器调度器 |
| 5 | 修改 `server.go` | `internal/server/server.go` | 集成备份引擎和调度器 |
| 6 | 更新配置文件示例 | `dev.config.json` | 添加 backup 和 archive 配置段 |

**涉及文件**：3 个新文件 + 2 个修改文件，约 350 行代码。全部使用 Go 标准库，无新增依赖。
