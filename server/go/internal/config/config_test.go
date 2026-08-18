/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

package config

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// TestDurationJSON 验证自定义 duration 类型支持字符串与数字两种 JSON 形式（修复 S-1）。
func TestDurationJSON(t *testing.T) {
	// 字符串形式
	var d duration
	if err := json.Unmarshal([]byte(`"60s"`), &d); err != nil {
		t.Fatal(err)
	}
	if d.Std() != 60*time.Second {
		t.Fatalf("string form: got %v, want 60s", d.Std())
	}

	// 数字纳秒形式（兼容旧格式）
	var d2 duration
	if err := json.Unmarshal([]byte("1000000000"), &d2); err != nil {
		t.Fatal(err)
	}
	if d2.Std() != time.Second {
		t.Fatalf("number form: got %v, want 1s", d2.Std())
	}

	// 序列化输出字符串（Go 规范形式：60s => "1m0s"，仍是合法可回解析的 duration）
	b, err := json.Marshal(d)
	if err != nil {
		t.Fatal(err)
	}
	if string(b) != `"1m0s"` {
		t.Fatalf("marshal: got %s, want \"1m0s\"", b)
	}

	// 非法字符串应报错（而非静默失败）
	var d3 duration
	if err := json.Unmarshal([]byte(`"not-a-duration"`), &d3); err == nil {
		t.Fatal("expected error for invalid duration string")
	}
}

// TestLoadConfigFileDurationString 验证带 "60s" 的配置文件能被正确加载（复现 S-1 修复）。
func TestLoadConfigFileDurationString(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "c.json")
	content := `{"readTimeout":"60s","writeTimeout":"60s","idleTimeout":"120s","token":"strong","rateLimit":10}`
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	c := Default()
	if err := loadConfigFile(c, p, map[string]bool{}); err != nil {
		t.Fatal(err)
	}
	if c.ReadTimeout.Std() != 60*time.Second {
		t.Fatalf("readTimeout: got %v", c.ReadTimeout.Std())
	}
	if c.Token != "strong" {
		t.Fatalf("token: got %q", c.Token)
	}
	if c.RateLimit != 10 {
		t.Fatalf("rateLimit: got %d", c.RateLimit)
	}
}

// TestLoadConfigFilePriority 验证 CLI 显式设置的字段不被配置文件覆盖（修复 M-1）。
func TestLoadConfigFilePriority(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "c.json")
	content := `{"addr":":5000","token":"file-token","rateLimit":5,"readTimeout":"30s"}`
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}

	c := Default()
	// 模拟命令行显式设置了 addr（对应 flag 名 "addr"）
	set := map[string]bool{"addr": true}
	if err := loadConfigFile(c, p, set); err != nil {
		t.Fatal(err)
	}

	// addr 被 CLI 显式设置 → 不被文件覆盖（保持默认值 :4080）
	if c.Addr != Default().Addr {
		t.Fatalf("addr 不应被文件覆盖，got %q", c.Addr)
	}
	// token / rateLimit / readTimeout 未被 CLI 设置 → 取文件值
	if c.Token != "file-token" {
		t.Fatalf("token 应取文件值，got %q", c.Token)
	}
	if c.RateLimit != 5 {
		t.Fatalf("rateLimit 应取文件值，got %d", c.RateLimit)
	}
	if c.ReadTimeout.Std() != 30*time.Second {
		t.Fatalf("readTimeout 应取文件值，got %v", c.ReadTimeout.Std())
	}
}

// TestLoadConfigFileBackup 验证配置文件中 backup 段被正确合并（含归档子配置）。
func TestLoadConfigFileBackup(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "c.json")
	content := `{
		"token":"strong",
		"backup": {
			"enabled": true,
			"scheduleInterval": "1h",
			"autoOnWrite": true,
			"writeDebounceMs": 3000,
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
	}`
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	c := Default()
	if err := loadConfigFile(c, p, map[string]bool{}); err != nil {
		t.Fatal(err)
	}
	b := c.Backup
	if !b.Enabled || b.ScheduleInterval != "1h" || !b.AutoOnWrite || b.WriteDebounceMs != 3000 {
		t.Fatalf("backup 配置未正确合并: %+v", b)
	}
	if b.MaxSnapshots != 24 || b.RetentionDays != 7 {
		t.Fatalf("backup 清理参数未正确合并: %+v", b)
	}
	a := b.Archive
	if !a.Enabled || a.Interval != "24h" || a.Path != "D:/Backup/safenotes" || a.Format != "zip" || a.MaxArchives != 30 {
		t.Fatalf("archive 配置未正确合并: %+v", a)
	}
}

// TestLoadConfigFileNoBackupKeepsDisabled 验证配置文件不含 backup 段时保持默认禁用。
func TestLoadConfigFileNoBackupKeepsDisabled(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "c.json")
	content := `{"token":"strong"}`
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	c := Default()
	if err := loadConfigFile(c, p, map[string]bool{}); err != nil {
		t.Fatal(err)
	}
	// 不含 backup 字段时 fileCfg.Backup 为零值，而备份默认值本身即零值（全部关闭），
	// 因此语义一致：备份默认不启用。
	if c.Backup.Enabled || c.Backup.AutoOnWrite || c.Backup.ScheduleInterval != "" {
		t.Fatalf("backup 默认应为关闭: %+v", c.Backup)
	}
}

// TestLoadConfigFileFatalOnBadDuration 验证非法 duration 会让 loadConfigFile 报错，
// 从而由调用方非零退出（避免静默回退弱 token，修复 S-1）。
func TestLoadConfigFileFatalOnBadDuration(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "bad.json")
	content := `{"readTimeout":"not-duration"}`
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	c := Default()
	if err := loadConfigFile(c, p, map[string]bool{}); err == nil {
		t.Fatal("期望 loadConfigFile 因非法 duration 返回错误")
	}
}
