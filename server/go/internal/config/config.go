/*
* Copyright (C) mcxiaoke 2026 - All Rights Reserved.
*
* SPDX-License-Identifier: GPL-3.0-or-later
* You may use, distribute and modify this code under the
* terms of the GPL-3.0+ license.

*/

// Package config 处理 SafeServer 的配置
//
// 配置来源：命令行参数（flag）+ 可选 JSON 配置文件（-config path）+ 环境变量。
// 优先级：命令行 flag（显式）> 环境变量 > 配置文件 > 默认值。
package config

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"log/slog"
	"os"
	"time"
)

// duration 是对 time.Duration 的封装，支持 JSON 中以字符串（"60s"）或数字（纳秒）形式解析，
// 同时实现 flag.Value 接口，供命令行 -read-timeout 等使用。
//
// 修复 S-1：旧实现直接用 time.Duration 字段接收 JSON，无法解析 "60s" 形式的字符串，
// 导致整个配置文件解析失败并静默回退到弱默认 token。
type duration time.Duration

// Std 返回原生 time.Duration，方便在 http.Server 等处直接使用。
func (d duration) Std() time.Duration { return time.Duration(d) }

// UnmarshalJSON 支持字符串（"60s"）与数字（纳秒）两种形式。
func (d *duration) UnmarshalJSON(b []byte) error {
	var v interface{}
	if err := json.Unmarshal(b, &v); err != nil {
		return err
	}
	switch val := v.(type) {
	case float64: // 数字纳秒（兼容旧格式）
		*d = duration(time.Duration(val))
	case string: // "60s" / "1m" 等
		if val == "" {
			return nil
		}
		parsed, err := time.ParseDuration(val)
		if err != nil {
			return fmt.Errorf("invalid duration %q: %w", val, err)
		}
		*d = duration(parsed)
	default:
		return fmt.Errorf("invalid duration: %v", v)
	}
	return nil
}

// MarshalJSON 输出字符串形式（如 "60s"），便于配置回写与阅读。
func (d duration) MarshalJSON() ([]byte, error) {
	return json.Marshal(d.Std().String())
}

// Set 实现 flag.Value 接口，支持命令行以 "60s" 形式传入。
func (d *duration) Set(s string) error {
	parsed, err := time.ParseDuration(s)
	if err != nil {
		return err
	}
	*d = duration(parsed)
	return nil
}

// String 实现 flag.Value 接口。
func (d duration) String() string { return d.Std().String() }

// Config 是 SafeServer 的运行配置
type Config struct {
	Addr         string  `json:"addr"`         // 监听地址
	DataDir      string  `json:"dataDir"`      // 数据存储根目录
	Token        string  `json:"token"`        // Bearer Token（认证用）
	RateLimit    int     `json:"rateLimit"`    // 每分钟允许的认证失败次数（<=0 禁用，建议用 -1 显式禁用）
	MaxBodyBytes int64   `json:"maxBodyBytes"` // 请求体最大大小（字节，防恶意大文件上传）
	ReadTimeout  duration `json:"readTimeout"`  // HTTP 读超时（含 body）
	WriteTimeout duration `json:"writeTimeout"` // HTTP 写超时
	IdleTimeout  duration `json:"idleTimeout"`  // HTTP 空闲连接超时

	// BehindProxy 是否位于可信反向代理之后。
	// 仅当开启时才信任 X-Forwarded-For（且只取最右一跳），否则一律使用 RemoteAddr。
	// 直连公网时务必保持默认关闭，否则攻击者可伪造 XFF 绕过限速（修复 C-1）。
	BehindProxy bool `json:"behindProxy"`

	// TLS 配置：同时设置 CertFile 与 KeyFile 时启用 HTTPS（修复 L-1）。
	// 为空则明文 HTTP，启动时打印告警，禁止公网裸跑。
	CertFile string `json:"certFile"` // TLS 证书路径
	KeyFile  string `json:"keyFile"`  // TLS 私钥路径

	// 配置：备份（开发调试用）
	LogLevel    slog.Level `json:"-"`        // 日志级别（不直接 JSON 序列化，用 LogLevel 字符串）
	LogLevelStr string     `json:"logLevel"` // 日志级别字符串："debug"/"info"/"warn"/"error"
	LogFile     string     `json:"logFile"`  // 日志文件路径（空=stdout）
	LogJSON     bool       `json:"logJSON"`  // 是否输出 JSON 格式日志（true=JSON，false=文本）

	// Backup 备份配置（Tier 1 快照 + Tier 2 归档，见 docs/server-backup-design.md）
	Backup BackupConfig `json:"backup"`
}

