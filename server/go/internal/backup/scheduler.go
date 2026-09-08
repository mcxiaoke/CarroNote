/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

// 定时备份调度器：两个独立 ticker（Tier 1 快照 + Tier 2 归档）
package backup

import (
	"context"
	"log/slog"
	"time"
)

// Scheduler 定时备份调度器
//
// Start 在独立 goroutine 中运行两个 ticker：
//   - Tier 1：snapInterval 触发生成 manifest 快照（轻量，~10KB/份）
//   - Tier 2：archiveInterval 触发全量归档（zip/tar.gz）
//
// 任一失败只记日志不退出，等下一个 tick 自动重试。
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

// Start 启动定时循环（阻塞，应在独立 goroutine 中运行）
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
	// Start 自身不持锁，返回后调用方可等待 ctx 取消
}

func (s *Scheduler) runTicker(ctx context.Context, interval time.Duration, label string, fn func() error) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ticker.C:
			s.logger.Debug("backup: " + label + " starting")
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

