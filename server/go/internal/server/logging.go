/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

// 结构化日志工具
//
// 使用 Go 1.21+ 标准库 log/slog，输出 JSON 或文本格式的结构化日志。
// 每条日志带时间戳、级别、消息和结构化字段（如 request_id、method、path、status）。
//
// 日志配置：
//   - 级别：debug/info/warn/error（通过 -log-level 或配置文件 logLevel 设置）
//   - 输出：stdout（默认）或文件（通过 -log-file 或配置文件 logFile 设置）
//   - 格式：文本（默认）或 JSON（通过 -log-json 或配置文件 logJSON 设置）
//
// debug 级别会记录完整的请求/响应详情（方法、路径、头、body 大小、状态码、耗时），
// 便于开发调试协议交互问题。
package server

import (
	"io"
	"log/slog"
	"net/http"
	"os"
)

// noopCloser 是一个不执行任何操作的 io.Closer，用于 stdout 日志场景。
type noopCloser struct{}

func (noopCloser) Close() error { return nil }

// NewLogger 创建结构化日志器
//
// 根据 cfg 的日志配置创建：
//   - level：日志级别
//   - file：日志文件路径（空=stdout）
//   - json：是否 JSON 格式
//
// 返回 (logger, closer)：当日志写入文件时 closer 为该文件句柄，调用方应在
// graceful shutdown 时 Close 以释放句柄（修复 L-6）；stdout 场景返回 noopCloser。
func NewLogger(level slog.Level, logFile string, useJSON bool) (*slog.Logger, io.Closer) {
	var w io.Writer = os.Stdout
	var closer io.Closer = noopCloser{}
	if logFile != "" {
		f, err := os.OpenFile(logFile, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
		if err != nil {
			// 文件打开失败降级到 stdout
			os.Stderr.WriteString("warning: open log file failed: " + err.Error() + ", fallback to stdout\n")
		} else {
			w = f
			closer = f
		}
	}

	opts := &slog.HandlerOptions{
		Level: level,
	}
	var handler slog.Handler
	if useJSON {
		handler = slog.NewJSONHandler(w, opts)
	} else {
		handler = slog.NewTextHandler(w, opts)
	}
	return slog.New(handler), closer
}

// statusWriter 包装 http.ResponseWriter，捕获响应状态码和写入字节数用于日志
type statusWriter struct {
	http.ResponseWriter
	status      int
	bytesWritten int
	wroteHead   bool
}

// WriteHeader 捕获状态码
func (w *statusWriter) WriteHeader(status int) {
	if w.wroteHead {
		return // 防止重复 WriteHeader
	}
	w.status = status
	w.wroteHead = true
	w.ResponseWriter.WriteHeader(status)
}

// Write 如果未显式设置状态码，默认记为 200
func (w *statusWriter) Write(b []byte) (int, error) {
	if !w.wroteHead {
		w.status = http.StatusOK
		w.wroteHead = true
	}
	n, err := w.ResponseWriter.Write(b)
	w.bytesWritten += n
	return n, err
}
