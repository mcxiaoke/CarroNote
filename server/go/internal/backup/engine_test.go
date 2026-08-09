package backup

import (
	"archive/tar"
	"archive/zip"
	"compress/gzip"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"safenotes-server/internal/config"
	"safenotes-server/internal/storage"
)

// newTestVault 创建一个真实的文件系统 vault（vault-default）并返回根目录、vault 句柄、engine。
//
// engine 的如未调用本函数，所有子测试都围绕该真实文件系统展开，便于验证与 storage 的集成。
func newTestVault(t *testing.T, cfg *config.BackupConfig) (string, storage.Vault, *Engine) {
	t.Helper()
	root := t.TempDir()
	store, err := storage.NewFileSystem(root)
	if err != nil {
		t.Fatal(err)
	}
	vlt, err := store.NewVault(storage.DefaultVaultID)
	if err != nil {
		t.Fatal(err)
	}
	vaultDir := filepath.Join(root, "vaults", storage.DefaultVaultID)
	return vaultDir, vlt, NewEngine(vaultDir, cfg)
}

func enabledCfg() *config.BackupConfig {
	return &config.BackupConfig{Enabled: true}
}

// ── CopyBlobToPool ──

func TestCopyBlobToPool(t *testing.T) {
	t.Run("disabled no-op", func(t *testing.T) {
		_, _, eng := newTestVault(t, &config.BackupConfig{Enabled: false})
		if err := eng.CopyBlobToPool("abc", []byte("data")); err != nil {
			t.Fatal(err)
		}
		if _, err := os.Stat(eng.BackupBlobsDir()); err == nil {
			t.Fatal("备份禁用时不应创建备份 blobs 目录")
		}
	})

	t.Run("copies content", func(t *testing.T) {
		_, _, eng := newTestVault(t, enabledCfg())
		data := []byte("ciphertext-blob-a")
		if err := eng.CopyBlobToPool("abc", data); err != nil {
			t.Fatal(err)
		}
		got, err := os.ReadFile(filepath.Join(eng.BackupBlobsDir(), "abc"))
		if err != nil {
			t.Fatal(err)
		}
		if string(got) != string(data) {
			t.Fatalf("backup 池内容不一致: got %q want %q", got, data)
		}
	})
}

// ── SyncBlobPool ──

func TestSyncBlobPool(t *testing.T) {
	t.Run("空 blobs 目录返回 nil", func(t *testing.T) {
		_, _, eng := newTestVault(t, enabledCfg())
		if err := eng.SyncBlobPool(); err != nil {
			t.Fatalf("期望 nil，got %v", err)
		}
	})

	t.Run("新增 blob 复制到备份池", func(t *testing.T) {
		_, vlt, eng := newTestVault(t, enabledCfg())
		data := []byte("blob-new")
		if err := vlt.PutBlob("aaa", data); err != nil {
			t.Fatal(err)
		}
		if err := eng.SyncBlobPool(); err != nil {
			t.Fatal(err)
		}
		got, err := os.ReadFile(filepath.Join(eng.BackupBlobsDir(), "aaa"))
		if err != nil {
			t.Fatal(err)
		}
		if string(got) != string(data) {
			t.Fatalf("got %q want %q", got, data)
		}
	})

	t.Run("主 blob 更新则覆盖，相同 mtime 跳过", func(t *testing.T) {
		_, vlt, eng := newTestVault(t, enabledCfg())
		fixed := time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC)
		mainBlobs := filepath.Join(vaultDirOf(eng), "blobs")
		mainPath := filepath.Join(mainBlobs, "aaa")

// 先在备份池写入旧内容，并把 mtime 设为过去
		if err := os.MkdirAll(eng.BackupBlobsDir(), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(eng.BackupBlobsDir(), "aaa"), []byte("old"), 0o644); err != nil {
			t.Fatal(err)
		}
		old := time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC)
		os.Chtimes(filepath.Join(eng.BackupBlobsDir(), "aaa"), old, old)

		// 主文件内容更新，mtime 晚于池中
		if err := vlt.PutBlob("aaa", []byte("new")); err != nil {
			t.Fatal(err)
		}
		os.Chtimes(mainPath, fixed, fixed) // 2025 > 2020 → 应覆盖

		if err := eng.SyncBlobPool(); err != nil {
			t.Fatal(err)
		}
		got, _ := os.ReadFile(filepath.Join(eng.BackupBlobsDir(), "aaa"))
		if string(got) != "new" {
			t.Fatalf("主文件更新后应覆盖备份池: got %q want %q", got, "new")
		}

		// 现在主文件再次修改，但备份池 mtime 与其相同 → 跳过
		if err := vlt.PutBlob("aaa", []byte("new2")); err != nil {
			t.Fatal(err)
		}
		os.Chtimes(mainPath, fixed, fixed)
		os.Chtimes(filepath.Join(eng.BackupBlobsDir(), "aaa"), fixed, fixed)
		if err := eng.SyncBlobPool(); err != nil {
			t.Fatal(err)
		}
		got, _ = os.ReadFile(filepath.Join(eng.BackupBlobsDir(), "aaa"))
		if string(got) != "new" {
			t.Fatalf("mtime 相同应跳过: got %q want %q", got, "new")
		}
	})
}