// BackupConfig 是 Tier 1 备份配置（manifest 快照 + blob 副本池）
//
// 零值即文档默认值（全部关闭/不限制），故 Default() 无需填充。
type BackupConfig struct {
	Enabled          bool          `json:"enabled"`          // 是否启用备份
	ScheduleInterval string        `json:"scheduleInterval"` // 定时快照间隔（"1h"/"6h"，空=仅写入触发）
	AutoOnWrite      bool          `json:"autoOnWrite"`      // 写入后去抖触发快照
	WriteDebounceMs  int           `json:"writeDebounceMs"`  // 写入去抖间隔（毫秒，默认 5000）
	MaxSnapshots     int           `json:"maxSnapshots"`     // 最多保留快照数（0=不限）
	RetentionDays    int           `json:"retentionDays"`    // 保留天数（0=不限）
	Archive          ArchiveConfig `json:"archive"`          // Tier 2 归档配置
}

// ArchiveConfig 是 Tier 2 归档配置（全量打包导出到外部路径）
//
// 零值即"默认值"（Enabled=false / Interval="" / Format="zip" / MaxArchives=0）。
type ArchiveConfig struct {
	Enabled     bool   `json:"enabled"`     // 是否启用归档
	Interval    string `json:"interval"`    // 归档间隔（"24h"/"12h"，空=不启用）
	Path        string `json:"path"`        // 输出目录（可跨磁盘/网络映射）
	Format      string `json:"format"`      // "zip" 或 "tar.gz"（空=zip）
	MaxArchives int    `json:"maxArchives"` // 保留份数（0=不限）
}

// DefaultToken 是默认的弱 Token，仅用于本地开发未配置时的兜底。
// 任何生产/非默认场景都应通过 -token / 环境变量 / 配置文件覆盖它。
const DefaultToken = "my-secret-token"

// Default 返回默认配置
func Default() *Config {
	return &Config{
		Addr:         ":4080",
		DataDir:      "./data",
		Token:        DefaultToken,
		RateLimit:    10,
		MaxBodyBytes: 64 << 20, // 64MB
		ReadTimeout:  duration(60 * time.Second),
		WriteTimeout: duration(60 * time.Second),
		IdleTimeout:  duration(120 * time.Second),
		LogLevelStr:  "info",
		LogFile:      "", // 默认 stdout
		LogJSON:      false,
	}
}

// ParseFlags 解析命令行参数
//
// 参数优先级：命令行 flag（显式）> 环境变量 > 配置文件 > 默认值。
func ParseFlags() *Config {
	c := Default()

	var configFile string
	// 记录显式设置的 flag，供配置文件合并时判断优先级（修复 M-1）
	set := map[string]bool{}

	flag.StringVar(&configFile, "config", "", "配置文件路径（JSON，可选，用于开发调试场景）")
	flag.StringVar(&c.Addr, "addr", c.Addr, "监听地址")
	flag.StringVar(&c.DataDir, "data", c.DataDir, "数据存储目录")
	flag.StringVar(&c.Token, "token", c.Token, "Bearer Token（认证用）")
	flag.IntVar(&c.RateLimit, "rate-limit", c.RateLimit, "每分钟允许的认证失败次数（<=0 禁用，建议用 -1）")
	flag.Int64Var(&c.MaxBodyBytes, "max-body", c.MaxBodyBytes, "请求体最大大小（字节，默认 64MB）")
	flag.Var(&c.ReadTimeout, "read-timeout", "HTTP 读超时（如 60s）")
	flag.Var(&c.WriteTimeout, "write-timeout", "HTTP 写超时（如 60s）")
	flag.Var(&c.IdleTimeout, "idle-timeout", "HTTP 空闲连接超时（如 120s）")
	flag.BoolVar(&c.BehindProxy, "behind-proxy", c.BehindProxy, "是否位于可信反向代理之后（开启才信任 X-Forwarded-For）")
	flag.StringVar(&c.CertFile, "cert", c.CertFile, "TLS 证书路径（与 -key 同时设置时启用 HTTPS）")
	flag.StringVar(&c.KeyFile, "key", c.KeyFile, "TLS 私钥路径（与 -cert 同时设置时启用 HTTPS）")
	flag.StringVar(&c.LogLevelStr, "log-level", c.LogLevelStr, "日志级别（debug/info/warn/error）")
	flag.StringVar(&c.LogFile, "log-file", c.LogFile, "日志文件路径（空=stdout）")
	flag.BoolVar(&c.LogJSON, "log-json", c.LogJSON, "是否输出 JSON 格式日志")
	flag.Parse()

	// 收集显式设置的 flag（flag.Visit 仅在被显式传参时回调）
	flag.Visit(func(f *flag.Flag) { set[f.Name] = true })

	// 加载配置文件（仅填充命令行未显式设置的字段）
	if configFile != "" {
		if err := loadConfigFile(c, configFile, set); err != nil {
			// 修复 S-1：配置文件加载失败属致命错误，必须非零退出，
			// 严禁静默回退到弱默认 token 导致鉴权被绕过。
			log.Fatalf("fatal: load config file %q failed: %v", configFile, err)
		}
	}

	// 修复 L-3：环境变量 SAFESERVER_TOKEN 仅在未通过命令行显式设置 token 时生效，
	// 且优先级低于显式 flag、高于配置文件/默认值。
	if !set["token"] {
		if envToken := os.Getenv("SAFESERVER_TOKEN"); envToken != "" {
			c.Token = envToken
		}
	}

	// 解析日志级别字符串到 slog.Level
	c.LogLevel = parseLogLevel(c.LogLevelStr)

	// 修复 L-4：仍在使用默认弱 token 时打印醒目告警，提醒用户配置强 token。
	if c.Token == DefaultToken && !set["token"] && os.Getenv("SAFESERVER_TOKEN") == "" {
		log.Printf("WARNING: using default weak token %q, set -token / SAFESERVER_TOKEN / config.token before any real deployment", DefaultToken)
	}
	return c
}

