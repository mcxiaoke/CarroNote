// 结构化日志模块
//
// 使用轻量自实现的结构化日志，输出 JSON 或文本格式。
// 每条日志带时间戳、级别、消息和结构化字段。
//
// 日志配置：
//   - 级别：debug/info/warn/error
//   - 输出：stdout（默认）或文件
//   - 格式：文本（默认）或 JSON

'use strict';

import fs from 'fs';

const LEVELS = { debug: 10, info: 20, warn: 30, error: 40 };

// Logger 结构化日志器
export class Logger {
  constructor({ level = 'info', file = '', json = false } = {}) {
    this.level = LEVELS[level] || LEVELS.info;
    this.levelName = level;
    this.json = json;
    if (file) {
      try {
        this.stream = fs.createWriteStream(file, { flags: 'a' });
      } catch (err) {
        process.stderr.write(`warning: open log file failed: ${err.message}, fallback to stdout\n`);
        this.stream = process.stdout;
      }
    } else {
      this.stream = process.stdout;
    }
  }

  // enabled 判断指定级别是否会被记录
  enabled(level) {
    return (LEVELS[level] || 0) >= this.level;
  }

  _log(level, msg, fields) {
    if ((LEVELS[level] || 0) < this.level) return;
    const ts = new Date().toISOString();
    if (this.json) {
      // JSON 格式：{"time":"...","level":"info","msg":"...","field1":"value1",...}
      const obj = { time: ts, level, msg, ...fields };
      this.stream.write(JSON.stringify(obj) + '\n');
    } else {
      // 文本格式：time=... level=INFO msg=... field1=value1 field2=value2
      let line = `time=${ts} level=${level.toUpperCase()} msg=${JSON.stringify(msg)}`;
      for (const [k, v] of Object.entries(fields || {})) {
        line += ` ${k}=${formatValue(v)}`;
      }
      this.stream.write(line + '\n');
    }
  }

  debug(msg, fields) { this._log('debug', msg, fields); }
  info(msg, fields) { this._log('info', msg, fields); }
  warn(msg, fields) { this._log('warn', msg, fields); }
  error(msg, fields) { this._log('error', msg, fields); }
}

// formatValue 格式化日志字段值
function formatValue(v) {
  if (v === null || v === undefined) return '';
  if (typeof v === 'object') return JSON.stringify(v);
  return String(v);
}