// vaultDirOf 从 engine 反推 vault 目录（engine.vaultDir）
func vaultDirOf(eng *Engine) string { return eng.vaultDir }

// ── CreateSnapshot ──

// listSnapshots 返回 backupDir 下所有 snap-* 目录名（backups 目录不存在时返回空）。
func listSnapshots(t *testing.T, eng *Engine) []string {
	t.Helper()
	entries, err := os.ReadDir(eng.backupDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		t.Fatal(err)
	}
	var snaps []string
	for _, e := range entries {
		if e.IsDir() && strings.HasPrefix(e.Name(), "snap-") {
			snaps = append(snaps, e.Name())
		}
	}
	return snaps
}

func TestCreateSnapshot(t *testing.T) {
	t.Run("快照含 manifest，且先同步 blob 池", func(t *testing.T) {
		_, vlt, eng := newTestVault(t, enabledCfg())
		if err := vlt.PutBlob("aaa", []byte("blob-data")); err != nil {
			t.Fatal(err)
		}
		if err := vlt.PutManifest([]byte("manifest-v1"), storage.PutOptions{}); err != nil {
			t.Fatal(err)
		}
		if err := eng.CreateSnapshot(); err != nil {
			t.Fatal(err)
		}
		snaps := listSnapshots(t, eng)
		if len(snaps) != 1 {
			t.Fatalf("期望 1 个快照，got %d", len(snaps))
		}
		// manifest 已复制进快照
		got, err := os.ReadFile(filepath.Join(eng.backupDir, snaps[0], "manifest"))
		if err != nil {
			t.Fatal(err)
		}
		if string(got) != "manifest-v1" {
			t.Fatalf("快照 manifest 内容: got %q", got)
		}
		// blob 池已同步（兜底路径）
		if _, err := os.Stat(filepath.Join(eng.BackupBlobsDir(), "aaa")); err != nil {
			t.Fatalf("快照应同步 blob 池: %v", err)
		}
	})

	t.Run("空 vault 无 manifest 不报错", func(t *testing.T) {
		_, _, eng := newTestVault(t, enabledCfg())
		if err := eng.CreateSnapshot(); err != nil {
			t.Fatalf("空 vault 快照不应报错: %v", err)
		}
		if len(listSnapshots(t, eng)) != 1 {
			t.Fatal("期望生成 1 个空快照目录")
		}
	})

	t.Run("禁用时 no-op", func(t *testing.T) {
		_, _, eng := newTestVault(t, &config.BackupConfig{Enabled: false})
		if err := eng.CreateSnapshot(); err != nil {
			t.Fatal(err)
		}
		if _, err := os.Stat(eng.backupDir); err == nil {
			t.Fatal("禁用备份时不应创建 backups 目录")
		}
	})
}

func TestPruneSnapshotsByCount(t *testing.T) {
	_, _, eng := newTestVault(t, &config.BackupConfig{Enabled: true, MaxSnapshots: 2})
	// 手工制造 5 个快照目录（名字严格递增）
	for i := 0; i < 5; i++ {
		name := "snap-20260809-12000" + string(rune('0'+i))
		if err := os.MkdirAll(filepath.Join(eng.backupDir, name), 0o755); err != nil {
			t.Fatal(err)
		}
	}
eng.pruneSnapshots()
	left := listSnapshots(t, eng)
	if len(left) != 2 {
		t.Fatalf("期望保留 2 份，got %d", len(left))
	}
	// 应保留最新的两个（120003、120004）
	if left[0] != "snap-20260809-120003" || left[1] != "snap-20260809-120004" {
		t.Fatalf("期望保留最新两份，got %v", left)
	}
}

