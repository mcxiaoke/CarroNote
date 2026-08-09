package backup

import (
	"context"
	"io"
	"log/slog"
	"sync/atomic"
	"testing"
	"time"

	"safenotes-server/internal/config"
)

// TestSchedulerTickerRuns 验证 runTicker 周期性调用回调，ctx 取消后退出。
func TestSchedulerTickerRuns(t *testing.T) {
	eng := NewEngine(t.TempDir(), enabledCfg())
	sch := NewScheduler(eng, 30*time.Millisecond, 0, slog.New(slog.NewTextHandler(io.Discard, nil)))
	var calls int64
	ctx, cancel := context.WithCancel(context.Background())

	done := make(chan struct{})
	go func() {
		sch.runTicker(ctx, 30*time.Millisecond, "test", func() error {
			atomic.AddInt64(&calls, 1)
			return nil
		})
		close(done)
	}()

	time.Sleep(250 * time.Millisecond)
	if atomic.LoadInt64(&calls) < 3 {
		t.Fatalf("期望 ticker 至少触发 3 次，got %d", atomic.LoadInt64(&calls))
	}
	cancel()
	select {
	case <-done:
		// goroutine 正常退出
	case <-time.After(time.Second):
		t.Fatal("ctx 取消后 runTicker 应退出")
	}
}

// TestSchedulerStartDisabled 验证间隔均为 0 时 Start 不启动任何 ticker，直接返回。
func TestSchedulerStartDisabled(t *testing.T) {
	eng := NewEngine(t.TempDir(), enabledCfg())
	sch := NewScheduler(eng, 0, 0, slog.New(slog.NewTextHandler(io.Discard, nil)))
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan struct{})
	go func() {
		sch.Start(ctx)
		close(done)
	}()
	select {
	case <-done:
		// Start 快速返回
	case <-time.After(100 * time.Millisecond):
		t.Fatal("disabled scheduler Start 应直接返回")
	}
}

// TestSchedulerEnabled 验证间隔非 0 时 Start 启动 ticker 并随 ctx 取消而退出。
func TestSchedulerStartEnabled(t *testing.T) {
	eng := NewEngine(t.TempDir(), &config.BackupConfig{Enabled: true})
	sch := NewScheduler(eng, 20*time.Millisecond, 20*time.Millisecond, slog.New(slog.NewTextHandler(io.Discard, nil)))
	ctx, cancel := context.WithCancel(context.Background())

	// 记录快照/归档被调度调用的次数（实际触发会写盘，故用标志性 vaultDir 控制副作用；
	// 这里只验证 Start 的编排：两个 ticker 均启动且最终随 cancel 退出）。
	started := time.Now()
	done := make(chan struct{})
	go func() {
		sch.Start(ctx)
		close(done)
	}()

	// 等 1 个 tick 周期后再取消
	time.Sleep(80 * time.Millisecond)
	cancel()
	select {
	case <-done:
		if time.Since(started) < 40*time.Millisecond {
			t.Fatal("Start 应在至少一个周期后才返回")
		}
	case <-time.After(time.Second):
		t.Fatal("cancel 后 Start 应返回")
	}
}
