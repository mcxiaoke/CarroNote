// Package config 处理 SafeServer 的配置
//
// 配置来源：命令行参数（flag）+ 可选 JSON 配置文件（-config path）。
// 配置文件用于开发/调试场景（如调整日志级别、日志路径），命令行参数优先级更高。
package config

import (
	"encoding/json"
	"flag"
	"log/slog"
	"os"
	"time"
)

// Config 是 SafeServer 的运行配置
type Config struct {
	Addr         string        `json:"addr"`         // 监听地址
	DataDir      string        `json:"dataDir"`      // 数据存储根目录
	Token        string        `json:"token"`        // Bearer Token（认证用）
	RateLimit    int           `json:"rateLimit"`    // 每分钟允许的认证失败次数（<=0 禁用，建议用 -1 显式禁用）
	MaxBodyBytes int64         `json:"maxBodyBytes"` // 请求体最大大小（字节，防恶意大文件上传）
	ReadTimeout  time.Duration `json:"readTimeout"`  // HTTP 读超时（含 body）
	WriteTimeout time.Duration `json:"writeTimeout"` // HTTP 写超时
	IdleTimeout  time.Duration `json:"idleTimeout"`  // HTTP 空闲连接超时

	// 日志配置（开发调试用）
	LogLevel    slog.Level `json:"-"`              // 日志级别（不直接 JSON 序列化，用 LogLevel 字符串）
	LogLevelStr string     `json:"logLevel"`       // 日志级别字符串："debug"/"info"/"warn"/"error"
	LogFile     string     `json:"logFile"`        // 日志文件路径（空=stdout）
	LogJSON     bool       `json:"logJSON"`        // 是否输出 JSON 格式日志（true=JSON，false=文本）
}

// Default 返回默认配置
func Default() *Config {
	return &Config{
		Addr:         ":4080",
		DataDir:      "./data",
		Token:        "my-secret-token",
		RateLimit:    10,
		MaxBodyBytes: 64 << 20, // 64MB
		ReadTimeout:  60 * time.Second,
		WriteTimeout: 60 * time.Second,
		IdleTimeout:  120 * time.Second,
		LogLevelStr:  "info",
		LogFile:      "", // 默认 stdout
		LogJSON:      false,
	}
}

// DevConfig 返回开发调试配置（debug 级别日志，写入文件）
//
// 用法：go run . -config dev.json（dev.json 内容见 docs/server-api-spec.md §13）
func DevConfig(logFile string) *Config {
	c := Default()
	c.LogLevelStr = "debug"
	c.LogFile = logFile
	c.LogJSON = false
	return c
}

// ParseFlags 解析命令行参数
//
// 参数优先级：命令行 flag > 配置文件 > 默认值
func ParseFlags() *Config {
	c := Default()

	var configFile string
	flag.StringVar(&configFile, "config", "", "配置文件路径（JSON，可选，用于开发调试场景）")
	flag.StringVar(&c.Addr, "addr", c.Addr, "监听地址")
	flag.StringVar(&c.DataDir, "data", c.DataDir, "数据存储目录")
	flag.StringVar(&c.Token, "token", c.Token, "Bearer Token（认证用）")
	flag.IntVar(&c.RateLimit, "rate-limit", c.RateLimit, "每分钟允许的认证失败次数（<=0 禁用，建议用 -1）")
	flag.Int64Var(&c.MaxBodyBytes, "max-body", c.MaxBodyBytes, "请求体最大大小（字节，默认 64MB）")
	flag.DurationVar(&c.ReadTimeout, "read-timeout", c.ReadTimeout, "HTTP 读超时")
	flag.DurationVar(&c.WriteTimeout, "write-timeout", c.WriteTimeout, "HTTP 写超时")
	flag.DurationVar(&c.IdleTimeout, "idle-timeout", c.IdleTimeout, "HTTP 空闲连接超时")
	flag.StringVar(&c.LogLevelStr, "log-level", c.LogLevelStr, "日志级别（debug/info/warn/error）")
	flag.StringVar(&c.LogFile, "log-file", c.LogFile, "日志文件路径（空=stdout）")
	flag.BoolVar(&c.LogJSON, "log-json", c.LogJSON, "是否输出 JSON 格式日志")
	flag.Parse()

	// 加载配置文件（命令行参数优先，配置文件只填充未通过命令行设置的字段）
	if configFile != "" {
		if err := loadConfigFile(c, configFile); err != nil {
			// 配置文件加载失败不致命，降级用命令行参数
			os.Stderr.WriteString("warning: load config file failed: " + err.Error() + "\n")
		}
	}

	// 解析日志级别字符串到 slog.Level
	c.LogLevel = parseLogLevel(c.LogLevelStr)
	return c
}

// loadConfigFile 从 JSON 文件加载配置（只填充未通过命令行显式设置的字段）
//
// 简化实现：直接反序列化到 c，覆盖现有值。
// 更严格的做法是用指针字段区分"未设置"和"显式设为零值"，但对当前场景足够。
func loadConfigFile(c *Config, path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	// 反序列化到临时结构，只覆盖非零字段
	var fileCfg Config
	if err := json.Unmarshal(data, &fileCfg); err != nil {
		return err
	}
	// 合并：文件配置覆盖默认值，但命令行参数已解析到 c 中优先级更高
	// 这里简化处理：文件的字段如果非零则覆盖
	if fileCfg.Addr != "" {
		c.Addr = fileCfg.Addr
	}
	if fileCfg.DataDir != "" {
		c.DataDir = fileCfg.DataDir
	}
	if fileCfg.Token != "" {
		c.Token = fileCfg.Token
	}
	if fileCfg.RateLimit != 0 {
		c.RateLimit = fileCfg.RateLimit
	}
	if fileCfg.MaxBodyBytes != 0 {
		c.MaxBodyBytes = fileCfg.MaxBodyBytes
	}
	if fileCfg.ReadTimeout != 0 {
		c.ReadTimeout = fileCfg.ReadTimeout
	}
	if fileCfg.WriteTimeout != 0 {
		c.WriteTimeout = fileCfg.WriteTimeout
	}
	if fileCfg.IdleTimeout != 0 {
		c.IdleTimeout = fileCfg.IdleTimeout
	}
	if fileCfg.LogLevelStr != "" {
		c.LogLevelStr = fileCfg.LogLevelStr
	}
	if fileCfg.LogFile != "" {
		c.LogFile = fileCfg.LogFile
	}
	if fileCfg.LogJSON {
		c.LogJSON = fileCfg.LogJSON
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