func TestPruneSnapshotsByRetention(t *testing.T) {
	_, _, eng := newTestVault(t, &config.BackupConfig{Enabled: true, RetentionDays: 7})
	// 一个近期 + 一个 30 天前的
	recent := "snap-" + time.Now().UTC().Format("20060102-150405")
	old := "snap-" + time.Now().AddDate(0, 0, -30).UTC().Format("20060102-150405")
	for _, name := range []string{recent, old} {
		if err := os.MkdirAll(filepath.Join(eng.backupDir, name), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	eng.pruneSnapshots()
	left := listSnapshots(t, eng)
	if len(left) != 1 || left[0] != recent {
		t.Fatalf("期望只保留近期快照, got %v", left)
	}
}

// ── CreateArchive ──

func readZipNames(t *testing.T, zipPath string) []string {
	t.Helper()
	zr, err := zip.OpenReader(zipPath)
	if err != nil {
		t.Fatal(err)
	}
	defer zr.Close()
	var names []string
	for _, f := range zr.File {
		names = append(names, f.Name)
	}
	return names
}

func listArchives(t *testing.T, dir string) []string {
	t.Helper()
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		t.Fatal(err)
	}
	var names []string
	for _, e := range entries {
		if !e.IsDir() && strings.HasPrefix(e.Name(), "vault-") {
			names = append(names, e.Name())
		}
	}
	return names
}

func TestCreateArchive(t *testing.T) {
t.Run("禁用归档 no-op", func(t *testing.T) {
		_, vlt, eng := newTestVault(t, enabledCfg()) // Archive 默认禁用
		archivePath := filepath.Join(t.TempDir(), "out")
		eng.cfg.Archive = config.ArchiveConfig{Enabled: false, Path: archivePath, Format: "zip"}
		if err := vlt.PutManifest([]byte("m"), storage.PutOptions{}); err != nil {
			t.Fatal(err)
		}
		if err := eng.CreateArchive(); err != nil {
			t.Fatal(err)
		}
		if len(listArchives(t, archivePath)) != 0 {
			t.Fatal("归档禁用时不应产生归档文件")
		}
	})

	t.Run("归档路径未配置报错", func(t *testing.T) {
		_, vlt, eng := newTestVault(t, enabledCfg())
		eng.cfg.Archive = config.ArchiveConfig{Enabled: true, Path: ""}
		if err := vlt.PutManifest([]byte("manifest"), storage.PutOptions{}); err != nil {
			t.Fatal(err)
		}
		if err := eng.CreateArchive(); err == nil {
			t.Fatal("期望归档路径未配置时返回错误")
		}
	})

	t.Run("zip 归档排除 backups 自身", func(t *testing.T) {
		_, vlt, eng := newTestVault(t, enabledCfg())
		archivePath := filepath.Join(t.TempDir(), "out")
		eng.cfg.Archive = config.ArchiveConfig{Enabled: true, Path: archivePath, Format: "zip"}
		if err := vlt.PutManifest([]byte("manifestV2"), storage.PutOptions{}); err != nil {
			t.Fatal(err)
		}
		if err := vlt.PutBlob("zzz", []byte("blob")); err != nil {
			t.Fatal(err)
		}
		if err := eng.CopyBlobToPool("zzz", []byte("blob")); err != nil {
			t.Fatal(err)
		}
		if err := eng.CreateSnapshot(); err != nil {
			t.Fatal(err)
		}
		if err := eng.CreateArchive(); err != nil {
			t.Fatal(err)
		}
		archives := listArchives(t, archivePath)
		if len(archives) != 1 {
			t.Fatalf("期望 1 个归档，got %v", archives)
		}
		names := readZipNames(t, filepath.Join(archivePath, archives[0]))
		joined := strings.Join(names, ",")
		if !strings.Contains(joined, "manifest") || !strings.Contains(joined, "blobs/zzz") {
			t.Fatalf("归档应包含 manifest 与 blobs/zzz: %v", names)
		}
		for _, n := range names {
			if strings.HasPrefix(n, "backups") {
				t.Fatalf("归档不应包含 backups: %v", names)
			}
		}
	})

	t.Run("tar.gz 归档可被解压", func(t *testing.T) {
		_, vlt, eng := newTestVault(t, enabledCfg())
		archivePath := filepath.Join(t.TempDir(), "out")
		eng.cfg.Archive = config.ArchiveConfig{Enabled: true, Path: archivePath, Format: "tar.gz"}
		if err := vlt.PutManifest([]byte("manifest"), storage.PutOptions{}); err != nil {
			t.Fatal(err)
		}
		if err := eng.CreateArchive(); err != nil {
			t.Fatal(err)
		}
		archives := listArchives(t, archivePath)
		if len(archives) != 1 || !strings.HasSuffix(archives[0], ".tar.gz") {
			t.Fatalf("期望 1 个 .tar.gz 归档，got %v", archives)
		}
		f, err := os.Open(filepath.Join(archivePath, archives[0]))
		if err != nil {
			t.Fatal(err)
		}
		defer f.Close()
		gz, err := gzip.NewReader(f)
		if err != nil {
			t.Fatal(err)
		}
		tr := tar.NewReader(gz)
		for {
			hdr, err := tr.Next()
			if err == io.EOF {
				break
			}
			if err != nil {
				t.Fatal(err)
			}
			if hdr.Name == "manifest" {
				return // 找到 manifest → 通过
			}
		}
		t.Fatal("tar.gz 归档中缺少 manifest")
	})

t.Run("pruneArchives 按数量清理", func(t *testing.T) {
		_, _, eng := newTestVault(t, enabledCfg())
		archivePath := filepath.Join(t.TempDir(), "out")
		if err := os.MkdirAll(archivePath, 0o755); err != nil {
			t.Fatal(err)
		}
		eng.cfg.Archive = config.ArchiveConfig{Enabled: true, Path: archivePath, Format: "zip", MaxArchives: 2}
		for i := 0; i < 5; i++ {
			name := "vault-20260801-12000" + string(rune('0'+i)) + ".zip"
			if err := os.WriteFile(filepath.Join(archivePath, name), []byte("x"), 0o644); err != nil {
				t.Fatal(err)
			}
		}
		eng.pruneArchives()
		left := listArchives(t, archivePath)
		if len(left) != 2 {
			t.Fatalf("期望保留 2 份归档，got %v", left)
		}
	})
}
