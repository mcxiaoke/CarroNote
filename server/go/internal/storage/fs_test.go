package storage

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

// TestValidateVaultPathTraversal 验证路径穿越防护（允许子目录，禁止逃逸）。
func TestValidateVaultPathTraversal(t *testing.T) {
	valid := []string{"blobs/abc", "manifest", "blobs-orphan/x.y", "a/b/c", "manifest.bak-0"}
	for _, rel := range valid {
		if err := ValidateVaultPath(rel); err != nil {
			t.Errorf("期望合法却被拒: %q (%v)", rel, err)
		}
	}
	invalid := []string{
		"",           // 空
		"..",         // 直接父目录
		"../etc",     // 上逃
		"a/../../b",  // 段内逃逸
		"/abs/path",  // 绝对路径
		"C:\\win",    // Windows 盘符
		"a\x00b",     // NUL 字节
	}
	for _, rel := range invalid {
		if err := ValidateVaultPath(rel); err == nil {
			t.Errorf("期望非法却通过: %q", rel)
		}
	}
}

// TestAtomicWriteConcurrent 验证并发写同一目标不会得到交错损坏的数据（修复 C-3）。
//
// 唯一随机后缀临时文件保证并发写入互不截断；最终落盘的内容必然是某个写入者的
// 完整内容（或初始内容），绝不允许字节交错。
//
// 注：Windows 下并发 rename 到同一目标可能偶发返回操作系统级 Access Denied（rename
// 失败=该次请求返回错误，客户端重试即可），这属于失败而非损坏；因此本测试只断言
// 「最终内容不被损坏」，不要求每次 rename 都必须成功。
func TestAtomicWriteConcurrent(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "blob")

	// 预先写入一个合法初始内容，确保最终一定可读
	initial := []byte("initial-content")
	if err := os.WriteFile(target, initial, 0o644); err != nil {
		t.Fatal(err)
	}

	const n = 30
	errCh := make(chan error, n)
	for i := 0; i < n; i++ {
		go func(i int) {
			data := []byte(fmt.Sprintf("content-%d", i))
			errCh <- atomicWrite(target, data, 0o644)
		}(i)
	}
	var errCount int
	for i := 0; i < n; i++ {
		if err := <-errCh; err != nil {
			errCount++
		}
	}
	if errCount > 0 {
		t.Logf("%d 次并发 rename 因操作系统竞争失败（属预期内的失败而非损坏），已忽略", errCount)
	}

	got, err := os.ReadFile(target)
	if err != nil {
		t.Fatalf("read final: %v", err)
	}
	// 最终内容必须是某个 goroutine 的完整写入或初始内容，不允许字节交错损坏。
	valid := map[string]bool{string(initial): true}
	for i := 0; i < n; i++ {
		valid[fmt.Sprintf("content-%d", i)] = true
	}
	if !valid[string(got)] {
		t.Fatalf("检测到损坏内容: %q", got)
	}
}

// TestAtomicWriteDurability 验证写入落盘后内容可读且一致。
func TestAtomicWriteDurability(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "m")
	want := []byte("hello-safenotes")
	if err := atomicWrite(target, want, 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(target)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(want) {
		t.Fatalf("got %q want %q", got, want)
	}
}
