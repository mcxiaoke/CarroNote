/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

package backup

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"wsns/internal/config"
	"wsns/internal/storage"
)

// newObservableVault 创建真实 fsVault + ObservableVault 包装（engine 的 vaultDir 与 inner 一致）。
func newObservableVault(t *testing.T, cfg *config.BackupConfig) (*Engine, *ObservableVault, storage.Vault) {
	t.Helper()
	if cfg.WriteDebounceMs == 0 {
		cfg.WriteDebounceMs = 100 // 测试用短去抖
	}
	_, inner, eng := newTestVault(t, cfg)
	return eng, NewObservableVault(inner, eng), inner
}

func TestObservableVault(t *testing.T) {
	t.Run("PutBlob 即时复制", func(t *testing.T) {
		_, ov, _ := newObservableVault(t, enabledCfg())
		if err := ov.PutBlob("ccc", []byte("payload")); err != nil {
			t.Fatal(err)
		}
		got, err := os.ReadFile(filepath.Join(ov.engine.BackupBlobsDir(), "ccc"))
		if err != nil {
			t.Fatal(err)
		}
		if string(got) != "payload" {
			t.Fatalf("blob 即时复制失败: got %q", got)
		}
	})

	t.Run("PutBlob 禁用备份不复制", func(t *testing.T) {
		_, ov, _ := newObservableVault(t, &config.BackupConfig{Enabled: false, WriteDebounceMs: 100})
		if err := ov.PutBlob("ccc", []byte("payload")); err != nil {
			t.Fatal(err)
		}
		if _, err := os.Stat(ov.engine.BackupBlobsDir()); err == nil {
			t.Fatal("禁用备份不应复制到备份池")
		}
	})

	t.Run("PutResource blobs/ 路径即时复制，其它路径不复制", func(t *testing.T) {
		_, ov, _ := newObservableVault(t, enabledCfg())
		if err := ov.PutResource("blobs/xyz", []byte("blob-data"), storage.PutOptions{}); err != nil {
			t.Fatal(err)
		}
		if got, err := os.ReadFile(filepath.Join(ov.engine.BackupBlobsDir(), "xyz")); err != nil || string(got) != "blob-data" {
			t.Fatalf("blobs/ 路径应复制: got %q err %v", got, err)
		}
		if err := ov.PutResource("notes/a.txt", []byte("other"), storage.PutOptions{}); err != nil {
			t.Fatal(err)
		}
		if _, err := os.Stat(filepath.Join(ov.engine.BackupBlobsDir(), "a.txt")); err == nil {
			t.Fatal("非 blobs/ 路径不应复制到 blob 备份池")
		}
	})

	t.Run("PutManifest 去抖后创建快照", func(t *testing.T) {
		_, ov, _ := newObservableVault(t, &config.BackupConfig{
			Enabled: true, AutoOnWrite: true, WriteDebounceMs: 150,
		})
		if err := ov.PutManifest([]byte("m1"), storage.PutOptions{}); err != nil {
			t.Fatal(err)
		}
		// 去抖内不应有快照目录
		if len(listSnapshots(t, ov.engine)) != 0 {
			t.Fatal("去抖窗口内不应产生快照")
		}
		<-time.After(400 * time.Millisecond)
		snaps := listSnapshots(t, ov.engine)
		if len(snaps) != 1 {
			t.Fatalf("期望去抖后 1 个快照，got %d", len(snaps))
		}
		got, err := os.ReadFile(filepath.Join(ov.engine.backupDir, snaps[0], "manifest"))
		if err != nil {
			t.Fatal(err)
		}
		if string(got) != "m1" {
			t.Fatalf("快照 manifest: got %q", got)
		}
	})

	t.Run("连续写入合并为单个快照", func(t *testing.T) {
		_, ov, _ := newObservableVault(t, &config.BackupConfig{
			Enabled: true, AutoOnWrite: true, WriteDebounceMs: 100,
		})
		for i := 0; i < 3; i++ {
			if err := ov.PutManifest([]byte("m"), storage.PutOptions{}); err != nil {
				t.Fatal(err)
			}
			<-time.After(30 * time.Millisecond) // 间隔小于去抖窗口
		}
		<-time.After(300 * time.Millisecond)
		if n := len(listSnapshots(t, ov.engine)); n != 1 {
			t.Fatalf("去抖应合并为 1 个快照，got %d", n)
		}
	})

	t.Run("autoOnWrite 关闭时不触发快照", func(t *testing.T) {
		_, ov, _ := newObservableVault(t, &config.BackupConfig{
			Enabled: true, AutoOnWrite: false, WriteDebounceMs: 100,
		})
		if err := ov.PutManifest([]byte("m"), storage.PutOptions{}); err != nil {
			t.Fatal(err)
		}
		<-time.After(300 * time.Millisecond)
		if n := len(listSnapshots(t, ov.engine)); n != 0 {
			t.Fatalf("autoOnWrite=false 不应产生快照，got %d", n)
		}
	})

	t.Run("备份禁用时不触发快照", func(t *testing.T) {
		_, ov, _ := newObservableVault(t, &config.BackupConfig{
			Enabled: false, AutoOnWrite: true, WriteDebounceMs: 100,
		})
		if err := ov.PutManifest([]byte("x"), storage.PutOptions{}); err != nil {
			t.Fatal(err)
		}
		<-time.After(300 * time.Millisecond)
		if _, err := os.Stat(ov.engine.backupDir); err == nil {
			t.Fatal("禁用备份不应创建快照目录")
		}
	})

	t.Run("Stop 阻止幽灵快照", func(t *testing.T) {
		_, ov, _ := newObservableVault(t, &config.BackupConfig{
			Enabled: true, AutoOnWrite: true, WriteDebounceMs: 100,
		})
		if err := ov.PutManifest([]byte("x"), storage.PutOptions{}); err != nil {
			t.Fatal(err)
		}
		ov.Stop()
		<-time.After(250 * time.Millisecond)
		if n := len(listSnapshots(t, ov.engine)); n != 0 {
			t.Fatalf("Stop 后不应再触发快照，got %d", n)
		}
	})
}

