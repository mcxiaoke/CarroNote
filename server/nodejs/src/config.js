// 配置模块
//
// 配置来源：命令行参数 + 可选 JSON 配置文件（--config path）。
// 优先级：命令行参数 > 配置文件 > 默认值。
//
// 用法：
//   node server.js [--port 8080] [--data ./data] [--token xxx]
//                  [--rate-limit 10] [--max-body 67108864]
//                  [--read-timeout 60000] [--write-timeout 60000]
//                  [--log-level info] [--log-file xxx] [--log-json]
//                  [--config dev.json]

'use strict';

import fs from 'fs';
import path from 'path';

// 默认配置
export function defaultConfig() {
  return {
    port: 4080,
    dataDir: './data',
    token: 'my-secret-token',
    rateLimit: 10,            // 每分钟认证失败上限（<=0 禁用，建议用 -1 显式禁用）
    maxBodyBytes: 64 * 1024 * 1024, // 64MB
    readTimeoutMs: 60000,
    writeTimeoutMs: 60000,
    // 日志配置
    logLevel: 'info',     // debug/info/warn/error
    logFile: '',           // 空=stdout
    logJSON: false,        // 是否 JSON 格式
  };
}

// 解析命令行参数
//
// 支持 --port 8080 和 --port=8080 两种形式。
// 如果指定 --config path，会先加载配置文件，再用命令行参数覆盖。
export function parseArgs() {
  const cfg = defaultConfig();
  const args = process.argv.slice(2);

  // 先找 --config，加载配置文件
  let configFile = '';
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--config' && i + 1 < args.length) {
      configFile = args[++i];
    } else if (args[i].startsWith('--config=')) {
      configFile = args[i].slice(9);
    }
  }
  if (configFile) {
    loadConfigFile(cfg, configFile);
  }

  // 命令行参数覆盖配置文件
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    const next = () => args[++i];
    if (a === '--port') cfg.port = parseInt(next(), 10);
    else if (a.startsWith('--port=')) cfg.port = parseInt(a.slice(7), 10);
    else if (a === '--data') cfg.dataDir = next();
    else if (a.startsWith('--data=')) cfg.dataDir = a.slice(7);
    else if (a === '--token') cfg.token = next();
    else if (a.startsWith('--token=')) cfg.token = a.slice(8);
    else if (a === '--rate-limit') cfg.rateLimit = parseInt(next(), 10);
    else if (a.startsWith('--rate-limit=')) cfg.rateLimit = parseInt(a.slice(13), 10);
    else if (a === '--max-body') cfg.maxBodyBytes = parseInt(next(), 10);
    else if (a.startsWith('--max-body=')) cfg.maxBodyBytes = parseInt(a.slice(11), 10);
    else if (a === '--read-timeout') cfg.readTimeoutMs = parseInt(next(), 10);
    else if (a.startsWith('--read-timeout=')) cfg.readTimeoutMs = parseInt(a.slice(15), 10);
    else if (a === '--write-timeout') cfg.writeTimeoutMs = parseInt(next(), 10);
    else if (a.startsWith('--write-timeout=')) cfg.writeTimeoutMs = parseInt(a.slice(16), 10);
    else if (a === '--log-level') cfg.logLevel = next();
    else if (a.startsWith('--log-level=')) cfg.logLevel = a.slice(12);
    else if (a === '--log-file') cfg.logFile = next();
    else if (a.startsWith('--log-file=')) cfg.logFile = a.slice(11);
    else if (a === '--log-json') cfg.logJSON = true;
    else if (a.startsWith('--log-json=')) cfg.logJSON = a.slice(11) === 'true';
    // --config 已处理，跳过
  }

  return cfg;
}

// 从 JSON 文件加载配置（只填充文件中非零/非空的字段）
function loadConfigFile(cfg, file) {
  let data;
  try {
    data = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (err) {
    process.stderr.write(`warning: load config file failed: ${err.message}\n`);
    return;
  }
  if (data.port) cfg.port = data.port;
  if (data.dataDir) cfg.dataDir = data.dataDir;
  if (data.token) cfg.token = data.token;
  if (data.rateLimit) cfg.rateLimit = data.rateLimit;
  if (data.maxBodyBytes) cfg.maxBodyBytes = data.maxBodyBytes;
  if (data.readTimeoutMs) cfg.readTimeoutMs = data.readTimeoutMs;
  if (data.writeTimeoutMs) cfg.writeTimeoutMs = data.writeTimeoutMs;
  if (data.logLevel) cfg.logLevel = data.logLevel;
  if (data.logFile) cfg.logFile = data.logFile;
  if (data.logJSON) cfg.logJSON = data.logJSON;
}