// loadConfigFile 从 JSON 文件加载配置（仅填充命令行未显式设置的字段）。
//
// set 记录命令行显式设置的 flag 名；只有 set 中不存在的字段才允许配置文件覆盖，
// 从而保证「命令行优先级 > 配置文件」的约定（修复 M-1）。
//
// 使用指针字段区分“未配置”与“显式配置为零值”（如 rateLimit=0 表示禁用），
// 从而正确支持显式零值覆盖（修复配置文件 0 零值覆盖缺陷）。
//
// duration 字段通过自定义 duration 类型解析，支持 "60s" 字符串，不再导致整体解析失败（修复 S-1）。
func loadConfigFile(c *Config, path string, set map[string]bool) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	// 指针字段：nil 表示 JSON 中未出现该键，非 nil 则为显式配置（含零值）
	var fileCfg struct {
		Addr         *string       `json:"addr"`
		DataDir      *string       `json:"dataDir"`
		Token        *string       `json:"token"`
		RateLimit    *int          `json:"rateLimit"`
		MaxBodyBytes *int64        `json:"maxBodyBytes"`
		ReadTimeout  *duration     `json:"readTimeout"`
		WriteTimeout *duration     `json:"writeTimeout"`
		IdleTimeout  *duration     `json:"idleTimeout"`
		BehindProxy  *bool         `json:"behindProxy"`
		CertFile     *string       `json:"certFile"`
		KeyFile      *string       `json:"keyFile"`
		LogLevelStr  *string       `json:"logLevel"`
		LogFile      *string       `json:"logFile"`
		LogJSON      *bool         `json:"logJSON"`
		Backup       *BackupConfig `json:"backup"`
	}
	if err := json.Unmarshal(data, &fileCfg); err != nil {
		return err
	}
	if !set["addr"] && fileCfg.Addr != nil {
		c.Addr = *fileCfg.Addr
	}
	if !set["data"] && fileCfg.DataDir != nil {
		c.DataDir = *fileCfg.DataDir
	}
	if !set["token"] && fileCfg.Token != nil {
		c.Token = *fileCfg.Token
	}
	if !set["rate-limit"] && fileCfg.RateLimit != nil {
		c.RateLimit = *fileCfg.RateLimit
	}
	if !set["max-body"] && fileCfg.MaxBodyBytes != nil {
		c.MaxBodyBytes = *fileCfg.MaxBodyBytes
	}
	if !set["read-timeout"] && fileCfg.ReadTimeout != nil {
		c.ReadTimeout = *fileCfg.ReadTimeout
	}
	if !set["write-timeout"] && fileCfg.WriteTimeout != nil {
		c.WriteTimeout = *fileCfg.WriteTimeout
	}
	if !set["idle-timeout"] && fileCfg.IdleTimeout != nil {
		c.IdleTimeout = *fileCfg.IdleTimeout
	}
	if !set["behind-proxy"] && fileCfg.BehindProxy != nil {
		c.BehindProxy = *fileCfg.BehindProxy
	}
	if !set["cert"] && fileCfg.CertFile != nil {
		c.CertFile = *fileCfg.CertFile
	}
	if !set["key"] && fileCfg.KeyFile != nil {
		c.KeyFile = *fileCfg.KeyFile
	}
	if !set["log-level"] && fileCfg.LogLevelStr != nil {
		c.LogLevelStr = *fileCfg.LogLevelStr
	}
	if !set["log-file"] && fileCfg.LogFile != nil {
		c.LogFile = *fileCfg.LogFile
	}
	if !set["log-json"] && fileCfg.LogJSON != nil {
		c.LogJSON = *fileCfg.LogJSON
	}
	// 备份配置：没有对应 CLI flag，配置文件一旦出现 backup 段就整体采用
	// （其零值字段即文档默认值，无需与默认值做差分）。
	if fileCfg.Backup != nil {
		c.Backup = *fileCfg.Backup
	}
	return nil
}

// parseLogLevel 将字符串转换为 slog.Level
func parseLogLevel(s string) slog.Level {
	switch s {
	case "debug":
		return slog.LevelDebug
	case "info":
		return slog.LevelInfo
	case "warn":
		return slog.LevelWarn
	case "error":
		return slog.LevelError
	default:
		return slog.LevelInfo
	}
}
